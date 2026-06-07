# ================================================================
# WireGuard + WARP Kill Switch - FULL AUTOMATIC SETUP
# ================================================================
# * WireGuard is installed automatically if missing
# * Anonymous WARP config is generated via wgcf (no personal info)
# * Kill Switch (firewall rules + monitor + repair layers) installed
# * Run as Administrator
# ================================================================
#Requires -RunAsAdministrator
$ErrorActionPreference = "SilentlyContinue"

# ── Paths ──────────────────────────────────────────────────────
$KLASOR      = "C:\WireGuard"
$CONFIG      = "C:\WireGuard\wgcf-profile.conf"
$LOG         = "C:\WireGuard\killswitch.log"
$MONITOR_PS1 = "C:\WireGuard\monitor.ps1"
$ONARIM_PS1  = "C:\WireGuard\onarim.ps1"
$SERVIS_PS1  = "C:\WireGuard\servis-monitor.ps1"
$WMI_WRAPPER = "C:\WireGuard\wmi-onarim.ps1"
$WG_EXE      = "C:\Program Files\WireGuard\wireguard.exe"
$WGCF_EXE   = "$KLASOR\wgcf.exe"
$NSSM        = "$KLASOR\nssm.exe"

# ── Names ──────────────────────────────────────────────────────
$TUNEL_ADI   = "wgcf-profile"
$TUNEL_SVC   = "WireGuardTunnel`$wgcf-profile"
$GOREV_ANA   = "WG-KillSwitch"
$GOREV_ONARIM= "WG-RepairTask"
$WG_SVC_ADI  = "WGKillSwitchSvc"
$WMI_FILTER  = "WGMonitorFilter"
$WMI_CONSUMER= "WGMonitorConsumer"
$STARTUP_LNK = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WGKillSwitch.lnk"
$GPO_SCRIPT_DIR = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup"
$GPO_SCRIPT  = "$GPO_SCRIPT_DIR\wg-startup.ps1"
$GPO_INI_DIR = "C:\Windows\System32\GroupPolicy\Machine\Scripts"
$GPO_INI     = "$GPO_INI_DIR\scripts.ini"

# ── Helpers ────────────────────────────────────────────────────
function Baslik($t) {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host " $t" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Cyan
}
function OK($t)   { Write-Host " [OK]   $t" -ForegroundColor Green }
function WARN($t) { Write-Host " [WARN] $t" -ForegroundColor Yellow }
function HATA($t) { Write-Host " [ERR]  $t" -ForegroundColor Red }
function BILGI($t){ Write-Host " [-->]  $t" -ForegroundColor Gray }

function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(3000) | Out-Null
        Add-Content -Path $LOG -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $m" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally {
        if ($mutex) { try { $mutex.ReleaseMutex() } catch {} }
    }
}

function GorevDurdurSil($isim) {
    schtasks /End    /TN "\$isim" /F 2>$null | Out-Null
    schtasks /Delete /TN "\$isim" /F 2>$null | Out-Null
    Stop-ScheduledTask      -TaskName $isim -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName $isim -Confirm:$false -EA SilentlyContinue
}

function TunelCalisiyor {
    return ((& sc.exe query $TUNEL_SVC 2>$null) -match "RUNNING")
}

function ScriptsIniGuncelle($iniDosyasi, $scriptYolu) {
    New-Item -ItemType Directory -Path (Split-Path $iniDosyasi) -Force -EA SilentlyContinue | Out-Null
    $icerik = ""
    if (Test-Path $iniDosyasi) {
        $icerik = Get-Content $iniDosyasi -Raw -Encoding Unicode -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($icerik)) {
            $icerik = Get-Content $iniDosyasi -Raw -EA SilentlyContinue
        }
    }
    if ($null -eq $icerik) { $icerik = "" }
    if ($icerik -match [regex]::Escape($scriptYolu)) { BILGI "GPO scripts.ini: already registered"; return }
    if ($icerik -match "\[Startup\]") {
        $maxIndex = -1; $startup = $false
        foreach ($satir in ($icerik -split "`r?`n")) {
            if ($satir -match "^\[Startup\]") { $startup = $true; continue }
            if ($satir -match "^\[" -and $satir -notmatch "^\[Startup\]") { $startup = $false; continue }
            if ($startup -and $satir -match "^(\d+)CmdLine=") {
                $idx = [int]$Matches[1]; if ($idx -gt $maxIndex) { $maxIndex = $idx }
            }
        }
        $yi = $maxIndex + 1
        $yeniBlok = "${yi}CmdLine=powershell.exe`r`n${yi}Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptYolu`"`r`n"
        $icerik = $icerik -replace "(\[Startup\]\r?\n)", "`$1$yeniBlok"
    } else {
        $icerik += "`r`n[Startup]`r`n0CmdLine=powershell.exe`r`n0Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptYolu`"`r`n"
    }
    $icerik | Set-Content $iniDosyasi -Encoding Unicode -Force
}

