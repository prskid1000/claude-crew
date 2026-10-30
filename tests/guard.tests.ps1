#Requires -Version 7
<#
guard.tests.ps1: crafty.ps1 guard (PreToolUse hook): self-test cases, the live kit clone, MR task links, layout, temp-root writes.
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
& $J @{ tracker = @{ type = 'command'; branchTag = 'TT-' } } $kl
$mg = Invoke-PsTest 'guard-mr' @'
$d, $kd, $shop, $plain = $args; . "$kd/skills/crafty/lib.ps1"
Update-KitTracking { param($t) $t.tasks['T1'] = @{ task = 'T1'; mrs = @('shop!12') } }
$cases = @(
  @('c-plain', $plain, 'glab mr create --title "fix: x" --fill --yes', 'names no tracker task'),
  @('c-branch', $shop, 'glab mr create --title "fix: x" --fill', ''),
  @('c-title', $plain, 'glab mr create -t "fix: x (TT-42)" -s fix/plain', ''),
  @('c-head', $plain, 'gh pr create -H f/TT-9-y -t x', ''),
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
Expect-Each $mg 'guard MR task link: # (c-*: create needs TT-<id> in branch or title; m-*: merge needs the MR tracked; escape: KIT_NO_TASK)' @('c-plain', 'c-branch', 'c-title', 'c-head', 'm-tracked', 'm-url', 'm-untracked', 'm-other-repo', 'm-no-number', 'm-cd', 'escape', 'quoted', 'heredoc', 'in-quotes', 'continued', 'no-tracker', 'logged') 17
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
$gl = (@{ tool_name = 'Write'; tool_input = @{ file_path = "$(TkPath $k runtime)/work/x2/a.md" } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
$dd = pwsh @np $D dir -Agent 'B 1' -Item T9 -Name 'Run.LOG' 2>&1 | Out-String
Expect 'guard: a write off the layout gets a note naming crafty.ps1 dir; dir: agents/<id>/<item>/<file>, lowercase-kebab' ($gl -match 'additionalContext.*kit layout: runtime/work/x2/a\.md.*dir -Agent' -and $gl -notmatch 'deny' -and $dd.Trim() -match '[\\/]work[\\/]agents[\\/]b-1[\\/]t9[\\/]run\.log$')
$gt = (@{ tool_name = 'Write'; tool_input = @{ file_path = '/tmp/mr-body.md' } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
Expect 'guard: a Write of a body file to the shared temp root is denied, naming crafty.ps1 dir' ($gt -match '"deny"' -and $gt -match 'shared temp root.*dir -Agent')
Remove-TestKit $k
Complete-Tests
