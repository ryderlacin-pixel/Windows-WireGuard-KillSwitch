#Requires -Version 5.1
<#
.SYNOPSIS
  Create or update GitHub Releases with reviewer-focused release notes.

.USAGE
  $env:GITHUB_TOKEN = "ghp_xxxxxxxx"
  .\scripts\publish-releases.ps1

  # Or uses git credential manager PAT if GITHUB_TOKEN unset:
  .\scripts\publish-releases.ps1

  # Create only v10.4:
  .\scripts\publish-releases.ps1 -Only v10.4
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
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{')
    $first = $true
    foreach ($key in $Obj.Keys) {
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        $val = $Obj[$key]
        if ($val -is [bool]) {
            $encoded = if ($val) { 'true' } else { 'false' }
        } else {
            $encoded = '"' + (($val.ToString()) -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t') + '"'
        }
        [void]$sb.Append('"')
        [void]$sb.Append($key)
        [void]$sb.Append('":')
        [void]$sb.Append($encoded)
    }
    [void]$sb.Append('}')
    [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
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
$toPublish = if ($Only) { @($Only) } else { @("v10.0", "v10.1", "v10.4", "v10.5", "v10.6") }

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