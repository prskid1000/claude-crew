#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/local-bench.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/local-bench.tests.ps1: crafty.ps1 local bench (adapters/localbench.py) on a tiny fixture, no model: build from recorded
# transcripts (a step's StructuredOutput, an ad hoc agent's final JSON, a null field), a rebuild needs -Force; run through the
# launcher (fake server + fake client: no tools, the bench User-Agent), resume, -Ids re-run, a timeout ends the
# client tree, a launcher refusal is infra (re-run, out of the rate); score: right answers accepted, a flipped ok, a missing
# count and a tool call written as text rejected, strict vs repairable JSON; report per role; diff.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/local-model.ps1', 'skills/crafty/adapters/video.ps1', 'skills/crafty/adapters/localbench.py')
$k = New-TestKit lb; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $cfgFile = Join-Path $k 'skills/crafty/kit.local.json'

# fixture transcripts: checky close steps T1-T4 (workflow), ad hoc watchy and datay runs
$tr = Join-Path (Kd) 'projects'; $wf = Join-Path $tr 's1/subagents/workflows/wf_1'; $ah = Join-Path $tr 's1/subagents'; New-Item -ItemType Directory -Force $wf | Out-Null
$ln = { param($o) $o | ConvertTo-Json -Depth 12 -Compress }
$sys = 'You are powered by the model named Haiku. The exact model ID is claude-haiku-5-5.'
function Add-Fixture([string]$Dir, [string]$Name, [string]$Type, [string]$Label, [string]$Prompt, [string]$ToolOut, $Final, [string]$FinalText) {
  $last = if ($FinalText) { & $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = $FinalText }) } } } else { & $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'u2'; name = 'StructuredOutput'; input = $Final }) } } }
  @((& $ln @{ type = 'user'; message = @{ content = "$Prompt $sys" } }),
    (& $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'u1'; name = 'Bash'; input = @{ command = "run $Label" } }) } }),
    (& $ln @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'u1'; content = $ToolOut }) } }), $last) | Set-Content (Join-Path $Dir "$Name.jsonl") -Encoding utf8
  @{ agentType = $Type; description = $Label } | ConvertTo-Json | Set-Content (Join-Path $Dir "$Name.meta.json") -Encoding utf8
}
Add-Fixture $wf 'agent-c5' checky 'close:T5' 'STEP (checky, role lead): publish T5.' 'nothing to publish' @{ ok = $true; output = 'done' }
foreach ($cn in 1..4) { Add-Fixture $wf "agent-c$cn" checky "close:T$cn" "STEP (checky, role lead): publish T$cn." "T$cn report: https://docs.example/d/$cn 3/3 pass" @{ ok = $true; output = "T$cn published: https://docs.example/d/$cn 3/3 pass" } }
Add-Fixture $ah 'agent-w1' watchy 'nightly sweep' 'Kind sweep, watch W1.' '0 errors' $null "Clean.`n``````json`n{`"status`": `"clean`", `"bugs`": 0}`n``````"
Add-Fixture $ah 'agent-d1' datay 'data check' 'Kind check, data D1.' '3 rows' $null "Done.`n``````json`n{`"status`": `"clean`", `"rows`": 3, `"mr`": null}`n``````"
$sys = $sys -replace 'haiku', 'sonnet'; Add-Fixture $ah 'agent-w2' watchy 'nightly sweep 2' 'Kind sweep, watch W2.' '1 error' $null "``````json`n{`"status`": `"bug`", `"bugs`": 1}`n``````"
$rvJson = '{"verdict": "changes", "findings": [{"file": "a.py", "severity": "high", "issue": "a null crash in parse_reply"}, {"file": "b.ps1", "severity": "low", "issue": "dropped empty argument"}]}'
$sys = $sys -replace 'sonnet', 'opus'; Add-Fixture $ah 'agent-r1' revy 'review mr' 'Kind mr. Review MR R1.' 'diff' $null "``````json`n$rvJson`n``````"; Add-Fixture $ah 'agent-r2' revy 'review plan' 'Kind plan. Review plan R2.' 'plan' $null "``````json`n$rvJson`n``````"

