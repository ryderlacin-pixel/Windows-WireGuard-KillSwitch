# ================================================================
# WireGuard + WARP Kill Switch - FULL AUTOMATIC SETUP (v15.0)
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
# - Install-safe (v10.8+): install lock defers outbound blocks until STEP 19; tunnel kept alive on upgrade;
#   kurtar.bat/ps1 restores internet offline if install is interrupted.
# - v10.9: strips IPv6 from WARP config; fixes WMI; dedupes monitor; faster tunnel-down block (2s poll).
# - v15.0: strong privacy — system DNS lock (all adapters 127.0.0.1), LLMNR/NetBIOS off,
#   stricter dnscrypt (require_nolog, quad9 only), KS-Dnscrypt-EXE firewall, sensitive-mode launcher.
# - v14.0: dnscrypt-proxy (127.0.0.1:53) + Tor Browser hardening + leak-sentinel (read-only);
#   phased upgrades: -DnsLeakUpgradeOnly / -TorUpgradeOnly / -FullPrivacyUpgrade / -StrongPrivacyUpgrade.
# - v13.5: privacy engineer pass — Privacy Sandbox/DoH/QUIC off, Firefox RFP+, WER reduced,
#   honest threat-model scores, script SHA256 integrity vault; supply-chain verify in safe-live-verify.
# - v13.4: privacy hardening — cookies/tracking/fingerprint + Windows telemetry/ads/cloud;
#   privacy-hardening-guard.ps1 re-applied by repair/vault (webrtc forwarder kept).
# - v13.3: system-level WebRTC leak guard — Chromium/Brave/Edge HKLM policies + Firefox
#   policies.json; webrtc-leak-guard.ps1 re-applied by repair/anti-tamper vault.
# - v13.2: kurtar.bat/ps1/kurtar2 removed — protection never torn down; watchdog/monitor use
#   gentle deep-unbrick only (blocks off + UnbrickUntil, tasks/service stay running).
# - v13.1: repair/GPO/SVC never Enable-Block (monitor-only block authority); startup fail-open;
#   recovery loop never re-blocks; resume sets BootGrace; tunnel+adapter dual check.
# - v13.0 ultimate fail-open: SafeToOpen = tunnel+TCP only (DNS never gates open); BootGrace 180s;
#   block only after 5x tunnel-down or 15x zombie; repair fail-open on zombie; watchdog graduated;
#   auto kurtar2 never turns firewall off; unified health across all layers.
# - v12.3: kurtar2 = full unbrick (stops layers, disables tasks, firewall recovery like Downloads KURTAR2);
#   UnbrickUntil cooldown stops monitor/repair re-blocking; watchdog auto-invokes kurtar2.
# - v12.2: tunnel-down debounce (3x/6s before block); repair uses rule-exists not rule-enabled for DNS;
#   dedupes duplicate firewall rules; watchdog every 1min; repair syncs DNS state after firewall repair.
# - v12.1: DNS leak rules toggle with block state (fixes internet-open DNS brick); Test-Dns in SafeToOpen;
#   internet watchdog task (3min) auto-unbricks stuck blocks; emergency unbrick after 5 failed cycles.
# - v12.0 ultimate: unified version constant; WMI watches powershell+pwsh (single OR query); PID validated
#   by command-line; GPO/repair/post-reboot tunnel names parameterized; repair task 15min limit; zombie
#   recovery uses DNS flush not reinstall; safe-live-verify.ps1 for non-disruptive production gate.
# - v11.5: Try-ReinstallTunnel polls sc.exe start up to 30s; monitor auto-unbrick after prolonged failure
#   (removes blocks + retries tunnel so user is never left without internet indefinitely).
# - v11.4: tunnel reinstall mutex shared by monitor/repair/kurtar; repair defers to active monitor;
#   SVC stops spawning repair every 5s during monitor recovery (fixes concurrent reinstall brick).
# - v11.3: anti-tamper guard — silent restore when tasks/scripts/firewall/WMI/service deleted.
# - v11.2: post-reboot auto-verify task (WG-RebootVerify, 5min after boot).
# - v11.1: monitor singleton hardening — single launcher, periodic dedupe, stale PID cleanup.
# - v11.0: ultimate hardening — firewall/config self-repair, network change detect, WMI cooldown,
#   2min repair cadence, delayed-auto enforcement, boot/GPO resilience, stress-test gate.
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
    [int]$CustomPort          = 0,   # WireGuard port (default: 2408)
    [switch]$PrivacyUpgradeOnly,      # v13.5+ privacy/integrity refresh without full reinstall
    [switch]$DnsLeakUpgradeOnly,      # v14: dnscrypt-proxy + WG DNS=127.0.0.1 only
    [switch]$TorUpgradeOnly,          # v14: Tor Browser user.js hardening only
    [switch]$FullPrivacyUpgrade,      # v14: dnscrypt + Tor + leak-sentinel + v13.5 privacy
    [switch]$StrongPrivacyUpgrade,    # v15: v14 + system DNS lock + network privacy + strict dnscrypt
    [switch]$NoPause                  # skip end pause (CI / automated resume)
)
# Installer: Continue shows errors without aborting noisy steps; runtime scripts set their own preference.
$ErrorActionPreference = "Continue"
$WG_KS_VERSION = '15.0'

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
$TASK_REBOOT_VERIFY = "WG-RebootVerify"
$TASK_WATCHDOG    = "WG-InternetWatchdog"
$REBOOT_VERIFY_PS1  = "$INSTALL_DIR\post-reboot-verify.ps1"
$WATCHDOG_PS1     = "$INSTALL_DIR\internet-watchdog.ps1"
$WG_SVC_NAME  = "WGKillSwitchSvc"
$WMI_FILTER   = "WGMonitorFilter"
$WMI_CONSUMER = "WGMonitorConsumer"
$STARTUP_LNK  = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WGKillSwitch.lnk"
$GPO_SCRIPT_DIR = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup"
$GPO_SCRIPT   = "$GPO_SCRIPT_DIR\wg-startup.ps1"
$GPO_INI_DIR  = "C:\Windows\System32\GroupPolicy\Machine\Scripts"
$GPO_INI      = "$GPO_INI_DIR\scripts.ini"
$INSTALL_LOCK = "$INSTALL_DIR\install.inprogress"
$GUARD_DIR    = 'C:\ProgramData\WGKillSwitchGuard'
$ANTI_TAMPER_PS1 = "$INSTALL_DIR\anti-tamper.ps1"
$WEBRTC_GUARD_PS1 = "$INSTALL_DIR\webrtc-leak-guard.ps1"
$PRIVACY_GUARD_PS1 = "$INSTALL_DIR\privacy-hardening-guard.ps1"
$DNSCRYPT_DIR      = "$INSTALL_DIR\dnscrypt-proxy"
$DNSCRYPT_EXE      = "$DNSCRYPT_DIR\dnscrypt-proxy.exe"
$DNSCRYPT_CONF     = "$DNSCRYPT_DIR\dnscrypt-proxy.toml"
$DNSCRYPT_SVC      = 'WG-DnscryptProxy'
$DNSCRYPT_GUARD_PS1 = "$INSTALL_DIR\dnscrypt-guard.ps1"
$TOR_GUARD_PS1     = "$INSTALL_DIR\tor-hardening-guard.ps1"
$TOR_MONITOR_PS1   = "$INSTALL_DIR\tor-connectivity-monitor.ps1"
$LEAK_SENTINEL_PS1 = "$INSTALL_DIR\leak-sentinel.ps1"
$DNS_LOCKDOWN_GUARD_PS1 = "$INSTALL_DIR\dns-lockdown-guard.ps1"
$NETWORK_PRIVACY_GUARD_PS1 = "$INSTALL_DIR\network-privacy-guard.ps1"
$SENSITIVE_MODE_PS1 = "$INSTALL_DIR\sensitive-mode.ps1"

$script:WG_KS_VERSION = $WG_KS_VERSION
$script:CONFIG = $CONFIG
$script:NSSM = $NSSM
$script:DNSCRYPT_DIR = $DNSCRYPT_DIR
$script:DNSCRYPT_EXE = $DNSCRYPT_EXE
$script:DNSCRYPT_CONF = $DNSCRYPT_CONF
$script:DNSCRYPT_SVC = $DNSCRYPT_SVC
$script:DNSCRYPT_GUARD_PS1 = $DNSCRYPT_GUARD_PS1
$script:TOR_GUARD_PS1 = $TOR_GUARD_PS1
$script:TOR_MONITOR_PS1 = $TOR_MONITOR_PS1
$script:LEAK_SENTINEL_PS1 = $LEAK_SENTINEL_PS1
$script:DNS_LOCKDOWN_GUARD_PS1 = $DNS_LOCKDOWN_GUARD_PS1
$script:NETWORK_PRIVACY_GUARD_PS1 = $NETWORK_PRIVACY_GUARD_PS1
$script:INSTALL_DIR = $INSTALL_DIR

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

$script:CimShort = $null
function Get-ShortCimSession {
    if ($script:CimShort) { return $script:CimShort }
    try {
        $opt = New-CimSessionOption -OperationTimeout (New-TimeSpan -Seconds 8)
        $script:CimShort = New-CimSession -SessionOption $opt -ErrorAction Stop
    } catch { $script:CimShort = $null }
    return $script:CimShort
}

function Get-WmiBindFilter([string]$FilterName = $WMI_FILTER) {
    return "Filter = ""__EventFilter.Name='$FilterName'"""
}

function Test-WmiSubscriptionActive {
    try {
        $cim = Get-ShortCimSession
        $ca = @{ Namespace = 'root\subscription' }
        if ($cim) { $ca['CimSession'] = $cim }
        $f = Get-CimInstance @ca -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" -EA SilentlyContinue
        if (-not $f) { return $false }
        $c = Get-CimInstance @ca -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" -EA SilentlyContinue
        if (-not $c) { return $false }
        $b = Get-CimInstance @ca -ClassName __FilterToConsumerBinding -Filter (Get-WmiBindFilter) -EA SilentlyContinue
        return [bool]$b
    } catch { return $false }
}

function Invoke-Schtasks($args, [int]$timeoutSec = 5) {
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList $args -PassThru -NoNewWindow -Wait:$false
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(2000) }
    } catch {}
}

function Invoke-ScCommand([string[]]$args, [int]$timeoutSec = 10) {
    try {
        $p = Start-Process -FilePath 'sc.exe' -ArgumentList $args -PassThru -NoNewWindow -Wait:$false
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(2000) }
    } catch {}
}

function Remove-TaskFully($name) {
    $tn = '\' + $name
    Invoke-Schtasks @('/End', '/TN', $tn, '/F')
    Invoke-Schtasks @('/Delete', '/TN', $tn, '/F')
}

function Register-TaskViaSchtasks(
    [string]$Name,
    [string]$Command,
    [string]$ScheduleArgs,
    [int]$TimeoutSec = 45
) {
    $tn = '\' + $Name
    $args = @('/Create', '/TN', $tn, '/TR', "`"$Command`"", '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F') + $ScheduleArgs.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList $args -PassThru -NoNewWindow -Wait:$false
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(2000) }
    } catch {}
    schtasks /Query /TN $tn 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Export-TaskXmlSafe([string]$Name, [int]$TimeoutSec = 20) {
    $tn = '\' + $Name
    $out = Join-Path $env:TEMP "wg-task-$Name.xml"
    try {
        $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Query', '/TN', $tn, '/XML') -PassThru -NoNewWindow -Wait:$false -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(2000); return $null }
        if (Test-Path $out) {
            $xml = Get-Content $out -Raw -Encoding UTF8 -EA SilentlyContinue
            Remove-Item $out, "$out.err" -Force -EA SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($xml)) { return $xml }
        }
    } catch {}
    Remove-Item $out, "$out.err" -Force -EA SilentlyContinue
    return $null
}

function Test-TunnelServiceRunning {
    try {
        $svc = Get-Service -Name $TUNNEL_SVC -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
    } catch {}
    return [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match 'RUNNING')
}

function Test-TunnelAdapterUp {
    $ifaces = & netsh interface show interface 2>$null | Out-String
    if ($ifaces -match 'WireGuard' -or $ifaces -match [regex]::Escape($TUNNEL_NAME)) { return $true }
    return $false
}

function Test-TunnelRunning {
    if (-not (Test-TunnelServiceRunning)) { return $false }
    return (Test-TunnelAdapterUp)
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

function Restart-TunnelWithConfig {
    if (-not (Test-Path $CONFIG)) { return $false }
    if (Test-TunnelRunning) {
        & sc.exe stop $TUNNEL_SVC 2>$null | Out-Null
        Start-Sleep 2
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        $waited = 0
        while ($waited -lt 30 -and -not (Test-TunnelRunning)) { Start-Sleep 2; $waited += 2 }
        return (Test-TunnelRunning)
    }
    $wgJob = Start-Job -ScriptBlock {
        param($exe, $tn, $cfg, $svc)
        & $exe /uninstalltunnelservice $tn 2>$null | Out-Null
        Start-Sleep 2
        & $exe /installtunnelservice $cfg 2>&1 | Out-Null
        & sc.exe start $svc 2>$null | Out-Null
    } -ArgumentList $WG_EXE, $TUNNEL_NAME, $CONFIG, $TUNNEL_SVC
    $null = Wait-Job $wgJob -Timeout 45
    if ($wgJob.State -eq 'Running') { Stop-Job $wgJob -EA SilentlyContinue; Remove-Job $wgJob -Force; return $false }
    Remove-Job $wgJob -Force
    $waited = 0
    while ($waited -lt 30 -and -not (Test-TunnelRunning)) { Start-Sleep 2; $waited += 2 }
    return (Test-TunnelRunning)
}

function Ensure-TunnelForInstall {
    if (Test-TunnelServiceRunning) {
        OK "Tunnel already RUNNING - kept alive during upgrade"
        return $true
    }
    if (-not (Test-Path $CONFIG)) { WARN "Config missing - cannot install tunnel"; return $false }
    Write-Info "Tunnel down - installing service..."
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
        Start-Sleep 2
        & $WG_EXE /installtunnelservice $CONFIG 2>&1 | Out-Null
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        $waited = 0
        while ($waited -lt 45 -and -not (Test-TunnelServiceRunning)) {
            Start-Sleep 3
            $waited += 3
        }
        if (Test-TunnelServiceRunning) {
            OK "Tunnel RUNNING (attempt $attempt, waited ${waited}s)"
            return $true
        }
    }
    WARN "Tunnel not up after 2 attempts - install continues with internet open"
    return $false
}

function Unlock-InstallDirForWrite {
    attrib -H -S "$INSTALL_DIR\*" /S /D 2>$null | Out-Null
    icacls $INSTALL_DIR /grant "BUILTIN\Administrators:(OI)(CI)F" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /C /Q 2>$null | Out-Null
}

function Remove-IPv6FromConfig {
    if (-not (Test-Path $CONFIG)) { return }
    Unlock-InstallDirForWrite
    try {
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-Content $CONFIG -Encoding UTF8 -EA Stop)) {
            if ($line -match '^\s*Address\s*=') {
                $parts = ($line -split '=', 2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                if ($parts) { $out.Add("Address = $($parts -join ', ')") }
            } elseif ($line -match '^\s*DNS\s*=') {
                $parts = ($line -split '=', 2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                if ($parts) { $out.Add("DNS = $($parts -join ', ')") }
            } elseif ($line -match '^\s*AllowedIPs\s*=') {
                $parts = ($line -split '=', 2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                if ($parts) { $out.Add("AllowedIPs = $($parts -join ', ')") }
            } else { $out.Add($line) }
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($CONFIG, $out, $utf8NoBom)
        OK "IPv6 stripped from config (IPv4-only WARP)"
    } catch { WARN "IPv6 config strip failed: $_" }
}

function Disable-AllIPv6Bindings {
    try {
        $list = & netsh interface show interface 2>$null | Out-String
        foreach ($line in ($list -split "`n")) {
            if ($line -notmatch '^\s*Enabled\s+Connected') { continue }
            $name = ($line -replace '^\s*\S+\s+\S+\s+\S+\s+', '').Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            & netsh interface ipv6 set interface "$name" disabled 2>$null | Out-Null
        }
    } catch {}
}

