# Dot-sourced from install.ps1 â€” Install-Privacy.ps1 (v15.1 modular split)
#Requires -Version 5.1
function Get-ChromiumPrivacyDWordProps {
    return @{
        WebRtcLocalhostCandidateAllowed      = 0
        BlockThirdPartyCookies               = 1
        DefaultThirdPartyCookieSetting       = 1
        EnableDoNotTrack                     = 1
        MetricsReportingEnabled              = 0
        DeviceMetricsReportingEnabled        = 0
        PaymentMethodQueryEnabled            = 0
        BrowserSignin                        = 0
        SyncDisabled                         = 1
        AutofillAddressEnabled               = 0
        AutofillCreditCardEnabled            = 0
        DefaultGeolocationSetting            = 2
        DefaultNotificationsSetting          = 2
        SafeBrowsingExtendedReportingEnabled = 0
        ChromeVariations                     = 0
        PrivacySandboxAdTopicsEnabled        = 0
        PrivacySandboxPromptEnabled          = 0
        PrivacySandboxAdMeasurementEnabled   = 0
        QuicAllowed                          = 0
        BrowserNetworkTimeQueriesEnabled     = 0
        SearchSuggestEnabled                 = 0
        NetworkPredictionOptions             = 2
        SharingDisabled                      = 1
        PasswordManagerEnabled               = 0
        AlternateErrorPagesEnabled           = 0
        SpellCheckServiceEnabled             = 0
        TranslateEnabled                     = 0
    }
}

function Get-FirefoxPrivacyPolicyJson {
    return @'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DoNotTrack": true,
    "Cookies": {
      "Default": "reject-third-party",
      "RejectThirdParty": true,
      "Locked": true
    },
    "Preferences": {
      "media.peerconnection.ice.no_host": { "Value": true, "Status": "locked" },
      "media.peerconnection.ice.default_address_only": { "Value": true, "Status": "locked" },
      "privacy.resistFingerprinting": { "Value": true, "Status": "locked" },
      "privacy.fingerprintingProtection": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.enabled": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.socialtracking.enabled": { "Value": true, "Status": "locked" },
      "network.cookie.cookieBehavior": { "Value": 1, "Status": "locked" },
      "geo.enabled": { "Value": false, "Status": "locked" },
      "privacy.donottrackheader.enabled": { "Value": true, "Status": "locked" },
      "browser.contentblocking.category": { "Value": "strict", "Status": "locked" },
      "webgl.disabled": { "Value": true, "Status": "locked" },
      "dom.webgpu.enabled": { "Value": false, "Status": "locked" },
      "network.http.referer.defaultPolicy": { "Value": 1, "Status": "locked" }
    }
  }
}
'@
}

function Get-WindowsPrivacyRegBlocks {
    return @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Props = @{
            AllowTelemetry = 0; MaxTelemetryAllowed = 0; DoNotShowFeedbackNotifications = 1
            DisableOneSettingsDownloads = 1; DisableTailoredExperiencesWithDiagnosticData = 1
            AllowDeviceNameInTelemetry = 0; AllowWUfBCloudProcessing = 0
        }}
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Props = @{ AllowTelemetry = 0 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Props = @{ DisabledByGroupPolicy = 1 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Props = @{
            PublishUserActivities = 0; EnableActivityFeed = 0; UploadUserActivities = 0; EnableClipboardHistory = 0
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'; Props = @{
            DisableLocation = 1; DisableLocationScripting = 1; DisableSensors = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Props = @{ AllowCortana = 0; AllowCloudSearch = 0 }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'; Props = @{
            RestrictImplicitInkCollection = 1; RestrictImplicitTextCollection = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Props = @{
            DisableWindowsConsumerFeatures = 1; DisableCloudOptimizedContent = 1
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Props = @{
            LetAppsAccessAdvertisingId = 2; LetAppsAccessLocation = 2; LetAppsAccessMicrophone = 2; LetAppsAccessCamera = 2
        }}
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Props = @{
            Disabled = 1; DontSendAdditionalData = 1; LoggingDisabled = 1
        }}
    )
}

