# Scriptblock::Create gate - install.ps1, lib/*.ps1, extracted generated scripts
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')

$fail = 0
$targets = [System.Collections.Generic.List[string]]::new()

$targets.Add((Join-Path $repoRoot 'install.ps1'))
$libDir = Join-Path $repoRoot 'lib'
if (Test-Path $libDir) {
    foreach ($f in (Get-ChildItem $libDir -Filter '*.ps1' -File | Sort-Object Name)) {
        $targets.Add($f.FullName)
    }
}

$extracted = Get-ExtractedGeneratedScripts $repoRoot
foreach ($pair in @(
    @{ Content = $extracted.Monitor; Label = 'monitor (extracted)' }
    @{ Content = $extracted.Gpo; Label = 'gpo (extracted)' }
    @{ Content = $extracted.Repair; Label = 'repair (extracted)' }
    @{ Content = $extracted.Watchdog; Label = 'watchdog (extracted)' }
    @{ Content = $extracted.Safety; Label = 'wg-safety (extracted)' }
)) {
    if (-not $pair.Content) {
        Write-Host "  [FAIL] $($pair.Label) extract empty" -ForegroundColor Red
        $fail = 1
        continue
    }
    $tmp = Write-ExtractedToTemp $pair.Content ($pair.Label -replace '\W', '-')
    $targets.Add($tmp)
}

foreach ($path in $targets) {
    $label = Split-Path $path -Leaf
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    try {
        $null = [scriptblock]::Create($raw)
        Write-Host "  [OK]   $label" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $label : $($_.Exception.Message)" -ForegroundColor Red
        $fail = 1
    }
    if ($path -like "$env:TEMP\wg-*") {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

if ($fail -eq 0) {
    Write-Host 'Scriptblock::Create OK - all targets runnable' -ForegroundColor Green
    exit 0
}
Write-Host 'Scriptblock::Create FAILED' -ForegroundColor Red
exit 1