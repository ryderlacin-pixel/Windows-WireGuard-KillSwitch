# v15 strong privacy stack — dot-sourced from install.ps1 (requires admin + install.ps1 variables)
#Requires -Version 5.1

function Get-DnscryptTomlContentV15 {
    return @"
# WG Kill Switch v15 - auto-generated (strict privacy)
listen_addresses = ['127.0.0.1:53']
max_clients = 256
ipv6_servers = false
block_ipv6 = true
require_dnssec = false
require_nolog = true
require_nofilter = false
force_tcp = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
log_level = 1
server_names = ['quad9-dnsovertls']
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53']
ignore_system_dns = true

[sources]

[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md'
]
cache_file = 'public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''
"@
}

function Get-TorUserJsContentV15 {
    $base = if (Get-Command Get-TorUserJsContent -EA SilentlyContinue) { Get-TorUserJsContent } else { '' }
    $extra = @"
user_pref("privacy.firstparty.isolate", true);
user_pref("network.http.referer.trimmingPolicy", 2);
user_pref("network.http.referer.XOriginTrimmingPolicy", 2);
"@
    if ([string]::IsNullOrWhiteSpace($base)) { return $extra.Trim() }
    return ($base.TrimEnd() + "`n" + $extra).Trim()
}

function Install-DnscryptExeFirewallRule {
    $prog = 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.exe'
    if (-not (Test-Path $prog)) { return $false }
    $exists = (netsh advfirewall firewall show rule name='KS-Dnscrypt-EXE' 2>&1 | Out-String) -notmatch 'No rules match'
    if (-not $exists) {
        netsh advfirewall firewall add rule name='KS-Dnscrypt-EXE' dir=out action=allow program="$prog" enable=yes 2>$null | Out-Null
        OK 'KS-Dnscrypt-EXE firewall rule added'
    }
    return $true
}

function Write-DnsLockdownGuardPs1 {
    $content = @"
# dns-lockdown-guard v$script:WG_KS_VERSION
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [DNS-LOCK] `$m" -Encoding UTF8 } catch {} }
`$tunnel = & sc.exe query 'WireGuardTunnel`$wgcf-profile' 2>&1 | Out-String
if (`$tunnel -notmatch 'RUNNING') {
    Log 'SKIP: WireGuard tunnel not RUNNING - refusing DNS lock (prevents internet brick)'
    Set-ItemProperty `$REG 'DnsLockdownState' 'DEFERRED' -Force -EA SilentlyContinue
    exit 0
}
`$st = & sc.exe query 'WG-DnscryptProxy' 2>&1 | Out-String
`$net = & netstat.exe -ano 2>&1 | Out-String
if (`$st -notmatch 'RUNNING' -or `$net -notmatch '127\.0\.0\.1:53\s+.*LISTENING') {
    Log 'SKIP: dnscrypt not healthy - refusing DNS lock (prevents internet brick)'
    Set-ItemProperty `$REG 'DnsLockdownState' 'DEFERRED' -Force -EA SilentlyContinue
    exit 0
}
`$tcp = `$null
try {
    `$tcp = New-Object System.Net.Sockets.TcpClient
    `$iar = `$tcp.BeginConnect('1.1.1.1', 443, `$null, `$null)
    if (-not `$iar.AsyncWaitHandle.WaitOne(4000, `$false)) {
        Log 'SKIP: internet not reachable - refusing DNS lock (prevents internet brick)'
        Set-ItemProperty `$REG 'DnsLockdownState' 'DEFERRED' -Force -EA SilentlyContinue
        exit 0
    }
    try { `$tcp.EndConnect(`$iar) } catch {
        Log 'SKIP: internet probe failed - refusing DNS lock (prevents internet brick)'
        Set-ItemProperty `$REG 'DnsLockdownState' 'DEFERRED' -Force -EA SilentlyContinue
        exit 0
    }
} catch {
    Log 'SKIP: internet probe error - refusing DNS lock (prevents internet brick)'
    Set-ItemProperty `$REG 'DnsLockdownState' 'DEFERRED' -Force -EA SilentlyContinue
    exit 0
} finally { if (`$tcp) { try { `$tcp.Close() } catch {} } }
try {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivity' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivity' 'DisableSmartNameResolution' 1 -Type DWord -Force
} catch { Log "SmartNameResolution reg failed: `$_" }
try {
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'EnableAutoDoh' 0 -Type DWord -Force
} catch { Log "EnableAutoDoh reg failed: `$_" }
`$fixed = 0
`$ifRaw = netsh interface show interface 2>&1 | Out-String
foreach (`$line in (`$ifRaw -split "`r?`n")) {
    if (`$line -notmatch '^\s*Enabled\s+Connected\s+\S+\s+(.+)$') { continue }
    `$name = `$Matches[1].Trim()
    `$null = netsh interface ipv4 set dnsservers name="`$name" source=static address=127.0.0.1 validate=no 2>&1
    if (`$LASTEXITCODE -eq 0) { `$fixed++ }
    else { Log "DNS lock netsh failed on `$name (exit `$LASTEXITCODE)" }
}
Set-ItemProperty `$REG 'DnsLockdownState' 'APPLIED' -Force -EA SilentlyContinue
Set-ItemProperty `$REG 'DnsLockdownAdapters' `$fixed -Force -EA SilentlyContinue
Log "dns-lockdown applied (`$fixed adapters)"
"@
    $content | Set-Content $script:DNS_LOCKDOWN_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:DNS_LOCKDOWN_GUARD_PS1 2>$null | Out-Null
}

function Write-NetworkPrivacyGuardPs1 {
    $content = @"
# network-privacy-guard v$script:WG_KS_VERSION
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [NET-PRIV] `$m" -Encoding UTF8 } catch {} }
try {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0 -Type DWord -Force
} catch { Log "LLMNR disable failed: `$_" }
`$nb = 0
foreach (`$key in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -EA SilentlyContinue)) {
    try {
        Set-ItemProperty -LiteralPath `$key.PSPath -Name NetbiosOptions -Value 2 -Type DWord -Force
        `$nb++
    } catch { Log "NetBIOS reg failed on `$(`$key.PSChildName): `$_" }
}
Set-ItemProperty `$REG 'NetworkPrivacyState' 'APPLIED' -Force -EA SilentlyContinue
Set-ItemProperty `$REG 'NetbiosDisabledAdapters' `$nb -Force -EA SilentlyContinue
Log "network-privacy applied (NetBIOS off on `$nb adapters)"
"@
    $content | Set-Content $script:NETWORK_PRIVACY_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:NETWORK_PRIVACY_GUARD_PS1 2>$null | Out-Null
}

