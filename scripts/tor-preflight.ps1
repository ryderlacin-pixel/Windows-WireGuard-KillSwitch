#Requires -RunAsAdministrator
# v14 preflight — port 53 + dnscrypt readiness (read-only).
$ErrorActionPreference = 'Continue'

Write-Host "`n=== V14 PREFLIGHT ===`n" -ForegroundColor Cyan

$warn = 0
$dnsClient = Get-Service -Name Dnscache -EA SilentlyContinue
if ($dnsClient -and $dnsClient.Status -eq 'Running') {
    Write-Host ' [INFO] DNS Client (Dnscache) is running - may share 127.0.0.1:53' -ForegroundColor Gray
    Write-Host "        dnscrypt-proxy usually binds successfully; if not, stop Dnscache temporarily" -ForegroundColor Gray
}

try {
    $listeners = Get-NetUDPEndpoint -LocalPort 53 -EA SilentlyContinue | Where-Object { $_.LocalAddress -match '127\.0\.0\.1|0\.0\.0\.0|::' }
    if ($listeners) {
        Write-Host " [WARN] UDP port 53 already in use:" -ForegroundColor Yellow
        $listeners | ForEach-Object { Write-Host "        $($_.LocalAddress):$($_.LocalPort)" -ForegroundColor Yellow }
        $warn++
    } else {
        Write-Host ' [OK]   UDP 127.0.0.1:53 appears free' -ForegroundColor Green
    }
} catch {
    Write-Host " [INFO] Could not enumerate UDP 53 (continuing)" -ForegroundColor Gray
}

$reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
if ($reg -and $reg.Version -ge '14.0') {
    Write-Host " [OK]   Registry version $($reg.Version)" -ForegroundColor Green
} else {
    Write-Host " [WARN] Not yet on v14.0 (got $($reg.Version)) - run -DnsLeakUpgradeOnly first" -ForegroundColor Yellow
    $warn++
}

if ($warn -eq 0) {
    Write-Host "`nPreflight OK - safe to run .\install.ps1 -DnsLeakUpgradeOnly -NoPause`n" -ForegroundColor Green
    exit 0
}
Write-Host "`nPreflight: $warn warning(s) - review before upgrade`n" -ForegroundColor Yellow
exit 0