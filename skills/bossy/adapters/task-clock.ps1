#Requires -Version 7
<#
task-clock.ps1: each task's clock, first kit call -> done (owner 2026-11-25: every task under budget.taskMinutes), dot-sourced by
bossy.ps1 (skills/bossy/adapters/). The clock stream: the verbs in crafty/vocab.json clockPhases write a start and an end row of
their phase (lib.ps1 Invoke-KitVerb via crafty adapters/task-items.ps1 Get-KitClockPhase, kitbag.py audited). Per task: elapsed,
the phase it is in, minutes per phase, MR opened, done (task state track.done / doneAt). supervise: ACT past budget.taskMrMinutes
(params.registry.json) with no MR or past budget.taskMinutes not done, naming the blocker phase and its wait; WATCH still
investigating past budget.investigateMinutes. The page: the Task clock section.
Usage: dot-sourced by bossy.ps1; supervise runs Get-KitSuperviseFlagsTaskClock (Invoke-KitHooks Get-KitSuperviseFlags);
Format-KitSuperviseHtml calls Format-KitTaskClockHtml. Exit codes: none (functions only).
Sections: L13 clock · L43 flags · L71 page
#>
# ---- clock: clock rows -> one object per task { task; agent; run; start; min; done; mrAt; now; nowMin; open; spent; idle }
# a phase between calls (the agent edits or thinks): the one its last call leads to
$script:KitClockNext = @{ investigate = 'investigate'; code = 'code'; build = 'code'; lane = 'local'; local = 'local'; precheck = 'mr'; mr = 'review'; ci = 'review'; merge = 'merge'; decision = 'code' }
function Get-KitTaskClock([datetime]$Now = (Get-Date), [double]$Hours = 24, $Rows = $null) {
  $clockRows = @(@(if ($null -ne $Rows) { $Rows } else { Read-KitLog clock $Now.AddHours(-$Hours) }) | Where-Object { $_.at -and $_.phase } | Sort-Object { [datetime]$_.at })
  # a row with no task (decide ask names an item): its agent's last task
  $last = @{}; $by = [ordered]@{}
  foreach ($r in $clockRows) { $t = "$($r.task)"; if (-not $t -and $r.agent) { $t = "$($last["$($r.agent)"])" }; if (-not $t) { continue }; if ($r.agent) { $last["$($r.agent)"] = $t }
    if (-not $by.Contains($t)) { $by[$t] = [Collections.Generic.List[object]]::new() }; $by[$t].Add($r) }
  foreach ($t in $by.Keys) {
    $rs = $by[$t]; $start = [datetime]$rs[0].at; $tr = (Read-KitState (Get-KitTaskFile $t)).track
    $doneAt = if ($tr.done) { try { [datetime]$tr.doneAt } catch { [datetime]$rs[-1].at } }
    if ($doneAt -and $doneAt -lt $start) { $doneAt = $null }   # done before this clock: a reopened task runs again
    $end = if ($doneAt) { $doneAt } else { $Now }
    # open = started, no end yet (review with CI, local checks with a lane deploy); a killed call (no end): the next start of its phase wins, 2 h old: dropped
    $open = [ordered]@{}; $spent = [ordered]@{}; $mrAt = $null
    foreach ($r in $rs) { $p = "$($r.phase)"; $at = [datetime]$r.at
      if ($r.event -eq 'start') { $open[$p] = $at } elseif ($open.Contains($p)) { $spent[$p] = [double]$spent[$p] + ($at - $open[$p]).TotalMinutes; $open.Remove($p) }
      if ($p -eq 'mr' -and $r.event -eq 'end' -and "$($r.rc)" -eq '0' -and -not $mrAt) { $mrAt = $at } }
    foreach ($p in @($open.Keys)) { if (($end - $open[$p]).TotalMinutes -gt 120) { $open.Remove($p); continue }; $spent[$p] = [double]$spent[$p] + [math]::Max(0.0, ($end - $open[$p]).TotalMinutes) }
    $lastAt = [datetime]$rs[-1].at; $lp = "$($rs[-1].phase)"
    $nowP = if ($open.Count) { @($open.Keys | Sort-Object { $open[$_] } -Descending)[0] } else { "$($script:KitClockNext[$lp])" }; if (-not $nowP) { $nowP = $lp }
    $ls = @($rs | Where-Object { $_.event -eq 'start' -and "$($_.phase)" -eq $nowP })   # still in the last call's phase: since that call began
    $nowAt = if ($open.Contains($nowP)) { $open[$nowP] } elseif ($nowP -eq $lp -and $ls.Count) { [datetime]$ls[-1].at } else { $lastAt }
    [pscustomobject]@{ task = $t; agent = "$(@($rs | Where-Object agent | ForEach-Object agent)[0])"; run = "$(@($rs | Where-Object run | ForEach-Object run)[-1])"; start = $start
      min = [math]::Round(($end - $start).TotalMinutes, 1); done = [bool]$doneAt; doneAt = $doneAt; mrAt = $mrAt; now = $nowP; nowMin = [math]::Round(($end - $nowAt).TotalMinutes, 1)
      open = @($open.Keys); spent = $spent; idle = (-not $doneAt) -and ($Now - $lastAt).TotalHours -ge 3 }
  }
}

