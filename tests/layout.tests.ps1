#Requires -Version 7
<#
layout.tests.ps1: the kit's place on disk: stray runtime folders (lint RUNTIME-STRAY), runtime resolution, the git hooks, run records (resumed run liveness, re-bind); the
supervise page's Statistics tiles (the sweep's lines as tiles, no sweep log) and Usage (budget -Usage); testy's goody guards; tracked ports current.
Usage: pwsh -NoProfile -File <kit>/tests/layout.tests.ps1 (or tests/kit-tests.ps1 -Area layout).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit layout
# RUNTIME-STRAY: a runtime folder up to 3 levels into the workspace, not the kit's own or a kit checkout's
$rtName = (Get-Content (Join-Path $src 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json)._paths.runtimeDir
$strayWs = Split-Path $k
foreach ($sd in '.', 'repo', 'wt', 'a/b/c') { New-Item -ItemType Directory -Force (Join-Path $strayWs "$sd/$rtName") | Out-Null }
New-Item -ItemType File -Force (Join-Path $strayWs 'wt/skills/crafty/crafty.ps1') | Out-Null; New-Item -ItemType Directory -Force (Join-Path $k $rtName) | Out-Null
$strayFound = python -X utf8 -c "import sys, os; sys.path.insert(0, sys.argv[1]); import kitbag; print(sorted(os.path.relpath(p, sys.argv[2]).replace(os.sep, '/') for p in kitbag.stray_runtimes(sys.argv[3])))" (Join-Path $k 'skills/bossy') $strayWs $k
foreach ($sd in $rtName, 'repo', 'wt', 'a') { Remove-Item -Recurse -Force (Join-Path $strayWs $sd) }
Expect "lint RUNTIME-STRAY: <ws>/$rtName and <ws>/repo/$rtName only ($strayFound)" ($strayFound -eq "['$rtName', 'repo/$rtName']")
# a relative runtime override resolves from the kit, never the cwd
Set-Item Env:CLAUDE_RUNTIME 'rt-rel'
$relRuntimes = @((python -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.runtime_dir())" (Join-Path $k 'skills/bossy')), (pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; Get-KitRuntime"))
Remove-Item Env:CLAUDE_RUNTIME
Expect "a relative runtime override resolves from the kit, never the cwd ($($relRuntimes -join ' | '))" (@($relRuntimes | Where-Object { [IO.Path]::GetFullPath($_) -eq [IO.Path]::GetFullPath((Join-Path $k 'rt-rel')) }).Count -eq 2)
# sweep: merged / local-copy branches + a merged clean worktree go, unpushed / open / protected stay; a junction skeleton no repo lists goes (its target stays)
$swBossy = Join-Path $k 'skills/bossy/bossy.ps1'; $swCrafty = Join-Path $k 'skills/crafty/crafty.ps1'; $sw = Join-Path (Kd) 'sw'; $so = Join-Path (Kd) 'so.git'; $sr = Join-Path (Kd) 'srepo'
$env:GIT_COMMITTER_DATE = (Get-Date).AddDays(-2).ToString('o'); git init -q --bare -b main $so; git clone -q $so $sr 2>$null; 'a' | Set-Content "$sr/a.txt"; Save-GitRepo $sr init; git -C $sr push -q origin main 2>$null
foreach ($b in 'f/merged', 'staging/x', 'f/open', 'f/local') { git -C $sr branch $b }
foreach ($b in 'f/open', 'f/local') { git -C $sr switch -q $b; $b | Set-Content "$sr/b.txt"; Save-GitRepo $sr $b }; git -C $sr push -q -u origin f/open 2>$null; git -C $sr switch -q main; git -C $sr branch mr7 f/open
git -C $sr worktree add -q -b f/wt "$sw/wt-srepo" 2>$null; git -C $sr worktree add -q -b f/wt2 "$sw/wt2-srepo" 2>$null; Remove-Item Env:GIT_COMMITTER_DATE
# wt2: a live board row without claims whose agent checkpointed it since joining (a kitty after its push) holds it
$heldRow = Join-Path (TkPath $k board -Create) 'kt-held.json'; & $J @{ agent = 'kt'; session = 'kt-held'; run = 'kr'; worktrees = @(); status = 'working'; joined = (Get-Date).AddHours(-1).ToString('o'); beat = (Get-Date).ToString('o') } $heldRow
& $J @{ agent = 'kt'; run = 'kr'; steps = @(@{ step = '8'; dir = "$sw\wt2-srepo"; at = (Get-Date).ToString('o') }) } (& { . (Lib); Get-KitCheckpointFile kt kr -Write })
$tgt = Join-Path (Kd) 'shared'; New-Item -ItemType Directory -Force "$tgt", "$sw/skel-srepo/sub", "$sw/note-srepo" | Out-Null; 'keep' | Set-Content "$tgt/f.txt"; 'mine' | Set-Content "$sw/note-srepo/n.txt"
$null = New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path "$sw/skel-srepo/sub/node_modules" -Value $tgt
foreach ($f in Get-ChildItem $sw -Recurse -Force -Attributes !ReparsePoint) { $f.LastWriteTime = (Get-Date).AddDays(-1) }
$swOut = pwsh @np $swBossy cleanup -WorktreesOnly -WorktreeRoot $sw -Detail 2>&1 | Out-String; $swBr = @(git -C $sr for-each-ref --format='%(refname:short)' refs/heads) -join ','
$swRm = @(1, 2 | ForEach-Object { "$(pwsh @np $swCrafty wt remove -Dir "$sw/wt-srepo" -Root $sw 2>&1) rc=$LASTEXITCODE" }); Remove-Item -LiteralPath $heldRow
Expect "sweep: f/merged, mr7, worktree wt-srepo + f/wt gone; main / staging/x / f/open / f/local kept; wt2 a board agent checkpointed kept; skeleton gone, link target kept; note-srepo kept; repo-sweep counts; wt remove after: already gone, exit 0 ($swBr | $($swRm -join ' | '))" ($swBr -eq 'f/local,f/open,f/wt2,main,staging/x' -and -not (Test-Path "$sw/skel-srepo") -and (Test-Path "$tgt/f.txt") -and (Test-Path "$sw/note-srepo/n.txt") -and
  (Test-Path "$sw/wt2-srepo") -and $swOut -match 'wt2-srepo: held by a board agent' -and
  $swOut -match 'f/local in srepo: 1 commit\(s\) on no remote' -and $swOut -match 'open: origin/f/open not merged' -and (Get-Content -LiteralPath (TkPath $k repo-sweep) -Raw | ConvertFrom-Json).repos[0].branches -eq 5 -and
  $swOut -match 'worktree: merged' -and @($swRm -match 'already gone.*rc=0$').Count -eq 2)
