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

# 3. GitHub Releases
Write-Host "[3/5] Creating releases..." -ForegroundColor Yellow
$releaseBody = @"
## v10.0 — Production-hardened kill switch

### Install
``````powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
``````

Custom server:
``````powershell
.\install.ps1 -CustomConfig "C:\path\to\myvpn.conf"
``````

### Highlights
- **Critical fix:** process detection no longer confuses ``service-monitor.ps1`` with ``monitor.ps1``
- Repair firewall check fixed (no false policy spam every 5 min)
- Scheduled tasks survive battery mode
- Service monitor 60s poll + 2-minute repair cooldown
- WMI + repair only target main ``monitor.ps1``
- Migrates legacy ``WG-OnarimGorevi`` to ``WG-RepairTask``

### Recovery layers (8)
monitor.ps1 · repair.ps1 · WG-KillSwitch task · WG-RepairTask · WGKillSwitchSvc · WMI · startup shortcut · GPO boot script

MIT licensed — no personal data in repo.
"@
function New-ReleaseIfMissing($tag, $name, $body) {
    try {
        $null = Invoke-GH GET "https://api.github.com/repos/$Owner/$Repo/releases/tags/$tag" $null
        Write-Host "  SKIP: $tag release already exists" -ForegroundColor Gray
    } catch {
        try {
            Invoke-GH POST "https://api.github.com/repos/$Owner/$Repo/releases" @{
                tag_name         = $tag
                target_commitish = "main"
                name             = $name
                body             = $body
                draft            = $false
                prerelease       = $false
            } | Out-Null
            Write-Host "  OK: $tag" -ForegroundColor Green
        } catch { Write-Host "  FAIL $tag : $($_.Exception.Message)" -ForegroundColor Red }
    }
}
New-ReleaseIfMissing "v10.0" "v10.0 — Production-hardened kill switch" $releaseBody

$releaseBodyV101 = @"
## v10.1 — English script names + docs

- Generated scripts renamed: ``repair.ps1``, ``service-monitor.ps1``, ``wmi-repair.ps1``
- Monitor functions Englishized (``Test-Internet``, ``Enable-Block``, ``Disable-Block``, etc.)
- Legacy Turkish filenames removed on upgrade reinstall
- ``CONTRIBUTING.md`` + launch/promotion docs

### Install
``````powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
``````

**Repo:** https://github.com/$Owner/$Repo
"@
New-ReleaseIfMissing "v10.1" "v10.1 — English script names + docs" $releaseBodyV101

# 4. Profile bio
Write-Host "[4/5] Updating profile bio..." -ForegroundColor Yellow
try {
    Invoke-GH PATCH "https://api.github.com/user" @{
        bio = "Windows WireGuard + WARP kill switch — one PowerShell script, 8 recovery layers"
    }
    Write-Host "  OK" -ForegroundColor Green
} catch { Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "[5/5] Pin repo (manual — no API)..." -ForegroundColor Yellow
Write-Host "  https://github.com/$Owner?tab=repositories"
Write-Host "  -> Customize pins -> Windows-WireGuard-KillSwitch"
Write-Host ""
Write-Host "Next: Reddit posts -> docs/PROMOTION.md"
Write-Host "      Full checklist -> docs/LAUNCH_CHECKLIST.md"
Write-Host ""
Write-Host "Done." -ForegroundColor Green