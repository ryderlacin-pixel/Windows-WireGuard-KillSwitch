#Requires -Version 5.1
<#
.SYNOPSIS
  Create or update GitHub Releases with reviewer-focused release notes.

.USAGE
  $env:GITHUB_TOKEN = "ghp_xxxxxxxx"
  .\scripts\publish-releases.ps1

  # Or uses git credential manager PAT if GITHUB_TOKEN unset:
  .\scripts\publish-releases.ps1

  # Create only v15.2:
  .\scripts\publish-releases.ps1 -Only v15.2
#>
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Owner = "ryderlacin-pixel",
    [string]$Repo  = "Windows-WireGuard-KillSwitch",
    [string]$Only  = ""
)

$ErrorActionPreference = "Stop"

function Get-GitHubToken {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    $credInput = "protocol=https`nhost=github.com`n`n"
    $credOut = $credInput | git credential fill 2>$null
    if ($credOut) {
        $m = $credOut | Select-String "^password=(.+)$"
        if ($m) { return $m.Matches.Groups[1].Value }
    }
    return $null
}

$Token = Get-GitHubToken $Token
if (-not $Token) {
    Write-Host "[ERROR] No GitHub token. Set GITHUB_TOKEN or configure git credentials." -ForegroundColor Red
    Write-Host "See docs/GITHUB_TOKEN.md"
    exit 1
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function ConvertTo-JsonUtf8([hashtable]$Obj) {
    $ordered = [ordered]@{}
    foreach ($key in $Obj.Keys) { $ordered[$key] = $Obj[$key] }
    return ($ordered | ConvertTo-Json -Compress -Depth 10)
}

function Invoke-GH($Method, $Uri, $Body) {
    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }
    if ($null -ne $Body) {
        $params.Body = ConvertTo-JsonUtf8 $Body
        $params.ContentType = "application/json; charset=utf-8"
    }
    Invoke-RestMethod @params
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$releaseDir = Join-Path $repoRoot "docs\releases"

$releases = @{
    "v10.0" = @{ name = "v10.0 - Production-hardened kill switch" }
    "v10.1" = @{ name = "v10.1 - English script names + docs" }
    "v10.4" = @{ name = "v10.4 - Production-hardened (code review response)" }
    "v10.5" = @{ name = "v10.5 - AbandonedMutexException fix" }
    "v10.6" = @{ name = "v10.6 - Zombie-tunnel leak prevention" }
    "v10.7" = @{ name = "v10.7 - 9.5 quality gate (layer sync + parse fix)" }
    "v10.9" = @{ name = "v10.9 - Security hardening (IPv6, WMI, audit clean)" }
    "v11.0" = @{ name = "v11.0 - Ultimate hardening + stress gate" }
    "v11.1" = @{ name = "v11.1 - Monitor singleton fix" }
    "v11.2" = @{ name = "v11.2 - Post-reboot auto-verify (production)" }
    "v15.0" = @{ name = "v15.0 - Strong Privacy Stack (DNS lock, network hardening, leak-sentinel v15)" }
    "v15.1" = @{ name = "v15.1 - Quality 95+ (lib modules, WARP-first docs, one-step Tor)" }
    "v15.2" = @{ name = "v15.2 - Boot-safety emergency fix (90s window, DHCP exempt, emergency-reset)" }
    "v15.2.1" = @{ name = "v15.2.1 - DryRun completeness fix (safe install preview)" }
    "v15.2.2" = @{ name = "v15.2.2 - Invoke-SafeRegistrySet splat fix (STEP 4 install)" }
    "v15.2.3" = @{ name = "v15.2.3 - Critical install hotfixes (dnscrypt path, fail-soft privacy stack)" }
    "v15.2.4" = @{ name = "v15.2.4 - Install internet protection (defer DNS lock until dnscrypt healthy)" }
    "v15.2.6" = @{ name = "v15.2.6 - Code review critical fixes (mutex, GPO regex, ScriptsPath, admin order)" }
    "v15.2.7" = @{ name = "v15.2.7 - Post-install internet protection (grace period, DNS lock gate, tunnel config backup)" }
    "v15.2.8" = @{ name = "v15.2.8 - Safe emergency-reset, fail-open DHCP DNS, stable DNS lock gate" }
    "v15.2.9" = @{ name = "v15.2.9-FINAL - Final line audit gate, 1008 assertions, 0 ERROR/WARN" }
    "v15.3.0" = @{ name = "v15.3.0 - Internet-safe install (KillSwitchArmed gate, DNS lock manual-only)" }
}

function Get-ReleaseBody($tag) {
    $path = Join-Path $releaseDir "$tag.md"
    if (-not (Test-Path $path)) { throw "Missing release notes: $path" }
    return [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8)
}

function Publish-Release($tag, $name, $body) {
    try {
        $existing = Invoke-GH GET "https://api.github.com/repos/$Owner/$Repo/releases/tags/$tag" $null
        Write-Host "  UPDATE: $tag (release id $($existing.id))" -ForegroundColor Yellow
        Invoke-GH PATCH "https://api.github.com/repos/$Owner/$Repo/releases/$($existing.id)" @{
            name       = $name
            body       = $body
            draft      = $false
            prerelease = $false
        } | Out-Null
        Write-Host "  OK: $tag updated" -ForegroundColor Green
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
            Write-Host "  OK: $tag created" -ForegroundColor Green
        } catch {
            Write-Host "  FAIL $tag : $($_.Exception.Message)" -ForegroundColor Red
            if ($_.ErrorDetails.Message) { Write-Host "         $($_.ErrorDetails.Message)" -ForegroundColor DarkRed }
        }
    }
}

Write-Host "=== Publish GitHub Releases ===" -ForegroundColor Cyan
$toPublish = if ($Only) { @($Only) } else { @("v15.2") }

foreach ($tag in $toPublish) {
    if (-not $releases.ContainsKey($tag)) {
        Write-Host "  SKIP: unknown tag $tag" -ForegroundColor Gray
        continue
    }
    $r = $releases[$tag]
    $body = Get-ReleaseBody $tag
    Publish-Release $tag $r.name $body
}

Write-Host ""
Write-Host "Releases: https://github.com/$Owner/$Repo/releases" -ForegroundColor Cyan
Write-Host "Reviewers: https://github.com/$Owner/$Repo/blob/main/docs/CODE_REVIEW.md" -ForegroundColor Cyan
Write-Host "Done." -ForegroundColor Green