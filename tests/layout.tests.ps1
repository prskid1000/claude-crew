#Requires -Version 7
<#
layout.tests.ps1: the kit's place on disk: stray runtime folders (lint RUNTIME-STRAY), runtime resolution, the git hooks, run records (resumed run liveness, re-bind); the
supervise page's Statistics tiles (the sweep's lines as tiles, no sweep log) and Usage (budget -Usage); testy's envy / phoney calls; tracked ports current.
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
$swKl = "$k/skills/crafty/kit.local.json"; $swKlNew = -not (Test-Path $swKl); if ($swKlNew) { & $J @{ protectedBranchesBase = @('main', 'staging/*') } $swKl }   # legacy-like base
$swOut = pwsh @np $swBossy cleanup -WorktreesOnly -WorktreeRoot $sw -Detail 2>&1 | Out-String; if ($swKlNew) { Remove-Item $swKl }; $swBr = @(git -C $sr for-each-ref --format='%(refname:short)' refs/heads) -join ','
$swRm = @(1, 2 | ForEach-Object { "$(pwsh @np $swCrafty wt remove -Dir "$sw/wt-srepo" -Root $sw 2>&1) rc=$LASTEXITCODE" }); Remove-Item -LiteralPath $heldRow
Expect "sweep: merged, mr7, wt-srepo + f/wt gone; main, staging/x, f/open, f/local, checkpointed wt2, link target, note kept; skeleton gone; counts; wt remove after: gone, exit 0 ($swBr | $($swRm -join ' | '))" ($swBr -eq 'f/local,f/open,f/wt2,main,staging/x' -and -not (Test-Path "$sw/skel-srepo") -and (Test-Path "$tgt/f.txt") -and (Test-Path "$sw/note-srepo/n.txt") -and
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
$sweepLines = @('workflow wf_a: 12 agents, 9 finished, 3 running', '  fix:W2T  idle 27 min', '  W1  idle 1 min', 'memory: 61% used, 24.7 GB available', 'gate: 1 running (tsc), 2 queued, longest wait 4 min', 'qa seats: 1 taken of 12',
  'disk C: 649.08 GB free, +0 GB/h', 'disk D: 479.08 GB free, +1.71 GB/h, full in 30.2 h', 'disk E: 9 GB free, +0.5 GB/h, full in 90 h', 'slowest: wave reports 14.2 s, x 1.0 s', 'sweep: 34 s')
$liveSamples = @([pscustomobject]@{ at = [datetime]'2026-01-02T09:30'; run = 5; mem = 70; secs = 40; br = 7; wt = 3; disks = @{ D = 480.5 } }, [pscustomobject]@{ at = '2026-01-02T10:00:00'; run = 3; mem = 61; secs = 34; br = 7; wt = 3; disks = @{ D = 479.08 } })
$repoRows = @(@{ repo = 'a'; branches = 3; worktrees = 2; kept = 1 }, @{ repo = 'b' }, @{ repo = 'c'; branches = 5 }); $sweepHist = @(@{ fixed = 0; flags = @(@{ level = 'WATCH' }) }, @{ fixed = 1; flags = @(@{ level = 'ACT' }) })
Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; history = $sweepHist; stats = [pscustomobject]@{ now = (Get-KitSuperviseNow $sweepLines 20); live = $liveSamples; repos = @{ at = '2026-01-02T08:30:00'; repos = $repoRows }; days = @(@{ day = '2026-01-01'; failed = 2 }) } })
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
$tileWant = @("<span class=gn title='seconds per sweep, the day&#39;s average; 7 d: average &#183; slowest step now: wave reports 14.2 s'>Sweep time (s)<small>now 34 s</small></span>", "title='2026-01-02 (today) &#183; Sweep time (s): 37'>37</i>", "id=sec-dl-days open>", ">Disk D<small>479.1 GB free &#183; filling 1.7 GB/h &#183; full in 30.2 h</small>",
  'steady (11 min) &#183; Writes GB: what it filled per hour', '>Disk E<small>9 GB free &#183; filling 0.5 GB/h</small>', '<b>1 / 12</b><span>QA seats</span>', '<b>1</b><span>Builds running</span>', '<b>2</b><span>Builds queued</span>', '<b>61<small>%</small></b><span>RAM used</span>',
  "<span class=gn translate=no>a</span><span class='gs hm dy mh' style='--n:5'", "<span class=gn translate=no>c</span><span class='gs hm dy mh' style='--n:5'",
  "title='2026-01-01 &#183; agents failed: 2'>2</i>")
