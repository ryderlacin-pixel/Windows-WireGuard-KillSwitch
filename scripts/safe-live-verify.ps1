#Requires -RunAsAdministrator
# v13.0 SAFE LIVE VERIFY — read-only production gate. NEVER stops tunnel or disrupts internet.
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
        if ($reg.TunnelName) { $script:TUNNEL_SVC = "WireGuardTunnel`$$($reg.TunnelName)" }
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

function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Internet) }

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
Write-Host "  SAFE LIVE VERIFY (v13.0 - non-disruptive)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$healthy = Test-SafeToOpen
Assert $healthy 'Health: tunnel + TCP internet (SafeToOpen)'
if (-not $healthy) {
    Write-Host "  [WARN] System unhealthy - read-only audits only" -ForegroundColor Yellow
}

$reg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($reg -and $reg.Version -ge '13.0') "Registry version 13.0+ (got $($reg.Version))"
Assert (Test-Path 'C:\WireGuard\monitor.ps1') 'monitor.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\repair.ps1') 'repair.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\kurtar.bat') 'kurtar.bat deployed'
Assert (Test-Path 'C:\WireGuard\kurtar2.ps1') 'kurtar2.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\anti-tamper.ps1') 'anti-tamper.ps1 deployed'

$mon = Get-Content 'C:\WireGuard\monitor.ps1' -Raw -EA SilentlyContinue
$rep = Get-Content 'C:\WireGuard\repair.ps1' -Raw -EA SilentlyContinue
$svc = Get-Content 'C:\WireGuard\service-monitor.ps1' -Raw -EA SilentlyContinue
$wmi = Get-Content 'C:\WireGuard\wmi-repair.ps1' -Raw -EA SilentlyContinue
$gpo = Get-Content 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\wg-startup.ps1' -Raw -EA SilentlyContinue
$k2 = Get-Content 'C:\WireGuard\kurtar2.ps1' -Raw -EA SilentlyContinue
$wd = Get-Content 'C:\WireGuard\internet-watchdog.ps1' -Raw -EA SilentlyContinue

Assert ($mon -match 'v13\.0') 'monitor.ps1 version v13.0'
Assert ($mon -match 'Test-BootGrace') 'monitor has BootGrace fail-open'
Assert ($mon -match 'Test-BlockAllowed') 'monitor has block-allowed guard'
Assert ($mon -notmatch 'Test-Dns') 'monitor SafeToOpen excludes DNS gate'
Assert ($mon -match 'zombieStreak') 'monitor debounces zombie block (15x)'
Assert ($mon -match 'tunnelLostStreak') 'monitor debounces tunnel-down (5x)'
Assert ($mon -match 'Invoke-EmergencyUnbrick') 'monitor has emergency unbrick'
Assert ($rep -match 'v13\.0|Repair Script v13') 'repair.ps1 version v13.0'
Assert ($rep -match 'deferring block to monitor') 'repair fail-open on zombie'
Assert ($rep -match 'Test-BootGrace') 'repair respects BootGrace'
Assert ($k2 -match 'UnbrickUntil') 'kurtar2 sets UnbrickUntil cooldown'
Assert ($k2 -match 'Disable-ScheduledTask') 'kurtar2 disables tasks'
Assert ($k2 -match 'FromAuto') 'kurtar2 supports auto mode'
Assert ($wd -match 'Invoke-GentleUnbrick') 'watchdog has gentle unbrick'
Assert ($wd -match 'streak') 'watchdog graduated response'
Assert (Test-Path 'C:\WireGuard\resume-after-unbrick.ps1') 'resume-after-unbrick.ps1 deployed'

foreach ($tn in @('WG-KillSwitch', 'WG-RepairTask', 'WG-RebootVerify', 'WG-InternetWatchdog')) {
    $t = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
    Assert ($t -and $t.State -in @('Ready', 'Running')) "Task $tn active"
}
if (Test-Path 'C:\WireGuard\nssm.exe') {
    $svcSt = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
    Assert ($svcSt -match 'RUNNING') 'WGKillSwitchSvc RUNNING'
}
Assert ((Get-MonitorCount) -ge 1) 'Monitor process running'
Assert ((Get-MonitorCount) -le 1) 'Single monitor instance'

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

Assert (Test-Path 'C:\ProgramData\WGKillSwitchGuard') 'Anti-tamper guard vault present'
$guardCount = (Get-ChildItem 'C:\ProgramData\WGKillSwitchGuard' -Force -EA SilentlyContinue | Measure-Object).Count
Assert ($guardCount -ge 8) "Guard vault file count >= 8 (got $guardCount)"

Assert (Test-Internet) 'Post-check: TCP internet still working'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SAFE LIVE: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  SAFE LIVE VERIFY: PASSED" -ForegroundColor Green
exit 0