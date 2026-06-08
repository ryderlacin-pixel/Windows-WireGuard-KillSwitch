# Dot-sourced from install.ps1 - Install-MainSteps-18-20.ps1 (v15.1)
#Requires -Version 5.1

function Invoke-InstallMainSteps18to20 {
Write-Step "STEP 18 - DEFENDER EXCLUSION"
# ================================================================
try {
    $defJob = Start-Job { param($p) Add-MpPreference -ExclusionPath $p -EA Stop } -ArgumentList $INSTALL_DIR
    if (Wait-Job $defJob -Timeout 25) {
        Receive-Job $defJob | Out-Null
        OK "Defender exclusion: $INSTALL_DIR"
    } else {
        Stop-Job $defJob -EA SilentlyContinue
        WARN "Defender exclusion timed out (skipped)"
    }
    Remove-Job $defJob -Force -EA SilentlyContinue
} catch { WARN "Defender exclusion failed" }

# ================================================================
Write-Step "STEP 18b - PRIVACY HARDENING"
# ================================================================
try { Install-PrivacyHardening } catch { WARN "Privacy hardening failed: $_" }
if (Test-Path $PRIVACY_GUARD_PS1) { OK "privacy-hardening-guard.ps1: deployed" } else { WARN "privacy-hardening-guard.ps1: missing" }
if (Test-Path $WEBRTC_GUARD_PS1) { OK "webrtc-leak-guard.ps1: deployed" } else { WARN "webrtc-leak-guard.ps1: missing" }
if (Test-ScriptIntegrityVault) { OK "Script integrity vault: seeded" } else { Write-Info "Script integrity vault: finalizes at STEP 19" }

# ================================================================
Write-Step "STEP 18c - V14 DNS LEAK STACK (dnscrypt-proxy)"
# ================================================================
if (Get-Command Invoke-V14DnsLeakStack -EA SilentlyContinue) {
    try { Invoke-V14DnsLeakStack } catch { WARN "v14 DNS leak stack failed: $_" }
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK "dnscrypt-proxy: healthy" }
        else { WARN "dnscrypt-proxy: service not healthy yet (guard will retry)" }
    }
} else { WARN "v14 DNS stack skipped (install-v14-stack.ps1 missing)" }

# ================================================================
Write-Step "STEP 18d - V14 TOR HARDENING"
# ================================================================
if (Get-Command Invoke-V14TorStack -EA SilentlyContinue) {
    try { Invoke-V14TorStack } catch { WARN "v14 Tor stack failed: $_" }
    if (Get-Command Test-V14TorPresent -EA SilentlyContinue) {
        if (Test-V14TorPresent) { OK "Tor Browser: present" }
        else { WARN "Tor Browser: not installed (manual install from torproject.org)" }
    }
} else { WARN "v14 Tor stack skipped" }

# ================================================================
Write-Step "STEP 18e - V14 LEAK SENTINEL (read-only probe)"
# ================================================================
if (Test-Path $LEAK_SENTINEL_PS1) {
    if (Get-Command Invoke-GuardScriptSafe -EA SilentlyContinue) {
        Invoke-GuardScriptSafe -Path $LEAK_SENTINEL_PS1 -Label 'leak-sentinel' | Out-Null
    } else { & $LEAK_SENTINEL_PS1 2>$null }
    $leakSt = (Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name LeakState -EA SilentlyContinue).LeakState
    if ($leakSt -eq 'HEALTHY') { OK "leak-sentinel: HEALTHY" }
    elseif ($leakSt) { WARN "leak-sentinel: $leakSt" }
    else { OK "leak-sentinel: probe completed" }
} else { WARN "leak-sentinel.ps1 missing" }

