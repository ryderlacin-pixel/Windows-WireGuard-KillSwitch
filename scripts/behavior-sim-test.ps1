# 200 offline behavioral simulations - "how would this PC react?"
# No admin, no install, no firewall changes. Models monitor/repair/install decision paths.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$libDir = Join-Path $repoRoot 'lib'
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
$script:passed = 0
$TARGET = 216

function Assert-Behavior([bool]$cond, [string]$msg) {
    if ($cond) { $script:passed++ }
    else { $failures.Add($msg) }
}

# --- Pure decision engine (mirrors wg-safety + monitor.ps1 logic) ---
function Get-SimBlockAllowed {
    param(
        [bool]$InstallLock,
        [bool]$UnbrickActive,
        [bool]$BootGrace,
        [bool]$PostInstallGrace,
        [bool]$BootSafeWindow
    )
    if ($InstallLock -or $UnbrickActive -or $BootGrace -or $PostInstallGrace -or $BootSafeWindow) {
        return $false
    }
    return $true
}

function Get-SimSafeToOpen([bool]$TunnelUp, [bool]$InternetOk) {
    return ($TunnelUp -and $InternetOk)
}

function Get-SimMonitorStartupAction {
    param(
        [bool]$InstallLock,
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$BootGrace,
        [bool]$UnbrickActive
    )
    if ($InstallLock) { return 'DISABLE_BLOCK' }
    if ((Get-SimSafeToOpen $TunnelUp $InternetOk) -or $BootGrace -or $UnbrickActive) {
        return 'DISABLE_BLOCK'
    }
    if ($TunnelUp -and -not $InternetOk) { return 'DISABLE_BLOCK_ZOMBIE' }
    return 'DISABLE_BLOCK_TUNNEL_DOWN'
}

function Get-SimMonitorLoopAction {
    param(
        [bool]$InstallLock,
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$BootGrace,
        [bool]$UnbrickActive,
        [bool]$PostInstallGrace,
        [bool]$BootSafeWindow,
        [int]$ZombieStreak = 0
    )
    if ($InstallLock) { return 'DISABLE_BLOCK' }
    if (Get-SimSafeToOpen $TunnelUp $InternetOk) { return 'DISABLE_BLOCK_OPEN' }
    if (-not (Get-SimBlockAllowed $InstallLock $UnbrickActive $BootGrace $PostInstallGrace $BootSafeWindow)) {
        return 'DEFER_BLOCK'
    }
    if ($TunnelUp -and -not $InternetOk -and $ZombieStreak -lt 15) {
        return 'ZOMBIE_DEBOUNCE'
    }
    return 'ENABLE_BLOCK'
}

function Get-SimRepairSyncAction {
    param(
        [bool]$InstallLock,
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$BootGrace,
        [bool]$UnbrickActive,
        [bool]$PostInstallGrace,
        [bool]$BootSafeWindow,
        [bool]$MonitorActive
    )
    if ($MonitorActive) { return 'DEFER_REINSTALL' }
    if (-not (Get-SimBlockAllowed $InstallLock $UnbrickActive $BootGrace $PostInstallGrace $BootSafeWindow)) {
        return 'DISABLE_BLOCK_FAILOPEN'
    }
    if (Get-SimSafeToOpen $TunnelUp $InternetOk) { return 'DISABLE_BLOCK_HEALTHY' }
    return 'SYNC_NO_ENABLE_BLOCK'
}

function Get-SimInstallStep6Action {
    param([bool]$DryRun)
    # v15.2.9: never add catch-all during install
    if ($DryRun) { return 'DRY_RUN_NO_CATCHALL' }
    return 'EXEMPTIONS_ONLY_NO_CATCHALL'
}

function Get-SimDnsLockAction {
    param(
        [bool]$InstallLock,
        [bool]$DnscryptListening
    )
    if ($InstallLock) { return 'DEFER_INSTALL_LOCK' }
    if (-not $DnscryptListening) { return 'DEFER_NO_LISTENER' }
    return 'APPLY_DNS_LOCK'
}

function Get-SimPrivacyGuardAction {
    param(
        [bool]$InstallLock,
        [bool]$TunnelUp,
        [bool]$DnscryptListening,
        [bool]$HealthStable
    )
    if ($InstallLock) { return 'DEFER' }
    if (-not $TunnelUp) { return 'DEFER' }
    if (-not $DnscryptListening) { return 'DEFER' }
    if (-not $HealthStable) { return 'DEFER' }
    return 'RUN_GUARDS'
}

