# Dot-sourced from install.ps1 - Install-SafeNetwork.ps1 (v15.2 boot-safety)
#Requires -Version 5.1

$script:BOOT_SAFE_WINDOW_SEC = 90
$script:BOOT_GRACE_SEC       = 90
$script:SAFETY_MODULE_PATH   = 'C:\WireGuard\wg-safety.ps1'
$script:TUNNEL_ADAPTER_PATTERNS = @('WireGuard', 'wintun', 'Wintun', 'AllDebrid')

if (-not (Get-Variable -Name InstallDryRun -Scope Script -ErrorAction SilentlyContinue)) {
    $script:InstallDryRun = $false
}
if (-not (Get-Variable -Name EnableFailsafe -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EnableFailsafe = $true
}

function Get-OsUptimeSeconds {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
        return [int][Math]::Max(0, ((Get-Date) - $boot).TotalSeconds)
    } catch { return 99999 }
}

function Test-BootSafeWindow {
    return (Get-OsUptimeSeconds) -lt $script:BOOT_SAFE_WINDOW_SEC
}

function Test-IsVirtualTunnelAdapter {
    param(
        [string]$Name,
        [string]$Description = ''
    )
    $haystack = "$Name $Description"
    foreach ($pattern in $script:TUNNEL_ADAPTER_PATTERNS) {
        if ($haystack -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

function Assert-AdapterMutationAllowed {
    param(
        [string]$Name,
        [string]$Description = '',
        [string]$Operation = 'mutate'
    )
    if (Test-IsVirtualTunnelAdapter $Name $Description) { return $true }
    $msg = "BLOCKED: $Operation on physical adapter '$Name' (whitelist: WireGuard/wintun/AllDebrid only)"
    if (Get-Command Log -ErrorAction SilentlyContinue) { Log $msg }
    elseif (Get-Command Write-Info -ErrorAction SilentlyContinue) { Write-Info $msg }
    return $false
}

function Write-SafeActionLog([string]$Message) {
    if ($script:InstallDryRun) {
        $line = "[DRY-RUN] $Message"
        if (Get-Command Write-Info -ErrorAction SilentlyContinue) { Write-Info $line }
        if (Get-Command Log -ErrorAction SilentlyContinue) { Log $line }
        return
    }
    if (Get-Command Log -ErrorAction SilentlyContinue) { Log $Message }
}

function Invoke-SafeNetsh {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Reason = ''
    )
    $detail = if ($Reason) { " ($Reason)" } else { '' }
    if ($script:InstallDryRun) {
        Write-SafeActionLog "Would run: $Command$detail"
        return
    }
    # FIXED: Use cmd.exe /c instead of Invoke-Expression to reduce injection surface
    # (all Command strings in this project are internally generated and trusted)
    cmd.exe /c $Command 2>$null | Out-Null
}

function Invoke-SafeRegistrySet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        $Type,
        [switch]$Force,
        [string]$Reason = ''
    )
    $detail = if ($Reason) { " ($Reason)" } else { '' }
    if ($script:InstallDryRun) {
        $typStr = if ($PSBoundParameters.ContainsKey('Type')) { [string]$Type } else { 'default' }
        Write-SafeActionLog "Would set registry ${Path}\${Name} = $Value (type $typStr)$detail"
        return
    }
    $setArgs = @{
        Path  = $Path
        Name  = $Name
        Value = $Value
    }
    if ($PSBoundParameters.ContainsKey('Type')) { $setArgs.Type = $Type }
    if ($Force) { $setArgs.Force = $true }
    Set-ItemProperty @setArgs
}

