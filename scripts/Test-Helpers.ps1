# Shared offline test helpers - dot-sourced by test-suite, behavior-sim, reboot-sim, file-coverage
#Requires -Version 5.1

function Unescape-GeneratedScript([string]$Text) {
    $t = $Text -replace '`r`n', "`r`n" -replace '`n', "`n" -replace '`t', "`t"
    return ($t -replace '`(.)', '$1')
}

function Extract-HeredocAtDoubleQuote([string]$Raw, [string]$VarName) {
    $pattern = [regex]::Escape($VarName) + '\s*=\s*@"\r?\n(.*?)\r?\n"@'
    $m = [regex]::Match($Raw, $pattern, 'Singleline')
    if (-not $m.Success) { return $null }
    return Unescape-GeneratedScript $m.Groups[1].Value
}

function Extract-HeredocAtSingleQuote([string]$Raw, [string]$VarName) {
    $pattern = [regex]::Escape($VarName) + "\s*=\s*@'(.*?)'@"
    $m = [regex]::Match($Raw, $pattern, 'Singleline')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-SimulatedRepairContent {
    param(
        [string]$GenRaw,
        [string]$Version = '15.2.9'
    )
    if ([string]::IsNullOrWhiteSpace($GenRaw)) { return $null }
    $m = [regex]::Match($GenRaw, '(?s)"@\s*\+\s*@''(.*?)''@\s*\r?\n\$repairContent\s*\|', 'Singleline')
    if (-not $m.Success) { return $null }
    $body = $m.Groups[1].Value
    $header = @"
# WG Repair Script v$Version (simulated test extract)
`$TASK_MONITOR = "WG-KillSwitch"
`$MONITOR      = "C:\WireGuard\monitor.ps1"
`$LOG          = "C:\WireGuard\killswitch.log"
`$WG_EXE       = "C:\Program Files\WireGuard\wireguard.exe"
`$LOCK         = "C:\WireGuard\repair.lock"
`$TUNNEL_SVC  = 'WireGuardTunnel`$wgcf-profile'
`$TUNNEL_NAME = 'wgcf-profile'
`$CONFIG      = 'C:\WireGuard\wgcf-profile.conf'
`$WG_SVC_NAME = 'WGKillSwitchSvc'
`$REG_KEY     = 'HKLM:\SOFTWARE\WGKillSwitch'
`$SERVER_PORT = '2408'
"@
    return ($header + "`r`n" + $body)
}

function Get-ExtractedGeneratedScripts {
    param([string]$RepoRoot)
    $libDir = Join-Path $RepoRoot 'lib'
    $genRaw = [string](Get-Content (Join-Path $libDir 'Install-GeneratedScripts.ps1') -Raw -Encoding UTF8 -EA SilentlyContinue)
    $tasksRaw = [string](Get-Content (Join-Path $libDir 'Install-TasksAndWmi.ps1') -Raw -Encoding UTF8 -EA SilentlyContinue)
    $safeNetPath = Join-Path $libDir 'Install-SafeNetwork.ps1'
    $monitor = Extract-HeredocAtDoubleQuote $genRaw '$monitorContent'
    $gpo = Extract-HeredocAtDoubleQuote $tasksRaw '$gpoContent'
    $repair = Get-SimulatedRepairContent $genRaw
    $watchdog = Extract-HeredocAtDoubleQuote $genRaw '$watchdogContent'
    $safety = $null
    if (Test-Path $safeNetPath) {
        $script:InstallDryRun = $true
        $script:EnableFailsafe = $true
        . $safeNetPath
        $safety = Get-WgSafetyRuntimeScript -Version '15.2.9'
    }
    return [PSCustomObject]@{
        GenRaw    = $genRaw
        TasksRaw  = $tasksRaw
        Monitor   = $monitor
        Gpo       = $gpo
        Repair    = $repair
        Watchdog  = $watchdog
        Safety    = $safety
    }
}

function Test-ParseContent {
    param([string]$Content, [string]$Label, [System.Collections.Generic.List[string]]$Failures)
    $errs = $null; $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tok, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in $errs) { $Failures.Add("$Label parse line $($e.Extent.StartLineNumber): $($e.Message)") }
        return $false
    }
    return $true
}

function Test-ScriptblockContent {
    param([string]$Content, [string]$Label, [System.Collections.Generic.List[string]]$Failures)
    try {
        $null = [scriptblock]::Create($Content)
        return $true
    } catch {
        $Failures.Add("$Label Scriptblock::Create: $($_.Exception.Message)")
        return $false
    }
}

function Write-ExtractedToTemp {
    param([string]$Content, [string]$Prefix)
    $tmp = Join-Path $env:TEMP "wg-$Prefix-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
    return $tmp
}

function Get-CiScriptSkipList {
    return @(
        'parse-bisect.ps1', 'parse-bisect2.ps1', 'parse-bisect3.ps1',
        'parse-bisect4.ps1', 'parse-bisect5.ps1', 'parse-any.ps1',
        'test-v10.6.ps1', 'github-visibility.ps1', 'open-launch-links.ps1',
        'split-install-lib.ps1', 'wrap-install-lib.ps1', 'ci.ps1',
        'Test-Helpers.ps1'
    )
}

function Get-ProductionFileManifest {
    param([string]$RepoRoot)
    $entries = [System.Collections.Generic.List[object]]::new()
    $skip = Get-CiScriptSkipList

    $entries.Add([PSCustomObject]@{ RelPath = 'install.ps1'; Group = 'core'; MinChecks = 5 })
    $entries.Add([PSCustomObject]@{ RelPath = 'emergency-reset.bat'; Group = 'emergency'; MinChecks = 4 })

    $libDir = Join-Path $RepoRoot 'lib'
    if (Test-Path $libDir) {
        foreach ($f in (Get-ChildItem $libDir -Filter '*.ps1' -File | Sort-Object Name)) {
            $entries.Add([PSCustomObject]@{ RelPath = "lib/$($f.Name)"; Group = 'lib'; MinChecks = 5 })
        }
    }

    $scriptsDir = Join-Path $RepoRoot 'scripts'
    if (Test-Path $scriptsDir) {
        foreach ($f in (Get-ChildItem $scriptsDir -Filter '*.ps1' -File | Sort-Object Name)) {
            if ($skip -contains $f.Name) { continue }
            $grp = switch -Regex ($f.Name) {
                'audit' { 'audit' }
                'verify|safe-live' { 'verify' }
                'install-v\d|install-tor' { 'stack' }
                'emergency' { 'emergency' }
                'stress|race-recovery' { 'destructive' }
                'tor-' { 'tor' }
                'ci|run-all|pre-push|test-suite|parse-check|scriptblock|behavior-sim|reboot-sim|file-coverage|final-line-audit' { 'ci' }
                default { 'ops' }
            }
            $min = if ($grp -eq 'ci') { 3 } else { 4 }
            $entries.Add([PSCustomObject]@{ RelPath = "scripts/$($f.Name)"; Group = $grp; MinChecks = $min })
        }
    }

    $manifestDir = Join-Path $RepoRoot 'manifests'
    if (Test-Path $manifestDir) {
        foreach ($f in (Get-ChildItem $manifestDir -Filter '*.json' -File)) {
            $entries.Add([PSCustomObject]@{ RelPath = "manifests/$($f.Name)"; Group = 'manifest'; MinChecks = 2 })
        }
    }

    $releaseNote = Join-Path $RepoRoot 'docs\releases\v15.2.9.md'
    if (Test-Path $releaseNote) {
        $entries.Add([PSCustomObject]@{ RelPath = 'docs/releases/v15.2.9.md'; Group = 'docs'; MinChecks = 2 })
    }

    return $entries
}

function Get-FileContentMap {
    param([string]$RepoRoot)
    $map = @{}
    foreach ($e in (Get-ProductionFileManifest $RepoRoot)) {
        $full = Join-Path $RepoRoot ($e.RelPath -replace '/', '\')
        if (Test-Path $full) {
            $map[$e.RelPath] = [string](Get-Content -LiteralPath $full -Raw -Encoding UTF8)
        }
    }
    $libDir = Join-Path $RepoRoot 'lib'
    $libRaw = ''
    if (Test-Path $libDir) {
        foreach ($lf in (Get-ChildItem $libDir -Filter '*.ps1' -File)) {
            $libRaw += [string](Get-Content -LiteralPath $lf.FullName -Raw -Encoding UTF8)
        }
    }
    $map['_libCombined'] = $libRaw
    $install = Join-Path $RepoRoot 'install.ps1'
    if (Test-Path $install) {
        $map['_installLibCombined'] = [string](Get-Content -LiteralPath $install -Raw -Encoding UTF8) + $libRaw
    }
    foreach ($extra in @('emergency-reset.bat', 'scripts/ci.ps1')) {
        $full = Join-Path $RepoRoot ($extra -replace '/', '\')
        if ((Test-Path $full) -and -not $map.ContainsKey($extra)) {
            $map[$extra] = [string](Get-Content -LiteralPath $full -Raw -Encoding UTF8)
        }
    }
    return $map
}

function Get-PatternMatrixEntries {
    param($Row)
    $entries = [System.Collections.Generic.List[object]]::new()
    $must = if ($Row.ContainsKey('Must') -and $Row.Must) { $Row.Must } elseif ($Row.Must) { $Row.Must } else { @() }
    $mustRegex = if ($Row.ContainsKey('MustRegex') -and $Row.MustRegex) { $Row.MustRegex } elseif ($Row.PSObject.Properties.Name -contains 'MustRegex' -and $Row.MustRegex) { $Row.MustRegex } else { @() }
    foreach ($p in $must) { $entries.Add(@{ Pat = $p; Regex = $false }) }
    foreach ($p in $mustRegex) { $entries.Add(@{ Pat = $p; Regex = $true }) }
    return $entries
}

function Test-ContentPattern {
    param(
        [string]$Body,
        [string]$Pattern,
        [switch]$IsRegex
    )
    if ([string]::IsNullOrEmpty($Body)) { return $false }
    if ($IsRegex) { return ($Body -match $Pattern) }
    return ($Body -match [regex]::Escape($Pattern))
}

function Get-ForbiddenPatternMatrix {
    return @(
        @{ File = 'lib/Install-MainSteps-0-6.ps1'; Forbidden = @('Add-KillSwitchCatchAllBlocks'); Regex = @('(?m)^\s*netsh advfirewall') }
        @{ File = 'lib/Install-SafeNetwork.ps1'; Forbidden = @(); Regex = @('(?m)^\s+Invoke-Expression\s') }
        @{ File = 'lib/Install-GeneratedScripts.ps1'; Forbidden = @('function IsMainMonitor'); Regex = @('repair[\s\S]{0,8000}Invoke-Expression\s+\$') }
        @{ File = 'lib/Install-UpgradePaths.ps1'; Forbidden = @(); Regex = @("@'\s*\+\s*`$[^`"]+\s*\+\s*@'") }
        @{ File = '_installLibCombined'; Forbidden = @('Get-MainMonitorProcs', 'function IsMainMonitor', 'Tunnel came up during 3min wait'); Regex = @() }
    )
}

function Get-FileScopedPatternMatrix {
    return @(
        @{ Files = @('install.ps1'); Must = @('v15.2.9', '15.2.9', '$LibRoot', 'Install-Constants.ps1', 'Set-Location -LiteralPath $PSScriptRoot', 'v15.1', 'v15.0', 'v14.0', '14.0', 'Invoke-InstallMainSteps0to6', 'Invoke-InstallGeneratedScripts', 'Invoke-InstallUpgradeEarlyExit', 'install-v14-stack.ps1', 'install-v15-privacy-stack.ps1') }
        @{ Files = @('lib/Install-Constants.ps1'); Must = @('$WG_KS_VERSION', '15.2.9', 'C:\ProgramData\WGKillSwitchGuard', 'webrtc-leak-guard.ps1', 'dnscrypt-guard.ps1', 'leak-sentinel.ps1', 'tor-hardening-guard.ps1') }
        @{ Files = @('lib/Install-Helpers.ps1'); Must = @('Register-RepairTaskDualTrigger', 'Refresh-RegistryTaskBackups', 'Backup-TunnelConfig', 'Restore-TunnelConfigIfMissing', 'Invoke-GuardScriptSafe', 'Test-SafeToOpen', 'Restore-DhcpDnsOnPhysicalAdapters', 'Test-InstallHealthStable', 'Clear-InstallLock', 'TaskXMLRepair', 'Get-WmiBindFilter', 'Invoke-DeferredPrivacyGuards', 'Ensure-DnscryptTomlFile', 'Remove-IPv6FromConfig', 'Test-WmiSubscriptionActive') }
        @{ Files = @('lib/Install-Privacy.ps1'); Must = @('Get-ScriptSha256', 'Install-PrivacyHardening', 'privacy-hardening-guard.ps1', 'Install-WindowsTelemetryReduction', 'BlockThirdPartyCookies', 'DisableWindowsConsumerFeatures', 'privacy.resistFingerprinting', 'AllowTelemetry', 'Install-BrowserPrivacyPolicies', 'WebRtcIpHandlingPolicy', 'default_public_interface_only', 'Get-ChromiumPrivacyDWordProps', 'Write-PrivacyHardeningGuardPs1', 'Install-ScriptIntegrityVault', 'Test-ScriptIntegrityVault', 'DnsOverHttpsMode', 'PrivacySandboxAdTopicsEnabled', 'QuicAllowed', 'fingerprintingProtection', 'webgl.disabled', 'consumer telemetry reduced (not eliminated)', 'Ensure-DelayedAutoStart', 'Test-DelayedAutoStart', 'Remove-KurtarArtifacts', 'Write-GuardBackups', '\[Startup\]'); MustRegex = @("powershell\.exe' OR TargetInstance\.Name='pwsh\.exe") }
        @{ Files = @('lib/Install-SafeNetwork.ps1'); Must = @('Install-SafeNetwork.ps1', 'Test-BootSafeWindow', 'Get-OsUptimeSeconds', 'Test-IsVirtualTunnelAdapter', 'Disable-TunnelIPv6BindingsOnly', 'Add-KillSwitchFirewallExemptions', 'Add-KillSwitchCatchAllBlocks', 'Enable-KillSwitchBlock', 'Disable-KillSwitchBlock', 'Invoke-FailOpenSafeguard', 'wg-safety.ps1', 'KS-DHCP-Bcast-Out', 'KS-Gateway-Out', 'KS-Gateway-In', 'Invoke-SafeNetsh', 'Invoke-SafeRegistrySet', 'InstallDryRun', 'EnableFailsafe', 'function Get-WgSafetyRuntimeScript', 'function Set-PostInstallGraceRegistry', 'PostInstallGraceUntil', 'function Test-PostInstallGrace') }
        @{ Files = @('lib/Install-MainSteps-0-6.ps1'); Must = @('Invoke-InstallMainSteps0to6', 'Remove-InstallBlocks', 'Remove-KurtarArtifacts', 'Invoke-SafeNetsh', 'blocks deferred until install completes', 'firewallpolicy blockinbound,allowoutbound', 'CustomEndpointIP requires -CustomConfig', 'Remove-IPv6FromConfig'); MustRegex = @('KS-DNS-Block.*enable=no') }
        @{ Files = @('lib/Install-MainSteps-18-20.ps1'); Must = @('STEP 18b - PRIVACY', 'STEP 18c - V14 DNS', 'STEP 18f - V15', 'Test-DnscryptListening', 'Set-PostInstallGraceRegistry', 'Set-BootGraceRegistry', 'Remove-InstallBlocks', 'Ensure-DelayedAutoStart', 'Test-DelayedAutoStart', 'Remove-KurtarArtifacts', 'Invoke-DeferredPrivacyGuards', 'webrtc-leak-guard.ps1', 'emergency-reset.ps1', 'emergency-reset.bat') }
        @{ Files = @('lib/Install-GeneratedScripts.ps1'); Must = @('Invoke-InstallGeneratedScripts', 'function Test-IsMainMonitor', 'function Sync-KillSwitchState', 'monitor-only block authority', 'dns-lockdown-guard.ps1', 'network-privacy-guard.ps1', 'function Try-ReinstallTunnel', 'monitor active, deferring reinstall', 'Test-MainMonitorActive', 'deferring reinstall', 'tunnel recovery delegated', 'anti-tamper.ps1', 'Invoke-AntiTamperGuard', 'NoChainRepair', 'graduated fail-open', 'never tears down protection', 'watchdog will deep-unbrick', 'cmd.exe /c', 'Fail-open hold at startup', 'Tunnel lost (confirmed 5x/10s)', '60s hold', 'tamperTick', 'Test-ServerRulePresent', 'Set-ServerRule', 'Start-HiddenScript', '8.8.8.8', 'hits -ge 2', 'Repair-ConfigIntegrity', 'Repair-EssentialFirewall', 'Test-NetworkChanged', 'NetworkFingerprint', 'Test-BlockRulePresent', 'protection stays installed', 'Invoke-EmergencyUnbrick', 'EMERGENCY UNBRICK', 'Invoke-DeepUnbrick', 'WGTunnelInstallMutex', 'Remove-OtherMonitorProcs', 'oldCmd -match', 'Log-Tamper', 'Restore-WmiSubscription', 'wmi-cooldown', 'WmiCooldownActive', 'Test-WmiSubscriptionActive', 'STEP 10d - V14', 'STEP 10e - V15', 'if (`$rewrite -or -not (Test-ServerRulePresent))'); MustRegex = @('Sync-KillSwitchState\r?\n\} finally') }
        @{ Files = @('lib/Install-TasksAndWmi.ps1'); Must = @('Install-WmiSubscription', 'Split-Path $PSScriptRoot -Parent', '$installScripts = Join-Path $INSTALL_DIR', 'Minutes 15', 'WG-RebootVerify', 'post-reboot-verify', 'RebootVerifyPath', 'ScriptsPath', 'TunnelName', 'WGKillSwitchGuard', 'Write-GuardBackups', 'GPO: zombie tunnel') }
        @{ Files = @('lib/Install-UpgradePaths.ps1'); Must = @('Invoke-InstallUpgradeEarlyExit', 'v15.2', '15.2', 'StrongPrivacyUpgrade', 'DnsLeakUpgradeOnly', 'TorUpgradeOnly', 'FullPrivacyUpgrade', 'Invoke-V14DnsLeakStack', 'Invoke-V15StrongPrivacyStack', 'PrivacyUpgradeOnly', 'safe-live-verify.ps1', 'webrtc-leak-guard.ps1 forwarder written', 'leak-sentinel') }
        @{ Files = @('install.ps1', 'lib/Install-Helpers.ps1'); Must = @('$ErrorActionPreference = "Continue"') }
        @{ Files = @('_installLibCombined'); Must = @('Write-Step', 'Test-InstallInProgress', 'install.inprogress', 'v11.3', 'v11.2', 'v11.1') }
        @{ Files = @('scripts/final-line-audit.ps1'); Must = @('Get-CompleteRepoManifest', 'Add-Finding', 'Test-Ps1FileDeep', 'findings.jsonl', 'final-audit-summary.md', '15.2.9') }
    )
}

