#Requires -RunAsAdministrator
# Ensure Tor Browser is installed + hardened for Hassas-Tarama (one-step, v15.1)
$ErrorActionPreference = 'Stop'

function Find-TorBrowserExe {
    foreach ($root in @(
        (Join-Path $env:ProgramFiles 'Tor Browser'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tor Browser'),
        (Join-Path $env:LOCALAPPDATA 'Tor Browser'),
        (Join-Path $env:USERPROFILE 'Desktop\Tor Browser'),
        (Join-Path $env:USERPROFILE 'Downloads\Tor Browser')
    )) {
        $exe = Join-Path $root 'Browser\firefox.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$installTor = Join-Path $PSScriptRoot 'install-tor-browser.ps1'
$v14Stack = Join-Path $PSScriptRoot 'install-v14-stack.ps1'
$v15Stack = Join-Path $PSScriptRoot 'install-v15-privacy-stack.ps1'

$script:INSTALL_DIR = 'C:\WireGuard'
$script:TOR_GUARD_PS1 = 'C:\WireGuard\tor-hardening-guard.ps1'
$script:TOR_MONITOR_PS1 = 'C:\WireGuard\tor-connectivity-monitor.ps1'

$torExe = Find-TorBrowserExe
if (-not $torExe) {
    Write-Host '  [-->]  Tor Browser yok - indiriliyor (tek seferlik)...' -ForegroundColor Cyan
    if (-not (Test-Path $installTor)) {
        Write-Host '  [ERR]  install-tor-browser.ps1 bulunamadi' -ForegroundColor Red
        exit 1
    }
    & $installTor
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host '  [ERR]  Tor kurulumu basarisiz. https://www.torproject.org/download/' -ForegroundColor Red
        exit 1
    }
    $torExe = Find-TorBrowserExe
}

if (-not $torExe) {
    Write-Host '  [ERR]  Tor Browser hala bulunamadi' -ForegroundColor Red
    exit 1
}

if (Test-Path $v14Stack) {
    . $v14Stack
    if (Get-Command Invoke-V14TorStack -EA SilentlyContinue) {
        Invoke-V14TorStack | Out-Null
    } elseif (Get-Command Write-TorHardeningGuardPs1 -EA SilentlyContinue) {
        Write-TorHardeningGuardPs1
        if (Test-Path $script:TOR_GUARD_PS1) { & $script:TOR_GUARD_PS1 2>$null }
    }
}

if (Test-Path $v15Stack) {
    . $v15Stack
    if (Get-Command Get-TorUserJsContentV15 -EA SilentlyContinue) {
        # v15 user.js extras applied by tor-hardening-guard on next run
        if (Test-Path $script:TOR_GUARD_PS1) { & $script:TOR_GUARD_PS1 2>$null }
    }
}

Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'TorState' 'READY' -Force -EA SilentlyContinue
Write-Output $torExe