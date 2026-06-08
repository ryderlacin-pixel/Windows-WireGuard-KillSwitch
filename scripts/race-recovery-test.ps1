#Requires -RunAsAdministrator
# v11.5 LIVE GATE (OPT-IN ONLY) - simulates monitor/repair tunnel reinstall race.
# NEVER run without -ConfirmDisruptsInternet. Always restores internet in finally block.
param(
    [switch]$ConfirmDisruptsInternet,
    [int]$RecoveryTimeoutSec = 120,
    [int]$RepairSpawnCount = 5
)
$ErrorActionPreference = 'Continue'

if (-not $ConfirmDisruptsInternet) {
    Write-Host ''
    Write-Host 'ABORT: This test STOPS the tunnel and DISRUPTS internet.' -ForegroundColor Red
    Write-Host '       Only run manually with: -ConfirmDisruptsInternet' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

$failures = [System.Collections.Generic.List[string]]::new()
$pass = 0
$total = 0
$TUNNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$TUNNEL_NAME = 'wgcf-profile'
$CONFIG = 'C:\WireGuard\wgcf-profile.conf'
$WG = 'C:\Program Files\WireGuard\wireguard.exe'
$LOG = 'C:\WireGuard\killswitch.log'
$REPAIR = 'C:\WireGuard\repair.ps1'
$KURTAR = 'C:\WireGuard\kurtar.ps1'

function Assert([bool]$cond, [string]$name) {
    $script:total++
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Test-TunnelRunning {
    return ([bool](( & sc.exe query $TUNNEL_SVC 2>$null) -match 'RUNNING'))
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

function Get-LogLinesSince([datetime]$since) {
    if (-not (Test-Path $LOG)) { return @() }
    try {
        return Get-Content $LOG -Encoding UTF8 -EA Stop | Where-Object {
            if ($_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                try { [datetime]$Matches[1] -ge $since } catch { $false }
            } else { $false }
        }
    } catch { return @() }
}

function Restore-Internet {
    Write-Host '[restore] Guaranteeing internet before exit...' -ForegroundColor Yellow
    foreach ($r in @('KS-Block-WiFi-Out', 'KS-Block-Ethernet-Out', 'KS-Block-RemoteAccess-Out', 'KS-Block-PPP-Out')) {
        netsh advfirewall firewall delete rule name="$r" 2>$null | Out-Null
    }
    netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>$null | Out-Null
    Clear-DnsClientCache -EA SilentlyContinue
    if (Test-Path $KURTAR) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $KURTAR 2>$null | Out-Null
    } elseif ((Test-Path $WG) -and (Test-Path $CONFIG) -and -not (Test-TunnelRunning)) {
        & $WG /uninstalltunnelservice $TUNNEL_NAME 2>$null | Out-Null
        Start-Sleep 3
        & $WG /installtunnelservice $CONFIG 2>$null | Out-Null
        & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
        Start-Sleep 10
    }
}

$raceStart = Get-Date
$exitCode = 1

try {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  RACE RECOVERY TEST (v11.5 - OPT IN)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $repRaw = Get-Content $REPAIR -Raw -EA SilentlyContinue
    $svcRaw = Get-Content 'C:\WireGuard\service-monitor.ps1' -Raw -EA SilentlyContinue
    Assert ($repRaw -match 'deferring reinstall') 'Live repair: deferral guard'
    Assert ($svcRaw -match 'tunnel recovery delegated') 'Live SVC: delegates to monitor'

    Assert (Test-SafeToOpen) 'Baseline: tunnel + internet healthy'
    Assert ((Get-MonitorCount) -ge 1) 'Baseline: monitor running'
    if (-not (Test-SafeToOpen)) { throw 'Unhealthy baseline' }

    Write-Host '[race] Stopping tunnel + spawning concurrent repairs...' -ForegroundColor Gray
    $raceStart = Get-Date
    sc.exe stop $TUNNEL_SVC 2>$null | Out-Null
    Start-Sleep -Seconds 2
    for ($i = 1; $i -le $RepairSpawnCount; $i++) {
        if (Test-Path $REPAIR) {
            Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File', $REPAIR -WindowStyle Hidden -EA SilentlyContinue
        }
        Start-Sleep -Milliseconds 400
    }

    $blockOk = $false
    for ($bw = 0; $bw -lt 20; $bw++) {
        Start-Sleep -Seconds 2
        $o = netsh advfirewall firewall show rule name=KS-Block-WiFi-Out 2>&1 | Out-String
        if ($o -match 'Enabled:\s+Yes') { $blockOk = $true; break }
    }
    Assert $blockOk 'KillSwitch: block engaged within 40s'

    Write-Host "[race] Waiting up to ${RecoveryTimeoutSec}s for automatic recovery..." -ForegroundColor Gray
    $recovered = $false
    $w = 0
    while ($w -lt $RecoveryTimeoutSec) {
        if (Test-SafeToOpen) { $recovered = $true; break }
        Start-Sleep -Seconds 3
        $w += 3
    }
    Assert $recovered "Recovery: SafeToOpen within ${RecoveryTimeoutSec}s"

    Start-Sleep -Seconds 3
    $lines = Get-LogLinesSince $raceStart
    $deferCount = ($lines | Where-Object { $_ -match 'deferring reinstall|tunnel recovery delegated' }).Count
    $criticalCount = ($lines | Where-Object { $_ -match 'CRITICAL: Tunnel could not be reinstalled' }).Count
    Assert ($deferCount -ge 1) "Log: deferred to monitor (count=$deferCount)"
    Assert ($criticalCount -eq 0) "Log: zero reinstall CRITICAL (count=$criticalCount)"

    $exitCode = if ($failures.Count -eq 0) { 0 } else { 1 }
} catch {
    $failures.Add("Exception: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    Restore-Internet
    if (-not (Test-Internet)) {
        Write-Host '[restore] FAILED - internet still down. Check connection manually.' -ForegroundColor Red
        $exitCode = 1
    } else {
        Write-Host '[restore] Internet verified OK' -ForegroundColor Green
    }
}

Write-Host "`n  RACE TEST: $pass / $total passed" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
exit $exitCode