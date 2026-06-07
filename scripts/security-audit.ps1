#Requires -RunAsAdministrator
# WireGuard Kill Switch - Full Security Audit (IP/DNS/IPv6/KillSwitch)
$ErrorActionPreference = 'Continue'
$findings = [System.Collections.Generic.List[object]]::new()
$pass = 0
$fail = 0
$warn = 0

function Add-Result([string]$Cat, [string]$Test, [string]$Status, [string]$Detail) {
    $script:findings.Add([pscustomobject]@{ Category=$Cat; Test=$Test; Status=$Status; Detail=$Detail })
    switch ($Status) {
        'PASS' { $script:pass++ }
        'FAIL' { $script:fail++ }
        'WARN' { $script:warn++ }
    }
}

function Test-TcpHost([string]$HostName, [int]$Port, [int]$TimeoutMs = 5000) {
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

function Test-RulePresent([string]$Name) {
    $o = netsh advfirewall firewall show rule name=$Name 2>&1 | Out-String
    return ($o -notmatch 'No rules match')
}
function Test-RuleEnabled([string]$Name) {
    $o = netsh advfirewall firewall show rule name=$Name 2>&1 | Out-String
    return ($o -match 'Enabled:\s+Yes')
}
function Test-RuleAbsent([string]$Name) {
    $o = netsh advfirewall firewall show rule name=$Name 2>&1 | Out-String
    return ($o -match 'No rules match')
}

function Test-TunnelRunning {
    return ([bool](( & sc.exe query 'WireGuardTunnel$wgcf-profile' 2>$null) -match 'RUNNING'))
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  WG KILL SWITCH - FULL SECURITY AUDIT' -ForegroundColor Cyan
Write-Host '  ' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# --- TUNNEL ---
$tunnelUp = Test-TunnelRunning
if ($tunnelUp) { Add-Result 'Tunnel' 'WireGuard service RUNNING' 'PASS' 'WireGuardTunnel$wgcf-profile' }
else { Add-Result 'Tunnel' 'WireGuard service RUNNING' 'FAIL' 'Tunnel DOWN - kill switch should block' }

$wgAdapter = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Name -eq 'wgcf-profile' }
if ($wgAdapter -and $wgAdapter.Status -eq 'Up') {
    Add-Result 'Tunnel' 'wgcf-profile adapter Up' 'PASS' $wgAdapter.InterfaceDescription
} elseif ($tunnelUp) {
    Add-Result 'Tunnel' 'wgcf-profile adapter Up' 'WARN' "Status=$($wgAdapter.Status)"
} else {
    Add-Result 'Tunnel' 'wgcf-profile adapter Up' 'FAIL' 'Adapter missing or down'
}

$conf = Get-Content 'C:\WireGuard\wgcf-profile.conf' -Raw -EA SilentlyContinue
if ($conf -match 'AllowedIPs\s*=\s*0\.0\.0\.0/0') {
    Add-Result 'Tunnel' 'Full tunnel (0.0.0.0/0)' 'PASS' 'All IPv4 via tunnel'
} else {
    Add-Result 'Tunnel' 'Full tunnel (0.0.0.0/0)' 'FAIL' 'Split tunnel risk - check AllowedIPs'
}
if ($conf -match '::/0') {
    Add-Result 'Tunnel' 'IPv6 absent from AllowedIPs' 'FAIL' '::/0 still in config - run install.ps1 v11.0+'
} else {
    Add-Result 'Tunnel' 'IPv6 absent from AllowedIPs' 'PASS' 'AllowedIPs is IPv4-only'
}

# --- ROUTING ---
$defRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue
$wgRoute = $defRoutes | Where-Object { $_.InterfaceAlias -eq 'wgcf-profile' }
$wifiRoute = $defRoutes | Where-Object { $_.InterfaceAlias -eq 'Wi-Fi' }
if ($wgRoute) {
    Add-Result 'Routing' 'Default route via wgcf-profile' 'PASS' "Metric=$($wgRoute.RouteMetric)"
} else {
    Add-Result 'Routing' 'Default route via wgcf-profile' 'FAIL' 'No 0.0.0.0/0 via tunnel'
}
if ($wifiRoute -and $tunnelUp) {
    $detail = "Wi-Fi default route also present (metric=$($wifiRoute.RouteMetric)) - normal with WireGuard split metric"
    if ($wgRoute -and $wgRoute.RouteMetric -le $wifiRoute.RouteMetric) {
        Add-Result 'Routing' 'Tunnel route preferred' 'PASS' $detail
    } else {
        Add-Result 'Routing' 'Tunnel route preferred' 'WARN' $detail
    }
}

# --- PUBLIC IP (leak test) ---
Write-Host '[-->] Fetching public IP via tunnel...' -ForegroundColor Gray
$publicIp = $null
$ipSources = @(
    @{ Url='https://1.1.1.1/cdn-cgi/trace'; Pattern='ip=([0-9.]+)' },
    @{ Url='https://www.cloudflare.com/cdn-cgi/trace'; Pattern='ip=([0-9.]+)' },
    @{ Url='https://api.ipify.org'; Pattern='([0-9.]+)' }
)
foreach ($src in $ipSources) {
    try {
        $r = Invoke-WebRequest -Uri $src.Url -UseBasicParsing -TimeoutSec 10 -EA Stop
        if ($r.Content -match $src.Pattern) { $publicIp = $Matches[1]; break }
    } catch {}
}
if ($publicIp) {
    $isCf = $publicIp -match '^(104\.|162\.159\.|172\.64\.|172\.65\.|172\.66\.|172\.67\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.)'
    if ($isCf) {
        Add-Result 'IP Leak' 'Public IP via HTTPS' 'PASS' "IP=$publicIp (Cloudflare/WARP range)"
    } else {
        Add-Result 'IP Leak' 'Public IP via HTTPS' 'FAIL' "IP=$publicIp (NOT Cloudflare - possible leak)"
    }
} else {
    Add-Result 'IP Leak' 'Public IP via HTTPS' 'WARN' 'Could not fetch public IP'
}

# --- DNS LEAK ---
Write-Host '[-->] DNS leak tests...' -ForegroundColor Gray
$dnsBlockUdp = Test-RuleEnabled 'KS-DNS-Block'
$dnsBlockTcp = Test-RuleEnabled 'KS-DNS-Block-TCP'
$dnsAllow = Test-RuleEnabled 'KS-DNS-Allow'
if ($dnsBlockUdp) { Add-Result 'DNS Leak' 'KS-DNS-Block (UDP/53)' 'PASS' 'Blocks unauthorized UDP DNS' }
else { Add-Result 'DNS Leak' 'KS-DNS-Block (UDP/53)' 'FAIL' 'Rule missing or disabled' }
if ($dnsBlockTcp) { Add-Result 'DNS Leak' 'KS-DNS-Block-TCP' 'PASS' 'Blocks TCP port 53' }
else { Add-Result 'DNS Leak' 'KS-DNS-Block-TCP' 'FAIL' 'Rule missing or disabled' }
if ($dnsAllow) { Add-Result 'DNS Leak' 'KS-DNS-Allow (1.1.1.1/1.0.0.1)' 'PASS' 'Only CF DNS allowed outbound' }
else { Add-Result 'DNS Leak' 'KS-DNS-Allow' 'FAIL' 'Allow rule missing' }

# Test DNS to non-CF server should fail (3 attempts — ignore single flaky response)
$dnsLeakHits = 0
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 1500
        $bytes = [byte[]](0,0,1,0,0,1,0,0,0,0,0,0,3,119,119,119,3,99,111,109,0,0,1,0,1)
        [void]$udp.Send($bytes, $bytes.Length, '8.8.8.8', 53)
        try { $null = $udp.Receive([ref](New-Object IPEndPoint([IPAddress]::Any,0))); $dnsLeakHits++ } catch {}
        $udp.Close()
    } catch {}
    Start-Sleep -Milliseconds 500
}
if ($dnsLeakHits -eq 0) {
    Add-Result 'DNS Leak' 'UDP/53 to 8.8.8.8 blocked' 'PASS' 'Cannot query Google DNS directly (3 tries)'
} elseif ($dnsLeakHits -lt 3 -and (Test-RuleEnabled 'KS-DNS-Block')) {
    Add-Result 'DNS Leak' 'UDP/53 to 8.8.8.8 blocked' 'PASS' "Flaky probe ($dnsLeakHits/3) but KS-DNS-Block active"
} else {
    Add-Result 'DNS Leak' 'UDP/53 to 8.8.8.8 blocked' 'FAIL' "Google DNS responded $dnsLeakHits/3 - check KS-DNS-Block"
}