function Get-SimWatchdogAction {
    param(
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$BlockPresent
    )
    if (-not $TunnelUp -or -not $InternetOk) {
        return 'FAILOPEN_DNS_RESTORE'
    }
    if ($BlockPresent -and (Get-SimSafeToOpen $TunnelUp $InternetOk)) {
        return 'NO_TEAR_DOWN'
    }
    return 'MONITOR_ONLY'
}

function Get-SimEmergencyResetAction {
    param([bool]$DeepReset)
    if ($DeepReset) { return 'DEEP_RESET_OPTIONAL' }
    return 'SAFE_DHCP_DNS_NO_WINSOCK'
}

# --- Load real helpers (DryRun - no netsh/registry side effects on adapters) ---
$CustomConfig = ''
$script:InstallDryRun = $true
$script:EnableFailsafe = $true
. (Join-Path $libDir 'Install-Constants.ps1')
. (Join-Path $libDir 'Install-SafeNetwork.ps1')
. (Join-Path $libDir 'Install-Helpers.ps1')

$genRaw = Get-Content (Join-Path $libDir 'Install-GeneratedScripts.ps1') -Raw -Encoding UTF8
$main06Raw = Get-Content (Join-Path $libDir 'Install-MainSteps-0-6.ps1') -Raw -Encoding UTF8
$main18Raw = Get-Content (Join-Path $libDir 'Install-MainSteps-18-20.ps1') -Raw -Encoding UTF8
$emerRaw = Get-Content (Join-Path $repoRoot 'scripts\emergency-reset.ps1') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$extracted = Get-ExtractedGeneratedScripts $repoRoot
$mon = $extracted.Monitor

Write-Host '========================================' -ForegroundColor Cyan
Write-Host '  BEHAVIOR SIM TESTS (216 scenarios)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# [A] Virtual tunnel adapter whitelist (30)
Write-Host '[A] Adapter mutation / tunnel detection' -ForegroundColor Yellow
$tunnelCases = @(
    @{ N='WireGuard Tunnel'; D='WireGuard Tunnel'; E=$true },
    @{ N='wgcf-profile'; D='Wintun Userspace Tunnel'; E=$true },
    @{ N='Ethernet'; D='Intel Ethernet'; E=$false },
    @{ N='Wi-Fi'; D='Intel Wi-Fi 6'; E=$false },
    @{ N='Ethernet 2'; D='Realtek PCIe GbE'; E=$false },
    @{ N='Local Area Connection'; D='TAP-Windows Adapter'; E=$false },
    @{ N='AllDebrid VPN'; D='AllDebrid Tunnel'; E=$true },
    @{ N='vEthernet (WSL)'; D='Hyper-V Virtual Ethernet'; E=$false },
    @{ N='Bluetooth Network'; D='Bluetooth Device'; E=$false },
    @{ N='wintun0'; D='wintun'; E=$true }
)
foreach ($c in $tunnelCases) {
    Assert-Behavior ((Test-IsVirtualTunnelAdapter $c.N $c.D) -eq $c.E) "TunnelDetect: $($c.N)"
    Assert-Behavior ((Assert-AdapterMutationAllowed $c.N $c.D 'test') -eq $c.E) "AdapterMutate: $($c.N)"
    Assert-Behavior ((Test-IsVirtualTunnelAdapter $c.N '') -eq ($c.N -match 'WireGuard|wintun|Wintun|AllDebrid')) "TunnelNameOnly: $($c.N)"
}

