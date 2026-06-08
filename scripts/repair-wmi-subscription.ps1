#Requires -RunAsAdministrator
# Idempotent WMI permanent subscription repair (WGMonitorFilter / WGMonitorConsumer)
$ErrorActionPreference = 'Continue'
$WMI_FILTER   = 'WGMonitorFilter'
$WMI_CONSUMER = 'WGMonitorConsumer'
$WMI_WRAPPER  = 'C:\WireGuard\wmi-repair.ps1'

function Get-WmiBindFilter {
    return "Filter = ""__EventFilter.Name='$WMI_FILTER'"""
}

function Test-WmiSubscriptionActive {
    try {
        $f = Get-CimInstance -Namespace root\subscription -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" -EA SilentlyContinue
        if (-not $f) { return $false }
        $c = Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" -EA SilentlyContinue
        if (-not $c) { return $false }
        $b = Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -Filter (Get-WmiBindFilter) -EA SilentlyContinue
        return [bool]$b
    } catch { return $false }
}

function Install-WmiSubscription {
    if (Test-WmiSubscriptionActive) { return $true }
    if (-not (Test-Path $WMI_WRAPPER)) {
        Write-Host " [!!] Missing $WMI_WRAPPER - run install.ps1 first" -ForegroundColor Red
        return $false
    }
    $ns = @{ Namespace = 'root\subscription' }
    Get-CimInstance @ns -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" -EA SilentlyContinue | Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ns -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" -EA SilentlyContinue | Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ns -ClassName __FilterToConsumerBinding -Filter (Get-WmiBindFilter) -EA SilentlyContinue | Remove-CimInstance -EA SilentlyContinue
    $q = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND (TargetInstance.Name='powershell.exe' OR TargetInstance.Name='pwsh.exe')"
    try {
        $filter = New-CimInstance @ns -ClassName __EventFilter -Property @{
            Name = $WMI_FILTER; EventNamespace = 'root\cimv2'; QueryLanguage = 'WQL'; Query = $q
        } -EA Stop
        $consumer = New-CimInstance @ns -ClassName CommandLineEventConsumer -Property @{
            Name = $WMI_CONSUMER
            CommandLineTemplate = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WMI_WRAPPER`""
        } -EA Stop
        if ($filter -and $consumer) {
            New-CimInstance @ns -ClassName __FilterToConsumerBinding -Property @{
                Filter = [Ref]$filter; Consumer = [Ref]$consumer
            } -EA Stop | Out-Null
        }
    } catch {
        Write-Host " [!!] WMI install error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    return (Test-WmiSubscriptionActive)
}

Write-Host "`n=== WMI Subscription Repair ===" -ForegroundColor Cyan
if (Install-WmiSubscription) {
    Write-Host " [OK] WMI subscription active (filter+consumer+binding)" -ForegroundColor Green
    exit 0
}
Write-Host " [FAIL] WMI subscription repair failed" -ForegroundColor Red
exit 1