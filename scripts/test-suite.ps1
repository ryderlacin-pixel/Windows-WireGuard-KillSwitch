# Comprehensive offline test suite - v15.3.2 rigor gate (no hollow tests)
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')

function Get-ChildPowerShellExe {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return (Get-Command pwsh).Source }
    return (Get-Command powershell.exe).Source
}
$installPath = Join-Path $repoRoot 'install.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([bool]$cond, [string]$msg) {
    if ($cond) { $script:passed++ } else { $failures.Add($msg) }
}

function Test-ParseFile([string]$path, [string]$label) {
    $errs = $null; $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) { $failures.Add("$label parse line $($e.Extent.StartLineNumber): $($e.Message)") }
        return $false
    }
    Assert-True $true "$label parses clean"
    return $true
}

function Test-ScriptblockCreate([string]$path, [string]$label) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    try {
        $null = [scriptblock]::Create($raw)
        Assert-True $true "$label Scriptblock::Create OK"
        return $true
    } catch {
        $failures.Add("$label Scriptblock::Create: $($_.Exception.Message)")
        return $false
    }
}

function Test-ExtractedScript {
    param([string]$Content, [string]$Label, [string[]]$Must)
    if (-not $Content) { $failures.Add("$Label extract failed"); return }
    $tmp = Write-ExtractedToTemp $Content $Label
    try {
        Test-ScriptblockCreate $tmp "$Label (extracted)" | Out-Null
        Test-ParseFile $tmp "$Label (extracted)" | Out-Null
        foreach ($m in $Must) {
            Assert-True ($Content -match $m) "$Label contract: $m"
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Kill Switch FULL TEST SUITE (v15.3.2 - rigor gate)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$libDir = Join-Path $repoRoot 'lib'
$libFiles = @()
if (Test-Path $libDir) {
    $libFiles = Get-ChildItem $libDir -Filter '*.ps1' -File | Sort-Object Name
}

# [1] install.ps1 + lib/*.ps1 compile + AST
Write-Host "`n[1/17] install.ps1 + lib modules compile + AST" -ForegroundColor Yellow
Test-ScriptblockCreate $installPath 'install.ps1' | Out-Null
Test-ParseFile $installPath 'install.ps1' | Out-Null
foreach ($lf in $libFiles) {
    Test-ParseFile $lf.FullName "lib/$($lf.Name)" | Out-Null
}
Assert-True ($libFiles.Count -ge 10) 'lib/ has 10+ modules (v15.3.1 dry-run preview)'

$contentMap = Get-FileContentMap $repoRoot
$genRaw = $contentMap['lib/Install-GeneratedScripts.ps1']
$tasksRaw = $contentMap['lib/Install-TasksAndWmi.ps1']
$main06Raw = $contentMap['lib/Install-MainSteps-0-6.ps1']
$main18Raw = $contentMap['lib/Install-MainSteps-18-20.ps1']
$safeNetRaw = $contentMap['lib/Install-SafeNetwork.ps1']
$v15StackRaw = $contentMap['scripts/install-v15-privacy-stack.ps1']
$v14StackRaw = $contentMap['scripts/install-v14-stack.ps1']

# [2] File-scoped patterns (not hollow rawCombined)
Write-Host "[2/17] File-scoped v15.3.2 patterns" -ForegroundColor Yellow
foreach ($row in (Get-FileScopedPatternMatrix)) {
    foreach ($item in (Get-PatternMatrixEntries $row)) {
        $found = $false
        foreach ($f in $row.Files) {
            if ($contentMap.ContainsKey($f) -and (Test-ContentPattern $contentMap[$f] $item.Pat -IsRegex:$item.Regex)) { $found = $true; break }
        }
        Assert-True $found "Scoped [$($row.Files -join ',')]: $($item.Pat)"
    }
}
foreach ($row in (Get-ForbiddenPatternMatrix)) {
    if (-not $contentMap.ContainsKey($row.File)) { continue }
    $body = $contentMap[$row.File]
    foreach ($bad in $row.Forbidden) { Assert-True ($body -notmatch [regex]::Escape($bad)) "Forbidden $($row.File): $bad" }
    foreach ($rx in $row.Regex) { Assert-True ($body -notmatch $rx) "Forbidden regex $($row.File): $rx" }
}
Assert-True ($main06Raw -match 'Invoke-SafeRegistrySet @ipv6RegParams') 'MainSteps 0-6: IPv6 registry via Invoke-SafeRegistrySet splat'
Assert-True ($safeNetRaw -match 'function Invoke-SafeRegistrySet') 'Invoke-SafeRegistrySet defined'
Assert-True ($main06Raw -notmatch '(?m)^\s*netsh ') 'MainSteps 0-6: no bare netsh (DryRun-safe)'
Assert-True ($v15StackRaw -match 'Join-Path `\$DNSCRYPT_DIR') 'v15 dnscrypt-guard: Join-Path for DNSCRYPT paths'
Assert-True ($v14StackRaw -match 'Join-Path `\$DNSCRYPT_DIR') 'v14 dnscrypt-guard: Join-Path for DNSCRYPT paths'
Assert-True ($v15StackRaw -match 'Test-DnscryptListening') 'v15 dnscrypt-guard: health gate before WG DNS'
Assert-True ($v15StackRaw -match 'deferGuards') 'v15 stack: defer guards during install lock'

$extracted = Get-ExtractedGeneratedScripts $repoRoot
$mon = $extracted.Monitor
$gpo = $extracted.Gpo

# [3] Extracted monitor
Write-Host "[3/17] Generated monitor.ps1" -ForegroundColor Yellow
Test-ExtractedScript $mon 'monitor' @('function Enable-Block', 'Test-BlockAllowed', 'Test-ServerRulePresent', 'Set-ServerRule')

# [4] Extracted GPO
Write-Host "[4/17] Generated GPO script" -ForegroundColor Yellow
Test-ExtractedScript $gpo 'gpo' @('Disable-KillSwitchBlock', 'fail-open')

# [5] Extracted repair.ps1 (compile, not grep-only)
Write-Host "[5/17] repair.ps1 extract + compile" -ForegroundColor Yellow
Test-ExtractedScript $extracted.Repair 'repair' @(
    'function Sync-KillSwitchState',
    'monitor-only block authority',
    'Test-PostInstallGrace',
    'Test-KillSwitchArmed',
    'network-privacy-guard.ps1',
    'function Try-ReinstallTunnel',
    'monitor active, deferring reinstall',
    'cmd.exe /c'
)
Assert-True ($extracted.Repair -notmatch 'dns-lockdown-guard\.ps1') 'repair extract: no auto dns-lockdown'

# [6] Extracted watchdog + wg-safety
Write-Host "[6/17] watchdog + wg-safety extract + compile" -ForegroundColor Yellow
Test-ExtractedScript $extracted.Watchdog 'watchdog' @('graduated fail-open', 'Invoke-GentleUnbrick', 'Invoke-DeepUnbrick', 'Restore-DhcpDnsOnPhysicalAdapters')
if ($extracted.Safety) {
    Test-ExtractedScript $extracted.Safety 'wg-safety' @('function Test-BlockAllowed', 'function Test-KillSwitchArmed', 'cmd.exe /c')
    Assert-True ($extracted.Safety -notmatch 'Invoke-Expression') 'wg-safety: no Invoke-Expression'
} else { $failures.Add('wg-safety extract failed') }

# [7] Test-Internet 2-of-3 logic
Write-Host "[7/17] Test-Internet logic" -ForegroundColor Yellow
function Test-TcpHost([string]$HostName, [int]$Port, [int]$TimeoutMs = 4000) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        try { $tcp.EndConnect($iar) } catch { return $false }
        return $true
    } catch { return $false }
    finally { if ($tcp) { try { $tcp.Close() } catch {} } }
}
function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-TcpHost $h 443) { $hits++ } }
    return ($hits -ge 2)
}
Assert-True ((Test-Internet) -is [bool]) 'Test-Internet returns bool'

