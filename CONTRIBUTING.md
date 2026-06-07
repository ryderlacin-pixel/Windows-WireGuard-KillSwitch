# Contributing

Thanks for your interest in this project.

## Language

All contributions must be in **English**:

- Issue titles and descriptions
- Pull request titles and descriptions
- Code comments and user-facing strings in scripts
- Documentation (`README.md`, `docs/`, templates)

Non-English issues or PRs may be closed without review.

## How to contribute

1. Fork the repository on GitHub.
2. Create a branch from `main`.
3. Make focused changes — one logical fix or feature per PR.
4. Test on Windows 10/11 with an elevated PowerShell session when touching `install.ps1` or generated scripts.
5. Open a pull request with a clear description of what changed and why.

## What not to commit

- WireGuard `.conf` files, private keys, or personal endpoints
- `wgcf-profile.conf` or generated credentials
- Machine-specific paths beyond the documented `C:\WireGuard\` install target

## Scope

This repo ships a single installer (`install.ps1`) that generates runtime scripts under `C:\WireGuard\` on the target machine. Keep changes minimal and consistent with the existing PowerShell style.

## Code review

Before opening a design or security question, read **[docs/CODE_REVIEW.md](docs/CODE_REVIEW.md)**. It documents:

- Responses to reviewer feedback (v10.2 → v10.4)
- Why WMI and 8 recovery layers exist
- Firewall model and verification commands

Use the **[Code review issue template](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/issues/new?template=code_review.md)** for architecture questions.

After changing `install.ps1`, update `docs/CODE_REVIEW.md` and release notes in `scripts/publish-releases.ps1` if behavior changes.

## Questions

Open a [GitHub issue](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/issues) in English. For promotion copy, see `docs/PROMOTION.md`.