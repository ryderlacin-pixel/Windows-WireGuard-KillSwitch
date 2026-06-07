# Launch Checklist — get the repo in front of people

Complete these in order. **English only** for all public posts.

**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch

---

## Current status (2026-06-08)

| Item | Status | Action |
|------|--------|--------|
| Repo public | OK | — |
| README + badges | OK | — |
| Git tags `v10.0` / `v10.1` / `v10.4` | OK | — |
| GitHub **Release v10.0** | OK | — |
| GitHub **Release v10.1** | OK | — |
| GitHub **Release v10.4** | Run script | Step 1 below |
| **Topics** | OK | — |
| **Discussions** | OK | — |
| **CODE_REVIEW.md** | OK | Link in README |
| Profile **pin** | Manual | Step 2 |
| Reddit posts | Not done | Step 3 (you, logged in) |

---

## Step 1 — Publish releases (2 minutes)

### 1a. Create token (if needed)

https://github.com/settings/tokens/new — scopes: `repo`, `read:user`, `user:email`

### 1b. Run script

```powershell
$env:GITHUB_TOKEN = "ghp_paste_here"
cd C:\Users\seyit\Windows-WireGuard-KillSwitch
.\scripts\publish-releases.ps1
```

Creates/updates **v10.0**, **v10.1**, **v10.4** with reviewer-focused release notes.

Full visibility (topics, bio, discussions): `.\scripts\github-visibility.ps1`

### 1c. Revoke token after success

https://github.com/settings/tokens

---

## Step 2 — Pin repo (manual, 30 seconds)

1. https://github.com/ryderlacin-pixel?tab=repositories
2. **Customize your pins**
3. Select **Windows-WireGuard-KillSwitch**

---

## Step 3 — Reddit (you must be logged in)

Copy-paste from `docs/PROMOTION.md`.

```powershell
.\scripts\open-launch-links.ps1
```

---

## Step 4 — awesome-wireguard PR (optional)

Fork https://github.com/cedrick-f/awesome-wireguard and add:

```markdown
- [Windows-WireGuard-KillSwitch](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch) — One-script WireGuard + WARP setup with firewall kill switch and 8 recovery layers for Windows.
```

---

## Step 5 — Point reviewers to CODE_REVIEW.md

When sharing the repo with developers, link:

- https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/blob/main/docs/CODE_REVIEW.md
- https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v10.4

---

## Copy-paste lives in

- `docs/PROMOTION.md` — Reddit / forum posts
- `docs/CODE_REVIEW.md` — reviewer Q&A
- `docs/GITHUB_TOKEN.md` — token help
- `scripts/publish-releases.ps1` — release note bodies