#Requires -Version 7
<#
sessions.tests.ps1: several coordinators on one machine (adapters/supervise_resources.ps1 "sessions"): run owners for pause /
resume / recover (-Everyone), a stepped-aside supervise prints its own runs' flags, task claims at launch, the step-age HANDOFF;
the dashboard's folds and grouping (supervise page); handoff successors, placeholder task ids, planned areas holding promotion, pause / resume leftovers, pokey api user hints; git-host adapters, crafty.ps1 host MR refs and check's python stale-env; the kit to-do ACT; crafty.ps1 pipes default and statuses; board beat of an unknown session.
Usage: pwsh -NoProfile -File <kit>/tests/sessions.tests.ps1 (or tests/kit-tests.ps1 -Area sessions).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit sess; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx'; New-Item -ItemType Directory -Force $env:KIT_TRANSCRIPTS | Out-Null   # no real session folders
$self = { param($run, $json) $f = Join-Path (Kd) "args-$(Get-Random).json"; [IO.File]::WriteAllText($f, $json); pwsh @np $O launch -Self -Script buildy.js -Run $run -ArgsFile $f -Fnv (& { . $O; Get-KitFnv $json }) | Out-String }
$sp = { Start-Process $pwshExe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' }
$fp = & $sp; $mp = & $sp; $env:KIT_HOLDER_PID = $mp.Id   # session processes: another coordinator's, this one's (a test shell has none above it)
$hold = { param($p) @{ holderPid = $p.Id; holderStart = $p.StartTime.ToUniversalTime().ToString('o') } }; $fh = & $hold $fp
$bd = TkPath $k board -Create; $ld = TkPath $k launches -Create
try {
  $null = & $self mr '{"brief":"C:/b/mr.md","agents":[{"id":"M1","items":"tsk111a fix"}]}'; $null = & $self fr '{"brief":"C:/b/fr.md","agents":[{"id":"F1","items":"tsk222b fix"}]}'
  foreach ($rp in @('fr', $fp), @('mr', $mp)) { $rf = (Get-ChildItem $ld -Filter "self-buildy-$($rp[0])-*.json")[0].FullName; $x = Read-Json $rf; foreach ($kv in (& $hold $rp[1]).GetEnumerator()) { $x.($kv.Key) = $kv.Value }; & $J $x $rf }
  $ff = (Get-ChildItem $ld -Filter 'self-buildy-fr-*.json')[0].FullName
  $null = Px $O board join -Agent M1 -Run mr
  $row = { param($a, $t, $r, $i, $h) & $J (@{ agent = $a; type = $t; session = "$a-x"; run = $r; items = $i; worktrees = @(); status = 'working'; joined = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o') } + $h) (Join-Path $bd "$a-x.json") }
  & $row F1 devy fr '' $fh; & $row M2 devy mr '' $fh; & $row R1 revy rv 'tsk222b' $fh   # M2: my run's agent under another process; R1 a reviewer
  # claims: one run per task, whichever session runs it; builders only
  $cf = Join-Path (Kd) 'claim.json'; '{"brief":"C:/b/new.md","agents":[{"id":"N1","items":"tsk222b again"}]}' | Set-Content $cf; $cl = Invoke-TestScript $O launch -Check -ArgsFile $cf
  '{"run":"fr","agents":[{"id":"N1","items":"tsk222b again"}]}' | Set-Content $cf; $co = Invoke-TestScript $O launch -Check -ArgsFile $cf
  Expect 'claims: a task a builder of another run works on is refused at launch -Check (exit 1); in its own run, or by a reviewer, not' ($cl.code -eq 1 -and $cl.out -match 'TASKS REFUSED tsk222b: run fr \(agent F1, beat \d\d:\d\d\) works on it now' -and $cl.out -notmatch 'run rv' -and $co.out -notmatch 'TASKS REFUSED')
  # pause: mine only; the other coordinator's run is released from the '*' pause
  $p1 = Invoke-TestScript $O pause -Run fr -Reason t; $pa = Px $O pause -All -Reason 'two coordinators' -Wait 0 | Out-String
  $pr = Read-Json (Get-ChildItem (TkPath $k pauses) -Filter 'pause-*.json' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
  Expect "pause: another live coordinator's run is OWNED (exit 1); -All pauses only mine, the other run released" ($p1.code -eq 1 -and $p1.out -match 'OWNED: run fr belongs to the live session process' -and
    $pa -match 'PAUSE sent to 2 agent\(s\) \(M1, M2\)' -and $pa -match 'marked paused: mr' -and @($pr.released) -contains 'fr' -and -not (Read-Json $ff).paused -and $pr.holderPid)
  Start-Sleep -Milliseconds 1100; $pe = Px $O pause -Run fr -Everyone -Wait 0 | Out-String   # a new pause file name (seconds)
  Expect 'pause -Everyone: the other coordinator''s run too' ($pe -match 'PAUSE sent to 1 agent\(s\) \(F1\)' -and $pe -match 'marked paused: fr' -and (Read-Json $ff).paused)
  $af = Join-Path (TkPath $k pauses) 'pause-a.json'; & $J (@{ at = (Get-Date).ToString('o'); run = 'fr'; state = 'paused'; reason = 'a' } + $fh) $af   # the other coordinator's own pause
  $env:KIT_OFFLINE = '0'; $ru = Px $O resume -Run fr | Out-String; $rc = Px $O recover -Run fr | Out-String; Remove-Item Env:KIT_OFFLINE
  Expect "resume / recover: another live coordinator's paused run is OWNED, never relaunched here, its pause kept" ($ru -match '== OWNED: buildy\.js run fr belongs to' -and $ru -notmatch '== buildy\.js run fr' -and $rc -match '== OWNED: buildy\.js run fr' -and $rc -notmatch 'RELAUNCH|resumeFromRunId' -and (Read-Json $af).state -eq 'paused')
  # one session supervises; one that steps aside prints that sweep's flags of its own runs
  & $J @{ session = 'other-coordinator'; at = (Get-Date).ToString('o'); pid = 1 } (Join-Path (TkPath $k cache -Create) 'supervise.lock')
  & $J @{ report = @{ at = (Get-Date).ToString('o') }; lastFlags = @(@{ level = 'ACT'; what = 'run mr: M1 stuck 40 min'; action = 'look at M1' }, @{ level = 'ACT'; what = 'run fr: F1 stuck 40 min'; action = 'look at F1' }) } (TkPath $k supervise-state -Create)
  $cs = if ((Px $O board join -Type coordinator -Agent coordinator | Out-String) -match 'SESSION (\S+)') { $Matches[1] }; $cj = Join-Path $bd "$cs.json"
  $x = Read-Json $cj; $x.beat = (Get-Date).AddHours(-1).ToString('o'); foreach ($kv in (& $hold $mp).GetEnumerator()) { $x.($kv.Key) = $kv.Value }; & $J $x $cj
  $sv = Px $O supervise -Brief 2>$null | Out-String
  Expect "supervise: a stepped-aside session prints that sweep's flags of its own runs only; its coordinator row beats" ([datetime](Read-Json $cj).beat -gt (Get-Date).AddMinutes(-5) -and $sv -match 'steps aside' -and $sv -match "your runs' flags" -and $sv -match '\[ACT\] run mr: M1 stuck' -and $sv -match '-> look at M1' -and $sv -notmatch 'run fr')
  # step age: an agent that checkpoints, since join or its last checkpoint
  $ss = if ((Px $O board join -Agent S1 -Run sr | Out-String) -match 'SESSION (\S+)') { $Matches[1] }; $sf = Join-Path $bd "$ss.json"
  $x = Read-Json $sf; $x.joined = (Get-Date).AddHours(-3).ToString('o'); & $J $x $sf; $h0 = Px $O board beat -Session $ss | Out-String
  $cp = & { . (Lib); Get-KitCheckpointFile S1 sr -Write }; $hb = foreach ($c in @(-3, $false), @(-3, $true), @(0, $false)) { & $J @{ agent = 'S1'; run = 'sr'; next = 'test'; done = $c[1]; updated = (Get-Date).AddHours($c[0]).ToString('o') } $cp; Px $O board beat -Session $ss | Out-String }
  Expect 'board beat: a step past budget.stepHours -> HANDOFF; none without a checkpoint, a done one or after a newer one' ($hb[0] -match 'HANDOFF: one step running 3\.0 h >= budget\.stepHours 2: write a resume brief' -and "$h0$($hb[1])$($hb[2])" -notmatch 'HANDOFF')
  # a handoff's successor = a later row of that agent, any run (a fresh kitty ran as kit-build): no HANDOFF flag, no stale CONTINUE
  foreach ($hr in @('HK', 'HK'), @('D9', 'devy')) { & $J @{ agent = $hr[0]; type = $hr[1]; session = "$($hr[0])-a"; run = 'r1'; status = 'left'; handoffBrief = 'C:/b/h.md'; joined = (Get-Date).AddHours(-2).ToString('o'); beat = (Get-Date).AddMinutes(-30).ToString('o') } (Join-Path $bd "$($hr[0])-a.json") }
  $hoCount = { (@(& { . $O; Get-KitHandoffs 24 }).agent | Where-Object { $_ -in 'HK', 'D9' } | Sort-Object) -join ',' }
  $ho0 = & $hoCount; foreach ($ha in 'HK', 'D9') { $null = Px $O board join -Agent $ha -Run r2 }; $ho1 = & $hoCount; $hoJoin = Px $O board join -Agent HK -Run r1 | Out-String
  $hoAck = & { . (Lib); Test-KitAcked ([pscustomobject]@{ what = 'HANDOFF HK (r1) 40 min ago, no fresh agent yet'; kind = 'HANDOFF'; who = 'HK (r1)'; problem = 'handed off, no fresh agent yet' }) @('HANDOFF · HK (r1) · handed off, no fresh agent yet') }
  Expect "handoff: a one-per-machine agent (named after its type) is continued by its row in any run, an area id (D9) only in its run; no stale CONTINUE; an -Ack pasted from the -Brief cells (·) matches ($ho0 / $ho1)" ($ho0 -eq 'D9,HK' -and $ho1 -eq 'D9' -and $hoJoin -notmatch 'CONTINUE' -and $hoAck)
  $ntOut = & { . $O; $KitConf.TrackerTag = 'CU-'; @('PLACEHOLDER', 'CU-PLACEHOLDER', '<task>', 'abc123x') | ForEach-Object { "[$(NormTask $_)]" } }
  Expect "track: a brief's placeholder task id is no id ($($ntOut -join ''))" (($ntOut -join '') -eq '[][][][abc123x]')
  # pokey api: an unknown user names the target that holds it (names only)
  $tlf = Join-Path $k 'skills/pokey/targets.local.json'; & $J @{ default = 'ta'; targets = @{ ta = @{ api = 'http://127.0.0.1:9'; users = @{ admin = @('u1', 'p1') } }; tb = @{ api = 'http://127.0.0.1:9'; users = @{ sa = @('u2', 'p2') } } } } $tlf
  $pu = Invoke-TestScript (Join-Path $k 'skills/pokey/pokey.ps1') api -Target ta -As sa -Path /x; Remove-Item -LiteralPath $tlf
  Expect 'pokey api: an unknown user names the target holding it, never a value' ($pu.out -match "NO-USER 'sa' in target ta \(not retried[^)]*\)\. Known: admin\. 'sa' is in target\(s\) tb: -Target tb -As sa" -and $pu.out -notmatch 'u2|p2')
  # resume -MaxSeconds 0: partial, the pause kept
  $env:KIT_OFFLINE = '0'; $rpz = Px $O resume -Run mr -MaxSeconds 0 | Out-String; Remove-Item Env:KIT_OFFLINE
  Expect 'resume -MaxSeconds: out of time = partial with the runs left, their pause kept' ($rpz -match 'partial: time budget \(0 s\) used; 1 run\(s\) not resumed: mr' -and @(Get-ChildItem (TkPath $k pauses) -Filter 'pause-*.json' | ForEach-Object { Read-Json $_.FullName } | Where-Object { $_.run -eq '*' -and $_.state -ne 'resumed' }).Count)
  $planTest = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$global:sets = @(); $global:mrReads = 0
function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = 'merged' } }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { $global:mrReads++; [pscustomobject]@{ state = 'merged' } }
function Get-TrackerTask($id) { [pscustomobject]@{ status = 'review'; subtasks = @() } }
function Set-TrackerStatus($id, $s) { $global:sets += "$id=$s" }
function Set-TrackerKitComment { }; function Get-TrackerComments { }; function Add-TrackerComment { }; function Start-Process { }
@{ script = 'buildy.js'; run = 'pl'; at = (Get-Date).ToString('o'); args = @{ agents = @(@{ id = 'P1'; items = 'tpl1' }, @{ id = 'P2'; items = 'tpl1 F2' }) } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path (Get-KitPath launches -Create) 'self-buildy-pl-1.json')
@{ run = 'wf_pl'; agents = @{ P1 = @{ done = @('tpl1') } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path (Get-KitPath waves -Create) 'wf_pl.json')
$null = Invoke-Track add -Task tpl1 -Mrs 'g/web!3'; $h1 = Invoke-Track run -Detail | Out-String; $s1 = @($global:sets)
$null = Invoke-Track add -Task tpl1 -HoldPromotion ''; $null = Invoke-Track run -Detail
"plan:$($h1 -match 'HOLD tpl1: MRs merged, planned area\(s\) P2 not delivered' -and -not ($s1 -match 'tpl1=') -and $global:sets -contains 'tpl1=promoted')"
$global:mrReads = 0; foreach ($n in 1, 2) { $null = Test-KitStepEvidence @{ evidence = 'g/web!4' } }; "mrread:$($global:mrReads -eq 1)"
$pf = Join-Path (Get-KitPath pauses -Create) 'pause-fin.json'; @{ at = (Get-Date).ToString('o'); run = '*'; state = 'pausing'; agents = @(); runs = @(); released = @() } | ConvertTo-Json | Set-Content $pf
function Invoke-KitPauseLateResume { $j = Get-Content $Pf -Raw | ConvertFrom-Json; $j.released = @('late'); $j | ConvertTo-Json | Set-Content $Pf }   # a resume -Run late meanwhile
$null = Complete-KitPause $pf 0; $fin = Get-Content $pf -Raw | ConvertFrom-Json; "fin:$($fin.state -eq 'paused' -and @($fin.released) -contains 'late')"
'@
  $planRes = Invoke-PsTest 'plan-test' $planTest @($O)
  $null = Px $O supervise -Brief -Takeover 2>$null; $usageJob = Join-Path (TkPath $k background) 'bossy.ps1-budget-usage.json'
  Expect 'supervise: every sweep starts the usage refresh as a detached job, outside the section budget' (Test-Path -LiteralPath $usageJob)
  Expect-Each $planRes 'sessions: # (plan: launched areas no wave delivered hold promotion, HoldPromotion '''' releases; mrread: one MR read per resume; fin: the pause finisher keeps a released run)' @('plan', 'mrread', 'fin') 8
} finally { $fp.Kill(); $mp.Kill(); Remove-Item Env:KIT_HOLDER_PID }
# heartbeat reply (owner 2026-11-12): 1-4 action lines, never the supervise stdout; SKILL.md E1 quotes the prompt word for word
$beatRx = 'Get-KitBeatPrompt \{ "Run & .+? supervise -AutoFix -Brief\. (.+?)" \}'
$beatTail = if ((Get-Content (Join-Path $src 'skills/crafty/lib.ps1') -Raw) -match $beatRx) { $Matches[1] }
$beatDocs = @('CLAUDE.md', 'GEMINI.md', 'skills/bossy/SKILL.md' | ForEach-Object { Get-Content (Join-Path $src $_) -Raw -ErrorAction SilentlyContinue })
Expect 'heartbeat prompt: reply = 1-4 action lines, never the stdout; SKILL.md E1 quotes it; no doc asks to paste the stdout' ($beatTail -match 'Reply = 1-4 lines.*never paste the stdout' -and "$($beatDocs[2])".Contains($beatTail) -and -not ($beatDocs -match 'verbatim,? (and )?unfenced|entire stdout|renders as cards'))
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
& $J @{ gitHost = 'git.example'; gitHostType = 'command'; repos = @(@{ name = 'cmd'; ci = @{ mrPipelines = $false } }); gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$cmdf`" {repo} {n}" } } } (Join-Path $ka 'skills/crafty/kit.local.json') 5
$hostRefDir = Join-Path (Kd) 'hostref'; git init -q $hostRefDir; git -C $hostRefDir remote add origin https://git.example/o/cmd.git; $kaCrafty = Join-Path $ka 'skills/crafty/crafty.ps1'
Push-Location $hostRefDir; $hostRefOut = @(@('cmd!4'), @('g/cmd!5'), @('cmd', '6'), @('7') | % { (pwsh @np $kaCrafty host mr.get @_ | ConvertFrom-Json).title }); $hostBad = pwsh @np $kaCrafty host mr.get 'not a ref' 2>&1 | Out-String; $hostBadCode = $LASTEXITCODE; Pop-Location
Expect "host: a bare MR ref binds to {repo, n} ([group/]repo!iid, repo iid; iid = the folder's origin); neither JSON nor a ref: exit 2 + both forms ($($hostRefOut -join ' '))" (($hostRefOut -join ' ') -eq 'cmd g/cmd cmd o/cmd' -and $hostBadCode -eq 2 -and $hostBad -match 'repo!iid')
$noGitDir = Join-Path ([IO.Path]::GetTempPath()) "kit-nogit-$PID"; New-Item -ItemType Directory -Force $noGitDir | Out-Null   # outside any git repo
Push-Location $noGitDir; $hostEdge = @(@('{"repo":"cmd","n":"4"}', '5'), @('8')) | % { $edgeOut = pwsh @np $kaCrafty host mr.get @_ 2>&1 | Out-String; "$LASTEXITCODE $edgeOut" }; Pop-Location; Remove-Item -LiteralPath $noGitDir -Recurse -Force
Expect 'host: an argument after the JSON and an iid outside a git folder: exit 2, each named' ($hostEdge[0] -match '(?s)^2 .*extra argument\(s\) after the JSON: 5' -and $hostEdge[1] -match '(?s)^2 .*iid 8 needs a git folder')
Remove-TestKit $ka
# crafty.ps1 check, python stale-env
$D = Join-Path $k 'skills/crafty/crafty.ps1'
$pyCase = { param([string]$caseName, [string]$imports, [string]$body, [string[]]$extra)
  $cd = Join-Path (Kd) "py-$caseName"; New-Item -ItemType Directory -Force "$cd/src/localpkg" | Out-Null; 'NoSuchMod-Kit-Probe[x]==1.0', 'kit-bare-absent' | Set-Content "$cd/requirements.txt"; '' | Set-Content "$cd/src/localpkg/__init__.py"
  "import unittest`n$imports`nclass T(unittest.TestCase):`n    def test_a(self): $body" | Set-Content "$cd/test_$caseName.py"
  $caseOut = pwsh @np $D check -Dir $cd -Step test @extra 2>&1 | Out-String; "$LASTEXITCODE|$caseOut" }
$pyOut = @{ pin = & $pyCase pin 'import nosuchmod_kit_probe' pass @('-Tests', 'test_pin.py'); all = & $pyCase all 'import yaml_kit_absent.sub' pass @('-AllTests')
  bare = & $pyCase bare 'import kit_bare_absent' pass @('-Tests', 'test_bare.py')
  fail = & $pyCase fail 'print("optional: No module named ''zz_kit''")' 'self.assertEqual(1, 2)' @('-Tests', 'test_fail.py'); src = & $pyCase src 'import localpkg' pass @('-Tests', 'test_src.py') }
Expect "check python: a ModuleNotFoundError line = stale-env, exit 5 + the pinned ENV-FIX command; -AllTests too (a bare requirements line counts; none: no command); a failed assert (a printed optional ImportError too) or a src/ module = FAILED" (
  $pyOut.pin -match '^5\|' -and $pyOut.pin -match 'stale-env: nosuchmod_kit_probe' -and $pyOut.pin -match 'never run it from a worktree\): ".*" -m pip install -c ".*constraints-\w+\.txt" "NoSuchMod-Kit-Probe\[x\]==1\.0"' -and
  $pyOut.bare -match '^5\|' -and $pyOut.bare -match '-m pip install -c ".*" "kit-bare-absent"' -and $pyOut.all -match '^5\|' -and $pyOut.all -match 'no requirements.txt line for yaml_kit_absent' -and $pyOut.all -notmatch 'pip install' -and
  $pyOut.fail -match '(?s)^1\|.*test FAILED' -and $pyOut.fail -notmatch 'stale-env' -and $pyOut.src -match '^1\|' -and $pyOut.src -notmatch 'stale-env')
$probeRes = Invoke-PsTest 'py-probe' @'
. $args[0]; Get-PyStaleModules $args[1] 'python -X utf8' "x`nModuleNotFoundError: No module named 'zz_kit_absent.sub'`nModuleNotFoundError: No module named 'os.zz'" @()
'@ @($D, (Kd))
Expect "check python: the probe takes 'python -X utf8' and names a missing package, not a missing submodule of one found ($probeRes)" ("$probeRes" -eq 'zz_kit_absent')
# kit to-do (bossy K1): open items queued while no kitty runs = an ACT
$tdd = Join-Path (TkPath $k agents -Create) 'kitty'; New-Item -ItemType Directory -Force $tdd | Out-Null; "- [ ] a`n- [x] b`n  - [ ] c`n| 4 | x | open |" | Set-Content (Join-Path $tdd 'kit-todo.md')
$ktd = & { . $O; $kb = @(@{ status = 'left'; type = 'kitty'; agent = 'kitty'; beat = "$(Get-Date)" }, @{ status = 'working'; type = 'kitty'; agent = 'kitty-2'; beat = "$((Get-Date).AddHours(-7))" }); "$(@(Get-KitSuperviseFlagsKitTodo -Board $kb | ForEach-Object { "$($_.level) $($_.what)" }))|$(@(Get-KitSuperviseFlagsKitTodo -Board @($kb + @{ status = 'working'; type = 'kitty'; agent = 'kitty'; beat = "$(Get-Date)" })).Count)" }
Expect "kit to-do: open '- [ ]' items and no live kitty (left, or no beat for 6 h) = one ACT; a live kitty = none ($ktd)" ($ktd -eq 'ACT kit to-do has 2 open item(s), no kitty live|0')
$bu = pwsh @np $O board beat -Session 'nobody-1234' 2>&1 | Out-String; $buc = $LASTEXITCODE
Expect 'board beat: an unknown session says join first, exit 3, no stack trace' ($buc -eq 3 -and $bu -match "unknown session 'nobody-1234': board join first" -and $bu -notmatch 'Exception|at line|ScriptStackTrace')
# pipes default and statuses (crafty.ps1; moved from params for the per-file test caps)
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $lf = Join-Path (Kd) 'mrs.ps1'; Set-Content $lf "'[]'"
& $J @{ gitHost = 'git.example'; gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.list' = "pwsh -NoProfile -File `"$lf`"" } } } "$k/skills/crafty/kit.local.json"
$pipeRepo = Join-Path (Kd) 'pp'; $pipeWt = Join-Path (Kd) 'pp-wt'; git init -q -b main $pipeRepo; git -C $pipeRepo commit -q --allow-empty -m i; git -C $pipeRepo remote add origin 'https://git.example/g/pp.git'; git -C $pipeRepo worktree add -q -b TK-11-x $pipeWt
Set-Content (Join-Path "$(git -C $pipeWt rev-parse --absolute-git-dir)" 'claude-target') 'main'; Push-Location $pipeWt; $pipeNone = pwsh @np $D pipes -MaxMinutes 0 2>&1 | Out-String; $pipeNoneCode = $LASTEXITCODE
Set-Content $lf "'[{""iid"":6,""state"":""opened"",""source_branch"":""TK-11-x"",""target_branch"":""main"",""web_url"":""https://git.example/g/pp/-/merge_requests/6""}]'"; $pipeOut = pwsh @np $D pipes -MaxMinutes 0 2>&1 | Out-String; Pop-Location; Set-Content $lf "'[]'"
Expect "pipes without -Mrs in a wt worktree: its branch's open MRs; none = exit 2 naming the branch ($pipeNoneCode)" ($pipeNoneCode -eq 2 -and $pipeNone -match 'no open MR for TK-11-x -> main' -and $pipeOut -match 'pipes: -Mrs https://git\.example/g/pp/-/merge_requests/6 \(open MRs of TK-11-x\)')
# pipes: busy only with a head pipeline
$pt = @'
. $args[0]
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
 if ($Verb -eq 'mr.get') { if ($A.n -in '3', '4') { [pscustomobject]@{ state = @{ '3' = 'opened'; '4' = 'closed' }[$A.n]; head_pipeline = @{ status = 'success' } } } elseif ($A.n -ne '9') { [pscustomobject]@{ state = 'opened'; head_pipeline = $null; target_branch = 'main' } } }
 elseif ($Verb -eq 'ci.config') { if ($A.repo -match 'nocirepo') { $false } else { $null } }   # no CI file / a failed call
 elseif ($Verb -eq 'mr.url') { "https://h.example/$($A.repo)/-/merge_requests/$($A.n)" }
}
Update-KitTaskIndex tp1 { param($x) $x.track = @{ task = 'tp1'; mrs = @('g/cirepo!3', 'g/cirepo!4'); done = $false; wave = 'w-p' } }
Update-KitTaskIndex tp2 { param($x) $x.track = @{ task = 'tp2'; mrs = @('g/other!3'); done = $true } }
Push-Location $env:TEMP; $tr = Invoke-Pipes -Run w-p -MaxMinutes 0 | ConvertFrom-Json; Pop-Location
"tracked:$(@($tr.mrs).Count -eq 1 -and $tr.mrs[0].mr -eq 'https://h.example/g/cirepo/-/merge_requests/3')"
$a = Invoke-Pipes -Mrs 'https://h.example/g/nocirepo/-/merge_requests/1' -MaxMinutes 0 | ConvertFrom-Json
$b = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json
$c = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/9' -MaxMinutes 0 | ConvertFrom-Json
function Get-KitValue { @{ name = 'cirepo'; ci = @{ mrPipelines = $false } } }
"mr-off:$((Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json).done)"
"no-ci:$($a.done -and $a.mrs[0].status -eq 'no-ci')"
"no-pipeline:$(-not $b.done -and $b.mrs[0].status -eq 'no-pipeline')"
"unknown:$(-not $c.done -and $c.mrs[0].status -eq 'unknown')"
$t0 = Get-Date; $u = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/3','https://h.example/g/cirepo/-/merge_requests/4' -MaxMinutes 1 -UntilMerged | ConvertFrom-Json; $ut = ((Get-Date) - $t0).TotalSeconds; $g = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/3' -MaxMinutes 0 | ConvertFrom-Json
"until-merged:$(-not $u.done -and $u.mrs[0].status -eq 'success' -and $u.mrs[1].status -eq 'closed' -and $ut -lt 20 -and $g.done)"
'@
$res = Invoke-PsTest 'pipes-test' $pt @($D)
Expect-Each $res 'pipes: # (tracked: outside a worktree, no -Mrs = the open MRs of the tracked tasks of -Run)' 'no-ci', 'no-pipeline', 'unknown', 'mr-off', 'until-merged', 'tracked'
# every section folds (owner, 2026-11-13): open by default flags, agents, runs, machine and resources, usage; top steps + kit internals closed;
# '<title> (<count>)' in the summary, 0 = the summary only; internals hold kit tuning only (never leases, agents, usage)
$folds = Invoke-PsTest folds @'
. $args[0]
$t0 = [datetime]'2026-01-02T10:00:00'; $d0 = $t0.ToString('o'); $d1 = $t0.AddDays(-1).ToString('o')
$rn = { param($run, $id, $st, $at, $roles, $lb, $kind) [pscustomobject]@{ run = $run; id = $id; status = $st; at = $at; started = $at; roles = $roles; label = $lb; kind = $kind; done = 2; total = 2; tok = 1000; cost = 1; merged = 1; cap = 100; spent = 10; steps = @() } }
$u = [pscustomobject]@{ days = @([pscustomobject]@{ day = '2026-01-02'; tok = 5 }); rates = [pscustomobject]@{ n = 0 }; merged = [pscustomobject]@{ source = 'workflows' }
  runs = @((& $rn 'wave-brief-1' 'wf_a' 'running' $d0 'devy 2' 'Ask RM bug wave' 'build'), (& $rn 'wave-brief-1' 'wf_b' 'ended' $d0 'devy 2' 'Ask RM bug wave' 'build'), (& $rn 'wf_kit' 'wf_k' 'ended' $d0 'kitty 2' '' ''), (& $rn 'select-x' 'wf_c' 'ended' $d1 'checky 4' '' 'test')) }
$fh = Format-KitSuperviseHtml ([pscustomobject]@{ at = $d0; flags = @([pscustomobject]@{ level = 'ACT'; what = 'x' }); agents = @([pscustomobject]@{ name = 'devy-1 (devy)'; run = 'r1'; state = 'ACTIVE' }, [pscustomobject]@{ name = 'old (devy)'; run = 'r1'; state = 'FINISHED' })
  resources = @([pscustomobject]@{ name = 'browser t1'; by = 'devy-1'; gb = 0.2 }, [pscustomobject]@{ name = 'mysql'; by = ''; gb = 1 })
  stats = [pscustomobject]@{ usage = $u; params = @([pscustomobject]@{ key = 'k1'; source = 'live' }, [pscustomobject]@{ key = 'k2' }); changes = @([pscustomobject]@{ key = 'k1' }); settings = [pscustomobject]@{ heartbeatMinutes = 15 } } })
$st = foreach ($m in [regex]::Matches($fh, "<details class='sec (?<c>[^']*)' id=sec-(?<id>[\w-]+)(?<o> open)?><summary><h\d>(?<t>[^<]+)</h\d>(?:<span class=cnt>\((?<n>[^)]*)\)</span>)?(?:<span class=cnt>[^<]*</span>)?(?:<span class='chip[^']*'>[^<]*</span>)*(?:<svg.*?</svg>|<span class=sbh.*?</span>)?</summary>(?<b><div class=bd>)?")) { "$($m.Groups['id'].Value)=$(if ($m.Groups['o'].Success) { 'open' } else { 'closed' })$(if ($m.Groups['n'].Success) { ":$((($m.Groups['n'].Value -replace "<svg[^>]*aria-label='([^']*)'.*?</svg>", '[$1]') -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim())" })$(if (-not $m.Groups['b'].Success) { ':nobody' })" }
$sec = { param($id) [regex]::Match($fh, "(?s)id=sec-$id(?: open)?>.*?(?=<details class='sec top'|<footer)").Value }
$int = & $sec internals; $runsH = & $sec runs; $agH = & $sec agents
"$($st -join ' ')"
"internals:$(-not ($int -match 'sec-(resources|shells|agents|runs-)') -and $int -match 'sec-usage' -and $int -match "<details class='sec sub f' id=sec-tg-k1><summary><h4>k1</h4><span class=cnt>\(1\)</span><span class='chip'>1 learned<" -and $int -notmatch 'sec-(top|kit-runs)' -and $fh -notmatch 'wf_kit')"
$rxRun = @('id=sec-runs-2026-01-02 open><summary><h3>Today</h3><span class=cnt>\(1 runs &#183; 2 steps', 'id=sec-runs-2026-01-01><summary><h3>Yesterday', ">Ask RM bug wave</span><span class='chip k-build'>build</span><span class='chip s-oth'>resumed", "title='select-x &#183; wf_c'>select-x<")
$rxAg = @("devy-1 \(devy\)<div class=lc><span class='chip ls'[^>]*>browser t1<", 'id=sec-agents-done><summary><h3>Finished today</h3><span class=cnt>\(1\)')
$rxOrphan = "<div class='ci f orphan'[^>]*><div class=tn>mysql(?:<span class=.iv.>.*?</span>)?</div><div class=sm>no live holder"
"runs:$($runsH -notmatch 'wf_kit' -and -not @($rxRun | Where-Object { $runsH -notmatch $_ }).Count -and $runsH.IndexOf('wf_a') -lt $runsH.IndexOf('sec-runs-2026-01-02') -and ($runsH -split "class='bar sb3'").Count -eq 4 -and ($runsH -split 'class=bar>').Count -eq 2)"
$u.runs = @(1..27 | ForEach-Object { & $rn "r$_" "wf_$_" 'ended' $d0 'devy 1' '' 'build' }); $fh2 = Format-KitSuperviseHtml ([pscustomobject]@{ at = $d0; stats = [pscustomobject]@{ usage = $u } })
$rowRx = "<details class='ru f'>"; $olderTxt = '2 older run(s)'
$fh3 = Format-KitSuperviseHtml ([pscustomobject]@{ at = $d0; shells = @(1..12 | ForEach-Object { [pscustomobject]@{ pid = $_; dir = 'maven|a/b' } }) })
$uxRx = @("<tr class='f more'>", 'class=sa data-n=12>Show all \(12\)', '<nav class=jl', 'id=nm class=empty hidden', 'maven\|<wbr>a/<wbr>b', '\.tw \.lo\{display:none', 'function jp\(k,f\)\{try', 'fbl>details\[open\]', 'gk\{display:contents', "try\{L\.setItem\('kc-open'")   # a low column only inside tables (.st.lo tiles stay); stored state parsed safely
$rawTone = '(?<![-\w])color:var\(--(act|watch|sage|slate|plum)\)'   # tone text mixed toward --fg: WCAG AA in the light theme
"ux:$(([regex]::Matches($fh3, $uxRx[0])).Count -eq 2 -and -not @($uxRx | Where-Object { $fh3 -notmatch $_ }).Count -and $fh3 -notmatch $rawTone)"
"cap:$(([regex]::Matches($fh2, $rowRx)).Count -eq 25 -and $fh2.Contains($olderTxt))"
"agents:$(-not @($rxAg | Where-Object { $agH -notmatch $_ }).Count -and $fh -match $rxOrphan)"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))
$fl = @($folds | ForEach-Object { "$_" -split "`r?`n" } | Where-Object { "$_".Trim() })
$foldWant = 'flags=open', 'agents=open:[running]1', 'runs=open:[running runs]1 · 3 in 7 days', 'machine=open', 'resources=open:2', 'usage=open', 'internals=closed', 'tuning=closed:3', 'tg-k2=closed:1', 'agents-done=closed:1', 'steps=closed:0:nobody'
$foldMiss = @($foldWant | Where-Object { " $($fl[0]) " -notmatch " $([regex]::Escape($_))[ :]" })
Expect "supervise page: every section a <details> with '<title> (<count>)', the owner's default open states, an empty one summary only (missing: $foldMiss | $($fl[0]))" (-not $foldMiss.Count)
Expect-Each @($fl | Select-Object -Skip 1) 'supervise page: # (internals: usage, activity, tuning (a closed fold per area, source counts); no top steps or kit runs; runs: running first, a fold per day (today open, sum), label, kind, resumed, budget bar running or 80%+, no kit runs; agents: leases on the row, finished folded, orphan tinted; cap: newest 25 ended runs, rest counted; ux: 10 rows + Show all (N), jump links, No match, keys break at | /, tone AA)' @('internals', 'runs', 'agents', 'cap', 'ux') 5
# a CI-raised test task (tracker.ciTaskPattern): track add of its merged fix MR promotes it with no testing docs, holds while the
# named job runs again on its branch, closes it with ONE qa-result comment linking the passing job; a plain task keeps the doc gate
$ciTrack = Invoke-PsTest track-ci @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$KitConf.TrackerType = 'fake'; $global:st = 'open'; $global:kc = @(); $global:jobSt = 'running'; $global:tname = '[Backend Unit Test] Stale tests'
$jobUrl = 'https://h/g/api/-/jobs/'
function Get-TrackerTask($id) { [pscustomobject]@{ name = $global:tname; status = $global:st; subtasks = @(); description = "**Pipeline:** [x](https://h/g/api/-/pipelines/100)`n**Branch:** staging/x @ abc`n**Job:** [x](${jobUrl}7)" } }
function Set-TrackerStatus($id, $s) { $global:st = $s }
function Set-TrackerKitComment($id, $kind, $text) { $global:kc += "$kind|$text" }
function Get-TrackerComments($id) { @() }
function Start-Process { }
function ProjPath($r) { "g/$r" }
function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) { [pscustomobject]@{ state = 'merged' } }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  switch ($Verb) { 'mr.get' { [pscustomobject]@{ state = 'merged'; merge_commit_sha = 'm1' } } 'ci.runs' { @([pscustomobject]@{ id = 101; sha = 's1' }, [pscustomobject]@{ id = 99; sha = 's0' }) } 'repo.base' { [pscustomobject]@{ id = 'm1' } }
    'ci.jobs' { if ("$($A.id)" -eq '100') { @([pscustomobject]@{ id = 7; name = 'unit-x'; status = 'failed' }) } else { @([pscustomobject]@{ id = 9; name = 'unit-x'; status = $global:jobSt; web_url = "${jobUrl}9" }) } } default { $null } } }
$a1 = Invoke-Track add -Task ci1 -Mrs 'api!5' -Detail | Out-String; $s1 = "$global:st|$((Read-KitTracking).tasks['ci1'].done)"
$global:jobSt = 'success'; $r2 = Invoke-Track run -Task ci1 | Out-String
"wait:$($s1 -eq 'promoted|False' -and $a1 -match 'HOLD ci1: CI task not closed: CI job unit-x running on staging/x')"
"closed:$($global:st -eq 'closed' -and (Read-KitTracking).tasks['ci1'].done -and $r2 -match 'DONE ci1: all 1 MRs merged, CI job unit-x passed on staging/x -> closed' -and @($global:kc).Count -eq 1 -and $global:kc[0] -match '^qa-result\|QA: PASS . CI job unit-x passed on staging/x with \S*api!5 merged: https://h/g/api/-/jobs/9$')"
$global:tname = 'Plain fix'; $global:st = 'open'; $p3 = Invoke-Track add -Task ci2 -Mrs 'api!6' | Out-String
"plain:$($global:st -eq 'open' -and $p3 -match 'ATTENTION ci2: MRs merged, no testing-doc link' -and $null -eq (Get-KitCiTask ci2))"
'@ @($O)
Expect-Each $ciTrack 'track: CI task # (wait: track add of a merged MR promotes at once, holds while the job runs again; closed: job passed -> closed + one qa-result comment with the job link; plain: no pattern match = the testing-doc gate)' @('wait', 'closed', 'plain') 3
# each headline number renders once: 7-day tokens + cost (chart title), step outcomes (one bar), agents spawned (one tile; the Today list counted board rows)
$once = Invoke-PsTest once @'
$null = . $args[0] 6>$null; $t0 = [datetime]'2026-01-02T10:00:00'
$u = [pscustomobject]@{ days = @(6..0 | ForEach-Object { [pscustomobject]@{ day = $t0.AddDays(-$_).ToString('yyyy-MM-dd'); tok = 971428571; cost = 249.57 } }); byRole = @([pscustomobject]@{ k = 'devy'; n = 3; sum = 5e9; cost = 900 })
  rates = [pscustomobject]@{ n = 919; empty = 129; fail = 122; stopped = 119 }; merged = [pscustomobject]@{ source = 'workflows' } }
$sd = @([pscustomobject]@{ day = '2026-01-02'; spawned = 46 }, [pscustomobject]@{ day = '2026-01-01'; spawned = 5 })
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $t0.ToString('o'); agents = @([pscustomobject]@{ name = 'a'; state = 'ACTIVE'; since = $t0.ToString('o') }); stats = [pscustomobject]@{ usage = $u; days = $sd } })
$txt = $h -replace '(?s)<(style|script)>.*?</\1>' -replace '<[^>]+>', ' '
"$(@('6.8B', '$1,747', '549', '129', '122', '119', '46') | ForEach-Object { ([regex]::Matches($txt, "(?<![\d.])$([regex]::Escape($_))(?![\d.])")).Count }) $($h -match 'sec-timeline')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))
Expect "supervise page: 7-day tokens and cost, each step outcome render once, agents spawned not repeated in Kit internals, no Today list ($once)" ("$once".Trim() -eq '1 1 1 1 1 1 0 False')
# Settings (supervise.*): effective values, never an empty section
$setOut = Invoke-PsTest 'settings' @'
$null = . $args[0] 6>$null; $p = @{ key = 'supervise.shellStuckMinutes'; value = 45; source = 'learned' }; $__cfg = [pscustomobject]@{}; $s = Get-KitSuperviseSettings $p
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = @{ settings = $s } })
$__cfg = [pscustomobject]@{ supervise = [pscustomobject]@{ heartbeatMinutes = 10 } }; $l = (Get-KitSuperviseSettings $p).'supervise.heartbeatMinutes'
"$($s.'supervise.ramActPct'.source) $($s.'supervise.shellStuckMinutes'.source) $($h -match '<td data-k=Value>90</td><td data-k=Source>default</td>') $($l.value)/$($l.source)/$($l.default)"
'@ @($O)
Expect "settings: effective defaults with no override, learned, an override names its default ($setOut)" ("$setOut" -eq 'default learned True 10/local/15')
Remove-TestKit $k
Complete-Tests
