#Requires -Version 7
<#
task-clock.ps1: each task's clock, first kit call -> done (owner 2026-11-25: every task under budget.taskMinutes), dot-sourced by
bossy.ps1 (skills/bossy/adapters/). The clock stream: the verbs in crafty/vocab.json clockPhases write a start and an end row of
their phase (lib.ps1 Invoke-KitVerb via crafty adapters/task-items.ps1 Get-KitClockPhase, kitbag.py audited). Per task: elapsed,
the phase it is in, minutes per phase, MR opened, done (task state track.done / doneAt). supervise: ACT past budget.taskMrMinutes
(params.registry.json) with no MR or past budget.taskMinutes not done, naming the blocker phase and its wait; WATCH still
investigating past budget.investigateMinutes. Elapsed = time with a live agent; no live agent = stopped. The page: each task row of
Delivery (outcomes.ps1). Usage: dot-sourced by bossy.ps1; supervise runs Get-KitSuperviseFlagsTaskClock (Invoke-KitHooks
Get-KitSuperviseFlags); Format-KitDeliveryHtml calls Format-KitTaskClockCell / Get-KitTaskClockLine. Exit codes: none (functions only).
Sections: L13 clock · L72 flags · L100 page
#>
# ---- clock: clock rows -> one object per task { task; agent; run; start; min; done; mrAt; mrMin; now; nowMin; open; spent; stopped }
# a phase between calls (the agent edits or thinks): the one its last call leads to
$script:KitClockNext = @{ investigate = 'investigate'; code = 'code'; build = 'code'; lane = 'local'; local = 'local'; precheck = 'mr'; mr = 'review'; ci = 'review'; merge = 'merge'; decision = 'code' }
# minutes covered by intervals @(start, end) inside [From, To] (parallel agents and phases count once)
function Measure-KitClockSpan($Spans, [datetime]$From, [datetime]$To) {
  $sum = 0.0; $reach = $From
  foreach ($sp in @($Spans | Where-Object { $_ } | Sort-Object { $_[0] })) { $s = if ($sp[0] -gt $reach) { $sp[0] } else { $reach }; $x = if ($sp[1] -lt $To) { $sp[1] } else { $To }
    if ($x -gt $s) { $sum += ($x - $s).TotalMinutes; $reach = $x } }
  $sum
}
# elapsed (owner 2026-11-26) = time with a live agent: phases + waits while a board entry of the task (its items or a clock agent) lived;
# stops at done (track.doneAt) or merged (track.mergedSeenAt); no live entry now = stopped (no agent), never counted on
function Get-KitTaskClock([datetime]$Now = (Get-Date), [double]$Hours = 24, $Rows = $null, $Board = $null) {
  # one computation per sweep minute (supervise flags + the page's Delivery rows)
  $mk = if ($null -eq $Rows -and $null -eq $Board) { "$($Now.ToString('yyyyMMddHHmm'))|$Hours" }
  if ($mk -and $script:KitClockMemo -and $script:KitClockMemo.k -eq $mk) { return $script:KitClockMemo.v }
  if ($mk) { $v = @(Get-KitTaskClock $Now $Hours @(Read-KitLog clock $Now.AddHours(-$Hours)) @(Read-KitJsonFiles (Get-KitPath board))); $script:KitClockMemo = @{ k = $mk; v = $v }; return $v }
  # rows after Now (written while supervise ran, a page drawn from an older report): not yet, else nowMin goes negative
  $clockRows = @(@(if ($null -ne $Rows) { $Rows } else { Read-KitLog clock $Now.AddHours(-$Hours) }) | Where-Object { $_.at -and $_.phase -and [datetime]$_.at -le $Now } | Sort-Object { [datetime]$_.at })
  # board entries of the window, indexed once: by item (raw, NormTask'd: CU-<id>, '<id> (fix round 2)') and, with no items, by agent
  $byItem = @{}; $byAgent = @{}; $cut = $Now.AddHours(-$Hours)
  foreach ($b in @(@(if ($null -ne $Board) { $Board } else { Read-KitJsonFiles (Get-KitPath board) }) | Where-Object { $_ -and $_.joined -and $_.beat -and [datetime]$_.beat -ge $cut })) {
    $bi = @(@("$($b.items)" -split '[\s,;()]+') + @(Get-KitItemTasks "$($b.items)") | Where-Object { $_ } | Select-Object -Unique)
    if ($bi.Count) { foreach ($i in $bi) { $byItem[$i] = @(@($byItem[$i]) + $b | Where-Object { $_ }) } } else { $byAgent["$($b.agent)"] = @(@($byAgent["$($b.agent)"]) + $b | Where-Object { $_ }) } }
  # a row with no task (decide ask names an item): its agent's last task
  $last = @{}; $by = [ordered]@{}
  foreach ($r in $clockRows) { $t = "$($r.task)"; if (-not $t -and $r.agent) { $t = "$($last["$($r.agent)"])" }; if (-not $t) { continue }; if ($r.agent) { $last["$($r.agent)"] = $t }
    if (-not $by.Contains($t)) { $by[$t] = [Collections.Generic.List[object]]::new() }; $by[$t].Add($r) }
  foreach ($t in $by.Keys) {
    $rs = $by[$t]; $start = [datetime]$rs[0].at; $ts = Read-KitState (Get-KitTaskFile $t); $tr = $ts.track; $ids = @(@($t) + @($ts.itemIds) | Where-Object { $_ } | ForEach-Object { "$_" })
    $doneAt = if ($tr.done) { try { [datetime]$tr.doneAt } catch { [datetime]$rs[-1].at } } elseif ($tr.mergedSeenAt) { try { [datetime]$tr.mergedSeenAt } catch { } }
    if ($doneAt -and $doneAt -lt $start) { $doneAt = $null }   # done before this clock: a reopened task runs again
    if ($doneAt -and $doneAt -gt $Now) { $doneAt = $null }
    $end = if ($doneAt) { $doneAt } else { $Now }
    # open = started, no end yet (review with CI, local checks with a lane deploy); a killed call (no end): the next start of its phase wins, 2 h old: dropped
    $open = [ordered]@{}; $spent = [ordered]@{}; $mrAt = $null; $spans = [Collections.Generic.List[object]]::new()
    foreach ($r in $rs) { $p = "$($r.phase)"; $at = [datetime]$r.at
      if ($r.event -eq 'start') { $open[$p] = $at } elseif ($open.Contains($p)) { $spent[$p] = [double]$spent[$p] + ($at - $open[$p]).TotalMinutes; $spans.Add(@($open[$p], $at)); $open.Remove($p) }
      if ($p -eq 'mr' -and $r.event -eq 'end' -and "$($r.rc)" -eq '0' -and -not $mrAt) { $mrAt = $at } }
    foreach ($p in @($open.Keys)) { if (($end - $open[$p]).TotalMinutes -gt 120) { $open.Remove($p); continue }; $spent[$p] = [double]$spent[$p] + [math]::Max(0.0, ($end - $open[$p]).TotalMinutes); $spans.Add(@($open[$p], $end)) }
    # live spans: board entries whose items name the task (or its itemIds), or with no items a clock agent of it; left / dead holder: until its last beat
    $ags = @($rs | Where-Object agent | ForEach-Object { "$($_.agent)" } | Select-Object -Unique)
    $seenB = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)   # by reference: Select-Object -Unique folds every pscustomobject into one
    $mine = @(@($ids | ForEach-Object { $byItem[$_] }) + @($ags | ForEach-Object { $byAgent[$_] }) | Where-Object { $_ -and $seenB.Add($_) })
    $alive = @($mine | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -ne $false -and ($Now - [datetime]$_.beat).TotalHours -lt 3 })
    foreach ($b in $mine) { $spans.Add(@([datetime]$b.joined, $(if (@($alive | Where-Object { [object]::ReferenceEquals($_, $b) }).Count) { $Now } else { [datetime]$b.beat }))) }
    $lastAt = [datetime]$rs[-1].at; $lp = "$($rs[-1].phase)"
    $nowP = if ($open.Count) { @($open.Keys | Sort-Object { $open[$_] } -Descending)[0] } else { "$($script:KitClockNext[$lp])" }; if (-not $nowP) { $nowP = $lp }
    $ls = @($rs | Where-Object { $_.event -eq 'start' -and "$($_.phase)" -eq $nowP })   # still in the last call's phase: since that call began
    $nowAt = if ($open.Contains($nowP)) { $open[$nowP] } elseif ($nowP -eq $lp -and $ls.Count) { [datetime]$ls[-1].at } else { $lastAt }
    # no board entry at all (an agent outside the board): the old rule, 3 h without a clock row = gone
    $stopped = (-not $doneAt) -and $(if ($mine.Count) { -not $alive.Count } else { ($Now - $lastAt).TotalHours -ge 3 })
    [pscustomobject]@{ task = $t; agent = "$(@($rs | Where-Object agent | ForEach-Object agent)[-1])"; run = "$(@($rs | Where-Object run | ForEach-Object run)[-1])"; start = $start
      min = [math]::Round((Measure-KitClockSpan $spans $start $end), 1); done = [bool]$doneAt; doneAt = $doneAt; mrAt = $mrAt
      mrMin = $(if ($mrAt) { [math]::Round((Measure-KitClockSpan $spans $start $mrAt), 1) }); now = $nowP; nowMin = [math]::Round([math]::Max(0.0, ($end - $nowAt).TotalMinutes), 1)
      open = @($open.Keys); spent = $spent; stopped = $stopped; idle = $stopped }
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

