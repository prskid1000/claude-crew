#Requires -Version 7
<#
tests/track-rebuild.tests.ps1: bossy.ps1 track -Rebuild, offline, on a throw-away test kit with adapters/track_rebuild.ps1; invalid task files.
Usage: pwsh -NoProfile -File tests/track-rebuild.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs   # New-TestKit adds $TestKitFiles
$TestKitFiles = @('skills/bossy/adapters/track_rebuild.ps1')   # copied into every New-TestKit kit
$k = New-TestKit track-rebuild; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$out = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild without trackerRepos: no tasks and the config hint' ($out -match 'trackerRepos')
$null = pwsh @np $O track add -Task t9 -Mrs 'api!1' 2>&1; $out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
Expect 'track -Rebuild keeps existing tasks (no -Force)' ($out2 -match 'holds 1 task\(s\): nothing to rebuild')
# invalid task files: a flag taken as the id is refused on write; cleanup removes an old one, real task files stay
$tkd = TkPath $k tasks -Create; '{"task":"--help"}' | Set-Content (Join-Path $tkd '--help.json')
$tkw = pwsh -NoProfile -Command ". '$O'; try { Update-KitTaskIndex '--help' { param(`$x) `$x.n = 1 }; 'written' } catch { `"`$_`" }"
$tkc = pwsh @np $O cleanup -Detail 2>&1 | Out-String
Expect "cleanup: task file of a flag id (--help.json) removed, t9.json kept; Update-KitTaskIndex refuses '--help' ($tkw)" ("$tkw" -match 'not a task id' -and $tkc -match 'invalid task id' -and -not (Test-Path -LiteralPath (Join-Path $tkd '--help.json')) -and (Test-Path (Join-Path $tkd 't9.json')))
Remove-TestKit $k
Complete-Tests
