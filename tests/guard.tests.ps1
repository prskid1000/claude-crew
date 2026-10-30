#Requires -Version 7
<#
guard.tests.ps1: crafty.ps1 guard (PreToolUse hook): self-test cases, the live kit clone, MR task links, layout, temp-root writes; background shells
(the guard's note, supervise's Shells sweep); the supervise -Brief report.
Usage: pwsh -NoProfile -File <kit>/tests/guard.tests.ps1 (or tests/kit-tests.ps1 -Area guard).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit guard; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$gi = -not (Test-Path "$k/.git"); if ($gi) { git init -q $k }   # {KIT} cases
$kl = "$k/skills/crafty/kit.local.json"; '{"guard":{"layout":"block"}}' | Set-Content $kl
$out = pwsh @np $D guard -SelfTest 2>&1 | Out-String; Remove-Item $kl
Expect 'guard self-test (guard.layout block)' ($out -match '(\d+)/\1 passed')
'/nested/' | Set-Content "$k/.gitignore"; git init -q "$k/nested/wt"; New-Item -ItemType Directory -Force "$k/nested/plain" | Out-Null
$gn = Invoke-PsTest 'guard-nested' @'
$d, $kd = $args; foreach ($x in "$kd/nested/wt", "$kd/skills", "$kd/nested/plain") { $j = @{ tool_name = 'Bash'; cwd = $x; tool_input = @{ command = 'git commit -m x' } } | ConvertTo-Json -Compress; "$((& $d guard -Json $j) -join '' -match 'the live kit runs')" }
'@ @($D, $k)
Remove-Item "$k/.gitignore", "$k/nested" -Recurse -Force
Expect "guard: git commit in a nested worktree passes; a tracked folder, an ignored non-repo denied ($($gn -join ' '))" (($gn -join ' ') -eq 'False True True'); if ($gi) { Remove-Item -Recurse -Force "$k/.git" }
# guard: a raw MR create needs a task id (branch or title); a raw merge needs the MR in task tracking; KIT_NO_TASK=<reason> passes, logged
$shop = Join-Path (Kd) 'shop'; git init -q -b f/TT-42-x $shop; git -C $shop commit -q --allow-empty -m init; git -C $shop remote add origin 'https://h.example/g/shop.git'
$plain = Join-Path (Kd) 'plain'; git init -q -b fix/plain $plain; git -C $plain commit -q --allow-empty -m init; git -C $plain remote add origin 'https://h.example/g/shop.git'
$hf = Join-Path (Kd) 'mrget.ps1'; Set-Content $hf '@{ source_branch = $(if ($args[0] -eq 77) { ''deploy/s'' } else { ''f'' }) } | ConvertTo-Json'
& $J @{ tracker = @{ type = 'command'; branchTag = 'TT-' }; gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$hf`" {n}" } } } $kl
$mg = Invoke-PsTest 'guard-mr' @'
$d, $kd, $shop, $plain = $args; . "$kd/skills/crafty/lib.ps1"
Update-KitTracking { param($t) $t.tasks['T1'] = @{ task = 'T1'; mrs = @('shop!12') } }
$cases = @(
  @('c-plain', $plain, 'glab mr create --title "fix: x" --fill --yes', 'names no tracker task'),
  @('c-branch', $shop, 'glab mr create --title "fix: x" --fill', ''),
  @('c-title', $plain, 'glab mr create -t "fix: x (TT-42)" -s fix/plain', ''),
  @('c-head', $plain, 'gh pr create -H f/TT-9-y -t x', ''),
  @('c-deploy', $plain, 'glab mr create -t x -s deploy/s -b main', ''), @('m-deploy', $shop, 'glab mr merge 77', ''),
  @('m-tracked', $shop, 'glab mr merge 12 --auto-merge --yes', ''),
  @('m-url', $plain, 'gh pr merge https://h.example/g/shop/-/merge_requests/12 --squash', ''),
  @('m-untracked', $shop, 'glab mr merge 13 -s', "track add -Task <id> -Mrs 'shop!13'"),
  @('m-other-repo', $shop, 'glab mr merge 12 -R g/other', "other!12"),
  @('m-no-number', $shop, 'glab mr merge --auto-merge', 'needs the MR number'),
  @('m-cd', $kd, "cd $shop && glab mr merge 13", "shop!13"),
  @('escape', $shop, 'KIT_NO_TASK="hotfix, no task" glab mr merge 13', ''),
  @('quoted', $shop, 'git commit -m "glab mr merge 13; gh pr create"', ''),
  @('heredoc', $shop, "glab mr merge 12 --yes; cat > n.md <<'EOF'`nglab mr merge 99`nEOF", ''),
  @('in-quotes', $shop, "glab mr merge 12; echo 'x`nglab mr merge 99`ny'", ''),
  @('continued', $plain, "glab mr create --fill \`n  --title `"fix (TT-5)`"", ''))
foreach ($c in $cases) {
  $j = @{ tool_name = 'Bash'; cwd = $c[1]; tool_input = @{ command = $c[2] } } | ConvertTo-Json -Compress
  $o = (& $d guard -Json $j) -join ''; $deny = $o -match '"permissionDecision":"deny"'
  "$($c[0]):$(if ($c[3]) { $deny -and $o.Contains($c[3]) } else { -not $deny })"
}
$env:KIT_TRACKER_TYPE = 'none'; $j = @{ tool_name = 'Bash'; cwd = $shop; tool_input = @{ command = 'glab mr merge 13' } } | ConvertTo-Json -Compress
"no-tracker:$(-not ((& $d guard -Json $j) -join '' -match 'deny'))"; $env:KIT_TRACKER_TYPE = $null
"logged:$(@(Read-KitLog guard (Get-Date).AddMinutes(-5) | Where-Object { $_.event -eq 'no-task' -and $_.reason -eq 'hotfix, no task' }).Count -eq 1)"
'@ @($D, $k, $shop, $plain)
Remove-Item $kl
Expect-Each $mg 'guard MR task link: # (c-*: create needs TT-<id> in branch or title; m-*: merge needs the MR tracked; escape: KIT_NO_TASK)' @('c-plain', 'c-branch', 'c-title', 'c-head', 'm-tracked', 'm-url', 'm-untracked', 'm-other-repo', 'm-no-number', 'm-cd', 'escape', 'quoted', 'heredoc', 'in-quotes', 'continued', 'no-tracker', 'logged', 'c-deploy', 'm-deploy') 19
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
$gl = (@{ tool_name = 'Write'; tool_input = @{ file_path = "$(TkPath $k runtime)/work/x2/a.md" } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
$dd = pwsh @np $D dir -Agent 'B 1' -Item T9 -Name 'Run.LOG' 2>&1 | Out-String
Expect 'guard: a write off the layout gets a note naming crafty.ps1 dir; dir: agents/<id>/<item>/<file>, lowercase-kebab' ($gl -match 'additionalContext.*kit layout: runtime/work/x2/a\.md.*dir -Agent' -and $gl -notmatch 'deny' -and $dd.Trim() -match '[\\/]work[\\/]agents[\\/]b-1[\\/]t9[\\/]run\.log$')
$gt = (@{ tool_name = 'Write'; tool_input = @{ file_path = '/tmp/mr-body.md' } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
Expect 'guard: a Write of a body file to the shared temp root is denied, naming crafty.ps1 dir' ($gt -match '"deny"' -and $gt -match 'shared temp root.*dir -Agent')
$bgc = foreach ($c in @('until curl -s x; do sleep 5; done', 1), @("cd x; cat > /dev/null; python - <<'EOF'`nEOF", 1), @('until x; do sleep 5; done', 0), @('timeout 5 curl x; until curl -s x; do sleep 2; done', 1), @('git log | cat', 1), @("python - <<'PY'`nprint(1)`nPY", 1), @('for i in $(seq 1 20); do sleep 5; done', 1), @('timeout 600 bash -c "until x; do sleep 5; done"', 1), @("cat <<'EOF' > n.md`nx`nEOF", 1)) {
  "$(((@{ tool_name = 'Bash'; tool_input = @{ command = $c[0]; run_in_background = [bool]$c[1] } } | ConvertTo-Json -Compress) | Px $D guard | Out-String) -match 'background shell may never end')" }
Expect "guard: a background sleep loop with no bound or a stdin read gets a note; bounded, foreground or a heredoc into a file: none ($bgc)" (($bgc -join ' ') -eq 'True True False True False False False False False')
# agents' background shells: owner from its transcript (Agent-tool meta, workflow journal, main session = coordinator); -AutoFix kills
$sh = Invoke-PsTest 'shells' @'
. $args[0]; $tr = Join-Path $args[1] 'tx-sh'; $env:KIT_TRANSCRIPTS = $tr; $env:KIT_PARAM_SUPERVISE_SHELLSTUCKMINUTES = '0'; $env:KIT_PARAM_SUPERVISE_HEARTBEATMINUTES = '1'; $t0 = Get-Date
$gone = (Join-Path $args[1] 'gone-wt') -replace '\\', '/'; $c1 = "cd $gone; until crafty.ps1 pipes -Dir $gone; do sleep 30; done"; $c2 = "cat > /dev/null; python - <<'EOF' 2>&1 || true`nEOF"
$tu = { param($f, $c, $at) New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Add-Content $f (@{ type = 'assistant'; timestamp = ([datetime]$at).ToUniversalTime().ToString('o'); message = @{ content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ command = $c; run_in_background = $true } }) } } | ConvertTo-Json -Compress -Depth 6) }
$p1, $p2 = 1, 2 | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -NoNewWindow }
& $tu "$tr/s9/subagents/agent-k1.jsonl" $c1 $p1.StartTime; '{"agentType":"devy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k1.meta.json"
& $tu "$tr/s9/subagents/workflows/wf_1/agent-w2.jsonl" $c2 $p2.StartTime; '{"type":"started","agentId":"w2","label":"build:H2"}', '{"type":"result","agentId":"w2","result":{}}' | Set-Content "$tr/s9/subagents/workflows/wf_1/journal.jsonl"
& $tu "$tr/s9.jsonl" 'sleep 900; echo coordinator' $t0.AddMinutes(-60)
$cl = { param($c) "`"C:\Git\bin\bash.exe`" -c `"source s && eval '$($c -replace "'", "'\''" -replace '"', '\"')' < /dev/null && pwd -P >| /tmp/c`"" }
$sp = { param($id, $par, $c, $at) [pscustomobject]@{ Id = $id; ParentId = $par; Name = 'bash.exe'; CommandLine = (& $cl $c); Created = $at; Cpu = 1 } }
$procs = @([pscustomobject]@{ Id = 50; ParentId = 1; Name = 'claude.exe'; CommandLine = 'claude'; Cpu = 9 }, (& $sp $p1.Id 50 $c1 $p1.StartTime), (& $sp $p2.Id 50 $c2 $p2.StartTime),
  (& $sp 999999 50 'sleep 900; echo coordinator' $t0.AddMinutes(-60)), (& $sp 999998 50 'npm run lint' $t0.AddMinutes(-2)), (& $sp 999997 7 'sleep 900; echo coordinator' $t0.AddMinutes(-60)))
$st = @{}; $rs = foreach ($i in 0, 1, 1.2, 2) { $w = Get-KitShellSweep $st $t0.AddMinutes($i) -AutoFix -Procs $procs; Start-Sleep -Milliseconds 300; $w }
"cmd:$((Get-KitShellCommand (& $cl $c2)) -eq $c2)"; "dir:$((Get-KitShellDir 'cd /tmp/x && npm run dev') -eq '')"; "k1:$($p1.HasExited)"; "k2:$($p2.HasExited)"
foreach ($i in 0..3) { "s${i}:$(@($rs[$i].rows | ForEach-Object { "$($_.owner)=$($_.state)" }) -join ',')|$(@($rs[$i].flags | ForEach-Object what) -join '|')" }
"log:$(@(Read-KitLog calls $t0.AddMinutes(-1) | Where-Object event -eq 'shell-kill').Count)"; Format-KitShellTable $rs[1].rows
$hd = "cd /d/x && export A=1; python - <<'`"'`"'EOF'`"'`"'`nimport a`nb`nEOF"; "short:$(Get-KitShellShort $hd)|$((Get-KitShellShort ('npm run x ' * 9)).Length)"
$dd = @{ at = $t0; rows = @(); flags = @(); mem = @{ TotalGB = 8; AvailGB = 4 }; keepFree = 1; resources = @(@{ name = 'r'; gb = 1 }); shells = $rs[1].rows }
$rp = (Format-KitReport $dd) -join "`n"; Write-KitSuperviseReport $dd @($rp) @() n; $f = Get-Content (Get-KitPath supervise-report) -Raw
"order:$($rp.IndexOf('| Resource |') -lt $rp.IndexOf('| Shell |') -and $f.IndexOf('## Resources') -lt $f.IndexOf('## Shells'))"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), (Kd))
Expect "shells: cell unquoted, heredoc collapsed, preambles skipped, 60 chars; the table after RAM in -Brief and the report ($($sh -match '^(short|order):'))" ($sh -contains 'short:python - <<EOF (heredoc, 2 lines)|60' -and $sh -contains 'order:True')
$s0, $s1, $s9, $s2 = @($sh -match '^s\d:')
Expect "shells: finished owner + dir gone = killed, + STUCK 2 sweeps = killed; coordinator's kept; young / non-agent unlisted ($s1)" (
  $sh -contains 'cmd:True' -and $sh -contains 'dir:True' -and $s9 -notmatch 'killed' -and $sh -contains 'k1:True' -and $sh -contains 'k2:True' -and $sh -contains 'log:2' -and
  $s0 -match '^s0:H2=ORPHAN,coordinator=running\|auto-fixed: killed shell \d+ of devy \(owner devy finished; dir gone: .+gone-wt\): until crafty' -and
  $s1 -match '^s1:H2=ORPHAN, STUCK,coordinator=STUCK\|SHELL ORPHAN, STUCK pid \d+ of H2 \(cat > /dev/null; python - <<.+\|SHELL STUCK pid 999999 of coordinator' -and
  $s2 -match '^s3:coordinator=STUCK\|auto-fixed: killed shell \d+ of H2' -and ($sh -join "`n") -match '\| Shell \| Owner \| Age \| State \| Next \|(.|\n)+\| coordinator \| 61 min \| STUCK \| yours: stop it')