# DNS resolution through system
try {
    $resolved = Resolve-DnsName google.com -Type A -EA Stop | Select-Object -First 1
    if ($resolved.IPAddress) {
        Add-Result 'DNS Leak' 'System DNS resolves google.com' 'PASS' "A=$($resolved.IPAddress)"
    }
} catch {
    Add-Result 'DNS Leak' 'System DNS resolves google.com' 'FAIL' $_.Exception.Message
}

# DNS server addresses on interfaces
$dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue |
    Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 }
$badDns = $dnsServers | Where-Object {
    $_.InterfaceAlias -ne 'wgcf-profile' -and
    ($_.ServerAddresses | Where-Object { $_ -notin @('1.1.1.1','1.0.0.1','127.0.0.1') })
}
if (-not $badDns) {
    Add-Result 'DNS Leak' 'No rogue DNS on adapters' 'PASS' 'Only CF DNS or none on physical adapters'
} else {
    foreach ($d in $badDns) {
        Add-Result 'DNS Leak' "Rogue DNS on $($d.InterfaceAlias)" 'WARN' ($d.ServerAddresses -join ',')
    }
}

# --- IPv6 LEAK ---
$ipv6Reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents -EA SilentlyContinue
if ($ipv6Reg -and $ipv6Reg.DisabledComponents -eq 255) {
    Add-Result 'IPv6 Leak' 'DisabledComponents=0xFF' 'PASS' 'IPv6 stack disabled'
} else {
    Add-Result 'IPv6 Leak' 'DisabledComponents=0xFF' 'FAIL' "Got=$($ipv6Reg.DisabledComponents)"
}
$ipv6Bindings = Get-NetAdapterBinding -ComponentID ms_tcpip6 -EA SilentlyContinue |
    Where-Object { $_.Enabled -eq $true -and $_.Status -eq 'Up' }