function Get-LocalGatewaySubnets {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($cidr in @('192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12')) {
        if (-not $list.Contains($cidr)) { $list.Add($cidr) | Out-Null }
    }
    try {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | ForEach-Object {
            $hop = [string]$_.NextHop
            if ([string]::IsNullOrWhiteSpace($hop) -or $hop -eq '0.0.0.0') { return }
            if (-not $list.Contains($hop)) { $list.Add($hop) | Out-Null }
            $octets = $hop -split '\.'
            if ($octets.Count -eq 4) {
                $subnet = "$($octets[0]).$($octets[1]).$($octets[2]).0/24"
                if (-not $list.Contains($subnet)) { $list.Add($subnet) | Out-Null }
            }
        }
    } catch {}
    return $list
}

function Add-KillSwitchFirewallExemptions {
    param([string]$ServerIPs = '', [string]$ServerPort = '')

    $dhcpRules = @(
        'netsh advfirewall firewall add rule name="KS-DHCP-Out" dir=out action=allow protocol=UDP localport=68 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-In" dir=in action=allow protocol=UDP localport=68 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-Bcast-Out" dir=out action=allow protocol=UDP localport=68 remoteip=255.255.255.255 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-Server-In" dir=in action=allow protocol=UDP remoteport=67 localport=68 enable=yes'
    )
    foreach ($cmd in $dhcpRules) {
        Invoke-SafeNetsh $cmd 'DHCP exemption'
    }

    $gwList = Get-LocalGatewaySubnets
    if ($gwList.Count -gt 0) {
        $gwCsv = ($gwList -join ',')
        Invoke-SafeNetsh "netsh advfirewall firewall add rule name=`"KS-Gateway-Out`" dir=out action=allow remoteip=$gwCsv enable=yes" 'gateway subnet out'
        Invoke-SafeNetsh "netsh advfirewall firewall add rule name=`"KS-Gateway-In`" dir=in action=allow remoteip=$gwCsv enable=yes" 'gateway subnet in'
    }

    Invoke-SafeNetsh 'netsh advfirewall firewall add rule name="KS-LAN-Out" dir=out action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes' 'LAN out'
    Invoke-SafeNetsh 'netsh advfirewall firewall add rule name="KS-LAN-In" dir=in action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes' 'LAN in'
    Invoke-SafeNetsh 'netsh advfirewall firewall add rule name="KS-Loopback-Out" dir=out action=allow remoteip=127.0.0.0/8 enable=yes' 'loopback out'
    Invoke-SafeNetsh 'netsh advfirewall firewall add rule name="KS-Loopback-In" dir=in action=allow remoteip=127.0.0.0/8 enable=yes' 'loopback in'

    if ($ServerIPs) {
        Invoke-SafeNetsh "netsh advfirewall firewall add rule name=`"KS-WARP-Server-Out`" dir=out action=allow protocol=UDP remoteip=$ServerIPs remoteport=$ServerPort enable=yes" 'WARP server'
    }
}

function Add-KillSwitchCatchAllBlocks {
    $blocks = @(
        'netsh advfirewall firewall add rule name="KS-Block-WiFi-Out" dir=out action=block interfacetype=wireless remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes'
        'netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out" dir=out action=block interfacetype=lan remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes'
        'netsh advfirewall firewall add rule name="KS-Block-RemoteAccess-Out" dir=out action=block interfacetype=remoteaccess remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes'
        'netsh advfirewall firewall add rule name="KS-Block-PPP-Out" dir=out action=block interfacetype=ppp remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes'
    )
    foreach ($cmd in $blocks) {
        Invoke-SafeNetsh $cmd 'catch-all block'
    }
}

function Disable-TunnelIPv6BindingsOnly {
    if ($script:InstallDryRun) {
        try {
            foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
                if (Test-IsVirtualTunnelAdapter $a.Name $a.InterfaceDescription) {
                    Write-SafeActionLog "Would disable IPv6 binding on tunnel adapter '$($a.Name)' only"
                }
            }
        } catch {}
        Write-SafeActionLog 'Would skip all physical adapters (hardware whitelist enforced)'
        return
    }
    try {
        foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
            if (-not (Test-IsVirtualTunnelAdapter $a.Name $a.InterfaceDescription)) { continue }
            & netsh interface ipv6 set interface "$($a.Name)" disabled 2>$null | Out-Null
            try {
                Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -EA SilentlyContinue | Out-Null
            } catch {}
        }
    } catch {}
}

function Disable-AllIPv6Bindings {
    Disable-TunnelIPv6BindingsOnly
}

function Enable-AllPhysicalAdapters {
    try {
        foreach ($a in (Get-NetAdapter -EA SilentlyContinue)) {
            if (Test-IsVirtualTunnelAdapter $a.Name $a.InterfaceDescription) { continue }
            try { Enable-NetAdapter -Name $a.Name -Confirm:$false -EA SilentlyContinue | Out-Null } catch {}
            foreach ($comp in @('ms_tcpip', 'ms_tcpip6', 'ms_lldp', 'ms_lltdio', 'ms_rspndr', 'ms_server', 'ms_msclient', 'ms_pacer')) {
                try { Enable-NetAdapterBinding -Name $a.Name -ComponentID $comp -EA SilentlyContinue | Out-Null } catch {}
            }
        }
    } catch {}
}

function Invoke-FailOpenSafeguard {
    param(
        [string]$Reason = 'fail-open safeguard',
        [string]$LogPrefix = '[INSTALL]'
    )
    if (Get-Command Remove-InstallBlocks -ErrorAction SilentlyContinue) {
        Remove-InstallBlocks
    }
    if ($script:InstallDryRun) {
        Write-SafeActionLog "$LogPrefix $Reason (would fail-open)"
        return
    }
    try {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'UnbrickUntil' (Get-Date).AddMinutes(10).ToString('o') -Force
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'BootGraceUntil' (Get-Date).AddSeconds($script:BOOT_GRACE_SEC).ToString('o') -Force
        Remove-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'InstallInProgress' -EA SilentlyContinue
        netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=no 2>$null | Out-Null
        netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=no 2>$null | Out-Null
    } catch {}
    if (Get-Command Log -ErrorAction SilentlyContinue) { Log "$LogPrefix $Reason" }
    elseif (Get-Command Write-Err -ErrorAction SilentlyContinue) { Write-Err "$LogPrefix $Reason" }
}

function Set-BootGraceRegistry {
    param([int]$Seconds = $script:BOOT_GRACE_SEC)
    if ($script:InstallDryRun) {
        Write-SafeActionLog "Would set BootGraceUntil for ${Seconds}s (uptime $(Get-OsUptimeSeconds)s)"
        return
    }
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
        $graceEnd = $boot.AddSeconds($Seconds)
        if ((Get-Date) -lt $graceEnd) { $graceEnd = (Get-Date).AddSeconds($Seconds) }
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'BootGraceUntil' $graceEnd.ToString('o') -Force
    } catch {}
}

function Set-PostInstallGraceRegistry {
    param([int]$Minutes = 60)
    if ($script:InstallDryRun) {
        Write-SafeActionLog "Would set PostInstallGraceUntil for ${Minutes}min"
        return
    }
    try {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'PostInstallGraceUntil' (Get-Date).AddMinutes($Minutes).ToString('o') -Force
    } catch {}
}

function Set-KillSwitchArmedRegistry {
    param([bool]$Armed = $true)
    if ($script:InstallDryRun) {
        Write-SafeActionLog "Would set KillSwitchArmed=$([int]$Armed)"
        return
    }
    try {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'KillSwitchArmed' ([int]$Armed) -Type DWord -Force
    } catch {}
}

function Get-WgSafetyRuntimeScript {
    param([string]$Version = '15.2')
    $bootSec = $script:BOOT_SAFE_WINDOW_SEC
    $graceSec = $script:BOOT_GRACE_SEC
    return @"
# WG Kill Switch runtime safety module v$Version (auto-generated)
`$script:BOOT_SAFE_WINDOW_SEC = $bootSec
`$script:BOOT_GRACE_SEC = $graceSec
`$script:TUNNEL_ADAPTER_PATTERNS = @('WireGuard', 'wintun', 'Wintun', 'AllDebrid')
`$REG_KEY = 'HKLM:\SOFTWARE\WGKillSwitch'
`$LOG = 'C:\WireGuard\killswitch.log'

function Get-EnableFailsafe {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name EnableFailsafe -EA SilentlyContinue
        if (`$null -ne `$reg.EnableFailsafe) { return ([int]`$reg.EnableFailsafe -ne 0) }
    } catch {}
    return `$true
}
`$script:EnableFailsafe = Get-EnableFailsafe

function Get-OsUptimeSeconds {
    try {
        `$boot = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
        return [int][Math]::Max(0, ((Get-Date) - `$boot).TotalSeconds)
    } catch { return 99999 }
}

function Test-BootSafeWindow {
    return (Get-OsUptimeSeconds) -lt `$script:BOOT_SAFE_WINDOW_SEC
}

function Test-IsVirtualTunnelAdapter {
    param([string]`$Name, [string]`$Description = '')
    `$haystack = "`$Name `$Description"
    foreach (`$pattern in `$script:TUNNEL_ADAPTER_PATTERNS) {
        if (`$haystack -match [regex]::Escape(`$pattern)) { return `$true }
    }
    return `$false
}

function Assert-AdapterMutationAllowed {
    param([string]`$Name, [string]`$Description = '', [string]`$Operation = 'mutate')
    if (Test-IsVirtualTunnelAdapter `$Name `$Description) { return `$true }
    return `$false
}

function Get-LocalGatewaySubnets {
    `$list = [System.Collections.Generic.List[string]]::new()
    foreach (`$cidr in @('192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12')) {
        if (-not `$list.Contains(`$cidr)) { `$list.Add(`$cidr) | Out-Null }
    }
    try {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | ForEach-Object {
            `$hop = [string]`$_.NextHop
            if ([string]::IsNullOrWhiteSpace(`$hop) -or `$hop -eq '0.0.0.0') { return }
            if (-not `$list.Contains(`$hop)) { `$list.Add(`$hop) | Out-Null }
            `$octets = `$hop -split '\.'
            if (`$octets.Count -eq 4) {
                `$subnet = "`$(`$octets[0]).`$(`$octets[1]).`$(`$octets[2]).0/24"
                if (-not `$list.Contains(`$subnet)) { `$list.Add(`$subnet) | Out-Null }
            }
        }
    } catch {}
    return `$list
}

function Add-KillSwitchFirewallExemptions {
    param([string]`$ServerIPs = '', [string]`$ServerPort = '')
    `$dhcpRules = @(
        'netsh advfirewall firewall add rule name="KS-DHCP-Out" dir=out action=allow protocol=UDP localport=68 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-In" dir=in action=allow protocol=UDP localport=68 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-Bcast-Out" dir=out action=allow protocol=UDP localport=68 remoteip=255.255.255.255 remoteport=67 enable=yes'
        'netsh advfirewall firewall add rule name="KS-DHCP-Server-In" dir=in action=allow protocol=UDP remoteport=67 localport=68 enable=yes'
    )
    foreach (`$cmd in `$dhcpRules) { cmd.exe /c `$cmd 2>`$null | Out-Null }
    `$gwList = Get-LocalGatewaySubnets
    if (`$gwList.Count -gt 0) {
        `$gwCsv = (`$gwList -join ',')
        netsh advfirewall firewall delete rule name="KS-Gateway-Out" 2>`$null | Out-Null
        netsh advfirewall firewall delete rule name="KS-Gateway-In" 2>`$null | Out-Null
        netsh advfirewall firewall add rule name="KS-Gateway-Out" dir=out action=allow remoteip=`$gwCsv enable=yes | Out-Null
        netsh advfirewall firewall add rule name="KS-Gateway-In" dir=in action=allow remoteip=`$gwCsv enable=yes | Out-Null
    }
    netsh advfirewall firewall add rule name="KS-LAN-Out" dir=out action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes 2>`$null | Out-Null
    netsh advfirewall firewall add rule name="KS-LAN-In" dir=in action=allow remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 enable=yes 2>`$null | Out-Null
    if (`$ServerIPs -and `$ServerPort) {
        netsh advfirewall firewall delete rule name="KS-WARP-Server-Out" 2>`$null | Out-Null
        netsh advfirewall firewall add rule name="KS-WARP-Server-Out" dir=out action=allow protocol=UDP remoteip=`$ServerIPs remoteport=`$ServerPort enable=yes | Out-Null
    }
}

function Test-BootGrace {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name BootGraceUntil -EA SilentlyContinue
        if (`$reg.BootGraceUntil -and (Get-Date) -lt [datetime]`$reg.BootGraceUntil) { return `$true }
    } catch {}
    return `$false
}

function Test-UnbrickActive {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name UnbrickUntil -EA SilentlyContinue
        if (`$reg.UnbrickUntil -and (Get-Date) -lt [datetime]`$reg.UnbrickUntil) { return `$true }
    } catch {}
    return `$false
}

function Test-PostInstallGrace {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name PostInstallGraceUntil -EA SilentlyContinue
        if (`$reg.PostInstallGraceUntil -and (Get-Date) -lt [datetime]`$reg.PostInstallGraceUntil) { return `$true }
    } catch {}
    return `$false
}

function Test-InstallInProgress {
    if (Test-Path 'C:\WireGuard\install.inprogress') { return `$true }
    try {
        `$reg = Get-ItemProperty `$REG_KEY -EA SilentlyContinue
        return (`$reg.InstallInProgress -eq 1)
    } catch { return `$false }
}

