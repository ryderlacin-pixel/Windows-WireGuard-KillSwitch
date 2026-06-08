# Dot-sourced from install.ps1 - Install-MainSteps-0-6.ps1 (v15.1)
#Requires -Version 5.1

function Invoke-InstallMainSteps0to6 {
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
    Remove-IPv6FromConfig
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
    Remove-IPv6FromConfig
    $svcRunning = [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match 'RUNNING')
    if ($svcRunning) { OK "Tunnel RUNNING - kept alive (IPv4-only config active)" }
    elseif (Restart-TunnelWithConfig) { OK "Tunnel reloaded with IPv4-only config" }
    else { WARN "Tunnel reload after IPv6 strip failed - STEP 5 will retry" }
} # end WARP block

# ================================================================
Write-Step "STEP 1 - FOLDER PREP"
# ================================================================
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
Unlock-InstallDirForWrite
OK "Folder ready: $INSTALL_DIR"

# ================================================================
Write-Step "STEP 2 - NSSM"
# ================================================================
if (-not (Test-Path $NSSM)) {
    try {
        $zip = "$INSTALL_DIR\nssm.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $nssmUrls = @(
            'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip',
            'https://nssm.cc/release/nssm-2.24.zip'
        )
        $downloaded = $false
        foreach ($nssmUrl in $nssmUrls) {
            try {
                Invoke-WebRequest $nssmUrl -OutFile $zip -TimeoutSec 60 -UseBasicParsing
                $downloaded = $true
                break
            } catch { Write-Info "NSSM URL failed: $nssmUrl" }
        }
        if (-not $downloaded) { throw 'All NSSM download URLs failed' }
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
Write-Info "Install lock set; clearing legacy rescue artifacts..."
Remove-KurtarArtifacts
OK "Server IPs cached; install lock ON (watchdog auto-unbricks if needed)"

# ================================================================
Write-Step "STEP 3 - CLEANUP (old installs)"
# ================================================================
$cim = Get-ShortCimSession
$cimArgs = @{}
if ($cim) { $cimArgs['CimSession'] = $cim }

Write-Info "Removing old scheduled tasks..."
foreach ($tn in @($TASK_MONITOR, $TASK_REPAIR, 'WireGuard-KillSwitch-Monitor', 'WG-OnarimGorevi',
        'WG-RepairTask', 'WG-RebootVerify', $TASK_WATCHDOG, 'WG-InternetWatchdog', 'WG-UnbrickResume')) {
    Remove-TaskFully $tn
}
Remove-KurtarArtifacts

Write-Info "Removing old NSSM service (if any)..."
$oldSvc = & sc.exe query $WG_SVC_NAME 2>$null
if ($oldSvc) {
    if ($oldSvc -match 'PAUSED') { Invoke-ScCommand @('continue', $WG_SVC_NAME) }
    if (Test-Path $NSSM) {
        $np = Start-Process -FilePath $NSSM -ArgumentList 'stop', $WG_SVC_NAME -PassThru -NoNewWindow -Wait:$false
        $dl = (Get-Date).AddSeconds(12)
        while (-not $np.HasExited -and (Get-Date) -lt $dl) { Start-Sleep -Milliseconds 200 }
        if (-not $np.HasExited) { $np.Kill() }
    }
    Invoke-ScCommand @('stop', $WG_SVC_NAME)
    if (Test-Path $NSSM) {
        $np2 = Start-Process -FilePath $NSSM -ArgumentList 'remove', $WG_SVC_NAME, 'confirm' -PassThru -NoNewWindow -Wait:$false
        $dl2 = (Get-Date).AddSeconds(12)
        while (-not $np2.HasExited -and (Get-Date) -lt $dl2) { Start-Sleep -Milliseconds 200 }
        if (-not $np2.HasExited) { $np2.Kill() }
    }
    Invoke-ScCommand @('delete', $WG_SVC_NAME)
}

Write-Info "Removing old WMI subscriptions..."
try {
    Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" @cimArgs -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" @cimArgs -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    $bindFilter = "Filter = ""__EventFilter.Name='$WMI_FILTER'"""
    Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Filter $bindFilter @cimArgs -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='WGMonitorOldu'" @cimArgs -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
} catch {}

Remove-Item $STARTUP_LNK -Force -EA SilentlyContinue

Write-Info "Legacy shells skipped (install lock active; old tasks removed)"

$allRules = @(
    "KS-Block-WiFi-Out","KS-Block-Ethernet-Out","KS-Block-RemoteAccess-Out","KS-Block-PPP-Out",
    "KS-Block-IPv6-Out","KS-Block-IPv6-In",
    "KS-LAN-Out","KS-LAN-In","KS-DHCP-Out","KS-DHCP-In",
    "KS-WARP-Server-Out","KS-Loopback-Out","KS-Loopback-In",
    "KS-DNS-Allow","KS-DNS-Block","KS-DNS-Block-TCP","KS-WireGuard-EXE","KS-Dnscrypt-EXE","KS-WireGuard-Tunnel-SVC",
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
foreach ($pfx in @('fe80::/10','::1/128','fc00::/7')) {
    netsh advfirewall firewall add rule name="KS-Block-IPv6-Out" dir=out action=block remoteip=$pfx enable=yes 2>$null | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-IPv6-In"  dir=in  action=block remoteip=$pfx enable=yes 2>$null | Out-Null
}
Write-Info "Disabling IPv6 bindings (timeout 45s)..."
Disable-AllIPv6Bindings

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
netsh advfirewall firewall add rule name="KS-DNS-Block"     dir=out action=block protocol=UDP remoteport=53 enable=no | Out-Null
netsh advfirewall firewall add rule name="KS-DNS-Block-TCP" dir=out action=block protocol=TCP remoteport=53 enable=no | Out-Null
netsh advfirewall firewall add rule name="KS-WireGuard-EXE" dir=out action=allow program="C:\Program Files\WireGuard\wireguard.exe" enable=yes | Out-Null
if (Test-Path $DNSCRYPT_EXE) {
    netsh advfirewall firewall add rule name="KS-Dnscrypt-EXE" dir=out action=allow program="$DNSCRYPT_EXE" enable=yes | Out-Null
}

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
    WARN "Tunnel down - blocks deferred (install lock); monitor will recover"
}


}