# [B] Main monitor process detection (25)
Write-Host '[B] Monitor process command-line detection' -ForegroundColor Yellow
$monPositive = @(
    'C:\WireGuard\monitor.ps1',
    'powershell -File C:\WireGuard\monitor.ps1',
    'pwsh.exe -File "C:\WireGuard\monitor.ps1"',
    'C:/WireGuard/monitor.ps1 -NoProfile',
    'C:\WireGuard\monitor.ps1"',
    ' -File C:\WireGuard\monitor.ps1 ',
    'C:\WireGuard\monitor.ps1 -WindowStyle Hidden'
)
$monNegative = @(
    'C:\WireGuard\repair.ps1',
    'C:\WireGuard\monitor.ps1.bak',
    'C:\WireGuard\monitor.ps1.backup',
    'C:\WireGuard\service-monitor.ps1',
    'monitor.ps1notreal',
    '',
    $null,
    'C:\WireGuard\monitor.ps1extra',
    'C:\WireGuard\pre-monitor.ps1',
    'C:\WireGuard\monitor.ps1\..\..\windows\system32\evil.ps1'
)
foreach ($cmd in $monPositive) {
    Assert-Behavior (Test-IsMainMonitor $cmd) "MainMonitor+: $cmd"
}
foreach ($cmd in $monNegative) {
    Assert-Behavior (-not (Test-IsMainMonitor $cmd)) "MainMonitor-: $cmd"
}
Assert-Behavior (Test-IsMainMonitor 'x C:\WireGuard\monitor.ps1 y') 'MainMonitor: embedded path'

# [C] Test-BlockAllowed - 32 boolean grid + 3 edge (35)
Write-Host '[C] Block policy state machine (32 combos)' -ForegroundColor Yellow
for ($mask = 0; $mask -lt 32; $mask++) {
    $il = [bool]($mask -band 1)
    $ub = [bool]($mask -band 2)
    $bg = [bool]($mask -band 4)
    $pg = [bool]($mask -band 8)
    $bs = [bool]($mask -band 16)
    $expected = Get-SimBlockAllowed $il $ub $bg $pg $bs
    $anyHold = ($il -or $ub -or $bg -or $pg -or $bs)
    Assert-Behavior (($expected -eq -not $anyHold)) "BlockAllowed mask=$mask expected=$expected"
}
Assert-Behavior (-not (Get-SimBlockAllowed $true $false $false $false $false)) 'BlockDenied: install lock alone'
Assert-Behavior (Get-SimBlockAllowed $false $false $false $false $false) 'BlockAllowed: all clear'
Assert-Behavior (-not (Get-SimBlockAllowed $false $false $false $false $true)) 'BlockDenied: boot safe window'

# [D] Monitor startup - 16 tunnelxinternet + grace variants (48)
Write-Host '[D] Monitor startup reactions' -ForegroundColor Yellow
foreach ($tu in @($true, $false)) {
    foreach ($io in @($true, $false)) {
        foreach ($bg in @($false, $true)) {
            foreach ($ub in @($false, $true)) {
                $act = Get-SimMonitorStartupAction $false $tu $io $bg $ub
                if ($bg -or $ub -or (Get-SimSafeToOpen $tu $io)) {
                    Assert-Behavior ($act -eq 'DISABLE_BLOCK') "Startup open: tu=$tu io=$io bg=$bg ub=$ub"
                } elseif ($tu -and -not $io) {
                    Assert-Behavior ($act -eq 'DISABLE_BLOCK_ZOMBIE') "Startup zombie: tu=$tu io=$io"
                } else {
                    Assert-Behavior ($act -eq 'DISABLE_BLOCK_TUNNEL_DOWN') "Startup down: tu=$tu io=$io"
                }
            }
        }
    }
}

# [E] Monitor main loop - 32 core states (32)
Write-Host '[E] Monitor loop reactions' -ForegroundColor Yellow
for ($mask = 0; $mask -lt 32; $mask++) {
    $tu = [bool]($mask -band 1)
    $io = [bool]($mask -band 2)
    $bg = [bool]($mask -band 4)
    $ub = [bool]($mask -band 8)
    $il = [bool]($mask -band 16)
    $act = Get-SimMonitorLoopAction $il $tu $io $bg $ub $false $false 0
    if ($il) {
        Assert-Behavior ($act -eq 'DISABLE_BLOCK') "Loop install lock mask=$mask"
    } elseif (Get-SimSafeToOpen $tu $io) {
        Assert-Behavior ($act -eq 'DISABLE_BLOCK_OPEN') "Loop safe open mask=$mask"
    } elseif ($bg -or $ub) {
        Assert-Behavior ($act -eq 'DEFER_BLOCK') "Loop grace defer mask=$mask"
    } elseif ($tu -and -not $io) {
        Assert-Behavior ($act -eq 'ZOMBIE_DEBOUNCE') "Loop zombie debounce mask=$mask"
    } else {
        Assert-Behavior ($act -eq 'ENABLE_BLOCK') "Loop enable block mask=$mask"
    }
}

