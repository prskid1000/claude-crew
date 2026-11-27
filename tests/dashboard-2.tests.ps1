#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page has no Parity panel (parity stays internal); the PARITY next batch ACT; the context
info popover text (from context.tests.ps1); label case, role map, day heat groups (from runtimes.tests.ps1); the hour head;
context ACTs count only agents after a fix; heatmap cell numbers (from dashboard.tests.ps1); group lines, today-only rows, status per
past day, folds kept across a reload; board beat stamps stored UTC, shown local (TS-STORED, from naming.tests.ps1); Statistics
tiles, grids, sentence case and the page's ui-check (from layout.tests.ps1).
Usage: pwsh -NoProfile -File <kit>/tests/dashboard-2.tests.ps1 (or tests/kit-tests.ps1 -Area dashboard-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/waits.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/adapters/deploy-merge.ps1', 'skills/pokey/adapters/deployed-checks.ps1')   # DEPLOY IDLE / STALLED
$k = New-TestKit dashboard2; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# no parity panel (owner 2026-11-24: parity stays internal, kitbag.py parity): an old report's stats.parity renders nothing, no kitbag.py call
$pq = & { . $O; $global:pqx = 0; function Invoke-KitExe { $global:pqx++; [pscustomobject]@{ code = 0; out = '{}'; err = '' } }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ parity = [pscustomobject]@{ adapters = @{ ci = @{} } } } })
  "$global:pqx|$($h -match 'id=sec-parity|class=.pq')|$($h -match 'id=sec-internals')|$([bool](Get-Command Get-KitParityView, Format-KitParityHtml -ErrorAction SilentlyContinue))" }
Expect "dashboard: no Parity panel or its functions, Kit internals still there, no kitbag.py parity run ($pq)" ($pq -eq '0|False|True|False')
# PARITY next batch (owner 2026-11-24): open cells and no live parity kitty = one ACT; a live parity kitty (run or subject) = none; the
# count is cached per kit HEAD + parity.json time (one kitbag.py run); no open cell = none
$pfl = & { . $O; $global:pfx = 0; $global:pfo = 'parity next: 7 open cell(s)'; function Invoke-KitExe { $global:pfx++; [pscustomobject]@{ code = 0; out = $global:pfo; err = '' } }
  $now = "$(Get-Date)"; $kb = @(@{ status = 'working'; type = 'kitty'; agent = 'kitty-3'; run = 'kitty-docker'; subject = 'docker'; beat = $now }, @{ status = 'left'; type = 'kitty'; agent = 'kitty-4'; run = 'kitty-parity'; beat = $now })
  $a1 = @(Get-KitSuperviseFlagsParity -Board $kb | ForEach-Object { "$($_.level) $($_.what)" }) -join ';'
  $a2 = @(Get-KitSuperviseFlagsParity -Board @($kb + @{ status = 'working'; type = 'kitty'; agent = 'kitty-5'; run = 'kitty-x'; subject = 'parity'; beat = $now })).Count
  $a3 = @(Get-KitSuperviseFlagsParity -Board $kb).Count; Remove-Item (Join-Path (Get-KitPath cache) 'parity-next.json'); $global:pfo = 'parity next: 0 open cell(s)'
  "$a1|$a2|$a3|$global:pfx|$(@(Get-KitSuperviseFlagsParity -Board $kb).Count)" }
