# Dot-sourced from install.ps1 - Install-TasksAndWmi.ps1 (v15.1)
#Requires -Version 5.1

function Invoke-InstallTasksAndWmi {
Write-Step "STEP 11 - MAIN SCHEDULED TASK (60s boot delay)"
# ================================================================
Remove-TaskFully $TASK_MONITOR
$monTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MONITOR_PS1`""
if (Register-TaskViaSchtasks $TASK_MONITOR $monTr '/SC ONSTART /DELAY 0001:00') {
    OK "WG-KillSwitch task registered - start deferred to STEP 19"
} else { Write-Err "WG-KillSwitch task registration FAILED!" }

# ================================================================
Write-Step "STEP 12 - REPAIR TASK (30s boot delay + every 2min)"
# ================================================================
# Repair cadence: every 2min; repair.ps1 enforces ExecutionTimeLimit Minutes 15 per run
Remove-TaskFully $TASK_REPAIR
$repTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
if (Register-TaskViaSchtasks $TASK_REPAIR $repTr '/SC MINUTE /MO 2') {
    OK "WG-RepairTask registered - every 2min"
} else { Write-Err "WG-RepairTask registration FAILED!" }

# ================================================================
Write-Step "STEP 12b - POST-REBOOT VERIFY TASK (5min boot delay)"
# ================================================================
$repoScripts = Join-Path $PSScriptRoot 'scripts'
$rebootVerifySrc = Join-Path $repoScripts 'post-reboot-verify.ps1'
if (Test-Path $rebootVerifySrc) {
    Copy-Item $rebootVerifySrc $REBOOT_VERIFY_PS1 -Force
    OK "post-reboot-verify.ps1 deployed"
} else {
    WARN "post-reboot-verify.ps1 source missing in repo"
}
Remove-TaskFully $TASK_REBOOT_VERIFY
$rvTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REBOOT_VERIFY_PS1`""
if (Register-TaskViaSchtasks $TASK_REBOOT_VERIFY $rvTr '/SC ONSTART /DELAY 0005:00') {
    OK "WG-RebootVerify task registered - 5min after boot"
} else { WARN "WG-RebootVerify task registration failed" }

# ================================================================
Write-Step "STEP 12c - INTERNET WATCHDOG TASK (every 3min)"
# ================================================================
Remove-TaskFully $TASK_WATCHDOG
$wdTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WATCHDOG_PS1`""
if (Register-TaskViaSchtasks $TASK_WATCHDOG $wdTr '/SC MINUTE /MO 1') {
    OK "WG-InternetWatchdog registered - every 1min"
} else { WARN "WG-InternetWatchdog task registration failed" }

# ================================================================
Write-Step "STEP 13 - REGISTRY BACKUP + FOLDER PROTECTION"
# ================================================================
try {
    $acl = Get-Acl $INSTALL_DIR -EA Stop
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM",   "FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl",    "ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users",         "ReadAndExecute", "ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl -Path $INSTALL_DIR -AclObject $acl -EA Stop
    Get-ChildItem $INSTALL_DIR -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'killswitch.log' } |
        ForEach-Object { attrib +S +H $_.FullName 2>$null | Out-Null }
    OK "ACL set + files hidden"
} catch { WARN "ACL/hide skipped: $_" }

New-Item -Path "HKLM:\SOFTWARE\WGKillSwitch" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "Version"       $WG_KS_VERSION                      -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "EnableFailsafe" ([int]$script:EnableFailsafe) -Type DWord -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ScriptsPath"  (Join-Path $PSScriptRoot 'scripts')   -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TunnelName"   $TUNNEL_NAME                        -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "MonitorPath"   $MONITOR_PS1                        -Force
Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RepairPath"    $REPAIR_PS1                         -Force
$taskXml = Export-TaskXmlSafe $TASK_MONITOR
if ($taskXml) {
    $taskXml | Set-Content "$INSTALL_DIR\WG-KillSwitch-backup.xml" -Encoding UTF8 -Force
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($taskXml))
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TaskXML"       $b64                                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ScriptsPath"  (Join-Path $PSScriptRoot 'scripts') -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "RebootVerifyPath" $REBOOT_VERIFY_PS1             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "InstalledDate" (Get-Date -f "yyyy-MM-dd HH:mm:ss") -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "CustomMode"    ([bool]$CUSTOM_MODE)                -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ConfigPath"    $CONFIG                             -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "TunnelName"    $TUNNEL_NAME                        -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerIP"      $(if ($CUSTOM_MODE) { $CustomEndpointIP } else { $serverIPs }) -Force
    Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" "ServerPort"    (Get-ServerPort)                    -Force
    OK "Registry backup written"
} else { WARN "WG-KillSwitch task XML export failed" }
foreach ($pair in @(
    @{ Name = 'TaskXMLRepair'; Task = $TASK_REPAIR },
    @{ Name = 'TaskXMLRebootVerify'; Task = $TASK_REBOOT_VERIFY },
    @{ Name = 'TaskXMLWatchdog'; Task = $TASK_WATCHDOG }
)) {
    $tx = Export-TaskXmlSafe $pair.Task
    if ($tx) {
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tx))
        Set-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" $pair.Name $b64 -Force
    }
}

$runKeyValue = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "WGKillSwitchGuard" $runKeyValue -Force
OK "Registry Run key added"

& sc.exe failure $TUNNEL_SVC reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
OK "WireGuard tunnel crash recovery configured"

# ================================================================
Write-Step "STEP 14 - WINDOWS SERVICE (NSSM)"
# ================================================================
if (Test-Path $NSSM) {
    & $NSSM install    $WG_SVC_NAME powershell.exe 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppParameters "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SERVICE_PS1`"" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME Start          SERVICE_DELAYED_AUTO_START 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME ObjectName     LocalSystem 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME DisplayName    "WG KillSwitch Guard" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME Description    "WireGuard Kill Switch - auto-generated" 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppExit        Default Restart 2>$null | Out-Null
    & $NSSM set        $WG_SVC_NAME AppRestartDelay 5000 2>$null | Out-Null
    & sc.exe failure   $WG_SVC_NAME reset=60 actions=restart/5000/restart/10000/restart/30000 2>$null | Out-Null
    & sc.exe sdset     $WG_SVC_NAME "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)" 2>$null | Out-Null
    OK "WGKillSwitchSvc: installed (start deferred to STEP 19)"
} else { WARN "NSSM not available - service layer skipped" }

