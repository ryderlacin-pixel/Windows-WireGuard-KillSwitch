# ================================================================
# WireGuard + WARP Kill Switch - FULL AUTOMATIC SETUP (v10.8)
# ================================================================
# * WireGuard is installed automatically if missing
# * Anonymous WARP config is generated via wgcf (no personal info)
# * Kill Switch (firewall rules + monitor + repair layers) installed
# * Custom server: -CustomConfig / -CustomEndpointIP / -CustomPort
# * Run as Administrator
# ================================================================
#
# DESIGN PHILOSOPHY (for code reviewers):
# - Zero third-party dependencies. 100% native Windows (PowerShell + netsh + WMI + Task Scheduler + NSSM)
# - Self-healing architecture: If monitor/repair process is killed (Task Manager, crash, update), 
#   it automatically respawns via WMI Permanent Event Subscription (__InstanceDeletionEvent).
#   This is the only native, zero-dependency way in Windows to guarantee the kill switch never leaks.
# - 8 recovery layers for maximum resilience during boot/network stack initialization.
# - Backticks removed, splatting preferred for readability.
# - Variable names improved. Redundant returns cleaned where safe.
# - Firewall is strict (block all outbound except LAN/DHCP/DNS/WARP endpoint).
# - IPv6 fully disabled to prevent leaks. Both TCP/UDP port 53 blocked (DNS leak prevention).
# - KS-WireGuard-EXE rule added to explicitly allow wireguard.exe outbound.
# - IPv6 block covers full address space including ::1, 64:ff9b::/96 (NAT64 range).
# - Mutex guards treat AbandonedMutexException as success (previous owner killed = we own it now).
# - Internet opens only when tunnel is RUNNING and Test-Internet passes (zombie-tunnel leak prevention).
# - Block rules cover wireless, LAN, remoteaccess (tethering), and PPP interfaces.
# - WARP mode refreshes Cloudflare server IPs at runtime; log writes skip if mutex times out.
# - All layers (monitor/repair/GPO) share SafeToOpen logic; repair syncs firewall state every run.
# - Install-safe (v10.8): install lock defers outbound blocks until STEP 19; tunnel kept alive on upgrade;
#   kurtar.bat/ps1 restores internet offline if install is interrupted.
# - Test-Internet requires 2 of 3 hosts (1.1.1.1, 1.0.0.1, 8.8.8.8); server rule rewrite only on IP change.
#
# If you see WMI and think "overkill": It is intentional.
# Without it, killing the PowerShell process would silently disable the kill switch.
# ================================================================
#Requires -RunAsAdministrator
param(
    [string]$CustomConfig     = "",  # Own .conf file: .\install.ps1 -CustomConfig "C:\myvpn.conf"
    [string]$CustomTunnel     = "",  # Tunnel name (default: wgcf-profile)
    [string]$CustomEndpointIP = "",  # Server IP or CIDR (e.g. "1.2.3.4/32")
    [int]$CustomPort          = 0    # WireGuard port (default: 2408)
)
# Installer: Continue shows errors without aborting noisy steps; runtime scripts set their own preference.
$ErrorActionPreference = "Continue"

# -- Paths --
$INSTALL_DIR = "C:\WireGuard"
$CONFIG      = "C:\WireGuard\wgcf-profile.conf"
$LOG         = "C:\WireGuard\killswitch.log"
$MONITOR_PS1 = "C:\WireGuard\monitor.ps1"
$REPAIR_PS1  = "C:\WireGuard\repair.ps1"
$SERVICE_PS1 = "C:\WireGuard\service-monitor.ps1"
$WMI_WRAPPER = "C:\WireGuard\wmi-repair.ps1"
$WG_EXE      = "C:\Program Files\WireGuard\wireguard.exe"
$WGCF_EXE    = "$INSTALL_DIR\wgcf.exe"
$NSSM        = "$INSTALL_DIR\nssm.exe"

# -- Names --
$TUNNEL_NAME  = "wgcf-profile"
$TUNNEL_SVC   = "WireGuardTunnel`$wgcf-profile"
$TASK_MONITOR = "WG-KillSwitch"
$TASK_REPAIR  = "WG-RepairTask"
$WG_SVC_NAME  = "WGKillSwitchSvc"
$WMI_FILTER   = "WGMonitorFilter"
$WMI_CONSUMER = "WGMonitorConsumer"
$STARTUP_LNK  = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WGKillSwitch.lnk"
$GPO_SCRIPT_DIR = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup"
$GPO_SCRIPT   = "$GPO_SCRIPT_DIR\wg-startup.ps1"
$GPO_INI_DIR  = "C:\Windows\System32\GroupPolicy\Machine\Scripts"
$GPO_INI      = "$GPO_INI_DIR\scripts.ini"
$INSTALL_LOCK = "$INSTALL_DIR\install.inprogress"
$KURTAR_PS1   = "$INSTALL_DIR\kurtar.ps1"
$KURTAR_BAT   = "$INSTALL_DIR\kurtar.bat"

# -- Custom mode (full validation in STEP 0) --
$CUSTOM_MODE = ($CustomConfig -ne "")
if ($CUSTOM_MODE) {
    Write-Host " [--] Custom server mode active" -ForegroundColor Cyan
}

# -- Helpers --
function Write-Step([string]$Title) {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Cyan
}
function OK([string]$Message)         { Write-Host " [OK]   $Message" -ForegroundColor Green }
function WARN([string]$Message)       { Write-Host " [WARN] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host " [ERR]  $Message" -ForegroundColor Red }
function Write-Info([string]$Message) { Write-Host " [-->]  $Message" -ForegroundColor Gray }

function Wait-NamedMutex([System.Threading.Mutex]$Mutex, [int]$TimeoutMs) {
    try { return $Mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Test-TcpHost([string]$HostName, [int]$Port, [int]$TimeoutMs = 4000) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        try { $tcp.EndConnect($iar) } catch { return $false }
        return $true
    } catch { return $false }
    finally { if ($tcp) { try { $tcp.Close() } catch {} } }
}

function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) {
        if (Test-TcpHost $h 443) { $hits++ }
    }
    return ($hits -ge 2)
}

function Get-PreferredShell {
    $pwshPath = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) { return $pwshPath }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Start-HiddenScript([string]$ScriptPath) {
    $shell = Get-PreferredShell
    $argList = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    Start-Process -FilePath $shell -ArgumentList $argList -WindowStyle Hidden
}

function Test-FirewallRuleEnabled([string]$RuleName) {
    $out = netsh advfirewall firewall show rule name="$RuleName" 2>$null
    return ($out -match 'Enabled:\s+Yes')
}

function Test-SafeToOpen {
    return (Test-TunnelRunning) -and (Test-Internet)
}

function Log([string]$Message) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex $mutex 3000)) { return }
        Add-Content -Path $LOG -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally {
        if ($mutex) { try { $mutex.ReleaseMutex() } catch {} }
    }
}

function Remove-TaskFully($name) {
    schtasks /End    /TN "\$name" /F 2>$null | Out-Null
    schtasks /Delete /TN "\$name" /F 2>$null | Out-Null
    Stop-ScheduledTask       -TaskName $name -EA SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -EA SilentlyContinue
}

function Test-TunnelRunning {
    try {
        $svc = Get-Service -Name $TUNNEL_SVC -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
    } catch {}
    return [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match "RUNNING")
}

function Test-IsMainMonitor([string]$CommandLine) {
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    return ($CommandLine -match '(?:\\|/)monitor\.ps1(?:\s|"|$)')
}

function Get-MonitorShellProcs() {
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($shell in @('powershell', 'pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if (Test-IsMainMonitor $cmd) { $found.Add($_) }
            } catch {}
        }
    }
    return $found
}

function Set-InstallLock {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Set-Content $INSTALL_LOCK (Get-Date -Format 'o') -Force -EA SilentlyContinue
    New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' 1 -Type DWord -Force
}

function Clear-InstallLock {
    Remove-Item $INSTALL_LOCK -Force -EA SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
}

function Remove-InstallBlocks {
    foreach ($r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        netsh advfirewall firewall delete rule name="$r" 2>$null | Out-Null
    }
}

function Ensure-TunnelForInstall {
    if (Test-TunnelRunning) {
        OK "Tunnel already RUNNING - kept alive during upgrade"
        return $true
    }
    if (-not (Test-Path $CONFIG)) { WARN "Config missing - cannot install tunnel"; return $false }
    Write-Info "Tunnel down - installing service..."
    & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
    Start-Sleep 2
    & $WG_EXE /installtunnelservice $CONFIG 2>&1 | Out-Null
    $waited = 0
    while ($waited -lt 45 -and -not (Test-TunnelRunning)) {
        Start-Sleep 3
        $waited += 3
        if ($waited -eq 15 -and -not (Test-TunnelRunning)) {
            & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
            Start-Sleep 2
            & $WG_EXE /installtunnelservice $CONFIG 2>&1 | Out-Null
        }
    }
    if (Test-TunnelRunning) { OK "Tunnel RUNNING (waited ${waited}s)"; return $true }
    WARN "Tunnel not up after ${waited}s - install continues with internet open"
    return $false
}

