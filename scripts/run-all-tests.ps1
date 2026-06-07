$root = Split-Path $PSScriptRoot -Parent
$fail = 0
foreach ($i in 1..3) {
    Write-Host "--- test-suite run $i ---" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'test-suite.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1; break }
}
if ($fail -eq 0) {
    & (Join-Path $PSScriptRoot 'scriptblock-test.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
}
if ($fail -eq 0) {
    & (Join-Path $PSScriptRoot 'parse-check.ps1')
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
}
if ($fail -eq 0) { Write-Host 'ALL TEST RUNS PASSED' -ForegroundColor Green }
exit $fail