# ================================================================
Write-Step "STEP 15 - WMI SUBSCRIPTION"
# ================================================================
if (Install-WmiSubscription) { OK "WMI Event Subscription active" }
else { WARN "WMI Subscription failed - 7 other layers still active" }

# ================================================================
Write-Step "STEP 16 - STARTUP FOLDER SHORTCUT"
# ================================================================
New-Item -ItemType Directory -Path (Split-Path $STARTUP_LNK) -Force -EA SilentlyContinue | Out-Null
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($STARTUP_LNK)
$lnk.TargetPath       = "powershell.exe"
$lnk.Arguments        = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
$lnk.WorkingDirectory = $INSTALL_DIR
$lnk.Save()
if (Test-Path $STARTUP_LNK) { OK "Startup shortcut created" } else { WARN "Startup shortcut failed" }

# ================================================================
Write-Step "STEP 17 - GPO BOOT SCRIPT"
# ================================================================
New-Item -ItemType Directory -Path $GPO_SCRIPT_DIR -Force -EA SilentlyContinue | Out-Null
$gpoTunnelSvc = $TUNNEL_SVC
$gpoKsVersion = $WG_KS_VERSION
$gpoTunnelName = $TUNNEL_NAME
$gpoContent = @"
# WG KillSwitch GPO Boot Script v$gpoKsVersion (auto-generated by install.ps1)
`$LOG        = 'C:\WireGuard\killswitch.log'
`$REPAIR     = 'C:\WireGuard\repair.ps1'
`$TUNNEL_SVC = '$gpoTunnelSvc'
`$TUNNEL_NAME = '$gpoTunnelName'
`$REG_KEY    = 'HKLM:\SOFTWARE\WGKillSwitch'
`$SAFETY_MOD = 'C:\WireGuard\wg-safety.ps1'
if (Test-Path `$SAFETY_MOD) { . `$SAFETY_MOD }
`$ErrorActionPreference = 'SilentlyContinue'
function Wait-NamedMutex([System.Threading.Mutex]`$Mutex, [int]`$TimeoutMs) {
    try { return `$Mutex.WaitOne(`$TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { return `$true }
}
function Log(`$m) {
    `$mutex = `$null
    try {
        `$mutex = New-Object System.Threading.Mutex(`$false, "Global\WGKillSwitchLog")
        if (-not (Wait-NamedMutex `$mutex 2000)) { return }
        Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [GPO] `$m" -Encoding UTF8 -EA SilentlyContinue
    } finally { if (`$mutex) { try { `$mutex.ReleaseMutex() } catch {} } }
}
function Test-TunnelAdapterUp {
    for (`$try = 0; `$try -lt 3; `$try++) {
        try {
            foreach (`$a in (Get-NetAdapter -EA SilentlyContinue)) {
                if (`$a.Status -ne 'Up') { continue }
                if (`$a.Name -eq `$TUNNEL_NAME -or `$a.InterfaceDescription -match 'WireGuard') { return `$true }
            }
        } catch {}
        if (`$try -lt 2) { Start-Sleep -Milliseconds 500 }
    }
    return `$false
}
function Test-TunnelRunning {
    if (-not ([bool](( & sc.exe query `$TUNNEL_SVC 2>`$null) -match "RUNNING"))) { return `$false }
    return (Test-TunnelAdapterUp)
}
function Test-TcpHost([string]`$HostName, [int]`$Port, [int]`$TimeoutMs = 4000) {
    `$tcp = `$null
    try {
        `$tcp = New-Object System.Net.Sockets.TcpClient
        `$iar = `$tcp.BeginConnect(`$HostName, `$Port, `$null, `$null)
        if (-not `$iar.AsyncWaitHandle.WaitOne(`$TimeoutMs, `$false)) { return `$false }
        try { `$tcp.EndConnect(`$iar) } catch { return `$false }
        return `$true
    } catch { return `$false }
    finally { if (`$tcp) { try { `$tcp.Close() } catch {} } }
}
function Test-Internet {
    `$hits = 0
    foreach (`$h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-TcpHost `$h 443) { `$hits++ } }
    return (`$hits -ge 2)
}
function Test-SafeToOpen { return (Test-TunnelRunning) -and (Test-Internet) }
function Get-PreferredShell {
    `$pwshPath = Join-Path `$env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path `$pwshPath) { return `$pwshPath }
    `$cmd = Get-Command pwsh -EA SilentlyContinue
    if (`$cmd) { return `$cmd.Source }
    return Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
function Start-HiddenScript([string]`$ScriptPath) {
    `$shell = Get-PreferredShell
    Start-Process -FilePath `$shell -ArgumentList @('-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',`$ScriptPath) -WindowStyle Hidden
}
Log "GPO boot script fired (v$gpoKsVersion)"
try {
    `$graceEnd = Set-BootGraceFromUptime
    if (`$graceEnd) { Log "GPO: BootGrace until `$(`$graceEnd.ToString('HH:mm:ss')) (uptime `$(Get-OsUptimeSeconds)s, fail-open)" }
} catch {}
Disable-KillSwitchBlock
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound 2>`$null | Out-Null
& sc.exe config `$TUNNEL_SVC start= delayed-auto 2>`$null | Out-Null
if (Test-UnbrickActive -or Test-BootGrace -or (Test-BootSafeWindow)) {
    Log "GPO: fail-open hold - blocks cleared, repair only (no block authority)"
} else {
    `$waited = 0
    while (`$waited -lt 120 -and -not (Test-SafeToOpen)) {
        Start-Sleep -Seconds 3; `$waited += 3
    }
    if (Test-SafeToOpen) { Log "GPO: healthy after `${waited}s (tunnel + internet)" }
    elseif (Test-TunnelRunning) { Log "GPO: zombie tunnel after `${waited}s - monitor will debounce" }
    else { Log "GPO: tunnel down after `${waited}s - monitor will debounce" }
}
if (Test-Path `$REPAIR) {
    Start-HiddenScript `$REPAIR
    Log "Repair triggered (GPO never blocks)"
}
"@
$gpoContent | Set-Content $GPO_SCRIPT -Encoding UTF8 -Force
Update-GpoScriptsIni $GPO_INI $GPO_SCRIPT
Start-Process "secedit.exe"  -ArgumentList "/refreshpolicy machine_policy /enforce" -WindowStyle Hidden -Wait -EA SilentlyContinue
Start-Process "gpupdate.exe" -ArgumentList "/force" -WindowStyle Hidden -EA SilentlyContinue
if (Test-Path $GPO_SCRIPT) { OK "GPO boot script installed" } else { WARN "GPO script failed" }

# ================================================================
Write-Step "STEP 17b - ANTI-TAMPER GUARD VAULT"
# ================================================================
Write-GuardBackups
OK "Guard vault written ($GUARD_DIR)"


}
