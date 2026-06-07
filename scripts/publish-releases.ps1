#Requires -Version 5.1
<#
.SYNOPSIS
  Create or update GitHub Releases with reviewer-focused release notes.

.USAGE
  $env:GITHUB_TOKEN = "ghp_xxxxxxxx"
  .\scripts\publish-releases.ps1

  # Create only v10.4:
  .\scripts\publish-releases.ps1 -Only v10.4
#>
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Owner = "ryderlacin-pixel",
    [string]$Repo  = "Windows-WireGuard-KillSwitch",
    [string]$Only  = ""   # empty = all; or "v10.4"
)

$ErrorActionPreference = "Stop"
if (-not $Token) {
    Write-Host "[ERROR] GITHUB_TOKEN not set." -ForegroundColor Red
    Write-Host "See docs/GITHUB_TOKEN.md"
    exit 1
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-GH($Method, $Uri, $Body) {
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 6)
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

$releases = @{
    "v10.0" = @{
        name = "v10.0 - Production-hardened kill switch"
        body = @'
## v10.0 — Production-hardened kill switch

First public production release after fixing critical monitor/repair bugs found in earlier private builds.

### Install
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

Custom server:
```powershell
.\install.ps1 -CustomConfig "C:\path\to\myvpn.conf"
```

### Highlights
- **Critical fix:** process detection no longer confuses `service-monitor.ps1` with `monitor.ps1` (prevents monitor kill loop)
- Repair firewall check fixed (no false "policy corrected" spam every 5 minutes)
- Scheduled tasks survive battery mode
- Service monitor 60s poll + 2-minute repair cooldown
- WMI + repair only target main `monitor.ps1`
- Migrates legacy `WG-OnarimGorevi` to `WG-RepairTask`

### Recovery layers (8)
`monitor.ps1` → `repair.ps1` → `WG-KillSwitch` task → `WG-RepairTask` → `WGKillSwitchSvc` → WMI → Run key → GPO boot script

MIT licensed — no personal data in repo.
'@
    }
    "v10.1" = @{
        name = "v10.1 - English script names + docs"
        body = @'
## v10.1 — English script names + documentation

### Changes
- Generated scripts renamed: `repair.ps1`, `service-monitor.ps1`, `wmi-repair.ps1`
- Monitor functions Englishized (`Test-Internet`, `Enable-Block`, `Disable-Block`, etc.)
- Legacy Turkish filenames removed on upgrade reinstall
- Real-world testing section (ISP-level blocks + WARP + kill switch)
- `CONTRIBUTING.md` + launch/promotion docs

### Install
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

**Full changelog:** [README.md#changelog](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch#changelog)
'@
    }
    "v10.4" = @{
        name = "v10.4 - Production-hardened (code review response)"
        body = @'
## v10.4 — Production-hardened installer (responds to code review)

This release addresses every issue raised during external review of v10.2–v10.3 drafts.

**For reviewers:** see [docs/CODE_REVIEW.md](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/blob/main/docs/CODE_REVIEW.md) — full Q&A table, architecture, and verification commands.

### Install / upgrade
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```
Re-running the installer upgrades an existing `C:\WireGuard\` install in place.

---

### Bugs fixed (reviewer-reported)

| Issue | Fix |
|-------|-----|
| `Test-Internet` false positive | `EndConnect` must succeed, not just async `WaitOne` |
| `*monitor.ps1*` matched `service-monitor.ps1` | Strict regex `(?:\\|/)monitor\.ps1` everywhere + WMI WQL |
| Repair `schtasks` path escaping | `$taskRun = '\' + $TASK_MONITOR` |
| Monitor heredoc line-continuation bugs | Single-line `netsh` in generated `monitor.ps1` |
| Double Cloudflare API call | `$serverIPs` cached once; shared by firewall + monitor + registry |
| NSSM zip null entry crash | Path normalize + null-guard before extract |
| DNS leak via TCP/53 | `KS-DNS-Block-TCP` rule |
| IPv6 / NAT64 leaks | Extended block ranges + adapter binding disable |
| `wireguard.exe` blocked | `KS-WireGuard-EXE` allow rule |
| Duplicate monitors | `Global\WGMainMonitorMutex` single instance |
| Task Scheduler `P9999D` failure | `RepetitionDuration = 3650` days |

---

### Hardening kept from v10.2–v10.3
- Design philosophy header in `install.ps1` (lines 11–26)
- PowerShell splatting (readability)
- Repair script `@'…'@` heredoc refactor
- Registry stores resolved WARP server IPs (`ServerIP`)

---

### Verify after install
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" | Select Version, ServerIP
Get-NetFirewallRule -DisplayName "KS-DNS-Block*"
Select-String -Path C:\WireGuard\monitor.ps1 -Pattern "EndConnect"
```

---

### Recovery layers (unchanged — 8 layers)
`monitor.ps1` → `repair.ps1` → `WG-KillSwitch` → `WG-RepairTask` → `WGKillSwitchSvc` → WMI → Run key → GPO boot script

**Why WMI?** Intentional — only native zero-dependency way to respawn monitor if killed. See CODE_REVIEW.md.

MIT licensed — no keys or personal configs in repo.
'@
    }
}

function Publish-Release($tag, $name, $body) {
    try {
        $existing = Invoke-GH GET "https://api.github.com/repos/$Owner/$Repo/releases/tags/$tag" $null
        Write-Host "  UPDATE: $tag (release id $($existing.id))" -ForegroundColor Yellow
        Invoke-GH PATCH "https://api.github.com/repos/$Owner/$Repo/releases/$($existing.id)" @{
            name       = $name
            body       = $body
            draft      = $false
            prerelease = $false
        } | Out-Null
        Write-Host "  OK: $tag updated" -ForegroundColor Green
    } catch {
        try {
            Invoke-GH POST "https://api.github.com/repos/$Owner/$Repo/releases" @{
                tag_name         = $tag
                target_commitish = "main"
                name             = $name
                body             = $body
                draft            = $false
                prerelease       = $false
            } | Out-Null
            Write-Host "  OK: $tag created" -ForegroundColor Green
        } catch {
            Write-Host "  FAIL $tag : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host "=== Publish GitHub Releases ===" -ForegroundColor Cyan
$toPublish = if ($Only) { @($Only) } else { @("v10.0", "v10.1", "v10.4") }

foreach ($tag in $toPublish) {
    if (-not $releases.ContainsKey($tag)) {
        Write-Host "  SKIP: unknown tag $tag" -ForegroundColor Gray
        continue
    }
    $r = $releases[$tag]
    Publish-Release $tag $r.name $r.body
}

Write-Host ""
Write-Host "Releases: https://github.com/$Owner/$Repo/releases" -ForegroundColor Cyan
Write-Host "Reviewers: https://github.com/$Owner/$Repo/blob/main/docs/CODE_REVIEW.md" -ForegroundColor Cyan
Write-Host "Done." -ForegroundColor Green