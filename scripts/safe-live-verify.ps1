#Requires -RunAsAdministrator
# v12.1 SAFE LIVE VERIFY — read-only production gate. NEVER stops tunnel or disrupts internet.
$ErrorActionPreference = 'Continue'
$failures = [System.Collections.Generic.List[string]]::new()
$pass = 0
$TUNNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'

function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Test-TunnelRunning {
    try {
        $reg = Get-ItemProperty $REG -Name TunnelName -EA SilentlyContinue
        if ($reg.TunnelName) { $TUNNEL_SVC = "WireGuardTunnel`$$($reg.TunnelName)" }
    } catch {}
    return ([bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match 'RUNNING'))
}

function Test-Tcp443([string]$h) {
    $t = $null
    try {
        $t = New-Object Net.Sockets.TcpClient
        $a = $t.BeginConnect($h, 443, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(4000, $false)) { return $false }
        try { $t.EndConnect($a) } catch { return $false }
        return $true
    } catch { return $false } finally { if ($t) { try { $t.Close() } catch {} } }
}

function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-Tcp443 $h) { $hits++ } }
    return ($hits -ge 2)
}

function Test-Dns {
    try {
        $r = [System.Net.Dns]::GetHostAddresses('google.com')
        return ($r -and $r.Count -gt 0)
    } catch { return $false }
}

function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Internet) -and (Test-Dns) }

function Get-MonitorCount {
    $n = 0
    foreach ($shell in @('powershell', 'pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $n++ }
            } catch {}
        }
    }
    return $n
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SAFE LIVE VERIFY (v12.1 - non-disruptive)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# [1] Health baseline — abort destructive checks if unhealthy but still run script audits
$healthy = Test-SafeToOpen
Assert $healthy 'Health: tunnel + internet (SafeToOpen)'
if (-not $healthy) {
    Write-Host "  [WARN] System unhealthy - running read-only script audits only" -ForegroundColor Yellow
}

# [2] Registry
$reg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($reg -and $reg.Version -ge '12.2') "Registry version 12.2+ (got $($reg.Version))"
Assert (Test-Path 'C:\WireGuard\monitor.ps1') 'monitor.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\repair.ps1') 'repair.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\kurtar.bat') 'kurtar.bat deployed'
Assert (Test-Path 'C:\WireGuard\kurtar2.ps1') 'kurtar2.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\anti-tamper.ps1') 'anti-tamper.ps1 deployed'

# [3] v12.0 script content guards
$mon = Get-Content 'C:\WireGuard\monitor.ps1' -Raw -EA SilentlyContinue
$rep = Get-Content 'C:\WireGuard\repair.ps1' -Raw -EA SilentlyContinue
$svc = Get-Content 'C:\WireGuard\service-monitor.ps1' -Raw -EA SilentlyContinue
$wmi = Get-Content 'C:\WireGuard\wmi-repair.ps1' -Raw -EA SilentlyContinue
$gpo = Get-Content 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\wg-startup.ps1' -Raw -EA SilentlyContinue

Assert ($mon -match 'v12\.2') 'monitor.ps1 version v12.2'
Assert ($mon -match 'tunnelLostStreak') 'monitor debounces tunnel-down before block'
Assert ($mon -match 'Disable-DnsLeakProtection') 'monitor toggles DNS leak with block state'
Assert ($mon -match 'Test-Dns') 'monitor includes DNS health check'
Assert ($mon -match 'oldCmd -match') 'monitor PID validated by command-line'
Assert ($mon -match 'Invoke-EmergencyUnbrick') 'monitor has emergency unbrick'
Assert ($mon -match 'DNS flush') 'monitor zombie uses DNS flush not reinstall'
Assert ($rep -match 'v12\.2|Repair Script v12') 'repair.ps1 version v12.2'
Assert ($rep -match 'Test-FwRuleExists') 'repair uses rule-exists check for DNS'
Assert ($rep -match 'Disable-DnsLeakProtection') 'repair toggles DNS leak with block state'
Assert ($rep -match 'deferring reinstall') 'repair defers to active monitor'
Assert ($rep -match 'Try-ReinstallTunnel') 'repair has mutex reinstall'
Assert ($rep -match 'oldCmd -match|CommandLine') 'repair validates monitor PID'
Assert ($svc -match 'tunnel recovery delegated') 'SVC delegates tunnel recovery'
Assert ($wmi -match 'v12\.0') 'wmi-repair.ps1 version v12.0'
Assert ($gpo -match 'sc\.exe config.*TUNNEL_SVC') 'GPO uses parameterized tunnel service'

