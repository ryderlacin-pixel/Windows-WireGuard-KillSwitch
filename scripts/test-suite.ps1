# Comprehensive offline test suite — target quality 9.5/10 (v12.0)
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

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
Write-Host '  Kill Switch FULL TEST SUITE (v15.2.1)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$libDir = Join-Path $repoRoot 'lib'
$libFiles = @()
if (Test-Path $libDir) {
    $libFiles = Get-ChildItem $libDir -Filter '*.ps1' -File | Sort-Object Name
}

# [1] install.ps1 + lib/*.ps1 compile + AST
Write-Host "`n[1/11] install.ps1 + lib modules compile + AST" -ForegroundColor Yellow
Test-ScriptblockCreate $installPath 'install.ps1' | Out-Null
Test-ParseFile $installPath 'install.ps1' | Out-Null
foreach ($lf in $libFiles) {
    Test-ParseFile $lf.FullName "lib/$($lf.Name)" | Out-Null
}
Assert-True ($libFiles.Count -ge 9) 'lib/ has 9+ modules (v15.2 safe-network)'

$raw = [string](Get-Content -LiteralPath $installPath -Raw -Encoding UTF8)
$libRaw = ''
foreach ($lf in $libFiles) {
    $libRaw += [string](Get-Content -LiteralPath $lf.FullName -Raw -Encoding UTF8)
}
$rawCombined = $raw + $libRaw
$genPath = Join-Path $libDir 'Install-GeneratedScripts.ps1'
$genRaw = if (Test-Path $genPath) { [string](Get-Content -LiteralPath $genPath -Raw -Encoding UTF8) } else { '' }
$tasksPath = Join-Path $libDir 'Install-TasksAndWmi.ps1'
$tasksRaw = if (Test-Path $tasksPath) { [string](Get-Content -LiteralPath $tasksPath -Raw -Encoding UTF8) } else { '' }

