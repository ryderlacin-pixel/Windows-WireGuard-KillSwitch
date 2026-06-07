# Windows WireGuard Kill Switch (WARP Auto-Setup)

> **One script. No config. No personal info. Full kill switch.**

Automatically installs WireGuard + Cloudflare WARP on Windows with a hardened kill switch that blocks all traffic if the VPN drops. **v1.1** adds first-class support for your own WireGuard server.

---

## What it does

1. **Downloads & installs WireGuard** silently (if not already installed)
2. **Downloads wgcf** and generates an **anonymous** Cloudflare WARP account — no email, no login
3. **Applies a kill switch** via Windows Firewall that blocks all internet traffic unless the VPN tunnel is active
4. **Installs 8 redundant recovery layers** so the VPN restarts automatically after crashes or reboots

No personal data is stored anywhere. The WARP registration is completely anonymous.

---

## Requirements

- Windows 10 / 11 (x64)
- PowerShell 5.1+
- Run as **Administrator**
- Internet access during setup

---

## Installation

### Default — Cloudflare WARP (anonymous)

```powershell
# 1. Download install.ps1
# 2. Right-click → "Run with PowerShell" as Administrator
#    OR open an elevated PowerShell and run:

Set-ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

That's it. No manual WireGuard setup. No account creation. Fully automated.

### Custom WireGuard server (v1.1)

Use your own `.conf` file instead of WARP. WireGuard is still installed automatically; only wgcf/WARP generation is skipped.

**Minimum** — endpoint and port are read from the config file:

```powershell
.\install.ps1 -CustomConfig "C:\path\to\myvpn.conf"
```

Tunnel name defaults to the config filename (`myvpn.conf` → tunnel `myvpn`).

**Full control:**

```powershell
.\install.ps1 `
  -CustomConfig "C:\path\to\myvpn.conf" `
  -CustomTunnel "myvpn" `
  -CustomEndpointIP "1.2.3.4/32" `
  -CustomPort 51820
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-CustomConfig` | Yes (custom mode) | Path to your WireGuard `.conf` file |
| `-CustomTunnel` | No | Tunnel/service name (default: config filename) |
| `-CustomEndpointIP` | No* | Server IP or CIDR for firewall allow rule |
| `-CustomPort` | No* | WireGuard UDP port (default: `51820`) |

\*If omitted, `Endpoint = IP:PORT` is parsed from the config file.

Custom settings are baked into generated `monitor.ps1`, `onarim.ps1`, and GPO scripts at install time, and stored in `HKLM:\SOFTWARE\WGKillSwitch`.

---

## How the kill switch works

| Situation | Behavior |
|-----------|----------|
| VPN tunnel **running** | All internet traffic flows normally through the tunnel |
| VPN tunnel **drops** | Internet is **immediately blocked** via firewall rules |
| VPN **recovers** | Internet is automatically unblocked, DNS cache flushed |
| System **reboots** | Kill switch activates before any traffic can leak |

### Firewall rules applied

- `KS-Block-WiFi-Out` / `KS-Block-Ethernet-Out` — blocks all outbound traffic on real adapters
- `KS-LAN-*` — allows local network (192.168.x.x, 10.x.x.x, 172.16.x.x)
- `KS-DHCP-*` — allows DHCP so the adapter can get an IP
- `KS-DNS-Allow` — allows DNS only to 1.1.1.1 and 1.0.0.1
- `KS-DNS-Block` — blocks all other DNS (prevents leaks)
- `KS-WARP-Server-Out` — allows UDP to VPN server endpoints (WARP or custom) so the tunnel can reconnect
- `KS-Block-IPv6-*` — blocks all IPv6 (prevents leaks)

---

## Recovery layers (8 total)

If anything goes wrong (crash, update, kill), the system recovers automatically:

| Layer | Description |
|-------|-------------|
| **monitor.ps1** | Main loop — checks tunnel every 5s, recovers if down |
| **onarim.ps1** | System repair script — restarts missing components |
| **WG-KillSwitch** | Scheduled task, runs at boot (60s delay) + restarts on failure |
| **WG-RepairTask** | Scheduled task, runs at boot (30s delay) + every 5 minutes |
| **WGKillSwitchSvc** | Windows service via NSSM, delayed-auto-start |
| **WMI Subscription** | Watches for powershell.exe death, triggers repair |
| **Startup shortcut** | `C:\ProgramData\...\StartUp\WGKillSwitch.lnk` |
| **GPO Boot Script** | Machine startup script via Group Policy |

All layers are installed by `install.ps1`. Nothing needs to be done manually.

---

## Files installed to `C:\WireGuard\`

| File | Purpose |
|------|---------|
| `wgcf-profile.conf` | WARP config (auto-generated) or your custom config path |
| `monitor.ps1` | Main VPN monitor loop |
| `onarim.ps1` | System repair script |
| `servis-monitor.ps1` | NSSM service wrapper |
| `wmi-onarim.ps1` | WMI event consumer wrapper |
| `killswitch.log` | Live log (max 500 lines, auto-rotated) |
| `nssm.exe` | Service manager |
| `wgcf.exe` | WARP config generator (WARP mode only) |
| `WG-KillSwitch-backup.xml` | Task backup for self-repair |

All files except the log are hidden/system-flagged and ACL-protected.

---

## Uninstall

Run the following in an elevated PowerShell. Replace `wgcf-profile` with your tunnel name if you used custom mode:

```powershell
# Stop and remove everything
schtasks /Delete /TN "\WG-KillSwitch" /F
schtasks /Delete /TN "\WG-RepairTask" /F
sc.exe stop WGKillSwitchSvc
C:\WireGuard\nssm.exe remove WGKillSwitchSvc confirm
& "C:\Program Files\WireGuard\wireguard.exe" /uninstalltunnelservice wgcf-profile
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS-*" } | Remove-NetFirewallRule
netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound
Remove-Item -Recurse -Force "C:\WireGuard"
Remove-Item -Force "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WGKillSwitch.lnk"
Remove-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "WGKillSwitchGuard"
Remove-Item "HKLM:\SOFTWARE\WGKillSwitch" -Recurse
```

---

## Log

```
C:\WireGuard\killswitch.log
```

```powershell
Get-Content C:\WireGuard\killswitch.log -Wait -Tail 30
```

---

## Privacy

- No account is created. The `wgcf register` command generates a random device identity on Cloudflare's WARP network.
- No email, name, or identifying information is collected or stored.
- The generated `wgcf-profile.conf` contains only a private key and Cloudflare's WARP endpoint — nothing personal.

---

## Troubleshooting

**Tunnel won't start**
The monitor will retry up to 5 times, then wait 3 minutes and try again indefinitely. Check the log for details.

**Internet blocked after reboot**
Wait 60–90 seconds. The monitor starts after a boot delay to let the network stack initialize.

**Custom server won't reconnect when tunnel is down**
Ensure `-CustomEndpointIP` matches your server's public IP and `-CustomPort` matches the `Endpoint` port in your `.conf`.

**Want to check status right now?**

```powershell
# Check tunnel (replace wgcf-profile with your tunnel name if custom)
sc.exe query "WireGuardTunnel`$wgcf-profile"

# Check registry install info
Get-ItemProperty "HKLM:\SOFTWARE\WGKillSwitch"

# View live log
Get-Content C:\WireGuard\killswitch.log -Tail 20
```

---

## Changelog

### v1.1
- Custom WireGuard server support via `-CustomConfig`, `-CustomTunnel`, `-CustomEndpointIP`, `-CustomPort`
- Endpoint/port auto-parsed from `.conf` when not specified
- Dynamic tunnel name, server IP, and port baked into monitor/repair/GPO scripts at install time
- Registry backup extended with custom mode metadata

### v1.0
- Initial release: WARP auto-setup + 8-layer kill switch

---

## License

MIT — do whatever you want with it.