Expect "supervise PARITY: ACT while cells are open and no parity kitty lives; a live one (subject parity) = none; cached; 0 open = none ($pfl)" ($pfl -eq 'ACT PARITY next batch: 7 open cell(s), no parity kitty live|0|1|1|0')
# the info popover (owner 2026-11-23): one script on the page and each run page (titles stay data, no title rewrite); context tip text
# the popover structures: empty categories left out, the largest results one per line; tile labels wrap (no ellipsis on the page)
$popT = & { . $O; $n = [datetime]'2026-01-02T10:00:00'
  $cx = [pscustomobject]@{ n = 4; s0 = 20000; pk = 29000; sum = 94000; agents = 1; pks = 29000; add = @(21500, 1000, 3000, 0, 4000, 0, 0, 1200); car = @(60000, 3000, 9000, 0, 12000, 0, 0, 10000); w = @(0, 0, 0, 0, 0, 0); rr = @(0, ''); top = @('4000|4|Bash pwsh crafty.ps1 check', '900|2|Read a.ps1') }
  $tx = Get-KitContextTip $cx 'build:A1'; $pgs = @{}; $hk = $n.AddHours(-1).ToString('yyyy-MM-dd HH')
  $sp = [pscustomobject]@{ label = 'devy:A1'; role = 'devy'; at = $n.AddMinutes(-10).ToString('o'); min = 50; result = 'pass'; tok = 1000; in = 10; out = 90; cr = 800; cw = 100; cs = @(0.01, 0.2, 0.02, 0.05); tm = @(20, 10, 0, 0, 5, 15); hrs = @{ $hk = @(10, 90, 800, 100, 0.01, 0.2, 0.02, 0.05) }; mrs = @() }
  $run = [pscustomobject]@{ run = 'r1'; id = 'wf_1'; label = 'build a thing'; kind = 'build'; started = $n.AddHours(-2).ToString('o'); status = 'ended'; at = $n.AddMinutes(-10).ToString('o'); tok = 1000; cost = 0.28; in = 10; out = 90; cr = 800; cw = 100; cs = $sp.cs; tm = $sp.tm; tmN = 1; wall = 50; hrs = $sp.hrs; steps = @($sp); total = 1; done = 1; merged = 0; roles = 'devy 1' }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = @(); stats = [pscustomobject]@{ usage = [pscustomobject]@{ runs = @($run); days = @([pscustomobject]@{ day = $n.ToString('yyyy-MM-dd'); tok = 1000; cost = 0.28; in = 10; out = 90; cr = 800; cw = 100; cs = $run.cs }) } } }) $pgs
  "$($tx -match "(?m)^largest results:\r?\n^Bash pwsh crafty\.ps1 check 4k\r?\n^Read a\.ps1 900$") $($tx -notmatch 'kit data|web \+ docs') $(@([regex]::Matches($h, 'window\.KC_SW=\{"kit instructions":"var\(--x-ki\)"')).Count -eq 1 -and $h -notmatch 'text-overflow:ellipsis') $(@($pgs.Values | Where-Object { $_ -match 'KC_SW' -and $_ -notmatch 'text-overflow:ellipsis' }).Count -ge 1)" }
Expect "popover: context tip lines (largest results one per line, no empty category), one script with the chart swatches, run pages carry it; no ellipsis ($popT)" ($popT -eq 'True True True True')
# (moved from runtimes.tests.ps1: its cap)
# label pass: a head <b> and a row name capitalised; a value <b>, flag text in <li>, an id row (translate=no) kept
$lcIn = "<b>idle</b><span class='gs0 hrs dy'><b>steps</b></span><li class='f hr'>build gate</li><span class=gn translate=no>api</span><span class=gn>browser x</span>"
$lcOut = & { . $O; ConvertTo-KitLabelCase $lcIn }
Expect "labels: sentence case on heads and row names only ($lcOut)" ($lcOut -ceq "<b>idle</b><span class='gs0 hrs dy'><b>Steps</b></span><li class='f hr'>build gate</li><span class=gn translate=no>api</span><span class=gn>Browser x</span>")
# one role map (owner 2026-11-24): column groups with a header each, a gap (data-g0) before each later group; Waste: patterns per tag, amber fixable, red open
$rgm = & { . $O; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
  $wi = @([pscustomobject]@{ role = 'devy'; kind = 'reread'; tag = 'fixable'; tokens = 9000; what = 're-read a.ps1 3x'; why = 'w1' }, [pscustomobject]@{ role = 'devy'; kind = 'reread'; tag = 'ignored'; tokens = 10; what = 'x'; why = 'w2' }, [pscustomobject]@{ role = 'devy'; kind = 'buildlog'; tag = 'open'; tokens = 5; what = 'log'; why = 'w3' }, [pscustomobject]@{ role = 'revy'; kind = 'reread'; tag = 'fixed'; tokens = 1; what = 'y'; why = 'w4' })
  $wc = (Get-KitWasteRoleCells $wi).devy
  $mh = Format-KitMetricHeat @(@{ n = 'devy'; sub = '2 agents'; v = @(1, 2) + $wc.v; tx = @('1', '2') + $wc.tx; tone = @('', '', 'warn', 'act', ''); tips = @('', '') + $wc.tips }) @('a', 'b', 'fixable', 'open', 'fixed') 'x' 'rg' @(@('Spend', 2), @('Waste', 3))
  "$(@($wc.tx) -join ',') $($mh -match "<b style='grid-column:span 2'>Spend</b><b data-g0 style='grid-column:span 3'>Waste</b>") $($mh -match '<b data-g0>Fixable') $($mh -match "<i data-g0 data-t=warn [^>]*title='devy &#183; fixable: reread: re-read a\.ps1 3x[^']*w1'>1</i><i data-t=act ") $($mh -match '>devy<small>2 agents</small>')" }
