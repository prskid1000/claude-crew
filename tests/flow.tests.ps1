#Requires -Version 7
<#
flow.tests.ps1: dev-flow plumbing: bossy.ps1 track add / run (task ids, promotion), board join / leave, health's overdue beat;
devtools.py finish / prior gate; pokey.ps1 api, goody verbs and seats (from pokey.tests: its cap); buildy.js MR dedupe (moved
from bossy.tests: its cap).
Usage: pwsh -NoProfile -File <kit>/tests/flow.tests.ps1 (or tests/kit-tests.ps1 -Area flow).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit flow; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $tf = Join-Path $k '.state/tracking.json'
$env:KIT_TRACKER_TYPE = 'clickup'   # tag CU- (type only: no clickup call, no goody)
$out = pwsh @np $O track add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
Expect "track: placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $out -match 'needs a real -Task id')
& $J @{ tasks = @{ old1 = @{ task = 'old1'; mrs = @('api!9'); done = $true } } } $tf   # a tracking.json from before tasks/
$out = pwsh @np $O track add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
$trk = { & { . (Join-Path $k 'skills/crafty/lib.ps1'); (Read-KitTracking).tasks } }; $tasks = & $trk; $td = TkPath $k tasks
$tk = Read-Json "$td/abc123.json"; $am = Read-Json (Join-Path (Split-Path $td) 'automerge.json')
Expect 'state: tracking.json -> tasks/<id>.json (schemaVersion, holder, mrs in order) + automerge.json, deleted (no .migrated)' ($tk.schemaVersion -eq 1 -and $tk.holder.pid -and
  (@($tk.track.mrs) -join ',') -eq 'web!1,web!2' -and (Read-Json "$td/old1.json").track.done -and $am.schemaVersion -eq 1 -and -not (Test-Path $tf) -and -not (Test-Path "$tf.migrated"))
Copy-Item (Join-Path $src 'skills/bossy/STATE.md') (Join-Path $k 'skills/bossy'); '{bad' | Set-Content "$td/bad1.json"
$rtd = TkPath $k runtimes -Create; & $J @{ held = @{}; waiting = @() } "$rtd/locks.json"; & $J @{ isUp = $true } "$rtd/vm.json"
$sl = & $py -X utf8 (Join-Path $k 'skills/bossy/kitbag.py') state lint 2>&1 | Out-String; $slc = $LASTEXITCODE; Remove-Item "$td/bad1.json", "$rtd/locks.json", "$rtd/vm.json"
Expect "state lint: a broken task file is BAD (exit 1), readers skip it; locks.json has its own row ($slc)" ($slc -eq 1 -and $sl -match 'BAD .*bad1\.json: unreadable' -and $tasks.ContainsKey('old1') -and $sl -notmatch 'locks\.json' -and $sl -match 'vm\.json: missing leases')
Expect 'track: tag stripped, merge order echoed' ($tasks.ContainsKey('abc123') -and $out -match 'merge-after: web!2>api!7')
$null = pwsh @np $O track add -Task zero1 2>&1; $zr = pwsh @np $O track run -Detail 2>&1 | Out-String
Expect 'track run: a task with 0 MRs is held, never promoted' (-not (& $trk).zero1.done -and $zr -match 'HOLD zero1: no MR')
$mr = pwsh @np $O track add -Task 'web!3' -Mrs 'web!3' 2>&1 | Out-String; $mc = $LASTEXITCODE
$ti = pwsh @np $O track add -Task 'help lane - AR-17 (CU-ab12cd) (web)' -Mrs 'web!4' 2>&1 | Out-String
& { . (Lib); Update-KitTracking { param($t) $t.tasks['web!5'] = @{ task = 'web!5'; mrs = @('web!5'); onMerged = @('promoted'); done = $false }
  $t.tasks['fix x (CU-mv1) (web)'] = @{ task = 'fix x (CU-mv1) (web)'; mrs = @('web!6'); onMerged = @('promoted'); holdPromotion = 'h'; done = $false } } }
