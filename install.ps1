# ================================================================
# WireGuard + WARP Kill Switch - FULL AUTOMATIC SETUP (v15.2)
# ================================================================
# Orchestrator: implementation in lib/*.ps1 (dot-sourced below).
# Entry point unchanged: .\install.ps1
#
# DESIGN PHILOSOPHY (for code reviewers):
# - Zero third-party dependencies. 100% native Windows (PowerShell + netsh + WMI + Task Scheduler + NSSM)
# - Self-healing: WMI Permanent Event Subscription respawns monitor if killed.
# - Install-safe: install lock defers outbound blocks until STEP 19; tunnel kept alive on upgrade.
# - Internet opens only when tunnel RUNNING and Test-Internet passes (zombie-tunnel prevention).
# - v15.2: boot-safe window (90s), DHCP/gateway exemptions, tunnel-only IPv6 bind, fail-open + DryRun.
# - v15.1: lib/ modular split; WARP-first docs; one-step Hassas-Tarama; optional CI live-smoke.
# - v11.3: anti-tamper guard; v11.2: WG-RebootVerify; v11.1: monitor singleton hardening.
# - v15.0: DNS lock, network privacy, strict dnscrypt, leak-sentinel v15, sensitive-mode.
# - v14.0: dnscrypt-proxy + Tor hardening + leak-sentinel.
# - Test-Internet: 2-of-3 hosts; server rule rewrite only on IP change.
# ================================================================
#Requires -RunAsAdministrator
param(
    [string]$CustomConfig     = "",
    [string]$CustomTunnel     = "",
    [string]$CustomEndpointIP = "",
    [int]$CustomPort          = 0,
    [switch]$PrivacyUpgradeOnly,
    [switch]$DnsLeakUpgradeOnly,
    [switch]$TorUpgradeOnly,
    [switch]$FullPrivacyUpgrade,
    [switch]$StrongPrivacyUpgrade,
    [switch]$DryRun,
    [bool]$EnableFailsafe = $true,
    [switch]$NoPause
)
$ErrorActionPreference = "Continue"
$script:InstallDryRun = $DryRun.IsPresent
$script:EnableFailsafe = $EnableFailsafe

$LibRoot = Join-Path $PSScriptRoot 'lib'
$LibModules = @(
    'Install-Constants.ps1',
    'Install-SafeNetwork.ps1',
    'Install-Helpers.ps1',
    'Install-Privacy.ps1',
    'Install-UpgradePaths.ps1',
    'Install-MainSteps-0-6.ps1',
    'Install-GeneratedScripts.ps1',
    'Install-TasksAndWmi.ps1',
    'Install-MainSteps-18-20.ps1'
)
foreach ($mod in $LibModules) {
    $modPath = Join-Path $LibRoot $mod
    if (-not (Test-Path $modPath)) {
        Write-Host " [ERR]  Missing lib module: $mod" -ForegroundColor Red
        Write-Host "        Re-clone the repo or restore lib/ from v15.2." -ForegroundColor Gray
        if (-not $NoPause) { pause }
        exit 1
    }
    . $modPath
}

$v14StackPath = Join-Path $PSScriptRoot 'scripts\install-v14-stack.ps1'
if (Test-Path $v14StackPath) { . $v14StackPath } else { Write-Host ' [WARN] install-v14-stack.ps1 missing - v14 features disabled' -ForegroundColor Yellow }
$v15StackPath = Join-Path $PSScriptRoot 'scripts\install-v15-privacy-stack.ps1'
if (Test-Path $v15StackPath) { . $v15StackPath } else { Write-Host ' [WARN] install-v15-privacy-stack.ps1 missing - v15 features disabled' -ForegroundColor Yellow }

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "`n [!!] Run as Administrator!" -ForegroundColor Red
    if (-not $NoPause) { pause }
    exit 1
}

if ($DryRun) {
    Write-Host "`n [DRY-RUN] Active - no firewall rules or adapter bindings will be changed." -ForegroundColor Yellow
    Write-Host "           Simulation logs only. Re-run without -DryRun to apply." -ForegroundColor Gray
}

if (Invoke-InstallUpgradeEarlyExit) { exit 0 }

try {
Invoke-InstallMainSteps0to6
Invoke-InstallGeneratedScripts
Invoke-InstallTasksAndWmi
Invoke-InstallMainSteps18to20
} catch {
    Write-Err "Install fatal: $_"
    if ($EnableFailsafe) {
        Write-Host " [SAFE] EnableFailsafe: opening internet (fail-open)" -ForegroundColor Yellow
        if (Get-Command Invoke-FailOpenSafeguard -ErrorAction SilentlyContinue) {
            Invoke-FailOpenSafeguard -Reason ('install.ps1 catch: ' + $_.Exception.Message) -LogPrefix '[INSTALL]'
        } elseif (Get-Command Remove-InstallBlocks -ErrorAction SilentlyContinue) {
            Remove-InstallBlocks
        }
    }
    if (-not $NoPause) { pause }
    exit 1
}