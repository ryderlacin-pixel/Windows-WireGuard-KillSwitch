# File coverage gate - every production file must pass meaningful (non-hollow) checks
# No install, no admin, no firewall changes.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$script:passed = 0
$script:fileCheckCounts = @{}

function Assert-Coverage([bool]$cond, [string]$msg, [string]$File = '') {
    if ($cond) {
        $script:passed++
        if ($File) {
            if (-not $script:fileCheckCounts.ContainsKey($File)) { $script:fileCheckCounts[$File] = 0 }
            $script:fileCheckCounts[$File]++
        }
    } else {
        $failures.Add($msg)
    }
}

function Test-FileParseAndScriptblock {
    param([string]$RelPath, [string]$FullPath)
    if ($RelPath -notmatch '\.ps1$') { return }

    $errs = $null; $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$tok, [ref]$errs)
    Assert-Coverage ((-not $errs) -or ($errs.Count -eq 0)) "$RelPath AST parse clean" $RelPath

    $raw = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8
    try {
        $null = [scriptblock]::Create($raw)
        Assert-Coverage $true "$RelPath Scriptblock::Create OK" $RelPath
    } catch {
        Assert-Coverage $false "$RelPath Scriptblock::Create: $($_.Exception.Message)" $RelPath
    }
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  FILE COVERAGE TEST (anti-hollow gate)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$contentMap = Get-FileContentMap $repoRoot
$manifest = Get-ProductionFileManifest $repoRoot