function WarpIpleriniAl {
    $ipList = [System.Collections.Generic.List[string]]::new()
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match "^\s*Endpoint\s*=" } | Select-Object -First 1
        if ($ep -match "=\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+:") {
            $prefix = $Matches[1] + ".0/24"
            if (-not $ipList.Contains($prefix)) { $ipList.Add($prefix) }
            BILGI "WARP endpoint from conf: $prefix"
        }
    } catch {}
    try {
        $resp = Invoke-RestMethod "https://api.cloudflare.com/client/v4/ips" -TimeoutSec 8 -EA Stop
        if ($resp.success -and $resp.result.ipv4_cidrs) {
            foreach ($cidr in $resp.result.ipv4_cidrs) {
                if ($cidr -match "^(162\.159\.|104\.16\.)") {
                    if (-not $ipList.Contains($cidr)) { $ipList.Add($cidr) }
                }
            }
        }
    } catch {}
    if ($ipList.Count -eq 0) {
        @("162.159.192.0/24","162.159.193.0/24","162.159.195.0/24","104.16.0.0/13") |
            ForEach-Object { $ipList.Add($_) }
        WARN "Using WARP IP fallback"
    }
    return ($ipList -join ",")
}

# ================================================================
# ADMIN CHECK
# ================================================================
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "`n [!!] Run as Administrator!" -ForegroundColor Red; pause; exit 1
}

# ================================================================
Baslik "STEP 0 - WIREGUARD + WARP AUTOMATIC INSTALL"
# ================================================================
New-Item -ItemType Directory -Path $KLASOR -Force | Out-Null

# -- 0.1 WireGuard --
if (-not (Test-Path $WG_EXE)) {
    BILGI "WireGuard not found - downloading..."
    $wgMsi = "$KLASOR\wireguard-amd64.msi"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://download.wireguard.com/windows-client/wireguard-amd64-0.5.3.msi" `
            -OutFile $wgMsi -TimeoutSec 60 -UseBasicParsing
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$wgMsi`" /quiet /norestart" `
            -Wait -NoNewWindow -PassThru
        if ($p.ExitCode -eq 0) { OK "WireGuard installed" }
        else { HATA "WireGuard install failed (exit $($p.ExitCode))"; pause; exit 1 }
        Remove-Item $wgMsi -Force -EA SilentlyContinue
    } catch { HATA "WireGuard download/install error: $_"; pause; exit 1 }
} else { OK "WireGuard already present" }

