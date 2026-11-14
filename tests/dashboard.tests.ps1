#Requires -Version 7
<#
dashboard.tests.ps1: the supervise page's history graphs (adapters/supervise_stats.ps1): lease waits per resource from the logs,
test-run results per day, CPU per lane process and top other processes; their cards; tile rows of one height (ui-check).
Usage: pwsh -NoProfile -File <kit>/tests/dashboard.tests.ps1 (or tests/kit-tests.ps1 -Area dashboard).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit dashboard; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# lease waits: a tab acquire logged since = wait start, a gate start waitSec, a train's lease-wait; a lock with no wait and short waits drop; noon: one clock hour
$tmp0 = $env:TMP, $env:TEMP; $env:TMP = $env:TEMP = (Kd)   # the gate queue is machine-wide (temp): none here
try { $lwr = & { . $O; $n = (Get-Date).Date.AddHours(12); $t = $n.AddMinutes(-30); $iso = { param($m) $t.AddMinutes($m).ToString('o') }; $dd = Join-Path (Get-KitPath audit -Create) $n.ToString('yyyy-MM-dd'); New-Item -ItemType Directory -Force $dd | Out-Null
  @(@{ at = (& $iso 0); event = 'acquire'; kind = 'tab'; name = 'k1'; agent = 'c1'; since = (& $iso -10) }, @{ at = (& $iso 0); event = 'acquire'; kind = 'lock'; name = 'L'; agent = 'c2'; since = (& $iso 0) }, @{ at = (& $iso 0); event = 'release'; kind = 'tab'; name = 'k1'; since = (& $iso -20) }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Get-KitLogFile leases -Create)
  @(@{ at = (& $iso 0); event = 'start'; owner = 'd1'; waitSec = 600 }, @{ at = (& $iso 0); event = 'start'; owner = 'd2'; waitSec = 5 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $dd 'builds.jsonl')
  @{ at = (& $iso 0); event = 'lease-wait'; env = 'rm2'; services = @('api', 'web'); holders = @('H'); min = 4 } | ConvertTo-Json -Compress | Set-Content (Join-Path $dd 'env.jsonl')
  $w = Get-KitLeaseWaits $n; $hc = @($w.rows | Where-Object name -eq 'browser seats')[0].hours | Where-Object { $_[0] }
  "$(@($w.rows | ForEach-Object { "$($_.name)=$($_.n)/$([math]::Round($_.min))" } | Sort-Object) -join ',')|$($hc[3])"
  $html = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ waits = $w } }); "$($html -match "Lease waits")|$($html -match "title='[^']*&#183; 1 waits &#183; 10 min &#183; longest 10 min &#183; c1'")" }
} finally { $env:TMP, $env:TEMP = $tmp0 }
Expect "lease waits: wait = acquire since..at per resource (tab = browser seats, gate waitSec, a train per service), under 30 s none; card + cell tooltip ($lwr)" ($lwr -join ' ' -eq 'browser seats=1/10,build gate=1/10,rm2 · api=1/4,rm2 · web=1/4|c1 True|True')
# test runs: results.json by write day; PASS_WITH_NOTE = PASS, PENDING none, a cause outside the list = other; an old run is out
$qa = & { . $O; $r = Get-KitPath qa-runs -Create; $f = Join-Path (New-Item -ItemType Directory -Force (Join-Path $r 'run1/T1')) 'results.json'; $f2 = Join-Path (New-Item -ItemType Directory -Force (Join-Path $r 'old/T1')) 'results.json'
  $cs = @(@{ result = 'PASS' }, @{ result = 'PASS_WITH_NOTE' }, @{ result = 'FAIL' }, @{ result = 'NOT_TESTED'; cause = 'env-data' }, @{ result = 'NOT_TESTED' }, @{ result = 'OUT_OF_SCOPE' }, @{ result = 'PENDING' })
  foreach ($x in $f, $f2) { @{ checks = $cs } | ConvertTo-Json -Depth 4 | Set-Content $x }; (Get-Item $f2).LastWriteTime = (Get-Date).AddDays(-9)
  $q = Get-KitQaDays; $d = $q.days[-1]; "$(@($q.days).Count) $($d.pass)/$($d.fail)/$($d.nt)/$($d.oos) $(@($d.runs).run) $($q.causes.'env-data')+$($q.causes.other) $(@($q.days | ForEach-Object { @($_.runs).Count }) -join '')"
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ qa = $q } }); "$($h -match "id=sec-qa open><summary><h2>Test runs, 7 days</h2><span class=cnt>\(1\)") $($h -match "<ul class=qdl data-d='[\d-]+'><li class=qh>") $(([regex]::Matches($h, "<button type=button class='qc")).Count) $($h.Contains(' * 100 / 100'))" }
Expect "test runs: 7 days, today 2 PASS / 1 FAIL / 2 NOT_TESTED / 1 OUT_OF_SCOPE, causes env-data + other, old run out; band (1) with today's runs listed, 7 day bars, full height at the 7-day max ($qa)" ($qa -join ' ' -eq '7 2/1/2/1 run1 1+1 0000001 True True 7 True')
# CPU: % of the machine from CPU seconds between two snapshots; a hook group = its process tree; others 10%+ with the shell's owner
$cpu = & { . $O; $c = [math]::Max(1, [Environment]::ProcessorCount); $n = Get-Date
  function Get-KitSweepProcs { foreach ($p in @(@(100, 1, 60), @(101, 100, 30), @(200, 250, 540), @(250, 1, 0), @(300, 1, 6), @(0, 0, 300))) { [pscustomobject]@{ Id = $p[0]; ParentId = $p[1]; Name = "p$($p[0]).exe"; Cpu = 1000 + $p[2] * $c } } }
  function Get-KitCpuGroupsT { @{ name = 'e · api'; pid = 100 } }
  $acc = [pscustomobject]@{ '100|' = 1000; '101|' = 1000; '200|' = 1000; '250|' = 1000; '300|' = 1000; idle = 1000 }
  $s = (Update-KitCpuStats ([pscustomobject]@{ at = $n.AddSeconds(-600).ToString('o'); acc = $acc; samples = @() }) $n @(@{ pid = 250; owner = 'devy-1' })).samples[-1]
  "$($s.g.'e · api') $($s.all) $(@($s.top | ForEach-Object { "$($_.n):$($_.p):$($_.o)" }) -join ',')"
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ cpu = @{ samples = @($s, $s) } } }); "$($h -match "class='cpo f hot'") $($h -match 'e &#183; api<span class=cv>15') $($h -match 'class=nod>[^<]*no trend yet')" }
Expect "cpu: group = its tree (15%), machine from idle time (50%), top other 90% with its shell's owner; card: red row, group sparkline, a 1-point tile says no trend yet ($cpu)" ($cpu -join ' ' -eq '15 50 p200.exe:90:devy-1 True True True')
if (Use-BrowserKit) {   # owner 2026-11-14: one tall tile (15 repos) beside short ones: each column's last tile stretches; without it uiChecks fails
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'; $pg = Join-Path (Kd) 'tiles.html'; $pg2 = Join-Path (Kd) 'tiles-flat.html'
  & { . $O; $n = [datetime]'2026-01-02T10:00:00'; $lv = @(0..30 | ForEach-Object { [pscustomobject]@{ at = $n.AddMinutes(-20 * $_).ToString('o'); run = $_ % 5; secs = 30 + $_ % 9; br = 30; wt = 9 } }); [array]::Reverse($lv)
    Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); history = @(@{ fixed = 1 }, @{ fixed = 0 }); stats = [pscustomobject]@{ live = $lv; now = [pscustomobject]@{ run = 2; done = 3; total = 9; secs = 34; wfr = @(); stale = @(); disks = @() }; repos = @{ at = $n.ToString('o'); repos = @(1..15 | ForEach-Object { @{ repo = "repo-$_-with-a-longer-name"; branches = $_ % 7 + 1; worktrees = $_ % 3 } }) }; days = @(@{ day = '2026-01-01'; failed = 2 }) } }) } | Set-Content $pg -Encoding utf8
  (Get-Content $pg -Raw).Replace('if(fill)Object.keys', 'if(0)Object.keys') | Set-Content $pg2 -Encoding utf8
  $u1 = @(& $py -X utf8 $uiKb ui-check $pg --widths 1920,1366 --click '#sec-internals summary,#sec-activity summary' 2>&1); $c1 = $LASTEXITCODE; $u2 = @(& $py -X utf8 $uiKb ui-check $pg2 --widths 1366 --click '#sec-internals summary,#sec-activity summary' 2>&1)
  Expect "ui-check: Activity tiles stretch to one row height at 1920 + 1366 (exit $c1$(@($u1 -match '^\s+CLIP') | Select-Object -First 2)); unstretched, uiChecks flags the columns ($(@($u2 -match 'tile columns end')[0]))" ($c1 -eq 0 -and @($u2 -match 'CLIP cg stats msn: tile columns end \d+ px apart').Count -ge 2)
}
Remove-TestKit $k
Complete-Tests
