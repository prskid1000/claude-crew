#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/local-bench.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/local-bench.tests.ps1: crafty.ps1 local bench (localbench.py) on a tiny fixture, no model: build from recorded transcripts
# (a workflow step's StructuredOutput, an ad hoc agent's final JSON), run through the launcher (fake server + fake client, no
# tools, the bench User-Agent), resume / -Ids re-run, score (strict, repairable, tool call as text), report per role, diff.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/local-model.ps1', 'skills/crafty/adapters/video.ps1', 'skills/crafty/adapters/localbench.py')
$k = New-TestKit lb; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $cfgFile = Join-Path $k 'skills/crafty/kit.local.json'

# fixture transcripts: one checky close step (workflow), one ad hoc watchy run
$tr = Join-Path (Kd) 'projects'; $wf = Join-Path $tr 's1/subagents/workflows/wf_1'; $ah = Join-Path $tr 's1/subagents'; New-Item -ItemType Directory -Force $wf | Out-Null
$ln = { param($o) $o | ConvertTo-Json -Depth 12 -Compress }
$sys = 'You are powered by the model named Haiku. The exact model ID is claude-haiku-5-5.'
@((& $ln @{ type = 'user'; message = @{ content = "STEP (checky, role lead): publish T1. $sys" } }),
  (& $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'u1'; name = 'Bash'; input = @{ command = 'pokey.ps1 finalize -Code T1' } }) } }),
  (& $ln @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'u1'; content = 'T1 report: https://docs.example/d/1 3/3 pass' }) } }),
  (& $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'u2'; name = 'StructuredOutput'; input = @{ ok = $true; output = 'T1 published: https://docs.example/d/1 3/3 pass' } }) } })) | Set-Content (Join-Path $wf 'agent-a1.jsonl') -Encoding utf8