function Get-RoleContractMatrix {
    return @(
        @{ Role = 'audit'; Scripts = @('leak-audit.ps1', 'privacy-audit.ps1', 'tor-audit.ps1'); Must = @('function Assert', 'ErrorActionPreference', 'failures') }
        @{ Role = 'audit'; Scripts = @('security-audit.ps1'); Must = @('function Add-Result', 'ErrorActionPreference', 'ConfirmDisruptiveTests', 'findings') }
        @{ Role = 'audit'; Scripts = @('system-audit.ps1'); Must = @('System Audit', 'WGKillSwitch', 'Scheduled tasks', 'sc.exe query') }
        @{ Role = 'verify'; Scripts = @('post-install-verify.ps1', 'safe-live-verify.ps1'); Must = @('function Assert', 'exit 1', 'ErrorActionPreference') }
        @{ Role = 'verify'; Scripts = @('post-reboot-verify.ps1'); Must = @('function Log', 'Get-ScriptsDir', 'ScriptsPath', 'exit') }
        @{ Role = 'verify'; Scripts = @('safe-live-verify.ps1'); Must = @('non-disruptive', 'NEVER stops tunnel', 'Post-check: TCP internet still working') }
        @{ Role = 'stack'; Scripts = @('install-v14-stack.ps1', 'install-v15-privacy-stack.ps1'); Must = @('Join-Path', 'Test-DnscryptListening', 'try {', 'dnscrypt') }
        @{ Role = 'stack'; Scripts = @('install-v15-privacy-stack.ps1'); Must = @('deferGuards', 'dns-lockdown-guard.ps1', 'network-privacy-guard.ps1') }
        @{ Role = 'emergency'; Scripts = @('emergency-reset.ps1'); Must = @('DeepReset', 'dhcp', 'kurtar') }
        @{ Role = 'destructive'; Scripts = @('ultimate-stress-test.ps1', 'race-recovery-test.ps1'); Must = @('ConfirmDisruptsInternet', 'exit 2') }
        @{ Role = 'ci'; Scripts = @('run-all-tests.ps1', 'pre-push-gate.ps1'); Must = @('test-suite', 'exit') }
        @{ Role = 'ci'; Scripts = @('final-line-audit.ps1'); Must = @('Get-CompleteRepoManifest', 'findings.jsonl', 'exit 1', 'audit-results') }
        @{ Role = 'tor'; Scripts = @('tor-preflight.ps1', 'ensure-tor-sensitive.ps1'); Must = @('ErrorActionPreference', 'Tor', 'exit') }
        @{ Role = 'tor'; Scripts = @('tor-rollback-v13.5.ps1'); Must = @('ErrorActionPreference', 'ROLLBACK', 'Tor', 'sc.exe') }
        @{ Role = 'ops'; Scripts = @('live-smoke-test.ps1'); Must = @('SKIP:', 'safe-live-verify.ps1', 'RequireStack') }
        @{ Role = 'ops'; Scripts = @('post-reboot-verify.ps1'); Must = @('RebootVerify', 'ScriptsPath') }
        @{ Role = 'ops'; Scripts = @('repair-wmi-subscription.ps1'); Must = @('WMI', 'Subscription') }
        @{ Role = 'ops'; Scripts = @('fetch-nssm.ps1'); Must = @('nssm', 'Invoke-WebRequest') }
        @{ Role = 'ops'; Scripts = @('restore-full-stack.ps1'); Must = @('WireGuard', 'restore') }
        @{ Role = 'ops'; Scripts = @('sensitive-mode.ps1'); Must = @('Tor', 'Sensitive') }
        @{ Role = 'ops'; Scripts = @('patch-gpo-v13.5.ps1'); Must = @('GPO', 'Startup') }
        @{ Role = 'ops'; Scripts = @('resume-v13.5.ps1', 'resume-v14.ps1'); Must = @('resume', 'upgrade') }
        @{ Role = 'ops'; Scripts = @('publish-releases.ps1', 'push-v15.2.ps1'); Must = @('release', 'v15') }
        @{ Role = 'ops'; Scripts = @('install-tor-browser.ps1'); Must = @('Tor', 'Browser') }
    )
}