# ---- page: the clock on each task row of Delivery's task list (owner 2026-11-26: no own section; outcomes.ps1 Format-KitDeliveryHtml);
# helpers $e $bar by dynamic scope (Format-KitSuperviseHtml)
$script:KitClockTone = [ordered]@{ investigate = '--slate'; code = '--sage'; build = '--k3'; lane = '--plum'; local = '--k2'; precheck = '--k4'; mr = '--watch'; ci = '--watch'; merge = '--sage2'; decision = '--act' }
# one task's clock: elapsed bar vs the budget (its colour: sage / watch at 80% / act at 100%), now, ~MR at, labelled phase strip
function Format-KitTaskClockCell($c, [double]$Budget = [double](Get-KitParam 'budget.taskMinutes')) {
  $tot = [math]::Max(0.1, [double]($c.spent.Values | Measure-Object -Sum).Sum)
  $seg = @(foreach ($p in @($c.spent.Keys)) { $m = [double]$c.spent[$p]; if ($m -le 0) { continue }; $tn = if ($script:KitClockTone[$p]) { $script:KitClockTone[$p] } else { '--mt' }
      "<i title='$(& $e "$p $([math]::Round($m, 1)) min")' style='display:inline-block;border-radius:0;width:$([math]::Round(100 * $m / $tot, 1))%;background:var($tn)'></i>" })
  $lab = @(foreach ($p in @($c.spent.Keys)) { if ([double]$c.spent[$p] -gt 0) { "$p $([math]::Round([double]$c.spent[$p]))" } }) -join ' · '
  $state = if ($c.done) { 'done' } elseif ($c.stopped) { 'stopped (no agent)' } else { "now $($c.now) $([int]$c.nowMin) min" }
  $tone = if ($c.stopped) { 'mt' } else { '' }
  "<span class=tck title='$(& $e "task clock: time with a live agent$(if ($c.agent) { " ($($c.agent))" })")'>$(& $bar ([double]$c.min) $Budget "$([int]$c.min) of $([int]$Budget) min" $tone)<span class=m>$(& $e $state)$(if ($null -ne $c.mrMin) { " · MR at $([int]$c.mrMin) min" })</span>" +
    "<span class=bar style='white-space:nowrap;font-size:0'>$($seg -join '')</span><span class=bl>$(& $e $lab)</span></span>"
}
# the Delivery group line's clock part: live tasks, over budget, stopped
function Get-KitTaskClockLine($Clock, [double]$Budget = [double](Get-KitParam 'budget.taskMinutes')) {
  $cs = @($Clock | Where-Object { $_ }); if (-not $cs.Count) { return '' }
  $lv = @($cs | Where-Object { -not $_.done -and -not $_.stopped }); $ov = @($lv | Where-Object { $Budget -gt 0 -and $_.min -ge $Budget }).Count; $sp = @($cs | Where-Object stopped).Count
  "task clock: $($lv.Count) live$(if ($ov) { " ($ov over $([int]$Budget) min)" })$(if ($sp) { " · $sp stopped (no agent)" })"
}
