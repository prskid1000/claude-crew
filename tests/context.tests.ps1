#Requires -Version 7
<#
tests/context.tests.ps1: adapters/usage.ps1 context offline: what fills each agent's context per model call (Claude, Codex, Antigravity
transcripts: categories, start load, peak, carried, compactions, handoffs, waste signals), the CLIs' tokens and spend, usage -Context, the
supervise WATCH / ACT rules and the learned start norm, the Runs band cell, the Trends rows and the per-role table, the info popover.
Usage: pwsh -NoProfile -File tests/context.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit ctx; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $fx = New-Item -ItemType Directory -Force (Join-Path (Kd) 'fx')
$t0 = (Get-Date).Date.AddHours(9).ToUniversalTime(); $iso = { param($s) $t0.AddSeconds($s).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
$q = { param($s) $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n') }   # a JSON string body
# Claude: prompt (a resume brief), call 1 (Read a code file), its result, a skill load, call 2 (a gated build), a 16 KB log, the same
# file read twice more, an instructions attachment, a compaction marker + summary, call 3 after it
$cu = { param($id, [int]$ctx, [int]$out, [string]$c, [int]$s) "{`"type`":`"assistant`",`"timestamp`":`"$(& $iso $s)`",`"message`":{`"model`":`"claude-sonnet-5-5`",`"id`":`"$id`",`"role`":`"assistant`",`"content`":[$c],`"usage`":{`"input_tokens`":10,`"cache_creation_input_tokens`":0,`"cache_read_input_tokens`":$($ctx - 10),`"output_tokens`":$out}}}" }
$tu = { param($id, $name, $in) "{`"type`":`"tool_use`",`"id`":`"$id`",`"name`":`"$name`",`"input`":$in}" }
$tr = { param($id, [int]$bytes, [int]$s) "{`"type`":`"user`",`"timestamp`":`"$(& $iso $s)`",`"message`":{`"role`":`"user`",`"content`":[{`"tool_use_id`":`"$id`",`"type`":`"tool_result`",`"content`":`"$('a' * $bytes)`"}]},`"toolUseResult`":{`"stdout`":`"$('a' * $bytes)`"}}" }
$rd = '{"file_path":"/w/app/src/Main.java"}'
$cl = @("{`"type`":`"user`",`"timestamp`":`"$(& $iso 0)`",`"message`":{`"role`":`"user`",`"content`":`"$(& $q "Resume from /w/notes/resume-r1.md $('b' * 3992)")`"}}",
  (& $cu 'msg_1' 20000 100 (& $tu 't1' 'Read' $rd) 1), (& $tr 't1' 4000 2),
  "{`"type`":`"user`",`"isMeta`":true,`"timestamp`":`"$(& $iso 3)`",`"message`":{`"role`":`"user`",`"content`":[{`"type`":`"text`",`"text`":`"Base directory for this skill: /w/kit/.claude/skills/x $('c' * 7950)`"}]}}",
  (& $cu 'msg_2' 24000 50 (& $tu 't2' 'Bash' '{"command":"pwsh /w/kit/.claude/skills/crafty/crafty.ps1 check -Dir /w/app"}') 4), (& $tr 't2' 16000 5),
  (& $cu 'msg_3' 29000 20 "$(& $tu 't3' 'Read' $rd),$(& $tu 't4' 'Read' $rd)" 6),
  "{`"type`":`"user`",`"timestamp`":`"$(& $iso 7)`",`"message`":{`"role`":`"user`",`"content`":[{`"tool_use_id`":`"t3`",`"type`":`"tool_result`",`"content`":`"$('a' * 4000)`"},{`"tool_use_id`":`"t4`",`"type`":`"tool_result`",`"content`":`"$('a' * 4000)`"}]},`"toolUseResult`":{`"x`":1}}",
  "{`"type`":`"attachment`",`"timestamp`":`"$(& $iso 8)`",`"attachment`":{`"type`":`"nested_memory`",`"path`":`"/w/app/CLAUDE.md`",`"content`":`"$('d' * 2000)`"}}",
  "{`"type`":`"system`",`"subtype`":`"compact_boundary`",`"timestamp`":`"$(& $iso 9)`"}",
  "{`"type`":`"user`",`"isCompactSummary`":true,`"timestamp`":`"$(& $iso 10)`",`"message`":{`"role`":`"user`",`"content`":`"$('s' * 4000)`"}}",
  (& $cu 'msg_4' 21000 30 '{"type":"text","text":"done"}' 11)) -join "`n"
