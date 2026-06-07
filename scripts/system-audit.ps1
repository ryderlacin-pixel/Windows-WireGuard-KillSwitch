#Requires -RunAsAdministrator
Write-Host '=== WG Kill Switch System Audit ===' -ForegroundColor Cyan

$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
if ($reg) {
    Write-Host "Registry: v$($reg.Version) installed $($reg.InstalledDate) custom=$($reg.CustomMode)"
} else {
    Write-Host 'Registry: WGKillSwitch not found'
}

foreach ($p in @('C:\WireGuard', 'C:\Users\seyit\Windows-WireGuard-KillSwitch')) {
    if (Test-Path $p) {
        Write-Host "`nDIR: $p" -ForegroundColor Yellow
        Get-ChildItem $p -EA SilentlyContinue | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
    } else {
        Write-Host "MISSING: $p"
    }
}

Write-Host "`nTunnel service:" -ForegroundColor Yellow
& sc.exe query 'WireGuardTunnel$wgcf-profile' 2>&1

Write-Host "`nScheduled tasks:" -ForegroundColor Yellow
foreach ($tn in @('WG-KillSwitch', 'WG-RepairTask')) {
    $t = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
    if ($t) { Write-Host "  $tn : $($t.State) triggers=$((($t.Triggers | Measure-Object).Count))" }
    else { Write-Host "  $tn : MISSING" }
}

Write-Host "`nWGKillSwitchSvc:" -ForegroundColor Yellow
& sc.exe query WGKillSwitchSvc 2>&1

Write-Host "`nRelated processes:" -ForegroundColor Yellow
foreach ($shell in @('powershell', 'pwsh')) {
    Get-Process $shell -EA SilentlyContinue | ForEach-Object {
        try {
            $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
            if ($c -match 'monitor\.ps1|repair\.ps1|service-monitor|wmi-repair|install\.ps1') {
                Write-Host "  PID $($_.Id) [$shell]: $c"
            }
        } catch {}
    }
}

Write-Host "`nFirewall rules (sample):" -ForegroundColor Yellow
foreach ($r in @('KS-Block-WiFi-Out', 'KS-Block-RemoteAccess-Out', 'KS-Block-PPP-Out', 'KS-WARP-Server-Out', 'KS-DNS-Block')) {
    $o = netsh advfirewall firewall show rule name=$r 2>&1 | Out-String
    if ($o -match 'No rules') { Write-Host "  $r : absent" }
    else { $enabled = if ($o -match 'Enabled:\s+Yes') { 'enabled' } else { 'disabled?' }; Write-Host "  $r : $enabled" }
}

$wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue | Where-Object { $_.Name -eq 'WGMonitorFilter' }
Write-Host "`nWMI WGMonitorFilter: $(if ($wmi) { 'ACTIVE' } else { 'missing' })"

if (Test-Path 'C:\WireGuard\killswitch.log') {
    Write-Host "`nLog tail:" -ForegroundColor Yellow
    Get-Content 'C:\WireGuard\killswitch.log' -Tail 8 -EA SilentlyContinue
}