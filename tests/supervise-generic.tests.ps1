#Requires -Version 7
<#
supervise-generic.tests.ps1: supervise resources on neutral and custom config: cleanup.idleDaemons, storage.toolCaches, gate.labels.
Usage: pwsh -NoProfile -File <kit>/tests/supervise-generic.tests.ps1 (or tests/kit-tests.ps1 -Area supervise-generic).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit supgen; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# storage.db.maxGB unset: no temp cap, a 7 GB query is not killed; 5 = killed (LEGACY value)
$sd = Join-Path (Kd) 'sdb'; New-Item -ItemType Directory -Force $sd | Out-Null
# use / kill are shell builtins (cmd or sh): a pwsh fake missed the 5 s hook limit under a loaded suite (timed out -> db skipped 5 min)
$cap = Invoke-PsTest storage-cap @'
$null = . $args[0] 6>$null; $sd = $args[1]; $db = @{ use = 'echo 43 7 30 SELECT big'; kill = "echo {id} >> `"$sd/killed.txt`"" }
$__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ db = [pscustomobject]$db } }; $null = Invoke-KitStorageTick -Force; "nocap:$(-not (Test-Path "$sd/killed.txt"))"
$db.maxGB = 5; $__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ db = [pscustomobject]$db } }; $null = Invoke-KitStorageTick -Force; "cap:$("$(Get-Content "$sd/killed.txt")".Trim() -eq '43')"
'@ @($O, $sd)
Expect-Each $cap 'storage db cap: #' 'nocap', 'cap' -Show 4
# generic: idle daemons only from cleanup.idleDaemons (busyKinds hold them), tool caches from storage.toolCaches, gate.labels before built-in kinds
$gen = Invoke-PsTest res-generic @'
$null = . $args[0] 6>$null; Remove-Item Env:KIT_KEEP_DAEMONS -ErrorAction SilentlyContinue
$now = Get-Date; $actions = [Collections.ArrayList]::new(); $DryRun = $true; $tmp = Join-Path $args[1] 'gt'; New-Item -ItemType Directory -Force (Join-Path $tmp 'claude-build-gate') | Out-Null
function Get-SysProcs([string]$Name) { @([pscustomobject]@{ Id = 7; Name = 'java'; CommandLine = 'java GradleDaemon'; Created = $now.AddHours(-1); WorkingSet = 1GB }, [pscustomobject]@{ Id = 8; Name = 'node'; CommandLine = 'node tsserver'; Created = $now.AddHours(-1); WorkingSet = 1GB }) | Where-Object Name -match $Name }
Invoke-KitCleanupResources; "none:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ cleanup = [pscustomobject]@{ idleDaemons = @([pscustomobject]@{ process = '^node$'; match = 'tsserver'; label = 'TS server' }) } }
Invoke-KitCleanupResources; "own:$($actions.Count -eq 1 -and $actions[0] -match '^stopped idle TS server pid 8 ')"
$actions.Clear(); $__cfg.cleanup.idleDaemons[0] | Add-Member busyKinds '^tsc' ; Set-Content (Join-Path $tmp "claude-build-gate/b.json") (@{ kind = 'tsc-lint'; pid = $PID; start = (Get-Process -Id $PID).StartTime.ToString('o') } | ConvertTo-Json)
function Test-KitPid { $true }; Invoke-KitCleanupResources; "busy:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ toolCaches = @('~/.mine', '{localAppData}/x') } }
"caches:$((@(Get-KitToolCaches 'H' 'L') -join ',') -eq 'H/.mine,L/x' -and (@(Get-KitToolCaches 'H' '') -join ',') -eq 'H/.mine')"
$__cfg = $null; "cachedef:$(@(Get-KitToolCaches 'H' 'L') -contains 'H/.gradle')"
"labels-def:$((Get-KitGateGroup 'maven-test' 'x') -eq 'maven test' -and (Get-KitGateGroup 'zig' 'x') -eq 'other')"
$script:KitGateLabels = $null; $__cfg = [pscustomobject]@{ gate = [pscustomobject]@{ labels = [pscustomobject]@{ _readme = 'x'; 'zig build' = '^zig'; 'all maven' = '^maven' } } }
"labels:$((Get-KitGateGroup 'zig' 'x') -eq 'zig build' -and (Get-KitGateGroup 'maven-test' 'x') -eq 'all maven' -and (Get-KitGateGroup 'ng-test' 'x') -eq 'js tests')"
'@ @($O, (Kd))
Expect-Each $gen 'resources generic: #' 'none', 'own', 'busy', 'caches', 'cachedef', 'labels-def', 'labels' -Show 6
# a CI-raised test task (tracker.ciTaskPattern): track add of its merged fix MR promotes it with no testing docs, holds while the
# named job runs again on its branch, closes it with ONE qa-result comment linking the passing job; a plain task keeps the doc gate
$ciTrack = Invoke-PsTest track-ci @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$__cfg = if ($__cfg) { $__cfg } else { [pscustomobject]@{} }; $__cfg | Add-Member -Force process ([pscustomobject]@{ gates = [pscustomobject]@{ promote = 'builtin:testingDocs' } })   # the legacy row: a plain task keeps the doc gate
$KitConf.TrackerType = 'fake'; $global:st = 'open'; $global:kc = @(); $global:jobSt = 'running'; $global:tname = '[Backend Unit Test] Stale tests'
$jobUrl = 'https://h/g/api/-/jobs/'
function Get-TrackerTask($id) { [pscustomobject]@{ name = $global:tname; status = $global:st; subtasks = @(); description = "**Pipeline:** [x](https://h/g/api/-/pipelines/100)`n**Branch:** staging/x @ abc`n**Job:** [x](${jobUrl}7)" } }
function Set-TrackerStatus($id, $s) { $global:st = $s }
function Set-TrackerKitComment($id, $kind, $text) { $global:kc += "$kind|$text" }
function Get-TrackerComments($id) { @() }
function Start-Process { }
function ProjPath($r) { "g/$r" }
$__cfg | Add-Member -Force NoteProperty tracker ([pscustomobject]@{ ciTaskPattern = '^\W*\[[^\]]*Unit Test\]' })   # LEGACY tracker.ciTaskPattern
function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = 'merged' } }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  switch ($Verb) { 'ci.parseUrl' { $j = [regex]::Match("$($A.text)", '(?<u>https?://\S+?/jobs/(?<id>\d+))'); @{ url = $j.Groups['u'].Value; job = $j.Groups['id'].Value; run = [regex]::Match("$($A.text)", '/pipelines/(\d+)').Groups[1].Value } }
    'mr.get' { [pscustomobject]@{ state = 'merged'; merge_commit_sha = 'm1' } } 'ci.runs' { @([pscustomobject]@{ id = 101; sha = 's1' }, [pscustomobject]@{ id = 99; sha = 's0' }) } 'repo.base' { [pscustomobject]@{ id = 'm1' } } 'mr.url' { "https://h/$($A.repo)/-/merge_requests/$($A.n)" }
    'ci.jobs' { if ("$($A.id)" -eq '100') { @([pscustomobject]@{ id = 7; name = 'unit-x'; status = 'failed' }) } else { @([pscustomobject]@{ id = 9; name = 'unit-x'; status = $global:jobSt; web_url = "${jobUrl}9" }) } } default { $null } } }
$a1 = Invoke-Track add -Task ci1 -Mrs 'api!5' -Detail | Out-String; $s1 = "$global:st|$((Read-KitTracking).tasks['ci1'].done)"
$global:jobSt = 'success'; $r2 = Invoke-Track run -Task ci1 | Out-String
"wait:$($s1 -eq 'promoted|False' -and $a1 -match 'HOLD ci1: CI task not closed: CI job unit-x running on staging/x')"
"closed:$($global:st -eq 'closed' -and (Read-KitTracking).tasks['ci1'].done -and $r2 -match 'DONE ci1: all 1 MRs merged, CI job unit-x passed on staging/x -> closed' -and @($global:kc).Count -eq 1 -and $global:kc[0] -match '^qa-result\|QA: PASS . CI job unit-x passed on staging/x with \[api!5\]\(https://h/\S*api/-/merge_requests/5\) merged: https://h/g/api/-/jobs/9$')"
$global:tname = 'Plain fix'; $global:st = 'open'; $p3 = Invoke-Track add -Task ci2 -Mrs 'api!6' | Out-String
"plain:$($global:st -eq 'open' -and $p3 -match 'ATTENTION ci2: MRs merged, no testing-doc link' -and $null -eq (Get-KitCiTask ci2))"
'@ @($O)
Expect-Each $ciTrack 'track: CI task # (wait: track add of a merged MR promotes at once, holds while the job runs again; closed: job passed -> closed + one qa-result comment with the job link; plain: no pattern match = the testing-doc gate)' @('wait', 'closed', 'plain') 3
Remove-TestKit $k
# gate.cacheFlush: starved gate + big cache -> 1 flush / 30 min; failing command = 1 WATCH
$cft = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Get-KitSetting($Key, $Default) { if ($Key -eq 'gate.cacheFlush') { 'flush-now' } else { $Default } }
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
$global:runs = 0; function Invoke-KitExe($Exe, $A, $TimeoutSec) { $global:runs++; [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
function Get-SysMem { [pscustomobject]@{ TotalGB = 64; AvailGB = 9 } }
$m = [pscustomobject]@{ TotalGB = 64; AvailGB = 3 }; $n = Get-Date
$a = Invoke-KitCacheFlush 12 $m $n; $b = Invoke-KitCacheFlush 12 $m $n
"once:$($a.what -eq 'auto-fixed: file cache flush: available 3 -> 9 GB' -and -not $b -and $global:runs -eq 1)"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp')
"short:$(-not (Invoke-KitCacheFlush 5 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 4GB } }
"small:$(-not (Invoke-KitCacheFlush 12 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 1; out = ''; err = 'Access is denied.'; timedOut = $false } }
$fl = Invoke-KitCacheFlush 12 $m $n
"fail:$($fl.level -eq 'WATCH' -and $fl.what -match 'exit 1: Access is denied')"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp'); function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
$global:polls = 0; function Get-SysMem { $global:polls++; [pscustomobject]@{ TotalGB = 64; AvailGB = 3 } }   # no gain: polls only within its budget
$nb = Invoke-KitCacheFlush 12 $m $n 2
"budget:$($global:polls -eq 1 -and $nb.what -match 'available 3 -> 3 GB')"
'@
Expect-Each (Invoke-PsTest 'cache-flush' $cft @($O)) 'cache flush: #' @('once', 'short', 'small', 'fail', 'budget')
Complete-Tests
