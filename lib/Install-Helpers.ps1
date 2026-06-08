# Dot-sourced from install.ps1 - Install-Helpers.ps1 (v15.2.9 modular split - REVIEWED)
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
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog "Would start hidden script: $ScriptPath"
        }
        return
    }
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
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\WGKillSwitchLog')
        $acquired = Wait-NamedMutex $mutex 3000
        if (-not $acquired) { return }
        Add-Content -Path $LOG -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message" -Encoding UTF8 -EA SilentlyContinue
        try {
            $s = Get-Content $LOG -Encoding UTF8 -EA Stop
            if ($s.Count -gt 500) { $s | Select-Object -Last 250 | Set-Content $LOG -Encoding UTF8 -Force }
        } catch {}
    } finally {
        if ($mutex) {
            if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
            $mutex.Dispose()
        }
    }
}

$script:CimShort = $null
function Get-ShortCimSession {
    if ($script:CimShort) {
        try {
            $null = Get-CimInstance -CimSession $script:CimShort -ClassName Win32_ComputerSystem -EA Stop |
                Select-Object -First 1
            return $script:CimShort
        } catch {
            try { Remove-CimSession $script:CimShort -EA SilentlyContinue } catch {}
            $script:CimShort = $null
        }
    }
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
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog "Would remove scheduled task: $name"
        }
        return
    }
    $tn = '\' + $name
    Invoke-Schtasks @('/End', '/TN', $tn, '/F')
    Invoke-Schtasks @('/Delete', '/TN', $tn, '/F')
}

function Register-RepairTaskDualTrigger([string]$TaskName, [string]$ScriptPath) {
    Remove-TaskFully $TaskName
    $start = (Get-Date).ToString('yyyy-MM-dd') + 'T00:00:00'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>WG Repair - 30s boot delay + every 2min</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT2M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File &quot;$ScriptPath&quot;</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $tmp = Join-Path $env:TEMP 'wg-repair-dual.xml'
    try {
        [IO.File]::WriteAllText($tmp, $xml, [Text.UnicodeEncoding]::new($false, $true))
        Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $tmp -Raw -Encoding Unicode) -Force -EA Stop | Out-Null
        return $true
    } catch {
        $repTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
        return (Register-TaskViaSchtasks $TaskName $repTr '/SC MINUTE /MO 2')
    } finally {
        Remove-Item $tmp -Force -EA SilentlyContinue
    }
}

function Refresh-RegistryTaskBackups {
    if (-not (Test-Path 'HKLM:\SOFTWARE\WGKillSwitch')) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    }
    $pairs = @(
        @{ Name = 'TaskXML'; Task = $TASK_MONITOR },
        @{ Name = 'TaskXMLRepair'; Task = $TASK_REPAIR },
        @{ Name = 'TaskXMLRebootVerify'; Task = $TASK_REBOOT_VERIFY },
        @{ Name = 'TaskXMLWatchdog'; Task = $TASK_WATCHDOG }
    )
    $ok = 0
    foreach ($pair in $pairs) {
        if (-not $pair.Task) { continue }
        $tx = Export-TaskXmlSafe $pair.Task
        if ($tx) {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tx))
            Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' $pair.Name $b64 -Force
            $ok++
        }
    }
    return ($ok -ge 2)
}

function Register-TaskViaSchtasks(
    [string]$Name,
    [string]$Command,
    [string]$ScheduleArgs,
    [int]$TimeoutSec = 45
) {
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog "Would register scheduled task: $Name ($ScheduleArgs)"
        }
        return $false
    }
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
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog 'Would set install lock (install.inprogress + registry)'
        }
        return
    }
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Set-Content $INSTALL_LOCK (Get-Date -Format 'o') -Force -EA SilentlyContinue
    New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' 1 -Type DWord -Force
}

function Clear-InstallLock {
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog 'Would clear install lock'
        }
        return
    }
    Remove-Item $INSTALL_LOCK -Force -EA SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
}

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return $true }
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name InstallInProgress -ErrorAction SilentlyContinue
        return ($reg.InstallInProgress -eq 1)
    } catch { return $false }
}

function Test-DnscryptListening {
    $exe = if ($script:DNSCRYPT_EXE) { $script:DNSCRYPT_EXE } elseif ($DNSCRYPT_EXE) { $DNSCRYPT_EXE } else { 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.exe' }
    if (-not (Test-Path $exe)) { return $false }
    $svc = if ($script:DNSCRYPT_SVC) { $script:DNSCRYPT_SVC } elseif ($DNSCRYPT_SVC) { $DNSCRYPT_SVC } else { 'WG-DnscryptProxy' }
    $st = & sc.exe query $svc 2>&1 | Out-String
    if ($st -notmatch 'RUNNING') { return $false }
    $net = & netstat.exe -ano 2>&1 | Out-String
    return ($net -match '127\.0\.0\.1:53\s+.*LISTENING')
}

function Restore-DhcpDnsOnPhysicalAdapters {
    $tunnelPatterns = @('WireGuard', 'wintun', 'Wintun', 'AllDebrid')
    $fixed = 0
    foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
        $isTunnel = $false
        foreach ($p in $tunnelPatterns) {
            if ("$($a.Name) $($a.InterfaceDescription)" -match [regex]::Escape($p)) { $isTunnel = $true; break }
        }
        if ($isTunnel) { continue }
        netsh interface ipv4 set dnsservers name="$($a.Name)" source=dhcp 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $fixed++ }
    }
    Clear-DnsClientCache -EA SilentlyContinue
    return $fixed
}

