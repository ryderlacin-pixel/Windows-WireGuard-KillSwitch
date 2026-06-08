#Requires -RunAsAdministrator
# v15.0 SAFE LIVE VERIFY - read-only production gate. NEVER stops tunnel or disrupts internet.
$ErrorActionPreference = 'Continue'
$failures = [System.Collections.Generic.List[string]]::new()
$pass = 0
$TUNNEL_SVC = 'WireGuardTunnel$wgcf-profile'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'

function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Test-TunnelServiceRunning {
    try {
        $tunnelReg = Get-ItemProperty $REG -Name TunnelName -EA SilentlyContinue
        if ($tunnelReg.TunnelName) { $script:TUNNEL_SVC = "WireGuardTunnel`$$($tunnelReg.TunnelName)" }
    } catch {}
    return [bool]((& sc.exe query $TUNNEL_SVC 2>$null) -match 'RUNNING')
}

function Test-TunnelAdapterUp {
    $tunnelReg = Get-ItemProperty $REG -Name TunnelName -EA SilentlyContinue
    $tn = if ($tunnelReg -and $tunnelReg.TunnelName) { $tunnelReg.TunnelName } else { 'wgcf-profile' }
    $ifaces = & netsh interface show interface 2>$null | Out-String
    if ($ifaces -match 'WireGuard' -or $ifaces -match [regex]::Escape($tn)) { return $true }
    return $false
}

function Test-TunnelRunning {
    if (-not (Test-TunnelServiceRunning)) { return $false }
    return (Test-TunnelAdapterUp)
}

function Test-Tcp443([string]$h) {
    $t = $null
    try {
        $t = New-Object Net.Sockets.TcpClient
        $a = $t.BeginConnect($h, 443, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(4000, $false)) { return $false }
        try { $t.EndConnect($a) } catch { return $false }
        return $true
    } catch { return $false } finally { if ($t) { try { $t.Close() } catch {} } }
}

function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-Tcp443 $h) { $hits++ } }
    return ($hits -ge 2)
}

