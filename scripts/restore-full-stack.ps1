#Requires -RunAsAdministrator
# Fast full-stack restore - tunnel + tasks + NSSM + v15 guards (no Get-ScheduledTask; no WMI network)
$ErrorActionPreference = 'Continue'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'
$INSTALL = 'C:\WireGuard'
$WG = 'C:\Program Files\WireGuard\wireguard.exe'
$CFG = "$INSTALL\wgcf-profile.conf"
$TUNNEL = 'wgcf-profile'
$TUNNEL_SVC = "WireGuardTunnel`$$TUNNEL"
$NSSM = "$INSTALL\nssm.exe"
$WG_SVC = 'WGKillSwitchSvc'
$REPAIR = "$INSTALL\repair.ps1"
$MONITOR = "$INSTALL\monitor.ps1"
$SERVICE = "$INSTALL\service-monitor.ps1"

function OK($m) { Write-Host " [OK]   $m" -ForegroundColor Green }
function WARN($m) { Write-Host " [WARN] $m" -ForegroundColor Yellow }
function ERR($m) { Write-Host " [ERR]  $m" -ForegroundColor Red }

function Restore-TaskFromReg([string]$TaskName, [string]$RegProp) {
    schtasks.exe /Query /TN "\$TaskName" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        schtasks.exe /Change /TN "\$TaskName" /ENABLE 2>$null | Out-Null
        return $true
    }
    $reg = Get-ItemProperty $REG -EA SilentlyContinue
    $b64 = $reg.$RegProp
    if (-not $b64) { return $false }
    try {
        $xml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $tmp = Join-Path $env:TEMP "wg-restore-$TaskName.xml"
        [IO.File]::WriteAllText($tmp, $xml, [Text.UTF8Encoding]::new($false))
        schtasks.exe /Create /TN "\$TaskName" /XML $tmp /F 2>$null | Out-Null
        Remove-Item $tmp -Force -EA SilentlyContinue
        if ($LASTEXITCODE -eq 0) { return $true }
        try {
            Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -EA Stop | Out-Null
            return $true
        } catch {}
        if ($TaskName -eq 'WG-RepairTask') {
            $repTr = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR`""
            schtasks.exe /Create /TN '\WG-RepairTask' /TR $repTr /SC MINUTE /MO 2 /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        return $false
    } catch { return $false }
}

function Install-Tunnel {
    if (-not ((Test-Path $WG) -and (Test-Path $CFG))) { WARN 'WireGuard or config missing'; return $false }
    Get-Process wireguard -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    & $WG /uninstalltunnelservice $TUNNEL 2>$null | Out-Null
    Start-Sleep -Seconds 3
    & $WG /installtunnelservice $CFG 2>$null | Out-Null
    & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    & sc.exe start $TUNNEL_SVC 2>$null | Out-Null
    $w = 0
    while ($w -lt 45 -and -not ((sc.exe query $TUNNEL_SVC 2>&1 | Out-String) -match 'RUNNING')) {
        Start-Sleep -Seconds 2; $w += 2
    }
    $up = (sc.exe query $TUNNEL_SVC 2>&1 | Out-String) -match 'RUNNING'
    if ($up) { OK "Tunnel RUNNING (${w}s)" } else { WARN "Tunnel not RUNNING after ${w}s" }
    return $up
}

function Install-NssmService {
    if (-not (Test-Path $NSSM)) { WARN 'nssm.exe missing'; return $false }
    $q = sc.exe query $WG_SVC 2>&1 | Out-String
    if ($q -notmatch 'SERVICE_NAME') {
        & $NSSM install $WG_SVC powershell.exe 2>$null | Out-Null
        & $NSSM set $WG_SVC AppParameters "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SERVICE`"" 2>$null | Out-Null
        & $NSSM set $WG_SVC Start SERVICE_DELAYED_AUTO_START 2>$null | Out-Null
        & $NSSM set $WG_SVC ObjectName LocalSystem 2>$null | Out-Null
        & $NSSM set $WG_SVC DisplayName "WG KillSwitch Guard" 2>$null | Out-Null
        & $NSSM set $WG_SVC AppExit Default Restart 2>$null | Out-Null
        OK 'WGKillSwitchSvc installed via NSSM'
    }
    & $NSSM start $WG_SVC 2>$null | Out-Null
    Start-Sleep -Seconds 3
    $run = (sc.exe query $WG_SVC 2>&1 | Out-String) -match 'RUNNING'
    if ($run) { OK 'WGKillSwitchSvc RUNNING' } else { WARN 'WGKillSwitchSvc not RUNNING' }
    return $run
}

function Start-Hidden([string]$path) {
    if (-not (Test-Path $path)) { return }
    Start-Process powershell.exe -ArgumentList @(
        '-NonInteractive','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$path
    ) -WindowStyle Hidden
}

Write-Host "`n=== RESTORE FULL STACK (v15) ===`n" -ForegroundColor Cyan

New-Item -Path $REG -Force | Out-Null
Set-ItemProperty $REG 'BootGraceUntil' (Get-Date).AddSeconds(180).ToString('o') -Force
OK 'BootGrace 180s set (fail-open)'

Install-Tunnel | Out-Null

foreach ($pair in @(
    @('WG-KillSwitch','TaskXML'),
    @('WG-RepairTask','TaskXMLRepair'),
    @('WG-RebootVerify','TaskXMLRebootVerify'),
    @('WG-InternetWatchdog','TaskXMLWatchdog')
)) {
    if (Restore-TaskFromReg $pair[0] $pair[1]) { OK "Task $($pair[0]) restored" }
    else { WARN "Task $($pair[0]) restore failed" }
}

Install-NssmService | Out-Null

$repo = Split-Path $PSScriptRoot -Parent
$installPs1 = Join-Path $repo 'install.ps1'
if (Test-Path $installPs1) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -StrongPrivacyUpgrade -NoPause 2>&1 | Out-Null
    OK 'v15 StrongPrivacyUpgrade sync completed'
}

Start-Hidden $REPAIR
Start-Sleep -Seconds 4
if (-not (Test-Path "$INSTALL\monitor.pid")) { Start-Hidden $MONITOR }
Start-Sleep -Seconds 5

Write-Host "`n--- Verification ---`n" -ForegroundColor Cyan
foreach ($tn in @('WG-KillSwitch','WG-RepairTask','WG-RebootVerify','WG-InternetWatchdog')) {
    schtasks.exe /Query /TN "\$tn" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { OK "Task $tn present" } else { ERR "Task $tn MISSING" }
}
$tunnel = (sc.exe query $TUNNEL_SVC 2>&1 | Out-String) -match 'RUNNING'
if ($tunnel) { OK 'Tunnel service RUNNING' } else { ERR 'Tunnel service DOWN' }
$svc = (sc.exe query $WG_SVC 2>&1 | Out-String) -match 'RUNNING'
if ($svc) { OK 'WGKillSwitchSvc RUNNING' } else { WARN 'WGKillSwitchSvc not RUNNING' }

foreach ($script in @('privacy-audit.ps1','leak-audit.ps1','safe-live-verify.ps1')) {
    $p = Join-Path $PSScriptRoot $script
    if (Test-Path $p) {
        Write-Host "`n>> $script" -ForegroundColor Yellow
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
    }
}
exit $LASTEXITCODE