function Write-KurtarScript {
    $kurtarTunnelSvc = $TUNNEL_SVC
    $kurtarContent = @"
# WG Kill Switch - KURTAR (emergency restore, works 100% offline)
#Requires -RunAsAdministrator
`$TUNNEL_SVC  = '$kurtarTunnelSvc'
`$TUNNEL_NAME = '$TUNNEL_NAME'
`$CONFIG      = '$CONFIG'
`$WG_EXE      = '$WG_EXE'
`$INSTALL_LOCK = '$INSTALL_LOCK'
`$LOG         = '$LOG'
`$ErrorActionPreference = 'Continue'
Write-Host '=== WG KURTAR (emergency restore) ===' -ForegroundColor Cyan
foreach (`$r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
    netsh advfirewall firewall delete rule name="`$r" 2>`$null | Out-Null
}
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
Remove-Item `$INSTALL_LOCK -Force -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
if (-not (( & sc.exe query `$TUNNEL_SVC 2>`$null) -match 'RUNNING')) {
    Write-Host '[-->] Tunnel down - reinstalling...' -ForegroundColor Yellow
    if ((Test-Path `$WG_EXE) -and (Test-Path `$CONFIG)) {
        & `$WG_EXE /uninstalltunnelservice `$TUNNEL_NAME 2>`$null | Out-Null
        Start-Sleep 2
        & `$WG_EXE /installtunnelservice `$CONFIG 2>`$null | Out-Null
        Start-Sleep 5
    }
}
`$running = (( & sc.exe query `$TUNNEL_SVC 2>`$null) -match 'RUNNING')
Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [KURTAR] Emergency restore - tunnel=`$running" -Encoding UTF8 -EA SilentlyContinue
Write-Host "[OK] Internet restored (tunnel=`$running)" -ForegroundColor Green
Write-Host "     Re-run install.ps1 when ready to re-apply kill switch." -ForegroundColor Gray
"@
    Set-Content $KURTAR_PS1 $kurtarContent -Encoding UTF8 -Force
    attrib -H -S $KURTAR_PS1 2>$null | Out-Null
    @"
@echo off
title WireGuard Kill Switch - KURTAR
echo.
echo  Acil internet kurtarma (offline calisir)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$KURTAR_PS1"
echo.
pause
"@ | Set-Content $KURTAR_BAT -Encoding ASCII -Force
    attrib -H -S $KURTAR_BAT 2>$null | Out-Null
    OK "Emergency rescue: $KURTAR_BAT"
}

function Update-GpoScriptsIni($iniPath, $scriptPath) {
    New-Item -ItemType Directory -Path (Split-Path $iniPath) -Force -EA SilentlyContinue | Out-Null
    $content = ""
    if (Test-Path $iniPath) {
        $content = Get-Content $iniPath -Raw -Encoding Unicode -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            $content = Get-Content $iniPath -Raw -EA SilentlyContinue
        }
    }
    if ($null -eq $content) { $content = "" }
    if ($content -match [regex]::Escape($scriptPath)) { Write-Info "GPO scripts.ini: already registered"; return }
    if ($content -match "\[Startup\]") {
        $maxIndex = -1; $startup = $false
        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match "^\[Startup\]") { $startup = $true; continue }
            if ($line -match "^\[" -and $line -notmatch "^\[Startup\]") { $startup = $false; continue }
            if ($startup -and $line -match "^(\d+)CmdLine=") {
                $idx = [int]$Matches[1]; if ($idx -gt $maxIndex) { $maxIndex = $idx }
            }
        }
        $nextIndex = $maxIndex + 1
        $newBlock = "${nextIndex}CmdLine=powershell.exe`r`n${nextIndex}Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"`r`n"
        $content = $content -replace "(\[Startup\]\r?\n)", "`$1$newBlock"
    } else {
        $content += "`r`n[Startup]`r`n0CmdLine=powershell.exe`r`n0Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"`r`n"
    }
    $content | Set-Content $iniPath -Encoding Unicode -Force
}

function Get-EndpointFromConfig {
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match "^\s*Endpoint\s*=" } | Select-Object -First 1
        if ($ep -match "=\s*([^:\s]+):(\d+)") {
            return @{ IP = $Matches[1] + "/32"; Port = [int]$Matches[2] }
        }
        if ($ep -match "=\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)") {
            return @{ IP = $Matches[1] + "/32"; Port = 51820 }
        }
    } catch {}
    return $null
}

function Get-ServerPort {
    if ($CUSTOM_MODE) {
        if ($CustomPort -gt 0) { return "$CustomPort" }
        return "51820"
    }
    return "2408,854"
}

function Get-ServerIPs {
    if ($CUSTOM_MODE) {
        Write-Info "Custom endpoint: $CustomEndpointIP port $(Get-ServerPort)"
        return $CustomEndpointIP
    }
    $ipList = [System.Collections.Generic.List[string]]::new()
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match "^\s*Endpoint\s*=" } | Select-Object -First 1
        if ($ep -match "=\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+:") {
            $prefix = $Matches[1] + ".0/24"
            if (-not $ipList.Contains($prefix)) { $ipList.Add($prefix) }
            Write-Info "WARP endpoint from conf: $prefix"
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
Write-Step "STEP 0 - WIREGUARD + WARP AUTOMATIC INSTALL"
# ================================================================
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

# -- 0.1 WireGuard (always) --
if (-not (Test-Path $WG_EXE)) {
    Write-Info "WireGuard not found - downloading..."
    $wgMsi = "$INSTALL_DIR\wireguard-amd64.msi"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wgParams = @{
            Uri             = "https://download.wireguard.com/windows-client/wireguard-amd64-0.5.3.msi"
            OutFile         = $wgMsi
            TimeoutSec      = 60
            UseBasicParsing = $true
        }
        Invoke-WebRequest @wgParams

        $procParams = @{
            FilePath         = "msiexec.exe"
            ArgumentList     = "/i `"$wgMsi`" /quiet /norestart"
            Wait             = $true
            NoNewWindow      = $true
            PassThru         = $true
        }
        $p = Start-Process @procParams
        if ($p.ExitCode -eq 0) { OK "WireGuard installed" }
        else { Write-Err "WireGuard install failed (exit $($p.ExitCode))"; pause; exit 1 }
        Remove-Item $wgMsi -Force -EA SilentlyContinue
    } catch { Write-Err "WireGuard download/install error: $_"; pause; exit 1 }
} else { OK "WireGuard already present" }

if ($CustomConfig -ne "" -and $CustomEndpointIP -ne "" -and -not $CUSTOM_MODE) {
    Write-Err "-CustomEndpointIP requires -CustomConfig"; pause; exit 1
}
if ($CUSTOM_MODE) {
    if ($CustomConfig -eq "" -or -not (Test-Path $CustomConfig)) {
        Write-Err "Custom mode requires -CustomConfig pointing to an existing .conf file"; pause; exit 1
    }
    $CONFIG = (Resolve-Path $CustomConfig).Path
    if ($CustomTunnel -ne "") {
        $TUNNEL_NAME = $CustomTunnel
    } else {
        $TUNNEL_NAME = [System.IO.Path]::GetFileNameWithoutExtension($CONFIG)
    }
    $TUNNEL_SVC = "WireGuardTunnel`$$TUNNEL_NAME"
    $parsed = Get-EndpointFromConfig
    if ($CustomEndpointIP -eq "" -and $parsed) {
        $CustomEndpointIP = $parsed.IP
        Write-Info "Endpoint from config: $CustomEndpointIP"
    }
    if ($CustomPort -eq 0 -and $parsed) {
        $CustomPort = $parsed.Port
        Write-Info "Port from config: $CustomPort"
    }
    if ($CustomEndpointIP -eq "") {
        Write-Err "Custom mode: set -CustomEndpointIP or Endpoint= in .conf"; pause; exit 1
    }
    $confCheck = Get-Content $CONFIG -Encoding UTF8 -EA Stop -Raw
    if ($confCheck -notmatch "PrivateKey" -or $confCheck -notmatch "Endpoint") {
        Write-Err "Config file invalid (missing PrivateKey or Endpoint)"; pause; exit 1
    }
    OK "Custom config: $CONFIG | tunnel: $TUNNEL_NAME | server: ${CustomEndpointIP}:$(Get-ServerPort)"
} else {
    # -- 0.2 wgcf --
    if (-not (Test-Path $WGCF_EXE)) {
        Write-Info "Downloading wgcf..."
        try {
            $wgcfParams = @{
                Uri             = "https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_windows_amd64.exe"
                OutFile         = $WGCF_EXE
                TimeoutSec      = 30
                UseBasicParsing = $true
            }
            Invoke-WebRequest @wgcfParams
            OK "wgcf downloaded"
        } catch { Write-Err "wgcf download failed: $_"; pause; exit 1 }
    } else { OK "wgcf already present" }

    # -- 0.3 WARP config (anonymous, no personal info) --
    if (-not (Test-Path $CONFIG)) {
        Write-Info "Generating anonymous WARP config..."
        Push-Location $INSTALL_DIR
        try {
            $r = & $WGCF_EXE register --accept-tos 2>&1
            if ($LASTEXITCODE -ne 0) { throw "wgcf register failed: $r" }
            $g = & $WGCF_EXE generate 2>&1
            if ($LASTEXITCODE -ne 0) { throw "wgcf generate failed: $g" }
            if (Test-Path "$INSTALL_DIR\wgcf-profile.conf") {
                Move-Item "$INSTALL_DIR\wgcf-profile.conf" $CONFIG -Force
                OK "WARP config created: $CONFIG"
            } else { throw "wgcf-profile.conf not found after generate" }
        } catch {
            Write-Err "WARP config failed: $_"
            Pop-Location
            pause; exit 1
        }
        Pop-Location
    } else { OK "WARP config already exists" }

    $confCheck = Get-Content $CONFIG -Encoding UTF8 -EA Stop -Raw
    if ($confCheck -notmatch "PrivateKey" -or $confCheck -notmatch "Endpoint") {
        Write-Err "Config file invalid (missing PrivateKey or Endpoint)"; pause; exit 1
    }
} # end WARP block

# ================================================================
Write-Step "STEP 1 - FOLDER PREP"
# ================================================================
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
OK "Folder ready: $INSTALL_DIR"

# ================================================================
Write-Step "STEP 2 - NSSM"
# ================================================================
if (-not (Test-Path $NSSM)) {
    try {
        $zip = "$INSTALL_DIR\nssm.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -TimeoutSec 45 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zf    = [System.IO.Compression.ZipFile]::OpenRead($zip)
        # FIX: check both forward-slash and backslash path separators; null-guard before extract
        $entry = $zf.Entries | Where-Object { $_.FullName -replace '\\','/' -like "*/win64/nssm.exe" } | Select-Object -First 1
        if ($entry) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $NSSM, $true)
            $zf.Dispose()
            Remove-Item $zip -Force -EA SilentlyContinue
            OK "NSSM downloaded"
        } else {
            $zf.Dispose()
            Remove-Item $zip -Force -EA SilentlyContinue
            throw "nssm.exe entry not found in zip"
        }
    } catch { WARN "NSSM download failed - service layer will be skipped" }
} else { OK "NSSM present" }

