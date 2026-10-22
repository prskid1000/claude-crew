<#
orch.ps1: the coordinator + kit commands (orchestrate SKILL.md). pwsh 7: & <kit>/skills/orchestrate/orch.ps1 <verb> [args]
  board join|beat|check|leave|show|msg|inbox -Agent -Run [-Claims] [-Session]   agent board, messages
  learn -Skill -Kind -Text | -Read | -Show (-Lesson | -Bump | -Fixed | -Trim | -Stats | -History: extra kit-admin)   signals, lessons
  launch -RunId -Script -ArgsJson | -Self -Script -Run -ArgsFile -Fnv [-Plan] | -Done -RunId|-Run | -List [-Brief]
  recover [-RunId <id> | -Run <runs>] [-Hours 48]   stopped runs: state, resume brief, exact resume call
  pause -Run <run> | -All [-Reason] [-Wait 10] · resume -Run <run> | -All [-Wait <min>]   stop at checkpoints; paused / crashed runs back
  program set|get|list -Program <name> [-Key <k>] [-Value <v>]   the coordinator's program state in .state
  budget [-Model] [-Plan 'role/model:n,..'] [-Run <run>] [-Json]   agent budget, run cap + spend
  track add -Task -Mrs [-MergeAfter] [-Discover] [-HoldPromotion] | run [-Detail]   task <-> MRs; promoted when all merged
  supervise [-AutoFix] [-Brief] [-Agents] [-Json] [-Takeover] [-Session]   heartbeat
  report -Run <id> [-Detail] · bugbrief -Task -Agent -Repos · cleanup [-DryRun] [-IfDue] [-Quiet] [-WorktreesOnly]
  audit [-Run <run | wf id>] [-Agent] [-Task] [-Since 2h|3d|<time>] [-Last N] [-All] [-Json]   one timeline: kitlog + journal + board
  deploy plan|request|record|intest ... (extra deploys) · decide ask|list|answer|wait ...   deploy batch; decision pauses
  health · setup [-Exclude] [-WriteLocal] · guard-sendmessage · prepush · precommit (extra kit-admin)   hooks and install
