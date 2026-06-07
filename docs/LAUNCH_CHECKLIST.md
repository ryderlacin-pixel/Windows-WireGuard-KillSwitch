# Launch Checklist — get the repo in front of people

Complete these in order. **English only** for all public posts.

**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch

---

## Current status (auto-checked 2026-06-07)

| Item | Status | Action |
|------|--------|--------|
| Repo public | OK | — |
| README + badges | OK | — |
| Git tag `v10.0` | OK (local + remote) | — |
| Git tag `v10.1` | Push after this doc | `git push origin v10.1` |
| GitHub **Release** | **Missing** | Step 1 (token) or Step 1b (manual) |
| **Topics** | **Empty** | Step 1 or 1b |
| **Discussions** | **Off** | Step 1 or 1b |
| Profile **bio** | **Empty** | Step 1 or edit profile |
| Profile **pin** | Unknown | Step 2 (manual only) |
| Reddit posts | Not done | Step 3 (you, logged in) |

---

## Step 1 — GitHub API (5 minutes, recommended)

### 1a. Create token

Open: https://github.com/settings/tokens/new

| Field | Value |
|-------|-------|
| Note | `wg-killswitch-visibility` |
| Expiration | 90 days |
| Scopes | `repo`, `read:user`, `user:email` |

Copy the token (`ghp_...`) — shown **once**.

### 1b. Run script

```powershell
$env:GITHUB_TOKEN = "ghp_paste_here"
cd C:\Users\seyit\Windows-WireGuard-KillSwitch
.\scripts\github-visibility.ps1
```

This sets topics, enables Discussions, creates releases, updates profile bio.

### 1c. Revoke token (optional, after success)

https://github.com/settings/tokens

---

## Step 1b — Manual GitHub (if no token)

Do each link:

1. **Topics:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/settings  
   → Topics → add: `wireguard`, `warp`, `kill-switch`, `windows`, `powershell`, `vpn`, `firewall`, `privacy`, `wgcf`, `self-hosted`, `cloudflare-warp`

2. **Discussions:** same Settings page → Features → **Discussions** ✓

3. **Release v10.1:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/new  
   - Tag: `v10.1` (create from `main`)  
   - Title: `v10.1 — English script names + docs`  
   - Description: copy from `README.md` changelog v10.1 + install snippet:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\install.ps1
   ```

4. **Profile bio:** https://github.com/settings/profile  
   → Bio: `Windows WireGuard + WARP kill switch — one PowerShell script, 8 recovery layers`

---

## Step 2 — Pin repo (manual, 30 seconds)

1. https://github.com/ryderlacin-pixel?tab=repositories  
2. **Customize your pins**  
3. Select **Windows-WireGuard-KillSwitch**

No API exists for pins — this step is required.

---

## Step 3 — Reddit (you must be logged in)

Reddit blocks automated posting from this environment. Copy-paste from `docs/PROMOTION.md`.

| Priority | Where | What |
|----------|-------|------|
| 1 | [r/PowerShell thread](https://www.reddit.com/r/PowerShell/comments/1tza2u0/refactored_a_monolithic_script_into_a_modular/) | Comment (modular refactor context) |
| 2 | [r/WireGuard](https://www.reddit.com/r/WireGuard/submit) | Standalone release post |
| 3 | [r/selfhosted](https://www.reddit.com/r/selfhosted/submit) | Privacy / automation angle |

**Quick open (PowerShell):**

```powershell
.\scripts\open-launch-links.ps1
```

---

## Step 4 — awesome-wireguard PR (optional, high value)

1. Fork: https://github.com/cedrick-f/awesome-wireguard  
2. Add under **Windows** or **Tools**:

```markdown
- [Windows-WireGuard-KillSwitch](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch) — One-script WireGuard + WARP setup with firewall kill switch and 8 recovery layers for Windows.
```

3. Open PR with title: `Add Windows-WireGuard-KillSwitch`

---

## Step 5 — Hacker News (optional)

https://news.ycombinator.com/submit

- **Title:** `Show HN: Windows WireGuard kill switch – one PowerShell script, 8 recovery layers`
- **URL:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch
- First comment: short technical summary from README (English)

---

## Step 6 — Verify (after Steps 1–3)

```powershell
# Topics visible on repo page?
# Release badge on README working?
# Discussions tab appears?
```

Check: https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch

---

## What we cannot automate

- Reddit login / posting (403 from bots; needs your session)
- GitHub pin order (no public API)
- GitHub topics/releases without your token (unless Step 1b manual)

---

## Copy-paste lives in

- `docs/PROMOTION.md` — all post bodies
- `docs/GITHUB_TOKEN.md` — token help