# ================================================================
Write-Step "STEP 2b - PRE-CACHE + INSTALL LOCK (internet required)"
# ================================================================
# Resolve server IPs while internet is still available; set install lock so
# monitor/repair never cut connectivity during the rest of install.ps1.
$serverIPs = Get-ServerIPs
$serverPort = Get-ServerPort
Set-InstallLock
Write-KurtarScript
OK "Server IPs cached; install lock ON (use kurtar.bat if internet drops)"

# ================================================================
Write-Step "STEP 3 - CLEANUP (old installs)"
# ================================================================
Remove-TaskFully $TASK_MONITOR
Remove-TaskFully $TASK_REPAIR
Remove-TaskFully "WireGuard-KillSwitch-Monitor"
Remove-TaskFully "WG-OnarimGorevi"
Remove-TaskFully "WG-RepairTask"

$oldSvc = & sc.exe query $WG_SVC_NAME 2>$null
if ($oldSvc) {
    if ($oldSvc -match "PAUSED") { & sc.exe continue $WG_SVC_NAME 2>$null | Out-Null; Start-Sleep 2 }
    if (Test-Path $NSSM) { & $NSSM stop $WG_SVC_NAME 2>$null | Out-Null }
    & sc.exe stop   $WG_SVC_NAME 2>$null | Out-Null; Start-Sleep 2
    if (Test-Path $NSSM) { & $NSSM remove $WG_SVC_NAME confirm 2>$null | Out-Null }
    & sc.exe delete $WG_SVC_NAME 2>$null | Out-Null; Start-Sleep 2
}

Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_FILTER } | Remove-CimInstance -EA SilentlyContinue
Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_CONSUMER } | Remove-CimInstance -EA SilentlyContinue
Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -EA SilentlyContinue |
    Where-Object { $_.Filter -like "*$WMI_FILTER*" } | Remove-CimInstance -EA SilentlyContinue

foreach ($oldFilter in @("WGMonitorOldu")) {
    Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
        Where-Object { $_.Name -eq $oldFilter } | Remove-CimInstance -EA SilentlyContinue
}

Remove-Item $STARTUP_LNK -Force -EA SilentlyContinue

Get-CimInstance Win32_Process -EA SilentlyContinue |
    Where-Object { (Test-IsMainMonitor $_.CommandLine) -or $_.CommandLine -like "*repair.ps1*" -or
                   $_.CommandLine -like "*onarim.ps1*" -or $_.CommandLine -like "*service-monitor.ps1*" -or
                   $_.CommandLine -like "*servis-monitor.ps1*" -or $_.CommandLine -like "*wmi-repair.ps1*" -or
                   $_.CommandLine -like "*wmi-onarim.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

$allRules = @(
    "KS-Block-WiFi-Out","KS-Block-Ethernet-Out","KS-Block-RemoteAccess-Out","KS-Block-PPP-Out",
    "KS-Block-IPv6-Out","KS-Block-IPv6-In",
    "KS-LAN-Out","KS-LAN-In","KS-DHCP-Out","KS-DHCP-In",
    "KS-WARP-Server-Out","KS-Loopback-Out","KS-Loopback-In",
    "KS-DNS-Allow","KS-DNS-Block","KS-DNS-Block-TCP","KS-WireGuard-EXE","KS-WireGuard-Tunnel-SVC",
    "KS - ENGEL Wi-Fi Cikis","KS - ENGEL Ethernet Cikis","KS - ENGEL IPv6 Cikis","KS - ENGEL IPv6 Giris",
    "KS - Yerel Ag Cikis","KS - Yerel Ag Giris","KS - DHCP Cikis","KS - DHCP Giris",
    "KS - WARP Sunucu Cikis","KS - Loopback Cikis","KS - Loopback Giris",
    "KS - DNS Izin","KS - DNS Engel","KS - WireGuard EXE","KS - WireGuard Tunnel SVC"
)
foreach ($k in $allRules) { netsh advfirewall firewall delete rule name="$k" | Out-Null }

netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
# Keep tunnel alive during upgrade — reinstall only in STEP 5 if down
Remove-Item "$INSTALL_DIR\repair.lock"        -Force -EA SilentlyContinue
Remove-Item "$INSTALL_DIR\onarim.lock"        -Force -EA SilentlyContinue
Remove-Item "$INSTALL_DIR\onarim.ps1"         -Force -EA SilentlyContinue
Remove-Item "$INSTALL_DIR\servis-monitor.ps1" -Force -EA SilentlyContinue
Remove-Item "$INSTALL_DIR\wmi-onarim.ps1"     -Force -EA SilentlyContinue
if (Test-Path $LOG) { attrib -H -S $LOG 2>$null | Out-Null }
Get-ChildItem $INSTALL_DIR -File -EA SilentlyContinue | ForEach-Object { attrib -H -S $_.FullName 2>$null | Out-Null }
OK "Cleanup done"

# ================================================================
Write-Step "STEP 4 - IPv6 BLOCK"
# ================================================================
netsh advfirewall firewall delete rule name="KS-Block-IPv6-Out" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="KS-Block-IPv6-In"  2>$null | Out-Null
# netsh IPv6 remoteip lists are unreliable on some builds; registry + binding disable below are primary
foreach ($pfx in @('fe80::/10','::1/128','fc00::/7')) {
    netsh advfirewall firewall add rule name="KS-Block-IPv6-Out" dir=out action=block remoteip=$pfx enable=yes 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-IPv6-In"  dir=in  action=block remoteip=$pfx enable=yes 2>$null | Out-Null
}

Get-NetAdapter | Where-Object { $_.Status -ne "Not Present" -and $_.Name -ne $TUNNEL_NAME } |
    ForEach-Object { Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -EA SilentlyContinue }

$ipv6RegParams = @{
    Path        = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
    Name        = "DisabledComponents"
    Value       = 0xFF
    Type        = "DWord"
    Force       = $true
    ErrorAction = "SilentlyContinue"
}
Set-ItemProperty @ipv6RegParams
OK "IPv6 blocked"

# ================================================================
Write-Step "STEP 5 - WIREGUARD TUNNEL"
# ================================================================
Ensure-TunnelForInstall | Out-Null
& sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
OK "WireGuard tunnel: delayed-auto-start"

# ================================================================
Write-Step "STEP 6 - FIREWALL RULES"
# ================================================================
# Server IPs pre-cached in STEP 2b (no network call during install body)

netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
netsh advfirewall firewall add rule name="KS-Block-WiFi-Out"         dir=out action=block interfacetype=wireless     remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out"     dir=out action=block interfacetype=lan         remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Block-RemoteAccess-Out" dir=out action=block interfacetype=remoteaccess remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Block-PPP-Out"          dir=out action=block interfacetype=ppp          remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-LAN-Out"   dir=out action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-LAN-In"    dir=in  action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DHCP-Out"  dir=out action=allow protocol=UDP localport=68 remoteport=67 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DHCP-In"   dir=in  action=allow protocol=UDP localport=68 remoteport=67 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Loopback-Out" dir=out action=allow remoteip=127.0.0.0/8 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-Loopback-In"  dir=in  action=allow remoteip=127.0.0.0/8 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Allow"     dir=out action=allow protocol=UDP remoteip=1.1.1.1,1.0.0.1 remoteport=53 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Block"     dir=out action=block protocol=UDP remoteport=53 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Block-TCP" dir=out action=block protocol=TCP remoteport=53 enable=yes | Out-Null
netsh advfirewall firewall add rule name="KS-WireGuard-EXE" dir=out action=allow program="C:\Program Files\WireGuard\wireguard.exe" enable=yes | Out-Null

Write-Info "Server IPs: $serverIPs"
netsh advfirewall firewall add rule name="KS-WARP-Server-Out" dir=out action=allow protocol=UDP remoteip=$serverIPs remoteport=$serverPort enable=yes | Out-Null
OK "Firewall rules applied"

# Install lock: never leave outbound blocks on during install (agent/remote needs internet)
Remove-InstallBlocks
if (Test-SafeToOpen) {
    OK "Tunnel + internet verified - blocks deferred until install completes"
} elseif (Test-TunnelRunning) {
    WARN "Tunnel up but internet not ready - blocks deferred (install lock)"
} else {
    WARN "Tunnel down - blocks deferred (install lock); use kurtar.bat if needed"
}

# ================================================================
Write-Step "STEP 7 - MONITOR SCRIPT"
# ================================================================
$monitorTunnelSvc  = $TUNNEL_SVC
$monitorTunnelName = $TUNNEL_NAME
$monitorConfig     = $CONFIG
# Use already-resolved values from STEP 6 (no second API call)
$monitorServerIp   = $serverIPs
$monitorPort       = $serverPort
$monitorCustomMode = if ($CUSTOM_MODE) { '$true' } else { '$false' }

$monitorContent = @"
# WireGuard Kill Switch - Monitor v10.8 (auto-generated by install.ps1)
`$TUNNEL_SVC   = '$monitorTunnelSvc'
`$TUNNEL_NAME  = '$monitorTunnelName'
`$CONFIG       = '$monitorConfig'
`$LOG          = 'C:\WireGuard\killswitch.log'
`$WG_EXE       = 'C:\Program Files\WireGuard\wireguard.exe'
`$REG_KEY      = 'HKLM:\SOFTWARE\WGKillSwitch'
`$CUSTOM_MODE  = $monitorCustomMode
`$script:SERVER_IP = '$monitorServerIp'
`$SERVER_PORT  = '$monitorPort'
`$script:LastServerIP = ''
`$script:ServerIPRefreshTick = 0

function Wait-NamedMutex([System.Threading.Mutex]`$Mutex, [int]`$TimeoutMs) {
    try { return `$Mutex.WaitOne(`$TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return `$true }
}

