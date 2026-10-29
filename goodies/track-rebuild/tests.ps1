#Requires -Version 7
<#
tests.ps1 (goody track-rebuild): offline, on a throw-away test kit with this goody's files.
Usage: kitbag.py goody test track-rebuild (tests/kit-tests.ps1 -Area goodies runs every installed goody)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kitbag.py goody test: the kit's harness; New-TestKit adds this goody's files
$k = New-TestKit track-rebuild; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$out = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild without trackerRepos: no tasks and the config hint' ($out -match 'trackerRepos')
$null = pwsh @np $O track add -Task t9 -Mrs 'api!1' 2>&1; $out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild keeps existing tasks (no -Force)' ($out2 -match 'holds 1 task\(s\): nothing to rebuild')
Remove-TestKit $k
Complete-Tests