# ================================================================
Write-Step "STEP 18f - V15 STRONG PRIVACY STACK"
# ================================================================
if (Get-Command Invoke-V15StrongPrivacyStack -EA SilentlyContinue) {
    try { Invoke-V15StrongPrivacyStack } catch { WARN "v15 strong privacy stack failed: $_" }
    if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
        if ((Get-Command Test-InstallInProgress -EA SilentlyContinue) -and (Test-InstallInProgress)) {
            WARN 'System DNS lock: deferred until install completes (internet protected)'
        } elseif (Test-V15DnsLockdownHealthy) { OK "System DNS lock: all adapters 127.0.0.1" }
        else { WARN "System DNS lock: incomplete (guard will retry)" }
    }
    if (Get-Command Test-V15NetworkPrivacyHealthy -EA SilentlyContinue) {
        if (Test-V15NetworkPrivacyHealthy) { OK "Network privacy: LLMNR disabled" }
        else { WARN "Network privacy: LLMNR may still be on" }
    }
} else { WARN "v15 strong privacy stack skipped" }

# ================================================================
Write-Step "STEP 19 - ACTIVATE MONITOR + CLEAR INSTALL LOCK"
# ================================================================
Ensure-TunnelForInstall | Out-Null
Ensure-DelayedAutoStart
Disable-TunnelIPv6BindingsOnly
Remove-KurtarArtifacts
New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'EnableFailsafe' ([int]$script:EnableFailsafe) -Type DWord -Force
Set-BootGraceRegistry -Seconds $script:BOOT_GRACE_SEC
Set-PostInstallGraceRegistry -Minutes 15
Clear-InstallLock
OK "Install lock cleared - $($script:BOOT_GRACE_SEC)s BootGrace + 15min post-install grace (fail-open)"
$repoRoot = Split-Path $PSScriptRoot -Parent
$emerBat = Join-Path $repoRoot 'emergency-reset.bat'
$emerPs1 = Join-Path $repoRoot 'scripts\emergency-reset.ps1'
if (Test-Path $emerPs1) {
    Copy-Item $emerPs1 "$INSTALL_DIR\emergency-reset.ps1" -Force
    OK "emergency-reset.ps1 deployed to $INSTALL_DIR"
}
if (Test-Path $emerBat) {
    Copy-Item $emerBat "$INSTALL_DIR\emergency-reset.bat" -Force
    OK "emergency-reset.bat deployed to $INSTALL_DIR"
}
Write-GuardBackups
Install-ScriptIntegrityVault
if (Get-Command Refresh-RegistryTaskBackups -EA SilentlyContinue) {
    if (Refresh-RegistryTaskBackups) { OK 'Registry task backups refreshed' }
    else { WARN 'Registry task backups: partial export' }
}
OK "Guard vault + integrity vault finalized (before services start)"
Stop-AllMonitorProcs
Remove-Item "$INSTALL_DIR\monitor.pid" -Force -EA SilentlyContinue
if (Test-Path $NSSM) {
    & $NSSM start $WG_SVC_NAME 2>$null | Out-Null
    Start-Sleep 3
    $svcStatus = & sc.exe query $WG_SVC_NAME 2>$null | Out-String
    if ($svcStatus -match 'RUNNING') { OK 'WGKillSwitchSvc: RUNNING (delayed-auto)' }
    else { WARN 'WGKillSwitchSvc: start pending - repair layers still active' }
}
Write-Info "Monitor start delayed 45s (post-install stability window)..."
Start-Sleep -Seconds 45
Start-HiddenScript $MONITOR_PS1
Start-Sleep 5
if (-not (Test-SafeToOpen)) {
    Remove-InstallBlocks
    WARN "Tunnel not healthy yet - blocks OFF; monitor will recover."
} else {
    OK "Tunnel + internet OK - monitor taking over"
}

