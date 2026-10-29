#Requires -Version 7
<#
crafty.tests.ps1: crafty.ps1 wt / check / gate / guard, lib.ps1 git host + tracker adapters, devtools.py.
Usage: pwsh -NoProfile -File <kit>/tests/crafty.tests.ps1 (or tests/kit-tests.ps1 -Area crafty).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit dev; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$r = Join-Path (Kd) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
$env:CLAUDE_WT_ROOT = "$r/wt"
try {
  git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
  'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
  $out = pwsh @np $D wt commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
  Expect 'wt commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $out -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
  'feat: from file' | Set-Content "$r/msg.txt"
  Push-Location "$r/outer"; $null = pwsh @np $D wt commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'wt commit -MessageFile from the current folder' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
  Copy-Item (Join-Path $src 'skills/crafty/templates.md') (Join-Path $k 'skills/crafty')
  'z' | Set-Content "$r/outer/z.txt"; $lm = 'feat: ' + ('long subject ' * 8)
  $po = pwsh @np $D wt commit -Dir "$r/outer" -Message $lm 2>&1 | Out-String; $pc = $LASTEXITCODE; $ps = git -C "$r/outer" log -1 --format=%s
  $null = pwsh @np $D wt commit -Dir "$r/outer" -Message $lm -ProseOk 'test' 2>&1; $pk = $LASTEXITCODE
  'w' | Set-Content "$r/outer/w.txt"; $null = pwsh @np $D wt commit -Dir "$r/outer" -Message ('wip: ' + 'pause ' * 20) 2>&1; $pk += $LASTEXITCODE
  Expect "wt commit: a subject over its prose limit is refused, -ProseOk / a WIP commit pass ($pc $pk)" ($pc -eq 1 -and $po -match 'commit refused' -and $ps -eq 'feat: from file' -and $pk -eq 0 -and (git -C "$r/outer" log -2 --format=%s)[1] -eq $lm.Trim())
  foreach ($n in 'a', 'ab', 'c-1', 'c-2') { git -C "$r/outer" worktree add -q -b $n "$r/wt/$n-outer" 2>$null }
  Push-Location "$r/outer"
  $bad = @(@(), @('-Dir', "$r/outer"), @('-Name', 'zz'), @('-Name', 'c')) | ForEach-Object { $a = $_; $null = pwsh @np $D wt remove @a -Force 2>&1; $LASTEXITCODE }
  $null = pwsh @np $D wt remove -Name a 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'wt remove -Name: only that worktree; main tree, no args, no match, 2 matches -> refused' (-not ($bad -contains 0) -and $code -eq 0 -and -not (Test-Path "$r/wt/a-outer") -and @('ab', 'c-1', 'c-2' | Where-Object { Test-Path "$r/wt/$_-outer" }).Count -eq 3 -and (Test-Path "$r/outer/.git"))
  foreach ($n in 'ci', 'cu') { $w = "$r/wt/$n"; git -C "$r/outer" worktree add -q -b $n $w 2>$null; [IO.File]::WriteAllBytes("$(git -C $w rev-parse --path-format=absolute --git-dir)/index", [byte[]]::new(64)) }
  'u' | Set-Content "$r/wt/cu/u.txt"; $ci, $cu = 'ci', 'cu' | ForEach-Object { "$(pwsh @np $D wt remove -Dir "$r/wt/$_" 2>&1) rc=$LASTEXITCODE" }
  Expect "wt remove: a corrupt index is rebuilt; clean: removed, untracked file: refused" ($ci -match '(?s)rebuilt the corrupt index.*rc=0' -and -not (Test-Path "$r/wt/ci") -and $cu -match '(?s)u\.txt.*rc=[1-9]' -and (Test-Path "$r/wt/cu/u.txt"))
  $w = "$r/wt/ab-outer"; git -C "$r/outer" worktree lock "$r/wt/c-1-outer"; 'main' | Set-Content "$(git -C $w rev-parse --path-format=absolute --git-dir)/claude-target"; 'y' | Set-Content "$w/stray.txt"
  $ws = (& { pwsh @np $D wt remove -Dir "$r/wt/c-1-outer" -Force; pwsh @np $D wt sync -Dir $w; pwsh @np $D wt sync -Dir "$r/wt" } 2>&1 | Out-String) -replace '\s*\r?\n\s*\|?\s*', ' '
  Expect 'wt remove: git''s why; wt sync: dirty -> wt commit line, worktrees root -> its worktrees' ($ws -match 'remove failed.*locked' -and $ws -match 'wt commit -Dir .*ab-outer -Message ''wip: ' -and $ws -match 'holds worktrees.*-outer')
  # wt sync, repos[].regenerate: a binary generated file conflicts -> target's copy + command, amended, pushed; a failing command -> the conflict
  $g = "$r/gen"; git init -q --bare "$r/fix.git"; git clone -q "$r/fix.git" $g 2>$null; 'gen.bin binary' | Set-Content "$g/.gitattributes"; 'base' | Set-Content "$g/gen.bin"
  Save-GitRepo $g base; git -C $g push -q origin HEAD:main; git -C $g checkout -q -b f; 'mine' | Set-Content "$g/gen.bin"; 'a' | Set-Content "$g/a.txt"; Save-GitRepo $g mine; 'm2' | Set-Content "$g/gen.bin"; Save-GitRepo $g stamp
  git -C $g push -q origin f; git -C $g checkout -q main; 'theirs' | Set-Content "$g/gen.bin"; Save-GitRepo $g theirs; git -C $g push -q origin main
  git -C $g checkout -q f; 'main' | Set-Content "$g/.git/claude-target"; $kl = "$k/skills/crafty/kit.local.json"
  $sy = foreach ($run in 'node -e process.exit(3)', 'node -e "require(''fs'').writeFileSync(''gen.bin'', ''regen {mr} {target}'')"') {
    & $J @{ repos = @(@{ name = 'fix'; regenerate = @(@{ path = '*.bin'; run = $run }) }) } $kl 6
    "$(pwsh @np $D wt sync -Dir $g -Mrs '!7' 2>&1) rc=$LASTEXITCODE mid=$(Test-Path "$g/.git/rebase-merge")"; git -C $g rebase --abort 2>$null }
  Remove-Item $kl
  Expect "wt sync regenerate: failing command keeps the conflict; else target's copy + command, amended, pushed" ($sy[0] -match '(?s)regenerate failed.*REBASE CONFLICT.*rc=1 mid=True' -and $sy[1] -match 'regenerated gen\.bin.*pushed f.*rc=0' -and
    (Get-Content "$g/gen.bin") -eq 'regen 7 main' -and (git -C $g rev-list --count origin/main..origin/f) -eq 1 -and (git -C $g show --stat --format= origin/f) -match 'a\.txt')
  $wm = pwsh @np $D wt commit -Dir "$r/outer" 2>&1 | ForEach-Object { "$_" } | Out-String
  & $J @{ repos = @(@{ name = 'shop'; checkout = "$r/outer" }) } $kl
  $wn = foreach ($rn in 'nosuch', 'shop') { pwsh @np $D wt new -Repo $rn -Branch b9 -Target main -Name n9 2>&1 | ForEach-Object { "$_" } | Out-String }; Remove-Item $kl
  $pu = pwsh @np $D pipes 2>&1 | ForEach-Object { "$_" } | Out-String; $puc = $LASTEXITCODE
  $null = pwsh @np $D checkpoint -Agent c9 -Step build 2>&1; $cr = Read-Json (Join-Path (TkPath $k agents) 'c9/resume.json')
  Expect "wt commit names -MessageFile; wt new -Repo <name> via repos[].checkout; pipes: exit 2 + usage; checkpoint run adhoc-<agent> ($($cr.run))" ($wm -match '-MessageFile <file>' -and
    $wn[0] -match 'no repo nosuch' -and $wn[1] -notmatch 'no repo' -and $puc -eq 2 -and $pu -match 'Usage: pipes -Mrs' -and $cr.run -eq 'adhoc-c9')
} finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
# git-host adapters
$gh = @'
. $args[0]
$u = 'https://h/g/s/r/-/merge_requests/4', 'https://github.com/o/r/pull/5', 'https://h/w/r/pull-requests/6', 'https://h/o/p/_git/r/pullrequest/7' | % { $x = ConvertFrom-MrUrl $_; "$($x.type):$($x.repo)!$($x.n)" }
"mr-urls:$("$u" -eq 'gitlab:g/s/r!4 github:o/r!5 bitbucket:w/r!6 azure:o/p/r!7')"
$m = Invoke-HostVerb 'mr.get' @{ type = 'command'; repo = 'o/cmd'; n = '4' }; "command:$($m.iid -eq 4 -and $m.title -eq 'o/cmd')"
$e = try { Invoke-HostVerb 'mr.get' @{ type = 'github'; repo = 'o/r'; n = '1' } } catch { "$_" }; $g = try { Invoke-HostVerb 'mr.get' @{ repo = 'o/r'; n = '1' } } catch { "$_" }   # unknown host = gitlab
"extra-line:$($e -eq 'git-host github is a goody: run kitbag.py goody add github' -and $g -eq 'git-host gitlab is a goody: run kitbag.py goody add gitlab')"
"ci-object:$(try { $null = Invoke-HostVerb 'ci.status' @{ type = 'command'; repo = 'o/cmd' }; $true } catch {})"
'@
$ka = New-TestKit adapters; $cmdf = Join-Path (Split-Path $ka) 'host-cmd.ps1'; Set-Content $cmdf '[ordered]@{ iid = [int]$args[1]; state = ''merged''; title = $args[0] } | ConvertTo-Json -Compress'
& $J @{ gitHost = 'git.example'; repos = @(@{ name = 'cmd'; ci = @{ mrPipelines = $false } }); gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$cmdf`" {repo} {n}" } } } (Join-Path $ka 'skills/crafty/kit.local.json') 5
$f = Join-Path (Kd) 'githost-test.ps1'; Set-Content $f $gh
$res = @(pwsh @np $f (Join-Path $ka 'skills/crafty/lib.ps1') 2>&1)
Expect-Each $res 'git host: #' 'mr-urls', 'command', 'extra-line', 'ci-object'
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
$wl = (1..130 | ForEach-Object { "w$_" }) -join ' '; $n0 = @(pwsh @np $D tracker comments $t.id | ConvertFrom-Json).Count
$pr = pwsh @np $D tracker comment $t.id $wl -Kind comment-status 2>&1 | Out-String; $prc = $LASTEXITCODE; $n1 = @(pwsh @np $D tracker comments $t.id | ConvertFrom-Json).Count
$null = pwsh @np $D tracker comment $t.id $wl -Kind comment-status -ProseOk 'brief format' 2>&1; $pkc = $LASTEXITCODE; $n2 = @(pwsh @np $D tracker comments $t.id | ConvertFrom-Json).Count
$dp = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') comment $t.id $wl comment-solution 2>&1 | Out-String; $dpc = $LASTEXITCODE
$null = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') comment $t.id $wl comment-solution --prose-ok 'brief format' 2>&1; $dkc = $LASTEXITCODE; $n3 = @(pwsh @np $D tracker comments $t.id | ConvertFrom-Json).Count
Expect "prose gate: tracker / devtools.py comment over the limit refused, unposted; -ProseOk / --prose-ok post ($prc $pkc $dpc $dkc $n0 $n1 $n2 $n3)" ($prc -eq 1 -and $pr -match 'tracker comment refused' -and $n1 -eq $n0 -and $pkc -eq 0 -and $n2 -eq $n0 + 1 -and $dpc -eq 1 -and $dp -match 'refused' -and $dkc -eq 0 -and $n3 -eq $n0 + 2)
$null = pwsh @np $D tracker comment $t.id 'round two' -Kind comment-solution -ProseOk x; $cs = @(pwsh @np $D tracker comments $t.id | ConvertFrom-Json)
Expect 'kit comment -Kind comment-solution: the next round edits it; status notes and a person''s comment untouched' ($cs.Count -eq $n3 -and @($cs.text -match '^round two\s+\[kit:comment-solution\]$').Count -eq 1 -and @($cs.text -match '^body text').Count -eq 1 -and @($cs.text -match '^w1 ').Count -eq 1)
$env:KIT_DOC_GATE = '1'; $g1 = pwsh @np $D tracker status $t.id promoted 2>&1 | Out-String; $null = pwsh @np $D tracker describe $t.id "Testing doc (human): https://d/h"
$g3 = pwsh @np $D tracker status $t.id promoted 2>&1 | Out-String; $null = pwsh @np $D tracker describe $t.id "Testing doc (human): https://d/h`nTesting doc (AI): https://d/a"
$g2 = pwsh @np $D tracker status $t.id promoted 2>&1 | Out-String; Remove-Item Env:KIT_DOC_GATE
$k1 = pwsh @np $D tracker create -List L1 -Name 'Bug s1' -Description 'a' -Key sig-1 | ConvertFrom-Json; $k2 = pwsh @np $D tracker create -List L1 -Name 'Bug s1 (2)' -Description 'b' -Key sig-1 | ConvertFrom-Json
Expect 'tracker create -Key: an open task of the same key is updated, not created again' ($k2.id -eq $k1.id -and $k2.reused -and (pwsh @np $D tracker view $k1.id | ConvertFrom-Json).description -eq 'b')
Expect 'status gate: promoted needs both doc links (none, the human one only: refused)' ($g1 -match 'not set to promoted' -and $g2 -notmatch 'not set' -and $g3 -match 'not set to promoted')
Remove-Item Env:KIT_TRACKER_TYPE
# tracker: unknown call fails
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
$res = Invoke-PsTest 'tracker-test' $tb @(Lib)
Expect-Each $res 'tracker #: view, status, comment, create, list on recorded answers' 'command'
$kv = pwsh -NoProfile -Command ". '$(Lib)'; function T1 { param([string]`$Mode, [string[]]`$Lanes, [switch]`$Cold) ""`$Mode|`$(`$Lanes -join '+')|`$Cold"" }; `$a = @{ Lanes = 'L1'; Mode = 'None'; Cold = `$true }; & { Invoke-KitVerb T1 `$args } @a"
Expect 'Invoke-KitVerb: splatted Mode=None binds like -Mode None' ("$kv".Trim() -eq 'None|L1|True')
$kl = pwsh -NoProfile -Command ". '$(Lib)'; `$ErrorActionPreference = 'Stop'; `$f = Join-Path '$(Kd)' 'kl.json'; Set-Content `"`$f.lock`" x; (Get-Item `"`$f.lock`").LastWriteTime = (Get-Date).AddMinutes(-5); function Test-Path { Remove-Item `"`$f.lock`" -Force -ErrorAction SilentlyContinue; `$true }; try { Invoke-KitLocked `$f { 'ran' } } catch { `"threw: `$_`" }"
Expect "Invoke-KitLocked: a lock removed mid-check is no crash ($kl)" ("$kl".Trim() -eq 'ran')
$mv = pwsh -NoProfile -Command ". '$(Lib)'; foreach (`$e in [IO.IOException]::new('p', -2147024809), [ArgumentException]::new('p'), [IO.IOException]::new('b', -2147024864)) { Test-KitMoveUnsupported `$e }; `$f = '$(Kd)/atomic.json'; Write-KitAtomic `$f 'a'; Write-KitAtomic `$f 'b'; Get-Content `$f"
Expect "Write-KitAtomic: Win32 87 / ArgumentException copy over, a sharing violation retries ($mv)" ("$mv" -eq 'True True False b')
$vk = foreach ($r in @(@('Nosuch-Cmd; ''after''', '', 1, 'FAILED: .*Nosuch-Cmd'), @('$null.X()', '', 1, 'FAILED'), @('''ok''', '-Mode x', 2, 'Mode'), @('''ok''', '', 0, '^$'))) {
  $e = pwsh -NoProfile -Command ". '$(Lib)'; function Invoke-T { param([int]`$Mode) $($r[0]) }; Invoke-KitVerb Invoke-T @('$($r[1] -split ' ' -join "','")' | Where-Object { `$_ })" 2>&1 | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Out-String
  if ($LASTEXITCODE -ne $r[2] -or $e.Trim() -notmatch $r[3]) { "$($r[0]) -> $LASTEXITCODE $($e.Trim())" } }
Expect "Invoke-KitVerb: crash exit 1, bad parameter 2 ($vk)" (-not $vk)
$mw = pwsh -NoProfile -Command ". '$(Lib)'; function Invoke-M { param([string]`$Message, [string[]]`$Mrs) ""`$Message|`$(`$Mrs -join '+')"" }; Invoke-KitVerb Invoke-M @('-Message', 'fix', 'the', 'bug', '-Mrs', 'a!1', 'b!2')"
Expect "Invoke-KitVerb: unquoted words join with spaces, arrays stay arrays ($mw)" ("$mw".Trim() -eq 'fix the bug|a!1+b!2')
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
$out = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest' ($LASTEXITCODE -eq 0)
$DT = Join-Path $k 'skills/crafty/devtools.py'
$dv = & $py -X utf8 $DT 2>&1 | Out-String; $dvc = $LASTEXITCODE; $dmiss = & $py -X utf8 $DT doc t (Join-Path $k 'none.md') 2>&1 | Out-String; $ddc = $LASTEXITCODE
Expect "devtools: no verb / a doc file that is missing = a usage line, exit 2 ($dvc $ddc)" ($dvc -eq 2 -and $dv -match 'missing verb: .*\(verbs: ' -and $ddc -eq 2 -and $dmiss -match 'file not found' -and $dmiss -notmatch 'Traceback')
$th = & $py -X utf8 $DT comment --help 2>&1 | Out-String; $thc = $LASTEXITCODE; $null = & $py -X utf8 $DT comment T1 --bogus 2>&1; $tbc = $LASTEXITCODE; $null = & $py -X utf8 $DT finish T1 2>&1; $tmc = $LASTEXITCODE
$fk = Join-Path (Kd) 'flaky.py'; [IO.File]::WriteAllText($fk, "import sys, subprocess as sp; sys.path.insert(0, sys.argv[1]); import devtools as d`nn = []; hang = [0]`ndef fake(cmd, **kw):`n    n.append(cmd)`n    if hang[0]: raise sp.TimeoutExpired(cmd, 1)`n    return sp.CompletedProcess(cmd, 1 if len(n) == 1 else 0, 'connection reset' if len(n) == 1 else 'ok', '')`nd.subprocess.run = fake`nr = d._tracker('view', 'T1'); a = len(n); n.clear()`ntry: d._tracker('create', 'x')`nexcept SystemExit: pass`nw = len(n); n.clear(); hang[0] = 1; d._run(['glab', 'api', 'x']); print(r, a, w, len(n))`n")
$rt = & $py -X utf8 $fk (Split-Path $DT) 2>$null | Out-String
Expect "devtools: --help 0, bad args 2, reads retried, writes never, hung read once ($thc $tbc $tmc $($rt.Trim()))" ($thc -eq 0 -and $th -match 'devtools\.py comment <taskId>' -and $th -notmatch 'finish' -and $tbc -eq 2 -and $tmc -eq 2 -and $rt.Trim() -eq 'ok 2 1 2')
$se = & $py -X utf8 $DT mr (Kd) main nobody-wrote-this.md 2>&1 | Out-String; $sec = $LASTEXITCODE
Expect "devtools: a sys.exit('<why>') prints its why (exit $sec)" ($sec -eq 1 -and $se -match 'file not found: nobody-wrote-this\.md')
if ($IsWindows) {
  $sh = Join-Path (Kd) 'shim'; New-Item -ItemType Directory -Force "$sh/node_modules/c" | Out-Null; 'console.log(JSON.stringify(process.argv.slice(2)))' | Set-Content "$sh/node_modules/c/run.js"
  "@ECHO off`r`nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & ""%_prog%""  ""%dp0%\node_modules\c\run.js"" %*" | Set-Content "$sh/g.cmd"; '@echo %*' | Set-Content "$sh/p.cmd"
  $sq = "import sys; sys.path.insert(0, sys.argv[1]); import devtools as d`nprint(d._run([sys.argv[2], 'RM<>HM |&^% ""q""']))`ntry: d._run([sys.argv[3], 'a<b'])`nexcept SystemExit as e: print('REFUSED', e)"
  [IO.File]::WriteAllText("$sh/t.py", $sq); $so = & $py -X utf8 "$sh/t.py" (Split-Path $DT) "$sh\g.cmd" "$sh\p.cmd" 2>&1 | Out-String
  Expect "devtools: a .cmd shim gets RM<>HM |&^% intact (node direct), another shim refuses it ($so)" ($so -match [regex]::Escape('["RM<>HM |&^% \"q\""]') -and $so -match 'REFUSED p\.cmd is a cmd\.exe shim')
}
# pipes: busy only with a head pipeline
$pt = @'
. $args[0]
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
 if ($Verb -eq 'mr.get') { if ($A.n -ne '9') { [pscustomobject]@{ state = 'opened'; head_pipeline = $null; target_branch = 'main' } } }
 elseif ($Verb -eq 'ci.config') { if ($A.repo -match 'nocirepo') { $false } else { $null } }   # no CI file / a failed call
}
$a = Invoke-Pipes -Mrs 'https://h.example/g/nocirepo/-/merge_requests/1' -MaxMinutes 0 | ConvertFrom-Json
$b = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json
$c = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/9' -MaxMinutes 0 | ConvertFrom-Json
function Get-KitValue { @{ name = 'cirepo'; ci = @{ mrPipelines = $false } } }
"mr-off:$((Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json).done)"
"no-ci:$($a.done -and $a.mrs[0].status -eq 'no-ci')"
"no-pipeline:$(-not $b.done -and $b.mrs[0].status -eq 'no-pipeline')"
"unknown:$(-not $c.done -and $c.mrs[0].status -eq 'unknown')"
'@
$res = Invoke-PsTest 'pipes-test' $pt @($D)
Expect-Each $res 'pipes: #' 'no-ci', 'no-pipeline', 'unknown', 'mr-off'
# migrations: own check, Liquibase (goody), else UNRUN
$ud = Join-Path (Kd) 'unrun-repo'; New-Item -ItemType Directory -Force $ud | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
Save-GitRepo $ud init
$mig = { param([hashtable]$f) foreach ($p in $f.Keys) { New-Item -Force "$ud/$p" -Value $f[$p] | Out-Null }; Save-GitRepo $ud add; Invoke-TestScript $D check -Dir $ud -Step migrations }
Expect-Cases @(
  , @('check: migrations without a kit check or tool are UNRUN (exit 5), docs skipped', { & $mig @{ 'db/migrate/20240101000000_x.rb' = 'def change; end'; 'CHANGELOG.md' = 'x'; 'database/migrations/2024_01_01_000000_x.php' = '<?php' } },
      { param($r) $r.code -eq 5 -and $r.out -match 'UNRUN: 2 migration file\(s\) of another tool' -and $r.out -match '000000_x\.php' -and $r.out -notmatch 'CHANGELOG' })
  , @('check: Flyway, Alembic and Prisma files are UNRUN too', { & $mig @{ 'alembic/versions/a1_x.py' = 'x'; 'prisma/migrations/1_x/migration.sql' = 'x'; 'db/migration/V1__x.sql' = 'x' } },
      { param($r) $r.code -eq 5 -and $r.out -match 'UNRUN: 5 migration file\(s\) of another tool' })
  , @('check: Liquibase without the goody is UNRUN with the goody line', { & $mig @{ 'config/liquibase/master.xml' = '<databaseChangeLog/>' } }, { param($r) $r.code -eq 5 -and $r.out -match 'goody add liquibase' })
)
$tr = Join-Path (Kd) 'touched-repo'; New-Item -ItemType Directory -Force "$tr/src" | Out-Null; '{ "stack": "custom", "commands": { "test": "node -e 0" } }' | Set-Content "$tr/.claude-stack.json"
'x' | Set-Content "$tr/src/Audit.spec.ts"; Save-GitRepo $tr i; 'x' | Set-Content "$tr/src/Audit.ts"
$out = pwsh @np $D check -Dir $tr -Step test -Touched 2>&1 | Out-String
Expect 'check -Touched: Audit.ts is no test (case-sensitive Test suffix); its spec runs' ($out -match '-Touched: 1 test\(s\) for 1 changed file\(s\): src/Audit\.spec\.ts')
$wd = Join-Path (Kd) 'web-no-tests'; New-Item -ItemType Directory -Force $wd | Out-Null
'{ "name": "w", "devDependencies": { "typescript": "5" } }' | Set-Content "$wd/package.json"; '{}' | Set-Content "$wd/tsconfig.json"
$out = pwsh -NoProfile -File $D check -Dir $wd -Step test -Tests x.spec.ts 2>&1 | Out-String
Expect 'check: no test target and no goody node-spec = UNRUN with the goody line' ($LASTEXITCODE -eq 5 -and $out -match 'goody add node-spec')
$sd = Join-Path (Kd) 'stack-only'; New-Item -ItemType Directory -Force $sd | Out-Null; '{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$sd/.claude-stack.json"
$out = pwsh @np $D stack -Dir $sd 2>&1 | Out-String
Expect 'stack: a .claude-stack.json alone names the stack' ($out -match 'stack: custom' -and $out -notmatch 'FAILED')   # in-process: git's exit code leaks
$out = pwsh @np $D gate -Dir $ud -Cmd 'echo gradlew build' 2>&1 | Out-String
Expect 'gate: runs the command; no heap cap without the goody build-heap' ($out -match '(?m)^gradlew build' -and $out -notmatch 'jvmargs')
# gate: half the file cache counts; the queue head starts after 20 min above a 5% floor
$gt = @'
. $args[0]
"kinds:$((@('py -m unittest', 'py t/test_a.py', 'echo running tests', 'ng test', 'mvn package -DskipTests', 'mvn verify', 'npx tsc --noEmit -p cypress/tsconfig.json', 'npx cypress run') | ForEach-Object { Get-GateKind $_ }) -join ',' -eq 'python,python,other,ng-test,maven,maven-test,typecheck,e2e')"
"histcmd:$((Get-GateHistCmd 'mvn -f C:\w\a\p.xml' 'C:/W/a') -eq 'mvn -f .\p.xml' -and (Get-GateHistCmd ('x' * 200) 'C:\w').Length -eq 120)"
"cache:$((Get-GateAvailGB ([pscustomobject]@{ AvailGB = 13.6; CacheGB = 21 })) -eq 24.1)"
"keep:$((Test-GateStart 11 10 0 64) -and -not (Test-GateStart 9 10 5 64))"
"starved:$((Test-GateStart 4 10 25 64) -and -not (Test-GateStart 2 10 25 64))"
'@
Expect-Each (Invoke-PsTest 'gate-test' $gt @($D)) 'gate: #' 'cache', 'keep', 'starved', 'kinds', 'histcmd'
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
$gl = (@{ tool_name = 'Write'; tool_input = @{ file_path = "$(TkPath $k runtime)/work/x2/a.md" } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
$dd = pwsh @np $D dir -Agent 'B 1' -Item T9 -Name 'Run.LOG' 2>&1 | Out-String
Expect 'guard: a write off the layout gets a note naming crafty.ps1 dir; dir: agents/<id>/<item>/<file>, lowercase-kebab' ($gl -match 'additionalContext.*kit layout: runtime/work/x2/a\.md.*dir -Agent' -and $gl -notmatch 'deny' -and $dd.Trim() -match '[\\/]work[\\/]agents[\\/]b-1[\\/]t9[\\/]run\.log$')
$gt = (@{ tool_name = 'Write'; tool_input = @{ file_path = '/tmp/mr-body.md' } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
Expect 'guard: a Write of a body file to the shared temp root is denied, naming crafty.ps1 dir' ($gt -match '"deny"' -and $gt -match 'shared temp root.*dir -Agent')
$na = Join-Path $k 'skills/crafty/adapters/note_test.ps1'; New-Item -ItemType Directory -Force (Split-Path $na) | Out-Null
"Register-KitAdapter 'guard' 'note' @{ check = { param(`$a) if (`$a.cmd -match 'notecmd') { @{ note = 'lease noted' } } } }" | Set-Content $na
$gn = Px $D guard -Json '{"tool_name":"Bash","tool_input":{"command":"notecmd x"}}' | Out-String; Remove-Item $na
$rt = Invoke-TestScript $D runtime status
Expect "guard: a goody's note is context, no decision; runtime without its goody exits 1 ($gn)" ($gn -match '"additionalContext":"lease noted"' -and $gn -notmatch 'permissionDecision' -and $rt.code -eq 1 -and $rt.out -match 'goody add runtimes')
$lw = New-LinkedKit 'main kit' @{ tracker = @{ type = 'jira' }; zz = @(@{ p = 'q' }) }
$tt = pwsh -NoProfile -Command ". '$lw/skills/crafty/lib.ps1'; Get-KitSetting 'tracker.type' 'none'; (Get-KitSetting 'zz' 'dflt').p; Invoke-GitFetch -Dir '$lw' -TimeoutSec 20" 2>&1 | Out-String
Expect 'lib: a linked worktree reads the main clone''s kit.local.json (a list of one object stays a list); fetch in a path with spaces runs (no origin: warning, $false)' ($tt -match '(?m)^jira' -and $tt -match '(?m)^q\r?$' -and $tt -match 'git fetch in .*kit wt failed' -and $tt -match '(?m)^False')
$gt = & { . (Lib); Update-KitTracking { param($t) $t.tasks['g1'] = @{ task = 'g1' }; $t.tasks['g2'] = @{ task = 'g2' } }; "$(Remove-KitGoneTask g1 'HTTP 404 Task not found, deleted') $(Remove-KitGoneTask g2 '404 Not Found') $((Read-KitTracking).tasks.ContainsKey('g1')) $((Read-KitTracking).tasks.ContainsKey('g2'))|$(Test-KitPid $PID (Get-Date).AddHours(-9)) $(Test-KitPid $PID (Get-KitPidStart $PID)) $(Test-KitPid $PID 'x')" }
Expect 'lib: a deleted task leaves tracking (not on outage); reused pid, bad start: dead' ($gt -eq 'True False False True|False True False')
# learned params: shadowDays 3, heartbeat pinned; KIT_NOW = fake clock
$pk = Join-Path (Kd) 'pk/.claude/skills/crafty'; New-Item -ItemType Directory -Force $pk | Out-Null; Copy-Item (Lib), "$k/skills/crafty/kit.example.json" $pk
& $J @{ params = @{ shadowDays = 3 }; supervise = @{ heartbeatMinutes = 12 } } "$pk/kit.local.json"
$pr = Invoke-PsTest params @'
. $args[0]; $t = [datetime]'2026-01-01T08:00'; $fl = @()
function F($y, $v, $n, $h, $c = '', $r = 'ok', $d = 10) { for ($i = 0; $i -lt $n; $i++) { $env:KIT_NOW = $t.AddHours($h + $i).ToString('o'); Add-KitParamObs $y $v $c $r $d } }
function L($h) { $env:KIT_NOW = $t.AddHours($h).ToString('o'); $script:KitParamMemo.Clear(); $script:fl += @(Invoke-ParamLearn) }
foreach ($w in 0..6) { $h = 24 * $w; F idle.graceMinutes 30 4 $h; F net.timeoutSec 4 6 $h gh -d 60; if (!$w) { F net.timeoutSec 60 1 7 gh timeout 60; L 7.5; "fail:$(Get-KitParam net.timeoutSec 60 gh)" }; F gate.needGB 9 5 $h 'w|a' -d 2; L ($h + 8); if ($w -eq 2) { "d2:$(Get-KitParam idle.graceMinutes 10)" } }
$g = { Get-KitParam net.timeoutSec 60 gh }; "hold:$(& $g)"; F net.timeoutSec 4 6 176 gh -d 60; L 183; "down1:$(& $g)"; F net.timeoutSec 4 2 208 gh -d 60; L 209; "wait5:$(& $g)"; F net.timeoutSec 4 3 210 gh -d 60; L 211; "down2:$(& $g)"
F supervise.heartbeatMinutes 20 1 220 '' short 15; L 221; "beat:$((Read-KitParams).byKey['supervise.heartbeatMinutes']['_'].rec)"; $env:KIT_NOW = $t.AddHours(222).ToString('o')
$l = [ordered]@{ agent = 'zz-1'; at = (Get-Date).ToString('o'); seen = (Get-Date).AddMinutes(-90).ToString('o') }; $u = Update-KitLease $l; $null = New-KitLease 'zz-1'; $null = New-KitLease 'zz-1'
"back:${u}:$(@(Read-KitLog params $t | Where-Object { $_.event -eq 'obs' -and $_.key -eq 'idle.graceMinutes' -and $_.r -eq 'short' }).Count)"; (Invoke-KitParamVerb show net.timeoutSec) -join ' '
"slow:$(Get-KitParam idle.graceMinutes 10):$((Read-KitParams).byKey['idle.graceMinutes']['_'].rec)"
"ask:$(Get-KitParam gate.needGB 3.0 'w|a'):$(@($fl | Where-Object what -match 'needGB.*past 2x').Count):$(@((Read-KitParams).history | Where-Object { !$_ }).Count)"
$null = Invoke-KitParamVerb approve gate.needGB '' 'w|a'; L 200; "ok:$(Get-KitParam gate.needGB 3.0 'w|a')"
$env:KIT_PARAM_IDLE_GRACEMINUTES = 7; $a = Get-KitParam idle.graceMinutes 10; $env:KIT_PARAM_IDLE_GRACEMINUTES = ''
$null = Invoke-KitParamVerb pin idle.graceMinutes 9; $null = Invoke-KitParamVerb pin gate.needGB 5; $script:KitParamMemo.Clear()
"pin:${a}:$(Get-KitParam idle.graceMinutes 10):$(Get-KitParam supervise.heartbeatMinutes 15):$(Get-KitParam gate.needGB 3.0 'w|a')"; Invoke-KitParamVerb pin no.such 1
'@ @("$pk/lib.ps1")
Expect 'params: shadow = default; then a step a day toward p95 x1.5; held at 2x' ($pr -contains 'd2:10' -and "$pr" -match 'slow:20:3[78]\.')
Expect 'params: past 2x one WATCH; param approve lifts it' ($pr -contains 'ask:4:1:0' -and $pr -contains 'ok:8')
Expect 'params: a timeout steps up x1.5 at once; no risky step for 7 d, then -10% a day after 5 new observations' ($pr -contains 'fail:90' -and $pr -contains 'hold:90' -and $pr -contains 'down1:81' -and $pr -contains 'wait5:81' -and $pr -contains 'down2:72.9')
Expect 'params: 2+ new ACTs step the beat down; a holder back after grace = short (once); show: last change + next risky step' ($pr -contains 'beat:10' -and $pr -contains 'back:False:1' -and "$pr" -match 'last change \d\d-\d\d \d\d:\d\d down: .*next risky step from')
Expect 'params: env > kit.local.json > pin (no -Context: all) > learned; unknown key refused' ($pr -contains 'pin:7:9:12:5' -and "$pr" -match "unknown param 'no.such'")

$rd = @{ rows = @(@{ name = 'W1'; task = 'T1'; state = 'ACTIVE'; since = '2026-01-02T10:00'; last = '2026-01-02T10:05'; doing = 'StructuredOutput' }, @{ name = 'J1'; task = '2026-10-29-rm-staging-2xyz wf_e8c577f7-894'; state = 'WAITING'; wait = 'hm deploy 0abbaa36, train d09409 waits for leases (switch-over)'; since = '2026-01-02T10:00'; next = 'envy.ps1 wait -Id 0abbaa36' })
  mem = @{ TotalGB = 64; AvailGB = 16 }; keepFree = 8; info = @('ready'); resources = @(@{ name = 'rm · api'; by = 'W1'; gb = 3 }) + @(1..6 | ForEach-Object { @{ name = "browser a-b·c·d$_"; by = 'devy-3dy3'; gb = 1 } }) }
$ef = { param($a, $q) @{ level = 'ACT'; kind = 'ENV-FIX'; who = "$a (wave-brief-a8da)"; age = '34 min'; what = $a; problem = $q; action = "& D:\Kit\.claude\skills\bossy\bossy.ps1 decide answer -Id e-20261029090127-$a-e69a" } }
$rd.flags = @(@{ level = 'WATCH'; what = 'RESTART LOOP: hm search 3x'; action = 'logs' }, (& $ef W 'devy-3dy3-put'), ((& $ef J ('p ' * 60)) + @{ next = 'nx' }), (& $ef J1 'C:\d\|x'))
$r1 = (& { . $O; Format-KitReport $rd }) -join "`n"; $rd.mem.AvailGB = 6; $rd.rows = @(); $r2 = (& { . $O; Format-KitReport $rd }) -join "`n"
$want1 = @('| Agent | Task / run | State | Since | Last progress | Next |', '|---|---|---|---|---|---|', '| J1 | rm-staging- 2xyz e8c577f7 | WAITING: hm deploy 0abbaa36, train d09409 waits for leases (switch- over) | 10:00 | — | envy.ps1 wait -Id 0abbaa36 |', '| W1 | T1 | ACTIVE | 10:00 | 10:05 Structured Output | — |', '', '**Flags**', '') -join "`n"
$fr = @($r1 -split "`n" | Where-Object { $_ -match '^\| (ACT|WATCH|INFO) \|' }); $fw = @($r1 -split "`n`n" | Where-Object { $_.StartsWith('|') } | ForEach-Object { $tl = $_ -split "`n"; $nc = ($tl[0] -split '\|').Count - 2
  (1..$nc | ForEach-Object { $ci = $_; @($tl | ForEach-Object { ($_ -split '(?<!\\)\|')[$ci] -split ' ' | ForEach-Object Length }) | Measure-Object -Maximum } | Measure-Object Maximum -Sum).Sum + 3 * $nc + 1 })
$rt = foreach ($n in 2, 3, 7) { $rd.resources = @(1..$n | ForEach-Object { @{ name = "r$_"; gb = $_ } }); $fo = & { . $O; Format-KitReport $rd 'ACT: 1' }; "$(@($fo -match '^\| Resource \|').Count)$(@($fo -match '^\| r\d').Count)$(@($fo -match '— \| — \|$').Count)$(($fo -join ' ') -match 'INFO.+ACT: 1 +\*\*RAM')" }
Expect "report: widths ($fw) <= 95, cells <= 90; RAM last; 2/3/7 resources 3 a row ($rt)" ($r1.StartsWith($want1) -and "$rt" -eq '112True 111True 132True' -and $r1.EndsWith("`n") -and -not @($fw | Where-Object { $_ -gt 95 }).Count -and -not ($fr -split '\|' -match '.{93}') -and $fr[1] -match 'p \(full: report\) \| nx \|$' -and $fr[3] -match 'WATCH \| RESTART LOOP \| — \| — \| hm' -and ($r1 -replace ' ').Contains('J1(wave-brief-a8da)|34min|C:\d\\\|x|&D:\Kit\.claude\skills\bossy\bossy.ps1decideanswer-Ide-20261029090127-J1-e69a|') -and $r2 -match 'below the floor 8 GB' -and $r2 -match 'nothing running')
Remove-TestKit $k
# ---- OS helpers on Linux / macOS
$k = New-TestKit posix
if ($IsWindows) { 'SKIP posix (Linux / macOS only)' } else {
  $r = pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; `$m = Get-SysMem; `$p = @(Get-SysProcs | Where-Object Id -eq `$PID); `$d = Join-Path '$(Kd)' 'l'; New-DirLink `$d '$(Kd)'; ""`$(`$m.TotalGB -gt 0 -and `$m.AvailGB -gt 0)|`$(`$p.Count)|`$(@(Get-DirLinks '$(Kd)' 1).Count)""" 2>&1 | Out-String
  Expect "posix: memory, own process, a directory link ($($r.Trim()))" ($r.Trim() -match '^True\|1\|1$')
}
Remove-TestKit $k
Complete-Tests