# -- 0.2 wgcf --
if (-not (Test-Path $WGCF_EXE)) {
    BILGI "Downloading wgcf..."
    try {
        Invoke-WebRequest "https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_windows_amd64.exe" `
            -OutFile $WGCF_EXE -TimeoutSec 30 -UseBasicParsing
        OK "wgcf downloaded"
    } catch { HATA "wgcf download failed: $_"; pause; exit 1 }
} else { OK "wgcf already present" }

# -- 0.3 WARP config (anonymous, no personal info) --
if (-not (Test-Path $CONFIG)) {
    BILGI "Generating anonymous WARP config..."
    Push-Location $KLASOR
    try {
        $r = & $WGCF_EXE register --accept-tos 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wgcf register failed: $r" }
        $g = & $WGCF_EXE generate 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wgcf generate failed: $g" }
        if (Test-Path "$KLASOR\wgcf-profile.conf") {
            Move-Item "$KLASOR\wgcf-profile.conf" $CONFIG -Force
            OK "WARP config created: $CONFIG"
        } else { throw "wgcf-profile.conf not found after generate" }
    } catch { HATA "WARP config failed: $_"; Pop-Location; pause; exit 1 }
    Pop-Location
} else { OK "WARP config already exists" }

$confCheck = Get-Content $CONFIG -Encoding UTF8 -EA Stop
if ($confCheck -notmatch "PrivateKey" -or $confCheck -notmatch "Endpoint") {
    HATA "Config file invalid (missing PrivateKey or Endpoint)"; pause; exit 1
}

# ================================================================
Baslik "STEP 1 - FOLDER PREP"
# ================================================================
New-Item -ItemType Directory -Path $KLASOR -Force | Out-Null
OK "Folder ready: $KLASOR"

# ================================================================
Baslik "STEP 2 - NSSM"
# ================================================================
if (-not (Test-Path $NSSM)) {
    try {
        $zip = "$KLASOR\nssm.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -TimeoutSec 45 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zf    = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $entry = $zf.Entries | Where-Object { $_.FullName -like "*win64/nssm.exe" } | Select-Object -First 1
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $NSSM, $true)
        $zf.Dispose(); Remove-Item $zip -Force -EA SilentlyContinue
        OK "NSSM downloaded"
    } catch { WARN "NSSM download failed - service layer will be skipped" }
} else { OK "NSSM present" }

# ================================================================
Baslik "STEP 3 - CLEANUP (old installs)"
# ================================================================
GorevDurdurSil $GOREV_ANA
GorevDurdurSil $GOREV_ONARIM
GorevDurdurSil "WireGuard-KillSwitch-Monitor"
# Old task names (Turkish - kept for backward compat cleanup)
GorevDurdurSil "WG-OnarimGorevi"

$eskiSvc = & sc.exe query $WG_SVC_ADI 2>$null
if ($eskiSvc) {
    if ($eskiSvc -match "PAUSED") { & sc.exe continue $WG_SVC_ADI 2>$null | Out-Null; Start-Sleep 2 }
    if (Test-Path $NSSM) { & $NSSM stop $WG_SVC_ADI 2>$null | Out-Null }
    & sc.exe stop   $WG_SVC_ADI 2>$null | Out-Null; Start-Sleep 2
    if (Test-Path $NSSM) { & $NSSM remove $WG_SVC_ADI confirm 2>$null | Out-Null }
    & sc.exe delete $WG_SVC_ADI 2>$null | Out-Null; Start-Sleep 2
}

Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_FILTER } | Remove-CimInstance -EA SilentlyContinue
Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_CONSUMER } | Remove-CimInstance -EA SilentlyContinue
Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -EA SilentlyContinue |
    Where-Object { $_.Filter -like "*$WMI_FILTER*" } | Remove-CimInstance -EA SilentlyContinue

# Remove old Turkish-named filters (backward compat)
foreach ($oldFilter in @("WGMonitorOldu")) {
    Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
        Where-Object { $_.Name -eq $oldFilter } | Remove-CimInstance -EA SilentlyContinue
}

Remove-Item $STARTUP_LNK -Force -EA SilentlyContinue

Get-CimInstance Win32_Process -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like "*monitor.ps1*" -or $_.CommandLine -like "*onarim.ps1*" -or
                   $_.CommandLine -like "*servis-monitor.ps1*" -or $_.CommandLine -like "*wmi-onarim.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

# All rule names (English + old Turkish)
$allRules = @(
    "KS-Block-WiFi-Out","KS-Block-Ethernet-Out","KS-Block-IPv6-Out","KS-Block-IPv6-In",
    "KS-LAN-Out","KS-LAN-In","KS-DHCP-Out","KS-DHCP-In",
    "KS-WARP-Server-Out","KS-Loopback-Out","KS-Loopback-In",
    "KS-DNS-Allow","KS-DNS-Block","KS-WireGuard-EXE","KS-WireGuard-Tunnel-SVC",
    # Old Turkish names
    "KS - ENGEL Wi-Fi Cikis","KS - ENGEL Ethernet Cikis","KS - ENGEL IPv6 Cikis","KS - ENGEL IPv6 Giris",
    "KS - Yerel Ag Cikis","KS - Yerel Ag Giris","KS - DHCP Cikis","KS - DHCP Giris",
    "KS - WARP Sunucu Cikis","KS - Loopback Cikis","KS - Loopback Giris",
    "KS - DNS Izin","KS - DNS Engel","KS - WireGuard EXE","KS - WireGuard Tunnel SVC"
)
foreach ($k in $allRules) { netsh advfirewall firewall delete rule name="$k" | Out-Null }

netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
& $WG_EXE /uninstalltunnelservice $TUNEL_ADI 2>$null; Start-Sleep 3
Remove-Item "$KLASOR\onarim.lock" -Force -EA SilentlyContinue
if (Test-Path $LOG) { attrib -H -S $LOG 2>$null | Out-Null }
Get-ChildItem $KLASOR -File -EA SilentlyContinue | ForEach-Object { attrib -H -S $_.FullName 2>$null | Out-Null }
OK "Cleanup done"

# ================================================================
Baslik "STEP 4 - IPv6 BLOCK"
# ================================================================
Remove-NetFirewallRule -DisplayName "KS-Block-IPv6-Out" -EA SilentlyContinue
Remove-NetFirewallRule -DisplayName "KS-Block-IPv6-In"  -EA SilentlyContinue
New-NetFirewallRule -DisplayName "KS-Block-IPv6-Out" -Direction Outbound -Action Block `
    -RemoteAddress "fe80::/10","2001::/32","2002::/16","fc00::/7","2000::/3" `
    -Enabled True -EA SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "KS-Block-IPv6-In" -Direction Inbound -Action Block `
    -RemoteAddress "fe80::/10","2001::/32","2002::/16","fc00::/7","2000::/3" `
    -Enabled True -EA SilentlyContinue | Out-Null
Get-NetAdapter | Where-Object { $_.Status -ne "Not Present" -and $_.Name -ne $TUNEL_ADI } |
    ForEach-Object { Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -EA SilentlyContinue }
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" `
    -Name "DisabledComponents" -Value 0xFF -Type DWord -Force -EA SilentlyContinue
OK "IPv6 blocked"

# ================================================================
Baslik "STEP 5 - WIREGUARD TUNNEL"
# ================================================================
& $WG_EXE /installtunnelservice $CONFIG 2>$null
Start-Sleep 7
if (TunelCalisiyor) { OK "Tunnel RUNNING" } else { WARN "Tunnel not up yet - monitor will start it" }
& sc.exe config $TUNEL_SVC start= delayed-auto 2>$null | Out-Null
OK "WireGuard tunnel: delayed-auto-start"

# ================================================================
Baslik "STEP 6 - FIREWALL RULES"
# ================================================================
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
netsh advfirewall firewall add rule name="KS-Block-WiFi-Out" `
    dir=out action=block interfacetype=wireless remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out" `
    dir=out action=block interfacetype=lan    remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-LAN-Out" `
    dir=out action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-LAN-In" `
    dir=in  action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DHCP-Out" `
    dir=out action=allow protocol=UDP localport=68 remoteport=67 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DHCP-In" `
    dir=in  action=allow protocol=UDP localport=68 remoteport=67 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Loopback-Out" `
    dir=out action=allow remoteip=127.0.0.0/8 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Loopback-In" `
    dir=in  action=allow remoteip=127.0.0.0/8 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Allow" `
    dir=out action=allow protocol=UDP remoteip=1.1.1.1,1.0.0.1 remoteport=53 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Block" `
    dir=out action=block protocol=UDP remoteport=53 enable=yes | Out-Null

$warpIpler = WarpIpleriniAl
BILGI "WARP IPs: $warpIpler"
netsh advfirewall firewall add rule name="KS-WARP-Server-Out" `
    dir=out action=allow protocol=UDP remoteip=$warpIpler remoteport=2408,854 enable=yes | Out-Null
OK "Firewall rules applied"

if (TunelCalisiyor) {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"     | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out" | Out-Null
    OK "Tunnel active - internet unblocked"
} else { WARN "Tunnel down - block rules active" }

# ================================================================
Baslik "STEP 7 - MONITOR SCRIPT"
# ================================================================
@'
# WireGuard Kill Switch - Monitor (auto-generated by install.ps1)
$TUNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$TUNEL_ADI = 'wgcf-profile'
$CONFIG    = 'C:\WireGuard\wgcf-profile.conf'
$LOG       = 'C:\WireGuard\killswitch.log'
$WG_EXE    = 'C:\Program Files\WireGuard\wireguard.exe'

function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(3000) | Out-Null
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [MON] $m" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}

function TunelCalisiyor { return ((& sc.exe query $TUNEL_SVC 2>$null) -match "RUNNING") }

function InternetVar {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('1.1.1.1', 443, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne(4000, $false)
        if ($ok) { $tcp.EndConnect($iar); $tcp.Close(); return $true }
        $tcp.Close(); return $false
    } catch { return $false }
}

function WarpIpAl {
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match '^\s*Endpoint\s*=' } | Select-Object -First 1
        if ($ep -match '=\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+:') { return ($Matches[1] + '.0/24') }
    } catch {}
    return "162.159.192.0/24,162.159.193.0/24,162.159.195.0/24,104.16.0.0/13"
}

function EngelKapat {
    $warpIp = WarpIpAl
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"     2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-WiFi-Out" `
        dir=out action=block interfacetype=wireless remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out" `
        dir=out action=block interfacetype=lan    remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-WARP-Server-Out" `
        dir=out action=allow protocol=UDP remoteip=$warpIp remoteport=2408,854 enable=yes | Out-Null
    Log "BLOCK active (WARP $warpIp allowed)"
}

function EngelAc {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"     | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out" | Out-Null
    Log "BLOCK removed - internet open"
}

function WarpKuraliniGaranti {
    $ip = WarpIpAl
    netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-WARP-Server-Out" `
        dir=out action=allow protocol=UDP remoteip=$ip remoteport=2408,854 enable=yes | Out-Null
    Log "WARP rule refreshed ($ip)"
}

function TunelKurmeYDene {
    $mux = $null
    try {
        $mux = New-Object System.Threading.Mutex($false, 'Global\WGTunnelInstallMutex')
        if (-not $mux.WaitOne(60000)) {
            Log "TunnelReinstall: mutex timeout - another process is installing, keeping current state"
            return (TunelCalisiyor)
        }
        Get-Process -Name "wireguard" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        $wgSvcPid = (Get-CimInstance Win32_Service -Filter "Name='$TUNEL_SVC'" -EA SilentlyContinue).ProcessId
        if ($wgSvcPid -and $wgSvcPid -gt 0) { Stop-Process -Id $wgSvcPid -Force -EA SilentlyContinue }
        Start-Sleep -Seconds 1
        & $WG_EXE /uninstalltunnelservice $TUNEL_ADI 2>$null
        Start-Sleep -Seconds 3
        & $WG_EXE /installtunnelservice $CONFIG 2>$null
        Start-Sleep -Seconds 10
        return (TunelCalisiyor)
    } finally {
        if ($mux) { try { $mux.ReleaseMutex() } catch {} }
    }
}

Log "=== Monitor started ==="

# Boot grace period: wait up to 90s for tunnel on fresh boot
try {
    $bootTime = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
    if ((Get-Date) -lt $bootTime.AddSeconds(90)) {
        Log "Fresh boot detected - extra 15s wait for network stack"
        Start-Sleep -Seconds 15
    }
} catch {}

$bootWait = 0
while ($bootWait -lt 90 -and -not (TunelCalisiyor)) {
    Start-Sleep -Seconds 3; $bootWait += 3
}

if (TunelCalisiyor) {
    $durum = 'running'
    Clear-DnsClientCache -EA SilentlyContinue
    EngelAc
    Log "Startup: tunnel running (waited ${bootWait}s), internet open"
} else {
    $durum = 'stopped'
    EngelKapat
    Log "Startup: tunnel down (waited ${bootWait}s), block active - starting recovery"
}

$loopCount = 0
while ($true) {
    Start-Sleep -Seconds 5
    $loopCount++

    if (TunelCalisiyor) {
        if ($durum -ne 'running') {
            Clear-DnsClientCache -EA SilentlyContinue
            EngelAc
            $durum = 'running'
        }
    } else {
        if ($durum -ne 'stopped') {
            Log "WARNING: Tunnel went down - activating block"
            EngelKapat
            $durum = 'stopped'
        }
        WarpKuraliniGaranti
        Log "Starting recovery"
        $success = $false
        $totalAttempts = 0
        while (-not $success) {
            for ($i = 1; $i -le 5; $i++) {
                $totalAttempts++
                Log "Attempt $i/5 (total: $totalAttempts)"
                $up = TunelKurmeYDene
                if ($up) {
                    $waited = 0; $netOK = $false
                    while ($waited -lt 30) {
                        if (InternetVar) { $netOK = $true; break }
                        Start-Sleep -Seconds 5; $waited += 5
                    }
                    if ($netOK) {
                        Log "Attempt $i - tunnel + internet OK (waited ${waited}s)"
                        Clear-DnsClientCache -EA SilentlyContinue
                        EngelAc; $durum = 'running'; $success = $true; break
                    } else {
                        Log "Attempt $i - tunnel up but no internet after 30s, retrying"
                        EngelKapat
                        & $WG_EXE /uninstalltunnelservice $TUNEL_ADI 2>$null
                        Start-Sleep -Seconds 3
                    }
                } else {
                    Log "Attempt $i - tunnel did not start"
                    Start-Sleep -Seconds 5
                }
            }
            if (-not $success) {
                Log "CRITICAL: 5 attempts failed (total: $totalAttempts) - waiting 3min then retrying"
                EngelKapat
                $waited = 0
                while ($waited -lt 180) {
                    Start-Sleep -Seconds 15; $waited += 15
                    if (TunelCalisiyor) {
                        Log "Tunnel came up during 3min wait!"
                        $success = $true
                        Clear-DnsClientCache -EA SilentlyContinue
                        EngelAc; $durum = 'running'; break
                    }
                }
                if ($success) { break }
                Log "3min wait done - retrying..."
            }
        }
    }
}
'@ | Set-Content $MONITOR_PS1 -Encoding UTF8 -Force
attrib -H -S $MONITOR_PS1 2>$null | Out-Null
try {
    $raw = [System.IO.File]::ReadAllText($MONITOR_PS1, [System.Text.Encoding]::UTF8)
    $raw = $raw -replace "(?<!\r)\n", "`r`n"
    [System.IO.File]::WriteAllText($MONITOR_PS1, $raw, [System.Text.Encoding]::UTF8)
} catch {}
OK "monitor.ps1 written"

# ================================================================
Baslik "STEP 8 - REPAIR SCRIPT"
# ================================================================
@'
# WG Repair Script (auto-generated by install.ps1)
$GOREV_ANA = "WG-KillSwitch"
$MONITOR   = "C:\WireGuard\monitor.ps1"
$LOG       = "C:\WireGuard\killswitch.log"
$TUNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$WG_EXE    = "C:\Program Files\WireGuard\wireguard.exe"
$CONFIG    = "C:\WireGuard\wgcf-profile.conf"
$TUNEL_ADI = "wgcf-profile"
$LOCK      = "C:\WireGuard\onarim.lock"

function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(3000) | Out-Null
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [REPAIR] $m" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}

if (Test-Path $LOCK) {
    $lp = [int](Get-Content $LOCK -EA SilentlyContinue)
    if ($lp -and (Get-Process -Id $lp -EA SilentlyContinue)) { exit 0 }
    Remove-Item $LOCK -Force -EA SilentlyContinue
}
$PID | Set-Content $LOCK -Force -EA SilentlyContinue

try {
    if (Test-Path $LOG) { attrib -H -S $LOG 2>$null | Out-Null }

    # Firewall policy check
    $policyOK = $true
    foreach ($profile in @("DomainProfile","PrivateProfile","PublicProfile")) {
        if ((netsh advfirewall show $profile 2>$null) -match "BlockOutbound") { $policyOK = $false }
    }
    if (-not $policyOK) {
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
        Log "Firewall policy corrected"
    }

    # Firewall service check
    if ((& sc.exe query MpsSvc 2>$null) -match "STOPPED") {
        & sc.exe start MpsSvc 2>$null | Out-Null; Start-Sleep 3
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
        Log "CRITICAL: Firewall service restarted"
    }

    # Scheduled task check
    $task = Get-ScheduledTask -TaskName $GOREV_ANA -EA SilentlyContinue
    if (-not $task) {
        $b64 = (Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -Name "TaskXML" -EA SilentlyContinue).TaskXML
        if ($b64) {
            [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) |
                Register-ScheduledTask -TaskName $GOREV_ANA -Force | Out-Null
            schtasks /Run /TN "\$GOREV_ANA" 2>$null | Out-Null
            Log "WG-KillSwitch task restored from registry backup"
        } else { Log "CRITICAL: No registry backup found" }
    } elseif ($task.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $GOREV_ANA | Out-Null
        schtasks /Run /TN "\$GOREV_ANA" 2>$null | Out-Null
        Log "WG-KillSwitch task re-enabled"
    }

    # Tunnel check
    if ((& sc.exe query $TUNEL_SVC 2>$null) -notmatch "RUNNING") {
        Log "Tunnel not running - reinstalling"
        if ((Test-Path $WG_EXE) -and (Test-Path $CONFIG)) {
            & $WG_EXE /uninstalltunnelservice $TUNEL_ADI 2>$null | Out-Null
            Start-Sleep 2
            & $WG_EXE /installtunnelservice $CONFIG 2>$null | Out-Null
            Start-Sleep 8
            if ((& sc.exe query $TUNEL_SVC 2>$null) -match "RUNNING") { Log "Tunnel reinstalled OK" }
            else { Log "CRITICAL: Tunnel could not be reinstalled" }
        }
    }

    # Service check
    if ((& sc.exe query WGKillSwitchSvc 2>$null) -notmatch "RUNNING") {
        Log "WGKillSwitchSvc not running - starting"
        & sc.exe start WGKillSwitchSvc 2>$null | Out-Null; Start-Sleep 5
        if ((& sc.exe query WGKillSwitchSvc 2>$null) -match "RUNNING") { Log "WGKillSwitchSvc started" }
        else { Log "CRITICAL: WGKillSwitchSvc could not start" }
    }

    # Monitor process check
    Start-Sleep -Milliseconds 500
    $procs = Get-Process powershell -EA SilentlyContinue | Where-Object {
        try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
        catch { $false }
    }
    if (-not $procs) {
        Log "Monitor process missing - triggering task and direct start"
        schtasks /Run /TN "\$GOREV_ANA" 2>$null | Out-Null
        Start-Sleep 3
        $procs2 = Get-Process powershell -EA SilentlyContinue | Where-Object {
            try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
            catch { $false }
        }
        if (-not $procs2) {
            Start-Process powershell.exe -ArgumentList "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MONITOR`"" -WindowStyle Hidden
            Log "Monitor started directly"
        }
    } elseif (($procs | Measure-Object).Count -gt 1) {
        $procs | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object {
            Stop-Process -Id $_.Id -Force -EA SilentlyContinue
            Log "Duplicate monitor killed (PID: $($_.Id))"
        }
    }
} finally {
    Remove-Item $LOCK -Force -EA SilentlyContinue
}
'@ | Set-Content $ONARIM_PS1 -Encoding UTF8 -Force
OK "repair.ps1 written"

# ================================================================
Baslik "STEP 9 - WMI WRAPPER"
# ================================================================
@'
# WMI Repair Wrapper (auto-generated by install.ps1)
$LOG    = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\onarim.ps1'
function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(2000) | Out-Null
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [WMI] $m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}
Start-Sleep -Seconds 2
$proc = Get-Process powershell -EA SilentlyContinue | Where-Object {
    try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
    catch { $false }
}
if (-not $proc) {
    Log "Monitor gone - triggering repair"
    if (Test-Path $REPAIR) {
        Start-Process powershell.exe -ArgumentList "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR`"" -WindowStyle Hidden
    }
} else {
    Log "WMI triggered but monitor still running (other PS exited) - no action"
}
'@ | Set-Content $WMI_WRAPPER -Encoding UTF8 -Force
OK "wmi-wrapper.ps1 written"