function Set-ChromiumPrivacyPolicies([string]$PolicyPath, [string]$Label) {
    $props = Get-ChromiumPrivacyDWordProps
    New-Item -Path $PolicyPath -Force | Out-Null
    Set-ItemProperty $PolicyPath 'WebRtcIpHandlingPolicy' 'default_public_interface_only' -Type String -Force
    Set-ItemProperty $PolicyPath 'DnsOverHttpsMode' 'off' -Type String -Force
    Set-ItemProperty $PolicyPath 'ExtensionInstallBlocklist' '*' -Type String -Force
    foreach ($kv in $props.GetEnumerator()) {
        Set-ItemProperty $PolicyPath $kv.Key $kv.Value -Type DWord -Force
    }
    if ($PolicyPath -match 'Microsoft\\Edge') {
        Set-ItemProperty $PolicyPath 'PersonalizationReportingEnabled' 0 -Type DWord -Force
        Set-ItemProperty $PolicyPath 'DiagnosticData' 0 -Type DWord -Force
    }
    OK "Browser privacy: $Label"
}

function Install-BrowserPrivacyPolicies {
    foreach ($b in @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Label = 'Chrome' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Label = 'Edge' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Label = 'Brave' }
    )) {
        try { Set-ChromiumPrivacyPolicies $b.Path $b.Label }
        catch { WARN "Browser privacy failed: $($b.Label)" }
    }
    $ffPolicy = Get-FirefoxPrivacyPolicyJson
    foreach ($ffDir in @('C:\Program Files\Mozilla Firefox\distribution', 'C:\Program Files (x86)\Mozilla Firefox\distribution')) {
        $ffRoot = Split-Path $ffDir -Parent
        if (-not (Test-Path $ffRoot)) { continue }
        try {
            New-Item -Path $ffDir -ItemType Directory -Force | Out-Null
            $ffPolicy | Set-Content (Join-Path $ffDir 'policies.json') -Encoding UTF8 -Force
            OK "Browser privacy: Firefox ($ffRoot)"
        } catch { WARN "Browser privacy failed: Firefox ($ffRoot)" }
    }
}

function Install-WindowsTelemetryReduction {
    foreach ($block in (Get-WindowsPrivacyRegBlocks)) {
        try {
            New-Item -Path $block.Path -Force | Out-Null
            foreach ($kv in $block.Props.GetEnumerator()) {
                Set-ItemProperty $block.Path $kv.Key $kv.Value -Type DWord -Force
            }
        } catch { WARN "Telemetry registry failed: $($block.Path)" }
    }
    foreach ($svc in @('DiagTrack', 'dmwappushservice')) {
        & sc.exe config $svc start= disabled 2>$null | Out-Null
        & sc.exe stop $svc 2>$null | Out-Null
    }
    OK 'Windows privacy: consumer telemetry reduced (not eliminated)'
}

function Install-PrivacyHardening {
    Install-BrowserPrivacyPolicies
    Install-WindowsTelemetryReduction
}

