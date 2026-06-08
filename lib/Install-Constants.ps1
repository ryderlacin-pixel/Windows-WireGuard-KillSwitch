# Dot-sourced from install.ps1 - Install-Constants.ps1 (v15.1 modular split)
#Requires -Version 5.1
$WG_KS_VERSION = '15.2.7'

# -- Paths --
$INSTALL_DIR = "C:\WireGuard"
$CONFIG      = "C:\WireGuard\wgcf-profile.conf"
$LOG         = "C:\WireGuard\killswitch.log"
$MONITOR_PS1 = "C:\WireGuard\monitor.ps1"
$REPAIR_PS1  = "C:\WireGuard\repair.ps1"
$SERVICE_PS1 = "C:\WireGuard\service-monitor.ps1"
$WMI_WRAPPER = "C:\WireGuard\wmi-repair.ps1"
$WG_EXE      = "C:\Program Files\WireGuard\wireguard.exe"
$WGCF_EXE    = "$INSTALL_DIR\wgcf.exe"
$NSSM        = "$INSTALL_DIR\nssm.exe"

# -- Names --
$TUNNEL_NAME  = "wgcf-profile"
$TUNNEL_SVC   = 'WireGuardTunnel$' + $TUNNEL_NAME
$TASK_MONITOR = "WG-KillSwitch"
$TASK_REPAIR  = "WG-RepairTask"
$TASK_REBOOT_VERIFY = "WG-RebootVerify"
$TASK_WATCHDOG    = "WG-InternetWatchdog"
$REBOOT_VERIFY_PS1  = "$INSTALL_DIR\post-reboot-verify.ps1"
$WATCHDOG_PS1     = "$INSTALL_DIR\internet-watchdog.ps1"
$WG_SVC_NAME  = "WGKillSwitchSvc"
$WMI_FILTER   = "WGMonitorFilter"
$WMI_CONSUMER = "WGMonitorConsumer"
$STARTUP_LNK  = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WGKillSwitch.lnk"
$GPO_SCRIPT_DIR = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup"
$GPO_SCRIPT   = "$GPO_SCRIPT_DIR\wg-startup.ps1"
$GPO_INI_DIR  = "C:\Windows\System32\GroupPolicy\Machine\Scripts"
$GPO_INI      = "$GPO_INI_DIR\scripts.ini"
$INSTALL_LOCK = "$INSTALL_DIR\install.inprogress"
$GUARD_DIR    = 'C:\ProgramData\WGKillSwitchGuard'
$ANTI_TAMPER_PS1 = "$INSTALL_DIR\anti-tamper.ps1"
$WEBRTC_GUARD_PS1 = "$INSTALL_DIR\webrtc-leak-guard.ps1"
$PRIVACY_GUARD_PS1 = "$INSTALL_DIR\privacy-hardening-guard.ps1"
$DNSCRYPT_DIR      = "$INSTALL_DIR\dnscrypt-proxy"
$DNSCRYPT_EXE      = "$DNSCRYPT_DIR\dnscrypt-proxy.exe"
$DNSCRYPT_CONF     = "$DNSCRYPT_DIR\dnscrypt-proxy.toml"
$DNSCRYPT_SVC      = 'WG-DnscryptProxy'
$DNSCRYPT_GUARD_PS1 = "$INSTALL_DIR\dnscrypt-guard.ps1"
$TOR_GUARD_PS1     = "$INSTALL_DIR\tor-hardening-guard.ps1"
$TOR_MONITOR_PS1   = "$INSTALL_DIR\tor-connectivity-monitor.ps1"
$LEAK_SENTINEL_PS1 = "$INSTALL_DIR\leak-sentinel.ps1"
$DNS_LOCKDOWN_GUARD_PS1 = "$INSTALL_DIR\dns-lockdown-guard.ps1"
$NETWORK_PRIVACY_GUARD_PS1 = "$INSTALL_DIR\network-privacy-guard.ps1"
$SENSITIVE_MODE_PS1 = "$INSTALL_DIR\sensitive-mode.ps1"

$script:WG_KS_VERSION = $WG_KS_VERSION
$script:CONFIG = $CONFIG
$script:NSSM = $NSSM
$script:DNSCRYPT_DIR = $DNSCRYPT_DIR
$script:DNSCRYPT_EXE = $DNSCRYPT_EXE
$script:DNSCRYPT_CONF = $DNSCRYPT_CONF
$script:DNSCRYPT_SVC = $DNSCRYPT_SVC
$script:DNSCRYPT_GUARD_PS1 = $DNSCRYPT_GUARD_PS1
$script:TOR_GUARD_PS1 = $TOR_GUARD_PS1
$script:TOR_MONITOR_PS1 = $TOR_MONITOR_PS1
$script:LEAK_SENTINEL_PS1 = $LEAK_SENTINEL_PS1
$script:DNS_LOCKDOWN_GUARD_PS1 = $DNS_LOCKDOWN_GUARD_PS1
$script:NETWORK_PRIVACY_GUARD_PS1 = $NETWORK_PRIVACY_GUARD_PS1
$script:INSTALL_DIR = $INSTALL_DIR

# -- Custom mode (full validation in STEP 0) --
$CUSTOM_MODE = ($CustomConfig -ne "")
if ($CUSTOM_MODE) {
    Write-Host " [--] Custom server mode active" -ForegroundColor Cyan
}