$bd = Invoke-TestScript $D local bench build -Set t1 -Roles 'checky:close,watchy,datay,revy,vidy' -N 9 -Since 2000-01-01 -Transcripts $tr
$sd = Join-Path $k '.state/local-bench/t1/tasks'
$byLabel = @{}; foreach ($td in @(Get-ChildItem $sd -Directory -ErrorAction SilentlyContinue)) { $mt = Get-Content (Join-Path $td.FullName 'meta.json') -Raw | ConvertFrom-Json; $byLabel[$mt.label] = $mt }
$c1 = $byLabel['close:T1']; $cj = try { Get-Content (Join-Path $sd "$($c1.id)/cloud.json") -Raw | ConvertFrom-Json } catch { $null }
$dsch = try { Get-Content (Join-Path $sd "$($byLabel['data check'].id)/schema.json") -Raw | ConvertFrom-Json } catch { $null }
Expect "bench build: one task per recorded step, the cloud answer (StructuredOutput / final JSON), its tier, a prompt hash, a missing role named ($($bd.code): $($bd.out.Trim()))" ($bd.code -eq 0 -and $byLabel.Count -eq 10 -and $cj.ok -eq $true -and $byLabel['nightly sweep 2'].tier -eq 'sonnet' -and $byLabel['review mr'].role -eq 'revy@mr' -and $byLabel['review plan'].tier -eq 'opus' -and $c1.tier -eq 'haiku' -and $c1.promptSha -and $bd.out -match 'no history: vidy' -and (Get-Content (Join-Path $sd "$($c1.id)/prompt.md") -Raw) -match '(?s)never call a tool.*run close:T1.*3/3 pass.*JSON SCHEMA')
Expect "bench build: a null in the cloud answer allows any type in the schema" ($dsch -and $null -eq $dsch.properties.mr.type -and $dsch.properties.rows.type -eq 'number')
$b2 = Invoke-TestScript $D local bench build -Set t1 -Roles watchy -Since 2000-01-01 -Transcripts $tr
Expect "bench build: an existing set is not rebuilt without -Force, exit 1 ($($b2.code))" ($b2.code -eq 1 -and $b2.out -match '-Force rebuilds it')

# a fake server (GET /v1/models: small-a) and fake clients: right for T1 / W1 / D1, ok flipped for T2, count dropped for T3,
# T4 sleeps past the timeout, W2 writes a tool call as text; stderr: its args, User-Agent and PID
$tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port; $tl.Stop()
$srv = Start-Job { param($p) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$p/"); $hl.Start(); $end = (Get-Date).AddMinutes(4)
  while ((Get-Date) -lt $end) { $ct = $hl.GetContextAsync(); while (-not $ct.Wait(500)) { if ((Get-Date) -ge $end) { break } }; if (-not $ct.IsCompleted) { break }
    $by = [Text.Encoding]::UTF8.GetBytes('{"object":"list","data":[{"id":"small-a"}]}'); $rs = $ct.Result.Response; $rs.ContentType = 'application/json'; $rs.OutputStream.Write($by, 0, $by.Length); $rs.Close() } } -ArgumentList $port