# ================================================================
Baslik "STEP 10 - SERVICE MONITOR (NSSM wrapper)"
# ================================================================
@'
# WGKillSwitchSvc wrapper - run by NSSM as a Windows service (auto-generated by install.ps1)
$LOG    = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\onarim.ps1'
function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(2000) | Out-Null
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [SVC] $m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}
Log "WGKillSwitchSvc started"
Start-Sleep -Seconds 20
if (Test-Path $REPAIR) {
    Start-Process powershell.exe -ArgumentList "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR`"" -WindowStyle Hidden
    Log "Initial repair triggered"
}
while ($true) {
    Start-Sleep -Seconds 30
    $proc = Get-Process powershell -EA SilentlyContinue | Where-Object {
        try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
        catch { $false }
    }
    if (-not $proc) {
        Log "Monitor missing - triggering repair"
        if (Test-Path $REPAIR) {
            Start-Process powershell.exe -ArgumentList "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR`"" -WindowStyle Hidden
        }
    }
}
'@ | Set-Content $SERVIS_PS1 -Encoding UTF8 -Force
OK "service-monitor.ps1 written"

# ================================================================
Baslik "STEP 11 - MAIN SCHEDULED TASK (60s boot delay)"
# ================================================================
GorevDurdurSil $GOREV_ANA
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MONITOR_PS1`""
$trigger  = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT60S"
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $GOREV_ANA -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
schtasks /Run /TN "\$GOREV_ANA" 2>$null | Out-Null
Start-Sleep 2
$g1 = Get-ScheduledTask -TaskName $GOREV_ANA -EA SilentlyContinue
if ($g1) { OK "WG-KillSwitch task registered ($($g1.State)) - 60s boot delay" }
else      { HATA "WG-KillSwitch task registration FAILED!" }

# ================================================================
Baslik "STEP 12 - REPAIR TASK (30s boot delay + every 5min)"
# ================================================================
GorevDurdurSil $GOREV_ONARIM
$action2   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ONARIM_PS1`""
$trigger2a = New-ScheduledTaskTrigger -AtStartup
$trigger2a.Delay = "PT30S"
$trigger2b = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 9999)
$settings2 = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false -MultipleInstances IgnoreNew
$principal2 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $GOREV_ONARIM -Action $action2 `
    -Trigger $trigger2a,$trigger2b -Settings $settings2 -Principal $principal2 -Force | Out-Null
$g2 = Get-ScheduledTask -TaskName $GOREV_ONARIM -EA SilentlyContinue
if ($g2) { OK "WG-RepairTask registered ($($g2.State)) - 30s boot delay + every 5min" }
else      { HATA "WG-RepairTask registration FAILED!" }

# ================================================================
Baslik "STEP 13 - REGISTRY BACKUP + FOLDER PROTECTION"
# ================================================================
$acl = Get-Acl $KLASOR
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM",   "FullControl",     "ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl",     "ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users",         "ReadAndExecute",  "ContainerInherit,ObjectInherit","None","Allow")))
Set-Acl -Path $KLASOR -AclObject $acl
Get-ChildItem $KLASOR -File | Where-Object { $_.Name -ne "killswitch.log" } |
    ForEach-Object { attrib +S +H $_.FullName }
OK "ACL set + files hidden"

$taskXml = Export-ScheduledTask -TaskName $GOREV_ANA
if ($taskXml) {
    $taskXml | Set-Content "$KLASOR\WG-KillSwitch-backup.xml" -Encoding UTF8 -Force
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskXml))
    New-Item -Path "HKLM:\SOFTWARE\WGKillSwitch" -Force | Out-Null
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TaskXML"       $b64                              -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "MonitorPath"   $MONITOR_PS1                      -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RepairPath"    $ONARIM_PS1                       -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "Version"       "1.0"                             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "InstalledDate" (Get-Date -f "yyyy-MM-dd HH:mm:ss") -Force
    OK "Registry backup written"
}

Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "WGKillSwitchGuard" `
    "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ONARIM_PS1`"" -Force