function Get-MonitorSimParityKeywords {
    return @(
        @{ Keyword = 'Install in progress'; SimContext = 'install_lock' }
        @{ Keyword = 'Test-BlockAllowed'; SimContext = 'block_allowed_fn' }
        @{ Keyword = 'Disable-Block'; SimContext = 'disable_block' }
        @{ Keyword = 'zombie'; SimContext = 'zombie_path' }
        @{ Keyword = 'fail-open'; SimContext = 'fail_open' }
        @{ Keyword = 'Test-PostInstallGrace'; SimContext = 'post_install_grace' }
        @{ Keyword = 'Test-BootGrace'; SimContext = 'boot_grace' }
    )
}

function Get-FileAuditTier {
    param([string]$RelPath)
    if ($RelPath -match '^lib\\' -or $RelPath -eq 'install.ps1' -or $RelPath -eq 'emergency-reset.bat' -or $RelPath -match '^scripts\\' -and $RelPath -notmatch 'github-visibility|open-launch-links') {
        if ($RelPath -match 'Test-Helpers|file-coverage|final-line-audit|test-suite|behavior-sim|reboot-sim|ci\.ps1|run-all|pre-push|parse-check|scriptblock') { return 'P0-test' }
        return 'P0'
    }
    if ($RelPath -match '^\.github\\') { return 'P1' }
    if ($RelPath -in @('README.md', 'CONTRIBUTING.md', 'LICENSE', '.gitignore')) { return 'P2' }
    if ($RelPath -match '^docs\\releases\\v15\.2\.9\.md$') { return 'P3' }
    if ($RelPath -match '^docs\\releases\\') { return 'P4' }
    if ($RelPath -match '^docs\\') { return 'P3' }
    if ($RelPath -match '^manifests\\') { return 'P0' }
    return 'P5'
}

