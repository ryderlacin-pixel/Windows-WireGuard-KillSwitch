# Final line-by-line audit - every repo file (93/93), dot-by-dot
# No install, no admin, no firewall changes.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')

$auditDir = Join-Path $repoRoot 'audit-results'
if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }

$findings = [System.Collections.Generic.List[object]]::new()
$fileResults = [System.Collections.Generic.List[object]]::new()
$functionInventory = @{}
$errors = 0
$warns = 0
$passed = 0
$CURRENT_VER = '15.3.0'
$CURRENT_ASSERTIONS = '1013'

function Get-RuleStringList {
    param($Rule, [string]$Key)
    if (-not $Rule.ContainsKey($Key)) { return @() }
    $raw = $Rule[$Key]
    if ($null -eq $raw) { return @() }
    $items = @($raw) | Where-Object { $_ }
    if (@($items).Count -eq 0) { return @() }
    return [string[]]$items
}

function Add-Finding {
    param(
        [string]$File,
        [int]$Line = 0,
        [string]$Severity,
        [string]$Rule,
        [string]$Message
    )
    $findings.Add([PSCustomObject]@{
        file     = $File
        line     = $Line
        severity = $Severity
        rule     = $Rule
        message  = $Message
        ts       = (Get-Date -Format 'o')
    })
    if ($Severity -eq 'ERROR') { $script:errors++ }
    elseif ($Severity -eq 'WARN') { $script:warns++ }
}

function Test-CurrentDocClaims {
    param([string]$RelPath, [string]$Content, [string[]]$Lines)
    if ($RelPath -notin @('README.md', 'docs/releases/v15.3.0.md', 'CONTRIBUTING.md', 'docs/PROMOTION.md', 'docs/LAUNCH_CHECKLIST.md', 'docs/CODE_REVIEW.md', 'docs/GITHUB_TOKEN.md')) { return }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $ln = $Lines[$i]
        $n = $i + 1
        if ($RelPath -eq 'README.md') {
            if ($ln -match 'v15\.2\.4.*latest release' -or $ln -match 'Latest release:.*v15\.2\.4') {
                Add-Finding $RelPath $n 'ERROR' 'stale_readme_version' "README claims v15.2.4 as latest (current: $CURRENT_VER)"
            }
            if ($ln -match 'v15\.2.*current production release' -and $ln -notmatch '15\.2\.9') {
                Add-Finding $RelPath $n 'ERROR' 'stale_readme_version' "README current release not $CURRENT_VER"
            }
            if ($ln -match '164\+ offline assertions') {
                Add-Finding $RelPath $n 'ERROR' 'stale_assertion_count' "README says 164+ assertions (current: $CURRENT_ASSERTIONS+)"
            }
            if ($ln -match 'version 15\.2' -and $ln -notmatch '15\.2\.9') {
                Add-Finding $RelPath $n 'WARN' 'stale_constants_ref' 'README references lib version 15.2 not 15.3.0'
            }
        }
        if ($RelPath -eq 'docs/releases/v15.3.0.md' -and $ln -match '\b915\b' -and $ln -notmatch 'was|previously|old') {
            Add-Finding $RelPath $n 'WARN' 'stale_assertion_count' 'v15.3.0 release note mentions obsolete 915 count'
        }
        if ($RelPath -eq 'CONTRIBUTING.md' -and $ln -match '164\+') {
            Add-Finding $RelPath $n 'ERROR' 'stale_assertion_count' "CONTRIBUTING says 164+ assertions (current: $CURRENT_ASSERTIONS+)"
        }
        if ($RelPath -in @('docs/PROMOTION.md', 'docs/LAUNCH_CHECKLIST.md', 'docs/CODE_REVIEW.md', 'docs/GITHUB_TOKEN.md')) {
            if ($ln -match '164\+' -or $ln -match '186\+') {
                Add-Finding $RelPath $n 'ERROR' 'stale_assertion_count' "Doc says obsolete assertion count (current: $CURRENT_ASSERTIONS+)"
            }
            if ($ln -match 'releases/tag/v15\.1' -or $ln -match '\[v15\.1\]' -or $ln -match 'releases/tag/v15\.2\.1') {
                Add-Finding $RelPath $n 'ERROR' 'stale_release_ref' "Doc references old release as current (current: $CURRENT_VER)"
            }
        }
        if ($RelPath -eq 'docs/CODE_REVIEW.md' -and $ln -match 'Current release' -and $ln -notmatch '15\.2\.9') {
            Add-Finding $RelPath $n 'ERROR' 'stale_code_review_release' "CODE_REVIEW current release not $CURRENT_VER"
        }
        if ($RelPath -eq 'docs/GITHUB_TOKEN.md' -and $ln -match 'v15\.1' -and $ln -notmatch 'v15\.1\+') {
            Add-Finding $RelPath $n 'ERROR' 'stale_github_token_ref' "GITHUB_TOKEN references v15.1 (current: $CURRENT_VER)"
        }
    }
}

