# Dot-sourced from install.ps1 - Install-DryRunPreview.ps1 (v15.3.1 AI-safe preview)
#Requires -Version 5.1

function Invoke-InstallDryRunPreview {
    Write-Step 'DRY-RUN PREVIEW (read-only - zero network mutations)'
    Write-Host ''
    Write-Host '  AI CONNECTION INVARIANT: preview never downloads, installs, or mutates network.' -ForegroundColor Cyan
    Write-Host ''

    $previewSteps = @(
        'STEP 0: Would verify/install WireGuard + WARP config (skipped in preview)'
        'STEP 1: Would prepare C:\WireGuard folder (skipped)'
        'STEP 2: Would download NSSM if missing (skipped)'
        'STEP 2b: Would cache server IPs + set install lock (skipped)'
        'STEP 3: Would remove legacy tasks/WMI (skipped)'
        'STEP 4: Would apply IPv6 firewall rules via Invoke-SafeNetsh (skipped)'
        'STEP 5: Would ensure WireGuard tunnel service (skipped)'
        'STEP 6: Would apply firewall exemptions only - no catch-all blocks (skipped)'
        'Steps 0-20: Would deploy scripts, tasks, WMI, monitor - all skipped in DryRun'
    )
    foreach ($line in $previewSteps) {
        Write-SafeActionLog $line
    }

    Write-Step 'SYSTEM STATUS (read-only)'
    $wgExe = Test-Path 'C:\Program Files\WireGuard\wireguard.exe'
    OK "WireGuard EXE present: $wgExe"
    if (Get-Command Test-TunnelRunning -ErrorAction SilentlyContinue) {
        if (Test-TunnelRunning) { OK 'Tunnel: RUNNING' } else { WARN 'Tunnel: not running' }
    } else {
        $tq = & sc.exe query $TUNNEL_SVC 2>$null | Out-String
        if ($tq -match 'RUNNING') { OK 'Tunnel service: RUNNING' } else { WARN 'Tunnel service: not RUNNING' }
    }
    $blockPresent = $false
    foreach ($br in @('KS-Block-WiFi-Out', 'KS-Block-Ethernet-Out')) {
        $o = netsh advfirewall firewall show rule name="$br" 2>$null | Out-String
        if ($o -match 'Enabled:\s+Yes') { $blockPresent = $true; WARN "Block rule active: $br" }
    }
    if (-not $blockPresent) { OK 'Catch-all block rules: none active' }
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -ErrorAction SilentlyContinue
        if ($reg.KillSwitchArmed -eq 1) { WARN 'KillSwitchArmed=1 (blocks allowed when healthy)' }
        else { OK 'KillSwitchArmed=0 or unset (fail-open)' }
        if ($reg.PostInstallGraceUntil -and (Get-Date) -lt [datetime]$reg.PostInstallGraceUntil) {
            OK "PostInstallGrace active until $($reg.PostInstallGraceUntil)"
        }
    } catch {}
    $mon = @()
    if (Get-Command Get-MonitorShellProcs -ErrorAction SilentlyContinue) {
        $mon = @(Get-MonitorShellProcs)
    }
    if ($mon.Count -gt 0) { WARN "Monitor process(es) running: $(($mon | ForEach-Object { $_.Id }) -join ', ')" }
    else { OK 'Monitor: not running' }

    Write-Step 'DRY-RUN COMPLETE'
    OK 'Preview finished - no install steps executed (Steps 0-20 all skipped)'
    Write-Host ''
    Write-Host ' [DRY-RUN] Your network and AI connection were protected by pre-flight quiesce.' -ForegroundColor Green
    Write-Host '           Run without -DryRun for full install after preview looks correct.' -ForegroundColor Green
    Write-Host ''
}