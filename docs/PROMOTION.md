# Promotion — English-speaking communities only

This project is maintained for an **English-speaking audience**. Use the copy below on English platforms only.

**Do not post on:** Turkish forums, localized subreddits, or non-English tech communities.

---

## r/WireGuard — standalone post

**Title:** `[Release] Windows WireGuard Kill Switch — one PowerShell script, anonymous WARP, 8 recovery layers (v10.1)`

**Body:**

```
Repo: https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch

One elevated PowerShell script that:
- Installs WireGuard if missing
- Generates an anonymous Cloudflare WARP config via wgcf (no account)
- Applies a real kill switch (firewall blocks outbound when tunnel is down)
- Installs 8 redundant recovery layers (monitor, repair, tasks, NSSM service, WMI, GPO, startup)

Custom server mode:
  .\install.ps1 -CustomConfig "C:\path\to\myvpn.conf"

v10.0 fixes a critical bug where repair killed the main monitor while the tunnel was still up.

MIT licensed. No personal keys in the repo.

Happy to answer questions in English.
```

---

## r/PowerShell — comment on modular-script thread (PRIORITY)

**Link:** https://www.reddit.com/r/PowerShell/comments/1tza2u0/refactored_a_monolithic_script_into_a_modular/

**Paste this entire comment:**

```
I went the opposite direction on a similar problem — one monolithic installer that *generates* modular runtime components at deploy time.

**Project:** Windows WireGuard + Cloudflare WARP kill switch (PowerShell)
**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch
**Version:** v10.1 (production-hardened, tested across reboots on Windows 11)

### What it does
- One `install.ps1` run as Admin — no manual WireGuard setup
- Auto-installs WireGuard if missing
- Generates an **anonymous** Cloudflare WARP config via `wgcf` (no email/login)
- Applies a real **kill switch** via Windows Firewall — if the tunnel drops, outbound internet is blocked immediately
- 8 redundant recovery layers so the tunnel/monitor come back after crash or reboot

### Runtime layout (modular, installed by one script)
After install, everything lives in `C:\WireGuard\`:
- `monitor.ps1` — main loop (5s poll, tunnel recovery)
- `repair.ps1` — system repair
- `service-monitor.ps1` — NSSM service wrapper
- `wmi-repair.ps1` — WMI event consumer
- Scheduled tasks: `WG-KillSwitch`, `WG-RepairTask`
- Windows service: `WGKillSwitchSvc`
- GPO boot script + startup shortcut + registry guard

### Custom server support
```powershell
.\install.ps1 -CustomConfig "C:\path\to\myvpn.conf"
.\install.ps1 -CustomConfig "..." -CustomTunnel "myvpn" -CustomEndpointIP "1.2.3.4/32" -CustomPort 51820
```

### v10.0 — critical bug we fixed
Process detection used to match `service-monitor.ps1` when looking for `monitor.ps1` (substring match). Repair killed the *real* monitor while the tunnel was still up → kill switch dead. Fix: strict regex `(?:\\|/)monitor\.ps1(?:\s|"|$)` everywhere.

Also: false firewall "policy corrected" spam, battery-mode tasks, repair cooldown storms, dual tunnel health check.

### Privacy
No personal data in the repo. WARP registration is anonymous. Keys/configs stay local.

### Kill switch behavior
| State | Result |
|-------|--------|
| Tunnel up | Normal internet via VPN |
| Tunnel down | Outbound blocked on Wi-Fi/Ethernet |
| Reboot | Block active until tunnel confirmed running |

MIT licensed. Happy to answer questions.
```

---

## r/selfhosted — short post

**Title:** `Automated Windows WireGuard + WARP kill switch with 8 recovery layers`

**Body:** Same as r/WireGuard, add privacy angle (anonymous WARP, no email, firewall leak protection).

---

## awesome-wireguard PR

Add one line under a **Windows** or **Tools** section:

```markdown
- [Windows-WireGuard-KillSwitch](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch) — One-script WireGuard + WARP setup with firewall kill switch and 8 recovery layers for Windows.
```

---

## Hacker News (optional)

**Title:** `Show HN: Windows WireGuard kill switch – one PowerShell script, 8 recovery layers`

Keep the first comment technical and concise. Reply in English only.