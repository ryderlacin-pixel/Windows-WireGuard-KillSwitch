#Requires -RunAsAdministrator
$GPO = 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\wg-startup.ps1'
if (-not (Test-Path $GPO)) { Write-Host 'GPO script missing'; exit 1 }
attrib -H -S -R $GPO 2>$null | Out-Null
$text = Get-Content $GPO -Raw -Encoding UTF8
$new = $text -replace 'v13\.4', 'v13.5'
if ($new -eq $text) { Write-Host 'Already v13.5 or no v13.4 markers'; exit 0 }
Set-Content -Path $GPO -Value $new -Encoding UTF8 -Force
attrib +S +H $GPO 2>$null | Out-Null
Write-Host 'GPO patched to v13.5'