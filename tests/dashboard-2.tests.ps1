#Requires -Version 7
<#
dashboard-2.tests.ps1: the supervise page's Parity panel (Kit internals, folded): kitbag.py parity --json cached per kit HEAD +
parity.json time; per family the verbs some adapter lacks natively (gap red, fallback amber, the reason on hover), all-native
families in one line, the harness rows not ported to both.
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
Remove-TestKit $k
Complete-Tests
