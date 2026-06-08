#Requires -RunAsAdministrator
# WG Kill Switch - Post-Reboot Auto Verification (v12.0)
param([switch]$Force)
$ErrorActionPreference = 'Continue'
$LOG = 'C:\WireGuard\reboot-verify.log'
$REG = 'HKLM:\SOFTWARE\WGKillSwitch'

function Log([string]$m) {
    Add-Content $LOG "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $m" -Encoding UTF8 -EA SilentlyContinue
}

function Get-TunnelSvcName {
    try {
        $reg = Get-ItemProperty $REG -Name TunnelName -EA SilentlyContinue
        if ($reg.TunnelName) { return "WireGuardTunnel`$$($reg.TunnelName)" }
    } catch {}
    return 'WireGuardTunnel$wgcf-profile'
}

function Get-ScriptsDir {
    try {
        $reg = Get-ItemProperty $REG -Name ScriptsPath -EA SilentlyContinue
        if ($reg.ScriptsPath -and (Test-Path $reg.ScriptsPath)) { return [string]$reg.ScriptsPath }
    } catch {}
    $candidates = @(
        'C:\Users\seyit\Windows-WireGuard-KillSwitch\scripts',
        (Join-Path $env:ProgramData 'WGKillSwitchGuard\scripts')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Test-TunnelRunning {
    $svc = Get-TunnelSvcName
    return ([bool]((& sc.exe query $svc 2>$null) -match 'RUNNING'))
}

function Test-TcpHost([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 4000) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        try { $tcp.EndConnect($iar) } catch { return $false }
        return $true
    } catch { return $false }
    finally { if ($tcp) { try { $tcp.Close() } catch {} } }
}

function Test-Internet {
    $hits = 0
    foreach ($h in @('1.1.1.1', '1.0.0.1', '8.8.8.8')) { if (Test-TcpHost $h) { $hits++ } }
    return ($hits -ge 2)
}

function Test-SafeToOpen {
    return (Test-TunnelRunning) -and (Test-Internet)
}

$bootTime = try { (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime } catch { Get-Date }
$bootKey = $bootTime.ToString('yyyyMMddHHmmss')
$doneFile = "C:\WireGuard\reboot-verify-$bootKey.done"

if ((Test-Path $doneFile) -and -not $Force) { exit 0 }

Log "=== Post-reboot verify started (boot $bootTime) ==="

$waited = 0
while ($waited -lt 150 -and -not (Test-SafeToOpen)) {
    Start-Sleep 10
    $waited += 10
}
Log "Health wait: ${waited}s SafeToOpen=$(Test-SafeToOpen) Tunnel=$(Test-TunnelRunning)"

$scriptsDir = Get-ScriptsDir
if (-not $scriptsDir) {
    Log 'FAIL: scripts directory not found'
    Set-ItemProperty $REG RebootVerifyLastResult 'FAIL' -Force -EA SilentlyContinue
    Set-Content $doneFile (Get-Date -Format 'o') -Force -EA SilentlyContinue
    exit 1
}

$overall = 0
foreach ($name in @('safe-live-verify.ps1', 'security-audit.ps1')) {
    $path = Join-Path $scriptsDir $name
    if (-not (Test-Path $path)) {
        Log "FAIL: missing $path"
        $overall = 1
        continue
    }
    $outFile = Join-Path $env:TEMP "wg-reboot-$name.stdout.log"
    $errFile = Join-Path $env:TEMP "wg-reboot-$name.stderr.log"
    Remove-Item $outFile, $errFile -Force -EA SilentlyContinue
    Log "Running $name ..."
    $p = Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Log "$name exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { $overall = 1 }
    if (Test-Path $outFile) {
        Get-Content $outFile -EA SilentlyContinue | Select-Object -Last 5 | ForEach-Object { Log "  $_" }
    }
}

$verdict = if ($overall -eq 0) { 'PASS' } else { 'FAIL' }
Log "VERDICT: POST-REBOOT $verdict"

Set-ItemProperty $REG RebootVerifyLastBoot   $bootKey -Force -EA SilentlyContinue
Set-ItemProperty $REG RebootVerifyLastResult $verdict -Force -EA SilentlyContinue
Set-ItemProperty $REG RebootVerifyLastTime  (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force -EA SilentlyContinue
Set-Content $doneFile (Get-Date -Format 'o') -Force -EA SilentlyContinue

exit $overall