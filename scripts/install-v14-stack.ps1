# v14 privacy stack — dot-sourced from install.ps1 (requires admin + install.ps1 variables)
#Requires -Version 5.1

function Get-TorBrowserRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Tor Browser'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tor Browser'),
        (Join-Path $env:LOCALAPPDATA 'Tor Browser'),
        (Join-Path $env:USERPROFILE 'Desktop\Tor Browser'),
        (Join-Path $env:USERPROFILE 'Downloads\Tor Browser')
    )) {
        if ($p -and (Test-Path (Join-Path $p 'Browser\firefox.exe'))) { $roots.Add($p) }
    }
    return ,$roots
}

function Get-DnscryptManifest {
    $repoRoot = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
    $mf = Join-Path $repoRoot 'manifests\dnscrypt-v2.1.7.json'
    if (-not (Test-Path $mf)) { return $null }
    return Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-DnscryptTomlContent {
    return @"
# WG Kill Switch v14 - auto-generated
listen_addresses = ['127.0.0.1:53']
max_clients = 256
ipv6_servers = false
block_ipv6 = true
require_dnssec = false
force_tcp = false
timeout = 5000
keepalive = 30
cert_refresh_delay = 240
log_level = 1
server_names = ['cloudflare', 'quad9-dnsovertls']
bootstrap_resolvers = ['9.9.9.9:53', '1.1.1.1:53']
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

function Install-DnscryptProxy {
    $manifest = Get-DnscryptManifest
    if (-not $manifest) { WARN 'dnscrypt manifest missing'; return $false }
    New-Item -ItemType Directory -Path $script:DNSCRYPT_DIR -Force | Out-Null
    $zip = Join-Path $env:TEMP "dnscrypt-win64-$($manifest.version).zip"
    try {
        if (-not (Test-Path $script:DNSCRYPT_EXE)) {
            Write-Info "Downloading dnscrypt-proxy $($manifest.version)..."
            Invoke-WebRequest -Uri $manifest.url -OutFile $zip -UseBasicParsing -TimeoutSec 120
            $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
            if ($hash -ne $manifest.sha256) {
                Write-Err "dnscrypt SHA256 mismatch (got $hash)"
                return $false
            }
            Expand-Archive -Path $zip -DestinationPath $script:DNSCRYPT_DIR -Force
            $nested = Get-ChildItem $script:DNSCRYPT_DIR -Recurse -Filter $manifest.exe -EA SilentlyContinue | Select-Object -First 1
            if ($nested -and $nested.DirectoryName -ne $script:DNSCRYPT_DIR) {
                Copy-Item $nested.FullName $script:DNSCRYPT_EXE -Force
            }
        }
        if (-not (Test-Path $script:DNSCRYPT_EXE)) { Write-Err 'dnscrypt-proxy.exe not found after extract'; return $false }
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($script:DNSCRYPT_CONF, (Get-DnscryptTomlContent), $enc)
        try {
            icacls $script:DNSCRYPT_DIR /grant 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /grant 'BUILTIN\Administrators:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
        } catch {}
        OK 'dnscrypt-proxy installed'
        return $true
    } catch {
        Write-Err "dnscrypt install failed: $_"
        return $false
    } finally {
        Remove-Item $zip -Force -EA SilentlyContinue
    }
}

function Install-DnscryptService {
    if (-not (Test-Path $script:DNSCRYPT_EXE)) { return $false }
    if (Test-Path $script:NSSM) {
        & $script:NSSM stop $script:DNSCRYPT_SVC 2>$null | Out-Null
        & $script:NSSM remove $script:DNSCRYPT_SVC confirm 2>$null | Out-Null
    }
    & sc.exe stop $script:DNSCRYPT_SVC 2>$null | Out-Null
    & sc.exe delete $script:DNSCRYPT_SVC 2>$null | Out-Null
    Start-Sleep 1
    if (Test-Path $script:NSSM) {
        & $script:NSSM install $script:DNSCRYPT_SVC $script:DNSCRYPT_EXE 2>$null | Out-Null
        & $script:NSSM set $script:DNSCRYPT_SVC AppDirectory $script:DNSCRYPT_DIR 2>$null | Out-Null
        & $script:NSSM set $script:DNSCRYPT_SVC AppParameters "-config `"$script:DNSCRYPT_CONF`"" 2>$null | Out-Null
        & $script:NSSM set $script:DNSCRYPT_SVC Start SERVICE_DELAYED_AUTO_START 2>$null | Out-Null
        & $script:NSSM set $script:DNSCRYPT_SVC DisplayName "WG dnscrypt-proxy" 2>$null | Out-Null
        & $script:NSSM start $script:DNSCRYPT_SVC 2>$null | Out-Null
    } else {
        $bin = "`"$script:DNSCRYPT_EXE`" -config `"$script:DNSCRYPT_CONF`""
        & sc.exe create $script:DNSCRYPT_SVC binPath= $bin start= delayed-auto DisplayName= "WG dnscrypt-proxy" 2>$null | Out-Null
        & sc.exe start $script:DNSCRYPT_SVC 2>$null | Out-Null
    }
    Start-Sleep 2
    $st = & sc.exe query $script:DNSCRYPT_SVC 2>&1 | Out-String
    if ($st -match 'RUNNING') { OK 'WG-DnscryptProxy RUNNING'; return $true }
    WARN 'WG-DnscryptProxy not RUNNING (will retry via guard)'
    return $false
}

function Unlock-WireGuardConfigForWrite {
    if (-not (Test-Path $script:CONFIG)) { return }
    try {
        icacls $script:CONFIG /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
        attrib -R -S -H $script:CONFIG 2>$null | Out-Null
    } catch {}
}

function Set-WireGuardDnsLocalhost {
    if (-not (Test-Path $script:CONFIG)) { return $false }
    Unlock-WireGuardConfigForWrite
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        $hasDns = $false
        foreach ($line in (Get-Content $script:CONFIG -Encoding UTF8)) {
            if ($line -match '^\s*DNS\s*=') {
                $lines.Add('DNS = 127.0.0.1')
                $hasDns = $true
            } else { $lines.Add($line) }
        }
        if (-not $hasDns) { $lines.Add('DNS = 127.0.0.1') }
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($script:CONFIG, $lines, $enc)
        OK 'WireGuard DNS = 127.0.0.1 (dnscrypt)'
        return $true
    } catch {
        WARN "WG DNS update failed: $_"
        return $false
    }
}

function Test-DnscryptHealthy {
    if (-not (Test-Path $script:DNSCRYPT_EXE)) { return $false }
    $st = & sc.exe query $script:DNSCRYPT_SVC 2>&1 | Out-String
    if ($st -notmatch 'RUNNING') { return $false }
    $net = & netstat.exe -ano 2>&1 | Out-String
    return ($net -match '127\.0\.0\.1:53\s+.*LISTENING')
}

function Write-DnscryptGuardPs1 {
    $toml = (Get-DnscryptTomlContent) -replace "'", "''"
    $content = @"
# dnscrypt-guard v$script:WG_KS_VERSION
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$DNSCRYPT_DIR = 'C:\WireGuard\dnscrypt-proxy'
`$DNSCRYPT_EXE = '`$DNSCRYPT_DIR\dnscrypt-proxy.exe'
`$DNSCRYPT_CONF = '`$DNSCRYPT_DIR\dnscrypt-proxy.toml'
`$DNSCRYPT_SVC = 'WG-DnscryptProxy'
`$CONFIG = 'C:\WireGuard\wgcf-profile.conf'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [DNSCRYPT] `$m" -Encoding UTF8 } catch {} }
`$toml = @'
$toml
'@
if (-not (Test-Path `$DNSCRYPT_DIR)) { New-Item -Path `$DNSCRYPT_DIR -ItemType Directory -Force | Out-Null }
if (-not (Test-Path `$DNSCRYPT_CONF)) { `$toml | Set-Content `$DNSCRYPT_CONF -Encoding UTF8 -Force }
`$st = & sc.exe query `$DNSCRYPT_SVC 2>&1 | Out-String
if (`$st -notmatch 'RUNNING') {
    if (Test-Path 'C:\WireGuard\nssm.exe') {
        & 'C:\WireGuard\nssm.exe' start `$DNSCRYPT_SVC 2>`$null | Out-Null
    } else { & sc.exe start `$DNSCRYPT_SVC 2>`$null | Out-Null }
    Start-Sleep 2
}
if (Test-Path `$CONFIG) {
    `$lines = Get-Content `$CONFIG -Encoding UTF8
    `$out = @(); `$has = `$false
    foreach (`$line in `$lines) {
        if (`$line -match '^\s*DNS\s*=') { `$out += 'DNS = 127.0.0.1'; `$has = `$true } else { `$out += `$line }
    }
    if (-not `$has) { `$out += 'DNS = 127.0.0.1' }
    `$enc = New-Object System.Text.UTF8Encoding `$false
    [System.IO.File]::WriteAllLines(`$CONFIG, `$out, `$enc)
}
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'DnscryptState' 'APPLIED' -Force -EA SilentlyContinue
Log 'dnscrypt guard applied'
"@
    $content | Set-Content $script:DNSCRYPT_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:DNSCRYPT_GUARD_PS1 2>$null | Out-Null
}

function Get-TorUserJsContent {
    return @"
user_pref("network.proxy.socks_remote_dns", true);
user_pref("media.peerconnection.enabled", false);
user_pref("privacy.resistFingerprinting.letterboxing", true);
user_pref("dom.security.https_only_mode", true);
user_pref("extensions.torbutton.security_slider", 1);
user_pref("browser.security_level", 1);
user_pref("xpinstall.signatures.required", true);
"@
}

function Write-TorHardeningGuardPs1 {
    $userJs = (Get-TorUserJsContent) -replace "'", "''"
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
Log 'tor hardening guard done'
"@
    $content | Set-Content $script:TOR_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:TOR_GUARD_PS1 2>$null | Out-Null
}

function Write-TorConnectivityMonitorPs1 {
    $content = @"
# tor-connectivity-monitor v$script:WG_KS_VERSION
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
`$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
`$CRISIS = 'C:\WireGuard\tor-crisis.jsonl'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [TOR-MON] `$m" -Encoding UTF8 } catch {} }
function Write-Crisis(`$state, `$detail) {
    `$o = @{ t=(Get-Date -Format 'o'); state=`$state; detail=`$detail } | ConvertTo-Json -Compress
    try { Add-Content `$CRISIS `$o -Encoding UTF8 } catch {}
    Set-ItemProperty `$REG 'TorState' `$state -Force -EA SilentlyContinue
    Set-ItemProperty `$REG 'TorLastError' `$detail -Force -EA SilentlyContinue
}
`$torInstalled = `$false
foreach (`$r in @((Join-Path `$env:ProgramFiles 'Tor Browser'), (Join-Path `$env:LOCALAPPDATA 'Tor Browser'))) {
    if (Test-Path (Join-Path `$r 'Browser\firefox.exe')) { `$torInstalled = `$true; break }
}
if (-not `$torInstalled) {
    Set-ItemProperty `$REG 'TorState' 'NOT_INSTALLED' -Force -EA SilentlyContinue
    exit 0
}
`$socksOk = `$false
try {
    `$tcp = New-Object Net.Sockets.TcpClient
    `$iar = `$tcp.BeginConnect('127.0.0.1', 9150, `$null, `$null)
    if (`$iar.AsyncWaitHandle.WaitOne(2000, `$false)) { try { `$tcp.EndConnect(`$iar); `$socksOk = `$true } catch {} }
    `$tcp.Close()
} catch {}
if (`$socksOk) { Write-Crisis 'HEALTHY' 'SOCKS 9150 listening'; Log 'Tor SOCKS OK' }
else { Write-Crisis 'TOR_DOWN' 'SOCKS 9150 not listening'; Log 'Tor SOCKS down (start Tor Browser for sensitive use)' }
"@
    $content | Set-Content $script:TOR_MONITOR_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:TOR_MONITOR_PS1 2>$null | Out-Null
}

function Write-LeakSentinelPs1 {
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
if (`$hits -gt 0) { Write-Crisis 'DNS_LEAK_SUSPECT' "8.8.8.8 responded `$hits/3"; Log "DNS leak suspect `$hits/3" }
else { Write-Crisis 'HEALTHY' 'no direct 8.8.8.8 DNS'; Log 'DNS leak probe OK' }
`$st = & sc.exe query 'WG-DnscryptProxy' 2>&1 | Out-String
if (`$st -notmatch 'RUNNING') { Write-Crisis 'DNS_PROXY_DOWN' 'WG-DnscryptProxy not running'; Log 'dnscrypt service down' }
"@
    $content | Set-Content $script:LEAK_SENTINEL_PS1 -Encoding UTF8 -Force
    attrib +S +H $script:LEAK_SENTINEL_PS1 2>$null | Out-Null
}

function Write-AllV14GuardScripts {
    Write-DnscryptGuardPs1
    Write-TorHardeningGuardPs1
    Write-TorConnectivityMonitorPs1
    Write-LeakSentinelPs1
}

function Install-TorBrowserHint {
    $roots = Get-TorBrowserRoots
    if ($roots.Count -gt 0) {
        OK ('Tor Browser found: ' + $roots[0])
        return $true
    }
    WARN 'Tor Browser not installed — install from https://www.torproject.org/download/ then re-run -TorUpgradeOnly'
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'TorState' 'NOT_INSTALLED' -Force -EA SilentlyContinue
    return $false
}

function Patch-RepairV14GuardChain {
    $repairPath = 'C:\WireGuard\repair.ps1'
    if (-not (Test-Path $repairPath)) { return $false }
    $raw = [System.IO.File]::ReadAllText($repairPath)
    if ($raw -match 'dnscrypt-guard\.ps1') { return $true }
    $insert = @'

    $wgDns = 'C:\WireGuard\dnscrypt-guard.ps1'
    if (Test-Path $wgDns) { & $wgDns }
    $wgTor = 'C:\WireGuard\tor-hardening-guard.ps1'
    if (Test-Path $wgTor) { & $wgTor }
    $wgTorMon = 'C:\WireGuard\tor-connectivity-monitor.ps1'
    if (Test-Path $wgTorMon) { & $wgTorMon }
    $wgLeak = 'C:\WireGuard\leak-sentinel.ps1'
    if (Test-Path $wgLeak) { & $wgLeak }

'@
    $anchor = 'Repair-ConfigIntegrity'
    if ($raw -notmatch [regex]::Escape($anchor)) { return $false }
    $raw = $raw.Replace("`r`n    $anchor", "$insert    $anchor")
    if ($raw -notmatch 'dnscrypt-guard\.ps1') {
        $raw = $raw.Replace("`n    $anchor", "$insert    $anchor")
    }
    if ($raw -notmatch 'dnscrypt-guard\.ps1') { return $false }
    icacls $repairPath /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
    attrib -R -S -H $repairPath 2>$null | Out-Null
    [System.IO.File]::WriteAllText($repairPath, $raw, [System.Text.UTF8Encoding]::new($false))
    OK 'repair.ps1 patched with v14 guard chain'
    return $true
}

function Invoke-V14DnsLeakStack {
    Write-AllV14GuardScripts
    if (Install-DnscryptProxy) {
        Install-DnscryptService | Out-Null
        Set-WireGuardDnsLocalhost | Out-Null
        & $script:DNSCRYPT_GUARD_PS1 2>$null
    }
    Patch-RepairV14GuardChain | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14DnsLeak' '1' -Force -EA SilentlyContinue
}

function Invoke-V14TorStack {
    Write-TorHardeningGuardPs1
    Write-TorConnectivityMonitorPs1
    Install-TorBrowserHint | Out-Null
    if (Test-Path $script:TOR_GUARD_PS1) { & $script:TOR_GUARD_PS1 }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14Tor' '1' -Force -EA SilentlyContinue
}

function Invoke-V14FullPrivacyStack {
    Invoke-V14DnsLeakStack
    Invoke-V14TorStack
    Write-LeakSentinelPs1
    if (Test-Path $script:LEAK_SENTINEL_PS1) { & $script:LEAK_SENTINEL_PS1 }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'V14Enabled' '1' -Force -EA SilentlyContinue
}

function Test-V14DnsLeakHealthy {
    return (Test-DnscryptHealthy)
}

function Test-V14TorPresent {
    return ((Get-TorBrowserRoots).Count -gt 0)
}

function Extend-ScriptIntegrityVaultV14 {
    foreach ($f in @(
        $script:DNSCRYPT_GUARD_PS1, $script:TOR_GUARD_PS1,
        $script:TOR_MONITOR_PS1, $script:LEAK_SENTINEL_PS1
    )) {
        if (-not (Test-Path $f)) { continue }
        $leaf = Split-Path $f -Leaf
        $hash = (Get-FileHash -Path $f -Algorithm SHA256).Hash
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' "Hash_$leaf" $hash -Force
    }
}

function Test-ScriptIntegrityVaultV14 {
    if (-not (Test-ScriptIntegrityVault)) { return $false }
    foreach ($pair in @(
        @{ File = $script:DNSCRYPT_GUARD_PS1; Key = 'Hash_dnscrypt-guard.ps1' },
        @{ File = $script:LEAK_SENTINEL_PS1; Key = 'Hash_leak-sentinel.ps1' }
    )) {
        if (-not (Test-Path $pair.File)) { continue }
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
        $expected = $reg.$($pair.Key)
        if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
        $actual = (Get-FileHash -Path $pair.File -Algorithm SHA256).Hash
        if ($actual -ne $expected) { return $false }
    }
    return $true
}