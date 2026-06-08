#Requires -Version 5.1
<#
.SYNOPSIS
  Optional post-install live smoke gate (read-only). Skips safely when stack not present.

.PARAMETER RequireStack
  Exit 1 when production stack is missing (for self-hosted / post-install verification).
#>
param(
    [switch]$RequireStack
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path $PSScriptRoot -Parent
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
$TUNNEL_SVC = 'WireGuardTunnel$wgcf-profile'

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-ProductionStackPresent {
    if (-not (Test-IsAdmin)) { return $false }
    if (-not (Test-Path 'C:\WireGuard\monitor.ps1')) { return $false }
    try {
        $tn = (Get-ItemProperty $REG -Name TunnelName -EA SilentlyContinue).TunnelName
        if ($tn) { $script:TUNNEL_SVC = "WireGuardTunnel`$$tn" }
    } catch {}
    $st = & sc.exe query $TUNNEL_SVC 2>&1 | Out-String
    return ($st -match 'RUNNING')
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  LIVE SMOKE TEST (v15.1, read-only)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

if (-not (Test-ProductionStackPresent)) {
    $msg = 'SKIP: production stack not detected (no admin, C:\WireGuard, or tunnel not RUNNING)'
    Write-Host "  $msg" -ForegroundColor Yellow
    if ($RequireStack) { exit 1 }
    exit 0
}

$fail = 0
$scripts = @(
    @{ Name = 'privacy-audit.ps1'; Required = $true },
    @{ Name = 'leak-audit.ps1'; Required = $true },
    @{ Name = 'safe-live-verify.ps1'; Required = $true }
)

foreach ($s in $scripts) {
    $path = Join-Path $PSScriptRoot $s.Name
    if (-not (Test-Path $path)) {
        Write-Host "  [FAIL] Missing $($s.Name)" -ForegroundColor Red
        if ($s.Required) { $fail++ }
        continue
    }
    Write-Host "`n>> Running $($s.Name)" -ForegroundColor Cyan
    & $path
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "  [FAIL] $($s.Name) exit $LASTEXITCODE" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "  [OK] $($s.Name)" -ForegroundColor Green
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'LIVE SMOKE: PASSED' -ForegroundColor Green
    exit 0
}
Write-Host "LIVE SMOKE: FAILED ($fail)" -ForegroundColor Red
exit 1