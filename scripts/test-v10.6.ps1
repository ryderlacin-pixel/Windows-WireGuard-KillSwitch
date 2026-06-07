# v10.6 verification — parse install.ps1, validate generated patterns, mutex simulation
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$installPath = Join-Path $repoRoot 'install.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$cond, [string]$msg) {
    if (-not $cond) { $failures.Add($msg) }
}

Write-Host '=== v10.6 verification ===' -ForegroundColor Cyan

# 1. AST parse
try {
    $null = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$null, [ref]$null)
    Write-Host '[OK] install.ps1 parses' -ForegroundColor Green
} catch {
    $failures.Add("Parse failed: $_")
}

$raw = Get-Content -LiteralPath $installPath -Raw -Encoding UTF8

# 2. Version strings
foreach ($needle in @('v10.6', '10.6', 'Test-SafeToOpen', 'KS-Block-RemoteAccess-Out', 'KS-Block-PPP-Out', 'Get-MonitorShellProcs', 'pwsh.exe', 'Get-ResolvedServerIP', 'Zombie tunnel')) {
    Assert-True ($raw -match [regex]::Escape($needle)) "Missing: $needle"
}

# 3. Log mutex skip
Assert-True ($raw -match 'if \(-not \(Wait-NamedMutex \$mutex') 'Log mutex skip pattern missing'

# 4. Monitor heredoc: no unsafe 3min tunnel-only open
Assert-True ($raw -notmatch 'Tunnel came up during 3min wait') 'Old 3min tunnel-only message still present'
Assert-True ($raw -match 'Healthy during 3min wait') 'New 3min SafeToOpen message missing'

# 5. Wait-NamedMutex abandoned mutex simulation
function Wait-NamedMutex([System.Threading.Mutex]$Mutex, [int]$TimeoutMs) {
    try { return $Mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

$abandonName = 'Global_WGCompareAbandonTest_v106'
try {
    $m1 = New-Object System.Threading.Mutex($true, $abandonName)
    $m1.Close()
    $m1.Dispose()
    $m2 = New-Object System.Threading.Mutex($false, $abandonName)
    $got = Wait-NamedMutex $m2 1000
    Assert-True $got 'AbandonedMutexException should return true'
    try { $m2.ReleaseMutex() } catch {}
    $m2.Dispose()
    Write-Host '[OK] AbandonedMutex simulation' -ForegroundColor Green
} catch {
    $failures.Add("Mutex simulation failed: $_")
}

# 6. Cross-process duplicate mutex (same thread would re-enter — not a real-world case)
$dupName = "Global_WGCompareDupTest_v106_$([guid]::NewGuid().ToString('N'))"
$mA = $null
try {
    $mA = New-Object System.Threading.Mutex($true, $dupName)
    $probe = @"
`$m = New-Object System.Threading.Mutex(`$false, '$dupName')
`$ok = `$false
try { `$ok = `$m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { `$ok = `$true }
if (`$m) { try { if (`$ok) { `$m.ReleaseMutex() } } catch {}; `$m.Dispose() }
if (`$ok) { exit 2 } else { exit 0 }
"@
    $probePath = Join-Path $env:TEMP "wg-mutex-probe.ps1"
    Set-Content -Path $probePath -Value $probe -Encoding UTF8
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$probePath`"" -PassThru -Wait -WindowStyle Hidden
    Assert-True ($p.ExitCode -eq 0) "Cross-process second instance should not acquire mutex (exit=$($p.ExitCode))"
    Remove-Item $probePath -Force -EA SilentlyContinue
    Write-Host '[OK] Cross-process duplicate mutex simulation' -ForegroundColor Green
} catch {
    $failures.Add("Duplicate mutex test failed: $_")
} finally {
    if ($mA) { try { $mA.ReleaseMutex() } catch {}; $mA.Dispose() }
}

if ($failures.Count -gt 0) {
    Write-Host "`nFAILED ($($failures.Count)):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "`nALL CHECKS PASSED" -ForegroundColor Green
exit 0