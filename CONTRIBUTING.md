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

- **Entry point:** `install.ps1` (orchestrator, ~70 lines)
- **Implementation:** `lib/*.ps1` (dot-sourced modules) + `scripts/install-v14-stack.ps1`, `scripts/install-v15-privacy-stack.ps1`
- **Runtime output:** generated scripts under `C:\WireGuard\` on the target machine

When changing install behavior, update the relevant `lib/` module (or stack script), keep `install.ps1` thin, and run `.\scripts\test-suite.ps1` (1008+ assertions, 0 ERROR/WARN on final line audit).

## Code review

Before opening a design or security question, read **[docs/CODE_REVIEW.md](docs/CODE_REVIEW.md)**. It documents:

- Reviewer Q&A (v10.2 → v10.4) and v11–v15 history
- **`lib/` module map** (v15.2.9)
- Why WMI and 9 recovery layers exist
- Firewall model and verification commands (`live-smoke-test.ps1`, `safe-live-verify.ps1`)

Use the **[Code review issue template](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/issues/new?template=code_review.md)** for architecture questions.

After changing install logic, update `docs/CODE_REVIEW.md`, `docs/releases/v15.x.md`, and `scripts/publish-releases.ps1` if behavior changes.

## Questions

Open a [GitHub issue](https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/issues) in English. For promotion copy, see `docs/PROMOTION.md`.