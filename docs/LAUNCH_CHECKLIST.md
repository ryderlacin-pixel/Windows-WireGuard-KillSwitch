# Launch Checklist - get the repo in front of people

Complete these in order. **English only** for all public posts.

**Repo:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch
**Latest release:** https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.2.9

---

## Current status (2026-06-08)

| Item | Status | Action |
|------|--------|--------|
| Repo public | OK | - |
| README + badges (v15.2.9, `lib/`, WARP-first) | OK | - |
| Git tags through **v15.2.9** | OK | - |
| GitHub **Release v15.2.9** (latest) | OK | - |
| **Topics** + repo description | Run script | Step 1b `github-visibility.ps1` |
| **Discussions** | OK | - |
| **CODE_REVIEW.md** (v15.2.9 + lib map) | OK | - |
| **PROMOTION.md** (v15.2.9 copy) | OK | Step 3 |
| Profile **pin** | Manual | Step 2 |
| Reddit posts | Not done | Step 3 (you, logged in) |
| Offline test gate (1008+ assertions) | OK | `scripts/test-suite.ps1` |
| Final line audit (0 ERROR/WARN) | OK | `scripts/final-line-audit.ps1` |

---

## Step 1 - GitHub metadata (2 minutes)

### 1a. Create token (if needed)

https://github.com/settings/tokens/new - scopes: `repo`, `read:user`, `user:email`

### 1b. Run scripts

```powershell
$env:GITHUB_TOKEN = "ghp_paste_here"
cd C:\Users\seyit\Windows-WireGuard-KillSwitch
.\scripts\github-visibility.ps1
```

Updates: topics, repo description, discussions, profile bio, release pages.

Publish **v15.2.9** (current production):

```powershell
.\scripts\publish-releases.ps1 -Only v15.2.9
```

### 1c. Revoke token after success

https://github.com/settings/tokens

---

## Step 2 - Pin repo (manual, 30 seconds)

1. https://github.com/ryderlacin-pixel?tab=repositories
2. **Customize your pins**
3. Select **Windows-WireGuard-KillSwitch**

---

## Step 3 - Reddit (you must be logged in)

Copy-paste from **`docs/PROMOTION.md`** (v15.2.9 - not v10.x).

```powershell
.\scripts\open-launch-links.ps1
```

---

## Step 4 - awesome-wireguard PR (optional)

```markdown
- [Windows-WireGuard-KillSwitch](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch) - One-command WireGuard + free WARP kill switch (v15.2.9: lib/ modules, DNS lock, 9 recovery layers).
```

---

## Step 5 - Point reviewers to CODE_REVIEW.md

- https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/blob/main/docs/CODE_REVIEW.md
- https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.2.9
- Repository layout: **README -> Architecture -> Repository layout (`lib/`)**

---

## Copy-paste lives in

- `docs/PROMOTION.md` - Reddit / forum posts (v15.2.9)
- `docs/CODE_REVIEW.md` - reviewer Q&A + lib module map
- `docs/GITHUB_TOKEN.md` - token help
- `docs/releases/v15.2.9.md` - release notes body
- `scripts/publish-releases.ps1` - GitHub Releases API
- `audit-results/` - final line audit manifest + SHA256SUMS