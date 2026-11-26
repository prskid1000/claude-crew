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
Expect "learn -Read: learn.readCap 20 lessons by default: the most-hit, then the newest (the top); the rest counted ($(([regex]::Matches($capOut, '(?m)^- cap')).Count))" (([regex]::Matches($capOut, '(?m)^- cap')).Count -eq 20 -and $capOut -match '\(5 more, fewest hits' -and $capOut -match '- cap 25 ' -and $capOut -match '- cap 19 ' -and $capOut -notmatch '- cap 2[0-4] ')
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
Remove-TestKit $k
Complete-Tests
