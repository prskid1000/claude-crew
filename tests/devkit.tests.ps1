#Requires -Version 7
<#
devkit.tests.ps1: dev.ps1 wt / check / gate / guard, lib.ps1 git host + tracker adapters, devtools.py.
Usage: pwsh -NoProfile -File <kit>/tests/devkit.tests.ps1 (or tests/kit-tests.ps1 -Area devkit).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit dev; $D = Join-Path $k 'skills/dev-kit/dev.ps1'; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
$r = Join-Path (Kd) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
$env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
try {
  git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
  'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
  $out = pwsh @np $D wt commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
  Expect 'wt commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $out -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
  'feat: from file' | Set-Content "$r/msg.txt"
  Push-Location "$r/outer"; $null = pwsh @np $D wt commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'wt commit -MessageFile from the current folder' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
  foreach ($n in 'a', 'ab', 'c-1', 'c-2') { git -C "$r/outer" worktree add -q -b $n "$r/wt/$n-outer" 2>$null }
  Push-Location "$r/outer"
  $bad = @(@(), @('-Dir', "$r/outer"), @('-Name', 'zz'), @('-Name', 'c')) | ForEach-Object { $a = $_; $null = pwsh @np $D wt remove @a -Force 2>&1; $LASTEXITCODE }
  $null = pwsh @np $D wt remove -Name a 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'wt remove -Name: only that worktree; main tree, no args, no match, 2 matches -> refused' (-not ($bad -contains 0) -and $code -eq 0 -and -not (Test-Path "$r/wt/a-outer") -and @('ab', 'c-1', 'c-2' | Where-Object { Test-Path "$r/wt/$_-outer" }).Count -eq 3 -and (Test-Path "$r/outer/.git"))
} finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
# git-host + ci adapters: glab replies, type command, MR URLs, a missing extra
$gh = @'
$script:calls = [Collections.Generic.List[string]]::new()
function glab { $script:calls.Add("glab $($args -join ' ')"); $global:LASTEXITCODE = 0; '{"iid":5,"state":"merged"}' }
. $args[0]
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; "gl-get:$($script:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')"
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }; "gl-put:$($script:calls[-1] -like 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f *squash=true*' -and $script:calls[-1] -like '*should_remove_source_branch=true*')"
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; $n = $script:calls.Count; $null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; "memo:$($script:calls.Count -eq $n)"
$u = 'https://h/g/s/r/-/merge_requests/4', 'https://github.com/o/r/pull/5', 'https://h/w/r/pull-requests/6', 'https://h/o/p/_git/r/pullrequest/7' | % { $x = ConvertFrom-MrUrl $_; "$($x.type):$($x.repo)!$($x.n)" }
"mr-urls:$("$u" -eq 'gitlab:g/s/r!4 github:o/r!5 bitbucket:w/r!6 azure:o/p/r!7')"
$m = Invoke-HostVerb 'mr.get' @{ type = 'command'; repo = 'o/cmd'; n = '4' }; "command:$($m.iid -eq 4 -and $m.title -eq 'o/cmd')"
$e = try { Invoke-HostVerb 'mr.get' @{ type = 'github'; repo = 'o/r'; n = '1' } } catch { "$_" }; "extra-line:$($e -eq 'git-host github is an extra: run kittool.py extra add github')"
'@
$ka = New-TestKit adapters; $cmdf = Join-Path (Split-Path $ka) 'host-cmd.ps1'; Set-Content $cmdf '[ordered]@{ iid = [int]$args[1]; state = ''merged''; title = $args[0] } | ConvertTo-Json -Compress'
& $J @{ gitHost = 'git.example'; gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$cmdf`" {repo} {n}" } } } (Join-Path $ka 'skills/dev-kit/kit.local.json') 5
$f = Join-Path (Kd) 'githost-test.ps1'; Set-Content $f $gh
$res = @(pwsh @np $f (Join-Path $ka 'skills/dev-kit/lib.ps1') 2>&1)
Expect-Each $res 'git host: #' 'gl-get', 'gl-put', 'memo', 'mr-urls', 'command', 'extra-line'
Remove-TestKit $ka
$env:KIT_TRACKER_TYPE = 'none'
$t = pwsh @np $D tracker create -List L1 -Name 'T one' -Description 'd' | ConvertFrom-Json
$null = pwsh @np $D tracker status $t.id failedTesting
$l = @(pwsh @np $D tracker list L1 failedTesting | ConvertFrom-Json)
Expect 'tracker none: create, status failedTesting, list' ($t.id -like 'LOCAL-*' -and $l.Count -eq 1 -and $l[0].id -eq $t.id)
'body text' | Set-Content "$r/c.md"; $null = pwsh @np $D tracker comment $t.id -File "$r/c.md"
$bad = pwsh @np $D tracker comment 12 -Bogus x -DryRun 2>&1 | Out-String; $badCode = $LASTEXITCODE
$said = (pwsh @np $D tracker comments $t.id | ConvertFrom-Json).text
Expect 'tracker comment -File sends it; unknown option = usage error' (@($said) -match '^body text' -and $badCode -eq 2 -and $bad -match 'unknown option -Bogus')
Remove-Item Env:KIT_TRACKER_TYPE
# tracker command backend on recorded answers (an unknown call fails)
$tb = @'
. $args[0]; $global:log = [Collections.Generic.List[string]]::new()
$__cfg = '{"tracker":{"commands":{"view":"mytr view {id}","status":"mytr status {id} {status}","comment":"mytr comment {id} {text}","create":"mytr create {list} {name}","list":"mytr list {list} {status}"}}}' | ConvertFrom-Json
$fx = [ordered]@{ '^view T1' = '{"id":"T1","name":"Bug","status":"In Progress","subtasks":[{"name":"Sub"}]}'; '^status T1 in test' = 'ok'; '^comment T1 two words' = 'ok'; '^create B New one' = '{"id":"T9"}'
 '^list B in test' = '[{"id":"T3","name":"A","assignees":[{"id":"ann"}]}]' }
function mytr { $global:LASTEXITCODE = 0; $c = "$($args -join ' ')"; $global:log.Add($c); foreach ($k in $fx.Keys) { if ($c -match $k) { return $fx[$k] } }; throw "404 no fixture: $c" }
Initialize-KitTracker -Type command
$r = @{ v = Get-TrackerTask T1; s = Set-TrackerStatus T1 inTest; c = Add-TrackerComment T1 'two words'; n = New-TrackerTask -List B -Name 'New one' -Description 'd' -Parent T1 -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks B inTest) }
"command:$($r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq 'T9' -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq 'ann')"
'@
$res = Invoke-PsTest 'tracker-test' $tb @(Join-Path $k 'skills/dev-kit/lib.ps1')
Expect-Each $res 'tracker #: view, status, comment, create, list on recorded answers' 'command'
$kv = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function T1 { param([string]`$Mode, [string[]]`$Lanes, [switch]`$Cold) ""`$Mode|`$(`$Lanes -join '+')|`$Cold"" }; `$a = @{ Lanes = 'L1'; Mode = 'None'; Cold = `$true }; & { Invoke-KitVerb T1 `$args } @a"
Expect 'Invoke-KitVerb: splatted Mode=None binds like -Mode None' ("$kv".Trim() -eq 'None|L1|True')
# a stale lock that vanishes between the check and the read (Test-Path stub removes it) must not throw
$kl = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; `$ErrorActionPreference = 'Stop'; `$f = Join-Path '$(Kd)' 'kl.json'; Set-Content `"`$f.lock`" x; (Get-Item `"`$f.lock`").LastWriteTime = (Get-Date).AddMinutes(-5); function Test-Path { Remove-Item `"`$f.lock`" -Force -ErrorAction SilentlyContinue; `$true }; try { Invoke-KitLocked `$f { 'ran' } } catch { `"threw: `$_`" }"
Expect "Invoke-KitLocked: a lock removed mid-check is no crash ($kl)" ("$kl".Trim() -eq 'ran')
# a crash in any verb exits 1 (a statement error alone kept exit 0), a bad parameter 2; rows: verb body, args, exit, stderr
$vk = foreach ($r in @(@('Nosuch-Cmd; ''after''', '', 1, 'FAILED: .*Nosuch-Cmd'), @('$null.X()', '', 1, 'FAILED'), @('''ok''', '-Mode x', 2, 'Mode'), @('''ok''', '', 0, '^$'))) {
  $e = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function Invoke-T { param([int]`$Mode) $($r[0]) }; Invoke-KitVerb Invoke-T @('$($r[1] -split ' ' -join "','")' | Where-Object { `$_ })" 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Out-String
  if ($LASTEXITCODE -ne $r[2] -or $e.Trim() -notmatch $r[3]) { "$($r[0]) -> $LASTEXITCODE $($e.Trim())" } }
Expect "Invoke-KitVerb: crash exit 1, bad parameter 2 ($vk)" (-not $vk)
$mw = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function Invoke-M { param([string]`$Message, [string[]]`$Mrs) ""`$Message|`$(`$Mrs -join '+')"" }; Invoke-KitVerb Invoke-M @('-Message', 'fix', 'the', 'bug', '-Mrs', 'a!1', 'b!2')"
Expect "Invoke-KitVerb: unquoted words join with spaces, arrays stay arrays ($mw)" ("$mw".Trim() -eq 'fix the bug|a!1+b!2')
$out = pwsh @np $D guard -SelfTest 2>&1 | Out-String
Expect 'guard self-test' ($out -match '(\d+)/\1 passed')
$out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest' ($LASTEXITCODE -eq 0)
$DT = Join-Path $k 'skills/dev-kit/devtools.py'
$th = & $py -X utf8 $DT comment --help 2>&1 | Out-String; $thc = $LASTEXITCODE; $null = & $py -X utf8 $DT comment T1 --bogus 2>&1; $tbc = $LASTEXITCODE; $null = & $py -X utf8 $DT finish T1 2>&1; $tmc = $LASTEXITCODE
$fk = Join-Path (Kd) 'flaky.py'; [IO.File]::WriteAllText($fk, "import sys, subprocess as sp; sys.path.insert(0, sys.argv[1]); import devtools as d`nn = []; hang = [0]`ndef fake(cmd, **kw):`n    n.append(cmd)`n    if hang[0]: raise sp.TimeoutExpired(cmd, 1)`n    return sp.CompletedProcess(cmd, 1 if len(n) == 1 else 0, 'connection reset' if len(n) == 1 else 'ok', '')`nd.subprocess.run = fake`nr = d._tracker('view', 'T1'); a = len(n); n.clear()`ntry: d._tracker('create', 'x')`nexcept SystemExit: pass`nw = len(n); n.clear(); hang[0] = 1; d._run(['glab', 'api', 'x']); print(r, a, w, len(n))`n")
$rt = & $py -X utf8 $fk (Split-Path $DT) 2>&1 | Out-String
Expect "devtools: --help 0, bad args 2, reads retried, writes never, hung read once ($thc $tbc $tmc $($rt.Trim()))" ($thc -eq 0 -and $th -match 'devtools\.py comment <taskId>' -and $th -notmatch 'finish' -and $tbc -eq 2 -and $tmc -eq 2 -and $rt.Trim() -eq 'ok 2 1 2')
# pipes: busy only with a head pipeline
$pt = @'
. $args[0]
$ast = [Management.Automation.Language.Parser]::ParseFile($args[1], [ref]$null, [ref]$null)
$fn = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Invoke-Pipes' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
 if ($Verb -eq 'mr.get') { if ($A.n -ne '9') { [pscustomobject]@{ state = 'opened'; head_pipeline = $null; target_branch = 'main' } } }
 elseif ($Verb -eq 'ci.config') { if ($A.repo -match 'nocirepo') { $false } else { $null } }   # no CI file / a failed call
}
$a = Invoke-Pipes -Mrs 'https://h.example/g/nocirepo/-/merge_requests/1' -MaxMinutes 0 | ConvertFrom-Json
$b = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json
$c = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/9' -MaxMinutes 0 | ConvertFrom-Json
"no-ci:$($a.done -and $a.mrs[0].status -eq 'no-ci')"
"no-pipeline:$(-not $b.done -and $b.mrs[0].status -eq 'no-pipeline')"
"unknown:$(-not $c.done -and $c.mrs[0].status -eq 'unknown')"
'@
$res = Invoke-PsTest 'pipes-test' $pt @((Join-Path $k 'skills/dev-kit/lib.ps1'), $D)
Expect-Each $res 'pipes: #' 'no-ci', 'no-pipeline', 'unknown'
# migrations: the repo's own check, Liquibase (extra), any other tool UNRUN
$ud = Join-Path (Kd) 'unrun-repo'; New-Item -ItemType Directory -Force $ud | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
git -C $ud init -q; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m init
$env:CLAUDE_GATE_KEEP_FREE_GB = '0'   # the test builds need no free-RAM reserve: a busy machine must not stall them
New-Item -ItemType Directory -Force "$ud/db/migrate", "$ud/database/migrations" | Out-Null; 'def change; end' | Set-Content "$ud/db/migrate/20240101000000_x.rb"
'x' | Set-Content "$ud/CHANGELOG.md"; '<?php' | Set-Content "$ud/database/migrations/2024_01_01_000000_x.php"; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m rb
$out = pwsh -NoProfile -File $D check -Dir $ud -Step migrations 2>&1 | Out-String
Expect 'check: migrations without a kit check or tool are UNRUN (exit 5), docs skipped' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN: 2 migration file\(s\) of another tool' -and $out -match '000000_x\.php' -and $out -notmatch 'CHANGELOG')
$tr = Join-Path (Kd) 'touched-repo'; New-Item -ItemType Directory -Force "$tr/src" | Out-Null; '{ "stack": "custom", "commands": { "test": "node -e 0" } }' | Set-Content "$tr/.claude-stack.json"
'x' | Set-Content "$tr/src/Audit.spec.ts"; git -C $tr init -q; git -C $tr add -A; git -C $tr -c user.name=t -c user.email=t@t commit -q -m i; 'x' | Set-Content "$tr/src/Audit.ts"
$out = pwsh @np $D check -Dir $tr -Step test -Touched 2>&1 | Out-String
Expect 'check -Touched: Audit.ts is no test (case-sensitive Test suffix); its spec runs' ($out -match '-Touched: 1 test\(s\) for 1 changed file\(s\): src/Audit\.spec\.ts')
New-Item -ItemType Directory -Force "$ud/alembic/versions", "$ud/prisma/migrations/1_x", "$ud/db/migration" | Out-Null
'x' | Set-Content "$ud/alembic/versions/a1_x.py"; 'x' | Set-Content "$ud/prisma/migrations/1_x/migration.sql"; 'x' | Set-Content "$ud/db/migration/V1__x.sql"
git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m tools
$out = pwsh -NoProfile -File $D check -Dir $ud -Step migrations 2>&1 | Out-String
Expect 'check: Flyway, Alembic and Prisma files are UNRUN too' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN: 5 migration file\(s\) of another tool')
New-Item -ItemType Directory -Force "$ud/config/liquibase" | Out-Null; '<databaseChangeLog/>' | Set-Content "$ud/config/liquibase/master.xml"
git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m lb
$out = pwsh -NoProfile -File $D check -Dir $ud -Step migrations 2>&1 | Out-String
Expect 'check: Liquibase without the extra is UNRUN with the extra line' ($LASTEXITCODE -eq 5 -and $out -match 'extra add liquibase')
$wd = Join-Path (Kd) 'web-no-tests'; New-Item -ItemType Directory -Force $wd | Out-Null
'{ "name": "w", "devDependencies": { "typescript": "5" } }' | Set-Content "$wd/package.json"; '{}' | Set-Content "$wd/tsconfig.json"
$out = pwsh -NoProfile -File $D check -Dir $wd -Step test -Tests x.spec.ts 2>&1 | Out-String
Expect 'check: no test target and no extra node-spec = UNRUN with the extra line' ($LASTEXITCODE -eq 5 -and $out -match 'extra add node-spec')
$sd = Join-Path (Kd) 'stack-only'; New-Item -ItemType Directory -Force $sd | Out-Null; '{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$sd/.claude-stack.json"
$out = pwsh @np $D stack -Dir $sd 2>&1 | Out-String
Expect 'stack: a .claude-stack.json alone names the stack' ($out -match 'stack: custom' -and $out -notmatch 'FAILED')   # in-process: git's exit code leaks
$out = pwsh @np $D gate -Dir $ud -Cmd 'echo gradlew build' 2>&1 | Out-String; Remove-Item Env:CLAUDE_GATE_KEEP_FREE_GB
Expect 'gate: runs the command; no heap cap without the extra build-heap' ($out -match '(?m)^gradlew build' -and $out -notmatch 'jvmargs')
# gate: half the system file cache counts as free; the head of the queue starts after 20 min above a 5% RAM floor
$gt = @'
. $args[0]
"cache:$((Get-GateAvailGB ([pscustomobject]@{ AvailGB = 13.6; CacheGB = 21 })) -eq 24.1)"
"keep:$((Test-GateStart 11 10 0 64) -and -not (Test-GateStart 9 10 5 64))"
"starved:$((Test-GateStart 4 10 25 64) -and -not (Test-GateStart 2 10 25 64))"
'@
Expect-Each (Invoke-PsTest 'gate-test' $gt @(Join-Path $k 'skills/dev-kit/lib.ps1')) 'gate: #' 'cache', 'keep', 'starved'
# guard: a non-JSON payload denies (logged); empty stdin allows
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
# an extra's guard rule may return a note: it reaches the agent as additionalContext, the call is not decided; no runtimes extra: one line
$na = Join-Path $k 'skills/dev-kit/adapters/note_test.ps1'; New-Item -ItemType Directory -Force (Split-Path $na) | Out-Null
"Register-KitAdapter 'guard' 'note' @{ check = { param(`$a) if (`$a.cmd -match 'notecmd') { @{ note = 'lease noted' } } } }" | Set-Content $na
$gn = Px $D guard -Json '{"tool_name":"Bash","tool_input":{"command":"notecmd x"}}' | Out-String; Remove-Item $na
$rt = Invoke-TestScript $D runtime status
Expect "guard: an extra's note is context, no decision; runtime without its extra exits 1 ($gn)" ($gn -match '"additionalContext":"lease noted"' -and $gn -notmatch 'permissionDecision' -and $rt.code -eq 1 -and $rt.out -match 'extra add runtimes')
$mk = Join-Path (Kd) 'main kit'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit" | Out-Null
Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"
git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
& $J @{ tracker = @{ type = 'jira' } } "$mk/skills/dev-kit/kit.local.json"
$lw = Join-Path (Kd) 'wt kit'; git -C $mk worktree add -q --detach $lw 2>$null
$tt = pwsh -NoProfile -Command ". '$lw/skills/dev-kit/lib.ps1'; Get-KitSetting 'tracker.type' 'none'; Invoke-GitFetch -Dir '$lw' -TimeoutSec 20" 2>&1 | Out-String
Expect 'lib: a linked worktree reads the main clone''s kit.local.json; fetch in a path with spaces runs (no origin: warning, $false)' ($tt -match '(?m)^jira' -and $tt -match 'git fetch in .*wt kit failed' -and $tt -match '(?m)^False')
Remove-TestKit $k
Complete-Tests
