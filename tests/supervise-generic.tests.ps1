#Requires -Version 7
<#
supervise-generic.tests.ps1: supervise resources on neutral and custom config: cleanup.idleDaemons, storage.toolCaches, gate.labels,
builds per agent (gate card, gate.buildsPerHour WATCH).
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
# K20: an anomalous drive's round: one db query list a sweep (the tick's), top writers sampled once per 5 min
$rnd = Invoke-PsTest storage-round @'
$null = . $args[0] 6>$null; $global:dbc = 0; $global:twc = 0; function Get-KitDbQueries($C) { $global:dbc++; @() }; function Get-KitTopWriters { $global:twc++; @([pscustomobject]@{ name = 'w'; pid = 1; mbs = 9 }) }
function Get-KitDrives { @([pscustomobject]@{ name = 'Q'; root = 'Q:\'; free = 3; size = 100; kit = $true }) }; function Get-KitDiskVerdict { [pscustomobject]@{ level = 'WATCH'; anomaly = $true; rate = 9; ttf = 0.3; free = 3; normal = 0.1 } }
function Get-KitHeldDeletedGB { $null }; function Get-KitFolderGrowth { @() }; function Start-KitStorageScan { }
$r1 = @(Get-KitStorageRound); $r2 = @(Get-KitStorageRound); "round:$($global:dbc):$($global:twc):$(@($r2 | Where-Object { "$($_.what)" -match 'top writers: w \(1\)' }).Count)"
'@ @($O)
Expect "storage round: one db query list a sweep, top writers cached 5 min ($(@($rnd)[-1]))" (@($rnd)[-1] -eq 'round:2:1:1')
# K70 (K7 fix): an empty scan.lock (a failed start) older than a minute is replaced; a fresh one (a starter mid-write) is left
$slk = Invoke-PsTest storage-lock @'
$null = . $args[0] 6>$null; $env:KIT_STORAGE_SCAN = '1'; $global:sp = 0; function Start-Process { $global:sp++; [pscustomobject]@{ Id = $PID } }
$lk = Get-KitStorageFile 'Q' 'scan.lock'; New-Item -ItemType Directory -Force (Split-Path $lk) | Out-Null
Set-Content -LiteralPath $lk '' -NoNewline; Start-KitStorageScan 'Q'; $fresh = "$($global:sp):$((Get-Item -LiteralPath $lk).Length)"
(Get-Item -LiteralPath $lk).LastWriteTime = (Get-Date).AddMinutes(-3); Start-KitStorageScan 'Q'; "lock:$fresh/$($global:sp):$((Read-KitText $lk | ConvertFrom-Json).pid -eq $PID)"
'@ @($O)
Expect "storage scan: an old empty scan.lock is replaced, a fresh one left ($(@($slk)[-1]))" (@($slk)[-1] -eq 'lock:0:0/1:True')
# generic: idle daemons only from cleanup.idleDaemons (busyKinds hold them), tool caches from storage.toolCaches, gate.labels before built-in kinds
$gen = Invoke-PsTest res-generic @'
$null = . $args[0] 6>$null; Remove-Item Env:KIT_KEEP_DAEMONS -ErrorAction SilentlyContinue
$now = Get-Date; $actions = [Collections.ArrayList]::new(); $DryRun = $true; $gtLedger = Join-Path $args[1] 'gt'; function Get-KitGateLedger { $gtLedger }; New-Item -ItemType Directory -Force $gtLedger | Out-Null
function Get-SysProcs([string]$Name) { @([pscustomobject]@{ Id = 7; Name = 'java'; CommandLine = 'java GradleDaemon'; Created = $now.AddHours(-1); WorkingSet = 1GB }, [pscustomobject]@{ Id = 8; Name = 'node'; CommandLine = 'node tsserver'; Created = $now.AddHours(-1); WorkingSet = 1GB }) | Where-Object Name -match $Name }
Invoke-KitCleanupResources; "none:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ cleanup = [pscustomobject]@{ idleDaemons = @([pscustomobject]@{ process = '^node$'; match = 'tsserver'; label = 'TS server' }) } }
Invoke-KitCleanupResources; "own:$($actions.Count -eq 1 -and $actions[0] -match '^stopped idle TS server pid 8 ')"
$actions.Clear(); $__cfg.cleanup.idleDaemons[0] | Add-Member busyKinds '^tsc' ; Set-Content (Join-Path $gtLedger 'b.json') (@{ kind = 'tsc-lint'; pid = $PID; start = (Get-Process -Id $PID).StartTime.ToString('o') } | ConvertTo-Json)
function Test-KitPid { $true }; Invoke-KitCleanupResources; "busy:$($actions.Count -eq 0)"
$__cfg = [pscustomobject]@{ storage = [pscustomobject]@{ toolCaches = @('~/.mine', '{localAppData}/x') } }
"caches:$((@(Get-KitToolCaches 'H' 'L') -join ',') -eq 'H/.mine,L/x' -and (@(Get-KitToolCaches 'H' '') -join ',') -eq 'H/.mine')"
$__cfg = $null; "cachedef:$(@(Get-KitToolCaches 'H' 'L') -contains 'H/.gradle')"
"labels-def:$((Get-KitGateGroup 'maven-test' 'x') -eq 'maven test' -and (Get-KitGateGroup 'zig' 'x') -eq 'zig' -and (Get-KitGateGroup '' 'x') -eq 'other')"   # an unknown kind = its own row; presets only label
$script:KitGateLabels = $null; $__cfg = [pscustomobject]@{ gate = [pscustomobject]@{ labels = [pscustomobject]@{ _readme = 'x'; 'zig build' = '^zig'; 'all maven' = '^maven' } } }
"labels:$((Get-KitGateGroup 'zig' 'x') -eq 'zig build' -and (Get-KitGateGroup 'maven-test' 'x') -eq 'all maven' -and (Get-KitGateGroup 'ng-test' 'x') -eq 'js tests')"
$sp = { param($i, $p, $n, $c, $m) [pscustomobject]@{ Id = $i; ParentId = $p; Name = $n; CommandLine = $c; Created = $now.AddMinutes(-$m) } }; $rd = $script:KitPathMap.runtimeDir; $wd = "--no-defaults `"--datadir=D:/k/$rd/work/tests/mysqld-1`""
$so = @(Get-KitScratchOrphans @((& $sp 50 1 'pwsh.exe' 'pwsh' 120), (& $sp 51 50 'mysqld.exe' $wd 60), (& $sp 60 99 'mysqld.exe' $wd 60), (& $sp 61 60 'mysqld.exe' $wd 60), (& $sp 70 99 'mysqld.exe' $wd 2),
  (& $sp 80 99 'mysqld.exe' "--defaults-file=D:/k/env.ini --datadir=D:/k/data --tmpdir=D:/k/$rd/work/tmp" 60),(& $sp 90 91 'mariadbd' "--datadir=/k/$rd/work/agents/x/probe" 60), (& $sp 91 1 'bash' 'bash' 5)) $now)
"scratch:$(($so | ForEach-Object { $_.ids -join '+' }) -join ',')"
# K86: a suspended git / glab child whose parent is gone goes; a live parent, a running one, a young one or another name stays
$sus = @(Get-KitSuspendedOrphans @((& $sp 50 1 'pwsh.exe' 'pwsh' 120), (& $sp 52 99 'git.exe' 'git remote -v' 60), (& $sp 53 50 'git.exe' 'git remote -v' 60), (& $sp 54 99 'git.exe' 'git fetch' 60),
  (& $sp 55 99 'git.exe' 'git remote -v' 2), (& $sp 56 99 'node.exe' 'node x' 60)) $now { param($id) $id -ne 54 })
"suspended:$(@($sus.id) -join ',')"
$allDrv = @(Get-KitDrives).Count; function Get-KitInternalLetters { @('Q') }; "intdrv:$($allDrv -ge 1 -and @(Get-KitDrives).Count -eq 0)"   # a drive on no internal disk (USB, external, phone): not watched
'@ @($O, (Kd))
Expect-Each $gen 'resources generic: #' 'none', 'own', 'busy', 'caches', 'cachedef', 'labels-def', 'labels', 'intdrv' -Show 6
Expect "suspended orphans: a suspended git child whose parent is gone past idle.graceMinutes is stopped; a live parent, a running, a young or a non-git one stays ($(@($gen) -match '^suspended:'))" (@($gen) -contains 'suspended:52')
Expect "scratch DB servers: launcher gone past idle.graceMinutes = orphan, its worker child too; a live or reused-later launcher, a young one, an env server (data dir outside runtime work/, its --tmpdir inside) stay; monitor first ($(@($gen) -match '^scratch:'))" (@($gen) -contains 'scratch:60+61,90')
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
$global:tname = '[Backend Unit Test] Named'; function Get-TrackerTask($id) { [pscustomobject]@{ name = $global:tname; status = 'open'; subtasks = @(); description = "Re-run the job until green; the job URL is not known.`n**Pipeline:** [https://h/g/api/-/pipelines/100/test\_report](https://h/g/api/-/pipelines/100/test_report)`n**Env:** Staging · job ``unit-x```n**Branch:** ``staging/x`` @ ``abc``" } }
$c4 = Get-KitCiTask ci4; $t4 = Test-KitCiTaskJob $c4 @('api!5')
"named:$("$($c4.jobName)|$($c4.run)|$($c4.branch)|$($t4.state)" -eq 'unit-x|100|staging/x|pass')"
'@ @($O)
Expect-Each $ciTrack 'track: CI task # (wait: track add of a merged MR promotes at once, holds while the job runs again; closed: job passed -> closed + one qa-result comment with the job link; plain: no pattern match = the testing-doc gate; named: a pipeline link + a job name, no job URL)' @('wait', 'closed', 'plain', 'named') 3
# supervise failedTesting: tracker views in the background (inline: 6-9 s a sweep), cached statuses now, a 2-beat cache
$qd = TkPath $k qa-runs -Create; $null = New-Item -ItemType Directory -Force "$qd/q1/A1"; & $J @{ subtasks = @(1..4 | ForEach-Object { @{ id = "ft$_"; failedTesting = $true } }); watch = @(@{ id = 'X1'; task = 'ft1'; screen = 'api'; env = 'stg' }) } "$qd/q1/A1/finalize.json"
$tn = TkPath $k tracker-none -Create; $ts = { param($i, $s) & $J @{ id = "ft$i"; name = 'n'; status = $s } "$tn/ft$i.json" }; 1..4 | ForEach-Object { & $ts $_ 'failed testing' }
$ftn = { "$(@((pwsh @np $O supervise -Json 2>$null | Out-String | ConvertFrom-Json).flags.what) -match 'failed testing, back' -replace ' .*')" }
$ftw = { foreach ($bj in @(Get-ChildItem (TkPath $k background) -Filter '*statuses*.json' -ErrorAction SilentlyContinue)) { $bjr = Get-Content $bj.FullName -Raw | ConvertFrom-Json; for ($i = 0; $i -lt 300 -and (Get-Process -Id $bjr.pid -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 } } }
$fta = { $svf = TkPath $k supervise-state; $svs = Get-Content $svf -Raw | ConvertFrom-Json -AsHashtable; foreach ($v in $svs.ftStatus.Values) { $v.at = (Get-Date).AddDays(-1).ToString('o') }; $svs | ConvertTo-Json -Depth 20 | Set-Content $svf }
$f1 = & $ftn; & $ftw; $f2 = & $ftn; & $ftw; & $ts 4 'in progress'; $f3 = & $ftn; & $fta; $f4 = & $ftn; & $ftw; & $fta; $f5 = & $ftn
Expect "supervise failedTesting: views in the background, the last result next sweep; an ACT reads the live status role first (a task moved on since the cached view drops at once) ($f1 $f2 $f3 $f4 $f5)" ("$f1|$f2$f3$f4$f5" -eq '|4333')
& $J @{ task = 'ft1'; track = @{ task = 'ft1'; done = $true; mrs = @(); doneAt = (Get-Date).AddMinutes(1).ToString('o') } } (Join-Path (TkPath $k tasks -Create) 'ft1.json'); $f6 = & $ftn
& $ts 2 'Closed'; $f7 = & $ftn
Expect "supervise failedTesting: all MRs merged after the run (track doneAt) clears the task; a task closed since the cached view is no ACT (2026-11-19) ($f5 -> $f6 -> $f7)" ("$f6|$f7" -eq '2|1')
# every view fails (tracker down): one WATCH, not silence
& $ftw; Remove-Item "$tn/ft*.json"; & $fta; $null = & $ftn; & $ftw; & $fta
$fwa = @((pwsh @np $O supervise -Json 2>$null | Out-String | ConvertFrom-Json).flags); $fw = @($fwa | Where-Object { $_.level -eq 'WATCH' -and $_.what -match '^failedTesting views: background .*failed: tracker statuses: 3 view\(s\) failed' })
Expect "supervise failedTesting: failed views are a WATCH ($($fw.Count))" ($fw.Count -eq 1)
Expect "supervise: an unproven QA finding (finalize.json watch, K52) is one WATCH naming run/item, check and env" (@($fwa | Where-Object { $_.level -eq 'WATCH' -and $_.what -match '^1 unproven QA finding.*q1/A1 X1 \(ft1, api\) on stg' }).Count -eq 1)
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
# (cap move from crafty.tests.ps1)
$gt = & { . (Lib); Update-KitTracking { param($t) $t.tasks['g1'] = @{ task = 'g1' }; $t.tasks['g2'] = @{ task = 'g2' } }; "$(Remove-KitGoneTask g1 'HTTP 404 Task not found, deleted') $(Remove-KitGoneTask g2 '404 Not Found') $((Read-KitTracking).tasks.ContainsKey('g1')) $((Read-KitTracking).tasks.ContainsKey('g2'))|$(Test-KitPid $PID (Get-Date).AddHours(-9)) $(Test-KitPid $PID (Get-KitPidStart $PID)) $(Test-KitPid $PID 'x')" }
Expect 'lib: a deleted task leaves tracking (not on outage); reused pid, bad start: dead' ($gt -eq 'True False False True|False True False')
# waste audit 2026-11-18: QA files at their fixed depth, poll backoff, file-change wake, log rows from the window, agent folder cap
$wst = @'
$null = . $args[0] 6>$null; $qa = Get-KitPath qa-runs -Create
foreach ($n in 1..3) { $rd = Join-Path $qa "r$n"; $cd = "$rd/C$n"; New-Item -ItemType Directory -Force "$cd/archive-1", "$cd/scripts", "$cd/evidence" | Out-Null
  foreach ($f in "$rd/run.json", "$cd/finalize.json", "$cd/archive-1/finalize.json", "$cd/scripts/run.json", "$cd/evidence/finalize.json") { Set-Content $f '{}' } }
(Get-Item "$qa/r1/C1/finalize.json").LastWriteTime = (Get-Date).AddDays(-10)
$mine = { process { if ($_.FullName -match '[\\/]r\d[\\/]') { $_ } } }   # the area's earlier runs share qa-runs
$fin = @(Get-KitQaRunFiles finalize.json | & $mine)
"qafiles:$(@(Get-KitQaRunFiles run.json | & $mine).Count -eq 3 -and $fin.Count -eq 3 -and @(Get-KitQaRunFiles finalize.json -SinceDays 7 | & $mine).Count -eq 2 -and -not @($fin | Where-Object { $_.Directory.Name -notmatch '^C\d$' }).Count)"
$global:slept = @(); function Start-Sleep([int]$Seconds) { $global:slept += $Seconds; if ($global:wakeAt -and $global:slept.Count -eq $global:wakeAt) { [IO.File]::SetLastWriteTimeUtc($global:wf, [datetime]::UtcNow.AddMinutes(1)) } }
$env:KIT_PARAM_POLL_MAXSEC = '100'; $bo = @{}; foreach ($sg in 'a', 'a', 'a', 'a', 'b') { Wait-KitBackoff $bo $sg 30 (Get-Date).AddHours(1) }
$s1 = $global:slept -join ','; $global:slept = @(); Wait-KitBackoff $bo 'b' 30 (Get-Date).AddSeconds(5)
"backoff:$($s1 -eq '30,60,100,100,30' -and $global:slept[0] -le 6)"
$global:wf = Join-Path (Get-KitPath work -Create) 'wake.json'; Set-Content $global:wf '{}'; $global:slept = @(); $global:wakeAt = 4; Wait-KitFileChange $global:wf 15
$quiet = $global:slept.Count; $global:wakeAt = 0; $global:slept = @(); Wait-KitFileChange $global:wf 15; "wake:$($quiet -eq 4 -and $global:slept.Count -eq 15)"
$lf = Join-Path (Get-KitPath work) 'rows.jsonl'; $t0 = Get-Date
$rows = @(foreach ($m in 300, 200, 100, 45, 20, 5) { [ordered]@{ at = $t0.AddMinutes(-$m).ToString('o'); m = $m } | ConvertTo-Json -Compress })
Set-Content $lf (@($rows[0..3]) + 'not json' + @($rows[4..5]))
$got = @(Get-KitLogLines $lf $t0.AddMinutes(-30) | ForEach-Object { try { "$(($_ | ConvertFrom-Json).m)" } catch { 'bad' } })
"loglines:$(($got -join ',') -eq '45,bad,20,5')"
$env:KIT_PARAM_CLEANUP_AGENTDIRMAXMB = '1'; $DryRun = $false; $actions = [Collections.ArrayList]::new(); $now = Get-Date
function Gone($path, $why) { Remove-Item -LiteralPath $path -Recurse -Force; [void]$actions.Add([pscustomobject]@{ why = $why; path = $path }) }
function Old($item, $hours) { ($now - $item.LastWriteTime).TotalHours -gt $hours }
$ab = Join-Path (Get-KitPath agents -Create) 'big'; $af = Join-Path (Get-KitPath agents) 'fresh'; New-Item -ItemType Directory -Force $ab, $af | Out-Null
foreach ($p in "$ab/old1.bin", "$ab/old2.bin", "$ab/new1.bin", "$af/a.bin", "$af/b.bin") { [IO.File]::WriteAllBytes($p, [byte[]]::new(700KB)) }
(Get-Item "$ab/old1.bin").LastWriteTime = $now.AddDays(-4); (Get-Item "$ab/old2.bin").LastWriteTime = $now.AddDays(-3)
Invoke-KitCleanupAgentDirs
"cap:$(-not (Test-Path "$ab/old1.bin") -and -not (Test-Path "$ab/old2.bin") -and (Test-Path "$ab/new1.bin") -and (Test-Path "$af/a.bin") -and (Test-Path "$af/b.bin"))"
"overcap:$(@($actions | Where-Object { $_.why -match '^OVER CAP' -and $_.path -eq $af }).Count -eq 1 -and @($actions | Where-Object { $_.why -match '^OVER CAP' }).Count -eq 1)"
'@
Expect-Each (Invoke-PsTest 'waste' $wst @($O)) 'waste audit: #' @('qafiles', 'backoff', 'wake', 'loglines', 'cap', 'overcap') -Show 8
# waste guards: per-beat API budget (WATCH names the caller), idle holders (any leased kind quiet 3x idle.graceMinutes = WATCH)
$wg = @'
$null = . $args[0] 6>$null; $KitAdapters['git-host']['fakeh'] = @{ '*' = { param($a, $v) 1 } }
function Get-FakePlan([int]$N) { foreach ($i in 1..$N) { $null = Invoke-KitAdapter git-host fakeh 'mr.get' @{} } }
$env:KIT_API_LEDGER = Join-Path (Get-KitPath cache -Create) 'api-test.txt'; Get-FakePlan 160; $f1 = @(Get-KitApiBeatFlag $env:KIT_API_LEDGER)
Get-FakePlan 20; $f2 = @(Get-KitApiBeatFlag $env:KIT_API_LEDGER)
# calls inside a lock wrapper name the function around it, not Invoke-KitLocked
function Get-FakeLockedDirect { Invoke-KitLocked (Join-Path (Get-KitPath cache) 'api-lock.json') { foreach ($i in 1..151) { $null = Invoke-KitAdapter git-host fakeh 'mr.get' @{} } } }
Get-FakeLockedDirect; $f3 = @(Get-KitApiBeatFlag $env:KIT_API_LEDGER); Remove-Item Env:KIT_API_LEDGER; Get-FakePlan 5
"wrap:$($f3.Count -eq 1 -and $f3[0].what -match ':Get-FakeLockedDirect 151$')"
"api:$($f1.Count -eq 1 -and $f1[0].level -eq 'WATCH' -and $f1[0].what -match '^API budget: 160 host / tracker adapter verbs this beat \(supervise\.apiCallsPerBeat 150\): \S+:Get-FakePlan 160$' -and -not $f2.Count -and -not (Test-Path (Join-Path (Get-KitPath cache) 'api-test.txt')))"
$lf = Get-KitLogFile leases; $ago = { param($m) (Get-Date).AddMinutes(-$m).ToString('o') }
Set-Content $lf @(foreach ($r in @('gpu', 'g0', 'gone-a', 45), @('local-ai', 'stt', 'fresh-b', 5)) { "{`"at`":`"$(& $ago $r[3])`",`"event`":`"acquire`",`"kind`":`"$($r[0])`",`"name`":`"$($r[1])`",`"agent`":`"$($r[2])`",`"holder`":`"9999999`"}" })
# the first beat that sees no live holder starts the count (an old acquire alone flags nothing); 40 min later only the 45-min lease flags
$now = Get-Date; $ih0 = @(Get-KitSuperviseGuardResources | Where-Object { "$($_.what)" -match 'no live holder for' })
$idf = Join-Path (Get-KitPath cache) 'idle-holders.json'; $idc = Get-Content $idf -Raw | ConvertFrom-Json -AsHashtable; foreach ($ik in @($idc.Keys)) { $idc[$ik] = (& $ago 40) }; $idc | ConvertTo-Json | Set-Content $idf
$ih = @(Get-KitSuperviseGuardResources | Where-Object { "$($_.what)" -match 'no live holder for' })
"idle:$(-not $ih0.Count -and $ih.Count -eq 1 -and $ih[0].level -eq 'WATCH' -and $ih[0].what -match '^gpu .*held by gone-a: no live holder for 40 min$')"
'@
Expect-Each (Invoke-PsTest 'wguard' $wg @($O)) 'waste guards: #' @('api', 'wrap', 'idle') -Show 8
# sweep cost: 500 QA runs (490 older than 7 days) + 3000-row signals and outcomes logs; one beat stays at the measured cost
# (2026-11-18: 750-950 reads, 40-56 API calls; every run.json was read and each run's parent viewed: 6500 reads, 1000+ calls)
$wc = @'
param($O, $Fill)
$null = . $O 6>$null 2>$null
if ($Fill) { $qa = Get-KitPath qa-runs -Create; $old = (Get-Date).AddDays(-10)
  foreach ($n in 1..500) { $rd = Join-Path $qa "r$n"; New-Item -ItemType Directory -Force "$rd/C1" | Out-Null; Set-Content "$rd/run.json" "{`"tracker`":{`"parent`":`"P$n`"},`"items`":[]}"; Set-Content "$rd/C1/finalize.json" '{}'
    if ($n -gt 10) { foreach ($p in "$rd/run.json", "$rd/C1/finalize.json", "$rd/C1", $rd) { (Get-Item $p).LastWriteTime = $old } } }
  foreach ($lg in 'signals', 'outcomes') { $t0 = (Get-Date).AddDays(-2); Set-Content (Get-KitPath $lg -Create) @(foreach ($i in 1..3000) { "{`"at`":`"$($t0.AddMinutes($i).ToString('o'))`",`"skill`":`"crafty`",`"kind`":`"idea`",`"text`":`"row $i`",`"task`":`"t$i`",`"stage`":`"x`"}" }) }
  return }
$io = { if ($IsWindows) { [long](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ReadOperationCount } else { 0 } }
$env:KIT_PARAM_SUPERVISE_APICALLSPERBEAT = '0'; $r0 = & $io; $sj = & $O supervise -Json 2>$null | Out-String | ConvertFrom-Json; $r1 = & $io
$api = @($sj.flags | Where-Object { $_.what -match '^API budget: (\d+) ' } | ForEach-Object { [int]$Matches[1] })[0]
"cost:$($r1 - $r0) reads, $([int]$api) api"
'@
$wcf = Join-Path (Kd) 'wcost.ps1'; Set-Content $wcf $wc; $null = & $pwshExe -NoProfile -File $wcf $O 1; $wco = "$(& $pwshExe -NoProfile -File $wcf $O '' | Select-Object -Last 1)"
$wcr = if ($wco -match '^cost:(\d+) reads, (\d+) api$') { [int]$Matches[1], [int]$Matches[2] } else { 99999, 99999 }
Expect "waste guards: one supervise beat over 500 QA runs + 3000-row logs <= 2000 file reads (measured 950) and <= 120 API calls (measured 56) ($wco)" ($wcr[0] -le 2000 -and $wcr[1] -le 120)
# write-if-changed: supervise, learn -Stats and kitbag.py release run twice on the same input: no file is rewritten with the same bytes
# (by design: usage.result.json and live-steps.json -Volatile move their time, a background job's .out / .err are its new run, the API ledger its late calls)
$wsnap = { @(Get-ChildItem -LiteralPath $k -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '[\\/](\.runtime|\.state)[\\/]' -and $_.FullName -notmatch '[\\/]background[\\/]|usage\.result\.json$|live-steps\.json$|supervise-api\.txt$' } |
  ForEach-Object { [pscustomobject]@{ f = $_.FullName.Substring($k.Length); t = $_.LastWriteTimeUtc.Ticks; h = (Get-FileHash -LiteralPath $_.FullName -Algorithm MD5).Hash } }) }
$wsame = foreach ($wrun in { $null = & $pwshExe -NoProfile -File $O supervise -Json 2>$null }, { $null = & $pwshExe -NoProfile -File $O learn -Stats 2>$null }, { $null = & $py -X utf8 (Join-Path $k 'skills/bossy/kitbag.py') release 2>$null }) {
  & $wrun; Start-Sleep -Milliseconds 1100; $wa = @{}; foreach ($x in & $wsnap) { $wa[$x.f] = $x }; & $wrun
  foreach ($y in & $wsnap) { $x = $wa[$y.f]; if ($x -and $x.t -ne $y.t -and $x.h -eq $y.h) { $y.f } } }
Expect "waste guards: a second supervise / learn -Stats / release on the same input rewrites no file with the same bytes ($($wsame -join ', '))" (-not @($wsame).Count)
# QA parents index (owner decision 2026-11-18): a [Bug] under the parent of a 20-day-old run (no run.json in the 7-day scan) still
# raises its ACT; a second beat within 6 h views it no more (cached); finalize writes the index
$qpt = @'
$env:KIT_TRACKER_TYPE = 'none'; $null = . $args[0] 6>$null; $cd = $KitCmd.dev
$ask = (pwsh -NoProfile -File $cd tracker create -Key qa-fx-qp-1 -List L1 -Name 'Ask old' -Description 'a' -NewTask fixture | ConvertFrom-Json).id
$null = pwsh -NoProfile -File $cd tracker create -Key qa-fx-qp-2 -List L1 -Parent $ask -Name '[Bug] Old ask button broken' -Description 'b' -NewTask fixture
Add-KitQaParent $ask (Get-Date).AddDays(-20); Add-KitQaParent 'gone-40d' (Get-Date).AddDays(-40)
$act = { @((pwsh -NoProfile -File $args[0] supervise -Json 2>$null | Out-String | ConvertFrom-Json).flags | Where-Object { $_.level -eq 'ACT' -and $_.what -match 'new QA bug task' }).Count }
$a1 = & $act $args[0]; $seen1 = (Get-Content (Join-Path (Get-KitPath cache) 'qa-parents.json') -Raw | ConvertFrom-Json -AsHashtable)
$a2 = & $act $args[0]
"old:$($a1 -eq 1 -and $seen1[$ask].seen -and -not $seen1.ContainsKey('gone-40d'))"
"cached:$($a2 -eq 0)"
'@
Expect-Each (Invoke-PsTest 'qaparents' $qpt @($O)) 'QA parents index: #' @('old', 'cached') -Show 8
# builds per agent (owner 2026-11-18 "why were so many builds needed?"): today's count, build-min, failed per owner in a table
# card, QA seat leases aside; over gate.buildsPerHour in the last hour -> one WATCH BUILDS per owner
$bpo = & { . $O; $n = Get-Date; $dd = Join-Path (Get-KitPath audit -Create) $n.ToString('yyyy-MM-dd'); New-Item -ItemType Directory -Force $dd | Out-Null
  $bl = @(1..10 | ForEach-Object { @{ at = $n.AddMinutes(-3 * $_).ToString('o'); event = 'end'; kind = 'maven-test'; owner = 'w1'; project = 'svc-x/api'; sec = 120; waitSec = 0; code = [int]($_ -le 2) } }) +
    @(@{ at = $n.AddMinutes(-4).ToString('o'); event = 'end'; kind = 'maven'; owner = 'w2'; project = 'svc-x/api'; sec = 60; waitSec = 0; code = 0 }) +
    @(1..12 | ForEach-Object { @{ at = $n.AddMinutes(-2 * $_).ToString('o'); event = 'end'; kind = 'other'; owner = 'test:T1'; project = 'kit/work/qa-seats'; sec = 0; waitSec = 0; code = 0 } })
  $bl | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $dd 'builds.jsonl')
  $g = Get-KitGateStats $n @(); $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); mem = @{ TotalGB = 16; AvailGB = 8 }; stats = [pscustomobject]@{ gate = $g; keepFree = 2 } })
  $now = $n; $script:mem = @{ AvailGB = 8; TotalGB = 16 }; $fl = @(Get-KitSuperviseGuardResources | Where-Object { $_.kind -eq 'BUILDS' -and "$($_.what)" -match 'gated builds' })
  "$(@($g.owners | ForEach-Object { "$($_.name)=$($_.n)/$($_.min)/$($_.failed)" }) -join ',')|$($h -match ">w1</span></span></span><span[^>]+>(<i[^>]*>[^<]*</i>)+</span><span class='gc' data-mv=b>10</span><span class='gc' data-mv=b>20</span><span class=gc data-mv=b><span class='chip s-stuck'>2<")|$($fl.Count)|$($fl[0].who)" }
Expect "kind row: owner, today / min / failed; no QA seats; over gate.buildsPerHour (8) -> one WATCH ($bpo)" ($bpo -eq 'w1=10/20/2,w2=1/1/0|True|1|w1')
# flags table (D4/D7, owner 2026-11-19): ACT first, a repeat (same level, kind, problem) one row with its count and both owners; auto-fixes and notes one folded row
$ftb = & { . $O; $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; flags = @(@{ level = 'WATCH'; kind = 'SHELL'; who = 'a1'; problem = 'pid 4 quiet 30 min'; action = 'end it' }, @{ level = 'WATCH'; kind = 'SHELL'; who = 'a2'; problem = 'pid 9 quiet 31 min' }, @{ level = 'ACT'; what = 'DISK D: low' }, @{ level = 'INFO'; what = 'auto-fixed: killed shell 7' }) })
  "$($h.IndexOf("<tr class='f fr ACT'>") -lt $h.IndexOf("<tr class='f fr WATCH'>")) $(([regex]::Matches($h, "<tr class='f fr WATCH'>")).Count) $($h -match "title='seen 2 times this sweep'>x2</span></td><td>SHELL</td><td>a1, a2</td>") $($h -match 'data-tg=fx-rows aria-expanded=false>1 auto-fixed this sweep</button></td></tr></tbody><tbody id=fx-rows hidden>')" }
Expect "flags table: ACT first, a repeat one row x2 with both owners, auto-fixes folded ($ftb)" ($ftb -eq 'True 1 True True')
# D1 (owner 2026-11-19): kit-owned = the kit's trees summed, other processes = the machine minus them: both rows have CPU samples and now values; a row with no sample folds
$kow = & { . $O; $n = [datetime]'2026-01-02T10:00:00'; $cs = [pscustomobject]@{ samples = @([pscustomobject]@{ at = $n.AddMinutes(-20).ToString('o'); s = 600; all = 50; g = @{ 'e · api' = 10; 'phone P' = 5 }; m = @{ 'e · api' = 2; 'phone P' = 1 }; top = @() }); svc = @('e · web') }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); mem = @{ TotalGB = 16; AvailGB = 8 }; stats = [pscustomobject]@{ cpu = $cs } })
  "$($h -match "kit-owned &#183; CPU avg 15% &#183; peak 15% &#183; RAM 3 GB'>") $($h -match "other processes &#183; CPU avg 35%") $($h -match "<span class='gc' data-mv=c title='kit-owned: now CPU 15 %'>15</span>") $($h -match "idle rows · no data in 24 h</button><div class=gki><div class='gk'><span class=gn title='e &#183; web")" }
Expect "resources: kit-owned and other processes rows carry samples, a sample-less row folds ($kow)" ($kow -eq 'True True True True')
# board leave (owner 2026-11-19): the leaving agent's background shells die (its transcript), another agent's and a foreground one stay
$lsh = & { . $O; $tx = Join-Path (Kd) 'agent-k1.jsonl'; $ps = @([pscustomobject]@{ Id = 50; ParentId = 1; Name = 'claude.exe' }) + @(60, 61, 62 | ForEach-Object { [pscustomobject]@{ Id = $_; ParentId = 50; Name = 'bash.exe'; CommandLine = "bash -c 'sleep $_'" } })
  $fd = @{ '60' = [pscustomobject]@{ file = $tx; bg = $true }; '61' = [pscustomobject]@{ file = (Join-Path (Kd) 'agent-x.jsonl'); bg = $true }; '62' = [pscustomobject]@{ file = $tx; bg = $false } }
  $killed = [Collections.Generic.List[int]]::new(); $said = @(Stop-KitLeftShells ([pscustomobject]@{ agent = 'k1'; transcript = $tx }) $ps $fd { param($id) $killed.Add($id) })
  "$($killed -join ',')|$($said -match '^killed shell 60 of k1: ' -as [bool])" }
Expect "board leave: its background shells killed, not another agent's or a foreground one ($lsh)" ($lsh -eq '60|True')
# coordinator 2026-11-19: 4 MR lists took 15 s of a 40 s sweep: at most 2 due repos a beat, oldest first; a missing dep source: WATCH
Copy-Item (Join-Path $src 'skills/bossy/adapters/localenv_supervise.ps1') (Join-Path $k 'skills/bossy/adapters')
$ul = Invoke-PsTest ulist @'
. $args[0]; $n = Get-Date; $script:hostCalls = @(); function Invoke-HostVerb($v, $p) { $script:hostCalls += $p.repo; @() }; function Get-HostProject($r, [switch]$Raw) { $r }
$KitConf.TrackerRepos = @('a', 'b', 'c', 'd'); $s = @{ hostUser = @{ at = "$n"; v = 'u' }; untrackedMrs = @{ user = 'u'; repos = @{ c = @{ at = $n.AddHours(-2).ToString('o'); mrs = @() }; d = @{ at = "$n"; mrs = @() } } } }
$null = Get-KitUntrackedMrFlag $s $n; "ul:$($script:hostCalls -join ',')|$(@($s.untrackedMrs.repos.Keys | Sort-Object) -join ',')"
$script:noDir = $args[0] -replace 'bossy.ps1$', 'no-such-dir'; function Get-KitValue($key, $def) { if ($key -eq 'repos') { @([pscustomobject]@{ name = 'web'; linkFrom = $script:noDir; linkFromByTarget = [pscustomobject]@{ main = @($PSScriptRoot, $env:TEMP) } }) } else { $def } }
"ds:$(@(Get-KitDepSourceFlags).what -join '|')"
'@ @($O)
Expect "supervise: untracked MRs list at most 2 due repos a beat, never-listed first, a fresh one kept ($ul)" (@($ul | Where-Object { "$_" -match '^ul:(a,b|b,a)\|a,b,c,d$' }).Count -eq 1)
Expect "supervise: a missing linkFrom dep source is one WATCH, existing linkFromByTarget ones none ($ul)" (@($ul | Where-Object { "$_" -match '^ds:DEP SOURCE MISSING: web \S+no-such-dir \(kit\.local\.json' }).Count -eq 1)
Remove-TestKit $k
Complete-Tests
