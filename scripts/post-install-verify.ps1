#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert([bool]$cond, [string]$msg) {
    if (-not $cond) { $failures.Add($msg) }
    else { Write-Host "  [OK] $msg" -ForegroundColor Green }
}

Write-Host '=== POST-INSTALL VERIFICATION (v12.0) ===' -ForegroundColor Cyan

$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
Assert ($reg.Version -ge '12.0') "Registry version 12.0+ (got $($reg.Version))"

foreach ($f in @('monitor.ps1','repair.ps1','service-monitor.ps1','wmi-repair.ps1','wgcf-profile.conf')) {
    Assert (Test-Path "C:\WireGuard\$f") "File exists: $f"
}

Assert (-not (Test-Path 'C:\WireGuard\servis-monitor.ps1')) 'Old servis-monitor.ps1 removed'
Assert (-not (Test-Path 'C:\WireGuard\onarim.ps1')) 'Old onarim.ps1 removed'

function Test-RuleEnabled([string]$RuleName) {
    $o = netsh advfirewall firewall show rule name=$RuleName 2>&1 | Out-String
    return ($o -match 'Enabled:\s+Yes')
}
function Test-RuleAbsent([string]$RuleName) {
    $o = netsh advfirewall firewall show rule name=$RuleName 2>&1 | Out-String
    return ($o -match 'No rules match')
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
    foreach ($h in @('1.1.1.1','1.0.0.1','8.8.8.8')) { if (Test-TcpHost $h 443) { $hits++ } }
    return ($hits -ge 2)
}
function Test-TunnelRunning {
    return ([bool]((& sc.exe query 'WireGuardTunnel$wgcf-profile' 2>$null) -match 'RUNNING'))
}
$safe = (Test-TunnelRunning) -and (Test-Internet)
Assert $safe "Test-SafeToOpen (tunnel + internet)"

Assert (Test-RuleEnabled 'KS-WARP-Server-Out') "Firewall rule enabled: KS-WARP-Server-Out"
if ($safe) {
    foreach ($r in @('KS-DNS-Block','KS-DNS-Block-TCP')) {
        $o = netsh advfirewall firewall show rule name=$r 2>$null | Out-String
        Assert ($o -match 'Enabled:\s+No') "DNS leak OFF when healthy: $r"
    }
} else {
    foreach ($r in @('KS-DNS-Block','KS-DNS-Block-TCP')) {
        Assert (Test-RuleEnabled $r) "DNS leak ON when blocked: $r"
    }
}
if ($safe) {
    foreach ($r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        Assert (Test-RuleAbsent $r) "Outbound block absent (healthy): $r"
    }
} else {
    foreach ($r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        Assert (Test-RuleEnabled $r) "Firewall block active (unhealthy): $r"
    }
}
$ipv6Reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents -EA SilentlyContinue
Assert ($ipv6Reg -and $ipv6Reg.DisabledComponents -eq 0xFF) 'IPv6 disabled via registry (DisabledComponents=0xFF)'

$monitors = @()
for ($mw = 0; $mw -lt 12; $mw++) {
    $monitors = @()
    foreach ($shell in @('powershell','pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $monitors += $_ }
            } catch {}
        }
    }
    if ($monitors.Count -ge 1) { break }
    Start-Sleep -Seconds 3
}
if ($monitors.Count -gt 1) {
    $monitors | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object {
        Stop-Process -Id $_.Id -Force -EA SilentlyContinue
    }
    Start-Sleep 2
    $monitors = @()
    foreach ($shell in @('powershell','pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $monitors += $_ }
            } catch {}
        }
    }
}
Assert (($monitors | Measure-Object).Count -eq 1) "Exactly one main monitor (count=$(($monitors | Measure-Object).Count))"

$bad = Get-Process powershell -EA SilentlyContinue | Where-Object {
    try {
        $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
        $c -match 'servis-monitor\.ps1'
    } catch { $false }
}
Assert (-not $bad) 'No servis-monitor.ps1 process'

foreach ($tn in @('WG-KillSwitch','WG-RepairTask')) {
    $t = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
    Assert ($t -and $t.State -in @('Ready','Running')) "Task $tn active ($($t.State))"
}

if (Test-Path 'C:\WireGuard\nssm.exe') {
    $svc = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
    Assert ($svc -match 'RUNNING') 'WGKillSwitchSvc RUNNING'
} else {
    Assert $true 'WGKillSwitchSvc skipped (NSSM not installed)'
}

$wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue | Where-Object { $_.Name -eq 'WGMonitorFilter' }
Assert ($null -ne $wmi) 'WMI subscription active'

# v11.0 script version + self-repair checks
$monRaw = Get-Content 'C:\WireGuard\monitor.ps1' -Raw -EA SilentlyContinue
Assert ($monRaw -match 'v12\.0') 'monitor.ps1 is v12.0'
Assert ($monRaw -match 'Test-SafeToOpen') 'monitor.ps1 has Test-SafeToOpen'
Assert ($monRaw -match 'Test-InstallInProgress|monitor\.pid') 'monitor has install-safe logic'

$repRaw = Get-Content 'C:\WireGuard\repair.ps1' -Raw -EA SilentlyContinue
Assert ($repRaw -match 'Repair-ConfigIntegrity') 'repair.ps1 has Repair-ConfigIntegrity'
Assert ($repRaw -match 'Repair-EssentialFirewall') 'repair.ps1 has Repair-EssentialFirewall'
Assert ($repRaw -match 'Test-NetworkChanged') 'repair.ps1 has Test-NetworkChanged'
Assert ($repRaw -match 'Test-MainMonitorActive') 'repair.ps1 defers to active monitor'
Assert ($repRaw -match 'deferring reinstall') 'repair.ps1 has deferral guard'
Assert ($repRaw -match 'Try-ReinstallTunnel') 'repair.ps1 uses mutex reinstall'

$svcRaw = Get-Content 'C:\WireGuard\service-monitor.ps1' -Raw -EA SilentlyContinue
Assert ($svcRaw -match 'tunnel recovery delegated') 'service-monitor delegates tunnel recovery'

$wmiRaw = Get-Content 'C:\WireGuard\wmi-repair.ps1' -Raw -EA SilentlyContinue
Assert ($wmiRaw -match 'wmi-cooldown') 'wmi-repair.ps1 has WMI cooldown'

& sc.exe config 'WireGuardTunnel$wgcf-profile' start= delayed-auto 2>$null | Out-Null
$qc = & sc.exe qc 'WireGuardTunnel$wgcf-profile' 2>$null | Out-String
Assert ($qc -match 'DELAYED') 'Tunnel service delayed-auto-start configured'

Assert (-not (Test-Path 'C:\WireGuard\kurtar.bat')) 'kurtar.bat removed (v13.2+)'
Assert (-not (Test-Path 'C:\WireGuard\kurtar2.ps1')) 'kurtar2.ps1 removed (v13.2+)'
Assert (-not (Test-Path 'C:\WireGuard\install.inprogress')) 'install lock cleared after install'

$cfg = Get-Content 'C:\WireGuard\wgcf-profile.conf' -Raw -EA SilentlyContinue
Assert ($cfg -notmatch '::/0') 'Config has no ::/0 (IPv6 stripped)'

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "FAILED $($failures.Count):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL POST-INSTALL CHECKS PASSED' -ForegroundColor Green
exit 0