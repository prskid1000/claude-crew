#Requires -Version 7
<#
layout.tests.ps1: the kit's place on disk: stray runtime folders (lint RUNTIME-STRAY), runtime resolution, the git hooks; the
supervise page's Statistics tiles (the sweep's lines as tiles, no sweep log).
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
$tileWant = @("st warn'><div class=k>Live agents</div><div class=v>3<small> running</small><span class='tr eq'>▼ 2", '9 of 12 done &#183; wf_a &#183; 1 stale: fix:W2T 27 min', "st warn'><div class=k>Disk D</div><div class=v>479.1<small> GB free</small><span class='tr bad'>▼ 1.4",
  '+1.7 GB/h &#183; full in 30.2 h', "st '><div class=k>Disk E", 'QA seats</div><div class=v>1<small> / 12', 'Build gate</div><div class=v>1<small> running · </small>2', '7 days avg 65.5% &#183; peak 70%',
  "st lo'><div class=k>Sweep time</div><div class=v>34<small> s</small><span class='tr good'>▼ 6</span></div><div class=s title='wave reports 14.2 s'")
$tileMissing = @($tileWant | Where-Object { -not $tilePage.Contains($_) })
$staleBoard = Join-Path (TkPath $k board -Create) 'stale-s.json'; @{ session = 'stale-s'; agent = 'Y7'; run = 'r7'; status = 'working'; beat = (Get-Date).AddMinutes(-40).ToString('o'); joined = (Get-Date).AddMinutes(-50).ToString('o') } | ConvertTo-Json | Set-Content $staleBoard -Encoding utf8
$superviseOut = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') supervise -AutoFix -Json 2>$null | Out-String | ConvertFrom-Json
$livePage = Get-Content ([IO.Path]::ChangeExtension((TkPath $k supervise-report), '.html')) -Raw
Expect "supervise page: Statistics tiles (live agents + stale, memory, gate, QA seats, a disk each: full-in under 72 h only, sweep time), no sweep log; a silent board entry = STUCK flag, no board / shells count lines (missing: $($tileMissing -join ' | '))" (
  -not $tileMissing.Count -and $tilePage -notmatch 'full in 90|Sweep log|<pre' -and @($superviseOut.flags.what -match '^STUCK Y7 .*\(r7\): no progress for 40 min').Count -eq 1 -and -not @($superviseOut.summary -match '^(board|shells): ').Count -and $livePage -match 'This sweep</h3>.+Memory</div>.+Sweep time' -and $livePage -notmatch 'Sweep log')
# supervise page: every list of short items goes through the one grid helper (.cg, auto-fill); no one-row-per-item list or narrow column
$gridPage = (Invoke-PsTest grids @'
. $args[0]
Format-KitSuperviseHtml ('{"at":"2026-01-02T10:00:00","flags":[{"level":"WATCH","what":"w"},{"level":"INFO","what":"i"}],"agents":[{"name":"a (workflow)","run":"r1","state":"ACTIVE","task":"t · steps 1/4 · 2k tokens of 10k"}],"resources":[{"name":"seat","by":"W1","gb":1.5}],"mem":{"TotalGB":8,"AvailGB":2},"stats":{"settings":{"heartbeatMinutes":15}}}' | ConvertFrom-Json)
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
$gridWant = @('kpis', 'flags', 'info', 'gauges', 'res', 'stats', 'toks', 'kv' | Where-Object { $gridPage -notmatch "class='cg $_' style='--cmin:\d+px" })
$gridOld = @('<section class=kpis>', '<div class=gauges>', '<div class=stats>', 'class=toks>', '<span class=tn>', '<th>Resource</th>', '<th>Key</th><th>Value</th>', 'grid-template-columns:minmax(0,240px)' | Where-Object { $gridPage.Contains($_) })
Expect "supervise page: list sections use the grid helper (missing: $gridWant), no old list pattern (found: $gridOld); tokens 3 across max with a full-width bar" (
  -not $gridWant.Count -and -not $gridOld.Count -and $gridPage -match "cg toks' style='--cmin:\d+px;--cmax:3'><div class='ci f' title='r1 &#183; 2k of 10k tokens'><div class=tn>r1</div><div class=sm>2k of 10k tokens</div><span class=bar>" -and $gridPage -match '\.cg\{display:grid;[^}]*repeat\(auto-fill,minmax\(min\(100%')
# kitbag.py ui-check (headless, light + dark): an ellipsis, an overflow or a squeezed cell fails; the dashboard with long names and 10
# holders passes at 1366 / 900 / 390 and stamps; lint nudges (UI-CHECK) on a changed page generator newer than the stamp
if (Use-BrowserKit) {
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'; $uiBad = Join-Path (Kd) 'clip.html'
  [IO.File]::WriteAllText($uiBad, '<!doctype html><body><div style="width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">browser app-staging·tenant1·admin</div><div style="width:90px;white-space:nowrap">test:W2P, test:W2U, test:W2R</div><table style="width:60px;table-layout:fixed"><tr><td style="width:20px;overflow-wrap:anywhere">abcdefghijklmnop</td><td>x</td></tr></table><p style="width:90px;height:16px;overflow:hidden">one two three four five six</p><p style="width:90px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:1">clamped to one line of text</p></body>')
  $uiBadOut = @(& $py -X utf8 $uiKb ui-check $uiBad --widths 390 2>&1); $uiBadCode = $LASTEXITCODE
  Expect "ui-check: ellipsis, overflow, hidden height, line-clamp and a squeezed cell fail in both themes (exit $uiBadCode)" ($uiBadCode -eq 1 -and @($uiBadOut -match 'CLIP div: text-overflow: ellipsis').Count -eq 2 -and @($uiBadOut -match 'CLIP div: scrollWidth').Count -eq 2 -and @($uiBadOut -match 'CLIP td: squeezed').Count -eq 2 -and @($uiBadOut -match 'CLIP p: scrollHeight').Count -eq 2 -and @($uiBadOut -match 'CLIP p: line-clamp 1').Count -eq 2)
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
  $uiOut = @(& $py -X utf8 $uiKb ui-check $uiPage 2>&1); $uiCode = $LASTEXITCODE; $uiShots = @(Get-ChildItem (Join-Path (TkPath $k shots) 'ui-check') -Filter 'dash-*.png' -ErrorAction SilentlyContinue)
  Expect "ui-check: the dashboard (long names, 10 holders) has no clipped text at 1366 / 900 / 390, light + dark, 6 shots; UI-CHECK nudge before the stamp only (exit $uiCode, $($uiShots.Count) shots, before $uiWarnBefore; $($uiOut | Where-Object { $_ -match 'CLIP' } | Select-Object -First 3))" (
    $uiCode -eq 0 -and $uiShots.Count -eq 6 -and "$uiWarnBefore" -eq "['skills/bossy/adapters/supervise_resources.ps1']" -and "$(& $uiWarn)" -eq '[]')
}
Remove-TestKit $k
Complete-Tests
