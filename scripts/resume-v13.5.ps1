#Requires -RunAsAdministrator
# Finish interrupted v13.5 install without full reinstall (kill-switch safe).
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$installPs1 = Join-Path $repo 'install.ps1'
$GPO_SCRIPT = 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\wg-startup.ps1'
$GPO_INI = 'C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini'
$INSTALL_LOCK = 'C:\WireGuard\install.inprogress'
$NSSM = 'C:\WireGuard\nssm.exe'
$WG_SVC = 'WGKillSwitchSvc'

function OK($m) { Write-Host " [OK]   $m" -ForegroundColor Green }
function WARN($m) { Write-Host " [WARN] $m" -ForegroundColor Yellow }

Write-Host "`n=== RESUME v13.5 (interrupted install) ===`n" -ForegroundColor Cyan

# 1) GPO version stamp (logic unchanged from v13.4 - safe patch)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'patch-gpo-v13.5.ps1') | Out-Host
OK 'GPO script version patched'

# 2) Clear install lock (fail-open: do not touch firewall blocks)
if (Test-Path $INSTALL_LOCK) {
    Remove-Item $INSTALL_LOCK -Force -EA SilentlyContinue
    Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
    OK 'install.inprogress cleared'
} else { OK 'install lock already clear' }

# 3) Start WGKillSwitchSvc if NSSM present
if (Test-Path $NSSM) {
    & $NSSM start $WG_SVC 2>$null | Out-Null
    Start-Sleep 2
    $st = & sc.exe query $WG_SVC 2>&1 | Out-String
    if ($st -match 'RUNNING') { OK 'WGKillSwitchSvc RUNNING' }
    else { WARN 'WGKillSwitchSvc not RUNNING yet (repair layers still active)' }
} else { WARN 'nssm.exe missing - service start skipped' }

# 4) Privacy + integrity refresh (no full install)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -PrivacyUpgradeOnly | Out-Host
OK 'PrivacyUpgradeOnly completed'

Write-Host "`nRun: .\scripts\safe-live-verify.ps1`n" -ForegroundColor Gray