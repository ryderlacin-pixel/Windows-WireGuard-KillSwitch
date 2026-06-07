\# Windows WireGuard/WARP Kill Switch (Refactored)



A modular, self-healing kill switch implementation for Windows designed to prevent any protocol, IP, or DNS leakage when using Cloudflare WARP via WireGuard. 



Most scripts fail during the boot sequence because they attempt to enforce rules before the Windows network stack or wireguard drivers are fully initialized. This refactored setup addresses this by implementing staggered boot delays and a continuous self-healing matrix.



\## Core Features

\* \*\*Zero-Trust ACL Routing:\*\* Complete physical interface isolation (Wi-Fi/Ethernet) and nuclear IPv6 blocking at the adapter level to prevent dual-stack bypass.

\* \*\*WMI Permanent Subscriptions:\*\* Spawns a low-level WMI event filter. If the core monitoring PowerShell process is manually killed or crashes, the OS immediately triggers a recovery wrapper.

\* \*\*Triple-Layer Persistence:\*\* Orchestrated via NSSM (running as a delayed-start Windows Service), Task Scheduler (SYSTEM level), and GPO local startup scripts.

\* \*\*Active Anti-Stall:\*\* Implements a dynamic token/mutex mechanism to handle automated tunnel reinstalls without process race conditions.



\## Project Structure

\* `Deploy.ps1` - The main orchestrator that sets up permissions and triggers modules.

\* `src/Install-Prereqs.ps1` - Handles silent binary deployment (WireGuard \& NSSM) and anonymous profile generation.

\* `src/Setup-Firewall.ps1` - Flushes legacy rules and builds the strict firewall matrix.

\* `src/Watchdog-Service.ps1` - Establishes WMI subscriptions, tasks, and system persistence.

## Resilience & Leak Testing

Most VPN kill switches only work under ideal conditions. This implementation was subjected to aggressive, simulated infrastructure failures to guarantee a 100% zero-leak state under all conditions.

## Stress Test Scenarios Passed (Zero Leaks Detected):
* **Hard Reboots & Power Cycles:** Verified that the network stack is strictly locked *before* Windows finishes loading asynchronously, blocking early-boot driver vulnerabilities.
* **Router & Modem Resets:** Simulating a sudden WAN drop or PPPoE lease renewal does not cause a race condition. The script actively stalls and re-evaluates the routing matrix without dropping the firewall ACL.
* **Forced Process Termination:** Manually killing the monitoring core from Task Manager or a high-privilege command prompt instantly triggers the kernel-level WMI Permanent Event Consumer, respawning the watchdog wrapper within milliseconds.
* **Windows Updates & Background Servicing:** Survives local GPO refreshes, Windows Defender updates, and dynamic network adapter resets triggered by OS background tasks.

## Protocol & Software Compatibility
Tested and proven to completely prevent IPv4, IPv6, and WebRTC leakage across heavy network loads, specialized scraping scripts, and automated scraping software:
* **Web Browsers:** Hardened against WebRTC/STUN leaks on hardened Firefox, Chromium, and Brave profiles.
* **Custom Automation & Tools:** Complete security wrapper for custom headless automation scripts, persistent background programs, and P2P/media streaming utilities that directly query socket layers.



## Deployment

Since Windows does not provide a default "Run as Administrator" right-click option for `.ps1` files, follow these exact steps to deploy:

1. Open the **Start Menu**, search for **PowerShell**, right-click it, and select **Run as Administrator**.
2. Run the following command sequence to navigate to your project directory and execute the orchestrator (adjust the path if your folder is located elsewhere):

```powershell
cd "$HOME\Desktop\Windows-WireGuard-KillSwitch"
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Deploy.ps1
```

