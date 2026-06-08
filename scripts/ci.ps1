#Requires -Version 5.1
# CI entry point — offline quality gate (no admin, no WireGuard, no network required)
# Used by GitHub Actions and local pre-push verification.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
$fail = 0

trap {
    Write-Host "CI aborted: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function Write-Step([string]$msg) {
    Write-Host "`n>> $msg" -ForegroundColor Cyan
}

Write-Step 'Phase 1/3 — run-all-tests (test-suite x3 + scriptblock + parse)'
& (Join-Path $PSScriptRoot 'run-all-tests.ps1')
if ($LASTEXITCODE -ne 0) { $fail = 1 }

if ($fail -eq 0) {
    Write-Step 'Phase 2/3 — parse lib/*.ps1 modules'
    $libDir = Join-Path $repoRoot 'lib'
    if (Test-Path $libDir) {
        foreach ($f in (Get-ChildItem $libDir -Filter '*.ps1' -File | Sort-Object Name)) {
            $errs = $null; $tok = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$errs)
            if ($errs -and $errs.Count -gt 0) {
                Write-Host "  [FAIL] lib/$($f.Name)" -ForegroundColor Red
                $fail = 1
            } else {
                Write-Host "  [OK] lib/$($f.Name)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host '  [FAIL] lib/ directory missing' -ForegroundColor Red
        $fail = 1
    }
}

if ($fail -eq 0) {
    Write-Step 'Phase 3/3 — parse all production scripts'
    $skip = @(
        'parse-bisect.ps1', 'parse-bisect2.ps1', 'parse-bisect3.ps1',
        'parse-bisect4.ps1', 'parse-bisect5.ps1', 'parse-any.ps1',
        'test-v10.6.ps1', 'github-visibility.ps1', 'open-launch-links.ps1',
        'split-install-lib.ps1', 'wrap-install-lib.ps1', 'ci.ps1'
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

if ($fail -eq 0) {
    Write-Step 'Phase 3b — live-smoke-test.ps1 structure (offline)'
    $smokePath = Join-Path $PSScriptRoot 'live-smoke-test.ps1'
    if (Test-Path $smokePath) {
        $smokeRaw = Get-Content -LiteralPath $smokePath -Raw -Encoding UTF8
        foreach ($pat in @('SKIP: production stack not detected', 'privacy-audit.ps1', 'safe-live-verify.ps1', 'RequireStack')) {
            if ($smokeRaw -notmatch [regex]::Escape($pat)) {
                Write-Host "  [FAIL] live-smoke missing: $pat" -ForegroundColor Red
                $fail = 1
            }
        }
        if ($fail -eq 0) { Write-Host '  [OK] live-smoke-test.ps1 structure' -ForegroundColor Green }
    } else {
        Write-Host '  [FAIL] live-smoke-test.ps1 missing' -ForegroundColor Red
        $fail = 1
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'CI QUALITY GATE: PASSED' -ForegroundColor Green
    exit 0
}
Write-Host 'CI QUALITY GATE: FAILED' -ForegroundColor Red
exit 1