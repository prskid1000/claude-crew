#Requires -Version 7
<#
flow.tests.ps1: dev-flow plumbing: bossy.ps1 track add / run (task ids, promotion), board join / leave, health's overdue beat;
devtools.py finish / prior gate; pokey.ps1 api arguments; buildy.js MR dedupe (moved from bossy.tests: its cap).
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
# wt commit: a refusal reaches stderr (a chained call shows it)
$cr = Join-Path (Kd) 'cr'; New-Item -ItemType Directory -Force $cr | Out-Null; git -C $cr init -q; git -C $cr commit -q --allow-empty -m init; 'z' | Set-Content "$cr/z.txt"
Copy-Item (Join-Path $src 'skills/crafty/templates.md') (Join-Path $k 'skills/crafty')
$ce = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $cr -Message ('feat: ' + 'long subject ' * 8) 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Out-String
Expect 'wt commit: an over-long subject is refused on stderr with its findings' ($ce -match '(?s)commit refused: \d+ prose finding\(s\).*line 1 is \d+ chars')
# buildy: one MR listed twice ships once, merged only when every copy says so
$uq = node -e "const s = require('fs').readFileSync(process.argv[1], 'utf8'); eval(s.match(/^const nu = .*$/m)[0] + '\n' + s.match(/^const uniqMr = .*$/m)[0] + '\nglobalThis.u = uniqMr');
const r = u([{ url: 'https://h/g/a/-/merge_requests/1', merged: true }, { url: 'https://h/g/a/-/merge_requests/1/', merged: false }, { url: 'https://h/g/a/-/merge_requests/2', merged: true }]); console.log(r.length === 2 && !r[0].merged && r[1].merged)" (Join-Path $src 'workflows/buildy.js')
Expect "buildy: duplicate MRs collapse, MERGED only when every copy is ($uq)" ("$uq" -eq 'true')
Remove-TestKit $k
Complete-Tests