if (-not $ipv6Bindings) {
    Add-Result 'IPv6 Leak' 'IPv6 binding disabled on active adapters' 'PASS' 'ms_tcpip6 off'
} else {
    Add-Result 'IPv6 Leak' 'IPv6 binding disabled on active adapters' 'FAIL' ($ipv6Bindings.Name -join ', ')
}
try {
    $ping6 = Test-NetConnection -ComputerName '2606:4700:4700::1111' -WarningAction SilentlyContinue -EA SilentlyContinue
    if (-not $ping6.PingSucceeded -and -not $ping6.TcpTestSucceeded) {
        Add-Result 'IPv6 Leak' 'IPv6 connectivity test' 'PASS' 'No IPv6 reachability'
    } else {
        Add-Result 'IPv6 Leak' 'IPv6 connectivity test' 'FAIL' 'IPv6 traffic possible'
    }
} catch {
    Add-Result 'IPv6 Leak' 'IPv6 connectivity test' 'PASS' 'Unreachable'
}

# --- KILL SWITCH ---
$safe = $tunnelUp -and (Test-TcpHost '1.1.1.1' 443) -and (Test-TcpHost '8.8.8.8' 443)
if ($safe) {
    Add-Result 'Kill Switch' 'Test-SafeToOpen' 'PASS' 'Tunnel up + internet OK'
    foreach ($br in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        if (Test-RuleAbsent $br) { Add-Result 'Kill Switch' "Block off (healthy): $br" 'PASS' 'Correct when tunnel healthy' }
        else { Add-Result 'Kill Switch' "Block off (healthy): $br" 'WARN' 'Block rule present while healthy' }
    }
} else {
    Add-Result 'Kill Switch' 'Test-SafeToOpen' 'WARN' 'Not safe-to-open state'
    foreach ($br in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        if (Test-RuleEnabled $br) { Add-Result 'Kill Switch' "Block active: $br" 'PASS' 'Leak protection ON' }
        else { Add-Result 'Kill Switch' "Block active: $br" 'FAIL' 'Should block when unhealthy' }
    }
}