OK "Registry Run key added"

& sc.exe failure $TUNEL_SVC reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
OK "WireGuard tunnel crash recovery configured"

# ================================================================
Baslik "STEP 14 - WINDOWS SERVICE (NSSM)"
# ================================================================
if (Test-Path $NSSM) {
    & $NSSM install    $WG_SVC_ADI powershell.exe 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI AppParameters "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SERVIS_PS1`"" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI Start          SERVICE_DELAYED_AUTO_START 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI ObjectName     LocalSystem 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI DisplayName    "WG KillSwitch Guard" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI Description    "WireGuard Kill Switch - auto-generated" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI AppExit        Default Restart 2>$null | Out-Null
    & $NSSM set        $WG_SVC_ADI AppRestartDelay 5000 2>$null | Out-Null
    & sc.exe failure   $WG_SVC_ADI reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
    & sc.exe sdset     $WG_SVC_ADI "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)" 2>$null | Out-Null
    & $NSSM start      $WG_SVC_ADI 2>$null | Out-Null
    Start-Sleep 5
    $svcStatus = & sc.exe query $WG_SVC_ADI 2>$null
    if ($svcStatus -match "RUNNING") { OK "WGKillSwitchSvc: RUNNING (delayed-auto)" }
    elseif ($svcStatus -match "PENDING") { OK "WGKillSwitchSvc: STARTING..." }
    else { WARN "WGKillSwitchSvc did not start - other layers still active" }
} else { WARN "NSSM not available - service layer skipped" }

