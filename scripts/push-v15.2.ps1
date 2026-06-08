#Requires -Version 5.1
<#
.SYNOPSIS
  Push v15.2 to GitHub and publish release (one command).

.USAGE
  $env:GITHUB_TOKEN = "github_pat_..."   # Contents: Read and write on this repo
  .\scripts\push-v15.2.ps1
#>
param(
    [string]$Token = $env:GITHUB_TOKEN
)
$ErrorActionPreference = 'Stop'
if (-not $Token) {
    Write-Host '[ERR] Set GITHUB_TOKEN first (Contents: Read and write on Windows-WireGuard-KillSwitch)' -ForegroundColor Red
    Write-Host 'See docs/GITHUB_TOKEN.md'
    exit 1
}

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { $git = Get-Command 'C:\Users\vboxuser\MinGit\cmd\git.exe' -ErrorAction SilentlyContinue }
if (-not $git) { throw 'git not found' }
$gitExe = $git.Source

# Verify write access before push
$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
try {
    Invoke-RestMethod -Method POST -Uri 'https://api.github.com/repos/ryderlacin-pixel/Windows-WireGuard-KillSwitch/git/blobs' `
        -Headers $headers -Body '{"content":"dGVzdA==","encoding":"base64"}' -ContentType 'application/json' | Out-Null
} catch {
    Write-Host '[ERR] Token cannot write to repo. Grant Contents: Read and write.' -ForegroundColor Red
    exit 1
}

$remote = 'https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch.git'
$pushUrl = "https://oauth2:${Token}@github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch.git"

& $gitExe remote set-url origin $pushUrl
try {
    & $gitExe push origin main
    & $gitExe tag -f -a v15.2 -m 'v15.2 boot-safety emergency fix'
    & $gitExe push -f origin v15.2
    Write-Host '[OK] Pushed main + tag v15.2' -ForegroundColor Green
} finally {
    & $gitExe remote set-url origin $remote
}

$env:GITHUB_TOKEN = $Token
& (Join-Path $repoRoot 'scripts\publish-releases.ps1') -Only v15.2 -Token $Token
Write-Host '[OK] Release v15.2 published' -ForegroundColor Green
Write-Host 'https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.2' -ForegroundColor Cyan