@{ agentType = 'checky'; description = 'close:T1' } | ConvertTo-Json | Set-Content (Join-Path $wf 'agent-a1.meta.json') -Encoding utf8
@((& $ln @{ type = 'user'; message = @{ content = "Kind sweep. $($sys -replace 'haiku', 'sonnet')" } }),
  (& $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'w1'; name = 'Bash'; input = @{ command = 'logs query' } }) } }),
  (& $ln @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'w1'; content = '0 errors' }) } }),
  (& $ln @{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Clean.`n``````json`n{`"status`": `"clean`", `"bugs`": 0}`n``````" }) } })) | Set-Content (Join-Path $ah 'agent-b1.jsonl') -Encoding utf8
@{ agentType = 'watchy'; description = 'nightly sweep' } | ConvertTo-Json | Set-Content (Join-Path $ah 'agent-b1.meta.json') -Encoding utf8

$bd = Invoke-TestScript $D local bench build -Set t1 -Roles 'checky:close,watchy,vidy' -Since 2000-01-01 -Transcripts $tr
$sd = Join-Path $k '.state/local-bench/t1/tasks'
$cj = try { Get-Content (Join-Path $sd 'checky-close-1/cloud.json') -Raw | ConvertFrom-Json } catch { $null }
$mj = try { Get-Content (Join-Path $sd 'watchy-1/meta.json') -Raw | ConvertFrom-Json } catch { $null }
Expect "bench build: one task per recorded step, the cloud answer (StructuredOutput / final JSON), its tier, a missing role named ($($bd.code): $($bd.out.Trim()))" ($bd.code -eq 0 -and $cj.ok -eq $true -and $mj.tier -eq 'sonnet' -and $mj.role -eq 'watchy' -and $bd.out -match 'no samples: vidy' -and (Get-Content (Join-Path $sd 'checky-close-1/prompt.md') -Raw) -match '(?s)never call a tool.*pokey\.ps1 finalize.*3/3 pass.*JSON SCHEMA')

# a fake server (GET /v1/models: small-a) and a fake claude that answers the close step right, prints its args and User-Agent header
$tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port; $tl.Stop()
$srv = Start-Job { param($p) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$p/"); $hl.Start(); $end = (Get-Date).AddMinutes(3)
  while ((Get-Date) -lt $end) { $ct = $hl.GetContextAsync(); while (-not $ct.Wait(500)) { if ((Get-Date) -ge $end) { break } }; if (-not $ct.IsCompleted) { break }
    $by = [Text.Encoding]::UTF8.GetBytes('{"object":"list","data":[{"id":"small-a"}]}'); $rs = $ct.Result.Response; $rs.ContentType = 'application/json'; $rs.OutputStream.Write($by, 0, $by.Length); $rs.Close() } } -ArgumentList $port
$fake = Join-Path (Kd) 'fakeclaude.ps1'
Set-Content $fake @'
$in = @($input) -join "`n"
$r = if ($in -match 'publish T1') { '{"ok": true, "output": "T1 report https://docs.example/d/1 3/3 pass"}' } else { '<tool_call><function=Read></function></tool_call>' }
[Console]::Error.WriteLine("ARGS=$($args -join '|') UA=$env:ANTHROPIC_CUSTOM_HEADERS")
@{ result = $r; num_turns = 1 } | ConvertTo-Json -Compress
'@ -Encoding utf8
& $J @{ models = @{ local = @{ baseUrl = "http://127.0.0.1:$port"; defaultModel = 'small-a'; needGB = 0; commands = @{ claude = @($fake) } } } } $cfgFile
for ($wi = 0; $wi -lt 60; $wi++) { try { $tc = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $tc.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }

$md = Join-Path $k '.state/local-bench/t1/small-a'
$r1 = Invoke-TestScript $D local bench run -Set t1 -Model small-a -TimeoutSec 60
$er = Get-Content (Join-Path $md 'runs/checky-close-1.err') -Raw -ErrorAction SilentlyContinue
Expect "bench run: each task through local claude, no tools, no MCP, no session, the neutral User-Agent ($($r1.code): $($r1.out.Trim()) · $("$er".Trim()))" ($r1.code -eq 0 -and $r1.out -match 'run checky-close-1: rc 0' -and $r1.out -match 'run watchy-1: rc 0' -and "$er" -match 'ARGS=-p\|--output-format\|json\|--tools\|\|--strict-mcp-config\|--no-session-persistence' -and "$er" -match 'UA=User-Agent: kit-local-bench')
$r2 = Invoke-TestScript $D local bench run -Set t1 -Model small-a
$r3 = Invoke-TestScript $D local bench run -Set t1 -Model small-a -Ids watchy-1
Expect "bench run: done ids skipped (resume), -Ids re-runs only that id ($($r2.out.Trim()) / $($r3.out.Trim()))" ($r2.code -eq 0 -and $r2.out -notmatch 'run ' -and $r3.out -match 'run watchy-1' -and $r3.out -notmatch 'checky-close-1')

$s1 = Invoke-TestScript $D local bench score -Set t1 -Model small-a
$sc = Get-Content (Join-Path $md 'score.json') -Raw | ConvertFrom-Json
Expect "bench score: the right step accepted (same ok, URL, count), the tool call written as text named ($($s1.out.Trim()))" ($s1.code -eq 0 -and $sc.'checky-close-1'.accepted -and -not $sc.'watchy-1'.accepted -and $sc.'watchy-1'.why -eq 'tool-call-text' -and $sc.'watchy-1'.toolText)
$rp = Invoke-TestScript $D local bench report -Set t1 -Model small-a -Json
$rj = try { $rp.out | ConvertFrom-Json } catch { @() }
$rc1 = @($rj | Where-Object role -eq 'checky:close')[0]; $rw = @($rj | Where-Object role -eq 'watchy')[0]
Expect "bench report: accept rate, p50 and the cloud tier per role ($($rp.out.Substring(0, [math]::Min(200, $rp.out.Length))))" ($rp.code -eq 0 -and $rc1.rate -eq 100 -and $rc1.tier -eq 'haiku' -and $rw.rate -eq 0 -and $rw.toolText -eq 1 -and $null -ne $rc1.p50)

$pt = Join-Path (Kd) 'parse.py'
Set-Content $pt "import sys; sys.path.insert(0, r'$k/skills/crafty/adapters'); import localbench as b`nr = b.parse_reply('{`"ok`": true, `"output`": `"a\nb`"}'); f = b.parse_reply('``````json\n{`"ok`": false}\n``````'); p = b.parse_reply('Here: {`"ok`": true, `"output`": `"x`"} done')`nprint(r['strict'] is None, isinstance(r['repairable'], dict), f['strict'] is None, f['repairable'] == {'ok': False}, p['lenient'] == {'ok': True, 'output': 'x'})" -Encoding utf8
$po = "$(& (Get-Command python).Source -X utf8 $pt 2>&1)".Trim()
Expect "bench parse: a raw newline in a string or a code fence is repairable, not strict; prose around an object: lenient ($po)" ($po -eq 'True True True True True')

$m2 = Join-Path $k '.state/local-bench/t1/small-b'; Copy-Item $md $m2 -Recurse
$s2 = Get-Content (Join-Path $m2 'score.json') -Raw | ConvertFrom-Json; $s2.'checky-close-1'.accepted = $false; $s2 | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $m2 'score.json') -Encoding utf8
$df = Invoke-TestScript $D local bench diff -Set t1 -Model small-a -Against small-b
Expect "bench diff: per role rates side by side and the ids that flip ($($df.out.Trim() -replace '\s+', ' '))" ($df.code -eq 0 -and $df.out -match 'checky:close\s+100% \S+\s+0%' -and $df.out -match 'flip checky-close-1: small-a accepted, small-b rejected')
$nm = Invoke-TestScript $D local bench report -Set nope -Model small-a
Expect "bench report: a set never scored says so, exit 1 ($($nm.code))" ($nm.code -eq 1 -and $nm.out -match 'no score for nope/small-a')

Stop-Job $srv -ErrorAction SilentlyContinue; Remove-Job $srv -Force -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