function Write-PrivacyHardeningGuardPs1 {
    $dwords = Get-ChromiumPrivacyDWordProps
    $dwordInit = ($dwords.GetEnumerator() | ForEach-Object { "        $($_.Key)=$($_.Value)" }) -join "`n"
    $ffJson = (Get-FirefoxPrivacyPolicyJson) -replace "'", "''"
    $regInit = (Get-WindowsPrivacyRegBlocks | ForEach-Object {
        $pairs = ($_.Props.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
        "    @{ Path='$($_.Path)'; Props=@{ $pairs }}"
    }) -join ",`n"
    $content = @"
# Privacy Hardening Guard v$WG_KS_VERSION (auto-generated by install.ps1)
`$ErrorActionPreference = 'SilentlyContinue'
`$LOG = 'C:\WireGuard\killswitch.log'
function Log(`$m) { try { Add-Content `$LOG "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | [PRIVACY] `$m" -Encoding UTF8 } catch {} }
function Set-ChromiumPrivacyPolicies([string]`$PolicyPath, [string]`$Label) {
    `$props = @{
$dwordInit
    }
    New-Item -Path `$PolicyPath -Force | Out-Null
    Set-ItemProperty `$PolicyPath 'WebRtcIpHandlingPolicy' 'default_public_interface_only' -Type String -Force
    Set-ItemProperty `$PolicyPath 'DnsOverHttpsMode' 'off' -Type String -Force
    Set-ItemProperty `$PolicyPath 'ExtensionInstallBlocklist' '*' -Type String -Force
    foreach (`$kv in `$props.GetEnumerator()) { Set-ItemProperty `$PolicyPath `$kv.Key `$kv.Value -Type DWord -Force }
    if (`$PolicyPath -match 'Microsoft\\Edge') {
        Set-ItemProperty `$PolicyPath 'PersonalizationReportingEnabled' 0 -Type DWord -Force
        Set-ItemProperty `$PolicyPath 'DiagnosticData' 0 -Type DWord -Force
    }
    Log "`$Label browser privacy applied"
}
foreach (`$b in @(
    @{ Path='HKLM:\SOFTWARE\Policies\Google\Chrome'; Label='Chrome' },
    @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Label='Edge' },
    @{ Path='HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'; Label='Brave' }
)) { try { Set-ChromiumPrivacyPolicies `$b.Path `$b.Label } catch { Log "`$(`$b.Label) failed: `$_" } }
`$ffPolicy = @'
$ffJson
'@
foreach (`$ffDir in @('C:\Program Files\Mozilla Firefox\distribution','C:\Program Files (x86)\Mozilla Firefox\distribution')) {
    `$ffRoot = Split-Path `$ffDir -Parent
    if (-not (Test-Path `$ffRoot)) { continue }
    try {
        New-Item -Path `$ffDir -ItemType Directory -Force | Out-Null
        `$ffPolicy | Set-Content (Join-Path `$ffDir 'policies.json') -Encoding UTF8 -Force
        Log "Firefox privacy applied (`$ffRoot)"
    } catch { Log "Firefox failed: `$_" }
}
`$regBlocks = @(
$regInit
)
foreach (`$block in `$regBlocks) {
    try {
        New-Item -Path `$block.Path -Force | Out-Null
        foreach (`$kv in `$block.Props.GetEnumerator()) { Set-ItemProperty `$block.Path `$kv.Key `$kv.Value -Type DWord -Force }
    } catch { Log "Registry failed: `$(`$block.Path)" }
}
foreach (`$svc in @('DiagTrack','dmwappushservice')) { & sc.exe config `$svc start= disabled 2>`$null | Out-Null; & sc.exe stop `$svc 2>`$null | Out-Null }
Log 'Windows privacy reduction applied'
"@
    $content | Set-Content $PRIVACY_GUARD_PS1 -Encoding UTF8 -Force
    attrib +S +H $PRIVACY_GUARD_PS1 2>$null | Out-Null
}

function Install-ScriptIntegrityVault {
    if (-not (Test-Path 'HKLM:\SOFTWARE\WGKillSwitch')) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    }
    $vaultFiles = @(
        $MONITOR_PS1, $REPAIR_PS1, $PRIVACY_GUARD_PS1, $ANTI_TAMPER_PS1, $WMI_WRAPPER,
        (Join-Path $INSTALL_DIR 'install.ps1')
    )
    foreach ($f in $vaultFiles) {
        if (-not (Test-Path $f)) { continue }
        if ((Get-Item -LiteralPath $f -EA SilentlyContinue) -is [System.IO.DirectoryInfo]) { continue }
        $leaf = Split-Path $f -Leaf
        $hash = (Get-FileHash -Path $f -Algorithm SHA256).Hash
        Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' "Hash_$leaf" $hash -Force
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'IntegrityVaultDate' (Get-Date -Format 'o') -Force
    if (Get-Command Extend-ScriptIntegrityVaultV14 -EA SilentlyContinue) {
        Extend-ScriptIntegrityVaultV14
    }
    if (Get-Command Extend-ScriptIntegrityVaultV15 -EA SilentlyContinue) {
        Extend-ScriptIntegrityVaultV15
    }
}

function Test-PrivacyChromiumPolicy([string]$VendorPath) {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Policies\$VendorPath" -EA SilentlyContinue
    return ($p -and $p.WebRtcIpHandlingPolicy -eq 'default_public_interface_only' -and
            $p.WebRtcLocalhostCandidateAllowed -eq 0 -and $p.BlockThirdPartyCookies -eq 1 -and
            $p.MetricsReportingEnabled -eq 0 -and $p.DnsOverHttpsMode -eq 'off' -and
            $p.PrivacySandboxAdTopicsEnabled -eq 0 -and $p.QuicAllowed -eq 0)
}

function Test-WindowsTelemetryReduced {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -EA SilentlyContinue
    $wer = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -EA SilentlyContinue
    return ($p -and $p.AllowTelemetry -eq 0 -and $wer -and $wer.Disabled -eq 1)
}

function Test-ScriptIntegrityVault {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' -EA SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($pair in @(
        @{ File = $MONITOR_PS1; Key = 'Hash_monitor.ps1' },
        @{ File = $REPAIR_PS1; Key = 'Hash_repair.ps1' },
        @{ File = $PRIVACY_GUARD_PS1; Key = 'Hash_privacy-hardening-guard.ps1' }
    )) {
        $expected = $reg.$($pair.Key)
        if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
        if (-not (Test-Path $pair.File)) { return $false }
        $actual = (Get-FileHash -Path $pair.File -Algorithm SHA256).Hash
        if ($actual -ne $expected) { return $false }
    }
    return $true
}

