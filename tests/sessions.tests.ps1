#Requires -Version 7
<#
sessions.tests.ps1: several coordinators on one machine (adapters/supervise_resources.ps1 "sessions"): run owners for pause /
resume / recover (-Everyone), a stepped-aside supervise prints its own runs' flags, task claims at launch, the step-age HANDOFF.
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
} finally { $fp.Kill(); $mp.Kill(); Remove-Item Env:KIT_HOLDER_PID }
Remove-TestKit $k
Complete-Tests
