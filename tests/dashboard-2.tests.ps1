#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page's Parity panel (Kit internals, folded): kitbag.py parity --json cached per kit HEAD +
parity.json time; per family the verbs some adapter lacks natively (gap red, fallback amber, the reason on hover), all-native
families in one line, the harness rows not ported to both; the context info popover text (from context.tests.ps1); label case, role map, day heat groups (from runtimes.tests.ps1).
Usage: pwsh -NoProfile -File <kit>/tests/dashboard-2.tests.ps1 (or tests/kit-tests.ps1 -Area dashboard-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit dashboard2; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$pjx = '{"adapters":{"ci":{"github":{"runs":"native","parseUrl":"native","failure":"fallback"},"jenkins":{"runs":"native","parseUrl":"gap","failure":"fallback"}},"stack":{"core":{"detect":"native"}}},' +
  '"harness":[{"feature":"skill crafty","claude":{"state":"native","note":""},"codex":{"state":"port","note":""},"antigravity":{"state":"port","note":""}},{"feature":"Artifacts","claude":{"state":"native","note":""},"codex":{"state":"gap","note":"no Artifacts tool"},"antigravity":{"state":"port","note":""}}],"problems":[]}'
$reg = '{"adapters":{"ci":{"gaps":{"jenkins/parseUrl":"no URL parser"},"fallback":{"failure":"core Get-KitCiFailure"}},"stack":{}}}'
$pq = & { . $O; Set-Content (Join-Path $k 'skills/crafty/parity.json') $reg
  $global:pqx = 0; function Invoke-KitExe { $global:pqx++; [pscustomobject]@{ code = 0; out = $pjx; err = '' } }
  $v = Get-KitParityView; $v2 = Get-KitParityView
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ parity = $v2 } })
  $sec = [regex]::Match($h, "<details class='sec sub' id=sec-parity>[\s\S]*?</details>").Value
  "$global:pqx|$($v2.why.ci.'jenkins/parseUrl')|$($sec -match '<span class=cnt>\(2 gaps &#183; 2 fallbacks\)</span>')|$($sec -match "<span class='pq g' title='gap: no URL parser'>gap</span>")|$($sec -match "<span class='pq f' title='fallback: core Get-KitCiFailure'>fallback</span>")|$($sec -match 'all native: runs')|$($sec -match 'All native: stack')|$($sec -match '>Artifacts<' -and $sec -notmatch '>skill crafty<')|$($sec -match "title='gap: no Artifacts tool'")" }
Expect "parity panel: one kitbag.py run (cached), folded fold with gap / fallback counts, red gap and amber fallback cells with their reasons, all-native verbs and families, harness gaps only ($pq)" ($pq -eq '1|no URL parser|True|True|True|True|True|True|True')
$pn = & { . $O; (Format-KitParityHtml $null).h }
Expect "parity panel: no data yet says so ($pn)" ($pn -match 'No parity data yet')
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