# post-rewrite runs post-merge after a rebase (pull --rebase), not after an amend
$hookRepo = Join-Path (Kd) 'hookrepo'; $hookDir = Join-Path (Kd) 'hookdir'; New-Item -ItemType Directory -Force $hookDir | Out-Null
Copy-Item (Join-Path $src '.githooks/post-rewrite') $hookDir; [IO.File]::WriteAllText((Join-Path $hookDir 'post-merge'), "#!/bin/sh`necho ran >> `"`$(git rev-parse --git-dir)/pm`"`n")
git init -q -b main $hookRepo; git -C $hookRepo config core.hooksPath $hookDir; git -C $hookRepo commit -q --allow-empty -m a; git -C $hookRepo checkout -q -b side; git -C $hookRepo commit -q --allow-empty -m b
git -C $hookRepo commit -q --amend --allow-empty -m b2; $afterAmend = Test-Path "$hookRepo/.git/pm"
git -C $hookRepo checkout -q main; git -C $hookRepo commit -q --allow-empty -m c; git -C $hookRepo checkout -q side; git -C $hookRepo rebase -q main 2>$null
Expect "post-rewrite: a rebase runs post-merge, an amend does not (amend $afterAmend, rebase $(Test-Path "$hookRepo/.git/pm"))" (-not $afterAmend -and (Test-Path "$hookRepo/.git/pm"))
# supervise page: sweep lines -> Statistics tiles (value, change vs the previous sample, 7 days); a silent board entry = its STUCK flag, no count lines
$tilePage = (Invoke-PsTest tiles @'
. $args[0]
$sweepLines = @('workflow wf_a: 12 agents, 9 finished, 3 running', '  fix:W2T            idle 27 min', '  W1                 idle 1 min', 'memory: 61% used, 24.7 GB available', 'gate: 1 running (tsc), 2 queued, longest wait 4 min', 'qa seats: 1 taken of 12',
  'disk C: 649.08 GB free, +0 GB/h (normal 0.54), not filling', 'disk D: 479.08 GB free, +1.71 GB/h (normal 0.55), full in 30.2 h', 'disk E: 9 GB free, +0.5 GB/h (normal 0.5), full in 90 h', 'slowest: wave reports 14.2 s, x 1.0 s', 'sweep: 34 s')
$liveSamples = @([pscustomobject]@{ at = '2026-01-02T09:30:00'; run = 5; mem = 70; secs = 40; disks = [pscustomobject]@{ D = 480.5 } }, [pscustomobject]@{ at = '2026-01-02T10:00:00'; run = 3; mem = 61; secs = 34; disks = [pscustomobject]@{ D = 479.08 } })
Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; stats = [pscustomobject]@{ now = (Get-KitSuperviseNow $sweepLines 20); live = $liveSamples } })
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
$tileWant = @("st warn' data-fit><div class=k>Workflow steps now</div><div class=v>3<small> running</small><span class='tr eq'>▼ 2", '9 of 12 done &#183; wf_a &#183; 1 stale: fix:W2T 27 min', "<div class='dk warn'><div class=v><span class=dn0>D</span> 479.1<small> GB free</small><span class='tr bad'>▼ 1.4",
  'filling 1.7 GB/h (11 min) &#183; full in 30.2 h', 'steady (11 min)', "<div class='dk '><div class=v><span class=dn0>E</span>", '<small> · seats </small>1<small> / 12', 'Build gate &#183; QA seats</div><div class=v>1<small> running · </small>2', '7 days avg 65.5% &#183; peak 70%',
  "st lo' data-fit><div class=k>Sweep time</div><div class=v>34<small> s</small><span class='tr good'>▼ 6</span></div><div class=s title='wave reports 14.2 s'")
$tileMissing = @($tileWant | Where-Object { -not $tilePage.Contains($_) })
$staleBoard = Join-Path (TkPath $k board -Create) 'stale-s.json'; @{ session = 'stale-s'; agent = 'Y7'; run = 'r7'; status = 'working'; beat = (Get-Date).AddMinutes(-40).ToString('o'); joined = (Get-Date).AddMinutes(-50).ToString('o') } | ConvertTo-Json | Set-Content $staleBoard -Encoding utf8
$superviseOut = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') supervise -AutoFix -Json 2>$null | Out-String | ConvertFrom-Json
$livePage = Get-Content ([IO.Path]::ChangeExtension((TkPath $k supervise-report), '.html')) -Raw
Expect "supervise page: machine row (memory, disks in one tile: full-in under 72 h only, gate + QA seats in one) and folded kit tiles (workflow steps + stale, sweep time), no sweep log; a silent board entry = STUCK flag, no board / shells count lines (missing: $($tileMissing -join ' | '))" (
  -not $tileMissing.Count -and $tilePage -notmatch 'full in 90|Sweep log|<pre' -and @($superviseOut.flags.what -match '^STUCK Y7 .*\(r7\): no progress for 40 min').Count -eq 1 -and -not @($superviseOut.summary -match '^(board|shells): ').Count -and $livePage -match 'Memory</div>.+Kit activity</h3>.+Sweep time' -and $livePage -notmatch 'Sweep log')