# ---- flags: one ACT per task over budget (no MR at taskMrMinutes, not done at taskMinutes), its blocker phase and the coordinator's move
function Get-KitTaskClockMove($c, $Pending) {
  $dec = @($Pending | Where-Object { $_ -and ("$($_.task)" -eq $c.task -or ($c.agent -and "$($_.agent)" -eq $c.agent)) })[0]
  if ($dec) { return @{ wait = "decision $($dec.id)"; move = "Answer decision $($dec.id) now (bossy.ps1 decide list -Ask); the item's agent goes on with the rest meanwhile" } }
  $who = if ($c.agent) { $c.agent } else { 'its agent' }
  switch ($c.now) {
    { $_ -in 'investigate', 'code' } { @{ wait = 'agent'; move = "SendMessage ${who}: time-box over: act on what you know (the smallest change that meets the goals), commit, the minimum proof the gates need" } }
    'build' { @{ wait = 'build gate'; move = 'Gate queue or a slow build (supervise RAM / gate lines): free the largest idle holder; never a rebuild loop (review fixes batched)' } }
    'lane' { @{ wait = 'lane deploy'; move = "envy.ps1 status -Env <env> (a hung train: kitty kind env); ${who} runs unit tests and precheck meanwhile (envy step 2)" } }
    { $_ -in 'local', 'precheck' } { @{ wait = 'local checks'; move = "SendMessage ${who}: one proof per goal, no repeated runs; a flaky check reruns alone once" } }
    { $_ -in 'mr', 'review', 'ci' } { @{ wait = 'review + CI'; move = 'Review and CI run together (buildy Review): crafty.ps1 pipes -Mrs <its MRs>; a dead review step: redo it (bossy.ps1 report -Run <run>)' } }
    'merge' { @{ wait = 'merge'; move = "merge-when-green armed: CI still running or a producer unmerged (bossy.ps1 track show -Task $($c.task))" } }
    default { @{ wait = "$($c.now)"; move = "Read ${who}'s transcript tail; unblock that phase" } }
  }
}
function Get-KitSuperviseFlagsTaskClock([switch]$AutoFix, $Pending = $pd, [datetime]$At = (Get-Date), $Clock = $null) {
  $capT = [double](Get-KitParam 'budget.taskMinutes'); $capM = [double](Get-KitParam 'budget.taskMrMinutes'); $capI = [double](Get-KitParam 'budget.investigateMinutes')
  $cs = @(@(if ($null -ne $Clock) { $Clock } else { Get-KitTaskClock $At }) | Where-Object { -not $_.done -and -not $_.idle } | Sort-Object { -$_.min })
  foreach ($c in $cs) {
    if ($c.now -eq 'merge' -and $c.nowMin -lt 10) { continue }   # merged, its tracker task not registered yet (buildy Track runs after ship)
    $tid = if ("$($c.task)" -match '^\d+$') { "task_$($c.task)" } else { $c.task }   # a numeric id would read as a count in the flag key
    $over = if ($capT -gt 0 -and $c.min -ge $capT) { "not merged at $([int]$c.min) min (budget $capT)" } elseif ($capM -gt 0 -and $c.min -ge $capM -and -not $c.mrAt) { "no MR at $([int]$c.min) min (budget $capM)" }
    $mv = Get-KitTaskClockMove $c @($Pending); $ph = "$($c.now) $([int]$c.nowMin) min, waits on $($mv.wait)"
    if ($over) { [pscustomobject]@{ level = 'ACT'; what = "TASK CLOCK $($tid): $over; now $ph ($($c.agent))"; kind = 'TASK CLOCK'; who = "$($c.agent) ($($c.run)), task $($c.task)"; age = "$([int]$c.min) min"; problem = "$over; $ph"; action = $mv.move } }
    elseif ($capI -gt 0 -and $c.now -eq 'investigate' -and $c.nowMin -ge $capI) { [pscustomobject]@{ level = 'WATCH'; what = "TASK CLOCK $($tid): investigating $([int]$c.nowMin) min (time-box $capI) ($($c.agent))"; kind = 'TASK CLOCK'; who = "$($c.agent), task $($c.task)"; age = "$([int]$c.min) min"; problem = 'investigate past its time-box'; action = $mv.move } }
  }
}