Expect "role map: group headers span their columns, later groups open with a gap, waste counts per tag toned with the list in the tooltip, agents on the name line ($rgm)" ($rgm -eq '1,1, True True True True')
$dgf = & { . $O; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; Format-KitDayHeat @(@{ hd = 'G'; g = 'g1'; cn = 2 }, @{ n = 'a'; v = @(1) }, @{ n = 'b'; v = @(0) }) @('2026-01-01') 'k' }
Expect 'day heat groups: a header folds its rows, an idle row in the group''s own fold' ($dgf -match "(?s)<div class=rgg data-g='dg-g1'><div class='gk rgh dgh'><button type=button class=rgb aria-expanded=true><span class=gn0>G</span><span class=gcn>2</span></button></div><div class=gk>.*?>a<.*<button type=button class=gkx data-k='rows' aria-expanded=false>1 idle rows (·|&#183;) no data in 1 days</button><div class=gki>.*>b<.*</div></div></div>$")
# owner 2026-11-25: a group line without its own summary lists its busy rows; a today-only row is no grid row, its value joins the line
$dgn = & { . $O; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; Format-KitDayHeat @(@{ hd = 'G'; g = 'g2' }, @{ n = 'a'; v = @(1, 2); t = '3' }, @{ n = 'fresh'; v = @($null, 4); t = '4' }, @{ n = 'zero'; v = @($null, 0) }) @('2026-01-01', '2026-01-02') 'k' }
Expect "day heat: a group line summarises its rows, today-only rows fold into it (a 0: dropped), never a mostly blank row" ($dgn -match "<span class=gn0>G</span><span class=fsm>a 3 (·|&#183;) now: fresh 4</span>" -and $dgn -notmatch '>fresh<|>zero<')
# status per past day (owner 2026-11-25): outcomes.jsonl rows replayed to each day's end; no row yet: no day
$sdy = & { . $O; $n = Get-Date; $f = Get-KitPath outcomes -Create; $at = { param([int]$b, [int]$h) ([datetimeoffset]$n.Date.AddDays(-$b).AddHours($h)).ToUniversalTime().ToString('o') }
  $rows = @(@{ task = 'S-1'; stage = 'review'; at = (& $at 3 10) }, @{ task = 'S-1'; stage = 'promoted'; at = (& $at 2 9) }, @{ task = 'S-2'; stage = 'open'; at = (& $at 2 11) }, @{ task = 'S-2'; stage = 'failedTesting'; at = (& $at 0 1) })
  [IO.File]::WriteAllLines($f, [string[]]@($rows | ForEach-Object { $_.area = 'r'; $_ | ConvertTo-Json -Compress })); $s = Get-KitOutcomeStats 14; $dd = { param([int]$b) $n.Date.AddDays(-$b).ToString('yyyy-MM-dd') }
  $tx = { param([int]$b) $l = $s.stageDays[(& $dd $b)]; if ($null -eq $l) { 'none' } else { @($l | Sort-Object id | ForEach-Object { "$($_.id)=$($_.stage)" }) -join ',' } }
  "$(& $tx 4)|$(& $tx 3)|$(& $tx 2)|$(& $tx 1)|$($s.stageDays.Contains((& $dd 0)))" }