# supervise page: short-item lists use the grid helper (.cg); a tile + ring per disk, a flagged one tinted and first
$gridPage = (Invoke-PsTest grids @'
. $args[0]
Format-KitSuperviseHtml ('{"at":"2026-01-02T10:00:00","flags":[{"level":"WATCH","what":"disk D: x"},{"level":"INFO","what":"i"}],"agents":[{"name":"a (workflow)","run":"r1","state":"ACTIVE","task":"t · steps 1/4 · 2k tokens of 10k"}],"resources":[{"name":"seat","by":"W1","gb":1.5}],"mem":{"TotalGB":8,"AvailGB":2},"stats":{"settings":{"heartbeatMinutes":15},"disks":[{"drive":"C","free":40,"total":900},{"drive":"D","free":300,"total":500,"series":[3,2]}]}}' | ConvertFrom-Json)
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
$gridWant = @('flags', 'info', 'res', 'stats', 'kv' | Where-Object { $gridPage -notmatch "class='cg $_' style='--cmin:\d+px" })
$gridOld = @('<section class=kpis>', '<div class=gauges>', '<div class=stats>', 'class=toks>', '<span class=tn>', '<th>Resource</th>', '<th>Key</th><th>Value</th>', 'grid-template-columns:minmax(0,240px)' | Where-Object { $gridPage.Contains($_) })
Expect "supervise page: list sections use the grid helper (missing: $gridWant), no old list pattern (found: $gridOld); no usage cache: its one line; memory from the board sample, disks in one tile, a flagged one tinted and first, no gauges" ($gridPage -match "(?s)Memory</div><div class=v>75<small>% used.+<div class='st warn' data-fit><div class=k>Disks</div><div class='dk warn'><div class=v><span class=dn0>D</span>.+dn0>C<" -and $gridPage -notmatch 'class=gauge' -and
  -not $gridWant.Count -and -not $gridOld.Count -and $gridPage -match 'No usage yet: bossy\.ps1 budget -Usage' -and $gridPage -match '\.cg\{display:grid;[^}]*repeat\(auto-fill,minmax\(min\(100%')
# each headline number renders once: 7-day tokens + cost (chart title), step outcomes (one bar), agents spawned (one tile; the Today list counted board rows)
$once = Invoke-PsTest once @'
$null = . $args[0] 6>$null; $t0 = [datetime]'2026-01-02T10:00:00'
$u = [pscustomobject]@{ days = @(6..0 | ForEach-Object { [pscustomobject]@{ day = $t0.AddDays(-$_).ToString('yyyy-MM-dd'); tok = 971428571; cost = 249.57 } }); byRole = @([pscustomobject]@{ k = 'devy'; n = 3; sum = 5e9; cost = 900 })
  rates = [pscustomobject]@{ n = 919; empty = 129; fail = 122; stopped = 119 }; merged = [pscustomobject]@{ source = 'workflows' } }
$sd = @([pscustomobject]@{ day = '2026-01-02'; spawned = 46 }, [pscustomobject]@{ day = '2026-01-01'; spawned = 5 })
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $t0.ToString('o'); agents = @([pscustomobject]@{ name = 'a'; state = 'ACTIVE'; since = $t0.ToString('o') }); stats = [pscustomobject]@{ usage = $u; days = $sd } })
$txt = $h -replace '(?s)<(style|script)>.*?</\1>' -replace '<[^>]+>', ' '
"$(@('6.8B', '$1,747', '549', '129', '122', '119', '46') | ForEach-Object { ([regex]::Matches($txt, "(?<![\d.])$([regex]::Escape($_))(?![\d.])")).Count }) $($h -match 'sec-timeline')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))
Expect "supervise page: 7-day tokens and cost, each step outcome and agents spawned render once, no Today list ($once)" ("$once".Trim() -eq '1 1 1 1 1 1 1 False')
# kitbag.py ui-check (headless, light + dark): cases below
if (Use-BrowserKit) {
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'; $uiBad = Join-Path (Kd) 'clip.html'
  [IO.File]::WriteAllText($uiBad, '<!doctype html><body><div style="width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">browser app-staging·tenant1·admin</div><div style="width:90px;white-space:nowrap">test:W2P, test:W2U, test:W2R</div><table style="width:60px;table-layout:fixed"><tr><td style="width:20px;overflow-wrap:anywhere">abcdefghijklmnop</td><td>x</td></tr></table><p style="width:90px;height:16px;overflow:hidden">one two three four five six</p><p style="width:90px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:1">clamped to one line of text</p><div style="display:grid;grid-template-columns:1fr 1fr"><div data-fit>a<br>b<br>c<br>d</div><div data-fit>stretched</div></div></body>')
  $uiBadOut = @(& $py -X utf8 $uiKb ui-check $uiBad --widths 390 2>&1); $uiBadCode = $LASTEXITCODE
  Expect "ui-check: ellipsis, overflow, hidden height, line-clamp, a squeezed cell and a stretched data-fit card (24+ px blank) fail in both themes (exit $uiBadCode)" ($uiBadCode -eq 1 -and @($uiBadOut -match 'CLIP fit: blank \d+ px below the content \(stretched\)').Count -eq 2 -and @($uiBadOut -match 'CLIP div: text-overflow: ellipsis').Count -eq 2 -and @($uiBadOut -match 'CLIP div: scrollWidth').Count -eq 2 -and @($uiBadOut -match 'CLIP td: squeezed').Count -eq 2 -and @($uiBadOut -match 'CLIP p: scrollHeight').Count -eq 2 -and @($uiBadOut -match 'CLIP p: line-clamp 1').Count -eq 2)
  $uiLay = Join-Path (Kd) 'boxes.html'   # a canvas page's window.uiBoxes: one box off-screen, one pair overlapping; a label on its own node passes
  [IO.File]::WriteAllText($uiLay, '<!doctype html><body><script>window.uiBoxes = () => ({view: [0, 0, 300, 300], boxes: [{id: "node a", key: "a", b: [10, 10, 20, 20]}, {id: "label a", own: "a", b: [5, 25, 40, 12]}, {id: "node b", key: "b", b: [60, 60, 20, 20]}, {id: "node c", key: "c", b: [70, 70, 20, 20]}, {id: "node far", key: "f", b: [290, 100, 20, 20]}]})</script></body>')
  $uiLayOut = @(& $py -X utf8 $uiKb ui-check $uiLay --widths 390 2>&1); $uiLayCode = $LASTEXITCODE
  Expect "ui-check: window.uiBoxes off-screen and overlapping boxes fail in both themes; a label on its own node does not (exit $uiLayCode)" ($uiLayCode -eq 1 -and @($uiLayOut -match 'CLIP layout: off-screen \(node far\)').Count -eq 2 -and @($uiLayOut -match 'CLIP layout: overlap \(node b x node c\)').Count -eq 2 -and @($uiLayOut -match 'CLIP layout').Count -eq 4)
  git init -q $k; git -C $k add skills/bossy; git -C $k commit -q -m base; Add-Content (Join-Path $k 'skills/bossy/adapters/supervise_resources.ps1') '# touched'
  $uiWarn = { & $py -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print([w for _, w, _ in kitbag.ui_check_warns(sys.argv[2])])" (Join-Path $k 'skills/bossy') $k }
  $uiWarnBefore = & $uiWarn
  $uiPage = Join-Path (Kd) 'dash.html'
  Invoke-PsTest uipage @'
. $args[0]
$holders = (1..10 | ForEach-Object { "test:W2$([char](64 + $_))-checky-lane-$_" }) -join ', '
$res = @(@{ name = 'browser app-staging·tenant1·admin'; by = $holders; gb = 2.4 }, @{ name = 'lock C:/work/.worktrees/f-TASK-1234-copy-orders-with-rerating-java/target'; by = 'devy-1; waiting: devy-2, devy-3'; gb = 0 })
$sh = @(@{ pid = 123456; owner = 'W2R-checky-2026-11-10-app-staging-intest-verify'; age = 42; state = 'STUCK'; dir = 'C:/work/.worktrees/f-TASK-1234-copy-orders/app/api'; cmd = 'pwsh -NoProfile -File C:/work/.claude/skills/crafty/crafty.ps1 check -Dir C:/work/.worktrees/f-TASK-1234-copy-orders/app/api'; next = 'kill' })
$ag = @(@{ name = 'wf_build_2026_11_10_super_long_workflow_identifier (workflow)'; run = '2026-11-10-app-staging-intest-and-a-long-run-name'; state = 'ACTIVE'; task = 'TASK-1234 Copy orders · steps 3/9 · 412k tokens of 967k'; since = '2026-01-02T09:10:00'; last = '2026-01-02T09:58:00'; doing = 'running crafty.ps1 check on C:/work/.worktrees/f-TASK-1234-copy-orders-with-rerating-java' }, @{ name = 'W2S (checky)'; run = 'r2'; state = 'ACTIVE'; since = '2026-01-02T10:00:00' })   # a bar at the timeline's end
$st = @{ settings = @{ 'supervise.paceRules' = '{"busy":5,"some":"long-value-without-spaces-0123456789abcdefghijklmnopqrstuvwxyz"}' }; params = @(@{ key = 'supervise.heartbeatMinutes.withAVeryLongKeyName'; ctx = 'android-swarm|lane-3'; value = '15'; source = 'approved · kit.local.json'; learned = '12'; changed = '2026-01-02T09:00:00'; why = 'owner pinned it' }) }
Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; flags = @(@{ level = 'ACT'; what = 'STUCK W2R-checky-2026-11-10-app-staging-intest-verify-very-long-agent-name: no progress for 41 min'; action = 'stop it' }); agents = $ag; resources = $res; shells = $sh; mem = @{ TotalGB = 31.7; AvailGB = 9.4 }; stats = $st } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) | Set-Content -LiteralPath $args[1] -Encoding utf8
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $uiPage) | Out-Null
  $uiOut = @(& $py -X utf8 $uiKb ui-check $uiPage 2>&1); $uiCode = $LASTEXITCODE; $uiShots = @(Get-ChildItem (Join-Path (TkPath $k shots) 'ui-check') -Filter 'dash-*.png' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*-open.png'); $uiOpen = @(Get-ChildItem (Join-Path (TkPath $k shots) 'ui-check') -Filter 'dash-*-open.png' -ErrorAction SilentlyContinue)
  Expect "ui-check: the dashboard (long names, 10 holders) has no clipped text at 1366 / 900 / 390, light + dark, 6 shots as loaded (height printed) + 6 all open; UI-CHECK nudge before the stamp only (exit $uiCode, $($uiShots.Count)+$($uiOpen.Count) shots, before $uiWarnBefore; $($uiOut | Where-Object { $_ -match 'CLIP' } | Select-Object -First 3))" (
    $uiCode -eq 0 -and $uiShots.Count -eq 6 -and $uiOpen.Count -eq 6 -and [int](@($uiOut -match '^1366 px light loaded: .* (\d+) px tall')[0] -replace '^.* (\d+) px tall.*$', '$1') -le 2700 -and @($uiOut -match '· \d+ px tall as loaded ·').Count -eq 6 -and "$uiWarnBefore" -eq "['skills/bossy/adapters/supervise_resources.ps1']" -and "$(& $uiWarn)" -eq '[]')
}
# run records on disk: a resumed run's liveness and its self record re-bound
$O = Join-Path $k 'skills/bossy/bossy.ps1'; $ld = TkPath $k launches -Create
$wfr = New-Item -ItemType Directory -Force (Join-Path (Kd) 'wf/wf_r2'); $txr = Join-Path $wfr 'agent-a1.jsonl'; '{}' | Set-Content $txr
$rb = Invoke-PsTest rebind @'
$null = . $args[0] 6>$null; $d = Get-Item $args[1]; $old = (Get-Date).AddHours(-3); $dead = @{ holderPid = 999999; holderStart = '2020-01-01T00:00:00Z' }
$me = [pscustomobject]@{ runId = 'wf_r2'; script = 'x/buildy.js'; at = (Get-Date).ToString('o'); holderPid = $PID; holderStart = (Get-KitPidStart $PID); file = 'r.json'; args = @{ brief = 'C:/b/w.md' } }
$sf = [pscustomobject](@{ script = 'x/buildy.js'; run = 'w-1'; at = $old.ToString('o'); wfDir = $d.FullName; file = (Join-Path $d.Parent 'self-w.json') } + $dead); $sf | ConvertTo-Json | Set-Content $sf.file
$rd = [pscustomobject](@{ runId = 'wf_r2'; script = 'x/buildy.js'; at = $old.ToString('o'); file = 'r.json'; args = @{ brief = 'C:/b/w.md' } } + $dead)
$a = @(Get-StoppedRunsOf @($me) @($sf) $old.AddHours(-1) $false).Count; $b = @(Get-StoppedRunsOf @($rd) @($sf) $old.AddHours(-1) $false).Count; $c = "$(Get-KitWorkflowStop $d @($sf, $me))"
(Get-Item $args[2]).LastWriteTime = $old; "$a $b $c|$(@(Get-StoppedRunsOf @($rd) @($sf) $old.AddHours(-1) $false).Count) $(Get-KitWorkflowStop $d @($sf, $rd))"
'@ @($O, "$wfr", $txr) | Out-String
[IO.File]::WriteAllText((Join-Path $ld 'self-buildy-w-1.json'), (@{ script = 'buildy.js'; run = 'w-1'; at = (Get-Date).ToString('o'); wfDir = "$wfr"; holderPid = 999999; crashed = 'x' } | ConvertTo-Json))
$rbo = pwsh @np $O launch -RunId wf_r2 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/w.md"}' 2>&1 | Out-String; $rbs = Read-Json (Join-Path $ld 'self-buildy-w-1.json')
Expect "resumed run: live record or fresh step transcript = not stopped, quiet + dead holders = session gone; launch -RunId re-binds its self record ($($rb.Trim()))" ($rb.Trim() -eq '0 0 |1 session gone' -and $rbo -match 're-bound self-buildy-w-1' -and -not $rbs.crashed -and $rbs.holderPid -ne 999999)
Remove-Item (Join-Path $ld 'self-buildy-w-1.json'), (Join-Path $ld 'wf_r2.json') -Force
$tx3 = New-Item -ItemType Directory -Force (Join-Path (Kd) 'tx3/s1/subagents/workflows/wf_r3'); "launch -Self -Script buildy.js -Run 'w-3' -ArgsFile a.json -Fnv abcd1234" | Set-Content (Join-Path $tx3 'agent-x.jsonl')
[IO.File]::WriteAllText((Join-Path $ld 'self-buildy-w-3.json'), (@{ script = 'buildy.js'; run = 'w-3'; at = (Get-Date).ToString('o'); fnv = 'abcd1234'; holderPid = 999999; crashed = 'x' } | ConvertTo-Json))
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx3'; $rb3 = pwsh @np $O launch -RunId wf_r3 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/w3.md"}' 2>&1 | Out-String; Remove-Item Env:KIT_TRANSCRIPTS
Expect 'launch -RunId: a self record without wfDir re-bound by its launch -Self line (args hash) in that run folder' ($rb3 -match 're-bound self-buildy-w-3' -and -not (Read-Json (Join-Path $ld 'self-buildy-w-3.json')).crashed)
Remove-Item (Join-Path $ld 'self-buildy-w-3.json'), (Join-Path $ld 'wf_r3.json') -Force
# usage: per message id (a repeated content block counts once), appended lines only, a partial last line waits; steps, rounds, outcomes, background agents, cost, page
$ux = Join-Path (Kd) 'ux'; $uw = New-Item -ItemType Directory -Force "$ux/s1/subagents/workflows/wf_u1"; $ub = "$ux/s1/subagents"
$um = { param($id, [int[]]$v, [string]$t, [string]$extra = '') "{`"type`":`"assistant`",`"timestamp`":`"$t`",`"message`":{`"model`":`"claude-sonnet-5-5`",`"id`":`"$id`",`"role`":`"assistant`",`"content`":[$extra],`"usage`":{`"input_tokens`":$($v[0]),`"cache_creation_input_tokens`":$($v[3]),`"cache_read_input_tokens`":$($v[2]),`"output_tokens`":$($v[1])}}}" }
$t0 = (Get-Date).Date.AddMinutes(1).ToUniversalTime(); $iso = { param($m) $t0.AddMinutes($m).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
[IO.File]::WriteAllText("$uw/agent-a1.jsonl", ((& $um 'msg_1' 10, 5, 1000, 100 (& $iso 0) '{"type":"tool_use"}'), (& $um 'msg_1' 10, 50, 1000, 100 (& $iso 1)), (& $um 'msg_2' 1, 20, 2000, 0 (& $iso 10)) -join "`n") + "`n")
[IO.File]::WriteAllText("$uw/agent-a2.jsonl", (& $um 'msg_9' 1, 1, 0, 0 (& $iso 12)) + "`n"); [IO.File]::WriteAllText("$ub/agent-b1.jsonl", (& $um 'msg_7' 0, 7, 0, 0 (& $iso 5)) + "`n")
'{"agentType":"devy","model":"sonnet"}' | Set-Content "$uw/agent-a1.meta.json"; '{"agentType":"revy"}' | Set-Content "$uw/agent-a2.meta.json"; '{"agentType":"revy","description":"review x"}' | Set-Content "$ub/agent-b1.meta.json"
(@{ type = 'started'; agentId = 'a1'; label = 'build:X1' }, @{ type = 'result'; agentId = 'a1'; result = @{ summary = 'ok'; mrs = @(@{ url = 'u/1'; merged = $true }) } }, @{ type = 'started'; agentId = 'a2'; label = 'review:X1' }, @{ type = 'result'; agentId = 'a2'; result = @{ error = 'boom' } } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) | Set-Content "$uw/journal.jsonl"
(Get-Item "$ux/s1").LastWriteTime = (Get-Date).AddDays(-10)   # a coordinator session started 10 days ago, its runs today (the page showed 0)
$uo = Invoke-PsTest usage @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $a = Get-KitUsage -Seconds 30
Add-Content -LiteralPath $args[2] -Value ((Get-Content -LiteralPath $args[3] -Raw).Trim() -replace 'msg_9', 'msg_8') -NoNewline; [IO.File]::AppendAllText($args[2], "`n{`"type`":`"assistant`",`"message`":{`"usage`"")
$b = Get-KitUsage -Seconds 30; $r = $b.runs[0]; $s1 = @($r.steps | Where-Object label -eq 'build:X1')[0]
"$($a.runs[0].tok)|$($r.tok)|$($s1.out)|$($s1.tools)|$($s1.min)|$($r.merged)|$($r.done)/$($r.total)|$($b.rates.fail)|$($b.bg[0].tok)|$($b.bg[0].roles)|$([math]::Round($s1.cost, 6))|$($r.loop)|$(@($b.days)[-1].tok)|$(@($b.byType).k -join ',')"
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ usage = $b } })
$cardGrid = @("class=ug><details class='sec sub st uc' id=sec-u-days open><summary><h4>Per day", "<div class=ucol><details class='sec sub st uc ", "Per model</h4>", "class='sec sub st uc ur' id=sec-u-roles open><summary><h4>Per role", 'repeat(auto-fit') | Where-Object { -not $h.Contains($_) }
# the right-align nth-child ranges assume these column counts: step type 7, top-5 5, role 7, model 6, run steps 9
$thCount = { param($open) ([regex]::Match($h, [regex]::Escape($open) + '.*?</tr>', 'Singleline').Value | Select-String '<th[ >]' -AllMatches).Matches.Count }
$colCounts = "$(& $thCount "class='uc ua'>") $(& $thCount '<div class=ut>') $(& $thCount "class='sec sub st uc ur'") $(& $thCount "class='sec sub st uc um'") $(& $thCount "class='ru f'>")"
"$($h -match 'Tokens today') $($h -match "class='ru f'") $($h -notmatch 'Agents outside workflows') $(-not $cardGrid -and $colCounts -eq '7 5 7 6 9')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $ux, "$uw/agent-a2.jsonl", "$uw/agent-a2.jsonl") | Out-String
$uv = @($uo.Trim() -split "`r?`n")
Expect "usage: an old session folder's new runs count; dedupe by message id, appended lines, partial line waits; run, step, outcomes, background, cost, page in auto-fit card grids ($($uv -join ' // '))" ($uv[-2] -eq '3183|3185|70|1|10|1|2/2|1|7|revy 1|0.001272|4|3192|build,agent,review' -and $uv[-1] -eq 'True True True True')
# usage numbers: 5.5 prices (alias, dated and [1m] ids, 1-hour writes), unknown model listed; ok=false / failed event = fail, empty = no field but ok,
# stopped its own rate; one calendar window (a 9-day-old message drops); runs a day by workflow id; coordinator sessions; host-merged MRs
$uy = Join-Path (Kd) 'uy'; $y1 = New-Item -ItemType Directory -Force "$uy/s1/subagents/workflows/wf_y1"; $y2 = New-Item -ItemType Directory -Force "$uy/s1/subagents/workflows/wf_y2"
$ym = { param($id, [string]$model, [int[]]$v, [int]$h1, [datetime]$at) "{`"type`":`"assistant`",`"timestamp`":`"$($at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))`",`"message`":{`"model`":`"$model`",`"id`":`"$id`",`"usage`":{`"input_tokens`":$($v[0]),`"cache_creation_input_tokens`":$($v[3]),`"cache_read_input_tokens`":$($v[2]),`"output_tokens`":$($v[1]),`"cache_creation`":{`"ephemeral_1h_input_tokens`":$h1,`"ephemeral_5m_input_tokens`":$($v[3] - $h1)}}}}" }
$yt = (Get-Date).Date.AddHours(1)
[IO.File]::WriteAllText("$y1/agent-b1.jsonl", ((& $ym 'msg_o' 'claude-sonnet-5-5[1m]' 5000, 0, 0, 0 0 $yt.AddDays(-9)), (& $ym 'msg_n' 'claude-sonnet-5-5[1m]' 100, 10, 1000, 200 0 $yt) -join "`n") + "`n")
[IO.File]::WriteAllText("$y1/agent-b2.jsonl", (& $ym 'msg_a' 'sonnet' 10, 0, 0, 0 0 $yt) + "`n"); [IO.File]::WriteAllText("$y1/agent-b3.jsonl", (& $ym 'msg_b' 'claude-haiku-5-5-20261101' 1000, 100, 0, 0 0 $yt) + "`n")
[IO.File]::WriteAllText("$y1/agent-b4.jsonl", (& $ym 'msg_c' 'gpt-x' 7, 0, 0, 0 0 $yt) + "`n"); [IO.File]::WriteAllText("$y2/agent-c1.jsonl", (& $ym 'msg_d' 'sonnet' 1, 0, 0, 0 0 $yt) + "`n")
[IO.File]::WriteAllText("$uy/main-1.jsonl", ((& $ym 'msg_m' 'claude-opus-5-5' 100, 10, 0, 1000 1000 $yt), (& $ym 'msg_s' 'claude-sonnet-5-5' 0, 0, 0, 0 0 $yt) -join "`n") + "`n")   # a /model switch: parts per model
(@{ type = 'started'; agentId = 'b1'; label = 'build:A' }, @{ type = 'result'; agentId = 'b1'; result = @{ ok = $false; summary = 'red' } }, @{ type = 'started'; agentId = 'b2'; label = 'review:A' }, @{ type = 'result'; agentId = 'b2'; result = @{ ok = $true; summary = '' } },
  @{ type = 'started'; agentId = 'b3'; label = 'check:A' }, @{ type = 'result'; agentId = 'b3'; result = @{ ok = $true; findings = @('f1') } }, @{ type = 'started'; agentId = 'b4'; label = 'fix:A' }, @{ type = 'failed'; agentId = 'b4' }, @{ type = 'finished' } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) | Set-Content "$y1/journal.jsonl"
(@{ type = 'started'; agentId = 'c1'; label = 'track:A' }, @{ type = 'finished' } | ForEach-Object { $_ | ConvertTo-Json -Compress }) | Set-Content "$y2/journal.jsonl"
foreach ($wy in 'wf_y1', 'wf_y2') { @{ runId = $wy; run = 'same-run'; script = 'buildy.js'; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $ld "$wy.json") }
$yo = Invoke-PsTest usage2 @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $KitConf.TrackerRepos = @('r1')
function Get-KitHostUser { 'me' }; function Get-HostProject { param($n, [switch]$Raw) $n }
function Invoke-HostVerb { param($v, $a) $mr = { param($i, $d, $who, $src) [pscustomobject]@{ iid = $i; merged_at = (Get-Date).AddDays($d).ToString('o'); author = @{ username = $who }; source_branch = $src; target_branch = 'main' } }
  & $mr 1 0 'me' 'f/x'; & $mr 2 -10 'me' 'f/y'; & $mr 3 0 'other' 'f/z'; & $mr 4 0 'me' 'main' }   # in window, too old, not mine, a deploy MR
$u = Get-KitUsage -Seconds 30; $s = @($u.runs.steps); $res = ($s | Sort-Object label | ForEach-Object { "$($_.label)=$($_.result)" }) -join ','
$b1 = @($s | Where-Object label -eq 'build:A')[0]; $cst = { param($l) [math]::Round([double](@($s | Where-Object label -eq $l)[0].cost), 6) }
"$res|$($b1.in)|$(& $cst 'build:A')|$(& $cst 'review:A')|$(& $cst 'check:A')|$(@($u.unpriced).model -join ',')|$($u.rates.n) $($u.rates.fail) $($u.rates.empty) $($u.rates.stopped)"
"$(@($u.days)[-1].runs)|$(@($u.runs).Count)|$($u.coord[0].tok) $([math]::Round((Get-KitUsageCost @(100, 10, 0, 1000, 1000) 'claude-opus-5-5'), 4))|$(@($u.days)[-1].tok)|$($u.merged.source) $($u.merged.n) $(@($u.days)[-1].merged)"
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ usage = $u } })
"$($h -match "data-k='Role'>coordinator<") $($h -match 'class=dch') $(([regex]::Matches($h, "class='st uc dn'|class=gauge|viewBox='0 0 42 42'")).Count) $($h -match 'not priced: gpt-x') $($h -match '1 MR\(s\) merged on the git host by me') $($h -match "'Elapsed'|>Elapsed<")"
$pm = @(Get-KitUsageParts (Update-KitUsageFile "$($args[1])/main-1.jsonl" $null ([ref][long]1GB)) @((Get-Date).ToString('yyyy-MM-dd')) | ForEach-Object model | Sort-Object) -join ','
function Invoke-HostVerb { throw 'host down' }; $hp = Get-KitUsageHostMrs (Get-Date).Date (Get-Date) @{ at = '2020-01-01T00:00:00'; since = 'x'; mrs = @(1) }
$cf = Get-KitPath usage-cache; $cj = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable; foreach ($kv in @($cj.files.GetEnumerator())) { if ($kv.Key -like '*agent-b3*') { $kv.Value.v = 2 } }; $cj | ConvertTo-Json -Depth 7 | Set-Content $cf
"$pm|$(@($hp.mrs).Count)|$(@((Get-KitUsage -Seconds 0).runs.steps | Where-Object label -eq 'check:A').Count)"
function Get-KitStorageSamples { param($Drive, $Tail) foreach ($x in @(0, 100), @(3600, 110), @(7200, 60)) { [pscustomobject]@{ t = $x[0]; free = $x[1] } } }   # a 50 GB drop in the last hour
$sr = Get-KitSuperviseSeries @('disk D: 60 GB free, +25 GB/h (normal 1), full in 2.4 h') $null; $h2 = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ disks = $sr.disks } })
"$($sr.disks[0].h1) $($h2.Contains('filling 25 GB/h (11 min) &#183; last hour 50 GB used'))"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $uy) | Out-String
$yv = @($yo.Trim() -split "`r?`n")
Expect "usage numbers: prices by id / alias / variant + 1 h writes, unpriced listed, outcomes, one window, runs by id, coordinator, host MRs, charts, disk filling + last hour ($($yv -join ' // '))" ($yv[-5] -eq 'build:A=fail,check:A=pass,fix:A=fail,review:A=empty,track:A=stopped|100|0.0009|2E-05|0.00015|gpt-x|5 2 1 1' -and $yv[-4] -eq '2|2|1110 0.0086|3538|host 1 1' -and $yv[-3] -eq 'True True 0 True True True' -and $yv[-2] -eq 'claude-opus-5-5,claude-sonnet-5-5|1|0' -and $yv[-1] -eq '-50 True')
Remove-Item (Join-Path $ld 'wf_y1.json'), (Join-Path $ld 'wf_y2.json') -Force
# status: one agent joined twice (with -Type, then with -Run) on one transcript = one row (active agents not inflated)
$jvTx = Join-Path (Kd) 'JV.jsonl'; '{}' | Set-Content $jvTx; $jvB = TkPath $k board -Create; $jvNow = (Get-Date).ToString('o')
foreach ($jvE in @{ session = 's-JVz'; agent = 'JV'; run = 'rr'; type = '' }, @{ session = 's-JV'; agent = 'JV'; run = ''; type = 'devy' }, @{ session = 's-KZ1'; agent = 'KZ'; run = 'r1'; status = 'left' }, @{ session = 's-KZ2'; agent = 'KZ'; run = 'r2' }) { $jvR = @{ type = 'devy'; status = 'working'; beat = $jvNow; joined = $jvNow; transcript = $jvTx }; foreach ($kv in $jvE.GetEnumerator()) { $jvR[$kv.Key] = $kv.Value }; & $J $jvR (Join-Path $jvB "$($jvE.session).json") }   # KZ: left, re-joined live
$jv = Invoke-PsTest 'dupjoin' '$null = . $args[0] 6>$null; @(Get-KitStatusRows | Where-Object { $_.name -match "^(JV|KZ) " } | ForEach-Object { "$($_.name)/$($_.run)" }) -join ","' @($O)
Expect "status: two board entries of one agent on one transcript = one row, the typed one, a live re-join over its left twin ($jv)" ((@("$jv".Trim() -split ',') | Sort-Object) -join ',' -eq 'JV (devy)/,KZ (devy)/r2')
# testy: envy / phoney calls guarded (goodies): a missing one prints the goody line; the prompt names goody sync
$js3b = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^(test|retest)/.test(o.label)) return _res(o.label.split(':')[1], [_ck('C1', 'PASS')])
})
const args = { runDir: 'C:/runs/R2', ..._kl, verify: false, localEnv: 'shop', lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556' }],
 items: [_item('P1', 'app')] }
