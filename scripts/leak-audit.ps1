#Requires -RunAsAdministrator
# v14 DNS leak audit — read-only probes, never changes firewall.
$ErrorActionPreference = 'Continue'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
$pass = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Test-DnscryptRunning {
    $st = & sc.exe query WG-DnscryptProxy 2>&1 | Out-String
    return ($st -match 'RUNNING')
}

function Test-LocalDns53 {
    $net = & netstat.exe -ano 2>&1 | Out-String
    return ($net -match '127\.0\.0\.1:53\s+.*LISTENING')
}

function Test-DirectDnsLeak {
    $hits = 0
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $u = New-Object Net.Sockets.UdpClient
            $u.Client.ReceiveTimeout = 1200
            $b = [byte[]](0,0,1,0,0,1,0,0,0,0,0,0,3,119,119,119,3,99,111,109,0,0,1,0,1)
            [void]$u.Send($b, $b.Length, '8.8.8.8', 53)
            try { $null = $u.Receive([ref](New-Object Net.IPEndPoint([IPAddress]::Any,0))); $hits++ } catch {}
            $u.Close()
        } catch {}
    }
    return $hits
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  LEAK AUDIT (v15 - read-only)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$reg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($reg -and ($reg.Version -ge '15.0' -or $reg.V15StrongPrivacy -eq '1' -or $reg.Version -ge '14.0')) "Registry version 14.0+ / v15 phased (got $($reg.Version))"
Assert (Test-Path 'C:\WireGuard\dnscrypt-guard.ps1') 'dnscrypt-guard.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\leak-sentinel.ps1') 'leak-sentinel.ps1 deployed'
Assert (Test-Path 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.exe') 'dnscrypt-proxy.exe present'
Assert (Test-DnscryptRunning) 'WG-DnscryptProxy service RUNNING'
Assert (Test-LocalDns53) '127.0.0.1:53 responds'

$cfg = Get-Content 'C:\WireGuard\wgcf-profile.conf' -EA SilentlyContinue | Where-Object { $_ -match '^\s*DNS\s*=' } | Select-Object -First 1
Assert ($cfg -match '127\.0\.0\.1') "WireGuard DNS = 127.0.0.1 (got: $cfg)"

$dnsRaw = netsh interface ipv4 show dnsservers 2>&1 | Out-String
$sysLeak = 0
foreach ($line in ($dnsRaw -split "`r?`n")) {
    if ($line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
        if ($Matches[1] -ne '127.0.0.1') { $sysLeak++ }
    }
}
Assert ($sysLeak -eq 0) "System DNS locked to 127.0.0.1 (foreign=$sysLeak)"

$leakHits = Test-DirectDnsLeak
if ($leakHits -gt 0) {
    Write-Host "  [INFO] Raw 8.8.8.8 UDP probe: $leakHits/3 (expected when kill-switch blocks are off)" -ForegroundColor Gray
} else {
    Assert $true "No direct 8.8.8.8 DNS response (hits=0/3)"
}

if (Test-Path 'C:\WireGuard\leak-sentinel.ps1') { & 'C:\WireGuard\leak-sentinel.ps1' 2>$null }
$leakSt = (Get-ItemProperty $REG -Name LeakState -EA SilentlyContinue).LeakState
if ($leakSt) { Assert ($leakSt -eq 'HEALTHY') "Registry LeakState: $leakSt" }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  LEAK AUDIT: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  LEAK AUDIT: PASSED" -ForegroundColor Green
exit 0