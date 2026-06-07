#Requires -RunAsAdministrator
# WireGuard Kill Switch - ULTIMATE LIVE STRESS TEST (v11.0 gate)
# Simulates: process kill, tunnel drop, firewall tamper, network/modem change, reinstall, layer recovery
param(
    [int]$PassCount = 1,
    [switch]$Quick
)
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()
$pass = 0
$total = 0
$TUNNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$CONFIG = 'C:\WireGuard\wgcf-profile.conf'
$WG = 'C:\Program Files\WireGuard\wireguard.exe'

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
function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Tcp443 '1.1.1.1') -and (Test-Tcp443 '8.8.8.8') }
function Get-MonitorCount {
    $n = 0
    foreach ($shell in @('powershell','pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $n++ }
            } catch {}
        }
    }
    return $n
}
function Invoke-Repair {
    if (Test-Path 'C:\WireGuard\repair.ps1') {
        Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\WireGuard\repair.ps1' -WindowStyle Hidden -EA SilentlyContinue
    }
}
function Wait-Healthy([int]$sec = 60) {
    $w = 0
    while ($w -lt $sec -and -not (Test-SafeToOpen)) {
        if ($w -eq 15) { Invoke-Repair }
        Start-Sleep 3; $w += 3
    }
    return (Test-SafeToOpen)
}
function Wait-Monitor([int]$sec = 60) {
    $w = 0
    while ($w -lt $sec) {
        if ((Get-MonitorCount) -ge 1) { return $true }
        if ($w -in @(5, 20, 40)) { Invoke-Repair }
        Start-Sleep 3; $w += 3
    }
    return ((Get-MonitorCount) -ge 1)
}
function Wait-Block([int]$sec = 30) {
    $w = 0
    while ($w -lt $sec) {
        $o = netsh advfirewall firewall show rule name=KS-Block-WiFi-Out 2>&1 | Out-String
        if ($o -match 'Enabled:\s+Yes') { return $true }
        Start-Sleep 2; $w += 2
    }
    return $false
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  ULTIMATE STRESS TEST (v11.0)" -ForegroundColor Cyan
Write-Host "  Passes: $PassCount  Quick: $Quick" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

for ($passNum = 1; $passNum -le $PassCount; $passNum++) {
    Write-Host "--- PASS $passNum / $PassCount ---" -ForegroundColor Yellow

    # [1] Baseline healthy
    Assert (Test-SafeToOpen) "Baseline: SafeToOpen healthy"
    Assert ((Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue).Version -ge '11.0') "Baseline: registry version 11.0+"

    # [2] Kill monitor — should respawn
    Write-Host '[stress] Kill monitor process...' -ForegroundColor Gray
    Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.CommandLine -match 'monitor\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Assert (Wait-Monitor 45) "Recovery: monitor respawned after kill"
    if (-not $Quick) { Assert (Wait-Healthy 90) "Recovery: healthy after monitor kill" }

    # [3] Stop tunnel — block must engage
    Write-Host '[stress] Stop tunnel service...' -ForegroundColor Gray
    sc.exe stop $TUNNEL_SVC 2>$null | Out-Null
    $blockOk = $false
    for ($bw = 0; $bw -lt 20; $bw++) {
        Start-Sleep 2
        $o = netsh advfirewall firewall show rule name=KS-Block-WiFi-Out 2>&1 | Out-String
        if ($o -match 'Enabled:\s+Yes') { $blockOk = $true; break }
        if ($bw -eq 5) { Invoke-Repair }
    }
    Assert $blockOk "KillSwitch: block engaged within 40s of tunnel stop"
    if (-not $Quick) {
        $leak = Test-Tcp443 '93.184.216.34'
        Assert (-not $leak) "KillSwitch: non-WARP TCP blocked while tunnel down"
    }
    & $WG /installtunnelservice $CONFIG 2>$null | Out-Null
    Start-Sleep 8
    if (-not (Test-TunnelRunning)) { sc.exe start $TUNNEL_SVC 2>$null | Out-Null; Start-Sleep 5 }
    Assert (Wait-Healthy 60) "Recovery: tunnel restored and healthy"

    # [4] Firewall tamper — delete block rule
    Write-Host '[stress] Delete KS-Block-WiFi-Out...' -ForegroundColor Gray
    netsh advfirewall firewall delete rule name=KS-Block-WiFi-Out 2>$null | Out-Null
    sc.exe stop $TUNNEL_SVC 2>$null | Out-Null
    function Test-AnyBlockRule {
        foreach ($br in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
            $o = netsh advfirewall firewall show rule name=$br 2>&1 | Out-String
            if ($o -match 'Enabled:\s+Yes') { return $true }
        }
        return $false
    }
    $tamperOk = $false
    for ($tw = 0; $tw -lt 15; $tw++) {
        Start-Sleep 2
        if (Test-AnyBlockRule) { $tamperOk = $true; break }
        if ($tw -eq 2) { Invoke-Repair }
    }
    Assert $tamperOk "Tamper: block rule restored after delete+stop"
    & $WG /installtunnelservice $CONFIG 2>$null | Out-Null
    Start-Sleep 8
    Wait-Healthy 60 | Out-Null

    # [5] DNS rule tamper
    netsh advfirewall firewall delete rule name=KS-DNS-Block 2>$null | Out-Null
    Start-Sleep 8
    if (Test-Path 'C:\WireGuard\repair.ps1') { Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\WireGuard\repair.ps1' -WindowStyle Hidden }
    Start-Sleep 12
    $dns = netsh advfirewall firewall show rule name=KS-DNS-Block 2>&1 | Out-String
    Assert ($dns -match 'Enabled:\s+Yes') "Tamper: KS-DNS-Block restored by repair"

    # [6] Modem/network simulation — DHCP renew + DNS flush
    if (-not $Quick) {
        Write-Host '[stress] Network/modem simulation (DHCP renew)...' -ForegroundColor Gray
        ipconfig /flushdns 2>$null | Out-Null
        ipconfig /renew 2>$null | Out-Null
        Start-Sleep 10
        Assert (Test-SafeToOpen) "Network: healthy after DHCP renew"
    }

    # [7] Wi-Fi adapter bounce (if present)
    $wifi = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Name -eq 'Wi-Fi' -and $_.Status -eq 'Up' }
    if ($wifi -and -not $Quick) {
        Write-Host '[stress] Wi-Fi adapter disable/enable...' -ForegroundColor Gray
        Disable-NetAdapter -Name 'Wi-Fi' -Confirm:$false -EA SilentlyContinue
        Start-Sleep 5
        Enable-NetAdapter -Name 'Wi-Fi' -Confirm:$false -EA SilentlyContinue
        Start-Sleep 15
        Assert (Wait-Healthy 90) "Network: recovered after Wi-Fi bounce"
    }

    # [8] Config IPv6 injection — repair should fix on next install/repair
    if (-not $Quick) {
        Write-Host '[stress] Inject ::/0 into config then repair...' -ForegroundColor Gray
        icacls C:\WireGuard /grant "BUILTIN\Administrators:(OI)(CI)F" /T /C /Q 2>$null | Out-Null
        $cfg = Get-Content $CONFIG -Raw
        if ($cfg -notmatch '::/0') {
            $cfg = $cfg -replace 'AllowedIPs = 0.0.0.0/0', 'AllowedIPs = 0.0.0.0/0, ::/0'
            Set-Content $CONFIG $cfg -Encoding UTF8 -Force
        }
        echo "" | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'install.ps1') 2>$null | Out-Null
        Start-Sleep 5
        $cfg2 = Get-Content $CONFIG -Raw
        Assert ($cfg2 -notmatch '::/0') "Config: IPv6 stripped after reinstall"
        Assert (Wait-Healthy 60) "Config: healthy after IPv6 strip reinstall"
    }

    # [9] Double install (upgrade path)
    Write-Host '[stress] Double install.ps1 run...' -ForegroundColor Gray
    echo "" | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'install.ps1') 2>$null | Out-Null
    Start-Sleep 8
    Assert (Test-Path 'C:\WireGuard\kurtar.bat') "Install: kurtar.bat present after double install"
    Assert ((Get-MonitorCount) -le 1) "Install: single monitor after double install"
    Assert (Wait-Healthy 120) "Install: healthy after double install"

    # [10] WMI layer present
    $wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue |
        Where-Object { $_.Name -eq 'WGMonitorFilter' }
    Assert ($null -ne $wmi) "Layers: WMI subscription active"

    # [11] Service layer
    $svc = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
    Assert ($svc -match 'RUNNING') "Layers: WGKillSwitchSvc running"

    # [12] Security audit subprocess
    if (-not $Quick) {
        echo "" | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'install.ps1') 2>$null | Out-Null
        Wait-Monitor 45 | Out-Null
        Wait-Healthy 90 | Out-Null
        $audit = Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File',(Join-Path $PSScriptRoot 'security-audit.ps1') -Wait -PassThru -WindowStyle Hidden
        Assert ($audit.ExitCode -eq 0) "Audit: security-audit.ps1 exit 0"
    }

    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  STRESS RESULT: $pass / $total passed" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    Write-Host "  FAILURES:" -ForegroundColor Red
    $failures | Select-Object -Unique | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  ULTIMATE STRESS GATE: PASSED" -ForegroundColor Green
exit 0