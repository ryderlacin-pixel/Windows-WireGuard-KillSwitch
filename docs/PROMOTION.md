# Promotion — English-speaking communities only

**Current release:** [v15.1](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.1)

**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch

Use **English only** on public posts. Do not post on Turkish or other non-English tech communities.

---

## Key message (v15.1)

- **Users:** one command — `.\install.ps1`
- **Developers:** implementation split into **`lib/`** (8 modules); orchestrator ~70 lines
- **Default:** free WARP, strong leak/DNS/kill-switch (not max anonymity)
- **Sensitive:** desktop **Hassas-Tarama** — one-step Tor (v15.1)
- **Verify:** `privacy-audit.ps1` STRONG, `safe-live-verify.ps1` 77/77, offline CI 164+ assertions

---

## r/WireGuard — standalone post

**Title:** `[Release] Windows WireGuard Kill Switch v15.1 — free WARP, DNS lock, lib/ modules, 9 recovery layers`

**Body:**

```markdown
**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch  
**Release:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.1

I'm the author. One elevated `install.ps1` (orchestrator) dot-sources `lib/` modules — you still run a single command.

**What it does:**
- WireGuard + anonymous Cloudflare WARP (wgcf, no account)
- Kill switch: firewall blocks outbound when tunnel drops
- v15 privacy: DNS lock → 127.0.0.1, dnscrypt (Quad9), LLMNR/NetBIOS off, leak-sentinel
- 9 recovery layers + watchdog + anti-tamper
- Optional Tor: Hassas-Tarama desktop shortcut (auto-installs Tor if missing, v15.1)

**Install:**
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1 -NoPause
```

**Honest limits:** WARP = Cloudflare is your VPN operator (~7.5–8/10 anonymity). Strong leak protection, not magic exit anonymity.

**Real-world:** Tested in Turkey (ISP-level blocks). Daily use on Windows 11 across reboots.

**Review:** docs/CODE_REVIEW.md · **164+** offline test assertions

MIT. Questions welcome (English).
```

---

## r/PowerShell — post or comment

**Title (new post):** `[Project] 3500-line installer → lib/ modules, still one install.ps1 for users (WireGuard kill switch v15.1)`

**Body:**

```markdown
Refactored production installer into 8 dot-sourced modules under `lib/` while keeping `.\install.ps1` as the only user entry point (~70-line orchestrator).

**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch  
**Release:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.1

- `lib/Install-GeneratedScripts.ps1` — builds monitor/repair/GPO heredocs at install time
- Offline gate: 164+ assertions (parse, heredoc extract, mutex, pattern coverage)
- GitHub Actions CI on every push
- Runtime output still modular under `C:\WireGuard\`

Happy to discuss heredoc testing, WMI self-healing, or install-safe upgrade paths.
```

**Comment thread (optional):** https://www.reddit.com/r/PowerShell/comments/1tza2u0/refactored_a_monolithic_script_into_a_modular/

---

## r/selfhosted — short post

**Title:** `Windows WireGuard + WARP kill switch v15.1 — DNS lock, dnscrypt, 9 recovery layers`

**Body:** Same as r/WireGuard post; emphasize automation, recovery layers, and `live-smoke-test.ps1` post-install gate.

---

## awesome-wireguard PR

```markdown
- [Windows-WireGuard-KillSwitch](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch) — One-command WireGuard + free WARP kill switch for Windows (v15.1: `lib/` modules, DNS lock, dnscrypt, 9 recovery layers).
```

---

## Hacker News (optional)

**Title:** `Show HN: Windows WireGuard kill switch v15.1 – lib/ modules, one install.ps1, strong privacy stack`

Keep first comment technical: lib split, WARP-first, honest anonymity limits, link to CODE_REVIEW.md.