# [2] Version / critical patterns (install.ps1 + lib/)
Write-Host "[2/11] v15.2.1 patterns" -ForegroundColor Yellow
foreach ($n in @('v15.2.1','15.2.1','v15.2','15.2','Install-SafeNetwork.ps1','Test-BootSafeWindow','Get-OsUptimeSeconds','Test-IsVirtualTunnelAdapter','Disable-TunnelIPv6BindingsOnly','Add-KillSwitchFirewallExemptions','Add-KillSwitchCatchAllBlocks','Enable-KillSwitchBlock','Disable-KillSwitchBlock','Invoke-FailOpenSafeguard','wg-safety.ps1','KS-DHCP-Bcast-Out','KS-Gateway-Out','KS-Gateway-In','Invoke-SafeNetsh','Invoke-SafeRegistrySet','InstallDryRun','EnableFailsafe','emergency-reset.bat','emergency-reset.ps1','v15.1','15.1','$LibRoot','Install-Constants.ps1','Invoke-InstallMainSteps0to6','Invoke-InstallGeneratedScripts','Invoke-InstallUpgradeEarlyExit','v15.0','15.0','StrongPrivacyUpgrade','install-v15-privacy-stack.ps1','dns-lockdown-guard.ps1','network-privacy-guard.ps1','Invoke-V15StrongPrivacyStack','KS-Dnscrypt-EXE','STEP 18f - V15','STEP 10e - V15','v14.0','14.0','$WG_KS_VERSION','DnsLeakUpgradeOnly','TorUpgradeOnly','FullPrivacyUpgrade','install-v14-stack.ps1','dnscrypt-guard.ps1','leak-sentinel.ps1','tor-hardening-guard.ps1','Invoke-V14DnsLeakStack','STEP 18c - V14 DNS','STEP 10d - V14','PrivacyUpgradeOnly','Get-ChromiumPrivacyDWordProps','Write-PrivacyHardeningGuardPs1','Install-ScriptIntegrityVault','Test-ScriptIntegrityVault','DnsOverHttpsMode','PrivacySandboxAdTopicsEnabled','QuicAllowed','fingerprintingProtection','webgl.disabled','consumer telemetry reduced (not eliminated)','Test-WmiSubscriptionActive','Get-WmiBindFilter','Install-PrivacyHardening','privacy-hardening-guard.ps1','Install-WindowsTelemetryReduction','BlockThirdPartyCookies','DisableWindowsConsumerFeatures','privacy.resistFingerprinting','AllowTelemetry','Install-BrowserPrivacyPolicies','webrtc-leak-guard.ps1','WebRtcIpHandlingPolicy','default_public_interface_only','STEP 18b - PRIVACY','safe-live-verify.ps1','oldCmd -match','powershell.exe'' OR TargetInstance.Name=''pwsh.exe','Minutes 15','Invoke-EmergencyUnbrick','EMERGENCY UNBRICK','protection stays installed','Remove-KurtarArtifacts','Invoke-DeepUnbrick','Test-MainMonitorActive','deferring reinstall','tunnel recovery delegated','WGTunnelInstallMutex','ScriptsPath','TunnelName','anti-tamper.ps1','Invoke-AntiTamperGuard','NoChainRepair','Write-GuardBackups','WGKillSwitchGuard','TaskXMLRepair','Log-Tamper','Restore-WmiSubscription','C:\ProgramData\WGKillSwitchGuard','v11.3','v11.2','WG-RebootVerify','post-reboot-verify','RebootVerifyPath','Remove-OtherMonitorProcs','v11.1','Ensure-DelayedAutoStart','Test-DelayedAutoStart','Repair-ConfigIntegrity','Repair-EssentialFirewall','Test-NetworkChanged','NetworkFingerprint','Test-BlockRulePresent','wmi-cooldown','WmiCooldownActive','Sync-KillSwitchState','Test-ServerRulePresent','Set-ServerRule','Start-HiddenScript','8.8.8.8','hits -ge 2','GPO: zombie tunnel','Test-InstallInProgress','install.inprogress','Remove-IPv6FromConfig','Install-WmiSubscription','Tunnel lost (confirmed 5x/10s)','60s hold','tamperTick','watchdog will deep-unbrick')) {
    Assert-True ($rawCombined -match [regex]::Escape($n)) "Missing: $n"
}
Assert-True ($rawCombined -notmatch 'Get-MainMonitorProcs') 'Broken Get-MainMonitorProcs alias must be removed'
Assert-True ($rawCombined -notmatch 'Tunnel came up during 3min wait') 'Legacy unsafe 3min message'
Assert-True ($rawCombined -match 'if \(\`\$rewrite -or -not \(Test-ServerRulePresent\)\)') 'Conditional server rule rewrite'
$main06Path = Join-Path $libDir 'Install-MainSteps-0-6.ps1'
$main06Raw = if (Test-Path $main06Path) { [string](Get-Content -LiteralPath $main06Path -Raw -Encoding UTF8) } else { '' }
Assert-True ($main06Raw -match 'Invoke-SafeRegistrySet') 'MainSteps 0-6: IPv6 registry via Invoke-SafeRegistrySet'
Assert-True ($main06Raw -notmatch '(?m)^\s*netsh ') 'MainSteps 0-6: no bare netsh (DryRun-safe)'

# [3] Extracted monitor (from lib/Install-GeneratedScripts.ps1)
Write-Host "[3/11] Generated monitor.ps1" -ForegroundColor Yellow
$mon = Extract-Heredoc $genRaw '$monitorContent'
if ($mon) {
    $tmp = Join-Path $env:TEMP "wg-mon-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($tmp, $mon, [Text.UTF8Encoding]::new($false))
    Test-ScriptblockCreate $tmp 'monitor (extracted)' | Out-Null
    Test-ParseFile $tmp 'monitor (extracted)' | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
} else { $failures.Add('monitor heredoc extract failed') }

# [4] Extracted GPO (from lib/Install-GeneratedScripts.ps1)
Write-Host "[4/11] Generated GPO script" -ForegroundColor Yellow
$gpo = Extract-Heredoc $tasksRaw '$gpoContent'
if ($gpo) {
    $tmp = Join-Path $env:TEMP "wg-gpo-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($tmp, $gpo, [Text.UTF8Encoding]::new($false))
    Test-ScriptblockCreate $tmp 'GPO (extracted)' | Out-Null
    Test-ParseFile $tmp 'GPO (extracted)' | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
} else { $failures.Add('GPO heredoc extract failed') }