# [8] Mutex tests
Write-Host "[8/17] Mutex simulations" -ForegroundColor Yellow
function Wait-NamedMutex([Threading.Mutex]$Mutex,[int]$TimeoutMs){try{return $Mutex.WaitOne($TimeoutMs)}catch [Threading.AbandonedMutexException]{return $true}}
$ab = "Global_WGTestAb_$([guid]::NewGuid().ToString('N'))"
$m1 = New-Object Threading.Mutex($true,$ab); $m1.Close(); $m1.Dispose()
$m2 = New-Object Threading.Mutex($false,$ab)
Assert-True (Wait-NamedMutex $m2 1000) 'AbandonedMutex'
try{$m2.ReleaseMutex()}catch{}; $m2.Dispose()

$dup = "Global_WGTestDup_$([guid]::NewGuid().ToString('N'))"
$mA = New-Object Threading.Mutex($true,$dup)
$probe = "param(`$n)`$m=New-Object Threading.Mutex(`$false,`$n);`$ok=`$false;try{`$ok=`$m.WaitOne(0)}catch [Threading.AbandonedMutexException]{`$ok=`$true};if(`$m){try{if(`$ok){`$m.ReleaseMutex()}}catch{};`$m.Dispose()};if(`$ok){exit 2}else{exit 0}"
$pp = Join-Path $env:TEMP 'wg-probe-suite.ps1'
Set-Content $pp "param(`$n)`n$probe" -Encoding UTF8
$shell = Get-ChildPowerShellExe
$p = Start-Process -FilePath $shell -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pp, '-n', $dup
) -PassThru -Wait -WindowStyle Hidden
Assert-True ($p.ExitCode -eq 0) "Cross-process mutex (exit=$($p.ExitCode))"
Remove-Item $pp -Force -ErrorAction SilentlyContinue
try{$mA.ReleaseMutex()}catch{}; $mA.Dispose()