function Get-ChromiumPrivacyDWordProps {
    return @{
        WebRtcLocalhostCandidateAllowed      = 0
        BlockThirdPartyCookies               = 1
        DefaultThirdPartyCookieSetting       = 1
        EnableDoNotTrack                     = 1
        MetricsReportingEnabled              = 0
        DeviceMetricsReportingEnabled        = 0
        PaymentMethodQueryEnabled            = 0
        BrowserSignin                        = 0
        SyncDisabled                         = 1
        AutofillAddressEnabled               = 0
        AutofillCreditCardEnabled            = 0
        DefaultGeolocationSetting            = 2
        DefaultNotificationsSetting          = 2
        SafeBrowsingExtendedReportingEnabled = 0
        ChromeVariations                     = 0
        PrivacySandboxAdTopicsEnabled        = 0
        PrivacySandboxPromptEnabled          = 0
        PrivacySandboxAdMeasurementEnabled   = 0
        QuicAllowed                          = 0
        BrowserNetworkTimeQueriesEnabled     = 0
        SearchSuggestEnabled                 = 0
        NetworkPredictionOptions             = 2
        SharingDisabled                      = 1
        PasswordManagerEnabled               = 0
        AlternateErrorPagesEnabled           = 0
        SpellCheckServiceEnabled             = 0
        TranslateEnabled                     = 0
    }
}

function Get-FirefoxPrivacyPolicyJson {
    return @'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DoNotTrack": true,
    "Cookies": {
      "Default": "reject-third-party",
      "RejectThirdParty": true,
      "Locked": true
    },
    "Preferences": {
      "media.peerconnection.ice.no_host": { "Value": true, "Status": "locked" },
      "media.peerconnection.ice.default_address_only": { "Value": true, "Status": "locked" },
      "privacy.resistFingerprinting": { "Value": true, "Status": "locked" },
      "privacy.fingerprintingProtection": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.enabled": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.socialtracking.enabled": { "Value": true, "Status": "locked" },
      "network.cookie.cookieBehavior": { "Value": 1, "Status": "locked" },
      "geo.enabled": { "Value": false, "Status": "locked" },
      "privacy.donottrackheader.enabled": { "Value": true, "Status": "locked" },
      "browser.contentblocking.category": { "Value": "strict", "Status": "locked" },
      "webgl.disabled": { "Value": true, "Status": "locked" },
      "dom.webgpu.enabled": { "Value": false, "Status": "locked" },
      "network.http.referer.defaultPolicy": { "Value": 1, "Status": "locked" }
    }
  }
}
'@
}

function Get-WindowsPrivacyRegBlocks {
    return @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Props = @{
            AllowTelemetry = 0; MaxTelemetryAllowed = 0; DoNotShowFeedbackNotifications = 1
            DisableOneSettingsDownloads = 1; DisableTailoredExperiencesWithDiagnosticData = 1
            AllowDeviceNameInTelemetry = 0; AllowWUfBCloudProcessing = 0
        }}
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Props = @{ AllowTelemetry = 0 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Props = @{ DisabledByGroupPolicy = 1 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Props = @{
            PublishUserActivities = 0; EnableActivityFeed = 0; UploadUserActivities = 0; EnableClipboardHistory = 0
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'; Props = @{
            DisableLocation = 1; DisableLocationScripting = 1; DisableSensors = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Props = @{ AllowCortana = 0; AllowCloudSearch = 0 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'; Props = @{
            RestrictImplicitInkCollection = 1; RestrictImplicitTextCollection = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Props = @{
            DisableWindowsConsumerFeatures = 1; DisableCloudOptimizedContent = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Props = @{
            LetAppsAccessAdvertisingId = 2; LetAppsAccessLocation = 2; LetAppsAccessMicrophone = 2; LetAppsAccessCamera = 2
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Props = @{
            Disabled = 1; DontSendAdditionalData = 1; LoggingDisabled = 1
        }}
    )
}

function Set-ChromiumPrivacyPolicies([string]$PolicyPath, [string]$Label) {
    $props = Get-ChromiumPrivacyDWordProps
    New-Item -Path $PolicyPath -Force | Out-Null
    Set-ItemProperty $PolicyPath 'WebRtcIpHandlingPolicy' 'default_public_interface_only' -Type String -Force
    Set-ItemProperty $PolicyPath 'DnsOverHttpsMode' 'off' -Type String -Force
    Set-ItemProperty $PolicyPath 'ExtensionInstallBlocklist' '*' -Type String -Force
    foreach ($kv in $props.GetEnumerator()) {
        Set-ItemProperty $PolicyPath $kv.Key $kv.Value -Type DWord -Force
    }
    if ($PolicyPath -match 'Microsoft\\Edge') {
        Set-ItemProperty $PolicyPath 'PersonalizationReportingEnabled' 0 -Type DWord -Force
        Set-ItemProperty $PolicyPath 'DiagnosticData' 0 -Type DWord -Force
    }
    OK "Browser privacy: $Label"
}

function Install-BrowserPrivacyPolicies {
    foreach ($b in @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Label = 'Chrome' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Label = 'Edge' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Label = 'Brave' }
    )) {
        try { Set-ChromiumPrivacyPolicies $b.Path $b.Label }
        catch { WARN "Browser privacy failed: $($b.Label)" }
    }
    $ffPolicy = Get-FirefoxPrivacyPolicyJson
    foreach ($ffDir in @('C:\Program Files\Mozilla Firefox\distribution', 'C:\Program Files (x86)\Mozilla Firefox\distribution')) {
        $ffRoot = Split-Path $ffDir -Parent
        if (-not (Test-Path $ffRoot)) { continue }
        try {
            New-Item -Path $ffDir -ItemType Directory -Force | Out-Null
            $ffPolicy | Set-Content (Join-Path $ffDir 'policies.json') -Encoding UTF8 -Force
            OK "Browser privacy: Firefox ($ffRoot)"
        } catch { WARN "Browser privacy failed: Firefox ($ffRoot)" }
    }
}

function Install-WindowsTelemetryReduction {
    foreach ($block in (Get-WindowsPrivacyRegBlocks)) {
        try {
            New-Item -Path $block.Path -Force | Out-Null
            foreach ($kv in $block.Props.GetEnumerator()) {
                Set-ItemProperty $block.Path $kv.Key $kv.Value -Type DWord -Force
            }
        } catch { WARN "Telemetry registry failed: $($block.Path)" }
    }
    foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
        & sc.exe config $svc start= disabled 2>$null | Out-Null
        & sc.exe stop $svc 2>$null | Out-Null
    }
    OK 'Windows privacy: consumer telemetry reduced (not eliminated)'
}

function Install-PrivacyHardening {
    Install-BrowserPrivacyPolicies
    Install-WindowsTelemetryReduction
}

