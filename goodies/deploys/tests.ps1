#Requires -Version 7
<#
tests.ps1 (goody deploys): deploy plan / request / record batching, trigger owner vs ask, UNKNOWN on a failed check.
Usage: pwsh -NoProfile -File goodies/deploys/tests.ps1 (kitbag.py goody test deploys: next to the kit's tests/harness.ps1; New-TestKit
gets this goody's files).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit deploys; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $tf = Join-Path $k '.state/tracking.json'
$cfgF = Join-Path $k 'skills/crafty/kit.local.json'; $dep = { Px $O deploy @args }
$J0 = $J; $J = { param($o, $f, [int]$d = 8) if ($f -eq $tf) { Remove-Item (Join-Path $k '.state/tasks'), (Join-Path $k '.state/automerge.json') -Recurse -Force -ErrorAction SilentlyContinue }; & $J0 $o $f $d }   # a tracking.json fixture replaces the state it moved into
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }, @{ target = 'prod'; branch = 'production'; job = 'deploy' }, @{ target = 'live'; production = $true }, @{ target = 'preprod'; production = $false }) }); deploy = @{ trigger = 'ask'; minIntervalHours = @{ default = 4 } } } $cfgF
$null = New-Item -ItemType Directory -Force (Split-Path $tf); & $J @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('api!1'); done = $true; doneAt = (Get-Date).ToString('s') }; t2 = @{ task = 't2'; mrs = @('api!2'); done = $false } }; automerge = @{} } $tf
$fx = Join-Path (Kd) 'deploy-fixture.json'
& $J @{ mrs = @{ 'api!1' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) }; 'api!2' = @{ rows = @(@{ target = 'stage'; state = 'DEPLOYED'; detail = 'live' }) }; 'api!3' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) } }; lastCi = @{ stage = (Get-Date).AddHours(-6).ToString('s') } } $fx
$plan = { @(& $dep plan -Offline $fx -Json | ConvertFrom-Json) }; $p = & $plan
Expect 'deploy plan: production by name / flag / false; one ASK batch for stage' (($p.target -join ',') -eq 'stage,preprod' -and $p[0].target -eq 'stage' -and $p[0].status -eq 'ASK' -and (@($p[0].mrs.mr) -join ',') -eq 'api!1')
$null = & $dep request -Mrs 'https://git.example.com/g/api/-/merge_requests/3' -Run w2 -Offline $fx; $p = & $plan
Expect 'deploy request: another session''s MR joins the same batch' ((@($p[0].mrs.mr | Sort-Object) -join ',') -eq 'api!1,api!3')
$pcf = Join-Path (TkPath $k deploys -Create) 'plan-cache.json'; $bgp = Join-Path (TkPath $k background -Create) (& { . (Lib); ConvertTo-KitSlug 'bossy.ps1 deploy plan' })
foreach ($f in $pcf, "$bgp.out", "$bgp.json") { '{"at":"2020-01-01","ask":["stage: 1 MR(s) (api!1)"],"pid":1}' | Set-Content $f }
$null = & $dep record -Env stage -Mrs 'api!1','api!3' -By tester; $p = & $plan
Expect 'deploy record: WAIT in the window, the request cleared; the cached + background plan dropped (no second ask)' ($p[0].status -eq 'WAIT' -and -not @($p[0].pending).Count -and -not (Test-Path $pcf) -and -not (Test-Path "$bgp.out") -and -not (Test-Path "$bgp.json"))
# a host-group name (no repos[].deploys target) is refused; a list records each target; a recorded MANUAL MR leaves the batch
$fxm = Join-Path (Kd) 'deploy-fixture-m.json'; & $J @{ mrs = @{ 'api!7' = @{ rows = @(@{ target = 'preprod'; state = 'MANUAL'; detail = 'by hand' }) } } } $fxm
$null = & $dep request -Mrs 'api!7' -Run w5 -Offline $fxm; $m0 = @(@(& $dep plan -Offline $fxm -Json | ConvertFrom-Json) | Where-Object target -eq preprod).mrs.Count
$ru = & $dep record -Env 'stage-group' -Mrs 'api!7' | Out-String; $ruc = $LASTEXITCODE; $rl0 = @(Get-Content (TkPath $k deploy-log)).Count
$null = & $dep record -Env 'stage,preprod' -Mrs 'api!7' -By tester; $rl = @(Get-Content (TkPath $k deploy-log) | ConvertFrom-Json | Select-Object -Last 2).target -join ','
$m1 = @(@(& $dep plan -Offline $fxm -Json | ConvertFrom-Json) | Where-Object target -eq preprod).mrs.Count
Expect "deploy record: an unknown target refused (exit 2, nothing logged), a list = one line per target, a recorded MANUAL MR leaves the batch ($ruc $rl $m0>$m1)" ($ruc -eq 2 -and $ru -match 'unknown target\(s\) stage-group' -and $rl0 -eq 1 -and $rl -eq 'stage,preprod' -and $m0 -eq 1 -and $m1 -eq 0)
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }, @{ name = 'py'; deploys = @(@{ target = 'pystage' }) }) } $cfgF
$fx2 = Join-Path (Kd) 'deploy-fixture2.json'; & $J @{ mrs = @{ 'api!5' = @{ rows = @(@{ target = 'stage'; state = 'UNKNOWN'; detail = 'cannot reach the host' }) } } } $fx2
$dr = & $dep request -Mrs 'api!5' -Run w4 -Offline $fx2 | Out-String
Expect 'deploy request: only the MR repo''s deploys; UNKNOWN names the deploy and why' ($dr -match 'DEPLOY stage: UNKNOWN: the deploy check failed: api!5: cannot reach the host' -and $dr -notmatch 'pystage')
$null = & $dep record -Env stage -Mrs 'api!5' -By tester
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } $cfgF
$null = & $dep request -Mrs 'api!3' -Run w3 -Offline $fx; $p = & $plan
Expect 'deploy plan: trigger owner -> READY in the window, never ASK / WAIT' ($p[0].status -eq 'READY' -and $p[0].trigger -eq 'owner')
# done + live on every test env (liveOn), or done without doneAt (an old record): not looked up, not in the batch
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage' }, @{ target = 'qa2' }) }) } $cfgF
$now = (Get-Date).ToString('s'); $nd = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }, @{ target = 'qa2'; state = 'NOT-DEPLOYED'; detail = 'x' }) }
& $J @{ tasks = @{ a = @{ task = 'a'; mrs = @('api!7'); done = $true; doneAt = $now; liveOn = @('stage', 'qa2') }; b = @{ task = 'b'; mrs = @('api!8'); done = $true }; c = @{ task = 'c'; mrs = @('api!9'); done = $true; doneAt = $now; liveOn = @('stage') } }; automerge = @{} } $tf
$fx3 = Join-Path (Kd) 'deploy-fixture3.json'; & $J @{ mrs = @{ 'api!7' = $nd; 'api!8' = $nd; 'api!9' = $nd } } $fx3
$p = @(& $dep plan -Offline $fx3 -Json | ConvertFrom-Json)
Expect 'deploy plan: skips a task live on every test env and a done task without doneAt' ((@($p | Where-Object target -eq 'stage' | ForEach-Object { $_.mrs.mr }) -join ',') -eq 'api!9')
# an open task untouched for -Days (14) is not this plan's: October's 94 MRs filled it
& $J @{ tasks = @{ d = @{ task = 'd'; mrs = @('api!10'); done = $false; created = (Get-Date).AddDays(-30).ToString('s') }; e = @{ task = 'e'; mrs = @('api!11'); done = $false; created = (Get-Date).AddDays(-30).ToString('s'); allMergedAt = $now } }; automerge = @{} } $tf
$fx5 = Join-Path (Kd) 'deploy-fixture5.json'; & $J @{ mrs = @{ 'api!10' = $nd; 'api!11' = $nd } } $fx5
$p = @(& $dep plan -Offline $fx5 -Json | ConvertFrom-Json)
Expect 'deploy plan: an open task with no activity in -Days is skipped; one merged recently stays' ((@($p | Where-Object target -eq 'stage' | ForEach-Object { $_.mrs.mr }) -join ',') -eq 'api!11')
# one repo, two products: an MR counts only where deploys[].from has its target branch and deploys[].paths a file it touched
& $J @{ repos = @(@{ name = 'web'; deploys = @(@{ target = 'a-st'; from = 'a-main' }, @{ target = 'b-st'; from = @('main'); paths = @('b/ui/**', 'b/[id]/*.ts') }, @{ target = 'c-st' }) }) } $cfgF
& $J @{ tasks = @{ f = @{ task = 'f'; mrs = @('web!1', 'web!2', 'web!3', 'web!4', 'web!5', 'web!6'); done = $true; doneAt = $now } }; automerge = @{} } $tf
$nd3 = { param($tb, $ps, $ov) @{ targetBranch = $tb; paths = $ps; overflow = $ov; rows = @('a-st', 'b-st', 'c-st' | ForEach-Object { @{ target = $_; state = 'NOT-DEPLOYED'; detail = 'x' } }) } }
$fx4 = Join-Path (Kd) 'deploy-fixture4.json'; & $J @{ mrs = @{ 'web!1' = (& $nd3 'a-main' @('a/ui/x.ts')); 'web!2' = (& $nd3 'main' @('b/ui/y.ts')); 'web!3' = (& $nd3 'main' @('a/old/z.ts')); 'web!4' = (& $nd3 $null $null); 'web!5' = (& $nd3 'main' @('b/[id]/p.ts')); 'web!6' = (& $nd3 'main' @('a/x.ts') $true) } } $fx4
$p = @(& $dep plan -Offline $fx4 -Json | ConvertFrom-Json); $by = { param($t) (@(@($p | Where-Object target -eq $t).mrs.mr) | Sort-Object) -join ',' }
Expect "deploy plan: deploys[].from / paths pick the targets an MR feeds; an unknown branch, a missing or cut file list keeps it; [id] is literal ($(& $by a-st) | $(& $by b-st) | $(& $by c-st))" ((& $by a-st) -eq 'web!1,web!4' -and (& $by b-st) -eq 'web!2,web!4,web!5,web!6' -and (& $by c-st) -eq 'web!1,web!2,web!3,web!4,web!5,web!6')
$sup = (Get-Content (Join-Path $k 'skills/bossy/adapters/deploys.ps1') -Raw) -match "deploy\.trigger' 'owner'\)\)\.ToLower\(\) -eq 'ask'"
Expect 'supervise: DEPLOY ASK only under trigger ask' $sup
$dps = Get-Content (Join-Path $k 'skills/bossy/adapters/deploys.ps1') -Raw
$preg = (Get-Content (Join-Path $src 'skills/bossy/params.registry.json') -Raw | ConvertFrom-Json).params
Expect 'deploy plan: -TimeoutSec from deploy.deployedTimeoutSec (100 s); supervise passes deploy.planTimeoutSec (600 s, params.registry.json); a record triggers a learn pass' ($dps -match "\[int\]\`$TimeoutSec = \(Get-KitParam 'deploy\.deployedTimeoutSec'\)\)" -and $preg.'deploy.deployedTimeoutSec' -match 'default=100\b' -and $dps -match "'-TimeoutSec', \[int\]\(Get-KitParam 'deploy\.planTimeoutSec'\)" -and $dps -match 'Add-KitParamTrigger deploy' -and (Get-Content (Join-Path $src 'skills/bossy/params.registry.json') -Raw | ConvertFrom-Json).params.'deploy.planTimeoutSec' -match 'default=600\b')
# one pokey.ps1 deployed per repo, in parallel, each MR on the targets it needs: a crashed or slow run is UNKNOWN (never NOTHING), the others stand
$fRepos = @(foreach ($n in 'bad', 'slow', 'good', 'part', 'crash', 'many') { @{ name = $n; deploys = @(@{ target = $n }) } }) + @(@{ name = 'two'; deploys = @(@{ target = 'ta' }, @{ target = 'tb' }) }, @{ name = 'fr'; deploys = @(@{ target = 'fa'; from = 'x-main' }, @{ target = 'fb' }) })
& $J @{ repos = $fRepos } $cfgF
& $J @{ tasks = @{ u = @{ task = 'u'; mrs = @(@(foreach ($n in 'bad', 'slow', 'good', 'part', 'crash', 'two') { "$n!1"; "$n!2" }) + @(1..9 | ForEach-Object { "many!$_" }) + @('fr!1', 'fr!2')); done = $false } }; automerge = @{} } $tf
$fq = Join-Path (Kd) 'fake-deployed.ps1'
Set-Content $fq @'
$t = $args[[array]::IndexOf($args, '-Target') + 1]; $ms = @($args[[array]::IndexOf($args, '-Mrs') + 1] -split ','); Add-Content $env:FAKE_LOG "$t|$($ms -join ',')"
if ($t -eq 'good') { Set-Content $env:FAKE_TO $args[[array]::IndexOf($args, '-TimeoutSec') + 1] }
if ($t -eq 'slow') { Start-Sleep 30 }
if ($t -eq 'bad') { 'pokey.ps1: usage error'; exit 2 }
foreach ($y in $t -split ',') { "{`"mr`":`"$($ms[0])`",`"target`":`"$y`",`"state`":`"NOT-DEPLOYED`",`"detail`":`"x`"}" }
if ($t -eq 'part') { Start-Sleep 30 }; if ($t -eq 'crash') { exit 3 }   # <repo>!1 checked, <repo>!2 never
if ($t -match ',') { "{`"mr`":`"$($ms[1])`",`"target`":`"$t`",`"state`":`"UNKNOWN`",`"detail`":`"deadline`"}"; exit 1 }   # a row for no one target
foreach ($y in $t -split ',') { "{`"mr`":`"$($ms[1])`",`"target`":`"$y`",`"state`":`"DEPLOYED`",`"detail`":`"live`"}" }
'@ -Encoding utf8
$ut = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$KitCmd.qa = $args[1]; $env:FAKE_TO = $args[2]; $env:FAKE_LOG = $args[3]; $sw = [Diagnostics.Stopwatch]::StartNew(); $script:KitMrTb = @{ 'fr!1' = 'y-main'; 'fr!2' = 'y-main' }
$p = @(Invoke-Deploy plan -Json -TimeoutSec 4 | ConvertFrom-Json); $s = @{}; foreach ($x in $p) { $s[$x.target] = $x }
"bad:$($s.bad.status -eq 'UNKNOWN' -and $s.bad.why -match 'exit 2 on bad')"
"slow:$($s.slow.status -eq 'UNKNOWN' -and $s.slow.why -match 'timed out after 4 s on slow')"
"good:$($s.good.status -eq 'READY' -and (@($s.good.mrs.mr) -join ',') -eq 'good!1')"
"part:$($s.part.status -eq 'READY' -and (@($s.part.mrs.mr) -join ',') -eq 'part!1' -and $s.part.why -match 'part!2: not checked: .*timed out after 4 s on part')"
"feeds:$($s.fa.status -eq 'NOTHING' -and -not $s.fa.why -and $s.fb.status -eq 'READY' -and $s.fb.why -match 'fr!2: deadline')"
"crash:$($s.crash.status -eq 'READY' -and $s.crash.why -match 'crash!2: not checked: pokey\.ps1 deployed exit 3 on crash')"
"parallel:$($sw.Elapsed.TotalSeconds -lt 20)"
"childcap:$((Get-Content $env:FAKE_TO) -as [int] -in 0..3)"
$lg = @(Get-Content $env:FAKE_LOG); "slices:$((@($lg | Where-Object { $_ -like 'many|*' } | ForEach-Object { @(($_ -split '\|')[1] -split ',').Count }) -join ',') -eq '4,4,1')";"perrepo:$($lg.Count -eq 10 -and $lg -contains 'ta,tb|two!1,two!2' -and $s.ta.status -eq 'READY' -and $s.tb.status -eq 'READY' -and $s.ta.why -match 'two!2: deadline' -and $s.tb.why -match 'two!2: deadline')"
Remove-Item $env:FAKE_LOG; $null = Invoke-Deploy plan -Env tb -Json -TimeoutSec 4; "needed:$((@(Get-Content $env:FAKE_LOG) -join ';') -eq 'tb|two!1,two!2')"
$null = Invoke-Deploy plan -TimeoutSec 4   # text mode: each row on stderr as it comes
'@
$res = Invoke-PsTest 'deploy-unknown' $ut @($O, $fq, (Join-Path (Kd) 'child-timeout.txt'), (Join-Path (Kd) 'child-calls.txt'))
Expect-Each $res 'deploy plan: one run per repo (slices of 4+ MRs) in parallel with only the targets each MR needs, a failed one UNKNOWN; a timeout keeps the rows already checked; each child gets the time left as -TimeoutSec (#)' @('bad', 'slow', 'good', 'part', 'crash', 'parallel', 'childcap', 'perrepo', 'needed', 'slices', 'feeds')
$all = $res -join "`n"
Expect 'deploy plan: each NOT-DEPLOYED row printed as its check ends (a slow env''s too), DEPLOYED / UNKNOWN only counted per state' ($all -match '(?m)^\s+part!1 @ part: NOT-DEPLOYED x' -and $all -notmatch '(?m)^\s+good!2 @ good: DEPLOYED live' -and $all -match 'deploy plan probes: DEPLOYED \d+ · NOT-DEPLOYED \d+')
# an MR whose merge is in the deploy branch's last green job: DEPLOYED from one git rev-list, never probed; the request is on disk before the probe
$gr = Join-Path (Kd) 'anc-repo'; $null = git init -q -b main $gr; git -C $gr -c user.name=t -c user.email=t@t commit -q --allow-empty -m c1
$c1 = git -C $gr rev-parse HEAD; git -C $gr branch staging; git -C $gr -c user.name=t -c user.email=t@t commit -q --allow-empty -m c2; $c2 = git -C $gr rev-parse HEAD
& $J @{ repos = @(@{ name = 'api'; checkout = $gr; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } $cfgF
& $J @{ tasks = @{ v = @{ task = 'v'; mrs = @('api!1'); done = $false } }; automerge = @{} } $tf
$fa = Join-Path (Kd) 'fake-deployed-anc.ps1'
Set-Content $fa @'
$m = $args[[array]::IndexOf($args, '-Mrs') + 1]; Add-Content $env:FAKE_ASKED $m
$pend = (Test-Path $env:FAKE_PENDING) -and (Get-Content $env:FAKE_PENDING -Raw) -match 'api!2'
foreach ($x in $m -split ',') { "{`"mr`":`"$x`",`"target`":`"stage`",`"state`":`"NOT-DEPLOYED`",`"detail`":`"pending:$pend`"}" }
exit 1
'@ -Encoding utf8
$ua = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$KitCmd.qa = $args[1]; $c1 = $args[2]; $c2 = $args[3]; $env:FAKE_ASKED = $args[4]; $env:FAKE_PENDING = Join-Path (Get-KitPath deploys -Create) 'pending.json'; Remove-Item $env:FAKE_PENDING -ErrorAction SilentlyContinue
function Invoke-HostApi([string]$Path) {
  if ($Path -match 'merge_requests\?') { if ($Path -match 'page=1') { @([pscustomobject]@{ iid = 1; merge_commit_sha = $c1; target_branch = 'main' }, [pscustomobject]@{ iid = 2; merge_commit_sha = $c2; target_branch = 'main' }) }; return }
  if ($Path -match 'pipelines/7/jobs') { return @([pscustomobject]@{ name = 'deploy'; status = 'success' }) }
  if ($Path -match 'pipelines\?') { return @([pscustomobject]@{ id = 7; sha = $c1; status = 'success'; updated_at = (Get-Date).AddHours(-6).ToString('s') }) }
}
$p = @((@(Invoke-Deploy request -Mrs 'api!2' -Run w9 -Json) -notmatch '^requested ') -join "`n" | ConvertFrom-Json); $asked = @(Get-Content $env:FAKE_ASKED)
"skip:$(($asked -join ';') -eq 'api!2')"
"batch:$($p[0].status -eq 'READY' -and (@($p[0].mrs.mr) -join ',') -eq 'api!2')"
"first:$($p[0].mrs[0].detail -eq 'pending:True')"
$rp = @(Get-KitValue 'repos' @()); $two = @([pscustomobject]@{ name = 'api'; checkout = $rp[0].checkout; deploys = @($rp[0].deploys[0], [pscustomobject]@{ target = 'stage'; ssh = @{ host = 'h' } }) })
$gone = @([pscustomobject]@{ name = 'api'; checkout = 'Z:/no-such-checkout'; deploys = $rp[0].deploys })
"degrade:$((Get-DeployedByAncestry @('api!1') $two @('stage')).Count -eq 0 -and (Get-DeployedByAncestry @('api!1') $gone @('stage')).Count -eq 0 -and (Get-DeployedByAncestry @('api!1') $rp @('stage') 14 (Get-Date).AddSeconds(-1)).Count -eq 0)"
'@
$res = Invoke-PsTest 'deploy-ancestry' $ua @($O, $fa, $c1, $c2, (Join-Path (Kd) 'asked.txt'))
Expect-Each $res 'deploy plan: an MR in the last green deploy job is not probed; the request is recorded before the probe; another deploy to the same env, no checkout or a passed deadline -> probed (#)' @('skip', 'batch', 'first', 'degrade')
$it = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$d0 = (Get-Date).ToString('o'); $old = (Get-Date).AddDays(-30).ToString('o')
Update-KitTracking { param($t) $t.tasks['gone1'] = @{ task = 'gone1'; mrs = @('api!1'); done = $true; doneAt = $d0 }; $t.tasks['ok2'] = @{ task = 'ok2'; mrs = @('api!2'); done = $true; doneAt = $d0 }
  $t.tasks['old3'] = @{ task = 'old3'; mrs = @('api!3'); done = $true; doneAt = $old }; $t.tasks['open4'] = @{ task = 'open4'; mrs = @('api!4') }; $t.tasks['qa5'] = @{ task = 'qa5'; mrs = @('api!5'); done = $true; doneAt = $d0; qaCovered = @('r1') } }
$script:viewed = @(); function Get-TrackerTask($id) { $script:viewed += $id; if ($id -eq 'gone1') { throw "HTTP 404 'Task not found, deleted'" }; [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } }
$o = Invoke-MarkInTest -Apply | Out-String
"gone:$($o -match 'GONE  gone1' -and $o -match 'deleted in the tracker \(gone1\)' -and -not (Read-KitTracking).tasks.ContainsKey('gone1') -and (Read-KitTracking).tasks.ContainsKey('ok2'))"
"scope:$((@($script:viewed | Sort-Object) -join ',') -eq 'gone1,ok2,qa5' -and $o -match "mark-in-test: 3 task\(s\) checked \(3 promoted by the kit in 14 d, subtasks included\): 2 now 'inProgress', 1 deleted in the tracker \(gone1\)")"
$script:viewed = @(); $tq = Invoke-MarkInTest -Task old3 | Out-String; "task:$(($script:viewed -join ',') -eq 'old3' -and $tq -match "SKIP  old3  status 'inProgress', not promoted")"
Update-KitTracking { param($t) $t.tasks['api!4'] = @{ task = 'api!4'; mrs = @('api!4') } }   # an MR ref registered as a task
function Get-TrackerTask($id) { $script:viewed += $id; if ($id -ne 'nil1') { [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } } }; $nq = Invoke-MarkInTest -Task nil1 | Out-String
$script:viewed = @(); $mq = Invoke-MarkInTest -FromMrs 'api!4,api!3,api!9' | Out-String
"mrs:$((@($script:viewed | Sort-Object) -join ',') -eq 'old3,open4' -and $mq -match 'MAP   api!4 -> open4\r?\n' -and $mq -match 'api!9 -> no task' -and $nq -match 'SKIP  nil1  the tracker returned nothing')"
'@
Expect-Each (Invoke-PsTest 'intest-gone' $it @($O)) 'deploy intest -Apply: a task deleted in the tracker is skipped, reported and dropped; the rest go on; candidates = tracked tasks promoted in -Days, -Task any (SKIP line), -Mrs their tracked tasks (#)' @('gone', 'scope', 'task', 'mrs')
$pt = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Within($n) { $true }; function Invoke-Bounded { $script:calls++; $script:planOut }
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'; Remove-Item $pc -ErrorAction SilentlyContinue
$now = Get-Date; $script:planOut = @(); $r = @(Get-KitSuperviseFlagsDeploys)
"none:$(-not (Test-Path $pc) -and -not $r.Count)"
$script:planOut = @('[{"target":"stage","status":"READY","mrs":[{"mr":"api!1"}]}]'); $r = @(Get-KitSuperviseFlagsDeploys)
"good:$(($r.info -join ';') -match '^deploy ready: stage \(1 MR\(s\)\) \(waits for a person.s deploy <env>\)$')"
$now = (Get-Date).AddMinutes(90); $script:calls = 0; $script:planOut = @(); $r = @(Get-KitSuperviseFlagsDeploys)
"stale:$($script:calls -eq 1 -and ($r.info -join ';') -match 'deploy ready: stage .*plan 9\d min old, refresh pending' -and [int]($now - [datetime](Get-Content $pc -Raw | ConvertFrom-Json).asked).TotalMinutes -eq 90)"   # no output: the last ask's run still goes
$script:planOut = @('WATCH background x failed: boom'); $r = @(Get-KitSuperviseFlagsDeploys)
"watch:$(@($r | Where-Object level -eq 'WATCH').what -match 'deploy plan: background x failed: boom' -and ($r.info -join ';') -match 'stage')"
$now = $now.AddMinutes(5); $script:planOut = @('[]'); $r = @(Get-KitSuperviseFlagsDeploys)   # a background plan: as old as the ask that started it (5 min ago)
"empty:$(-not @($r | Where-Object info).Count -and [int]($now - [datetime](Get-Content $pc -Raw | ConvertFrom-Json).at).TotalMinutes -eq 5)"
Update-KitTracking { param($t) $t.tasks.d1 = @{ task = 'd1'; mrs = @('api!1'); done = $true; doneAt = $now.ToString('o') } }
$script:planOut = @('WATCH background d failed: boom'); $r = @(Get-KitSuperviseFlagsDeploys -AutoFix)   # a deployed check with no JSON: flagged, not stamped (asked again)
"live:$(@($r.what -match '^deployed check d1: background d failed').Count -and -not (Read-KitTracking).tasks.d1.liveCheckedAt)"
Set-KitTaskFields d1 @{ inTestDue = $now.ToString('o') }; Update-KitTracking { param($t) $t.tasks.d2 = @{ task = 'd2'; inTestDue = $now.ToString('o') } }
function Invoke-Bounded { param($s, $a) if ($a[1] -eq 'intest') { $script:it = $a; @('MARKED  d2  in test (api!2 on stage) | n', 'ERROR d1  could not set status: x', 'mark-in-test: 2 task(s) checked (the tasks named (-Task / -Mrs)): 1 moved to in test, 1 blocked (d1: x)') } }
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix); $tk = (Read-KitTracking).tasks
"intest:$(($script:it -join ' ') -eq 'deploy intest -Apply -Task d1,d2' -and @($r | Where-Object { "$($_.what)" -match '^auto-fixed: MARKED  d2 ' }).Count -eq 1 -and -not @($r | Where-Object { "$($_.what)" -match 'd1' }).Count -and $tk.d1.inTestDue -and -not $tk.d2.inTestDue)"
$gs = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())   # trigger ask, the rest real
@{ at = $now.AddMinutes(-90).ToString('o'); ready = @('stage (1 MR(s))'); ask = @('stage: 1 MR(s) (api!1)') } | ConvertTo-Json | Set-Content $pc
$script:planOut = @(); $r = @(Get-KitSuperviseFlagsDeploys)
$a1 = @($r | Where-Object level -eq 'ACT').what -match '^DEPLOY ASK stage: .*window open .plan 9\d min old, refresh pending'
@{ at = $now.AddMinutes(-90).ToString('o'); ready = @(); ask = $null } | ConvertTo-Json | Set-Content $pc; $r = @(Get-KitSuperviseFlagsDeploys)   # no batch: no empty ask
"ask:$([bool]$a1 -and -not @($r | Where-Object { "$($_.what)" -match '^DEPLOY ASK' }).Count)"
'@
Expect-Each (Invoke-PsTest 'plan-cache' $pt @($O)) 'supervise deploy plan: a timed-out, pending or failed plan is never cached; the last good plan stays, marked stale (ready and ASK lines), and is retried next round; a real empty plan is cached, dated by the ask that started it; a deployed check without JSON asks again; due inTest moves = one background run, each line credited to the task it names (#)' @('none', 'good', 'stale', 'watch', 'empty', 'live', 'intest', 'ask')
$ht = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Within($n) { $true }; function Invoke-Bounded { @() }
$gs = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'; $now = Get-Date
$cacheOf = { param([string[]]$m) @{ at = $now.ToString('o'); asked = $now.ToString('o'); ready = @("stage ($($m.Count) MR(s))"); ask = @("stage: $($m.Count) MR(s) ($($m -join ', '))"); mrsOf = @{ stage = $m } } | ConvertTo-Json -Depth 4 | Set-Content $pc }
$word = { param($id, $ans, $q = 'deploy stage', $min = 1) Write-KitLog decisions-log answered ([ordered]@{ id = $id; kind = 'decision'; item = 'stage,other'; gate = 'deploy'; question = $q; answer = $ans; by = 'owner'; answeredAt = $now.AddMinutes(-$min).ToString('o'); mrs = @() }) }
$acts = { param($r) @($r | Where-Object level -eq 'ACT' | ForEach-Object what) -join ';' }
& $cacheOf @('api!1'); & $word 'd-20260101000000-coordinator-aa11' 'dont deploy stage' 'deploy stage' 3
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"held:$(-not (& $acts $r) -and ($r.info -join ';') -eq 'deploy stage held by owner: aa11' -and (Get-Content $pc -Raw | ConvertFrom-Json).held.stage.id -eq 'd-20260101000000-coordinator-aa11')"
& $cacheOf @('api!1', 'api!2'); $held = (Get-Content $pc -Raw | ConvertFrom-Json); $held | Add-Member -Force NoteProperty held ([pscustomobject]@{ stage = @{ id = 'd-20260101000000-coordinator-aa11'; mrs = @('api!1') } }); $held | ConvertTo-Json -Depth 5 | Set-Content $pc
$r1 = @(Get-KitSuperviseFlagsDeploys -AutoFix); $r2 = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"fresh:$((& $acts $r1) -match '^DEPLOY ASK stage: 2 MR\(s\) .*new since hold aa11: api!2' -and -not (& $acts $r2) -and ($r2.info -join ';') -match 'held by owner: aa11')"
& $word 'd-20260101000100-coordinator-bb22' 'yes, deploy stage'; $r = @(Get-KitSuperviseFlagsDeploys)
"yes:$((& $acts $r) -match '^DEPLOY ASK stage' -and @($r.info -match '^deploy ready: stage').Count -eq 1)"
& $word 'd-20260101000200-opsy-stage-cc33' "wait: retry $($now.AddMinutes(30).ToString('HH:mm'))" 'host stayed busy' 0; $r = @(Get-KitSuperviseFlagsDeploys)
"wait:$(-not (& $acts $r) -and ($r.info -join ';') -eq "deploy stage waiting: host busy, retry $($now.AddMinutes(30).ToString('HH:mm')) (cc33)")"
$now = $now.AddMinutes(31); $r = @(Get-KitSuperviseFlagsDeploys)
"due:$((& $acts $r) -match '^DEPLOY RETRY stage: host busy, wait cc33 due since' -and (& $acts $r) -notmatch 'DEPLOY ASK')"
"kinds:$((@('dont deploy hm', 'No', 'hold it', 'wait: not urgent, never cut a live turn', 'Deploy tomorrow', 'yes: standing rule', 'deploy if needed', 'Sure, no problem', 'Please deploy now, no need to hold', 'test prod pipelines also') | ForEach-Object { Get-KitDeployWordKind $_ }) -join ',')"
'@
$hr = Invoke-PsTest 'deploy-holds' $ht @($O)
Expect-Each $hr 'supervise deploy holds: an env''s newest no = one muted "held by <by>: <id>" line, no ACT, until a later yes or an MR it did not cover (one fresh ask, then covered); a wait = "waiting: <why>, retry HH:mm", then DEPLOY RETRY (#)' @('held', 'fresh', 'yes', 'wait', 'due')
Expect "deploy word kinds: no / wait / yes from the answer ($(@($hr) -match '^kinds:'))" (@($hr) -contains 'kinds:no,no,no,wait,wait,yes,yes,yes,yes,unclear')
# a deploy MR (into deploys[].branch) feeds its own target only; from / paths pick an MR's targets in the intest gate too; old requests expire
& $J @{ repos = @(@{ name = 'jc'; deploys = @(@{ target = 'a-st'; branch = 'st/a'; job = 'da' }, @{ target = 'b-st'; branch = 'st/b'; job = 'db' }) }) } $cfgF
& $J @{ tasks = @{ g = @{ task = 'g'; mrs = @('jc!1', 'jc!2'); done = $true; doneAt = $now } }; automerge = @{} } $tf
$nd5 = { param($tb) @{ targetBranch = $tb; rows = @('a-st', 'b-st' | ForEach-Object { @{ target = $_; state = 'NOT-DEPLOYED'; detail = 'x' } }) } }
$fx5 = Join-Path (Kd) 'deploy-fixture5.json'; & $J @{ mrs = @{ 'jc!1' = (& $nd5 'st/b'); 'jc!2' = (& $nd5 'main'); 'jc!3' = (& $nd5 'main'); 'jc!4' = (& $nd5 'main') } } $fx5
$pdf = Join-Path (TkPath $k deploys -Create) 'pending.json'; & $J @{ requests = @(@{ at = (Get-Date).AddDays(-30).ToString('s'); run = 'old'; mrs = @('jc!3') }, @{ at = $now; run = 'new'; mrs = @('jc!4') }) } $pdf
$p = @(& $dep plan -Offline $fx5 -Json | ConvertFrom-Json); $by = { param($t) (@(@($p | Where-Object target -eq $t).mrs.mr) | Sort-Object) -join ',' }
Expect "deploy plan: a deploy MR counts for its own target only ($(& $by a-st) | $(& $by b-st))" ((& $by a-st) -eq 'jc!2,jc!4' -and (& $by b-st) -eq 'jc!1,jc!2,jc!4')
Expect 'deploy plan: a request older than -Days expires, a new one stays' ((@((Get-Content $pdf -Raw | ConvertFrom-Json).requests.run) -join ',') -eq 'new')
& $J @{ repos = @(@{ name = 'jc'; deploys = @(@{ target = 'a-st'; branch = 'st/a'; job = 'da'; paths = @('a/api/**', 'common/**') }, @{ target = 'b-st'; branch = 'st/b'; job = 'db'; paths = @('b/**', 'common/**') }) }); productTargets = @(@{ pathRegex = '^a/'; targetRegex = '^a-'; label = 'A env' }, @{ pathRegex = '^b/'; targetRegex = '^b-'; label = 'B env' }) } $cfgF
$fq2 = Join-Path (Kd) 'fake-deployed-gate.ps1'
Set-Content $fq2 @'
$m = $args[[array]::IndexOf($args, '-Mrs') + 1]; $live = @{ 'jc!1' = 'b-st'; 'jc!4' = 'b-st'; 'jc!5' = 'b-st' }[$m]
ConvertTo-Json -Compress @('a-st', 'b-st' | ForEach-Object { @{ mr = $m; target = $_; state = $(if ($_ -eq $live) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }); detail = "not on $_ yet" } })
'@ -Encoding utf8
$ug = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$KitCmd.qa = $args[1]
function Get-TrackerTask($id) { [pscustomobject]@{ id = $id; name = "n$id"; status = 'promoted' } }; function Test-TrackerStatus { $true }
function Set-TrackerStatus { }; function Add-TrackerComment { $global:kc += 'appended' }; function Set-TrackerKitComment($i, $kd) { $global:kc += "$i|$kd" }; $global:kc = @()
$tbs = @{ 1 = 'st/b'; 2 = 'st/b'; 3 = 'st/b'; 4 = 'main'; 5 = 'main' }; $fs = @{ 1 = 'a/x.java'; 4 = @('b/api/x.java', 'a/docs/r.md'); 5 = 'common/lib/x.java' }
function Invoke-HostApi([string]$Path) { $i = [int]($Path -replace '^.*merge_requests/(\d+).*$', '$1'); if ($Path -match '/changes(\?|$)') { [pscustomobject]@{ changes = @(@($fs[$i]) | ForEach-Object { [pscustomobject]@{ new_path = $_ } }) } } else { [pscustomobject]@{ target_branch = $tbs[$i] } } }
Write-KitLog deploy-log record ([ordered]@{ target = 'b-st'; mrs = @('jc!2'); by = 'opsy' }); Write-KitLog deploy-log record ([ordered]@{ target = 'a-st'; mrs = @('jc!3'); by = 'opsy' })   # the wrong target proves nothing
$o = @(foreach ($n in 1..5) { Invoke-MarkInTest -Task "t$n" -Quiet:$false | Where-Object { $_ -match '^(MARK|WAIT)' } | ForEach-Object { "$n=$_" } })
function Has($n, $rx) { [bool]@($o | Where-Object { $_ -match "^$n=$rx" }).Count }
"live:$(Has 1 'MARK .*jc!1 on b-st\b')"
"record:$(Has 2 'MARK .*jc!2 on b-st\b')"
"wait:$(Has 3 'WAIT .*jc!3 not live on: b-st \(NOT-DEPLOYED: not on b-st yet\)')"
"paths:$(Has 4 'MARK .*jc!4 on b-st\b')"
"shared:$(Has 5 'WAIT .*jc!5 not live on: a-st \(NOT-DEPLOYED: not on a-st yet\)')"
$null = Invoke-MarkInTest -Task t1 -Apply -Quiet; "keyed:$("$global:kc" -eq 't1|comment-intest')"
$fs = Format-KitInTestSummary 63 62 1 14 $false ([ordered]@{ 'moved to in test' = @('a'); 'already closed' = @('b', 'c'); 'not deployed yet' = @('d'); 'blocked' = @('e: no status') })
"summary:$($fs -eq 'mark-in-test: 63 task(s) checked (62 promoted by the kit in 14 d, subtasks included, 1 more assigned to you in trackerLists): 1 moved to in test, 2 already closed, 1 not deployed yet, 1 blocked (e: no status)')"
'@
& $J @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('jc!1') }; t2 = @{ task = 't2'; mrs = @('jc!2') }; t3 = @{ task = 't3'; mrs = @('jc!3') }; t4 = @{ task = 't4'; mrs = @('jc!4') }; t5 = @{ task = 't5'; mrs = @('jc!5') } }; automerge = @{} } $tf
$res = Invoke-PsTest 'intest-gate' $ug @($O, $fq2)
Expect-Each $res 'deploy intest: a deploy MR is live on its own target (green job or recorded deploy); from / paths set the targets an MR must be live on, productTargets aside; the in-test note is ONE comment edited in place; the summary counts each outcome and says where the tasks came from (#)' @('live', 'record', 'wait', 'paths', 'shared', 'keyed', 'summary') 20
Remove-TestKit $k
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the goodies merged into this one
Complete-Tests
