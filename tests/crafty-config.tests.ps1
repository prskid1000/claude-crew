#Requires -Version 7
<#
crafty-config.tests.ps1: crafty.ps1 stack / check config, lib.ps1 file writes and reads (Write-KitAtomic, Read-KitText): -Touched, .claude-stack.json, switches (stack.presets, tests.fallbackRunner, protectedBranchesBase, kitBranch, items label, bug prefix, linkDefaults, guard.heavyPatterns / e2ePatterns); guard stray writes (drive root, outside every root, guard.writeRoots).
Usage: pwsh -NoProfile -File <kit>/tests/crafty-config.tests.ps1 (or tests/kit-tests.ps1 -Area crafty-config).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit config; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$dkl = "$k/skills/crafty/kit.local.json"
$tr = Join-Path (Kd) 'touched-repo'; New-Item -ItemType Directory -Force "$tr/src" | Out-Null; '{ "stack": "custom", "commands": { "test": "node -e 0" } }' | Set-Content "$tr/.claude-stack.json"
'x' | Set-Content "$tr/src/Audit.spec.ts"; Save-GitRepo $tr i; 'x' | Set-Content "$tr/src/Audit.ts"
$out = pwsh @np $D check -Dir $tr -Step test -Touched 2>&1 | Out-String
Expect 'check -Touched: Audit.ts is no test (case-sensitive Test suffix); its spec runs' ($out -match '-Touched: 1 test\(s\) for 1 changed file\(s\): src/Audit\.spec\.ts')
$sd = Join-Path (Kd) 'stack-only'; New-Item -ItemType Directory -Force $sd | Out-Null; '{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$sd/.claude-stack.json"
$out = pwsh @np $D stack -Dir $sd 2>&1 | Out-String
Expect 'stack: a .claude-stack.json alone names the stack' ($out -match 'stack: custom' -and $out -notmatch 'FAILED')   # in-process: git's exit code leaks
# config switches: stack.presets, tests.fallbackRunner, protectedBranchesBase (legacy list), linkDefaults, guard.heavyPatterns / e2ePatterns
$gd = Join-Path (Kd) 'go-only'; New-Item -ItemType Directory -Force $gd | Out-Null; 'module x' | Set-Content "$gd/go.mod"
$td = Join-Path (Kd) 'ts-only'; New-Item -ItemType Directory -Force $td | Out-Null; '{ "name": "x", "devDependencies": { "typescript": "5" } }' | Set-Content "$td/package.json"; '{}' | Set-Content "$td/tsconfig.json"
$sw = @'
$env:KIT_TRACKER_TYPE = 'none'; $D, $gd, $td = $args
$st = try { (& $D stack -Dir $gd -Json | ConvertFrom-Json).stack } catch { 'none' }; if (-not $st) { $st = 'none' }
$tt = (& $D stack -Dir $td -Json | ConvertFrom-Json).commands.test
. $D; $kr = Get-KitKeepBranchRx $gd
"stack=$st|spec=$(if (-not $tt) { 'null' } else { $tt })|keep=$('main' -match $kr),$('staging/x' -match $kr),$('critical/a' -match $kr)|links=$(@(Get-DepLinkDefaults | ForEach-Object dir) -join '+')"
'@
$swf = Join-Path (Kd) 'switches.ps1'; Set-Content $swf $sw -Encoding utf8
$spa = "$k/skills/crafty/adapters/stack_presets.ps1"; $spNew = -not (Test-Path $spa); if ($spNew) { New-Item -ItemType Directory -Force (Split-Path $spa) | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/stack_presets.ps1') $spa }
$dk1 = if (Test-Path $dkl) { Get-Content $dkl -Raw }
if (Test-Path $dkl) { Remove-Item $dkl }; $s0 = "$(pwsh @np $swf $D $gd $td 2>&1)"
Set-JsonFile $dkl @{ stack = @{ presets = @() }; tests = @{ fallbackRunner = 'none' }; linkDefaults = @(); guard = @{ heavyPatterns = @('\bbazel\s+(build|test)\b'); e2ePatterns = @('\btestcafe\b') }
  protectedBranchesBase = @('main', 'master', 'develop', 'release/*', 'staging', 'staging/*', 'production', 'production/*', 'prod/*', 'hotfix/*', 'critical/*') }
$s1 = "$(pwsh @np $swf $D $gd $td 2>&1)"
$gj = { param($c) @{ tool_name = 'Bash'; cwd = $gd; tool_input = @{ command = $c } } | ConvertTo-Json -Compress }
$hb = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; $he = (pwsh @np $D guard -Json (& $gj 'npx testcafe chrome t.js') 2>&1) -join '' -match 'e2e runs go through'
Set-JsonFile $dkl @{ stack = @{ presets = @('presets') }; tests = @{ fallbackRunner = 'npx mocha {tests}' } }; $s2 = "$(pwsh @np $swf $D $gd $td 2>&1)"
if ($dk1) { $dk1 | Set-Content $dkl } else { Remove-Item $dkl }
$hn = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; if ($spNew) { Remove-Item $spa }
Expect "config switches: unset = presets on, spec.mjs, base main/master/develop/release, node_modules+.venv; set = presets off, no fallback, the legacy branch list, no links, guard extras deny ($s0 | $s1 | $s2 | $hb $he $hn)" (
  $s0 -match '^stack=go\|spec=node .*spec\.mjs.* \{tests\}\|keep=True,False,False\|links=node_modules\+\.venv$' -and $s1 -match '^stack=none\|spec=null\|keep=True,True,True\|links=( .*no preset detects|$)' -and
  $s2 -match '^stack=go\|spec=npx mocha \{tests\}' -and $hb -and $he -and -not $hn)
# (cap move from guard) stray writes (D:\tmpj.txt, D:\c.md): a new file at a drive root or outside every root is denied per write pattern; guard.writeRoots lets an owner-asked place through
$swr = Invoke-PsTest 'guard-stray' @'
$d, $kd = $args; $dq = [IO.Path]::GetPathRoot($kd); $dm = '/' + $dq.Substring(0, 1).ToLower(); $sf = "kit-stray-$PID"; $dr = 'at a drive root'; $ou = 'outside the workspace'
$cases = @(@('Bash', "crafty.ps1 wt new x > $dq$sf.txt", $dr), @('Bash', "pokey.ps1 deployed > $dm/$sf.txt", $dr), @('Bash', "echo x >> `"$dq$sf.md`"", $dr),
  @('Bash', "git log | tee $dq$sf.txt", $dr), @('Bash', "cp a.txt $dq", $dr), @('Bash', "cd $dm/ && git log > $sf.txt", $dr),
  @('PowerShell', "git log | Out-File -FilePath $dq$sf.txt", $dr), @('PowerShell', "Set-Content -Path $dq$sf.txt -Value 1", $dr),
  @('PowerShell', "[IO.File]::WriteAllText('$dq$sf.txt', 'x')", $dr), @('Write', "$dq$sf.md", $dr), @('Bash', "echo x > ~/$sf.txt", $ou), @('Write', "~/$sf/notes.md", $ou),
  @('Bash', "cat $dq$sf.txt; git -C $dq status 2>/dev/null >/dev/null; echo x > nul; echo a > x:y; ls $dm > $kd/$sf.txt; echo x > ~/.claude/$sf/n.md", ''),
  @('PowerShell', "Get-Content $dq$sf.txt; 'x' | Out-File ~/Downloads/$sf.html; git log > $kd/$sf.txt; 1 > `$null", ''), @('Write', "~/Downloads/$sf.html", ''),
  @('PowerShell', "New-Item -ItemType Directory -Force -Path $kd/o; git log | Out-File -Encoding utf8 $kd/a.txt", '', $dq))   # option values from a cwd outside every root
foreach ($c in $cases) {
  $ti = if ($c[0] -eq 'Write') { @{ file_path = $c[1] } } else { @{ command = $c[1] } }
  $o = (& $d guard -Json (@{ tool_name = $c[0]; cwd = $(if ($c[3]) { $c[3] } else { $kd }); tool_input = $ti } | ConvertTo-Json -Compress)) -join ''
  $ok = if ($c[2]) { $o -match '"deny"' -and $o -match ([regex]::Escape($c[2]) + '.*dir -Agent') } else { $o -notmatch '"deny"' }; if (-not $ok) { "FAIL $($c[0]) $($c[1]) -> $o" }
}
$kl = "$kd/skills/crafty/kit.local.json"; '{"guard":{"writeRoots":["~/' + $sf + '"]}}' | Set-Content $kl
if (((& $d guard -Json (@{ tool_name = 'Write'; cwd = $kd; tool_input = @{ file_path = "~/$sf/notes.md" } } | ConvertTo-Json -Compress)) -join '') -match '"deny"') { 'FAIL writeRoots' }; Remove-Item $kl
'@ @($D, $k)
Expect "guard: new files at a drive root or outside every root denied (redirect, tee, cp, cd + redirect, Out-File, Set-Content, WriteAllText, Write); reads, /dev/null, nul, kit, ~/.claude, Downloads, guard.writeRoots pass ($swr)" (-not "$swr".Trim())
$churnTest = @'
param($LibPath, $Dir)
. $LibPath; $f = Join-Path $Dir 'churn.json'; $new = (Get-Date).AddMinutes(-2); $old = [datetime]'2020-01-01'
Write-KitAtomic $f '{"at": "1", "n": 1}'; [IO.File]::SetLastWriteTime($f, $new); Write-KitAtomic $f '{"at": "1", "n": 1}'; $same = [IO.File]::GetLastWriteTime($f) -eq $new
[IO.File]::SetLastWriteTime($f, $old); Write-KitAtomic $f '{"at": "1", "n": 1}'; "same:$($same -and [IO.File]::GetLastWriteTime($f) -gt $new)"   # an old file gets a fresh time
$u = Join-Path $Dir 'usage.json'; $ux = '^\{"at":"[^"]*","since":"[^"]*"'; Write-KitAtomic $u '{"at":"1","since":"1","runs":[{"at":"a"}]}'; Write-KitAtomic $u '{"at":"2","since":"2","runs":[{"at":"b"}]}' -Volatile $ux
"nested:$([IO.File]::ReadAllText($u) -match '"b"')"
Write-KitAtomic $f '{"at": "2", "n": 1}' -Volatile '"at":\s*"[^"]*"'; "volatile:$([IO.File]::GetLastWriteTime($f) -gt $old -and [IO.File]::ReadAllText($f) -match '"1"')"
Write-KitAtomic $f '{"at": "3", "n": 2}' -Volatile '"at":\s*"[^"]*"'; "changed:$([IO.File]::ReadAllText($f) -match '"3".*2')"
$e0 = $Error.Count; $t = Read-KitText (Join-Path $Dir 'no-such.json'); "missing:$($null -eq $t -and $Error.Count -eq $e0)"; "text:$((Read-KitText $f) -match '"n": 2')"
"locks:$($env:GIT_OPTIONAL_LOCKS -eq '0')"
'@
Expect-Each (Invoke-PsTest 'churn' $churnTest @((Lib), (Kd))) 'churn #: Write-KitAtomic skips same bytes (an old file: time only), a -Volatile-only change moves the file time, a change outside it writes; Read-KitText misses quietly; git probes skip optional locks' 'same', 'nested', 'volatile', 'changed', 'missing', 'text', 'locks'
# usage errors carry one worked example (retro 2026-11-17: cases 31x, evidence 7x)
$dtU = Join-Path $k 'skills/crafty/devtools.py'; $evU = & $py -X utf8 $dtU evidence 2>&1 | Out-String; $caU = & $py -X utf8 $dtU cases 2>&1 | Out-String; $crU = & $py -X utf8 $dtU cases result T1 2>&1 | Out-String
Expect 'devtools.py: evidence / cases usage errors print a worked example per verb' ($evU -match 'e\.g\. python -X utf8 devtools\.py evidence "T1' -and $caU -match 'cases add T1 ' -and $caU -match 'cases round T1 --fix' -and $crU -match 'e\.g\. python -X utf8 devtools\.py cases result T1 A1 PASS')
# K32: cases add on a shared task merges a second agent's goals / env per item; title / change stay first-wins; a repeat adds nothing
$sw2 = Join-Path (Kd) 'shared'; New-Item -ItemType Directory -Force $sw2 | Out-Null
Set-JsonFile "$sw2/a.json" @{ title = 'a'; change = 'ca'; env = 'rm'; plan = @{ unit = 'x' }; checks = @(@{ id = 'S1'; goal = 'g1' }) }
Set-JsonFile "$sw2/b.json" @{ title = 'b'; change = 'cb'; env = 'hm'; setup = 's'; plan = @{ unit = 'y'; e2e = 'z' }; checks = @(@{ id = 'S2'; goal = 'g2' }) }
foreach ($n in 'AA:a', 'BB:b', 'BB:b') { $env:CLAUDE_AGENT, $f = $n -split ':'; $null = & $py -X utf8 $dtU cases add T8 "$sw2/$f.json" 2>&1 }; $env:CLAUDE_AGENT = $null
$sg = Get-Content (& $py -X utf8 $dtU cases render T8 goals) -Raw
Expect "cases add, shared task: env 'rm; BB: hm', plan per key, both goals; title / change first-wins; a repeat adds nothing" ($sg -match '# Testing goals: T8 a\b' -and $sg -match 'Change: ca\.' -and $sg -match 'Local env: rm; BB: hm,' -and $sg -match '- unit: x; BB: y' -and $sg -match '- e2e: z' -and $sg -match 'G1 \(S1\) \| g1' -and $sg -match 'G2 \(S2\) \| g2' -and ([regex]::Matches($sg, 'BB: hm')).Count -eq 1)
# guard: a script in command position is denied with its exact rewrite (retro 2026-11-17)
$gRw = foreach ($gc in 'skills/bossy/bossy.ps1 learn -Skill kitty -Kind win', 'cd x && tools/run.py --n 2', 'skills/pokey/pokey.ps1 results patch -Patch ''{"set":{"T1":{"verify":"a | b; c"}}}''', 'tools/a.py --msg it''s --n 2 | head', 'skills/pokey/pokey.ps1 api -Path "D:\x\" -Flag 1') { $gj = @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $gc } } | ConvertTo-Json -Compress; (pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') guard -Json $gj) -join '' }
Expect "guard: a .ps1 / .py in command position -> the pwsh -File / python -X utf8 rewrite in the deny ($(($gRw | ForEach-Object { [regex]::Match($_, 'Rewrite: [^.]*').Value }) -join ' | '))" ($gRw[0] -match '[Rr]eason":"(kit guard: )?Rewrite: pwsh -NoProfile -File skills/bossy/bossy\.ps1 learn -Skill kitty -Kind win ->' -and $gRw[1] -match '[Rr]eason":"(kit guard: )?Rewrite: python -X utf8 tools/run\.py --n 2 ->' -and
  ($gRw[2] | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason -match [regex]::Escape('Rewrite: pwsh -NoProfile -File skills/pokey/pokey.ps1 results patch -Patch ''{"set":{"T1":{"verify":"a | b; c"}}}'' ->') -and
  ($gRw[3] | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason -match [regex]::Escape('Rewrite: python -X utf8 tools/a.py --msg it''s --n 2 ->') -and
  ($gRw[4] | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason -match [regex]::Escape('Rewrite: pwsh -NoProfile -File skills/pokey/pokey.ps1 api -Path "D:\x\" -Flag 1 ->'))   # the ready command first (retro 2205)
# org names from config, one name for writer and readers: tracker.taskTemplate items label, kindPrefixes.bug (Get-KitItemsLabel, Get-KitKindPrefix)
$ilr = Invoke-PsTest itemslabel @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; . $args[1]; $kl = Join-Path $KitConf.Kit 'skills/crafty/kit.local.json'
"def:$((Get-KitItemsLabel) -eq 'Items' -and (@(Get-KitItemsLabel -All) -join ',') -eq 'Items,Bugs' -and (@(Get-KitDescItems "**Bugs:**`n- B1 x").id -join ',') -eq 'B1' -and (Test-KitBugName '[Bug] x'))"
$c = @{ tracker = @{ kindPrefixes = @{ bug = 'Defect:' }; taskTemplate = @(@{ key = 'items'; label = 'Scope'; required = 'subtask' }) } }; Set-Content $kl ($c | ConvertTo-Json -Depth 6); $script:__cfg = $c | ConvertTo-Json -Depth 6 | ConvertFrom-Json
"custom:$((Get-KitItemsLabel) -eq 'Scope' -and (@(Get-KitDescItems "**Scope:**`n- S1 y").id -join ',') -eq 'S1' -and (@(Get-KitDescItems "**Items:**`n- I1 z").id -join ',') -eq 'I1' -and (Test-KitBugName 'Defect: x') -and (Get-KitKindPrefix 'bug') -eq 'Defect:')"
'@ @($D, (Join-Path $src 'skills/bossy/adapters/task_rollup.ps1'))
Expect-Each $ilr 'items label / bug prefix from config: #' 'def', 'custom' -Show 5
# guard: the kit's protected branch = kitBranch, else main
$gi = -not (Test-Path "$k/.git"); if ($gi) { git init -q $k }
$kbr = foreach ($kbv in '', 'trunk') { if ($kbv) { & $J @{ kitBranch = $kbv } $dkl }; foreach ($kbb in 'main', 'trunk') { "$($kbv)/$($kbb):$((& $D guard -Json (@{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = "git push origin --delete $kbb" } } | ConvertTo-Json -Compress)) -join '' -match 'a protected kit branch')" } }
if (Test-Path $dkl) { Remove-Item $dkl }; if ($gi) { Remove-Item -Recurse -Force "$k/.git" }
Expect "guard: kit branch = kitBranch, else main ($($kbr -join ' '))" (($kbr -join ' ') -eq '/main:True /trunk:False trunk/main:False trunk/trunk:True')
Remove-TestKit $k
Complete-Tests