function Write-DnscryptGuardPs1V15 {
    $toml = (Get-DnscryptTomlContentV15) -replace "'", "''"
    $content = @"
# dnscrypt-guard v$script:WG_KS_VERSION (v15 strict)
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$DNSCRYPT_DIR = 'C:\WireGuard\dnscrypt-proxy'
`$DNSCRYPT_EXE = Join-Path `$DNSCRYPT_DIR 'dnscrypt-proxy.exe'
`$DNSCRYPT_CONF = Join-Path `$DNSCRYPT_DIR 'dnscrypt-proxy.toml'
`$DNSCRYPT_SVC = 'WG-DnscryptProxy'
`$CONFIG = 'C:\WireGuard\wgcf-profile.conf'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [DNSCRYPT] `$m" -Encoding UTF8 } catch {} }
`$toml = @'
$toml
'@
if (-not (Test-Path `$DNSCRYPT_DIR)) { New-Item -Path `$DNSCRYPT_DIR -ItemType Directory -Force | Out-Null }
`$enc = New-Object System.Text.UTF8Encoding `$false
[System.IO.File]::WriteAllText(`$DNSCRYPT_CONF, `$toml, `$enc)
`$st = & sc.exe query `$DNSCRYPT_SVC 2>&1 | Out-String
if (`$st -notmatch 'RUNNING') {
    if (Test-Path 'C:\WireGuard\nssm.exe') {
        & 'C:\WireGuard\nssm.exe' start `$DNSCRYPT_SVC 2>`$null | Out-Null
    } else { & sc.exe start `$DNSCRYPT_SVC 2>`$null | Out-Null }
    Start-Sleep 2
}
function Test-DnscryptListening {
    `$st2 = & sc.exe query `$DNSCRYPT_SVC 2>&1 | Out-String
    if (`$st2 -notmatch 'RUNNING') { return `$false }
    `$net = & netstat.exe -ano 2>&1 | Out-String
    return (`$net -match '127\.0\.0\.1:53\s+.*LISTENING')
}
if (-not (Test-DnscryptListening)) {
    Log 'SKIP: dnscrypt not listening on 127.0.0.1:53 - refusing WG DNS change'
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'DnscryptState' 'DEFERRED' -Force -EA SilentlyContinue
    exit 0
}
if (Test-Path `$CONFIG) {
    `$lines = Get-Content `$CONFIG -Encoding UTF8
    `$out = @(); `$has = `$false
    foreach (`$line in `$lines) {
        if (`$line -match '^\s*DNS\s*=') { `$out += 'DNS = 127.0.0.1'; `$has = `$true } else { `$out += `$line }
    }
    if (-not `$has) { `$out += 'DNS = 127.0.0.1' }
    [System.IO.File]::WriteAllLines(`$CONFIG, `$out, `$enc)
}
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'DnscryptState' 'APPLIED' -Force -EA SilentlyContinue
Log 'dnscrypt guard applied (v15 strict)'
"@
    $content | Set-Content $script:DNSCRYPT_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:DNSCRYPT_GUARD_PS1 2>$null | Out-Null
}

function Write-TorHardeningGuardPs1V15 {
    $userJs = (Get-TorUserJsContentV15) -replace "'", "''"
    $content = @"
# tor-hardening-guard v$script:WG_KS_VERSION
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [TOR] `$m" -Encoding UTF8 } catch {} }
`$userJs = @'
$userJs
'@
`$roots = @(
    (Join-Path `$env:ProgramFiles 'Tor Browser'),
    (Join-Path `${env:ProgramFiles(x86)} 'Tor Browser'),
    (Join-Path `$env:LOCALAPPDATA 'Tor Browser')
)
foreach (`$root in `$roots) {
    if (-not (Test-Path `$root)) { continue }
    `$prof = Join-Path `$root 'Browser\TorBrowser\Data\Browser'
    if (-not (Test-Path `$prof)) { New-Item -Path `$prof -ItemType Directory -Force | Out-Null }
    `$userJs | Set-Content (Join-Path `$prof 'user.js') -Encoding UTF8 -Force
    Log "Tor user.js applied: `$root"
}
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'TorGuardApplied' (Get-Date -Format 'o') -Force -EA SilentlyContinue
Log 'tor hardening guard done (v15)'
"@
    $content | Set-Content $script:TOR_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:TOR_GUARD_PS1 2>$null | Out-Null
}

function Write-LeakSentinelPs1V15 {
    $content = @"
# leak-sentinel v$script:WG_KS_VERSION - read-only probes, never changes firewall
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
`$CRISIS = 'C:\WireGuard\leak-crisis.jsonl'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [LEAK] `$m" -Encoding UTF8 } catch {} }
function Write-Crisis(`$state, `$detail) {
    `$o = @{ t=(Get-Date -Format 'o'); state=`$state; detail=`$detail } | ConvertTo-Json -Compress
    try { Add-Content `$CRISIS `$o -Encoding UTF8 } catch {}
    Set-ItemProperty `$REG 'LeakState' `$state -Force -EA SilentlyContinue
}
`$hits = 0
for (`$i=0; `$i -lt 3; `$i++) {
    try {
        `$u = New-Object Net.Sockets.UdpClient
        `$u.Client.ReceiveTimeout = 1200
        `$b = [byte[]](0,0,1,0,0,1,0,0,0,0,0,0,3,119,119,119,3,99,111,109,0,0,1,0,1)
        [void]`$u.Send(`$b, `$b.Length, '8.8.8.8', 53)
        try { `$null = `$u.Receive([ref](New-Object Net.IPEndPoint([IPAddress]::Any,0))); `$hits++ } catch {}
        `$u.Close()
    } catch {}
}
`$blockOn = ((netsh advfirewall firewall show rule name='KS-DNS-Block' 2>&1 | Out-String) -match 'Enabled:\s+Yes')
if (`$hits -gt 0 -and `$blockOn) { Write-Crisis 'DNS_LEAK_SUSPECT' "8.8.8.8 responded `$hits/3 with block on"; Log "DNS leak suspect `$hits/3" }
elseif (`$hits -gt 0) { Log "Raw 8.8.8.8 probe `$hits/3 (DNS block off - not a crisis)" }
else { Log 'Raw 8.8.8.8 probe OK' }
`$sysLeak = 0
`$dnsRaw = netsh interface ipv4 show dnsservers 2>&1 | Out-String
foreach (`$line in (`$dnsRaw -split "`r?`n")) {
    if (`$line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
        if (`$Matches[1] -ne '127.0.0.1') { `$sysLeak++ }
    }
}
`$crisis = `$null
if (`$sysLeak -gt 0) { `$crisis = 'SYSTEM_DNS_LEAK'; `$detail = "non-local DNS on `$sysLeak entries"; Log "system DNS leak `$sysLeak" }
`$st = & sc.exe query 'WG-DnscryptProxy' 2>&1 | Out-String
if (`$st -notmatch 'RUNNING') { `$crisis = 'DNS_PROXY_DOWN'; `$detail = 'WG-DnscryptProxy not running'; Log 'dnscrypt service down' }
`$llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -EA SilentlyContinue).EnableMulticast
if (`$llmnr -eq 1) { `$crisis = 'LLMNR_ENABLED'; `$detail = 'EnableMulticast=1'; Log 'LLMNR still enabled' }
if (`$crisis) { Write-Crisis `$crisis `$detail }
else { Write-Crisis 'HEALTHY' 'system DNS locked + dnscrypt up'; Log 'leak sentinel HEALTHY' }
"@
    $content | Set-Content $script:LEAK_SENTINEL_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:LEAK_SENTINEL_PS1 2>$null | Out-Null
}

function Install-V15WifiRandomMac {
    try {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivity' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivity' 'Randomization' 1 -Type DWord -Force
        OK 'Wi-Fi random MAC: policy enabled'
        return $true
    } catch {
        WARN "Wi-Fi random MAC policy failed: $_"
        return $false
    }
}

function Install-SensitiveModeLauncher {
    $repoScripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
    foreach ($pair in @(
        @('sensitive-mode.ps1', "$script:INSTALL_DIR\sensitive-mode.ps1"),
        @('ensure-tor-sensitive.ps1', "$script:INSTALL_DIR\ensure-tor-sensitive.ps1")
    )) {
        $src = Join-Path $repoScripts $pair[0]
        if (-not (Test-Path $src)) { $src = Join-Path $PSScriptRoot $pair[0] }
        $dest = $pair[1]
        if (-not (Test-Path $src)) { WARN "$($pair[0]) source missing"; continue }
        if (Test-Path $dest) {
            icacls $dest /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
            attrib -R -S -H $dest 2>$null | Out-Null
        }
        try {
            $enc = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($dest, (Get-Content $src -Raw -Encoding UTF8), $enc)
            attrib +S +H $dest 2>$null | Out-Null
            OK "$($pair[0]) deployed"
        } catch { WARN "$($pair[0]) deploy failed: $_" }
    }
    $dest = "$script:INSTALL_DIR\sensitive-mode.ps1"
    try {
        $desk = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desk 'Hassas-Tarama.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$dest`""
        $lnk.WorkingDirectory = $script:INSTALL_DIR
        $lnk.Description = 'Tor Browser sensitive browsing (v15.1 one-step)'
        $lnk.Save()
        OK 'Hassas-Tarama.lnk shortcut created'
    } catch { WARN "Hassas-Tarama shortcut failed: $_" }
}

function Patch-RepairV15GuardChain {
    $repairPath = 'C:\WireGuard\repair.ps1'
    if (-not (Test-Path $repairPath)) { return $false }
    $raw = [System.IO.File]::ReadAllText($repairPath)
    if ($raw -match 'dns-lockdown-guard\.ps1') { return $true }
    $insert = @'

    $wgDnsLock = 'C:\WireGuard\dns-lockdown-guard.ps1'
    if (Test-Path $wgDnsLock) { & $wgDnsLock }
    $wgNetPriv = 'C:\WireGuard\network-privacy-guard.ps1'
    if (Test-Path $wgNetPriv) { & $wgNetPriv }

'@
    $anchor = 'if (Test-Path $wgDns) { & $wgDns }'
    if ($raw -notmatch [regex]::Escape($anchor)) { return $false }
    $raw = $raw.Replace($anchor, "$anchor$insert")
    if ($raw -notmatch 'dns-lockdown-guard\.ps1') { return $false }
    icacls $repairPath /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
    attrib -R -S -H $repairPath 2>$null | Out-Null
    [System.IO.File]::WriteAllText($repairPath, $raw, [System.Text.UTF8Encoding]::new($false))
    OK 'repair.ps1 patched with v15 guard chain'
    return $true
}

function Invoke-V15StrongPrivacyStack {
    try {
        if (Get-Command Invoke-V14FullPrivacyStack -EA SilentlyContinue) {
            Invoke-V14FullPrivacyStack
        } elseif (Get-Command Invoke-V14DnsLeakStack -EA SilentlyContinue) {
            Invoke-V14DnsLeakStack
            if (Get-Command Invoke-V14TorStack -EA SilentlyContinue) { Invoke-V14TorStack }
        }
        Write-DnscryptGuardPs1V15
        Write-DnsLockdownGuardPs1
        Write-NetworkPrivacyGuardPs1
        Write-TorHardeningGuardPs1V15
        Write-LeakSentinelPs1V15
        if (Get-Command Ensure-DnscryptTomlFile -EA SilentlyContinue) {
            Ensure-DnscryptTomlFile { Get-DnscryptTomlContentV15 } | Out-Null
        } else {
            New-Item -ItemType Directory -Path $script:DNSCRYPT_DIR -Force | Out-Null
            $enc = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($script:DNSCRYPT_CONF, (Get-DnscryptTomlContentV15), $enc)
        }
        Install-DnscryptExeFirewallRule | Out-Null
        Install-V15WifiRandomMac | Out-Null
        Install-SensitiveModeLauncher | Out-Null
        $deferGuards = (Get-Command Test-InstallInProgress -EA SilentlyContinue) -and (Test-InstallInProgress)
        if (-not $deferGuards) {
            if (Get-Command Invoke-GuardScriptSafe -EA SilentlyContinue) {
                Invoke-GuardScriptSafe -Path $script:DNSCRYPT_GUARD_PS1 -Label 'dnscrypt-guard'
                Start-Sleep -Seconds 2
                foreach ($g in @(
                    $script:DNS_LOCKDOWN_GUARD_PS1, $script:NETWORK_PRIVACY_GUARD_PS1,
                    $script:TOR_GUARD_PS1, $script:LEAK_SENTINEL_PS1
                )) {
                    Invoke-GuardScriptSafe -Path $g -Label (Split-Path $g -Leaf)
                }
            } else {
                if (Test-Path $script:DNSCRYPT_GUARD_PS1) { & $script:DNSCRYPT_GUARD_PS1 2>$null }
                Start-Sleep -Seconds 2
                foreach ($g in @(
                    $script:DNS_LOCKDOWN_GUARD_PS1, $script:NETWORK_PRIVACY_GUARD_PS1,
                    $script:TOR_GUARD_PS1, $script:LEAK_SENTINEL_PS1
                )) {
                    if (Test-Path $g) { & $g 2>$null }
                }
            }
        } elseif (Get-Command WARN -EA SilentlyContinue) {
            WARN 'v15 privacy guards deferred until install completes (internet protected)'
        }
        Patch-RepairV15GuardChain | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V15StrongPrivacy' '1' -Force -EA SilentlyContinue
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'PrivacyTier' 'STRONG' -Force -EA SilentlyContinue
    } catch {
        if (Get-Command WARN -EA SilentlyContinue) { WARN "v15 strong privacy stack: $_" }
    }
}

function Test-V15DnsLockdownHealthy {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
    if ($reg.DnsLockdownState -ne 'APPLIED') { return $false }
    $doh = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableAutoDoh -EA SilentlyContinue).EnableAutoDoh
    if ($doh -eq 1) { return $false }
    $leak = 0
    $dnsRaw = netsh interface ipv4 show dnsservers 2>&1 | Out-String
    foreach ($line in ($dnsRaw -split "`r?`n")) {
        if ($line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
            if ($Matches[1] -ne '127.0.0.1') { $leak++ }
        }
    }
    return ($leak -eq 0)
}