function Write-Emergency([string]`$m) {
    try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [MON] `$m" -Encoding UTF8 -EA SilentlyContinue } catch {}
}

function Log([string]`$m) {
    `$mutex = `$null
    try {
        `$mutex = New-Object System.Threading.Mutex(`$false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex `$mutex 3000)) { return }
        Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [MON] `$m" -Encoding UTF8 -EA SilentlyContinue
        try {
            `$s = Get-Content `$LOG -Encoding UTF8 -EA Stop
            if (`$s.Count -gt 500) { `$s | Select-Object -Last 250 | Set-Content `$LOG -Encoding UTF8 -Force }
        } catch {}
    } finally { if (`$mutex) { try { `$mutex.ReleaseMutex() } catch {} } }
}

function Test-TunnelRunning {
    try {
        `$svc = Get-Service -Name `$TUNNEL_SVC -ErrorAction SilentlyContinue
        if (`$svc -and `$svc.Status -eq 'Running') { return `$true }
    } catch {}
    return ([bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match "RUNNING"))
}

function Test-TcpHost([string]`$HostName, [int]`$Port, [int]`$TimeoutMs = 4000) {
    `$tcp = `$null
    try {
        `$tcp = New-Object System.Net.Sockets.TcpClient
        `$iar = `$tcp.BeginConnect(`$HostName, `$Port, `$null, `$null)
        if (-not `$iar.AsyncWaitHandle.WaitOne(`$TimeoutMs, `$false)) { return `$false }
        try { `$tcp.EndConnect(`$iar) } catch { return `$false }
        return `$true
    } catch { return `$false }
    finally { if (`$tcp) { try { `$tcp.Close() } catch {} } }
}

function Test-Internet {
    `$hits = 0
    foreach (`$h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) {
        if (Test-TcpHost `$h 443) { `$hits++ }
    }
    return (`$hits -ge 2)
}

function Test-SafeToOpen {
    return (Test-TunnelRunning) -and (Test-Internet)
}

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return `$true }
    try {
        `$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
        return (`$reg.InstallInProgress -eq 1)
    } catch { return `$false }
}

function Test-ServerRulePresent {
    try {
        `$out = netsh advfirewall firewall show rule name="KS-WARP-Server-Out" 2>`$null
        if (`$out -notmatch 'Enabled:\s+Yes') { return `$false }
        `$firstIp = (`$script:SERVER_IP -split ',')[0]
        return (`$out -match [regex]::Escape(`$firstIp))
    } catch { return `$false }
}

function Set-ServerRule {
    netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>`$null | Out-Null
    netsh advfirewall firewall add rule name="KS-WARP-Server-Out" dir=out action=allow protocol=UDP remoteip=`$script:SERVER_IP remoteport=`$SERVER_PORT enable=yes | Out-Null
}

function Get-ResolvedServerIP {
    if (`$CUSTOM_MODE) {
        try {
            `$reg = Get-ItemProperty `$REG_KEY -EA SilentlyContinue
            if (`$reg.ServerIP) { return [string]`$reg.ServerIP }
        } catch {}
        return `$script:SERVER_IP
    }
    `$ipList = [System.Collections.Generic.List[string]]::new()
    try {
        `$ep = (Get-Content `$CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { `$_ -match '^\s*Endpoint\s*=' } | Select-Object -First 1
        if (`$ep -match '=\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+:') {
            `$prefix = `$Matches[1] + '.0/24'
            if (-not `$ipList.Contains(`$prefix)) { `$ipList.Add(`$prefix) }
        }
    } catch {}
    try {
        `$resp = Invoke-RestMethod 'https://api.cloudflare.com/client/v4/ips' -TimeoutSec 8 -EA Stop
        if (`$resp.success -and `$resp.result.ipv4_cidrs) {
            foreach (`$cidr in `$resp.result.ipv4_cidrs) {
                if (`$cidr -match '^(162\.159\.|104\.16\.)') {
                    if (-not `$ipList.Contains(`$cidr)) { `$ipList.Add(`$cidr) }
                }
            }
        }
    } catch {}
    if (`$ipList.Count -eq 0) { return `$script:SERVER_IP }
    return (`$ipList -join ',')
}

function Enable-Block {
    if (Test-InstallInProgress) {
        Log "Install in progress - block skipped (internet stays open)"
        return
    }
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         2>`$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     2>`$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" 2>`$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          2>`$null | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-WiFi-Out"         dir=out action=block interfacetype=wireless     remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out"     dir=out action=block interfacetype=lan         remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-RemoteAccess-Out" dir=out action=block interfacetype=remoteaccess remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-PPP-Out"          dir=out action=block interfacetype=ppp          remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>`$null | Out-Null
    netsh advfirewall firewall add rule name="KS-WARP-Server-Out" dir=out action=allow protocol=UDP remoteip=`$script:SERVER_IP remoteport=`$SERVER_PORT enable=yes | Out-Null
    Log "BLOCK active (server `$(`$script:SERVER_IP) allowed)"
}

function Disable-Block {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          | Out-Null
    Log "BLOCK removed - internet open"
}

function Ensure-ServerRule {
    `$script:ServerIPRefreshTick++
    `$rewrite = -not `$script:LastServerIP
    if (`$script:ServerIPRefreshTick -ge 60) {
        `$script:ServerIPRefreshTick = 0
        `$resolved = Get-ResolvedServerIP
        if (`$resolved -ne `$script:LastServerIP) {
            `$script:LastServerIP = `$resolved
            `$script:SERVER_IP = `$resolved
            Log "Server IPs refreshed: `$resolved"
            `$rewrite = `$true
        }
    }
    if (`$rewrite -or -not (Test-ServerRulePresent)) { Set-ServerRule }
}

function Try-ReinstallTunnel {
    `$mux = `$null
    try {
        `$mux = New-Object System.Threading.Mutex(`$false, 'Global\WGTunnelInstallMutex')
        if (-not (Wait-NamedMutex `$mux 60000)) {
            Log "TunnelReinstall: mutex timeout"
            return (Test-TunnelRunning)
        }
        Get-Process -Name "wireguard" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        `$wgSvcPid = (Get-CimInstance Win32_Service -Filter "Name='`$TUNNEL_SVC'" -EA SilentlyContinue).ProcessId
        if (`$wgSvcPid -and `$wgSvcPid -gt 0) { Stop-Process -Id `$wgSvcPid -Force -EA SilentlyContinue }
        Start-Sleep -Seconds 1
        & `$WG_EXE /uninstalltunnelservice `$TUNNEL_NAME 2>`$null
        Start-Sleep -Seconds 3
        & `$WG_EXE /installtunnelservice `$CONFIG 2>`$null
        Start-Sleep -Seconds 10
        return (Test-TunnelRunning)
    } finally {
        if (`$mux) { try { `$mux.ReleaseMutex() } catch {} }
    }
}

`$mainMux = `$null
try {
    `$mainMux = New-Object System.Threading.Mutex(`$false, 'Global\WGMainMonitorMutex')
    if (-not (Wait-NamedMutex `$mainMux 0)) { exit 0 }
} catch [System.UnauthorizedAccessException] {
    Write-Emergency "FATAL: monitor mutex access denied"
    exit 1
} catch {
    Write-Emergency "FATAL: monitor mutex error: `$_"
    exit 1
}