Expect "outcomes replay: each past day's statuses at its end, none before the first row, today not stored ($sdy)" ($sdy -eq 'none|S-1=review|S-1=promoted,S-2=open|S-1=promoted,S-2=open|False')
# every fold keeps its state across a reload (owner 2026-11-25): a section, a Per day group, idle rows, a long text
if (Use-BrowserKit) {
  $pgK = Join-Path (Kd) 'keep.html'
  & { . $O; $n = Get-Date; $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ days = @(@{ day = $n.ToString('yyyy-MM-dd'); failed = 0 }) } })
    $e = { param($t) [Net.WebUtility]::HtmlEncode("$t") }; $fd = { param($w) "<div class=gks>$(Format-KitHeatRows @(@{ busy = $false; html = '<div class=gk>x</div>' }) $w)</div>" }   # keyed by its row name: a fold added above keeps it
    $lx = "$("<details class=lx><summary>a long text</summary><div class=lf>the rest</div></details>" * 2)$(& $fd 'rows')"
    $h.Replace('<footer>', "<div id=keepx>$lx</div><footer>") | Set-Content $pgK -Encoding utf8; $h.Replace('<footer>', "<div id=keepx>$(& $fd 'kinds')$lx</div><footer>") | Set-Content "$pgK.2.html" -Encoding utf8 }
  $kj = @'
import puppeteer from 'puppeteer-core'
import { pathToFileURL } from 'node:url'
const [bm, file] = process.argv.slice(1), { CHROME, QUIET_ARGS } = await import(bm)
const b = await puppeteer.launch({ executablePath: CHROME, headless: true, args: [...QUIET_ARGS], protocolTimeout: 180000 }), o = {}
try {
  const p = await (await b.createBrowserContext()).newPage(); await p.goto(pathToFileURL(file).href)
  const st = () => p.evaluate(() => { const q = (s) => document.querySelector(s); return [q('#sec-trends').open, q('[data-g=dg-kit]').classList.contains('cl'), q('#keepx .gks').classList.contains('gio'), q('#keepx details.lx').open, document.querySelectorAll('#keepx details.lx')[1].open].join(',') })
  o.before = await st()
  await p.evaluate(() => { document.querySelector('#sec-internals').open = true })
  await p.evaluate(() => ['#sec-trends>summary', '[data-g=dg-kit] .rgb', '#keepx .gkx', '#keepx details.lx>summary'].forEach((s) => document.querySelector(s).click()))   // DOM clicks: a sticky header covers no target
  await new Promise((r) => setTimeout(r, 300)); o.clicked = await st(); await p.reload(); o.after = await st()
  await p.goto(pathToFileURL(file + '.2.html').href); o.shift = await p.evaluate(() => [...document.querySelectorAll('#keepx .gkx')].map((x) => x.dataset.k + ':' + x.parentNode.classList.contains('gio')).join(','))
} finally { await b.close() }
console.log(JSON.stringify(o))
'@
  Push-Location (Join-Path $k 'skills/pokey'); try { $raw = @(& node --input-type=module -e $kj (([uri](Join-Path $k 'skills/pokey/browser.mjs')).AbsoluteUri) $pgK 2>&1); $kr = try { $raw[-1] | ConvertFrom-Json } catch { [pscustomobject]@{ after = "$raw" } } } finally { Pop-Location }
  Expect "folds kept across a reload: section, group, idle rows, long text (a twin summary keeps its own state) ($($kr.before) -> $($kr.clicked) -> $($kr.after))" ($kr.before -eq 'true,false,false,false,false' -and $kr.clicked -eq 'false,true,true,true,false' -and $kr.after -eq $kr.clicked)
  Expect "an idle-row fold keeps its state when a fold above it comes (key: section + row name) ($($kr.shift))" ($kr.shift -eq 'kinds:false,rows:true')
}
# MR-SPREAD (outcomes sweep, lead-time dashboard): an open task's first MRs per repo opened 95 min apart -> one WATCH, then cached
# (no host call, no second WATCH); a fix MR in the same repo (never fetched: a repo's lowest iid only) and a 10 min spread do not count
$msp = & { . $O; $global:msc = 0; function Read-KitTracking { @{ tasks = @{ T1 = @{ task = 'T1'; mrs = @('api!1', 'web!2', 'api!3') }; T2 = @{ task = 'T2'; mrs = @('api!4', 'web!5') } } } }
  function Get-HostProject($r, [switch]$Raw) { $r }; function Invoke-HostVerb($v, $p) { $global:msc++; @{ created_at = @{ '1' = '2026-01-01T10:00:00Z'; '2' = '2026-01-01T11:35:00Z'; '3' = '2026-01-01T15:00:00Z'; '4' = '2026-01-01T10:00:00Z'; '5' = '2026-01-01T10:10:00Z' }["$($p.n)"] } }
  $w1 = @(Get-KitMrSpreadFlags | ForEach-Object what); $c1 = $global:msc; $w2 = @(Get-KitMrSpreadFlags).Count; "$($w1 -join ';')|$c1|$w2|$global:msc" }