# ---- page: the Task clock section of Format-KitSuperviseHtml (its helpers $e $bar $table $taskA $section by dynamic scope); open first
$script:KitClockTone = [ordered]@{ investigate = '--slate'; code = '--sage'; build = '--k3'; lane = '--plum'; local = '--k2'; precheck = '--k4'; mr = '--watch'; ci = '--watch'; merge = '--sage2'; decision = '--act' }
function Format-KitTaskClockHtml([datetime]$At = (Get-Date), $Clock = $null, [double]$Budget = [double](Get-KitParam 'budget.taskMinutes')) {
  $cs = @(@(if ($null -ne $Clock) { $Clock } else { try { Get-KitTaskClock $At } catch { } }) | Where-Object { $_ } | Sort-Object { [int]$_.done }, { -$_.min })
  if (-not $cs.Count) { return '' }
  $rows = @(foreach ($c in $cs) {
      $tot = [math]::Max(0.1, [double]($c.spent.Values | Measure-Object -Sum).Sum)
      $seg = @(foreach ($p in @($c.spent.Keys)) { $m = [double]$c.spent[$p]; if ($m -le 0) { continue }; $tn = if ($script:KitClockTone[$p]) { $script:KitClockTone[$p] } else { '--mt' }
          "<i title='$(& $e "$p $([math]::Round($m, 1)) min")' style='display:inline-block;border-radius:0;width:$([math]::Round(100 * $m / $tot, 1))%;background:var($tn)'></i>" })
      $lab = @(foreach ($p in @($c.spent.Keys)) { if ([double]$c.spent[$p] -gt 0) { "$p $([math]::Round([double]$c.spent[$p]))" } }) -join ' · '
      $state = if ($c.done) { 'done' } elseif ($c.idle) { "idle since $($c.now)" } else { "$($c.now) $([int]$c.nowMin) min" }
      , @(@{ h = & $taskA $c.task }, "$($c.agent)", @{ h = & $bar ([double]$c.min) $Budget "$([int]$c.min) of $([int]$Budget) min" }, $state, $(if ($c.mrAt) { ([datetime]$c.mrAt - [datetime]$c.start).TotalMinutes.ToString('0') + ' min' } else { '—' }),
        @{ h = "<span class=bar style='white-space:nowrap;font-size:0'>$($seg -join '')</span><span class=bl>$(& $e $lab)</span>" })
    })
  $cnt = "$(@($cs | Where-Object { -not $_.done -and -not $_.idle }).Count) open · $(@($cs | Where-Object done).Count) done · 24 h"
  & $section 'tasks' 'Task clock' $cnt (& $table @('Task', 'Agent', 'Elapsed', 'Now', '~MR at', 'Phases (min)') $rows) -Open
}