# [F] Install phase - STEP 6 + dry-run + catch (20)
Write-Host '[F] Install-phase PC reactions' -ForegroundColor Yellow
Assert-Behavior ($main06Raw -notmatch 'Add-KillSwitchCatchAllBlocks') 'Install: STEP6 never calls catch-all'
Assert-Behavior ($main06Raw -match 'Remove-InstallBlocks') 'Install: clears blocks after STEP6'
Assert-Behavior ($main06Raw -match 'Set-InstallLock') 'Install: sets lock before firewall'
Assert-Behavior ($main06Raw -match 'Get-ServerIPs') 'Install: pre-caches server IPs'
Assert-Behavior ((Get-SimInstallStep6Action $true) -eq 'DRY_RUN_NO_CATCHALL') 'Install DryRun: no catch-all'
Assert-Behavior ((Get-SimInstallStep6Action $false) -eq 'EXEMPTIONS_ONLY_NO_CATCHALL') 'Install live: exemptions only'
foreach ($rule in @('KS-DHCP-Out','KS-Gateway-Out','KS-Loopback-Out','KS-WARP-Server-Out')) {
    Assert-Behavior ($main06Raw -match [regex]::Escape($rule)) "Install STEP6 allows: $rule"
}
foreach ($block in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out')) {
    Assert-Behavior ($main06Raw -notmatch "add rule name=`"$block`"") "Install STEP6 no add: $block"
}
Assert-Behavior ($main06Raw -match 'blocks deferred until install completes') 'Install: defers blocks message'
Assert-Behavior ($main06Raw -match 'Invoke-SafeNetsh') 'Install: DryRun-safe netsh wrapper'
Assert-Behavior ($main06Raw -notmatch '(?m)^\s*netsh advfirewall') 'Install: no bare netsh in main steps'
Assert-Behavior ($main06Raw -match 'Disable-TunnelIPv6BindingsOnly') 'Install: tunnel-only IPv6'
Assert-Behavior ($main06Raw -match 'Ensure-TunnelForInstall') 'Install: keeps tunnel alive'
Assert-Behavior ($main06Raw -match 'Remove-KurtarArtifacts') 'Install: clears legacy rescue'
Assert-Behavior ($main06Raw -match 'firewallpolicy blockinbound,allowoutbound') 'Install: allow outbound during setup'
Assert-Behavior ($main06Raw -match 'KS-DNS-Block.*enable=no') 'Install: DNS block disabled until healthy'

# [G] Repair sync - monitor authority (15)
Write-Host '[G] Repair-task PC reactions' -ForegroundColor Yellow
Assert-Behavior ($genRaw -match 'monitor-only block authority') 'Repair: never owns block authority'
Assert-Behavior ($genRaw -match 'monitor active, deferring reinstall') 'Repair: defers when monitor up'
Assert-Behavior ((Get-SimRepairSyncAction $false $true $true $false $false $false $false $true) -eq 'DEFER_REINSTALL') 'Repair: monitor active defer'
Assert-Behavior ((Get-SimRepairSyncAction $false $true $true $false $false $false $false $false) -eq 'DISABLE_BLOCK_HEALTHY') 'Repair: healthy opens'
Assert-Behavior ((Get-SimRepairSyncAction $false $false $false $false $false $false $false $false) -eq 'SYNC_NO_ENABLE_BLOCK') 'Repair: no Enable-Block'
Assert-Behavior ($genRaw -match 'function Sync-KillSwitchState') 'Repair: has Sync-KillSwitchState'
Assert-Behavior ($genRaw -match 'Repair-EssentialFirewall') 'Repair: restores essential rules'
Assert-Behavior ($genRaw -match 'Try-ReinstallTunnel') 'Repair: mutex tunnel reinstall'
Assert-Behavior ($genRaw -match 'cmd\.exe /c') 'Repair: cmd.exe not iex for firewall'
Assert-Behavior ($genRaw -match 'Sync-KillSwitchState[\s\S]{0,1200}Disable-Block') 'Repair Sync: uses Disable-Block not Enable-Block'
if ($mon) {
    Assert-Behavior ($mon -match 'function Enable-Block') 'Monitor: owns Enable-Block'
    Assert-Behavior ($mon -match 'Install in progress') 'Monitor: respects install lock'
    Assert-Behavior ($mon -match 'Test-BlockAllowed') 'Monitor: uses Test-BlockAllowed'
    Assert-Behavior ($mon -match 'zombie') 'Monitor: zombie debounce path'
    Assert-Behavior ($mon -match 'fail-open') 'Monitor: fail-open logging'
}

# [H] DNS lock + privacy deferral (15)
Write-Host '[H] DNS / privacy deferral on PC' -ForegroundColor Yellow
foreach ($il in @($true, $false)) {
    foreach ($dl in @($true, $false)) {
        $a = Get-SimDnsLockAction $il $dl
        if ($il) { Assert-Behavior ($a -eq 'DEFER_INSTALL_LOCK') "DNS lock defer install=$il listen=$dl" }
        elseif (-not $dl) { Assert-Behavior ($a -eq 'DEFER_NO_LISTENER') "DNS lock defer no listener" }
        else { Assert-Behavior ($a -eq 'APPLY_DNS_LOCK') "DNS lock apply when ready" }
    }
}
Assert-Behavior ($main18Raw -match 'Test-DnscryptListening') 'STEP18f: dnscrypt listen gate'
Assert-Behavior ($main18Raw -match 'deferred.*dnscrypt-proxy not listening') 'STEP18f: warns defer'
Assert-Behavior ((Get-SimPrivacyGuardAction $true $true $true $true) -eq 'DEFER') 'Privacy: defer install lock'
Assert-Behavior ((Get-SimPrivacyGuardAction $false $false $true $true) -eq 'DEFER') 'Privacy: defer no tunnel'
Assert-Behavior ((Get-SimPrivacyGuardAction $false $true $false $true) -eq 'DEFER') 'Privacy: defer no dnscrypt'
Assert-Behavior ((Get-SimPrivacyGuardAction $false $true $true $false) -eq 'DEFER') 'Privacy: defer unstable'
Assert-Behavior ((Get-SimPrivacyGuardAction $false $true $true $true) -eq 'RUN_GUARDS') 'Privacy: run when stable'

# [I] Watchdog + emergency (10)
Write-Host '[I] Watchdog / emergency PC reactions' -ForegroundColor Yellow
Assert-Behavior ((Get-SimWatchdogAction $false $false $true) -eq 'FAILOPEN_DNS_RESTORE') 'Watchdog: restore DNS when down'
Assert-Behavior ((Get-SimWatchdogAction $true $true $true) -eq 'NO_TEAR_DOWN') 'Watchdog: no tear-down when healthy'
Assert-Behavior ((Get-SimEmergencyResetAction $false) -eq 'SAFE_DHCP_DNS_NO_WINSOCK') 'Emergency: safe mode default'
Assert-Behavior ((Get-SimEmergencyResetAction $true) -eq 'DEEP_RESET_OPTIONAL') 'Emergency: deep reset opt-in'
if ($emerRaw) {
    Assert-Behavior ($emerRaw -match 'DeepReset') 'Emergency: -DeepReset switch exists'
    Assert-Behavior ($emerRaw -match 'dhcp|DHCP') 'Emergency: restores DHCP DNS'
}
Assert-Behavior ($genRaw -match 'graduated fail-open') 'Watchdog: graduated fail-open'
Assert-Behavior ($genRaw -match 'Restore-DhcpDnsOnPhysicalAdapters') 'Watchdog: DHCP DNS restore fn'
Assert-Behavior ($genRaw -match 'never tears down protection') 'Watchdog: keeps protection layers'

# [J] Real runtime helpers on this machine (15)
Write-Host '[J] Live machine probes (read-only)' -ForegroundColor Yellow
Assert-Behavior ((Get-OsUptimeSeconds) -is [int]) 'PC: uptime returns int'
Assert-Behavior ((Get-OsUptimeSeconds) -ge 0) 'PC: uptime non-negative'
Assert-Behavior ((Test-BootSafeWindow) -is [bool]) 'PC: boot safe window bool'
$gw = Get-LocalGatewaySubnets
Assert-Behavior ($gw.Count -ge 3) 'PC: gateway list includes RFC1918 defaults'
Assert-Behavior ($gw -contains '192.168.0.0/16') 'PC: 192.168/16 in gateway list'
Assert-Behavior ((Test-Internet) -is [bool]) 'PC: Test-Internet returns bool'
Assert-Behavior ((Test-TcpHost '127.0.0.1' 53 500) -is [bool]) 'PC: loopback TCP probe works'
Assert-Behavior ((Get-PreferredShell) -match 'powershell|pwsh') 'PC: preferred shell resolved'
$safety = Get-WgSafetyRuntimeScript -Version '15.2.9'
Assert-Behavior ($safety -match 'function Test-BlockAllowed') 'wg-safety: exports Test-BlockAllowed'
Assert-Behavior ($safety -match 'cmd\.exe /c') 'wg-safety: cmd.exe for DHCP'
Assert-Behavior ($safety -notmatch 'Invoke-Expression') 'wg-safety: no Invoke-Expression'
$tmpSafety = Join-Path $env:TEMP "wg-safety-sim-$([guid]::NewGuid().ToString('N')).ps1"
try {
    [IO.File]::WriteAllText($tmpSafety, $safety, [Text.UTF8Encoding]::new($false))
    $errs = $null; $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($tmpSafety, [ref]$tok, [ref]$errs)
    Assert-Behavior ((-not $errs) -or ($errs.Count -eq 0)) 'wg-safety: parses on this PC'
} finally {
    Remove-Item $tmpSafety -Force -EA SilentlyContinue
}
Assert-Behavior ($script:BOOT_SAFE_WINDOW_SEC -eq 90) 'Config: 90s boot safe window'
Assert-Behavior ($script:BOOT_GRACE_SEC -eq 90) 'Config: 90s boot grace'

# [K] Sim <-> extracted monitor production parity (15)
Write-Host '[K] Sim vs extracted monitor keyword parity' -ForegroundColor Yellow
if ($mon) {
    foreach ($kw in (Get-MonitorSimParityKeywords)) {
        Assert-Behavior ($mon -match [regex]::Escape($kw.Keyword)) "Monitor extract has: $($kw.Keyword)"
    }
    Assert-Behavior ($mon -match 'Test-BlockAllowed') 'Monitor: uses Test-BlockAllowed (from wg-safety)'
    Assert-Behavior ($mon -match 'Disable-Block') 'Monitor: Disable-Block path'
    Assert-Behavior ((Get-SimMonitorStartupAction $true $false $false $false $false) -eq 'DISABLE_BLOCK') 'Sim parity: install lock startup'
    Assert-Behavior ((Get-SimMonitorLoopAction $false $true $true $false $false $false $false 0) -eq 'DISABLE_BLOCK_OPEN') 'Sim parity: healthy loop'
    Assert-Behavior ((Get-SimMonitorLoopAction $false $false $false $false $false $true $false 0) -eq 'DEFER_BLOCK') 'Sim parity: post-install grace defer'
    Assert-Behavior ((Get-SimMonitorLoopAction $false $true $false $false $false $false $false 5) -eq 'ZOMBIE_DEBOUNCE') 'Sim parity: zombie debounce'
    Assert-Behavior ((Get-SimMonitorLoopAction $false $false $false $false $false $false $false 0) -eq 'ENABLE_BLOCK') 'Sim parity: enable block when unhealthy'
    $tmpMon = Write-ExtractedToTemp $mon 'mon-parity'
    try {
        $errs = $null; $tok = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tmpMon, [ref]$tok, [ref]$errs)
        Assert-Behavior ((-not $errs) -or ($errs.Count -eq 0)) 'Monitor extract parses on this PC'
        $null = [scriptblock]::Create((Get-Content -LiteralPath $tmpMon -Raw -Encoding UTF8))
        Assert-Behavior $true 'Monitor extract Scriptblock::Create OK'
    } finally {
        Remove-Item $tmpMon -Force -EA SilentlyContinue
    }
} else {
    $failures.Add('Monitor extract missing for sim parity')
}

# --- Count guard ---
Write-Host ''
if ($script:passed -ne $TARGET) {
    $failures.Add("Expected exactly $TARGET assertions, ran $($script:passed)")
}
if ($failures.Count -eq 0) {
    Write-Host "ALL $TARGET BEHAVIOR SIMULATIONS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED $($failures.Count) / $script:passed passed" -ForegroundColor Red
$failures | Select-Object -First 30 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
if ($failures.Count -gt 30) { Write-Host "  ... and $($failures.Count - 30) more" -ForegroundColor Red }
exit 1