function Test-InstallHealthStable {
    param([int]$Checks = 3, [int]$IntervalSec = 10)
    if (-not (Get-Command Test-SafeToOpen -ErrorAction SilentlyContinue)) { return $true }
    for ($i = 1; $i -le $Checks; $i++) {
        if (-not (Test-SafeToOpen)) { return $false }
        if ($i -lt $Checks) { Start-Sleep -Seconds $IntervalSec }
    }
    return $true
}

function Invoke-DeferredPrivacyGuards {
    if (Test-InstallInProgress) {
        WARN 'Privacy guards deferred: install still in progress'
        return
    }
    if (-not (Test-TunnelRunning)) {
        WARN 'Privacy guards deferred: WireGuard tunnel not RUNNING (repair will retry)'
        return
    }
    if (-not (Test-DnscryptListening)) {
        WARN 'Privacy guards deferred: dnscrypt not listening on 127.0.0.1:53 (repair will retry)'
        return
    }
    if (-not (Test-InstallHealthStable)) {
        WARN 'Privacy guards deferred: tunnel+internet not stable for 30s (repair will retry)'
        return
    }
    if (Get-Command Unlock-WireGuardConfigForWrite -ErrorAction SilentlyContinue) {
        Unlock-WireGuardConfigForWrite
    } elseif (Test-Path $CONFIG) {
        try {
            icacls $CONFIG /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
            attrib -R -S -H $CONFIG 2>$null | Out-Null
        } catch {}
    }
    foreach ($g in @(
        $(if ($script:DNSCRYPT_GUARD_PS1) { $script:DNSCRYPT_GUARD_PS1 } else { "$INSTALL_DIR\dnscrypt-guard.ps1" }),
        $(if ($script:NETWORK_PRIVACY_GUARD_PS1) { $script:NETWORK_PRIVACY_GUARD_PS1 } else { "$INSTALL_DIR\network-privacy-guard.ps1" })
    )) {
        if ($g) { Invoke-GuardScriptSafe -Path $g -Label (Split-Path $g -Leaf) | Out-Null }
    }
}

function Invoke-GuardScriptSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'guard'
    )
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog "Would run guard script: $Label ($Path)"
        }
        return $false
    }
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

function Backup-TunnelConfig {
    if (-not (Test-Path $CONFIG)) { return $false }
    Copy-Item $CONFIG "$CONFIG.bak" -Force
    return $true
}

function Restore-TunnelConfigIfMissing {
    if (Test-Path $CONFIG) { return $true }
    if (Test-Path "$CONFIG.bak") {
        Copy-Item "$CONFIG.bak" $CONFIG -Force
        return $true
    }
    $guardCfg = Join-Path $GUARD_DIR 'wgcf-profile.conf'
    if (Test-Path $guardCfg) {
        Copy-Item $guardCfg $CONFIG -Force
        return $true
    }
    return $false
}

function Restart-TunnelWithConfig {
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog 'Would restart WireGuard tunnel with config'
        }
        return $true
    }
    Restore-TunnelConfigIfMissing | Out-Null
    if (-not (Test-Path $CONFIG)) { return $false }
    if (Test-TunnelRunning) {
        & sc.exe stop $TUNNEL_SVC 2>$null | Out-Null
        Start-Sleep 2
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        $waited = 0
        while ($waited -lt 30 -and -not (Test-TunnelRunning)) { Start-Sleep 2; $waited += 2 }
        return (Test-TunnelRunning)
    }
    $svcExists = [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -notmatch 'does not exist')
    if ($svcExists) {
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        $waited = 0
        while ($waited -lt 30 -and -not (Test-TunnelRunning)) { Start-Sleep 2; $waited += 2 }
        if (Test-TunnelRunning) { return $true }
    }
    Backup-TunnelConfig | Out-Null
    & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
    Start-Sleep 2
    Restore-TunnelConfigIfMissing | Out-Null
    if (-not (Test-Path $CONFIG)) { return $false }
    & $WG_EXE /installtunnelservice $CONFIG 2>&1 | Out-Null
    & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
    $waited = 0
    while ($waited -lt 30 -and -not (Test-TunnelRunning)) { Start-Sleep 2; $waited += 2 }
    return (Test-TunnelRunning)
}

function Ensure-TunnelForInstall {
    if ($script:InstallDryRun) {
        if (Get-Command Write-SafeActionLog -ErrorAction SilentlyContinue) {
            Write-SafeActionLog 'Would ensure WireGuard tunnel for install'
        }
        return $true
    }
    if (Test-TunnelServiceRunning) {
        OK "Tunnel already RUNNING - kept alive during upgrade"
        return $true
    }
    Restore-TunnelConfigIfMissing | Out-Null
    if (-not (Test-Path $CONFIG)) { WARN "Config missing - cannot install tunnel"; return $false }
    Write-Info "Tunnel down - installing service..."
    $svcExists = [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -notmatch 'does not exist')
    if ($svcExists) {
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        $waited = 0
        while ($waited -lt 45 -and -not (Test-TunnelServiceRunning)) { Start-Sleep 3; $waited += 3 }
        if (Test-TunnelServiceRunning) {
            OK "Tunnel RUNNING (soft start, waited ${waited}s)"
            return $true
        }
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Backup-TunnelConfig | Out-Null
        & $WG_EXE /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
        Start-Sleep 2
        Restore-TunnelConfigIfMissing | Out-Null
        if (-not (Test-Path $CONFIG)) {
            WARN "Tunnel config lost after uninstall - attempt $attempt"
            continue
        }
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