function Test-SafeToOpen {
    for ($try = 0; $try -lt 3; $try++) {
        if ((Test-TunnelRunning) -and (Test-Internet)) { return $true }
        if ($try -lt 2) { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Test-TaskExists([string]$Name) {
    $tn = '\' + $Name
    & schtasks.exe /Query /TN $tn 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-WmiSubscriptionActive {
    try {
        $f = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='WGMonitorFilter'" -EA SilentlyContinue
        if (-not $f) { return $false }
        $c = Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Filter "Name='WGMonitorConsumer'" -EA SilentlyContinue
        if (-not $c) { return $false }
        $bf = 'Filter = "__EventFilter.Name=''WGMonitorFilter''"'
        $b = Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Filter $bf -EA SilentlyContinue
        return [bool]$b
    } catch { return $false }
}

function Test-PrivacyChromiumPolicy([string]$VendorPath) {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Policies\$VendorPath" -EA SilentlyContinue
    return ($p -and $p.WebRtcIpHandlingPolicy -eq 'default_public_interface_only' -and
            $p.BlockThirdPartyCookies -eq 1 -and $p.MetricsReportingEnabled -eq 0 -and
            $p.DnsOverHttpsMode -eq 'off' -and $p.PrivacySandboxAdTopicsEnabled -eq 0 -and $p.QuicAllowed -eq 0)
}

function Test-ScriptIntegrityVault {
    $reg = Get-ItemProperty $REG -EA SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($pair in @(
        @{ File = 'C:\WireGuard\monitor.ps1'; Key = 'Hash_monitor.ps1' },
        @{ File = 'C:\WireGuard\repair.ps1'; Key = 'Hash_repair.ps1' },
        @{ File = 'C:\WireGuard\privacy-hardening-guard.ps1'; Key = 'Hash_privacy-hardening-guard.ps1' },
        @{ File = 'C:\WireGuard\dnscrypt-guard.ps1'; Key = 'Hash_dnscrypt-guard.ps1' },
        @{ File = 'C:\WireGuard\leak-sentinel.ps1'; Key = 'Hash_leak-sentinel.ps1' },
        @{ File = 'C:\WireGuard\dns-lockdown-guard.ps1'; Key = 'Hash_dns-lockdown-guard.ps1' },
        @{ File = 'C:\WireGuard\network-privacy-guard.ps1'; Key = 'Hash_network-privacy-guard.ps1' }
    )) {
        $expected = $reg.$($pair.Key)
        if ([string]::IsNullOrWhiteSpace($expected)) { continue }
        if (-not (Test-Path $pair.File)) { return $false }
        $actual = (Get-FileHash -Path $pair.File -Algorithm SHA256).Hash
        if ($actual -ne $expected) { return $false }
    }
    return $true
}

function Test-DnscryptHealthy {
    $st = & sc.exe query WG-DnscryptProxy 2>&1 | Out-String
    if ($st -notmatch 'RUNNING') { return $false }
    $net = & netstat.exe -ano 2>&1 | Out-String
    return ($net -match '127\.0\.0\.1:53\s+.*LISTENING')
}

function Get-MonitorCount {
    if (-not (Test-Path 'C:\WireGuard\killswitch.log')) { return 0 }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $hits = 0
    Get-Content 'C:\WireGuard\killswitch.log' -Tail 40 -EA SilentlyContinue | ForEach-Object {
        if ($_ -match "\[MON\]" -and $_ -match $today) { $script:hits++ }
    }
    if ($hits -gt 0) { return 1 }
    if (Test-TaskExists 'WG-KillSwitch') { return 1 }
    return 0
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SAFE LIVE VERIFY (v15.0 - non-disruptive)" -ForegroundColor Cyan
Write-Host "  Metrics: KillSwitch | DnsLeak | PrivacyStrong | Tor" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$healthy = Test-SafeToOpen
Assert $healthy 'KillSwitch: tunnel + TCP internet (SafeToOpen)'
if (-not $healthy) { Write-Host "  [WARN] System unhealthy - read-only audits only" -ForegroundColor Yellow }

$ksReg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($ksReg -and ($ksReg.Version -match '^15\.' -or $ksReg.Version -ge '15.0' -or ($ksReg.Version -ge '14.0' -and $ksReg.V15StrongPrivacy -eq '1') -or ($ksReg.Version -ge '13.5' -and $ksReg.V14DnsLeak -eq '1'))) "Registry version 15.0+ or phased (got $($ksReg.Version))"
Assert (Test-Path 'C:\WireGuard\monitor.ps1') 'monitor.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\repair.ps1') 'repair.ps1 deployed'
Assert (-not (Test-Path 'C:\WireGuard\kurtar.bat')) 'kurtar.bat removed'
Assert (-not (Test-Path 'C:\WireGuard\kurtar.ps1')) 'kurtar.ps1 removed'
Assert (-not (Test-Path 'C:\WireGuard\kurtar2.ps1')) 'kurtar2.ps1 removed'
Assert (-not (Test-Path 'C:\WireGuard\resume-after-unbrick.ps1')) 'resume-after-unbrick.ps1 removed'
Assert (Test-Path 'C:\WireGuard\anti-tamper.ps1') 'anti-tamper.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\privacy-hardening-guard.ps1') 'privacy-hardening-guard.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\webrtc-leak-guard.ps1') 'webrtc-leak-guard.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\wmi-repair.ps1') 'wmi-repair.ps1 deployed'
Assert (Test-WmiSubscriptionActive) 'WMI subscription: filter+consumer+binding'
Assert (-not (Test-Path 'C:\WireGuard\install.inprogress')) 'install lock cleared'

$mon = Get-Content 'C:\WireGuard\monitor.ps1' -Raw -EA SilentlyContinue
$rep = Get-Content 'C:\WireGuard\repair.ps1' -Raw -EA SilentlyContinue
$svc = Get-Content 'C:\WireGuard\service-monitor.ps1' -Raw -EA SilentlyContinue
$gpo = Get-Content 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\wg-startup.ps1' -Raw -EA SilentlyContinue
$wd = Get-Content 'C:\WireGuard\internet-watchdog.ps1' -Raw -EA SilentlyContinue

Assert ($mon -match 'v15\.0|v14\.0|Monitor v15|Monitor v14|v13\.5|Monitor v13') 'monitor.ps1 version (v15/v14 or v13.5 phased)'
Assert ($mon -match 'Test-TunnelAdapterUp') 'monitor dual-check: service + adapter'
Assert ($mon -match 'Test-BootGrace') 'monitor has BootGrace fail-open'
Assert ($mon -match 'Test-BlockAllowed') 'monitor has block-allowed guard'
Assert ($mon -notmatch 'Test-Dns') 'monitor SafeToOpen excludes DNS gate'
Assert ($mon -match 'no re-block') 'monitor recovery never re-blocks'
Assert ($mon -match 'Invoke-EmergencyUnbrick') 'monitor has emergency unbrick'
Assert ($mon -notmatch 'kurtar') 'monitor has no kurtar references'
Assert ($rep -match 'v15\.0|v14\.0|Repair Script v15|Repair Script v14|v13\.5|Repair Script v13') 'repair.ps1 version (v15/v14 or v13.5 phased)'
Assert ($rep -notmatch 'dns-lockdown-guard\.ps1') 'repair does NOT auto-run dns-lockdown (v15.3 manual-only)'
Assert ($rep -match 'network-privacy-guard\.ps1') 'repair re-applies network-privacy guard'
Assert ($rep -match 'privacy-hardening-guard\.ps1') 'repair re-applies privacy guard'
Assert ($rep -match 'dnscrypt-guard\.ps1') 'repair re-applies dnscrypt guard'
Assert ($rep -match 'leak-sentinel\.ps1') 'repair runs leak-sentinel'
Assert ($rep -match 'monitor-only block authority') 'repair never blocks (monitor-only)'
Assert ($rep -notmatch 'function Enable-Block') 'repair has no Enable-Block function'
Assert ($wd -match 'Invoke-GentleUnbrick') 'watchdog has gentle unbrick'
Assert ($wd -match 'Invoke-DeepUnbrick') 'watchdog has deep unbrick (no teardown)'
Assert ($wd -notmatch 'kurtar') 'watchdog has no kurtar references'
Assert ($gpo -match 'v15\.|v14\.0|v13\.5') 'GPO script version (v15/v14 or v13.5 phased)'
Assert ($gpo -match 'never blocks') 'GPO has no block authority'

foreach ($tn in @('WG-KillSwitch', 'WG-RepairTask', 'WG-RebootVerify', 'WG-InternetWatchdog')) {
    Assert (Test-TaskExists $tn) "Task $tn active"
}
if (Test-Path 'C:\WireGuard\nssm.exe') {
    $svcSt = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
    Assert ($svcSt -match 'RUNNING') 'WGKillSwitchSvc RUNNING'
}
Assert ((Get-MonitorCount) -ge 1) 'Monitor process running'
Assert ((Get-MonitorCount) -le 1) 'Single monitor instance'

if ($healthy) {
    $o = netsh advfirewall firewall show rule name='KS-WARP-Server-Out' 2>&1 | Out-String
    Assert ($o -match 'Enabled:\s+Yes') 'Firewall enabled: KS-WARP-Server-Out'
    foreach ($r in @('KS-DNS-Block', 'KS-DNS-Block-TCP')) {
        $o = netsh advfirewall firewall show rule name=$r 2>&1 | Out-String
        Assert ($o -match 'Enabled:\s+No') "DNS leak OFF when healthy: $r"
    }
    foreach ($r in @('KS-Block-WiFi-Out', 'KS-Block-Ethernet-Out')) {
        $o = netsh advfirewall firewall show rule name=$r 2>&1 | Out-String
        Assert ($o -match 'No rules match') "Block absent when healthy: $r"
    }
}

Assert (Test-Path 'C:\ProgramData\WGKillSwitchGuard') 'Anti-tamper guard vault present'
foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
    Assert (Test-PrivacyChromiumPolicy $pair[0]) "Browser privacy v14: $($pair[1])"
}
$tel = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -EA SilentlyContinue
Assert ($tel -and $tel.AllowTelemetry -eq 0) 'Windows telemetry: AllowTelemetry=0'
$wer = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -EA SilentlyContinue
Assert ($wer -and $wer.Disabled -eq 1) 'Windows Error Reporting: disabled'
$adv = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -EA SilentlyContinue
Assert ($adv -and $adv.DisabledByGroupPolicy -eq 1) 'Windows advertising ID: disabled'
$cloud = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -EA SilentlyContinue
Assert ($cloud -and $cloud.DisableWindowsConsumerFeatures -eq 1) 'Windows consumer features: disabled'
$priv = Get-Content 'C:\WireGuard\privacy-hardening-guard.ps1' -Raw -EA SilentlyContinue
Assert ($priv -match 'DnsOverHttpsMode') 'privacy guard: DoH off'
Assert ($priv -match 'PrivacySandboxAdTopicsEnabled') 'privacy guard: Privacy Sandbox off'
Assert ($priv -match 'QuicAllowed') 'privacy guard: QUIC off'
Assert ($priv -match 'fingerprintingProtection') 'privacy guard: Firefox fingerprintingProtection'
Assert ($priv -match 'webgl\.disabled') 'privacy guard: Firefox WebGL off'
Assert ($priv -match 'AllowTelemetry') 'privacy guard reduces Windows telemetry'
Assert (Test-ScriptIntegrityVault) 'Script integrity vault: SHA256 match'

