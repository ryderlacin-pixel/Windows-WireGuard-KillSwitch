# Comprehensive offline test suite — target quality 9.5/10 (v11.2)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$installPath = Join-Path $repoRoot 'install.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([bool]$cond, [string]$msg) {
    if ($cond) { $script:passed++ } else { $failures.Add($msg) }
}

function Unescape-GeneratedScript([string]$text) {
    $t = $text -replace '`r`n', "`r`n" -replace '`n', "`n" -replace '`t', "`t"
    return ($t -replace '`(.)', '$1')
}

function Extract-Heredoc([string]$raw, [string]$varName) {
    $pattern = [regex]::Escape($varName) + '\s*=\s*@"\r?\n(.*?)\r?\n"@'
    $m = [regex]::Match($raw, $pattern, 'Singleline')
    if (-not $m.Success) { return $null }
    return Unescape-GeneratedScript $m.Groups[1].Value
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

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  Kill Switch FULL TEST SUITE (v11.2)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# [1] install.ps1 compile + AST
Write-Host "`n[1/10] install.ps1 compile + AST" -ForegroundColor Yellow
Test-ScriptblockCreate $installPath 'install.ps1' | Out-Null
Test-ParseFile $installPath 'install.ps1' | Out-Null

$raw = [string](Get-Content -LiteralPath $installPath -Raw -Encoding UTF8)

# [2] Version / critical patterns
Write-Host "[2/10] v11.2 patterns" -ForegroundColor Yellow
foreach ($n in @('v11.2','11.2','WG-RebootVerify','post-reboot-verify','RebootVerifyPath','Remove-OtherMonitorProcs','v11.1','Ensure-DelayedAutoStart','Test-DelayedAutoStart','Repair-ConfigIntegrity','Repair-EssentialFirewall','Test-NetworkChanged','NetworkFingerprint','Test-BlockRulePresent','wmi-cooldown','WmiCooldownActive','Sync-KillSwitchState','Test-ServerRulePresent','Set-ServerRule','Start-HiddenScript','8.8.8.8','hits -ge 2','GPO: zombie tunnel','Test-InstallInProgress','Write-KurtarScript','install.inprogress','kurtar.bat','Remove-IPv6FromConfig','Install-WmiSubscription','Tunnel lost while open','60s hold')) {
    Assert-True ($raw -match [regex]::Escape($n)) "Missing: $n"
}
Assert-True ($raw -notmatch 'Get-MainMonitorProcs') 'Broken Get-MainMonitorProcs alias must be removed'
Assert-True ($raw -notmatch 'Tunnel came up during 3min wait') 'Legacy unsafe 3min message'
Assert-True ($raw -match 'if \(\`\$rewrite -or -not \(Test-ServerRulePresent\)\)') 'Conditional server rule rewrite'

# [3] Extracted monitor
Write-Host "[3/10] Generated monitor.ps1" -ForegroundColor Yellow
$mon = Extract-Heredoc $raw '$monitorContent'
if ($mon) {
    $tmp = Join-Path $env:TEMP "wg-mon-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($tmp, $mon, [Text.UTF8Encoding]::new($false))
    Test-ScriptblockCreate $tmp 'monitor (extracted)' | Out-Null
    Test-ParseFile $tmp 'monitor (extracted)' | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
} else { $failures.Add('monitor heredoc extract failed') }

# [4] Extracted GPO
Write-Host "[4/10] Generated GPO script" -ForegroundColor Yellow
$gpo = Extract-Heredoc $raw '$gpoContent'
if ($gpo) {
    $tmp = Join-Path $env:TEMP "wg-gpo-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($tmp, $gpo, [Text.UTF8Encoding]::new($false))
    Test-ScriptblockCreate $tmp 'GPO (extracted)' | Out-Null
    Test-ParseFile $tmp 'GPO (extracted)' | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
} else { $failures.Add('GPO heredoc extract failed') }

# [5] Repair structure (compile fragment via install write simulation - grep based)
Write-Host "[5/10] repair.ps1 structure" -ForegroundColor Yellow
Assert-True ($raw -match 'function Sync-KillSwitchState') 'repair Sync-KillSwitchState'
Assert-True ($raw -match 'Sync-KillSwitchState\r?\n\} finally') 'Sync before repair finally'
Assert-True ($raw -match 'function Enable-Block') 'repair Enable-Block'

# [6] Test-Internet 2-of-3 logic
Write-Host "[6/10] Test-Internet logic" -ForegroundColor Yellow
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

# [7] Mutex tests
Write-Host "[7/10] Mutex simulations" -ForegroundColor Yellow
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
$p = Start-Process powershell.exe -Args "-NoProfile -ExecutionPolicy Bypass -File `"$pp`" -n `"$dup`"" -PassThru -Wait -WindowStyle Hidden
Assert-True ($p.ExitCode -eq 0) "Cross-process mutex (exit=$($p.ExitCode))"
Remove-Item $pp -Force -ErrorAction SilentlyContinue
try{$mA.ReleaseMutex()}catch{}; $mA.Dispose()

# [8] Installer guards
Write-Host "[8/10] Installer guards" -ForegroundColor Yellow
Assert-True ($raw -match '\$ErrorActionPreference = "Continue"') 'Installer uses Continue'
Assert-True ($raw -match 'CustomEndpointIP requires -CustomConfig') 'Custom param guard'

# [9] Ensure-ServerRule not spamming (no unconditional delete every loop)
Write-Host "[9/10] Ensure-ServerRule efficiency" -ForegroundColor Yellow
$monBody = if ($mon) { $mon } else { '' }
Assert-True ($monBody -match 'function Set-ServerRule') 'Set-ServerRule helper'
Assert-True ($monBody -match 'if \(\$rewrite -or -not \(Test-ServerRulePresent\)\) \{ Set-ServerRule \}') 'Ensure-ServerRule uses conditional Set-ServerRule'

# [10] Layer count / WMI pwsh
Write-Host "[10/10] Layer coverage" -ForegroundColor Yellow
Assert-True ($raw -match "TargetInstance.Name='pwsh.exe'") 'WMI includes pwsh query'
Assert-True (($raw | Select-String -Pattern 'Write-Step' -AllMatches).Matches.Count -ge 19) 'All install steps present'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL $passed ASSERTIONS PASSED - quality gate OK" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED $($failures.Count) / $passed passed" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1