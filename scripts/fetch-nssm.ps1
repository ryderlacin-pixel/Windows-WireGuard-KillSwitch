#Requires -RunAsAdministrator
$NSSM = 'C:\WireGuard\nssm.exe'
$zip = 'C:\WireGuard\nssm.zip'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$urls = @(
    'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip',
    'https://nssm.cc/release/nssm-2.24.zip'
)
$wingetLink = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe"
if (Test-Path $wingetLink) {
    Copy-Item $wingetLink $NSSM -Force
    Write-Host "OK: copied from winget ($NSSM)" -ForegroundColor Green
    exit 0
}
foreach ($url in $urls) {
    try {
        Write-Host "Trying $url ..."
        Invoke-WebRequest $url -OutFile $zip -TimeoutSec 90 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zf = [System.IO.Compression.ZipFile]::OpenRead($zip)
        $entry = $zf.Entries | Where-Object { $_.FullName -replace '\\', '/' -like '*/win64/nssm.exe' } | Select-Object -First 1
        if (-not $entry) { throw 'nssm.exe not in zip' }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $NSSM, $true)
        $zf.Dispose()
        Remove-Item $zip -Force -EA SilentlyContinue
        Write-Host "OK: $NSSM" -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item $zip -Force -EA SilentlyContinue
    }
}
Write-Host 'FAIL: could not download NSSM' -ForegroundColor Red
exit 1