Extras (kittool.py extra add <name>) install skills/orchestrate/adapters/*.ps1, loaded below; their hooks: Invoke-KitHooks.
Exit codes: 0 ok · 1 problem / not answered / blocked · 2 usage.
Sections: L23 init · L51 board · L216 budget · L244 launch · L336 recover · L403 pause · L447 resume · L505 program · L549 track ·
  L822 supervise report · L863 anomalies · L892 supervise · L1150 report · L1227 audit · L1287 bugbrief · L1397 cleanup ·
  L1521 learn · L1551 decide · L1617 health · L1679 retro due · L1689 the kit origin's main and extras · L1705 setup ·
  L1770 guard-sendmessage
#>
# ---- init: verb arguments, lib.ps1, adapters, shared helpers
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# a broken adapter must not take every verb (and the hooks) down with it
foreach ($adapter in @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue)) { try { . $adapter.FullName } catch { [Console]::Error.WriteLine("adapter $($adapter.Name): $_") } }
# a feature moved to the extras branch: its function when installed, else one clear line instead of a crash
function Assert-KitExtra([string]$Function, [string]$Feature, [string]$Extra) {
  $fn = Get-Command $Function -CommandType Function -ErrorAction SilentlyContinue; if ($fn) { return $fn }
  "$Feature is an extra: run kittool.py extra add $Extra"; exit 1
}
# what installed extras add to a verb: every function named <Prefix>* (adapters/*.ps1); it sees the calling verb's variables
function Invoke-KitHooks([string]$Prefix, [hashtable]$Arguments = @{}) {
  foreach ($hook in @(Get-Command "$Prefix*" -CommandType Function -ErrorAction SilentlyContinue)) { & $hook @Arguments }
}
# workflow run folders (<Claude project dir>/<session>/subagents/workflows/<run>) of every session, or of one
function Get-KitWorkflowDirs([string]$Session) {
  Get-ChildItem $(if ($env:KIT_TRANSCRIPTS) { $env:KIT_TRANSCRIPTS } else { $KitConf.ClaudeProjectDir }) -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents/workflows') -Directory -ErrorAction SilentlyContinue }
}
# every parsed *.json of a state folder, each with its path in .file; a broken file is skipped
function Read-KitJsonFiles([string]$Dir, [string]$Filter = '*.json') {
  if (-not $Dir) { return }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue)) {
    $o = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }
    if ($o) { $o | Add-Member -Force NoteProperty file $f.FullName; $o }
  }
}

# ---- board: who is alive; one writer per worktree
# $Change returns $null = unchanged; script scope: supervise uses it too
function Update-BoardEntry([string]$Path, [scriptblock]$Change) {
  Invoke-KitLocked $Path { if (Test-Path $Path) { $e0 = Get-Content $Path -Raw | ConvertFrom-Json; $n0 = & $Change $e0; if ($null -ne $n0) { Write-KitAtomic $Path ($n0 | ConvertTo-Json) } } }
}
# board entries whose session process is gone (crash, reboot): left + crashed (health, supervise -AutoFix); the entries
function Set-KitBoardCrashed {
  foreach ($e in @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -eq $false })) {
    Update-BoardEntry $e.file { param($x) $x.status = 'left'; $x | Add-Member -Force NoteProperty crashed (Get-Date).ToString('o'); $x }; $e
  }
}
function Get-KitCheckpointFile([string]$Agent) { Join-Path (Get-KitPath agents) "$(ConvertTo-KitSlug $Agent)/resume.json" }
function Get-KitCheckpoint([string]$Agent) { $f = Get-KitCheckpointFile $Agent; if (Test-Path -LiteralPath $f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch {} } }
# the newest pause holding this run (one of all runs unless resume released it), $null when none
function Get-KitActivePause([string]$Run) { @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($_.run -eq $Run -or ($_.run -eq '*' -and $Run -notin @($_.released))) } | Sort-Object { [datetime]$_.at })[-1] }
function Get-InboxFile([string]$Agent) { Join-Path (Get-KitPath board -Create) "inbox/$($Agent.ToLower() -replace '[^\w.-]', '_').jsonl" }
function Send-BoardMsg([string]$From, [string]$To, [string]$Text) {
  $f = Get-InboxFile $To; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $line = [ordered]@{ at = (Get-Date).ToString('o'); from = $From; text = $Text; read = $false } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
}
function Invoke-Board {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('join', 'beat', 'show', 'check', 'leave', 'msg', 'inbox')][string]$Action,
  [string]$Agent, [string]$Area = '', [string]$Items = '', [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree, [switch]$Resume, [string]$Type = '',
  [string]$To, [string]$Text, [switch]$All, [string]$Model = '', [string]$Handoff = '', [double]$Wait = 1.5
)
$dir = Get-KitPath board -Create
$staleMin = [double](Get-KitSetting 'idle.beatMinutes' 20)
function All { Read-KitJsonFiles $dir }
function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
# plain claims only lowercased: GetFullPath mangles them
function Norm($p) { if (-not $p) { return }; if ($p -match '[\\/]|^[A-Za-z]:') { [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } else { $p.ToLower() } }
# "86abc F2, X1" -> 86abc X1: bug tasks share check ids
function ItemKeys($s) {
  $task = $null
  foreach ($t in @($s -split '\s*,\s*' | Where-Object { $_ })) {
    if ($t -match '^(?<task>\S+)\s+(?<check>.+)$') { $task = $Matches.task; $t.ToLower() }
    elseif ($task -and $t -match '^[A-Za-z]{0,3}\d+[a-z]?$') { "$task $t".ToLower() }
    else { $t.ToLower() }
  }
}
function Warnings($me, $act) {
  foreach ($o in $act | Where-Object { $_.session -ne $me.session }) {
    if ($o.agent -eq $me.agent -and (-not $me.run -or $o.run -eq $me.run)) { "DUPLICATE: agent $($o.agent) is also active in session $($o.session) (joined $(([datetime]$o.joined).ToString('HH:mm'))). The newer session must stop without writing." }
    $shared = @($o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -in @($me.worktrees | ForEach-Object { Norm $_ }) }
    if ($shared) { "CLAIM: $($o.agent) also claims $($shared -join ', ') (worktree / phone / port). Don't both use it - tell the coordinator." }
    if ($me.run -and $o.run -eq $me.run -and $me.items -and $o.items) {
      $theirs = @(ItemKeys $o.items); $common = @(ItemKeys $me.items) | Where-Object { $_ -in $theirs }
      if ($common) { "AREA: $($o.agent) also lists $($common -join ', ')." }
    }
  }
}
function Print($act) {
  if (-not $act) { 'board: no other active agents'; return }
  'board (active agents):'
  $act | Sort-Object run, agent | ForEach-Object { $task = "$(if ($_.items) { $_.items } else { $_.area })"; $cl = (@($_.worktrees | ForEach-Object { Split-Path "$_" -Leaf }) -join ',')
    '  {0,-6} {1,-6} {2,-14} {3,-8} {4,-30} {5,-22} {6} | beat {7}{8}' -f $_.agent, "$($_.type)", $_.run, "$(if ($_.holderPid) { "s$($_.holderPid)" })", $task.Substring(0, [math]::Min(30, $task.Length)), $cl.Substring(0, [math]::Min(22, $cl.Length)), $_.status, ([datetime]$_.beat).ToString('HH:mm'), $(if ($_.budget) { " | spend $([int]($_.spend / 1000))k/$([int]($_.budget / 1000))k" }) }
}
function Get-Unread([string]$who) { $f = Get-InboxFile $who; if (Test-Path $f) { @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { -not $_.read }).Count } else { 0 } }

switch ($Action) {
  'join' {
    if (-not $Agent) { throw 'join needs -Agent' }
    $now = Get-Date
    $myClaims = @(Split-KitList $Worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $same = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.status -ne 'left' })
    $notes = @()
    $rejoin = $same | Where-Object { -not $Resume -and ($now - [datetime]$_.beat).TotalMinutes -lt 2 -and ((@(Split-KitList $_.worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique) -join '|') -eq ($myClaims -join '|')) } |
      Sort-Object { [datetime]$_.joined } -Descending | Select-Object -First 1
    if ($rejoin) { $tok = $rejoin.session; $joined = $rejoin.joined; $notes += "REJOIN: same agent, run and claims within 2 min - reusing session $tok" }
    else { $tok = "$Agent-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $joined = $now.ToString('o') }
    # the dead pid is the join shell's: not alone
    foreach ($o in @($same | Where-Object { $_.session -ne $tok })) {
      $alive = $o.pid -and (Test-KitPid $o.pid $o.pidStart)
      $age = ($now - [datetime]$o.beat).TotalMinutes
      $shared = @(@(Split-KitList $o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -and $_ -in $myClaims })
      $why = if ((Test-KitHolder $o) -eq $false) { "its session process $($o.holderPid) is gone (crash or restart)" } elseif (-not $alive -and $age -ge 3) { "no heartbeat for $([int]$age) min" } elseif ($Resume -and $shared.Count) { "-Resume on $($shared -join ', ')" } else { $null }
      if (-not $why) { continue }
      try {
        Update-BoardEntry $o.file { param($j) $j.status = 'left'; $j | Add-Member -Force NoteProperty takenOverBy $tok; $j | Add-Member -Force NoteProperty takenOverAt $now.ToString('o'); $j }
        $notes += "TAKEOVER: replaced session $($o.session) ($why; joined $(([datetime]$o.joined).ToString('HH:mm')), last beat $(([datetime]$o.beat).ToString('HH:mm')))"
      } catch { $notes += "could not take over session $($o.session): $_" }
    }
    $me = [ordered]@{ agent = $Agent; type = $(if ($Type) { $Type } else { "$env:CLAUDE_AGENT_TYPE" }); session = $tok; run = $Run; area = $Area; items = $Items; worktrees = @(Split-KitList $Worktrees); contracts = $Contracts
                      status = 'working'; joined = $joined; beat = $now.ToString('o'); pid = $PID; pidStart = (Get-KitPidStart $PID) } + (Get-KitHolder)
    $bg = Get-KitBudget -Model $Model; $me += [ordered]@{ tool = $bg.tool; model = $bg.model; budget = $bg.budget; handoff = $bg.handoff; spend = 0 }
    $mf = Join-Path $dir "$tok.json"; Invoke-KitLocked $mf { Write-KitAtomic $mf ($me | ConvertTo-Json) }
    $ho = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.handoffBrief -and -not $_.continuedBy } | Sort-Object { [datetime]$_.beat } -Descending)[0]
    if ($ho) { Update-BoardEntry $ho.file { param($x) $x | Add-Member -Force NoteProperty continuedBy $tok; $x }; "CONTINUE: the previous $Agent handed off at its budget: read its resume brief $($ho.handoffBrief) first, then go on from there" }
    $ck = Get-KitCheckpoint $Agent
    if ($ck -and -not $ck.done -and $ck.next -ne 'none' -and (-not $Run -or -not $ck.run -or $ck.run -eq $Run)) {
      $rb = Join-Path (Split-Path (Get-KitCheckpointFile $Agent)) 'resume-brief.md'
      "CHECKPOINT: start at step '$($ck.next)': $(if (Test-Path -LiteralPath $rb) { "$rb (orch.ps1 resume verified it), " })$((Get-KitCheckpointFile $Agent) -replace 'json$', 'md'). Done steps: verify (sha, MR, doc exist), never redo; an uncommitted diff is the interrupted step's work: keep it"
    }
    $act = @(Active | Where-Object session -ne $tok)
    Print $act
    $notes | ForEach-Object { $_ }
    $w = @(Warnings ([pscustomobject]$me) $act)
    if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" } }
    $c = if ($Contracts) { $Contracts } else { (Active | Where-Object { $_.run -eq $Run -and $_.contracts } | Select-Object -First 1).contracts }
    if ($c -and (Test-Path $c)) { "CONTRACTS ($c) - re-read before every push:"; Get-Content $c | Select-Object -First 60 | ForEach-Object { "  $_" } }
    "budget: $($bg.tool) $(if ($bg.model) { $bg.model } else { '(default model)' }) $($bg.budget) tokens, handoff at $($bg.handoff) ($($bg.row): $($bg.source)); every beat prints the spend"
    "SESSION $tok   (pass -Session $tok to beat / check / leave)"
  }
  'beat' {
    $f = Join-Path $dir "$Session.json"; if (-not (Test-Path $f)) { throw "unknown session $Session - join first" }
    $script:beatEntry = $null; $script:beatTaken = $null
    Update-BoardEntry $f { param($x) if ($x.status -eq 'left' -and $x.takenOverBy) { $script:beatTaken = $x; return $null }; $x.beat = (Get-Date).ToString('o'); if ($Status) { $x.status = $Status }; $script:beatEntry = $x; $x }
    if ($script:beatTaken) { $me = $script:beatTaken; "TAKEN OVER: session $($me.takenOverBy) replaced $Session at $(([datetime]$me.takenOverAt).ToString('HH:mm')). Stop without writing and tell the coordinator."; exit 1 }
    $me = $script:beatEntry
    # spend = this agent's transcript (found by its SESSION line); at the handoff point a fresh agent continues from a resume brief
    $tf = if ($me.transcript) { $me.transcript } elseif ($me.tool -eq 'claude' -and -not ($me.txTry -and ((Get-Date) - [datetime]$me.txTry).TotalMinutes -lt 10)) { Update-BoardEntry $f { param($x) $x | Add-Member -Force NoteProperty txTry (Get-Date).ToString('o'); $x }; Find-KitTranscript "SESSION $Session" }; $sp = Get-KitSpend $tf
    if ($sp) {
      $bg = if ($sp.model -and $sp.model -ne $me.model) { Get-KitBudget -Model $sp.model } else { [pscustomobject]@{ budget = $me.budget; handoff = $me.handoff; model = $me.model } }
      Update-BoardEntry $f { param($x) foreach ($p in @{ transcript = $tf; spend = $sp.spend; model = $bg.model; budget = $bg.budget; handoff = $bg.handoff }.GetEnumerator()) { $x | Add-Member -Force NoteProperty $p.Key $p.Value }; $x }
      "budget: spend $($sp.spend) / $($bg.budget) (handoff at $($bg.handoff))"
      if ($bg.handoff -and $sp.spend -ge $bg.handoff) { $hb = Join-Path (Get-KitPath briefs -Create) "$(ConvertTo-KitSlug "handoff-$($me.agent)-$Session").md"; "HANDOFF: spend $($sp.spend) >= $($bg.handoff): write a resume brief (templates.md ""Resume brief"") to $hb, commit WIP, board leave -Session $Session -Handoff $hb, return handoff = $hb and stop: a fresh agent continues" }
    }
    $u = Get-Unread $me.agent; if ($u) { "INBOX: $u message(s) wait: orch.ps1 board inbox -Agent $($me.agent)" }
    $pz = Get-KitActivePause $me.run; if ($pz) { "PAUSE ($($pz.reason)): now, at this step boundary: dev.ps1 checkpoint, dev.ps1 wt commit (WIP, no push), release your leases, then board leave -Session $Session -Status paused (again while it prints PAUSED); return no result" }
    $w = @(Warnings $me @(Active)); if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" }; exit 1 }
  }
  'show' { $act = @(Active | Where-Object { -not $Run -or $_.run -eq $Run }); Print $act; @($act | ForEach-Object { Warnings $_ $act }) | Sort-Object -Unique | ForEach-Object { "  ! $_" }
    Invoke-KitHooks Get-KitBoardLines }   # extra supervise-resources: QA seats, local-env leases
  'check' {
    if (-not $Worktree) { 'usage: board check -Worktree <dir> -Session <token>'; exit 2 }
    $mine = Norm $Worktree
    $others = @(Active | Where-Object { $_.session -ne $Session -and (@($_.worktrees | ForEach-Object { Norm $_ }) -contains $mine) })
    if ($others) { $others | ForEach-Object { "OTHER WRITER: $($_.agent) (session $($_.session), status $($_.status), beat $(([datetime]$_.beat).ToString('HH:mm')))" }; exit 1 }
    'ok: no other active agent claims this worktree'; exit 0
  }
  'leave' {
    $f = Join-Path $dir "$Session.json"
    if (-not $Session -or -not (Test-Path $f)) { "board leave: unknown session '$Session' (nothing left, no handoff recorded)"; exit 1 }
    $paused = $Status -eq 'paused'
    Update-BoardEntry $f { param($x) $x.status = 'left'; $x.beat = (Get-Date).ToString('o'); if ($Handoff) { $x | Add-Member -Force NoteProperty handoffBrief $Handoff }; if ($paused) { $x | Add-Member -Force NoteProperty paused $x.beat }; $script:leftEntry = $x; $x }
    $cf = Get-KitCheckpointFile $script:leftEntry.agent
    if (-not $paused -and -not $Handoff -and (Test-Path -LiteralPath $cf)) { try { Invoke-KitLocked $cf { $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json; if (-not $c.run -or "$($c.run)" -eq "$($script:leftEntry.run)") { $c | Add-Member -Force NoteProperty done $true; Write-KitAtomic $cf ($c | ConvertTo-Json -Depth 6) } } } catch {} }   # finished: the next join starts fresh
    if ($paused) {
      $until = (Get-Date).AddMinutes($Wait); while (($pz = Get-KitActivePause $script:leftEntry.run) -and (Get-Date) -lt $until) { Wait-KitPoll 10 }
      if ($pz) { "PAUSED ($Session): stay stopped, return no result; the coordinator stops this run or resumes it. Run this same leave again now"; exit 0 }
      "RESUMED: board join -Agent $($script:leftEntry.agent) -Run '$($script:leftEntry.run)' -Resume, then go on at your checkpoint's next step"; exit 0
    }
    "left ($Session)$(if ($Handoff) { ": handoff brief $Handoff (a fresh agent continues: board join prints CONTINUE)" })"
  }
  'msg' {
    if (-not ($Agent -and $To -and $Text)) { 'usage: board msg -Agent <me> -To <agent id> -Text "<message>"'; exit 2 }
    Send-BoardMsg $Agent $To $Text
    $held = @(Active | Where-Object { $_.agent -eq $To }); "sent to $To$(if (-not $held) { ' (not on the board now: it reads it when it joins)' })"
  }
  'inbox' {
    if (-not $Agent) { 'usage: board inbox -Agent <me> [-All]'; exit 2 }
    $f = Get-InboxFile $Agent; if (-not (Test-Path $f)) { 'inbox: empty'; return }
    Invoke-KitLocked $f {
      $m = @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json })
      $show = @($m | Where-Object { $All -or -not $_.read }); foreach ($x in $show) { "$(([datetime]$x.at).ToString('HH:mm')) from $($x.from): $($x.text)" }
      if (-not $show.Count) { 'inbox: nothing unread' }
      Write-KitAtomic $f ((@($m | ForEach-Object { $_.read = $true; $_ | ConvertTo-Json -Compress }) -join "`n") + "`n")
    }
  }
}
}

# ---- budget: this agent's budget (the tool's default compaction point), a plan's run cap, a run's spend
function Get-KitPlanCap([string]$Plan, [string]$Tool = '') {   # 'role/model:n,...' (role without /model: an estimate unit, no budget)
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).budget; $cap = 0; $est = 0; $memo = @{}
  foreach ($p in @("$Plan" -split ',' | Where-Object { $_ -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$' })) {
    $null = $p -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$'; $role = $Matches[1]; $m = $Matches[2]; $n = [int]$Matches[3]; $hasM = $p -match '/'
    if ($hasM) { if (-not $memo.ContainsKey($m)) { $memo[$m] = (Get-KitBudget -Tool $Tool -Model $m).budget }; $cap += $n * $memo[$m] }
    $est += $n * [double](Get-KitSetting "budget.estimate.$role" $ex.estimate.$role)
  }
  [pscustomobject]@{ cap = [int]$cap; estimate = [int]$est; perModel = $memo }
}
function Invoke-Budget {
param([string]$Tool = '', [string]$Model = '', [int]$Window = 0, [string]$Plan = '', [string]$Run = '', [switch]$Json)
if ($Run) {   # a workflow run: the sum of its agents' spend vs the cap its launch -Self recorded
  $sf = @(Read-KitJsonFiles (Get-KitPath launches -Create) 'self-*.json' | Where-Object run -eq $Run | Sort-Object { [datetime]$_.at } -Descending)[0]
  if (-not $sf) { "no launch record for run $Run"; exit 1 }
  $wf = if ($sf.wfDir -and (Test-Path $sf.wfDir)) { $sf.wfDir } else { $t = Find-KitTranscript "-Run '$Run' " 'agent-*.jsonl'; if ($t) { Split-Path $t } }
  $sp = @(if ($wf) { Get-ChildItem $wf -Filter 'agent-*.jsonl' | ForEach-Object { (Get-KitSpend $_.FullName).spend } })
  $o = [ordered]@{ run = $Run; spent = [int](($sp | Measure-Object -Sum).Sum); agents = $sp.Count; cap = [int]$sf.cap; estimate = [int]$sf.estimate; stopAt = [double]$sf.stopAt }
  Invoke-KitLocked $sf.file { $j = Get-Content $sf.file -Raw | ConvertFrom-Json; $j | Add-Member -Force NoteProperty wfDir $wf; $j | Add-Member -Force NoteProperty spent $o.spent; Write-KitAtomic $sf.file ($j | ConvertTo-Json -Depth 30) }
  if ($Json) { $o | ConvertTo-Json -Compress } else { "run $Run`: spent $($o.spent) of the cap $($o.cap) ($($o.agents) agents; stop at $([int]($o.stopAt * 100))%)" }; exit 0
}
$b = Get-KitBudget -Tool $Tool -Model $Model -Window $Window
if ($Plan) { $c = Get-KitPlanCap $Plan $Tool; $b | Add-Member -Force NoteProperty cap $c.cap; $b | Add-Member -Force NoteProperty estimate $c.estimate }
if ($Json) { $b | ConvertTo-Json -Compress; exit 0 }
"budget: $($b.tool) $(if ($b.model) { $b.model } else { '(default model)' }): $($b.budget) tokens, handoff at $($b.handoff) ($($b.row): $($b.source))"
if ($Plan) { "plan cap $($b.cap), estimate $($b.estimate): new items stop at $([int]($b.cap * $b.runStopAt))$(if ($b.estimate -gt $b.cap * $b.runStopAt) { ' - OVER: split the run (batch)' })" }
}

# ---- launch: records so a restarted session resumes its workflows
function Get-KitFnv([string]$s) { [uint64]$h = 2166136261; foreach ($c in $s.ToCharArray()) { $h = (($h -bxor [uint64][int]$c) * 16777619) % 4294967296 }; ([uint32]$h).ToString('x8') }
function Invoke-Launch {
param(
  [string]$RunId, [string]$Script, [string]$ArgsJson, [string]$ArgsFile, [string]$RunDir, [string]$Session,
  [switch]$Done, [switch]$List, [switch]$Brief, [int]$Hours = 24, [switch]$Self, [string]$Run, [string]$Fnv, [string]$Plan = ''
)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
$dir = Get-KitPath launches -Create
$RunId = "$RunId".Trim().Trim('''"')
$safe = { param($id) ($id -replace '[^\w.-]', '_') }

if ($Self) {
  if (-not ($Script -and $Run -and $ArgsFile)) { 'usage: launch -Self -Script <wf>.js -Run <run> -ArgsFile <file> -Fnv <hash> [-RunDir <dir>] [-Plan ''role/model:n,..'']'; exit 2 }
  $raw = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ArgsFile).Path)).TrimStart([char]0xFEFF).TrimEnd("`r", "`n")
  $got = Get-KitFnv $raw
  if ($Fnv -and $got -ne $Fnv.Trim().ToLower()) { "MISMATCH: the file hashes to $got, not $Fnv ($($raw.Length) chars): write the args again, byte for byte"; exit 1 }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { "MISMATCH: not valid JSON ($($_.Exception.Message))"; exit 1 }
  $leaf = Split-Path $Script -Leaf
  $rec = [ordered]@{ script = (Join-Path $kit "workflows/$leaf"); run = $Run; args = $a; argsRaw = $raw; runDir = $(if ($RunDir) { $RunDir } else { $a.runDir }); fnv = $got; at = (Get-Date).ToString('o') } + (Get-KitHolder)
  $bud = if ($Plan) { $c = Get-KitPlanCap $Plan; $b0 = Get-KitBudget; [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; handoffAt = $b0.handoffAt; plan = $Plan }; $rec += [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; plan = $Plan } }
  Write-KitAtomic (Get-SelfLaunchFile $leaf $Run $got) ($rec | ConvertTo-Json -Depth 30)
  "RECORDED $leaf $Run (fnv $got)"; if ($bud) { "BUDGET $($bud | ConvertTo-Json -Compress)" }; exit 0
}

if ($Done) {
  if (-not $RunId -and -not $Run) { 'usage: launch -Done -RunId <id> | -Run <run> (a self record: the workflow wrote it)'; exit 2 }
  $files = @(@(if ($RunId) { Join-Path $dir "$(& $safe $RunId).json" }) | Where-Object { Test-Path -LiteralPath $_ })
  if ($Run) { $files += @(Read-KitJsonFiles $dir 'self-*.json' | Where-Object run -eq $Run | ForEach-Object file) }
  if (-not $files.Count) { Write-Host "[launch] no record for $RunId$Run (nothing to mark)"; exit 0 }
  foreach ($x in $files) { Invoke-KitLocked $x { $r = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json -AsHashtable; $r.completed = (Get-Date).ToString('o'); Write-KitAtomic $x ($r | ConvertTo-Json -Depth 30) } }
  Write-Host "[launch] marked completed: $(@($files | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
  exit 0
}
if (-not $List) {
  if (-not $RunId -or -not $Script) { throw 'record a launch with -RunId <id> -Script <path> and -ArgsJson <json> or -ArgsFile <file>' }
  $raw = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw } elseif ($ArgsJson) { $ArgsJson } else { '{}' }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "the args are not valid JSON: $($_.Exception.Message)" }
  if (-not $RunDir -and $a -is [hashtable] -and $a.runDir) { $RunDir = [string]$a.runDir }
  $rec = [ordered]@{ runId = $RunId; script = $Script; args = $a; argsFile = $(if ($ArgsFile) { (Resolve-Path -LiteralPath $ArgsFile).Path } else { $null })
    runDir = $(if ($RunDir) { $RunDir } else { $null }); session = $(if ($Session) { $Session } else { $null }); at = (Get-Date).ToString('o'); completed = $null } + (Get-KitHolder)
  $f = Join-Path $dir "$(& $safe $RunId).json"
  Write-KitAtomic $f ($rec | ConvertTo-Json -Depth 30)
  Write-Host "[launch] recorded $RunId ($(Split-Path $Script -Leaf)) -> $f"
  exit 0
}

# one line per stopped run; the resume calls, briefs and finalize lines: orch.ps1 recover
$out = @(foreach ($s in Get-StoppedRuns -Hours $Hours) {
  if ($s.runId) { "$(if ($s.paused) { 'paused ' })$($s.leaf) $($s.runId) (resumeFromRunId $($s.runId), args $(if ($s.selfFile) { $s.selfFile } else { $s.file }))" }
  else { "$(if ($s.paused) { 'paused ' })$($s.leaf) run $($s.run): launched, run id never recorded (orch.ps1 recover finds it; finished: launch -Done -Run '$($s.run)')" }
})
foreach ($q in Get-OrphanQaItems -Hours ([math]::Max($Hours, 48))) { $out += "QA run $($q.run): $($q.codes.Count) item(s) tested, never published ($($q.codes -join ', ')): qa.ps1 finalize" }
$out | ForEach-Object { $_ }
if ($out.Count -and -not $Brief) { 'resume calls, resume briefs, finalize lines: orch.ps1 recover' }
exit 0
}

function Get-LaunchArgsJson($r) { if ($r.argsRaw) { return [string]$r.argsRaw }; if ($r.argsFile -and (Test-Path -LiteralPath $r.argsFile)) { return (Get-Content -LiteralPath $r.argsFile -Raw).Trim() }; $r.args | ConvertTo-Json -Depth 30 -Compress }
function Get-SelfLaunchFile([string]$Leaf, [string]$Run, [string]$Fnv = '') { Join-Path (Get-KitPath launches -Create) ("self-{0}-{1}{2}.json" -f (($Leaf -replace '\.js$', '') -replace '[^\w.-]', '_'), ($Run -replace '[^\w.-]', '_'), $(if ($Fnv) { "-$Fnv" } else { '' })) }
function Get-LaunchRunName($a) {
  if (-not $a) { return '' }
  if ($a.run) { return [string]$a.run }
  if ($a.brief) { $fnv = Get-KitFnv ([string]$a.brief); return "$([IO.Path]::GetFileName([string]$a.brief) -replace '\.md$', '')-$(if ($fnv.Length -ge 4) { $fnv.Substring(0, 4) } else { $fnv })" }
  if ($a.runDir) { return (Split-Path ([string]$a.runDir) -Leaf) }
  if ($a.select) { return "select-$(if ($a.name) { $a.name } elseif ($a.target) { $a.target } else { 'run' })" }
  ''
}
# self records alone have no runId
function Get-StoppedRuns([int]$Hours = 24, [switch]$All) {
  $dir = Get-KitPath launches -Create; $since = (Get-Date).AddHours(-$Hours)
  $selfs = @(Read-KitJsonFiles $dir 'self-*.json')
  $records = @(Read-KitJsonFiles $dir | Where-Object { (Split-Path $_.file -Leaf) -notlike 'self-*' -and $_.script } | Sort-Object { (Get-Item -LiteralPath $_.file).LastWriteTime })   # args dumps are no launches
  $used = @{}
  foreach ($r in $records | Where-Object { -not $_.completed }) {
    $at = try { [datetime]$r.at } catch { (Get-Item -LiteralPath $r.file).LastWriteTime }
    if ($at -lt $since -and -not $r.paused) { continue }   # a paused run waits for resume however long
    if (-not $All -and -not $r.paused -and (Test-KitHolder $r) -eq $true) { continue }
    $leaf = Split-Path ([string]$r.script) -Leaf; $run = Get-LaunchRunName $r.args
    $sf = @($selfs | Where-Object { $run -and (Split-Path ([string]$_.script) -Leaf) -eq $leaf -and $_.run -eq $run } | Sort-Object { [math]::Abs(([datetime]$_.at - $at).TotalMinutes) }) | Select-Object -First 1 -ExpandProperty file
    if (-not $sf) { $sf = @($selfs | Where-Object { (Split-Path ([string]$_.script) -Leaf) -eq $leaf -and [math]::Abs(([datetime]$_.at - $at).TotalMinutes) -le 30 }) | Select-Object -First 1 -ExpandProperty file }
    if ($sf) { $used[$sf] = $true; $so = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json; if ($so.completed) { continue }; $run = $so.run }   # an owner-stopped self record ends the launch too
    [pscustomobject]@{ runId = $r.runId; leaf = $leaf; script = $r.script; run = $run; at = $at; file = $r.file; selfFile = $sf; runDir = $r.runDir; record = $r; paused = $r.paused }
  }
  foreach ($s in $selfs | Where-Object { -not $used[$_.file] -and -not $_.completed -and ($_.paused -or [datetime]$_.at -ge $since) }) {
    if (-not $All -and -not $s.paused -and (Test-KitHolder $s) -eq $true) { continue }
    # only a completed record of THIS launch hides it
    if (@($records | Where-Object { $_.completed -and (Get-LaunchRunName $_.args) -eq $s.run -and [math]::Abs(([datetime]$_.at - [datetime]$s.at).TotalMinutes) -le 30 }).Count) { continue }
    [pscustomobject]@{ runId = $null; leaf = (Split-Path ([string]$s.script) -Leaf); script = $s.script; run = $s.run; at = [datetime]$s.at; file = $null; selfFile = $s.file; runDir = $(if ($s.runDir) { $s.runDir } else { $s.args.runDir }); record = $null; paused = $s.paused }
  }
}
# ---- recover: stopped runs; no network
function Invoke-Recover {
param([string]$RunId, [string[]]$Run = @(), [int]$Hours = 48)
$Run = @(Split-KitList $Run)
$runs = @(Get-StoppedRuns -Hours $Hours -All:([bool]($RunId -or $Run.Count)) | Where-Object { (-not $RunId -or $_.runId -eq $RunId) -and (-not $Run.Count -or $_.run -in $Run) })
if ($RunId -and -not $runs.Count) { "no launch record for $RunId within $Hours h (orch.ps1 launch -List)"; exit 0 }
$wfDirs = @(Get-KitWorkflowDirs | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) })
foreach ($s in $runs) {
  if (-not $s.runId) {
    $hit = $wfDirs | Where-Object { @(Get-ChildItem $_.FullName -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch "launch -Self -Script $($s.leaf) -Run '$($s.run)' " -Quiet }).Count } | Select-Object -First 1
    if ($hit) { $s.runId = $hit.Name }
  }
  $lr = Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json; $a = $lr.args
  $aj = Get-LaunchArgsJson $lr; if (-not $a.runDir -and $lr.runDir) { $a | Add-Member -Force NoteProperty runDir $lr.runDir }
  "== $($s.leaf) run $(if ($s.runId) { $s.runId } else { '<id unknown>' }) ($($s.run)), launched $($s.at.ToString('yyyy-MM-dd HH:mm'))"
  "  args: $(if ($s.selfFile) { "$($s.selfFile) (.args, written by the workflow: exact)" } else { "$($s.file) (.args, typed by the coordinator: a missing field breaks resumeFromRunId)" })"
  $board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.run -eq $s.run })
  foreach ($b in $board | Where-Object { $_.status -ne 'left' -or $_.paused -or $_.crashed } | Sort-Object agent) { "  board: $($b.agent) $(if ($b.paused) { 'paused' } elseif ($b.crashed) { 'crashed' } else { $b.status }), last beat $(([datetime]$b.beat).ToString('dd MMM HH:mm'))$(if ((Test-KitHolder $b) -eq $false) { ', session gone' }) | $($b.area)" }
  if (@($board | Where-Object status -eq 'left').Count) { "  board: $(@($board | Where-Object status -eq 'left').Count) entr(ies) left" }
  $wts = @(); $brief = @()
  $agents = if ($a.agents) { @($a.agents) } else { @($board | Group-Object agent | ForEach-Object { [pscustomobject]@{ id = $_.Name; items = $_.Group[0].items } }) }
  foreach ($ag in $agents) {
    $pre = "$($ag.id)".ToLower()
    foreach ($root in $KitConf.WorktreeRoots) {
      foreach ($w in @(Get-ChildItem $root -Directory -Filter "$pre-*" -ErrorAction SilentlyContinue)) {
        $br = "$(git -C $w.FullName branch --show-current 2>$null)".Trim(); if (-not $br) { continue }
        $gd = "$(git -C $w.FullName rev-parse --absolute-git-dir 2>$null)".Trim(); $tg = if ($gd -and (Test-Path "$gd/claude-target")) { "$(Get-Content "$gd/claude-target")".Trim() } else { '' }
        $dirty = @(git -C $w.FullName status --porcelain 2>$null).Count
        $ahead = if ($tg) { "$(git -C $w.FullName rev-list --count "origin/$tg..HEAD" 2>$null)".Trim() } else { '?' }
        $last = "$(git -C $w.FullName log -1 --format='%h %cr %s' 2>$null)".Trim()
        $line = "$($ag.id) $($w.FullName): branch $br (target $(if ($tg) { $tg } else { '?' })), $ahead commit(s) not on the target, $dirty uncommitted file(s); last: $last"
        $wts += "  worktree: $line"; $brief += "- $line"
      }
    }
    if (-not @($wts | Where-Object { $_ -like "*worktree: $($ag.id) *" }).Count) { $brief += "- $($ag.id) (items $($ag.items)): no worktree found: not started, or removed" }
    $ck = Get-KitCheckpoint $ag.id
    if ($ck -and -not $ck.done -and (-not $ck.run -or $ck.run -eq $s.run)) { $l = "$($ag.id) checkpoint: next $($ck.next); done: $(@($ck.steps | ForEach-Object { "$($_.step) $($_.evidence)".Trim() }) -join '; ')"; $wts += "  $l"; $brief += "- $l (start there; dev.ps1 checkpoint -Agent $($ag.id) -Read)" }
  }
  $wts
  if ($s.runId) {
    $wv = Join-Path (Get-KitPath waves) "$($s.runId).json"
    if (Test-Path $wv) { foreach ($x in @((Get-Content $wv -Raw | ConvertFrom-Json).agents)) { foreach ($m in @($x.report.mrs)) { "  MR: $($x.id) $($m.url) $(if ($m.mergeState) { $m.mergeState } elseif ($m.merged) { 'MERGED' } else { 'OPEN' })"; $brief += "- $($x.id) MR $($m.url) $($m.mergeState)" } } }
  }
  foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ -and $_.run -eq $s.run })) { "  decision pending: $($d.id) $($d.agent) item $($d.item): $($d.question)" }
  if ($s.leaf -eq 'testy.js' -and $a.runDir) { "  QA run folder: $($a.runDir) (unpublished items: below)" }
  if ($s.leaf -eq 'buildy.js' -and $agents.Count) {
    $rf = Join-Path (Get-KitPath launches -Create) "$(ConvertTo-KitSlug $(if ($s.runId) { $s.runId } else { $s.run })).resume.md"
    $txt = @("# Resume brief: $($s.run) ($($s.leaf) $($s.runId))", "Original brief: $($a.brief) (it wins where this differs). Mode: resume.",
      'A stopped agent''s work is below. Join the board with its id + -Resume (TAKEOVER, not DUPLICATE). Before editing: dev.ps1 wt status',
      '-Dir <wt> per worktree, the task + comments, open/merged MRs of the branch. Continue where it stopped (testing goals, local test',
      'loop, MRs); never redo finished work. Files changing under you = another writer: stop, report.', '', '## State at recovery') + $brief
    Write-KitAtomic $rf (($txt -join "`n") + "`n")
    "  resume brief: $rf"
  }
  if ($s.runId) { "  RESUME: Workflow({ scriptPath: '$($s.script -replace '\\', '/')', resumeFromRunId: '$($s.runId)', args: $aj })" }
  if ($s.leaf -eq 'buildy.js') { "  RELAUNCH (resume refused): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: { ...the same args, brief: '<resume brief above>', mode: 'resume' } })" }
  elseif ($a.runDir) { "  RELAUNCH (resume refused): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: { runDir: '$($a.runDir)', kitDir: '$($KitConf.Kit -replace '\\', '/')' } }) (item claims skip published items)" }
  "  then: orch.ps1 launch -RunId <new id> ... ; the old one: orch.ps1 launch -Done -RunId $(if ($s.runId) { $s.runId } else { '<id>' })"
}
if (-not $runs.Count) { 'no stopped workflow runs' }
foreach ($q in Get-OrphanQaItems -Hours $Hours) { "== QA $($q.run): tested, never published: $($q.codes -join ', ')$(if ($q.fails) { " (unverified FAIL in $($q.fails -join ', '): checky first)" })"; foreach ($c in $q.codes) { "  & $($KitCmd.qa) finalize -RunDir '$($q.dir)' -Code $c" } }
Invoke-KitHooks Get-KitRecoverLines   # extra supervise-resources: env and phone leases with no live holder
foreach ($b in @(Get-KitHandoffs $Hours)) { "== HANDOFF $($b.agent) ($($b.run)): a fresh $(if ($b.type) { $b.type } else { 'agent' }) with the same -Agent and -Run continues from $($b.handoffBrief) (a workflow agent: its workflow starts it)" }
foreach ($l in @(Invoke-KitOutbox -DryRun)) { "== tracker outbox: $l (orch.ps1 supervise -AutoFix replays it)" }
"== heartbeat: a new session has none; arm ONE: CronCreate (cron */10 * * * *), prompt: ""Run & '$($KitCmd.orch -replace '\\', '/')' supervise -AutoFix -Brief, paste its output verbatim, one own line only when an ACT needs action (orchestrate E1)"""
}

# ---- pause: agents checkpoint, commit WIP, release leases, stop; a .state record lets resume start each at its next step
function Get-KitWtState([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return [pscustomobject]@{ dir = $Dir; gone = $true; dirty = @() } }
  [pscustomobject]@{ dir = $Dir; branch = "$(git -C $Dir branch --show-current 2>$null)".Trim(); head = "$(git -C $Dir rev-parse --short HEAD 2>$null)".Trim(); dirty = @(git -C $Dir status --porcelain 2>$null | ForEach-Object { "$_".Substring(3) }) }
}
function Set-KitLaunchField([string[]]$Files, [string]$Name, $Value) {   # $null removes it
  foreach ($x in @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) { Invoke-KitLocked $x { $j = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json; if ($null -eq $Value) { $j.PSObject.Properties.Remove($Name) } else { $j | Add-Member -Force NoteProperty $Name $Value }; Write-KitAtomic $x ($j | ConvertTo-Json -Depth 30) } }
}
function Invoke-Pause {
param([string]$Run = '', [switch]$All, [string]$Reason = 'owner pause', [double]$Wait = 10)
if (-not ($Run -or $All)) { 'usage: orch.ps1 pause -Run <run> | -All [-Reason "<why>"] [-Wait <min, default 10>]'; exit 2 }
$pf = Join-Path (Get-KitPath pauses -Create) "pause-$(Get-Date -Format yyyy-MM-dd-HHmmss).json"
$rec = [ordered]@{ at = (Get-Date).ToString('o'); reason = $Reason; run = $(if ($All) { '*' } else { $Run }); state = 'pausing'; agents = @(); runs = @() }
Write-KitAtomic $pf ($rec | ConvertTo-Json -Depth 30)   # from now every board beat prints PAUSE
$mine = { param($x) $All -or $x.run -eq $Run }
$live = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and (& $mine $_) -and (Test-KitHolder $_) -ne $false })
foreach ($b in $live) { Send-BoardMsg 'coordinator' $b.agent "PAUSE ($Reason): at your next step boundary: dev.ps1 checkpoint, dev.ps1 wt commit (WIP, no push), release your leases, board leave -Session $($b.session) -Status paused; return no result" }
"PAUSE sent to $($live.Count) agent(s)$(if ($live.Count) { " ($(@($live.agent) -join ', '))" }); waiting up to $Wait min for each to leave at a checkpoint"
$until = (Get-Date).AddMinutes($Wait)
while ($true) {
  $open = @($live | Where-Object { $e = try { Get-Content -LiteralPath $_.file -Raw | ConvertFrom-Json } catch { $null }; $e -and $e.status -ne 'left' -and (Test-KitHolder $e) -ne $false })
  if (-not $open.Count -or (Get-Date) -ge $until) { break }; Wait-KitPoll 15
}
$runs = @(Get-StoppedRuns -Hours 168 -All | Where-Object { & $mine $_ })
foreach ($s in $runs) {
  Set-KitLaunchField @($s.file, $s.selfFile) paused $pf
  $rec.runs += [ordered]@{ run = $s.run; leaf = $s.leaf; runId = $s.runId; file = $s.file; selfFile = $s.selfFile
    launch = $(if ($s.file) { Get-Content -LiteralPath $s.file -Raw | ConvertFrom-Json }); self = $(if ($s.selfFile) { Get-Content -LiteralPath $s.selfFile -Raw | ConvertFrom-Json }) }   # cleanup may remove launches/ meanwhile
}
foreach ($b in $live) {
  $ck = Get-KitCheckpoint $b.agent
  $dirs = @(@($ck.worktrees) + @($b.worktrees | Where-Object { "$_" -match '[\\/]' -and (Test-Path -LiteralPath "$_" -PathType Container) }) | Where-Object { $_ } | Select-Object -Unique)
  $rec.agents += [ordered]@{ agent = $b.agent; run = $b.run; session = $b.session; confirmed = $b.session -notin @($open.session); next = $ck.next; checkpoint = $ck; worktrees = @($dirs | ForEach-Object { Get-KitWtState $_ }) }
}
$hooks = @(Invoke-KitHooks Invoke-KitPause)   # extra local-env: services no live holder needs stop
$rec.state = 'paused'; Write-KitAtomic $pf ($rec | ConvertTo-Json -Depth 30)
"PAUSED $($live.Count - $open.Count) of $($live.Count) agent(s) at a checkpoint$(if ($open.Count) { "; not confirmed: $(@($open.agent) -join ', ') (their last checkpoint and worktree hold the state; resume treats them as crashed)" }); $($runs.Count) run(s) marked paused$(if ($runs.Count) { ": $(@($runs.run) -join ', ')" })"
$hooks
"record: $pf"
if ($open.Count) { "NOT safe yet: $(@($open.agent) -join ', ') still working; wait (orch.ps1 pause again) or power off anyway = a crash for them (resume starts them at their last checkpoint)" }
else { 'Safe to power off: nothing after this needs the network.' }
'Machine stays on: stop the workflow runs and the heartbeat (agents wait in board leave). Back: orch.ps1 resume -All (or -Run <run>)'
}

# ---- resume: paused and crashed runs; network first; done steps verified (sha, MR), never redone; merged runs skipped
function Test-KitOnline { if ($env:KIT_OFFLINE) { return $env:KIT_OFFLINE -eq '0' }; $c = [Net.Sockets.TcpClient]::new(); try { $c.ConnectAsync($KitConf.GitHost, 443).Wait(5000) -and $c.Connected } catch { $false } finally { $c.Dispose() } }
function Test-KitStepEvidence($st) {
  $e = "$($st.evidence)".Trim()
  $u = if ($e -match '^https?://') { ConvertFrom-MrUrl $e } elseif ($e -match '^(?<r>[\w./-]+)!(?<n>\d+)$') { @{ repo = (Get-HostProject $Matches.r -Raw); n = $Matches.n } }
  if ($u) { $h = try { Invoke-HostVerb 'mr.get' $u -NoMemo } catch { $null }; return [pscustomobject]@{ mr = $e; state = "$($h.state)"; text = "MR $(if ($h) { $h.state } else { 'UNKNOWN (host call failed): check it' })" } }
  $sha = if ($e -cmatch '^[0-9a-f]{7,40}$') { $e } else { $st.head }
  if ($st.dir -and $sha) { git -C $st.dir cat-file -e "$sha^{commit}" 2>$null; return [pscustomobject]@{ text = $(if ((Test-Path -LiteralPath $st.dir) -and -not $LASTEXITCODE) { "commit $sha present" } else { "commit $sha not found (rebased? check the branch; redo only what it lacks)" }) } }
  [pscustomobject]@{ text = $(if ($e -match '^https?://') { 'link recorded' } else { 'recorded' }) }
}
function Invoke-Resume {
param([string]$Run = '', [switch]$All, [double]$Wait = 0, [int]$Hours = 168)
if (-not ($Run -or $All)) { 'usage: orch.ps1 resume -Run <run> | -All [-Wait <min> for the network]'; exit 2 }
$until = (Get-Date).AddMinutes($Wait)
while (-not (Test-KitOnline)) {
  if ((Get-Date) -ge $until) { "OFFLINE: $($KitConf.GitHost):443 unreachable; resume needs the git host and the tracker. Connect, then run orch.ps1 resume again (-Wait <min> waits for the network)"; exit 1 }
  Wait-KitPoll 30
}
$pauses = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($All -or $_.run -in '*', $Run) })
foreach ($p in $pauses) { foreach ($r in @($p.runs)) { foreach ($pair in @(, @($r.file, $r.launch)) + @(, @($r.selfFile, $r.self))) {   # launch records a cleanup removed while paused
  if ($pair[0] -and $pair[1] -and -not (Test-Path -LiteralPath $pair[0])) { New-Item -ItemType Directory -Force (Split-Path $pair[0]) | Out-Null; Write-KitAtomic $pair[0] ($pair[1] | ConvertTo-Json -Depth 30) } } }
  foreach ($a in @($p.agents | Where-Object { $_.checkpoint })) { $cf = Get-KitCheckpointFile $a.agent; if (-not (Test-Path -LiteralPath $cf)) { New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null; Write-KitAtomic $cf ($a.checkpoint | ConvertTo-Json -Depth 6) } } }   # and checkpoints (cleanup: agents/ after 7 d)
$null = Set-KitBoardCrashed
$go = @()
foreach ($s in @(Get-StoppedRuns -Hours $Hours | Where-Object { $All -or $_.run -eq $Run })) {
  "== $($s.leaf) run $($s.run) ($(if ($s.paused) { 'paused' } else { 'crashed' }))"
  $board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object run -eq $s.run)
  $waiting = @($board | Where-Object { $_.paused -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 3 })   # board leave -Status paused beats every 1.5 min
  Set-KitLaunchField @($s.file, $s.selfFile) paused $null   # resumed, relaunched or skipped: no longer paused
  if ($waiting.Count) { "  still running: $(@($waiting.agent) -join ', ') wait in board leave; released, they rejoin and continue (no relaunch)"; continue }
  $lr = Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json
  $wf = @(Get-KitWorkflowDirs | Where-Object { $s.runId -and $_.Name -eq $s.runId })[0]
  $jl = @(if ($wf -and (Test-Path (Join-Path $wf.FullName 'journal.jsonl'))) { Get-Content (Join-Path $wf.FullName 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } })
  $res = @($jl | Where-Object type -eq 'result' | ForEach-Object agentId)
  $steps = @($jl | Where-Object type -eq 'started' | ForEach-Object { [pscustomobject]@{ who = ($_.label -split ':', 2)[-1] -replace '@.*$', ''; done = $_.agentId -in $res } })
  $mrs = @(); $noMr = 0   # agents: the launch args, the board and every checkpoint of the run (checky checkpoints under its <CODE>)
  $cks = @(Get-ChildItem (Get-KitPath agents) -Filter 'resume.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.run -eq $s.run } | ForEach-Object agent)
  $lines = @(foreach ($ag in @(@(@($lr.args.agents) | ForEach-Object { $_.id }) + @($board.agent) + $cks | Where-Object { $_ } | Select-Object -Unique)) {
    $mySteps = @($steps | Where-Object who -eq $ag)
    $ck = Get-KitCheckpoint $ag
    if (-not $ck -or $ck.done -or ($ck.run -and $ck.run -ne $s.run)) { "  $ag`: no open checkpoint$(if ($mySteps.Count -and -not @($mySteps | Where-Object { -not $_.done }).Count) { '; its steps have journal results: not relaunched (resumeFromRunId keeps them)' })"; continue }
    $b = @("# Resume brief $ag (run $($s.run))", "Start AT step: $($ck.next). The steps below are done and were verified now: never redo them.", '', '## Done (verified)')
    if (-not @($ck.steps | Where-Object step -eq 'mr').Count) { $noMr++ }
    foreach ($st in @($ck.steps)) { $v = Test-KitStepEvidence $st; if ($v.mr) { $mrs += $v }; $b += "- $($st.step)$(if ($st.item) { " [$($st.item)]" }): $($st.evidence) -> $($v.text)" }
    $b += @('', "## Interrupted step '$($ck.next)': rerun it from the kept diff (never discard it)") + @(foreach ($d in @($ck.worktrees)) { $w = Get-KitWtState $d; "- $d $(if ($w.gone) { 'GONE: recreate the worktree from its branch' } else { "branch $($w.branch) @ $($w.head); uncommitted, kept: $(if ($w.dirty.Count) { $w.dirty -join ', ' } else { 'none' })" })" })
    $b += @('', "## Open: leases to take again: $(@($ck.leases) -join ', '); decisions: $(@($ck.decisions) -join ', ')")
    $bf = Join-Path (Split-Path (Get-KitCheckpointFile $ag)) 'resume-brief.md'; Write-KitAtomic $bf (($b -join "`n") + "`n")
    "  $ag`: resume at '$($ck.next)' -> $bf"
  })
  $openMrs = @($mrs | Where-Object { $_.state -ne 'merged' })
  if ($mrs.Count -and -not $openMrs.Count -and -not $noMr) { "  SKIP: all $($mrs.Count) MR(s) merged; finished: orch.ps1 launch -Done $(if ($s.runId) { "-RunId $($s.runId)" } else { "-Run '$($s.run)'" })"; continue }
  $lines; $go += $s.run
}
# a pause of all runs resumed for one run: that run released, the others stay paused
foreach ($p in $pauses) { Invoke-KitLocked $p.file { $j = Get-Content -LiteralPath $p.file -Raw | ConvertFrom-Json; if ($All -or $j.run -ne '*') { $j.state = 'resumed'; $j | Add-Member -Force NoteProperty resumedAt (Get-Date).ToString('o') } else { $j | Add-Member -Force NoteProperty released @(@($j.released) + $Run | Where-Object { $_ } | Select-Object -Unique) }; Write-KitAtomic $p.file ($j | ConvertTo-Json -Depth 30) } }
if ($go.Count) { Invoke-Recover -Run $go -Hours $Hours } else { 'nothing to relaunch' }
}

# ---- program: the coordinator's own state per program (phases -> run, MRs, synced) in .state; a heartbeat reads it after a restart
function Invoke-Program {
param([Parameter(Position = 0)][ValidateSet('set', 'get', 'list')][string]$Action = 'list', [string]$Program, [string]$Key, [string]$Value, [switch]$Json)
$dir = Get-KitPath programs -Create
if ($Action -eq 'list') { Get-ChildItem $dir -Filter '*.json' | ForEach-Object BaseName; return }
if (-not $Program -or ($Action -eq 'set' -and -not $Key)) { 'usage: orch.ps1 program set -Program <name> -Key <k> -Value <text | JSON> | get -Program <name> [-Key <k>] [-Json] | list'; exit 2 }
$f = Join-Path $dir "$(ConvertTo-KitSlug $Program).json"
$read = { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
if ($Action -eq 'set') {
  $v = try { $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $Value }
  Invoke-KitLocked $f { $p = & $read; $p[$Key] = $v; $p._updated = (Get-Date).ToString('s'); Write-KitAtomic $f ($p | ConvertTo-Json -Depth 20) }
  "program $Program`: $Key set"; return
}
$p = & $read
if ($Key) { if (-not $p.ContainsKey($Key)) { "program $Program has no key $Key"; exit 1 }; $p = $p[$Key] }
if ($Json -or $p -isnot [string]) { ConvertTo-Json -InputObject $p -Depth 20 } else { $p }
}

# agents that handed off at their budget and no fresh agent took over yet
function Get-KitHandoffs([double]$Hours = 48) { @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.handoffBrief -and -not $_.continuedBy -and ((Get-Date) - [datetime]$_.beat).TotalHours -lt $Hours }) }
function Get-OrphanQaItems([int]$Hours = 48) {
  $live = @(Read-KitJsonFiles (Get-KitPath launches -Create) |
      Where-Object { -not $_.completed -and (Test-KitHolder $_) -ne $false } | ForEach-Object { [string]$(if ($_.runDir) { $_.runDir } else { $_.args.runDir }) } | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf })
  foreach ($d in Get-ChildItem -LiteralPath (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) -and $_.Name -notin $live }) {
    $codes = @(); $fails = @()
    foreach ($it in @(try { (Get-Content -LiteralPath (Join-Path $d.FullName 'run.json') -Raw -ErrorAction Stop | ConvertFrom-Json).items } catch { })) {
      $c = [string]$it.code; $id = Join-Path $d.FullName $c
      if (-not $c -or -not (Test-Path (Join-Path $id 'results.json')) -or (Test-Path (Join-Path $id 'finalize.json')) -or (Test-Path (Join-Path $id 'held.json'))) { continue }
      $codes += $c
      $res = try { Get-Content (Join-Path $id 'results.json') -Raw | ConvertFrom-Json } catch { $null }
      if (@($res.checks | Where-Object { $_.result -eq 'FAIL' -and -not $_.verify }).Count) { $fails += $c }
    }
    if ($codes.Count) { [pscustomobject]@{ run = $d.Name; dir = $d.FullName; codes = $codes; fails = $fails } }
  }
}

# task '0' broke every promote
function NormTask($id) {
  $id = "$id".Trim().Trim("'", '"').Trim()
  if ($KitConf.TrackerTag) { $id = $id -replace "^(?i)$([regex]::Escape($KitConf.TrackerTag))", '' }
  if ($id -match '^(0+|-+|none|null|undefined|n/?a|tbd|task|id)?$') { return '' }
  $id
}

# ---- track: task <-> MRs; promoted once all merge
# MR / PR URL -> <repo>!<iid>
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$repo" } else { $null } }
# search ignores in=source_branch
function Find-TaskMrs($task) {
  $tagged = "$($KitConf.TrackerTag)$task"
  @(foreach ($r in @($KitConf.TrackerRepos)) {
      $pp = ProjPath $r; if (-not $pp) { continue }
      $enc = $pp -replace '/', '%2F'
      @(@(Invoke-HostApi "projects/$enc/merge_requests?search=$([uri]::EscapeDataString($tagged))&in=title&state=all&per_page=50") +
        @(Invoke-HostApi "projects/$enc/merge_requests?state=opened&per_page=100" | Where-Object { "$($_.source_branch)" -match "(?i)$([regex]::Escape($tagged))(?![A-Za-z0-9])" })) |
        Where-Object { $_ -and $_.iid -and $_.state -ne 'closed' } | ForEach-Object { "$r!$($_.iid)" }
    }) | Select-Object -Unique
}
# repo@target of the tasks' MRs: a bug fix lands where the original ask shipped
function Get-TaskMrBranches([string[]]$Tasks) {
  foreach ($ref in @(@($Tasks | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Find-TaskMrs $_ }) | Select-Object -Unique)) {
    if ("$ref" -notmatch '^(?<r>[^!]+)!(?<i>\d+)$') { continue }
    $repo = $Matches.r; $iid = $Matches.i; $pp = ProjPath $repo; if (-not $pp) { continue }
    $m = Invoke-HostApi "projects/$($pp -replace '/', '%2F')/merge_requests/$iid"
    if ($m.target_branch) { [pscustomobject]@{ ref = $ref; repo = $repo; branch = [string]$m.target_branch } }
  }
}
function ConvertTo-MrRef([string]$m) { if ($u = ConvertFrom-MrUrl $m) { "$(($u.repo -split '/')[-1])!$($u.n)" } else { $m.Trim() } }
function Invoke-Track {
param([Parameter(Position = 0)][ValidateSet('add', 'run', 'rebuild')][string]$Action, [switch]$Rebuild, [switch]$Force, [string]$Task, [string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @(), [string]$Wave, [switch]$Detail, [string]$HoldPromotion)
$ErrorActionPreference = 'SilentlyContinue'
if ($Rebuild) { $Action = 'rebuild' }
# a throw is swallowed under SilentlyContinue
function Fail([string]$m) { [Console]::Error.WriteLine("track: $m"); exit 1 }
if (-not $Action) { Fail 'usage: orch.ps1 track add|run|rebuild ... (or -Rebuild)' }
$wavesDir = Get-KitPath waves
$script:holds = 0
function Hold($s) { if ($Quiet) { return }; if ($Detail) { $s } else { $script:holds++ } }
$script:gone = @{}   # deleted in the tracker: dropped from tracking
function TaskStatus($id) { try { [string](Get-TrackerTask $id).status } catch { if (Remove-KitGoneTask $id $_) { $script:gone[$id] = $true }; '' } }
$group = $KitConf.GitlabGroup
$groupRx = if ($group) { '(?:' + [regex]::Escape($group) + '/)?' } else { '' }
$alias = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $alias[$p.Name] = [string]$p.Value } }
function NormRef($r) {
  $r = "$r".Trim().Trim("'", '"')  # with the quotes
  if ($u = ConvertFrom-MrUrl $r) { $r = "$($u.repo -replace "^(?i)$groupRx", '')!$($u.n)" }
  if ($r -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$' -and $alias[$Matches.repo]) { $r = "$($alias[$Matches.repo])!$($Matches.iid)" }
  $r
}
function Load($t) { (Read-KitTracking).tasks[$t] }
function TaskOfMr($ref) {
  if (-not $KitConf.TrackerTag -or $ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return '' }
  $proj = ProjPath $Matches.repo; if (-not $proj) { return '' }
  $m = Invoke-HostApi "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)"
  foreach ($s in @($m.title, $m.source_branch)) { if ("$s" -match "(?i)$([regex]::Escape($KitConf.TrackerTag))(?<id>[A-Za-z0-9]+)") { return (NormTask $Matches.id) } }
  ''
}
# re-arming would break merge order
function ProducerOpen($proj, $iid) {
  foreach ($x in @((Read-KitTracking).tasks.Values)) {
    foreach ($pair in @($x.mergeAfter)) {
      $p = "$pair" -split '>', 2; if ($p.Count -ne 2) { continue }
      if ((NormRef $p[0]) -match '^(?<r>[\w./-]+)!(?<i>\d+)$' -and $Matches.i -eq $iid -and ($proj -ieq $Matches.r -or $proj -like "*/$($Matches.r)") -and (MrState (NormRef $p[1])) -ne 'merged') { return $true }
    }
  }
  $false
}
$script:doneFields = 'doneAt', 'liveOn', 'liveCheckedAt', 'qaCovered'
function Save($o, [switch]$Run) {
  # keep what another process wrote since load; -Run: track add owns holdPromotion / onMerged / wave
  Update-KitTracking {
    param($all)
    $cur = $all.tasks[$o.task]
    if ($cur) {
      # run vs add race
      $newMrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ -and @($cur.mrs) -notcontains $_ })
      if ($o.done -and -not $cur.done -and [string]$cur.reopenedAt -ne [string]$o.reopenedAt) { $o.done = $false; $o.reopenedAt = $cur.reopenedAt; foreach ($k in $script:doneFields) { $o.Remove($k) } }
      elseif ($cur.done -and -not $o.done -and [string]$cur.reopenedAt -eq [string]$o.reopenedAt -and -not $newMrs.Count) { $o.done = $true; $o.doneAt = $cur.doneAt }
    }
    if ($cur -and $Run) { foreach ($k in 'holdPromotion', 'onMerged', 'wave') { if ($cur.ContainsKey($k)) { $o[$k] = $cur[$k] } else { $o.Remove($k) } } }
    if ($cur) { foreach ($k in 'mrs', 'mergeAfter') { $o[$k] = @(@($o[$k]) + @($cur[$k]) | Where-Object { $_ } | Select-Object -Unique) }; if ($cur.discover) { $o.discover = $true } }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $o.mergeAfter = @(@($o.mergeAfter) | Where-Object { $_ } | ForEach-Object { $p = $_ -split '>', 2; if ($p.Count -eq 2) { "$(NormRef $p[0])>$(NormRef $p[1])" } else { $_ } } | Select-Object -Unique)
    $all.tasks[$o.task] = $o
  }
}
function InFlight($ref) {
  if ($ref -notmatch '^(?<r>[\w./-]+)!(?<i>\d+)$') { return $null }   # bare or owner/repo (no group)
  $pat = "/$([regex]::Escape(($Matches.r -split '/')[-1]))/$MrSegRx/$($Matches.i)(\D|$)"
  foreach ($f in Get-ChildItem $wavesDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-12) }) {
    $w = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if (-not @($w.running).Count) { continue }
    foreach ($p in $w.agents.PSObject.Properties) {
      if (@($p.Value.mrs | ForEach-Object { "$($_.url)$_" }) -match $pat) {
        $lbl = @($w.running) | Where-Object { $_ -match "^(build|review|fix|ship|ci):$([regex]::Escape($p.Name))$" } | Select-Object -First 1
        if ($lbl) {
          # stale once its workflow ends
          if ($f.LastWriteTime -lt (Get-Date).AddMinutes(-5)) {
            & $KitCmd.orch report -Run $w.run *> $null
            $w2 = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not (@($w2.running) -contains $lbl)) { continue }
          }
          return "$lbl ($($w.run))"
        }
      }
    }
  }
  $null
}
$script:mrMemo = @{}   # one host read per MR per run
function MrState($ref) { if (-not $script:mrMemo.ContainsKey($ref)) { $script:mrMemo[$ref] = MrState0 $ref }; $script:mrMemo[$ref] }
function MrState0($ref) {
  if ($ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return 'bad-ref' }
  $proj = ProjPath $Matches.repo
  if (-not $proj) { return 'bad-ref (use <group/repo>!<iid>, or set "gitlabGroup" in kit.local.json)' }
  $m = Invoke-HostApi "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)"
  if (-not $m) { return 'unknown' }
  if ($m.state -eq 'opened' -and $m.head_pipeline.status -in 'failed', 'canceled') { return "opened (pipeline $($m.head_pipeline.status))" }
  if ($m.state -eq 'opened' -and ($m.has_conflicts -or $m.detailed_merge_status -eq 'conflict')) { return 'opened (conflict)' }
  $m.state
}
switch ($Action) {
  'rebuild' { $rebuildFn = Assert-KitExtra Invoke-TrackRebuild 'track rebuild' 'track-rebuild'; & $rebuildFn }   # not $rebuild: that is the -Rebuild switch
  'add' {
    $given = $Task; $Task = NormTask $Task
    $refs = @(@($Mrs -split '\s*,\s*') | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    # placeholders, reused branches
    $titled = @($refs | ForEach-Object { TaskOfMr $_ } | Where-Object { $_ } | Select-Object -Unique)
    if ($titled.Count -eq 1 -and $titled[0] -ne $Task) { "NOTE: the MR title names task $($titled[0]) - registering under it$(if ($Task) { ", not $Task" })"; $Task = $titled[0] }
    elseif ($titled.Count -gt 1 -and (-not $Task -or $titled -notcontains $Task)) { Fail "add: the MRs name different tasks in their titles ($($titled -join ', ')): register each task with its own MRs" }
    if (-not $Task) { Fail "add needs a real -Task id (got '$given'; the tracker id without its tag, as in the MR title)" }
    $o = Load $Task; if (-not $o) { $o = @{ task = $Task; mrs = @(); onMerged = @($OnMerged -split '\s*,\s*'); done = $false; created = (Get-Date).ToString('s') } }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $before = @($o.mrs).Count
    if ($Discover -and @($KitConf.TrackerRepos).Count) { $refs = @(@($refs) + @(Find-TaskMrs $Task) | Select-Object -Unique) }
    $o.mrs = @(@($o.mrs) + $refs | Where-Object { $_ } | Select-Object -Unique)
    if ($PSBoundParameters.ContainsKey('OnMerged')) { $o.onMerged = @($OnMerged -split '\s*,\s*') }
    if ($Discover) { $o.discover = $true }
    if ($Wave) { $o.wave = $Wave }
    if ($PSBoundParameters.ContainsKey('HoldPromotion')) { if ($HoldPromotion) { $o.holdPromotion = $HoldPromotion } else { $o.Remove('holdPromotion') } }
    if ($MergeAfter) {
      $o.mergeAfter = @(@($o.mergeAfter) + @($MergeAfter -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique)
      # it would merge before its producer
      foreach ($pair in @($MergeAfter -split '\s*,\s*' | Where-Object { $_ })) {
        $p = $pair -split '>', 2; if ($p.Count -ne 2 -or (NormRef $p[0]) -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { continue }
        $pp = ProjPath $Matches.repo; $ci = $Matches.iid; if (-not $pp -or (MrState (NormRef $p[1])) -eq 'merged') { continue }
        $enc = $pp -replace '/', '%2F'; $m = Invoke-HostApi "projects/$enc/merge_requests/$ci"
        if ($m.merge_when_pipeline_succeeds) { $null = Invoke-HostApi "projects/$enc/merge_requests/$ci/cancel_merge_when_pipeline_succeeds" -Method POST; "NOTE: cancelled the scheduled merge of $(NormRef $p[0]): it merges after $(NormRef $p[1])" }
      }
    }
    if ($o.done -and @($o.mrs).Count -gt $before) { $o.done = $false; $o.reopenedAt = (Get-Date).ToString('o'); foreach ($k in $script:doneFields) { $o.Remove($k) } }
    elseif (-not $o.done) { $o.done = $false }
    Save $o; $s = Load $Task
    "tracking $Task : $(@($s.mrs) -join ', ')$(if (@($s.mergeAfter).Count) { ' | merge-after: ' + (@($s.mergeAfter) -join ', ') }) -> on all merged: $(@($s.onMerged) -join ' -> ')$(if ($s.holdPromotion) { " (promotion HELD: $($s.holdPromotion))" })$(if ($Discover -and -not @($s.mrs).Count) { ' (no MR found yet: every run looks again)' })"
  }
  'run' {
    # a later push cancels merge-when-green
    $am = (Read-KitTracking).automerge
    if ($am.Count) {
      $keep = @{}
      foreach ($ref in @($am.Keys)) {
        if ($ref -notmatch '^(?<proj>.+)!(?<iid>\d+)$') { continue }
        $amProj = $Matches.proj; $enc = $amProj -replace '/', '%2F'; $iid = $Matches.iid
        $m = Invoke-HostApi "projects/$enc/merge_requests/$iid"
        if (-not $m) { $keep[$ref] = $am[$ref]; continue }
        if ($m.state -ne 'opened') { continue }
        $keep[$ref] = $am[$ref]
        if ($m.merge_when_pipeline_succeeds -or $m.draft -or $m.has_conflicts -or $m.detailed_merge_status -eq 'conflict' -or $m.head_pipeline.status -in 'failed', 'canceled') { continue }
        # no head pipeline: GitLab would merge at once
        if (-not $m.head_pipeline) { continue }
        if ((ProducerOpen $amProj $iid) -or (InFlight "$(($amProj -split '/')[-1])!$iid")) { continue }
        $fl = @{}   # merge method + branch delete: repos[] mergeMethod / deleteBranch
        if ($m.head_pipeline.status -ne 'success') { $fl.merge_when_pipeline_succeeds = 'true' }
        $r = Invoke-HostApi "projects/$enc/merge_requests/$iid/merge" -Method PUT -Fields $fl
        "re-armed merge-when-green for $ref (it was dropped, probably by a push after scheduling): $(if ($r.state -eq 'merged') { 'merged' } elseif ($r.merge_when_pipeline_succeeds) { 'scheduled' } else { 'FAILED - check the MR' })"
      }
      # devtools.py may add meanwhile
      $gone = @($am.Keys | Where-Object { -not $keep.ContainsKey($_) })
      if ($gone) { Update-KitTracking { param($t) foreach ($r in $gone) { $t.automerge.Remove($r) } } }
    }
    # least recently checked first: a run cut by a timeout never starves the same tasks
    foreach ($id in @((Read-KitTracking).tasks.Values | Where-Object { -not $_.done } | Sort-Object { [string]$_.checkedAt } | ForEach-Object task)) {
      $o = Load $id; if (-not $o -or $o.done) { continue }   # fresh: a hold added meanwhile counts
      $o.checkedAt = (Get-Date).ToString('s'); Save $o -Run
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      foreach ($pair in @($o.mergeAfter)) {
        if ($pair -notmatch '^(?<dep>[^>]+)>(?<on>.+)$') { continue }
        $dep = $Matches.dep.Trim(); $on = $Matches.on.Trim()
        # the ship step merges it
        $owner = InFlight $dep
        if ($owner) { Hold "HOLD $($o.task): $dep waits for its review ($owner still running)"; continue }
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w./-]+)!(?<iid>\d+)$') {
          $rn = ($Matches.repo -split '/')[-1]; $wt = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ($_.name -eq $rn -or @($_.aliases) -contains $rn) } | ForEach-Object checkout | Select-Object -First 1
          if (-not $wt) { $wt = Join-Path $KitConf.ReposRoot $rn }
          $res = if (-not (Test-Path $wt)) { "no checkout at $wt - set repos[].checkout in kit.local.json" } else { python $KitCmd.devtools merge $wt $Matches.iid 2>&1 }
          if (-not $Quiet) { "MERGE-AFTER $($o.task): $on merged -> $dep : $res" }
        }
        if ($o.mrs -notcontains $dep) { $o.mrs = @(@($o.mrs) + $dep) }
      }
      if ($o.holdPromotion) { Hold "HOLD $($o.task): promotion held ($($o.holdPromotion)); release: orch.ps1 track add -Task $($o.task) -HoldPromotion ''"; continue }
      if ($o.discover) {
        if (-not @($KitConf.TrackerRepos).Count -and -not @($o.mrs).Count) { if (-not $Quiet) { "CONFIG $($o.task): -Discover needs ""trackerRepos"" in kit.local.json (or register MRs: orch.ps1 track add -Task $($o.task) -Mrs <repo>!<iid>)" } }
        # the MR search is the slow part: again only every 30 min once MRs are known
        if (-not @($o.mrs).Count -or -not $o.discoveredAt -or ((Get-Date) - [datetime]$o.discoveredAt).TotalMinutes -ge 30) { $o.mrs = @(@($o.mrs) + @(Find-TaskMrs $o.task) | Where-Object { $_ } | Select-Object -Unique); $o.discoveredAt = (Get-Date).ToString('s'); Save $o -Run }
        if (-not @($o.mrs).Count) { continue }
        $cur = TaskStatus $o.task
        if ($script:gone[$o.task]) { "DROPPED $($o.task): deleted in the tracker, no longer tracked"; continue }
        if (-not (Test-TrackerStatus $cur 'review')) {
          $allMerged = -not @(@($o.mrs) | Where-Object { (MrState $_) -ne 'merged' }).Count
          if (-not $allMerged) { $o.Remove('allMergedAt'); Save $o -Run; continue }
          if (-not $o.allMergedAt) { $o.allMergedAt = (Get-Date).ToString('s'); Save $o -Run; continue }
          if (((Get-Date) - [datetime]$o.allMergedAt).TotalMinutes -lt 20) { continue }
          if (-not $Quiet) { "NOTE $($o.task): status '$cur' was never set to review, but all MRs merged 20+ min ago - completing it" }
        }
      }
      # no MR yet = nothing merged: never promote it
      if (-not @($o.mrs).Count) { Hold "HOLD $($o.task): no MR registered yet (orch.ps1 track add -Task $($o.task) -Mrs <repo>!<iid>)"; continue }
      $states = @{}; foreach ($m in $o.mrs) { $states[$m] = MrState $m }
      $failed = @($states.GetEnumerator() | Where-Object { $_.Value -match 'pipeline (failed|canceled)|closed|conflict' })
      if ($failed) { if (-not $Quiet) { "ATTENTION $($o.task): $(($failed | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')" }; continue }
      if (@($states.Values | Where-Object { $_ -ne 'merged' }).Count) { continue }
      $held = @(Get-ChildItem $wavesDir -Filter '*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) } | ForEach-Object {
          $w = Get-Content $_.FullName -Raw | ConvertFrom-Json
          if (@($w.running).Count) { & $KitCmd.orch report -Run $w.run *> $null; $w = Get-Content $_.FullName -Raw | ConvertFrom-Json }
          if (@($w.running).Count) { @($w.openFindings) | Where-Object { $_.severity -eq 'blocking' -and (ConvertTo-MrRef $_.mr) -in @($o.mrs | ForEach-Object { ($_ -split '/')[-1] }) } } })
      if ($held) { Hold "HOLD $($o.task): blocking review finding still being fixed ($($held[0].mr))"; continue }
      # a follow-up MR may come
      if ($o.wave) {
        $wf = Join-Path $wavesDir "$($o.wave).json"; & $KitCmd.orch report -Run $o.wave *> $null
        if (-not (Test-Path $wf)) { if (-not $Quiet) { "CONFIG $($o.task): wave $($o.wave) has no journal/report (wrong or expired run id) - not holding for it" } }
        elseif (@((Get-Content $wf -Raw | ConvertFrom-Json).running).Count) { Hold "HOLD $($o.task): wave $($o.wave) is still fixing it"; continue }
      }
      $busy = @($o.mrs | ForEach-Object { InFlight $_ } | Where-Object { $_ } | Select-Object -Unique)
      if ($busy) { Hold "HOLD $($o.task): MRs merged but $($busy -join ', ') still in review/fix"; continue }
      # never backwards (QA may have closed it)
      $now = TaskStatus $o.task
      if ($script:gone[$o.task]) { "DROPPED $($o.task): deleted in the tracker, no longer tracked"; continue }
      if (Test-TrackerStatus $now 'closed', 'inTest') { $o.done = $true; Save $o -Run; if (-not $Quiet) { "DONE $($o.task): all MRs merged; status '$now' kept (already past promoted)" }; continue }
      $todo = @($o.onMerged)
      for ($q = $todo.Count - 1; $q -ge 0; $q--) { if (Test-TrackerStatus $now $todo[$q]) { $todo = @($todo | Select-Object -Skip ($q + 1)); break } }
      $setFailed = $false
      foreach ($s in $todo) { try { $null = Set-TrackerStatus $o.task $s } catch { $setFailed = $true; if (-not $Quiet) { "ATTENTION $($o.task): could not set status '$s' (retried next run): $_" }; break } }
      if ($setFailed) { continue }
      $urls = @($o.mrs | ForEach-Object { if ($_ -match '^(?<r>[\w./-]+)!(?<i>\d+)$' -and ($pp = ProjPath $Matches.r)) { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $Matches.i } } })
      # a run killed before Save would post again
      $allC = @(try { Get-TrackerComments $o.task } catch {}) | ForEach-Object { [string]$_.text }
      if (-not $o.mergedCommentAt -and -not @($allC | Where-Object { $_ -match '^All MRs merged' }).Count) {
        $o.mergedCommentAt = (Get-Date).ToString('s'); Save $o -Run
        try { $null = Add-TrackerComment $o.task "All MRs merged: $($urls -join ' , '). Status set to $($o.onMerged[-1]) automatically by the coordinator's tracker." } catch {}
      }
      $cmts = @($allC | Where-Object { $_ -notmatch '^All MRs merged' })
      if (-not ($cmts | Where-Object { $_ -match [string](Get-KitSetting 'locale.testCommentPattern' '(?i)how to test|test(ing)? (steps|guide|instructions)|tester guide|live check') })) {
        $steps = @(Get-KitWorkflowDirs | ForEach-Object { Get-Item (Join-Path $_.FullName 'journal.jsonl') -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) } | Sort-Object LastWriteTime -Descending | ForEach-Object {
            foreach ($line in Get-Content $_.FullName) {
              $j = try { $line | ConvertFrom-Json } catch { $null }
              $mine = (@($j.result.done) -match [regex]::Escape($o.task)) -or @(@($j.result.mrs) | Where-Object { $o.mrs -contains (NormRef $_.url) }).Count
              if ($j.type -eq 'result' -and $mine -and @($j.result.needsLiveCheck).Count) { @($j.result.needsLiveCheck) }
            } } | Where-Object { $_ } | Select-Object -Unique)
        if ($steps.Count) {
          try { $null = Add-TrackerComment $o.task ("How to test (from the dev agent's report; run after the next deploy of $($urls -join ' , ')):`n" + (($steps | ForEach-Object { "- $_" }) -join "`n")) } catch {}
          "COMMENTED $($o.task): posted $($steps.Count) how-to-test step(s) from the agent's report (its own testing comment was missing)"
        } else {
          "ATTENTION $($o.task): merged, but no solution/testing comment from its agent - post the solution, MR links and how-to-test on the task"
        }
      }
      $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); Save $o -Run
      "DONE $($o.task): all $(@($o.mrs).Count) MRs merged -> status $($o.onMerged -join ' -> ')"
      $script:merged = $true
    }
    if ($script:holds) { "HOLD: $($script:holds) task(s) waiting for their review/fix round (-Detail lists them)" }
    if ($script:merged) {
      Start-Detached (Resolve-Tool pwsh) @('-NoProfile', '-NonInteractive', '-File', $(if ($KitIsWindows) { "`"$($KitCmd.orch)`"" } else { $KitCmd.orch }), 'cleanup', '-WorktreesOnly', '-WorktreeIdleHours', '0', '-Quiet')   # Windows: quoted (spaces)
    }
  }
}
}

# ---- supervise report: -Brief = the owner's round report as final markdown (no LLM step); pure on $d, so fixtures test it
# label prefix of a workflow agent() -> crew type
function Get-KitLabelType([string]$Label) {
  $p = ($Label -split ':')[0]
  if ($p -match '^(build|fix|local|local-strong|resume|envfix-resume|duel|debate|ship|track|ci|record-args|deploy-batch|duel-ask|duel-close|decide)') { 'devy' }
  elseif ($p -match '^(review|duel-compare|duel-moderate)') { 'revy' }
  elseif ($p -match '^(test|retest|verify|audit|close|hold|prepare|load-run|envfix|release|add-followups)') { 'checky' }
  elseif ($p -match '^(learn|cleanup|analyse|apply|stamp)') { 'kitty' } else { 'other' }
}
function Format-KitReport($d, [switch]$Agents) {   # -Agents: the coordinator's agent table first
  $g1 = { param($x) [math]::Round([double]$x, 1) }
  $reportLines = [Collections.Generic.List[string]]::new()
  # 1. agents: one row per crew type; tokens = spend added since the last report
  if ($Agents) {
    $reportLines.Add('| Agent | Doing |'); $reportLines.Add('|---|---|')
    $all = @($d.agents)
    foreach ($t in @('devy', 'revy', 'checky', 'kitty', 'other')) {
      $as = @($all | Where-Object { $_.type -eq $t }); if (-not $as.Count) { continue }
      $doing = (@($as | Group-Object mode | ForEach-Object { "$(if (@($_.Group | Where-Object wait).Count -eq $_.Count) { 'waiting: ' })$($_.Name) $($_.Count) ($((@($_.Group | ForEach-Object name) -join ', ')))" }) -join ' · ')
      $added = @($as | Where-Object { $null -ne $_.spend } | ForEach-Object { [math]::Max(0, [double]$_.spend - [double]$_.prevSpend) })
      $reportLines.Add("| $($as.Count) × $t$(if ($added.Count) { " (+$([int](($added | Measure-Object -Average).Average / 1000))kT)" }) | $doing |")
    }
    if (-not $all.Count) { $reportLines.Add('| — | nothing running |') }
    $reportLines.Add('')
  }
  # 2. RAM in one line, then what the kit holds
  $m = $d.mem
  $reportLines.Add("**RAM** $(& $g1 ($m.TotalGB - $m.AvailGB)) / $(& $g1 $m.TotalGB) GB used, $(& $g1 $m.AvailGB) GB free$(if ($m.AvailGB -lt $d.keepFree) { " (below the floor $($d.keepFree) GB)" })")
  $rs = @($d.resources | Sort-Object { -[double]$_.gb })
  if ($rs.Count -gt 10) { $rs = @($rs | Select-Object -First 9) + [pscustomobject]@{ name = "…$($rs.Count - 9) more"; by = '—'; gb = (@($rs | Select-Object -Skip 9 | ForEach-Object { [double]$_.gb }) | Measure-Object -Sum).Sum } }
  if ($rs.Count) {
    $reportLines.Add(''); $reportLines.Add('| Resource | Used by | RAM |'); $reportLines.Add('|---|---|---|')
    foreach ($r in $rs) { $reportLines.Add("| $($r.name) | $(if ($r.by) { $r.by } else { '—' }) | $(if ($r.gb) { & $g1 $r.gb } else { '—' }) |") }
  }
  # 3. flags: ACT, WATCH, then what waits for the owner as info (deploy-ready envs)
  $fl = @(@($d.flags | Where-Object { $_.level -ne 'INFO' } | Sort-Object { @{ ACT = 0; WATCH = 1 }[$_.level] }) + @($d.info | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }))
  $reportLines.Add(''); $reportLines.Add("**Flags**$(if (-not $fl.Count) { ': none' })")
  foreach ($f in $fl | Select-Object -First 8) { $reportLines.Add("- **$($f.level)** $($f.what)$(if ($f.action) { " -> $($f.action)" })") }
  if ($fl.Count -gt 8) { $reportLines.Add("- …$($fl.Count - 8) more: $($d.detailFile)") }
  @($reportLines)
}
# ---- anomalies: pure ($c this round, $p last round's state.anom) -> WATCH flags + next state
function Get-KitAnomalies($c, $p) {
  $f = [Collections.Generic.List[object]]::new(); $AddF = { param($w, $a) $f.Add([pscustomobject]@{ level = 'WATCH'; what = $w; action = $a }) }; if (-not $p) { $p = @{} }
  if ($null -ne $p.outbox -and $c.outbox -gt [int]$p.outbox) { & $AddF "SILENT FAILURE: tracker outbox grew to $($c.outbox) write(s)" 'evidence .state/outbox.jsonl: tracker auth / network' }
  if ($null -ne $p.toolErrors -and $c.toolErrors -gt [int]$p.toolErrors) { & $AddF "SILENT FAILURE: $($c.toolErrors - [int]$p.toolErrors) new agent result error(s)" "evidence $($c.errorRun) journal" }
  [pscustomobject]@{ flags = @($f); state = @{ outbox = $c.outbox; toolErrors = $c.toolErrors } }
}
# agents of a journal still running: no result, no later finished start of the same item (a 529-dead agent writes no result),
# no later restart of the same label
function Get-JournalRunning($Started, $DoneIds) {
  $itemOf = { param($label) (([string]$label -split ':', 2)[-1] -split '@')[0] }
  $lastDone = @{}; $lastStart = @{}
  for ($i = 0; $i -lt $Started.Count; $i++) {
    if ($Started[$i].agentId -in $DoneIds) { $lastDone[(& $itemOf $Started[$i].label)] = $i }
    $lastStart[[string]$Started[$i].label] = $i
  }
  @(for ($i = 0; $i -lt $Started.Count; $i++) { $s = $Started[$i]; if ($s.agentId -notin $DoneIds -and -not ($lastDone[(& $itemOf $s.label)] -gt $i) -and $lastStart[[string]$s.label] -eq $i) { $s } })
}
# a run silent 2+ days with unfinished agents died with its session or was stopped: one WATCH ($Quiet remembers it), then skipped
function Get-KitSilentRun([string]$Name, [double]$SilentHours, $Quiet, [datetime]$Now) {
  if ($SilentHours -lt 48) { $Quiet.Remove($Name); return [pscustomobject]@{ skip = $false; flag = $null } }   # alive again: a later silence flags anew
  $flag = $null
  if (-not $Quiet.ContainsKey($Name)) {
    $Quiet[$Name] = $Now.ToString('s')
    $flag = [pscustomobject]@{ level = 'WATCH'; what = "run $Name silent $([int]($SilentHours / 24)) days with unfinished agents"; action = "Resume it (orch.ps1 recover -RunId $Name) or let it go: this flag does not repeat" }
  }
  [pscustomobject]@{ skip = $true; flag = $flag }
}
function Get-KitFinishedRuns { @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { $_.completed -and $_.runId } | ForEach-Object runId) }
# ---- supervise: coordinator heartbeat (FLAGS ACT / WATCH / INFO)
# who holds the supervise lock: the heartbeat's session, never this pwsh (a new pid each round would step aside from itself)
function Get-SuperviseOwner([string]$Session) {
  if ($Session) { return $Session }
  if ($env:CLAUDE_CODE_SESSION_ID) { return $env:CLAUDE_CODE_SESSION_ID }
  $h = Get-KitHolder; if ($h.holderPid) { "holder$($h.holderPid)" } else { "pid$PID" }
}
function Invoke-Supervise {
param([string]$Session, [switch]$Json, [switch]$AutoFix, [switch]$Brief, [switch]$Takeover, [switch]$Agents)
$ErrorActionPreference = 'SilentlyContinue'
$idleMin = 25
$wfAgents = New-Object System.Collections.ArrayList; $runTotal = 0; $toolErr = 0; $errRun = ''; $now = Get-Date; $t0 = $now
$liveLabels = New-Object System.Collections.ArrayList; $runningLabels = New-Object System.Collections.ArrayList; $doneLabels = New-Object System.Collections.ArrayList
$flags = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
# a timed-out sweep still shows them
function Flag($lvl, $what, $action) { [void]$flags.Add([pscustomobject]@{ level = $lvl; what = $what; action = $action }) }
function L($s) { [void]$lines.Add($s) }
$lk = Join-Path (Get-KitPath cache -Create) 'supervise.lock'
$me = Get-SuperviseOwner $Session
$script:aside = $null
Invoke-KitLocked $lk {
  $held = if (Test-Path $lk) { try { Get-Content $lk -Raw | ConvertFrom-Json } catch { $null } }
  if (-not $Takeover -and $held -and $held.session -ne $me -and ((Get-Date) - [datetime]$held.at).TotalMinutes -lt 30) { $script:aside = "another session's supervisor ran $([int]((Get-Date) - [datetime]$held.at).TotalMinutes) min ago (session $($held.session)): this heartbeat steps aside (stop it, or -Takeover)"; return }
  Write-KitAtomic $lk (@{ session = $me; at = (Get-Date).ToString('s'); pid = $PID } | ConvertTo-Json)
}
if ($script:aside) { $script:aside; return }
$budgetSeconds = if ($Brief) { [int](Get-KitSetting 'supervise.briefSeconds' 25) } else { 240 }
$script:skipped = @(); $deadline = (Get-Date).AddSeconds($budgetSeconds)
function Within($name) { if ((Get-Date) -lt $deadline) { $true } else { if ($name -notin $script:skipped) { $script:skipped += $name }; $false } }
$env:KIT_NET_TIMEOUT_SEC = [string][math]::Min(20, (Get-KitNetTimeout)); $env:KIT_NET_TRIES = '2'
function Left { [math]::Max(5, [int]($deadline - (Get-Date)).TotalSeconds) }
function Invoke-Bounded([string]$Script, [string[]]$A) { $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $Script) + $A) (Left); if ($r.timedOut) { $script:skipped += "$(Split-Path $Script -Leaf) $($A[0]) (timed out)" }; @($r.out -split "`r?`n" | Where-Object { $_ }) }
$stateFile = Get-KitPath supervise-state -Create
$state = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $state) { $state = @{} }
if (-not $state.quietRuns) { $state.quietRuns = @{} }

# 1. workflows: running agents from each journal
$wfDirs = Get-KitWorkflowDirs $Session | Sort-Object LastWriteTime -Descending | Select-Object -First 6
$finishedRuns = Get-KitFinishedRuns
if (-not $Session) { foreach ($k in @($state.quietRuns.Keys)) { if ($k -notin @($wfDirs | ForEach-Object Name)) { $state.quietRuns.Remove($k) } } }   # out of view: forget it (-Session sees only its own runs)
foreach ($w in $wfDirs) {
  $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j) -or $w.Name -in $finishedRuns) { continue }
  $ev = @(Get-Content $j | ForEach-Object { $_ | ConvertFrom-Json })
  $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($r in $ev | Where-Object type -eq 'result') { $res[$r.agentId] = $r }
  $done = [bool]($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' })
  $silentH = ($now - (Get-Item $j).LastWriteTime).TotalHours
  if ($done -and $silentH -gt 2) { continue }
  if (-not $done) { $sr = Get-KitSilentRun $w.Name $silentH $state.quietRuns $now; if ($sr.flag) { Flag $sr.flag.level $sr.flag.what $sr.flag.action }; if ($sr.skip) { continue } }
  $running = @(Get-JournalRunning $started @($res.Keys))
  $runTotal += $running.Count
  $errs = @($res.Values | Where-Object { $_.result.error }).Count; $toolErr += $errs; if ($errs) { $errRun = $w.Name }
  L ("workflow {0}: {1} agents, {2} finished, {3} running{4}" -f $w.Name, $started.Count, $res.Count, $running.Count, $(if ($done) { ' (complete)' }))
  # `track` holds merges in review / fix
  if ($AutoFix -and $running.Count -and @($started | Where-Object { $_.label -match '^(build|review|fix):' }).Count) {
    if (Within 'wave reports') { $null = Invoke-Bounded $KitCmd.orch @('report', '-Run', $w.Name) }
  }
  foreach ($a in $running) {
    $tf = Get-ChildItem $w.FullName -Recurse -File -Filter "*$($a.agentId)*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idle = if ($tf) { [int]($now - $tf.LastWriteTime).TotalMinutes } else { -1 }
    L ("  {0,-18} idle {1} min" -f $a.label, $idle)
    if ($idle -ge 0 -and $idle -lt $idleMin) { [void]$liveLabels.Add($a.label) }
    [void]$runningLabels.Add($a.label); [void]$wfAgents.Add([pscustomobject]@{ label = $a.label; agentId = $a.agentId; dir = $w.FullName })
    if ($idle -ge $idleMin) { Flag 'WATCH' "$($a.label) in $($w.Name) has written nothing for $idle min" "Waiting on the gate is fine (board, gate queue); idle > 60 min with no build: let the workflow finish it, then resume it with RESUME_BRIEF." }
  }
  foreach ($r in $res.Values) {
    $label = [string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label
    [void]$doneLabels.Add($label)
    $sum = [string]$r.result.summary + [string]$r.result.error
    # build-stage merged=false is no proof
    $shipped = $r.result.mrs -and -not @($r.result.mrs | Where-Object { -not $_.merged }).Count
    if ($running.Count -and -not $shipped -and $sum -match '(?i)duplicate (agent|copy|writer|instance|session)|(agent|copy|writer)s? collid|collid\w* with (another|an?other agent|agent)|another (agent|writer)|halted|stopped editing') { Flag 'ACT' "$label in $($w.Name) reported a collision/halt" 'Read its result; resume it alone with RESUME_BRIEF after making sure no other writer is active (orch.ps1 board check).' }
    if ($null -ne $r.result.mrs -and @($r.result.mrs).Count -eq 0 -and $sum -match '(?i)not done|no MRs') { Flag 'ACT' "$label finished without MRs" 'Resume it (buildy mode resume) unless it was deliberately stopped.' }
  }
}

# 2. board: gone sessions, re-joins, duplicates, silent entries
$board = Get-KitPath board
$entries = @(Read-KitJsonFiles $board)
$markLeft = { param($e) Update-BoardEntry (Join-Path $board "$($e.session).json") { param($x) $x.status = 'left'; $x | Add-Member -Force NoteProperty crashed (Get-Date).ToString('o'); $x } }
foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -eq $false })) {
  if ($AutoFix) { & $markLeft $e; Flag 'INFO' "auto-fixed: board entry $($e.agent) ($($e.run)) marked left: its session process $($e.holderPid) is gone" 'Resume its work if unfinished (orch.ps1 recover).' }
  else { Flag 'WATCH' "board entry $($e.agent) ($($e.run)): its session process $($e.holderPid) is gone" 'supervise -AutoFix marks it left; orch.ps1 recover lists its work.' }
}
$bm = [double](Get-KitSetting 'idle.beatMinutes' 20); $active = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt $bm })
$stale = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -ge $bm -and ($now - [datetime]$_.beat).TotalHours -lt 6 })
L "board: $($active.Count) active, $($stale.Count) stale"
# two waves may both have X1
foreach ($g in $active | Group-Object { "$($_.run)/$($_.agent)" } | Where-Object Count -gt 1) {
  $byBeat = @($g.Group | Sort-Object { [datetime]$_.beat } -Descending); $newest = [datetime]$byBeat[0].beat
  $old = @($byBeat | Select-Object -Skip 1)
  # a resumed duplicate keeps beating
  $superseded = { param($o) $o.run -eq $byBeat[0].run -and ((($newest - [datetime]$o.beat).TotalMinutes -ge 5) -or
      ((([datetime]$o.beat - [datetime]$o.joined).TotalSeconds -lt 5) -and [math]::Abs(([datetime]$o.joined - [datetime]$byBeat[0].joined).TotalMinutes) -le 2)) }
  if (-not @($old | Where-Object { -not (& $superseded $_) }).Count) {
    if ($AutoFix) { foreach ($o in $old) { & $markLeft $o }; Flag 'INFO' "auto-fixed: $($g.Name) re-joined the board; $($old.Count) old entry/entries marked left" 'Nothing to do.' }
    else { Flag 'WATCH' "$($g.Name) has $($g.Count) board entries but only the newest beats (re-join, not a duplicate)" 'Run supervise with -AutoFix to tidy the board.' }
    continue
  }
  Flag 'ACT' "DUPLICATE agent $($g.Name) active in $($g.Count) sessions" 'Stop the newer copy (TaskStop the resumed task, never the workflow agent); never SendMessage a workflow agent by id.'
}
# testers don't beat in long checks
function LabelNames($l) { $p = $l -split ':'; $n = ($p[-1] -split '@')[0]; @($n) + $(if ($p.Count -gt 1) { "$n-$($p[0])" }) }
$liveNames = @($liveLabels | ForEach-Object { LabelNames $_ })
$doneNames = @($doneLabels | ForEach-Object { LabelNames $_ } | Where-Object { $_ -and $_ -notin $liveNames })
# workflow steps for Test-KitLive
Write-KitAtomic (Get-KitPath live-steps -Create) (@{ at = $now.ToString('o'); running = @($runningLabels); labels = @(@($runningLabels) + @($doneLabels) | Where-Object { $_ } | Select-Object -Unique) } | ConvertTo-Json)
foreach ($s in $stale | Where-Object { $_.agent -in $doneNames }) {
  if ($AutoFix) { & $markLeft $s; Flag 'INFO' "auto-fixed: board entry $($s.agent) marked left (its workflow step finished)" 'Nothing to do.' }
}
foreach ($s in $stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames }) {
  if ($AutoFix -and ($now - [datetime]$s.beat).TotalHours -ge 2) { & $markLeft $s; Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) silent $([int]($now - [datetime]$s.beat).TotalMinutes) min -> marked left" 'Nothing to do.'; continue }
  Flag 'WATCH' "board entry $($s.agent) ($($s.run)) has no heartbeat for $([int]($now - [datetime]$s.beat).TotalMinutes) min" 'It may have finished without leaving, or be stuck. Cross-check with the workflow journal.'
}

# 3. memory, disk, guard blocks; extras' machine guards
$mem = Get-SysMem; $pct = [int](100 * (1 - $mem.AvailGB / $mem.TotalGB)); L "memory: $pct% used, $([math]::Round($mem.AvailGB, 1)) GB available"
$keepFree = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($mem.TotalGB * 0.15)))) }
# extras' hooks (adapters/*.ps1) see this sweep's variables ($now, $mem, $keepFree, Within, Left) and return { level, what, action } = a
# flag, { name, by, gb } = a report row, { info } = an owner line, { ramNeed } = GB a waiting build needs, a string = a sweep line
$res = [Collections.Generic.List[object]]::new(); $script:ownerInfo = @(); $script:ramNeed = 0
function Add-KitResult($x) { if ($x -is [string]) { L $x } elseif ($x.level) { Flag $x.level $x.what $x.action } elseif ($x.info) { $script:ownerInfo += $x.info } elseif ($x.ramNeed) { $script:ramNeed = [math]::Max($script:ramNeed, [double]$x.ramNeed) } elseif ($x.name) { $res.Add($x) } }
# machine guards first, inside the sweep budget (build gate, cache flush, phones, QA seats: extra supervise-resources)
foreach ($x in @(Invoke-KitHooks Get-KitSuperviseGuard @{ AutoFix = $AutoFix })) { Add-KitResult $x }
$ramAct = [int](Get-KitSetting 'supervise.ramActPct' 90); $diskMin = [double](Get-KitSetting 'supervise.minDiskFreeGB' 30)
if ($pct -ge $ramAct) { Flag 'ACT' "RAM $pct% used" 'Hold new launches; run orch.ps1 cleanup; check for orphaned java/node/chrome from finished agents.' }
$drive = if ($KitIsWindows -and $KitConf.Workspace.Length -gt 0) { $KitConf.Workspace.Substring(0, 1) } else { $KitConf.Workspace }
$freeGB = try { [math]::Round([IO.DriveInfo]::new($(if ($KitIsWindows) { "${drive}:\" } else { $drive })).AvailableFreeSpace / 1GB) } catch { 999 }
L "disk ${drive}: $freeGB GB free"
if ($freeGB -lt $diskMin) { Flag 'ACT' "disk ${drive}: only $freeGB GB free" 'Run orch.ps1 cleanup; remove finished worktrees.' }
$blocks = @(Read-KitLog guard $now.AddHours(-1) | Where-Object event -eq 'deny')
if ($blocks.Count -ge 3) { Flag 'WATCH' "guard blocked $($blocks.Count) commands in the last hour" 'Agents are tripping a rule: orch.ps1 audit -Since 1h shows them; add a contracts note or a lesson so they stop.' }

# 4. -AutoFix: tracker (track run), outbox, cleanup (deployed tasks -> inTest: the deploys extra's hook)
if ($AutoFix -and (Within 'tracker checks')) {
  # an active agent with the MR branch checked out is already on it
  function OwnerOf($repo, $iid) {
    $proj = if ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$repo" } else { $repo }
    $src = try { (Invoke-HostApi "projects/$([uri]::EscapeDataString($proj))/merge_requests/$iid").source_branch } catch { $null }   # a host adapter that is an extra throws
    if (-not $src) { return $null }
    foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 30 })) {
      foreach ($w in @($e.worktrees)) {
        $paths = if ([IO.Path]::IsPathRooted("$w")) { @("$w") } else { @($KitConf.WorktreeRoots | ForEach-Object { Join-Path $_ "$w" }) }
        foreach ($wp in $paths) { if ((Test-Path $wp) -and (git -C $wp branch --show-current 2>$null) -eq $src) { return $e.agent } }
      }
    }
    $null
  }
  foreach ($l in @(Invoke-Bounded $KitCmd.orch @('track', 'run', '-Detail'))) {
    if ($l -match '^(DONE|COMMENTED)') { Flag 'INFO' "auto-fixed: $l" 'Tracker moved the task; nothing to do.' }
    elseif ($l -match '^CONFIG') { Flag 'INFO' $l 'A kit.local.json key is missing for this task; add it or register its MRs by hand.' }
    elseif ($l -match '^HOLD') { Flag 'INFO' $l 'Merge/promotion waits for the review or fix round; it resumes by itself.' }
    elseif ($l -match '^ATTENTION \S+: could not set status') { Flag 'ACT' $l "MRs merged, the tracker refused the status (track retries each round): check auth and tracker.statuses (& $($KitCmd.dev) tracker view <id>), or set it by hand." }
    elseif ($l -match '^ATTENTION .*no solution/testing comment') { Flag 'ACT' $l "Post the solution, MR links and how-to-test steps on the task (& $($KitCmd.dev) tracker comment <id> <file.md>)." }
    elseif ($l -match '^ATTENTION .* (?<repo>[\w./-]+)!(?<iid>\d+) opened \((conflict|pipeline \w+)\)' -and ($owner = OwnerOf $Matches.repo $Matches.iid)) {
      Flag 'INFO' "$l - being handled by $owner" 'An active agent has that MR branch checked out; re-check next round.'
    }
    elseif ($l -match '^ATTENTION') { Flag 'ACT' $l 'A tracked MR failed its pipeline, was closed or conflicts (a sibling changed the same lines): get it fixed or rebased (resume its agent with RESUME_BRIEF).' }
  }
  foreach ($l in @(Invoke-KitOutbox)) { Flag $(if ($l -match '^GAVE UP') { 'ACT' } else { 'INFO' }) $(if ($l -match '^SENT') { "auto-fixed: outbox $l" } else { "outbox: $l" }) 'A tracker write lost to the network: do it by hand (dev.ps1 tracker).' }
  foreach ($gone in $stale | Where-Object { ($now - [datetime]$_.beat).TotalHours -ge 2 -and $_.agent -notin $liveNames }) { & $markLeft $gone }   # a long workflow step beats nothing
  # idle Gradle / Kotlin daemons hold GBs
  if ($pct -ge 85) { foreach ($l in @(& $KitCmd.orch cleanup | Select-Object -First 1)) { Flag 'INFO' "auto-fixed: RAM $pct% -> orch.ps1 cleanup: $l" 'Re-check memory next round.' } }
  elseif (Within 'cleanup') { $null = Invoke-Bounded $KitCmd.orch @('cleanup', '-IfDue', '-Quiet') }
}

# 5. QA results back to the dev flow: new [Bug] tasks, failedTesting tasks (orchestrate E6)
if (Within 'QA bug tasks') {
  $parents = @(Get-ChildItem (Get-KitPath qa-runs) -Directory | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'run.json') -Raw | ConvertFrom-Json).tracker.parent } catch {} } | Where-Object { $_ } | Select-Object -Unique)
  $tracked = @((Read-KitTracking).tasks.Keys)
  $openRuns = @{}
  foreach ($rd in Get-ChildItem (Get-KitPath qa-runs) -Directory | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }) {
    try { $rj = Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { continue }
    $left = @($rj.items | Where-Object { -not (Test-Path (Join-Path $rd.FullName "$($_.code)/finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)/held.json")) }).Count
    if ($left -and $rj.tracker.parent) { $openRuns[$rj.tracker.parent] = "$($rd.Name) ($left item(s) left)" }
  }
  foreach ($par in $parents) {
    if (-not (Within 'QA bug tasks')) { break }
    $subs = try { (Get-TrackerTask $par).subtasks } catch { @() }
    $new = @($subs | Where-Object { $_.name.StartsWith([string](Get-KitSetting 'tracker.bugPrefix' '[Bug]')) -and (Test-TrackerStatus $_.status 'open') -and $_.id -notin $tracked })
    if (-not $new.Count) { continue }
    $list = ($new | ForEach-Object { "$($_.id) $($_.name.Substring(0, [math]::Min(70, $_.name.Length)))" }) -join '; '
    $note = if ($openRuns[$par]) { " (run $($openRuns[$par]) is still testing: later bugs go into the next wave)" } else { '' }
    Flag 'ACT' "$($new.Count) new QA bug task(s) not being fixed$note`: $list" "ONE wave now: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> [-Hints ...] per task (brief, tracking, /buildy args), the briefs in one file (a section per agent), one /buildy."
  }
}
if (Within 'failedTesting tasks') {
  $ft = @{}
  foreach ($fj in Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter finalize.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddDays(-7) }) {
    foreach ($s in @((Get-Content $fj.FullName -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.failedTesting })) { $ft[[string]$s.id] = $fj.Directory.Parent.Name }
  }
  $trk = (Read-KitTracking).tasks
  $back = @(foreach ($id in $ft.Keys) {
      if (-not (Within 'failedTesting tasks')) { break }
      $o = $trk[$id]; if ($o -and -not $o.done) { continue }
      $st = try { [string](Get-TrackerTask $id).status } catch { '' }
      if ((Test-TrackerStatus $st 'failedTesting') -or ($o.done -and (Test-TrackerStatus $st 'inProgress'))) { "$id ($($ft[$id]))" } })
  if ($back.Count) { Flag 'ACT' "$($back.Count) task(s) failed testing, back to the dev flow: $($back -join '; ')" "ONE /buildy mode 'bugfix' for all: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> per task (reproduce locally first), then launch." }
}

# 6. decisions and ENV-FIX requests: every round until answered
foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ })) {
  $age = "waiting $([int]($now - [datetime]$d.at).TotalMinutes) min"
  if ($d.kind -eq 'envfix') { Flag 'ACT' "ENV-FIX $($d.id) $age ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Fix it (you or kitty kind env: config, paths, a hung train, shared DB repair; never start a service no live lease or person asked for), then & $($KitCmd.orch) decide answer -Id $($d.id) -By coordinator -Answer 'done: <what you did>' (cannot: 'cannot: <why>')"; continue }
  Flag 'ACT' "DECISION $($d.id) $age ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Ask the owner (options: $(@($d.options) -join ' ; ')$(if ($d.recommend) { "; recommended: $($d.recommend)" })), then & $($KitCmd.orch) decide answer -Id $($d.id) -Answer '<their words>'"
}

# 7. extras' checks (deploys, local env, ...): the same result shapes as section 3
foreach ($x in @(Invoke-KitHooks Get-KitSuperviseFlags @{ AutoFix = $AutoFix })) { Add-KitResult $x }
if ($script:ramNeed -and $mem.AvailGB -lt $keepFree + $script:ramNeed) { Flag 'ACT' "RAM: $([math]::Round($mem.AvailGB, 1)) GB free < floor $keepFree + the largest waiting build $($script:ramNeed) GB" "Free the biggest: $((@($res | Where-Object { $_.gb } | Sort-Object { -$_.gb } | Select-Object -First 3 | ForEach-Object { "$($_.name) $([math]::Round($_.gb, 1)) GB" })) -join '; ')" }
# config that needs an extra not installed (offline: the last fetched extras branch)
$need = if ((Within 'extras') -and (Get-Command (Get-Python) -ErrorAction SilentlyContinue)) { @(& (Get-Python) -X utf8 $KitCmd.kittool extra check 2>$null) }
if ($need) { Flag 'ACT' "missing extra(s): $($need -join '; ')" "python -X utf8 $($KitCmd.kittool) extra sync (between runs: it may update installed extras)" }

# 8. retro due (no workflow running), budgets: past handoff, handoffs not continued, runs at their stop line
if (-not $runTotal) {
  $since = Get-KitRetroSince
  $finished = @($wfDirs | Where-Object { $_.LastWriteTime -gt $since -and (Select-String (Join-Path $_.FullName 'journal.jsonl') -Pattern '"label":"(build|test|retest|verify|fix):' -Quiet) }).Count
  $due = Get-KitRetroDue -RunFinished:([bool]$finished)
  if ($due) { Flag 'ACT' "retro due: $due, $finished dev/QA run(s) finished since, no workflow running" '/tidy (E10)' }
}
foreach ($e in $active | Where-Object { $_.budget -and $_.spend -ge $_.handoff }) { Flag 'WATCH' "$($e.agent) ($($e.run)) past its handoff point: $($e.spend) of $($e.budget) tokens" 'It hands off at its next beat; silent 20 min -> stop it, continue fresh (orch.ps1 recover).' }
foreach ($h in Get-KitHandoffs 24 | Where-Object { ($now - [datetime]$_.beat).TotalMinutes -ge 15 }) { Flag 'ACT' "HANDOFF $($h.agent) ($($h.run)) $([int]($now - [datetime]$h.beat).TotalMinutes) min ago, no fresh agent yet" "Spawn a fresh $(if ($h.type) { $h.type } else { 'agent' }) (same -Agent, -Run): continue from $($h.handoffBrief)" }
foreach ($sf in @(Get-ChildItem (Get-KitPath launches) -Filter 'self-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-12) } | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
  $o = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $null }; if (-not $o.cap -or -not (Within 'run budgets')) { continue }
  $sp = try { & $KitCmd.orch budget -Run $o.run -Json | ConvertFrom-Json } catch { $null }
  if ($sp -and $sp.spent -ge $o.stopAt * $o.cap) { Flag 'WATCH' "run $($o.run) at $([int](100 * $sp.spent / $o.cap))% of its cap ($($sp.spent) / $($o.cap))" 'No new item starts; launch its next when it finishes (E7).' }
}

# 9. the round report: agents (board + workflow steps)
$rep = if ($state.report) { $state.report } else { @{ spend = @{} } }; $spendNow = @{}
$ags = [Collections.Generic.List[object]]::new()
foreach ($e in $active) { $ags.Add([pscustomobject]@{ type = $(if ($e.type) { $e.type } else { 'other' }); name = $e.agent; mode = $(if ($e.status -and $e.status -ne 'working') { $e.status } else { $e.run }); wait = $e.status -match 'wait'; spend = $e.spend }) }
foreach ($a in $wfAgents) {
  $nm = (($a.label -split ':', 2)[-1] -split '@')[0]; if (@($ags | Where-Object name -eq $nm).Count) { continue }
  $p = ($a.label -split ':')[0]; $sp = Get-KitSpend (Join-Path $a.dir "agent-$($a.agentId).jsonl")
  $ags.Add([pscustomobject]@{ type = Get-KitLabelType $a.label; name = $nm; mode = $(if ($p -match 'envfix') { 'env-fix' } elseif ($p -match 'wait|decide') { 'decision' } else { $p }); wait = $p -match 'wait|decide'; spend = $sp.spend })
}
foreach ($x in $ags) { $spendNow[$x.name] = $x.spend; $x | Add-Member -Force NoteProperty prevSpend $(if ($rep.spend -and $null -ne $rep.spend[$x.name]) { $rep.spend[$x.name] } else { $x.spend }) }

# 10. anomalies vs the last round: outbox, agent errors (env restarts, log errors: extra local-env)
$cur = @{ toolErrors = $toolErr; errorRun = $errRun; outbox = @(Get-Content (Get-KitPath outbox) -ErrorAction SilentlyContinue).Count }
$an = Get-KitAnomalies $cur $state.anom; foreach ($x in $an.flags) { Flag $x.level $x.what $x.action }; $state.anom = $an.state
$state.report = @{ spend = $spendNow; at = $now.ToString('s') }; Write-KitAtomic $stateFile ($state | ConvertTo-Json -Depth 5)
$report = [pscustomobject]@{ agents = @($ags); mem = $mem; keepFree = $keepFree; resources = @($res); flags = @($flags); info = $script:ownerInfo; detailFile = (Get-KitPath supervise-report) }
$secs = [int]((Get-Date) - $t0).TotalSeconds
if ($script:skipped.Count) { Flag 'WATCH' "sweep hit its $budgetSeconds s budget: skipped $($script:skipped -join ', ')" 'Partial result: the skipped sections run next round.' }
L "sweep: $secs s"
if ($Json) { [pscustomobject]@{ at = $now.ToString('s'); seconds = $secs; summary = @($lines); flags = @($flags); report = $report } | ConvertTo-Json -Depth 5; exit 0 }
if ($Brief) {   # the final markdown the coordinator pastes verbatim; the long detail goes to a file read only on ACT
  $md = @(Format-KitReport $report -Agents:$Agents)
  @("# supervise $($now.ToString('s'))") + $md + @('', '## All flags') + @($flags | ForEach-Object { "- [$($_.level)] $($_.what) -> $($_.action)" }) + @('', '## Sweep') + @($lines) | Set-Content (Get-KitPath supervise-report -Create) -Encoding utf8
  $md; $nAct = @($flags | Where-Object level -eq 'ACT').Count; if ($nAct) { "ACT: $nAct line(s): act on each now (orchestrate E2); the next heartbeat re-checks" }; $global:LASTEXITCODE = 0; exit 0
}
"=== supervise $($now.ToString('HH:mm')) ==="; $lines
if ($flags.Count) { '--- FLAGS'; $flags | Sort-Object { @{ ACT = 0; WATCH = 1; INFO = 2 }[$_.level] } | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" } } else { '--- no flags: all good' }
$global:LASTEXITCODE = 0
}

# ---- report: a run from its journal (notifications truncate)
function Invoke-Report {
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
$dir = Get-KitWorkflowDirs $Session | Where-Object Name -eq $Run | Select-Object -First 1 -ExpandProperty FullName
if (-not $dir) { [Console]::Error.WriteLine("wave-report: workflow $Run not found under $($KitConf.ClaudeProjectDir)"); exit 1 }  # swallowed under SilentlyContinue
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
$started = @($ev | Where-Object type -eq 'started'); $doneIds = @($ev | Where-Object type -eq 'result' | ForEach-Object agentId)
$running = @(if ($Run -notin (Get-KitFinishedRuns)) { Get-JournalRunning $started $doneIds | ForEach-Object label })

$agents = [ordered]@{}; $findings = New-Object System.Collections.ArrayList; $qa = [ordered]@{}; $learn = $null
foreach ($x in $results) {
  $kind, $id = ($x.label -split ':', 2); $id = ($id -split '@')[0]
  switch ($kind) {
    { $_ -in 'build', 'fix' } {
      $p = if ($agents.Contains($id)) { $agents[$id] } else { $null }
      if ($x.r -is [System.Management.Automation.PSCustomObject]) {
        $rm = @($x.r.mrs | Where-Object { $_ }); $urls = @($rm | ForEach-Object url)
        $mrs = @(@($p.mrs | Where-Object { $_ -and $_.url -notin $urls }) + @($rm | ForEach-Object { [ordered]@{ url = $_.url; merged = [bool]$_.merged; mergeState = $(if ($_.mergeState) { [string]$_.mergeState } elseif ($_.merged) { 'MERGED' } else { 'OPEN' }) } }))
        $nd = @($x.r.deferred | Where-Object { $_ }); $ndIds = @($nd | ForEach-Object id)
        $agents[$id] = [ordered]@{ mrs = $mrs; done = @(@($p.done) + @($x.r.done) | Where-Object { $_ } | Select-Object -Unique)
          deferred = @(@($p.deferred | Where-Object { $_ -and $_.id -notin $ndIds }) + $nd)
          needsLiveCheck = @(@($p.needsLiveCheck) + @($x.r.needsLiveCheck) | Where-Object { $_ } | Select-Object -Unique); fixedRound = ($kind -eq 'fix' -or [bool]$p.fixedRound) }
        if (-not $mrs.Count -and $x.r.summary) { $agents[$id].note = ([string]$x.r.summary).Substring(0, [math]::Min(300, ([string]$x.r.summary).Length)) }
      }
      elseif (-not $p) { $agents[$id] = [ordered]@{ mrs = @(); done = @(); deferred = @(); needsLiveCheck = @(); note = ([string]$x.r).Substring(0, [math]::Min(300, ([string]$x.r).Length)) } }
    }
    'ship' { if ($agents.Contains($id) -and $x.r.mrs) { foreach ($sm in @($x.r.mrs | Where-Object { $_ })) { $u = ([string]$sm.url).TrimEnd('/').ToLower()
      foreach ($m in $agents[$id].mrs) { if (([string]$m.url).TrimEnd('/').ToLower() -eq $u -and $sm.mergeState) { $m.mergeState = [string]$sm.mergeState; $m.merged = ($sm.mergeState -eq 'MERGED') } } } } }
    'review' { foreach ($f in $x.r.findings) { [void]$findings.Add([ordered]@{ agent = $id; severity = $f.severity; file = $f.file; line = $f.line; problem = $f.problem; fix = $f.fix; mr = $f.mr }) } }
    { $_ -in 'test', 'retest' } { if ($x.r.checks) { $c = @($x.r.checks); $qa[$id] = [ordered]@{ checks = $c.Count; pass = @($c | Where-Object result -in 'PASS', 'PASS_WITH_NOTE').Count; fail = @($c | Where-Object result -eq 'FAIL').Count; notTested = @($c | Where-Object result -eq 'NOT_TESTED').Count } } }
    'close' { if ($qa.Contains($id)) { $qa[$id].published = [bool]$x.r.ok } }
    'learn' { $learn = $x.r }
  }
}
$addressed = @($findings | Where-Object { $_.severity -ne 'nit' -and $agents[$_.agent].fixedRound })
$open = @($findings | Where-Object { $_.severity -ne 'nit' -and -not $agents[$_.agent].fixedRound })
# "merged" is a snapshot
foreach ($a in $agents.Values) { foreach ($m in $a.mrs) { if (-not $m.merged -and ($u = ConvertFrom-MrUrl $m.url)) {
  $h = try { Invoke-HostVerb 'mr.get' $u } catch { $null }   # a host adapter that is an extra throws: the journal state stays
  if ($h.state -eq 'merged') { $m.merged = $true; $m.mergeState = 'MERGED' } elseif ($h.merge_when_pipeline_succeeds) { $m.mergeState = 'SCHEDULED' } } } }
$out = [ordered]@{ run = $Run; at = (Get-Date).ToString('s'); running = $running; agents = $agents; openFindings = $open; qa = $qa; learn = $learn }
$wavesDir = Get-KitPath waves -Create
$wvf = Join-Path $wavesDir "$Run.json"; $wvt = "$wvf.$PID.tmp"; $out | ConvertTo-Json -Depth 8 | Set-Content $wvt; Move-Item -LiteralPath $wvt -Destination $wvf -Force
if ($Json) { $out | ConvertTo-Json -Depth 8; exit 0 }

"=== $Run $(if ($running) { "(running: $($running -join ', '))" } else { '(complete)' })"
function Sum($xs, $k) { [int](@($xs | ForEach-Object { $_[$k] }) | Measure-Object -Sum).Sum }
$isSched = { param($m) -not $m.merged -and $m.mergeState -eq 'SCHEDULED' }
$cut = { param($s, $n) $s = [string]$s; $s.Substring(0, [math]::Min($n, $s.Length)) }
if ($Detail) {
  foreach ($k in $agents.Keys) { $a = $agents[$k]; $sc = @($a.mrs | Where-Object { & $isSched $_ }).Count
    '{0,-4} MRs {1}/{2} merged{3} | done [{4}] | deferred {5}{6}' -f $k, @($a.mrs | Where-Object merged).Count, @($a.mrs).Count, $(if ($sc) { ", $sc scheduled" }), ($a.done -join ','), @($a.deferred).Count, $(if ($a.note) { " | $(& $cut $a.note 80)" })
    foreach ($m in @($a.mrs | Where-Object { -not $_.merged })) { "       MR $($m.mergeState): $($m.url)" }
    foreach ($d in @($a.deferred)) { "       deferred $($d.id): $($d.reason)" }
    foreach ($c in @($a.needsLiveCheck)) { "       live check: $c" } }
  foreach ($k in $qa.Keys) { $q = $qa[$k]; '{0,-5} {1}/{2} pass, {3} fail, {4} not tested{5}' -f $k, $q.pass, $q.checks, $q.fail, $q.notTested, $(if ($q.Contains('published')) { " | published: $($q.published)" }) }
  if ($addressed.Count) { "--- review findings addressed in the fix round ($($addressed.Count)) - see each agent's fix-round summary"; $addressed | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line)" } }
  if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $($_.problem)`n      fix: $($_.fix)" } }
} else {
  $am = @($agents.Values | ForEach-Object { @($_.mrs) }); $qv = @($qa.Values)
  $parts = @()
  if ($agents.Count) { $parts += "agents $($agents.Count): MRs $(@($am | Where-Object merged).Count)/$($am.Count) merged, $(@($am | Where-Object { & $isSched $_ }).Count) scheduled, done $(@($agents.Values | ForEach-Object { @($_.done) }).Count), deferred $(@($agents.Values | ForEach-Object { @($_.deferred) }).Count), findings open $($open.Count) / addressed $($addressed.Count)" }
  if ($qa.Count) { $parts += "QA $($qa.Count) pkg: pass $((Sum $qv 'pass'))/$((Sum $qv 'checks')), fail $((Sum $qv 'fail')), not tested $((Sum $qv 'notTested')), published $(@($qv | Where-Object { $_.Contains('published') -and $_.published }).Count)/$($qa.Count)" }
  if ($parts) { $parts -join ' | ' }
  foreach ($k in $agents.Keys) { $a = $agents[$k]; $um = @($a.mrs | Where-Object { -not $_.merged }).Count; $sc = @($a.mrs | Where-Object { & $isSched $_ }).Count; $dc = @($a.deferred).Count
    if ($um -or $dc -or $a.note) { '  {0}: {1}{2}{3}' -f $k, $(if ($um) { "$um MR(s) not merged$(if ($sc) { " ($sc scheduled)" }) " }), $(if ($dc) { "deferred $dc ($(@($a.deferred | ForEach-Object id) -join ',')) " }), $(if ($a.note) { "| $(& $cut $a.note 80)" }) } }
  foreach ($k in $qa.Keys) { $q = $qa[$k]; if ($q.fail -or $q.notTested -or ($q.Contains('published') -and -not $q.published)) { '  {0}: fail {1}, not tested {2}{3}' -f $k, $q.fail, $q.notTested, $(if ($q.Contains('published') -and -not $q.published) { ', NOT published' }) } }
  if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $(& $cut $_.problem 100)" } }
}
if ($learn) { "--- learn: $($learn.signals) signal(s); lessons: $(@($learn.lessonsChanged).Count)" }
if ($Detail) { "saved: $(Join-Path $wavesDir "$Run.json")" } else { "(full: -Detail or waves\$Run.json)" }
if (-not $running -and ($due = Get-KitRetroDue -RunFinished)) { "ACT  retro due ($due): /tidy (E10)" }
}

# ---- audit: one ordered timeline (kitlog streams, workflow journal, board) of a run, agent or task
function Invoke-Audit {
param([string]$Run, [string]$Agent, [string]$Task, [string]$Since, [int]$Last = 0, [switch]$All, [switch]$Json)
$now = Get-Date
$from = if ($Since -match '^(\d+)([mhd])$') { $now.AddMinutes(-[int]$Matches[1] * @{ m = 1; h = 60; d = 1440 }[$Matches[2]]) } elseif ($Since) { [datetime]$Since } else { $null }
$names = @(); $agents = @(); $wf = $null
if ($Run) {   # a kit run name (board, -Run) or a workflow run id: both name the same run
  $self = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { $_.run -eq $Run -or ($_.wfDir -and (Split-Path $_.wfDir -Leaf) -eq $Run) })
  $wf = @(Get-KitWorkflowDirs | Where-Object { $_.Name -eq $Run -or ($self.wfDir -and $_.FullName -in @($self.wfDir)) })[0]
  $j = if ($wf) { Join-Path $wf.FullName 'journal.jsonl' }
  $rec = if ($j -and (Test-Path $j)) { @(Select-String -LiteralPath $j -Pattern 'RECORDED \S+ (\S+)' | Select-Object -First 1 | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
  $names = @(@($Run, $wf.Name) + @($self.run) + $rec | Where-Object { $_ } | Select-Object -Unique)
  if (-not $from) { $from = @(@($self | ForEach-Object { [datetime]$_.at }) + @($wf.CreationTime) | Where-Object { $_ } | Sort-Object)[0]; if ($from) { $from = $from.AddMinutes(-5) } }
}
if (-not $from) { $from = $now.AddDays(-1) }
$ev = [Collections.Generic.List[object]]::new()
function Add-Ev($at, $who, $what, $res, $ms) { $ev.Add([pscustomobject]@{ at = [datetime]$at; agent = "$who"; what = ("$what" -replace '\s+', ' ').Trim(); result = "$res"; ms = $ms }) }
function Cut([string]$s, [int]$n = 90) { $s = $s -replace '\s+', ' '; if ($s.Length -gt $n) { $s.Substring(0, $n - 3) + '...' } else { $s } }
foreach ($b in @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.joined -and [datetime]$_.beat -ge $from -and (-not $names -or $_.run -in $names) -and (-not $Agent -or $_.agent -eq $Agent) })) {
  $agents += $b.agent; Add-Ev $b.joined $b.agent "board joined $($b.area) $(if ($b.items) { "[$($b.items)]" })" "session $($b.session)" $null
  if ($b.status -eq 'left') { Add-Ev $b.beat $b.agent 'board left' $(if ($b.handoffBrief) { "handoff $($b.handoffBrief)" } elseif ($b.takenOverBy) { "taken over by $($b.takenOverBy)" }) $null }
}
if ($wf -and (Test-Path $j)) {   # steps: the journal; their times: each agent transcript's first and last line
  $jl = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
  $done = @{}; foreach ($r in $jl | Where-Object type -eq 'result') { $done[$r.agentId] = $r.result }
  foreach ($s in $jl | Where-Object type -eq 'started') {
    $tf = Join-Path $wf.FullName "agent-$($s.agentId).jsonl"; if (-not (Test-Path $tf)) { continue }
    $t0, $t1 = @((Get-Content -LiteralPath $tf -TotalCount 1), (Get-Content -LiteralPath $tf -Tail 1)) | ForEach-Object { if ($_ -match '"timestamp":"([^"]+)"') { [datetime]$Matches[1] } }
    $who = ($s.label -split ':', 2)[-1] -replace '@.*$', ''; if ($Agent -and $who -ne $Agent) { continue }; $agents += $who
    $r = $done[$s.agentId]; $res = if ($null -eq $r) { 'running' } elseif ($r.ok -eq $false -or $r.error) { "failed $(Cut "$($r.error)$($r.summary)" 60)" } else { 'ok' }
    if ($t0) { Add-Ev $t0 $who "step $($s.label) ($($s.phase))" $res $(if ($t1 -and $null -ne $r) { [int]($t1 - $t0).TotalMilliseconds }) }
  }
}
$open = @{}
foreach ($l in @(Read-KitLog -Since $from | Sort-Object { [datetime]$_.at })) {
  if ($names -and -not ($l.run -in $names -or ($l.agent -and $l.agent -in $agents))) { continue }
  if ($Agent -and $l.agent -ne $Agent) { continue }
  if ($Task -and $l.task -ne $Task -and "$($l.args)$($l.text)$($l.item)$($l.id)" -notmatch [regex]::Escape($Task)) { continue }
  $w = $(if ($l.agent) { $l.agent } else { '-' })
  switch ($l.stream) {
    'calls' {
      if ($l.event -eq 'start') { $open["$($l.pid)"] = $l; continue }
      if ($l.event -eq 'end') { $s = $open["$($l.pid)"]; $open.Remove("$($l.pid)")
        if ($All -or $l.verb -notmatch '^board (beat|check)') { Add-Ev $(if ($s) { $s.at } else { $l.at }) $w "$($l.script) $($l.verb) $(Cut "$($s.args)" 70)" "rc $($l.rc)" $l.ms }; continue }
      Add-Ev $l.at $w "$($l.script) $($l.verb) $($l.event)" (Cut "$($l.error)$($l.what)$(@($l.byWhy) -join '; ')") $null }
    'builds' { Add-Ev $l.at $w "build $($l.event) $($l.kind) $($l.project)" $(if ($l.event -eq 'start') { "waited $($l.waitSec) s" } else { "code $($l.code), peak $($l.peakGB) GB" }) $(if ($l.sec) { 1000 * $l.sec }) }
    'guard' { Add-Ev $l.at $w "guard $($l.event) $($l.tool)" (Cut $l.why 70) $null }
    'signals' { Add-Ev $l.at $w "learn $($l.skill)/$($l.kind)" (Cut $l.text) $null }
    'decisions-log' { Add-Ev $l.at $w "decide $($l.id) $($l.status)" (Cut "$(if ($l.answer) { $l.answer } else { $l.question })") $null }
    'deploy-log' { Add-Ev $l.at $w "deploy $($l.target)" (Cut "$(@($l.mrs) -join ',') $($l.note)") $null }
    default { Add-Ev $l.at $w "$($l.stream) $($l.event) $($l.env)" (Cut "$($l.service)$($l.text)$($l.why)") $null }
  }
}
foreach ($s in $open.Values) { if ($All -or $s.verb -notmatch '^board (beat|check)') { Add-Ev $s.at $(if ($s.agent) { $s.agent } else { '-' }) "$($s.script) $($s.verb) $(Cut "$($s.args)" 70)" 'no end (running or killed)' $null } }
$out = @($ev | Sort-Object at); if ($Last) { $out = @($out | Select-Object -Last $Last) }
if ($Json) { ConvertTo-Json @($out) -Depth 4; return }
"audit$(if ($Run) { " run $($names -join ' = ')" })$(if ($Agent) { " agent $Agent" })$(if ($Task) { " task $Task" }): $($out.Count) events since $($from.ToString('yyyy-MM-dd HH:mm'))$(if (-not $All) { ' (board beats hidden: -All)' })"
foreach ($e in $out) { '{0:MM-dd HH:mm:ss} {1,-10} {2} -> {3}{4}' -f $e.at, $e.agent, $e.what, $e.result, $(if ($null -ne $e.ms) { ' ' + $(if ($e.ms -ge 60000) { "$([math]::Round($e.ms / 60000, 1)) min" } elseif ($e.ms -ge 1000) { "$([math]::Round($e.ms / 1000)) s" } else { "$($e.ms) ms" }) }) }
}

# ---- bugbrief: bug-fix brief + /buildy args
function Invoke-BugBrief {
param(
  [Parameter(Mandatory)][string]$Task,
  [Parameter(Mandatory)][string]$Agent,
  [Parameter(Mandatory)][string[]]$Repos,
  [string[]]$Hints = @(),
  [string]$Range,
  [string[]]$Mandate = @()
)
$ErrorActionPreference = 'Stop'
$kit = Split-Path $PSScriptRoot
$claude = Split-Path $kit
$cfgFile = Join-Path $kit 'dev-kit/kit.local.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { $null }
if (-not $cfg -or -not $cfg.repos) { throw "add a ""repos"" list to $cfgFile (see kit.example.json)" }

$j = Get-TrackerTask $Task
if (-not $j.name) { throw "cannot read task $Task from the tracker ($($KitConf.TrackerType)) - check its CLI auth / tracker config" }
$desc = [string]$j.description
$texts = @($desc) + @(@(try { Get-TrackerComments $Task } catch { @() }) | Sort-Object date -Descending | ForEach-Object { [string]$_.text })
$checks = @(); $cur = $null
foreach ($line in (@($texts | Where-Object { $_ -match '(?m)^###\s+\S+\s+[—-]\s+' } | Select-Object -First 1) -split "`n")) {
  if ($line -match '^###\s+(?<id>\S+)\s+[—-]\s+(?<screen>.+)$') { if ($cur) { $checks += $cur }; $cur = [ordered]@{ id = $Matches.id; screen = $Matches.screen.Trim(); saw = '' } }
  elseif ($cur -and $line -match '^\*\*Saw:\*\*\s*(?<s>.+)$') { $s = ($Matches.s -split '\| Independent re-test')[0].Trim(); $cur.saw = if ($s.Length -gt 500) { $s.Substring(0, 497) + '...' } else { $s } }
}
if ($cur) { $checks += $cur }
if (-not $checks) { throw "no '### <id> — <screen>' failed checks found in $Task" }

$runItem = $null
foreach ($fin in Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter finalize.json -ErrorAction SilentlyContinue) {
  $o = Get-Content $fin.FullName -Raw | ConvertFrom-Json
  if (@($o.subtasks | Where-Object { $_.bug -eq $Task }).Count) { $runItem = $fin.Directory; break }
}
$evidence = if ($runItem) { "Evidence + exported guide: ``$($runItem.FullName)/`` and ``$(Split-Path $runItem.FullName)/guides/$($runItem.Name).txt``." } else { 'Evidence: the results doc linked in the task.' }

$Repos = @($Repos -split '\s*,\s*' | Where-Object { $_ })
$orig = @(try { Get-TaskMrBranches @($Task, [string]$j.parent) } catch { @() })
function RepoName($r) { @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0].name }
foreach ($o in $orig) {   # the original ask's repos join the table unless named
  $rn = RepoName $o.repo
  if ($rn -and -not @($Repos | Where-Object { (RepoName ($_ -split '@')[0]) -eq $rn }).Count) { $Repos += "$rn@$($o.branch)" }
}
$origLine = if ($orig) { "Original ask's MRs: " + (($orig | ForEach-Object { "$($_.ref) -> ``$($_.branch)``" }) -join ', ') + '.' }
$rows = foreach ($spec in $Repos) {
  $r, $branch = $spec -split '@', 2
  $repo = @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0]
  if (-not $repo) { throw "unknown repo '$r' (kit.local.json repos: $(@($cfg.repos.name) -join ', '))" }
  # must not borrow the default's linked deps
  $deps = if ($branch -and $branch -ne $repo.target) { "a checkout on ``$branch`` (not ``$($repo.linkFrom)``, which is on ``$($repo.target)``; dev.ps1 wt warns on a mismatch)" } elseif ($repo.linkFrom) { "``$($repo.linkFrom)`` (-LinkFrom)" } else { 'main checkout' }
  "| $($repo.name) | ``$($repo.checkout)`` | ``$(if ($branch) { $branch } else { $repo.target })`` | $deps |"
}
$ids = ($checks | ForEach-Object id) -join ', '
$slugAgent = $Agent.ToLower()
$runName = "bugfix-$($Task)"
$md = @"
# Bug-fix brief: $($j.name)

Follow ``$claude/skills/dev-kit/templates.md`` "Bug-fix brief", ``$claude/skills/dev-kit/SKILL.md`` and ``$claude/skills/local-env/SKILL.md`` "Debug locally" (extra local-env).
This brief wins where they differ.

Task: $($j.url) — checks $ids to fix. **Reproduce each check on the local env FIRST** (template steps 1-4).
$evidence
$origLine

## Failed checks
$(($checks | ForEach-Object { "- **$($_.id)** — $($_.screen): $($_.saw)" }) -join "`n")
$(if ($Hints) { "`n## Coordinator notes`n" + (($Hints | ForEach-Object { "- $_" }) -join "`n") + "`n" })
Fix every check above (root cause + test) or prove it stale/expected with evidence. Fix only these checks. A check you cannot
fix here (another area or repo) needs a follow-up tracker task (cause, proposed fix) linked in a comment on $Task before your MR is done.
Product calls: the reference behaviour or a recorded decision, named. Additive only: users the fix does not target see no change
(crash/500/data-loss fixes may apply to everyone: list them under "Kept for everyone").

## Repos
| Repo | Main checkout | Target | Link deps from |
|---|---|---|---|
$($rows -join "`n")

## Ownership
| Agent | Bug task | Items | Migration range |
|---|---|---|---|
| $Agent | $Task | $ids | $(if ($Range) { $Range } else { 'ask the coordinator if you need one' }) |

Branches ``fix/$($KitConf.TrackerTag)$Task-<slug>``; worktree prefix ``$slugAgent``; board run ``$runName``. Tracker (``$claude/skills/dev-kit/dev.ps1 tracker``):
in progress → review (orch.ps1 track sets promoted when all merge). The workflow merges after review: do NOT merge yourself.
Register: ``$claude/skills/orchestrate/orch.ps1 track add -Task $Task -Discover``.
Phones (app bugs, extra android-swarm): the local-env APK (``swarm.ps1 build -Local``, ``swarm.ps1 acquire -Agent $Agent -Apk local``); release it when done.
"@
$dir = Get-KitPath briefs -Create
$out = Join-Path $dir "$Task.md"
Set-Content $out $md -Encoding utf8
$null = Test-KitProse -Kind bug-brief -Path $out
$m = if ($Mandate) { $Mandate } elseif ($cfg.bugfixMandate) { @($cfg.bugfixMandate) } else { Write-Warning 'no mandate: pass -Mandate or set kit.local.json "bugfixMandate" (agents drop their items for later chat messages without one)'; @() }
$cosmetic = [string](Get-KitSetting 'locale.cosmeticPattern' '(?i)label|translation|i18n|raw (translation )?key|colou?r|date format|typo|spelling|alignment|padding|wording|icon')
$complex = $checks.Count -gt 2 -or @($checks | Where-Object { ($_.screen + ' ' + $_.saw) -notmatch $cosmetic }).Count
$agentArgs = [ordered]@{ id = $Agent; items = "$Task $ids" }; if ($complex) { $agentArgs.complex = $true }
$wfArgs = [ordered]@{ brief = $out; run = $runName; mode = 'bugfix'; review = $true; mandate = $m; agents = @($agentArgs) }
$ro = [ordered]@{}; foreach ($x in @(Get-KitValue 'repos' @()) | Where-Object role) { $ro[$x.name] = $x.role }; if ($ro.Count) { $wfArgs.roles = $ro }
$wfArgs.agents[0].area = (($checks | ForEach-Object screen) -join '; ').Substring(0, [math]::Min(160, (($checks | ForEach-Object screen) -join '; ').Length))
"brief: $out ($($checks.Count) checks: $ids; model: $(if ($complex) { 'strongest (complex: true)' } else { 'sonnet (small/cosmetic)' }))"
"Workflow args (scriptPath $claude/workflows/buildy.js):"
$wfArgs | ConvertTo-Json -Depth 5 -Compress
$tj = Get-KitPath tracking
$tracked = (Test-Path $tj) -and @((Get-Content $tj -Raw | ConvertFrom-Json).tasks.PSObject.Properties.Name) -contains $Task
if ($tracked) { "already tracked: $Task" } else {
  $ta = @(& $KitCmd.orch track add -Task $Task -Discover 2>&1); $tc = $LASTEXITCODE
  if ($tc) { "NOT tracked: $Task (track add exit ${tc}: $(($ta | Select-Object -Last 2) -join ' ')): run orch.ps1 track add -Task $Task -Discover" } else { "tracking $Task (-Discover)" }
}
}

# ---- cleanup: kit-created leftovers only, never repos or in-use
function Invoke-Cleanup {
param([switch]$DryRun, [switch]$IfDue, [switch]$Quiet, [switch]$WorktreesOnly, [string[]]$WorktreeRoot = @(), [double]$WorktreeIdleHours = 2)
$ErrorActionPreference = 'SilentlyContinue'
$tmp = Get-KitTemp
if (-not $WorktreeRoot) { $WorktreeRoot = $KitConf.WorktreeRoots }
$keepBranches = '^(' + ((@('localenv/.+') + @($(if ((Get-KitSetting 'protectedBranchesMode' '') -ne 'replace') { 'main', 'master', 'develop' })) + @($KitConf.ProtectedBranches | ForEach-Object { [regex]::Escape($_) })) -join '|') + ')$'
$mark = Get-KitPath last-cleanup -Create
if ($IfDue -and (Test-Path $mark) -and ((Get-Date) - [datetime](Get-Content $mark -Raw).Trim()).TotalHours -lt 20) { exit 0 }

$now = Get-Date; $script:freed = 0L; $actions = New-Object System.Collections.ArrayList
function Size($p) { if (Test-Path $p -PathType Leaf) { (Get-Item $p).Length } else { (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
function Gone($path, $why) {
  if (-not (Test-Path $path)) { return }
  $sz = [long](Size $path)
  if (-not $DryRun) { try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { [void]$actions.Add([pscustomobject]@{ mb = 0; why = "FAILED $why"; path = "$path`: $($_.Exception.Message)" }); return } }
  $script:freed += $sz
  [void]$actions.Add([pscustomobject]@{ mb = $sz / 1MB; why = $why; path = $path })
}
# a folder's age = its newest file's
function Old($item, $hours) {
  $t = $item.LastWriteTime
  if ($item.PSIsContainer -and ($now - $t).TotalHours -gt $hours) { $n = (Get-ChildItem $item.FullName -Recurse -File -Force | Measure-Object LastWriteTime -Maximum).Maximum; if ($n -gt $t) { $t = $n } }
  ($now - $t).TotalHours -gt $hours
}
$notes = @()

if (-not $WorktreesOnly) {
Invoke-KitHooks Invoke-KitCleanup   # extra supervise-resources: test browsers, their profiles, idle Gradle / Kotlin daemons

# retention: kit.example.json _paths.keep (hours, [hours, newest N kept]); tab registries + locks belong to live browsers, pending decisions wait
$pm = $script:KitPathMap
foreach ($p in @($pm.keep.PSObject.Properties | Where-Object Name -notlike '_*')) {
  $v = @($p.Value); $n = if ($v.Count -gt 1) { [int]$v[1] } else { 0 }
  foreach ($i in @(Get-ChildItem (Get-KitPath $p.Name) -Force | Where-Object { $_.Name -notmatch '^tabs-|\.lock$' -and -not ($p.Name -eq 'decisions' -and (Get-Content $_.FullName -Raw) -match '"status":\s*"pending"') } | Sort-Object LastWriteTime -Descending | Select-Object -Skip $n)) { if (Old $i $v[0]) { Gone $i.FullName "$($p.Name) > $($v[0]) h" } }
}
# shots / evidence / scripts of a QA run: 7 d after its report, 30 d without one (results and report kept)
foreach ($r in Get-ChildItem (Get-KitPath qa-runs) -Directory | Where-Object { Old $_ 168 }) { $all = Old $r 720
  foreach ($sub in Get-ChildItem $r.FullName -Recurse -Directory | Where-Object Name -in 'shots', 'evidence', 'scripts') { if ($all -or (Test-Path (Join-Path $sub.Parent.FullName 'report.md'))) { Gone $sub.FullName 'QA run media (7 d published / 30 d)' } } }
# entries the layout does not name: runtime root after 72 h, work/ after 336 h, cache/ and logs/ after 720 h; durable ones are listed only
$known = @{}; foreach ($r in @($pm.runtime.PSObject.Properties.Value)) { $s = ([string]$r).TrimEnd('/') -split '/'; $known[$s[0]] = 1; if ($s.Count -gt 1) { $known["$($s[0])/$($s[1])"] = 1 } }
$rt = Get-KitRuntime
foreach ($i in Get-ChildItem $rt -Force) { if (-not $known[$i.Name] -and (Old $i 72)) { Gone $i.FullName 'not in the layout (runtime root)' } }
foreach ($top in 'work', 'cache', 'logs') { $h = if ($top -eq 'work') { 336 } else { 720 }
  foreach ($i in Get-ChildItem (Join-Path $rt $top) -Force | Where-Object Name -notmatch '\.lock$') { if (-not $known["$top/$($i.Name)"] -and (Old $i $h)) { Gone $i.FullName "not in the layout ($top/)" } } }
$dk = @($pm.durable.PSObject.Properties.Value | ForEach-Object { (([string]$_).TrimEnd('/') -split '/')[0] })
$sd = Split-Path (Get-KitPath tracking); $odd = @(Get-ChildItem $sd -Force | Where-Object { $_.Name -notin $dk -and $_.Name -notmatch '\.(lock|bad-.*)$' })
if ($odd) { $notes += "durable state not in the layout (kept; move or delete by hand): $(@($odd | ForEach-Object Name) -join ', ')" }

foreach ($f in Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json') {
  try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (-not (Get-Process -Id $e.pid -ErrorAction SilentlyContinue)) { Gone $f.FullName 'dead gate entry' } } catch {}
}

$ct = if ($DryRun) { [long](Size (Join-Path $tmp 'claude')) }; if ($ct) { $notes += "Claude session temp (outside the kit, not managed): $([math]::Round($ct / 1MB)) MB in $(Join-Path $tmp 'claude')" }

foreach ($f in Get-ChildItem $tmp -Force | Where-Object { $_.Name -match '^(kit-|claude-kit-|wfc\.js$|gradletest$|report-preview\.html$|gate-debug\.ps1$|bad-findings\.json$|audit-test$|kitshots$|tsc\d\.log$|claude-wt-selftest$)' }) {
  if (Old $f 24) { Gone $f.FullName 'kit test leftover' }
}

}

# a branch goes only with a MERGED MR at its tip
function MergedTip($repo, $br) {
  $url = "$(git -C $repo remote get-url origin 2>$null)".Trim()
  if ($url -notmatch '^(?:https?://(?:[^@/]+@)?(?<host>[^/]+)/|[^@]+@(?<host>[^:]+):)(?<path>.+?)(?:\.git)?/?$') { return $null }
  $hostName = $Matches.host; $path = $Matches.path -replace '/_git/', '/' -replace '^v3/', ''
  $type = if ($hostName -eq $KitConf.GitHost) { $script:HostType } else { Get-HostKind $hostName }
  if ($type -eq 'gitlab') { $env:GITLAB_HOST = $hostName }
  $mrs = Invoke-HostVerb 'mr.list' @{ repo = $path; type = $type; source_branch = $br; state = 'merged'; per_page = 20 }
  return @($mrs | ForEach-Object sha)
}
$repos = @{}; $claimed = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalHours -lt 24 } | ForEach-Object { $_.worktrees } | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/').ToLower() })
foreach ($root in $WorktreeRoot) {
  foreach ($w in Get-ChildItem $root -Directory) {
    $d = $w.FullName
    if (-not (git -C $d rev-parse --is-inside-work-tree 2>$null)) { continue }
    $br = git -C $d rev-parse --abbrev-ref HEAD 2>$null
    if (-not $br -or $br -eq 'HEAD' -or $br -match $keepBranches) { continue }
    if (git -C $d status --porcelain 2>$null) { continue }
    $newest = (Get-ChildItem $d -File -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue | Where-Object FullName -notmatch '[\\/](node_modules|\.git|target|build)[\\/]' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($newest -and ($now - $newest).TotalHours -lt $WorktreeIdleHours) { continue }
    if (-not (Invoke-GitFetch -Dir $d)) { continue }
    $main = "$(git -C $d rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
    $tip = (git -C $d rev-parse HEAD 2>$null); $ob = "$(git -C $d symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim()
    # its MR merged at this tip (host state: squash merges too), or the tip already in origin's default branch: nothing is lost
    # (contained: idle 24 h+, a fresh worktree has no commits yet; a claimed one is in use)
    $why = if (-not $main -or $d.ToLower() -in $claimed) { $null } elseif ($tip -in @(MergedTip $main $br)) { 'MR merged at its tip' } elseif ($ob -and (-not $newest -or ($now - $newest).TotalHours -ge 24) -and $(git -C $d merge-base --is-ancestor $tip $ob 2>$null; $LASTEXITCODE -eq 0)) { "contained in $ob" }
    if (-not $why) { continue }
    $sz = [long](Size $d); $script:freed += $sz
    [void]$actions.Add([pscustomobject]@{ mb = $sz / 1MB; why = "worktree + local branch: $why (clean, idle)"; path = "$d ($br)" })
    if (-not $DryRun) { & $KitCmd.dev wt remove -Dir $d | Out-Null; if (-not (Test-Path $d)) { git -C $main branch -D $br 2>$null | Out-Null } }
    if ($main) { $repos[$main] = $true }
  }
}
$roots = @($KitConf.ReposRoot) | Where-Object { $_ -and (Test-Path $_) -and (Test-Path $KitConf.ConfigFile) }
foreach ($r in $roots) { foreach ($c in Get-ChildItem $r -Directory) { if (Test-Path (Join-Path $c.FullName '.git')) { $gd = "$(git -C $c.FullName rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim(); if ($gd) { $repos[$gd] = $true } } } }
foreach ($repo in @($repos.Keys)) {
  if (-not (git -C $repo rev-parse --git-dir 2>$null)) { continue }
  if (-not (Invoke-GitFetch -Dir $repo)) { continue }
  $out = @(git -C $repo worktree list --porcelain 2>$null | Where-Object { $_ -like 'branch refs/heads/*' } | ForEach-Object { $_.Substring(18) })
  foreach ($line in git -C $repo for-each-ref --format='%(refname:short)|%(objectname)|%(upstream:track)' refs/heads) {
    $b, $tip, $track = $line -split '\|', 3
    if ($track -ne '[gone]' -or $b -match $keepBranches -or $b -in $out) { continue }
    $merged = MergedTip $repo $b
    if (-not $merged -or $tip -notin $merged) { continue }
    [void]$actions.Add([pscustomobject]@{ mb = 0; why = 'branch merged at its tip, remote gone -> deleted'; path = "$b in $repo" })
    if (-not $DryRun) { git -C $repo branch -D $b 2>$null | Out-Null }
  }
}

if (-not $WorktreesOnly) {
# service logs and the durable log streams keep their last 5000 lines
foreach ($f in @(@(Get-ChildItem (Get-KitPath logs) -Filter '*.log' -File -Recurse | ForEach-Object FullName) + @($script:KitLogMap.streams | Where-Object { $pm.durable.$_ } | ForEach-Object { Get-KitPath $_ }))) {
  if ((Test-Path $f) -and @(Get-Content $f).Count -gt 5000) { if (-not $DryRun) { Invoke-KitLocked $f { $keep = Get-Content $f -Tail 5000; Set-Content $f $keep } }; [void]$actions.Add([pscustomobject]@{ mb = 0; why = 'rotated to 5000 lines'; path = $f }) }
}

}
$summary = "$(if ($DryRun) { '[dry run] would free' } else { 'freed' }) $([math]::Round($script:freed / 1MB, 1)) MB in $($actions.Count) action(s)"
$groups = @($actions | Group-Object why | ForEach-Object { [pscustomobject]@{ why = $_.Name; n = $_.Count; mb = ($_.Group | Measure-Object mb -Sum).Sum; first = $_.Group[0].path } } | Sort-Object mb -Descending)
if (-not $DryRun) { if (-not $WorktreesOnly) { $now.ToString('s') | Set-Content $mark }; Write-KitLog calls cleanup @{ freedMB = [math]::Round($script:freed / 1MB, 1); actions = $actions.Count; byWhy = @($groups | ForEach-Object { "$($_.why): $($_.n), $([math]::Round($_.mb, 1)) MB" }) } }
if (-not $Quiet) { $summary; $groups | ForEach-Object { '{0,9:N1} MB {1,5} x  {2}  (e.g. {3})' -f $_.mb, $_.n, $_.why, $_.first }; $notes }
$global:LASTEXITCODE = 0
}

# ---- learn: signals + LESSONS.md (lesson edits, -Stats, -History: extra kit-admin)
# a lessons file as LF lines (empty when missing); the "## <name>" section of it as [start, end), $null when absent
function Read-KitLessonLines([string]$Path) { if (Test-Path $Path) { , [Collections.Generic.List[string]]@(([IO.File]::ReadAllText($Path) -replace "`r", '') -split "`n") } else { , [Collections.Generic.List[string]]::new() } }
function Find-KitLessonSection($Lines, [string]$Name) { $s = $Lines.IndexOf("## $Name"); if ($s -lt 0) { return $null }; $e = $s + 1; while ($e -lt $Lines.Count -and $Lines[$e] -notmatch '^## ') { $e++ }; , @($s, $e) }
function Invoke-Learn {
  param(
    [string]$Skill, [ValidateSet('friction', 'failure', 'defect-missed', 'false-positive', 'rule-violation', 'stale-env', 'flaky', 'idea', 'win')][string]$Kind,
    [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
    [switch]$Show, [int]$Last = 30, [switch]$Stats, [switch]$Read, [switch]$History, [string]$Grep,
    [string]$Lesson, [string]$Project, [string]$Fixed, [string]$Bump, [string]$Append, [switch]$Trim, [int]$Max = 40
  )
  if ($Stats -or $History -or $Lesson -or $Fixed -or $Bump -or $Trim) {   # the retro's tools (kitty, /tidy)
    $admin = Assert-KitExtra Invoke-LearnAdmin 'learn -Stats / -History / -Lesson / -Bump / -Fixed / -Trim' 'kit-admin'; & $admin @PSBoundParameters; return
  }
  $file = Get-KitPath signals -Create
  if ($Show) { if (Test-Path $file) { Get-Content $file -Tail $Last | ForEach-Object { $s = $_ | ConvertFrom-Json; '{0} {1,-13} {2,-15} {3}{4}' -f ([datetime]$s.at).ToString('yyyy-MM-dd HH:mm'), $s.skill, $s.kind, $s.text, $(if ($s.ref) { " [$($s.ref)]" }) } }; return }
  if ($Read) {
    if (-not $Skill) { 'usage: learn -Read -Skill <skill>'; exit 2 }
    foreach ($f in (Join-Path $KitConf.Kit 'LESSONS.md'), (Join-Path $KitConf.Kit 'LESSONS.local.md')) {
      $L = Read-KitLessonLines $f; $r = Find-KitLessonSection $L $Skill; if (-not $r) { continue }
      $lines = @($L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^(##|###|- )' } | Select-Object -First 41)   # step-0 read cap: 40 lessons
      if ($lines.Count -gt 1) { "$(if ($f -like '*.local.md') { '(local) ' })$($lines -join "`n")" }
    }
    return
  }
  if (-not ($Skill -and $Kind -and $Text)) { 'need -Skill -Kind -Text (or -Read, -Show; kit-admin: -Stats, -History, -Lesson, -Bump, -Fixed, -Trim)'; exit 2 }
  Write-KitLog signals '' ([ordered]@{ skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source })
  "recorded ($Skill/$Kind)"
}

# ---- decide: decision pauses; only that item waits
function Invoke-Decide {
  param([Parameter(Position = 0)][ValidateSet('ask', 'list', 'answer', 'wait')][string]$Action = 'list',
    [string]$Run, [string]$Agent, [string]$Item, [string]$Question, [string[]]$Options = @(), [string]$Recommend, [string]$Contracts,
    [string]$Id, [string]$Answer, [string]$By = 'owner', [int]$MaxMinutes = 50, [switch]$Pending, [switch]$Json,
    [ValidateSet('decision', 'envfix')][string]$Kind = 'decision',
    [string]$Task, [string[]]$Mrs = @(), [string]$Commit, [string]$ParentId, [string]$Rationale)
  $dir = Get-KitPath decisions -Create

  $get = { param($i) $f = Join-Path $dir "$i.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
  $save = {
    param($o)
    $f = Join-Path $dir "$($o.id).json"
    Invoke-KitLocked $f { Write-KitAtomic $f ($o | ConvertTo-Json -Depth 5) }
    Write-KitLog decisions-log $o.status ($o | Select-Object * -ExcludeProperty at)   # at = this line's time; the pending line's is the ask's
  }
  $note = { param($file, $text) if ($file -and (Test-Path (Split-Path $file))) { Add-Content -LiteralPath $file "`n$text" -Encoding utf8 } }
  switch ($Action) {
    'ask' {
      if (-not ($Agent -and $Question)) { 'usage: decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options "A: ..","B: .." [-Recommend A] [-Contracts <file>]'; exit 2 }
      $opts = @($Options | ForEach-Object { "$_" -split ',(?=\s*[A-Za-z0-9]+\s*:)' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      $mrsClean = @(Split-KitList $Mrs | ForEach-Object { ConvertTo-MrRef $_ })
      $resolvedTask = if ($Task) { NormTask $Task } elseif ($Item -and (NormTask $Item)) { NormTask $Item } else { '' }
      $o = [ordered]@{ id = "$(if ($Kind -eq 'envfix') { 'e' } else { 'd' })-$(Get-Date -Format yyyyMMddHHmmss)-$($Agent.ToLower() -replace '[^\w-]', '')-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
        kind = $Kind; run = $Run; agent = $Agent; item = $Item; question = $Question
        options = $opts; recommend = $Recommend; contracts = $Contracts; status = 'pending'; at = (Get-Date).ToString('s')
        task = $resolvedTask; mrs = $mrsClean; commit = $Commit; parentId = $ParentId }
      & $save ([pscustomobject]$o)
      if ($resolvedTask) {
        Update-KitTracking { param($t) if ($t.tasks[$resolvedTask]) { $t.tasks[$resolvedTask].decisions = @(@($t.tasks[$resolvedTask].decisions) + $o.id | Select-Object -Unique) } }
      }
      if ($Kind -eq 'envfix') {
        & $note $Contracts "## ENV-FIX NEEDED $($o.id) ($Agent, item $Item)$(if ($resolvedTask) { " [Task: $resolvedTask]" })`n$Question`nDone: pending (the coordinator appends it below)"
        "ENV-FIX $($o.id) pending: the coordinator fixes the local env; item $Item waits. Wait: orch.ps1 decide wait -Id $($o.id)"; return
      }
      $null = Test-KitProse -Kind decision-request -Text ("$Question`nOptions:`n$(($opts | ForEach-Object { "- $_" }) -join "`n")`nRecommended: $Recommend")
      & $note $Contracts ("## DECISION NEEDED $($o.id) ($Agent, item $Item)$(if ($resolvedTask) { " [Task: $resolvedTask]" })$(if ($mrsClean.Count) { " [MRs: $($mrsClean -join ', ')]" })`n$Question`nOptions:`n$(($opts | ForEach-Object { "- $_" }) -join "`n")`nRecommended: $(if ($Recommend) { $Recommend } else { 'none' })`nAnswer: pending (the coordinator appends it below)")
      "DECISION $($o.id) pending: item $Item stops (needs decision); continue your other items. Wait: orch.ps1 decide wait -Id $($o.id)"
    }
    'list' {
      $all = @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not $Pending -or $_.status -eq 'pending' })
      if ($Json) { ConvertTo-Json @($all) -Depth 5; return }
      foreach ($d in $all) { "$($d.status.ToUpper()) $($d.id) $($d.run)/$($d.agent) item $($d.item)$(if ($d.task) { " [Task: $($d.task)]" }): $($d.question) | options: $(@($d.options) -join ' ; ')$(if ($d.recommend) { " | recommended: $($d.recommend)" })$(if ($d.answer) { " | answer: $($d.answer)" })$(if ($d.rationale) { " | rationale: $($d.rationale)" })" }
      if (-not $all.Count) { 'no decisions' }
    }
    'answer' {
      $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
      if (-not $Answer) { 'usage: decide answer -Id <id> -Answer "<words>"'; exit 2 }
      $o.status = 'answered'; $o | Add-Member -Force answer $Answer; $o | Add-Member -Force by $By; $o | Add-Member -Force answeredAt (Get-Date).ToString('s')
      if ($Rationale) { $o | Add-Member -Force rationale $Rationale }
      & $save $o
      & $note $o.contracts "DECISION $Id ANSWERED by $($By): $Answer$(if ($Rationale) { " (Rationale: $Rationale)" })"
      "answered $Id ($($o.agent), item $($o.item)): $Answer"
    }
    'wait' {
      $until = (Get-Date).AddMinutes($MaxMinutes)
      while ($true) {
        $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
        if ($o.status -eq 'answered') { "ANSWERED $Id`: $($o.answer)$(if ($o.rationale) { " [Rationale: $($o.rationale)]" })"; return }
        if ((Get-Date) -ge $until) { "PENDING $Id (no answer within $MaxMinutes min; wait again)"; exit 1 }
        Wait-KitPoll 30
      }
    }
  }
}

# ---- health: SessionStart hook; no network
function Invoke-Health {
param([switch]$Flow, [switch]$Fetch)
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$py = if (Get-Command (Get-Python) -ErrorAction SilentlyContinue) { Get-Python }
if ($Flow -or $Fetch) {
  if ($Fetch -and (Test-Path (Join-Path $kit '.git'))) {
    git -C $kit fetch --quiet 2>$null
    # extras the config needs, installed in the background (this hook is async): a failure is one hook-error line (orch.ps1 audit)
    if ($py) { $sync = & $py -X utf8 $KitCmd.kittool extra sync 2>&1; if ($LASTEXITCODE) { Write-KitLog calls hook-error @{ error = "extra sync failed: $($sync -join ' ')" } } }
  }
  if ($Flow -and $py) { & $py -X utf8 $KitCmd.kittool flow $kit | Out-Null }
  exit 0
}

$msgs = @()
if (Test-Path (Join-Path $kit '.git')) {
  try { & $KitCmd.orch setup -Exclude -Quiet | Out-Null } catch {}
  $st = @(git -C $kit status --porcelain=v1 --branch 2>$null)
  $head = [string]($st | Select-Object -First 1)
  $changes = @($st | Select-Object -Skip 1).Count
  $parts = @()
  if ($changes) { $parts += "$changes uncommitted change(s) (commit + push them, or list org-only paths in kit.local.json localOnly)" }
  if ($head -match '\.\.\.(?<up>\S+)') {
    $up = $Matches.up
    if ($head -match 'behind (?<b>\d+)') { $parts += "$($Matches.b) commit(s) behind $up (git -C $kit pull --rebase once no agents run)" }
    if ($head -match 'ahead (?<a>\d+)') { $parts += "$($Matches.a) commit(s) ahead of $up (push them)" }
  }
  if ((git -C $kit config core.hooksPath 2>$null) -ne '.githooks') { $parts += "pre-push gate off (run: pwsh -File $($KitCmd.orch) setup)" }
  $pf = Get-KitPath kit-protect
  $st = if (Test-Path $pf) { @(Get-Content $pf | Where-Object { $_ }) }; $bad = if (-not $st) { 'unchecked' } else { @($st | Where-Object { $_ -notmatch '^\S+ (ok|set|skip)' }) }
  if ($bad) { $parts += "origin main / extras protection: $($bad -join ', ') (run: orch.ps1 setup)" }
  if ($parts) { $msgs += "kit: " + ($parts -join '; ') }
} else {
  $msgs += "kit: $kit is not a git clone of the kit repo (install: README Install)"
}
# workflows die with their session
$hook = $null
if ([Console]::IsInputRedirected) { try { $hook = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch {} }
if (-not $hook -or $hook.source -ne 'compact') {
  # a crash or power loss: board entries and launch records whose process is gone are marked crashed
  $crashed = @(Set-KitBoardCrashed)
  foreach ($s in @(Get-StoppedRuns -Hours 72 | Where-Object { -not $_.paused })) { foreach ($x in @($s.file, $s.selfFile) | Where-Object { $_ }) { try { Invoke-KitLocked $x { $j = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json; if (-not $j.crashed) { $j | Add-Member -Force NoteProperty crashed (Get-Date).ToString('o'); Write-KitAtomic $x ($j | ConvertTo-Json -Depth 30) } } } catch {} } }
  $stopped = @(& $KitCmd.orch launch -List -Brief -Hours 72 2>$null)
  if ($stopped.Count) { $msgs += "paused/crashed runs: $($stopped.Count) ($($stopped -join '; '))$(if ($crashed.Count) { "; $($crashed.Count) board agent(s) marked crashed" }). Do: & '$($KitCmd.orch)' resume -All (network first; a brief per agent from its checkpoint; orchestrate E3); finished ones: orch.ps1 launch -Done -RunId <id>. No heartbeat runs in this session: arm one (orchestrate E1: CronCreate */10 * * * *, orch.ps1 supervise -AutoFix -Brief)" }
}
if ($py) {
  $lint =& $py -X utf8 $KitCmd.kittool lint $kit --summary --warn --no-flow 2>$null
  if ($lint) { $msgs += ($lint -join ' ') }
  & $py -X utf8 $KitCmd.kittool port --check 2>$null | ForEach-Object { $msgs += $_ }   # silent without the ports extra
  & $py -X utf8 $KitCmd.kittool extra check 2>$null | ForEach-Object { $msgs += $_ }   # config that needs an extra not installed
}
if ($due = Get-KitRetroDue) { $msgs += "Kit learning: $due. Run /tidy to turn them into lessons and rule updates." }
$msgs += @(Invoke-KitHooks Get-KitHealthLines)   # extra kit-admin: the weekly kitty audit nudge
if ($msgs) {
  $text = ($msgs -join ' | ') + ' (orchestrate Events)'
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
}

# ---- retro due: one rule for health, supervise and report
function Get-KitRetroSince { $m = Get-KitPath last-retro; if (Test-Path $m) { [datetime](Get-Content $m -Raw).Trim() } else { [datetime]::MinValue } }
# 15+ signals and guard blocks since the last retro, or any signal once a run finished
function Get-KitRetroDue([switch]$RunFinished) {
  $since = Get-KitRetroSince
  $n = @(Get-Content (Get-KitPath signals) -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '"kind":"retired"' -and $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Read-KitLog guard $since | Where-Object event -eq 'deny').Count
  if ($n + $g -ge 15 -or ($RunFinished -and $n)) { "$n signal(s) + $g guard block(s) since the last retro" }
}

# ---- the kit origin's main and extras: force push and deletion off, direct push on (host verb branch.protect; never product repos)
function Set-KitOriginProtection {
  $kit = $KitConf.Kit; $gl, $gh = $env:GITLAB_HOST, $env:GH_HOST
  $lines = if ("$(git -C $kit remote get-url origin 2>$null)" -notmatch '^(?:\w+://)?(?:[^@/]+@)?(?<h>[^/:\\]{2,})(?::\d+)?[:/](?<r>[^:\\]+?)(?:\.git)?/?$') { 'origin failed: no origin remote with a host' } else {
    $h, $repo, $t = $Matches.h, $Matches.r, (Get-HostKind $Matches.h)
    if ($t -eq 'gitlab') { $env:GITLAB_HOST = $h } elseif ($t -eq 'github') { $env:GH_HOST = $h }
    foreach ($b in 'main', 'extras') {
      if (-not (git -C $kit rev-parse --verify -q "refs/remotes/origin/$b" 2>$null)) { "$b failed: origin/$b not fetched (git fetch origin)"; continue }
      $r = try { Invoke-HostVerb 'branch.protect' @{ type = $t; repo = $repo; branch = $b } -NoMemo } catch { "failed: $_" }
      "$b $(if ($r) { $r } else { "failed: set it by hand on $h/$repo (force push off, deletion off, direct push on)" })"
    }
  }
  $env:GITLAB_HOST, $env:GH_HOST = $gl, $gh
  Set-Content (Get-KitPath kit-protect -Create) $lines
  $lines | ForEach-Object { "protect: $_" }
}
# ---- setup: install / repair (idempotent)
function Invoke-Setup {
param([switch]$Exclude, [switch]$Quiet, [switch]$WriteLocal)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
function Say($s) { if (-not $Quiet) { $s } }

function Set-Memory {
  try { $cfg = Get-Content $KitConf.ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cfg = $null }
  if ($cfg -and $cfg.memory -and $cfg.memory.keepDefault) { return $null }
  $gd = "$(git -C $kit rev-parse --path-format=absolute --git-dir 2>$null)".Trim(); $cd = "$(git -C $kit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($gd -and $cd -and $gd -ne $cd) { return 'memory: a linked kit worktree - autoMemoryDirectory is set only in the main clone' }
  $dir = Join-Path $kit 'memory'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $want = ($dir -replace '\\', '/')
  $sl = Join-Path $kit 'settings.local.json'
  $s = if (Test-Path $sl) { try { Get-Content $sl -Raw | ConvertFrom-Json -AsHashtable } catch { $null } } else { @{} }
  if ($null -eq $s) { return "settings.local.json is not valid JSON: autoMemoryDirectory not set (fix the file, then re-run)" }
  if ($s['autoMemoryDirectory'] -eq $want) { return $null }
  $s['autoMemoryDirectory'] = $want
  [IO.File]::WriteAllText($sl, ($s | ConvertTo-Json -Depth 20))
  "memory: autoMemoryDirectory = $want (settings.local.json; from the next session)"
}

function Update-Exclude {
  if (-not (Test-Path (Join-Path $kit '.git'))) { return 'not a git clone: no .git/info/exclude' }
  $ex = "$(git -C $kit rev-parse --path-format=absolute --git-path info/exclude 2>$null)".Trim()
  if (-not $ex) { return 'git rev-parse --git-path info/exclude failed: excludes not written' }
  New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
  $paths = @()
  $kl = $KitConf.ConfigFile
  if (Test-Path $kl) { try { $paths = @((Get-Content $kl -Raw | ConvertFrom-Json).localOnly | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').Trim('/') }) } catch { return "kit.local.json is not valid JSON: $_" } }
  $begin = '# >>> kit localOnly (managed by skills/orchestrate/orch.ps1 setup; edit kit.local.json "localOnly" instead)'
  $end = '# <<< kit localOnly'
  $old = if (Test-Path $ex) { Get-Content $ex -Raw } else { '' }
  $rest = [regex]::Replace($old, '(?s)\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?', "`n").TrimEnd()
  $block = if ($paths.Count) { "$begin`n" + (($paths | ForEach-Object { "/$_" }) -join "`n") + "`n$end" } else { '' }
  $new = (@($rest, $block) | Where-Object { $_ }) -join "`n`n"
  $new = if ($new) { $new + "`n" } else { '' }
  if ($new -ne $old) { New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null; [IO.File]::WriteAllText($ex, $new); "excluded $($paths.Count) localOnly path(s) in $ex" }
}

if ($Exclude) { $r = Update-Exclude; if ($r) { Say $r }; $m = Set-Memory; if ($m) { Say $m }; exit 0 }

if (-not (Test-Path (Join-Path $kit '.git'))) { Write-Warning "$kit is not a git clone: install per README ""Install""" }
else {
  if ((git -C $kit config core.hooksPath) -ne '.githooks') { git -C $kit config core.hooksPath .githooks; Say 'git: core.hooksPath = .githooks (pre-commit, pre-push, post-merge on)' }
  Set-KitOriginProtection | Where-Object { $_ -notmatch ' ok$' } | ForEach-Object { Say $_ }
  $r = Update-Exclude; if ($r) { Say $r }
}
$m = Set-Memory; if ($m) { Say $m }
foreach ($n in 'work', 'cache', 'logs') { $null = Get-KitPath $n -Create }
Say "runtime: $(Get-KitPath runtime) (work/ cache/ logs/; disposable)"
$ex = Get-Content (Join-Path $kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json
$want = [ordered]@{ 'skills/dev-kit/kit.local.json' = ($ex | Select-Object -Property * -ExcludeProperty localFiles, _paths, _manifest, _doc) }
foreach ($p in $ex.localFiles.PSObject.Properties) { $want[$p.Name] = $p.Value }
foreach ($k in $want.Keys) {
  $f = Join-Path $kit $k; if (Test-Path $f) { continue }
  if ($WriteLocal) { $want[$k] | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding utf8; Say "wrote $k from kit.example.json: fill in the <...> values (git-ignored)" }
  else { Say "to do: $k is missing (setup -WriteLocal writes it from kit.example.json, then fill it in)" }
}
if (Get-Command (Get-Python) -ErrorAction SilentlyContinue) { foreach ($x in @(& (Get-Python) -X utf8 $KitCmd.kittool extra sync 2>&1)) { Say $x } }   # extras the config needs
Say 'kit ready.'
}