function Test-KillSwitchArmed {
    try {
        `$reg = Get-ItemProperty `$REG_KEY -Name KillSwitchArmed -EA SilentlyContinue
        return (`$reg.KillSwitchArmed -eq 1)
    } catch {}
    return `$false
}

function Test-BlockAllowed {
    if (-not (Test-KillSwitchArmed)) { return `$false }
    if (Test-InstallInProgress -or Test-UnbrickActive -or Test-BootGrace -or Test-PostInstallGrace -or (Test-BootSafeWindow)) { return `$false }
    return `$true
}

function Restore-DhcpDnsOnPhysicalAdapters {
    `$fixed = 0
    foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
        if (-not (Assert-AdapterMutationAllowed `$a.Name `$a.InterfaceDescription 'dns-restore')) { continue }
        netsh interface ipv4 set dnsservers name="`$(`$a.Name)" source=dhcp 2>`$null | Out-Null
        if (`$LASTEXITCODE -eq 0) { `$fixed++ }
    }
    Clear-DnsClientCache -EA SilentlyContinue
    return `$fixed
}

function Disable-KillSwitchBlock {
    foreach (`$r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        netsh advfirewall firewall delete rule name="`$r" 2>`$null | Out-Null
    }
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=no 2>`$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=no 2>`$null | Out-Null
}

function Enable-KillSwitchBlock {
    param([string]`$ServerIPs = '', [string]`$ServerPort = '', [string]`$LogPrefix = '[SAFE]')
    if (-not (Test-BlockAllowed)) {
        `$uptime = Get-OsUptimeSeconds
        Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | `$LogPrefix Block deferred (uptime `${uptime}s / boot-grace) - internet stays open" -Encoding UTF8 -EA SilentlyContinue
        return `$false
    }
    Add-KillSwitchFirewallExemptions -ServerIPs `$ServerIPs -ServerPort `$ServerPort
    foreach (`$r in @('KS-Block-WiFi-Out','KS-Block-Ethernet-Out','KS-Block-RemoteAccess-Out','KS-Block-PPP-Out')) {
        netsh advfirewall firewall delete rule name="`$r" 2>`$null | Out-Null
    }
    netsh advfirewall firewall add rule name="KS-Block-WiFi-Out" dir=out action=block interfacetype=wireless remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-Ethernet-Out" dir=out action=block interfacetype=lan remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-RemoteAccess-Out" dir=out action=block interfacetype=remoteaccess remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall add rule name="KS-Block-PPP-Out" dir=out action=block interfacetype=ppp remoteip=0.0.0.0/1,128.0.0.0/1 enable=yes | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block" new enable=yes 2>`$null | Out-Null
    netsh advfirewall firewall set rule name="KS-DNS-Block-TCP" new enable=yes 2>`$null | Out-Null
    return `$true
}

function Set-BootGraceFromUptime {
    try {
        `$boot = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
        `$graceEnd = `$boot.AddSeconds(`$script:BOOT_GRACE_SEC)
        if ((Get-Date) -lt `$graceEnd) {
            New-Item -Path `$REG_KEY -Force | Out-Null
            Set-ItemProperty `$REG_KEY 'BootGraceUntil' `$graceEnd.ToString('o') -Force
            return `$graceEnd
        }
    } catch {}
    return `$null
}

function Invoke-FailOpenSafeguard {
    param([string]`$Reason = 'fail-open safeguard', [string]`$LogPrefix = '[SAFE]')
    Disable-KillSwitchBlock
    Clear-DnsClientCache -EA SilentlyContinue
    try {
        New-Item -Path `$REG_KEY -Force | Out-Null
        Set-ItemProperty `$REG_KEY 'UnbrickUntil' (Get-Date).AddMinutes(10).ToString('o') -Force
        Set-ItemProperty `$REG_KEY 'BootGraceUntil' (Get-Date).AddSeconds(`$script:BOOT_GRACE_SEC).ToString('o') -Force
        Remove-ItemProperty `$REG_KEY 'InstallInProgress' -EA SilentlyContinue
    } catch {}
    Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | `$LogPrefix `$Reason" -Encoding UTF8 -EA SilentlyContinue
}

function Disable-TunnelIPv6BindingsOnly {
    try {
        foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
            if (-not (Test-IsVirtualTunnelAdapter `$a.Name `$a.InterfaceDescription)) { continue }
            & netsh interface ipv6 set interface "`$(`$a.Name)" disabled 2>`$null | Out-Null
            try { Disable-NetAdapterBinding -Name `$a.Name -ComponentID ms_tcpip6 -EA SilentlyContinue | Out-Null } catch {}
        }
    } catch {}
}

function Enable-AllPhysicalAdapters {
    try {
        foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
            if (Test-IsVirtualTunnelAdapter `$a.Name `$a.InterfaceDescription) { continue }
            try { Enable-NetAdapter -Name `$a.Name -Confirm:`$false -EA SilentlyContinue | Out-Null } catch {}
            foreach (`$comp in @('ms_tcpip', 'ms_tcpip6', 'ms_lldp', 'ms_lltdio', 'ms_rspndr', 'ms_server', 'ms_msclient', 'ms_pacer')) {
                try { Enable-NetAdapterBinding -Name `$a.Name -ComponentID `$comp -EA SilentlyContinue | Out-Null } catch {}
            }
        }
    } catch {}
}
"@
}

function Invoke-DeployWgSafetyModule {
    param([string]$Version = $WG_KS_VERSION)
    $content = Get-WgSafetyRuntimeScript -Version $Version
    if ($script:InstallDryRun) {
        Write-SafeActionLog "Would write $($script:SAFETY_MODULE_PATH) (runtime safety module)"
        return
    }
    New-Item -ItemType Directory -Path (Split-Path $script:SAFETY_MODULE_PATH) -Force | Out-Null
    [System.IO.File]::WriteAllText($script:SAFETY_MODULE_PATH, $content, [System.Text.UTF8Encoding]::new($false))
}