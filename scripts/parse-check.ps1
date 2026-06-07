$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$errs = $null
$tok = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$errs)
if ($errs) {
    foreach ($x in $errs) {
        Write-Host "$($x.Extent.StartLineNumber):$($x.Extent.StartColumnNumber) $($x.Message)"
    }
    exit 1
}
Write-Host 'OK'
exit 0