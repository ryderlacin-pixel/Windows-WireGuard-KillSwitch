#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert([bool]$cond, [string]$msg) {
    if (-not $cond) { $failures.Add($msg) }
    else { Write-Host "  [OK] $msg" -ForegroundColor Green }
}

Write-Host '=== POST-INSTALL VERIFICATION (v10.8) ===' -ForegroundColor Cyan

$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
Assert ($reg.Version -eq '10.8') "Registry version 10.8 (got $($reg.Version))"

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

foreach ($r in @('KS-WARP-Server-Out','KS-DNS-Block','KS-DNS-Block-TCP')) {
    Assert (Test-RuleEnabled $r) "Firewall rule enabled: $r"
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
foreach ($shell in @('powershell','pwsh')) {
    Get-Process $shell -EA SilentlyContinue | ForEach-Object {
        try {
            $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
            if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $monitors += $_ }
        } catch {}
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

$svc = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
Assert ($svc -match 'RUNNING') 'WGKillSwitchSvc RUNNING'

$wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue | Where-Object { $_.Name -eq 'WGMonitorFilter' }
if ($wmi) { Assert $true 'WMI subscription active' }
else { Write-Host '  [WARN] WMI subscription missing (7 other layers active)' -ForegroundColor Yellow }

# Monitor script version check
$monRaw = Get-Content 'C:\WireGuard\monitor.ps1' -Raw -EA SilentlyContinue
Assert ($monRaw -match 'v10\.8') 'monitor.ps1 is v10.8'
Assert ($monRaw -match 'Test-SafeToOpen') 'monitor.ps1 has Test-SafeToOpen'
Assert ($monRaw -match 'Test-InstallInProgress|Test-ServerRulePresent') 'monitor has v10.8 install-safe logic'
Assert (Test-Path 'C:\WireGuard\kurtar.bat') 'kurtar.bat rescue script present'
Assert (-not (Test-Path 'C:\WireGuard\install.inprogress')) 'install lock cleared after install'

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "FAILED $($failures.Count):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL POST-INSTALL CHECKS PASSED' -ForegroundColor Green
exit 0