# ================================================================
Write-Step "STEP 20 - FINAL CHECK"
# ================================================================
if (Get-Command Invoke-DeferredPrivacyGuards -EA SilentlyContinue) {
    Invoke-DeferredPrivacyGuards
}
Install-ScriptIntegrityVault
if (Get-Command Refresh-RegistryTaskBackups -EA SilentlyContinue) { Refresh-RegistryTaskBackups | Out-Null }
$warnings = 0
if (Test-TunnelRunning) { OK "Tunnel: RUNNING" } else { WARN "Tunnel: DOWN (monitor will recover)"; $warnings++ }
if (Test-SafeToOpen) {
    OK "Health: tunnel + internet verified (SafeToOpen)"
} elseif (Test-TunnelRunning) {
    OK "Health: zombie protected (tunnel up, block should be active)"
    foreach ($br in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        if (Test-FirewallRuleEnabled $br) { OK "Block rule active: $br" }
        else { WARN "Block rule missing: $br"; $warnings++ }
    }
} else {
    OK "Health: tunnel down (block rules expected)"
}

$g1 = Get-ScheduledTask -TaskName $TASK_MONITOR -EA SilentlyContinue
$g2 = Get-ScheduledTask -TaskName $TASK_REPAIR  -EA SilentlyContinue
if ($g1) { OK "WG-KillSwitch task: $($g1.State)" }  else { Write-Err "WG-KillSwitch task MISSING"; $warnings++ }
if ($g2) {
    $tc = ($g2.Triggers | Measure-Object).Count
    if ($tc -ge 2) { OK "WG-RepairTask: $($g2.State) ($tc triggers)" }
    else { WARN "WG-RepairTask: $tc trigger(s) (expected 2)"; $warnings++ }
} else { Write-Err "WG-RepairTask MISSING"; $warnings++ }

$gRv = Get-ScheduledTask -TaskName $TASK_REBOOT_VERIFY -EA SilentlyContinue
if ($gRv -and $gRv.State -in @('Ready','Running')) { OK "WG-RebootVerify task: $($gRv.State)" }
else { WARN "WG-RebootVerify task missing or disabled"; $warnings++ }
if (Test-Path $REBOOT_VERIFY_PS1) { OK "post-reboot-verify.ps1: present" } else { WARN "post-reboot-verify.ps1: missing"; $warnings++ }

$gWd = Get-ScheduledTask -TaskName $TASK_WATCHDOG -EA SilentlyContinue
if ($gWd -and $gWd.State -in @('Ready','Running')) { OK "WG-InternetWatchdog task: $($gWd.State)" }
else { WARN "WG-InternetWatchdog task missing or disabled"; $warnings++ }
if (Test-Path $WATCHDOG_PS1) { OK "internet-watchdog.ps1: present" } else { WARN "internet-watchdog.ps1: missing"; $warnings++ }

$proc = $null
for ($monWait = 0; $monWait -lt 12; $monWait++) {
    $proc = Get-MonitorShellProcs
    if ($proc) { break }
    Start-Sleep -Seconds 2
}
if (($proc | Measure-Object).Count -gt 1) {
    $proc | Sort-Object Id | Select-Object -SkipLast 1 | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
    Start-Sleep 2
    $proc = Get-MonitorShellProcs
}
if ($proc) { OK "Monitor: active (PID: $(($proc | Select-Object -First 1).Id))" }
else        { WARN "Monitor: not yet running (repair task will start it)" }

$svcSt = & sc.exe query $WG_SVC_NAME 2>$null
if ($svcSt -match "RUNNING")   { OK "WGKillSwitchSvc: RUNNING" }
elseif (Test-Path $NSSM)        { WARN "WGKillSwitchSvc: not running"; $warnings++ }
else                            { WARN "WGKillSwitchSvc: NSSM absent, skipped" }

Ensure-DelayedAutoStart
if (Test-DelayedAutoStart) { OK "Tunnel service: delayed-auto-start enforced" }
else { WARN "Tunnel service: delayed-auto not confirmed (sc qc)"; $warnings++ }

