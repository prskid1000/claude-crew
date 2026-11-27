#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/local-bench.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/local-bench.tests.ps1: crafty.ps1 local bench (adapters/localbench.py) on a tiny fixture, no model: build from recorded
# transcripts (a step's StructuredOutput, an ad hoc agent's final JSON, a null field), a rebuild needs -Force; run through the
# launcher (fake server + fake clients: no tools, the bench User-Agent, codex 'ARGS=exec|.*--sandbox|read-only|-s*$'), resume, -Ids re-run, a timeout ends the
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
foreach ($cn in 1..4) { Add-Fixture $wf "agent-c$cn" checky "close:T$cn" "STEP (checky, role lead): publish T$cn." "T$cn report: https://docs.example/d/$cn 3/3 pass" @{ ok = $true; output = "T$cn published: https://docs.example/d/$cn 3/3 pass" } }
Add-Fixture $ah 'agent-w1' watchy 'nightly sweep' 'Kind sweep, watch W1.' '0 errors' $null "Clean.`n``````json`n{`"status`": `"clean`", `"bugs`": 0}`n``````"
Add-Fixture $ah 'agent-d1' datay 'data check' 'Kind check, data D1.' '3 rows' $null "Done.`n``````json`n{`"status`": `"clean`", `"rows`": 3, `"mr`": null}`n``````"
$sys = $sys -replace 'haiku', 'sonnet'; Add-Fixture $ah 'agent-w2' watchy 'nightly sweep 2' 'Kind sweep, watch W2.' '1 error' $null "``````json`n{`"status`": `"bug`", `"bugs`": 1}`n``````"

$bd = Invoke-TestScript $D local bench build -Set t1 -Roles 'checky:close,watchy,datay,vidy' -Since 2000-01-01 -Transcripts $tr
$sd = Join-Path $k '.state/local-bench/t1/tasks'
$byLabel = @{}; foreach ($td in @(Get-ChildItem $sd -Directory -ErrorAction SilentlyContinue)) { $mt = Get-Content (Join-Path $td.FullName 'meta.json') -Raw | ConvertFrom-Json; $byLabel[$mt.label] = $mt }
$c1 = $byLabel['close:T1']; $cj = try { Get-Content (Join-Path $sd "$($c1.id)/cloud.json") -Raw | ConvertFrom-Json } catch { $null }
$dsch = try { Get-Content (Join-Path $sd "$($byLabel['data check'].id)/schema.json") -Raw | ConvertFrom-Json } catch { $null }
Expect "bench build: one task per recorded step, the cloud answer (StructuredOutput / final JSON), its tier, a prompt hash, a missing role named ($($bd.code): $($bd.out.Trim()))" ($bd.code -eq 0 -and $byLabel.Count -eq 7 -and $cj.ok -eq $true -and $byLabel['nightly sweep 2'].tier -eq 'sonnet' -and $c1.tier -eq 'haiku' -and $c1.promptSha -and $bd.out -match 'no samples: vidy' -and (Get-Content (Join-Path $sd "$($c1.id)/prompt.md") -Raw) -match '(?s)never call a tool.*run close:T1.*3/3 pass.*JSON SCHEMA')
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
  elseif ($in -match 'watch W1') { '{"status": "clean", "bugs": 0}' }
  elseif ($in -match 'data D1') { '```json' + "`n" + '{"status": "clean", "rows": 3, "mr": null}' + "`n" + '```' }
  else { '<tool_call><function=Read></function></tool_call>' }