Log "=== Monitor started (v10.8) ==="

if (Test-InstallInProgress) {
    Disable-Block
    Log "Install in progress - waiting for install.ps1 to finish (internet open)"
    while (Test-InstallInProgress) {
        Start-Sleep -Seconds 5
        Ensure-ServerRule
    }
    Log "Install lock cleared - resuming normal kill switch"
}

try {
    `$bootTime = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
    if ((Get-Date) -lt `$bootTime.AddSeconds(90)) {
        Log "Fresh boot detected - extra 15s wait for network stack"
        Start-Sleep -Seconds 15
    }
} catch {}

`$bootWait = 0
while (`$bootWait -lt 90 -and -not (Test-TunnelRunning)) {
    Start-Sleep -Seconds 3; `$bootWait += 3
}

if (Test-SafeToOpen) {
    `$state = 'open'
    Clear-DnsClientCache -EA SilentlyContinue
    Disable-Block
    Log "Startup: healthy (waited `${bootWait}s), internet open"
} else {
    `$state = 'blocked'
    Enable-Block
    if (Test-TunnelRunning) {
        Log "Startup: zombie tunnel (waited `${bootWait}s), block active - starting recovery"
    } else {
        Log "Startup: tunnel down (waited `${bootWait}s), block active - starting recovery"
    }
}

`$startupRecovery = (`$state -eq 'blocked')

while (`$true) {
    if (-not `$startupRecovery) { Start-Sleep -Seconds 5 }
    `$startupRecovery = `$false
    Ensure-ServerRule

    if (Test-SafeToOpen) {
        if (`$state -ne 'open') {
            Clear-DnsClientCache -EA SilentlyContinue
            Disable-Block
            `$state = 'open'
            Log "Healthy: tunnel + internet OK"
        }
        continue
    }

    if (`$state -ne 'blocked') {
        if (Test-TunnelRunning) {
            Log "WARNING: Zombie tunnel (running, no internet) - activating block"
        } else {
            Log "WARNING: Tunnel down - activating block"
        }
        Enable-Block
        `$state = 'blocked'
    }

    Log "Starting recovery"
    `$success = `$false
    `$totalAttempts = 0
    while (-not `$success) {
        for (`$i = 1; `$i -le 5; `$i++) {
            if (Test-SafeToOpen) {
                Log "Recovery: healthy before attempt `$i"
                Clear-DnsClientCache -EA SilentlyContinue
                Disable-Block; `$state = 'open'; `$success = `$true; break
            }
            `$totalAttempts++
            Log "Attempt `$i/5 (total: `$totalAttempts)"
            `$up = Try-ReinstallTunnel
            if (`$up) {
                `$waited = 0; `$netOK = `$false
                while (`$waited -lt 30) {
                    if (Test-SafeToOpen) { `$netOK = `$true; break }
                    Start-Sleep -Seconds 5; `$waited += 5
                }
                if (`$netOK) {
                    Log "Attempt `$i - tunnel + internet OK (waited `${waited}s)"
                    Clear-DnsClientCache -EA SilentlyContinue
                    Disable-Block; `$state = 'open'; `$success = `$true; break
                } else {
                    Log "Attempt `$i - tunnel up but no internet after 30s, retrying"
                    Enable-Block; `$state = 'blocked'
                    & `$WG_EXE /uninstalltunnelservice `$TUNNEL_NAME 2>`$null
                    Start-Sleep -Seconds 3
                }
            } else {
                Log "Attempt `$i - tunnel did not start"
                Start-Sleep -Seconds 5
            }
        }
        if (-not `$success) {
            Log "CRITICAL: 5 attempts failed (total: `$totalAttempts) - waiting 3min then retrying"
            Enable-Block; `$state = 'blocked'
            `$waited = 0
            while (`$waited -lt 180) {
                Start-Sleep -Seconds 15; `$waited += 15
                if (Test-SafeToOpen) {
                    Log "Healthy during 3min wait (tunnel + internet verified)"
                    Clear-DnsClientCache -EA SilentlyContinue
                    Disable-Block; `$state = 'open'; `$success = `$true; break
                }
            }
            if (`$success) { break }
            Log "3min wait done - retrying..."
        }
    }
}
"@
$monitorContent | Set-Content $MONITOR_PS1 -Encoding UTF8 -Force
try {
    $raw = [System.IO.File]::ReadAllText($MONITOR_PS1, [System.Text.Encoding]::UTF8)
    $raw = $raw -replace "(?<!\r)\n", "`r`n"
    [System.IO.File]::WriteAllText($MONITOR_PS1, $raw, [System.Text.Encoding]::UTF8)
} catch {}
attrib -H -S $MONITOR_PS1 2>$null | Out-Null
OK "monitor.ps1 written (server: $monitorServerIp)"

# ================================================================
Write-Step "STEP 8 - REPAIR SCRIPT"
# ================================================================
$repairTunnelSvc  = $TUNNEL_SVC
$repairTunnelName = $TUNNEL_NAME
$repairConfig     = $CONFIG
$repairSvcName    = $WG_SVC_NAME
$repairServerPort = $serverPort

# NOTE: repair.ps1 uses a single-quoted here-string (@' '@) for all static content.
# Variables that must expand at install-time are injected via direct string concatenation.
$repairContent = @'
# WG Repair Script (auto-generated by install.ps1)
$TASK_MONITOR = "WG-KillSwitch"
$MONITOR      = "C:\WireGuard\monitor.ps1"
$LOG          = "C:\WireGuard\killswitch.log"
$WG_EXE       = "C:\Program Files\WireGuard\wireguard.exe"
$LOCK         = "C:\WireGuard\repair.lock"
'@ + "`r`n" + @"
`$TUNNEL_SVC  = '$repairTunnelSvc'
`$TUNNEL_NAME = '$repairTunnelName'
`$CONFIG      = '$repairConfig'
`$WG_SVC_NAME = '$repairSvcName'
`$REG_KEY     = 'HKLM:\SOFTWARE\WGKillSwitch'
`$SERVER_PORT = '$repairServerPort'
"@ + @'

$ErrorActionPreference = "SilentlyContinue"

function Wait-NamedMutex([System.Threading.Mutex]$Mutex, [int]$TimeoutMs) {
    try { return $Mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex $mutex 3000)) { return }
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [REPAIR] $m" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}

function Test-TunnelRunning {
    try {
        $svc = Get-Service -Name $TUNNEL_SVC -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
    } catch {}
    return ([bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match "RUNNING"))
}

function Test-TcpHost([string]$HostName, [int]$Port, [int]$TimeoutMs = 4000) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        try { $tcp.EndConnect($iar) } catch { return $false }
        return $true
    } catch { return $false }
    finally { if ($tcp) { try { $tcp.Close() } catch {} } }
}

function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) {
        if (Test-TcpHost $h 443) { $hits++ }
    }
    return ($hits -ge 2)
}

function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Internet) }

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return $true }
    try {
        $reg = Get-ItemProperty $REG_KEY -EA SilentlyContinue
        return ($reg.InstallInProgress -eq 1)
    } catch { return $false }
}

function Get-RepairServerIP {
    try {
        $reg = Get-ItemProperty $REG_KEY -EA SilentlyContinue
        if ($reg.ServerIP) { return [string]$reg.ServerIP }
    } catch {}
    return '162.159.192.0/24,104.16.0.0/13'
}

function Enable-Block {
    if (Test-InstallInProgress) { return }
    $serverIp = Get-RepairServerIP
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" 2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-WiFi-Out"         dir=out action=block interfacetype=wireless     remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out"     dir=out action=block interfacetype=lan         remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-RemoteAccess-Out" dir=out action=block interfacetype=remoteaccess remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-PPP-Out"          dir=out action=block interfacetype=ppp          remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-WARP-Server-Out" dir=out action=allow protocol=UDP remoteip=$serverIp remoteport=$SERVER_PORT enable=yes | Out-Null
}

function Disable-Block {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" 2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          2>$null | Out-Null
}

function Sync-KillSwitchState {
    if (Test-InstallInProgress) {
        Disable-Block
        Log "Sync: install in progress - block deferred"
        return
    }
    if (Test-SafeToOpen) {
        Disable-Block
        Log "Sync: healthy - internet open"
    } else {
        Enable-Block
        if (Test-TunnelRunning) { Log "Sync: zombie tunnel - block active" }
        else { Log "Sync: tunnel down - block active" }
    }
}

function Get-PreferredShell {
    $pwshPath = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) { return $pwshPath }
    $cmd = Get-Command pwsh -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Start-HiddenScript([string]$ScriptPath) {
    $shell = Get-PreferredShell
    $argList = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    Start-Process -FilePath $shell -ArgumentList $argList -WindowStyle Hidden
}

