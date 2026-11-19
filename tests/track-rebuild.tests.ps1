#Requires -Version 7
<#
tests/track-rebuild.tests.ps1: bossy.ps1 track -Rebuild, offline, on a throw-away test kit with adapters/track_rebuild.ps1; track remove; invalid task files;
status writes (debounce, no step back, a parent follows its subtasks); launch area subtasks.
Usage: pwsh -NoProfile -File tests/track-rebuild.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs   # New-TestKit adds $TestKitFiles
$TestKitFiles = @('skills/bossy/adapters/track_rebuild.ps1', 'skills/bossy/adapters/task_rollup.ps1')   # copied into every New-TestKit kit
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
# status writes (owner, 2026-11-19, 11 flips): debounced, never a step back without failedTesting / -Back, a parent with open subtasks follows them
$sw = Invoke-PsTest statuswrites @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'
$global:Wr = [Collections.Generic.List[string]]::new(); $realSet = ${function:__Set-TrackerStatus}
${function:__Set-TrackerStatus} = { param($Id, $Status) $global:Wr.Add("$Id=$Status"); & $realSet $Id $Status }.GetNewClosure()
function Mk($n, $par) { (__TrA 'create' @{ name = $n; parent = $par }).id }; function Ky($i) { Clear-TrackerMemo $i; Get-TrackerStatusKey (Get-TrackerTask $i).status }
$t = Mk 'T' $null; Set-TrackerStatus $t 'inProgress' 6>$null; Set-TrackerStatus $t 'inProgress' 6>$null; "deb:$(@($Wr | Where-Object { $_ -like "$t=*" }).Count)"
Set-TrackerStatus $t 'review' 6>$null; Set-TrackerStatus $t 'inProgress' 6>$null; "back:$(Ky $t)"
Set-TrackerStatus $t 'inProgress' 'fix round 2' 6>$null; "backok:$(Ky $t)"
Set-TrackerStatus $t 'promoted' 6>$null; Set-TrackerStatus $t 'failedTesting' 6>$null; "ft:$(Ky $t)"
$p = Mk 'P' $null; $a = Mk 'A' $p; $b = Mk 'B' $p; Set-TrackerStatus $a 'promoted' 6>$null; $pr = Set-TrackerStatus $p 'promoted' 6>$null; "par:$(Ky $p)|$("$pr" -like 'SKIPPED*')"
Set-TrackerStatus $b 'review' 6>$null; "roll:$(Ky $p)"; Set-TrackerStatus $p 'failedTesting' 6>$null; "pft:$(Ky $p)"; $q = Mk 'Q' $null; $null = Mk '[Bug] Q leak' $q; Set-TrackerStatus $q 'closed' 6>$null; "bug:$(Ky $q)"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
$sx = { param($key) "$(@($sw | Where-Object { "$_" -like "${key}:*" })[0])".Substring($key.Length + 1) }
# launch -Self, 2+ areas on one task: one subtask per area (named, parent's assignee, item titles from the brief), kept on a relaunch
$ab = Join-Path (Kd) 'areabrief'; New-Item -ItemType Directory -Force $ab | Out-Null; $tst = Join-Path $k '.state/tracker-none'; New-Item -ItemType Directory -Force $tst | Out-Null
& $J @{ id = 'PAR1'; url = 'https://t.test/PAR1'; name = 'Shop setup'; status = 'in progress'; parent = $null; list = 'L1'; assignees = @('Ann Lee'); description = "Problem: p`nItems: A-1"; comments = @() } (Join-Path $tst 'PAR1.json')
Set-Content (Join-Path $ab 'wave-brief.md') "# Wave brief: Site builder PAR1, 2026-01-01`n| Agent | Items | Area | Repos |`n|---|---|---|---|`n| API1 | A-1 A-2 | API guard, names | api@main |`n| WEB1 | W-1 | Grid | web@main |`n`n| ID | Area | Title |`n|---|---|---|`n| A-1 | API1 | Guard the path |"
$aj = (@{ brief = (Join-Path $ab 'wave-brief.md').Replace('\', '/'); task = 'PAR1'; mode = 'feature'; mandate = @('m'); agents = @(@{ id = 'API1'; items = 'A-1 A-2'; area = 'API guard, names' }, @{ id = 'WEB1'; items = 'W-1'; area = 'Grid' }) } | ConvertTo-Json -Depth 5 -Compress)
$af = Join-Path (Kd) 'args-area.json'; [IO.File]::WriteAllText($af, $aj)
$atOut = Invoke-PsTest areatasks @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0] 6>$null; $realGet = ${function:Get-TrackerTask}   # tracker none URLs are file paths: the parent gets a web one
${function:Get-TrackerTask} = { param($Id) $v = & $realGet $Id; if ($v) { $v.url = "https://t.test/$Id" }; $v }.GetNewClosure()
$a = Get-Content -Raw $args[1] | ConvertFrom-Json -AsHashtable; @(New-KitAreaTasks $a 'area-r' '') | ForEach-Object { "one:$_" }; @(New-KitAreaTasks $a 'area-r' '') | ForEach-Object { "two:$_" }
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $af)
$at1 = @($atOut | Where-Object { "$_" -like 'one:*' } | ForEach-Object { "$_".Substring(4) }); $at2 = @($atOut | Where-Object { "$_" -like 'two:*' } | ForEach-Object { "$_".Substring(4) })
$subsA = @(Get-ChildItem $tst -Filter 'LOCAL-*.json' | ForEach-Object { Read-Json $_.FullName } | Where-Object { $_.parent -eq 'PAR1' })
$apiSub = @($subsA | Where-Object { $_.name -like '*API1*' })[0]
Expect "launch -Self: 2 areas on one task -> a subtask each under it, kept on a relaunch ($(@($at1 -match '^AREA TASK') -join ' | ') / $(@($at2 -match '^AREA TASK') -join ' | ') / $($apiSub.name))" (@($at1 -match '^AREA TASK (API1|WEB1) LOCAL-\d+').Count -eq 2 -and @($at2 -match '^AREA TASK \S+ LOCAL-\d+ \(kept\)').Count -eq 2 -and $subsA.Count -eq 2 -and
  $apiSub.name -eq '[Feature] Site builder — API1 API guard (api)' -and "$($apiSub.assignees)" -match 'Ann Lee' -and $apiSub.description -match 'A-1 · Guard the path' -and (Read-Json (Join-Path $ab 'area-tasks.json')).agents.Count -eq 2)
Expect "status write: the same status twice = one write ($(& $sx 'deb'))" ((& $sx 'deb') -eq '1')
Expect "status write: review -> inProgress kept; -Back '<why>' (a new code round) moves it; failedTesting always ($(& $sx 'back') $(& $sx 'backok') $(& $sx 'ft'))" ((& $sx 'back') -eq 'review' -and (& $sx 'backok') -eq 'inProgress' -and (& $sx 'ft') -eq 'failedTesting')
Expect "status write: a parent with open subtasks is never set directly (promoted refused: SKIPPED, follows them), failedTesting is; an open [Bug] child does not hold its ask ($($sw -join ' '))" ((& $sx 'par') -eq 'open|True' -and (& $sx 'bug') -eq 'closed' -and (& $sx 'roll') -eq 'review' -and (& $sx 'pft') -eq 'failedTesting')
Remove-TestKit $k
Complete-Tests
