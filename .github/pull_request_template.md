## Summary

<!-- What does this PR change and why? -->

## Code review checklist (if touching install.ps1)

- [ ] Reviewer concerns documented in PR description or linked issue
- [ ] `Test-IsMainMonitor` regex used (not `*monitor.ps1*` substring)
- [ ] Generated scripts (`monitor.ps1`, `repair.ps1`) tested on VM
- [ ] No personal keys, `.conf`, or tokens committed

## Tested on

- [ ] Windows 10 / 11
- [ ] WARP mode (`install.ps1`)
- [ ] Custom server mode (`-CustomConfig`)
- [ ] Reboot validation

## Privacy check

- [ ] No personal keys, configs, or machine-specific paths included