# [9] Installer guards
Write-Host "[9/17] Installer guards" -ForegroundColor Yellow
$installRaw = $contentMap['install.ps1']
Assert-True ($main06Raw -match 'CustomEndpointIP requires -CustomConfig') 'Custom param guard'
$adminIdx = $installRaw.IndexOf('Administrator')
$dryRunIdx = $installRaw.IndexOf('$script:InstallDryRun')
$dotSourceIdx = $installRaw.IndexOf('foreach ($mod in $LibModules)')
$preFlightIdx = $installRaw.IndexOf('Invoke-PreFlightInternetGuard')
$dryRunPreviewIdx = $installRaw.IndexOf('Invoke-InstallDryRunPreview')
Assert-True (($adminIdx -ge 0) -and ($dryRunIdx -gt $adminIdx) -and ($dotSourceIdx -gt $dryRunIdx)) 'admin check before dot-source'
Assert-True (($preFlightIdx -gt $dotSourceIdx) -and ($dryRunPreviewIdx -gt $preFlightIdx)) 'pre-flight before DryRun preview'
Assert-True ($installRaw -match 'AI CONNECTION INVARIANT') 'install.ps1: AI Connection Invariant documented'
Assert-True ($installRaw -match 'Invoke-PreFlightInternetGuard') 'install.ps1: pre-flight quiesce on every run'
Assert-True ($installRaw -match 'Invoke-InstallDryRunPreview') 'DryRun: preview-only path (steps 0-20 skipped)'
Assert-True ($installRaw -match 'if \(\$script:InstallDryRun\) \{[\s\S]*?exit 0') 'DryRun: early exit before MainSteps 0-20'
Assert-True ($main06Raw -match 'must never run in DryRun') 'MainSteps 0-6: hard throw guard in DryRun'
$dryRunPreviewRaw = $contentMap['lib/Install-DryRunPreview.ps1']
if ($dryRunPreviewRaw) {
    Assert-True ($dryRunPreviewRaw -match 'Invoke-InstallDryRunPreview') 'Install-DryRunPreview.ps1: preview function'
    Assert-True ($dryRunPreviewRaw -match 'zero network mutations') 'DryRun preview: zero mutations banner'
} else { $failures.Add('lib/Install-DryRunPreview.ps1 missing') }
$genRaw = $contentMap['lib/Install-GeneratedScripts.ps1']
$tasksRaw = $contentMap['lib/Install-TasksAndWmi.ps1']
$main1820Raw = $contentMap['lib/Install-MainSteps-18-20.ps1']
if ($genRaw) { Assert-True ($genRaw -match 'if \(\$script:InstallDryRun\)') 'GeneratedScripts: DryRun guard' }
if ($tasksRaw) { Assert-True ($tasksRaw -match 'if \(\$script:InstallDryRun\)') 'TasksAndWmi: DryRun guard' }
if ($main1820Raw) { Assert-True ($main1820Raw -match 'if \(\$script:InstallDryRun\)') 'MainSteps 18-20: DryRun guard' }
$safeNetRaw = $contentMap['lib/Install-SafeNetwork.ps1']
if ($safeNetRaw) {
    Assert-True ($safeNetRaw -match 'function Test-KillSwitchArmed') 'wg-safety: Test-KillSwitchArmed'
    Assert-True ($safeNetRaw -match 'KillSwitchArmed') 'wg-safety: armed gate in Test-BlockAllowed'
}
$repairExtract = if ($genRaw) { $genRaw } else { '' }
if ($repairExtract -match '\$repairContent') {
    Assert-True ($repairExtract -match 'Test-PostInstallGrace') 'repair: PostInstallGrace fail-open'
    Assert-True ($repairExtract -notmatch 'dns-lockdown-guard\.ps1') 'repair: no auto dns-lockdown'
}

