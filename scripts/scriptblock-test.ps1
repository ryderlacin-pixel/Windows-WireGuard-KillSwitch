$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
try {
    $null = [scriptblock]::Create($raw)
    Write-Host 'Scriptblock::Create OK - install.ps1 is runnable'
    exit 0
} catch {
    Write-Host "Scriptblock FAIL: $_"
    exit 1
}