$pidFile = Join-Path (Kd) 'sleeper.pid'
$fake = Join-Path (Kd) 'fakeclaude.ps1'
Set-Content $fake (@'
$in = @($input) -join "`n"
[Console]::Error.WriteLine("ARGS=$($args -join '|') UA=$env:ANTHROPIC_CUSTOM_HEADERS")
if ($in -match 'publish T4') { Set-Content -LiteralPath 'PIDFILE' $PID; Start-Sleep -Seconds 60 }
$r = if ($in -match 'publish T1') { '{"ok": true, "output": "T1 report https://docs.example/d/1 3/3 pass"}' }
  elseif ($in -match 'publish T2') { '{"ok": false, "output": "T2 report https://docs.example/d/2 3/3 pass"}' }
  elseif ($in -match 'publish T3') { "{`"ok`": true, `"output`": `"T3 report https://docs.example/d/3`nsee doc`"}" }
  elseif ($in -match 'publish T5') { '{"ok": true, "output": "nothing to publish, done"}' }
  elseif ($in -match 'watch W1') { '{"status": "clean", "bugs": 0}' }
  elseif ($in -match 'Review MR R1') { '{"verdict": "changes", "findings": [{"file": "b.ps1", "severity": "low", "issue": "an empty argument is dropped by the shim"}, {"file": "a.py", "severity": "high", "issue": "parse_reply crashes on a null"}]}' }
  elseif ($in -match 'Review plan R2') { '{"verdict": "changes", "findings": [{"file": "a.py", "severity": "low", "issue": "a null crash in parse_reply"}, {"file": "b.ps1", "severity": "low", "issue": "dropped empty argument"}]}' }
  elseif ($in -match 'data D1') { '```json' + "`n" + '{"status": "clean", "rows": 3, "mr": null}' + "`n" + '```' }
  else { '<tool_call><function=Read></function></tool_call>' }
@{ result = $r; num_turns = 1 } | ConvertTo-Json -Compress
'@).Replace('PIDFILE', $pidFile) -Encoding utf8
& $J @{ models = @{ local = @{ baseUrl = "http://127.0.0.1:$port"; defaultModel = 'small-a'; needGB = 0; commands = @{ claude = @($fake) } } } } $cfgFile
for ($wi = 0; $wi -lt 60; $wi++) { try { $tc = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $tc.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }

$md = Join-Path $k '.state/local-bench/t1/small-a'; $t4 = $byLabel['close:T4'].id; $w1 = $byLabel['nightly sweep'].id
$r1 = Invoke-TestScript $D local bench run -Set t1 -Model small-a -TimeoutSec 8
$er = Get-Content (Join-Path $md "runs/$($c1.id).err") -Raw -ErrorAction SilentlyContinue
$res = Get-Content (Join-Path $md 'results.json') -Raw | ConvertFrom-Json
Expect "bench run: each task through local claude, no tools (--tools=), no MCP, no session, the neutral User-Agent ($($r1.code) · $("$er".Trim()))" ($r1.code -eq 0 -and $r1.out -match "run $($c1.id): rc 0" -and "$er" -match 'ARGS=-p\|--output-format\|json\|--tools=\|--strict-mcp-config\|--no-session-persistence' -and "$er" -match 'UA=User-Agent: kit-local-bench')
$spid = [int]"$(Get-Content $pidFile -ErrorAction SilentlyContinue)"
Expect "bench run: a client past -TimeoutSec is ended with its tree, rc timeout ($($res.$t4.rc), pid $spid alive: $([bool](Get-Process -Id $spid -ErrorAction SilentlyContinue)))" ($res.$t4.rc -eq 'timeout' -and $spid -gt 0 -and -not (Get-Process -Id $spid -ErrorAction SilentlyContinue))
$r2 = Invoke-TestScript $D local bench run -Set t1 -Model small-a -TimeoutSec 8
$r3 = Invoke-TestScript $D local bench run -Set t1 -Model small-a -Ids $w1
Expect "bench run: ids that ran are skipped, a timeout runs again, -Ids re-runs only that id ($($r2.out.Trim() -replace '\s+', ' ') / $($r3.out.Trim()))" ($r2.code -eq 0 -and @($r2.out -split "`n" | Where-Object { $_ -match '^run ' }).Count -eq 1 -and $r2.out -match "run ${t4}: rc timeout" -and $r3.out -match "run ${w1}: rc 0" -and $r3.out -notmatch $c1.id)

$s1 = Invoke-TestScript $D local bench score -Set t1 -Model small-a
$sc = Get-Content (Join-Path $md 'score.json') -Raw | ConvertFrom-Json
$g = { param($l) $sc.($byLabel[$l].id) }
Expect "bench score: right answers accepted (same ok + URL + count; same ok, nothing to compare; same short fields; a null field)" ((& $g 'close:T1').accepted -and (& $g 'close:T5').accepted -and (& $g 'nightly sweep').accepted -and (& $g 'data check').outcome -and -not (& $g 'data check').strict -and (& $g 'data check').repairable)
Expect "bench score: list items matched by file whatever their order, a wrong severity rejected ($((& $g 'review mr').why) / $((& $g 'review plan').why))" ((& $g 'review mr').accepted -and -not (& $g 'review plan').accepted -and (& $g 'review plan').why -match 'differ .*findings')
Expect "bench score: a flipped ok, a dropped count and a tool call written as text rejected ($((& $g 'close:T2').why) / $((& $g 'close:T3').why) / $((& $g 'nightly sweep 2').why))" (-not (& $g 'close:T2').accepted -and (& $g 'close:T2').why -match 'ok False vs True' -and -not (& $g 'close:T3').accepted -and -not (& $g 'close:T3').strict -and (& $g 'close:T3').why -match 'missing .*3/3' -and (& $g 'nightly sweep 2').why -eq 'tool-call-text')
$rp = Invoke-TestScript $D local bench report -Set t1 -Model small-a -Json
$rj = try { $rp.out | ConvertFrom-Json } catch { @() }
$rc1 = @($rj | Where-Object role -eq 'checky:close')[0]; $rw = @($rj | Where-Object role -eq 'watchy@sweep')[0]
Expect "bench report: accept rate, p50 and the cloud tier per role ($($rp.out.Substring(0, [math]::Min(220, $rp.out.Length))))" ($rp.code -eq 0 -and $rc1.rate -eq 40 -and $rc1.timeouts -eq 1 -and $rc1.tier -eq 'haiku' -and $rw.rate -eq 50 -and $rw.toolText -eq 1 -and $null -ne $rc1.p50)

$ix = Invoke-TestScript $D local bench run -Set t1 -Model other-1 -Ids $w1; $null = Invoke-TestScript $D local bench score -Set t1 -Model other-1
$ir = try { (Invoke-TestScript $D local bench report -Set t1 -Model other-1 -Json).out | ConvertFrom-Json } catch { @() }
$ir2 = Invoke-TestScript $D local bench run -Set t1 -Model other-1 -Ids $w1
Expect "bench run: a launcher refusal (model not served) is infra: out of the rate, run again ($($ix.out.Trim()))" ($ix.out -match "run ${w1}: rc 1" -and @($ir | Where-Object role -eq 'watchy@sweep')[0].infra -eq 1 -and $null -eq @($ir | Where-Object role -eq 'watchy@sweep')[0].rate -and $ir2.out -match "run ${w1}: rc 1")

$pt = Join-Path (Kd) 'parse.py'
Set-Content $pt "import sys; sys.path.insert(0, r'$k/skills/crafty/adapters'); import localbench as b`nr = b.parse_reply('{`"ok`": true, `"output`": `"a\nb`"}'); f = b.parse_reply('``````json\n{`"ok`": false}\n``````'); p = b.parse_reply('Here: {`"ok`": true, `"output`": `"x`"} done'); t = b.parse_reply('{`"name`": `"PowerShell`", `"arguments`": {}}')`nprint(r['strict'] is None, isinstance(r['repairable'], dict), f['strict'] is None, f['repairable'] == {'ok': False}, p['lenient'] == {'ok': True, 'output': 'x'}, t['toolText'])" -Encoding utf8
$po = "$(& (Get-Command python).Source -X utf8 $pt 2>&1)".Trim()
Expect "bench parse: a raw newline in a string or a code fence is repairable, not strict; prose around an object: lenient; a PowerShell tool call as text named ($po)" ($po -eq 'True True True True True True')

$oc = & (Get-Command python).Source -X utf8 (Join-Path $PSScriptRoot 'local_bench_cases.py') (Join-Path $k 'skills/crafty/adapters') 2>&1; $ocRc = $LASTEXITCODE
Expect "bench outcome rules: ship texts, a flipped verdict, multi-word statuses, plain-string and keyless items, reordered items, empty objects, numbers as strings, echoes, kinds, wanted ($(@($oc)[-1]))" ($ocRc -eq 0)
$m2 = Join-Path $k '.state/local-bench/t1/small-b'; Copy-Item $md $m2 -Recurse
$s2 = Get-Content (Join-Path $m2 'score.json') -Raw | ConvertFrom-Json; $s2.($c1.id).accepted = $false; $s2 | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $m2 'score.json') -Encoding utf8
$df = Invoke-TestScript $D local bench diff -Set t1 -Model small-a -Against small-b
Expect "bench diff: per role rates side by side and the ids that flip ($($df.out.Trim() -replace '\s+', ' '))" ($df.code -eq 0 -and $df.out -match 'checky:close\s+haiku\s+40% \S+\s+20%' -and $df.out -match "flip $($c1.id): small-a accepted, small-b rejected")
$fb = Invoke-TestScript $D local bench build -Set t1 -Roles watchy -Since 2000-01-01 -Transcripts $tr -Force; $nb = Invoke-TestScript $D local bench report -Set t1 -Model small-b
Expect "bench build -Force: the set's old runs and scores go with its tasks (ids are reused) ($($fb.code) $($nb.code))" ($fb.code -eq 0 -and $nb.code -eq 1 -and -not (Test-Path (Join-Path $k '.state/local-bench/t1/small-b')))
$nm = Invoke-TestScript $D local bench report -Set nope -Model small-a
Expect "bench report: a set never scored says so, exit 1 ($($nm.code))" ($nm.code -eq 1 -and $nm.out -match 'no score for nope/small-a')

# runOn coverage, evidence, -Add on a set of their own (owner 2026-11-27: tuning from data, every unit 3+ real tasks)
$null = Invoke-TestScript $D local bench build -Set cov -Roles 'checky:close,watchy,datay' -N 9 -Since 2000-01-01 -Transcripts $tr
$cd = Join-Path $k '.state/local-bench/cov'; $cvIds = @(Get-ChildItem (Join-Path $cd 'tasks') -Directory).Name
$cv = Invoke-TestScript $D local bench coverage -Set cov -Json; $cvj = try { $cv.out | ConvertFrom-Json } catch { $null }; $cvRow = { param($u) @($cvj.units | Where-Object unit -eq $u)[0] }
Expect "bench coverage: tasks per run unit, under 3 = gap, every unit listed ($($cv.code): close $((& $cvRow 'checky:close').total), sweep $((& $cvRow 'watchy@sweep').total), check $((& $cvRow 'datay@check').total))" ($cv.code -eq 0 -and (& $cvRow 'checky:close').total -eq 5 -and -not (& $cvRow 'checky:close').gap -and (& $cvRow 'watchy@sweep').total -eq 2 -and (& $cvRow 'watchy@sweep').gap -and (& $cvRow 'datay@check').total -eq 1 -and $cvj.units.Count -ge 100 -and $cvj.tasks -eq 8)
# a score: close tasks accepted but one, the rest accepted; an infra fail is no evidence
$scObj = [ordered]@{}; $cvI = 0; foreach ($cvId in $cvIds) { $cvM = Get-Content (Join-Path $cd "tasks/$cvId/meta.json") -Raw | ConvertFrom-Json; $cvI++
  $scObj[$cvId] = @{ id = $cvId; role = $cvM.role; tier = 'haiku'; rc = $(if ($cvM.role -like 'datay*') { '1' } else { '0' }); sec = 1; strict = $true; repairable = $true; lenient = $true; toolText = $false; schema = $true; outcome = $true; accepted = -not ($cvM.label -eq 'close:T2'); why = '' } }
New-Item -ItemType Directory -Force (Join-Path $cd 'm1') | Out-Null; & $J $scObj (Join-Path $cd 'm1/score.json')
& $J @{ models = @{ mode = 'mixed'; runOn = @{ 'checky:close' = 'local'; 'watchy@sweep' = 'cloud' }; local = @{ baseUrl = "http://127.0.0.1:$port"; defaultModel = 'small-a' } } } $cfgFile
$ev = Invoke-TestScript $D local bench report -Model m1 -Set cov -WriteRunonEvidence; $evc = (Get-Content $cfgFile -Raw | ConvertFrom-Json -AsHashtable).models
$evClose = $evc.runOn['checky:close']; $evSweep = $evc.runOn['watchy@sweep']
Expect "bench report -WriteRunonEvidence: accepted / n per unit into models.runOn.<unit>.evidence.<set>, settings unchanged, an infra fail no evidence ($($ev.code): close $($evClose.evidence.cov.accepted)/$($evClose.evidence.cov.n))" ($ev.code -eq 0 -and $evClose.on -eq 'local' -and $evClose.evidence.cov.model -eq 'm1' -and $evClose.evidence.cov.accepted -eq 4 -and $evClose.evidence.cov.n -eq 5 -and $evClose.evidence.cov.rate -eq 80 -and $evSweep.on -eq 'cloud' -and $evSweep.evidence.cov.n -eq 2 -and -not $evc.runOn.ContainsKey('datay@check') -and $evc.local.defaultModel -eq 'small-a')
# build -Add tops a unit up from transcripts the set lacks and keeps every task; nothing new for a unit: no history
Add-Fixture $ah 'agent-w3' watchy 'nightly sweep 3' 'Kind sweep, watch W3.' '2 errors' $null "``````json`n{`"status`": `"bug`", `"bugs`": 2}`n``````"
$ad = Invoke-TestScript $D local bench build -Set cov -Roles 'watchy@sweep,datay@check' -N 3 -Add -Since 2000-01-01 -Transcripts $tr
$after = @(Get-ChildItem (Join-Path $cd 'tasks') -Directory).Name
Expect "bench build -Add: one new watchy@sweep task (the third), old tasks kept, datay@check no history ($($ad.code): $($ad.out.Trim()))" ($ad.code -eq 0 -and $after.Count -eq $cvIds.Count + 1 -and @($cvIds | Where-Object { $_ -notin $after }).Count -eq 0 -and $ad.out -match 'watchy@sweep 1' -and $ad.out -match 'no history: datay@check')
Stop-Job $srv -ErrorAction SilentlyContinue; Remove-Job $srv -Force -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