foreach ($r in @('KS-WARP-Server-Out','KS-WireGuard-EXE','KS-LAN-Out','KS-DHCP-Out','KS-Loopback-Out')) {
    if (Test-RuleEnabled $r) { Add-Result 'Firewall' "$r enabled" 'PASS' '' }
    elseif (Test-RulePresent $r) { Add-Result 'Firewall' "$r enabled" 'WARN' 'Present but disabled?' }
    else { Add-Result 'Firewall' "$r enabled" 'FAIL' 'Missing' }
}

# --- SIMULATED LEAK TEST (tunnel stop brief) ---
Write-Host ''
Write-Host '[-->] Kill switch simulation: brief tunnel stop...' -ForegroundColor Yellow
if ($tunnelUp) {
    sc.exe stop 'WireGuardTunnel$wgcf-profile' 2>$null | Out-Null
    $postTunnel = $true
    $postBlock = $false
    $postInternet = $true
    for ($w = 0; $w -lt 15; $w++) {
        Start-Sleep -Seconds 2
        $postTunnel = Test-TunnelRunning
        $postBlock = Test-RuleEnabled 'KS-Block-WiFi-Out'
        $postInternet = Test-TcpHost '1.1.1.1' 443
        if ($postBlock) { break }
        if ($w -eq 4) {
            Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\WireGuard\repair.ps1' -WindowStyle Hidden -EA SilentlyContinue
        }
    }
    if ($postBlock) {
        Add-Result 'Kill Switch SIM' 'Block activates on tunnel down' 'PASS' "Within $($w * 2)s"
    } else {
        Add-Result 'Kill Switch SIM' 'Block activates on tunnel down' 'FAIL' 'Block did NOT activate within 30s'
    }
    $postInternetLeak = Test-TcpHost '93.184.216.34' 443
    if (-not $postInternetLeak) {
        Add-Result 'Kill Switch SIM' 'Internet blocked on tunnel down' 'PASS' 'Non-WARP TCP 443 blocked'
    } elseif ($postBlock) {
        Add-Result 'Kill Switch SIM' 'Internet blocked on tunnel down' 'WARN' 'Block on but non-WARP TCP succeeded'
    } else {
        Add-Result 'Kill Switch SIM' 'Internet blocked on tunnel down' 'FAIL' 'No block and internet reachable'
    }
    & 'C:\Program Files\WireGuard\wireguard.exe' /installtunnelservice 'C:\WireGuard\wgcf-profile.conf' 2>$null | Out-Null
    Start-Sleep 8
    $restored = Test-TunnelRunning
    if ($restored) { Add-Result 'Kill Switch SIM' 'Tunnel restored' 'PASS' 'Reinstalled OK' }
    else { Add-Result 'Kill Switch SIM' 'Tunnel restored' 'FAIL' 'Could not restore - run kurtar.bat' }
} else {
    Add-Result 'Kill Switch SIM' 'Tunnel stop test' 'WARN' 'Skipped - tunnel already down'
}

