# Code Review Guide

**Audience:** developers reviewing `install.ps1` before trusting it on their machine.

**Current release:** [v15.3.1](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.3.1)

This document answers reviewer questions from v10.2-v10.4 and summarizes v11-v15 production changes. **v15.3.1** is current production (AI-safe DryRun, pre-flight quiesce, 1030+ offline assertions, 0 ERROR/WARN). **v15.2** added boot-safety in [`lib/Install-SafeNetwork.ps1`](../lib/Install-SafeNetwork.ps1) after a confirmed v15.1 reboot deadlock on real hardware. [`install.ps1`](../install.ps1) remains the single entry point.

---

## AI Connection Invariant (v15.3.1 — NEVER violate)

**If install or `-DryRun` kills internet, the user's Cursor/AI session dies too.**

| Rule | Implementation |
|------|----------------|
| Pre-flight first | `Invoke-PreFlightInternetGuard` runs before any install logic (including `-DryRun`) |
| DryRun = preview only | `Invoke-InstallDryRunPreview` — steps 0–20 never execute |
| Hard guard | `Invoke-InstallMainSteps0to6` throws if `$script:InstallDryRun` is set |

Pre-flight quiesce **does** mutate firewall/registry to restore internet (tasks stopped, blocks removed, `KillSwitchArmed=0`). That is intentional — it protects the AI session before preview or install proceeds.

```powershell
.\install.ps1 -DryRun    # pre-flight quiesce + read-only preview (safe on main PC)
.\install.ps1            # pre-flight quiesce + full install (VM first)
```

---

## Quick start for reviewers

1. Read the **DESIGN PHILOSOPHY** block at the top of [`install.ps1`](../install.ps1).
2. Skim **lib module map** below, then recovery layers in [README.md](../README.md#architecture).
3. Compare concerns against the **Review response table** (v10) and **Version history** (v11–v15).
4. Offline gate: `.\scripts\test-suite.ps1` (1030+ assertions), `.\scripts\final-line-audit.ps1` (98 files, 0 ERROR/WARN), `.\scripts\pre-push-gate.ps1`. Live (optional): `.\scripts\live-smoke-test.ps1`.
5. **VM first:** `.\install.ps1 -DryRun` (pre-flight quiesce restores internet, then read-only preview — install steps 0–20 do not run), then full VM install + reboot before physical hardware.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1 -DryRun    # pre-flight quiesce + read-only preview (AI-safe)
.\install.ps1              # real install (VM first)
```

**Network locked?** `emergency-reset.bat` as Administrator (see [v15.2 release notes](releases/v15.2.md)).

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
| 3500-line monolithic script | **Fixed in v15.1** | Split into `lib/*.ps1`; `install.ps1` orchestrator ~70 lines — see [Why lib/ modules?](#why-lib-modules-not-one-3500-line-file) |
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

## Why lib/ modules (not one 3500-line file)?

**Question:** "Why is `install.ps1` still one command if you split the code?"

**Answer (v15.1):**

| Audience | Experience |
|----------|------------|
| **End user** | Still runs only `.\install.ps1` — clone repo, one elevated command |
| **Reviewer** | Reads `install.ps1` (~70 lines) + `lib/*.ps1` (~3200 lines) + `scripts/install-v14|v15-*.ps1` |

`install.ps1` dot-sources `lib/` in a fixed order, then calls `Invoke-InstallMainSteps0to6`, `Invoke-InstallGeneratedScripts`, etc. Generated runtime scripts under `C:\WireGuard\` (monitor, repair, guards) are still produced at install time — that modular output is unchanged since v10.

---

## Architecture (source repo vs runtime)

**Repo (v15.1):**

```
install.ps1 (orchestrator)
    ├── lib/Install-*.ps1 (dot-sourced)
    ├── scripts/install-v14-stack.ps1
    └── scripts/install-v15-privacy-stack.ps1
```

**Target machine (after install):**

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
| v10.7 | Parse fix, layer sync (`Sync-KillSwitchState`), conditional server rule, test suite |
| v11.0–v11.3 | Ultimate hardening, reboot verify, monitor singleton, anti-tamper guard |
| v12.0–v13.5 | Fail-open policy, DNS leak guards, privacy/telemetry hardening, integrity vault |
| v14.0 | dnscrypt-proxy, Tor user.js, leak-sentinel (read-only) |
| v15.0 | System DNS lock, network privacy, strict dnscrypt, sensitive-mode launcher |
| v15.1 | `lib/` modular split, WARP-first docs, one-step Hassas-Tarama, optional CI live-smoke |
| v15.2 | Boot-safe 90s window, `Install-SafeNetwork.ps1`, emergency-reset.bat |
| v15.2.9 | Final line audit (dot-by-dot), file-coverage gate, behavior/reboot sims, 1008+ assertion suite |
| v15.3.0 | KillSwitchArmed gate, DNS lock manual-only, DryRun skipped steps 7–20 |
| v15.3.1 | **AI Connection Invariant:** pre-flight quiesce + DryRun preview-only (steps 0–20 never run) |

See [Releases](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases) for full notes per version.

---

## lib/ module map (v15.3.1)

| Module | Role |
|--------|------|
| `Install-Constants.ps1` | Paths, service names, registry keys |
| `Install-Helpers.ps1` | Logging, mutex, Test-Internet, tunnel/WMI/task helpers |
| `Install-Privacy.ps1` | Browser policies, telemetry reduction, guard vault |
| `Install-UpgradePaths.ps1` | `-StrongPrivacyUpgrade` and phased upgrade early-exit |
| `Install-DryRunPreview.ps1` | Read-only `-DryRun` preview (`Invoke-InstallDryRunPreview`) |
| `Install-MainSteps-0-6.ps1` | WireGuard, firewall, tunnel (STEP 0-6); throws in DryRun |
| `Install-SafeNetwork.ps1` | Boot-safe window, `Invoke-PreFlightInternetGuard`, `Invoke-SafeNetsh`, wg-safety.ps1, fail-open |
| `Install-GeneratedScripts.ps1` | monitor/repair/watchdog/anti-tamper heredocs |
| `Install-TasksAndWmi.ps1` | Scheduled tasks, NSSM, WMI, GPO boot script |
| `Install-MainSteps-18-20.ps1` | Privacy stacks, activation, final checks |

Dot-sourced stacks: `scripts/install-v14-stack.ps1`, `scripts/install-v15-privacy-stack.ps1`.

---

## Why lib/ modules (not one 3500-line file)?

**v15.2.9** keeps `.\install.ps1` as the user-facing command while moving generated-script builders and step logic into 9 reviewable `lib/` modules. Offline tests parse every production file, extract generated scripts, run behavior/reboot sims, and enforce a final line audit (0 ERROR/WARN).