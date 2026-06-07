# Promotion — English-speaking communities only

This project is maintained for an **English-speaking audience**. Use the copy below on English platforms only.

**Do not post on:** Turkish forums, localized subreddits, or non-English tech communities.

---

## r/WireGuard — standalone post

**Title:** `[Release] Windows WireGuard Kill Switch — one PowerShell script, anonymous WARP, 8 recovery layers (v10.0)`

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

## r/PowerShell — comment on modular-script thread

**Link:** https://www.reddit.com/r/PowerShell/comments/1tza2u0/refactored_a_monolithic_script_into_a_modular/

Use the full comment from the visibility plan (English technical write-up + repo link).

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