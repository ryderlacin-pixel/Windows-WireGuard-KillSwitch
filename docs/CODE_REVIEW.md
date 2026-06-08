# Code Review Guide

**Audience:** developers reviewing `install.ps1` before trusting it on their machine.

**Current release:** [v10.7](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v10.7)

This document answers the questions raised during external review of v10.2–v10.3 and explains what changed in **v10.4**.

---

## Quick start for reviewers

1. Read the **DESIGN PHILOSOPHY** block at the top of [`install.ps1`](../install.ps1) (lines 11–26).
2. Skim the **8 recovery layers** in [README.md](../README.md#architecture).
3. Compare your concerns against the **Review response table** below.
4. Test on a VM — never on your only machine first.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

---

## Review response table (v10.2 → v10.4)

| Reviewer concern | Status in v10.4 | What we did |
|------------------|-----------------|-------------|
| `Test-Internet` false positive — `WaitOne` succeeds even when TCP connect fails | **Fixed** | `EndConnect` must succeed; `finally` closes socket |
| `*monitor.ps1*` substring matches `service-monitor.ps1` | **Fixed** | Shared `Test-IsMainMonitor` regex: `(?:\\|/)monitor\.ps1(?:\s|"|$)` used in cleanup, repair, STEP 19, WMI WQL |
| Repair `schtasks /Run /TN` path escaping broken | **Fixed** | `$taskRun = '\' + $TASK_MONITOR` — explicit backslash concat, no broken backtick escaping |
| Monitor heredoc backticks cause line-continuation bugs in generated script | **Fixed** | Single-line `netsh` calls in generated `monitor.ps1`; repair uses `@'…'@` heredoc for static body |
| Double Cloudflare API call (`Get-ServerIPs` in STEP 6 + STEP 7) | **Fixed** | `$serverIPs` cached once; monitor embeds same values; registry `ServerIP` stores resolved IPs in WARP mode |
| NSSM zip extract can throw on null entry | **Fixed** | Path normalized (`/` vs `\`); null-guard before `ExtractToFile` |
| DNS leak via TCP port 53 | **Fixed** | `KS-DNS-Block-TCP` rule added (UDP was already blocked except 1.1.1.1 / 1.0.0.1) |
| IPv6 / NAT64 leak paths | **Fixed** | Extended ranges: `::1/128`, `64:ff9b::/96`, `64:ff9b:1::/48`, `100::/64` + adapter binding disable |
| `wireguard.exe` blocked by catch-all rules | **Fixed** | `KS-WireGuard-EXE` allow rule for `C:\Program Files\WireGuard\wireguard.exe` |
| Duplicate monitor processes after reboot | **Fixed** | `Global\WGMainMonitorMutex` — second instance exits immediately |
| `AbandonedMutexException` kills respawned monitor (`catch { exit 0 }`) | **Fixed in v10.5** | `Wait-NamedMutex` treats abandonment as successful acquire (MS docs); duplicate instance still exits on `WaitOne` timeout |
| Open internet when tunnel RUNNING but no traffic (zombie service) | **Fixed in v10.6** | `Test-SafeToOpen` = tunnel + dual-host `Test-Internet`; main loop recovery for zombie state |
| 3min wait opens internet on tunnel-only check | **Fixed in v10.6** | Recovery success requires `Test-SafeToOpen` |
| Tethering/PPP leak via non-LAN interfaces | **Fixed in v10.6** | `KS-Block-RemoteAccess-Out`, `KS-Block-PPP-Out` |
| Stale WARP server IPs in generated monitor | **Fixed in v10.6** | `Get-ResolvedServerIP` + periodic refresh in `Ensure-ServerRule` |
| Log corruption when log mutex times out | **Fixed in v10.6** | Skip write if mutex not acquired |
| `pwsh.exe` monitor invisible to WMI/repair | **Fixed in v10.6** | `Get-MonitorShellProcs` + WMI WQL includes `pwsh.exe` |
| `Get-MainMonitorProcs()` parse error on PS 5.1 (script won't compile) | **Fixed in v10.7** | Removed broken alias; use `Get-MonitorShellProcs` |
| repair/GPO out of sync with monitor SafeToOpen | **Fixed in v10.7** | `Sync-KillSwitchState` in repair; GPO waits `Test-SafeToOpen` |
| `Ensure-ServerRule` netsh delete/add every 5s | **Fixed in v10.7** | `Set-ServerRule` only on IP change or missing rule |
| `Test-Internet` single-host / OR-only | **Fixed in v10.7** | 2-of-3 hosts (1.1.1.1, 1.0.0.1, 8.8.8.8) |
| Task Scheduler `P9999D` repetition duration fails on some builds | **Fixed** | `RepetitionDuration = 3650 days` (10 years) |
| WMI looks like overkill / security risk | **By design** | See [Why WMI?](#why-wmi) below |
| 1200-line monolithic script | **Acknowledged** | Single-file installer is intentional — generates runtime scripts to `C:\WireGuard\`; see [Why one file?](#why-one-file) |
| `SilentlyContinue` hides real errors | **Partial** | Install-time errors use `Write-Err` + `exit 1` on critical paths; runtime scripts use silent continue to avoid monitor crash loops |

---

## Why WMI?

**Question:** "Isn't WMI Permanent Event Subscription dangerous / overkill?"

**Answer:** It is the only **native, zero-dependency** way on Windows to detect when the main `monitor.ps1` process is killed and respawn protection without a third-party watchdog.

| Without WMI | With WMI |
|-------------|----------|
| User kills `monitor.ps1` in Task Manager → kill switch may stop checking tunnel state | Deletion event fires → `wmi-repair.ps1` → `repair.ps1` restarts monitor |
| Requires external service (NSSM helps but is another layer) | Complements NSSM + scheduled tasks — defense in depth |

**Scope limits:**
- WQL filter matches `powershell.exe` or `pwsh.exe` whose command line contains `\monitor.ps1` or `/monitor.ps1`
- Does **not** match `service-monitor.ps1`, `repair.ps1`, or `wmi-repair.ps1`
- Consumer runs `wmi-repair.ps1` (thin wrapper), not arbitrary code

---

## Why one file?

**Question:** "Why not split into modules?"

**Answer:** The repo ships **one copy-paste installer** for non-developers. `install.ps1`:
1. Downloads WireGuard / wgcf / NSSM
2. Writes `monitor.ps1`, `repair.ps1`, `wmi-repair.ps1`, `service-monitor.ps1` to `C:\WireGuard\`
3. Registers tasks, service, WMI, firewall, GPO boot script

Splitting into modules would require a build step or multiple files users must keep together. The generated runtime scripts under `C:\WireGuard\` are the modular output.

---

## Architecture (what runs after install)

```
install.ps1 (run once)
    └── C:\WireGuard\
            ├── monitor.ps1          ← main loop: tunnel up/down → firewall
            ├── repair.ps1           ← every 5 min + on demand: heal tasks/service/tunnel
            ├── wmi-repair.ps1       ← WMI consumer entry point
            └── service-monitor.ps1  ← NSSM service wrapper

Recovery layers (any one can restore the others):
  1. monitor.ps1 loop
  2. repair.ps1 (scheduled + Run key)
  3. WG-KillSwitch scheduled task (60s boot delay)
  4. WG-RepairTask (30s boot + every 5 min)
  5. WGKillSwitchSvc (NSSM)
  6. WMI __InstanceDeletionEvent on monitor.ps1
  7. HKLM Run → repair.ps1
  8. GPO Machine Startup script
```

---

## Firewall model

**Default policy:** `blockinbound,allowoutbound` on all profiles.

**Block rules** (active when tunnel is down):
- Wi-Fi and Ethernet outbound to `0.0.0.0/1` + `128.0.0.0/1` (everything except LAN ranges handled by allow rules)

**Allow rules** (always):
- LAN (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`)
- DHCP (UDP 68→67)
- Loopback
- DNS UDP to `1.1.1.1`, `1.0.0.1` only
- WARP/Custom server UDP to resolved endpoint IPs
- `wireguard.exe` outbound

**Explicit blocks:**
- All other DNS (UDP + TCP port 53)
- IPv6 (multiple ranges + adapter binding disabled + `DisabledComponents=0xFF`)

When tunnel is **running** and internet test passes, Wi-Fi/Ethernet block rules are **removed** — traffic flows through the tunnel interface.

---

## Security & privacy

| Item | Detail |
|------|--------|
| Personal keys in repo | **None** — `.conf` generated on target machine via wgcf |
| Network calls during install | WireGuard MSI, wgcf binary, NSSM zip, Cloudflare trace/API for server IPs |
| Persistence | Scheduled tasks (SYSTEM), Windows service, WMI subscription, Run key, GPO script |
| Log file | `C:\WireGuard\killswitch.log` (rotated at 500 lines) |
| Uninstall | Re-run installer after manual tunnel removal, or delete tasks/service/rules manually |

**Threat model:** Primary goal — **accidental VPN leak** when tunnel drops. **v11.3+** adds anti-tamper guard (silent restore of deleted tasks/scripts/firewall/WMI/service from `C:\ProgramData\WGKillSwitchGuard` + registry). This raises the bar against deliberate tampering but **cannot** fully stop a determined local admin (Windows admin = root).

---

## How to verify fixes yourself

```powershell
# 1. Version in registry after install
Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch" | Select Version, ServerIP, InstalledDate

# 2. Main monitor only (not service-monitor)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match '(?:\\|/)monitor\.ps1(?:\s|"|$)' } |
  Select ProcessId, CommandLine

# 3. DNS rules (UDP + TCP block)
Get-NetFirewallRule -DisplayName "KS-DNS-Block*"

# 4. Test-Internet logic (in generated monitor.ps1)
Select-String -Path C:\WireGuard\monitor.ps1 -Pattern "EndConnect"

# 5. Repair schtasks path
Select-String -Path C:\WireGuard\repair.ps1 -Pattern "taskRun"
```

---

## Suggested review order

1. `param()` + STEP 0 validation (custom mode)
2. STEP 3 cleanup — `Test-IsMainMonitor` usage
3. STEP 4 IPv6 rules
4. STEP 6 firewall — `$serverIPs` cache
5. STEP 7 monitor heredoc — `Test-Internet`, mutex
6. STEP 8 repair heredoc — `@'…'@`, `schtasks` path
7. STEP 15 WMI WQL query
8. STEP 19 final check — `Get-MainMonitorProcs`

---

## Reporting issues

- **Bug:** [Bug report template](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/issues/new?template=bug_report.md)
- **Security:** Open a GitHub issue with `[Security]` prefix (no public exploit details until fixed)
- **Design discussion:** [GitHub Discussions](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/discussions)

All reports must be in **English**.

---

## Version history (reviewer-relevant)

| Version | Reviewer focus |
|---------|----------------|
| v10.0 | `service-monitor.ps1` vs `monitor.ps1` confusion; repair firewall spam |
| v10.1 | English filenames; real-world testing notes |
| v10.4 | All v10.2–v10.3 review items addressed; design doc in `install.ps1` header |
| v10.5 | AbandonedMutexException-safe mutex waits (monitor respawn after kill) |
| v10.6 | Zombie-tunnel prevention, tethering/PPP blocks, runtime WARP IP refresh, pwsh support |
| v10.7 | Parse fix, layer sync (`Sync-KillSwitchState`), conditional server rule, 30-assertion test suite |

See [Releases](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases) for full notes per version.