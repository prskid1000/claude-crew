#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page has no Parity panel (parity stays internal); the PARITY next batch ACT; the context
info popover text (from context.tests.ps1); label case, role map, day heat groups (from runtimes.tests.ps1); the hour head;
context ACTs count only agents after a fix; heatmap cell numbers (from dashboard.tests.ps1); group lines, today-only rows, status per
past day, folds kept across a reload; board beat stamps stored UTC, shown local (TS-STORED, from naming.tests.ps1).
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
Remove-TestKit $k
Complete-Tests
