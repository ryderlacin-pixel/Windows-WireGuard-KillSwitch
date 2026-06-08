#Requires -Version 5.1
# CI entry point — offline quality gate (no admin, no WireGuard, no network required)
# Used by GitHub Actions and local pre-push verification.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$fail = 0

function Write-Step([string]$msg) {
    Write-Host "`n>> $msg" -ForegroundColor Cyan
}

Write-Step 'Phase 1/2 — run-all-tests (test-suite x3 + scriptblock + parse)'
& (Join-Path $PSScriptRoot 'run-all-tests.ps1')
if ($LASTEXITCODE -ne 0) { $fail = 1 }

if ($fail -eq 0) {
    Write-Step 'Phase 2/2 — parse all production scripts'
    $skip = @(
        'parse-bisect.ps1', 'parse-bisect2.ps1', 'parse-bisect3.ps1',
        'parse-bisect4.ps1', 'parse-bisect5.ps1', 'parse-any.ps1',
        'test-v10.6.ps1', 'github-visibility.ps1', 'open-launch-links.ps1',
        'ci.ps1'
    )
    $scripts = Get-ChildItem (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File |
        Where-Object { $skip -notcontains $_.Name } |
        Sort-Object Name

    foreach ($f in $scripts) {
        $errs = $null
        $tok = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            Write-Host "  [FAIL] $($f.Name)" -ForegroundColor Red
            foreach ($e in $errs) {
                Write-Host "    line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
            }
            $fail = 1
        } else {
            Write-Host "  [OK] $($f.Name)" -ForegroundColor Green
        }
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'CI QUALITY GATE: PASSED' -ForegroundColor Green
    exit 0
}
Write-Host 'CI QUALITY GATE: FAILED' -ForegroundColor Red
exit 1