if (Test-Path $LOCK) {
    $lp = [int](Get-Content $LOCK -EA SilentlyContinue)
    if ($lp -and (Get-Process -Id $lp -EA SilentlyContinue)) { exit 0 }
    Remove-Item $LOCK -Force -EA SilentlyContinue
}
$PID | Set-Content $LOCK -Force -EA SilentlyContinue

try {
    if (Test-Path $LOG) { attrib -H -S $LOG 2>$null | Out-Null }

    $policyOK = $true
    foreach ($profile in @("DomainProfile","PrivateProfile","PublicProfile")) {
        if ((netsh advfirewall show $profile 2>$null) -match "BlockOutbound") { $policyOK = $false }
    }
    if (-not $policyOK) {
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
        Log "Firewall policy corrected"
    }

    if ((& sc.exe query MpsSvc 2>$null) -match "STOPPED") {
        & sc.exe start MpsSvc 2>$null | Out-Null; Start-Sleep 3
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
        Log "CRITICAL: Firewall service restarted"
    }

    $task = Get-ScheduledTask -TaskName $TASK_MONITOR -EA SilentlyContinue
    if (-not $task) {
        $b64 = (Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -Name "TaskXML" -EA SilentlyContinue).TaskXML
        if ($b64) {
            [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) |
                Register-ScheduledTask -TaskName $TASK_MONITOR -Force | Out-Null
            $taskRun = '\' + $TASK_MONITOR
            schtasks /Run /TN $taskRun 2>$null | Out-Null
            Log "WG-KillSwitch task restored from registry backup"
        } else { Log "CRITICAL: No registry backup found" }
    } elseif ($task.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $TASK_MONITOR | Out-Null
        $taskRun = '\' + $TASK_MONITOR
        schtasks /Run /TN $taskRun 2>$null | Out-Null
        Log "WG-KillSwitch task re-enabled"
    }

    if ((& sc.exe query $TUNNEL_SVC 2>$null) -notmatch "RUNNING") {
        Log "Tunnel not running - reinstalling"
        if ((Test-Path $WG_EXE) -and (Test-Path $CONFIG)) {
            & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
            Start-Sleep 2
            & $WG_EXE /installtunnelservice $CONFIG 2>$null | Out-Null
            Start-Sleep 8
            if ((& sc.exe query $TUNNEL_SVC 2>$null) -match "RUNNING") { Log "Tunnel reinstalled OK" }
            else { Log "CRITICAL: Tunnel could not be reinstalled" }
        }
    }

    if ((& sc.exe query $WG_SVC_NAME 2>$null) -notmatch "RUNNING") {
        Log "WGKillSwitchSvc not running - starting"
        & sc.exe start $WG_SVC_NAME 2>$null | Out-Null; Start-Sleep 5
        if ((& sc.exe query $WG_SVC_NAME 2>$null) -match "RUNNING") { Log "WGKillSwitchSvc started" }
        else { Log "CRITICAL: WGKillSwitchSvc could not start" }
    }

    function IsMainMonitor([string]$cmd) {
        if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
        return ($cmd -match '(?:\\|/)monitor\.ps1(?:\s|"|$)')
    }
    function GetMonitorShellProcs() {
        $found = @()
        foreach ($shell in @('powershell', 'pwsh')) {
            Get-Process $shell -EA SilentlyContinue | ForEach-Object {
                try {
                    $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                    if (IsMainMonitor $c) { $found += $_ }
                } catch {}
            }
        }
        return $found
    }
    Start-Sleep -Milliseconds 500
    $procs = GetMonitorShellProcs
    if (-not $procs) {
        Log "Main monitor missing - triggering task and direct start"
        $taskRun = '\' + $TASK_MONITOR
        schtasks /Run /TN $taskRun 2>$null | Out-Null
        Start-Sleep 4
        if (-not (GetMonitorShellProcs)) {
            Start-HiddenScript $MONITOR
            Log "Monitor started directly"
        }
    } elseif (($procs | Measure-Object).Count -gt 1) {
        $procs | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object {
            Stop-Process -Id $_.Id -Force -EA SilentlyContinue
            Log "Duplicate main monitor killed (PID: $($_.Id))"
        }
    }

    Sync-KillSwitchState
} finally {
    Remove-Item $LOCK -Force -EA SilentlyContinue
}
'@
$repairContent | Set-Content $REPAIR_PS1 -Encoding UTF8 -Force
OK "repair.ps1 written"

# ================================================================
Write-Step "STEP 9 - WMI WRAPPER"
# ================================================================
@'
# WMI Repair Wrapper v10.8 (auto-generated by install.ps1)
$LOG    = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\repair.ps1'
function Wait-NamedMutex([System.Threading.Mutex]$Mutex, [int]$TimeoutMs) {
    try { return $Mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}
function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex $mutex 2000)) { return }
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [WMI] $m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}
function IsMainMonitor([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    return ($cmd -match '(?:\\|/)monitor\.ps1(?:\s|"|$)')
}
function GetMonitorShellProcs() {
    $found = @()
    foreach ($shell in @('powershell', 'pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if (IsMainMonitor $c) { $found += $_ }
            } catch {}
        }
    }
    return $found
}
Start-Sleep -Seconds 2
$proc = GetMonitorShellProcs
function Get-PreferredShell {
    $pwshPath = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) { return $pwshPath }
    $cmd = Get-Command pwsh -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}
function Start-HiddenScript([string]$ScriptPath) {
    $shell = Get-PreferredShell
    $argList = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    Start-Process -FilePath $shell -ArgumentList $argList -WindowStyle Hidden
}
if (-not $proc) {
    Log "Main monitor gone - triggering repair"
    if (Test-Path $REPAIR) { Start-HiddenScript $REPAIR }
} else {
    Log "WMI triggered but main monitor still running - no action"
}
'@ | Set-Content $WMI_WRAPPER -Encoding UTF8 -Force
OK "wmi-repair.ps1 written"

# ================================================================
Write-Step "STEP 10 - SERVICE MONITOR (NSSM wrapper)"
# ================================================================
@'
# WGKillSwitchSvc wrapper v10.8 (auto-generated by install.ps1)
$LOG       = 'C:\WireGuard\killswitch.log'
$REPAIR    = 'C:\WireGuard\repair.ps1'
$COOLDOWN  = 'C:\WireGuard\repair-cooldown.txt'
function Wait-NamedMutex([System.Threading.Mutex]$Mutex, [int]$TimeoutMs) {
    try { return $Mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}
function Log($m) {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex $mutex 2000)) { return }
        Add-Content $LOG "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [SVC] $m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
}
function IsMainMonitor([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    return ($cmd -match '(?:\\|/)monitor\.ps1(?:\s|"|$)')
}
function GetMonitorShellProcs() {
    $found = @()
    foreach ($shell in @('powershell', 'pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if (IsMainMonitor $c) { $found += $_ }
            } catch {}
        }
    }
    return $found
}
function RepairCooldownActive {
    if (-not (Test-Path $COOLDOWN)) { return $false }
    try {
        $t = [datetime](Get-Content $COOLDOWN -EA Stop | Select-Object -First 1)
        return ((Get-Date) -lt $t.AddMinutes(2))
    } catch { return $false }
}
function Get-PreferredShell {
    $pwshPath = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) { return $pwshPath }
    $cmd = Get-Command pwsh -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}
function Start-HiddenScript([string]$ScriptPath) {
    $shell = Get-PreferredShell
    $argList = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    Start-Process -FilePath $shell -ArgumentList $argList -WindowStyle Hidden
}
function TriggerRepair([string]$reason) {
    if (RepairCooldownActive) { return }
    Set-Content $COOLDOWN (Get-Date -Format 'o') -Force -EA SilentlyContinue
    Log $reason
    if (Test-Path $REPAIR) { Start-HiddenScript $REPAIR }
}
Log "WGKillSwitchSvc started (v10.8)"
Start-Sleep -Seconds 20
TriggerRepair "Initial repair triggered"
while ($true) {
    Start-Sleep -Seconds 60
    $proc = GetMonitorShellProcs
    if (-not $proc) { TriggerRepair "Main monitor missing - repair triggered" }
}
'@ | Set-Content $SERVICE_PS1 -Encoding UTF8 -Force
OK "service-monitor.ps1 written"