# ================================================================
Baslik "STEP 15 - WMI SUBSCRIPTION"
# ================================================================
$wmiQuery  = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name = 'powershell.exe'"
$filter    = New-CimInstance -Namespace root\subscription -ClassName __EventFilter `
    -Property @{ Name=$WMI_FILTER; EventNamespace="root\cimv2"; QueryLanguage="WQL"; Query=$wmiQuery } -EA SilentlyContinue
$consumer  = New-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer `
    -Property @{ Name=$WMI_CONSUMER; CommandLineTemplate="powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WMI_WRAPPER`"" } -EA SilentlyContinue
if ($filter -and $consumer) {
    New-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding `
        -Property @{ Filter=[Ref]$filter; Consumer=[Ref]$consumer } -EA SilentlyContinue | Out-Null
    OK "WMI Event Subscription active"
} else { WARN "WMI Subscription failed" }

# ================================================================
Baslik "STEP 16 - STARTUP FOLDER SHORTCUT"
# ================================================================
New-Item -ItemType Directory -Path (Split-Path $STARTUP_LNK) -Force -EA SilentlyContinue | Out-Null
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($STARTUP_LNK)
$lnk.TargetPath      = "powershell.exe"
$lnk.Arguments       = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ONARIM_PS1`""
$lnk.WorkingDirectory = $KLASOR
$lnk.Save()
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut created" } else { WARN "Startup shortcut failed" }

# ================================================================
Baslik "STEP 17 - GPO BOOT SCRIPT"
# ================================================================
New-Item -ItemType Directory -Path $GPO_SCRIPT_DIR -Force -EA SilentlyContinue | Out-Null
@'
# WG KillSwitch GPO Boot Script (auto-generated by install.ps1)
$LOG    = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\onarim.ps1'
function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        $mutex.WaitOne(2000) | Out-Null
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [GPO] $m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}
Log "GPO boot script fired"
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>$null | Out-Null
$waited = 0
while ($waited -lt 60) {
    if ((& sc.exe query "WireGuardTunnel`$wgcf-profile" 2>$null) -match "RUNNING") { break }
    Start-Sleep -Seconds 3; $waited += 3
}
if (Test-Path $REPAIR) {
    Start-Process powershell.exe -ArgumentList "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR`"" -WindowStyle Hidden
    Log "Repair triggered (waited ${waited}s)"
}
'@ | Set-Content $GPO_SCRIPT -Encoding UTF8 -Force
ScriptsIniGuncelle $GPO_INI $GPO_SCRIPT
Start-Process "secedit.exe"  -ArgumentList "/refreshpolicy machine_policy /enforce" -WindowStyle Hidden -Wait -EA SilentlyContinue
Start-Process "gpupdate.exe" -ArgumentList "/force" -WindowStyle Hidden -EA SilentlyContinue
if (Test-Path $GPO_SCRIPT) { OK "GPO boot script installed" } else { WARN "GPO script failed" }

# ================================================================
Baslik "STEP 18 - DEFENDER EXCLUSION"
# ================================================================
try { Add-MpPreference -ExclusionPath $KLASOR -EA Stop; OK "Defender exclusion: $KLASOR" }
catch { WARN "Defender exclusion failed" }

# ================================================================
Baslik "STEP 19 - FINAL CHECK"
# ================================================================
$warnings = 0
if (TunelCalisiyor) { OK "Tunnel: RUNNING" } else { WARN "Tunnel: DOWN (monitor will recover)"; $warnings++ }

$g1 = Get-ScheduledTask -TaskName $GOREV_ANA    -EA SilentlyContinue
$g2 = Get-ScheduledTask -TaskName $GOREV_ONARIM -EA SilentlyContinue
if ($g1) { OK "WG-KillSwitch task: $($g1.State)" }         else { HATA "WG-KillSwitch task MISSING"; $warnings++ }
if ($g2) {
    $tc = ($g2.Triggers | Measure-Object).Count
    if ($tc -ge 2) { OK "WG-RepairTask: $($g2.State) ($tc triggers)" }
    else { WARN "WG-RepairTask: $tc trigger(s) (expected 2)"; $warnings++ }
} else { HATA "WG-RepairTask MISSING"; $warnings++ }

Start-Sleep 3
$proc = Get-Process powershell -EA SilentlyContinue | Where-Object {
    try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
    catch { $false }
}
if (($proc | Measure-Object).Count -gt 1) {
    $proc | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
    Start-Sleep 2
    $proc = Get-Process powershell -EA SilentlyContinue | Where-Object {
        try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine -like "*monitor.ps1*" }
        catch { $false }
    }
}
if ($proc) { OK "Monitor: active (PID: $(($proc | Select-Object -First 1).Id))" }
else        { WARN "Monitor: not yet running" }