@{ result = $r; num_turns = 1 } | ConvertTo-Json -Compress
'@).Replace('PIDFILE', $pidFile) -Encoding utf8
$fakeCodex = Join-Path (Kd) 'fakecodex.ps1'; Set-Content $fakeCodex "[Console]::Error.WriteLine(`"ARGS=`$(`$args -join '|')`"); '{`"status`": `"clean`", `"bugs`": 0}'" -Encoding utf8
& $J @{ models = @{ local = @{ baseUrl = "http://127.0.0.1:$port"; defaultModel = 'small-a'; needGB = 0; commands = @{ claude = @($fake); codex = @($fakeCodex) } } } } $cfgFile
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
Expect "bench score: right answers accepted (same ok + URL + count; same short fields; a null field)" ((& $g 'close:T1').accepted -and (& $g 'nightly sweep').accepted -and (& $g 'data check').outcome -and -not (& $g 'data check').strict -and (& $g 'data check').repairable)
Expect "bench score: a flipped ok, a dropped count and a tool call written as text rejected ($((& $g 'close:T2').why) / $((& $g 'close:T3').why) / $((& $g 'nightly sweep 2').why))" (-not (& $g 'close:T2').accepted -and (& $g 'close:T2').why -match 'ok False vs True' -and -not (& $g 'close:T3').accepted -and -not (& $g 'close:T3').strict -and (& $g 'close:T3').why -match 'missing .*3/3' -and (& $g 'nightly sweep 2').why -eq 'tool-call-text')
$rp = Invoke-TestScript $D local bench report -Set t1 -Model small-a -Json
$rj = try { $rp.out | ConvertFrom-Json } catch { @() }
$rc1 = @($rj | Where-Object role -eq 'checky:close')[0]; $rw = @($rj | Where-Object role -eq 'watchy')[0]
Expect "bench report: accept rate, p50 and the cloud tier per role ($($rp.out.Substring(0, [math]::Min(220, $rp.out.Length))))" ($rp.code -eq 0 -and $rc1.rate -eq 25 -and $rc1.timeouts -eq 1 -and $rc1.tier -eq 'haiku' -and $rw.rate -eq 50 -and $rw.toolText -eq 1 -and $null -ne $rc1.p50)

$ix = Invoke-TestScript $D local bench run -Set t1 -Model other-1 -Ids $w1; $null = Invoke-TestScript $D local bench score -Set t1 -Model other-1
$ir = try { (Invoke-TestScript $D local bench report -Set t1 -Model other-1 -Json).out | ConvertFrom-Json } catch { @() }
$ir2 = Invoke-TestScript $D local bench run -Set t1 -Model other-1 -Ids $w1
Expect "bench run: a launcher refusal (model not served) is infra: out of the rate, run again ($($ix.out.Trim()))" ($ix.out -match "run ${w1}: rc 1" -and @($ir | Where-Object role -eq 'watchy')[0].infra -eq 1 -and $null -eq @($ir | Where-Object role -eq 'watchy')[0].rate -and $ir2.out -match "run ${w1}: rc 1")
$cx = Invoke-TestScript $D local bench run -Set t1 -Model small-a -Ids $w1 -Runner codex
$cer = Get-Content (Join-Path $md "runs/$w1.err") -Raw -ErrorAction SilentlyContinue
Expect "bench run -Runner codex: codex exec, read-only sandbox, the prompt on stdin ($("$cer".Trim()))" ($cx.out -match "run ${w1}: rc 0" -and "$cer".Trim() -match 'ARGS=exec\|.*--sandbox\|read-only\|-$')

$pt = Join-Path (Kd) 'parse.py'
Set-Content $pt "import sys; sys.path.insert(0, r'$k/skills/crafty/adapters'); import localbench as b`nr = b.parse_reply('{`"ok`": true, `"output`": `"a\nb`"}'); f = b.parse_reply('``````json\n{`"ok`": false}\n``````'); p = b.parse_reply('Here: {`"ok`": true, `"output`": `"x`"} done'); t = b.parse_reply('{`"name`": `"PowerShell`", `"arguments`": {}}')`nprint(r['strict'] is None, isinstance(r['repairable'], dict), f['strict'] is None, f['repairable'] == {'ok': False}, p['lenient'] == {'ok': True, 'output': 'x'}, t['toolText'])" -Encoding utf8
$po = "$(& (Get-Command python).Source -X utf8 $pt 2>&1)".Trim()
Expect "bench parse: a raw newline in a string or a code fence is repairable, not strict; prose around an object: lenient; a PowerShell tool call as text named ($po)" ($po -eq 'True True True True True True')

$m2 = Join-Path $k '.state/local-bench/t1/small-b'; Copy-Item $md $m2 -Recurse
$s2 = Get-Content (Join-Path $m2 'score.json') -Raw | ConvertFrom-Json; $s2.($c1.id).accepted = $false; $s2 | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $m2 'score.json') -Encoding utf8
$df = Invoke-TestScript $D local bench diff -Set t1 -Model small-a -Against small-b
Expect "bench diff: per role rates side by side and the ids that flip ($($df.out.Trim() -replace '\s+', ' '))" ($df.code -eq 0 -and $df.out -match 'checky:close\s+25% \S+\s+0%' -and $df.out -match "flip $($c1.id): small-a accepted, small-b rejected")
$nm = Invoke-TestScript $D local bench report -Set nope -Model small-a
Expect "bench report: a set never scored says so, exit 1 ($($nm.code))" ($nm.code -eq 1 -and $nm.out -match 'no score for nope/small-a')

Stop-Job $srv -ErrorAction SilentlyContinue; Remove-Job $srv -Force -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
