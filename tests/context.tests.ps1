#Requires -Version 7
<#
tests/context.tests.ps1: adapters/usage.ps1 context offline: what fills each agent's context per model call (Claude Code
transcripts: categories, start load, peak, carried, compactions, handoffs, waste signals), tokens and spend, usage -Context, the
supervise WATCH / ACT rules and the learned start norm, the Runs band cell, the Trends rows and the per-role table, the info popover.
tests/context-2.tests.ps1: what an agent loads at its start, kept small: learn -Read with a
skill list (a shared org section once), board join (its own run in rows, other runs one line).
Usage: pwsh -NoProfile -File tests/context.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/ctx_hook.mjs'); $k = New-TestKit ctx; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $fx = New-Item -ItemType Directory -Force (Join-Path (Kd) 'fx')
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
$r = Invoke-PsTest ctx-parse @'
$null = . $args[0] 6>$null; $o = foreach ($f in $args[1]) { $l = [ref][long]1GB; $u = Update-KitContextFile $f (Update-KitUsageFile $f $null $l) $l; $c = $u.cx
  "$($u.model)|$($u.in)/$($u.out)/$($u.cr)|$($c.n)|$($c.s0)|$($c.pk)|$($c.cmp)|$($c.ho)|$(@($c.add) -join ',')|$(@($c.car | ForEach-Object { [math]::Round($_ / 1000) }) -join ',')|$(@($c.w) -join ',')|$(@($c.rmax) -join ':')|$(@($u.tm | ForEach-Object { [int]$_ }) -join '/')" }
$o; "cat $(Get-KitContextCat Bash 'cat /w/.claude/skills/a/SKILL.md')$(Get-KitContextCat Read '/w/.claude/skills/a/SKILL.md')"
'@ @($O, "$fx/claude.jsonl")
$c1 = "$($r[0])" -split '\|'
# Claude: start 20000 - prompt 1000 = 19000 kit; skill 2000 + memory 500 kit; code 3 x 1000; the gated build's 16 KB = build output, a pasted log
Expect "context claude: 4 calls, start 20k, peak 29k, a compaction (marker; the drop after it is not counted twice), resumed from a handoff ($($r[0]))" ($c1[2] -eq '4' -and $c1[3] -eq '20000' -and $c1[4] -eq '29000' -and $c1[5] -eq '1' -and $c1[6] -eq '1')
Expect "context claude: added per category: kit 19000 + skill 2000, task 1000, code 3000 + memory 500, build 4000, model 200 + summary 1000 ($($c1[7]))" ($c1[7] -match '^2(09|10)\d\d,10\d\d,3[45]\d\d,0,39\d\d,0,0,1200$')
Expect "context claude: waste = the file re-read 2x (2 rereads), no result over 8k, one build log over 3k pasted; most re-read Main.java 3x ($($c1[9]) $($c1[10]))" ($c1[9] -match '^2,\d+,0,0,1,\d+$' -and $c1[10] -eq '3:/w/app/src/main.java')
Expect "context claude: carried = mix x call size (20k + 24k + 29k + 21k = 94k) ($($c1[8]))" (([int[]]($c1[8] -split ',') | Measure-Object -Sum).Sum -in 93..95)
Expect "context: a shell / Read skill read = kit instructions ($($r[1]))" ($r[1] -eq 'cat 00')
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
Expect "board beat: a 15k start at a 32k window is no handoff (harness not counted); a 5k kit doc read on top -> HANDOFF over the 15k cap; at 200k (cap 50k) nothing; parse cached ($($bu[7..9] -join ' / '))" ($bu[7] -eq 'ki ' -and $bu[8] -match '^ki1 HANDOFF: kit instructions in context 1[67]\d{3} > cap 15000' -and $bu[9] -eq 'ki2 |True')
Expect "budget: a role's 0 turns off a 300k default (800k), another role gets the default (kit budget default); llama.cpp n_ctx read ($($bu[10..12] -join ' / '))" ($bu[10] -like '800000|*' -and $bu[11] -eq '300000|200000|50000|kit budget default' -and $bu[12] -like '13107|16384|15000|local 0.8 x (llama n_ctx*')
Expect "budget: 1M devy -> 200k (agentCap.devy), 200k -> 160k, 32k local -> 25.6k, design 32k, instruction cap floor 15k ($($bu[0..2] -join ' / '))" ($bu[0] -eq '200000|200000|50000|kit budget devy' -and $bu[1] -like '160000|200000|50000|*' -and $bu[2] -like '25600|32000|15000|*')
Expect "budget: kit role cap 400k wins over 800k (shown: kit budget devy), another role keeps 800k; Ollama's context length read ($($bu[3..5] -join ' / '))" ($bu[3] -eq '400000|200000|50000|kit budget devy' -and $bu[4] -like '800000|*' -and $bu[5] -like '52429|65536|24576|local 0.8 x (ollama OLLAMA_CONTEXT_LENGTH)')
Expect "spend: a transcript without usage fields (a local model) is estimated from its text, bytes / 4 ($($bu[6]))" ($bu[6] -match '^est 100\d\d True$')