$svcSt = & sc.exe query $WG_SVC_ADI 2>$null
if ($svcSt -match "RUNNING")      { OK "WGKillSwitchSvc: RUNNING" }
elseif (Test-Path $NSSM)           { WARN "WGKillSwitchSvc: not running"; $warnings++ }
else                               { WARN "WGKillSwitchSvc: NSSM absent, skipped" }

if ((& sc.exe qc $TUNEL_SVC 2>$null) -match "DELAYED") { OK "Tunnel service: delayed-auto-start" }
else { WARN "Tunnel service: not delayed-auto (may affect boot)"; $warnings++ }

$wmiK = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_FILTER }
if ($wmiK) { OK "WMI Subscription: ACTIVE" } else { WARN "WMI Subscription: missing"; $warnings++ }
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut: present" }  else { WARN "Startup shortcut: missing";  $warnings++ }
if (Test-Path $GPO_SCRIPT)  { OK "GPO script: present" }        else { WARN "GPO script: missing";        $warnings++ }

$reg = Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -EA SilentlyContinue
if ($reg.TaskXML) { OK "Registry backup: v$($reg.Version)" } else { WARN "Registry backup: missing"; $warnings++ }

$ipv6Rule = Get-NetFirewallRule -DisplayName "KS-Block-IPv6-Out" -EA SilentlyContinue
if ($ipv6Rule -and $ipv6Rule.Enabled -eq "True") { OK "IPv6 block: ACTIVE" } else { WARN "IPv6 block: inactive"; $warnings++ }

