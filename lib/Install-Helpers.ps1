# Dot-sourced from install.ps1 â€” Install-Helpers.ps1 (v15.1 modular split)
#Requires -Version 5.1
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

function Invoke-GuardScriptSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'guard'
    )
    if (-not (Test-Path $Path)) { return $false }
    try {
        & $Path 2>$null
        return $true
    } catch {
        if (Get-Command WARN -ErrorAction SilentlyContinue) { WARN "$Label failed: $_" }
        elseif (Get-Command Write-Info -ErrorAction SilentlyContinue) { Write-Info "$Label failed: $_" }
        return $false
    }
}

function Ensure-DnscryptTomlFile {
    param([Parameter(Mandatory)][scriptblock]$GetContent)
    $dir = if ($script:DNSCRYPT_DIR) { $script:DNSCRYPT_DIR } elseif ($DNSCRYPT_DIR) { $DNSCRYPT_DIR } else { 'C:\WireGuard\dnscrypt-proxy' }
    $conf = if ($script:DNSCRYPT_CONF) { $script:DNSCRYPT_CONF } elseif ($DNSCRYPT_CONF) { $DNSCRYPT_CONF } else { Join-Path $dir 'dnscrypt-proxy.toml' }
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($conf, (& $GetContent), $enc)
        return $true
    } catch {
        if (Get-Command WARN -ErrorAction SilentlyContinue) { WARN "dnscrypt toml write failed: $_" }
        return $false
    }
}

function Remove-InstallBlocks {
    foreach ($r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        if (Get-Command Invoke-SafeNetsh -ErrorAction SilentlyContinue) {
            Invoke-SafeNetsh "netsh advfirewall firewall delete rule name=`"$r`"" 'remove install block'
        } elseif (-not $script:InstallDryRun) {
            netsh advfirewall firewall delete rule name="$r" 2>$null | Out-Null
        }
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


