# GitHub API Token — Quick Setup

## 1. Create a token

**Classic token (recommended):**

https://github.com/settings/tokens/new

| Field | Value |
|-------|-------|
| Note | `wg-killswitch-visibility` |
| Expiration | 90 days (or No expiration) |
| Scopes | `repo`, `read:user`, `user:email` |

Click **Generate token** and copy the value (`ghp_...`). It is shown only once.

**Fine-grained alternative:**

https://github.com/settings/personal-access-tokens/new

- Repository access: Only `Windows-WireGuard-KillSwitch`
- Permissions: Contents (Read/Write), Metadata (Read), Discussions (Read/Write), Administration (Read/Write)

---

## 2. Set the token in PowerShell (one-time)

```powershell
$env:GITHUB_TOKEN = "ghp_paste_your_token_here"
```

---

## 3. Run the automation script

```powershell
cd C:\Users\seyit\Windows-WireGuard-KillSwitch
.\scripts\github-visibility.ps1
```

The script will:

- Add repository topics (`wireguard`, `kill-switch`, `powershell`, …)
- Enable Discussions
- Create the `v10.0` GitHub Release (if missing)
- Update your profile bio

---

## 4. One manual step (no API)

Pin the repo on your profile:

https://github.com/ryderlacin-pixel?tab=repositories

→ **Customize your pins** → select `Windows-WireGuard-KillSwitch`

---

## Security

- Do not paste the token into chat or commit it to git
- Revoke when done: https://github.com/settings/tokens