$dnsRule = Get-NetFirewallRule -DisplayName "KS-DNS-Block" -EA SilentlyContinue
if ($dnsRule) { OK "DNS leak protection: ACTIVE" } else { WARN "DNS leak protection: missing"; $warnings++ }

if (Test-Path $LOG) { attrib -H -S -R $LOG 2>$null | Out-Null }
OK "killswitch.log: accessible"

$defExcl = (Get-MpPreference -EA SilentlyContinue).ExclusionPath
if ($defExcl -contains $KLASOR) { OK "Defender exclusion: ACTIVE" } else { WARN "Defender exclusion: inactive" }

Log "install.ps1 completed"
Write-Host ""
if ($warnings -eq 0) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  INSTALL COMPLETE - SYSTEM FULLY PROTECTED                    " -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Green
} else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  INSTALL COMPLETE - $warnings WARNING(S) - see above          " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log file: C:\WireGuard\killswitch.log" -ForegroundColor Gray
Write-Host ""
Write-Host "  Protection layers active:" -ForegroundColor White
Write-Host "  [1] WireGuard tunnel: delayed-auto-start"           -ForegroundColor DarkGray
Write-Host "  [2] WGKillSwitchSvc (NSSM): delayed-auto-start"    -ForegroundColor DarkGray
Write-Host "  [3] WG-KillSwitch scheduled task: 60s boot delay"  -ForegroundColor DarkGray
Write-Host "  [4] WG-RepairTask: 30s boot delay + every 5min"    -ForegroundColor DarkGray
Write-Host "  [5] WMI Event Subscription: powershell death watch" -ForegroundColor DarkGray
Write-Host "  [6] Startup folder shortcut"                        -ForegroundColor DarkGray
Write-Host "  [7] GPO Machine Startup Script"                     -ForegroundColor DarkGray
Write-Host "  [8] HKLM Run key"                                   -ForegroundColor DarkGray
Write-Host ""
pause
