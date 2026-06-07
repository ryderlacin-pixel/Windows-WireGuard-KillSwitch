#Requires -Version 5.1
<#
.SYNOPSIS
  GitHub repo visibility setup via API (topics, release, discussions, profile bio).

.USAGE
  1. Create token: https://github.com/settings/tokens/new
     Scopes: repo, read:user, user:email
  2. Run once in elevated/admin PowerShell:
       $env:GITHUB_TOKEN = "ghp_xxxxxxxx"
       .\scripts\github-visibility.ps1
  3. Pin repo manually: https://github.com/ryderlacin-pixel?tab=repositories
     (GitHub has no public API for profile pin order)
#>
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Owner = "ryderlacin-pixel",
    [string]$Repo  = "Windows-WireGuard-KillSwitch"
)

$ErrorActionPreference = "Stop"
if (-not $Token) {
    Write-Host "[ERROR] GITHUB_TOKEN not set." -ForegroundColor Red
    Write-Host "Create token: https://github.com/settings/tokens/new"
    Write-Host 'Then: $env:GITHUB_TOKEN = "ghp_your_token_here"'
    exit 1
}

$headers = @{
    Authorization = "Bearer $Token"
    Accept        = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$topicHeaders = $headers.Clone()
$topicHeaders.Accept = "application/vnd.github.mercy-preview+json"

function Invoke-GH($Method, $Uri, $Body, [hashtable]$Hdr = $headers) {
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Hdr }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5); $params.ContentType = "application/json" }
    Invoke-RestMethod @params
}

Write-Host "=== GitHub Visibility Setup ===" -ForegroundColor Cyan

# 1. Topics
Write-Host "[1/5] Setting topics..." -ForegroundColor Yellow
$topics = @(
    "wireguard", "warp", "cloudflare-warp", "kill-switch", "vpn",
    "windows", "powershell", "privacy", "firewall", "wgcf", "self-hosted"
)
try {
    Invoke-GH PUT "https://api.github.com/repos/$Owner/$Repo/topics" @{ names = $topics } $topicHeaders
    Write-Host "  OK: $($topics -join ', ')" -ForegroundColor Green
} catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }

# 2. Enable discussions
Write-Host "[2/5] Enabling discussions..." -ForegroundColor Yellow
try {
    Invoke-GH PATCH "https://api.github.com/repos/$Owner/$Repo" @{ has_discussions = $true }
    Write-Host "  OK" -ForegroundColor Green
} catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }

# 3. GitHub Releases (reviewer-focused notes)
Write-Host "[3/5] Publishing releases..." -ForegroundColor Yellow
$publishScript = Join-Path $PSScriptRoot "publish-releases.ps1"
if (Test-Path $publishScript) {
    & $publishScript -Token $Token -Owner $Owner -Repo $Repo
} else {
    Write-Host "  FAIL: publish-releases.ps1 not found" -ForegroundColor Red
}

# 4. Profile bio
Write-Host "[4/5] Updating profile bio..." -ForegroundColor Yellow
try {
    Invoke-GH PATCH "https://api.github.com/user" @{
        bio = "Windows WireGuard + WARP kill switch - one PowerShell script, 8 recovery layers"
    }
    Write-Host "  OK" -ForegroundColor Green
} catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "[5/5] Pin repo (manual - no API)..." -ForegroundColor Yellow
Write-Host "  https://github.com/${Owner}?tab=repositories"
Write-Host "  -> Customize pins -> Windows-WireGuard-KillSwitch"
Write-Host ""
Write-Host "Next: Reddit posts -> docs/PROMOTION.md"
Write-Host "      Full checklist -> docs/LAUNCH_CHECKLIST.md"
Write-Host ""
Write-Host "Done." -ForegroundColor Green