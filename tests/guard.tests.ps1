#Requires -Version 7
<#
guard.tests.ps1: crafty.ps1 guard (PreToolUse hook), MR links, temp-root writes; supervise report; track add / show; bugbrief; tracker bug.
Usage: pwsh -NoProfile -File <kit>/tests/guard.tests.ps1 (or tests/kit-tests.ps1 -Area guard). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit guard; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$gi = -not (Test-Path "$k/.git"); if ($gi) { git init -q $k }   # {KIT} cases
$kl = "$k/skills/crafty/kit.local.json";'{"guard":{"layout":"block"}}' | Set-Content $kl
$out = pwsh @np $D guard -SelfTest 2>&1 | Out-String; Remove-Item $kl
Expect 'guard self-test (guard.layout block)' ($out -match '(\d+)/\1 passed')
'/nested/' | Set-Content "$k/.gitignore"; git init -q "$k/nested/wt"; New-Item -ItemType Directory -Force "$k/nested/plain" | Out-Null
$gn = Invoke-PsTest 'guard-nested' @'
$d, $kd = $args; foreach ($x in "$kd/nested/wt", "$kd/skills", "$kd/nested/plain") { $j = @{ tool_name = 'Bash'; cwd = $x; tool_input = @{ command = 'git commit -m x' } } | ConvertTo-Json -Compress; "$((& $d guard -Json $j) -join '' -match 'the live kit runs')" }
'@ @($D, $k)
Remove-Item "$k/.gitignore", "$k/nested" -Recurse -Force
Expect "guard: git commit in a nested worktree passes; a tracked folder, an ignored non-repo denied ($($gn -join ' '))" (($gn -join ' ') -eq 'False True True'); if ($gi) { Remove-Item -Recurse -Force "$k/.git" }
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
$p1, $p2, $p3, $p4, $p5 = 1..5 | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -NoNewWindow }
& $tu "$tr/s9/subagents/agent-k1.jsonl" $c1 $p1.StartTime; '{"agentType":"devy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k1.meta.json"
& $tu "$tr/s9/subagents/workflows/wf_1/agent-w2.jsonl" $c2 $p2.StartTime; '{"type":"started","agentId":"w2","label":"build:H2"}', '{"type":"result","agentId":"w2","result":{}}' | Set-Content "$tr/s9/subagents/workflows/wf_1/journal.jsonl"
# opsy lost its shell waiting on pipelines
$c3 = 'until [ $(glab api projects/1/pipelines/3035902453 | jq -r .status) = success ]; do sleep 60; done'; $c4 = 'cat n.md; python tidy.py --report x'
& $tu "$tr/s9/subagents/agent-k3.jsonl" $c3 $p3.StartTime; '{"agentType":"opsy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k3.meta.json"; & $tu "$tr/s9/subagents/agent-k4.jsonl" $c4 $p4.StartTime
$bd = Get-KitPath board -Create; $hs = (Get-Process -Id $PID).StartTime.ToString('o')
@{ agent = 'opsy-1'; status = 'working'; joined = $t0.ToString('o'); beat = $t0.AddMinutes(-40).ToString('o'); transcript = "$tr/s9/subagents/agent-k3.jsonl"; holderPid = $PID; holderStart = $hs } | ConvertTo-Json | Set-Content "$bd/opsy-1.json"
@{ agent = 'leaver'; status = 'left'; joined = $t0.ToString('o'); beat = $t0.AddMinutes(25).ToString('o'); transcript = "$tr/s9/subagents/agent-k4.jsonl" } | ConvertTo-Json | Set-Content "$bd/leaver.json"
$c5 = 'cat n2.md; python tidy2.py'; & $tu "$tr/s9/subagents/agent-k5.jsonl" $c5 $p5.StartTime; '{"agentType":"revy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k5.meta.json"
Get-ChildItem "$tr/s9" -Recurse -Filter 'agent-*.jsonl' | ForEach-Object { $_.LastWriteTime = $t0.AddMinutes($(if ($_.Name -eq 'agent-k5.jsonl') { 12 } else { 0 })) }
& $tu "$tr/s9.jsonl" 'sleep 900; echo coordinator' $t0.AddMinutes(-60)
$cl = { param($c) "`"C:\Git\bin\bash.exe`" -c `"source s && eval '$($c -replace "'", "'\''" -replace '"', '\"')' < /dev/null && pwd -P >| /tmp/c`"" }
$sp = { param($id, $par, $c, $at) [pscustomobject]@{ Id = $id; ParentId = $par; Name = 'bash.exe'; CommandLine = (& $cl $c); Created = $at; Cpu = 1 } }
$procs = @([pscustomobject]@{ Id = 50; ParentId = 1; Name = 'claude.exe'; CommandLine = 'claude'; Cpu = 9 }, (& $sp $p1.Id 50 $c1 $p1.StartTime), (& $sp $p2.Id 50 $c2 $p2.StartTime), (& $sp $p3.Id 50 $c3 $p3.StartTime), (& $sp $p4.Id 50 $c4 $p4.StartTime), (& $sp $p5.Id 50 $c5 $p5.StartTime),
  (& $sp 999999 50 'sleep 900; echo coordinator' $t0.AddMinutes(-60)), (& $sp 999998 50 'npm run lint' $t0.AddMinutes(28)), (& $sp 999997 7 'sleep 900; echo coordinator' $t0.AddMinutes(-60)))
$st = @{}; $rs = foreach ($i in 0, 1, 1.2, 2) { $w = Get-KitShellSweep $st $t0.AddMinutes(30 + $i) -AutoFix -Procs $procs; Start-Sleep -Milliseconds 300; $w }   # transcripts 30 min idle
"cmd:$((Get-KitShellCommand (& $cl $c2)) -eq $c2)"; "dir:$((Get-KitShellDir 'cd /tmp/x && npm run dev') -eq '')"; "k1:$($p1.HasExited)"; "k2:$($p2.HasExited)"; "k34:$(-not $p3.HasExited -and -not $p4.HasExited -and $p5.HasExited)"; $p3, $p4 | Stop-Process -Force
foreach ($i in 0..3) { "s${i}:$(@($rs[$i].rows | ForEach-Object { "$($_.owner)=$($_.state)" }) -join ',')|$(@($rs[$i].flags | ForEach-Object what) -join '|')" }
"log:$(@(Read-KitLog calls $t0.AddMinutes(-1) | Where-Object event -eq 'shell-kill').Count)"; Format-KitShellTable $rs[1].rows
$hd = "cd /d/x && export A=1; python - <<'`"'`"'EOF'`"'`"'`nimport a`nb`nEOF"; "short:$(Get-KitShellShort $hd)|$((Get-KitShellShort ('npm run x ' * 9)).Length)"
$dd = @{ at = $t0; rows = @(); flags = @(); mem = @{ TotalGB = 8; AvailGB = 4 }; keepFree = 1; resources = @(@{ name = 'r'; gb = 1 }); shells = $rs[1].rows }
$rp = (Format-KitReport $dd) -join "`n"; Write-KitSuperviseReport $dd @($rp) @() n; $f = Get-Content (Get-KitPath supervise-report) -Raw
"order:$($rp.IndexOf('| Resource |') -lt $rp.IndexOf('| Shell |') -and $f.IndexOf('## Resources') -lt $f.IndexOf('## Shells'))"
$dd.flags = @([pscustomobject]@{ level = 'WATCH'; what = 'w1'; action = 'a1' }, [pscustomobject]@{ level = 'ACT'; what = 'DECISION <b>x</b>'; who = 'devy'; action = 'answer it' }, [pscustomobject]@{ level = 'INFO'; what = 'auto-fixed: killed shell 7' }, [pscustomobject]@{ level = 'INFO'; what = 'plain info' })
$pg = foreach ($i in 1, 2) { Write-KitSuperviseHtml $dd @('sweep line') 'NEXT 5 min (x)' }; $hx = Get-Content $pg[1] -Raw; $hj = Get-Content ([IO.Path]::ChangeExtension($pg[1], '.json')) -Raw | ConvertFrom-Json
"svgfill:$($hx -match '<figure class=ftr>' -and $hx -match '<div class=fl data-row><div class=fmas><article class=.flag ACT' -and $hx -match 'id=sec-fixed><summary><h3>Fixed this sweep</h3><span class=cnt>\(1\)' -and $hx -match 'id=sec-notes><summary><h3>Notes</h3>' -and -not @([regex]::Matches($hx, '<(path|polyline|polygon)\b[^>]*>') | Where-Object { $_.Value -notmatch '\sfill(-opacity)?=' }).Count -and $hx -match '(^|\})svg \.ln\{fill:none')"   # an SVG line without fill draws black (dark theme)
$sx2 = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); agents = @([pscustomobject]@{ name = 's (devy)'; run = 'solo'; state = 'ACTIVE' }); shells = @([pscustomobject]@{ pid = 1; cmd = "a`nb`nc" }) })
"fold3:$($sx2 -match 'gn0>standalone agents<' -and $sx2 -match '<details class=cmd><summary>a <span class=cnt>\(more, 3 lines\)' -and $sx2 -match '\.cg\.res\{align-items:stretch')"
$o1 = @(Format-KitSuperviseOut $dd $dd $pg[1]);$o0 = @(Format-KitSuperviseOut $dd $dd '') -join "`n"
"page:$($hx.Contains('&lt;b&gt;x&lt;/b&gt;') -and $hx -match 'Kit internals</h2>.*Tuning</h3><span class=cnt>.*<table class=tun>' -and $hx -notmatch '<h3>(Parameters|Settings|Recent changes)</h3>' -and $hx -notmatch '<b>x' -and $hx.IndexOf('flag ACT') -lt $hx.IndexOf('flag WATCH') -and @($hj.history).Count -eq 2 -and @($hj.history[0].flags).Count -eq 2 -and $hj.history[0].fixed -eq 1 -and @($hj.stats.days).Count -eq 14 -and @($hj.stats.live).Count -eq 1 -and -not $hj.sweep)"
$sj = '{"at":"2026-01-02T10:00:00","next":"NEXT 5 min","flags":[{"level":"WATCH","what":"<img src=x onerror=f()>","action":"a&b"}],"agents":[{"name":"<s>n</s> (workflow)","run":"r''1","state":"ACTIVE","task":"t · steps 1/4 · 2k tokens of 10k","since":"2026-01-02T09:00:00"}],"mem":{"TotalGB":8,"AvailGB":2},"history":[],"shells":[{"dir":"D:/w"}],"stats":{"days":[{"day":"2026-01-02","runs":3,"lessons":null}]}}'
$sx = Format-KitSuperviseHtml ($sj | ConvertFrom-Json); "render:$($sx.Contains('&lt;img src=x onerror=f()&gt;') -and $sx -notmatch '<img|<s>' -and $sx.Contains('a&amp;b') -and $sx.Contains('r&#39;1') -and $sx -notmatch '2k tokens of 10k' -and $sx -notmatch 'class=k>Runs</div>' -and $sx -match 'Lessons recorded</div><div class=v>—' -and $sx.Length -lt 300kb -and $sx -match "<td data-k='Dir'>D:/<wbr>w</td>" -and $sx -notmatch 'text-overflow|nowrap;overflow:hidden' -and $sx -match '\.cg\{[^}]*align-items:flex-start' -and $sx -match 'scrollbar-width:none.*intersect.*30dvh.*\.fx table\{table-l' -and $sx -match "tail=''>next 10:05<.*ago data-t='2026-01-02T09" -and $sx -notmatch '=.?https?:|@import|url.h')"
$dz = $t0.Date.AddDays(-3).AddHours(9); $cf = Join-Path (Get-KitPath audit -Create) "$($dz.ToString('yyyy-MM-dd'))/calls.jsonl"; New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null
@(@(0, 'join', 'start', 1, '-Agent A -Run r1'), @(1, 'join', 'end', 1, 'exit'), @(2, 'join', 'start', 2, '-Agent B'), @(3, 'join', 'end', 2, 0), @(30, 'leave', 'start', 3, '-Agent A -Status done'), @(31, 'leave', 'end', 3, 'exit'), @(40, 'leave', 'start', 4, '-Agent B -Status paused'), @(41, 'leave', 'end', 4, 0), @(50, 'leave', 'start', 5, '-Agent C -Status blocked'), @(51, 'leave', 'end', 5, 0)) | ForEach-Object { $q = $_; $o = [ordered]@{ at = $dz.AddMinutes($q[0]).ToString('s'); verb = "board $($q[1])"; event = $q[2]; pid = $q[3] }; if ($q[2] -eq 'start') { $o.args = $q[4] } else { $o.rc = $q[4] }; $o | ConvertTo-Json -Compress } | Set-Content $cf
$dy = @(Get-KitSuperviseDays $null $dz 1)[0]; "days:$($dy.spawned)/$($dy.runs)/$($dy.finished)/$($dy.failed)/$($dy.durSum)/$($dy.durN)"
$pf = Join-Path $args[1] 'published.txt'; if (-not $__cfg) { $__cfg = [pscustomobject]@{} }; $__cfg | Add-Member -Force NoteProperty supervise ([pscustomobject]@{ publish = 'Set-Content -LiteralPath "' + $pf + '" -Value ($env:KIT_SUPERVISE_HTML + "  x")' })
'not json{' | Set-Content ([IO.Path]::ChangeExtension($pg[1], '.json'))   # corrupt .json: history restarts, page built
$pp = Write-KitSuperviseHtml $dd @() 'NEXT 5 min'; for ($w = 0; $w -lt 100 -and -not (Test-Path $pf); $w++) { Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 300
"pub:$((Get-Content $pf -ErrorAction SilentlyContinue) -eq "$pp  x" -and $pp -and -not $env:KIT_SUPERVISE_HTML -and @((Get-Content ([IO.Path]::ChangeExtension($pp, '.json')) -Raw | ConvertFrom-Json).history).Count -eq 1 -and (Get-Content $pp -Raw) -match '>supervise\.<wbr>publish</td><td data-k=Context></td><td data-k=Value>\(set\)')"
"out:$($o1.Count -eq 5 -and $o1[1] -eq 'ACT · DECISION · devy · <b>x</b> -> answer it' -and $o1[2] -eq 'WATCH · w1 -> a1' -and $o1[3] -eq 'FIXED · killed shell 7' -and $o1[4] -eq '0 agent(s) active · 1 ACT · 1 WATCH' -and $o0 -match '\| Level \| Flag')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), (Kd))
Expect "supervise page: escaped, ACT first, 2 sweeps, no scrollbar, live ages, no URL, every SVG line / area with an explicit fill, standalone agents, long commands folded, even resource grid; -Brief html: link, flags, counts; no page = tables; publish masked ($($sh -match '^(page|out|pub|svgfill):'))" ($sh -contains 'page:True' -and $sh -contains 'svgfill:True' -and $sh -contains 'fold3:True' -and $sh -contains 'out:True' -and $sh -contains 'pub:True' -and $sh -contains 'render:True' -and $sh -contains 'days:2/1/1/1/30/1')
Expect "shells: cell unquoted, heredoc collapsed, preambles skipped, 60 chars; after RAM in -Brief and report ($($sh -match '^(short|order):'))" ($sh -contains 'short:python - <<EOF (heredoc, 2 lines)|60' -and $sh -contains 'order:True')
$s0, $s1, $s9, $s2 = @($sh -match '^s\d:')
Expect "shells: gone owner (finished, off board, idle): killed in sweep 1, poll loop or < 20 min idle in sweep 2; live board / fresh beat / coordinator kept ($s0 $s1)" (
  $sh -contains 'cmd:True' -and $sh -contains 'dir:True' -and $s9 -notmatch 'killed' -and $s2 -notmatch 'killed' -and $sh -contains 'k1:True' -and $sh -contains 'k2:True' -and $sh -contains 'k34:True' -and $sh -contains 'log:3' -and
  $s0 -match '^s0:devy=ORPHAN,opsy-1=running,leaver=running,revy=ORPHAN,coordinator=running\|SHELL ORPHAN pid \d+ of devy .+\|auto-fixed: killed shell \d+ of H2 \(owner H2 finished, idle 30 min\): cat > /dev/null' -and $s0 -notmatch 'killed shell \d+ of (devy|opsy|leaver|revy)' -and
  $s1 -match '^s1:opsy-1=STUCK,leaver=STUCK,coordinator=STUCK\|auto-fixed: killed shell \d+ of devy \(owner devy finished, idle 31 min; dir gone: .+gone-wt; no CPU growth.*\): until crafty.*\|SHELL STUCK pid 999999 of coordinator' -and $s1 -match 'killed shell \d+ of revy \(owner revy finished, idle 19 min' -and
  $s2 -match '^s3:opsy-1=STUCK,leaver=STUCK,coordinator=STUCK\|' -and ($sh -join "`n") -match '\| Shell \| Owner \| Age \| State \| Next \|(.|\n)+\| coordinator \| 91 min \| STUCK \| yours: stop it')
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
$bnv = (pwsh @np $D wt 2>&1 | ForEach-Object { "$_" }) -join ' '; $bnc = $LASTEXITCODE; $bdv = pwsh @np $O board 2>&1 | Out-String   # the raw line, not the wrapped error view
Expect "a missing verb: exit 2 with the verb list ($bnc); board without one: show" ($bnc -eq 2 -and $bnv -match 'missing -Action\. Verbs: new, sync' -and $bdv -match '^board: ')
$mm = @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $at = @{ '7' = '2026-01-02T10:00Z'; '12' = '2026-01-02T11:00Z' }
function Invoke-HostVerb($Verb, $A) { if ($Verb -eq 'mr.url') { "https://h/$($A.repo)/-/merge_requests/$($A.n)" } else { @{ state = ('opened', 'merged')[[bool]$at[$A.n]]; merged_at = $at[$A.n]; title = "T$($A.n) (CU-$(('m1', 'b9')[$A.n -eq '13'])) ($(($A.repo -split '/')[-1]))" } } }
function Invoke-HostApi { @{ state = 'opened'; title = 'CU-m1 x' } }
function Start-Process { }
'@
$mc = Invoke-PsTest mrs-comment ($mm + @'
$null = Add-TrackerComment m1 'a person''s note'; $KitConf.TrackerTag = 'CU-'
1..2 | ForEach-Object { $null = Invoke-Track add -Task m1 -Mrs 'g/web!9' }; $null = Invoke-Track add -Task m1 -Mrs 'g/web!30'
$c = @(Get-TrackerComments m1)
"mrs:$($c.Count -eq 1 -and $c[0].text -eq 'a person''s note')"
$tb = Invoke-Track add -Task b1 -Mrs 'g/web!12'
"tb:$($tb -match 'names m1; registering under -Task b1' -and (Invoke-Track show -Task b1) -match '^b1 : g/web!12 \| open$')"
"ref:$((& $args[1] tracker comment m1 "MRs (merge order)`n- x !1") -match 'refused: no MRs comment' -and $LASTEXITCODE -eq 1)"
'@) @($O, $D)
Expect "track add: no MRs comment written (MR links live in the Items checklist), a person's comment kept ($mc)" ("$mc" -match 'mrs:True')
Expect "track add -Task b1 with an MR titled for m1: keyed by -Task; track show -Task; a tracker comment of an MRs comment refused ($mc)" ("$mc" -match 'tb:True.*ref:True')
git -C $shop worktree add -q -b gone "$(Kd)/gone" 2>$null; Remove-Item -Recurse -Force "$(Kd)/gone"; $wg = "$(pwsh @np $D wt remove -Dir "$(Kd)/gone" -Repo $shop 2>&1) rc=$LASTEXITCODE"
$wt = "$(pwsh @np $D wt remove -Dir "$(Kd)/typo" -Repo $shop 2>&1) rc=$LASTEXITCODE"
Expect "wt remove, folder gone: said, exit 0, record pruned; a path git never listed: error ($wg | $wt)" ($wg -match 'already gone.*rc=0$' -and "$(git -C $shop worktree list)" -notmatch 'gone' -and $wt -match 'no such folder.*rc=1$')
$env:KIT_TRACKER_TYPE = 'none'; $ni =pwsh @np $D tracker comment '' x -Kind comment-status -ProseOk t 2>&1 | Out-String; $env:KIT_TRACKER_TYPE = $null
Expect "tracker comment without a task id: refused, never a branch guess" ($ni -match 'no task id')
$bf = & { . $O; function Test-KitLive($l) { $l.agent -ne 'gone' }; $n = Get-Date; $f = { param($h, $ok) @{ ok = $ok; at = $n.AddMinutes(-$h).ToString('o') } }; $x = { param($h) (& $f ($h + 2) $false), (& $f ($h + 1) $false), (& $f $h $false) }
  $e = { param($p, $o, $c, $h) @{ event = 'end'; kind = 'm'; project = $p; owner = $o; code = $c; at = $n.AddMinutes(-$h).ToString('o') } }
  @(Get-KitBuildFailures @{ 'm|old' = & $x 70; 'm|new' = & $x 5; 'm|gone' = & $x 5; 'm|fixed' = & $x 5; 'm|mix' = @((& $f 3 $false), (& $f 2 $true), (& $f 1 $false)) } $n @((& $e new w 1 5), (& $e gone gone 1 5), (& $e fixed w2 1 5), (& $e fixed/sub w2 0 2)) | ForEach-Object { "$($_.key)@$($_.who)" }) -join ',' }
Expect "build failures: 3 in a row flag only < 60 min old, while their agent lives and has no green build of that dir since ($bf)" ($bf -eq 'm|new@w')
# bossy.ps1 bugbrief (a QA bug's brief) and a missing verb
$BX = Join-Path $k 'skills/bossy/bossy.ps1'
$kl = Join-Path $k 'skills/crafty/kit.local.json'; Set-JsonFile $kl @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm' }) }
$bb = Invoke-PsTest bb @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; Update-KitTracking { param($tk) $tk.tasks.b1 = @{ task = 'b1' } }
function Get-TrackerTask { @{ name = 'E500'; description = 'spike' } }; function Get-TrackerComments { }; function Get-TaskMrBranches { @{ repo = 'w'; branch = 'm' } }
$o = Invoke-BugBrief -Task b1 3>$null | Out-String; "d:$($o -match '"id":"B-b1"' -and (Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -match '(?s)\*\*b1\*\* .*E500: spike.*\| w \| `C:/w` \| `m`')"
function Get-TaskMrBranches { }; "r:$(try { Invoke-BugBrief -Task b1 3>$null; 0 } catch { "$_" -match 'no -Repos' })"
function Get-TrackerTask { @{ name = 'E500'; description = "## Failed checks`n### C1 — a`n**Saw:** x`n### C2 — b`n**Saw:** y`n### C3 — c`n**Saw:** z" } }
$null = Invoke-BugBrief -Task b1 -Repos w -Only C1, C2 -Skip 'C2=web; api area' 3>$null; $bt = Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw
"o:$($bt -match '(?s)## Failed checks\s+- \*\*C1\*\*[^\n]*\n\n## Not yours \(coordinator\)\s+- \*\*C2\*\* — web; api area\s+- \*\*C3\*\* — outside -Only')"
"n:$(try { Invoke-BugBrief -Task b1 -Repos w -Only C9 3>$null; 0 } catch { "$_" -match 'no check C9 ' })"
'@ @($BX); Remove-Item $kl
Expect-Each $bb 'bugbrief without check headings: the task is the check, -Agent B-<task>, -Repos from its MRs, else an error; -Only / -Skip -> a Not yours list (a ; in a why kept), an unknown id = error (#)' 'd', 'r', 'o', 'n'
# e2e: the diff's specs only (map, folder, name, imports, visits), none = NOT_TESTED, the whole suite only with -AllTests (logged)
$er = Join-Path (Kd) 'e2e-repo'; $ef = @{ 'cypress/e2e/02-orders/01.create.cy.ts' = 'x'; 'cypress/e2e/misc.cy.ts' = "import { a } from '../../src/app/orders/list.component'`nimport d from '../fixtures/d.json'"; 'cypress/fixtures/d.json' = '1'; 'cypress/e2e/pay.cy.ts' = 'x'; 'cypress/e2e/n.cy.ts.snap' = 'x'; 'src/app/pay/components/row/row.ts' = 'a'
  'cypress/e2e/nav.cy.ts' = "cy.visit('/orders?x=1')"; 'cypress/e2e/users.cy.ts' = "cy.visit('/users')"; 'cypress/e2e/invoices/a.cy.ts' = 'x'; 'src/app/orders/list.component.ts' = 'a'; 'src/billing/rate.ts' = 'a' }
foreach ($p in $ef.Keys) { New-Item -Force "$er/$p" -Value $ef[$p] | Out-Null }; '{ "commands": { "e2e": "node -e 0 cypress run --spec \"{specs}\"" }, "stack": "custom" }' | Set-Content "$er/.claude-stack.json"; Save-GitRepo $er i
& $J @{ tests = @{ e2e = @{ map = @(@{ paths = @('src/billing/**'); specs = @('cypress/e2e/invoices/**') }) } } } $kl
$e2 = { param($f, [string[]]$x = @()) git -C $er checkout -q -- .; foreach ($p in @($f)) { Add-Content "$er/$p" 'b' }; Invoke-TestScript $D check -Dir $er -Step e2e @x }
$cy = Join-Path (Kd) 'cy'; $null = mkdir -Force $cy; '{ "devDependencies": { "cypress": "13" } }' | Set-Content "$cy/package.json"; $cs = pwsh @np $D stack -Dir $cy 2>&1 | Out-String
Expect-Cases @(
  , @('check -Step e2e: the map picks its specs', { & $e2 'src/billing/rate.ts' '-Show' }, { param($r) $r.code -eq 0 -and $r.out -match 'invoices/a\.cy\.ts <- map src/billing/\*\*' -and $r.out -match '--spec "cypress/e2e/invoices/a\.cy\.ts"' -and $r.out -notmatch 'orders' })
  , @('check -Step e2e: unmapped -> folder, imports, visits; unrelated specs left out', { & $e2 'src/app/orders/list.component.ts' '-Show' },
      { param($r) $r.out -match '02-orders/01\.create\.cy\.ts <- folder orders' -and $r.out -match 'misc\.cy\.ts <- imports src/app/orders/list\.component\.ts' -and $r.out -match 'nav\.cy\.ts <- visits /orders\?x=1' -and $r.out -notmatch 'users\.cy|invoices' })
  , @('check -Step e2e: nested file -> its nearest named folder; a changed JSON a spec imports; a .snap is no spec', { & $e2 @('src/app/pay/components/row/row.ts', 'cypress/fixtures/d.json') '-Show' }, { param($r) $r.out -match 'pay\.cy\.ts <- folder pay' -and $r.out -match 'misc\.cy\.ts <- imports cypress/fixtures/d\.json' -and $r.out -match '\(of 6\)' })
  , @('check -Step e2e: no related spec = NOT_TESTED (exit 5), nothing runs', { & $e2 'README.md' }, { param($r) $r.code -eq 5 -and $r.out -match 'e2e NOT_TESTED: no spec relates to the 1 changed file' -and $r.out -notmatch 'gate' })
  , @('check -Step e2e -AllTests: the whole suite, logged; gate refuses a bare suite; cypress dep = e2e step', { $a = & $e2 'src/billing/rate.ts' '-AllTests'; $g = Invoke-TestScript $D gate -Dir $er -Cmd 'npx cypress run'; $a.out += "|$($g.code)|$(pwsh -NoProfile -Command ". '$(Lib)'; @(Read-KitLog builds | Where-Object event -eq e2e-all).Count")"; $a },
      { param($r) $r.code -eq 0 -and $r.out -match 'WHOLE suite' -and $r.out -match '\|2\|1' -and $cs -match 'e2e\s+npx cypress run --spec "\{specs\}"' })
)
Remove-Item $kl
# pokey.ps1 api: auth kinds, -Save, -ContentType, paths
$Q = Join-Path $k 'skills/pokey/pokey.ps1'
$api = Start-TestApi; $apiPort = $api.port
$T = { param($a, $sub) @{ api = "http://127.0.0.1:$apiPort$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tl = & $T ($L + @{ type = 'login' }); tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tt = & $T @{ type = 'none' } '/t/{tenant}' } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tl/l', 'tt/x') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
$xo = Px $Q api -Target tc -Path '/c' 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "api auth login + none; other kinds name their goody ($ok)" (@($ok).Count -eq 2 -and (Get-Content "$(Kd)/A1-C1_01_tl.json" -Raw) -match '"authorization": "\[redacted\]"' -and $xc -eq 1 -and $xo -match 'is a goody: run kitbag\.py goody add api-auth')
foreach ($e in 'pdf', 'txt', 'empty') { $null = Px $Q api -Target tt -Path "/$e" -Save "S-$e" -OutDir (Kd) 2>&1 }; $bo = @(Get-ChildItem (Kd) -Filter 'S-*.body*').Name -join ' '
Expect "api -Save: octet-stream sniffed, empty body: no file ($bo)" ($bo -ceq 'S-pdf.body.pdf S-txt.body.txt')
Expect 'api -ContentType is sent' ((Px $Q api -Target tt -Method POST -Path '/ct' -Body 'hi' -ContentType text/plain 2>&1) -match 'HTTP 200')
$pp = Px $Q api /x -Target tt 2>&1 | Out-String; $pg = Px $Q api -Target tt -Path 'C:/Program Files/Git/x' 2>&1 | Out-String
Expect 'api: a Git Bash path (C:/Program Files/Git/x) is sent as /x' ($pg -match 'HTTP 200'); $pu = Px $Q api -Target tt 2>&1 | ForEach-Object { "$_" } | Out-String; $puc = $LASTEXITCODE
Expect 'api: the first bare arg is -Path; none -> exit 2 with the usage line' ($pp -match 'HTTP 200' -and $puc -eq 2 -and $pu -match 'Usage: api -Target')$api.proc.Kill()
# crafty.ps1 tracker bug (lib.ps1 Add-KitAskBug)
$env:KIT_TRACKER_TYPE = 'none'; $bk = Kd
$ak = (pwsh @np $D tracker create -List L1 -Name 'Ask help routing' -Description 'a' -NewTask fixture | ConvertFrom-Json).id
'help answers link other product pages (vector.py:120)' | Set-Content "$bk/w1.md"; 'second defect' | Set-Content "$bk/w2.md"; 'same root cause' | Set-Content "$bk/w3.md"
$tbg = { param($key, $name, $file, $sig) pwsh @np $D tracker bug -Parent $ak -Key $key -Name $name -File "$bk/$file" -Signature $sig -List L1 | ConvertFrom-Json }
$b1 = & $tbg watch-stg-a '[Bug] Ask help — new defects (1)' w1.md 'vector.py:120'; $b2 = & $tbg qa-run1 '[Bug] staging run — new defects' w2.md 'other.py:9'
$b3 = & $tbg qa-run2 '[Bug] another run' w3.md 'VECTOR.py:120|x.js:1'; 'second defect v2' | Set-Content "$bk/w2.md"; $b4 = & $tbg qa-run1 '[Bug] staging run — new defects' w2.md 'other.py:9'
$bdx = (pwsh @np $D tracker view $b1.id | ConvertFrom-Json).description; $null = pwsh @np $D tracker status $b1.id closed; $b5 = & $tbg qa-run3 '[Bug] Ask help — later' w2.md 'none.py:0'
Expect "tracker bug: one open [Bug] per ask, titles; re-run replaces its section; known signature = duplicate line; closed -> new one ($($b1.action) $($b2.action) $($b3.action) $($b4.action) $($b5.action))" ($b1.action -eq 'created' -and $b2.id -eq $b1.id -and $b2.action -eq 'appended' -and $b3.id -eq $b1.id -and @($b3.duplicates).Count -eq 1 -and $bdx -notmatch 'same root cause' -and $bdx -match 'Duplicates.*qa-run2 \(`VECTOR\.py:120`\)' -and $bdx -match 'second defect v2' -and $bdx -notmatch 'second defect\r?\n' -and ([regex]::Matches($bdx, '\[kit:bug:qa-run1\]')).Count -eq 1 -and $b5.action -eq 'created' -and $b5.id -ne $b1.id)
$sg = & { . (Lib); $h = ConvertTo-KitBugNorm 'see src/my\_mod.py:12 and vector.py:1205, GET https://h.x/api/orders/5/lines'
  "$(Test-KitBugSig $h 'my_mod.py:12')$(Test-KitBugSig $h 'mod.py:12')$(Test-KitBugSig $h 'vector.py:120')$(Test-KitBugSig $h 'https://h.x/api/orders')$(Test-KitBugSig $h 'https://h.x/api/orders/9/lines')"
  (Get-KitDefectSigs ([pscustomobject]@{ observed = 'connect api.example.com:443 refused; https://app.example/#/orders/7?x=1 and https://app.example/#top'; cause = '' })) -join ' ' }
$kb = pwsh @np $D tracker bug -Parent $ak -Key 'watch-stg-err [x]' -Name '[Bug] k' -File "$bk/w3.md" -Signature 'zz.py:1' -List L1 | ConvertFrom-Json; $kc = pwsh @np $D tracker bug -Parent $ak -Key 'watch-stg-err [x]' -Name '[Bug] k' -File "$bk/w3.md" -Signature 'zz.py:1' -List L1 | ConvertFrom-Json
Expect "bug signatures: whole matches, escaped read-back, no host:port, hash routes kept; a key with ] stays one section ($($sg -join ' | '))" ($sg[0] -eq 'TrueFalseFalseFalseTrue' -and $sg[1] -eq 'https://app.example/#/orders/7' -and ([regex]::Matches((pwsh @np $D tracker view $kc.id | ConvertFrom-Json).description, 'kit:bug:watch-stg-err_x')).Count -eq 1 -and $kb.id -eq $kc.id)
$ke = try { & { $k = $null; Kd } } catch { "$_" }; $re = try { & { . (Lib); $script:KitRoot = '/'; Get-KitRuntime } } catch { "$_" }
Expect "path guards ($ke|$re)" ($ke -match 'Kd:' -and $re -match 'bad runtime')
Remove-Item Env:KIT_TRACKER_TYPE
Remove-TestKit $k
Complete-Tests
