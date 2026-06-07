# GitHub API Token — Quick Setup

## 1. Token oluştur

**Classic token (önerilen, en kolay):**

https://github.com/settings/tokens/new

| Alan | Değer |
|------|-------|
| Note | `wg-killswitch-visibility` |
| Expiration | 90 days (veya No expiration) |
| Scopes | `repo`, `read:user`, `user:email` |

**Create token** → token'ı kopyala (`ghp_...`). Bir daha gösterilmez.

**Fine-grained alternatif:**

https://github.com/settings/personal-access-tokens/new

- Repository access: Only `Windows-WireGuard-KillSwitch`
- Permissions: Contents (Read/Write), Metadata (Read), Discussions (Read/Write), Administration (Read/Write)

---

## 2. Token'ı PowerShell'e ver (tek seferlik)

```powershell
$env:GITHUB_TOKEN = "ghp_BURAYA_TOKEN_YAPIŞTIR"
```

---

## 3. Otomatik script çalıştır

```powershell
cd C:\Users\seyit\Windows-WireGuard-KillSwitch
.\scripts\github-visibility.ps1
```

Script şunları yapar:
- Topics ekler (`wireguard`, `kill-switch`, `powershell`, …)
- Discussions açar
- `v10.0` GitHub Release oluşturur
- Profil bio günceller

---

## 4. Elle yapılacak tek adım (API yok)

Profilde repoyu **pin** et:

https://github.com/ryderlacin-pixel?tab=repositories

→ **Customize your pins** → `Windows-WireGuard-KillSwitch` seç

---

## Güvenlik

- Token'ı chat'e yapıştırma; sadece kendi PowerShell oturumunda kullan
- İş bitince token'ı revoke edebilirsin: https://github.com/settings/tokens