[IO.File]::WriteAllText("$fx/claude.jsonl", $cl + "`n")
# Codex: developer instructions, the task, a shell read + its output, token counts (one repeated), a compaction, a build + a 14 KB log
$cxl = { param($s, [string]$ty, [string]$pl) "{`"timestamp`":`"$(& $iso $s)`",`"type`":`"$ty`",`"payload`":$pl}" }
$tc = { param([int]$in, [int]$out, [int]$tot) "{`"type`":`"token_count`",`"info`":{`"total_token_usage`":{`"input_tokens`":$in,`"cached_input_tokens`":$([int]($in * 0.8)),`"output_tokens`":$out,`"total_tokens`":$tot},`"last_token_usage`":{`"input_tokens`":$in,`"cached_input_tokens`":$([int]($in * 0.8)),`"output_tokens`":$out,`"total_tokens`":$tot}}}" }
$co = @((& $cxl 0 'session_meta' '{"id":"s1","cli_version":"1.0"}'), (& $cxl 0 'turn_context' '{"model":"gpt-6-mini","cwd":"/w/app"}'),
  (& $cxl 1 'response_item' "{`"type`":`"message`",`"role`":`"developer`",`"content`":[{`"type`":`"input_text`",`"text`":`"$('k' * 8000)`"}]}"),
  (& $cxl 2 'response_item' "{`"type`":`"message`",`"role`":`"user`",`"content`":[{`"type`":`"input_text`",`"text`":`"fix the bug $('t' * 1000)`"}]}"),
  (& $cxl 3 'response_item' '{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"cat src/app.py\"}","call_id":"c1"}'), (& $cxl 4 'event_msg' (& $tc 12000 200 12200)),
  (& $cxl 5 'response_item' "{`"type`":`"function_call_output`",`"call_id`":`"c1`",`"output`":`"$('o' * 6000)`"}"), (& $cxl 6 'event_msg' (& $tc 15000 100 27300)), (& $cxl 6 'event_msg' (& $tc 15000 100 27300)),
  (& $cxl 7 'compacted' '{"message":"summary"}'), (& $cxl 8 'response_item' '{"type":"function_call","name":"shell_command","arguments":"{\"command\":[\"pytest\",\"-q\"]}","call_id":"c2"}'),
  (& $cxl 9 'event_msg' (& $tc 6000 50 33350)), (& $cxl 10 'response_item' "{`"type`":`"function_call_output`",`"call_id`":`"c2`",`"output`":`"$('p' * 14000)`"}"), (& $cxl 11 'event_msg' (& $tc 9500 40 42890))) -join "`n"