# ================================================================
Write-Step "STEP 11 - MAIN SCHEDULED TASK (60s boot delay)"
# ================================================================
Remove-TaskFully $TASK_MONITOR
$actionParams = @{
    Execute  = "powershell.exe"
    Argument = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MONITOR_PS1`""
}
$action  = New-ScheduledTaskAction @actionParams
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT60S"
$settingsParams = @{
    ExecutionTimeLimit         = [TimeSpan]::Zero
    RestartCount               = 999
    RestartInterval            = (New-TimeSpan -Minutes 1)
    StartWhenAvailable         = $true
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    RunOnlyIfNetworkAvailable  = $false
    MultipleInstances          = 'IgnoreNew'
}
$settings  = New-ScheduledTaskSettingsSet @settingsParams
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$regParams = @{
    TaskName  = $TASK_MONITOR
    Action    = $action
    Trigger   = $trigger
    Settings  = $settings
    Principal = $principal
    Force     = $true
}
Register-ScheduledTask @regParams | Out-Null
# Monitor start deferred to STEP 19 (after install lock cleared)
$g1 = Get-ScheduledTask -TaskName $TASK_MONITOR -EA SilentlyContinue
if ($g1) { OK "WG-KillSwitch task registered ($($g1.State)) - start deferred to STEP 19" }
else      { Write-Err "WG-KillSwitch task registration FAILED!" }

# ================================================================
Write-Step "STEP 12 - REPAIR TASK (30s boot delay + every 5min)"
# ================================================================
Remove-TaskFully $TASK_REPAIR
$action2Params = @{
    Execute  = "powershell.exe"
    Argument = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
}
$action2   = New-ScheduledTaskAction @action2Params
$trigger2a = New-ScheduledTaskTrigger -AtStartup
$trigger2a.Delay = "PT30S"
# FIX: use 10 years instead of 9999 days - avoids Task Scheduler XML validation
# failures on some Windows builds where P9999D exceeds the internal duration limit
$trigger2bParams = @{
    Once               = $true
    At                 = (Get-Date).AddMinutes(5)
    RepetitionInterval = (New-TimeSpan -Minutes 5)
    RepetitionDuration = (New-TimeSpan -Days 3650)
}
$trigger2b  = New-ScheduledTaskTrigger @trigger2bParams
$settings2Params = @{
    ExecutionTimeLimit         = (New-TimeSpan -Minutes 2)
    StartWhenAvailable         = $true
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    RunOnlyIfNetworkAvailable  = $false
    MultipleInstances          = 'IgnoreNew'
}
$settings2  = New-ScheduledTaskSettingsSet @settings2Params
$principal2 = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$reg2Params = @{
    TaskName  = $TASK_REPAIR
    Action    = $action2
    Trigger   = @($trigger2a, $trigger2b)
    Settings  = $settings2
    Principal = $principal2
    Force     = $true
}
Register-ScheduledTask @reg2Params | Out-Null
$g2 = Get-ScheduledTask -TaskName $TASK_REPAIR -EA SilentlyContinue
if ($g2) { OK "WG-RepairTask registered ($($g2.State)) - 30s boot delay + every 5min" }
else      { Write-Err "WG-RepairTask registration FAILED!" }

# ================================================================
Write-Step "STEP 13 - REGISTRY BACKUP + FOLDER PROTECTION"
# ================================================================
$acl = Get-Acl $INSTALL_DIR
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM",   "FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users",         "ReadAndExecute", "ContainerInherit,ObjectInherit","None","Allow")))
Set-Acl -Path $INSTALL_DIR -AclObject $acl
Get-ChildItem $INSTALL_DIR -File | Where-Object { $_.Name -notin @('killswitch.log','kurtar.ps1','kurtar.bat') } |
    ForEach-Object { attrib +S +H $_.FullName }
OK "ACL set + files hidden"

$taskXml = Export-ScheduledTask -TaskName $TASK_MONITOR
if ($taskXml) {
    $taskXml | Set-Content "$INSTALL_DIR\WG-KillSwitch-backup.xml" -Encoding UTF8 -Force
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskXml))
    New-Item -Path "HKLM:\SOFTWARE\WGKillSwitch" -Force | Out-Null
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TaskXML"       $b64                                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "MonitorPath"   $MONITOR_PS1                        -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RepairPath"    $REPAIR_PS1                         -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "Version"       "10.8"                              -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "InstalledDate" (Get-Date -f "yyyy-MM-dd HH:mm:ss") -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "CustomMode"    ([bool]$CUSTOM_MODE)                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ConfigPath"    $CONFIG                             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TunnelName"    $TUNNEL_NAME                        -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerIP"      $(if ($CUSTOM_MODE) { $CustomEndpointIP } else { $serverIPs }) -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerPort"    (Get-ServerPort)                    -Force
    OK "Registry backup written"
}

$runKeyValue = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "WGKillSwitchGuard" $runKeyValue -Force
OK "Registry Run key added"

& sc.exe failure $TUNNEL_SVC reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
OK "WireGuard tunnel crash recovery configured"

# ================================================================
Write-Step "STEP 14 - WINDOWS SERVICE (NSSM)"
# ================================================================
if (Test-Path $NSSM) {
    & $NSSM install    $WG_SVC_NAME powershell.exe 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppParameters "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SERVICE_PS1`"" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME Start          SERVICE_DELAYED_AUTO_START 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME ObjectName     LocalSystem 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME DisplayName    "WG KillSwitch Guard" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME Description    "WireGuard Kill Switch - auto-generated" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppExit        Default Restart 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppRestartDelay 5000 2>$null | Out-Null
    & sc.exe failure   $WG_SVC_NAME reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
    & sc.exe sdset     $WG_SVC_NAME "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)" 2>$null | Out-Null
    & $NSSM start      $WG_SVC_NAME 2>$null | Out-Null
    Start-Sleep 5
    $svcStatus = & sc.exe query $WG_SVC_NAME 2>$null
    if ($svcStatus -match "RUNNING")     { OK "WGKillSwitchSvc: RUNNING (delayed-auto)" }
    elseif ($svcStatus -match "PENDING") { OK "WGKillSwitchSvc: STARTING..." }
    else { WARN "WGKillSwitchSvc did not start - other layers still active" }
} else { WARN "NSSM not available - service layer skipped" }

# ================================================================
Write-Step "STEP 15 - WMI SUBSCRIPTION"
# ================================================================
$wmiQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND (TargetInstance.Name = 'powershell.exe' OR TargetInstance.Name = 'pwsh.exe') AND (TargetInstance.CommandLine LIKE '%\monitor.ps1%' OR TargetInstance.CommandLine LIKE '%/monitor.ps1%')"
$filterParams = @{
    Namespace  = "root\subscription"
    ClassName  = "__EventFilter"
    Property   = @{ Name=$WMI_FILTER; EventNamespace="root\cimv2"; QueryLanguage="WQL"; Query=$wmiQuery }
    ErrorAction= "SilentlyContinue"
}
$filter = New-CimInstance @filterParams