Expect "MR-SPREAD: one WATCH per task whose repos' first MRs opened over track.mrSpreadMinutes apart, cached ($msp)" ($msp -match '^MR-SPREAD T1: its repos'' first MRs opened 95 min apart \(over 30; api, web\)\|4\|0\|4$')
# hour head (ui-check 900 px clipped 2-cell labels): labels span 3 cells and end before "now" (cols 21-24)
$hh = & { . $O; Format-KitHourHead ([datetime]'2026-01-01T06:00'); '|'; Format-KitHourHead ([datetime]'2026-01-01T01:00') -Clock }
$hw = "<b style='grid-column:1/span 3'>06</b><b style='grid-column:7/span 3'>12</b><b style='grid-column:13/span 3'>18</b><b class=nw style='grid-column:21/span 4'>now</b> | <b style='grid-column:6/span 3'>06</b><b style='grid-column:12/span 3'>12</b><b style='grid-column:18/span 3'>18</b>"
Expect "hour head: 3-cell labels, none under now ($hh)" ("$hh" -eq $hw)
# context ACT (a 7-day window kept fixed signals firing): only agents started after the signal's last fix count
$cf = & { . $O; $now = Get-Date; function Get-KitWasteFixes { @{ 'waste:kitty:bigresult' = @{ sha = 'f1x'; at = [datetimeoffset]$now.AddMinutes(-30) } } }
  $mk = { param($n, $m, $s0 = $m) [pscustomobject]@{ label = $n; role = 'kitty'; run = $n; result = 'pass'; at = $now.AddMinutes(-$m).ToString('o'); t0 = $now.AddMinutes(-$s0).ToString('o'); cx = [pscustomobject]@{ n = 3; s0 = 1; pk = 1; sum = 3; last = 1; w = @(0) * 6; rr = @(0, ''); top = @('9500|2|Read a.ps1') } } }
  "$(@(Get-KitContextFlags @((& $mk a 90), (& $mk b 80), (& $mk c 10), (& $mk e 5 60)) $now | Where-Object level -eq 'ACT').Count) $(@(Get-KitContextFlags @((& $mk a 90), (& $mk c 10), (& $mk d 5)) $now | Where-Object level -eq 'ACT').what)" }
Expect "context ACT: agents started before the fix (one ended after it) do not count, 2 after it flag again ($cf)" ("$cf" -match '^0 context: code reads results over 8000 tokens in 2 agents$')
# K51 (owner): every heatmap cell shows its number (gate: busy minutes; Resources: CPU % over RAM GB), 0 blank, dark shade = hi (contrast text)
$hnm = & { . $O; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }; $h0 = [datetime]'2026-01-02T00:00:00'; $hs = @(0..23 | ForEach-Object { , @(0, 0, 0) }); $hs[3] = @(1, 30, 0); $hs[4] = @(1, 2, 0)
  $g = Format-KitHeatCells $hs $h0 'g' { 'tip' }; $s = Format-KitHeatCells $hs $h0 's' { 'tip' } { param($hv) @(42, '5', 100, '1.5') } 'sp'
  "$((@(0, 0.04, 3.26, 12.6 | ForEach-Object { Format-KitHeatNum $_ }) -join '/') -eq '/0.1/3.3/13') $($g -match "<i class=hi style='--a:78%' title='03:00 &#183; tip'>30</i><i style='--a:\d+%' title='04:00 &#183; tip'>2</i><i style='--a:0%'[^>]*></i>") $($s -match "<i style='--a:42%;--b:100%' title='[^']*'><span class='t'>5</span><span class='u hi'>1.5</span></i>")" }
