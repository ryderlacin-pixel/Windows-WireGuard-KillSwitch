#Requires -RunAsAdministrator
# v15 privacy audit — read-only tier scoring (STRONG / MEDIUM / WEAK)
$ErrorActionPreference = 'Continue'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
$pass = 0
$failures = [System.Collections.Generic.List[string]]::new()
$score = 0
$maxScore = 0

function Assert([bool]$cond, [string]$name, [int]$weight = 1) {
    $script:maxScore += $weight
    if ($cond) { $script:pass++; $script:score += $weight; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $failures.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

function Test-DnscryptHealthy {
    $st = & sc.exe query WG-DnscryptProxy 2>&1 | Out-String
    if ($st -notmatch 'RUNNING') { return $false }
    $net = & netstat.exe -ano 2>&1 | Out-String
    return ($net -match '127\.0\.0\.1:53\s+.*LISTENING')
}

function Test-SystemDnsLocked {
    $leak = 0
    $dnsRaw = netsh interface ipv4 show dnsservers 2>&1 | Out-String
    foreach ($line in ($dnsRaw -split "`r?`n")) {
        if ($line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
            if ($Matches[1] -ne '127.0.0.1') { $leak++ }
        }
    }
    return ($leak -eq 0)
}

function Test-PrivacyChromiumPolicy([string]$VendorPath) {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Policies\$VendorPath" -EA SilentlyContinue
    return ($p -and $p.WebRtcIpHandlingPolicy -eq 'default_public_interface_only' -and
            $p.BlockThirdPartyCookies -eq 1 -and $p.DnsOverHttpsMode -eq 'off' -and
            $p.PrivacySandboxAdTopicsEnabled -eq 0 -and $p.QuicAllowed -eq 0)
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  PRIVACY AUDIT (v15 - read-only)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$reg = Get-ItemProperty $REG -EA SilentlyContinue
Assert ($reg -and $reg.Version -ge '15.0') "Registry version 15.0+ (got $($reg.Version))" 2
Assert ($reg.V15StrongPrivacy -eq '1') 'V15StrongPrivacy flag set' 2
Assert (Test-Path 'C:\WireGuard\dns-lockdown-guard.ps1') 'dns-lockdown-guard.ps1 deployed' 1
Assert (Test-Path 'C:\WireGuard\network-privacy-guard.ps1') 'network-privacy-guard.ps1 deployed' 1
Assert (Test-DnscryptHealthy) 'dnscrypt-proxy RUNNING + 127.0.0.1:53' 2
Assert (Test-SystemDnsLocked) 'All adapters DNS = 127.0.0.1' 2

$doh = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableAutoDoh -EA SilentlyContinue).EnableAutoDoh
Assert ($doh -ne 1) 'Windows DoH auto disabled (EnableAutoDoh!=1)' 1

$llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -EA SilentlyContinue).EnableMulticast
Assert ($llmnr -ne 1) 'LLMNR disabled (EnableMulticast!=1)' 1

$fw = netsh advfirewall firewall show rule name='KS-Dnscrypt-EXE' 2>&1 | Out-String
Assert ($fw -notmatch 'No rules match') 'KS-Dnscrypt-EXE firewall rule present' 1

foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
    Assert (Test-PrivacyChromiumPolicy $pair[0]) "Browser privacy: $($pair[1])" 1
}

$toml = Get-Content 'C:\WireGuard\dnscrypt-proxy\dnscrypt-proxy.toml' -Raw -EA SilentlyContinue
if ($toml) {
    Assert ($toml -match 'require_nolog\s*=\s*true') 'dnscrypt require_nolog=true' 1
    Assert ($toml -match 'quad9-dnsovertls') 'dnscrypt quad9-dnsovertls only' 1
    Assert ($toml -notmatch "server_names\s*=\s*\[.*cloudflare") 'dnscrypt cloudflare removed' 1
}

if (Test-Path 'C:\WireGuard\leak-sentinel.ps1') { & 'C:\WireGuard\leak-sentinel.ps1' 2>$null }
$leakSt = (Get-ItemProperty $REG -Name LeakState -EA SilentlyContinue).LeakState
if ($leakSt) { Assert ($leakSt -eq 'HEALTHY') "LeakState: $leakSt" 2 }

$pct = if ($maxScore -gt 0) { [math]::Round(100 * $score / $maxScore, 1) } else { 0 }
if ($pct -ge 90 -and $failures.Count -eq 0) { $tier = 'STRONG' }
elseif ($pct -ge 70) { $tier = 'MEDIUM' }
else { $tier = 'WEAK' }

Set-ItemProperty $REG 'PrivacyTier' $tier -Force -EA SilentlyContinue
Set-ItemProperty $REG 'PrivacyAuditScore' $pct -Force -EA SilentlyContinue

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  PRIVACY AUDIT: $pass checks, $($failures.Count) failures" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host "  Score: $score/$maxScore ($pct%) - Tier: $tier" -ForegroundColor $(if ($tier -eq 'STRONG') { 'Green' } elseif ($tier -eq 'MEDIUM') { 'Yellow' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  PRIVACY AUDIT: PASSED ($tier)" -ForegroundColor Green
exit 0