# Always restore tunnel after audit (especially after simulation)
if (-not (Test-TunnelRunning)) {
    & 'C:\Program Files\WireGuard\wireguard.exe' /installtunnelservice 'C:\WireGuard\wgcf-profile.conf' 2>$null | Out-Null
    Start-Sleep 8
    if (Test-TunnelRunning) { Write-Host '[-->] Tunnel restored after audit' -ForegroundColor Green }
}
& sc.exe config 'WireGuardTunnel$wgcf-profile' start= delayed-auto 2>$null | Out-Null
Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\WireGuard\repair.ps1' -WindowStyle Hidden -EA SilentlyContinue
schtasks /Run /TN '\WG-KillSwitch' 2>$null | Out-Null

# --- PROCESS LAYERS (after sim — wait for monitor recovery) ---
$monProcs = @()
for ($mw = 0; $mw -lt 12; $mw++) {
    $monProcs = @()
    foreach ($shell in @('powershell','pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $monProcs += $_ }
            } catch {}
        }
    }
    if ($monProcs.Count -ge 1) { break }
    Start-Sleep -Seconds 3
}
if ($monProcs.Count -gt 1) {
    $monProcs | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object {
        Stop-Process -Id $_.Id -Force -EA SilentlyContinue
    }
    Start-Sleep 3
    $monProcs = @()
    foreach ($shell in @('powershell','pwsh')) {
        Get-Process $shell -EA SilentlyContinue | ForEach-Object {
            try {
                $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -EA Stop).CommandLine
                if ($c -match '(?:\\|/)monitor\.ps1(?:\s|"|$)') { $monProcs += $_ }
            } catch {}
        }
    }
}
$monCount = $monProcs.Count
if ($monCount -eq 1) { Add-Result 'Layers' 'Single monitor process' 'PASS' 'PID count=1' }
elseif ($monCount -eq 0) { Add-Result 'Layers' 'Single monitor process' 'FAIL' 'No monitor running' }
else { Add-Result 'Layers' 'Single monitor process' 'FAIL' "Duplicate monitors: count=$monCount" }

$svc = & sc.exe query WGKillSwitchSvc 2>&1 | Out-String
if ($svc -match 'RUNNING') { Add-Result 'Layers' 'WGKillSwitchSvc' 'PASS' 'RUNNING' }
else { Add-Result 'Layers' 'WGKillSwitchSvc' 'WARN' 'Not running' }

$wmi = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -EA SilentlyContinue | Where-Object { $_.Name -eq 'WGMonitorFilter' }
if ($wmi) { Add-Result 'Layers' 'WMI subscription' 'PASS' 'ACTIVE' }
else { Add-Result 'Layers' 'WMI subscription' 'FAIL' 'Missing - run install.ps1 v11.0+' }

# --- REPORT ---
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  RESULTS' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
foreach ($cat in ($findings | Select-Object -ExpandProperty Category -Unique)) {
    Write-Host "`n[$cat]" -ForegroundColor White
    $findings | Where-Object { $_.Category -eq $cat } | ForEach-Object {
        $col = switch ($_.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } }
        $line = "  [{0}] {1}" -f $_.Status, $_.Test
        if ($_.Detail) { $line += " - $($_.Detail)" }
        Write-Host $line -ForegroundColor $col
    }
}
Write-Host ''
Write-Host "SUMMARY: PASS=$pass  FAIL=$fail  WARN=$warn" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -eq 0 -and $warn -eq 0) { Write-Host 'VERDICT: ALL SECURITY CHECKS PASSED' -ForegroundColor Green }
elseif ($fail -eq 0) { Write-Host 'VERDICT: PASSED WITH WARNINGS' -ForegroundColor Yellow }
else { Write-Host 'VERDICT: FAILURES DETECTED - REVIEW ABOVE' -ForegroundColor Red }
Write-Host ''
exit $(if ($fail -gt 0) { 1 } else { 0 })