Expect "heatmap cells: a number in every non-empty cell (one renderer), blank at 0, hi on a dark shade, split CPU over RAM ($hnm)" ($hnm -eq 'True True True')
# DEPLOY IDLE: a target done 10+ min ago (a running CI target: its run asked) with no deploy record since; STALLED: a turn ended on a
# wait whose background commands all ended (opsy 2026-11-25 never armed its watch3 waker)
$dw = & { . $O; $n = Get-Date; $iso = { param($m) $n.AddMinutes(-$m).ToString('o') }
  function Get-HostProject($r, [switch]$Raw) { $r }; function Invoke-HostVerb($v, $p) { @{ sha = 'abc1'; status = 'success'; updated_at = (& $iso 20) } }
  Set-JsonFile (Join-Path (Get-KitPath deploys -Create) 'schedule-x.json') @{ items = @(@{ name = 'A'; target = 'stg'; status = 'success'; finishedAt = (& $iso 30) }, @{ name = 'B'; target = 'prd'; status = 'success'; finishedAt = (& $iso 30) },
    @{ name = 'C'; target = 'stg2'; status = 'running'; kind = 'ci-job'; branch = 'main'; sha = 'abc1'; repo = 'r' }, @{ name = 'D'; target = 'stg3'; status = 'failed'; finishedAt = (& $iso 5) }) }
  Write-KitLog deploy-log record @{ target = 'prd' }
  $bd = Get-KitPath board -Create; foreach ($a in @(@('opsy-1', 'opsy', 'x1', 'completed'), @('devy-9', 'devy', 'x2', ''))) {
    $tf = Join-Path (Kd) "$($a[2]).jsonl"; @((@{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; content = "Command running in background with ID: $($a[2])." }) } } | ConvertTo-Json -Compress -Depth 6),
      $(if ($a[3]) { @{ type = 'user'; message = @{ content = "<task-id>$($a[2])</task-id>`n<status>$($a[3])</status>" } } | ConvertTo-Json -Compress -Depth 6 }),
      (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "The old watch goes quiet; I'll follow watch3.log and verify once both finish." }) } } | ConvertTo-Json -Compress -Depth 6)) | Where-Object { $_ } | Set-Content $tf
    (Get-Item $tf).LastWriteTime = $n.AddMinutes(-20); Set-JsonFile (Join-Path $bd "$($a[0]).json") @{ agent = $a[0]; type = $a[1]; status = 'working'; transcript = $tf } }
  "$(@(Get-KitDeployIdle $n 10 | ForEach-Object { "$($_.name)/$($_.agent)" }) -join ',')|$(@(Get-KitStalledWaits $n 10 | ForEach-Object agent) -join ',')|$(@(Get-KitSuperviseFlagsWaits -At $n | Where-Object level -eq 'ACT' | ForEach-Object kind) -join ',')" }