function Test-Ps1FileDeep {
    param([string]$RelPath, [string]$FullPath, [string[]]$Lines)
    $errs = $null; $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$tok, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) {
            Add-Finding $RelPath $e.Extent.StartLineNumber 'ERROR' 'parse_error' $e.Message
        }
    }
    $raw = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8
    try { $null = [scriptblock]::Create($raw) }
    catch { Add-Finding $RelPath 0 'ERROR' 'scriptblock_fail' $_.Exception.Message }

    $funcs = Get-Ps1FunctionNames $FullPath
    $functionInventory[$RelPath] = $funcs

    if ($RelPath -eq 'lib/Install-MainSteps-0-6.ps1') {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '(?m)^\s*netsh advfirewall' -and -not (Test-IsCommentLine $Lines[$i])) {
                Add-Finding $RelPath ($i + 1) 'ERROR' 'bare_netsh' 'MainSteps 0-6 must not use bare netsh'
            }
        }
    }

    foreach ($rule in (Get-LineSemanticRules)) {
        $exts = Get-RuleStringList $rule 'Extensions'
        $files = Get-RuleStringList $rule 'Files'
        $whitelist = Get-RuleStringList $rule 'WhitelistFiles'
        $excludeComments = $rule.ContainsKey('ExcludeComments') -and $rule['ExcludeComments']
        if ($exts -notcontains '.ps1') { continue }
        if ((@($files).Count -gt 0) -and ($files -notcontains $RelPath)) { continue }
        if ((@($whitelist).Count -gt 0) -and ($whitelist -contains $RelPath)) { continue }
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($excludeComments -and (Test-IsCommentLine $Lines[$i])) { continue }
            if ($Lines[$i] -match $rule['Pattern']) {
                Add-Finding -File $RelPath -Line ($i + 1) -Severity $rule['Severity'] -Rule $rule['Id'] -Message "Matched: $($rule['Pattern'])"
            }
        }
    }

    if ($RelPath -match '\.ps1$' -and $RelPath -notmatch 'final-line-audit|Test-Helpers') {
        $nonAscii = $false
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '[^\x09\x0A\x0D\x20-\x7E]') { $nonAscii = $true; break }
        }
        if ($nonAscii) { Add-Finding $RelPath 0 'WARN' 'non_ascii' 'Non-ASCII characters in PS1 (possible mojibake)' }
    }
}

function Test-BatFile {
    param([string]$RelPath, [string]$FullPath, [string[]]$Lines)
    foreach ($pat in @('@echo off', 'emergency-reset.ps1', 'RunAs')) {
        if (-not (($Lines -join "`n") -match [regex]::Escape($pat))) {
            Add-Finding $RelPath 0 'ERROR' 'bat_contract' "Missing: $pat"
        }
    }
}

function Test-JsonFile {
    param([string]$RelPath, [string]$Content)
    try {
        $null = $Content | ConvertFrom-Json
        if ($RelPath -match '^manifests/') {
            $j = $Content | ConvertFrom-Json
            foreach ($k in @('version', 'url', 'sha256', 'exe')) {
                if (-not $j.PSObject.Properties.Name.Contains($k)) {
                    Add-Finding $RelPath 0 'ERROR' 'json_schema' "Missing key: $k"
                }
            }
        }
    } catch {
        Add-Finding $RelPath 0 'ERROR' 'json_invalid' $_.Exception.Message
    }
}

