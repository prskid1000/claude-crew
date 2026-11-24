#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page has no Parity panel (parity stays internal); the PARITY next batch ACT; the context
info popover text (from context.tests.ps1); label case, role map, day heat groups (from runtimes.tests.ps1).
Usage: pwsh -NoProfile -File <kit>/tests/dashboard-2.tests.ps1 (or tests/kit-tests.ps1 -Area dashboard-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
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
Expect 'day heat groups: a header folds its rows, an idle row in the group''s own fold' ($dgf -match "(?s)<div class=rgg data-g='dg-g1'><div class='gk rgh dgh'><button type=button class=rgb aria-expanded=true><span class=gn0>G</span><span class=gcn>2</span></button></div><div class=gk>.*?>a<.*<button type=button class=gkx aria-expanded=false>1 idle rows (·|&#183;) no data in 1 days</button><div class=gki>.*>b<.*</div></div></div>$")
Remove-TestKit $k
Complete-Tests