run(args, agent, _n, _n, null).then(() => {
 const tp = (calls.find((c) => /^test:P1/.test(c.label)) || {}).prompt || '', rel = (calls.find((c) => c.label === 'release-Falcon') || {}).prompt || ''
 const guard = (s, x) => tp.includes(`if (Test-Path 'C:/kit/skills/${s}') { & 'C:/kit/skills/${s}' `) && tp.includes(`else { '${x} is a goody: run kitbag.py goody add ${x}' }`)
 console.log(`local-guard:${guard('envy/envy.ps1', 'local-env') && /goody sync \(or goody add local-env\)/.test(tp)}`)
 console.log(`phone-guard:${guard('phoney/phoney.ps1', 'android-swarm') && /goody sync \(or goody add android-swarm\)/.test(tp)}`)
 console.log(`release-guard:${/bossy\.ps1 release -Agent 'qa-w1-Falcon' -Reason 'agent finished'/.test(rel)}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-extras $js3b (Join-Path $src 'workflows/testy.js')) 'testy goodies: #' 'local-guard', 'phone-guard', 'release-guard' -Show 8
# tracked ports current (GEMINI.md went stale after a commit): kitbag.py port --check, workspace copies aside; 2 = no ports goody
$pck = python -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') port --check 2>&1 | Out-String; $pckc = $LASTEXITCODE; $pst = @([regex]::Matches($pck, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '\(workspace copy\)$' })
Expect "port: the tracked ports (.codex, .agents, GEMINI.md) match a fresh generation: run kitbag.py port before committing ($($pst -join ', '))" ($pckc -eq 2 -or -not $pst.Count)
Remove-TestKit $k
Complete-Tests