# [A] Every manifest file exists
Write-Host '[A] Production file inventory' -ForegroundColor Yellow
foreach ($entry in $manifest) {
    $full = Join-Path $repoRoot ($entry.RelPath -replace '/', '\')
    Assert-Coverage (Test-Path $full) "Missing production file: $($entry.RelPath)" $entry.RelPath
}
Assert-Coverage ($manifest.Count -ge 47) "Manifest has 47+ production files (got $($manifest.Count))"

# [B] Per-file parse + scriptblock (all .ps1)
Write-Host '[B] Per-file parse + Scriptblock::Create' -ForegroundColor Yellow
foreach ($entry in $manifest) {
    if ($entry.RelPath -notmatch '\.ps1$') { continue }
    $full = Join-Path $repoRoot ($entry.RelPath -replace '/', '\')
    if (Test-Path $full) { Test-FileParseAndScriptblock $entry.RelPath $full }
}

# [C] JSON manifests
Write-Host '[C] JSON manifest validation' -ForegroundColor Yellow
foreach ($entry in ($manifest | Where-Object { $_.RelPath -match '\.json$' })) {
    $full = Join-Path $repoRoot ($entry.RelPath -replace '/', '\')
    if (-not (Test-Path $full)) { continue }
    $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    try {
        $null = $raw | ConvertFrom-Json
        Assert-Coverage $true "$($entry.RelPath) JSON valid" $entry.RelPath
    } catch {
        Assert-Coverage $false "$($entry.RelPath) JSON invalid: $($_.Exception.Message)" $entry.RelPath
    }
    Assert-Coverage ($raw.Length -gt 20) "$($entry.RelPath) JSON non-empty" $entry.RelPath
}

# [D] File-scoped pattern matrix (not rawCombined hollow)
Write-Host '[D] File-scoped pattern matrix' -ForegroundColor Yellow
foreach ($row in (Get-FileScopedPatternMatrix)) {
    foreach ($item in (Get-PatternMatrixEntries $row)) {
        $found = $false
        foreach ($f in $row.Files) {
            if (-not $contentMap.ContainsKey($f)) { continue }
            if (Test-ContentPattern $contentMap[$f] $item.Pat -IsRegex:$item.Regex) { $found = $true; break }
        }
        $scope = ($row.Files -join ',')
        Assert-Coverage $found "Scoped Must [$scope]: $($item.Pat)"
        foreach ($f in $row.Files) {
            if ($contentMap.ContainsKey($f) -and (Test-ContentPattern $contentMap[$f] $item.Pat -IsRegex:$item.Regex)) {
                Assert-Coverage $true "Pattern in expected file $f : $($item.Pat)" $f
            }
        }
    }
}
$stepCount = 0
if ($contentMap.ContainsKey('_installLibCombined')) {
    $stepCount = ([regex]::Matches($contentMap['_installLibCombined'], 'Write-Step')).Count
}
Assert-Coverage ($stepCount -ge 19) "Install has 19+ Write-Step markers (got $stepCount)" 'install.ps1'

# [E] Forbidden / negative pattern matrix
Write-Host '[E] Forbidden pattern matrix' -ForegroundColor Yellow
foreach ($row in (Get-ForbiddenPatternMatrix)) {
    $key = $row.File
    if (-not $contentMap.ContainsKey($key)) { continue }
    $body = $contentMap[$key]
    foreach ($bad in $row.Forbidden) {
        Assert-Coverage ($body -notmatch [regex]::Escape($bad)) "Forbidden in ${key}: $bad" $key
    }
    foreach ($rx in $row.Regex) {
        Assert-Coverage ($body -notmatch $rx) "Forbidden regex in ${key}: $rx" $key
    }
}
$main06 = $contentMap['lib/Install-MainSteps-0-6.ps1']
if ($main06) {
    Assert-Coverage ($main06 -match 'Invoke-SafeRegistrySet @ipv6RegParams') 'MainSteps 0-6: IPv6 via splat' 'lib/Install-MainSteps-0-6.ps1'
    Assert-Coverage ($main06 -notmatch '(?m)^\s*netsh ') 'MainSteps 0-6: no bare netsh' 'lib/Install-MainSteps-0-6.ps1'
}
$safeNet = $contentMap['lib/Install-SafeNetwork.ps1']
if ($safeNet) {
    Assert-Coverage ($safeNet -match 'function Invoke-SafeRegistrySet') 'SafeNetwork: Invoke-SafeRegistrySet' 'lib/Install-SafeNetwork.ps1'
    Assert-Coverage ($safeNet -match '\[Parameter\(Mandatory\)\]\[string\]\$Path') 'SafeNetwork: Path splat param' 'lib/Install-SafeNetwork.ps1'
}
$gen = $contentMap['lib/Install-GeneratedScripts.ps1']
if ($gen) {
    Assert-Coverage ($gen -match 'function Test-IsMainMonitor') 'Generated: Test-IsMainMonitor' 'lib/Install-GeneratedScripts.ps1'
    Assert-Coverage ($gen -match 'Sync-KillSwitchState\r?\n\} finally') 'Repair: Sync before finally' 'lib/Install-GeneratedScripts.ps1'
}

# [F] ROLE_CONTRACT per script group
Write-Host '[F] Role contracts (>=4 meaningful checks per script)' -ForegroundColor Yellow
foreach ($contract in (Get-RoleContractMatrix)) {
    foreach ($scriptName in $contract.Scripts) {
        $rel = "scripts/$scriptName"
        if (-not $contentMap.ContainsKey($rel)) {
            Assert-Coverage $false "Role contract missing script: $rel"
            continue
        }
        $body = $contentMap[$rel]
        foreach ($pat in $contract.Must) {
            if ($pat -eq 'kurtar') {
                Assert-Coverage ($body -notmatch 'kurtar') "$rel must not reference kurtar" $rel
            } else {
                Assert-Coverage ($body -match $pat) "$rel contract: $pat" $rel
            }
        }
    }
}

# [G] Extracted generated scripts - compile + function contracts
Write-Host '[G] Generated script extract + compile' -ForegroundColor Yellow
$extracted = Get-ExtractedGeneratedScripts $repoRoot
$genChecks = @(
    @{ Name = 'monitor'; Content = $extracted.Monitor; Must = @('function Enable-Block', 'Test-BlockAllowed', 'Disable-Block', 'zombie', 'fail-open', 'Install in progress') }
    @{ Name = 'gpo'; Content = $extracted.Gpo; Must = @('Disable-KillSwitchBlock', 'fail-open', 'never blocks') }
    @{ Name = 'repair'; Content = $extracted.Repair; Must = @('function Sync-KillSwitchState', 'monitor-only block authority', 'function Try-ReinstallTunnel', 'cmd.exe /c', 'Test-PostInstallGrace', 'Test-KillSwitchArmed'); MustNot = @('dns-lockdown-guard.ps1') }
    @{ Name = 'watchdog'; Content = $extracted.Watchdog; Must = @('graduated fail-open', 'Invoke-GentleUnbrick', 'Invoke-DeepUnbrick', 'Restore-DhcpDnsOnPhysicalAdapters') }
    @{ Name = 'wg-safety'; Content = $extracted.Safety; Must = @('function Test-BlockAllowed', 'cmd.exe /c'); MustNot = @('Invoke-Expression') }
)
foreach ($gc in $genChecks) {
    if (-not $gc.Content) {
        Assert-Coverage $false "Extract failed: $($gc.Name)"
        continue
    }
    Assert-Coverage (Test-ParseContent $gc.Content "$($gc.Name) (extracted)" $failures) "$($gc.Name) parses" "generated/$($gc.Name).ps1"
    Assert-Coverage (Test-ScriptblockContent $gc.Content "$($gc.Name) (extracted)" $failures) "$($gc.Name) Scriptblock::Create" "generated/$($gc.Name).ps1"
    foreach ($m in $gc.Must) {
        Assert-Coverage ($gc.Content -match $m) "Generated $($gc.Name): $m" "generated/$($gc.Name).ps1"
    }
    $mustNot = if ($gc.PSObject.Properties.Name -contains 'MustNot') { $gc.MustNot } else { @() }
    if ($mustNot) {
        foreach ($mn in $mustNot) {
            Assert-Coverage ($gc.Content -notmatch $mn) "Generated $($gc.Name) must not: $mn" "generated/$($gc.Name).ps1"
        }
    }
}

# [H] emergency-reset.bat batch structure
Write-Host '[H] emergency-reset.bat structure' -ForegroundColor Yellow
$bat = $contentMap['emergency-reset.bat']
if ($bat) {
    foreach ($pat in @('@echo off', 'emergency-reset.ps1', 'RunAs', 'Administrator')) {
        Assert-Coverage ($bat -match $pat) "emergency-reset.bat: $pat" 'emergency-reset.bat'
    }
}

# [H2] Release notes, ci.ps1, emergency.bat role contracts
Write-Host '[H2] Release notes + ci.ps1 + emergency.bat' -ForegroundColor Yellow
if ($bat) {
    Assert-Coverage ($bat -match 'EnableExtensions') 'emergency-reset.bat: setlocal' 'emergency-reset.bat'
}
foreach ($relTag in @('v15.3.1', 'v15.3.0')) {
    $releasePath = Join-Path $repoRoot "docs\releases\$relTag.md"
    if (Test-Path $releasePath) {
        $relNote = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8
        $verPat = $relTag -replace 'v', '' -replace '\.', '\.'
        Assert-Coverage ($relNote -match $verPat) "$relTag.md mentions version" "docs/releases/$relTag.md"
        Assert-Coverage ($relNote.Length -gt 100) "$relTag.md non-trivial content" "docs/releases/$relTag.md"
    }
}
$ciRaw = $contentMap['scripts/ci.ps1']
if ($ciRaw) {
    Assert-Coverage ($ciRaw -match 'test-suite') 'ci.ps1 invokes test-suite' 'scripts/ci.ps1'
    Assert-Coverage ($ciRaw -match 'file-coverage') 'ci.ps1 invokes file-coverage' 'scripts/ci.ps1'
    Assert-Coverage ($ciRaw -match 'final-line-audit') 'ci.ps1 invokes final-line-audit' 'scripts/ci.ps1'
    Assert-Coverage ($ciRaw -match 'exit') 'ci.ps1 has exit codes' 'scripts/ci.ps1'
}

# [I] Min checks per file (anti-hollow coverage quota)
Write-Host '[I] Per-file minimum check quota' -ForegroundColor Yellow
$uncovered = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $manifest) {
    $count = if ($script:fileCheckCounts.ContainsKey($entry.RelPath)) { $script:fileCheckCounts[$entry.RelPath] } else { 0 }
    if ($count -lt $entry.MinChecks) {
        $uncovered.Add("$($entry.RelPath) has $count checks (need $($entry.MinChecks))")
    }
}
foreach ($u in $uncovered) { Assert-Coverage $false $u }
if ($uncovered.Count -eq 0) {
    Assert-Coverage $true "All $($manifest.Count) files meet minimum check quota"
}

# [J] install.ps1 ordering invariants
Write-Host '[J] install.ps1 safety ordering' -ForegroundColor Yellow
$install = $contentMap['install.ps1']
if ($install) {
    $adminIdx = $install.IndexOf('Administrator')
    $dryRunIdx = $install.IndexOf('$script:InstallDryRun')
    $dotSourceIdx = $install.IndexOf('foreach ($mod in $LibModules)')
    $preFlightIdx = $install.IndexOf('Invoke-PreFlightInternetGuard')
    $dryRunPreviewIdx = $install.IndexOf('Invoke-InstallDryRunPreview')
    Assert-Coverage (($adminIdx -ge 0) -and ($dryRunIdx -gt $adminIdx) -and ($dotSourceIdx -gt $dryRunIdx)) 'install.ps1: admin before dot-source' 'install.ps1'
    Assert-Coverage (($preFlightIdx -gt $dotSourceIdx) -and ($dryRunPreviewIdx -gt $preFlightIdx)) 'install.ps1: pre-flight before DryRun preview' 'install.ps1'
}

$coveredFiles = $script:fileCheckCounts.Keys.Count
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "FILE COVERAGE: $coveredFiles/$($manifest.Count) files, $passed assertions PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "FILE COVERAGE FAILED: $($failures.Count) / $passed passed" -ForegroundColor Red
$failures | Select-Object -First 40 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
if ($failures.Count -gt 40) { Write-Host "  ... and $($failures.Count - 40) more" -ForegroundColor Red }
exit 1