function Get-CompleteRepoManifest {
    param([string]$RepoRoot)
    $entries = [System.Collections.Generic.List[object]]::new()
    $files = Get-ChildItem $RepoRoot -Recurse -File | Where-Object {
        $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\audit-results\\'
    } | Sort-Object FullName
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\')
        $relNorm = $rel -replace '\\', '/'
        $lineArr = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        $lines = $lineArr.Count
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $tier = Get-FileAuditTier $rel
        $entries.Add([PSCustomObject]@{
            RelPath   = $relNorm
            Tier      = $tier
            Lines     = $lines
            Bytes     = $f.Length
            Extension = $f.Extension
            SHA256    = $hash
        })
    }
    return $entries
}

function Get-Ps1FunctionNames {
    param([string]$FilePath)
    $names = [System.Collections.Generic.List[string]]::new()
    $errs = $null; $ast = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$errs)
    if (-not $ast) { return @() }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $names.Add($node.Name) | Out-Null
    }
    return $names.ToArray()
}

function Get-LineSemanticRules {
    return @(
        @{ Id = 'iex_runtime'; Severity = 'ERROR'; Extensions = @('.ps1'); Pattern = '(?m)^\s+Invoke-Expression\s'; Files = @(); ExcludeComments = $true }
        @{ Id = 'is_main_monitor'; Severity = 'ERROR'; Extensions = @('.ps1'); Pattern = 'function IsMainMonitor'; Files = @('lib/Install-GeneratedScripts.ps1', 'lib/Install-Helpers.ps1') }
        @{ Id = 'catchall_install'; Severity = 'ERROR'; Extensions = @('.ps1'); Pattern = 'Add-KillSwitchCatchAllBlocks'; Files = @('lib/Install-MainSteps-0-6.ps1') }
        @{ Id = 'hardcoded_user_path'; Severity = 'ERROR'; Extensions = @('.ps1'); Pattern = 'C:\\Users\\[^\\]+\\Windows-WireGuard'; Files = @('scripts/system-audit.ps1') }
        @{ Id = 'kurtar_runtime'; Severity = 'ERROR'; Extensions = @('.ps1'); Pattern = '(?i)\bkurtar\.(bat|ps1)'; Files = @(); WhitelistFiles = @('lib/Install-Privacy.ps1', 'scripts/post-install-verify.ps1', 'scripts/safe-live-verify.ps1', 'scripts/ultimate-stress-test.ps1') }
    )
}

function Test-IsCommentLine {
    param([string]$Line)
    $t = $Line.TrimStart()
    return ($t.StartsWith('#') -or [string]::IsNullOrWhiteSpace($Line))
}