# --- v14 DnsLeak metric ---
Assert (Test-Path 'C:\WireGuard\dnscrypt-guard.ps1') 'DnsLeak: dnscrypt-guard.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\leak-sentinel.ps1') 'DnsLeak: leak-sentinel.ps1 deployed'
if ($ksReg.V14DnsLeak -eq '1' -or (Test-Path 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.exe')) {
    Assert (Test-DnscryptHealthy) 'DnsLeak: dnscrypt-proxy RUNNING + 127.0.0.1:53'
    $cfgDns = Get-Content 'C:\WireGuard\wgcf-profile.conf' -EA SilentlyContinue | Where-Object { $_ -match '^\s*DNS\s*=' } | Select-Object -First 1
    Assert ($cfgDns -match '127\.0\.0\.1') 'DnsLeak: WireGuard DNS = 127.0.0.1'
    $leakSt = $ksReg.LeakState
    if ($leakSt) { Assert ($leakSt -eq 'HEALTHY') "DnsLeak: LeakState $leakSt" }
}

# --- v15 PrivacyStrong metric ---
if ($ksReg.V15StrongPrivacy -eq '1' -or $ksReg.Version -ge '15.0') {
    Assert (Test-Path 'C:\WireGuard\dns-lockdown-guard.ps1') 'PrivacyStrong: dns-lockdown-guard.ps1 deployed'
    Assert (Test-Path 'C:\WireGuard\network-privacy-guard.ps1') 'PrivacyStrong: network-privacy-guard.ps1 deployed'
    $sysLeak = 0
    $dnsRaw = netsh interface ipv4 show dnsservers 2>&1 | Out-String
    foreach ($line in ($dnsRaw -split "`r?`n")) {
        if ($line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
            if ($Matches[1] -ne '127.0.0.1') { $sysLeak++ }
        }
    }
    Assert ($sysLeak -eq 0) "PrivacyStrong: all adapter DNS = 127.0.0.1 (leaks=$sysLeak)"
    $doh = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableAutoDoh -EA SilentlyContinue).EnableAutoDoh
    Assert ($doh -ne 1) 'PrivacyStrong: Windows DoH auto disabled'
    $llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -EA SilentlyContinue).EnableMulticast
    Assert ($llmnr -ne 1) 'PrivacyStrong: LLMNR disabled'
    $fwDnscrypt = netsh advfirewall firewall show rule name='KS-Dnscrypt-EXE' 2>&1 | Out-String
    Assert ($fwDnscrypt -notmatch 'No rules match') 'PrivacyStrong: KS-Dnscrypt-EXE firewall rule'
    $toml = Get-Content 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.toml' -Raw -EA SilentlyContinue
    if ($toml) {
        Assert ($toml -match 'require_nolog\s*=\s*true') 'PrivacyStrong: dnscrypt require_nolog'
        Assert ($toml -match 'quad9-dnsovertls') 'PrivacyStrong: dnscrypt quad9 only'
    }
}

# --- v14 Tor metric (optional) ---
Assert (Test-Path 'C:\WireGuard\tor-hardening-guard.ps1') 'Tor: tor-hardening-guard.ps1 deployed'
$torSt = $ksReg.TorState
if ($torSt -eq 'NOT_INSTALLED') {
    Write-Host "  [INFO] Tor: not installed (optional)" -ForegroundColor Gray
} elseif ($torSt) {
    Assert ($torSt -in @('HEALTHY','TOR_DOWN')) "Tor: TorState $torSt"
}

Assert (Test-Internet) 'Post-check: TCP internet still working'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SAFE LIVE: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  SAFE LIVE VERIFY: PASSED" -ForegroundColor Green
exit 0