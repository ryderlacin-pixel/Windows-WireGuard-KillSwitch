param([string]$Path)
$errs = $null; $tok = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Host "FAIL $($errs[0].Extent.StartLineNumber):$($errs[0].Extent.StartColumnNumber) $($errs[0].Message)"
    exit 1
}
Write-Host "OK $Path"
exit 0