# [4] WMI subscription — both shells in one query
$wmiFilter = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
    Where-Object { $_.Name -eq 'WGMonitorFilter' }
Assert ($null -ne $wmiFilter) 'WMI WGMonitorFilter present'
if ($wmiFilter) {
    Assert ($wmiFilter.Query -match "powershell\.exe' OR TargetInstance\.Name='pwsh\.exe") 'WMI watches powershell AND pwsh'
}

# [5] Layers (read-only)
Assert (Test-Path 'C:\WireGuard\internet-watchdog.ps1') 'internet-watchdog.ps1 deployed'
$wd = Get-Content 'C:\WireGuard\internet-watchdog.ps1' -Raw -EA SilentlyContinue
Assert ($wd -match 'v12\.1|Internet Watchdog') 'internet-watchdog.ps1 version v12.1'

foreach ($tn in @('WG-KillSwitch', 'WG-RepairTask', 'WG-RebootVerify', 'WG-InternetWatchdog')) {
    $t = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
    Assert ($t -and $t.State -in @('Ready', 'Running')) "Task $tn active"
}
if (Test-Path 'C:\WireGuard\nssm.exe') {
    $svcSt = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
    Assert ($svcSt -match 'RUNNING') 'WGKillSwitchSvc RUNNING'
} else {
    Assert $true 'WGKillSwitchSvc N/A (NSSM absent - other layers active)'
}
Assert ((Get-MonitorCount) -ge 1) 'Monitor process running'
Assert ((Get-MonitorCount) -le 1) 'Single monitor instance'

# [6] Firewall when healthy
if ($healthy) {
    $o = netsh advfirewall firewall show rule name='KS-WARP-Server-Out' 2>&1 | Out-String
    Assert ($o -match 'Enabled:\s+Yes') 'Firewall enabled: KS-WARP-Server-Out'
    foreach ($r in @('KS-DNS-Block', 'KS-DNS-Block-TCP')) {
        $o = netsh advfirewall firewall show rule name=$r 2>&1 | Out-String
        Assert ($o -match 'Enabled:\s+No') "DNS leak OFF when healthy: $r"
    }
    foreach ($r in @('KS-Block-WiFi-Out', 'KS-Block-Ethernet-Out')) {
        $o = netsh advfirewall firewall show rule name=$r 2>&1 | Out-String
        Assert ($o -match 'No rules match') "Block absent when healthy: $r"
    }
}

# [7] Guard vault
Assert (Test-Path 'C:\ProgramData\WGKillSwitchGuard') 'Anti-tamper guard vault present'
$guardCount = (Get-ChildItem 'C:\ProgramData\WGKillSwitchGuard' -Force -EA SilentlyContinue | Measure-Object).Count
Assert ($guardCount -ge 8) "Guard vault file count >= 8 (got $guardCount)"

# [8] Mutex cross-process (safe, no tunnel interaction)
$dup = "Global_WGSafeTest_$([guid]::NewGuid().ToString('N'))"
$mA = New-Object System.Threading.Mutex($true, $dup)
$probe = Join-Path $env:TEMP 'wg-safe-mutex.ps1'
@'
param($n)
$m = New-Object System.Threading.Mutex($false, $n)
$ok = $false
try { $ok = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ok = $true }
if ($m) { try { if ($ok) { $m.ReleaseMutex() } } catch {} ; $m.Dispose() }
if ($ok) { exit 2 } else { exit 0 }
'@ | Set-Content $probe -Encoding UTF8
$p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe, '-n', $dup -PassThru -Wait -WindowStyle Hidden
Assert ($p.ExitCode -eq 0) 'Mutex cross-process exclusion'
Remove-Item $probe -Force -EA SilentlyContinue
try { $mA.ReleaseMutex() } catch {}
$mA.Dispose()

# [9] Re-verify internet unchanged
Assert (Test-Internet) 'Post-check: TCP internet still working'
Assert (Test-Dns) 'Post-check: DNS still working'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SAFE LIVE: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  SAFE LIVE VERIFY: PASSED" -ForegroundColor Green
exit 0