$tileMissing = @($tileWant | Where-Object { -not $tilePage.Contains($_) })
$staleBoard = Join-Path (TkPath $k board -Create) 'stale-s.json'; @{ session = 'stale-s'; agent = 'Y7'; run = 'r7'; status = 'working'; beat = (Get-Date).AddMinutes(-40).ToString('o'); joined = (Get-Date).AddMinutes(-50).ToString('o') } | ConvertTo-Json | Set-Content $staleBoard -Encoding utf8
$superviseOut = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') supervise -AutoFix -Json 2>$null | Out-String | ConvertFrom-Json
$livePage = Get-Content ([IO.Path]::ChangeExtension((TkPath $k supervise-report), '.html')) -Raw
Expect "supervise page: machine row (full-in under 72 h), Activity as one day heatmap, no delta text, no sweep log; a silent board entry = STUCK, no board / shells lines (missing: $($tileMissing -join ' | '))" (
  -not $tileMissing.Count -and $tilePage -notmatch 'full in 90|Sweep log|<pre|rn>b<|class=.tr |Lessons|Workflow steps now|Sweep time</|Flags auto-FIXED' -and @($superviseOut.flags.what -match '^STUCK Y7 .*\(r7\): no progress for 40 min').Count -eq 1 -and -not @($superviseOut.summary -match '^(board|shells): ').Count -and $livePage -match '(?s)RAM used</span>.+Kit internals</h2>.+Trends</h3>.+>Sweep time \(s\)<' -and $livePage -notmatch 'Sweep log')
