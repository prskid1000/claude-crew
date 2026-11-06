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
Expect 'deploy plan: -TimeoutSec 100 by default; supervise passes deploy.planTimeoutSec (600 s, params.registry.json); a record triggers a learn pass' ($dps -match '\[int\]\$TimeoutSec = 100\)' -and $dps -match "'-TimeoutSec', \[int\]\(Get-KitParam 'deploy\.planTimeoutSec'\)" -and $dps -match 'Add-KitParamTrigger deploy' -and (Get-Content (Join-Path $src 'skills/bossy/params.registry.json') -Raw | ConvertFrom-Json).params.'deploy.planTimeoutSec' -match 'default=600\b')
# one pokey.ps1 deployed per target, in parallel: a crashed or slow target is UNKNOWN (never NOTHING), the others stand
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'bad' }, @{ target = 'slow' }, @{ target = 'good' }, @{ target = 'part' }, @{ target = 'crash' }) }) } $cfgF
& $J @{ tasks = @{ u = @{ task = 'u'; mrs = @('api!1', 'api!2'); done = $false } }; automerge = @{} } $tf
$fq = Join-Path (Kd) 'fake-deployed.ps1'
Set-Content $fq @'
$t = $args[[array]::IndexOf($args, '-Target') + 1]; if ($t -eq 'good') { Set-Content $env:FAKE_TO $args[[array]::IndexOf($args, '-TimeoutSec') + 1] }
if ($t -eq 'slow') { Start-Sleep 30 }
if ($t -eq 'bad') { 'pokey.ps1: usage error'; exit 2 }
"{`"mr`":`"api!1`",`"target`":`"$t`",`"state`":`"NOT-DEPLOYED`",`"detail`":`"x`"}"
if ($t -eq 'part') { Start-Sleep 30 }; if ($t -eq 'crash') { exit 3 }   # api!1 checked, api!2 never
"{`"mr`":`"api!2`",`"target`":`"$t`",`"state`":`"DEPLOYED`",`"detail`":`"live`"}"
'@ -Encoding utf8
$ut = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$KitCmd.qa = $args[1]; $env:FAKE_TO = $args[2]; $sw = [Diagnostics.Stopwatch]::StartNew()
$p = @(Invoke-Deploy plan -Json -TimeoutSec 4 | ConvertFrom-Json); $s = @{}; foreach ($x in $p) { $s[$x.target] = $x }
"bad:$($s.bad.status -eq 'UNKNOWN' -and $s.bad.why -match 'exit 2 on bad')"
"slow:$($s.slow.status -eq 'UNKNOWN' -and $s.slow.why -match 'timed out after 4 s on slow')"
"good:$($s.good.status -eq 'READY' -and (@($s.good.mrs.mr) -join ',') -eq 'api!1')"
"part:$($s.part.status -eq 'READY' -and (@($s.part.mrs.mr) -join ',') -eq 'api!1' -and $s.part.why -match 'api!2: not checked: .*timed out after 4 s on part')"
"crash:$($s.crash.status -eq 'READY' -and $s.crash.why -match 'api!2: not checked: pokey\.ps1 deployed exit 3 on crash')"
"parallel:$($sw.Elapsed.TotalSeconds -lt 20)"
"childcap:$((Get-Content $env:FAKE_TO) -as [int] -in 0..3)"
$null = Invoke-Deploy plan -TimeoutSec 4   # text mode: each row on stderr as it comes
'@
$res = Invoke-PsTest 'deploy-unknown' $ut @($O, $fq, (Join-Path (Kd) 'child-timeout.txt'))
Expect-Each $res 'deploy plan: per target in parallel, a failed one UNKNOWN; a timeout keeps the rows already checked; each child gets the time left as -TimeoutSec (#)' @('bad', 'slow', 'good', 'part', 'crash', 'parallel', 'childcap')
$all = $res -join "`n"
Expect 'deploy plan: each MR row printed as its check ends, a slow env''s finished rows too' ($all -match '(?m)^\s+api!1 @ part: NOT-DEPLOYED x' -and $all -match '(?m)^\s+api!2 @ good: DEPLOYED live')
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
"gone:$($o -match 'GONE  gone1' -and $o -match 'missing: gone1' -and -not (Read-KitTracking).tasks.ContainsKey('gone1') -and (Read-KitTracking).tasks.ContainsKey('ok2'))"
"scope:$((@($script:viewed | Sort-Object) -join ',') -eq 'gone1,ok2,qa5' -and $o -match 'mark-in-test: 3 candidate')"
$script:viewed = @(); $null = Invoke-MarkInTest -Task old3; "task:$(($script:viewed -join ',') -eq 'old3')"
'@
Expect-Each (Invoke-PsTest 'intest-gone' $it @($O)) 'deploy intest -Apply: a task deleted in the tracker is skipped, reported and dropped; the rest go on; candidates = tracked tasks promoted in -Days, -Task any (#)' @('gone', 'scope', 'task')
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
$gs = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())   # trigger ask, the rest real
@{ at = $now.AddMinutes(-90).ToString('o'); ready = @('stage (1 MR(s))'); ask = @('stage: 1 MR(s) (api!1)') } | ConvertTo-Json | Set-Content $pc
$script:planOut = @(); $r = @(Get-KitSuperviseFlagsDeploys)
"ask:$(@($r | Where-Object level -eq 'ACT').what -match '^DEPLOY ASK stage: .*window open .plan 9\d min old, refresh pending')"
'@
Expect-Each (Invoke-PsTest 'plan-cache' $pt @($O)) 'supervise deploy plan: a timed-out, pending or failed plan is never cached; the last good plan stays, marked stale (ready and ASK lines), and is retried next round; a real empty plan is cached, dated by the ask that started it; a deployed check without JSON asks again (#)' @('none', 'good', 'stale', 'watch', 'empty', 'live', 'ask')
Remove-TestKit $k
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the goodies merged into this one
Complete-Tests