function Test-V15NetworkPrivacyHealthy {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
    if ($reg.NetworkPrivacyState -ne 'APPLIED') { return $false }
    $llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -EA SilentlyContinue).EnableMulticast
    return ($llmnr -ne 1)
}

function Extend-ScriptIntegrityVaultV15 {
    foreach ($f in @(
        $script:DNS_LOCKDOWN_GUARD_PS1, $script:NETWORK_PRIVACY_GUARD_PS1
    )) {
        if (-not (Test-Path $f)) { continue }
        $leaf = Split-Path $f -Leaf
        $hash = (Get-FileHash -Path $f -Algorithm SHA256).Hash
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' "Hash_$leaf" $hash -Force
    }
}

function Test-ScriptIntegrityVaultV15 {
    if (-not (Test-ScriptIntegrityVault)) { return $false }
    foreach ($pair in @(
        @{ File = $script:DNS_LOCKDOWN_GUARD_PS1; Key = 'Hash_dns-lockdown-guard.ps1' },
        @{ File = $script:NETWORK_PRIVACY_GUARD_PS1; Key = 'Hash_network-privacy-guard.ps1' }
    )) {
        if (-not (Test-Path $pair.File)) { continue }
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
        $expected = $reg.$($pair.Key)
        if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
        $actual = if (Get-Command Get-ScriptSha256 -EA SilentlyContinue) { Get-ScriptSha256 $pair.File } else { (Get-FileHash -LiteralPath $pair.File -Algorithm SHA256).Hash }
        if (-not $actual -or $actual -ne $expected) { return $false }
    }
    return $true
}