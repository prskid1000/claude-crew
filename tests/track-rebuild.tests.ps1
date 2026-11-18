#Requires -Version 7
<#
tests/track-rebuild.tests.ps1: bossy.ps1 track -Rebuild, offline, on a throw-away test kit with adapters/track_rebuild.ps1; track remove; invalid task files.
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
$trA = pwsh @np $O track remove -Task t9 2>&1 | Out-String; $trAc = $LASTEXITCODE; $trB = pwsh @np $O track remove -Task t9 -Mrs 'api!7' 2>&1 | Out-String; $trBc = $LASTEXITCODE
Expect "track remove: no -Mrs = usage (exit 2); an MR not on the task is refused with its MRs (exit 1) ($trAc $trBc)" ($trAc -eq 2 -and $trA -match 'usage: bossy.ps1 track remove' -and $trBc -eq 1 -and $trB -match 'api!7 not on t9 \(its MRs: api!1\)')
# track remove in process: a wrong MR off and listed, discovery never re-adds it, add -Mrs re-attaches, an ignored closed MR blocks nothing
$trm = Invoke-PsTest 'track-remove' @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = $(if ("$($A.n)" -eq '61') { 'closed' } else { 'opened' }) } }
function Find-TaskMrs { 'g/web!61' }; function Get-TrackerTask($id) { [pscustomobject]@{ status = 'review'; subtasks = @() } }; function Set-TrackerStatus { }; function Start-Process { }
$KitConf.TrackerRepos = @('g/web'); $null = Invoke-Track add -Task t14 -Mrs 'g/web!60,g/web!61'; $rm1 = Invoke-Track remove -Task t14 -Mrs 'g/web!61' -Reason 'wrong task' | Out-String
$null = Invoke-Track add -Task t14 -Discover; $rm2 = (Read-KitTracking).tasks['t14']; $null = Invoke-Track add -Task t14 -Mrs 'g/web!61'; $rm3 = (Read-KitTracking).tasks['t14']
$null = Add-KitMrIgnore 'g/web!61' 'mislabelled'; $rm4 = Invoke-Track run -Task t14 -Detail | Out-String; $null = Invoke-Track add -Task t15 -Mrs 'g/web!61'; $rm5 = Invoke-Track run -Task t15 -Detail | Out-String
"off:$($rm1 -match 'removed g/web!61 from t14 \(wrong task\).*now g/web!60' -and (@($rm2.mrs) -join ',') -eq 'g/web!60' -and $rm2.removed[0].mr -eq 'g/web!61' -and $rm2.removed[0].reason -eq 'wrong task')"
"readd:$(@($rm3.mrs).Count -eq 2 -and -not $rm3.removed)"
"ignored:$($rm4 -notmatch 'ATTENTION t14' -and $rm5 -match 'HOLD t15: its only MRs are closed and ignored')"
'@ @($O)
Expect-Each $trm 'track remove: # (off: the MR leaves the task, listed with its reason, discovery never re-adds it; readd: track add -Mrs re-attaches; ignored: a closed ignored MR blocks nothing)' 'off', 'readd', 'ignored' -Show 8
# invalid task files: a flag taken as the id is refused on write; cleanup removes an old one, real task files stay
$tkd = TkPath $k tasks -Create; '{"task":"--help"}' | Set-Content (Join-Path $tkd '--help.json')
$tkw = pwsh -NoProfile -Command ". '$O'; try { Update-KitTaskIndex '--help' { param(`$x) `$x.n = 1 }; 'written' } catch { `"`$_`" }"
$tkc = pwsh @np $O cleanup -Detail 2>&1 | Out-String
Expect "cleanup: task file of a flag id (--help.json) removed, t9.json kept; Update-KitTaskIndex refuses '--help' ($tkw)" ("$tkw" -match 'not a task id' -and $tkc -match 'invalid task id' -and -not (Test-Path -LiteralPath (Join-Path $tkd '--help.json')) -and (Test-Path (Join-Path $tkd 't9.json')))
Remove-TestKit $k
Complete-Tests