$O = Join-Path $k 'skills/bossy/bossy.ps1'   # supervise -Brief report
$rd = @{ rows = @(@{ name = 'W1'; task = 'T1'; state = 'ACTIVE'; since = '2026-01-02T10:00'; last = '2026-01-02T10:05'; doing = 'StructuredOutput' }, @{ name = 'J1'; task = '2026-10-29-rm-staging-2xyz wf_e8c577f7-894'; state = 'WAITING'; wait = 'hm deploy 0abbaa36, train d09409 waits for leases (switch-over)'; since = '2026-01-02T10:00'; next = 'envy.ps1 wait -Id 0abbaa36' })
  mem = @{ TotalGB = 64; AvailGB = 16 }; keepFree = 8; info = @('ready'); resources = @(@{ name = 'rm · api'; by = 'W1'; gb = 3 }) + @(1..6 | ForEach-Object { @{ name = "browser a-b·c·d$_"; by = 'devy-3dy3'; gb = 1 } }) }
$ef = { param($a, $q) @{ level = 'ACT'; kind = 'ENV-FIX'; who = "$a (wave-brief-a8da)"; age = '34 min'; what = $a; problem = $q; action = "& D:\Kit\.claude\skills\bossy\bossy.ps1 decide answer -Id e-20261029090127-$a-e69a" } }
$rd.flags = @(@{ level = 'WATCH'; what = 'RESTART LOOP: hm search 3x'; action = 'logs' }, (& $ef W 'devy-3dy3-put'), ((& $ef J ('p ' * 60)) + @{ next = 'nx' }), (& $ef J1 'C:\d\|x'))
$r1 = (& { . $O; Format-KitReport $rd }) -join "`n"; $rd.mem.AvailGB = 6; $rd.rows = @(); $r2 = (& { . $O; Format-KitReport $rd }) -join "`n"
$want1 = @('| Agent | Task / run | State | Since | Last progress | Next |', '|---|---|---|---|---|---|', '| J1 | rm-staging- 2xyz e8c577f7 | WAITING: hm deploy 0abbaa36, train d09409 waits for leases (switch- over) | 10:00 | — | envy.ps1 wait -Id 0abbaa36 |', '| W1 | T1 | ACTIVE | 10:00 | 10:05 Structured Output | — |', '', '| Level | Flag | Who / item | Age | Problem | Next step |') -join "`n"
$fr = @($r1 -split "`n" | Where-Object { $_ -match '^\| (ACT|WATCH|INFO) \|' }); $fw = @($r1 -split "`n`n" | Where-Object { $_.StartsWith('|') } | ForEach-Object { $tl = $_ -split "`n"; $nc = ($tl[0] -split '\|').Count - 2
  (1..$nc | ForEach-Object { $ci = $_; @($tl | ForEach-Object { ($_ -split '(?<!\\)\|')[$ci] -split ' ' | ForEach-Object Length }) | Measure-Object -Maximum } | Measure-Object Maximum -Sum).Sum + 3 * $nc + 1 })