function Stop-AllMonitorProcs {
    Get-CimInstance Win32_Process -EA SilentlyContinue |
        Where-Object { (Test-IsMainMonitor $_.CommandLine) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

function Ensure-DelayedAutoStart {
    & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    if (Test-Path $NSSM) { & $NSSM set $WG_SVC_NAME Start SERVICE_DELAYED_AUTO_START 2>$null | Out-Null }
}

function Test-DelayedAutoStart {
    & sc.exe config $TUNNEL_SVC start= delayed-auto 2>$null | Out-Null
    $qc = & sc.exe qc $TUNNEL_SVC 2>$null | Out-String
    return ($qc -match 'DELAYED')
}

function Install-WmiSubscription {
    if (Test-WmiSubscriptionActive) { return $true }
    $cim = Get-ShortCimSession
    $ca = @{ Namespace = 'root\subscription' }
    if ($cim) { $ca['CimSession'] = $cim }
    Get-CimInstance @ca -ClassName __EventFilter -Filter "Name='$WMI_FILTER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ca -ClassName CommandLineEventConsumer -Filter "Name='$WMI_CONSUMER'" -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    Get-CimInstance @ca -ClassName __FilterToConsumerBinding -Filter (Get-WmiBindFilter) -EA SilentlyContinue |
        Remove-CimInstance -EA SilentlyContinue
    $wmiQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Process' AND (TargetInstance.Name='powershell.exe' OR TargetInstance.Name='pwsh.exe')"
    $nca = @{ Namespace = 'root\subscription' }
    if ($cim) { $nca['CimSession'] = $cim }
    try {
        $filter = New-CimInstance @nca -ClassName __EventFilter -Property @{
            Name=$WMI_FILTER; EventNamespace='root\cimv2'; QueryLanguage='WQL'; Query=$wmiQuery
        } -EA Stop
        $consumer = New-CimInstance @nca -ClassName CommandLineEventConsumer -Property @{
            Name=$WMI_CONSUMER
            CommandLineTemplate="powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WMI_WRAPPER`""
        } -EA Stop
        if ($filter -and $consumer) {
            New-CimInstance @nca -ClassName __FilterToConsumerBinding -Property @{
                Filter=[Ref]$filter; Consumer=[Ref]$consumer
            } -EA Stop | Out-Null
            return (Test-WmiSubscriptionActive)
        }
    } catch {
        Write-Info "WMI subscription failed: $($_.Exception.Message)"
    }
    return $false
}

function Remove-KurtarArtifacts {
    foreach ($name in @('kurtar.bat', 'kurtar.ps1', 'kurtar2.ps1', 'resume-after-unbrick.ps1')) {
        $path = Join-Path $INSTALL_DIR $name
        if (Test-Path $path) {
            attrib -H -S $path 2>$null | Out-Null
            Remove-Item $path -Force -EA SilentlyContinue
            Write-Info "Removed legacy rescue script: $name"
        }
    }
    $guardNames = @('kurtar.bat', 'kurtar.ps1', 'kurtar2.ps1', 'resume-after-unbrick.ps1')
    foreach ($name in $guardNames) {
        $gp = Join-Path $GUARD_DIR $name
        if (Test-Path $gp) { Remove-Item $gp -Force -EA SilentlyContinue }
    }
    Remove-TaskFully 'WG-UnbrickResume'
}

function Update-GpoScriptsIni($iniPath, $scriptPath) {
    New-Item -ItemType Directory -Path (Split-Path $iniPath) -Force -EA SilentlyContinue | Out-Null
    $content = ""
    if (Test-Path $iniPath) {
        $content = Get-Content $iniPath -Raw -Encoding Unicode -EA SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            $content = Get-Content $iniPath -Raw -EA SilentlyContinue
        }
    }
    if ($null -eq $content) { $content = "" }
    if ($content -match [regex]::Escape($scriptPath)) { Write-Info "GPO scripts.ini: already registered"; return }
    if ($content -match "\[Startup\]") {
        $maxIndex = -1; $startup = $false
        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match "^\[Startup\]") { $startup = $true; continue }
            if ($line -match "^\[" -and $line -notmatch "^\[Startup\]") { $startup = $false; continue }
            if ($startup -and $line -match "^(\d+)CmdLine=") {
                $idx = [int]$Matches[1]; if ($idx -gt $maxIndex) { $maxIndex = $idx }
            }
        }
        $nextIndex = $maxIndex + 1
        $newBlock = "${nextIndex}CmdLine=powershell.exe`r`n${nextIndex}Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"`r`n"
        $content = $content -replace "(\[Startup\]\r?\n)", "`$1$newBlock"
    } else {
        $content += "`r`n[Startup]`r`n0CmdLine=powershell.exe`r`n0Parameters=-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"`r`n"
    }
    $content | Set-Content $iniPath -Encoding Unicode -Force
}

