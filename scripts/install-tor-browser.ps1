#Requires -RunAsAdministrator
# Download and extract Tor Browser portable to Program Files (v14 helper).
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramFiles 'Tor Browser'
$installer = 'C:\WireGuard\tor-browser-installer.exe'
$url = 'https://www.torproject.org/dist/torbrowser/15.0.15/tor-browser-windows-x86_64-portable-15.0.15.exe'

function OK($m) { Write-Host " [OK]   $m" -ForegroundColor Green }
function WARN($m) { Write-Host " [WARN] $m" -ForegroundColor Yellow }

if (Test-Path (Join-Path $dest 'Browser\firefox.exe')) {
    OK "Tor Browser already at $dest"
    exit 0
}

New-Item -ItemType Directory -Path 'C:\WireGuard' -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host 'Downloading Tor Browser 15.0.15...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 300
OK "Downloaded $((Get-Item $installer).Length) bytes"

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -EA SilentlyContinue }
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# NSIS portable: silent extract to destination
$proc = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$dest") -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { WARN "Installer exit code $($proc.ExitCode) - trying direct run" }

if (-not (Test-Path (Join-Path $dest 'Browser\firefox.exe'))) {
    # Some builds extract to Tor Browser subfolder
    $nested = Get-ChildItem $dest -Recurse -Filter 'firefox.exe' -EA SilentlyContinue |
        Where-Object { $_.FullName -match 'TorBrowser\\Data\\Browser\\firefox\.exe|Browser\\firefox\.exe' } |
        Select-Object -First 1
    if ($nested) {
        $root = $nested.Directory.Parent.Parent.Parent.Parent.FullName
        if ($root -and (Test-Path (Join-Path $root 'Browser\firefox.exe'))) {
            Get-ChildItem $dest | Remove-Item -Recurse -Force -EA SilentlyContinue
            Copy-Item $root\* $dest -Recurse -Force
        }
    }
}

if (-not (Test-Path (Join-Path $dest 'Browser\firefox.exe'))) {
    # Fallback: run installer interactively would block - extract with 7z if present
    $7z = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($7z) {
        & $7z x $installer "-o$dest" -y | Out-Null
    }
}

Remove-Item $installer -Force -EA SilentlyContinue

if (Test-Path (Join-Path $dest 'Browser\firefox.exe')) {
    OK "Tor Browser installed: $dest"
    exit 0
}
Write-Host ' [ERR]  Tor Browser extract failed - install manually from torproject.org' -ForegroundColor Red
exit 1