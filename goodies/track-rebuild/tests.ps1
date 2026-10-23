#Requires -Version 7
<#
tests.ps1 (goody track-rebuild): offline, on a throw-away test kit with this goody's files.
Usage: kitbag.py goody test track-rebuild (tests/kit-tests.ps1 -Area goodies runs every installed goody)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kitbag.py goody test: the kit's harness; New-TestKit adds this goody's files
$k = New-TestKit track-rebuild; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$out = pwsh @np $O track -Rebuild 2>&1 | Out-String
$tf = & { . (Join-Path $k 'skills/crafty/lib.ps1'); Get-KitPath tracking }
Expect 'track -Rebuild without trackerRepos: an empty tracking file and the config hint' ((Test-Path $tf) -and $out -match 'trackerRepos')
$out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild keeps an existing file (no -Force)' ($out2 -match 'nothing to rebuild')
Remove-TestKit $k
Complete-Tests
