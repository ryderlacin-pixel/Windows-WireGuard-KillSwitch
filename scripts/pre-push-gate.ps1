#Requires -Version 5.1
<#
.SYNOPSIS
  Mandatory gate before any GitHub push. Does NOT run install.ps1.

.USAGE
  .\scripts\pre-push-gate.ps1
  Exit 0 = safe to push. Exit 1 = do NOT push.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Gate([bool]$Ok, [string]$Label) {
    if ($Ok) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label" -ForegroundColor Red; $failures.Add($Label) }
}

Write-Host "`n=== PRE-PUSH GATE (no live install) ===" -ForegroundColor Cyan

# 1) Full CI (test-suite x3 + parse all scripts)
Write-Host "`n>> CI quality gate" -ForegroundColor Yellow
& (Join-Path $PSScriptRoot 'ci.ps1')
if ($LASTEXITCODE -ne 0) { $failures.Add('ci.ps1 failed') }

# 2) Version consistency
Write-Host "`n>> Version consistency" -ForegroundColor Yellow
$constants = Get-Content (Join-Path $repoRoot 'lib\Install-Constants.ps1') -Raw -Encoding UTF8
$install   = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw -Encoding UTF8
if ($constants -match "\`$WG_KS_VERSION = '([^']+)'") { $ver = $Matches[1] } else { $ver = '' }
Assert-Gate ($ver -eq '15.2.9') "WG_KS_VERSION = 15.2.9 (got '$ver')"
Assert-Gate ($install -match 'v15\.2\.9') 'install.ps1 header version'
Assert-Gate (-not ($constants -match '[^\x09\x0A\x0D\x20-\x7E]')) 'Install-Constants.ps1: ASCII-only (no mojibake)'

# 3) Critical code-review invariants (static)
Write-Host "`n>> Critical invariants" -ForegroundColor Yellow
$helpers = Get-Content (Join-Path $repoRoot 'lib\Install-Helpers.ps1') -Raw -Encoding UTF8
$gen     = Get-Content (Join-Path $repoRoot 'lib\Install-GeneratedScripts.ps1') -Raw -Encoding UTF8
$privacy = Get-Content (Join-Path $repoRoot 'lib\Install-Privacy.ps1') -Raw -Encoding UTF8
$tasks   = Get-Content (Join-Path $repoRoot 'lib\Install-TasksAndWmi.ps1') -Raw -Encoding UTF8
$main06  = Get-Content (Join-Path $repoRoot 'lib\Install-MainSteps-0-6.ps1') -Raw -Encoding UTF8
$main1820 = Get-Content (Join-Path $repoRoot 'lib\Install-MainSteps-18-20.ps1') -Raw -Encoding UTF8
$emerBat = Get-Content (Join-Path $repoRoot 'emergency-reset.bat') -Raw -Encoding UTF8

Assert-Gate ($helpers -match '\$acquired = Wait-NamedMutex') 'Log() mutex acquire flag'
Assert-Gate ($helpers -match '\$mutex\.Dispose\(\)') 'Log() mutex Dispose'
Assert-Gate ($gen -notmatch 'function IsMainMonitor') 'no IsMainMonitor in generated scripts'
Assert-Gate ($gen -match 'function Test-IsMainMonitor') 'Test-IsMainMonitor in generated scripts'
Assert-Gate ($privacy -match "\\\[Startup\\\]") 'GPO regex escaped [Startup]'
Assert-Gate ($tasks -match 'Split-Path \$PSScriptRoot -Parent') 'TasksAndWmi uses repo root not lib/'
Assert-Gate ($tasks -match '\$installScripts = Join-Path \$INSTALL_DIR') 'audit scripts deploy path (Join-Path INSTALL_DIR scripts)'
Assert-Gate ($main06 -match 'name=""KS-Dnscrypt-EXE""') 'dnscrypt firewall rule quoting'
$adminIdx = $install.IndexOf('Administrator')
$dryRunIdx = $install.IndexOf('$script:InstallDryRun')
$dotSourceIdx = $install.IndexOf('foreach ($mod in $LibModules)')
Assert-Gate (($adminIdx -ge 0) -and ($dryRunIdx -gt $adminIdx) -and ($dotSourceIdx -gt $dryRunIdx)) 'admin check before dot-source'
Assert-Gate ($helpers -match 'Register-RepairTaskDualTrigger') 'repair task dual trigger registration'
Assert-Gate ($helpers -match 'Refresh-RegistryTaskBackups') 'registry task backup refresh'
Assert-Gate ($helpers -match 'Backup-TunnelConfig') 'tunnel config backup before reinstall'
Assert-Gate ($helpers -match 'Test-SafeToOpen') 'deferred privacy guards require SafeToOpen'
Assert-Gate ($main1820 -match 'Set-PostInstallGraceRegistry') 'STEP 19 post-install grace'
Assert-Gate ($gen -match 'Test-PostInstallGrace') 'monitor respects post-install grace'
Assert-Gate ($emerBat -match '^@echo off') 'emergency-reset.bat is real batch file'

# 4) File coverage gate (every production file, anti-hollow)
Write-Host "`n>> File coverage (anti-hollow)" -ForegroundColor Yellow
& (Join-Path $PSScriptRoot 'file-coverage-test.ps1')
if ($LASTEXITCODE -ne 0) { $failures.Add('file-coverage-test.ps1 failed') }
else { Write-Host '  [OK]   file-coverage-test.ps1' -ForegroundColor Green }

# 5) Final line audit (every repo file, 0 ERROR)
Write-Host "`n>> Final line audit (dot-by-dot)" -ForegroundColor Yellow
& (Join-Path $PSScriptRoot 'final-line-audit.ps1')
if ($LASTEXITCODE -ne 0) { $failures.Add('final-line-audit.ps1 failed (see audit-results/)') }
else { Write-Host '  [OK]   final-line-audit.ps1 (0 ERROR)' -ForegroundColor Green }

# 6) Release notes exist for current version
Write-Host "`n>> Release artifact" -ForegroundColor Yellow
Assert-Gate (Test-Path (Join-Path $repoRoot 'docs\releases\v15.2.9.md')) 'docs/releases/v15.2.9.md exists'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'PRE-PUSH GATE: PASSED - safe to push to GitHub' -ForegroundColor Green
    Write-Host '(This gate does NOT run install.ps1 on this machine.)' -ForegroundColor Gray
    exit 0
}
Write-Host "PRE-PUSH GATE: FAILED ($($failures.Count) checks)" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
Write-Host 'Do NOT push until all checks pass.' -ForegroundColor Yellow
exit 1