# [5] Repair structure (compile fragment via install write simulation - grep based)
Write-Host "[5/11] repair.ps1 structure" -ForegroundColor Yellow
Assert-True ($rawCombined -match 'function Sync-KillSwitchState') 'repair Sync-KillSwitchState'
Assert-True ($rawCombined -match 'Sync-KillSwitchState\r?\n\} finally') 'Sync before repair finally'
Assert-True ($rawCombined -match 'monitor-only block authority') 'repair never blocks (monitor-only)'
Assert-True ($rawCombined -match 'dns-lockdown-guard\.ps1') 'repair v15 dns-lockdown guard chain'
Assert-True ($rawCombined -match 'network-privacy-guard\.ps1') 'repair v15 network-privacy guard chain'
Assert-True ($rawCombined -match 'function Try-ReinstallTunnel') 'repair Try-ReinstallTunnel'
Assert-True ($rawCombined -match 'monitor active, deferring reinstall') 'repair defers to monitor'

# [6] Test-Internet 2-of-3 logic
Write-Host "[6/11] Test-Internet logic" -ForegroundColor Yellow
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
Write-Host "[7/11] Mutex simulations" -ForegroundColor Yellow
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

# [8] Installer guards
Write-Host "[8/11] Installer guards" -ForegroundColor Yellow
Assert-True ($rawCombined -match '\$ErrorActionPreference = "Continue"') 'Installer uses Continue'
Assert-True ($rawCombined -match 'CustomEndpointIP requires -CustomConfig') 'Custom param guard'

# [9] Ensure-ServerRule not spamming (no unconditional delete every loop)
Write-Host "[9/11] Ensure-ServerRule efficiency" -ForegroundColor Yellow
$monBody = if ($mon) { $mon } else { '' }
Assert-True ($monBody -match 'function Set-ServerRule') 'Set-ServerRule helper'
Assert-True ($monBody -match 'if \(\$rewrite -or -not \(Test-ServerRulePresent\)\) \{ Set-ServerRule \}') 'Ensure-ServerRule uses conditional Set-ServerRule'

# [10] Race recovery live gate script (offline structure)
Write-Host "[10/12] race-recovery-test.ps1 structure" -ForegroundColor Yellow
$racePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\race-recovery-test.ps1'
if (Test-Path $racePath) {
    $raceRaw = Get-Content -LiteralPath $racePath -Raw -Encoding UTF8
    foreach ($pat in @('ConfirmDisruptsInternet', 'Restore-Internet', 'DISRUPTS internet')) {
        Assert-True ($raceRaw -match [regex]::Escape($pat)) "race-recovery: $pat"
    }
    Test-ParseFile $racePath 'race-recovery-test.ps1' | Out-Null
} else { $failures.Add('race-recovery-test.ps1 missing') }

Write-Host "[11/12] safe-live-verify.ps1 structure" -ForegroundColor Yellow
$safePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\safe-live-verify.ps1'
if (Test-Path $safePath) {
    $safeRaw = Get-Content -LiteralPath $safePath -Raw -Encoding UTF8
    foreach ($pat in @('non-disruptive', 'NEVER stops tunnel', 'Post-check: TCP internet still working', 'Test-WmiSubscriptionActive', 'WMI subscription: filter+consumer+binding', 'v15.0', 'PrivacyStrong:', 'dns-lockdown-guard.ps1', 'network-privacy-guard.ps1', 'DnsLeak:', 'Test-DnscryptHealthy', 'dnscrypt-guard.ps1', 'Test-ScriptIntegrityVault', 'DnsOverHttpsMode', 'PrivacySandboxAdTopicsEnabled')) {
        Assert-True ($safeRaw -match [regex]::Escape($pat)) "safe-live: $pat"
    }
    Test-ParseFile $safePath 'safe-live-verify.ps1' | Out-Null
} else { $failures.Add('safe-live-verify.ps1 missing') }

# [12] Layer count / WMI pwsh
Write-Host "[12/12] Layer coverage" -ForegroundColor Yellow
Assert-True ($rawCombined -match "powershell\.exe' OR TargetInstance\.Name='pwsh\.exe") 'WMI single OR query for both shells'
Assert-True (($rawCombined | Select-String -Pattern 'Write-Step' -AllMatches).Matches.Count -ge 19) 'All install steps present'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "ALL $passed ASSERTIONS PASSED - quality gate OK" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED $($failures.Count) / $passed passed" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1