# Get-KitUsage walks the transcripts (tests: KIT_TRANSCRIPTS), steps carry the summary; the day rows the mix; usage -Context text + JSON
$tx = New-Item -ItemType Directory -Force (Join-Path (Kd) 'tx/s1/subagents'); Copy-Item "$fx/claude.jsonl" "$tx/agent-d1.jsonl"; '{"agentType":"devy","description":"build A1"}' | Set-Content "$tx/agent-d1.meta.json"
$u = Invoke-PsTest ctx-usage @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]
$u = Get-KitUsage -Seconds 30; $as = @($u.agentSteps); $d = @($u.days)[-1]
"$(@($as | ForEach-Object { "$($_.role):$($_.tool):$($_.cx.pk)" } | Sort-Object) -join ',')|$(@($u.bg | ForEach-Object session | Sort-Object) -join ',')|$($d.cx.pk)|$([long](@($d.cx.car) | Measure-Object -Sum).Sum -gt 0)"
'@ @($O, (Split-Path (Split-Path $tx)))
Expect "usage: an agent is a step with its tool and context peak; grouped by session; today's day row the peak and mix ($u)" ("$u" -eq 'devy:claude:29000|s1|29000|True')
$cli = Invoke-PsTest ctx-cli @'
$env:KIT_TRANSCRIPTS = $args[1]; & $args[0] usage -Context -Type devy -Since 2d; "rc $LASTEXITCODE"; $j = & $args[0] usage -Context -Since 2d -Json | ConvertFrom-Json; "$(@($j).Count) $(@($j | Where-Object role -eq devy)[0].carried.'build + test output' -gt 0) $(@($j | Where-Object role -eq devy)[0].waste[0])"
& $args[0] usage -Since x 2>&1 | Out-Null; "rc2 $LASTEXITCODE"
'@ @($O, (Split-Path (Split-Path $tx)))
Expect "usage -Context: text per type and agent (start, peak, top sources, waste), -Json the numbers, a bad call exits 2 ($($cli -join ' / '))" (($cli -join "`n") -match 'context since .*1 agent\(s\) · avg start 20k' -and ($cli -join "`n") -match 'devy build A1: start 20k · peak 29k' -and ($cli -join "`n") -match 'rc 0' -and ($cli -join "`n") -match '\b1 True start load 69% of the peak' -and ($cli -join "`n") -match 'read Main\.java 3x \(2k tokens re-read\)' -and ($cli -join "`n") -match 'rc2 2')

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
# L2: a step still 'running' whose transcript went quiet 2+ beats ago has ended: no WATCH for it
$tfq = Join-Path $args[1] 'quiet.jsonl'; '{}' | Set-Content $tfq; (Get-Item $tfq).LastWriteTime = $now.AddMinutes(-60); $qs = [pscustomobject]@{ label = 'q1'; role = 'checky'; run = 'r9'; model = 'claude-sonnet-5-5'; result = 'running'; at = $now.ToString('o'); tf = $tfq; cx = (& $cx 40000 900000 4 9000 '100|1|Read x') }
"ended quiet $(-not @(Get-KitContextFlags @($qs) $now | Where-Object { "$($_.what)" -match 'checky q1' }).Count)"
$sf = Join-Path (Get-KitPath cache) 'context-norm-seen.json'; $n1 = @((Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties).Count; $null = Get-KitContextFlags @($live, $e1, $e2) $now -Observe; "seen $n1 $(@((Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties).Count)"
'@ @($O, (Kd))
$fj = $fl -join "`n"
Expect "context: an agent whose transcript went quiet (ended) keeps no context WATCH ($(@($fl -match '^ended quiet') -join ''))" (@($fl -match '^ended quiet True').Count -eq 1)
Expect "context WATCH (live): 900k of 967k, a file read 4x, a 20k result, a pasted build log, start over 1.5x its type norm ($fj)" ($fj -match 'WATCH context: devy build:A1 over 75% of its budget => at 900k of 967k: hand it off' -and $fj -match 'WATCH context: devy build:A1 re-reads big\.java => 4x' -and $fj -match 'WATCH context: devy build:A1 took an oversized result \(Bash pwsh crafty\.ps1 check -Dir /w/app\) => 20k tokens' -and $fj -match 'WATCH context: devy build:A1 pasted full build / test logs => 1 log' -and $fj -match 'WATCH context: devy build:A1 start load over its type''s norm => started at 40k vs the devy norm 10k' -and $fj -match 'flag keys stable True')
Expect "context: a live agent at 900k is past the 200k design window (WATCH: why?) and holds 80k kit instructions over the 50k cap (ACT: its beat hands off) ($fj)" ($fj -match 'WATCH context: devy build:A1 past the 200k design window => at 900k' -and $fj -match 'ACT context: devy build:A1 holds kit instructions over the cap => 80k of cap 50k: its next board beat prints HANDOFF')
Expect "context ACT (2+ agents): the same oversized build output -> a kitty task with the fix, logs pasted by 2 agents, devy start load over its norm in 2 ended agents; ended agents' starts observed once each ($fj)" ($fj -match 'ACT context: build \+ test output results over 8000 tokens in 3 agents => Spawn kitty \(kind fix\): trim build / test output.*top: Bash pwsh 3; roles devy' -and $fj -match 'ACT context: full build / test logs pasted by 2 agents' -and $fj -match 'ACT context: devy start load over 1\.5 x its norm in 2 agents' -and $fj -match 'ACT context: 2 agents re-read one file 3\+ times' -and $fj -match 'seen 2 2')
# one ACT per source class (before: one per file, 15 a beat): two big files of one class in 4 ended agents -> one line, both files named
$cg = Invoke-PsTest ctx-class @'
$null = . $args[0] 6>$null; $now = Get-Date
$mk = { param($n, $t) [pscustomobject]@{ label = $n; role = 'kitty'; run = $n; result = 'pass'; at = $now.AddHours(-1).ToString('o'); cx = [pscustomobject]@{ n = 3; s0 = 1; pk = 1; sum = 3; last = 1; w = @(0) * 6; rr = @(0, ''); top = @($t) } } }
@(Get-KitContextFlags @((& $mk a '9500|2|Read a.ps1'), (& $mk b '9500|2|Read a.ps1'), (& $mk c '9600|2|Read b.ps1'), (& $mk d '9600|2|Read b.ps1')) $now) | Where-Object level -eq 'ACT' | ForEach-Object { "$($_.what) => $($_.action)" }
'@ @($O)
Expect "context ACT: one line per source class, its top files by agents ($cg)" (@($cg).Count -eq 1 -and "$cg" -match '^context: code reads results over 8000 tokens in 4 agents => .*top: Read a\.ps1 2, Read b\.ps1 2; roles kitty')

# the page: the Runs band cell (peak over a stacked bar, the tooltip per source + waste), the day heat's mix bar, role cells
$pg = Invoke-PsTest ctx-page @'
$null = . $args[0] 6>$null; function e($s) { [Net.WebUtility]::HtmlEncode("$s") }; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
$c = [pscustomobject]@{ n = 4; s0 = 20000; pk = 29000; sum = 94000; last = 21000; cmp = 1; ho = 1; agents = 1; pks = 29000; add = @(21500, 1000, 3000, 0, 4000, 0, 0, 1200); car = @(60000, 3000, 9000, 0, 12000, 0, 0, 10000); w = @(2, 2000, 0, 0, 1, 4000); rr = @(3, '/w/app/src/main.java'); top = @('4000|4|Bash pwsh crafty.ps1 check') }
$cell = Format-KitContextCell $c 'build:A1'; $none = Format-KitContextCell $null
$day = Format-KitDayHeat @(@{ n = 'Context mix'; v = @(94000, $null); sb = @((Get-KitContextGradient $c.car), ''); fmt = { param($v) Format-KitCompactNum $v }; t = '94k' }) @('2026-01-01', '2026-01-02') 'day'
$roles = Get-KitContextRoleCells ([pscustomobject]@{ cx = $c }) { param($v) Format-KitCompactNum $v }; $none2 = Get-KitContextRoleCells $null {}
$rx1 = "^<span class='gc cxc' title='build:A1`ncontext peak 29k &#183; start 20k"; $rx2 = "<b>29k</b><span class=cxb aria-hidden=true><i class=x-ki style='flex-grow:638'></i>"; $rx3 = '--sb:linear-gradient\(90deg,var\(--x-ki\) 0% 63\.83%'
$ok1 = $cell -match $rx1 -and $cell.Contains($rx2) -and @([regex]::Matches($cell, '<i class=x-')).Count -eq 5 -and $cell -match 'waste: start load 69% of the peak .* read main\.java 3x'
$ok3 = $day.Contains("class='gs hm dy sbr'") -and $day -match $rx3; $ok4 = "$($roles.tx[0..2])|$($roles.ag)|$(-join $none2.tx)|$(@($none2.tx).Count)" -eq '20k 29k 69%|1||11'
"$ok1|$($none.Contains('cxc z'))|$ok3|$ok4"
'@ @($O)
Expect "page: Runs band context cell = peak over 5 source parts (the zero ones left out), tooltip with waste; no record = a dash; Trends mix row = a stacked bar per day; per-role table (start / peak 69%) ($pg)" ("$pg" -eq 'True|True|True|True')
# category rules (revy 2026-11-22): a pure read naming a test tool is a code read, git is no build, MandateService.java is code,
# path keys (any case, JSON-in-JSON) count re-reads, secrets in a command label are masked, a tool input's created_at never dates a Claude line
$cr = Invoke-PsTest ctx-rules @'
$null = . $args[0] 6>$null
$cmd = @('cat web/cypress/e2e/orders.cy.ts', 'sed -n 1,80p build.gradle', 'cat jest.config.js', 'grep -rn pytest docs', 'rg -n jest src', 'git commit -m "fix tsc errors"', 'mvn test | tail -50', 'cd /w/app && yarn test', 'F=/w/x.log cat /w/a.py', 'cat /w/kit/.claude/skills/x/SKILL.md', 'bash -lc "cat src/a.py"', 'cd /w && git diff -- tests/kit-tests.ps1 | head', 'cd /w && sed -n 1,9p e2e/a.cy.ts; grep -n jest b.ts', 'cd /w; pwsh -File tests/kit-tests.ps1 -Area x') | ForEach-Object { Get-KitContextCmdCat $_ }
$rng = New-KitContextRec; foreach ($in in '{"file_path":"/w/a.ps1","offset":1,"limit":40}', '{"file_path":"/w/a.ps1","offset":41,"limit":40}', '{"file_path":"/w/a.ps1","offset":41,"limit":40}') { Add-KitContextResult $rng (Get-KitContextPend 'Read' $in) 100 '' }; Add-KitContextResult $rng '5|Bash|grep -n #Lines a.log' 9000 ''
$pth = @('/w/src/main/java/MandateService.java', '/w/briefs/mandate.md') | ForEach-Object { Get-KitContextPathCat $_ 2 }
$cx = New-KitContextRec; foreach ($i in 1, 2) { $p = Get-KitContextPend 'Read' '{"Path":"\"D:\\\\w\\\\.claude\\\\a.md\""}'; Add-KitContextResult $cx $p 100 '' }
$sec = New-KitContextRec; foreach ($c in 'pokey.ps1 login -User admin -Password Hunter2pw', 'curl -u admin:S3cretpw https://x.test', 'mysql -p Hunter3pw -e "select 1"') { Add-KitContextResult $sec "5|Bash|$c" 9000 '' }
$tx = Join-Path $args[1] 'ts.jsonl'; [IO.File]::WriteAllText($tx, '{"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__x__create","input":{"created_at":"2020-01-01T00:00:00Z"}}],"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-01-05T09:00:00.000Z"}' + "`n")
$u = Update-KitUsageFile $tx $null ([ref][long]1MB)
"$($cmd -join ',')|$($pth -join ',')|$(@($cx.rmax)[0]):$($p.Split('|')[0])|$(@($rng.w)[0]):$(@($rng.rmax)[1]):$((@($rng.top) -join ' ') -match '#Lines a\.log')|$((@($sec.top) -join ' ') -notmatch 'Hunter2pw|S3cretpw|Hunter3pw')|$($u.t1)|$(@($u.days.Keys) -join ',')"
'@ @($O, "$(Kd)")
Expect "category rules: reads naming test tools = code (2), git commit = other (5), mvn / yarn test = build (4), VAR= and sh -c wrappers off, kit .md = instructions (0); MandateService.java = code, briefs/mandate.md = task; a Path read twice = 2 re-reads of a kit .md; a read or git step naming a test tool in a chain is no build, a chained kit-tests run is; a next range is no re-read, the same range is (label without the range); no secret in labels; the line's timestamp, not a tool input's created_at ($cr)" ("$cr" -eq '2,2,2,2,2,5,4,4,2,0,2,5,2,4|2,1|2:0|1:/w/a.ps1:True|True|2026-01-05T09:00:00.000Z|2026-01-05|claude-sonnet-5-5')
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
# C1 context self-check: hook, board check (record + row), supervise, beat line
$sc = Invoke-PsTest ctx-check @'
$null = . $args[0] 6>$null; $tf = Join-Path $args[1] 'sess1.jsonl'; $hk = Join-Path (Split-Path $args[0]) 'ctx_hook.mjs'
$u = { param([int]$n) Set-Content $tf "{`"type`":`"assistant`",`"message`":{`"usage`":{`"input_tokens`":$n,`"output_tokens`":0}}}" }
$run = { param($j) ($j | ConvertTo-Json -Compress | node $hk) -join '' }
& $u 150000; "a $(& $run @{ transcript_path = $tf })"; & $u 185000; "b $(& $run @{ transcript_path = $tf })"; "c $(& $run @{ transcript_path = $tf })"
& $u 390000; "d $(& $run @{ transcript_path = $tf })"; "e $(& $run @{ transcript_path = $tf; agent_id = 'zz' })"; "k[$(Get-KitCtxCheckLine $tf 390000 200000)]"
$sd = New-Item -ItemType Directory -Force (Join-Path $args[1] 'sess1/subagents/workflows/wf1'); Copy-Item $tf "$sd/agent-ab.jsonl"; "l $(& $run @{ transcript_path = $tf; agent_id = 'ab' })"
[Environment]::SetEnvironmentVariable('CLAUDE_RUNTIME', '.claude/.rtw'); Copy-Item $tf (Join-Path $args[1] 's2.jsonl'); $null = & $run @{ transcript_path = (Join-Path $args[1] 's2.jsonl') }
"m $(Test-Path (Join-Path $args[1] '.claude/.rtw/cache/ctx-checks/s2.json'))"; [Environment]::SetEnvironmentVariable('CLAUDE_RUNTIME', $null)
$ss = "$(& $args[0] board join -Agent b1 -Type devy)" -replace '(?s).*SESSION (\S+).*', '$1'; "f $(& $args[0] board check -Decision continue -Reason 'phase ends soon' -Ctx sess1 -Session $ss) $((Get-Content (Join-Path (Get-KitPath board) "$ss.json") -Raw | ConvertFrom-Json).ctxCheck.decision)"
$cx = [pscustomobject]@{ n = 9; s0 = 1; pk = 390000; sum = 9; last = 390000; cmp = 0; ho = 0; w = @(0) * 6; rr = @(0, ''); top = @() }
$s = [pscustomobject]@{ label = 'b1'; role = 'devy'; run = 'r1'; model = 'claude-opus-5-5'; result = 'running'; at = (Get-Date).ToString('o'); tf = $tf; cx = $cx }
"g $(@(Get-KitContextFlags @($s) (Get-Date) | ForEach-Object { "$($_.level) $($_.what) => $($_.action)" }) -join ' | ')"
$s.tf = Join-Path $args[1] 'other.jsonl'; '{}' | Set-Content $s.tf; "h $(@(Get-KitContextFlags @($s) (Get-Date) | ForEach-Object { "$($_.level) $($_.what)" }) -join ' | ')"
"i $(Get-KitCtxCheckLine $s.tf 200000 200000) | $(Get-KitCtxCheckLine $s.tf 210000 200000)"; "j $(Get-KitHandoffLine ([pscustomobject]@{ agent = 'h9' }) 's9' 'why')"
'@ @($O, (Kd))
$sj = $sc -join "`n"
Expect "context self-check: none at 150k, once at 180k, next 380k; none for a subagent with no transcript, a workflow agent's own; one record with the beat; <kit>/.rtw runtime ($sj)" ($sj -match '(?m)^a $' -and $sj -match '(?m)^b .*CONTEXT-CHECK: context 185k \(self-check at 180k, next at 380k\).*board check -Decision continue\|handoff .*-Ctx sess1' -and $sj -match '(?m)^c $' -and $sj -match '(?m)^d .*self-check at 380k, next at 580k' -and $sj -match '(?m)^e $' -and $sj -match '(?m)^k\[\]$' -and $sj -match '(?m)^l .*self-check at 380k.*-Ctx agent-ab' -and $sj -match '(?m)^m True$')
Expect "context self-check: board check records it; supervise INFO, not the design-window WATCH; unanswered -> WATCH; beat line once; HANDOFF checks first (RT1) ($sj)" ($sj -match 'f context check recorded: continue at 380k \(phase ends soon\) continue' -and $sj -match 'j HANDOFF: why: code changed .* crafty\.ps1 check -Dir <worktree> first' -and $sj -match '(?m)^g INFO context: devy b1 self-check continue at 380k => phase ends soon$' -and $sj -match '(?m)^h .*WATCH context: devy b1 past the 200k design window' -and $sj -match '(?m)^i CONTEXT-CHECK: context 200k \(self-check at 180k.* \| $')
$eq = (Invoke-PsTest evq @'
$bo = $args[0]; $tq = Join-Path $args[1] 'q7.jsonl'; $run = { (@{ transcript_path = $tq } | ConvertTo-Json -Compress | node (Join-Path (Split-Path $bo) 'ctx_hook.mjs')) -join '' }
$tok = "$(& $bo board join -Agent q7 -Type devy)" -replace '(?s).*SESSION (\S+).*', '$1'; "{`"t`":`"SESSION $tok   (pass -Session $tok to beat`"}" | Set-Content $tq
$null = & $bo board msg -Agent lead -To q7 -Text 'lane 2'; "a $(& $run)"; "b $(& $run)"; "c $(& $bo board inbox -Agent q7)"
$null = & $bo board leave -Session $tok; $null = & $bo board msg -Agent lead -To q7 -Text 'two'; "g $(& $run)"; "f $(& $bo board inbox -Agent q7)"
'@ @($O, (Kd))) -join "`n"
Expect "event queue: unread msgs pushed once, not reprinted; a left agent gets none ($eq)" ($eq -match '(?m)^a .*MESSAGE for q7 .*lead: lane 2' -and $eq -match '(?m)^b $' -and $eq -match '(?m)^c inbox: nothing unread' -and $eq -match '(?m)^g $' -and $eq -match '(?m)^f .*two')
# an answered step is no EMPTY step: [] findings, object lists (they stringify blank), 0 and false are answers
$se = Invoke-PsTest stepempty @'
$null = . $args[0] 6>$null
(@('{"findings":[]}', '{"verdicts":[{"id":"1","outcome":"confirmed"}]}', '{"signals":0}', '{"ok":true}', '{"ok":true,"summary":"  "}', '{"summary":null}') | ForEach-Object { Test-KitStepEmpty ($_ | ConvertFrom-Json) }) -join ','
'@ @($O) | Out-String
Expect "an answered step is not EMPTY: [] / object lists / 0 count; ok alone, blank or null text is ($($se.Trim()))" (@($se.Trim() -split "`r?`n")[-1] -eq 'False,False,False,True,True,True')
Remove-TestKit $k
# ---- was context-2.tests.ps1 (its own test kit)
$TestKitFiles = @('skills/bossy/adapters/kit-admin.ps1'); $k = New-TestKit ctx2; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# learn -Read -Skill a,b: one call, a section both share once (it printed twice: 2.7k tokens per reviewer)
[IO.File]::WriteAllText((Join-Path $k 'LESSONS.md'), "# Kit lessons`n`n## crafty`n- pub when -> do it (pub why)`n`n## opsy`n- ops when -> do it (ops why)`n")
[IO.File]::WriteAllText((Join-Path $k 'ROLES.local.md'), "## opsy , crafty `n- role one`n### pk (pokey)`n- role pk`n## pokey`n- role two`n## crafty`n- role three`n## datay`n| a |`n|---|`n| b |`n|---|`n")
$pairOut = pwsh @np $O learn -Read -Skill opsy,crafty | Out-String; $oneOut = pwsh @np $O learn -Read -Skill crafty | Out-String; $ownOut = pwsh @np $O learn -Read -Skill datay | Out-String
Expect "learn -Read -Skill a,b: both skills' lessons and rules, a shared org section once ($(([regex]::Matches($pairOut, 'role one')).Count))" (([regex]::Matches($pairOut, 'role one')).Count -eq 1 -and $pairOut -match 'pub when' -and $pairOut -match 'ops when' -and $pairOut -match 'role three' -and $pairOut -notmatch 'role two|role pk')
Expect 'learn -Read -Skill a: unchanged (its lessons, its org sections)' ($oneOut -match 'pub when' -and $oneOut -match 'role one' -and $oneOut -match 'role three' -and $oneOut -notmatch 'ops when|role two' -and ([regex]::Matches($ownOut, '\|---\|')).Count -eq 2)
$capLines = @(1..25 | ForEach-Object { "- cap $_ -> a (b)$(if ($_ -eq 25) { ' (9×)' })" }) -join "`n"; [IO.File]::WriteAllText((Join-Path $k 'LESSONS.md'), "# Kit lessons`n`n## zc`n$capLines`n")
$capOut = pwsh @np $O learn -Read -Skill zc | Out-String
Expect "learn -Read: learn.readCap 10 lessons by default: the most-hit, then the newest (the top); the rest counted ($(([regex]::Matches($capOut, '(?m)^- cap')).Count))" (([regex]::Matches($capOut, '(?m)^- cap')).Count -eq 10 -and $capOut -match '\(15 more, fewest hits' -and $capOut -match '- cap 25 ' -and $capOut -match '- cap 9 ' -and $capOut -notmatch '- cap (1\d|2[0-4]) ')
# org blocks by skill and phase: "### t (crafty, ship)" = crafty in phase ship only (a phase tag alone showed it to every role)
[IO.File]::WriteAllText((Join-Path $k 'ROLES.local.md'), "## opsy, crafty, pokey`n- role all`n### mx (crafty, ship)`n- role mx`n### rv (pokey, crafty)`n- role rv`n")
$tagOut = @((pwsh @np $O learn -Read -Skill opsy), (pwsh @np $O learn -Read -Skill pokey), (pwsh @np $O learn -Read -Skill crafty -Phase code), (pwsh @np $O learn -Read -Skill crafty -Phase ship), (pwsh @np $O learn -Read -Skill crafty) | ForEach-Object { "$_" })
$tagGot = @($tagOut | ForEach-Object { "$(if ($_ -match 'role mx') { 'mx' })$(if ($_ -match 'role rv') { 'rv' })$(if ($_ -match 'role all') { '+' })" }) -join ','
Expect "learn -Read: ### (skills, phases) blocks need both to match; untagged rules stay ($tagGot)" ($tagGot -eq '+,rv+,rv+,mxrv+,mxrv+')
# ROUTER.md: the main session's SessionStart context only, never the owner's systemMessage (spawned agents never load it)
[IO.File]::WriteAllText((Join-Path $k 'ROUTER.md'), "## Router ROUTER-MARK-T`n"); $hrJson = @(pwsh @np $O health 2>$null | Where-Object { "$_" -match '^\{' })[-1] | ConvertFrom-Json
Expect "health: ROUTER.md in additionalContext, not in systemMessage ($("$($hrJson.systemMessage)".Length) chars shown)" ($hrJson.hookSpecificOutput.additionalContext -match 'ROUTER-MARK-T' -and "$($hrJson.systemMessage)" -notmatch 'ROUTER-MARK-T')
# board join prints its own run's rows; another run is one count line (the whole board: 1-2.6k tokens per join), board show keeps every row
$null = pwsh @np $O board join -Agent BY -Run rb
$farOut = pwsh @np $O board join -Agent FAR -Run rfar | Out-String; $nearOut = pwsh @np $O board join -Agent NEAR -Run rb | Out-String; $showOut = pwsh @np $O board show | Out-String
Expect "board join: other runs as one line, the own run in rows; show = all ($farOut)" ($farOut -match 'nobody else in your run' -and $farOut -match 'other runs: rb 1 \(rows: board show' -and $farOut -notmatch '(?m)^\s+BY' -and $nearOut -match '(?m)^\s+BY' -and $nearOut -match 'other runs: rfar 1' -and $showOut -match '(?m)^\s+BY' -and $showOut -match '(?m)^\s+FAR')
# context plan: a slice's added tokens over usage.context.sliceFactor (1.5) x the role's p90 = WATCH with the slice's rule, 2+ live agents = ACT
$sliceOut = (Invoke-PsTest ctx2-slices @'
$null = . $args[0] 6>$null; $env:KIT_PARAM_USAGE_CONTEXT_SLICE_CD = '10000'; $now = Get-Date
$mk = { param([string]$lb, [long]$code) [pscustomobject]@{ label = $lb; role = 'devy'; run = 'r1'; model = 'claude-sonnet-5-5'; result = 'running'; at = $now.ToString('o'); cx = [pscustomobject]@{ n = 9; s0 = 20000; pk = 50000; sum = 450000; last = 50000; cmp = 0; ho = 0; agents = 1; pks = 50000; kl = 0; add = @(0, 0, $code, 0, 0, 0, 0, 0); car = @(1) * 8; w = @(0, 0, 0, 0, 0, 0); rr = @(0, ''); top = @() } } }
@(Get-KitContextFlags @((& $mk 'build:A1' 16000), (& $mk 'build:A2' 20000), (& $mk 'build:A3' 14000)) $now) | ForEach-Object { "$($_.level) $($_.what) => $($_.action)" }
$ic = Get-KitInstrCap 967000; "cap $($ic.cap) watch $($ic.watch) small $((Get-KitInstrCap 32000).watch) mid $((Get-KitInstrCap 65536).cap)"
$env:KIT_PARAM_USAGE_CONTEXT_SLICE_CD = $null; 1..6 | ForEach-Object { Add-KitParamObs 'usage.context.slice.cd' (40000 + $_) 'devy' }; $script:KitParamMemo.Clear(); $null = Invoke-ParamLearn
"learned d $([double](Read-KitParams).byKey['usage.context.slice.cd']['devy'].d)"
'@ @($O)) -join "`n"
Expect "context plan: code reads 16k and 20k vs a 10k p90 = WATCH each (14k: none), 2 live devys = ACT with the rule ($sliceOut)" ($sliceOut -match 'WATCH context: devy build:A1 code reads over its plan => 16k added vs the devy p90 10k: read ranges' -and $sliceOut -match 'WATCH context: devy build:A2 code reads over its plan' -and $sliceOut -notmatch 'build:A3' -and $sliceOut -match 'ACT context: 2 live devy agents over their code reads plan => Spawn kitty \(kind fix\)')
Expect "kit instructions: 30k target (WATCH), 50k max (ACT + handoff); a 32k window never watches under the 12k kit start ($(@($sliceOut -split "`n")[-1]))" ($sliceOut -match 'cap 50000 watch 30000 small 12000 mid 24576')
Expect "params: an observation without -Default takes the registry default, so the learn pass keeps its key (the slice and start norms were never learned) ($(@($sliceOut -split "`n")[-1]))" ($sliceOut -match 'learned d 75000')
# an instruction file loaded mid-run counts by its path: the kit's = kit instructions, a product repo's CLAUDE.md = code reads
$mixOut = (Invoke-PsTest ctx2-mix @'
$null = . $args[0] 6>$null; $cx = New-KitContextRec; $big = 'd' * 4000
Step-KitContextLine $cx '{"type":"assistant","timestamp":"2026-01-01T10:00:00Z","message":{"id":"m1","usage":{"input_tokens":20000,"output_tokens":10},"content":[]}}'
Step-KitContextLine $cx ('{"type":"attachment","timestamp":"2026-01-01T10:00:01Z","attachment":{"type":"nested_memory","path":"/w/app/CLAUDE.md","content":{"path":"/w/app/CLAUDE.md","type":"Project","content":"' + $big + '"}}}')
Step-KitContextLine $cx ('{"type":"attachment","timestamp":"2026-01-01T10:00:02Z","attachment":{"type":"instructions","files":[{"path":"/w/x-.claude/AGENTS.md","content":"' + $big + '"},{"path":"/w/app/sub/CLAUDE.md","content":"' + $big + '"}]}}')
"kit $(@($cx.add)[0] - 20000) code $(@($cx.add)[2])"
# a beat cache written before the reclassification (no v) is parsed again: its 45k of "kit docs" (product files) never hands a devy off
$tf = Join-Path $args[1] 'old.jsonl'; '{"type":"assistant","timestamp":"2026-01-01T10:00:00Z","message":{"id":"m1","usage":{"input_tokens":20000,"output_tokens":10},"content":[]}}' | Set-Content $tf
$cf = Join-Path $args[1] 'old.cx'; $old = New-KitContextRec; $old.Remove('v'); $old.off = (Get-Item $tf).Length; $old.n = 1; $old.s0 = 20000; $old.live = @(65000.0, 0, 0, 0, 0, 0, 0, 0)
@{ file = $tf; off = $old.off; cx = $old } | ConvertTo-Json -Depth 10 -Compress | Set-Content $cf
"live $(Get-KitInstrLive $tf $cf) v $((Get-Content $cf -Raw | ConvertFrom-Json).cx.v) calls $((Get-Content $cf -Raw | ConvertFrom-Json).cx.n)"
'@ @($O, (Kd))) -join ' '
Expect "context: a product CLAUDE.md loaded mid-run is code reads, a kit worktree's AGENTS.md kit instructions ($mixOut)" ($mixOut -match 'kit 1000 code 2000')
Expect "beat cache: a record of the old classification is re-read (12k kit start, not 57k) and stamped v 2 ($mixOut)" ($mixOut -match 'live 12000 v 2 calls 1')
# a kit worktree (<name>-.claude) under the workspace: its CLAUDE.md + @AGENTS.md never load again on a file read (3.5k tokens a kitty / revy; probed 2026-11-26)
$stg = Get-Content (Join-Path $src 'settings.json') -Raw | ConvertFrom-Json
Expect "settings.json: claudeMdExcludes skips a kit worktree's CLAUDE.md ($($stg.claudeMdExcludes -join ' '))" (@($stg.claudeMdExcludes) -contains '**/*-.claude/CLAUDE.md')
# board join names the contracts file, never dumps it (its readers Read it; 2.5k tokens per join)
$ctrFile = Join-Path $k 'c.contracts.md'; [IO.File]::WriteAllText($ctrFile, "# Contracts`nCONTRACT-BODY-T`n"); $ctrOut = pwsh @np $O board join -Agent CTR -Run rctr -Contracts $ctrFile | Out-String
Expect "board join: contracts as a one-line pointer, no body ($(($ctrOut -split "`n" | Where-Object { $_ -match 'CONTRACTS' }) -join ''))" ($ctrOut -match 'CONTRACTS: .*c\.contracts\.md \(2 lines\)' -and $ctrOut -notmatch 'CONTRACT-BODY-T')
# lead-notes show (owner 2026-11-27: testers cat-ed the whole file before each check): result line, the code's rows, its newest answers
$lnRun = Join-Path (Kd) 'ln-run'; $null = New-Item -ItemType Directory -Force $lnRun; $lnP = Join-Path $k 'skills/pokey/pokey.ps1'
[IO.File]::WriteAllText((Join-Path $lnRun 'lead-notes.md'), "# Lead notes: r`n**Result:** 2 in, 0 left out`n`n## Prerequisites`n`n| Item | Flags | State |`n|---|---|---|`n| T1 | f1 | ok |`n| T2 | f2 | ok |`n`n## Left out`n`n## Answers (newest last)`n- 01:00 T2: other item`n- 01:01 ALL: run-wide rule`n`n## ENV-FIX NEEDED d-1 (qa-T1, item T1)`nfix the api`nDone: yes`nDECISION d-2 ANSWERED by owner: keep it`n")
foreach ($ln in 1..7) { $null = pwsh -NoProfile -File $lnP lead-notes add -RunDir $lnRun -Code T1 -Text "answer $ln" 2>&1 }
$lnShow = @(pwsh -NoProfile -File $lnP lead-notes show -RunDir $lnRun -Code T1 2>&1) -join "`n"
Expect "lead-notes show -Code T1: result line, T1's prerequisite row, env fixes and decisions, its run-wide rules, its newest 5 of 7 answers; no T2 row or answer ($($lnShow -replace "`n", ' / '))" ($lnShow -match '^\*\*Result:\*\* 2 in' -and $lnShow -match '\| T1 \| f1' -and $lnShow -match 'newest 5 of 7' -and $lnShow -match 'T1: answer 7' -and $lnShow -match 'ENV-FIX NEEDED d-1 .* \| Done: yes' -and $lnShow -match 'DECISION d-2 ANSWERED' -and $lnShow -match 'ALL: run-wide' -and $lnShow -notmatch 'answer [12]\b|T2')
# wt new's root: the kit's own worktree leaves a root under a product's CLAUDE.md (it loaded 12k tokens per kitty session); other repos keep it
$wrWs = Split-Path $k; $wrCfg = Join-Path $k 'skills/crafty/kit.local.json'; $null = New-Item -ItemType Directory -Force (Join-Path $wrWs 'prod/.worktrees'); Set-Content (Join-Path $wrWs 'prod/CLAUDE.md') '# product'
Set-Content $wrCfg (@{ worktreeRoots = @((Join-Path $wrWs 'prod/.worktrees')) } | ConvertTo-Json); $wrGot = & { . (Join-Path $k 'skills/crafty/lib.ps1'); "$(Get-KitWtRootFor $k)|$(Get-KitWtRootFor (Join-Path $wrWs 'prod'))" }
Expect "wt new root: the kit -> <workspace>/.kit-worktrees, a product repo -> the first worktreeRoots entry ($wrGot)" ($wrGot -eq "$(Join-Path $wrWs '.kit-worktrees')|$(Join-Path $wrWs 'prod/.worktrees')")
Remove-Item $wrCfg
# owner 2026-11-27: devy alone runs a 1-hour prompt cache (Claude Code agent front matter experimental.cacheTtl); lint SCHEMA takes only 5m / 1h
$ttlAgents = @(Get-ChildItem (Join-Path $src 'agents') -Filter *.md | Where-Object { (Get-Content $_.FullName -Raw) -match '(?m)^experimental:\r?\n  cacheTtl: 1h\r?$' } | ForEach-Object BaseName)
$ttlPy = "$(python -X utf8 -c "import sys; sys.path.insert(0, r'$(Join-Path $src 'skills/bossy')'); import kitbag as k; fm = k.frontmatter(open(r'$(Join-Path $src 'agents/devy.md')', encoding='utf-8').read().replace(chr(13), '')); s = k.SCHEMAS['agent']; print(fm.get('experimental'), len(k.schema_errors(fm, s)), len(k.schema_errors(dict(fm, experimental='cacheTtl: 2h'), s)))")"
Expect "prompt cache 1h: devy only ($($ttlAgents -join ',')); lint SCHEMA passes it, refuses 2h ($ttlPy)" ("$ttlAgents" -eq 'devy' -and $ttlPy -eq 'cacheTtl: 1h 0 1')
Remove-TestKit $k
Complete-Tests
