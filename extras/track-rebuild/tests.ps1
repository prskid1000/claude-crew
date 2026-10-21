#Requires -Version 7
<#
tests.ps1 (extra track-rebuild): offline, on a throw-away test kit with this extra's files.
Usage: kittool.py extra test track-rebuild (tests/kit-tests.ps1 -Area extras runs every installed extra)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kittool.py extra test: the kit's harness; New-TestKit adds this extra's files
$k = New-TestKit track-rebuild; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
$out = pwsh @np $O track -Rebuild 2>&1 | Out-String
$tf = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath tracking }
Expect 'track -Rebuild without trackerRepos: an empty tracking file and the config hint' ((Test-Path $tf) -and $out -match 'trackerRepos')
$out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild keeps an existing file (no -Force)' ($out2 -match 'nothing to rebuild')
Remove-TestKit $k
Complete-Tests