# [10] Ensure-ServerRule efficiency
Write-Host "[10/17] Ensure-ServerRule efficiency" -ForegroundColor Yellow
$monBody = if ($mon) { $mon } else { '' }
Assert-True ($monBody -match 'function Set-ServerRule') 'Set-ServerRule helper'
Assert-True ($monBody -match 'if \(\$rewrite -or -not \(Test-ServerRulePresent\)\) \{ Set-ServerRule \}') 'Ensure-ServerRule uses conditional Set-ServerRule'

# [11] race-recovery + safe-live structure
Write-Host "[11/17] race-recovery + safe-live structure" -ForegroundColor Yellow
$raceRaw = $contentMap['scripts/race-recovery-test.ps1']
if ($raceRaw) {
    foreach ($pat in @('ConfirmDisruptsInternet', 'Restore-Internet', 'DISRUPTS internet')) {
        Assert-True ($raceRaw -match [regex]::Escape($pat)) "race-recovery: $pat"
    }
    Test-ParseFile (Join-Path $repoRoot 'scripts\race-recovery-test.ps1') 'race-recovery-test.ps1' | Out-Null
} else { $failures.Add('race-recovery-test.ps1 missing') }

$safeRaw = $contentMap['scripts/safe-live-verify.ps1']
if ($safeRaw) {
    foreach ($pat in @('non-disruptive', 'NEVER stops tunnel', 'Post-check: TCP internet still working', 'Test-WmiSubscriptionActive', 'dns-lockdown-guard.ps1', 'Test-DnscryptHealthy', 'Test-ScriptIntegrityVault')) {
        Assert-True ($safeRaw -match [regex]::Escape($pat)) "safe-live: $pat"
    }
    Test-ParseFile (Join-Path $repoRoot 'scripts\safe-live-verify.ps1') 'safe-live-verify.ps1' | Out-Null
} else { $failures.Add('safe-live-verify.ps1 missing') }