Expect "waits: DEPLOY IDLE (done, or its CI run done, no record) names the live opsy; STALLED = a wait with no open background command ($dw)" ($dw -eq 'A/opsy-1,C/opsy-1|opsy-1|DEPLOY IDLE,DEPLOY IDLE,STALLED')
# deploy intest probe: never under one -TimeoutSec round once lookups used the budget (was a 15 s floor); no budget: 10 x -TimeoutSec
$ip = & { . $O; $s = (Get-Date).AddSeconds(-40); @((Get-KitInTestProbeSec 50 240 $s), (Get-KitInTestProbeSec 300 100 $s), (Get-KitInTestProbeSec 0 100 $s) | ForEach-Object { [int][math]::Round($_ / 10) * 10 }) -join ',' }
Expect "deploy intest: probe seconds = budget left, at least -TimeoutSec + 10; no budget 10 x ($ip)" ($ip -eq '250,260,1000')
# TS-STORED: writers store UTC ...Z; a fresh ...Z beat reads as local (board HH:mm local, age ~0, never stale)
$tsK = New-TestKit tsstored; $tsO = Join-Path $tsK 'skills/bossy/bossy.ps1'   # its own kit: no other agents on its board
$tsOut = Px $tsO board join -Type devy -Agent tsz-01 -Run tsr | Out-String; $tsFile = @(Get-ChildItem (TkPath $tsK board) -Filter 'tsz-01*.json')[0].FullName
$tsRaw = Get-Content -LiteralPath $tsFile -Raw; $tsLocal = ([datetimeoffset]($tsRaw | ConvertFrom-Json -DateKind String).beat).LocalDateTime.ToString('HH:mm'); $tsShow = Px $tsO board show | Out-String
$tsRead = pwsh -NoProfile -Command ". '$(Lib)'; `$e = Get-Content -LiteralPath '$tsFile' -Raw | ConvertFrom-Json; [int][math]::Abs(((Get-Date) - [datetime]`$e.beat).TotalMinutes); ([datetime]`$e.beat).ToString('HH:mm')"
$tsLeft = Px $tsO board leave -Agent tsz-01 | Out-String
Expect "TS-STORED: board beat stored as UTC ...Z, read back local ($($tsRead -join ' ')) and shown as local $tsLocal, not stale" ($tsRaw -match '"beat":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"' -and
  [int]$tsRead[0] -le 1 -and $tsRead[1] -eq $tsLocal -and $tsShow -match "tsz-01.*\| beat $tsLocal" -and "$(@($tsShow -split "`n") -match 'tsz-01')" -notmatch 'STALE|QUIET')   # its own row: this kit's earlier cases leave other agents
Remove-TestKit $tsK
# Runs list (owner 2026-11-26): ONE name (the run's topic in full, id in the tooltip); a run marked done (launch -Done on a self record:
# its wfDir) never "running"; one stopped by a usage limit says so; the state chips stay on the title line (no wrap)
$rl = & { . $O; $n = (Get-Date).Date.AddHours(12); $iso = { param($m) $n.AddMinutes($m).ToString('o') }
  @{ run = 'hm-x'; script = 'buildy.js'; wfDir = 'C:/t/workflows/wf_r1'; completed = (& $iso -5) } | ConvertTo-Json | Set-Content (Join-Path (Get-KitPath launches -Create) 'self-buildy-hm-x-1.json')
  function Get-KitUsageLimits { [pscustomobject]@{ text = 'weekly limit'; models = @('m'); runs = @('wf_r2'); at = $n } }
  $rr = { param($id, $tp) @{ run = "r-$id"; id = $id; label = "buildy-$id"; topic = $tp; kind = 'build'; status = 'running'; started = (& $iso -60); at = (& $iso -1); tok = 10; wall = 60; steps = @(@{ label = 'build:A1'; role = 'devy'; at = (& $iso -2); min = 30; result = 'running'; tok = 10 }) } }
  $u = [pscustomobject]@{ days = @(@{ day = $n.ToString('yyyy-MM-dd'); tok = 9 }); runs = @((& $rr 'wf_r1' 'HM parity in RM app: driver app, messaging, app texts and merge stops'), (& $rr 'wf_r2' '')) }
  $u.runs[1].status = 'ended'
  Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ usage = $u }; agents = @() }) }
$r1 = [regex]::Match($rl, "data-g='rr-wf_r1'.{0,900}?</span>(?=<span class=gs|<span class='gs)").Value; $r2 = [regex]::Match($rl, "data-g='rr-wf_r2'.{0,900}?</span>(?=<span class=gs|<span class='gs)").Value
Expect "Runs list: the topic in full as the one name, id in the tooltip; marked done = not running; usage limit = stopped (usage limit); chips on the title line ($($r1.Length)/$($r2.Length))" ($r1 -match "title='HM parity in RM app: driver app, messaging, app texts and merge stops &#183; r-wf_r1 &#183; wf_r1'><button type=button class=rtg aria-expanded=false>HM parity in RM app: driver app, messaging, app texts and merge stops</button>" -and $r1 -notmatch 'chip s-act' -and $r2 -match "rtg aria-expanded=false>buildy-wf_r2</button>.*chip s-oth'>stopped \(usage limit\)" -and $rl -match '\.rtl \.rr>\.gn\{display:flex;flex-wrap:nowrap')
# owner 2026-11-27: a tile strip is one row at desktop width (tiles share it, labels wrap), a zero tile dimmed; the machine row adds
# agents live / supervise.manyAgents, lane services up, CPU now + 24 h peak, disk written today (top writer in the tooltip)
$mt = & { . $O; $n = Get-Date; $ag = { param($nm, $st) [pscustomobject]@{ name = $nm; state = $st } }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = @((& $ag 'devy-1 (devy)' 'ACTIVE'), (& $ag 'checky-1 (checky)' 'WAITING'), (& $ag 'devy-2 (devy)' 'FINISHED'), (& $ag 'run-x (workflow)' 'ACTIVE'))
    resources = @(@{ kind = 'env'; name = 'ln-a · api' }); stats = [pscustomobject]@{ gate = @{ running = 0; queued = 0; today = 3 }; cpu = @{ svc = @('ln-a · api', 'ln-a · db'); samples = @(@{ at = $n.AddHours(-2).ToString('o'); s = 300; all = 90.2 }, @{ at = $n.ToString('o'); s = 300; all = 40.4 }) }
      writes = @{ src = 'tracer'; rows = @(@{ n = 'whole machine'; day = 3.5 }, @{ n = 'mysqld'; day = 2.1 }); more = @(@{ n = 'MsMpEng'; day = 0.4 }) } } })
  $ba = @(Get-KitBoardRunAgents @([pscustomobject]@{ live = $false; rows = @([pscustomobject]@{ run = 'solo-o'; agent = 'devy-o'; type = 'devy'; joined = $n.AddDays(-2).ToString('o'); beat = $n.AddDays(-2).ToString('o') }) }) @((& $ag 'devy-1 (devy)' 'ACTIVE')))
  "$($h -match "<b>2 / 8</b><span>Agents live</span>")|$($h -match "<b>1 / 2</b><span>Lane services up</span>" -and $h -match 'ln-a 1/2')|$($h -match "<b>40<small>%</small></b><span>CPU now &#183; 24 h peak 90%</span>")|$($h -match "<b>3.5<small> GB</small></b><span>Disk written today</span>" -and $h -match 'top writer mysqld 2.1 GB')|$($h -match "class='tl z'[^>]*><b>0</b><span>Builds queued")|$($h -match '@media\(min-width:1100px\)\{\.tls\{flex-wrap:nowrap\}')|$(@($ba).Count):$($ba[-1].name):$($ba[-1].state)" }
Expect "tile strips: one row at desktop width, zero dimmed; machine tiles agents live, lane services up, CPU, disk written today; an older ended solo agent keeps its run row ($mt)" ("$mt" -eq 'True|True|True|True|True|True|2:devy-o (devy):FINISHED')
# ---- from layout.tests.ps1: Statistics tiles, grids, sentence case, ui-check of the page
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
  "now: all branches 7 &#183; all worktrees 3 &#183; c 5/0 &#183; a 3/2</span>",   # owner 2026-11-25: rows with today only join the Repos line
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
  git init -q $k; git -C $k add skills/bossy; git -C $k commit -q -m base; $uiSr = Join-Path $k 'skills/bossy/adapters/supervise-resources.ps1'; Undo-TestKitLink $uiSr; Add-Content $uiSr '# touched'
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
    $uiCode -eq 0 -and $uiShots.Count -eq 8 -and $uiOpen.Count -eq 8 -and [int](@($uiOut -match '^1366 px light loaded: .* (\d+) px tall')[0] -replace '^.* (\d+) px tall.*$', '$1') -le 2700 -and @($uiOut -match '· \d+ px tall as loaded ·').Count -eq 8 -and "$uiWarnBefore" -eq "['skills/bossy/adapters/supervise-resources.ps1']" -and "$(& $uiWarn)" -eq '[]')
}
Remove-TestKit $k
Complete-Tests
