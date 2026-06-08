# Opens launch checklist URLs in the default browser (no API, no changes to system).
$links = @(
    "https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch",
    "https://github.com/settings/tokens/new",
    "https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/settings",
    "https://github.com/ryderlacin-pixel/Windows-WireGuard-KillSwitch/releases/tag/v15.2.9",
    "https://github.com/ryderlacin-pixel?tab=repositories",
    "https://github.com/settings/profile",
    "https://www.reddit.com/r/PowerShell/comments/1tza2u0/refactored_a_monolithic_script_into_a_modular/",
    "https://www.reddit.com/r/WireGuard/submit",
    "https://www.reddit.com/r/selfhosted/submit",
    "https://github.com/cedrick-f/awesome-wireguard"
)
Write-Host "Opening $($links.Count) launch URLs..." -ForegroundColor Cyan
foreach ($url in $links) {
    Write-Host "  $url" -ForegroundColor Gray
    Start-Process $url
    Start-Sleep -Milliseconds 800
}
Write-Host "Done. Use docs/LAUNCH_CHECKLIST.md and docs/PROMOTION.md for copy-paste text." -ForegroundColor Green