function Unlock-GuardDirForWrite {
    New-Item -ItemType Directory -Path $GUARD_DIR -Force -EA SilentlyContinue | Out-Null
    attrib -H -S $GUARD_DIR 2>$null | Out-Null
    Get-ChildItem $GUARD_DIR -File -EA SilentlyContinue | ForEach-Object { attrib -H -S $_.FullName 2>$null | Out-Null }
    icacls $GUARD_DIR /grant "BUILTIN\Administrators:(OI)(CI)F" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /C /Q 2>$null | Out-Null
}

function Write-GuardBackups {
    Unlock-GuardDirForWrite
    $guardFiles = @(
        $MONITOR_PS1, $REPAIR_PS1, $SERVICE_PS1, $WMI_WRAPPER,
        $REBOOT_VERIFY_PS1, $WATCHDOG_PS1, $GPO_SCRIPT, $ANTI_TAMPER_PS1,
        $PRIVACY_GUARD_PS1, $WEBRTC_GUARD_PS1,
        $DNSCRYPT_GUARD_PS1, $TOR_GUARD_PS1, $TOR_MONITOR_PS1, $LEAK_SENTINEL_PS1,
        $DNS_LOCKDOWN_GUARD_PS1, $NETWORK_PRIVACY_GUARD_PS1, $SENSITIVE_MODE_PS1
    )
    foreach ($f in $guardFiles) {
        if (Test-Path $f) {
            $dest = Join-Path $GUARD_DIR (Split-Path $f -Leaf)
            if (Test-Path $dest) {
                icacls $dest /grant 'BUILTIN\Administrators:F' /C 2>$null | Out-Null
                attrib -R -S -H $dest 2>$null | Out-Null
            }
            Copy-Item $f $dest -Force
        }
    }
    foreach ($tn in @($TASK_MONITOR, $TASK_REPAIR, $TASK_REBOOT_VERIFY, $TASK_WATCHDOG)) {
        $xml = Export-TaskXmlSafe $tn
        if ($xml) {
            $xml | Set-Content (Join-Path $GUARD_DIR "$tn.xml") -Encoding UTF8 -Force
        }
    }
    try {
        $gAcl = Get-Acl $GUARD_DIR
        $gAcl.SetAccessRuleProtection($true, $false)
        $gAcl.Access | ForEach-Object { $null = $gAcl.RemoveAccessRule($_) }
        $gAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $gAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -Path $GUARD_DIR -AclObject $gAcl
    } catch {}
    attrib +H +S $GUARD_DIR 2>$null | Out-Null
    Get-ChildItem $GUARD_DIR -File -EA SilentlyContinue | ForEach-Object { attrib +H +S $_.FullName 2>$null | Out-Null }

    if (-not (Test-Path 'HKLM:\SOFTWARE\WGKillSwitch')) {
        New-Item -Path 'HKLM:\SOFTWARE\WGKillSwitch' -Force | Out-Null
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'Version' $WG_KS_VERSION -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GuardDir' $GUARD_DIR -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'StartupLnk' $STARTUP_LNK -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GpoScript' $GPO_SCRIPT -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'GpoIni' $GPO_INI -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'NssmPath' $NSSM -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'ServiceScript' $SERVICE_PS1 -Force
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'WmiWrapper' $WMI_WRAPPER -Force
    $runVal = "powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$REPAIR_PS1`""
    Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' 'RunKeyValue' $runVal -Force
    foreach ($pair in @(
        @{ Name = 'TaskXML'; Task = $TASK_MONITOR },
        @{ Name = 'TaskXMLRepair'; Task = $TASK_REPAIR },
        @{ Name = 'TaskXMLRebootVerify'; Task = $TASK_REBOOT_VERIFY },
        @{ Name = 'TaskXMLWatchdog'; Task = $TASK_WATCHDOG }
    )) {
        $tx = Export-TaskXmlSafe $pair.Task
        if ($tx) {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tx))
            Set-ItemProperty 'HKLM:\SOFTWARE\WGKillSwitch' $pair.Name $b64 -Force
        }
    }
}

