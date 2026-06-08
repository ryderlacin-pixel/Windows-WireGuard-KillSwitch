#Requires -RunAsAdministrator
# Manual DNS lockdown - NOT run automatically by install/repair (v15.3.0)
# Entry: scripts/enable-dns-lockdown.ps1
# Prereq: install.ps1 deployed dns-lockdown-guard.ps1 to C:\WireGuard
param([switch]$NoPause)
$ErrorActionPreference = 'Continue'

$guard = 'C:\WireGuard\dns-lockdown-guard.ps1'
if (-not (Test-Path $guard)) {
    Write-Host '[ERR] dns-lockdown-guard.ps1 not found. Run install.ps1 first.' -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

function Test-AdminElevation {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host ' Manual DNS lockdown (all adapters -> 127.0.0.1)' -ForegroundColor Yellow
Write-Host ' Requires: WireGuard tunnel RUNNING + dnscrypt on 127.0.0.1:53 + working internet' -ForegroundColor Gray
if (-not (Test-AdminElevation)) {
    Write-Host '[ERR] Administrator required.' -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}
Write-Host ''

& $guard
$exitCode = $LASTEXITCODE
if ($exitCode -eq 0) {
    Write-Host '[OK] DNS lockdown guard completed (see killswitch.log)' -ForegroundColor Green
} else {
    Write-Host "[WARN] DNS lockdown guard exited with code $exitCode (likely deferred - check log)" -ForegroundColor Yellow
}
if (-not $NoPause) { pause }
exit $exitCode