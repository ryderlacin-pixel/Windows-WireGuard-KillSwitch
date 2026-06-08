# Dot-sourced from install.ps1 - Install-UpgradePaths.ps1 (v15.1)
#Requires -Version 5.1

function Invoke-InstallUpgradeEarlyExit {
if ($PrivacyUpgradeOnly) {
    Write-Step "PRIVACY UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    OK "webrtc-leak-guard.ps1 forwarder written"
    Install-PrivacyHardening
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" }
    else { WARN "Windows telemetry: not confirmed"; $upgWarn++ }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart browsers for policy changes. Cloudflare still sees WARP traffic." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    return $true
}

if ($DnsLeakUpgradeOnly) {
    Write-Step "DNS LEAK UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    if (-not (Get-Command Invoke-V14DnsLeakStack -EA SilentlyContinue)) {
        Write-Err "v14 stack not loaded"; exit 1
    }
    Invoke-V14DnsLeakStack
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: healthy (127.0.0.1:53)' }
        else { WARN 'dnscrypt-proxy: not healthy yet - check WG-DnscryptProxy service'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "dns leak upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  DNS LEAK UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  DNS LEAK UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart WireGuard tunnel to apply DNS=127.0.0.1" -ForegroundColor Gray
    Write-Host "  Run: .\scripts\leak-audit.ps1 then .\scripts\safe-live-verify.ps1" -ForegroundColor Gray
    if (-not $NoPause) { pause }
    return $true
}

if ($TorUpgradeOnly) {
    Write-Step "TOR UPGRADE ONLY (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    if (-not (Get-Command Invoke-V14TorStack -EA SilentlyContinue)) {
        Write-Err "v14 stack not loaded"; exit 1
    }
    Invoke-V14TorStack
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    if (Get-Command Test-V14TorPresent -EA SilentlyContinue) {
        if (Test-V14TorPresent) { OK "Tor Browser: installed" }
        else { WARN 'Tor Browser: not found - install manually from torproject.org'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "tor upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  TOR UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  TOR UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Start Tor Browser for sensitive browsing only. Cloudflare still sees WARP entry." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    return $true
}

if ($FullPrivacyUpgrade) {
    Write-Step "FULL PRIVACY UPGRADE (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    Install-PrivacyHardening
    if (Get-Command Invoke-V14FullPrivacyStack -EA SilentlyContinue) {
        Invoke-V14FullPrivacyStack
    } else { WARN 'v14 stack not loaded - dnscrypt/Tor/leak-sentinel skipped' }
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Test-WindowsTelemetryReduced) { OK "Windows telemetry: reduced (not eliminated)" }
    else { WARN "Windows telemetry: not confirmed"; $upgWarn++ }
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK "dnscrypt-proxy: healthy" }
        else { WARN "dnscrypt-proxy: not healthy"; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "full privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  FULL PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  FULL PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Restart WG tunnel + browsers. Tor = sensitive use only." -ForegroundColor Gray
    if (-not $NoPause) { pause }
    return $true
}

if ($StrongPrivacyUpgrade) {
    Write-Step "STRONG PRIVACY UPGRADE (v$WG_KS_VERSION)"
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    Write-PrivacyHardeningGuardPs1
    OK "privacy-hardening-guard.ps1 written"
    $webrtcForwarder = @'
# WebRTC forwarder (v'@ + $WG_KS_VERSION + @')
$ErrorActionPreference = 'SilentlyContinue'
$main = Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'privacy-hardening-guard.ps1'
if (Test-Path $main) { & $main }
'@
    $webrtcForwarder | Set-Content $WEBRTC_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $WEBRTC_GUARD_PS1 2>$null | Out-Null
    Install-PrivacyHardening
    if (Get-Command Invoke-V15StrongPrivacyStack -EA SilentlyContinue) {
        Invoke-V15StrongPrivacyStack
    } else { Write-Err 'v15 stack not loaded'; exit 1 }
    Write-GuardBackups
    Install-ScriptIntegrityVault
    $upgWarn = 0
    foreach ($pair in @(@('Google\Chrome','Chrome'), @('Microsoft\Edge','Edge'), @('BraveSoftware\Brave','Brave'))) {
        if (Test-PrivacyChromiumPolicy $pair[0]) { OK "Browser privacy: $($pair[1])" }
        else { WARN "Browser privacy: $($pair[1]) incomplete"; $upgWarn++ }
    }
    if (Get-Command Test-V14DnsLeakHealthy -EA SilentlyContinue) {
        if (Test-V14DnsLeakHealthy) { OK 'dnscrypt-proxy: healthy' }
        else { WARN 'dnscrypt-proxy: not healthy'; $upgWarn++ }
    }
    if (Get-Command Test-V15DnsLockdownHealthy -EA SilentlyContinue) {
        if (Test-V15DnsLockdownHealthy) { OK 'System DNS lock: all adapters 127.0.0.1' }
        else { WARN 'System DNS lock: incomplete'; $upgWarn++ }
    }
    if (Get-Command Test-V15NetworkPrivacyHealthy -EA SilentlyContinue) {
        if (Test-V15NetworkPrivacyHealthy) { OK 'Network privacy: LLMNR off' }
        else { WARN 'Network privacy: LLMNR still enabled'; $upgWarn++ }
    }
    if (Test-ScriptIntegrityVault) { OK "Script integrity vault: verified" }
    else { WARN "Script integrity vault: mismatch or missing"; $upgWarn++ }
    try { Log "strong privacy upgrade v$WG_KS_VERSION completed" } catch {}
    Write-Host ""
    if ($upgWarn -eq 0) {
        Write-Host "  STRONG PRIVACY UPGRADE COMPLETE (v$WG_KS_VERSION)" -ForegroundColor Green
    } else {
        Write-Host "  STRONG PRIVACY UPGRADE COMPLETE - $upgWarn warning(s)" -ForegroundColor Yellow
    }
    Write-Host "  Run: .\scripts\privacy-audit.ps1 then .\scripts\safe-live-verify.ps1" -ForegroundColor Gray
    Write-Host "  Sensitive browsing: desktop Hassas-Tarama.lnk or sensitive-mode.ps1" -ForegroundColor Gray
    if (-not $NoPause) { pause }
    return $true
}

    return $false
}
