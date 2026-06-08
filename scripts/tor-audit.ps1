#Requires -RunAsAdministrator
# v14 Tor audit — read-only, never starts/stops Tor Browser.
$ErrorActionPreference = 'Continue'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
$pass = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Get-TorRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Tor Browser'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tor Browser'),
        (Join-Path $env:LOCALAPPDATA 'Tor Browser')
    )) {
        if ($p -and (Test-Path (Join-Path $p 'Browser\firefox.exe'))) { $roots.Add($p) }
    }
    return ,$roots
}

function Test-Socks9150 {
    $tcp = $null
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('127.0.0.1', 9150, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
            try { $tcp.EndConnect($iar); return $true } catch {}
        }
    } catch {} finally { if ($tcp) { try { $tcp.Close() } catch {} } }
    return $false
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  TOR AUDIT (v15.1 - read-only)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$reg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($reg -and $reg.Version -ge '14.0') "Registry version 14.0+ (got $($reg.Version))"
Assert (Test-Path 'C:\WireGuard\tor-hardening-guard.ps1') 'tor-hardening-guard.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\tor-connectivity-monitor.ps1') 'tor-connectivity-monitor.ps1 deployed'

$roots = Get-TorRoots
$ensureDeployed = (Test-Path 'C:\WireGuard\ensure-tor-sensitive.ps1') -or (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ensure-tor-sensitive.ps1'))
Assert $ensureDeployed 'ensure-tor-sensitive.ps1 available (one-step Hassas-Tarama)'

if ($roots.Count -eq 0) {
    Write-Host '  [WARN] Tor Browser not installed - run Hassas-Tarama.lnk (auto-installs Tor)' -ForegroundColor Yellow
    exit 0
}

Assert ($roots.Count -ge 1) ('Tor Browser installed (' + $roots[0] + ')')

$userJs = Join-Path $roots[0] 'Browser\TorBrowser\Data\Browser\user.js'
Assert (Test-Path $userJs) 'Tor user.js present'
if (Test-Path $userJs) {
    $uj = Get-Content $userJs -Raw -EA SilentlyContinue
    Assert ($uj -match 'socks_remote_dns') 'user.js: socks_remote_dns'
    Assert ($uj -match 'peerconnection\.enabled.*false') 'user.js: WebRTC off'
}

$socks = Test-Socks9150
if ($socks) { Assert $true 'Tor SOCKS 9150 listening (Tor Browser running)' }
else { Write-Host '  [WARN] SOCKS 9150 not listening - start Tor Browser for sensitive use' -ForegroundColor Yellow }

$torSt = $reg.TorState
if ($torSt) { Write-Host "  [INFO] TorState: $torSt" -ForegroundColor Gray }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  TOR AUDIT: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  TOR AUDIT: PASSED" -ForegroundColor Green
exit 0