function Write-PrivacyHardeningGuardPs1 {
    $dwords = Get-ChromiumPrivacyDWordProps
    $dwordInit = ($dwords.GetEnumerator() | ForEach-Object { "        $($_.Key)=$($_.Value)" }) -join "`n"
    $ffJson = (Get-FirefoxPrivacyPolicyJson) -replace "'", "''"
    $regInit = (Get-WindowsPrivacyRegBlocks | ForEach-Object {
        $pairs = ($_.Props.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
        "    @{ Path='$($_.Path)'; Props=@{ $pairs }}"
    }) -join ",`n"
    $content = @"
# Privacy Hardening Guard v$WG_KS_VERSION (auto-generated by install.ps1)
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [PRIVACY] `$m" -Encoding UTF8 } catch {} }
function Set-ChromiumPrivacyPolicies([string]`$PolicyPath, [string]`$Label) {
    `$props = @{
$dwordInit
    }
    New-Item -Path `$PolicyPath -Force | Out-Null
    Set-ItemProperty `$PolicyPath 'WebRtcIpHandlingPolicy' 'default_public_interface_only' -Type String -Force
    Set-ItemProperty `$PolicyPath 'DnsOverHttpsMode' 'off' -Type String -Force
    Set-ItemProperty `$PolicyPath 'ExtensionInstallBlocklist' '*' -Type String -Force
    foreach (`$kv in `$props.GetEnumerator()) { Set-ItemProperty `$PolicyPath `$kv.Key `$kv.Value -Type DWord -Force }
    if (`$PolicyPath -match 'Microsoft\\Edge') {
        Set-ItemProperty `$PolicyPath 'PersonalizationReportingEnabled' 0 -Type DWord -Force
        Set-ItemProperty `$PolicyPath 'DiagnosticData' 0 -Type DWord -Force
    }
    Log "`$Label browser privacy applied"
}
foreach (`$b in @(
    @{ Path='HKLM:\SOFTWARE\Policies\Google\Chrome'; Label='Chrome' },
    @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Label='Edge' },
    @{ Path='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Label='Brave' }
)) { try { Set-ChromiumPrivacyPolicies `$b.Path `$b.Label } catch { Log "`$(`$b.Label) failed: `$_" } }
`$ffPolicy = @'
$ffJson
'@
foreach (`$ffDir in @('C:\Program Files\Mozilla Firefox\distribution','C:\Program Files (x86)\Mozilla Firefox\distribution')) {
    `$ffRoot = Split-Path `$ffDir -Parent
    if (-not (Test-Path `$ffRoot)) { continue }
    try {
        New-Item -Path `$ffDir -ItemType Directory -Force | Out-Null
        `$ffPolicy | Set-Content (Join-Path `$ffDir 'policies.json') -Encoding UTF8 -Force
        Log "Firefox privacy applied (`$ffRoot)"
    } catch { Log "Firefox failed: `$_" }
}
`$regBlocks = @(
$regInit
)
foreach (`$block in `$regBlocks) {
    try {
        New-Item -Path `$block.Path -Force | Out-Null
        foreach (`$kv in `$block.Props.GetEnumerator()) { Set-ItemProperty `$block.Path `$kv.Key `$kv.Value -Type DWord -Force }
    } catch { Log "Registry failed: `$(`$block.Path)" }
}
foreach (`$svc in @('DiagTrack','dmwappushservice')) { & sc.exe config `$svc start= disabled 2>`$null | Out-Null; & sc.exe stop `$svc 2>`$null | Out-Null }
Log 'Windows privacy reduction applied'
"@
    $content | Set-Content $PRIVACY_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $PRIVACY_GUARD_PS1 2>$null | Out-Null
}

function Install-ScriptIntegrityVault {
    if (-not (Test-Path 'HKLM:\SOFTWARE\WGKillSwitch')) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    }
    $vaultFiles = @(
        $MONITOR_PS1, $REPAIR_PS1, $PRIVACY_GUARD_PS1, $ANTI_TAMPER_PS1, $WMI_WRAPPER,
        (Join-Path $INSTALL_DIR 'install.ps1')
    )
    foreach ($f in $vaultFiles) {
        if (-not (Test-Path $f)) { continue }
        if ((Get-Item -LiteralPath $f -EA SilentlyContinue) -is [System.IO.DirectoryInfo]) { continue }
        $leaf = Split-Path $f -Leaf
        $hash = (Get-FileHash -Path $f -Algorithm SHA256).Hash
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' "Hash_$leaf" $hash -Force
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'IntegrityVaultDate' (Get-Date -Format 'o') -Force
    if (Get-Command Extend-ScriptIntegrityVaultV14 -EA SilentlyContinue) {
        Extend-ScriptIntegrityVaultV14
    }
    if (Get-Command Extend-ScriptIntegrityVaultV15 -EA SilentlyContinue) {
        Extend-ScriptIntegrityVaultV15
    }
}

function Test-PrivacyChromiumPolicy([string]$VendorPath) {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Policies\$VendorPath" -EA SilentlyContinue
    return ($p -and $p.WebRtcIpHandlingPolicy -eq 'default_public_interface_only' -and
            $p.WebRtcLocalhostCandidateAllowed -eq 0 -and $p.BlockThirdPartyCookies -eq 1 -and
            $p.MetricsReportingEnabled -eq 0 -and $p.DnsOverHttpsMode -eq 'off' -and
            $p.PrivacySandboxAdTopicsEnabled -eq 0 -and $p.QuicAllowed -eq 0)
}

function Test-WindowsTelemetryReduced {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -EA SilentlyContinue
    $wer = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -EA SilentlyContinue
    return ($p -and $p.AllowTelemetry -eq 0 -and $wer -and $wer.Disabled -eq 1)
}

function Test-ScriptIntegrityVault {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($pair in @(
        @{ File = $MONITOR_PS1; Key = 'Hash_monitor.ps1' },
        @{ File = $REPAIR_PS1; Key = 'Hash_repair.ps1' },
        @{ File = $PRIVACY_GUARD_PS1; Key = 'Hash_privacy-hardening-guard.ps1' }
    )) {
        $expected = $reg.$($pair.Key)
        if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
        if (-not (Test-Path $pair.File)) { return $false }
        $actual = (Get-FileHash -Path $pair.File -Algorithm SHA256).Hash
        if ($actual -ne $expected) { return $false }
    }
    return $true
}

function Stop-AllMonitorProcs {
    Get-CimInstance Win32_Process -EA SilentlyContinue |
        Where-Object { (Test-IsMainMonitor $_.CommandLine) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

function Ensure-DelayedAutoStart {
    & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    if (Test-Path $NSSM) { & $NSSM set $WG_SVC_NAME Start SERVICE_DELAYED_AUTO_START 2>$null | Out-Null }
}

function Test-DelayedAutoStart {
    & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    $qc = & sc.exe qc $TUNNEL_SVC 2>$null | Out-String
    return ($qc -match 'DELAYED')
}

function Install-WmiSubscription {
    if (Test-WmiSubscriptionActive) { return $true }
    $cim = Get-ShortCimSession
    $ca = @{ Namespace = 'root\subscription' }
    if ($cim) { $ca['CimSession'] = $cim }
    Get-CimInstance @ca -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ca -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ca -ClassName __FilterToConsumerBinding -Filter (Get-WmiBindFilter) -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    $wmiQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND (TargetInstance.Name='powershell.exe' OR TargetInstance.Name='pwsh.exe')"
    $nca = @{ Namespace = 'root\subscription' }
    if ($cim) { $nca['CimSession'] = $cim }
    try {
        $filter = New-CimInstance @nca -ClassName __EventFilter -Property @{
            Name=$WMI_FILTER; EventNamespace='root\cimv2'; QueryLanguage='WQL'; Query=$wmiQuery
        } -EA Stop
        $consumer = New-CimInstance @nca -ClassName CommandLineEventConsumer -Property @{
            Name=$WMI_CONSUMER
            CommandLineTemplate="powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WMI_WRAPPER`""
        } -EA Stop
        if ($filter -and $consumer) {
            New-CimInstance @nca -ClassName __FilterToConsumerBinding -Property @{
                Filter=[Ref]$filter; Consumer=[Ref]$consumer
            } -EA Stop | Out-Null
            return (Test-WmiSubscriptionActive)
        }
    } catch {
        Write-Info "WMI subscription failed: $($_.Exception.Message)"
    }
    return $false
}

function Remove-KurtarArtifacts {
    foreach ($name in @('kurtar.bat', 'kurtar.ps1', 'kurtar2.ps1', 'resume-after-unbrick.ps1')) {
        $path = Join-Path $INSTALL_DIR $name
        if (Test-Path $path) {
            attrib -H -S $path 2>$null | Out-Null
            Remove-Item $path -Force -EA SilentlyContinue
            Write-Info "Removed legacy rescue script: $name"
        }
    }
    $guardNames = @('kurtar.bat', 'kurtar.ps1', 'kurtar2.ps1', 'resume-after-unbrick.ps1')
    foreach ($name in $guardNames) {
        $gp = Join-Path $GUARD_DIR $name
        if (Test-Path $gp) { Remove-Item $gp -Force -EA SilentlyContinue }
    }
    Remove-TaskFully 'WG-UnbrickResume'
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

function Unlock-GuardDirForWrite {
    New-Item -ItemType Directory -Path $GUARD_DIR -Force -EA SilentlyContinue | Out-Null
    attrib -H -S $GUARD_DIR 2>$null | Out-Null
    Get-ChildItem $GUARD_DIR -File -EA SilentlyContinue | ForEach-Object { attrib -H -S $_.FullName 2>$null | Out-Null }
    icacls $GUARD_DIR /grant "BUILTIN\Administrators:(OI)(CI)F" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /C /Q 2>$null | Out-Null
}

function Write-GuardBackups {
    Unlock-GuardDirForWrite
    $guardFiles = @(
        $MONITOR_PS1, $REPAIR_PS1, $SERVICE_PS1, $WMI_WRAPPER,
        $REBOOT_VERIFY_PS1, $WATCHDOG_PS1, $GPO_SCRIPT, $ANTI_TAMPER_PS1,
        $PRIVACY_GUARD_PS1, $WEBRTC_GUARD_PS1,
        $DNSCRYPT_GUARD_PS1, $TOR_GUARD_PS1, $TOR_MONITOR_PS1, $LEAK_SENTINEL_PS1,
        $DNS_LOCKDOWN_GUARD_PS1, $NETWORK_PRIVACY_GUARD_PS1, $SENSITIVE_MODE_PS1
    )
    foreach ($f in $guardFiles) {
        if (Test-Path $f) {
            $dest = Join-Path $GUARD_DIR (Split-Path $f -Leaf)
            if (Test-Path $dest) {
                icacls $dest /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
                attrib -R -S -H $dest 2>$null | Out-Null
            }
            Copy-Item $f $dest -Force
        }
    }
    foreach ($tn in @($TASK_MONITOR, $TASK_REPAIR, $TASK_REBOOT_VERIFY, $TASK_WATCHDOG)) {
        $xml = Export-TaskXmlSafe $tn
        if ($xml) {
            $xml | Set-Content (Join-Path $GUARD_DIR "$tn.xml") -Encoding UTF8 -Force
        }
    }
    try {
        $gAcl = Get-Acl $GUARD_DIR
        $gAcl.SetAccessRuleProtection($true, $false)
        $gAcl.Access | ForEach-Object { $null = $gAcl.RemoveAccessRule($_) }
        $gAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $gAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -Path $GUARD_DIR -AclObject $gAcl
    } catch {}
    attrib +H +S $GUARD_DIR 2>$null | Out-Null
    Get-ChildItem $GUARD_DIR -File -EA SilentlyContinue | ForEach-Object { attrib +H +S $_.FullName 2>$null | Out-Null }

    if (-not (Test-Path 'HKLM:\SOFTWARE\WGKillSwitch')) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'Version' $WG_KS_VERSION -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GuardDir' $GUARD_DIR -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'StartupLnk' $STARTUP_LNK -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GpoScript' $GPO_SCRIPT -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GpoIni' $GPO_INI -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'NssmPath' $NSSM -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'ServiceScript' $SERVICE_PS1 -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'WmiWrapper' $WMI_WRAPPER -Force
    $runVal = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'RunKeyValue' $runVal -Force
    foreach ($pair in @(
        @{ Name = 'TaskXML'; Task = $TASK_MONITOR },
        @{ Name = 'TaskXMLRepair'; Task = $TASK_REPAIR },
        @{ Name = 'TaskXMLRebootVerify'; Task = $TASK_REBOOT_VERIFY },
        @{ Name = 'TaskXMLWatchdog'; Task = $TASK_WATCHDOG }
    )) {
        $tx = Export-TaskXmlSafe $pair.Task
        if ($tx) {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tx))
            Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' $pair.Name $b64 -Force
        }
    }
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
    if ($ipList.Count -eq 0) {
        @('162.159.192.0/24', '162.159.193.0/24', '162.159.195.0/24', '104.16.0.0/13') |
            ForEach-Object { $ipList.Add($_) }
        Write-Info 'Using WARP IP fallback (hostname endpoint or offline)'
    }
    return ($ipList -join ",")
}

$v14StackPath = Join-Path $PSScriptRoot 'scripts\install-v14-stack.ps1'
if (Test-Path $v14StackPath) { . $v14StackPath } else { Write-Host ' [WARN] install-v14-stack.ps1 missing - v14 features disabled' -ForegroundColor Yellow }
$v15StackPath = Join-Path $PSScriptRoot 'scripts\install-v15-privacy-stack.ps1'
if (Test-Path $v15StackPath) { . $v15StackPath } else { Write-Host ' [WARN] install-v15-privacy-stack.ps1 missing - v15 features disabled' -ForegroundColor Yellow }

# ================================================================
# ADMIN CHECK
# ================================================================
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "`n [!!] Run as Administrator!" -ForegroundColor Red; pause; exit 1
}

if ($PrivacyUpgradeOnly) {
    Write-Step "PRIVACY UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    OK "webrtc-leak-guard.ps1 forwarder written"
    Install-PrivacyHardening
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" }
    else { WARN "Windows telemetry: not confirmed"; $upgWarn++ }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart browsers for policy changes. Cloudflare still sees WARP traffic." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    exit 0
}

if ($DnsLeakUpgradeOnly) {
    Write-Step "DNS LEAK UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    if (-not (Get-Command Invoke-V14DnsLeakStack -EA SilentlyContinue)) {
        Write-Err "v14 stack not loaded"; exit 1
    }
    Invoke-V14DnsLeakStack
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: healthy (127.0.0.1:53)' }
        else { WARN 'dnscrypt-proxy: not healthy yet - check WG-DnscryptProxy service'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "dns leak upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  DNS LEAK UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  DNS LEAK UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart WireGuard tunnel to apply DNS=127.0.0.1" -ForegroundColor Gray
    Write-Host "  Run: .\scripts\leak-audit.ps1 then .\scripts\safe-live-verify.ps1" -ForegroundColor Gray
    if (-not $NoPause) { pause }
    exit 0
}

if ($TorUpgradeOnly) {
    Write-Step "TOR UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    if (-not (Get-Command Invoke-V14TorStack -EA SilentlyContinue)) {
        Write-Err "v14 stack not loaded"; exit 1
    }
    Invoke-V14TorStack
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    if (Get-Command Test-V14TorPresent -EA SilentlyContinue) {
        if (Test-V14TorPresent) { OK "Tor Browser: installed" }
        else { WARN 'Tor Browser: not found - install manually from torproject.org'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "tor upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  TOR UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  TOR UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Start Tor Browser for sensitive browsing only. Cloudflare still sees WARP entry." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    exit 0
}

if ($FullPrivacyUpgrade) {
    Write-Step "FULL PRIVACY UPGRADE (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    Install-PrivacyHardening
    if (Get-Command Invoke-V14FullPrivacyStack -EA SilentlyContinue) {
        Invoke-V14FullPrivacyStack
    } else { WARN 'v14 stack not loaded - dnscrypt/Tor/leak-sentinel skipped' }
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" }
    else { WARN "Windows telemetry: not confirmed"; $upgWarn++ }
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK "dnscrypt-proxy: healthy" }
        else { WARN "dnscrypt-proxy: not healthy"; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "full privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  FULL PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  FULL PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart WG tunnel + browsers. Tor = sensitive use only." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    exit 0
}

if ($StrongPrivacyUpgrade) {
    Write-Step "STRONG PRIVACY UPGRADE (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    Install-PrivacyHardening
    if (Get-Command Invoke-V15StrongPrivacyStack -EA SilentlyContinue) {
        Invoke-V15StrongPrivacyStack
    } else { Write-Err 'v15 stack not loaded'; exit 1 }
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: healthy' }
        else { WARN 'dnscrypt-proxy: not healthy'; $upgWarn++ }
    }
    if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
        if (Test-V15DnsLockdownHealthy) { OK 'System DNS lock: all adapters 127.0.0.1' }
        else { WARN 'System DNS lock: incomplete'; $upgWarn++ }
    }
    if (Get-Command Test-V15NetworkPrivacyHealthy -EA SilentlyContinue) {
        if (Test-V15NetworkPrivacyHealthy) { OK 'Network privacy: LLMNR off' }
        else { WARN 'Network privacy: LLMNR still enabled'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "strong privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  STRONG PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  STRONG PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Run: .\scripts\privacy-audit.ps1 then .\scripts\safe-live-verify.ps1" -ForegroundColor Gray
    Write-Host "  Sensitive browsing: desktop Hassas-Tarama.lnk or sensitive-mode.ps1" -ForegroundColor Gray
    if (-not $NoPause) { pause }
    exit 0
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
$monitorKsVersion  = $WG_KS_VERSION

$monitorContent = @"
# WireGuard Kill Switch - Monitor v$monitorKsVersion (auto-generated by install.ps1)
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
`$PID_FILE = 'C:\WireGuard\monitor.pid'

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

function Test-TunnelAdapterUp {
    for (`$try = 0; `$try -lt 3; `$try++) {
        try {
            foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
                if (`$a.Status -ne 'Up') { continue }
                if (`$a.Name -eq `$TUNNEL_NAME -or `$a.InterfaceDescription -match 'WireGuard') { return `$true }
            }
        } catch {}
        if (`$try -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    return `$false
}

function Test-TunnelRunning {
    `$svcUp = `$false
    try {
        `$svc = Get-Service -Name `$TUNNEL_SVC -ErrorAction SilentlyContinue
        if (`$svc -and `$svc.Status -eq 'Running') { `$svcUp = `$true }
    } catch {}
    if (-not `$svcUp) { `$svcUp = [bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match "RUNNING") }
    if (-not `$svcUp) { return `$false }
    return (Test-TunnelAdapterUp)
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

function Test-BootGrace {
    try {
        `$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name BootGraceUntil -EA SilentlyContinue
        if (`$reg.BootGraceUntil -and (Get-Date) -lt [datetime]`$reg.BootGraceUntil) { return `$true }
    } catch {}
    return `$false
}

function Test-BlockAllowed {
    if (Test-InstallInProgress -or Test-UnbrickActive -or Test-BootGrace) { return `$false }
    return `$true
}

function Enable-DnsLeakProtection {
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=yes 2>`$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=yes 2>`$null | Out-Null
}

function Disable-DnsLeakProtection {
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=no 2>`$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=no 2>`$null | Out-Null
}

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return `$true }
    try {
        `$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
        return (`$reg.InstallInProgress -eq 1)
    } catch { return `$false }
}

function Test-UnbrickActive {
    try {
        `$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name UnbrickUntil -EA SilentlyContinue
        if (`$reg.UnbrickUntil -and (Get-Date) -lt [datetime]`$reg.UnbrickUntil) { return `$true }
    } catch {}
    return `$false
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
    if (-not (Test-BlockAllowed)) {
        Log "Block deferred (install/unbrick/boot-grace) - internet stays open"
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
    Enable-DnsLeakProtection
    Log "BLOCK active (server `$(`$script:SERVER_IP) allowed)"
}

function Test-BlockRulePresent {
    `$o = netsh advfirewall firewall show rule name="KS-Block-WiFi-Out" 2>`$null | Out-String
    return (`$o -match 'Enabled:\s+Yes')
}

function Disable-Block {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          | Out-Null
    Disable-DnsLeakProtection
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
        if (Test-TunnelRunning) { return `$true }
        `$mux = New-Object System.Threading.Mutex(`$false, 'Global\WGTunnelInstallMutex')
        if (-not (Wait-NamedMutex `$mux 90000)) {
            Log "TunnelReinstall: mutex timeout"
            return (Test-TunnelRunning)
        }
        if (Test-TunnelRunning) { return `$true }
        Get-Process -Name "wireguard" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        `$wgSvcPid = (Get-CimInstance Win32_Service -Filter "Name='`$TUNNEL_SVC'" -EA SilentlyContinue).ProcessId
        if (`$wgSvcPid -and `$wgSvcPid -gt 0) { Stop-Process -Id `$wgSvcPid -Force -EA SilentlyContinue }
        Start-Sleep -Seconds 2
        for (`$attempt = 1; `$attempt -le 2; `$attempt++) {
            & `$WG_EXE /uninstalltunnelservice `$TUNNEL_NAME 2>`$null | Out-Null
            Start-Sleep -Seconds 4
            & `$WG_EXE /installtunnelservice `$CONFIG 2>`$null | Out-Null
            & sc.exe start `$TUNNEL_SVC 2>`$null | Out-Null
            `$waited = 0
            while (`$waited -lt 30 -and -not (Test-TunnelRunning)) {
                Start-Sleep -Seconds 3; `$waited += 3
            }
            if (Test-TunnelRunning) { return `$true }
            Log "TunnelReinstall: attempt `$attempt failed (waited `${waited}s)"
        }
        return `$false
    } finally {
        if (`$mux) { try { `$mux.ReleaseMutex() } catch {} }
    }
}

function Invoke-EmergencyUnbrick {
    Log "EMERGENCY UNBRICK: deep gentle unbrick (protection stays installed)"
    Disable-Block
    Disable-DnsLeakProtection
    Clear-DnsClientCache -EA SilentlyContinue
    Remove-Item 'C:\WireGuard\install.inprogress' -Force -EA SilentlyContinue
    New-Item -Path `$REG_KEY -Force | Out-Null
    Set-ItemProperty `$REG_KEY 'UnbrickUntil' (Get-Date).AddMinutes(10).ToString('o') -Force
    Remove-ItemProperty `$REG_KEY 'InstallInProgress' -EA SilentlyContinue
    Set-ItemProperty `$REG_KEY 'BootGraceUntil' (Get-Date).AddSeconds(180).ToString('o') -Force
    return `$true
}

function Remove-OtherMonitorProcs {
    foreach (`$shell in @('powershell', 'pwsh')) {
        Get-Process `$shell -EA SilentlyContinue | ForEach-Object {
            if (`$_.Id -eq `$PID) { return }
            try {
                `$c = (Get-CimInstance Win32_Process -Filter "ProcessId=`$(`$_.Id)" -EA Stop).CommandLine
                if (`$c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') {
                    Stop-Process -Id `$_.Id -Force -EA SilentlyContinue
                    Log "Duplicate monitor killed (PID: `$(`$_.Id))"
                }
            } catch {}
        }
    }
}

`$mainMux = `$null
try {
    `$mainMux = New-Object System.Threading.Mutex(`$false, 'Global\WGMainMonitorMutex')
    if (-not (Wait-NamedMutex `$mainMux 5000)) { exit 0 }
    if (Test-Path `$PID_FILE) {
        try {
            `$oldPid = [int](Get-Content `$PID_FILE -EA Stop | Select-Object -First 1)
            if (`$oldPid -gt 0 -and `$oldPid -ne `$PID) {
                try {
                    `$oldCmd = (Get-CimInstance Win32_Process -Filter "ProcessId=`$oldPid" -EA Stop).CommandLine
                    if (`$oldCmd -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { exit 0 }
                } catch {}
                Remove-Item `$PID_FILE -Force -EA SilentlyContinue
            }
        } catch { Remove-Item `$PID_FILE -Force -EA SilentlyContinue }
    }
    Set-Content `$PID_FILE `$PID -Force -EA SilentlyContinue
    Remove-OtherMonitorProcs
} catch [System.UnauthorizedAccessException] {
    Write-Emergency "FATAL: monitor mutex access denied"
    exit 1
} catch {
    Write-Emergency "FATAL: monitor mutex error: `$_"
    exit 1
}

Log "=== Monitor started (v$monitorKsVersion) ==="

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
    `$graceEnd = `$bootTime.AddSeconds(180)
    if ((Get-Date) -lt `$graceEnd) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'BootGraceUntil' `$graceEnd.ToString('o') -Force
        Log "Fresh boot - BootGrace until `$(`$graceEnd.ToString('HH:mm:ss')) (no block)"
        Start-Sleep -Seconds 15
    }
} catch {}

`$bootWait = 0
while (`$bootWait -lt 90 -and -not (Test-TunnelRunning)) {
    Start-Sleep -Seconds 3; `$bootWait += 3
}

if (Test-SafeToOpen -or Test-BootGrace -or Test-UnbrickActive) {
    `$state = 'open'
    Clear-DnsClientCache -EA SilentlyContinue
    Disable-Block
    if (Test-SafeToOpen) { Log "Startup: healthy (waited `${bootWait}s), internet open" }
    else { Log "Startup: fail-open hold (boot-grace/unbrick), internet open" }
} else {
    `$state = 'open'
    Disable-Block
    if (Test-TunnelRunning) {
        Log "Startup: zombie tunnel suspected (waited `${bootWait}s) - fail-open until debounce"
    } else {
        Log "Startup: tunnel down (waited `${bootWait}s) - fail-open until debounce"
    }
}

`$startupRecovery = `$false
`$wasOpen = (`$state -eq 'open')
`$script:dedupeTick = 0
`$script:tamperTick = 0
`$script:tunnelLostStreak = 0
`$script:zombieStreak = 0

while (`$true) {
    if (-not `$startupRecovery) { Start-Sleep -Seconds 2 }
    `$startupRecovery = `$false
    if (Test-UnbrickActive -or Test-BootGrace) {
        Disable-Block
        Disable-DnsLeakProtection
        Clear-DnsClientCache -EA SilentlyContinue
        if (`$state -ne 'open') {
            Log "Fail-open hold (unbrick/boot-grace) - internet open"
            `$state = 'open'; `$wasOpen = `$true
        }
        Start-Sleep -Seconds 30
        continue
    }
    Ensure-ServerRule
    `$script:dedupeTick++
    if (`$script:dedupeTick -ge 15) {
        `$script:dedupeTick = 0
        Remove-OtherMonitorProcs
    }
    `$script:tamperTick++
    if (`$script:tamperTick -ge 30) {
        `$script:tamperTick = 0
        `$at = 'C:\WireGuard\anti-tamper.ps1'
        if (Test-Path `$at) {
            Start-Process -FilePath (Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList @('-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',`$at,'-Quick') `
                -WindowStyle Hidden
        }
    }

    if (`$wasOpen -and -not (Test-TunnelRunning)) {
        `$script:tunnelLostStreak++
        if (`$script:tunnelLostStreak -ge 5) {
            Log "Tunnel lost (confirmed 5x/10s) - block"
            Enable-Block; `$state = 'blocked'; `$wasOpen = `$false
            `$script:tunnelLostStreak = 0
        }
    } elseif (Test-TunnelRunning) { `$script:tunnelLostStreak = 0 }

    if (Test-SafeToOpen) {
        `$script:zombieStreak = 0
        if (`$state -ne 'open') {
            Clear-DnsClientCache -EA SilentlyContinue
            Disable-Block
            `$state = 'open'
            `$wasOpen = `$true
            Log "Healthy: tunnel + internet OK"
        } else { `$wasOpen = `$true }
        continue
    }

    if (Test-TunnelRunning) {
        `$script:zombieStreak++
        if (`$script:zombieStreak -lt 15) {
            if (`$script:zombieStreak -eq 1) { Log "Zombie tunnel suspected - waiting 15x before block (fail-open)" }
            `$wasOpen = `$false
            Start-Sleep -Seconds 2
            continue
        }
        Log "Zombie tunnel confirmed 15x/30s - block"
    } else {
        `$script:zombieStreak = 0
        Log "Tunnel down - block"
    }
    `$wasOpen = `$false

    if (-not (Test-BlockAllowed)) {
        Log "Unhealthy but block deferred (fail-open hold)"
        continue
    }
    if (`$state -ne 'blocked') {
        Log "WARNING: Unhealthy - activating block after debounce"
    } elseif (-not (Test-BlockRulePresent)) {
        Log "WARNING: Block rules tampered/missing while unhealthy - re-applying"
    }
    Enable-Block
    `$state = 'blocked'
    `$script:zombieStreak = 0

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
                    Log "Attempt `$i - tunnel up but no internet after 30s, DNS flush + wait (no re-block)"
                    Clear-DnsClientCache -EA SilentlyContinue
                    Start-Sleep -Seconds 10
                }
            } else {
                Log "Attempt `$i - tunnel did not start"
                Start-Sleep -Seconds 5
            }
        }
        if (-not `$success) {
            Log "CRITICAL: 5 attempts failed (total: `$totalAttempts) - holding 60s then retrying (no re-block)"
            if (`$totalAttempts -ge 5 -and (`$totalAttempts % 5) -eq 0) {
                if (Invoke-EmergencyUnbrick) {
                    `$state = 'open'; `$wasOpen = `$true; `$success = `$true; break
                }
            } elseif (`$totalAttempts -ge 15 -and (`$totalAttempts % 15) -eq 0) {
                Log "STUCK: watchdog will deep-unbrick automatically"
            }
            `$waited = 0
            while (`$waited -lt 60) {
                Start-Sleep -Seconds 3; `$waited += 3
                if (Test-SafeToOpen) {
                    Log "Healthy during 60s hold (tunnel + internet verified)"
                    Clear-DnsClientCache -EA SilentlyContinue
                    Disable-Block; `$state = 'open'; `$wasOpen = `$true; `$success = `$true; break
                }
            }
            if (`$success) { break }
            Log "60s hold done - retrying..."
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
$repairKsVersion = $WG_KS_VERSION
$repairContent = "# WG Repair Script v$repairKsVersion (auto-generated by install.ps1)`r`n" + @'
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

function Test-TunnelAdapterUp {
    for ($try = 0; $try -lt 3; $try++) {
        try {
            foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
                if ($a.Status -ne 'Up') { continue }
                if ($a.Name -eq $TUNNEL_NAME -or $a.InterfaceDescription -match 'WireGuard') { return $true }
            }
        } catch {}
        if ($try -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Test-TunnelRunning {
    $svcUp = $false
    try {
        $svc = Get-Service -Name $TUNNEL_SVC -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { $svcUp = $true }
    } catch {}
    if (-not $svcUp) { $svcUp = [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match "RUNNING") }
    if (-not $svcUp) { return $false }
    return (Test-TunnelAdapterUp)
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

function Test-BootGrace {
    try {
        $reg = Get-ItemProperty $REG_KEY -Name BootGraceUntil -EA SilentlyContinue
        if ($reg.BootGraceUntil -and (Get-Date) -lt [datetime]$reg.BootGraceUntil) { return $true }
    } catch {}
    return $false
}

function Test-BlockAllowed {
    if (Test-InstallInProgress -or Test-UnbrickActive -or Test-BootGrace) { return $false }
    return $true
}

function Enable-DnsLeakProtection {
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=yes 2>$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=yes 2>$null | Out-Null
}

function Disable-DnsLeakProtection {
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=no 2>$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=no 2>$null | Out-Null
}

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return $true }
    try {
        $reg = Get-ItemProperty $REG_KEY -EA SilentlyContinue
        return ($reg.InstallInProgress -eq 1)
    } catch { return $false }
}

function Test-UnbrickActive {
    try {
        $reg = Get-ItemProperty $REG_KEY -Name UnbrickUntil -EA SilentlyContinue
        if ($reg.UnbrickUntil -and (Get-Date) -lt [datetime]$reg.UnbrickUntil) { return $true }
    } catch {}
    return $false
}

function Test-FwRuleEnabled([string]$name) {
    $o = netsh advfirewall firewall show rule name=$name 2>$null | Out-String
    return ($o -match 'Enabled:\s+Yes')
}

function Test-FwRuleExists([string]$name) {
    $o = netsh advfirewall firewall show rule name=$name 2>$null | Out-String
    return ($o -notmatch 'No rules match')
}

function Get-FwRuleCount([string]$name) {
    $o = netsh advfirewall firewall show rule name=$name 2>$null | Out-String
    if ($o -match 'No rules match') { return 0 }
    return ([regex]::Matches($o, 'Rule Name:')).Count
}

function Test-BlockRulePresent {
    $o = netsh advfirewall firewall show rule name="KS-Block-WiFi-Out" 2>$null | Out-String
    return ($o -match 'Enabled:\s+Yes')
}

function Repair-ConfigIntegrity {
    if (-not (Test-Path $CONFIG)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($CONFIG)
        if ($raw[0] -eq [char]0xFEFF -or $raw -match '::') {
            Log "Config integrity: fixing BOM/IPv6"
            $out = [System.Collections.Generic.List[string]]::new()
            foreach ($line in ($raw -split "`r?`n")) {
                if ($line -match '^\s*Address\s*=') {
                    $p = ($line -split '=',2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                    if ($p) { $out.Add("Address = $($p -join ', ')") }
                } elseif ($line -match '^\s*DNS\s*=') {
                    $p = ($line -split '=',2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                    if ($p) { $out.Add("DNS = $($p -join ', ')") }
                } elseif ($line -match '^\s*AllowedIPs\s*=') {
                    $p = ($line -split '=',2)[1].Trim() -split '\s*,\s*' | Where-Object { $_ -and $_ -notmatch ':' }
                    if ($p) { $out.Add("AllowedIPs = $($p -join ', ')") }
                } elseif ($line.Trim()) { $out.Add($line.TrimEnd()) }
            }
            $enc = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllLines($CONFIG, $out, $enc)
        }
    } catch {}
}

function Repair-EssentialFirewall {
    $serverIp = Get-RepairServerIP
    $alwaysOn = @(
        @{ N='KS-DNS-Allow';     A='netsh advfirewall firewall add rule name="KS-DNS-Allow" dir=out action=allow protocol=UDP remoteip=1.1.1.1,1.0.0.1 remoteport=53 enable=yes' },
        @{ N='KS-WireGuard-EXE'; A='netsh advfirewall firewall add rule name="KS-WireGuard-EXE" dir=out action=allow program="C:\Program Files\WireGuard\wireguard.exe" enable=yes' },
        @{ N='KS-Dnscrypt-EXE'; A='netsh advfirewall firewall add rule name="KS-Dnscrypt-EXE" dir=out action=allow program="C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.exe" enable=yes' },
        @{ N='KS-WARP-Server-Out'; A="netsh advfirewall firewall add rule name=`"KS-WARP-Server-Out`" dir=out action=allow protocol=UDP remoteip=$serverIp remoteport=$SERVER_PORT enable=yes" }
    )
    $existsOnly = @(
        @{ N='KS-DNS-Block';     A='netsh advfirewall firewall add rule name="KS-DNS-Block" dir=out action=block protocol=UDP remoteport=53 enable=no' },
        @{ N='KS-DNS-Block-TCP'; A='netsh advfirewall firewall add rule name="KS-DNS-Block-TCP" dir=out action=block protocol=TCP remoteport=53 enable=no' }
    )
    foreach ($e in $alwaysOn) {
        $need = (-not (Test-FwRuleExists $e.N)) -or (-not (Test-FwRuleEnabled $e.N)) -or ((Get-FwRuleCount $e.N) -gt 1)
        if ($need) {
            netsh advfirewall firewall delete rule name=$e.N 2>$null | Out-Null
            Invoke-Expression $e.A | Out-Null
            Log "Firewall restored: $($e.N)"
        }
    }
    foreach ($e in $existsOnly) {
        if (-not (Test-FwRuleExists $e.N) -or ((Get-FwRuleCount $e.N) -gt 1)) {
            netsh advfirewall firewall delete rule name=$e.N 2>$null | Out-Null
            Invoke-Expression $e.A | Out-Null
            Log "Firewall ensured: $($e.N)"
        }
    }
    if (Test-SafeToOpen) { Disable-DnsLeakProtection }
    elseif (Test-BlockRulePresent) { Enable-DnsLeakProtection }
}

function Test-NetworkChanged {
    try {
        $fp = ((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Sort-Object RouteMetric |
                Select-Object InterfaceAlias, NextHop, RouteMetric | Out-String).Trim())
        $reg = Get-ItemProperty $REG_KEY -Name NetworkFingerprint -EA SilentlyContinue
        $prev = [string]$reg.NetworkFingerprint
        if ($prev -and $prev -ne $fp) {
            Set-ItemProperty $REG_KEY NetworkFingerprint $fp -Force -EA SilentlyContinue
            return $true
        }
        Set-ItemProperty $REG_KEY NetworkFingerprint $fp -Force -EA SilentlyContinue
    } catch {}
    return $false
}

function Get-RepairServerIP {
    try {
        $reg = Get-ItemProperty $REG_KEY -EA SilentlyContinue
        if ($reg.ServerIP) { return [string]$reg.ServerIP }
    } catch {}
    return '162.159.192.0/24,104.16.0.0/13'
}

function Disable-Block {
    netsh advfirewall firewall delete rule name="KS-Block-WiFi-Out"         2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-Ethernet-Out"     2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-RemoteAccess-Out" 2>$null | Out-Null
    netsh advfirewall firewall delete rule name="KS-Block-PPP-Out"          2>$null | Out-Null
    Disable-DnsLeakProtection
}

function Sync-KillSwitchState {
    if (-not (Test-BlockAllowed)) {
        Disable-Block
        Disable-DnsLeakProtection
        Log "Sync: fail-open hold - internet open"
        return
    }
    if (Test-SafeToOpen) {
        Disable-Block
        Disable-DnsLeakProtection
        Log "Sync: healthy - internet open"
    } else {
        Log "Sync: unhealthy - monitor-only block authority (repair will not block)"
    }
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

function Test-MainMonitorActive {
    $pidFile = 'C:\WireGuard\monitor.pid'
    if (Test-Path $pidFile) {
        try {
            $mpid = [int](Get-Content $pidFile -EA Stop | Select-Object -First 1)
            if ($mpid -gt 0) {
                try {
                    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$mpid" -EA Stop).CommandLine
                    if ($cmd -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { return $true }
                } catch {}
            }
        } catch {}
    }
    return ((GetMonitorShellProcs | Measure-Object).Count -gt 0)
}

function Try-ReinstallTunnel {
    $mux = $null
    try {
        if (Test-TunnelRunning) { return $true }
        $mux = New-Object System.Threading.Mutex($false, 'Global\WGTunnelInstallMutex')
        if (-not (Wait-NamedMutex $mux 90000)) {
            Log "TunnelReinstall: mutex timeout"
            return (Test-TunnelRunning)
        }
        if (Test-TunnelRunning) { return $true }
        Get-Process -Name "wireguard" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        $wgSvcPid = (Get-CimInstance Win32_Service -Filter "Name='$TUNNEL_SVC'" -EA SilentlyContinue).ProcessId
        if ($wgSvcPid -and $wgSvcPid -gt 0) { Stop-Process -Id $wgSvcPid -Force -EA SilentlyContinue }
        Start-Sleep -Seconds 2
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
            Start-Sleep -Seconds 4
            & $WG_EXE /installtunnelservice $CONFIG 2>$null | Out-Null
            & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
            $waited = 0
            while ($waited -lt 30 -and -not (Test-TunnelRunning)) {
                Start-Sleep -Seconds 3; $waited += 3
            }
            if (Test-TunnelRunning) { return $true }
            Log "TunnelReinstall: attempt $attempt failed (waited ${waited}s)"
        }
        return $false
    } finally {
        if ($mux) { try { $mux.ReleaseMutex() } catch {} }
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

    if (Test-UnbrickActive -or Test-BootGrace) {
        Disable-Block
        Disable-DnsLeakProtection
        Clear-DnsClientCache -EA SilentlyContinue
        Log "Fail-open hold - repair skipped (no re-block)"
        exit 0
    }

    $atScript = 'C:\WireGuard\anti-tamper.ps1'
    if (Test-Path $atScript) { & $atScript -NoChainRepair }

    $wgPriv = 'C:\WireGuard\privacy-hardening-guard.ps1'
    if (Test-Path $wgPriv) { & $wgPriv }
    else {
        $wgRtc = 'C:\WireGuard\webrtc-leak-guard.ps1'
        if (Test-Path $wgRtc) { & $wgRtc }
    }
    $wgDns = 'C:\WireGuard\dnscrypt-guard.ps1'
    if (Test-Path $wgDns) { & $wgDns }
    $wgDnsLock = 'C:\WireGuard\dns-lockdown-guard.ps1'
    if (Test-Path $wgDnsLock) { & $wgDnsLock }
    $wgNetPriv = 'C:\WireGuard\network-privacy-guard.ps1'
    if (Test-Path $wgNetPriv) { & $wgNetPriv }
    $wgTor = 'C:\WireGuard\tor-hardening-guard.ps1'
    if (Test-Path $wgTor) { & $wgTor }
    $wgTorMon = 'C:\WireGuard\tor-connectivity-monitor.ps1'
    if (Test-Path $wgTorMon) { & $wgTorMon }
    $wgLeak = 'C:\WireGuard\leak-sentinel.ps1'
    if (Test-Path $wgLeak) { & $wgLeak }

    Repair-ConfigIntegrity
    Repair-EssentialFirewall
    if (Test-NetworkChanged) {
        Log "Network change detected (modem/route) - syncing"
        Clear-DnsClientCache -EA SilentlyContinue
        & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    }

    Sync-KillSwitchState

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
        if (Test-MainMonitorActive) {
            Log "Tunnel down - monitor active, deferring reinstall (avoid race)"
        } elseif ((Test-Path $WG_EXE) -and (Test-Path $CONFIG)) {
            Log "Tunnel not running - reinstalling (mutex)"
            if (Try-ReinstallTunnel) {
                Log "Tunnel reinstalled OK"
                & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
            } else {
                Log "CRITICAL: Tunnel could not be reinstalled"
            }
        }
    } else {
        & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    }

    if ((& sc.exe query $WG_SVC_NAME 2>$null) -notmatch "RUNNING") {
        Log "WGKillSwitchSvc not running - starting"
        & sc.exe start $WG_SVC_NAME 2>$null | Out-Null; Start-Sleep 5
        if ((& sc.exe query $WG_SVC_NAME 2>$null) -match "RUNNING") { Log "WGKillSwitchSvc started" }
        else { Log "CRITICAL: WGKillSwitchSvc could not start" }
    }

    Start-Sleep -Milliseconds 500
    $procs = GetMonitorShellProcs
    if (($procs | Measure-Object).Count -gt 1) {
        $procs | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object {
            Stop-Process -Id $_.Id -Force -EA SilentlyContinue
            Log "Duplicate main monitor killed (PID: $($_.Id))"
        }
        Start-Sleep 2
        $procs = GetMonitorShellProcs
    }
    if (-not $procs) {
        Log "Main monitor missing - single direct start"
        Start-HiddenScript $MONITOR
        Log "Monitor start requested"
    }

    Sync-KillSwitchState
} finally {
    Remove-Item $LOCK -Force -EA SilentlyContinue
}
'@
$repairContent | Set-Content $REPAIR_PS1 -Encoding UTF8 -Force
OK "repair.ps1 written"

# ================================================================
Write-Step "STEP 8b - INTERNET WATCHDOG SCRIPT"
# ================================================================
$watchdogKsVersion = $WG_KS_VERSION
$watchdogContent = @"
# Internet Watchdog v$watchdogKsVersion (graduated fail-open - never tears down protection)
`$LOG = '$LOG'
`$REG_KEY = 'HKLM:\SOFTWARE\WGKillSwitch'
`$INSTALL_LOCK = '$INSTALL_LOCK'
`$STUCK_FILE = 'C:\WireGuard\watchdog-stuck.count'
`$TUNNEL_SVC = '$TUNNEL_SVC'
`$ErrorActionPreference = 'Continue'

function Log([string]`$m) {
    Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [WATCHDOG] `$m" -Encoding UTF8 -EA SilentlyContinue
}
function Test-HoldActive {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -EA SilentlyContinue
        if (`$reg.UnbrickUntil -and (Get-Date) -lt [datetime]`$reg.UnbrickUntil) { return `$true }
        if (`$reg.BootGraceUntil -and (Get-Date) -lt [datetime]`$reg.BootGraceUntil) { return `$true }
    } catch {}
    return `$false
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
function Test-TunnelAdapterUp {
    for (`$try = 0; `$try -lt 3; `$try++) {
        try {
            foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
                if (`$a.Status -ne 'Up') { continue }
                if (`$a.InterfaceDescription -match 'WireGuard') { return `$true }
            }
        } catch {}
        if (`$try -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    return `$false
}
function Test-TunnelRunning {
    if (-not ([bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match 'RUNNING'))) { return `$false }
    return (Test-TunnelAdapterUp)
}
function Test-BlockRulePresent {
    `$o = netsh advfirewall firewall show rule name="KS-Block-WiFi-Out" 2>`$null | Out-String
    return (`$o -match 'Enabled:\s+Yes')
}
function Invoke-GentleUnbrick {
    foreach (`$r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        netsh advfirewall firewall delete rule name="`$r" 2>`$null | Out-Null
    }
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=no 2>`$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=no 2>`$null | Out-Null
    Clear-DnsClientCache -EA SilentlyContinue
}
function Invoke-DeepUnbrick {
    Invoke-GentleUnbrick
    Remove-Item `$INSTALL_LOCK -Force -EA SilentlyContinue
    New-Item -Path `$REG_KEY -Force | Out-Null
    Set-ItemProperty `$REG_KEY 'UnbrickUntil' (Get-Date).AddMinutes(10).ToString('o') -Force
    Remove-ItemProperty `$REG_KEY 'InstallInProgress' -EA SilentlyContinue
    Set-ItemProperty `$REG_KEY 'BootGraceUntil' (Get-Date).AddSeconds(180).ToString('o') -Force
}

if (Test-HoldActive) { exit 0 }

`$tcpOK = Test-Internet
`$tunnel = Test-TunnelRunning
`$healthy = `$tunnel -and `$tcpOK

if (`$healthy) {
    if (Test-BlockRulePresent) {
        Log "Healthy but blocks on - gentle unbrick"
        Invoke-GentleUnbrick
    }
    Set-Content `$STUCK_FILE '0' -Force -EA SilentlyContinue
    exit 0
}

`$count = 0
if (Test-Path `$STUCK_FILE) {
    try { `$count = [int](Get-Content `$STUCK_FILE -EA Stop | Select-Object -First 1) } catch {}
}
`$count++
Set-Content `$STUCK_FILE "`$count" -Force -EA SilentlyContinue

if (`$count -le 2) {
    Log "Unhealthy (tunnel=`$tunnel tcp=`$tcpOK) streak=`$count - gentle unbrick"
    Invoke-GentleUnbrick
    exit 0
}

if (`$count -ge 5) {
    Log "Unhealthy streak=`$count - deep gentle unbrick (tasks/service stay on)"
    Invoke-DeepUnbrick
    Set-Content `$STUCK_FILE '0' -Force -EA SilentlyContinue
} else {
    Log "Unhealthy streak=`$count - gentle unbrick (deep at 5)"
}
"@
Set-Content $WATCHDOG_PS1 $watchdogContent -Encoding UTF8 -Force
OK "internet-watchdog.ps1 written"

# ================================================================
Write-Step "STEP 9 - WMI WRAPPER"
# ================================================================
@'
# WMI Repair Wrapper v12.0 (auto-generated by install.ps1)
$LOG    = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\repair.ps1'
$WMI_COOLDOWN = 'C:\WireGuard\wmi-cooldown.txt'
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
function WmiCooldownActive {
    if (-not (Test-Path $WMI_COOLDOWN)) { return $false }
    try {
        $t = [datetime](Get-Content $WMI_COOLDOWN -EA Stop | Select-Object -First 1)
        return ((Get-Date) -lt $t.AddSeconds(45))
    } catch { return $false }
}
if (WmiCooldownActive) { Log "WMI cooldown active - skip"; exit 0 }
Set-Content $WMI_COOLDOWN (Get-Date -Format 'o') -Force -EA SilentlyContinue
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
$svcKsVersion = $WG_KS_VERSION
"# WGKillSwitchSvc wrapper v$svcKsVersion (auto-generated by install.ps1)`r`n" + @'
$LOG       = 'C:\WireGuard\killswitch.log'
$REPAIR    = 'C:\WireGuard\repair.ps1'
$COOLDOWN  = 'C:\WireGuard\repair-cooldown.txt'
$REG_KEY   = 'HKLM:\SOFTWARE\WGKillSwitch'
'@ + "`r`n" + "`$TUNNEL_SVC = '$TUNNEL_SVC'`r`n" + @'
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
function Test-HoldActive {
    try {
        $reg = Get-ItemProperty $REG_KEY -EA SilentlyContinue
        if ($reg.UnbrickUntil -and (Get-Date) -lt [datetime]$reg.UnbrickUntil) { return $true }
        if ($reg.BootGraceUntil -and (Get-Date) -lt [datetime]$reg.BootGraceUntil) { return $true }
    } catch {}
    return $false
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
'@ + "`r`nLog `"WGKillSwitchSvc started (v$svcKsVersion)`"`r`n" + @'
Start-Sleep -Seconds 15
if (-not (Test-HoldActive)) { TriggerRepair "Initial repair triggered" }
else { Log "Fail-open hold at startup - repair deferred" }
while ($true) {
    if (Test-HoldActive) {
        Start-Sleep -Seconds 60
        continue
    }
    $proc = GetMonitorShellProcs
    $tunnelDown = (( & sc.exe query $TUNNEL_SVC 2>$null) -notmatch 'RUNNING')
    if ($tunnelDown -and $proc) {
        Log "Monitor active - tunnel recovery delegated (no repair spawn)"
        Start-Sleep -Seconds 60
    } elseif ($tunnelDown) {
        TriggerRepair "Tunnel down - urgent repair (immediate)"
        Start-Sleep -Seconds 5
    } elseif (-not $proc) {
        TriggerRepair "Main monitor missing - repair triggered"
        Start-Sleep -Seconds 10
    } else {
        $atPath = 'C:\WireGuard\anti-tamper.ps1'
        if (Test-Path $atPath) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList @('-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$atPath,'-Quick') `
                -WindowStyle Hidden
        }
        Start-Sleep -Seconds 60
    }
}
'@ | Set-Content $SERVICE_PS1 -Encoding UTF8 -Force
OK "service-monitor.ps1 written"

# ================================================================
Write-Step "STEP 10b - ANTI-TAMPER GUARD SCRIPT"
# ================================================================
$atRepair = $REPAIR_PS1
$atMonitor = $MONITOR_PS1
$atService = $SERVICE_PS1
$atWmi = $WMI_WRAPPER
$atReboot = $REBOOT_VERIFY_PS1
$atGpo = $GPO_SCRIPT
$atGpoIni = $GPO_INI
$atStartup = $STARTUP_LNK
$atGuard = $GUARD_DIR
$atNssm = $NSSM
$atSvcName = $WG_SVC_NAME
$atTunnelSvc = $TUNNEL_SVC
@"
# WG Anti-Tamper Guard v12.0 (auto-generated by install.ps1)
# Silently restores deleted/disabled protection layers from guard vault + registry.
param([switch]`$Quick, [switch]`$NoChainRepair)
`$ErrorActionPreference = 'SilentlyContinue'
`$REG_KEY = 'HKLM:\SOFTWARE\WGKillSwitch'
`$LOG = 'C:\WireGuard\killswitch.log'
`$GUARD_DIR = '$atGuard'
`$REPAIR = '$atRepair'
`$MONITOR = '$atMonitor'
`$SERVICE_PS1 = '$atService'
`$WMI_WRAPPER = '$atWmi'
`$REBOOT_VERIFY = '$atReboot'
`$GPO_SCRIPT = '$atGpo'
`$GPO_INI = '$atGpoIni'
`$STARTUP_LNK = '$atStartup'
`$NSSM = '$atNssm'
`$WG_SVC_NAME = '$atSvcName'
`$TUNNEL_SVC = '$atTunnelSvc'
`$TASK_MONITOR = 'WG-KillSwitch'
`$TASK_REPAIR = 'WG-RepairTask'
`$TASK_REBOOT_VERIFY = 'WG-RebootVerify'
`$TASK_WATCHDOG = 'WG-InternetWatchdog'
`$WMI_FILTER = 'WGMonitorFilter'
`$WMI_CONSUMER = 'WGMonitorConsumer'
`$EVENT_SRC = 'WGKillSwitch'

function Wait-NamedMutex([System.Threading.Mutex]`$Mutex, [int]`$TimeoutMs) {
    try { return `$Mutex.WaitOne(`$TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return `$true }
}
function Log-Tamper([string]`$m) {
    `$mutex = `$null
    try {
        `$mutex = New-Object System.Threading.Mutex(`$false, 'Global\WGKillSwitchLog')
        if (-not (Wait-NamedMutex `$mutex 1500)) { return }
        Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [TAMPER] `$m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if (`$mutex) { try { `$mutex.ReleaseMutex() } catch {} } }
}
function Write-TamperEvent([string]`$m) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists(`$EVENT_SRC)) {
            New-EventLog -LogName Application -Source `$EVENT_SRC -EA SilentlyContinue
        }
        Write-EventLog -LogName Application -Source `$EVENT_SRC -EventId 4701 -EntryType Warning -Message `$m -EA SilentlyContinue
    } catch {}
}
function Restore-FileFromGuard([string]`$destPath) {
    if (Test-Path `$destPath) { return `$false }
    `$name = Split-Path `$destPath -Leaf
    `$src = Join-Path `$GUARD_DIR `$name
    if (-not (Test-Path `$src)) { return `$false }
    New-Item -ItemType Directory -Path (Split-Path `$destPath -Parent) -Force -EA SilentlyContinue | Out-Null
    Copy-Item `$src `$destPath -Force
    attrib +S +H `$destPath 2>`$null | Out-Null
    Log-Tamper "Restored file: `$name"
    Write-TamperEvent "WGKillSwitch restored missing file: `$name"
    return `$true
}
function Restore-TaskFromBackup([string]`$TaskName, [string]`$RegProp) {
    `$task = Get-ScheduledTask -TaskName `$TaskName -EA SilentlyContinue
    if (`$task) {
        if (`$task.State -eq 'Disabled') {
            Enable-ScheduledTask -TaskName `$TaskName | Out-Null
            `$tn = '\' + `$TaskName
            schtasks /Run /TN `$tn 2>`$null | Out-Null
            Log-Tamper "Re-enabled task: `$TaskName"
            Write-TamperEvent "WGKillSwitch re-enabled task: `$TaskName"
            return `$true
        }
        return `$false
    }
    `$b64 = (Get-ItemProperty `$REG_KEY -Name `$RegProp -EA SilentlyContinue).`$RegProp
    if (`$b64) {
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$b64)) |
            Register-ScheduledTask -TaskName `$TaskName -Force | Out-Null
        Log-Tamper "Restored task from registry: `$TaskName"
        Write-TamperEvent "WGKillSwitch restored task: `$TaskName"
        return `$true
    }
    `$xmlPath = Join-Path `$GUARD_DIR "`$TaskName.xml"
    if (Test-Path `$xmlPath) {
        Register-ScheduledTask -TaskName `$TaskName -Xml (Get-Content `$xmlPath -Raw -Encoding UTF8) -Force | Out-Null
        Log-Tamper "Restored task from guard XML: `$TaskName"
        Write-TamperEvent "WGKillSwitch restored task from guard: `$TaskName"
        return `$true
    }
    return `$false
}
function Ensure-FirewallService {
    `$fixed = `$false
    `$profiles = netsh advfirewall show allprofiles state 2>`$null | Out-String
    if (`$profiles -match 'OFF') {
        netsh advfirewall set allprofiles state on 2>`$null | Out-Null
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
        Log-Tamper 'Firewall profiles forced ON'
        Write-TamperEvent 'WGKillSwitch forced Windows Firewall ON'
        `$fixed = `$true
    }
    if ((& sc.exe query MpsSvc 2>`$null) -match 'STOPPED') {
        & sc.exe start MpsSvc 2>`$null | Out-Null
        Start-Sleep -Seconds 2
        netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
        Log-Tamper 'MpsSvc restarted'
        Write-TamperEvent 'WGKillSwitch restarted Windows Firewall service'
        `$fixed = `$true
    }
    return `$fixed
}
function Restore-RunKey {
    `$expected = (Get-ItemProperty `$REG_KEY -Name RunKeyValue -EA SilentlyContinue).RunKeyValue
    if (-not `$expected) { `$expected = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$REPAIR``"" }
    `$current = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name WGKillSwitchGuard -EA SilentlyContinue).WGKillSwitchGuard
    if (`$current -ne `$expected) {
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' WGKillSwitchGuard `$expected -Force
        Log-Tamper 'Run key restored'
        Write-TamperEvent 'WGKillSwitch restored HKLM Run key'
        return `$true
    }
    return `$false
}
function Restore-StartupShortcut {
    if (Test-Path `$STARTUP_LNK) { return `$false }
    New-Item -ItemType Directory -Path (Split-Path `$STARTUP_LNK -Parent) -Force -EA SilentlyContinue | Out-Null
    `$wsh = New-Object -ComObject WScript.Shell
    `$lnk = `$wsh.CreateShortcut(`$STARTUP_LNK)
    `$lnk.TargetPath = 'powershell.exe'
    `$lnk.Arguments = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$REPAIR``""
    `$lnk.WorkingDirectory = 'C:\WireGuard'
    `$lnk.Save()
    Log-Tamper 'Startup shortcut restored'
    Write-TamperEvent 'WGKillSwitch restored startup shortcut'
    return `$true
}
function Restore-GpoBootScript {
    `$fixed = `$false
    if (-not (Test-Path `$GPO_SCRIPT)) {
        Restore-FileFromGuard `$GPO_SCRIPT | Out-Null
        `$fixed = `$true
    }
    if (Test-Path `$GPO_SCRIPT) {
        `$iniRaw = ''
        if (Test-Path `$GPO_INI) {
            `$iniRaw = Get-Content `$GPO_INI -Raw -Encoding Unicode -EA SilentlyContinue
            if ([string]::IsNullOrWhiteSpace(`$iniRaw)) { `$iniRaw = Get-Content `$GPO_INI -Raw -EA SilentlyContinue }
        }
        if (`$null -eq `$iniRaw) { `$iniRaw = '' }
        if (`$iniRaw -notmatch [regex]::Escape(`$GPO_SCRIPT)) {
            if (`$iniRaw -match '\[Startup\]') {
                `$max = -1; `$in = `$false
                foreach (`$line in (`$iniRaw -split "`r?`n")) {
                    if (`$line -match '^\[Startup\]') { `$in = `$true; continue }
                    if (`$line -match '^\[' -and `$line -notmatch '^\[Startup\]') { `$in = `$false; continue }
                    if (`$in -and `$line -match '^(\d+)CmdLine=') { `$i = [int]`$Matches[1]; if (`$i -gt `$max) { `$max = `$i } }
                }
                `$n = `$max + 1
                `$block = "`${n}CmdLine=powershell.exe`r`n`${n}Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$GPO_SCRIPT``"`r`n"
                `$iniRaw = `$iniRaw -replace '(\[Startup\]\r?\n)', "`$1`$block"
            } else {
                `$iniRaw += "`r`n[Startup]`r`n0CmdLine=powershell.exe`r`n0Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$GPO_SCRIPT``"`r`n"
            }
            New-Item -ItemType Directory -Path (Split-Path `$GPO_INI -Parent) -Force -EA SilentlyContinue | Out-Null
            `$iniRaw | Set-Content `$GPO_INI -Encoding Unicode -Force
            Log-Tamper 'GPO scripts.ini entry restored'
            Write-TamperEvent 'WGKillSwitch restored GPO startup registration'
            `$fixed = `$true
        }
    }
    return `$fixed
}
function Test-WmiSubscriptionActive {
    try {
        `$bf = "Filter = ""__EventFilter.Name='`$WMI_FILTER'"""
        `$f = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='`$WMI_FILTER'" -EA SilentlyContinue
        if (-not `$f) { return `$false }
        `$c = Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Filter "Name='`$WMI_CONSUMER'" -EA SilentlyContinue
        if (-not `$c) { return `$false }
        `$b = Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Filter `$bf -EA SilentlyContinue
        return [bool]`$b
    } catch { return `$false }
}
function Restore-WmiSubscription {
    if (Test-WmiSubscriptionActive) { return `$false }
    Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='`$WMI_FILTER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Filter "Name='`$WMI_CONSUMER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    `$bf = "Filter = ""__EventFilter.Name='`$WMI_FILTER'"""
    Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Filter `$bf -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    `$wmiQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND (TargetInstance.Name='powershell.exe' OR TargetInstance.Name='pwsh.exe')"
    try {
        `$filter = New-CimInstance -Namespace root\subscription -ClassName __EventFilter -Property @{
            Name=`$WMI_FILTER; EventNamespace='root\cimv2'; QueryLanguage='WQL'; Query=`$wmiQuery
        } -EA Stop
        `$consumer = New-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Property @{
            Name=`$WMI_CONSUMER
            CommandLineTemplate="powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$WMI_WRAPPER``""
        } -EA Stop
        if (`$filter -and `$consumer) {
            New-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Property @{
                Filter=[Ref]`$filter; Consumer=[Ref]`$consumer
            } -EA Stop | Out-Null
            if (Test-WmiSubscriptionActive) {
                Log-Tamper 'WMI subscription restored'
                Write-TamperEvent 'WGKillSwitch restored WMI permanent subscription'
                return `$true
            }
        }
    } catch {}
    return `$false
}
function Restore-NssmService {
    if (-not (Test-Path `$NSSM)) { return `$false }
    `$q = & sc.exe query `$WG_SVC_NAME 2>`$null | Out-String
    if (`$q -match 'RUNNING') { return `$false }
    if (`$q -notmatch 'SERVICE_NAME') {
        & `$NSSM install `$WG_SVC_NAME powershell.exe 2>`$null | Out-Null
        & `$NSSM set `$WG_SVC_NAME AppParameters "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ``"`$SERVICE_PS1``"" 2>`$null | Out-Null
        & `$NSSM set `$WG_SVC_NAME Start SERVICE_DELAYED_AUTO_START 2>`$null | Out-Null
        & `$NSSM set `$WG_SVC_NAME ObjectName LocalSystem 2>`$null | Out-Null
        & `$NSSM set `$WG_SVC_NAME AppExit Default Restart 2>`$null | Out-Null
        & `$NSSM set `$WG_SVC_NAME AppRestartDelay 5000 2>`$null | Out-Null
        Log-Tamper 'NSSM service reinstalled'
        Write-TamperEvent 'WGKillSwitch reinstalled NSSM guard service'
    }
    & sc.exe start `$WG_SVC_NAME 2>`$null | Out-Null
    return `$true
}
function Invoke-AntiTamperGuard {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return }
    try {
        `$reg = Get-ItemProperty `$REG_KEY -EA SilentlyContinue
        if (`$reg.GuardDir) { `$script:GUARD_DIR = [string]`$reg.GuardDir }
    } catch {}
    `$actions = 0
    Ensure-FirewallService | Out-Null
    foreach (`$f in @(`$MONITOR, `$REPAIR, `$SERVICE_PS1, `$WMI_WRAPPER, `$REBOOT_VERIFY, `$GPO_SCRIPT)) {
        if (Restore-FileFromGuard `$f) { `$actions++ }
    }
    if (`$Quick) {
        Restore-TaskFromBackup `$TASK_MONITOR 'TaskXML' | Out-Null
        Restore-TaskFromBackup `$TASK_REPAIR 'TaskXMLRepair' | Out-Null
        return
    }
    if (Restore-TaskFromBackup `$TASK_MONITOR 'TaskXML') { `$actions++ }
    if (Restore-TaskFromBackup `$TASK_REPAIR 'TaskXMLRepair') { `$actions++ }
    if (Restore-TaskFromBackup `$TASK_REBOOT_VERIFY 'TaskXMLRebootVerify') { `$actions++ }
    if (Restore-TaskFromBackup `$TASK_WATCHDOG 'TaskXMLWatchdog') { `$actions++ }
    if (Restore-RunKey) { `$actions++ }
    if (Restore-StartupShortcut) { `$actions++ }
    if (Restore-GpoBootScript) { `$actions++ }
    if (Restore-WmiSubscription) { `$actions++ }
    if (Restore-NssmService) { `$actions++ }
    if (`$actions -gt 0 -and -not `$NoChainRepair -and (Test-Path `$REPAIR)) {
        `$shell = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath `$shell -ArgumentList @(
            '-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',`$REPAIR
        ) -WindowStyle Hidden
    }
}
Invoke-AntiTamperGuard
"@ | Set-Content $ANTI_TAMPER_PS1 -Encoding UTF8 -Force
attrib +S +H $ANTI_TAMPER_PS1 2>$null | Out-Null
OK "anti-tamper.ps1 written"

# ================================================================
Write-Step "STEP 10c - PRIVACY HARDENING GUARD SCRIPT"
# ================================================================
Write-PrivacyHardeningGuardPs1
OK "privacy-hardening-guard.ps1 written"
$privacyGuardVersion = $WG_KS_VERSION
$webrtcForwarder = @'
# WebRTC forwarder (v'@ + $privacyGuardVersion + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
$webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
OK "webrtc-leak-guard.ps1 forwarder written"

# ================================================================
Write-Step "STEP 10d - V14 PRIVACY STACK GUARD SCRIPTS"
# ================================================================
if (Get-Command Write-AllV14GuardScripts -EA SilentlyContinue) {
    Write-AllV14GuardScripts
    OK "v14 guard scripts written (dnscrypt/tor/leak-sentinel)"
} else { WARN 'v14 stack missing - guard scripts skipped' }

# ================================================================
Write-Step "STEP 10e - V15 STRONG PRIVACY GUARD SCRIPTS"
# ================================================================
if (Get-Command Write-DnsLockdownGuardPs1 -EA SilentlyContinue) {
    Write-DnsLockdownGuardPs1
    Write-NetworkPrivacyGuardPs1
    if (Get-Command Write-DnscryptGuardPs1V15 -EA SilentlyContinue) { Write-DnscryptGuardPs1V15 }
    if (Get-Command Write-TorHardeningGuardPs1V15 -EA SilentlyContinue) { Write-TorHardeningGuardPs1V15 }
    if (Get-Command Write-LeakSentinelPs1V15 -EA SilentlyContinue) { Write-LeakSentinelPs1V15 }
    OK "v15 guard scripts written (dns-lockdown/network-privacy/leak-sentinel)"
} else { WARN 'v15 stack missing - strong privacy guard scripts skipped' }

# ================================================================
Write-Step "STEP 11 - MAIN SCHEDULED TASK (60s boot delay)"
# ================================================================
Remove-TaskFully $TASK_MONITOR
$monTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MONITOR_PS1`""
if (Register-TaskViaSchtasks $TASK_MONITOR $monTr '/SC ONSTART /DELAY 0001:00') {
    OK "WG-KillSwitch task registered - start deferred to STEP 19"
} else { Write-Err "WG-KillSwitch task registration FAILED!" }

# ================================================================
Write-Step "STEP 12 - REPAIR TASK (30s boot delay + every 2min)"
# ================================================================
# Repair cadence: every 2min; repair.ps1 enforces ExecutionTimeLimit Minutes 15 per run
Remove-TaskFully $TASK_REPAIR
$repTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
if (Register-TaskViaSchtasks $TASK_REPAIR $repTr '/SC MINUTE /MO 2') {
    OK "WG-RepairTask registered - every 2min"
} else { Write-Err "WG-RepairTask registration FAILED!" }

# ================================================================
Write-Step "STEP 12b - POST-REBOOT VERIFY TASK (5min boot delay)"
# ================================================================
$repoScripts = Join-Path $PSScriptRoot 'scripts'
$rebootVerifySrc = Join-Path $repoScripts 'post-reboot-verify.ps1'
if (Test-Path $rebootVerifySrc) {
    Copy-Item $rebootVerifySrc $REBOOT_VERIFY_PS1 -Force
    OK "post-reboot-verify.ps1 deployed"
} else {
    WARN "post-reboot-verify.ps1 source missing in repo"
}
Remove-TaskFully $TASK_REBOOT_VERIFY
$rvTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REBOOT_VERIFY_PS1`""
if (Register-TaskViaSchtasks $TASK_REBOOT_VERIFY $rvTr '/SC ONSTART /DELAY 0005:00') {
    OK "WG-RebootVerify task registered - 5min after boot"
} else { WARN "WG-RebootVerify task registration failed" }

# ================================================================
Write-Step "STEP 12c - INTERNET WATCHDOG TASK (every 3min)"
# ================================================================
Remove-TaskFully $TASK_WATCHDOG
$wdTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WATCHDOG_PS1`""
if (Register-TaskViaSchtasks $TASK_WATCHDOG $wdTr '/SC MINUTE /MO 1') {
    OK "WG-InternetWatchdog registered - every 1min"
} else { WARN "WG-InternetWatchdog task registration failed" }

# ================================================================
Write-Step "STEP 13 - REGISTRY BACKUP + FOLDER PROTECTION"
# ================================================================
try {
    $acl = Get-Acl $INSTALL_DIR -EA Stop
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM",   "FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users",         "ReadAndExecute", "ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl -Path $INSTALL_DIR -AclObject $acl -EA Stop
    Get-ChildItem $INSTALL_DIR -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'killswitch.log' } |
        ForEach-Object { attrib +S +H $_.FullName 2>$null | Out-Null }
    OK "ACL set + files hidden"
} catch { WARN "ACL/hide skipped: $_" }

New-Item -Path "HKLM:\SOFTWARE\WGKillSwitch" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "Version"       $WG_KS_VERSION                      -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ScriptsPath"  (Join-Path $PSScriptRoot 'scripts')   -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TunnelName"   $TUNNEL_NAME                        -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "MonitorPath"   $MONITOR_PS1                        -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RepairPath"    $REPAIR_PS1                         -Force
$taskXml = Export-TaskXmlSafe $TASK_MONITOR
if ($taskXml) {
    $taskXml | Set-Content "$INSTALL_DIR\WG-KillSwitch-backup.xml" -Encoding UTF8 -Force
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskXml))
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TaskXML"       $b64                                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ScriptsPath"  (Join-Path $PSScriptRoot 'scripts') -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RebootVerifyPath" $REBOOT_VERIFY_PS1             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "InstalledDate" (Get-Date -f "yyyy-MM-dd HH:mm:ss") -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "CustomMode"    ([bool]$CUSTOM_MODE)                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ConfigPath"    $CONFIG                             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TunnelName"    $TUNNEL_NAME                        -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerIP"      $(if ($CUSTOM_MODE) { $CustomEndpointIP } else { $serverIPs }) -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerPort"    (Get-ServerPort)                    -Force
    OK "Registry backup written"
} else { WARN "WG-KillSwitch task XML export failed" }
foreach ($pair in @(
    @{ Name = 'TaskXMLRepair'; Task = $TASK_REPAIR },
    @{ Name = 'TaskXMLRebootVerify'; Task = $TASK_REBOOT_VERIFY },
    @{ Name = 'TaskXMLWatchdog'; Task = $TASK_WATCHDOG }
)) {
    $tx = Export-TaskXmlSafe $pair.Task
    if ($tx) {
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tx))
        Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" $pair.Name $b64 -Force
    }
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
    OK "WGKillSwitchSvc: installed (start deferred to STEP 19)"
} else { WARN "NSSM not available - service layer skipped" }

# ================================================================
Write-Step "STEP 15 - WMI SUBSCRIPTION"
# ================================================================
if (Install-WmiSubscription) { OK "WMI Event Subscription active" }
else { WARN "WMI Subscription failed - 7 other layers still active" }

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
$gpoKsVersion = $WG_KS_VERSION
$gpoTunnelName = $TUNNEL_NAME
$gpoContent = @"
# WG KillSwitch GPO Boot Script v$gpoKsVersion (auto-generated by install.ps1)
`$LOG        = 'C:\WireGuard\killswitch.log'
`$REPAIR     = 'C:\WireGuard\repair.ps1'
`$TUNNEL_SVC = '$gpoTunnelSvc'
`$TUNNEL_NAME = '$gpoTunnelName'
`$REG_KEY    = 'HKLM:\SOFTWARE\WGKillSwitch'
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
function Test-BootGrace {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name BootGraceUntil -EA SilentlyContinue
        if (`$reg.BootGraceUntil -and (Get-Date) -lt [datetime]`$reg.BootGraceUntil) { return `$true }
    } catch {}
    return `$false
}
function Test-UnbrickActive {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name UnbrickUntil -EA SilentlyContinue
        if (`$reg.UnbrickUntil -and (Get-Date) -lt [datetime]`$reg.UnbrickUntil) { return `$true }
    } catch {}
    return `$false
}
function Test-TunnelAdapterUp {
    for (`$try = 0; `$try -lt 3; `$try++) {
        try {
            foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
                if (`$a.Status -ne 'Up') { continue }
                if (`$a.Name -eq `$TUNNEL_NAME -or `$a.InterfaceDescription -match 'WireGuard') { return `$true }
            }
        } catch {}
        if (`$try -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    return `$false
}
function Test-TunnelRunning {
    if (-not ([bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match "RUNNING"))) { return `$false }
    return (Test-TunnelAdapterUp)
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
Log "GPO boot script fired (v$gpoKsVersion)"
try {
    `$bootTime = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
    `$graceEnd = `$bootTime.AddSeconds(180)
    if ((Get-Date) -lt `$graceEnd) {
        New-Item -Path `$REG_KEY -Force | Out-Null
        Set-ItemProperty `$REG_KEY 'BootGraceUntil' `$graceEnd.ToString('o') -Force
        Log "GPO: BootGrace until `$(`$graceEnd.ToString('HH:mm:ss')) (fail-open)"
    }
} catch {}
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
& sc.exe config `$TUNNEL_SVC start= delayed-auto 2>`$null | Out-Null
if (Test-UnbrickActive -or Test-BootGrace) {
    Log "GPO: fail-open hold - repair only (no block authority)"
} else {
    `$waited = 0
    while (`$waited -lt 120 -and -not (Test-SafeToOpen)) {
        Start-Sleep -Seconds 3; `$waited += 3
    }
    if (Test-SafeToOpen) { Log "GPO: healthy after `${waited}s (tunnel + internet)" }
    elseif (Test-TunnelRunning) { Log "GPO: zombie tunnel after `${waited}s - monitor will debounce" }
    else { Log "GPO: tunnel down after `${waited}s - monitor will debounce" }
}
if (Test-Path `$REPAIR) {
    Start-HiddenScript `$REPAIR
    Log "Repair triggered (GPO never blocks)"
}
"@
$gpoContent | Set-Content $GPO_SCRIPT -Encoding UTF8 -Force
Update-GpoScriptsIni $GPO_INI $GPO_SCRIPT
Start-Process "secedit.exe"  -ArgumentList "/refreshpolicy machine_policy /enforce" -WindowStyle Hidden -Wait -EA SilentlyContinue
Start-Process "gpupdate.exe" -ArgumentList "/force" -WindowStyle Hidden -EA SilentlyContinue
if (Test-Path $GPO_SCRIPT) { OK "GPO boot script installed" } else { WARN "GPO script failed" }

# ================================================================
Write-Step "STEP 17b - ANTI-TAMPER GUARD VAULT"
# ================================================================
Write-GuardBackups
OK "Guard vault written ($GUARD_DIR)"

# ================================================================
Write-Step "STEP 18 - DEFENDER EXCLUSION"
# ================================================================
try {
    $defJob = Start-Job { param($p) Add-MpPreference -ExclusionPath $p -EA Stop } -ArgumentList $INSTALL_DIR
    if (Wait-Job $defJob -Timeout 25) {
        Receive-Job $defJob | Out-Null
        OK "Defender exclusion: $INSTALL_DIR"
    } else {
        Stop-Job $defJob -EA SilentlyContinue
        WARN "Defender exclusion timed out (skipped)"
    }
    Remove-Job $defJob -Force -EA SilentlyContinue
} catch { WARN "Defender exclusion failed" }

# ================================================================
Write-Step "STEP 18b - PRIVACY HARDENING"
# ================================================================
Install-PrivacyHardening
if (Test-Path $PRIVACY_GUARD_PS1) { OK "privacy-hardening-guard.ps1: deployed" } else { WARN "privacy-hardening-guard.ps1: missing" }
if (Test-Path $WEBRTC_GUARD_PS1) { OK "webrtc-leak-guard.ps1: deployed" } else { WARN "webrtc-leak-guard.ps1: missing" }
if (Test-ScriptIntegrityVault) { OK "Script integrity vault: seeded" } else { WARN "Script integrity vault: not verified" }

# ================================================================
Write-Step "STEP 18c - V14 DNS LEAK STACK (dnscrypt-proxy)"
# ================================================================
if (Get-Command Invoke-V14DnsLeakStack -EA SilentlyContinue) {
    Invoke-V14DnsLeakStack
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK "dnscrypt-proxy: healthy" }
        else { WARN "dnscrypt-proxy: service not healthy yet (guard will retry)" }
    }
} else { WARN "v14 DNS stack skipped (install-v14-stack.ps1 missing)" }

# ================================================================
Write-Step "STEP 18d - V14 TOR HARDENING"
# ================================================================
if (Get-Command Invoke-V14TorStack -EA SilentlyContinue) {
    Invoke-V14TorStack
    if (Get-Command Test-V14TorPresent -EA SilentlyContinue) {
        if (Test-V14TorPresent) { OK "Tor Browser: present" }
        else { WARN "Tor Browser: not installed (manual install from torproject.org)" }
    }
} else { WARN "v14 Tor stack skipped" }

# ================================================================
Write-Step "STEP 18e - V14 LEAK SENTINEL (read-only probe)"
# ================================================================
if (Test-Path $LEAK_SENTINEL_PS1) {
    & $LEAK_SENTINEL_PS1 2>$null
    $leakSt = (Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name LeakState -EA SilentlyContinue).LeakState
    if ($leakSt -eq 'HEALTHY') { OK "leak-sentinel: HEALTHY" }
    elseif ($leakSt) { WARN "leak-sentinel: $leakSt" }
    else { OK "leak-sentinel: probe completed" }
} else { WARN "leak-sentinel.ps1 missing" }

# ================================================================
Write-Step "STEP 18f - V15 STRONG PRIVACY STACK"
# ================================================================
if (Get-Command Invoke-V15StrongPrivacyStack -EA SilentlyContinue) {
    Invoke-V15StrongPrivacyStack
    if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
        if (Test-V15DnsLockdownHealthy) { OK "System DNS lock: all adapters 127.0.0.1" }
        else { WARN "System DNS lock: incomplete (guard will retry)" }
    }
    if (Get-Command Test-V15NetworkPrivacyHealthy -EA SilentlyContinue) {
        if (Test-V15NetworkPrivacyHealthy) { OK "Network privacy: LLMNR disabled" }
        else { WARN "Network privacy: LLMNR may still be on" }
    }
} else { WARN "v15 strong privacy stack skipped" }

# ================================================================
Write-Step "STEP 19 - ACTIVATE MONITOR + CLEAR INSTALL LOCK"
# ================================================================
Ensure-TunnelForInstall | Out-Null
Ensure-DelayedAutoStart
Disable-AllIPv6Bindings
Remove-KurtarArtifacts
New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'BootGraceUntil' (Get-Date).AddSeconds(180).ToString('o') -Force
Clear-InstallLock
OK "Install lock cleared - 180s BootGrace (fail-open), then monitor takes over"
if (Test-Path $NSSM) {
    & $NSSM start $WG_SVC_NAME 2>$null | Out-Null
    Start-Sleep 3
    $svcStatus = & sc.exe query $WG_SVC_NAME 2>$null
    if ($svcStatus -match 'RUNNING') { OK 'WGKillSwitchSvc: RUNNING (delayed-auto)' }
    else { WARN 'WGKillSwitchSvc: start pending - repair layers still active' }
}
Stop-AllMonitorProcs
Remove-Item "$INSTALL_DIR\monitor.pid" -Force -EA SilentlyContinue
Start-Sleep 2
Start-HiddenScript $MONITOR_PS1
Start-Sleep 3
Start-Sleep 5
if (-not (Test-SafeToOpen)) {
    Remove-InstallBlocks
    WARN "Tunnel not healthy yet - blocks OFF; monitor will recover."
} else {
    OK "Tunnel + internet OK - monitor taking over"
}
Write-GuardBackups
Install-ScriptIntegrityVault
OK "Guard vault refreshed (final script versions)"

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

$gRv = Get-ScheduledTask -TaskName $TASK_REBOOT_VERIFY -EA SilentlyContinue
if ($gRv -and $gRv.State -in @('Ready','Running')) { OK "WG-RebootVerify task: $($gRv.State)" }
else { WARN "WG-RebootVerify task missing or disabled"; $warnings++ }
if (Test-Path $REBOOT_VERIFY_PS1) { OK "post-reboot-verify.ps1: present" } else { WARN "post-reboot-verify.ps1: missing"; $warnings++ }

$gWd = Get-ScheduledTask -TaskName $TASK_WATCHDOG -EA SilentlyContinue
if ($gWd -and $gWd.State -in @('Ready','Running')) { OK "WG-InternetWatchdog task: $($gWd.State)" }
else { WARN "WG-InternetWatchdog task missing or disabled"; $warnings++ }
if (Test-Path $WATCHDOG_PS1) { OK "internet-watchdog.ps1: present" } else { WARN "internet-watchdog.ps1: missing"; $warnings++ }

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

Ensure-DelayedAutoStart
if (Test-DelayedAutoStart) { OK "Tunnel service: delayed-auto-start enforced" }
else { WARN "Tunnel service: delayed-auto not confirmed (sc qc)"; $warnings++ }

if (Test-WmiSubscriptionActive) { OK "WMI Subscription: ACTIVE (filter+consumer+binding)" }
else { WARN "WMI Subscription: missing or incomplete"; $warnings++ }
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut: present" } else { WARN "Startup shortcut: missing"; $warnings++ }
if (Test-Path $GPO_SCRIPT)  { OK "GPO script: present" }       else { WARN "GPO script: missing";       $warnings++ }
if (Test-Path $ANTI_TAMPER_PS1) { OK "anti-tamper.ps1: present" } else { WARN "anti-tamper.ps1: missing"; $warnings++ }
if (Test-Path $GUARD_DIR) {
    $guardN = (Get-ChildItem $GUARD_DIR -File -Force -EA SilentlyContinue | Measure-Object).Count
    if ($guardN -ge 5) { OK "Guard vault: $guardN files" } else { WARN "Guard vault: only $guardN file(s)"; $warnings++ }
} else { WARN "Guard vault: missing"; $warnings++ }

$reg = Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -EA SilentlyContinue
if ($reg.TaskXML -and $reg.TaskXMLRepair) { OK "Registry backup: v$($reg.Version)" } else { WARN "Registry backup: incomplete"; $warnings++ }

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

foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
    if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
    else { WARN "Browser privacy: $($pair[1]) incomplete"; $warnings++ }
}
if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" } else { WARN "Windows telemetry: not confirmed"; $warnings++ }
if (Test-Path $PRIVACY_GUARD_PS1) { OK "privacy-hardening-guard.ps1: present" } else { WARN "privacy-hardening-guard.ps1: missing"; $warnings++ }
if (Test-Path $WEBRTC_GUARD_PS1) { OK "webrtc-leak-guard.ps1: present" } else { WARN "webrtc-leak-guard.ps1: missing"; $warnings++ }
if (Test-Path $DNSCRYPT_GUARD_PS1) { OK "dnscrypt-guard.ps1: present" } else { WARN "dnscrypt-guard.ps1: missing"; $warnings++ }
if (Test-Path $LEAK_SENTINEL_PS1) { OK "leak-sentinel.ps1: present" } else { WARN "leak-sentinel.ps1: missing"; $warnings++ }
if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
    if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: RUNNING + 127.0.0.1:53' }
    else { WARN "dnscrypt-proxy: not healthy"; $warnings++ }
}
if (Test-Path $DNS_LOCKDOWN_GUARD_PS1) { OK "dns-lockdown-guard.ps1: present" } else { WARN "dns-lockdown-guard.ps1: missing"; $warnings++ }
if (Test-Path $NETWORK_PRIVACY_GUARD_PS1) { OK "network-privacy-guard.ps1: present" } else { WARN "network-privacy-guard.ps1: missing"; $warnings++ }
$dnscryptFw = Get-NetFirewallRule -DisplayName "KS-Dnscrypt-EXE" -EA SilentlyContinue
if ($dnscryptFw) { OK "KS-Dnscrypt-EXE firewall rule: ACTIVE" } else { WARN "KS-Dnscrypt-EXE firewall rule: missing"; $warnings++ }
if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
    if (Test-V15DnsLockdownHealthy) { OK "System DNS lock: healthy" }
    else { WARN "System DNS lock: not confirmed"; $warnings++ }
}
$torSt = (Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name TorState -EA SilentlyContinue).TorState
if ($torSt -eq 'NOT_INSTALLED') { WARN "Tor Browser: not installed (optional)" }
elseif ($torSt) { OK "Tor state: $torSt" }
if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" } else { WARN "Script integrity vault: mismatch"; $warnings++ }

if ($CUSTOM_MODE) { OK "Mode: Custom server ($CustomEndpointIP)" } else { OK "Mode: Cloudflare WARP" }

Log "install.ps1 v$WG_KS_VERSION completed"
Write-Host ""
if ($warnings -eq 0) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  INSTALL COMPLETE - SYSTEM FULLY PROTECTED (v$WG_KS_VERSION)            " -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Green
} else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  INSTALL COMPLETE - $warnings WARNING(S) - see above          " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log: C:\WireGuard\killswitch.log" -ForegroundColor Gray
Write-Host "  Stuck internet: WG-InternetWatchdog auto-unbricks (every 1min)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Protection layers:" -ForegroundColor White
Write-Host "  [1] WireGuard tunnel: delayed-auto-start"           -ForegroundColor DarkGray
Write-Host "  [2] WGKillSwitchSvc (NSSM): delayed-auto-start"    -ForegroundColor DarkGray
Write-Host "  [3] WG-KillSwitch task: 60s boot delay"            -ForegroundColor DarkGray
Write-Host "  [4] WG-RepairTask: 30s boot delay + every 2min"    -ForegroundColor DarkGray
Write-Host "  [5] WMI Event Subscription: powershell death watch" -ForegroundColor DarkGray
Write-Host "  [6] Startup folder shortcut"                        -ForegroundColor DarkGray
Write-Host "  [7] GPO Machine Startup Script"                     -ForegroundColor DarkGray
Write-Host "  [8] HKLM Run key"                                   -ForegroundColor DarkGray
Write-Host "  [9] WG-RebootVerify: auto audit 5min after boot"   -ForegroundColor DarkGray
Write-Host "  [10] WG-InternetWatchdog: auto-unbrick every 1min"  -ForegroundColor DarkGray
Write-Host "  [+] Anti-tamper guard: silent restore from vault"  -ForegroundColor DarkGray
Write-Host "  [+] Privacy hardening: cookies/fingerprint/telemetry/ads" -ForegroundColor DarkGray
Write-Host "  [+] dnscrypt-proxy: encrypted DNS via 127.0.0.1 (WG DNS)" -ForegroundColor DarkGray
Write-Host "  [+] Tor hardening: user.js (start Tor Browser manually)" -ForegroundColor DarkGray
Write-Host "  [+] leak-sentinel: read-only DNS leak probe (no firewall changes)" -ForegroundColor DarkGray
Write-Host "  [+] v15 DNS lockdown: all adapters -> 127.0.0.1, DoH off" -ForegroundColor DarkGray
Write-Host "  [+] v15 network privacy: LLMNR/NetBIOS disabled" -ForegroundColor DarkGray
Write-Host "  [+] Sensitive mode: Hassas-Tarama.lnk (Tor Browser only)" -ForegroundColor DarkGray
Write-Host "  Reboot log: C:\WireGuard\reboot-verify.log"         -ForegroundColor DarkGray
Write-Host ""
if ($CUSTOM_MODE) {
    Write-Host "  Custom server usage example:" -ForegroundColor White
    Write-Host "  .\install.ps1 -CustomConfig C:\myvpn.conf -CustomTunnel myvpn -CustomEndpointIP 1.2.3.4/32 -CustomPort 51820" -ForegroundColor DarkGray
    Write-Host ""
}
if (-not $NoPause) { pause }