$dr = pwsh @np $O track run -Detail 2>&1 | Out-String; $tasks = & $trk
Expect "track: an MR ref as -Task refused, a title -> its tagged id; run drops an MR-ref task, moves a title one with its hold ($mc)" ($mc -ne 0 -and $mr -match 'needs a real -Task id' -and
  $ti -match 'tracking ab12cd : web!4' -and $dr -match 'ATTENTION web!5: no tracker id, dropped: register its MRs: bossy\.ps1 track add -Task <id> -Mrs web!5' -and -not $tasks.ContainsKey('web!5') -and
  $dr -match 'MOVED fix x \(CU-mv1\) \(web\): no tracker id; its MRs track under mv1' -and $tasks.mv1.holdPromotion -eq 'h' -and (@($tasks.mv1.mrs) -join ',') -eq 'web!6')
$tb = pwsh -NoProfile -Command ". '$O'; `$KitConf.TrackerTag = 'CU-'; `$KitConf.TrackerRepos = @('web'); `$KitConf.GitlabGroup = 'g'; function Invoke-HostApi(`$p) { if (`$p -match 'search=') { @{ iid = 5; state = 'merged' } } elseif (`$p -match 'merge_requests/5$') { @{ target_branch = 'rel/x' } } }; Get-TaskMrBranches 'abc', '' | ForEach-Object { `"`$(`$_.ref) `$(`$_.repo)@`$(`$_.branch)`" }"
Expect "bugbrief: the original task's MRs give repo@target" ($tb -eq 'web!5 web@rel/x')
Remove-Item Env:KIT_TRACKER_TYPE
# board: a quiet row of the same agent is STALE, not DUPLICATE; leave finds a lost token by -Agent
$bd = TkPath $k board -Create; $old = (Get-Date).AddMinutes(-10).ToString('o')
& $J @{ agent = 'ag'; session = 'ag-old'; run = 'r0'; status = 'working'; joined = $old; beat = $old; pid = 999999; pidStart = 'x'; worktrees = @() } "$bd/ag-old.json"
$bj = pwsh @np $O board join -Agent ag 2>&1 | Out-String
$null = pwsh @np $O board join -Agent solo -Run r9 2>&1; $bl = pwsh @np $O board leave -Agent solo -Run r9 2>&1 | Out-String; $blc = $LASTEXITCODE
Expect "board: a quiet same-agent row is STALE (no DUPLICATE); leave -Agent -Run without the token, exit 0 ($blc)" ($bj -match 'STALE: ag in session ag-old' -and $bj -cnotmatch 'DUPLICATE' -and $blc -eq 0 -and
  @(Get-ChildItem $bd -Filter *.json | ForEach-Object { Read-Json $_.FullName } | Where-Object { $_.agent -eq 'solo' -and $_.status -eq 'left' }).Count -eq 1)
# health: the beat supervise asked for passed while agents live
& $J @{ nextBeat = 15; report = @{ at = (Get-Date).AddMinutes(-40).ToString('o') } } (TkPath $k supervise-state -Create)
$hb = & { . (Lib); Get-KitBeatOverdue; Remove-Item (Join-Path (Get-KitPath board) '*.json'); "none:$(-not (Get-KitBeatOverdue))" }
Expect "health: an overdue heartbeat says by how much while agents live, nothing when none ($hb)" ("$hb" -match 'heartbeat OVERDUE 2[45] min: last beat \d\d:\d\d, next was due \d\d:\d\d' -and "$hb" -match 'none:True')
# devtools: finish promotes a tracked open task now; the prior gate passes a tracked sibling task, stops an unknown one
$fy = Join-Path (Kd) 'flow.py'; [IO.File]::WriteAllText($fy, @'
import sys; sys.path.insert(0, sys.argv[1]); import devtools as d
ran, tr = [], {'tasks': {'T1': {'done': False}, 'T2': {'mrs': ['web!1']}}}
for n, v in {'_pub_read': lambda k: {'url': 'https://d/x'}, 'prose_gate': lambda *a: None, 'local_pass': lambda t: (True, ''), 'case_gaps': lambda *a: [],
             'task': lambda t: {'id': t, 'name': 'n', 'status': 'review'}, '_doc_url': lambda t, k, doc: doc, 'links_block': lambda *a: 'x', '_tracker': lambda *a: '',
             'comment': lambda *a: None, 'refresh_mr_docs': lambda t: [], 'set_status': lambda *a: None, 'read_tracking': lambda *a: tr, '_run': lambda c, **k: ran.append(c) or 'DONE T1'}.items():
    setattr(d, n, v)
d.finish('T1', 'https://d/g', 'solution', ai='https://d/ai'); tr['tasks']['T1']['done'] = True; d.finish('T1', 'https://d/g', 'solution', ai='https://d/ai')
print('finish:', len(ran) == 1 and ran[0][-4:] == ['track', 'run', '-Task', 'T1'])
pr = lambda ref: {'prior': {'validUntil': '2999-01-01T00:00:00+00:00', 'found': [{'kind': 'task', 'ref': ref, 'title': 'sibling'}]}}
d.state_read = lambda p: pr('T2'); d.prior_gate('T1', 'web', 'x')
d.state_read = lambda p: pr('T9')
try: d.prior_gate('T1', 'web', 'x'); print('prior: False')
except SystemExit: print('prior: True')
'@)
$fo = & $py -X utf8 $fy (Join-Path $k 'skills/crafty') 2>&1 | Out-String
Expect "devtools: finish runs track run -Task for a tracked open task only; prior gate: a tracked task is no duplicate, an unknown one stops ($fo)" ($fo -match 'finish: True' -and $fo -match 'prior: True')
# pokey api: api GET /x binds the method; a second positional otherwise is an error, not a missing -Path
$Q = Join-Path $k 'skills/pokey/pokey.ps1'
$pa = Px $Q api GET '/x' -Target nosuch 2>&1 | Out-String; $pb = Px $Q api '/x' '/y' -Target nosuch 2>&1 | Out-String
Expect "pokey api: <METHOD> <path> positional (reaches the targets file), a second path refused" ($pa -notmatch 'positional parameter|missing -Path' -and $pa -match 'targets\.local\.json' -and $pb -match "a second positional '/y'")
# pokey seat claims and seats: live holders keep theirs, dead or unknown ones are taken over (moved from pokey.tests: its cap)
$sd = TkPath $k qa-seats; $crd = Join-Path (Kd) 'runs/CL'; New-Item -ItemType Directory -Force (Join-Path $sd 'claims'), $crd, (Join-Path $sd 'seats') | Out-Null
$myStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); $ago7h = (Get-Date).AddHours(-7).ToString('s')
& $J @{ run = 'CL'; code = 'C1'; owner = 'w9'; since = $ago7h; holderPid = $PID; holderStart = $myStart } (Join-Path $sd 'claims/CL__C1.json')
& $J @{ run = 'CL'; code = 'C2'; owner = 'w9'; since = $ago7h } (Join-Path $sd 'claims/CL__C2.json')
& $J @{ run = 'CL'; code = 'C4'; owner = 'w9'; since = (Get-Date).ToString('s'); holderPid = 999999; seen = '2000-01-01' } (Join-Path $sd 'claims/CL__C4.json')
$sq = { param($c, [double]$gb = 0.1) pwsh @np $Q seat acquire -Agent "test:$c" -Kind api -RunDir $crd -Code $c -Owner w1 -KeepFreeGB $gb -WaitMinutes 0 | Out-String; "rc=$LASTEXITCODE"; $null = pwsh @np $Q seat release -Agent "test:$c" }
$o1, $o2, $o4, $o3 = ('C1', 'C2', 'C4' | ForEach-Object { "$(& $sq $_)" }) + "$(& $sq C3 100000)"
Expect 'seat: a live holder keeps its claim past 6 h; an unknown holder''s old claim is free; a dead holder''s is taken over; still waiting exits 4' ($o1 -match 'ALREADY' -and $o1 -match 'rc=3' -and $o2 -notmatch 'ALREADY' -and
  $o4 -notmatch 'ALREADY' -and (Read-Json (Join-Path $sd 'claims/CL__C4.json')).owner -eq 'w1' -and $o3 -match 'rc=4')
$sw = { param($n, $o) & $J ($o + @{ agent = $n; lease = $n; need = 0; since = (Get-Date).AddHours(-4).ToString('s') }) (Join-Path $sd "seats/$n.json") }
& $sw L1 @{ holderPid = $PID; holderStart = $myStart }; & $sw L2 @{ holderPid = 999999; seen = '2000-01-01' }; & $sw L3 @{ holderPid = 999999 }
$null = pwsh @np $Q seat status
Expect 'seat: a live holder''s 4 h seat stays; a dead one''s goes after the grace' ((Test-Path (Join-Path $sd 'seats/L1.json')) -and -not (Test-Path (Join-Path $sd 'seats/L2.json')) -and (Get-Content (Join-Path $sd 'seats/L3.json') | ConvertFrom-Json).seen); Remove-Item (Join-Path $sd 'seats/L*')
# wt commit: a refusal reaches stderr (a chained call shows it)
$cr = Join-Path (Kd) 'cr'; New-Item -ItemType Directory -Force $cr | Out-Null; git -C $cr init -q; git -C $cr commit -q --allow-empty -m init; 'z' | Set-Content "$cr/z.txt"
Copy-Item (Join-Path $src 'skills/crafty/templates.md') (Join-Path $k 'skills/crafty')
$ce = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $cr -Message ('feat: ' + 'long subject ' * 8) 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Out-String
Expect 'wt commit: an over-long subject is refused on stderr with its findings' ($ce -match '(?s)commit refused: \d+ prose finding\(s\).*line 1 is \d+ chars')
# buildy: one MR listed twice ships once, merged only when every copy says so
$uq = node -e "const s = require('fs').readFileSync(process.argv[1], 'utf8'); eval(s.match(/^const nu = .*$/m)[0] + '\n' + s.match(/^const uniqMr = .*$/m)[0] + '\nglobalThis.u = uniqMr');
const r = u([{ url: 'https://h/g/a/-/merge_requests/1', merged: true }, { url: 'https://h/g/a/-/merge_requests/1/', merged: false }, { url: 'https://h/g/a/-/merge_requests/2', merged: true }]); console.log(r.length === 2 && !r[0].merged && r[1].merged)" (Join-Path $src 'workflows/buildy.js')
Expect "buildy: duplicate MRs collapse, MERGED only when every copy is ($uq)" ("$uq" -eq 'true')
# pokey api errors and goody verbs (moved from pokey.tests: its cap)
& $J @{ targets = @{ tq = @{ api = 'http://127.0.0.1:9'; auth = @{ type = 'none' } }; tw = @{ web = 'http://127.0.0.1:9'; auth = @{ type = 'none' } }; tx = @{ api = 'http://127.0.0.1:9'; auth = @{ type = 'key' }; users = @{ admin = 1 } } } } (Join-Path $k 'skills/pokey/targets.local.json') 5
$ao = Px $Q api -Target tq -Path '/x' -TimeoutSec 5 -Save "$(Kd)/q.json" 2>&1 | Out-String; $ac = $LASTEXITCODE; $bs = Px $Q api -Target tq -Path '/x' -Save "Q-T1_01`b_poll" 2>&1 | Out-String; $gx = Invoke-PsTest gx ". `$args[0]; function Invoke-ApiExtra { param(`$Path, `$Target, `$Save, `$OutDir) `"`$OutDir|`$Save`" }; Invoke-Api /x -Target tx -Save D:/z/q.json" @($Q)
$uo = Px $Q ui dump 2>&1 | Out-String; $uc = $LASTEXITCODE   # phone lanes are the goody android-swarm
$xo = foreach ($verbName in 'deployed', 'annotate') { $verbOut = Px $Q $verbName 2>&1 | Out-String; "$LASTEXITCODE $verbOut".Trim() }
$wo = Px $Q api -Target tw -Path '/x' 2>&1 | Out-String
Expect 'api: no answer exits 1 (status shown); ui, deployed, annotate without goodies exit 2 naming them; web-only target' ($ac -eq 1 -and $ao -match 'HTTP 0' -and $uc -eq 2 -and $uo -match 'goody add android-swarm' -and $xo[0] -match '(?s)^2 .*goody add deploys' -and $xo[1] -match '(?s)^2 .*goody add android-swarm' -and $wo -match 'no api URL')
Expect 'api -Save: a full path is split (api-auth goody too); a control character is named' ((Test-Path "$(Kd)/q.json") -and $bs -match "-Save 'Q-T1_01\?_poll' holds a control" -and "$gx" -eq 'D:\z|q')
$api = Start-TestApi; & $J @{ targets = @{ tb = @{ api = "http://127.0.0.1:$($api.port)"; auth = @{ type = 'login'; path = '/bad' }; users = @{ admin = 'u', 'K9' } } } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$lb = (Px $Q api -Target tb -Path '/l' 2>&1 | Out-String) -replace '\s+(\|\s+)?', ' '; $api.proc.Kill(); $lh = Px $Q api -Target tb -Path '/l' 2>&1 | Out-String
(Get-Item (Join-Path $k 'skills/pokey/targets.local.json')).LastWriteTime = Get-Date; $lr = Px $Q api -Target tb -Path '/l' 2>&1 | Out-String
Expect 'api: LOGIN-FAIL names target, tenant, user; held until targets.local.json changes' ($lb -match "LOGIN-FAIL target=tb tenant='' user=admin: login refused \(HTTP 401\): .*targets\.tb\.users\.admin" -and $lb -notmatch 'K9| char:' -and $lh -match 'not retried' -and $lr -notmatch 'not retried')
# gate words (deploy, merge, close ...): a recorded person's answer, never relayed text
$gcf = Join-Path (Kd) 'gate.contracts.md'; '# contracts' | Set-Content $gcf
$nw = Px $O decide check -Gate deploy -Item hx | Out-String; $c1 = $LASTEXITCODE
$null = Px $O decide record -Gate deploy -Item hx -Question q -Answer y -Source chat -By coordinator-2; $c2 = $LASTEXITCODE
$rec = Px $O decide record -Gate deploy -Item hx -Mrs 'api!8' -Question q -Answer 'Go (Recommended)' -Source askuser -Contracts $gcf | Out-String
$rid = if ($rec -match 'RECORDED (d-\S+)') { $Matches[1] }
$wm = Px $O decide check -Gate deploy -Mrs 'api!8' | Out-String; $null = Px $O decide check -Gate merge -Item hx; $c3 = $LASTEXITCODE
$wu = Px $O decide check -Gate deploy -Id $rid -Use -Agent op1 | Out-String; $wv = Px $O decide check -Gate deploy -Item hx | Out-String; $c4 = $LASTEXITCODE
$aid = (Px $O decide ask -Run w1 -Agent X1 -Item A2 -Question 'Close T1?' -Options 'A: close','B: keep' | Out-String) -replace '(?s).*DECISION (\S+) pending.*', '$1'
$null = Px $O decide answer -Id $aid -Answer 'A, close it'; $wl = Px $O decide check -Gate close -Id $aid -Item A2 | Out-String; $null = Px $O decide check -Gate deploy -Id $aid; $c6 = $LASTEXITCODE
$null = Px $O decide record -Gate deploy -Item hx -Question q -Answer y -Source chat -Agent opsy; $c7 = $LASTEXITCODE
Expect 'decide record/check: none, an agent -By / -Agent refused; found by MR, gate-bound, used once; an answered ask by -Id + its item only' ("$c1$c2$c3$c4$c6$c7" -eq '121112' -and $nw -match 'NO-WORD' -and $rid -and (Get-Content $gcf -Raw) -match "$rid RECORDED" -and
  $wm -match "WORD $rid .*Go \(Recommended\). by owner via askuser" -and $wu -match "WORD $rid" -and $wv -match 'used by op1' -and $wl -match "WORD $aid .*close it")
$sid = (Px $O decide record -Gate deploy -Item stg -Mrs 'api!9' -Question q -Answer y -Source chat | Out-String) -replace '(?s).*RECORDED (\S+) .*', '$1'
$null = Px $O decide check -Gate deploy -Item prd -Mrs 'api!9'; $c5 = $LASTEXITCODE
$sf = Get-ChildItem $k -Recurse -Filter "$sid.json" | Select-Object -First 1; $sj = Read-Json $sf.FullName; $sj.answeredAt = (Get-Date).AddHours(-13).ToString('o'); & $J $sj $sf.FullName
$so = Px $O decide check -Gate deploy -Item stg -Mrs 'api!9' | Out-String
Expect 'decide check: a staging yes never serves another env; a word older than -MaxHours (12) is none' ($c5 -eq 1 -and $so -match "NO-WORD.*$sid older than 12 h")
$D = Join-Path $k 'skills/crafty/crafty.ps1'
$lf = Join-Path (Kd) 'mrs.ps1'; Set-Content $lf "'[]'"; & $J @{ gitHost = 'git.example'; gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.list' = "pwsh -NoProfile -File `"$lf`"" } }; tracker = @{ type = 'none'; branchTag = 'TK-' } } "$k/skills/crafty/kit.local.json"
$gr = Join-Path (Kd) 'pr'; git init -q -b main $gr; git -C $gr commit -q --allow-empty -m i; git -C $gr remote add origin $gr; git -C $gr branch TK-7-old
$w = { param($b, $o) $wa = @('wt', 'new', '-Repo', $gr, '-Branch', $b, '-Target', 'main', '-Name', $b, '-Root', (Join-Path (Kd) 'pw')) + @(if ($o) { '-Override', $o }); pwsh @np $D @wa 2>&1 | Out-String; $LASTEXITCODE }
$w0 = & $w TK-7-new; Set-Content $lf "'[{""iid"":4,""state"":""opened"",""source_branch"":""TK-7-old""}]'"; $p7 = pwsh @np $D prior -Task 7 -Repo $gr | Out-String; $p7c = $LASTEXITCODE; Set-Content $lf "'[]'"
$w1 = & $w TK-7-new; $w2 = & $w TK-7-new 'retest round'; $w4 = & $w TK-7-old
$p8 = pwsh @np $D prior -Task 8 -Repo $gr | Out-String; $p8c = $LASTEXITCODE; $w3 = & $w TK-8-a; git -C $gr branch TK-8-sib; $p8s = pwsh @np $D prior -Task 8 -Repo $gr | Out-String; $p8r = $LASTEXITCODE
$gd = '{"tool_name":"Bash","tool_input":{"command":"git checkout -b TK-9-x"}}' | pwsh @np $D guard | Out-String; $fy = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') finish 9 a b 2>&1 | Out-String
Expect 'prior gate: wt new refused before prior / on a found branch (hints); -Override or found branch + MR pass; NONE, own, sibling pass; guard + devtools.py finish need prior' ($w0[-1] -eq 1 -and "$w0" -match 'run crafty.ps1 prior' -and $p7c -eq 1 -and $p7 -match 'FOUND branch .*TK-7-old' -and $w1[-1] -eq 1 -and "$w1" -match 'already exists: branch' -and ($w1n = "$w1" -replace '[\s|]+', ' ') -match 'reuse: crafty\.ps1 wt new .*-Branch TK-7-old' -and $w1n -match "7-new -Override '<why>'" -and $w2[-1] -eq 0 -and $w4[-1] -eq 0 -and $p8c -eq 0 -and $p8 -match '^NONE' -and $w3[-1] -eq 0 -and $p8r -eq 0 -and $p8s -match 'INFO branch .*8-sib' -and $gd -match '"deny"' -and $gd -match 'prior -Task 9' -and $fy -match 'prior -Task 9 first')
Set-Content $lf "'[{""iid"":5,""state"":""opened"",""title"":""api"",""source_branch"":""TK-10-api""}]'"; $null = pwsh @np $D prior -Task 10 -Repo $gr; $f10 = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') finish 10 a b 2>&1 | Out-String; $m10 = & $py -X utf8 -c "import sys; sys.path[:0] = [sys.argv[1]]; import devtools as d; d.prior_gate('10', sys.argv[2], 'mr')" "$k/skills/crafty" $gr 2>&1 | Out-String; $w10 = & $w TK-10-web; $g10 = '{"tool_name":"Bash","tool_input":{"command":"git checkout -b TK-10-dup"}}' | pwsh @np $D guard | Out-String; Set-Content $lf "'[]'"
Expect 'prior gate: a tagged MR of the task is its own (finish, mr in its repo: INFO, passes); wt new there and the guard (repo unknown) still stop' ($f10 -match 'INFO devtools.py finish 10: paired mr pr!5' -and $f10 -notmatch 'already exists' -and $m10 -match '^INFO mr: paired mr pr!5' -and $w10[-1] -eq 1 -and "$w10" -match 'already exists: mr pr!5' -and $g10 -match '"deny"' -and $g10 -match 'already exists')
$gc = { git -C $gr -c user.name=t -c user.email=t@t @args }; & $gc checkout -q -b TK-11-a; & $gc commit -q --allow-empty -m 'TK-11 wip'; & $gc checkout -q main; & $gc commit -q --allow-empty -m 'TK-11 fix'
Set-Content $lf "'[{""state"":""merged"",""target_branch"":""main"",""source_branch"":""TK-11-a""},{""iid"":7,""state"":""merged"",""target_branch"":""stg"",""source_branch"":""TK-11-b""}]'"; $p11 = pwsh @np $D prior -Task 11 -Repo $gr | Out-String; Set-Content $lf "'[]'"
Expect 'prior gate: merged into target = fix round' ($p11 -match 'FOUND mr pr pr!7' -and $p11 -notmatch 'pr!6|TK-11-a|commit')
Remove-TestKit $k
Complete-Tests