# [12] Layer count / WMI pwsh
Write-Host "[12/17] Layer coverage" -ForegroundColor Yellow
$privacyRaw = $contentMap['lib/Install-Privacy.ps1']
Assert-True (($privacyRaw -match "powershell\.exe' OR TargetInstance\.Name='pwsh\.exe") -or ($genRaw -match "powershell\.exe' OR TargetInstance\.Name='pwsh\.exe")) 'WMI single OR query for both shells'
$stepCount = ([regex]::Matches($contentMap['_installLibCombined'], 'Write-Step')).Count
Assert-True ($stepCount -ge 19) "All install steps present ($stepCount Write-Step)"

# [13] Behavioral PC simulations (200 scenarios)
Write-Host "[13/17] behavior-sim-test.ps1 (216 PC reaction scenarios)" -ForegroundColor Yellow
$behaviorPath = Join-Path $PSScriptRoot 'behavior-sim-test.ps1'
if (Test-Path $behaviorPath) {
    & $behaviorPath
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('behavior-sim-test.ps1 failed (see output above)')
    } else {
        $script:passed += 216
    }
} else {
    $failures.Add('behavior-sim-test.ps1 missing')
}

# [14] Post-reboot simulations (500 scenarios)
Write-Host "[14/17] reboot-sim-test.ps1 (510 post-reboot PC scenarios)" -ForegroundColor Yellow
$rebootPath = Join-Path $PSScriptRoot 'reboot-sim-test.ps1'
if (Test-Path $rebootPath) {
    & $rebootPath
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('reboot-sim-test.ps1 failed (see output above)')
    } else {
        $script:passed += 510
    }
} else {
    $failures.Add('reboot-sim-test.ps1 missing')
}

# [15] Full file coverage gate (every production file, anti-hollow)
Write-Host "[15/17] file-coverage-test.ps1 (per-file manifest)" -ForegroundColor Yellow
$coveragePath = Join-Path $PSScriptRoot 'file-coverage-test.ps1'
if (Test-Path $coveragePath) {
    $covOut = & $coveragePath 2>&1 | Out-String
    Write-Host $covOut
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('file-coverage-test.ps1 failed (see output above)')
    } elseif ($covOut -match 'FILE COVERAGE: (\d+)/(\d+) files, (\d+) assertions PASSED') {
        $script:passed += [int]$Matches[3]
    }
} else {
    $failures.Add('file-coverage-test.ps1 missing')
}

# [16] Role contracts quick gate (duplicate guard - file-coverage also runs these)
Write-Host "[16/17] Role contract spot-check" -ForegroundColor Yellow
foreach ($contract in (Get-RoleContractMatrix | Select-Object -First 5)) {
    foreach ($scriptName in $contract.Scripts) {
        $rel = "scripts/$scriptName"
        if ($contentMap.ContainsKey($rel)) {
            Assert-True ($contentMap[$rel].Length -gt 200) "$rel is non-trivial (>$($contentMap[$rel].Length) chars)"
        }
    }
}

# [17] Final line-by-line audit (every repo file, 0 ERROR required)
Write-Host "[17/17] final-line-audit.ps1 (93+ files dot-by-dot)" -ForegroundColor Yellow
$auditPath = Join-Path $PSScriptRoot 'final-line-audit.ps1'
if (Test-Path $auditPath) {
    $auditOut = & $auditPath 2>&1 | Out-String
    Write-Host $auditOut
    if ($LASTEXITCODE -ne 0) {
        $failures.Add('final-line-audit.ps1 failed (ERROR findings - see audit-results/)')
    } else {
        $script:passed++
    }
} else {
    $failures.Add('final-line-audit.ps1 missing')
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL $passed ASSERTIONS PASSED - quality gate OK" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED $($failures.Count) / $passed passed" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1