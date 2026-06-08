#Requires -RunAsAdministrator
# Finish interrupted v14 install without full reinstall (kill-switch safe).
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$installPs1 = Join-Path $repo 'install.ps1'
$INSTALL_LOCK = 'C:\WireGuard\install.inprogress'
$NSSM = 'C:\WireGuard\nssm.exe'
$WG_SVC = 'WGKillSwitchSvc'

function OK($m) { Write-Host " [OK]   $m" -ForegroundColor Green }
function WARN($m) { Write-Host " [WARN] $m" -ForegroundColor Yellow }

Write-Host "`n=== RESUME v14.0 (interrupted install) ===`n" -ForegroundColor Cyan

if (Test-Path $INSTALL_LOCK) {
    Remove-Item $INSTALL_LOCK -Force -EA SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
    OK 'install.inprogress cleared'
} else { OK 'install lock already clear' }

if (Test-Path $NSSM) {
    & $NSSM start $WG_SVC 2>$null | Out-Null
    & $NSSM start WG-DnscryptProxy 2>$null | Out-Null
    Start-Sleep 2
    $st = & sc.exe query $WG_SVC 2>&1 | Out-String
    if ($st -match 'RUNNING') { OK 'WGKillSwitchSvc RUNNING' }
    else { WARN 'WGKillSwitchSvc not RUNNING yet' }
    $dns = & sc.exe query WG-DnscryptProxy 2>&1 | Out-String
    if ($dns -match 'RUNNING') { OK 'WG-DnscryptProxy RUNNING' }
    else { WARN 'WG-DnscryptProxy not RUNNING - run -DnsLeakUpgradeOnly' }
} else { WARN 'nssm.exe missing - service start skipped' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -FullPrivacyUpgrade -NoPause | Out-Host
OK 'FullPrivacyUpgrade completed'

Write-Host "`nRun: .\scripts\leak-audit.ps1`n     .\scripts\safe-live-verify.ps1`n" -ForegroundColor Gray