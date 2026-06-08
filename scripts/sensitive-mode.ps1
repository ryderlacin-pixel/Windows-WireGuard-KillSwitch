#Requires -RunAsAdministrator
# v15.1 sensitive browsing — one-step Tor install + harden + launch
$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host '  HASSAS TARAMA MODU (v15.1)' -ForegroundColor Cyan
Write-Host '  Tor Browser uzerinden hassas tarama. Normal tarayicilari kullanmayin.' -ForegroundColor Gray
Write-Host '  Not: WireGuard/WARP giris noktasi Cloudflare tarafindan gorulebilir.' -ForegroundColor Yellow
Write-Host ''

$ensureScript = Join-Path $PSScriptRoot 'ensure-tor-sensitive.ps1'
if (-not (Test-Path $ensureScript)) {
    $ensureScript = 'C:\WireGuard\ensure-tor-sensitive.ps1'
}
if (-not (Test-Path $ensureScript)) {
    Write-Host '  [ERR]  ensure-tor-sensitive.ps1 bulunamadi. install.ps1 ile v15 kurun.' -ForegroundColor Red
    exit 1
}

try {
    $out = & $ensureScript
    if ($out -is [System.Array]) { $torExe = $out | Select-Object -Last 1 } else { $torExe = $out }
} catch {
    Write-Host "  [ERR]  Tor hazirlik hatasi: $_" -ForegroundColor Red
    exit 1
}

if (-not $torExe -or -not (Test-Path $torExe)) {
    Write-Host '  [ERR]  Tor Browser baslatilamadi.' -ForegroundColor Red
    exit 1
}

Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'SensitiveModeLastLaunch' (Get-Date -Format 'o') -Force -EA SilentlyContinue
Start-Process -FilePath $torExe -WorkingDirectory (Split-Path $torExe -Parent)
Write-Host "  [OK] Tor Browser baslatildi: $torExe" -ForegroundColor Green
exit 0