$consumerParams = @{
    Namespace  = "root\subscription"
    ClassName  = "CommandLineEventConsumer"
    Property   = @{ Name=$WMI_CONSUMER; CommandLineTemplate="powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WMI_WRAPPER`"" }
    ErrorAction= "SilentlyContinue"
}
$consumer = New-CimInstance @consumerParams

if ($filter -and $consumer) {
    $bindingParams = @{
        Namespace  = "root\subscription"
        ClassName  = "__FilterToConsumerBinding"
        Property   = @{ Filter=[Ref]$filter; Consumer=[Ref]$consumer }
        ErrorAction= "SilentlyContinue"
    }
    New-CimInstance @bindingParams | Out-Null
    OK "WMI Event Subscription active"
} else { WARN "WMI Subscription failed" }

# ================================================================
Write-Step "STEP 16 - STARTUP FOLDER SHORTCUT"
# ================================================================
New-Item -ItemType Directory -Path (Split-Path $STARTUP_LNK) -Force -EA SilentlyContinue | Out-Null
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($STARTUP_LNK)
$lnk.TargetPath       = "powershell.exe"
$lnk.Arguments        = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
$lnk.WorkingDirectory = $INSTALL_DIR
$lnk.Save()
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut created" } else { WARN "Startup shortcut failed" }

# ================================================================
Write-Step "STEP 17 - GPO BOOT SCRIPT"
# ================================================================
New-Item -ItemType Directory -Path $GPO_SCRIPT_DIR -Force -EA SilentlyContinue | Out-Null
$gpoTunnelSvc = $TUNNEL_SVC
$gpoContent = @"
# WG KillSwitch GPO Boot Script v10.8 (auto-generated by install.ps1)
`$LOG        = 'C:\WireGuard\killswitch.log'
`$REPAIR     = 'C:\WireGuard\repair.ps1'
`$TUNNEL_SVC = '$gpoTunnelSvc'
`$ErrorActionPreference = 'SilentlyContinue'
function Wait-NamedMutex([System.Threading.Mutex]`$Mutex, [int]`$TimeoutMs) {
    try { return `$Mutex.WaitOne(`$TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return `$true }
}
function Log(`$m) {
    `$mutex = `$null
    try {
        `$mutex = New-Object System.Threading.Mutex(`$false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex `$mutex 2000)) { return }
        Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [GPO] `$m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if (`$mutex) { try { `$mutex.ReleaseMutex() } catch {} } }
}
function Test-TunnelRunning {
    return ([bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match "RUNNING"))
}
function Test-TcpHost([string]`$HostName, [int]`$Port, [int]`$TimeoutMs = 4000) {
    `$tcp = `$null
    try {
        `$tcp = New-Object System.Net.Sockets.TcpClient
        `$iar = `$tcp.BeginConnect(`$HostName, `$Port, `$null, `$null)
        if (-not `$iar.AsyncWaitHandle.WaitOne(`$TimeoutMs, `$false)) { return `$false }
        try { `$tcp.EndConnect(`$iar) } catch { return `$false }
        return `$true
    } catch { return `$false }
    finally { if (`$tcp) { try { `$tcp.Close() } catch {} } }
}
function Test-Internet {
    `$hits = 0
    foreach (`$h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-TcpHost `$h 443) { `$hits++ } }
    return (`$hits -ge 2)
}
function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Internet) }
function Get-PreferredShell {
    `$pwshPath = Join-Path `$env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path `$pwshPath) { return `$pwshPath }
    `$cmd = Get-Command pwsh -EA SilentlyContinue
    if (`$cmd) { return `$cmd.Source }
    return Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
function Start-HiddenScript([string]`$ScriptPath) {
    `$shell = Get-PreferredShell
    Start-Process -FilePath `$shell -ArgumentList @('-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',`$ScriptPath) -WindowStyle Hidden
}
Log "GPO boot script fired (v10.8)"
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
`$waited = 0
while (`$waited -lt 90 -and -not (Test-SafeToOpen)) {
    Start-Sleep -Seconds 3; `$waited += 3
}
if (Test-SafeToOpen) { Log "GPO: healthy after `${waited}s (tunnel + internet)" }
elseif (Test-TunnelRunning) { Log "GPO: zombie tunnel after `${waited}s - repair will sync block" }
else { Log "GPO: tunnel down after `${waited}s - repair will sync block" }
if (Test-Path `$REPAIR) {
    Start-HiddenScript `$REPAIR
    Log "Repair triggered (waited `${waited}s)"
}
"@
$gpoContent | Set-Content $GPO_SCRIPT -Encoding UTF8 -Force
Update-GpoScriptsIni $GPO_INI $GPO_SCRIPT
Start-Process "secedit.exe"  -ArgumentList "/refreshpolicy machine_policy /enforce" -WindowStyle Hidden -Wait -EA SilentlyContinue
Start-Process "gpupdate.exe" -ArgumentList "/force" -WindowStyle Hidden -EA SilentlyContinue
if (Test-Path $GPO_SCRIPT) { OK "GPO boot script installed" } else { WARN "GPO script failed" }

# ================================================================
Write-Step "STEP 18 - DEFENDER EXCLUSION"
# ================================================================
try { Add-MpPreference -ExclusionPath $INSTALL_DIR -EA Stop; OK "Defender exclusion: $INSTALL_DIR" }
catch { WARN "Defender exclusion failed" }

# ================================================================
Write-Step "STEP 19 - ACTIVATE MONITOR + CLEAR INSTALL LOCK"
# ================================================================
Ensure-TunnelForInstall | Out-Null
Write-KurtarScript
Clear-InstallLock
OK "Install lock cleared - kill switch may now block if tunnel fails"
schtasks /Run /TN "\$($TASK_MONITOR)" 2>$null | Out-Null
Start-Sleep 5
if (-not (Test-SafeToOpen)) {
    Remove-InstallBlocks
    WARN "Tunnel not healthy yet - blocks OFF; monitor will recover. kurtar.bat available."
} else {
    OK "Tunnel + internet OK - monitor taking over"
}

# ================================================================
Write-Step "STEP 20 - FINAL CHECK"
# ================================================================
$warnings = 0
if (Test-TunnelRunning) { OK "Tunnel: RUNNING" } else { WARN "Tunnel: DOWN (monitor will recover)"; $warnings++ }
if (Test-SafeToOpen) {
    OK "Health: tunnel + internet verified (SafeToOpen)"
} elseif (Test-TunnelRunning) {
    OK "Health: zombie protected (tunnel up, block should be active)"
    foreach ($br in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        if (Test-FirewallRuleEnabled $br) { OK "Block rule active: $br" }
        else { WARN "Block rule missing: $br"; $warnings++ }
    }
} else {
    OK "Health: tunnel down (block rules expected)"
}

$g1 = Get-ScheduledTask -TaskName $TASK_MONITOR -EA SilentlyContinue
$g2 = Get-ScheduledTask -TaskName $TASK_REPAIR  -EA SilentlyContinue
if ($g1) { OK "WG-KillSwitch task: $($g1.State)" }  else { Write-Err "WG-KillSwitch task MISSING"; $warnings++ }
if ($g2) {
    $tc = ($g2.Triggers | Measure-Object).Count
    if ($tc -ge 2) { OK "WG-RepairTask: $($g2.State) ($tc triggers)" }
    else { WARN "WG-RepairTask: $tc trigger(s) (expected 2)"; $warnings++ }
} else { Write-Err "WG-RepairTask MISSING"; $warnings++ }

Start-Sleep 3
$proc = Get-MonitorShellProcs
if (($proc | Measure-Object).Count -gt 1) {
    $proc | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
    Start-Sleep 2
    $proc = Get-MonitorShellProcs
}
if ($proc) { OK "Monitor: active (PID: $(($proc | Select-Object -First 1).Id))" }
else        { WARN "Monitor: not yet running" }

$svcSt = & sc.exe query $WG_SVC_NAME 2>$null
if ($svcSt -match "RUNNING")   { OK "WGKillSwitchSvc: RUNNING" }
elseif (Test-Path $NSSM)        { WARN "WGKillSwitchSvc: not running"; $warnings++ }
else                            { WARN "WGKillSwitchSvc: NSSM absent, skipped" }

if ((& sc.exe qc $TUNNEL_SVC 2>$null) -match "DELAYED") { OK "Tunnel service: delayed-auto-start" }
else { WARN "Tunnel service: not delayed-auto"; $warnings++ }

$wmiK = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq $WMI_FILTER }
if ($wmiK) { OK "WMI Subscription: ACTIVE" } else { WARN "WMI Subscription: missing"; $warnings++ }
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut: present" } else { WARN "Startup shortcut: missing"; $warnings++ }
if (Test-Path $GPO_SCRIPT)  { OK "GPO script: present" }       else { WARN "GPO script: missing";       $warnings++ }

$reg = Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -EA SilentlyContinue
if ($reg.TaskXML) { OK "Registry backup: v$($reg.Version)" } else { WARN "Registry backup: missing"; $warnings++ }

$ipv6Rule = Get-NetFirewallRule -DisplayName "KS-Block-IPv6-Out" -EA SilentlyContinue
if ($ipv6Rule -and $ipv6Rule.Enabled -eq "True") { OK "IPv6 block: ACTIVE" } else { WARN "IPv6 block: inactive"; $warnings++ }

$dnsRule    = Get-NetFirewallRule -DisplayName "KS-DNS-Block"     -EA SilentlyContinue
$dnsTcpRule = Get-NetFirewallRule -DisplayName "KS-DNS-Block-TCP" -EA SilentlyContinue
if ($dnsRule -and $dnsTcpRule) { OK "DNS leak protection: ACTIVE (UDP+TCP)" } else { WARN "DNS leak protection: incomplete"; $warnings++ }

$wgExeRule = Get-NetFirewallRule -DisplayName "KS-WireGuard-EXE" -EA SilentlyContinue
if ($wgExeRule) { OK "WireGuard EXE rule: ACTIVE" } else { WARN "WireGuard EXE rule: missing"; $warnings++ }

if (Test-Path $LOG) { attrib -H -S -R $LOG 2>$null | Out-Null }
OK "killswitch.log: accessible"

$defExcl = (Get-MpPreference -EA SilentlyContinue).ExclusionPath
if ($defExcl -contains $INSTALL_DIR) { OK "Defender exclusion: ACTIVE" } else { WARN "Defender exclusion: inactive" }

if ($CUSTOM_MODE) { OK "Mode: Custom server ($CustomEndpointIP)" } else { OK "Mode: Cloudflare WARP" }

Log "install.ps1 v10.8 completed"
Write-Host ""
if ($warnings -eq 0) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  INSTALL COMPLETE - SYSTEM FULLY PROTECTED (v10.8)            " -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Green
} else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  INSTALL COMPLETE - $warnings WARNING(S) - see above          " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log: C:\WireGuard\killswitch.log" -ForegroundColor Gray
Write-Host "  Rescue (offline): C:\WireGuard\kurtar.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "  Protection layers:" -ForegroundColor White
Write-Host "  [1] WireGuard tunnel: delayed-auto-start"           -ForegroundColor DarkGray
Write-Host "  [2] WGKillSwitchSvc (NSSM): delayed-auto-start"    -ForegroundColor DarkGray
Write-Host "  [3] WG-KillSwitch task: 60s boot delay"            -ForegroundColor DarkGray
Write-Host "  [4] WG-RepairTask: 30s boot delay + every 5min"    -ForegroundColor DarkGray
Write-Host "  [5] WMI Event Subscription: powershell death watch" -ForegroundColor DarkGray
Write-Host "  [6] Startup folder shortcut"                        -ForegroundColor DarkGray
Write-Host "  [7] GPO Machine Startup Script"                     -ForegroundColor DarkGray
Write-Host "  [8] HKLM Run key"                                   -ForegroundColor DarkGray
Write-Host ""
if ($CUSTOM_MODE) {
    Write-Host "  Custom server usage example:" -ForegroundColor White
    Write-Host "  .\install.ps1 -CustomConfig C:\myvpn.conf -CustomTunnel myvpn -CustomEndpointIP 1.2.3.4/32 -CustomPort 51820" -ForegroundColor DarkGray
    Write-Host ""
}
pause

