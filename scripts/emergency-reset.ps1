#Requires -RunAsAdministrator
# WG Kill Switch — one-click emergency network recovery (v15.2)
$ErrorActionPreference = 'Continue'
$log = 'C:\WireGuard\emergency-reset.log'

function Write-Log([string]$m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $m"
    Write-Host $line
    try { Add-Content $log $line -Encoding UTF8 -EA SilentlyContinue } catch {}
}

Write-Log '=== EMERGENCY RESET START ==='

Write-Log 'Removing KS-* firewall rules...'
$removed = 0
foreach ($rule in @(
    'KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out',
    'KS-Block-IPv6-Out','KS-Block-IPv6-In','KS-LAN-Out','KS-LAN-In',
    'KS-DHCP-Out','KS-DHCP-In','KS-DHCP-Bcast-Out','KS-DHCP-Server-In',
    'KS-Gateway-Out','KS-Gateway-In','KS-WARP-Server-Out','KS-Loopback-Out','KS-Loopback-In',
    'KS-DNS-Allow','KS-DNS-Block','KS-DNS-Block-TCP','KS-WireGuard-EXE','KS-Dnscrypt-EXE'
)) {
    netsh advfirewall firewall delete rule name="$rule" 2>$null | Out-Null
    $removed++
}
Get-NetFirewallRule -DisplayName 'KS-*' -EA SilentlyContinue | ForEach-Object {
    Remove-NetFirewallRule -Name $_.Name -EA SilentlyContinue
    $removed++
}
Write-Log "Removed $removed KS rule references"

Write-Log 'Resetting Windows Firewall...'
netsh advfirewall reset 2>$null | Out-Null

Write-Log 'Resetting IP stack and Winsock...'
netsh int ip reset 2>$null | Out-Null
netsh winsock reset 2>$null | Out-Null

Write-Log 'Re-enabling physical adapters and bindings...'
$tunnelPatterns = @('WireGuard', 'wintun', 'Wintun', 'AllDebrid')
foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
    $isTunnel = $false
    foreach ($p in $tunnelPatterns) {
        if ("$($a.Name) $($a.InterfaceDescription)" -match [regex]::Escape($p)) { $isTunnel = $true; break }
    }
    if ($isTunnel) { continue }
    try { Enable-NetAdapter -Name $a.Name -Confirm:$false -EA SilentlyContinue | Out-Null } catch {}
    foreach ($comp in @('ms_tcpip', 'ms_tcpip6', 'ms_lldp', 'ms_lltdio', 'ms_rspndr', 'ms_server', 'ms_msclient', 'ms_pacer', 'ms_mslldp')) {
        try { Enable-NetAdapterBinding -Name $a.Name -ComponentID $comp -EA SilentlyContinue | Out-Null } catch {}
    }
    Write-Log "Physical adapter restored: $($a.Name)"
}

try {
    New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'UnbrickUntil' (Get-Date).AddMinutes(30).ToString('o') -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'BootGraceUntil' (Get-Date).AddMinutes(30).ToString('o') -Force
    Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
} catch {}

Write-Log '=== EMERGENCY RESET COMPLETE — reboot recommended ==='
Write-Host ''
Write-Host 'Reboot your PC to fully restore the network stack.' -ForegroundColor Yellow
pause