if (Test-WmiSubscriptionActive) { OK "WMI Subscription: ACTIVE (filter+consumer+binding)" }
else { WARN "WMI Subscription: missing or incomplete"; $warnings++ }
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut: present" } else { WARN "Startup shortcut: missing"; $warnings++ }
if (Test-Path $GPO_SCRIPT)  { OK "GPO script: present" }       else { WARN "GPO script: missing";       $warnings++ }
if (Test-Path $ANTI_TAMPER_PS1) { OK "anti-tamper.ps1: present" } else { WARN "anti-tamper.ps1: missing"; $warnings++ }
if (Test-Path $GUARD_DIR) {
    $guardN = (Get-ChildItem $GUARD_DIR -File -Force -EA SilentlyContinue | Measure-Object).Count
    if ($guardN -ge 5) { OK "Guard vault: $guardN files" } else { WARN "Guard vault: only $guardN file(s)"; $warnings++ }
} else { WARN "Guard vault: missing"; $warnings++ }

$reg = Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" -EA SilentlyContinue
if ($reg.TaskXML -and $reg.TaskXMLRepair) { OK "Registry backup: v$($reg.Version)" } else { WARN "Registry backup: incomplete"; $warnings++ }

$ipv6Rule = Get-NetFirewallRule -DisplayName "KS-Block-IPv6-Out" -EA SilentlyContinue
if ($ipv6Rule -and $ipv6Rule.Enabled -eq "True") { OK "IPv6 block: ACTIVE" } else { WARN "IPv6 block: inactive"; $warnings++ }

$dnsRule    = Get-NetFirewallRule -DisplayName "KS-DNS-Block"     -EA SilentlyContinue
$dnsTcpRule = Get-NetFirewallRule -DisplayName "KS-DNS-Block-TCP" -EA SilentlyContinue
if ($dnsRule -and $dnsTcpRule) { OK "DNS leak protection: ACTIVE (UDP+TCP)" } else { WARN "DNS leak protection: incomplete"; $warnings++ }

$wgExeRule = Get-NetFirewallRule -DisplayName "KS-WireGuard-EXE" -EA SilentlyContinue
if ($wgExeRule) { OK "WireGuard EXE rule: ACTIVE" } else { WARN "WireGuard EXE rule: missing"; $warnings++ }

if (Test-Path $LOG) { attrib -H -S -R $LOG 2>$null | Out-Null }
OK "killswitch.log: accessible"

$defExcl = (Get-MpPreference -EA SilentlyContinue).ExclusionPath
if ($defExcl -contains $INSTALL_DIR) { OK "Defender exclusion: ACTIVE" } else { WARN "Defender exclusion: inactive" }

foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
    if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
    else { WARN "Browser privacy: $($pair[1]) incomplete"; $warnings++ }
}
if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" } else { WARN "Windows telemetry: not confirmed"; $warnings++ }
if (Test-Path $PRIVACY_GUARD_PS1) { OK "privacy-hardening-guard.ps1: present" } else { WARN "privacy-hardening-guard.ps1: missing"; $warnings++ }
if (Test-Path $WEBRTC_GUARD_PS1) { OK "webrtc-leak-guard.ps1: present" } else { WARN "webrtc-leak-guard.ps1: missing"; $warnings++ }
if (Test-Path $DNSCRYPT_GUARD_PS1) { OK "dnscrypt-guard.ps1: present" } else { WARN "dnscrypt-guard.ps1: missing"; $warnings++ }
if (Test-Path $LEAK_SENTINEL_PS1) { OK "leak-sentinel.ps1: present" } else { WARN "leak-sentinel.ps1: missing"; $warnings++ }
if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
    if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: RUNNING + 127.0.0.1:53' }
    else { WARN "dnscrypt-proxy: not healthy"; $warnings++ }
}
if (Test-Path $DNS_LOCKDOWN_GUARD_PS1) { OK "dns-lockdown-guard.ps1: present" } else { WARN "dns-lockdown-guard.ps1: missing"; $warnings++ }
if (Test-Path $NETWORK_PRIVACY_GUARD_PS1) { OK "network-privacy-guard.ps1: present" } else { WARN "network-privacy-guard.ps1: missing"; $warnings++ }
$dnscryptFw = Get-NetFirewallRule -DisplayName "KS-Dnscrypt-EXE" -EA SilentlyContinue
if ($dnscryptFw) { OK "KS-Dnscrypt-EXE firewall rule: ACTIVE" } else { WARN "KS-Dnscrypt-EXE firewall rule: missing"; $warnings++ }
if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
    if (Test-V15DnsLockdownHealthy) { OK "System DNS lock: healthy" }
    else { WARN "System DNS lock: not confirmed"; $warnings++ }
}
$torSt = (Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -Name TorState -EA SilentlyContinue).TorState
if ($torSt -eq 'NOT_INSTALLED') { WARN "Tor Browser: not installed (optional)" }
elseif ($torSt) { OK "Tor state: $torSt" }
if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" } else { WARN "Script integrity vault: mismatch"; $warnings++ }