$cxd = New-Item -ItemType Directory -Force "$fx/codex/2026/01/02"; [IO.File]::WriteAllText("$cxd/rollout-2026-01-02-c1.jsonl", $co + "`n")
# Antigravity: the task with a model switch, a call (view_file + run_command), their steps, a checkpoint, a second call
$ag = { param([int]$i, [string]$ty, [string]$rest, [string]$src = 'MODEL') "{`"step_index`":$i,`"source`":`"$src`",`"type`":`"$ty`",`"status`":`"DONE`",`"created_at`":`"$(& $iso $i)`"$rest}" }
$an = @((& $ag 0 'USER_INPUT' ",`"content`":`"<USER_REQUEST>add the screen</USER_REQUEST> The user changed setting ``Model Selection`` from None to Gemini 3.5 Flash (Medium).`"" 'USER_EXPLICIT'),
  (& $ag 1 'PLANNER_RESPONSE' ',"input_tokens":9000,"cache_read_tokens":1000,"output_tokens":300,"tool_calls":[{"name":"view_file","args":{"AbsolutePath":"\"/w/app/src/screen.tsx\""}},{"name":"run_command","args":{"CommandLine":"\"mvn test\""}}]'),
  (& $ag 2 'VIEW_FILE' ",`"content`":`"File Path: ``file:///w/app/src/screen.tsx`` $('v' * 8000)`""), (& $ag 3 'RUN_COMMAND' ",`"content`":`"$('m' * 16000)`""),
  (& $ag 4 'CHECKPOINT' ",`"content`":`"# Resuming from a compaction $('r' * 2000)`"" 'SYSTEM'), (& $ag 5 'PLANNER_RESPONSE' ',"input_tokens":2000,"cache_read_tokens":4000,"output_tokens":100')) -join "`n"
$agd = New-Item -ItemType Directory -Force "$fx/ag/b1/.system_generated/logs"; [IO.File]::WriteAllText("$agd/transcript.jsonl", $an + "`n")

$r = Invoke-PsTest ctx-parse @'
$null = . $args[0] 6>$null; $o = foreach ($f in $args[1..3]) { $l = [ref][long]1GB; $u = Update-KitContextFile $f (Update-KitUsageFile $f $null $l) $l; $c = $u.cx
  "$($u.model)|$($u.in)/$($u.out)/$($u.cr)|$($c.n)|$($c.s0)|$($c.pk)|$($c.cmp)|$($c.ho)|$(@($c.add) -join ',')|$(@($c.car | ForEach-Object { [math]::Round($_ / 1000) }) -join ',')|$(@($c.w) -join ',')|$(@($c.rmax) -join ':')|$(@($u.tm | ForEach-Object { [int]$_ }) -join '/')" }
$o; $s = Read-KitSpendLines @([IO.File]::ReadAllLines($args[3])); "spend $($s.spend)"; "budget $((Get-KitBudget -Tool antigravity).budget) $((Get-KitBudget -Model 'gemini-3.5-flash').row)"
'@ @($O, "$fx/claude.jsonl", "$cxd/rollout-2026-01-02-c1.jsonl", "$agd/transcript.jsonl")
$c1 = "$($r[0])" -split '\|'; $c2 = "$($r[1])" -split '\|'; $c3 = "$($r[2])" -split '\|'
# Claude: start 20000 - prompt 1000 = 19000 kit; skill 2000 + memory 500 kit; code 3 x 1000; the gated build's 16 KB = build output, a pasted log
Expect "context claude: 4 calls, start 20k, peak 29k, a compaction (marker; the drop after it is not counted twice), resumed from a handoff ($($r[0]))" ($c1[2] -eq '4' -and $c1[3] -eq '20000' -and $c1[4] -eq '29000' -and $c1[5] -eq '1' -and $c1[6] -eq '1')
Expect "context claude: added per category: kit 19000 + skill 2000 + memory 500, task 1000, code 3000, build 4000, model 200 + summary 1000 ($($c1[7]))" ($c1[7] -match '^21[45]\d\d,10\d\d,29\d\d,0,39\d\d,0,0,1200$')
Expect "context claude: waste = the file re-read 2x (2 rereads), no result over 8k, one build log over 3k pasted; most re-read Main.java 3x ($($c1[9]) $($c1[10]))" ($c1[9] -match '^2,\d+,0,0,1,\d+$' -and $c1[10] -eq '3:/w/app/src/main.java')
Expect "context claude: carried = the mix scaled to each call's size (4 calls: 20k + 24k + 29k + 21k = 94k) ($($c1[8]))" (([int[]]($c1[8] -split ',') | Measure-Object -Sum).Sum -in 93..95)
# Codex: 4 counted calls (a repeated count skipped), developer text = kit, task, cat = code, pytest = build; compaction marker; tokens and model wired
Expect "context codex: tokens in 1900 out 40 cache read 7600 (cumulative), model from turn_context, 4 calls, start 12k, peak 15k, a compaction ($($r[1]))" ($c2[0] -eq 'gpt-6-mini' -and $c2[1] -eq '1900/40/7600' -and $c2[2] -eq '4' -and $c2[3] -eq '12000' -and $c2[4] -eq '15000' -and $c2[5] -eq '1')
Expect "context codex: added kit (start), task 250, code 1500, build 3500 (a log over 3k), model 390 ($($c2[7]) w $($c2[9]))" ($c2[7] -match '^\d+,2\d\d,14\d\d,0,34\d\d,0,0,390$' -and $c2[9] -match '^0,0,0,0,1,\d+$')
Expect "context antigravity: model from the switch line, tokens in 11000 out 400 cache read 5000, 2 calls, start 10k, a checkpoint = a compaction, view_file = code, mvn = build ($($r[2]))" ($c3[0] -eq 'gemini-3.5-flash' -and $c3[1] -eq '11000/400/5000' -and $c3[2] -eq '2' -and $c3[3] -eq '10000' -and $c3[5] -eq '1' -and $c3[7] -match '^\d+,\d+,20\d\d,0,39\d\d,0,0,\d+$')
Expect "time split: Codex and Antigravity record model and tool time (was Claude-only) ($($c2[11]) $($c3[11]))" ([int]($c2[11] -split '/')[0] -gt 0 -and [int]($c3[11] -split '/')[0] -gt 0)
Expect "spend: an Antigravity agent's last call = input + cache read + output (6100); its budget without a window = 800k (antigravity row) ($($r[3]) $($r[4]))" ($r[3] -eq 'spend 6100' -and $r[4] -eq 'budget 800000 antigravity')
# budget (owner 2026-11-23): handoff = whichever first, handoffAt x the tool's cap or the kit's role budget; design window = min(200k, the cap)
$bu = Invoke-PsTest ctx-budget @'
$null = . $args[0] 6>$null; $o = { param($b) "$($b.handoff)|$($b.design)|$($b.instrCap)|$($b.capBy)" }
& $o (Get-KitBudget -Tool local -Window 1000000 -Role devy); & $o (Get-KitBudget -Tool local -Window 200000); & $o (Get-KitBudget -Tool local -Window 32000)
$__cfg = [pscustomobject]@{ budget = [pscustomobject]@{ agentCap = [pscustomobject]@{ devy = 400000 } } }; & $o (Get-KitBudget -Tool local -Window 1000000 -Role devy); & $o (Get-KitBudget -Tool local -Window 1000000 -Role checky)
$__cfg = $null; $env:OLLAMA_CONTEXT_LENGTH = '65536'; & $o (Get-KitBudget -Tool local)
$x = [IO.Path]::Combine($args[1], 'big.jsonl'); [IO.File]::WriteAllText($x, '{"type":"user","message":{"content":"' + ('w' * 40000) + '"}}' + "`n"); "est $((Get-KitSpend $x).spend) $((Get-KitSpend $x).estimated)"
# the beat: a 15k start (harness + kit) at a 32k window is no handoff (kit start 12k counted, cap floor 15k); a 5k kit doc read on top is
$tr = [IO.Path]::Combine($args[1], 'ki.jsonl'); [IO.File]::WriteAllText($tr, '{"type":"assistant","timestamp":"2026-01-02T09:00:00Z","message":{"id":"m1","usage":{"input_tokens":15000,"output_tokens":10},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/k/.claude/skills/x/SKILL.md"}}]}}' + "`n")
$me = [pscustomobject]@{ agent = 'devy-x'; run = 'r1'; budget = 32000 }; $cc = [IO.Path]::Combine($args[1], 's1.cx'); "ki $(Get-KitInstrHandoff $me 's1' $tr $cc)"
[IO.File]::AppendAllText($tr, '{"type":"user","timestamp":"2026-01-02T09:00:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"' + ('x' * 20000) + '"}]}}' + "`n" + '{"type":"assistant","timestamp":"2026-01-02T09:00:02Z","message":{"id":"m2","usage":{"input_tokens":20000,"output_tokens":10},"content":[]}}' + "`n")
"ki1 $(Get-KitInstrHandoff $me 's1' $tr $cc)"; $me.budget = 200000; "ki2 $(Get-KitInstrHandoff $me 's1' $tr $cc)|$(Test-Path $cc)"
$__cfg = [pscustomobject]@{ budget = [pscustomobject]@{ agentCap = [pscustomobject]@{ default = 300000; devy = 0 } } }; & $o (Get-KitBudget -Tool local -Window 1000000 -Role devy); & $o (Get-KitBudget -Tool local -Window 1000000 -Role checky)
$__cfg = $null; $env:OLLAMA_CONTEXT_LENGTH = ''; $env:LLAMA_ARG_CTX_SIZE = '16384'; & $o (Get-KitBudget -Tool local)
'@ @($O, (Kd))
Expect "board beat: a 15k start at a 32k window is no handoff (harness not counted); a 5k kit doc read on top -> HANDOFF over the 15k cap; at 200k (cap 75k) nothing; parse cached ($($bu[7..9] -join ' / '))" ($bu[7] -eq 'ki ' -and $bu[8] -match '^ki1 HANDOFF: kit instructions in context 1[67]\d{3} > cap 15000' -and $bu[9] -eq 'ki2 |True')
Expect "budget: a role's 0 turns off a 300k default (800k), another role gets the default (kit budget default); llama.cpp n_ctx read ($($bu[10..12] -join ' / '))" ($bu[10] -like '800000|*' -and $bu[11] -eq '300000|200000|75000|kit budget default' -and $bu[12] -like '13107|16384|15000|local 0.8 x (llama n_ctx*')
Expect "budget: 1M -> handoff 800k (no kit cap), 200k -> 160k, 32k local -> 25.6k, design 32k, instruction cap floor 15k ($($bu[0..2] -join ' / '))" ($bu[0] -eq '800000|200000|75000|local 0.8 x (window given)' -and $bu[1] -like '160000|200000|75000|*' -and $bu[2] -like '25600|32000|15000|*')
Expect "budget: kit role cap 400k wins over 800k (shown: kit budget devy), another role keeps 800k; Ollama's context length read ($($bu[3..5] -join ' / '))" ($bu[3] -eq '400000|200000|75000|kit budget devy' -and $bu[4] -like '800000|*' -and $bu[5] -like '52429|65536|24576|local 0.8 x (ollama OLLAMA_CONTEXT_LENGTH)')
Expect "spend: a transcript without usage fields (a local model) is estimated from its text, bytes / 4 ($($bu[6]))" ($bu[6] -match '^est 100\d\d True$')

# Get-KitUsage walks all 3 CLIs (tests: KIT_TRANSCRIPTS_<TOOL>), steps carry the summary; the day rows the mix; usage -Context text + JSON
$tx = New-Item -ItemType Directory -Force (Join-Path (Kd) 'tx/s1/subagents'); Copy-Item "$fx/claude.jsonl" "$tx/agent-d1.jsonl"; '{"agentType":"devy","description":"build A1"}' | Set-Content "$tx/agent-d1.meta.json"
$u = Invoke-PsTest ctx-usage @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $env:KIT_TRANSCRIPTS_CODEX = $args[2]; $env:KIT_TRANSCRIPTS_ANTIGRAVITY = $args[3]
$u = Get-KitUsage -Seconds 30; $as = @($u.agentSteps); $d = @($u.days)[-1]
"$(@($as | ForEach-Object { "$($_.role):$($_.tool):$($_.cx.pk)" } | Sort-Object) -join ',')|$(@($u.bg | ForEach-Object session | Sort-Object) -join ',')|$($d.cx.pk)|$([long](@($d.cx.car) | Measure-Object -Sum).Sum -gt 0)"
'@ @($O, (Split-Path (Split-Path $tx)), "$fx/codex", "$fx/ag")
Expect "usage: Claude, Codex and Antigravity agents each a step with its tool and context peak; grouped by session / tool; today's day row the peak and mix ($u)" ("$u" -eq 'antigravity:antigravity:10000,codex:codex:15000,devy:claude:29000|antigravity,codex,s1|29000|True')
$cli = Invoke-PsTest ctx-cli @'
$env:KIT_TRANSCRIPTS = $args[1]; & $args[0] usage -Context -Type devy -Since 2d; "rc $LASTEXITCODE"; $j = & $args[0] usage -Context -Since 2d -Json | ConvertFrom-Json; "$(@($j).Count) $(@($j | Where-Object role -eq devy)[0].carried.'build + test output' -gt 0) $(@($j | Where-Object role -eq devy)[0].waste[0])"
& $args[0] usage -Since x 2>&1 | Out-Null; "rc2 $LASTEXITCODE"
'@ @($O, (Split-Path (Split-Path $tx)))
Expect "usage -Context: text per type and agent (start, peak, top sources, waste), -Json the numbers, a bad call exits 2 ($($cli -join ' / '))" (($cli -join "`n") -match 'context since .*1 agent\(s\) · avg start 20k' -and ($cli -join "`n") -match 'devy build A1: start 20k · peak 29k' -and ($cli -join "`n") -match 'rc 0' -and ($cli -join "`n") -match '\b3 True start load 69% of the peak' -and ($cli -join "`n") -match 'read Main\.java 3x \(2k tokens re-read\)' -and ($cli -join "`n") -match 'rc2 2')

# supervise rules: WATCH per live agent, ACT on a signal in 2+ agents, the learned start norm (observed once per transcript)
$fl = Invoke-PsTest ctx-flags @'
$null = . $args[0] 6>$null; $env:KIT_PARAM_USAGE_CONTEXT_STARTNORM = '10000'; $now = Get-Date
$cx = { param([long]$s0, [long]$last, [int]$rr, [long]$log, [string]$top) [pscustomobject]@{ n = 9; s0 = $s0; pk = $last; sum = 9 * $last; last = $last; cmp = 0; ho = 0; agents = 1; pks = $last; add = @(0) * 8; car = @(1) * 8; w = @(0, 0, 0, 0, [int][bool]$log, $log); rr = @($rr, '/w/app/big.java'); top = @($top) } }
$live = [pscustomobject]@{ label = 'build:A1'; role = 'devy'; run = 'r1'; model = 'claude-sonnet-5-5'; result = 'running'; at = $now.ToString('o'); cx = (& $cx 40000 900000 4 9000 '20000|4|Bash pwsh crafty.ps1 check -Dir /w/app') }
$live.cx | Add-Member kl 68000   # kit docs held; + the 12k kit start = 80k
$e1 = [pscustomobject]@{ label = 'build:A2'; role = 'devy'; run = 'r2'; result = 'pass'; at = $now.AddHours(-2).ToString('o'); tf = '/t/a2.jsonl'; cx = (& $cx 30000 50000 3 5000 '12000|4|Bash pwsh crafty.ps1 check -Dir /w/b') }
$e2 = [pscustomobject]@{ label = 'build:A3'; role = 'devy'; run = 'r3'; result = 'pass'; at = $now.AddHours(-3).ToString('o'); tf = '/t/a3.jsonl'; cx = (& $cx 31000 60000 1 0 '9000|4|Bash pwsh crafty.ps1 check -Dir /w/c') }
$f = @(Get-KitContextFlags @($live, $e1, $e2) $now -Observe); $f | ForEach-Object { "$($_.level) $($_.what) => $($_.action)" }
$live.cx.last = 930000; $live.cx.w[1] = 7000; $g = @(Get-KitContextFlags @($live, $e1, $e2) $now)   # the next sweep: new sizes, same flag keys
"flag keys stable $((@($f | ForEach-Object { Get-KitFlagKey $_.what }) -join '|') -eq (@($g | ForEach-Object { Get-KitFlagKey $_.what }) -join '|'))"
$sf = Join-Path (Get-KitPath cache) 'context-norm-seen.json'; $n1 = @((Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties).Count; $null = Get-KitContextFlags @($live, $e1, $e2) $now -Observe; "seen $n1 $(@((Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties).Count)"
'@ @($O)
$fj = $fl -join "`n"
Expect "context WATCH (live agent): near its budget (900k of 967k), a file read 4x, one 20k result, a pasted build log, a start over 1.5x its type's norm ($fj)" ($fj -match 'WATCH context: devy build:A1 over 75% of its budget => at 900k of 967k: hand it off' -and $fj -match 'WATCH context: devy build:A1 re-reads big\.java => 4x' -and $fj -match 'WATCH context: devy build:A1 took an oversized result \(Bash pwsh crafty\.ps1 check -Dir /w/app\) => 20k tokens' -and $fj -match 'WATCH context: devy build:A1 pasted full build / test logs => 1 log' -and $fj -match 'WATCH context: devy build:A1 start load over its type''s norm => started at 40k vs the devy norm 10k' -and $fj -match 'flag keys stable True')
Expect "context: a live agent at 900k is past the 200k design window (WATCH: why?) and holds 80k kit instructions over the 75k cap (ACT: its beat hands off) ($fj)" ($fj -match 'WATCH context: devy build:A1 past the 200k design window => at 900k' -and $fj -match 'ACT context: devy build:A1 holds kit instructions over the cap => 80k of cap 75k: its next board beat prints HANDOFF')
Expect "context ACT (2+ agents): the same oversized build output -> a kitty task with the fix, logs pasted by 2 agents, devy start load over its norm in 2 ended agents; ended agents' starts observed once each ($fj)" ($fj -match 'ACT context: build \+ test output results over 8000 tokens in 3 agents => Spawn kitty \(kind fix\): trim build / test output.*top: Bash pwsh 3; roles devy' -and $fj -match 'ACT context: full build / test logs pasted by 2 agents' -and $fj -match 'ACT context: devy start load over 1\.5 x its norm in 2 agents' -and $fj -match 'ACT context: 2 agents re-read one file 3\+ times' -and $fj -match 'seen 2 2')
# one ACT per source class (before: one per file, 15 a beat): two big files of one class in 4 ended agents -> one line, both files named
$cg = Invoke-PsTest ctx-class @'
$null = . $args[0] 6>$null; $now = Get-Date
$mk = { param($n, $t) [pscustomobject]@{ label = $n; role = 'kitty'; run = $n; result = 'pass'; at = $now.AddHours(-1).ToString('o'); cx = [pscustomobject]@{ n = 3; s0 = 1; pk = 1; sum = 3; last = 1; w = @(0) * 6; rr = @(0, ''); top = @($t) } } }
@(Get-KitContextFlags @((& $mk a '9500|2|Read a.ps1'), (& $mk b '9500|2|Read a.ps1'), (& $mk c '9600|2|Read b.ps1'), (& $mk d '9600|2|Read b.ps1')) $now) | Where-Object level -eq 'ACT' | ForEach-Object { "$($_.what) => $($_.action)" }
'@ @($O)
Expect "context ACT: one line per source class, its top files by agents ($cg)" (@($cg).Count -eq 1 -and "$cg" -match '^context: code reads results over 8000 tokens in 4 agents => .*top: Read a\.ps1 2, Read b\.ps1 2; roles kitty')

# the page: the Runs band cell (peak over a stacked bar, the tooltip per source + waste), the day heat's mix bar, the per-role table
$pg = Invoke-PsTest ctx-page @'
$null = . $args[0] 6>$null; function e($s) { [Net.WebUtility]::HtmlEncode("$s") }; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
$c = [pscustomobject]@{ n = 4; s0 = 20000; pk = 29000; sum = 94000; last = 21000; cmp = 1; ho = 1; agents = 1; pks = 29000; add = @(21500, 1000, 3000, 0, 4000, 0, 0, 1200); car = @(60000, 3000, 9000, 0, 12000, 0, 0, 10000); w = @(2, 2000, 0, 0, 1, 4000); rr = @(3, '/w/app/src/main.java'); top = @('4000|4|Bash pwsh crafty.ps1 check') }
$cell = Format-KitContextCell $c 'build:A1'; $none = Format-KitContextCell $null
$day = Format-KitDayHeat @(@{ n = 'Context mix'; v = @(94000, $null); sb = @((Get-KitContextGradient $c.car), ''); fmt = { param($v) Format-KitCompactNum $v }; t = '94k' }) @('2026-01-01', '2026-01-02') 'day'
$roles = Format-KitContextRoles @([pscustomobject]@{ k = 'devy'; cx = $c }) { param($v) Format-KitCompactNum $v }
$rx1 = "^<span class='gc cxc' title='build:A1`ncontext peak 29k &#183; start 20k"; $rx2 = "<b>29k</b><span class=cxb aria-hidden=true><i class=x-ki style='flex-grow:638'></i>"; $rx3 = '--sb:linear-gradient\(90deg,var\(--x-ki\) 0% 63\.83%'
$ok1 = $cell -match $rx1 -and $cell.Contains($rx2) -and @([regex]::Matches($cell, '<i class=x-')).Count -eq 5 -and $cell -match 'waste: start load 69% of the peak .* read main\.java 3x'
$ok3 = $day.Contains("class='gs hm dy sbr'") -and $day -match $rx3; $ok4 = $roles.Contains('role &#183; context') -and $roles.Contains('data-mk=context-role') -and $roles.Contains('>69%<')
"$ok1|$($none.Contains('cxc z'))|$ok3|$ok4"
'@ @($O)
Expect "page: Runs band context cell = peak over 5 source parts (the zero ones left out), tooltip with waste; no record = a dash; Trends mix row = a stacked bar per day; per-role table (start / peak 69%) ($pg)" ("$pg" -eq 'True|True|True|True')
# category rules (revy 2026-11-22): a pure read naming a test tool is a code read, git is no build, MandateService.java is code, Antigravity
# Path keys (any case, JSON-in-JSON) count re-reads, secrets in a command label are masked, a tool input's created_at never dates a Claude line
$cr = Invoke-PsTest ctx-rules @'
$null = . $args[0] 6>$null
$cmd = @('cat web/cypress/e2e/orders.cy.ts', 'sed -n 1,80p build.gradle', 'cat jest.config.js', 'grep -rn pytest docs', 'rg -n jest src', 'git commit -m "fix tsc errors"', 'mvn test | tail -50', 'cd /w/app && yarn test', 'F=/w/x.log cat /w/a.py', 'cat /w/kit/.claude/skills/x/SKILL.md', 'bash -lc "cat src/a.py"') | ForEach-Object { Get-KitContextCmdCat $_ }
$pth = @('/w/src/main/java/MandateService.java', '/w/briefs/mandate.md') | ForEach-Object { Get-KitContextPathCat $_ 2 }
$cx = New-KitContextRec; foreach ($i in 1, 2) { $p = Get-KitContextPend 'read_file' '{"Path":"\"D:\\\\w\\\\.claude\\\\a.md\""}'; Add-KitContextResult $cx $p 100 '' }
$sec = New-KitContextRec; foreach ($c in 'pokey.ps1 login -User admin -Password Hunter2pw', 'curl -u admin:S3cretpw https://x.test', 'mysql -p Hunter3pw -e "select 1"') { Add-KitContextResult $sec "5|Bash|$c" 9000 '' }
$tx = Join-Path $args[1] 'ts.jsonl'; [IO.File]::WriteAllText($tx, '{"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__x__create","input":{"created_at":"2020-01-01T00:00:00Z"}}],"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-01-05T09:00:00.000Z"}' + "`n")
$u = Update-KitUsageFile $tx $null ([ref][long]1MB)
"$($cmd -join ',')|$($pth -join ',')|$(@($cx.rmax)[0]):$($p.Split('|')[0])|$((@($sec.top) -join ' ') -notmatch 'Hunter2pw|S3cretpw|Hunter3pw')|$($u.t1)|$(@($u.days.Keys) -join ',')"
'@ @($O, "$(Kd)")
Expect "category rules: reads naming test tools = code (2), git commit = other (5), mvn / yarn test = build (4), VAR= and sh -c wrappers off, kit .md = instructions (0); MandateService.java = code, briefs/mandate.md = task; Antigravity Path read twice = 2 re-reads of a kit .md; no secret in labels; the line's timestamp, not a tool input's created_at ($cr)" ("$cr" -eq '2,2,2,2,2,5,4,4,2,0,2|2,1|2:0|True|2026-01-05T09:00:00.000Z|2026-01-05|claude-sonnet-5-5')
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
if (Use-BrowserKit) {
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'
  # the popover (owner 2026-11-23): a context tip at the bottom-right corner opens on hover inside the viewport as title, 4 tiles, a swatch
  # table, a waste note and command lines (no native title left); a token tip = a table with its total row; Esc closes it
  $uiPop = Join-Path (Kd) 'popover.html'
  & { . $O; $e = { param($x) [Net.WebUtility]::HtmlEncode("$x") }
    $cx = [pscustomobject]@{ n = 4; s0 = 20000; pk = 29000; sum = 94000; cmp = 1; agents = 1; pks = 29000; add = @(21500, 1000, 3000, 0, 4000, 0, 0, 1200); car = @(60000, 3000, 9000, 0, 12000, 0, 0, 10000); w = @(2, 2000, 0, 0, 1, 4000); rr = @(3, '/w/app/src/main.java'); top = @('4000|4|Bash pwsh crafty.ps1 check -Kind build --spec a/b.cy.ts', '900|2|Read a.ps1') }
    $tk = Get-KitSplitTip ([pscustomobject]@{ in = 10; out = 90; cr = 800; cw = 100; cs = @(0.01, 0.2, 0.02, 0.05); tok = 1 }) 'devy:A1'
    $chk = "var o0=window.uiChecks;window.uiChecks=function(){var r=o0?o0():[],d=document,t=d.getElementById('tip'),q=function(s){return t.querySelectorAll(s).length},hv=function(i){d.getElementById(i).dispatchEvent(new MouseEvent('mouseover',{bubbles:true}))};" +
      "hv('p1');var b=t.getBoundingClientRect(),n=[t.hidden?'hidden':'',q('.tp-pt b'),q('.tp-ps>div'),q('tbody tr'),q('.tp-sw'),q('.tp-pn li'),q('.tp-pl code')].join(',');if(n!=',1,4,5,5,3,2')r.push({el:'tip',why:'context popover parts '+n,text:''});" +
      "var hb=d.getElementById('p1').getBoundingClientRect();if(b.left<0||b.top<0||b.right>innerWidth||b.bottom>innerHeight)r.push({el:'tip',why:'outside the viewport',text:''});if(b.bottom>hb.top+1||hb.top-b.bottom>16||b.right<hb.left-24)r.push({el:'tip',why:'not flipped above its corner holder',text:''});if(d.getElementById('p1').hasAttribute('title'))r.push({el:'tip',why:'native title kept',text:''});" +
      "hv('p2');if(q('tr.tp-tt')!=1||q('tbody tr')!=5)r.push({el:'tip',why:'token popover rows '+q('tbody tr'),text:''});d.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));if(!t.hidden)r.push({el:'tip',why:'Esc leaves it open',text:''});" +
      "var p2=d.getElementById('p2');p2.title='devy:B2';hv('p2');if(p2.hasAttribute('title')||t.textContent.indexOf('devy:B2')<0)r.push({el:'tip',why:'a rewritten title shows stale text or stays native',text:''});" +
      "hv('p3');if(t.hidden||t.textContent.indexOf('stuck at step')<0)r.push({el:'tip',why:'a key line ending in a colon',text:''});hv('p4');if(q('dt')!=2)r.push({el:'tip',why:'key list keys '+q('dt'),text:''});" +
      "var g=d.getElementById('p5');g.focus();g.dispatchEvent(new FocusEvent('focusin',{bubbles:true}));var a1=t.textContent;g.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));if(a1.indexOf('11:00')<0||t.textContent.indexOf('10:00')<0)r.push({el:'tip',why:'heat row keys: '+a1+' / '+t.textContent,text:''});return r}"
    $sp = "<span id=p1 style='position:fixed;right:0;bottom:0' title='$(& $e (Get-KitContextTip $cx 'build:A1'))'>c</span><span id=p2 title='$(& $e $tk)'>t</span><span id=p3 title='Title · a 1 · b 2`nKind: stuck at step:'>k</span><span id=p4 title='Flag`nlevel: WATCH`nwho: coordinator'>v</span><span id=p5 class=gs><i title='10:00 · a'>1</i><i title='11:00 · b'>2</i></span>"
    (Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00' })).Replace('<main class=wrap>', "<main class=wrap>$sp").Replace('</body>', "<script>$chk</script></body>") } | Set-Content $uiPop -Encoding utf8
  $popOut = @(& $py -X utf8 $uiKb ui-check $uiPop --widths 1366 2>&1 | Out-String) -split "`n"
  Expect "popover: structured context + token tips inside the viewport, title moved (a rewritten one too), Esc closes, colon key line, key list, heat row arrows ($(@($popOut -match 'CLIP tip|render failed') -join ' / '))" (-not @($popOut -match 'CLIP tip|render failed').Count -and @($popOut -match '1366 px').Count)
}
Remove-TestKit $k
