#Requires -RunAsAdministrator
# Roll back v14 Tor/dnscrypt layers to v13.5 kill-switch baseline (keeps kill switch intact).
$ErrorActionPreference = 'Continue'

function OK($m) { Write-Host " [OK]   $m" -ForegroundColor Green }
function WARN($m) { Write-Host " [WARN] $m" -ForegroundColor Yellow }

Write-Host "`n=== ROLLBACK v14 → v13.5 privacy baseline ===`n" -ForegroundColor Cyan
Write-Host " Kill switch, monitor, repair are NOT removed.`n" -ForegroundColor Gray

& sc.exe stop WG-DnscryptProxy 2>$null | Out-Null
& sc.exe delete WG-DnscryptProxy 2>$null | Out-Null
OK 'WG-DnscryptProxy service removed'

foreach ($f in @(
    'C:\WireGuard\dnscrypt-guard.ps1',
    'C:\WireGuard\tor-hardening-guard.ps1',
    'C:\WireGuard\tor-connectivity-monitor.ps1',
    'C:\WireGuard\leak-sentinel.ps1'
)) {
    if (Test-Path $f) { Remove-Item $f -Force -EA SilentlyContinue; OK "removed $(Split-Path $f -Leaf)" }
}

$cfg = 'C:\WireGuard\wgcf-profile.conf'
if (Test-Path $cfg) {
    $lines = Get-Content $cfg -Encoding UTF8
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*DNS\s*=') { 'DNS = 1.1.1.1, 1.0.0.1' } else { $line }
    }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($cfg, $out, $enc)
    OK 'WireGuard DNS restored to 1.1.1.1, 1.0.0.1 (restart tunnel)'
}

Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14DnsLeak' -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14Tor' -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14Enabled' -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'DnscryptState' -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'TorState' -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'LeakState' -EA SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'Version' '13.5' -Force -EA SilentlyContinue
OK 'Registry v14 flags cleared; Version=13.5'

Write-Host "`nRe-run .\install.ps1 -PrivacyUpgradeOnly to refresh v13.5 guards + integrity vault.`n" -ForegroundColor Gray