function Get-EndpointFromConfig {
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match "^\s*Endpoint\s*=" } | Select-Object -First 1
        if ($ep -match "=\s*([^:\s]+):(\d+)") {
            return @{ IP = $Matches[1] + "/32"; Port = [int]$Matches[2] }
        }
        if ($ep -match "=\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)") {
            return @{ IP = $Matches[1] + "/32"; Port = 51820 }
        }
    } catch {}
    return $null
}

function Get-ServerPort {
    if ($CUSTOM_MODE) {
        if ($CustomPort -gt 0) { return "$CustomPort" }
        return "51820"
    }
    return "2408,854"
}

function Get-ServerIPs {
    if ($CUSTOM_MODE) {
        Write-Info "Custom endpoint: $CustomEndpointIP port $(Get-ServerPort)"
        return $CustomEndpointIP
    }
    $ipList = [System.Collections.Generic.List[string]]::new()
    try {
        $ep = (Get-Content $CONFIG -Encoding UTF8 -EA Stop) |
              Where-Object { $_ -match "^\s*Endpoint\s*=" } | Select-Object -First 1
        if ($ep -match "=\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+:") {
            $prefix = $Matches[1] + ".0/24"
            if (-not $ipList.Contains($prefix)) { $ipList.Add($prefix) }
            Write-Info "WARP endpoint from conf: $prefix"
        }
    } catch {}
    if ($ipList.Count -eq 0) {
        @('162.159.192.0/24', '162.159.193.0/24', '162.159.195.0/24', '104.16.0.0/13') |
            ForEach-Object { $ipList.Add($_) }
        Write-Info 'Using WARP IP fallback (hostname endpoint or offline)'
    }
    return ($ipList -join ",")
}