$rt = foreach ($n in 2, 3, 7) { $rd.resources = @(1..$n | ForEach-Object { @{ name = "r$_"; gb = $_ } }); $fo = & { . $O; Format-KitReport $rd }; "$(@($fo -match '^\| Resource \|').Count)$(@($fo -match '^\| r\d').Count)$(@($fo -match '^\| r\d.*—').Count)$(@($fo -match '^\| r\d' | Where-Object { ($_ -split '\|').Count -ne (@($fo -match '^\| Resource')[0] -split '\|').Count }).Count)$(@(($fo -join "`n") -split "`n`n" | Where-Object { $_.Trim() -and -not $_.StartsWith('|') -and $_ -notmatch '^\*\*RAM\*\* [^\n]+$' }).Count)" }
Expect "report: tables only (no titles but RAM's, no loose lines), widths ($fw) <= 95, cells <= 80 whole words; RAM groups by rows, no filler ($rt)" ($r1.StartsWith($want1) -and "$rt" -eq '12000 13000 14000' -and $r1.EndsWith("`n") -and -not @($fw | Where-Object { $_ -gt 95 }).Count -and -not ($fr -split '\|' -match '.{83}') -and $r1 -cnotmatch 'full: report|\*\*Flags|\*\*Shells|NEXT|transcripts' -and $fr[1] -match ' p …? \| nx \|$' -and $fr[3] -match 'WATCH \| RESTART LOOP \| — \| — \| hm' -and ($r1 -replace ' ').Contains('J1(wave-brief-a8da)|34min|C:\d\\\|x|bossy.ps1decideanswer-Ide-20261029090127-J1-e69a|') -and $r2 -match 'below the floor 8 GB' -and $r2 -match 'nothing running')
$bnv = (pwsh @np $O board 2>&1 | ForEach-Object { "$_" }) -join ' '; $bnc = $LASTEXITCODE   # the raw line, not the wrapped error view
Expect "a missing verb: exit 2 with the verb list ($bnc)" ($bnc -eq 2 -and $bnv -match 'missing -Action\. Verbs: join, beat, show')
Remove-TestKit $k
Complete-Tests
