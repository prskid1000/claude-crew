#Requires -Version 7
<#
crafty-config.tests.ps1: crafty.ps1 stack / check config, lib.ps1 file writes and reads (Write-KitAtomic, Read-KitText): -Touched, .claude-stack.json, switches (stack.presets, tests.fallbackRunner, protectedBranchesBase, kitBranch, items label, bug prefix, linkDefaults, guard.heavyPatterns / e2ePatterns); guard stray writes (drive root, outside every root, guard.writeRoots).
Usage: pwsh -NoProfile -File <kit>/tests/crafty-config.tests.ps1 (or tests/kit-tests.ps1 -Area crafty-config).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/container-tests.ps1', 'skills/crafty/adapters/runtimes.ps1')   # containerWhen
$k = New-TestKit config; $D =Join-Path $k 'skills/crafty/crafty.ps1'
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
$spa = "$k/skills/crafty/adapters/stack-presets.ps1"; $spNew = -not (Test-Path $spa); if ($spNew) { New-Item -ItemType Directory -Force (Split-Path $spa) | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/stack-presets.ps1') $spa }
$dk1 = if (Test-Path $dkl) { Get-Content $dkl -Raw }
if (Test-Path $dkl) { Remove-Item $dkl }; $s0 = "$(pwsh @np $swf $D $gd $td 2>&1)"
Set-JsonFile $dkl @{ stack = @{ presets = @() }; tests = @{ fallbackRunner = 'none' }; linkDefaults = @(); guard = @{ heavyPatterns = @('\bbazel\s+(build|test)\b'); e2ePatterns = @('\btestcafe\b') }
  protectedBranchesBase = @('main', 'master', 'develop', 'release/*', 'staging', 'staging/*', 'production', 'production/*', 'prod/*', 'hotfix/*', 'critical/*') }
$s1 = "$(pwsh @np $swf $D $gd $td 2>&1)"
$gj = { param($c) @{ tool_name = 'Bash'; cwd = $gd; tool_input = @{ command = $c } } | ConvertTo-Json -Compress }
$hb = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; $he = (pwsh @np $D guard -Json (& $gj 'npx testcafe chrome t.js') 2>&1) -join '' -match 'e2e runs go through'
$pgv = { @(foreach ($pc in 'git push origin --force-with-lease HEAD:hotfix/x', 'git push origin HEAD:staging', 'git push origin HEAD:f/x --force-with-lease') { (pwsh @np $D guard -Json (& $gj $pc) 2>&1) -join '' -match 'force-push|refused: a protected branch' }) -join ',' }; $pg1 = & $pgv; $dm1 = "$(pwsh -NoProfile -c "`$env:KIT_TRACKER_TYPE = 'none'; . '$D'; Test-KitDeployMr app hotfix/x main" 2>&1)"
Set-JsonFile $dkl @{ stack = @{ presets = @('presets') }; tests = @{ fallbackRunner = 'spec' } }; $s2 = "$(pwsh @np $swf $D $gd $td 2>&1)"
if ($dk1) { $dk1 | Set-Content $dkl } else { Remove-Item $dkl }
$hn = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; $pg0 = & $pgv; $dm0 = "$(pwsh -NoProfile -c "`$env:KIT_TRACKER_TYPE = 'none'; . '$D'; Test-KitDeployMr app hotfix/x main" 2>&1)"
Expect "protectedBranchesBase: the legacy list denies force-with-lease and direct pushes to hotfix/* and staging and makes hotfix/* a deploy-MR source; default: allowed, a task MR; own branch always passes ($pg1 $dm1 | $pg0 $dm0)" ($pg1 -eq 'True,True,False' -and $dm1 -eq 'True' -and $pg0 -eq 'False,False,False' -and $dm0 -eq 'False')
Expect "config switches: unset = presets on, no fallback runner (spec.mjs opt-in), base main/master/develop/release, node_modules+.venv; set = presets off, no fallback, the legacy branch list, no links, guard extras deny ($s0 | $s1 | $s2 | $hb $he $hn)" (
  $s0 -match '^stack=go\|spec=null\|keep=True,False,False\|links=node_modules\+\.venv$' -and $s1 -match '^stack=none\|spec=null\|keep=True,True,True\|links=( .*no preset detects|$)' -and
  $s2 -match '^stack=go\|spec=node .*spec\.mjs.* \{tests\}' -and $hb -and $he -and -not $hn)
# (cap move from guard) stray writes (D:\tmpj.txt, D:\c.md): a new file at a drive root or outside every root is denied per write pattern; guard.writeRoots lets an owner-asked place through
$swr = Invoke-PsTest 'guard-stray' @'
$d, $kd = $args; $dq = [IO.Path]::GetPathRoot($kd); $dm = '/' + $dq.Substring(0, 1).ToLower(); $sf = "kit-stray-$PID"; $dr = 'at a drive root'; $ou = 'outside the workspace'
$cases = @(@('Bash', "crafty.ps1 wt new x > $dq$sf.txt", $dr), @('Bash', "pokey.ps1 deployed > $dm/$sf.txt", $dr), @('Bash', "echo x >> `"$dq$sf.md`"", $dr),
  @('Bash', "git log | tee $dq$sf.txt", $dr), @('Bash', "cp a.txt $dq", $dr), @('Bash', "cd $dm/ && git log > $sf.txt", $dr),
  @('PowerShell', "git log | Out-File -FilePath $dq$sf.txt", $dr), @('PowerShell', "Set-Content -Path $dq$sf.txt -Value 1", $dr),
  @('PowerShell', "[IO.File]::WriteAllText('$dq$sf.txt', 'x')", $dr), @('PowerShell', "'p' | Set-Content `"/$sf.txt`"", $dr), @('PowerShell', "git init -q --bare /$sf.git", $dr),
  @('PowerShell', "git clone -q $kd /$sf", $dr), @('PowerShell', "git log > /dev/null; git log > /dev/stderr; git clone -q -b main /$sf.git; git init -b main; git clone https://h.example/r.git", ''),
  @('Bash', "git clone https://h.example/r.git $dm/$sf 2>&1", $dr), @('Bash', "git -c a=b clone git@h.example:r.git $dm/$sf", $dr), @('PowerShell', "git init $sf", $dr, $dq),@('Write', "$dq$sf.md", $dr), @('Bash', "echo x > ~/$sf.txt", $ou), @('Write', "~/$sf/notes.md", $ou),
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
Expect "guard: new files at a drive root or outside every root denied (redirect, tee, cp, cd + redirect, Out-File, Set-Content, WriteAllText, Write, PowerShell /x, git init / clone <dir>); reads, /dev/null, nul, kit, ~/.claude, Downloads, guard.writeRoots pass ($swr)" (-not "$swr".Trim())
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
# retro tidy-6: mr usage names the body caps (a test kit without templates.md has none)
$mrU = & $py -X utf8 $dtU mr --help 2>&1 | Out-String
Expect 'devtools.py mr --help: the mr-title / mr-body limits follow the usage line' ($mrU -match 'devtools\.py mr <worktree>' -and (-not (Test-Path (Join-Path $k 'skills/crafty/templates.md')) -or ($mrU -match 'mr-body: .* limits .*\d+b' -and $mrU -match 'mr-title: .* limits ')))
# K32: cases add on a shared task merges a second agent's goals / env per item; title / change stay first-wins; a repeat adds nothing
$sw2 = Join-Path (Kd) 'shared'; New-Item -ItemType Directory -Force $sw2 | Out-Null
Set-JsonFile "$sw2/a.json" @{ title = 'a'; change = 'ca'; env = 'rm'; plan = @{ unit = 'x' }; checks = @(@{ id = 'S1'; goal = 'g1' }) }
Set-JsonFile "$sw2/b.json" @{ title = 'b'; change = 'cb'; env = 'hm'; setup = 's'; plan = @{ unit = 'y'; e2e = 'z' }; checks = @(@{ id = 'S2'; goal = 'g2' }) }
foreach ($n in 'AA:a', 'BB:b', 'BB:b') { $env:CLAUDE_AGENT, $f = $n -split ':'; $null = & $py -X utf8 $dtU cases add T8 "$sw2/$f.json" 2>&1 }; $env:CLAUDE_AGENT = $null
$sg = Get-Content (& $py -X utf8 $dtU cases render T8 goals) -Raw
Expect "cases add, shared task: env 'rm; BB: hm', plan per key, both goals; title / change first-wins; a repeat adds nothing" ($sg -match '# Testing goals: T8 a\b' -and $sg -match 'Change: ca\.' -and $sg -match 'Local env: rm; BB: hm,' -and $sg -match '- unit: x; BB: y' -and $sg -match '- e2e: z' -and $sg -match 'G1 \(S1\) \| g1' -and $sg -match 'G2 \(S2\) \| g2' -and ([regex]::Matches($sg, 'BB: hm')).Count -eq 1)
# guard: a script in command position is denied with its exact rewrite (retro 2026-11-17)
$gRw = foreach ($gc in 'skills/bossy/bossy.ps1 learn -Skill kitty -Kind win', 'cd x && tools/run.py --n 2', 'skills/pokey/pokey.ps1 results patch -Patch ''{"set":{"T1":{"verify":"a | b; c"}}}''', 'tools/a.py --msg it''s --n 2 | head', 'skills/pokey/pokey.ps1 api -Path "D:\x\" -Flag 1') { $gj = @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $gc } } | ConvertTo-Json -Compress; (pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') guard -Json $gj) -join '' }
# owner 2026-11-27 (audit pick 1): the command runs rewritten (updatedInput), the rest of the line verbatim; what Bash cannot parse stays denied
$gRwTo = @($gRw | ForEach-Object { $ro = $_ | ConvertFrom-Json; if ($ro.hookSpecificOutput.updatedInput) { $ro.hookSpecificOutput.updatedInput.command } else { 'DENY ' + $ro.hookSpecificOutput.permissionDecisionReason } })
Expect "guard: a .ps1 / .py in command position runs rewritten through pwsh -File / python -X utf8, the rest verbatim ($($gRwTo -join ' | '))" ($gRwTo[0] -ceq 'pwsh -NoProfile -File skills/bossy/bossy.ps1 learn -Skill kitty -Kind win' -and $gRwTo[1] -ceq 'cd x && python -X utf8 tools/run.py --n 2' -and
  $gRwTo[2] -ceq 'pwsh -NoProfile -File skills/pokey/pokey.ps1 results patch -Patch ''{"set":{"T1":{"verify":"a | b; c"}}}''' -and $gRwTo[3] -match '^DENY kit guard: Bash cannot parse' -and $gRwTo[4] -match '^DENY kit guard: Bash cannot parse')
$gEnv = foreach ($gc in "export CLAUDE_AGENT='t'; & skills/bossy/bossy.ps1 track add -Mrs 'r!9' 2>&1 | tail -5", "`$env:CLAUDE_AGENT='p'; & skills/bossy/bossy.ps1 launch -List") { $gj = @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $gc } } | ConvertTo-Json -Compress; "$(((pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') guard -Json $gj) -join '' | ConvertFrom-Json).hookSpecificOutput.updatedInput.command)" }
Expect "guard rewrite keeps 2>&1 and an env var set before it (Bash: `$env:X= becomes export X=; retro 2026-11-22: $($gEnv -join ' | '))" ($gEnv[0] -ceq "export CLAUDE_AGENT='t'; pwsh -NoProfile -File skills/bossy/bossy.ps1 track add -Mrs 'r!9' 2>&1 | tail -5" -and $gEnv[1] -ceq "export CLAUDE_AGENT='p'; pwsh -NoProfile -File skills/bossy/bossy.ps1 launch -List")
# a heredoc fed to pwsh -Command - is PowerShell: & <script>.ps1 there runs in place (retro 2026-11-22: 50+ false blocks)
$gHd = foreach ($gc in "pwsh -NoProfile -Command - <<'EOF'`n`$j = 'a'`n& 'skills/pokey/pokey.ps1' results patch -Code T1`nEOF", "cat <<'PS' | pwsh -NoProfile -Command -`n& skills/pokey/pokey.ps1 api`nPS", "bash <<'EOF'`nskills/pokey/pokey.ps1 api`nEOF") {
  $gj = @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = $gc } } | ConvertTo-Json -Compress; $gho = (pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') guard -Json $gj) -join ''; $(if ($gho -match '"deny"') { 'deny' } elseif ($gho -match '"updatedInput"') { 'rw' } else { 'allow' }) }
Expect "guard: & pokey.ps1 in a pwsh heredoc (either form) runs; the same in a bash heredoc runs rewritten through pwsh -File ($($gHd -join ','))" (($gHd -join ',') -eq 'allow,allow,rw')
# org names from config, one name for writer and readers: tracker.taskTemplate items label, kindPrefixes.bug (Get-KitItemsLabel, Get-KitKindPrefix)
$ilr = Invoke-PsTest itemslabel @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; . $args[1]; $kl = Join-Path $KitConf.Kit 'skills/crafty/kit.local.json'
"def:$((Get-KitItemsLabel) -eq 'Items' -and (@(Get-KitItemsLabel -All) -join ',') -eq 'Items,Bugs' -and (@(Get-KitDescItems "**Bugs:**`n- B1 x").id -join ',') -eq 'B1' -and (Test-KitBugName '[Bug] x') -and "$((Get-KitNameKind '[Chore] Shop — A1 x').kind)|$((Get-KitNameKind 'Plain name').kind)|$((Get-KitNameKind '[Chore] Shop — A1 x').rest)" -eq 'Chore|Feature|Shop — A1 x' -and (Format-KitBugName 'Shop — x') -eq '[Bug] Shop — x' -and (Format-KitBugName ' [Bug] y') -eq '[Bug] y' -and (Format-KitBugName '[ui] Login broken') -eq '[Bug] [ui] Login broken')"
$c = @{ tracker = @{ kindPrefixes = @{ bug = 'Defect:'; feature = 'Story:' }; taskTemplate = @(@{ key = 'items'; label = 'Scope'; required = 'subtask' }) } }; Set-Content $kl ($c | ConvertTo-Json -Depth 6); $script:__cfg = $c | ConvertTo-Json -Depth 6 | ConvertFrom-Json
"custom:$((Get-KitItemsLabel) -eq 'Scope' -and (@(Get-KitDescItems "**Scope:**`n- S1 y").id -join ',') -eq 'S1' -and (@(Get-KitDescItems "**Items:**`n- I1 z").id -join ',') -eq 'I1' -and (Test-KitBugName 'Defect: x') -and (Get-KitKindPrefix 'bug') -eq 'Defect:' -and "$((Get-KitNameKind 'Story: Shop — x').kind)|$((Get-KitNameKind 'Story: Shop — x').rest)|$((Get-KitNameKind 'Defect: y').kind)" -eq 'feature|Shop — x|bug' -and (Format-KitBugName '[Bug] Shop — x') -eq 'Defect: Shop — x')"
'@ @($D, (Join-Path $src 'skills/bossy/adapters/task-rollup.ps1'))
Expect-Each $ilr 'items label / bug prefix / name kind (Get-KitNameKind) from config: #' 'def', 'custom' -Show 5
# testers never type [Bug]: a keyed defect's free-text name gets tracker.kindPrefixes.bug (a typed [Bug] swapped); a spec's typed kind prefix re-rendered, [ui] kept
Set-JsonFile $dkl @{ tracker = @{ kindPrefixes = @{ bug = 'DEFECT:' } } }; $env:KIT_TRACKER_TYPE = 'none'
$prefixBugNames = @('Crash on save', '[Bug] Invoice totals wrong' | ForEach-Object { $prefixBugId = (pwsh -NoProfile -File $D tracker create -Key "qa-fx-prefix-$($_.Length)" -List L1 -Name $_ -Description 'd' | ConvertFrom-Json).id; (pwsh -NoProfile -File $D tracker view $prefixBugId | ConvertFrom-Json).name })
$prefixSpecName = Invoke-PsTest specname @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; "$(Get-KitSpecName @{ kind = 'bug'; title = '[Bug] Crash'; code = 'B1' })|$(Get-KitSpecName @{ kind = 'feature'; title = '[ui] Cart'; code = 'C2' })"
'@ @($D)
Remove-Item Env:KIT_TRACKER_TYPE; Remove-Item $dkl
Expect "tracker create / spec name: the configured bug prefix added, a typed [Bug] swapped, [ui] kept ($($prefixBugNames -join ' | ') $(@($prefixSpecName)[-1]))" (($prefixBugNames -join '|') -eq 'DEFECT: Crash on save|DEFECT: Invoice totals wrong' -and @($prefixSpecName)[-1] -eq 'DEFECT: Crash|[ui] Cart')
# guard: the kit's protected branch = kitBranch, else main
$gi = -not (Test-Path "$k/.git"); if ($gi) { git init -q $k }
$kbr = foreach ($kbv in '', 'trunk') { if ($kbv) { & $J @{ kitBranch = $kbv } $dkl }; foreach ($kbb in 'main', 'trunk') { "$($kbv)/$($kbb):$((& $D guard -Json (@{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = "git push origin --delete $kbb" } } | ConvertTo-Json -Compress)) -join '' -match 'a protected kit branch')" } }
if (Test-Path $dkl) { Remove-Item $dkl }; if ($gi) { Remove-Item -Recurse -Force "$k/.git" }
Expect "guard: kit branch = kitBranch, else main ($($kbr -join ' '))" (($kbr -join ' ') -eq '/main:True /trunk:False trunk/main:False trunk/trunk:True')
# 2026-11-19: ng serve on localhost (= ::1 on Windows) never passed envy's IPv4 port check: rm web-old restarted every 10 min
$ng = Join-Path (Kd) 'ng'; New-Item -ItemType Directory -Force $ng | Out-Null; '{}' | Set-Content "$ng/angular.json"; '{ "name": "x" }' | Set-Content "$ng/package.json"
$ngRun = "$((pwsh @np $D stack -Dir $ng -Json | ConvertFrom-Json).commands.run)"
Expect "stack: the angular run binds 127.0.0.1 ($ngRun)" ($ngRun -eq 'npx ng serve --host 127.0.0.1 --port {port}')
# wt commit never stages test-run output (commit.ignore default; retro 2026-11-22)
$ci = Join-Path (Kd) 'commit-ignore'; New-Item -ItemType Directory -Force "$ci/web/cypress/screenshots", "$ci/web/cypress/reports", "$ci/web/src" | Out-Null; 'x' | Set-Content "$ci/a.txt"; Save-GitRepo $ci i
'y' | Set-Content "$ci/web/src/b.ts"; 'png' | Set-Content "$ci/web/cypress/screenshots/s.png"; 'r' | Set-Content "$ci/web/cypress/reports/r.json"
$null = pwsh @np $D wt commit -Dir $ci -Message 'feat: add the b module' 2>&1; $cic = $LASTEXITCODE; $cif = @(git -C $ci show --name-only --format= HEAD)
$null = pwsh @np $D wt commit -Dir $ci -Paths web -Message 'feat: stage web only' -AllowEmpty 2>&1
Expect "wt commit: cypress screenshots / reports stay out (with -Paths too); the source change goes in ($cic; $($cif -join ', '))" ($cic -eq 0 -and ($cif -join ',') -eq 'web/src/b.ts' -and -not (git -C $ci diff --cached --name-only) -and @(git -C $ci status --porcelain --untracked-files=all).Count -eq 2)
# process.docs drives the task spec's doc links: a one-doc set (AI only) shows only that doc (an old docs.human never lands on it);
# keyed docs from devtools.py finish are URL-checked like the old human / ai pair
$pdR = & { . $D; $__cfg = '{"process":{"docs":[{"key":"testing-ai","label":"AI doc"}]}}' | ConvertFrom-Json
  $old = [pscustomobject]@{ title = 't'; problem = 'p'; docs = [pscustomobject]@{ human = 'https://h/1'; ai = 'https://h/2' } }
  $txt = Format-KitTaskText $old; "one:$($txt -match '\*\*AI doc:\*\* \[open\]\(https://h/2\)' -and $txt -notmatch 'h/1')"
  "keyed:$((@(Test-KitTaskSpec ([pscustomobject]@{ title = '[Bug] t'; problem = 'p'; docs = [pscustomobject]@{ 'testing-ai' = 'not-a-url' } })) -join ' | ') -match "a full URL instead of 'not-a-url'")" }
Expect-Each $pdR 'task spec doc links from process.docs: #' 'one', 'keyed' -Show 4
# retro 1549: CLAUDE_RUNTIME '<kit name>/.runtime' is workspace-relative (it made <kit>/.claude/.runtime); '.rt2' stays kit-relative
$rtw = Invoke-PsTest rt-ws @'
$rtv = 'CLAUDE_RUNTIME'; [Environment]::SetEnvironmentVariable($rtv, "$(Split-Path $args[1] -Leaf)/.runtime"); . $args[0]; $a = Get-KitRuntime; $p = & $args[2] -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import kitbag; print(kitbag.runtime_dir())" (Join-Path $args[1] 'skills/bossy')
[Environment]::SetEnvironmentVariable($rtv, '.rt2'); "$([IO.Path]::GetFullPath($a) -eq [IO.Path]::GetFullPath((Join-Path $args[1] '.runtime')))|$([IO.Path]::GetFullPath("$p") -eq [IO.Path]::GetFullPath((Join-Path $args[1] '.runtime')))|$(Get-KitRuntime)"
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), $k, $py)
Expect "runtime: '<kit name>/.runtime' resolves from the workspace (lib.ps1, kitbag.py), '.rt2' from the kit ($rtw)" ("$rtw" -match "True\|True\|$([regex]::Escape((Join-Path $k '.rt2')))")
# run 1123: a kit key tracked where the tracker wants its native id read as "no testing-doc link"; now: a read keyed task maps it, else refused
$rvK = pwsh -NoProfile -Command "`$env:KIT_TRACKER_TYPE = 'command'; . '$k/skills/crafty/lib.ps1'; Save-TrackerKey ([pscustomobject]@{ id = 'n42'; name = 'AB-CD-007 [Feature] Ui: x' }); `$x = try { Resolve-TrackerId 'AB-CD-008' } catch { 'refused ' + `$_ }; `"`$(Resolve-TrackerId 'AB-CD-007')|`$(Resolve-TrackerId 'n9')|`$(Resolve-TrackerId 'AB-CD-008' -Soft)|`$x|`$(Test-KitHeldLine 'ATTENTION AB-CD-007: MRs merged, task id not readable: x' @('AB-CD-007'))`"" 2>&1 | Out-String
$gtx = Get-Content (Join-Path $k 'skills/crafty/adapters/process-gates.ps1') -Raw
Expect "tracker ids: a kit key -> the native id a read recorded; unknown key refused with the hint (url: kept); an unread task says 'task id not readable', a held one drops that line ($($rvK.Trim()))" ($rvK.Trim() -match '^n42\|n9\|AB-CD-008\|refused .*AB-CD-008 is a kit key, not a command task id: pass the native id.*\|True$' -and $gtx -match 'task id not readable: ')
# repos[].commitStyle (retro tidy-20261124-01: a commitlint hook only warned): a miss refused, -ProseOk too; a bad regex named
$csr = Join-Path (Kd) 'cs-repo'; New-Item -ItemType Directory -Force $csr | Out-Null; 'i' | Set-Content "$csr/i.txt"; Save-GitRepo $csr i
& $J @{ repos = @(@{ name = 'cs-repo'; commitStyle = '^web/ui: .{8,}' }) } $dkl; 'cs' | Set-Content "$csr/cs.txt"
$csNo = pwsh @np $D wt commit -Dir $csr -Message 'fix: no repo prefix here' -ProseOk x 2>&1 | Out-String; $csNoc = $LASTEXITCODE
$null = pwsh @np $D wt commit -Dir $csr -Message 'web/ui: with the repo prefix' 2>&1; $csOk = $LASTEXITCODE; $csLog = "$(git -C $csr log -1 --format=%s)"
& $J @{ repos = @(@{ name = 'cs-repo'; commitStyle = '([' }) } $dkl; 'c2' | Set-Content "$csr/c2.txt"; $csBad = pwsh @np $D wt commit -Dir $csr -Message 'web/ui: a bad regex now' 2>&1 | Out-String; $csBadc = $LASTEXITCODE; Remove-Item $dkl
Expect "wt commit: repos[].commitStyle refuses a miss even with -ProseOk, a match commits, a bad regex is named ($csNoc $csOk $csBadc)" ($csNoc -eq 1 -and $csNo -match 'misses repos\[\]\.commitStyle' -and $csOk -eq 0 -and $csLog -eq 'web/ui: with the repo prefix' -and $csBadc -eq 1 -and $csBad -match 'is no valid regex')
# repos[].commitMarker (owner 2026-11-26: CI failed 22 of 51 MR heads the repo's commit hook had not marked): wt commit says so at once, before any push
& $J @{ repos = @(@{ name = 'cs-repo'; commitMarker = '☑ hooks' }) } $dkl; 'm1' | Set-Content "$csr/m1.txt"
$cmNoRaw = pwsh @np $D wt commit -Dir $csr -Message 'fix: no hook ran for this one' 2>&1; $cmNoc = $LASTEXITCODE; $cmNo = ($cmNoRaw | ForEach-Object { "$_" }) -join "`n"   # stderr as text: pwsh 7.4 wraps an ErrorRecord at the console width
$null = New-Item -ItemType Directory -Force "$csr/.git/hooks"; [IO.File]::WriteAllText("$csr/.git/hooks/prepare-commit-msg", "#!/bin/sh`nprintf '\n☑ hooks\n' >> `"`$1`"`n"); 'm2' | Set-Content "$csr/m2.txt"
$cmOk = pwsh @np $D wt commit -Dir $csr -Message 'fix: the hook marks this one' 2>&1 | Out-String; $cmOkc = $LASTEXITCODE; Remove-Item $dkl
Expect "wt commit: a head without repos[].commitMarker exits 1 naming it and the amend, a hook-marked one passes ($cmNoc $cmOkc $(($cmNo.Trim() -split "`n")[-1]) // $($cmOk.Trim()))" ($cmNoc -eq 1 -and $cmNo -match "(?s)lacks repos\[\]\.commitMarker '.{1,4} hooks'.*commit --amend --no-edit" -and $cmOkc -eq 0 -and $cmOk -notmatch 'commitMarker')
# wt sync, a real-code conflict (no repos[].regenerate): refused mid-rebase (sync and commit), resolved + added -> continued on the branch (retro 2026-11-25)
$rcBare = Join-Path (Kd) 'rc.git'; $rcRepo = Join-Path (Kd) 'rc'; git init -q --bare $rcBare; git clone -q $rcBare $rcRepo 2>$null; 'a' | Set-Content "$rcRepo/a.txt"; Save-GitRepo $rcRepo base
git -C $rcRepo branch -M main; git -C $rcRepo push -q origin main 2>$null; git -C $rcRepo checkout -q -b rc; 'mine' | Set-Content "$rcRepo/c.txt"; Save-GitRepo $rcRepo rc1
git -C $rcRepo checkout -q main; 'theirs' | Set-Content "$rcRepo/c.txt"; Save-GitRepo $rcRepo rc0; git -C $rcRepo push -q origin main 2>$null; git -C $rcRepo checkout -q rc; 'main' | Set-Content "$rcRepo/.git/claude-target"
$rcs = foreach ($rcStep in 'conflict', 'open', 'commit', 'resolved') {
  if ($rcStep -eq 'resolved') { 'both' | Set-Content "$rcRepo/c.txt"; git -C $rcRepo add c.txt }
  $rcOut = if ($rcStep -eq 'commit') { pwsh @np $D wt commit -Dir $rcRepo -Message 'wip: x' 2>&1 } else { pwsh @np $D wt sync -Dir $rcRepo 2>&1 }
  "$rcOut rc=$LASTEXITCODE br=$(git -C $rcRepo branch --show-current)" }
Expect "wt sync: a conflict exits 1 (no 'rebased onto'); resumed unresolved and wt commit refused; resolved: continued on the branch ($($rcs -join ' | '))" ($rcs[0] -match 'REBASE CONFLICT.*rc=1' -and $rcs[0] -notmatch 'rebased onto' -and
  $rcs[1] -match 'rebase is in progress.*unresolved: c\.txt.*rc=1' -and $rcs[2] -match 'commit refused: a rebase is in progress.*rc=1' -and $rcs[3] -match 'resumed rebase finished on rc.*rc=0 br=rc$' -and (Get-Content "$rcRepo/c.txt") -eq 'both')
# wt sync before a merge (-Mrs): the target changed only other files -> no rebase (no push, no 2nd CI run); without -Mrs it rebases
$djBare = Join-Path (Kd) 'dj.git'; $djRepo = Join-Path (Kd) 'dj'; git init -q --bare $djBare; git clone -q $djBare $djRepo 2>$null; 'a' | Set-Content "$djRepo/a.txt"; Save-GitRepo $djRepo base
git -C $djRepo branch -M main; git -C $djRepo push -q origin main 2>$null; git -C $djRepo checkout -q -b dj; 'mine' | Set-Content "$djRepo/b.txt"; Save-GitRepo $djRepo dj1
git -C $djRepo checkout -q main; 'theirs' | Set-Content "$djRepo/m.txt"; Save-GitRepo $djRepo m1; git -C $djRepo push -q origin main 2>$null; git -C $djRepo checkout -q dj; 'main' | Set-Content "$djRepo/.git/claude-target"
$djHead = git -C $djRepo rev-parse HEAD; $djA = pwsh @np $D wt sync -Dir $djRepo -Mrs '!7' 2>&1 | Out-String; $djSame = (git -C $djRepo rev-parse HEAD) -eq $djHead
$djB = pwsh @np $D wt sync -Dir $djRepo 2>&1 | Out-String
git -C $djRepo checkout -q main; 'x' | Set-Content "$djRepo/m2.txt"; Save-GitRepo $djRepo m2; git -C $djRepo push -q origin main 2>$null; git -C $djRepo checkout -q dj
& $J @{ repos = @(@{ name = 'dj'; mergeMethod = 'ff' }) } $dkl; $djF = pwsh @np $D wt sync -Dir $djRepo -Mrs '!7' 2>&1 | Out-String; Remove-Item $dkl
git -C $djRepo checkout -q main; 'y' | Set-Content "$djRepo/b.txt"; Save-GitRepo $djRepo m3; git -C $djRepo push -q origin main 2>$null; git -C $djRepo checkout -q dj
$djO = pwsh @np $D wt sync -Dir $djRepo -Mrs '!7' 2>&1 | Out-String; git -C $djRepo rebase --abort 2>$null
Expect "wt sync -Mrs still rebases: repos[].mergeMethod ff, or the target touched a branch file ($djF | $djO)" ($djF -match 'rebased onto' -and $djO -match 'REBASE CONFLICT|rebased onto' -and $djO -notmatch 'rebase skipped')
Expect "wt sync -Mrs: target touched no file of the branch -> rebase skipped, HEAD kept; plain sync rebases ($djA | $djB)" ($djA -match 'rebase skipped: origin/main changed 1 file' -and $djSame -and $djB -match 'rebased onto origin/main')
# wt commit -ScopeOk <id>: a scope word keyed by a brief item id (not the branch) lets it through (dec-38 / dec-52 cases)
$soRepo = Join-Path (Kd) 'scope-ok'; New-Item -ItemType Directory -Force "$soRepo/specs", "$soRepo/src" | Out-Null; 'a' | Set-Content "$soRepo/specs/a.cy.js"; Save-GitRepo $soRepo base
git -C $soRepo checkout -q -b b2; Set-Content "$soRepo/.git/claude-scope" 'specs/**'; 'z' | Set-Content "$soRepo/src/Four.java"; $null = pwsh @np $D wt commit -Dir $soRepo -Message 'fix: four' 2>&1; $soCodes = "$LASTEXITCODE"
$soId = "$(pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') decide record -Gate scope -Item 'G7-account' -Question 'src in a spec area?' -Answer yes -Source chat 2>&1)" -replace '(?s)^.*RECORDED (\S+).*$', '$1'
$null = pwsh @np $D wt commit -Dir $soRepo -Message 'fix: four' -ScopeOk $soId 2>&1; $soCodes += "/$LASTEXITCODE"
Expect "wt commit -ScopeOk: an item-keyed scope word lets the commit through, none refuses ($soCodes)" ($soCodes -eq '1/0' -and (git -C $soRepo log -1 --format=%s) -eq 'fix: four')
# a source edited while the step runs: its result is not kept (the next run on that tree reruns)
$sd = Join-Path (Kd) 'race-repo'; New-Item -ItemType Directory -Force "$sd/src" | Out-Null; 'r' | Set-Content "$sd/src/r.txt"
$raceJs = Join-Path (Kd) 'stamp-race.js'; "require('fs').appendFileSync(process.argv[2] === 'A' ? String.raw``$sd/src/r.txt`` : String.raw``$sd.out``, 'x')" | Set-Content $raceJs
(@{ stack = 'custom'; commands = @{ test = "node `"$raceJs`" {tests}" } } | ConvertTo-Json) | Set-Content "$sd/.claude-stack.json"; git -C $sd init -q; git -C $sd add -A; git -C $sd -c user.name=t -c user.email=t@t commit -q -m init
$slotsOf = { @((Get-Content (pwsh -NoProfile -Command ". '$(Lib)'; Get-CheckStampFile '$sd'") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable).Values | Where-Object { $_ -and -not $_.rc }).Count }
$rc1 = pwsh @np $D check -Dir $sd -Step test -Tests A 2>&1 | Out-String; $rs1 = & $slotsOf; $null = pwsh @np $D check -Dir $sd -Step test -Tests B 2>&1; $rs2 = & $slotsOf
# tests.containerWhen (owner 2026-11-25): container / IT tests alone run here only when the diff touches a persistence glob; mixed
# with unit tests they run (with a hint); a matching change runs them (no engine here: exit 4)
$ctd = Join-Path (Kd) 'ct-repo'; $ctm = Join-Path $ctd 'api'; $ctb = Join-Path (Kd) 'ct-bin'; New-Item -ItemType Directory -Force $ctm, $ctb | Out-Null
'<project><dependency>org.testcontainers</dependency></project>' | Set-Content "$ctm/pom.xml"; '{ "stack": "java-maven", "commands": { "test": "echo {tests}" } }' | Set-Content "$ctm/.claude-stack.json"
if ($IsWindows) { foreach ($x in 'docker', 'podman') { '@exit /b 1' | Set-Content "$ctb/$x.cmd" } } else { foreach ($x in 'docker', 'podman') { "#!/bin/sh`nexit 1" | Set-Content "$ctb/$x"; chmod +x "$ctb/$x" } }
git -C $ctd init -q; git -C $ctd add -A; git -C $ctd -c user.name=t -c user.email=t@t commit -q -m init
$ctCf = Join-Path $k 'skills/crafty/kit.local.json'; $ctWas = Get-Content $ctCf -Raw -ErrorAction SilentlyContinue   # an earlier case's switches (presets off) would hide the JVM prep
& $J @{ tests = @{ containerWhen = @{ 'ct-repo/*' = @('**/repository/**', '**/liquibase/**') } } } $ctCf
$ctP0 = $env:PATH; $env:PATH = "$ctb$([IO.Path]::PathSeparator)$env:PATH"; $ctRun = { param([string]$T) $o = pwsh @np $D check -Dir $ctm -Step test -Tests $T 2>&1 | Out-String; "${LASTEXITCODE}:$([int]($o -match 'left to CI')):$([int]($o -match 'name the unit tests alone')):$([int]($o -match 'touches persistence'))" }
$ctr = @(& $ctRun 'OrderIT'; & $ctRun 'OrderIT,OrderTest'; (New-Item -Force -ItemType File "$ctm/src/main/java/a/repository/R.java" | Out-Null); & $ctRun 'OrderIT')
$env:PATH = $ctP0; if ($ctWas) { Set-Content $ctCf $ctWas -NoNewline } else { Remove-Item $ctCf }
Expect "check: tests.containerWhen leaves container tests to CI without a persistence change; mixed run with a hint; a repository change runs them ($($ctr -join ' '))" (($ctr -join ' ') -eq '0:1:0:0 4:0:1:0 4:0:0:1')
Expect "check stamps: an edit during the run is said and not stamped; a clean run is ($([int]($rc1 -match 'changed during')) $rs1 $rs2)" ($rc1 -match 'sources changed during the run' -and $rs1 -eq 0 -and $rs2 -eq 1)
# repos[].targets (owner 2026-11-27): one repo, several main lines by path; unmatched paths default, two lines refused, devtools.py agrees
$mlCf = Join-Path $k 'skills/crafty/kit.local.json'; $mlWas = Get-Content $mlCf -Raw -ErrorAction SilentlyContinue
& $J @{ repos = @(@{ name = 'ml-web'; target = 'rm/new'; targets = @(@{ branch = 'main'; paths = @('hm/web/**'); label = 'hm' }, @{ branch = 'rm/new'; paths = @('rm/web/**'); label = 'rm new' }) }) } $mlCf
$mlRes = pwsh -NoProfile -Command ". '$(Lib)'; `$r = foreach (`$p in @('hm/web/a.ts'), @('rm/web/a.ts'), @('common/x.ts'), @('common/x.ts', 'hm/web/b.ts'), @()) { Resolve-KitTarget 'ml-web' `$p }; `$r -join ' '; try { Resolve-KitTarget 'ml-web' @('hm/web/a.ts', 'rm/web/a.ts') } catch { 'REFUSED ' + `$_.Exception.Message }; (Get-KitMainLines 'ml-web') -join ','" 2>&1 | Out-String
$mlPy = "$(python -X utf8 -c "import sys; sys.path.insert(0, r'$k/skills/crafty'); import devtools as m; r = {'name': 'w', 'target': 'rm/new', 'targets': [{'branch': 'main', 'paths': ['hm/web/**']}]}; print(m.resolve_target(r, ['hm/web/a.ts']), m.resolve_target(r, ['x']))" 2>&1)"
if ($mlWas) { Set-Content $mlCf $mlWas -NoNewline } else { Remove-Item $mlCf }
Expect "repos[].targets: the touched paths pick the main line, a change on two is refused, python agrees ($($mlRes.Trim() -replace '\s+', ' ') | $mlPy)" ($mlRes -match 'main rm/new rm/new main rm/new' -and $mlRes -match 'REFUSED main lines: .*main and rm/new' -and $mlRes -match 'rm/new,main' -and $mlPy -eq 'main rm/new')
Remove-TestKit $k
Complete-Tests
