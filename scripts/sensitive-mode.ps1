#Requires -RunAsAdministrator
# v15 sensitive browsing launcher — starts Tor Browser only (WARP entry still visible to Cloudflare)
$ErrorActionPreference = 'Continue'

function Find-TorBrowserExe {
    foreach ($root in @(
        (Join-Path $env:ProgramFiles 'Tor Browser'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tor Browser'),
        (Join-Path $env:LOCALAPPDATA 'Tor Browser'),
        (Join-Path $env:USERPROFILE 'Desktop\Tor Browser'),
        (Join-Path $env:USERPROFILE 'Downloads\Tor Browser')
    )) {
        $exe = Join-Path $root 'Browser\firefox.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

Write-Host ''
Write-Host '  HASSAS TARAMA MODU (v15)' -ForegroundColor Cyan
Write-Host '  Tor Browser uzerinden hassas tarama. Normal tarayicilari kullanmayin.' -ForegroundColor Gray
Write-Host '  Not: WireGuard/WARP giris noktasi Cloudflare tarafindan gorulebilir.' -ForegroundColor Yellow
Write-Host ''

$torExe = Find-TorBrowserExe
if (-not $torExe) {
    Write-Host '  [ERR] Tor Browser bulunamadi. Once scripts/install-tor-browser.ps1 calistirin.' -ForegroundColor Red
    exit 1
}

Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'SensitiveModeLastLaunch' (Get-Date -Format 'o') -Force -EA SilentlyContinue
Start-Process -FilePath $torExe -WorkingDirectory (Split-Path $torExe -Parent)
Write-Host "  [OK] Tor Browser baslatildi: $torExe" -ForegroundColor Green
exit 0