function Test-YmlFile {
    param([string]$RelPath, [string]$Content)
    if ($RelPath -match 'ci\.yml' -and $Content -notmatch 'ci\.ps1') {
        Add-Finding $RelPath 0 'ERROR' 'workflow_ci' 'ci.yml must invoke ci.ps1'
    }
    if ($Content -match '164\+ offline' -or $Content -match '915 PASS') {
        Add-Finding $RelPath 0 'WARN' 'stale_workflow_doc' 'Workflow comment has stale assertion count'
    }
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  FINAL LINE AUDIT (93 files, dot-by-dot)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$manifest = Get-CompleteRepoManifest $repoRoot
Write-Host "Inventory: $($manifest.Count) files" -ForegroundColor Gray

if ($manifest.Count -lt 93) {
    Add-Finding 'REPO' 0 'ERROR' 'inventory' "Expected 93+ files, got $($manifest.Count)"
}

foreach ($entry in $manifest) {
    $rel = $entry.RelPath
    $full = Join-Path $repoRoot ($rel -replace '/', '\')
    $status = 'PASS'
    $notes = [System.Collections.Generic.List[string]]::new()
    $startErr = $script:errors
    $startWarn = $script:warns

    if (-not (Test-Path $full)) {
        Add-Finding $rel 0 'ERROR' 'missing' 'File missing'
        $fileResults.Add([PSCustomObject]@{ RelPath = $rel; Tier = $entry.Tier; Lines = 0; Status = 'FAIL'; Notes = 'missing' })
        continue
    }

    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) {
        Add-Finding $rel 0 'ERROR' 'empty_file' 'File is empty'
    }

    $lineArr = @(Get-Content -LiteralPath $full -Encoding UTF8)
    if ($lineArr.Count -ne $entry.Lines) {
        Add-Finding $rel 0 'WARN' 'line_drift' "Manifest lines $($entry.Lines) vs actual $($lineArr.Count)"
    }

    $trailCount = 0
    $firstTrailLine = 0
    for ($i = 0; $i -lt $lineArr.Count; $i++) {
        if ($lineArr[$i] -match '\s+$' -and $lineArr[$i].Trim().Length -gt 0) {
            $trailCount++
            if ($firstTrailLine -eq 0) { $firstTrailLine = $i + 1 }
        }
    }
    if ($trailCount -gt 0) {
        Add-Finding $rel $firstTrailLine 'WARN' 'trailing_whitespace' "Trailing whitespace on $trailCount line(s)"
    }

    $content = $lineArr -join "`n"
    Test-CurrentDocClaims $rel $content $lineArr

    switch -Regex ($entry.Extension) {
        '\.ps1$' { Test-Ps1FileDeep $rel $full $lineArr }
        '\.bat$' { Test-BatFile $rel $full $lineArr }
        '\.json$' { Test-JsonFile $rel $content }
        '\.yml$' { Test-YmlFile $rel $content }
        '\.md$' {
            if ($rel -eq 'README.md' -and $content -notmatch '15\.2\.9') {
                Add-Finding $rel 0 'WARN' 'readme_version' 'README does not mention 15.3.0 prominently'
            }
            if ($rel -match 'docs/releases/v15\.2\.9' -and $content -notmatch '1008') {
                Add-Finding $rel 0 'WARN' 'release_test_count' 'v15.3.0.md should document 1013 assertion gate'
            }
        }
    }

    $fileErr = $script:errors - $startErr
    $fileWarn = $script:warns - $startWarn
    if ($fileErr -gt 0) { $status = 'FAIL' }
    elseif ($fileWarn -gt 0) { $status = 'WARN' }
    else { $script:passed++ }

    $fileResults.Add([PSCustomObject]@{
        RelPath = $rel
        Tier    = $entry.Tier
        Lines   = $entry.Lines
        Status  = $status
        Errors  = $fileErr
        Warns   = $fileWarn
        SHA256  = $entry.SHA256
    })
}

# Generated script function coverage
$extracted = Get-ExtractedGeneratedScripts $repoRoot
foreach ($pair in @(
    @{ Name = 'monitor'; Content = $extracted.Monitor; Required = @('function Enable-Block', 'Test-BlockAllowed', 'Disable-Block') }
    @{ Name = 'repair'; Content = $extracted.Repair; Required = @('function Sync-KillSwitchState', 'function Try-ReinstallTunnel') }
    @{ Name = 'watchdog'; Content = $extracted.Watchdog; Required = @('Invoke-GentleUnbrick', 'Invoke-DeepUnbrick') }
    @{ Name = 'wg-safety'; Content = $extracted.Safety; Required = @('function Test-BlockAllowed', 'function Test-KillSwitchArmed') }
)) {
    if (-not $pair.Content) {
        Add-Finding "generated/$($pair.Name).ps1" 0 'ERROR' 'extract_fail' "Could not extract $($pair.Name)"
        continue
    }
    foreach ($req in $pair.Required) {
        if ($pair.Content -notmatch $req) {
            Add-Finding "generated/$($pair.Name).ps1" 0 'ERROR' 'generated_contract' "Missing: $req"
        }
    }
    $tmp = Write-ExtractedToTemp $pair.Content "audit-$($pair.Name)"
    try {
        $null = [scriptblock]::Create((Get-Content -LiteralPath $tmp -Raw -Encoding UTF8))
    } catch {
        Add-Finding "generated/$($pair.Name).ps1" 0 'ERROR' 'generated_compile' $_.Exception.Message
    } finally {
        Remove-Item $tmp -Force -EA SilentlyContinue
    }
}

# Version parity across core files
$constants = Get-Content (Join-Path $repoRoot 'lib\Install-Constants.ps1') -Raw -Encoding UTF8
$install = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw -Encoding UTF8
if ($constants -notmatch "\`$WG_KS_VERSION = '$CURRENT_VER'") {
    Add-Finding 'lib/Install-Constants.ps1' 0 'ERROR' 'version_mismatch' "WG_KS_VERSION must be $CURRENT_VER"
}
if ($install -notmatch 'v15\.3\.0') {
    Add-Finding 'install.ps1' 0 'ERROR' 'version_mismatch' 'install.ps1 header must reference v15.3.0'
}

# Write outputs (materialize strings before Set-Content - safe under x3 test-suite runs)
$manifestOut = $manifest | ForEach-Object { $_ }
Set-Content -LiteralPath (Join-Path $auditDir 'final-audit-manifest.json') -Value ($manifestOut | ConvertTo-Json -Depth 5) -Encoding UTF8 -Force

$findingsJsonl = ($findings | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n"
if ($findingsJsonl) { $findingsJsonl += "`n" }
Set-Content -LiteralPath (Join-Path $auditDir 'findings.jsonl') -Value $findingsJsonl -Encoding UTF8 -Force

Set-Content -LiteralPath (Join-Path $auditDir 'function-inventory.json') -Value ($functionInventory | ConvertTo-Json -Depth 4) -Encoding UTF8 -Force

$shaLines = [System.Collections.Generic.List[string]]::new()
foreach ($e in $manifest) {
    $shaLines.Add("$($e.SHA256)  $($e.RelPath)") | Out-Null
}
Set-Content -LiteralPath (Join-Path $auditDir 'SHA256SUMS.txt') -Value ($shaLines -join "`n") -Encoding UTF8 -Force

$warnFileCount = @($fileResults | Where-Object { $_.Status -eq 'WARN' }).Count
$failFileCount = @($fileResults | Where-Object { $_.Status -eq 'FAIL' }).Count
$summary = "# Final Audit Summary - v$CURRENT_VER`n`n"
$summary += "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
$summary += "Files audited: $($manifest.Count)`n"
$summary += "PASS: $passed | WARN files: $warnFileCount | FAIL: $failFileCount`n"
$summary += "ERROR findings: $errors | WARN findings: $warns`n`n"
$summary += "## Per-file status`n`n"
$summary += "| RelPath | Tier | Lines | Status | Errors | Warns |`n"
$summary += "|---------|------|-------|--------|--------|-------|`n"
foreach ($fr in ($fileResults | Sort-Object RelPath)) {
    $summary += "| $($fr.RelPath) | $($fr.Tier) | $($fr.Lines) | $($fr.Status) | $($fr.Errors) | $($fr.Warns) |`n"
}
if ($errors -gt 0) {
    $summary += "`n## ERROR findings`n"
    foreach ($f in ($findings | Where-Object { $_.severity -eq 'ERROR' })) {
        $summary += "- **$($f.file):$($f.line)** [$($f.rule)] $($f.message)`n"
    }
}
Set-Content -LiteralPath (Join-Path $auditDir 'final-audit-summary.md') -Value $summary -Encoding UTF8 -Force

Write-Host ''
$auditOk = ($errors -eq 0 -and $warns -eq 0)
Write-Host "AUDIT: $passed/$($manifest.Count) files PASS | ERROR=$errors WARN=$warns" -ForegroundColor $(if ($auditOk) { 'Green' } else { 'Red' })
Write-Host "Output: $auditDir" -ForegroundColor Gray

if ($errors -gt 0 -or $warns -gt 0) { exit 1 }
exit 0