# supervise page: short-item lists use the grid helper (.cg); a tile + ring per disk, a flagged one tinted and first
$gridPage = (Invoke-PsTest grids @'
. $args[0]
Format-KitSuperviseHtml ('{"at":"2026-01-02T10:00:00","flags":[{"level":"WATCH","what":"disk D: x"},{"level":"INFO","what":"i"}],"agents":[{"name":"a (workflow)","run":"r1","state":"ACTIVE","task":"t · steps 1/4 · 2k tokens of 10k"}],"resources":[{"name":"seat","by":"W1","gb":1.5},{"name":"db","by":"","gb":2,"shared":true}],"mem":{"TotalGB":8,"AvailGB":2},"stats":{"settings":{"heartbeatMinutes":15},"live":[{"at":"2026-01-02T09:30:00","mem":60,"res":{"seat":{"gb":1,"by":"W2"}},"disks":{"D":290}},{"at":"2026-01-02T09:45:00","mem":80,"res":{"seat":{"gb":1.2,"by":""}},"disks":{"D":280}}],"disks":[{"drive":"C","free":40,"total":900},{"drive":"D","free":300,"total":500,"series":[3,2]}]}}' | ConvertFrom-Json)
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
$gridWant = @(@() | Where-Object { $gridPage -notmatch "class='cg $_' style='--cmin:\d+px" })
$gridOld = @('<section class=kpis>', '<div class=gauges>', '<div class=stats>', 'class=toks>', '<span class=tn>', '<table><thead><tr><th>Resource</th>','<th>Key</th><th>Value</th>', 'grid-template-columns:minmax(0,240px)' | Where-Object { $gridPage.Contains($_) })
Expect "supervise page: lists on .cg (missing: $gridWant), no old pattern ($gridOld); disk, icons, meters, sparklines, timeline, agents" ($gridPage -match "<div[^>]* class='gk[^']*\bwarn'><span class=gn title='disk D &#183; 300 GB free &#183; 40% used &#183; steady[^']*'>disk D<small>300 GB free &#183; 40% used &#183; steady</small>" -and $gridPage -match '>disk C<small>40 GB free &#183; 96% used' -and $gridPage -notmatch 'class=k>Disks' -and $gridPage -notmatch 'class=gauge' -and $gridPage -match "<span class=gn title='db &#183; shared &#183; always on: CPU not sampled: [^']*RAM now 2 GB &#183; 24 h peak 2 GB'>db<small>shared &#183; always on</small></span>" -and
  $gridPage -match "title='09:00 &#183; seat &#183; RAM 1.1 GB &#183; W2'><span class='t'></span><span class='u[^']*'>1.1</span></i><i class=nw style='--a:0%;--b:[\d.]+%' title='10:00 \(now\) &#183; seat &#183; RAM 1.5 GB &#183; W1'>" -and
  $gridPage -match "<b>75<small>%</small></b><span>RAM used</span>.+used <b>6</b> GB" -and $gridPage -match ">D free</small>" -and $gridPage -match "<span class='gc fr lo' title='[^']*'>280</span>" -and $gridPage -match "rtg aria-expanded=false>r1</button>" -and
  -not $gridWant.Count -and -not $gridOld.Count -and $gridPage -match 'No usage yet: bossy\.ps1 budget -Usage' -and $gridPage -match '\.cg\{display:flex;flex-wrap:wrap;[^}]*\}\.cg>\*\{flex:1 1 max\(min\(100%')
# sentence case (owner 2026-11-21): every label (heading, column head, row name, chip, tile caption, legend key, button) starts upper
# case; an id stays (crew, lane, repo, key, unit: a - . _ / | : @ # · or digit, camelCase; a translate=no row)
$lblId = '^(?:[^\s,;:()]*[-._/|:@#\\·\d][^\s,;:()]*|[a-z]+[A-Z]\w*|devy|revy|checky|kitty|briefy|rechy|datay|opsy|watchy|vidy|coordinator|workflow|buildy|testy|tidy|min|h|s|d|ms)(?:[\s,;:()]|$)'
$lblScan = { param([string]$pg) $tx = $pg -replace '(?s)<(script|style|code)\b.*?</\1>', ''
  @(@([regex]::Matches($tx, '<(?<tag>th|button|summary|h[1-4]|li|span|div|p)(?<at>\s[^>]*)?>\s*(?<t>[a-z][^<]*)') | Where-Object { $_.Groups['tag'].Value -notin 'span', 'div', 'p' -or ($_.Groups['at'].Value -match "class=(?:'[^']*\b(?:gn0?|chip|hk|tgn|kleg|bdg)\b|(?:gn0?|chip|hk|tgn|kleg|bdg)\b)" -and $_.Groups['at'].Value -notmatch 'translate=no') } | ForEach-Object { $_.Groups['t'].Value.Trim() }) +
    @([regex]::Matches($tx, '<i\b[^>]*></i>\s*(?<t>[a-z][^<]*)') | ForEach-Object { $_.Groups['t'].Value.Trim() }) | Where-Object { $_ -cnotmatch $lblId } | Select-Object -Unique) }
$lblBad = @(& $lblScan $tilePage) + @(& $lblScan $gridPage)
$lblCanary = (& $lblScan "<th>value</th><span class='chip x'>running</span><span class=gn translate=no>api</span><span class=gn>devy</span><i class=lgk></i>output") -join ','
Expect "labels: sentence case on the page, ids kept (lower-case labels: $($lblBad -join ' | '); canary $lblCanary)" ($lblCanary -eq 'value,running,output' -and -not $lblBad.Count -and $tilePage.Contains('>Sweep time (s)<small>now 34 s</small>') -and $gridPage -cmatch "<span class='chip s-act'>Running</span>|class=gn0>Ended today<")
# kitbag.py ui-check (headless, light + dark): cases below
if (Use-BrowserKit) {
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'; $uiBad = Join-Path (Kd) 'clip.html'
  [IO.File]::WriteAllText($uiBad, '<!doctype html><body><div style="width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">browser app-staging·tenant1·admin</div><div style="width:90px;white-space:nowrap">test:W2P, test:W2U, test:W2R</div><table style="width:60px;table-layout:fixed"><tr><td style="width:20px;overflow-wrap:anywhere">abcdefghijklmnop</td><td>x</td></tr></table><p style="width:90px;height:16px;overflow:hidden">one two three four five six</p><p style="width:90px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:1">clamped to one line of text</p><div style="display:grid;grid-template-columns:1fr 1fr"><div data-fit>a<br>b<br>c<br>d</div><div data-fit>stretched</div></div><section style="width:100px;overflow:hidden"><span style="display:inline-block;white-space:nowrap">a side panel line cut at the edge</span></section></body>')
  $uiBadOut = @(& $py -X utf8 $uiKb ui-check $uiBad --widths 390 2>&1); $uiBadCode = $LASTEXITCODE
  Expect "ui-check: ellipsis, overflow, hidden height, line-clamp, squeezed cell, text cut by a clipping box, stretched data-fit card fail, both themes (exit $uiBadCode)" ($uiBadCode -eq 1 -and -not @('fit: blank \d+ px below the content \(stretched\)', 'div: text-overflow: ellipsis', 'div: scrollWidth', 'td: squeezed', 'p: scrollHeight', 'p: line-clamp 1', 'clip: text cut \d+ px by section' | Where-Object { @($uiBadOut -match "CLIP $_").Count -ne 2 }).Count)
  $uiRow = Join-Path (Kd) 'rows.html'   # 3 cards in 4 columns: an empty column; 3 in 3, one shifted by a margin: full
  [IO.File]::WriteAllText($uiRow, '<style>div{display:grid;gap:8px}</style><div style="grid-template-columns:repeat(4,1fr)"><p data-fit>a<p data-fit>b<p data-fit>c</div><div style="grid-template-columns:repeat(3,1fr)"><p data-fit>a<details style="margin:8px"><summary>b</summary></details><p data-fit>c</div><div style="grid-template-columns:repeat(auto-fill,minmax(200px,1fr))"><article>lone</article></div><section style="columns:3 300px"><article>col</article></section>')
  $uiRowOut = @(& $py -X utf8 $uiKb ui-check $uiRow --widths 1366,900 2>&1)
  Expect "ui-check: a card row 24+ px short of its box, a lone grid card, empty CSS columns fail at 1280+ px only ($($uiRowOut -match 'rows'))" (@($uiRowOut -match 'CLIP rows: a card row ends').Count -eq 2 -and @($uiRowOut -match 'CLIP rows: a lone card ends').Count -eq 2 -and @($uiRowOut -match 'CLIP rows: CSS columns end').Count -eq 2 -and @($uiRowOut -match '^900 px .* 0 clipped').Count -eq 2)
  git init -q $k; git -C $k add skills/bossy; git -C $k commit -q -m base; $uiSr = Join-Path $k 'skills/bossy/adapters/supervise_resources.ps1'; Undo-TestKitLink $uiSr; Add-Content $uiSr '# touched'
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
  Expect "ui-check: dashboard unclipped at 4 widths x 2 themes, UI-CHECK nudge (exit $uiCode, $($uiShots.Count)+$($uiOpen.Count) shots, before $uiWarnBefore; $($uiOut | Where-Object { $_ -match 'CLIP' } | Select-Object -First 3))" (
    $uiCode -eq 0 -and $uiShots.Count -eq 8 -and $uiOpen.Count -eq 8 -and [int](@($uiOut -match '^1366 px light loaded: .* (\d+) px tall')[0] -replace '^.* (\d+) px tall.*$', '$1') -le 2700 -and @($uiOut -match '· \d+ px tall as loaded ·').Count -eq 8 -and "$uiWarnBefore" -eq "['skills/bossy/adapters/supervise_resources.ps1']" -and "$(& $uiWarn)" -eq '[]')
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
(Get-Item "$uw/journal.jsonl").LastWriteTime = $t0.ToLocalTime().AddMinutes(12); (Get-Item $uw).CreationTime = $t0.ToLocalTime(); (Get-Item $uw).LastWriteTime = $t0.ToLocalTime()   # a run folder's write time stays at its last new file: wall = to the last step's write (12 min, was 0)
$uo = Invoke-PsTest usage @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $a = Get-KitUsage -Seconds 30
Add-Content -LiteralPath $args[2] -Value ((Get-Content -LiteralPath $args[3] -Raw).Trim() -replace 'msg_9', 'msg_8') -NoNewline; [IO.File]::AppendAllText($args[2], "`n{`"type`":`"assistant`",`"message`":{`"usage`"")
$b = Get-KitUsage -Seconds 30; $r = $b.runs[0]; $s1 = @($r.steps | Where-Object label -eq 'build:X1')[0]
"$($a.runs[0].tok)|$($r.tok)|$($s1.out)|$($s1.tools)|$($s1.min)|$($r.merged)|$($r.done)/$($r.total)|$($b.rates.fail)|$($b.bg[0].tok)|$($b.bg[0].roles)|$([math]::Round($s1.cost, 6))|$($r.loop)|$(@($b.days)[-1].tok)|$(@($b.byType).k -join ',')|$($r.wall)"
$pgs = @{}; $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ usage = $b } }) $pgs
$cardGrid = @("<details class='sec sub st uc dlr' id=sec-dl-days open><summary><h4>Per day", "<span class=gn title='est. cost per day", "<div class=tls data-mk=trend-tiles>", "data-oc=fail aria-pressed=false", "class='sec sub st uc ur' id=sec-u-spend><summary><h4>Spend per role</h4>", '</span><span class=fsm>Top: ', "data-mk=spend-role>", '.ur{grid-column:1/-1}') | Where-Object { -not $h.Contains($_) }
# column counts: run steps 8 (right-align nth-child ranges)
$thCount = { param($open, $in = $h) ([regex]::Match($in, [regex]::Escape($open) + '.*?</tr>', 'Singleline').Value | Select-String '<th[ >]' -AllMatches).Matches.Count }
$colCounts = "7 $(& $thCount "class='sy rst'>" @($pgs.Values)[0])"
"$($h -notmatch 'Tokens today') $($h -match "data-g='rr-[^']+' data-oc=" -and $h -match "<button type=button class='tl ocb' data-oc=fail") $($h -notmatch 'Agents outside workflows') $(-not $cardGrid -and $colCounts -eq '7 8' -and @($pgs.Values)[0] -match 'class=kleg' -and $h -notmatch 'class=ut>|Per model|Per step type|sec-u-rolecost|class=spd')"
# a transcript last written before today moves to usage.cold.json, which a later call leaves unchanged; totals the same
$cfu = Get-KitPath usage-cache; $cfc = $cfu -replace '\.json$', '.cold.json'; [IO.File]::SetLastWriteTime(($args[2] -replace 'agent-a2', 'agent-a1'), (Get-Date).Date.AddHours(-2))
$null = Get-KitUsage -Seconds 30; $cold1 = [IO.File]::ReadAllText($cfc); $d = Get-KitUsage -Seconds 30
$cold2 = [IO.File]::ReadAllText($cfc); [IO.File]::SetLastWriteTime(($args[2] -replace 'agent-a2', 'agent-a1'), (Get-Date)); $e = Get-KitUsage -Seconds 30   # written again today: back to the hot file
"$($cold1 -match 'agent-a1' -and $cold1 -notmatch 'agent-a2' -and $cold1 -ceq $cold2 -and $d.runs[0].tok -eq $b.runs[0].tok -and [IO.File]::ReadAllText($cfc) -notmatch 'agent-a1' -and [IO.File]::ReadAllText($cfu) -match 'agent-a1' -and $e.runs[0].tok -eq $b.runs[0].tok)"
# board-only agents: tokens from their own transcript (usage agentSteps by path), "No usage record" only without one (R2: its row + agent
# line; standalone agents a row each); a finished
# agent's time = joined -> ended (90 min), never its state's since (0 min, owner screenshot 2026-11-21)
$bo = @([pscustomobject]@{ name = 'R1 (revy)'; run = 'solo'; state = 'ACTIVE'; since = (Get-Date).AddMinutes(-5).ToString('o'); tx = $args[4] }, [pscustomobject]@{ name = 'R2 (revy)'; run = 'solo'; state = 'ACTIVE'; since = (Get-Date).AddMinutes(-5).ToString('o'); tx = '' },
  [pscustomobject]@{ name = 'K1 (kitty)'; run = 'kit-x'; state = 'FINISHED'; started = (Get-Date).AddMinutes(-100).ToString('o'); since = (Get-Date).AddMinutes(-10).ToString('o'); ended = (Get-Date).AddMinutes(-10).ToString('o'); tx = '' })
$hb = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); agents = $bo; stats = [pscustomobject]@{ usage = $e } }); "bo:$(@($e.agentSteps | Where-Object { $_.tf -like '*agent-b1.jsonl' }).tok) $(([regex]::Matches($hb, '>No usage record<')).Count) $(($kx = @($hb -split "data-g='rr-" | Where-Object { $_.StartsWith('board-kit-x') })[0]) -match '<span class=gc>90 min</span>' -and $kx -match ' [1-9]\d* min active')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $ux, "$uw/agent-a2.jsonl", "$uw/agent-a2.jsonl", "$ub/agent-b1.jsonl") | Out-String
$uv = @($uo.Trim() -split "`r?`n")
Expect "usage: an old session folder's new runs count; dedupe by message id, appended lines, partial line waits; runs, steps, outcomes, cost, card grids, cold cache, board-only tokens by transcript ($($uv -join ' // '))" ($uv[-4] -eq '3183|3185|70|1|10|1|2/2|1|7|revy 1|0.001272|4|3192|build,agent,review|12' -and $uv[-3] -eq 'True True True True' -and $uv[-2] -eq 'True' -and $uv[-1] -eq 'bo:7 4 True')
# status: one agent joined twice (with -Type, then with -Run) on one transcript = one row (active agents not inflated)
$jvTx = Join-Path (Kd) 'JV.jsonl'; '{}' | Set-Content $jvTx; $jvB = TkPath $k board -Create; $jvNow = (Get-Date).ToString('o')
foreach ($jvE in @{ session = 's-JVz'; agent = 'JV'; run = 'rr'; type = '' }, @{ session = 's-JV'; agent = 'JV'; run = ''; type = 'devy' }, @{ session = 's-KZ1'; agent = 'KZ'; run = 'r1'; status = 'left' }, @{ session = 's-KZ2'; agent = 'KZ'; run = 'r2' }) { $jvR = @{ type = 'devy'; status = 'working'; beat = $jvNow; joined = $jvNow; transcript = $jvTx }; foreach ($kv in $jvE.GetEnumerator()) { $jvR[$kv.Key] = $kv.Value }; & $J $jvR (Join-Path $jvB "$($jvE.session).json") }   # KZ: left, re-joined live
$jv = Invoke-PsTest 'dupjoin' '$null = . $args[0] 6>$null; @(Get-KitStatusRows | Where-Object { $_.name -match "^(JV|KZ) " } | ForEach-Object { "$($_.name)/$($_.run)" }) -join ","' @($O)
Expect "status: two board entries of one agent on one transcript = one row, the typed one, a live re-join over its left twin ($jv)" ((@("$jv".Trim() -split ',') | Sort-Object) -join ',' -eq 'JV (devy)/,KZ (devy)/r2')
# tracked ports current (GEMINI.md went stale after a commit): kitbag.py port --check, workspace copies aside; 2 = ports unavailable
$pck = python -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') port --check 2>&1 | Out-String; $pckc = $LASTEXITCODE; $pst = @([regex]::Matches($pck, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '\(workspace copy\)$' })
Expect "port: the tracked ports (.codex, .agents, GEMINI.md) match a fresh generation: run kitbag.py port before committing ($($pst -join ', '))" ($pckc -eq 2 -or -not $pst.Count)
Remove-TestKit $k
Complete-Tests