# ---- guard-sendmessage: a send RESUMES a second copy on the same worktree
function Invoke-GuardSendMessage {
$ErrorActionPreference = 'SilentlyContinue'
$in = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() | ConvertFrom-Json }  # by hand: no stdin wait
$to = "$($in.tool_input.to)".Trim()
if ($to -notmatch '^(?<id>a[0-9a-f]{12,})$') { exit 0 }
$id = $Matches.id
$meta = Get-ChildItem (Join-Path $HOME ".claude/projects/*/*/subagents/workflows/*/agent-$id.meta.json") | Select-Object -First 1
if (-not $meta) { exit 0 }
$label = (Get-Content $meta.FullName -Raw | ConvertFrom-Json).description
$why = "Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you."
[Console]::Error.WriteLine($why)
@{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
exit 0
}

# SessionStart hooks never surface an error: one warning line, the detail in the hook log
function Write-KitHookError([string]$Verb, $Err) { "kit: $Verb failed ($($Err.Exception.Message)); see orch.ps1 audit -Since 1h"; exit 0 }
if ($MyInvocation.InvocationName -ne '.') {  # dot-sourced (tests): functions only
  trap { if ($__verb -in 'health', 'cleanup') { Write-KitHookError $__verb $_ } else { break } }
  $KitVerbOnError = { param($e) if ($__verb -in 'health', 'cleanup') { Write-KitHookError $__verb $e } }   # Invoke-KitVerb catches first
  if ($__verb -in '-h', '--help', 'help', '-?') { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
  switch ($__verb) {
    'board' {
      if ($__rest[0] -in 'dispute', 'disputes') { $null = Assert-KitExtra Invoke-BoardDispute 'board dispute' 'board-disputes'; Invoke-KitVerb Invoke-BoardDispute $__rest }
      else { Invoke-KitVerb Invoke-Board $__rest }
    }
    'learn' { Invoke-KitVerb Invoke-Learn $__rest }
    'launch' { Invoke-KitVerb Invoke-Launch $__rest }
    'track' { Invoke-KitVerb Invoke-Track $__rest }
    'supervise' { Invoke-KitVerb Invoke-Supervise $__rest }
    'report' { Invoke-KitVerb Invoke-Report $__rest }
    'audit' { Invoke-KitVerb Invoke-Audit $__rest }
    'bugbrief' { Invoke-KitVerb Invoke-BugBrief $__rest }
    'cleanup' { Invoke-KitVerb Invoke-Cleanup $__rest }
    'deploy' { $null = Assert-KitExtra Invoke-Deploy 'orch.ps1 deploy' 'deploys'; Invoke-KitVerb Invoke-Deploy $__rest }
    'decide' { Invoke-KitVerb Invoke-Decide $__rest }
    'recover' { Invoke-KitVerb Invoke-Recover $__rest }
    'pause' { Invoke-KitVerb Invoke-Pause $__rest }
    'resume' { Invoke-KitVerb Invoke-Resume $__rest }
    'program' { Invoke-KitVerb Invoke-Program $__rest }
    'budget' { Invoke-KitVerb Invoke-Budget $__rest }
    'health' { Invoke-KitVerb Invoke-Health $__rest }
    'setup' { Invoke-KitVerb Invoke-Setup $__rest }
    'guard-sendmessage' { Invoke-KitVerb Invoke-GuardSendMessage $__rest }
    'prepush' { $null = Assert-KitExtra Invoke-PrePush 'orch.ps1 prepush' 'kit-admin'; Invoke-KitVerb Invoke-PrePush $__rest }   # the kit's own git hooks
    'precommit' { $null = Assert-KitExtra Invoke-PreCommit 'orch.ps1 precommit' 'kit-admin'; Invoke-KitVerb Invoke-PreCommit $__rest }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }
  }
}