if ($CUSTOM_MODE) { OK "Mode: Custom server ($CustomEndpointIP)" } else { OK "Mode: Cloudflare WARP" }

Log "install.ps1 v$WG_KS_VERSION completed"
Write-Host ""
if ($warnings -eq 0) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  INSTALL COMPLETE - SYSTEM FULLY PROTECTED (v$WG_KS_VERSION)            " -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Green
} else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  INSTALL COMPLETE - $warnings WARNING(S) - see above          " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log: C:\WireGuard\killswitch.log" -ForegroundColor Gray
Write-Host "  Stuck internet: WG-InternetWatchdog auto-unbricks (every 1min)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Protection layers:" -ForegroundColor White
Write-Host "  [1] WireGuard tunnel: delayed-auto-start"           -ForegroundColor DarkGray
Write-Host "  [2] WGKillSwitchSvc (NSSM): delayed-auto-start"    -ForegroundColor DarkGray
Write-Host "  [3] WG-KillSwitch task: 60s boot delay"            -ForegroundColor DarkGray
Write-Host "  [4] WG-RepairTask: 30s boot delay + every 2min"    -ForegroundColor DarkGray
Write-Host "  [5] WMI Event Subscription: powershell death watch" -ForegroundColor DarkGray
Write-Host "  [6] Startup folder shortcut"                        -ForegroundColor DarkGray
Write-Host "  [7] GPO Machine Startup Script"                     -ForegroundColor DarkGray
Write-Host "  [8] HKLM Run key"                                   -ForegroundColor DarkGray
Write-Host "  [9] WG-RebootVerify: auto audit 5min after boot"   -ForegroundColor DarkGray
Write-Host "  [10] WG-InternetWatchdog: auto-unbrick every 1min"  -ForegroundColor DarkGray
Write-Host "  [+] Anti-tamper guard: silent restore from vault"  -ForegroundColor DarkGray
Write-Host "  [+] Privacy hardening: cookies/fingerprint/telemetry/ads" -ForegroundColor DarkGray
Write-Host "  [+] dnscrypt-proxy: encrypted DNS via 127.0.0.1 (WG DNS)" -ForegroundColor DarkGray
Write-Host "  [+] Tor hardening: user.js (start Tor Browser manually)" -ForegroundColor DarkGray
Write-Host "  [+] leak-sentinel: read-only DNS leak probe (no firewall changes)" -ForegroundColor DarkGray
Write-Host "  [+] v15 DNS lockdown: all adapters -> 127.0.0.1, DoH off" -ForegroundColor DarkGray
Write-Host "  [+] v15 network privacy: LLMNR/NetBIOS disabled" -ForegroundColor DarkGray
Write-Host "  [+] Sensitive mode: Hassas-Tarama.lnk (Tor Browser only)" -ForegroundColor DarkGray
Write-Host "  Reboot log: C:\WireGuard\reboot-verify.log"         -ForegroundColor DarkGray
Write-Host ""
if ($CUSTOM_MODE) {
    Write-Host "  Custom server usage example:" -ForegroundColor White
    Write-Host "  .\install.ps1 -CustomConfig C:\myvpn.conf -CustomTunnel myvpn -CustomEndpointIP 1.2.3.4/32 -CustomPort 51820" -ForegroundColor DarkGray
    Write-Host ""
}
if (-not $NoPause) { pause }


}
