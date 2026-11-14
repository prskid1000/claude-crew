#Requires -Version 7
<#
tests/track-rebuild.tests.ps1: bossy.ps1 track -Rebuild, offline, on a throw-away test kit with adapters/track_rebuild.ps1.
Usage: pwsh -NoProfile -File tests/track-rebuild.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # New-TestKit adds $TestKitFiles
$TestKitFiles = @('skills/bossy/adapters/track_rebuild.ps1')   # copied into every New-TestKit kit
$k = New-TestKit track-rebuild; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$out = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild without trackerRepos: no tasks and the config hint' ($out -match 'trackerRepos')
$null = pwsh @np $O track add -Task t9 -Mrs 'api!1' 2>&1; $out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild keeps existing tasks (no -Force)' ($out2 -match 'holds 1 task\(s\): nothing to rebuild')
Remove-TestKit $k
Complete-Tests
