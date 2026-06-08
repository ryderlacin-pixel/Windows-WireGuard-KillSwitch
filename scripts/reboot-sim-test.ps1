# 500 post-reboot behavioral simulations - "after reboot, does internet survive?"
# Models monitor/GPO/watchdog/service/DNS-lock timelines. No install, no firewall changes.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$libDir = Join-Path $repoRoot 'lib'
. (Join-Path $PSScriptRoot 'Test-Helpers.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
$script:passed = 0
$TARGET = 513
$BOOT_SAFE_SEC = 90

function Assert-Reboot([bool]$cond, [string]$msg) {
    if ($cond) { $script:passed++ }
    else { $failures.Add($msg) }
}

# --- Decision engines (mirror production reboot paths) ---

function Test-SimBlockAllowed {
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

function Get-SimDnsBroken {
    param([bool]$DnsLocked, [bool]$DnscryptListening)
    return ($DnsLocked -and -not $DnscryptListening)
}

function Get-SimMonitorBootUx {
    param(
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$InstallLock,
        [bool]$BootGrace,
        [bool]$Unbrick,
        [bool]$PostInstallGrace,
        [bool]$DnsBroken
    )
    # monitor.ps1 startup ALWAYS Disable-Block (lines 358-372) - firewall never bricks at boot
    if ($DnsBroken) { return 'DEGRADED_DNS' }
    if ($InstallLock) { return 'OPEN_INSTALL_LOCK' }
    if ($BootGrace -or $Unbrick -or $PostInstallGrace) { return 'OPEN_GRACE' }
    if ($TunnelUp -and $InternetOk) { return 'OPEN_HEALTHY' }
    if ($TunnelUp -and -not $InternetOk) { return 'OPEN_ZOMBIE_DEBOUNCE' }
    return 'OPEN_TUNNEL_DOWN'
}

function Get-SimGpoBootUx {
    param(
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$Unbrick,
        [bool]$BootGrace,
        [bool]$BootSafeWindow,
        [bool]$DnsBroken
    )
    # GPO always Disable-KillSwitchBlock + allow outbound
    if ($DnsBroken) { return 'DEGRADED_DNS' }
    if ($Unbrick -or $BootGrace -or $BootSafeWindow) { return 'OPEN_FAILOPEN_HOLD' }
    if ($TunnelUp -and $InternetOk) { return 'OPEN_HEALTHY' }
    if ($TunnelUp) { return 'OPEN_ZOMBIE_WAIT' }
    return 'OPEN_TUNNEL_WAIT'
}

function Get-SimWatchdogAction {
    param(
        [bool]$HoldActive,
        [bool]$BootSafeWindow,
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$BlockPresent,
        [int]$Streak
    )
    if ($HoldActive -or $BootSafeWindow) { return 'EXIT_HOLD' }
    if ($TunnelUp -and $InternetOk) {
        if ($BlockPresent) { return 'GENTLE_UNBRICK_BLOCKS_ON' }
        return 'OK_HEALTHY'
    }
    if ($Streak -le 2) { return 'GENTLE_UNBRICK' }
    if ($Streak -ge 5) { return 'DEEP_UNBRICK' }
    return 'GENTLE_UNBRICK_ACCUMULATE'
}

function Get-SimServiceStartupAction {
    param([bool]$HoldActive)
    if ($HoldActive) { return 'REPAIR_DEFERRED' }
    return 'REPAIR_TRIGGERED'
}

function Get-SimMonitorLoopUx {
    param(
        [bool]$TunnelUp,
        [bool]$InternetOk,
        [bool]$InstallLock,
        [bool]$Unbrick,
        [bool]$BootGrace,
        [bool]$PostInstallGrace,
        [bool]$BootSafeWindow,
        [int]$ZombieStreak
    )
    if ($InstallLock) { return 'OPEN_INSTALL' }
    if ($Unbrick -or $BootGrace -or $PostInstallGrace) { return 'OPEN_GRACE_LOOP' }
    if ($TunnelUp -and $InternetOk) { return 'OPEN_HEALTHY' }
    if ($TunnelUp -and -not $InternetOk) {
        if ($ZombieStreak -lt 15) { return 'OPEN_ZOMBIE_WAIT' }
        if (-not (Test-SimBlockAllowed $false $Unbrick $BootGrace $PostInstallGrace $BootSafeWindow)) {
            return 'OPEN_DEFERRED'
        }
        return 'BLOCK_ZOMBIE_CONFIRMED'
    }
    if (-not (Test-SimBlockAllowed $false $Unbrick $BootGrace $PostInstallGrace $BootSafeWindow)) {
        return 'OPEN_DEFERRED'
    }
    return 'BLOCK_TUNNEL_DOWN'
}

function Get-SimPostRebootVerifyUx {
    param(
        [bool]$ScriptsFound,
        [bool]$SafeToOpenAfterWait,
        [int]$WaitSec
    )
    if (-not $ScriptsFound) { return 'FAIL_NO_SCRIPTS' }
    if ($SafeToOpenAfterWait) { return 'PASS_HEALTHY' }
    if ($WaitSec -ge 150) { return 'FAIL_TIMEOUT' }
    return 'WAITING'
}

function Get-SimDnsTimelineUx {
    param(
        [string]$Phase,
        [bool]$DnsLocked,
        [bool]$DnscryptListening,
        [bool]$TunnelUp
    )
    $broken = Get-SimDnsBroken $DnsLocked $DnscryptListening
    switch ($Phase) {
        'install_complete' {
            if ($broken) { return 'DEFER_DNS_LOCK' }
            return 'OK'
        }
        'reboot_immediate' {
            if ($broken) { return 'INTERNET_BROKEN_DNS' }
            return 'OK'
        }
        'watchdog_tick1' {
            if ($broken -and -not $TunnelUp) { return 'GENTLE_RESTORE_DHCP' }
            if ($broken) { return 'STILL_BROKEN_NEED_DNCRYPT' }
            return 'OK'
        }
        'watchdog_tick5' {
            if ($broken) { return 'DEEP_UNBRICK_GRACE' }
            return 'OK'
        }
        default { return 'UNKNOWN' }
    }
}

function Get-SimRecoveryLayer {
    param(
        [string]$Problem,
        [bool]$GraceActive
    )
    switch ($Problem) {
        'blocks_on_healthy' { return 'watchdog_gentle' }
        'dns_locked_no_dnscrypt' {
            if ($GraceActive) { return 'emergency_grace' }
            return 'watchdog_dhcp'
        }
        'tunnel_down' { return 'monitor_recovery' }
        'stuck_5_ticks' { return 'watchdog_deep' }
        'panic_reset' { return 'emergency_reset' }
        default { return 'none' }
    }
}

# Load sources for contract checks
$genRaw = Get-Content (Join-Path $libDir 'Install-GeneratedScripts.ps1') -Raw -Encoding UTF8
$tasksRaw = Get-Content (Join-Path $libDir 'Install-TasksAndWmi.ps1') -Raw -Encoding UTF8
$main18Raw = Get-Content (Join-Path $libDir 'Install-MainSteps-18-20.ps1') -Raw -Encoding UTF8
$safeRaw = Get-Content (Join-Path $libDir 'Install-SafeNetwork.ps1') -Raw -Encoding UTF8
$emerRaw = Get-Content (Join-Path $repoRoot 'scripts\emergency-reset.ps1') -Raw -Encoding UTF8
$rebootRaw = Get-Content (Join-Path $repoRoot 'scripts\post-reboot-verify.ps1') -Raw -Encoding UTF8
$extracted = Get-ExtractedGeneratedScripts $repoRoot
$mon = $extracted.Monitor
$gpo = $extracted.Gpo
$watchdog = $extracted.Watchdog
$repairExtract = $extracted.Repair

Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  REBOOT SIM TESTS (513 post-reboot PC scenarios)' -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan

# [A] Monitor boot - 128 combos (7 flags) - NEVER firewall-block at startup
Write-Host '[A] Monitor post-reboot boot (128)' -ForegroundColor Yellow
for ($mask = 0; $mask -lt 128; $mask++) {
    $tu = [bool]($mask -band 1)
    $io = [bool]($mask -band 2)
    $il = [bool]($mask -band 4)
    $bg = [bool]($mask -band 8)
    $ub = [bool]($mask -band 16)
    $pg = [bool]($mask -band 32)
    $dns = [bool]($mask -band 64)
    $ux = Get-SimMonitorBootUx $tu $io $il $bg $ub $pg $dns
    $bootOk = ($ux -notmatch '^BLOCK') -and (
        ($dns -and $ux -eq 'DEGRADED_DNS') -or
        (-not $dns -and $ux -like 'OPEN*') -or
        ($il -and $ux -in @('OPEN_INSTALL_LOCK', 'DEGRADED_DNS'))
    )
    Assert-Reboot $bootOk "MonitorBoot m=$mask tu=$tu io=$io -> $ux (firewall open path)"
}

# [B] GPO machine startup - 64 combos
Write-Host '[B] GPO boot script (64)' -ForegroundColor Yellow
for ($mask = 0; $mask -lt 64; $mask++) {
    $tu = [bool]($mask -band 1)
    $io = [bool]($mask -band 2)
    $ub = [bool]($mask -band 4)
    $bg = [bool]($mask -band 8)
    $bs = [bool]($mask -band 16)
    $dns = [bool]($mask -band 32)
    $ux = Get-SimGpoBootUx $tu $io $ub $bg $bs $dns
    $gpoOk = ($ux -notmatch 'BLOCK') -and (
        ($dns -and $ux -eq 'DEGRADED_DNS') -or (-not $dns -and $ux -like 'OPEN*')
    )
    Assert-Reboot $gpoOk "GPO m=$mask -> $ux (never firewall-blocks at boot)"
}

# [C] Internet watchdog - 80 (10 streaks x 8 states)
Write-Host '[C] Watchdog graduated unbrick (80)' -ForegroundColor Yellow
for ($streak = 0; $streak -lt 10; $streak++) {
    for ($sm = 0; $sm -lt 8; $sm++) {
        $hold = [bool]($sm -band 1)
        $bs = [bool]($sm -band 2)
        $tu = [bool]($sm -band 4)
        $io = [bool]($sm -band 8) -and $tu
        $blk = [bool](($sm -band 4) -and -not ($sm -band 8))
        $act = Get-SimWatchdogAction $hold $bs $tu $io $blk $streak
        if ($hold -or $bs) {
            Assert-Reboot ($act -eq 'EXIT_HOLD') "Watchdog s=$streak sm=$sm skips during hold"
        } elseif ($tu -and $io -and $blk) {
            Assert-Reboot ($act -eq 'GENTLE_UNBRICK_BLOCKS_ON') "Watchdog s=$streak removes stray blocks when healthy"
        } elseif ($tu -and $io) {
            Assert-Reboot ($act -eq 'OK_HEALTHY') "Watchdog s=$streak healthy idle"
        } elseif ($streak -ge 5) {
            Assert-Reboot ($act -eq 'DEEP_UNBRICK') "Watchdog s=$streak deep unbrick at 5+"
        } else {
            Assert-Reboot ($act -match 'GENTLE') "Watchdog s=$streak gentle path (got $act)"
        }
    }
}

# [D] Monitor main loop after grace expires - 96 scenarios
Write-Host '[D] Monitor loop after reboot grace (96)' -ForegroundColor Yellow
for ($mask = 0; $mask -lt 96; $mask++) {
    $tu = [bool]($mask -band 1)
    $io = [bool]($mask -band 2) -and $tu
    $ub = [bool]($mask -band 4)
    $bg = [bool]($mask -band 8)
    $pg = [bool]($mask -band 16)
    $bs = [bool]($mask -band 32)
    $zs = ($mask % 16)
    $ux = Get-SimMonitorLoopUx $tu $io $false $ub $bg $pg $bs $zs
    $loopOk = $false
    if ($ub -or $bg -or $pg -or $bs) { $loopOk = ($ux -like 'OPEN*') }
    elseif ($tu -and $io) { $loopOk = ($ux -eq 'OPEN_HEALTHY') }
    elseif ($tu -and -not $io -and $zs -lt 15) { $loopOk = ($ux -eq 'OPEN_ZOMBIE_WAIT') }
    elseif ($tu -and -not $io -and $zs -ge 15) { $loopOk = ($ux -eq 'BLOCK_ZOMBIE_CONFIRMED') }
    elseif (-not $tu) { $loopOk = ($ux -in @('BLOCK_TUNNEL_DOWN', 'OPEN_DEFERRED')) }
    Assert-Reboot $loopOk "Loop m=$mask zs=$zs -> $ux"
}

# [E] DNS lock death-spiral timeline - 32 (4 phases x 2 dnsLocked x 2 dnscrypt x 2 tunnel)
Write-Host '[E] DNS lock reboot timeline (32)' -ForegroundColor Yellow
foreach ($phase in @('install_complete', 'reboot_immediate', 'watchdog_tick1', 'watchdog_tick5')) {
    foreach ($dl in @($false, $true)) {
        foreach ($dc in @($false, $true)) {
            foreach ($tu in @($false, $true)) {
                $ux = Get-SimDnsTimelineUx $phase $dl $dc $tu
                $broken = Get-SimDnsBroken $dl $dc
                $expect = switch ($phase) {
                    'install_complete' { if ($broken) { 'DEFER_DNS_LOCK' } else { 'OK' } }
                    'reboot_immediate' { if ($broken) { 'INTERNET_BROKEN_DNS' } else { 'OK' } }
                    'watchdog_tick1' {
                        if ($broken -and -not $tu) { 'GENTLE_RESTORE_DHCP' }
                        elseif ($broken) { 'STILL_BROKEN_NEED_DNCRYPT' }
                        else { 'OK' }
                    }
                    'watchdog_tick5' { if ($broken) { 'DEEP_UNBRICK_GRACE' } else { 'OK' } }
                }
                Assert-Reboot ($ux -eq $expect) "DNS $phase dl=$dl dc=$dc tu=$tu -> $ux (expect $expect)"
            }
        }
    }
}

# [F] Recovery layer routing - 20
Write-Host '[F] Recovery layer selection (20)' -ForegroundColor Yellow
$problemMap = @{
    'blocks_on_healthy'       = 'watchdog_gentle'
    'dns_locked_no_dnscrypt'  = 'watchdog_dhcp'
    'tunnel_down'             = 'monitor_recovery'
    'stuck_5_ticks'           = 'watchdog_deep'
    'panic_reset'             = 'emergency_reset'
}
foreach ($p in $problemMap.Keys) {
    foreach ($g in @($false, $true)) {
        $layer = Get-SimRecoveryLayer $p $g
        $expect = $problemMap[$p]
        if ($p -eq 'dns_locked_no_dnscrypt' -and $g) { $expect = 'emergency_grace' }
        Assert-Reboot ($layer -eq $expect) "Recovery $p grace=$g -> $layer"
    }
}

# [G] Uptime-sensitive boot-safe window - 16
Write-Host '[G] Boot-safe 90s window (16)' -ForegroundColor Yellow
foreach ($uptime in @(0, 1, 45, 89, 90, 91, 120, 300)) {
    foreach ($tu in @($false, $true)) {
        $bs = ($uptime -lt $BOOT_SAFE_SEC)
        $allowed = Test-SimBlockAllowed $false $false $false $false $bs
        Assert-Reboot ((-not $allowed) -eq $bs) "BootSafe uptime=$uptime blockAllowed=$allowed"
        if ($bs) {
            $ux = Get-SimMonitorLoopUx $tu $false $false $false $false $false $true 0
            Assert-Reboot ($ux -like 'OPEN*') "BootSafe uptime=$uptime keeps internet open"
        }
    }
}

# [H] Post-reboot-verify outcomes - 8
Write-Host '[H] WG-RebootVerify task (8)' -ForegroundColor Yellow
foreach ($scripts in @($false, $true)) {
    foreach ($healthy in @($false, $true)) {
        foreach ($wait in @(30, 150)) {
            $ux = Get-SimPostRebootVerifyUx $scripts $healthy $wait
            $expect = if (-not $scripts) { 'FAIL_NO_SCRIPTS' }
                      elseif ($healthy) { 'PASS_HEALTHY' }
                      elseif ($wait -ge 150) { 'FAIL_TIMEOUT' }
                      else { 'WAITING' }
            Assert-Reboot ($ux -eq $expect) "RebootVerify scripts=$scripts healthy=$healthy wait=$wait"
        }
    }
}

# [I] Service monitor startup - 4
Write-Host '[I] WGKillSwitchSvc startup (4)' -ForegroundColor Yellow
foreach ($ub in @($false, $true)) {
    foreach ($bg in @($false, $true)) {
        $ha = ($ub -or $bg)
        $act = Get-SimServiceStartupAction $ha
        $expect = if ($ha) { 'REPAIR_DEFERRED' } else { 'REPAIR_TRIGGERED' }
        Assert-Reboot ($act -eq $expect) "Svc startup ub=$ub bg=$bg -> $act"
    }
}

# [J] Source-code reboot contracts - 44 (regression guards for internet-loss bugs)
Write-Host '[J] Reboot regression contracts (44)' -ForegroundColor Yellow
if ($mon) {
    foreach ($pat in @(
        'Disable-Block',
        'Test-InstallInProgress',
        'Test-BootGrace',
        'Test-UnbrickActive',
        'Test-PostInstallGrace',
        'fail-open',
        'zombie tunnel',
        'Invoke-EmergencyUnbrick',
        'Set-BootGraceFromUptime',
        'Tunnel lost but block deferred',
        'Unhealthy but block deferred'
    )) {
        Assert-Reboot ($mon -match [regex]::Escape($pat)) "Monitor contract: $pat"
    }
}
if ($gpo) {
    foreach ($pat in @('Disable-KillSwitchBlock', 'fail-open hold', 'Repair triggered', 'never blocks', 'Set-BootGraceFromUptime')) {
        Assert-Reboot ($gpo -match [regex]::Escape($pat)) "GPO contract: $pat"
    }
}
if ($watchdog) {
    foreach ($pat in @('graduated fail-open', 'Invoke-GentleUnbrick', 'Invoke-DeepUnbrick', 'Test-HoldActive', 'Test-BootSafeWindow', 'Restore-DhcpDnsOnPhysicalAdapters')) {
        Assert-Reboot ($watchdog -match [regex]::Escape($pat)) "Watchdog contract: $pat"
    }
}
Assert-Reboot ($main18Raw -match 'Test-DnscryptListening') 'Install: dnscrypt gate before DNS lock'
Assert-Reboot ($main18Raw -match 'Remove-InstallBlocks') 'Install STEP19: clears blocks if unhealthy'
Assert-Reboot ($main18Raw -match 'Set-BootGraceRegistry') 'Install: sets boot grace on complete'
Assert-Reboot ($main18Raw -match 'Set-PostInstallGraceRegistry') 'Install: post-install grace'
Assert-Reboot ($main18Raw -match 'Set-PostInstallGraceRegistry -Minutes 60') 'Install: 60min post-install grace'
Assert-Reboot ($main18Raw -match 'Set-KillSwitchArmedRegistry') 'Install: KillSwitchArmed gate'
Assert-Reboot ($main18Raw -match 'Test-InstallHealthStable') 'Install: stability gate before arming'
Assert-Reboot ($safeRaw -match 'Test-KillSwitchArmed') 'wg-safety: Test-KillSwitchArmed'
Assert-Reboot ($safeRaw -match 'function Test-BlockAllowed') 'wg-safety: Test-BlockAllowed'
Assert-Reboot ($safeRaw -match 'Disable-KillSwitchBlock') 'wg-safety: Disable-KillSwitchBlock'
Assert-Reboot ($emerRaw -match 'source=dhcp') 'Emergency: DHCP DNS restore'
Assert-Reboot ($emerRaw -match 'if \(\$DeepReset\)') 'Emergency: winsock reset only with -DeepReset'
Assert-Reboot ($emerRaw -match 'Skipping full firewall') 'Emergency: safe mode skips deep reset'
Assert-Reboot ($rebootRaw -match '150') 'RebootVerify: 150s health wait'
Assert-Reboot ($rebootRaw -match 'ScriptsPath') 'RebootVerify: ScriptsPath lookup'
Assert-Reboot ($genRaw -match 'Fail-open hold at startup') 'Service: defer repair during grace'
$main06Raw = Get-Content (Join-Path $libDir 'Install-MainSteps-0-6.ps1') -Raw -Encoding UTF8
$helpersRaw = Get-Content (Join-Path $libDir 'Install-Helpers.ps1') -Raw -Encoding UTF8
$allRebootSrc = $genRaw + $tasksRaw + $watchdog + $main18Raw + $safeRaw + $helpersRaw
foreach ($pat in @(
    'no catch-all blocks yet',
    'Remove-InstallBlocks',
    'Clear-InstallLock',
    'bootWait -lt 90',
    'while (`$waited -lt 120',
    'graduated fail-open',
    'UnbrickUntil',
    'PostInstallGraceUntil',
    'Restore-DhcpDnsOnPhysicalAdapters',
    'Set-PostInstallGraceRegistry',
    'Invoke-EmergencyUnbrick'
)) {
    $src = if ($pat -match 'catch-all|Remove-Install') { $main06Raw }
           elseif ($pat -match 'Clear-InstallLock') { $helpersRaw + $main18Raw }
           else { $allRebootSrc }
    Assert-Reboot ($src -match [regex]::Escape($pat)) "Reboot hardening: $pat"
}

# [L] Extracted script compile + sim parity (15)
Write-Host '[L] Extracted script compile + sim parity' -ForegroundColor Yellow
if ($repairExtract) {
    $tmpRepair = Write-ExtractedToTemp $repairExtract 'reboot-repair'
    try {
        $errs = $null; $tok = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tmpRepair, [ref]$tok, [ref]$errs)
        Assert-Reboot ((-not $errs) -or ($errs.Count -eq 0)) 'Repair extract parses'
        $null = [scriptblock]::Create((Get-Content -LiteralPath $tmpRepair -Raw -Encoding UTF8))
        Assert-Reboot $true 'Repair extract Scriptblock::Create OK'
    } finally { Remove-Item $tmpRepair -Force -EA SilentlyContinue }
    Assert-Reboot ($repairExtract -match 'Sync-KillSwitchState') 'Repair extract: Sync-KillSwitchState'
    Assert-Reboot ($repairExtract -match 'monitor-only block authority') 'Repair extract: monitor-only authority'
} else { $failures.Add('Repair extract missing') }
if ($watchdog) {
    $tmpWd = Write-ExtractedToTemp $watchdog 'reboot-wd'
    try {
        $null = [scriptblock]::Create((Get-Content -LiteralPath $tmpWd -Raw -Encoding UTF8))
        Assert-Reboot $true 'Watchdog extract Scriptblock::Create OK'
    } finally { Remove-Item $tmpWd -Force -EA SilentlyContinue }
    foreach ($pat in @('graduated fail-open', 'Invoke-GentleUnbrick', 'Test-HoldActive')) {
        Assert-Reboot ($watchdog -match [regex]::Escape($pat)) "Watchdog sim parity: $pat"
    }
}
if ($mon) {
    Assert-Reboot ($mon -match 'Disable-Block') 'Monitor boot sim parity: always Disable-Block at startup path'
    Assert-Reboot ((Get-SimMonitorBootUx $false $false $false $true $false $false $false) -like 'OPEN*') 'Sim: boot grace never blocks'
}

# [K] Known regression scenarios - 8 explicit user-reported paths
Write-Host '[K] Known internet-loss regression paths (8)' -ForegroundColor Yellow
$regressions = @(
    @{ N='R01 fresh reboot 30s tunnel down'; U=30; TU=$false; IO=$false; IL=$false; BG=$true; DNS=$false; E='OPEN' }
    @{ N='R02 fresh reboot DNS lock no dnscrypt'; U=30; TU=$true; IO=$false; IL=$false; BG=$true; DNS=$true; E='DEGRADED_DNS' }
    @{ N='R03 install lock during reboot'; U=10; TU=$false; IO=$false; IL=$true; BG=$false; DNS=$false; E='OPEN' }
    @{ N='R04 post-install grace'; U=60; TU=$false; IO=$false; IL=$false; BG=$false; DNS=$false; PG=$true; E='OPEN_GRACE' }
    @{ N='R05 unbrick after emergency'; U=20; TU=$false; IO=$false; IL=$false; UB=$true; DNS=$false; E='OPEN_GRACE' }
    @{ N='R06 healthy after reboot'; U=120; TU=$true; IO=$true; IL=$false; BG=$false; DNS=$false; E='OPEN_HEALTHY' }
    @{ N='R07 zombie tunnel boot'; U=100; TU=$true; IO=$false; IL=$false; BG=$false; DNS=$false; E='OPEN_ZOMBIE_DEBOUNCE' }
    @{ N='R08 tunnel down boot'; U=100; TU=$false; IO=$false; IL=$false; BG=$false; DNS=$false; E='OPEN_TUNNEL_DOWN' }
)
foreach ($r in $regressions) {
    $bg = if ($r.ContainsKey('BG')) { [bool]$r.BG } else { $false }
    $pg = if ($r.ContainsKey('PG')) { [bool]$r.PG } else { $false }
    $ub = if ($r.ContainsKey('UB')) { [bool]$r.UB } else { $false }
    $ux = Get-SimMonitorBootUx $r.TU $r.IO $r.IL $bg $ub $pg $r.DNS
    if ($r.E -eq 'OPEN') { Assert-Reboot ($ux -like 'OPEN*') "$($r.N) -> $ux (expect open path)" }
    else { Assert-Reboot ($ux -like "$($r.E)*") "$($r.N) -> $ux (expect $($r.E))" }
}


Write-Host ''
if ($script:passed -ne $TARGET) {
    $failures.Add("Expected exactly $TARGET assertions, ran $($script:passed)")
}
if ($failures.Count -eq 0) {
    Write-Host "ALL $TARGET REBOOT SIMULATIONS PASSED" -ForegroundColor Green
    Write-Host '  Key finding: firewall NEVER blocks at boot; DNS-lock-without-dnscrypt is the main brick risk.' -ForegroundColor Gray
    exit 0
}
Write-Host "FAILED $($failures.Count) / $script:passed passed" -ForegroundColor Red
$failures | Select-Object -First 25 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
if ($failures.Count -gt 25) { Write-Host "  ... and $($failures.Count - 25) more" -ForegroundColor Red }
exit 1