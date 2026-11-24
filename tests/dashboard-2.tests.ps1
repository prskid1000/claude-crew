#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page's Parity panel (Kit internals, folded): kitbag.py parity --json cached per kit HEAD +
parity.json time; per family the verbs some adapter lacks natively (gap red, fallback amber, the reason on hover), all-native
families in one line, the harness rows not ported to both; the context info popover text (from context.tests.ps1).
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
Remove-TestKit $k
Complete-Tests
