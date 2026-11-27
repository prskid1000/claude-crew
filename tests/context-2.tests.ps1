#Requires -Version 7
<#
tests/context-2.tests.ps1: what an agent loads at its start, kept small (context.tests.ps1 is at its cap): learn -Read with a
skill list (a shared org section once), board join (its own run in rows, other runs one line).
Usage: pwsh -NoProfile -File tests/context-2.tests.ps1 (or tests/kit-tests.ps1 -Area context-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
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
