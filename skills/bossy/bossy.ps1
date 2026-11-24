<#
bossy.ps1: the coordinator + kit commands (bossy SKILL.md). pwsh 7: & <kit>/skills/bossy/bossy.ps1 <verb> [args]
  board join|beat|check|leave|show|msg|inbox -Agent -Run [-Claims] [-Session] [-Tool] [-Kind] [-Ref]   agent board, messages;
    check -Decision continue|handoff -Reason <why> -Ctx <key>: answers a CONTEXT-CHECK (board beat, the Claude Code hook)
  learn -Skill -Kind -Text | -Read [-Phase -Project] | -Show (-When -Do -Why | -Bump | -Fixed | -Trim | -Stats | -History)   signals, lessons
  launch -RunId -Script -ArgsJson | -Self -Script -Run -ArgsFile -Fnv [-Plan] | -Check -ArgsFile (buildy item tasks) | -Done -RunId|-Run | -List [-Brief]
  recover [-RunId <id> | -Run <runs>] [-Hours 24] [-MaxSeconds 150] [-Everyone]   stopped runs: state, resume brief, exact resume call
  pause -Run <run> | -All [-Reason] [-Wait <min>] [-Everyone] | -Status · resume -Run <run> | -All [-Wait <min>] [-Hours 24] [-MaxSeconds 150] [-Everyone]
    stop at checkpoints; paused / crashed runs back; another live coordinator's runs only with -Everyone
  program set|get|list -Program <name> [-Key <k>] [-Value <v>]   the coordinator's program state in .state
  param show|history|learn|pin|unpin|freeze|reset|approve [<key>] [<value>] [-Context] [-Json]   learned parameters
  budget [-Model] [-Plan 'role/model:n,..'] [-Run <run>] [-Usage] [-Json]   agent budget, run cap + spend; -Usage: page usage
  usage -Context [-Agent <id> | -Run <run> | -Type <role>] [-Since 24h|7d] [-Json] [-Refresh]   context per agent: start, peak, sources, waste
  track add -Task -Mrs [-MergeAfter] [-Discover] [-HoldPromotion] | run [-Detail] | show [-Task] | ignore -Mrs -Reason   task <-> MRs; promoted when all merged and every launched area delivered (add: at once; -HoldPromotion '' releases)
    | rollup -Task <parent> [-From <brief dir>]   parent's delivery + triage sections, subtask Items checklists
    | rollup -Status (-Task <parent> | -All) [-Apply]   parent status = its least advanced open subtask (dry run unless -Apply)
    | forget-item -Task -Item <codes>   items removed from a task's checklist on purpose: never written back
    | remove -Task -Mrs [-Reason]   a wrongly attached MR off the task (kept in its removed list; add -Mrs re-attaches)
    | route -From <failed / [Bug] task> -To <task | run> [-Items <check ids>] [-Mrs]   fixed in that wave: its new MRs join, all merged -> promoted
  supervise [-AutoFix] [-Brief] [-Json] [-Takeover] [-Session] | -Ack '<flag start>' [-Reason]   heartbeat
  status [-Watch [-Seconds 30]] [-Json] [-Session]   one row per agent / run: ACTIVE WAITING FINISHED STUCK STOPPED, then
    one row per resource: holder, since, last seen, last used (files only)
  release -Agent <id>[,<id>] [-Reason]   every lease of those agents (lanes, env + layers, GPU, builds, tabs), logged in .state/leases.jsonl
  shells [-Json]   agents' background shells: owner, state, CPU / IO / output progress, last output line; recently ended ones (read-only)
  stats [-Reset]   the dashboard's statistics-only files; -Reset moves them to .state/forgotten/stats-reset-<date>/ (charts start empty)
  storage [-Drive] [-Since 24h|7d] [-Folders] [-Scan]   free space per drive, folder sizes, rescues (.state/storage)
  tidy prep [-DryRun] [-Json] | done -At <time>   /tidy: digest + upkeep without an LLM, then the retro stamp
  report -Run <id> [-Detail] [-Stopped] · bugbrief -Task [-Agent B-<task>] [-Repos <from its MRs>] [-Mandate] [-Only <ids>] [-Skip <id>=<why>; ...] [-Complex] · cleanup [-DryRun] [-IfDue] [-Quiet] [-WorktreesOnly] [-Detail]
  audit [-Run <run | wf id>] [-Agent] [-Task] [-Since 2h|3d|<time>] [-Last N] [-All] [-Json]   one timeline: kitlog + journal + board
  deploy plan|request|record|intest ... · decide ask|list|answer|wait|record|check|publish|rules ...   deploy batch; decision pauses; a person's gate word; a task's Decisions checklist; standing rules
  debate start -Item -Question -Options "A: ..","B: .." [-Run] [-Why] [-Owner] | brief -File -Side A|B|revy -Round <n> | ask -File   a written debate (1 per run; rechy kind debate), its table + decide ask
  heartbeat [install|uninstall|status|tick] · health · setup [-Exclude] [-WriteLocal] [-Allow] [-BrowserPolicy [-Undo|-Clean]] · guard-sendmessage · prepush · precommit   hooks and install
Adapters: skills/bossy/adapters/*.ps1, loaded below; their hooks: Invoke-KitHooks.
Exit codes: 0 ok · 1 problem / not answered / blocked · 2 usage · 3 board beat: unknown session (join first).
Sections: L40 init · L51 board · L252 budget · L282 launch · L525 recover · L612 pause · L623 resume · L690 program · L728 param ·
  L734 track · L1122 supervise · L1464 report · L1544 audit · L1604 storage · L1607 bugbrief · L1609 cleanup · L1696 learn ·
  L1734 decide · L1903 debate · L1947 health · L2015 setup · L2110 guard-sendmessage
#>
#Requires -Version 7
# ---- init: arguments, lib.ps1, adapters, helpers
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'crafty/lib.ps1')
# a broken adapter must not take every verb and hook down
foreach ($adapter in @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue)) { try { . $adapter.FullName } catch { [Console]::Error.WriteLine("adapter $($adapter.Name): $_") } }
# adapter hooks <Prefix>* (adapters/*.ps1) see the caller's variables
function Invoke-KitHooks([string]$Prefix, [hashtable]$Arguments = @{}) {
  foreach ($hook in @(Get-Command "$Prefix*" -CommandType Function -ErrorAction SilentlyContinue)) { if ($kitSweep) { Start-KitSweepPhase $kitSweep $hook.Name }; & $hook @Arguments }
}

# ---- board: who is alive; one writer per worktree
# $Change returns $null = unchanged
function Update-BoardEntry([string]$Path, [scriptblock]$Change) {
  Invoke-KitLocked $Path { if (Test-Path $Path) { $e0 = Get-Content $Path -Raw | ConvertFrom-Json; $n0 = & $Change $e0; if ($null -ne $n0) { Write-KitState $Path $n0 } } }
}
# process gone (crash, reboot): left + crashed
function Set-KitBoardCrashed {
  foreach ($e in @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -eq $false })) {
    Update-BoardEntry $e.file { param($x) $x.status = 'left'; $x | Add-Member -Force NoteProperty crashed (Get-KitStamp); $x }; $e
  }
}
function Get-KitCheckpoint([string]$Agent, [string]$Run = '') { $f = Get-KitCheckpointFile $Agent $Run; if (Test-Path -LiteralPath $f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch {} } }
function Get-KitResumeBriefFile([string]$Agent, [string]$Run = '') { (Get-KitCheckpointFile $Agent $Run) -replace '\.json$', '-brief.md' }   # resume.json -> resume-brief.md
function Get-KitActivePause([string]$Run) { @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($_.run -eq $Run -or ($_.run -eq '*' -and $Run -notin @($_.released))) } | Sort-Object { [datetime]$_.at })[-1] }
# N3 agent ids <role>-<nn>: one counter per role in .state naming.json (kitbag_naming.py's file, same lock), never reused (an old
# holder's inbox); $Legacy (the old <role>-<run> form) -> aliases, read by msg -To for one version
function New-KitAgentId([string]$Type, [string]$Legacy = '') { $f = Get-KitPath naming -Create
  $live = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' } | ForEach-Object { "$($_.agent)" })   # never a live id
  Invoke-KitLocked $f { $x = Read-KitState $f; if ($x -isnot [Collections.IDictionary]) { $x = @{} }; $k = "agent:$($Type.ToLower())"; do { $x[$k] = 1 + [int]$x[$k]; $id = '{0}-{1:00}' -f $Type.ToLower(), $x[$k] } while ($id -in $live -and $x[$k] -lt 999)
    if ($Legacy) { if ($x.aliases -isnot [Collections.IDictionary]) { $x.aliases = @{} }; if (-not $x.aliases[$Legacy]) { $x.aliases[$Legacy] = $id } }; Write-KitState $f $x; $id } }   # the run's first of its role keeps the old name
function Resolve-KitAgentAlias([string]$Id) { $a = (Read-KitState (Get-KitPath naming)).aliases; if ($a -is [Collections.IDictionary] -and $a[$Id]) { $a[$Id] } else { $Id } }
function Invoke-Board {
param(
  [Parameter(Position = 0)][ValidateSet('join', 'beat', 'show', 'list', 'check', 'leave', 'msg', 'inbox', 'help')][string]$Action = 'show',
  [string]$Agent, [string]$Area = '', [string[]]$Items = @(), [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree, [switch]$Resume, [string]$Type = '',
  [string]$To, [string]$Text, [switch]$All, [string]$Model = '', [string]$Tool = '', [string]$Handoff = '', [double]$Wait = 1.5, [switch]$Force, [string]$Kind = 'note', [string]$Ref = '',
  [ValidateSet('', 'continue', 'handoff')][string]$Decision = '', [string]$Reason = '', [string]$Ctx = ''
)
if ($Action -eq 'help') { (Get-Content $PSCommandPath -TotalCount 6 | Select-String -Pattern '^\s+(board |check -Decision)').Line; return }   # retro 1709: board help failed validation
$dir = Get-KitPath board -Create
$staleMin = [double](Get-KitParam 'idle.beatMinutes')
function All { Read-KitJsonFiles $dir }
function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
# plain claims only lowercased: GetFullPath mangles them
function Norm($p) { if (-not $p) { return }; if ($p -match '[\\/]|^[A-Za-z]:') { [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } else { $p.ToLower() } }
# "86abc F2, X1" -> 86abc X1
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
    $quiet = ((Get-Date) - [datetime]$o.beat).TotalMinutes -ge 3 -and -not ($o.pid -and (Test-KitPid $o.pid $o.pidStart))   # join's takeover rule: a stopped agent's row
    if ($o.agent -eq $me.agent -and (-not $me.run -or $o.run -eq $me.run) -and $quiet) { "STALE: $($o.agent) in session $($o.session) is quiet since $(([datetime]$o.beat).ToString('HH:mm')): not a duplicate, continue" }
    elseif ($o.agent -eq $me.agent -and (-not $me.run -or $o.run -eq $me.run)) { "DUPLICATE: agent $($o.agent) is also active in session $($o.session) (joined $(([datetime]$o.joined).ToString('HH:mm'))). The newer session must stop without writing." }
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
  # N3 (owner 2026-11-23): a run line '<run id> · <KEY> <short title>', its agents '<role>-<nn> · <area>'
  foreach ($g in @($act | Group-Object { "$($_.run)" } | Sort-Object Name)) { if ($g.Name) { "  run $(Get-KitRunTitle $g.Name)" }
  $g.Group | Sort-Object agent | ForEach-Object { $task = "$($_.items)"; $cl = (@($_.worktrees | Where-Object { $_ } | ForEach-Object { Split-Path "$_" -Leaf }) -join ',')
    '    {0,-24} {1,-8} {2,-30} {3,-22} {4} | beat {5}{6}' -f (Get-KitAgentLabel ([pscustomobject]@{ n = $_.agent; ar = $_.area; sub = $_.type })), "$(if ($_.holderPid) { "s$($_.holderPid)" })", $task.Substring(0, [math]::Min(30, $task.Length)), $cl.Substring(0, [math]::Min(22, $cl.Length)), $_.status, ([datetime]$_.beat).ToString('HH:mm'), $(if ($_.budget) { " | spend $([int]($_.spend / 1000))k/$([int]($_.budget / 1000))k" }) } }
}

switch ($Action) {
  'join' {
    if (-not ($Agent -or $Type)) { 'usage: bossy.ps1 board join -Type <role> [-Run] [-Area] [-Items] [-Claims] (-Agent <id>: legacy)'; exit 2 }
    $notes = @()
    # N3: <role>-<nn>, given here only; the same run + area keeps it
    $auto = $Type -and $Type -ne 'coordinator' -and $Agent -in @($null, '', $Type)   # one coordinator per session: its role is its name
    # a legacy row (area id or <type>-<run>) keeps its id
    if ($auto) { $Agent = @(All | Where-Object { $Run -and $Area -and $_.type -eq $Type -and $_.run -eq $Run -and $_.area -eq $Area -and ($_.agent -match '^[a-z]+-\d{2,}$' -or $_.agent -in @($Area, "$Type-$Run")) } | Sort-Object { [datetime]$_.joined })[-1].agent
      if (-not $Agent) { $Agent = New-KitAgentId $Type $(if ($Run) { "$Type-$Run" }) }; $notes += "RUN-ID: you are $Agent (checkpoint, inbox: -Agent $Agent)" }
    if (-not $Agent) { $Agent = $Type }
    $now = Get-Date
    $myClaims = @(Split-KitList $Worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $same = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.status -ne 'left' })
    # no claims, no -Session: two spawns of one id -> PARALLEL
    $rejoin = $same | Where-Object { -not $Resume -and ($myClaims.Count -or ($Session -and $_.session -eq $Session)) -and ($now - [datetime]$_.beat).TotalMinutes -lt 2 -and ((@(Split-KitList $_.worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique) -join '|') -eq ($myClaims -join '|')) } |
      Sort-Object { [datetime]$_.joined } -Descending | Select-Object -First 1
    $peer = @($same | Where-Object { -not ($Resume -or $rejoin) -and (Test-KitHolder $_) -and (($now - [datetime]$_.beat).TotalMinutes -lt $staleMin -or ($_.transcript -and ($now - [IO.File]::GetLastWriteTime($_.transcript)).TotalMinutes -lt $staleMin / 6)) })   # or a fresh transcript
    # one id in two live runs shares leases (retro)
    $other = @(All | Where-Object { -not $auto -and -not $Resume -and $Run -and $_.run -and (-not $Session -or $_.session -ne $Session) -and $Type -ne 'coordinator' -and $_.agent -eq $Agent -and "$($_.run)" -ne "$Run" -and $_.status -ne 'left' -and (Test-KitHolder $_) -and ($now - [datetime]$_.beat).TotalMinutes -lt $staleMin })
    if ($other) { "REFUSED: agent id $Agent is live in run $($other[0].run): give this agent another id"; exit 2 }
    if ($peer) { $b = $Agent; $n = 2; if ($auto) { $Agent = New-KitAgentId $Type } else { while (@(Active | Where-Object agent -eq "$b-$n").Count) { $n++ }; $Agent = "$b-$n" }; $same = @(); $notes += "PARALLEL: $b runs in session $($peer[0].session): you are $Agent" }
    if ($rejoin) { $tok = $rejoin.session; $joined = $rejoin.joined; $notes += "REJOIN: same agent, run and claims within 2 min - reusing session $tok" }
    else { $tok = "$($Agent -replace '[\\/:*?"<>|\s]', '-')-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $joined = (Get-KitStamp stored $now) }
    # the dead pid is the join shell's: not alone
    foreach ($o in @($same | Where-Object { $_.session -ne $tok })) {
      $alive = $o.pid -and (Test-KitPid $o.pid $o.pidStart)
      $age = ($now - [datetime]$o.beat).TotalMinutes
      $shared = @(@(Split-KitList $o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -and $_ -in $myClaims })
      $holderLive = Test-KitHolder $o   # one session's agents share its process: a live holder loses its row only to -Resume
      $why = if ($holderLive -eq $false) { "its session process $($o.holderPid) is gone (crash or restart)" } elseif (-not $alive -and $age -ge 3 -and $null -eq $holderLive) { "no heartbeat for $([int]$age) min" } elseif ($Resume -and ($shared.Count -or -not $myClaims.Count)) { "-Resume$(if ($shared.Count) { " on $($shared -join ', ')" })" } else { $null }
      if (-not $why) { if ($age -ge 3) { $notes += "QUIET: session $($o.session) of a live session process, last beat $(([datetime]$o.beat).ToString('HH:mm')): kept (a crashed one: join -Resume)" }; continue }
      try {
        Update-BoardEntry $o.file { param($j) $j.status = 'left'; $j | Add-Member -Force NoteProperty takenOverBy $tok; $j | Add-Member -Force NoteProperty takenOverAt (Get-KitStamp stored $now); $j }
        $notes += "TAKEOVER: replaced session $($o.session) ($why; joined $(([datetime]$o.joined).ToString('HH:mm')), last beat $(([datetime]$o.beat).ToString('HH:mm')))"
      } catch { $notes += "could not take over session $($o.session): $_" }
    }
    $me = [ordered]@{ agent = $Agent; type = $(if ($Type) { $Type } else { "$env:CLAUDE_AGENT_TYPE" }); session = $tok; run = $Run; area = $Area; items = (@($Items) -join ','); worktrees = @(Split-KitList $Worktrees); contracts = $Contracts
                      status = 'working'; joined = $joined; beat = (Get-KitStamp stored $now); pid = $PID; pidStart = (Get-KitPidStart $PID) } + (Get-KitHolder)
    $bg = Get-KitBudget -Tool $Tool -Model $Model -Role $me.type; $me += [ordered]@{ tool = $bg.tool; model = $bg.model; budget = $bg.budget; handoff = $bg.handoff; capBy = $bg.capBy; spend = 0 }
    $mf = Join-Path $dir "$tok.json"; Invoke-KitLocked $mf { Write-KitState $mf $me }
    $ho = @(Get-KitHandoffs 1e6 $tok | Where-Object { ($_.agent -eq $Agent -and "$($_.run)" -eq "$Run") -or ("$($_.run)" -ne "$Run" -and (Test-KitRunLineage $_ ([pscustomobject]$me))) } | Sort-Object { [datetime]$_.beat } -Descending)[0]
    if ($ho) { Update-BoardEntry $ho.file { param($x) $x | Add-Member -Force NoteProperty continuedBy $tok; $x }; "CONTINUE: the previous $($ho.agent) ($($ho.run)) handed off at its budget: read its resume brief $($ho.handoffBrief) first" }
    $ck = Get-KitCheckpoint $Agent $Run
    if ($ck -and -not $ck.done -and $ck.next -ne 'none' -and (-not $Run -or -not $ck.run -or $ck.run -eq $Run)) {
      $rb = Get-KitResumeBriefFile $Agent $Run
      "CHECKPOINT: start at step '$($ck.next)': $(if (Test-Path -LiteralPath $rb) { "$rb (bossy.ps1 resume verified it), " })$((Get-KitCheckpointFile $Agent $Run) -replace 'json$', 'md'). Done steps: verify (sha, MR, doc exist), never redo; an uncommitted diff is the interrupted step's work: keep it"
    }
    $act = @(Active | Where-Object session -ne $tok)
    Print $act
    $notes | ForEach-Object { $_ }
    $w = @(Warnings ([pscustomobject]$me) $act)
    if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" } }
    $c = if ($Contracts) { $Contracts } else { (Active | Where-Object { $_.run -eq $Run -and $_.contracts } | Select-Object -First 1).contracts }
    if ($c -and (Test-Path $c)) { "CONTRACTS ($c) - re-read before every push:"; Get-Content $c | Select-Object -First 60 | ForEach-Object { "  $_" } }
    "budget: $($bg.tool) $(if ($bg.model) { $bg.model } else { '(default model)' }) $($bg.budget) tokens, handoff at $($bg.handoff) ($($bg.capBy)), never earlier; instructions cap $($bg.instrCap); design window $($bg.design) (no stop)"
    "SESSION $tok   (pass -Session $tok to beat / check / leave)"
  }
  'beat' {
    $f = Join-Path $dir "$Session.json"; if (-not $Session -or -not (Test-Path $f)) { "board beat: unknown session '$Session': board join first, then beat with the SESSION it prints"; exit 3 }   # no stack trace
    $script:beatEntry = $null; $script:beatTaken = $null; $ho = $null
    Update-BoardEntry $f { param($x) if ($x.status -eq 'left' -and $x.takenOverBy) { $script:beatTaken = $x; return $null }; $x.beat = (Get-KitStamp); if ($Status) { $x.status = $Status } elseif ($x.status -eq 'left' -and -not $x.handoffBrief) { $x.status = 'working' }; $script:beatEntry = $x; $x }   # a beat proves it lives: a reaped row is back
    if ($script:beatTaken) { $me = $script:beatTaken; "TAKEN OVER: session $($me.takenOverBy) replaced $Session at $(([datetime]$me.takenOverAt).ToString('HH:mm')). Stop without writing and tell the coordinator."; exit 1 }
    $me = $script:beatEntry
    $rt = if ($me.tool) { Invoke-KitAdapter transcript (Get-KitTranscriptKind $me.tool) root }
    $tf = if ($me.transcript) { $me.transcript } elseif ($rt -and -not ($me.txTry -and ((Get-Date) - [datetime]$me.txTry).TotalMinutes -lt (Get-KitParam 'board.transcriptRetryMinutes'))) { Update-BoardEntry $f { param($x) $x | Add-Member -Force NoteProperty txTry (Get-KitStamp); $x }; Find-KitTranscript "(pass -Session $Session to beat" $rt.filter $rt.dir }; $sp = Get-KitSpend $tf
    if ($tf -and -not $sp -and -not $me.transcript) { Update-BoardEntry $f { param($x) $x | Add-Member -Force NoteProperty transcript $tf; $x } }   # Codex / Antigravity: no usage lines
    if ($sp) {
      $bg = if ($sp.model -and $sp.model -ne $me.model) { Get-KitBudget -Model $sp.model -Role $me.type } else { [pscustomobject]@{ budget = $me.budget; handoff = $me.handoff; model = $me.model; capBy = $me.capBy } }
      Update-BoardEntry $f { param($x) foreach ($p in @{ transcript = $tf; spend = $sp.spend; model = $bg.model; budget = $bg.budget; handoff = $bg.handoff; capBy = $bg.capBy }.GetEnumerator()) { $x | Add-Member -Force NoteProperty $p.Key $p.Value }; $x }
      "budget: spend $($sp.spend) / $($bg.budget) (handoff at $($bg.handoff): $($bg.capBy))"
      if ($bg.handoff -and $sp.spend -ge $bg.handoff) { $ho = Get-KitHandoffLine $me $Session "spend $($sp.spend) >= $($bg.handoff)" }
      else { Get-KitCtxCheckLine $tf $sp.spend (Get-KitBudget -Model $bg.model -Role $me.type).design }   # Claude Code: its hook asked first (one record)
    }
    if (-not $ho -and $tf) { $ih = Get-KitInstrHandoff $me $Session $tf "$f.cx"; if ("$ih" -like 'HANDOFF*') { $ho = $ih } else { $ih } }
    if (-not $ho) { $ho = Get-KitStepAgeHandoff $me $Session }; $ho   # past budget.stepHours: a fresh agent from the checkpoint
    try { $null = Invoke-KitStorageTick } catch {}
    foreach ($m in @(Read-KitInboxNew $me.agent)) { "MESSAGE (follow it; a rule holds for the rest of your run): $m" }
    $pz = Get-KitActivePause $me.run; if ($pz) { "PAUSE ($($pz.reason)): $(Get-KitPauseSteps $Session)" }
    $w = @(Warnings $me @(Active)); if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" }; if ($w -notlike 'STALE:*') { exit 1 } }
  }
  { $_ -in 'show', 'list' } { $act = @(Active | Where-Object { -not $Run -or $_.run -eq $Run }); Print $act; @($act | ForEach-Object { Warnings $_ $act }) | Sort-Object -Unique | ForEach-Object { "  ! $_" }
    Invoke-KitHooks Get-KitBoardLines }   # QA seats, local-env leases
  'check' {
    if ($Decision) { if (-not $Ctx -or -not $Reason) { 'usage: board check -Decision continue|handoff -Reason <why> -Ctx <key> [-Session <token>]'; exit 2 }; $cr = Set-KitCtxCheck $Ctx $Decision $Reason $(if ($Session) { Join-Path $dir "$Session.json" }); $cr; exit $(if ("$cr" -like 'board check: no *') { 1 } else { 0 }) }
    if (-not $Worktree) { 'usage: board check -Worktree <dir> -Session <token>'; exit 2 }
    $mine = Norm $Worktree
    $others = @(Active | Where-Object { $_.session -ne $Session -and (@($_.worktrees | ForEach-Object { Norm $_ }) -contains $mine) })
    if ($others) { $others | ForEach-Object { "OTHER WRITER: $($_.agent) (session $($_.session), status $($_.status), beat $(([datetime]$_.beat).ToString('HH:mm')))" }; exit 1 }
    if ($Session) { Update-BoardEntry (Join-Path $dir "$Session.json") { param($x) if (@($x.worktrees | ForEach-Object { Norm $_ }) -notcontains $mine) { $x | Add-Member -Force NoteProperty worktrees @(@(Split-KitList $x.worktrees) + $Worktree) }; $x } }   # claimed: cleanup keeps it
    'ok: no other active agent claims this worktree'; exit 0
  }
  'leave' {
    $mine = @(if (-not $Session -and $Agent) { All | Where-Object { $_.agent -eq $Agent -and $_.status -ne 'left' -and (-not $Run -or $_.run -eq $Run) } })
    if ($mine.Count -and -not $Force) { $Session = @($mine | Sort-Object { (Test-KitHolder $_) -ne $false }, { "$($_.beat)" } -Descending)[0].session }   # token lost: the agent's newest live row
    elseif ($Force) { $Session = @($mine | Where-Object { (Test-KitHolder $_) -eq $false -or $_.session -notin (Active).session })[0].session }   # else a gone / quiet one
    $f = Join-Path $dir "$Session.json"
    if (-not $Session -or -not (Test-Path $f)) { "board leave: unknown session '$Session' (nothing left, no handoff; token lost: -Agent [-Run] leaves its newest live row; a gone one: -Force)"; exit 1 }
    $paused = $Status -eq 'paused'
    Update-BoardEntry $f { param($x) $x.status = 'left'; $x.beat = (Get-KitStamp); if ($Handoff) { $x | Add-Member -Force NoteProperty handoffBrief $Handoff }; if ($paused) { $x | Add-Member -Force NoteProperty paused $x.beat }; $script:leftEntry = $x; $x }
    $cf = Get-KitCheckpointFile $script:leftEntry.agent "$($script:leftEntry.run)"
    if (-not $paused) { Add-KitSpendObs $script:leftEntry $(if ($Handoff) { 'short' } else { 'ok' }) }   # a handoff: the estimate was too low
    if (-not $paused -and -not $Handoff -and (Test-Path -LiteralPath $cf)) { try { Invoke-KitLocked $cf { $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json; if (-not $c.run -or "$($c.run)" -eq "$($script:leftEntry.run)") { $c | Add-Member -Force NoteProperty done $true; Write-KitAtomic $cf ($c | ConvertTo-Json -Depth 6) } } } catch {} }   # next join starts fresh
    $twin = @(All | Where-Object { $_.agent -eq $script:leftEntry.agent -and $_.session -ne $Session -and $_.status -ne 'left' -and (Test-KitLive @{ session = $_.session }) })
    # its phone leases under another id (test:T1hm, holder T1), same process: now
    $byHolder = @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.agent -and $_.agent -ne $script:leftEntry.agent -and "$($_.holder)" -eq $script:leftEntry.agent -and $_.holderPid -and "$($_.holderPid)" -eq "$($script:leftEntry.holderPid)" } | ForEach-Object agent | Select-Object -Unique)
    if (-not $paused -and -not $Handoff -and -not $twin.Count) { Invoke-KitReleaseAgent -Agent (@($script:leftEntry.agent) + $byHolder) -Reason "left the board ($Session)" }   # paused / handed off: successor keeps them
    if (-not $paused) { try { Stop-KitLeftShells $script:leftEntry } catch { } }   # shells die with it
    if ($paused) {
      # poll-ok: local pause record, bounded by -Wait minutes
      $until = (Get-Date).AddMinutes($Wait); while (($pz = Get-KitActivePause $script:leftEntry.run) -and (Get-Date) -lt $until) { Wait-KitPoll 10 }
      if ($pz) { "PAUSED ($Session): stay stopped, return no result; the coordinator stops this run or resumes it. Run this same leave again now"; exit 0 }
      "RESUMED: board join -Agent $($script:leftEntry.agent) -Run '$($script:leftEntry.run)' -Resume, then go on at your checkpoint's next step"; exit 0
    }
    "left ($Session)$(if ($Handoff) { ": handoff brief $Handoff (a fresh agent continues: board join prints CONTINUE)" })"; $global:LASTEXITCODE = 0   # a release's git call left its code (no exit: dot-sourced callers)
  }
  'msg' {
    if (-not ($Agent -and $To -and $Text)) { "usage: board msg -Agent <me> -To <id> -Text '<message>' [-Kind $($script:KitMsgKinds -join '|')] [-Ref <id>]"; exit 2 }
    $To = Resolve-KitAgentAlias $To
    if ($Kind -notin $script:KitMsgKinds) { "board msg: -Kind '$Kind' unknown ($($script:KitMsgKinds -join ', '))"; exit 2 }
    if ($Text.Length -gt 2000) { "board msg: text over 2000 chars: a file, -Ref it"; exit 2 }
    $ids = @(Active | Where-Object type -eq $To | ForEach-Object agent); if ($ids -and $To -notin $ids) { "board msg: $To is a type: to $($ids -join ', ')"; exit 2 }
    Send-BoardMsg $Agent $To $Text $Kind $Ref
    $held = @(Active | Where-Object { $_.agent -eq $To }); "sent to $To$(if (-not $held) { ' (not on the board now: it reads it when it joins)' })"
  }
  'inbox' {
    if (-not $Agent) { 'usage: board inbox -Agent <me> [-All]'; exit 2 }
    if (-not (Test-Path (Get-InboxFile $Agent))) { 'inbox: empty'; return }
    $show = @(Read-KitInboxNew $Agent -All:$All); if ($show.Count) { $show } else { 'inbox: nothing unread' }
  }
}
}

function Invoke-Release([string[]]$Agent, [string]$Reason = 'agent finished') { $script:KitReleaseFailed = $false; Invoke-KitReleaseAgent $Agent $Reason; if ($script:KitReleaseFailed) { exit 1 } }

# ---- budget: agent budget (tool compaction point), plan run cap, run spend
function Get-KitPlanCap([string]$Plan, [string]$Tool = '') {   # 'role/model:n,...' (no /model: estimate unit, no budget; /@<phase>=<default>: models.<phase>)
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget; $cap = 0; $est = 0; $memo = @{}
  foreach ($p in @("$Plan" -split ',' | Where-Object { $_ -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$' })) {
    $null = $p -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$'; $role = $Matches[1]; $m = $Matches[2]; $n = [int]$Matches[3]; $hasM = $p -match '/'
    if ($m -match '^@([\w-]+)=(.*)$') { $m = [string](Get-KitSetting "models.$($Matches[1])" $Matches[2]) }
    if ($hasM) { if (-not $memo.ContainsKey($m)) { $memo[$m] = (Get-KitBudget -Tool $Tool -Model $m).budget }; $cap += $n * $memo[$m] }
    $est += $n * [double](Get-KitParam 'budget.estimate' ([double](Get-KitMember $ex.estimate $role)) $role)
  }
  [pscustomobject]@{ cap = [int]$cap; estimate = [int]$est; perModel = $memo }
}
function Invoke-Budget {
param([string]$Tool = '', [string]$Model = '', [int]$Window = 0, [string]$Plan = '', [string]$Run = '', [switch]$Json, [switch]$Usage)
if ($Usage) { Show-KitUsage 180 $Json; exit 0 }   # detached: a week's backlog (~150 s) once, then new lines only
if ($Run) {
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

# ---- launch: records for resume after a restart
# a workflow's config (CONFIG line of launch -Self): models.<phase>, repos[].role by name + alias, qa.lanes
function Get-KitWorkflowConfig {
  $roles = [ordered]@{}; $local = [ordered]@{}
  foreach ($r in @(Get-KitSetting 'repos' @())) { $nm = @(@($r.name) + @($r.aliases) | Where-Object { $_ } | ForEach-Object { "$_".ToLower() }); if ($r.role) { foreach ($n in $nm) { $roles[$n] = "$($r.role)".ToLower() } }
    # repos[].localTest optional / none: its localFallback; ci needs MR pipelines, else unit
    if ("$($r.localTest)" -in 'optional', 'none') { foreach ($n in $nm) { $local[$n] = $(if ("$($r.localFallback)" -eq 'unit' -or ($r.ci -and $r.ci.mrPipelines -eq $false)) { 'unit' } else { 'ci' }) } } }
  $plain = { param($o) if ($o) { $h = [ordered]@{}; foreach ($p in (Get-KitProps $o)) { if ($p.Name -notlike '_*') { $h[$p.Name] = $p.Value } }; if ($h.Count) { $h } } }
  [ordered]@{ models = (& $plain (Get-KitSetting 'models' $null)); tiers = Get-KitTiers; roles = $roles; local = $local; humanDoc = [bool]@(Get-KitProcessDocs | Where-Object key -eq 'testing-doc').Count; qaLanes = (& $plain (Get-KitSetting 'qa.lanes' $null)); intermittentRx = "$(Get-KitSetting 'qa.intermittentRx' '')" }
}
function Get-KitFnv([string]$s) { [uint64]$h = 2166136261; foreach ($c in $s.ToCharArray()) { $h = (($h -bxor [uint64][int]$c) * 16777619) % 4294967296 }; ([uint32]$h).ToString('x8') }
function Invoke-Launch {
param(
  [string]$RunId, [string]$Script, [string]$ArgsJson, [string]$ArgsFile, [string]$RunDir, [string]$Session,
  [switch]$Done, [switch]$List, [switch]$Brief, [int]$Hours = 24, [switch]$Self, [string]$Run, [string]$Fnv, [string]$Plan = '', [switch]$Check
)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
$dir = Get-KitPath launches -Create
$RunId = "$RunId".Trim().Trim('''"')
$safe = { param($id) ($id -replace '[^\w.-]', '_') }
# relative '.claude/.runtime/...': from the workspace root, not the cwd
if ($ArgsFile -and -not (Test-Path -LiteralPath $ArgsFile)) {
  $ArgsFile = @(if (-not [IO.Path]::IsPathRooted($ArgsFile)) { Join-Path (Split-Path $kit) $ArgsFile }; Join-Path $dir (Split-Path $ArgsFile -Leaf)) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $ArgsFile) { "MISMATCH: args file not found (looked in the workspace root and $dir): write it there again, then re-run"; exit 1 }
}

if ($Self) {
  if (-not ($Script -and $Run -and $ArgsFile)) { 'usage: launch -Self -Script <wf>.js -Run <run> -ArgsFile <file> -Fnv <hash> [-RunDir <dir>] [-Plan ''role/model:n,..'']'; exit 2 }
  $raw = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ArgsFile).Path)).TrimStart([char]0xFEFF).TrimEnd("`r", "`n")
  $got = Get-KitFnv $raw
  if ($Fnv -and $got -ne $Fnv.Trim().ToLower()) { "MISMATCH: the file hashes to $got, not $Fnv ($($raw.Length) chars): write the args again, byte for byte"; exit 1 }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { "MISMATCH: not valid JSON ($($_.Exception.Message))"; exit 1 }
  $leaf = Split-Path $Script -Leaf
  $rec = [ordered]@{ script = (Join-Path $kit "workflows/$leaf"); run = $Run; args = $a; argsRaw = $raw; runDir = $(if ($RunDir) { $RunDir } else { $a.runDir }); fnv = $got; at = (Get-KitStamp) } + (Get-KitHolder)
  $bud = if ($Plan) { $c = Get-KitPlanCap $Plan; $b0 = Get-KitBudget; [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; handoffAt = $b0.handoffAt; plan = $Plan }; $rec += [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; plan = $Plan } }
  $sf = Get-SelfLaunchFile $leaf $Run $got
  $prev = if (Test-Path -LiteralPath $sf) { Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json }   # a live run re-recording keeps its pause
  Write-KitState $sf $rec
  "RECORDED $leaf $Run (fnv $got)"; if ($bud) { "BUDGET $($bud | ConvertTo-Json -Compress)" }
  "CONFIG $(Get-KitWorkflowConfig | ConvertTo-Json -Compress -Depth 10)"
  if (-not $prev -or $prev.completed -or $prev.paused) { Clear-KitPauseFor $Run }
  if ($leaf -like 'buildy*') { Invoke-KitLaunchTaskSteps $a $Run $sf }   # TASKS REFUSED: buildy.js refuses; AREA TASK lines
  exit 0
}
if ($Check) { Test-KitLaunchTasks -File $ArgsFile }   # the coordinator, before a /buildy launch

if ($Done) {
  if (-not $RunId -and -not $Run) { 'usage: launch -Done -RunId <id> | -Run <run> (a self record: the workflow wrote it)'; exit 2 }
  $files = @(@(if ($RunId) { Join-Path $dir "$(& $safe $RunId).json" }) | Where-Object { Test-Path -LiteralPath $_ })
  $raw = @(Get-StoppedRuns -Hours 720 -Raw)
  $wfDirs = @(if ($RunId) { Get-KitWorkflowDirs })
  $hit = @($raw | Where-Object { ($Run -and $_.run -eq $Run) -or ($RunId -and ($_.runId -eq $RunId -or (-not $_.runId -and (Resolve-KitRunId $_ $wfDirs) -eq $RunId))) })
  if ($RunId) { foreach ($h in $hit) { if (-not $h.runId) { $h.runId = $RunId } } }
  # a relaunch with a live session is never closed
  $live = { param($o) @(@($o.record) + @(if ($o.selfFile) { Get-Content -LiteralPath $o.selfFile -Raw | ConvertFrom-Json }) | Where-Object { $_ -and (Test-KitHolder $_) -eq $true }).Count }
  $keys = @{}; foreach ($h in $hit) { foreach ($x in @(Get-KitResumeKeys $h) + @(Get-KitParentKey (Get-KitRunArgs $h))) { if ($x) { $keys[$x] = $true } } }
  if ($RunId) { $keys["$(ConvertTo-KitSlug $RunId).resume.md"] = $true }
  do { $more = @($raw | Where-Object { $_ -notin $hit -and (@(Get-KitResumeKeys $_ | Where-Object { $keys[$_] }).Count -or $keys["$(Get-KitParentKey (Get-KitRunArgs $_))"]) -and -not (& $live $_) })
    foreach ($m in $more) { $hit += $m; foreach ($x in @(Get-KitResumeKeys $m) + @(Get-KitParentKey (Get-KitRunArgs $m))) { if ($x) { $keys[$x] = $true } } } } while ($more.Count)
  $files += @($hit | ForEach-Object { $_.file, $_.selfFile } | Where-Object { $_ })
  foreach ($h in $hit) { $files += @(Read-KitJsonFiles $dir 'self-*.json' | Where-Object { -not $_.completed -and (($_.run -eq $h.run -and (Split-Path ([string]$_.script) -Leaf) -eq $h.leaf -and [datetime]$_.at -le $h.last) -or ($keys["$(Get-KitParentKey $_.args)"] -and (Test-KitHolder $_) -ne $true)) } | ForEach-Object file) }   # + superseded launches
  if ($Run) { $files += @(Read-KitJsonFiles $dir 'self-*.json' | Where-Object run -eq $Run | ForEach-Object file) }
  $files = @($files | Select-Object -Unique)
  if (-not $files.Count -and @($wfDirs | Where-Object Name -eq $RunId).Count) { $files = @(Join-Path $dir "$(& $safe $RunId).json"); Write-KitState $files[0] @{ runId = $RunId; at = (Get-KitStamp) } }   # folder without record: stopped, supervise skips it
  if (-not $files.Count) { Write-Host "[launch] no record for $RunId$Run (nothing to mark)"; exit 0 }
  foreach ($h in $hit) { Invoke-KitStopLearn $h 'launch -Done' | ForEach-Object { Write-Host "[launch] $_" } }
  foreach ($x in $files) { Invoke-KitLocked $x { $r = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json -AsHashtable; $r.completed = (Get-KitStamp); Write-KitState $x $r } }
  Write-Host "[launch] marked completed: $(@($files | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
  exit 0
}
if (-not $List) {
  if (-not $RunId -or -not $Script) { throw 'record a launch with -RunId <id> -Script <path> and -ArgsJson <json> or -ArgsFile <file>' }
  $raw = if ($ArgsFile) { Get-Content -LiteralPath $ArgsFile -Raw } elseif ($ArgsJson) { $ArgsJson } else { '{}' }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "the args are not valid JSON: $($_.Exception.Message)" }
  if (-not $RunDir -and $a -is [hashtable] -and $a.runDir) { $RunDir = [string]$a.runDir }
  $rec = [ordered]@{ runId = $RunId; script = $Script; args = $a; argsFile = $(if ($ArgsFile) { (Resolve-Path -LiteralPath $ArgsFile).Path } else { $null })
    runDir = $(if ($RunDir) { $RunDir } else { $null }); session = $(if ($Session) { $Session } else { $null }); at = (Get-KitStamp); completed = $null } + (Get-KitHolder)
  $f = Join-Path $dir "$(& $safe $RunId).json"
  Write-KitState $f $rec
  Write-Host "[launch] recorded $RunId ($(Split-Path $Script -Leaf)) -> $f"
  Update-KitSelfHolder $dir $RunId $Script | ForEach-Object { Write-Host "[launch] $_" }
  if (($ln = Get-LaunchRunName $a)) { Clear-KitPauseFor $ln }
  exit 0
}

$out = @(foreach ($s in Get-StoppedRuns -Hours $Hours) {
  if ($s.runId) { "$(if ($s.paused) { 'paused ' })$($s.leaf) $($s.runId) (resumeFromRunId $($s.runId), args $(if ($s.selfFile) { $s.selfFile } else { $s.file }))" }
  else { "$(if ($s.paused) { 'paused ' })$($s.leaf) run $($s.run): launched, run id never recorded (bossy.ps1 recover finds it; finished: launch -Done -Run '$($s.run)')" }
})
foreach ($q in Get-OrphanQaItems -Hours ([math]::Max($Hours, 48))) { $out += "QA run $($q.run): $($q.codes.Count) item(s) tested, never published ($($q.codes -join ', ')): pokey.ps1 finalize" }
$out | ForEach-Object { $_ }
if ($out.Count -and -not $Brief) { 'resume calls, resume briefs, finalize lines: bossy.ps1 recover' }
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
# task ids in items text (notes have words like oauth2)
function Get-KitItemTasks([string]$Text) { @("$Text" -split '[\s,;()]+' | ForEach-Object { NormTask $_ } | Where-Object { $_ -match '^(?=.*\d)(?=.*[a-z])[\w-]{5,}$' }) }# recover writes <slug>.resume.md: a relaunch's brief
function Get-KitResumeKeys($S) { @(@($S.runId, $S.run) | Where-Object { $_ } | ForEach-Object { "$(ConvertTo-KitSlug $_).resume.md" }) }
function Get-KitParentKey($A) { $l = "$($A.brief)" -split '[\\/]' | Select-Object -Last 1; if ($l -match '\.resume\.md$') { $l.ToLower() } }
$script:KitArgs = @{}
function Get-KitRunArgs($S) { if ($S.selfFile) { if (-not $script:KitArgs.ContainsKey($S.selfFile)) { $script:KitArgs[$S.selfFile] = try { (Get-Content -LiteralPath $S.selfFile -Raw | ConvertFrom-Json).args } catch { $null } }; $script:KitArgs[$S.selfFile] } elseif ($S.record) { $S.record.args } }
# () notes dropped: 'a, b (fix round 2)' repeats 'a, b'
function Get-KitAgentKeys($A) { @(foreach ($g in @($A.agents | Where-Object { $_ })) { foreach ($i in "$($g.items)" -split ',(?![^()]*\))') { $i = (($i -replace '\([^()]*\)', '') -replace '\s+', ' ').Trim().ToLower(); if ($i) { "$("$($g.id)".ToLower())|$i" } } }) | Select-Object -Unique }
# a relaunch's ancestors
function Get-KitLineage($S, $WfDirs = @()) {
  $all = @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { $_.script -and $_.at }); $o = @{ since = $S.at; runs = @($S.run); ids = @($S.runId | Where-Object { $_ }) }; $a = Get-KitRunArgs $S; $before = [datetime]$S.at
  for ($n = 0; $n -lt 10 -and ($pk = Get-KitParentKey $a); $n++) {
    $par = @($all | Where-Object { [datetime]$_.at -lt $before -and @(@($_.runId, $_.run) | Where-Object { $_ } | ForEach-Object { "$(ConvertTo-KitSlug $_).resume.md" }) -contains $pk } | Sort-Object { [datetime]$_.at } | Select-Object -Last 2); if (-not $par.Count) { break }; $a = $null
    foreach ($p in $par) { $t = [datetime]$p.at; if ($p.runId) { $o.ids += $p.runId }
      # not by time: runs share a minute
      $m = if ($p.run) { $p } elseif ($p.runId) { @($all | Where-Object { $_.run -and $_.file -like '*self-*' -and [math]::Abs(([datetime]$_.at - $t).TotalMinutes) -le 30 -and (Resolve-KitRunId ([pscustomobject]@{ selfFile = $_.file; leaf = (Split-Path ([string]$_.script) -Leaf); run = $_.run }) $WfDirs -FnvOnly) -eq $p.runId })[0] }
      foreach ($x in @($p, $m) | Where-Object { $_ }) { if ([datetime]$x.at -lt $o.since) { $o.since = [datetime]$x.at }; if ([datetime]$x.at -lt $before) { $before = [datetime]$x.at } }; if ($m) { $o.runs += $m.run; if (-not $a) { $a = $m.args } } }
  }
  $o.runs = @($o.runs | Where-Object { $_ } | Select-Object -Unique); $o.ids = @($o.ids | Select-Object -Unique); $o
}
# a later launch (relaunch, fix round) supersedes
function Get-StoppedRuns([int]$Hours = 24, [switch]$All, [switch]$Raw) {
  $dir = Get-KitPath launches -Create; $since = (Get-Date).AddHours(-$Hours)
  $selfs = @(Read-KitJsonFiles $dir 'self-*.json')
  $records = @(Read-KitJsonFiles $dir | Where-Object { (Split-Path $_.file -Leaf) -notlike 'self-*' -and $_.script } | Sort-Object { (Get-Item -LiteralPath $_.file).LastWriteTime })   # args dumps are no launches
  if ($Raw) { return @(Get-StoppedRunsOf $records $selfs $since $true) }
  $latest = @{}
  foreach ($x in @($selfs | ForEach-Object { , @($_.script, $_.run, $_.at) }) + @($records | ForEach-Object { , @($_.script, (Get-LaunchRunName $_.args), $_.at) })) {
    $t = $null; try { $t = [datetime]$x[2] } catch {}; if (-not $t) { continue }; $key = "$(Split-Path ([string]$x[0]) -Leaf)|$($x[1])"; if (-not $latest[$key] -or $t -gt $latest[$key]) { $latest[$key] = $t }
  }
  $runs = @(Get-StoppedRunsOf $records $selfs $since $All | Where-Object { $_.paused -or $latest["$($_.leaf)|$($_.run)"] -le $_.last.AddMinutes(10) })
  $runs = @(@($runs | Where-Object { -not $_.runId }) + @($runs | Where-Object runId | Group-Object runId | ForEach-Object { $_.Group | Sort-Object at | Select-Object -Last 1 }))
  $runs = @($runs | Group-Object { "$($_.leaf)|$($_.run)" } | ForEach-Object { $_.Group | Sort-Object last | Select-Object -Last 1 })
  # superseded: relaunched, or a later run of the same agents and tasks
  $views = @(@($selfs) + @($records | Where-Object { $_.args.agents -or $_.args.brief }) | ForEach-Object { $t = try { [datetime]$_.at } catch { $null }; if ($t) { [pscustomobject]@{ file = $_.file; leaf = Split-Path ([string]$_.script) -Leaf; run = $(if ($_.run) { $_.run } else { Get-LaunchRunName $_.args }); at = $t; parent = Get-KitParentKey $_.args; agents = @(Get-KitAgentKeys $_.args) } } })
  $kids = @{}; foreach ($v in $views | Where-Object parent) { if (-not $kids[$v.parent] -or $v.at -gt $kids[$v.parent]) { $kids[$v.parent] = $v.at } }   # a run name can be reused
  @($runs | Where-Object { $s = $_
      if (@(Get-KitResumeKeys $s | Where-Object { $kids[$_] -and $kids[$_] -gt $s.at }).Count) { return $false }
      $mine = @(Get-KitAgentKeys (Get-KitRunArgs $s)); if (-not $mine.Count) { return $true }
      -not @($views | Where-Object { $v = $_; $v.leaf -eq $s.leaf -and $v.run -ne $s.run -and $v.at -gt $s.last -and $v.file -notin @($s.file, $s.selfFile) -and -not @($mine | Where-Object { $_ -notin $v.agents }).Count }).Count })
}
function Get-StoppedRunsOf($records, $selfs, [datetime]$since, [bool]$All) {
  $used = @{}
  # a resumed run: live by its new record or folder, never by its old self record
  $liveIds = @{}; foreach ($r in $records | Where-Object { $_.runId -and -not $_.completed -and (Test-KitHolder $_) -eq $true }) { $liveIds[$r.runId] = $true }
  foreach ($s in $selfs | Where-Object { $_.wfDir -and -not $_.completed }) { $sid = Split-Path "$($s.wfDir)" -Leaf; if (-not $liveIds[$sid] -and (Test-KitRunLive "$($s.wfDir)" @())) { $liveIds[$sid] = $true } }
  foreach ($r in $records | Where-Object { -not $_.completed }) {
    $at = try { [datetime]$r.at } catch { (Get-Item -LiteralPath $r.file).LastWriteTime }
    if ($at -lt $since -and -not $r.paused -and -not ($All -and (Test-KitHolder $r) -eq $true)) { continue }   # paused: waits however long; -All: a live one, any age
    if (-not $All -and -not $r.paused -and ((Test-KitHolder $r) -eq $true -or ($r.runId -and $liveIds[$r.runId]))) { foreach ($so in @($selfs | Where-Object { $_.wfDir -and (Split-Path "$($_.wfDir)" -Leaf) -eq $r.runId })) { $used[$so.file] = $true }; continue }
    $leaf = Split-Path ([string]$r.script) -Leaf; $run = Get-LaunchRunName $r.args
    $free = @($selfs | Where-Object { -not $used[$_.file] -and (Split-Path ([string]$_.script) -Leaf) -eq $leaf })
    $sf = @($free | Where-Object { $run -and $_.run -eq $run } | Sort-Object { [math]::Abs(([datetime]$_.at - $at).TotalMinutes) }) | Select-Object -First 1 -ExpandProperty file
    $near = @($free | Where-Object { [math]::Abs(([datetime]$_.at - $at).TotalMinutes) -le 30 } | Sort-Object { [math]::Abs(([datetime]$_.at - $at).TotalMinutes) }); $bp = { param($x) ("$x" -split '[\\/]')[-1] }   # typed args: brief file name only
    if (-not $sf) { $sf = @(@($near | Where-Object { $r.args.brief -and (& $bp $_.args.brief) -ieq (& $bp $r.args.brief) }) + $near) | Select-Object -First 1 -ExpandProperty file }
    $last = $at
    if ($sf) { $used[$sf] = $true; $so = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json; if ($so.completed) { continue }; $run = $so.run; if ([datetime]$so.at -gt $last) { $last = [datetime]$so.at } }   # owner-stopped ends the launch
    [pscustomobject]@{ runId = $r.runId; leaf = $leaf; script = $r.script; run = $run; at = $at; last = $last; file = $r.file; selfFile = $sf; runDir = $r.runDir; record = $r; paused = $r.paused }
  }
  foreach ($s in $selfs | Where-Object { -not $used[$_.file] -and -not $_.completed -and ($_.paused -or [datetime]$_.at -ge $since -or ($All -and (Test-KitHolder $_) -eq $true)) }) {
    if (-not $All -and -not $s.paused -and ((Test-KitHolder $s) -eq $true -or ($s.wfDir -and $liveIds[(Split-Path "$($s.wfDir)" -Leaf)]))) { continue }
    # only a completed record of THIS launch hides it
    if (@($records | Where-Object { $_.completed -and (Get-LaunchRunName $_.args) -eq $s.run -and [math]::Abs(([datetime]$_.at - [datetime]$s.at).TotalMinutes) -le 30 }).Count) { continue }
    [pscustomobject]@{ runId = $null; leaf = (Split-Path ([string]$s.script) -Leaf); script = $s.script; run = $s.run; at = [datetime]$s.at; file = $null; selfFile = $s.file; runDir = $(if ($s.runDir) { $s.runDir } else { $s.args.runDir }); record = $null; paused = $s.paused; last = [datetime]$s.at }
  }
}
# from the launch -Self transcript, args hash first
$script:KitRunIds = @{}
function Resolve-KitRunId($S, $WfDirs, [switch]$FnvOnly) {   # -FnvOnly: run name in 2+ transcripts = unknown
  $k = "$($S.selfFile)|$FnvOnly"; if ($script:KitRunIds.ContainsKey($k)) { return $script:KitRunIds[$k] }
  $sj = if ($S.selfFile) { try { Get-Content -LiteralPath $S.selfFile -Raw | ConvertFrom-Json } catch { $null } }; $fnv = "$($sj.fnv)"
  $base = [regex]::Escape("launch -Self -Script $($S.leaf) -Run '$($S.run)' "); $id = $null
  # budget -Run stored its folder: read one folder, not 41 (2.7 s per run)
  $own = @($WfDirs | Where-Object { $fnv -and $sj.wfDir -and $_.FullName -eq "$($sj.wfDir)".TrimEnd('\', '/') })
  if ($own.Count -and @(Get-ChildItem $own[0].FullName -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath $_.FullName -Pattern "$base.*-Fnv $fnv" -Quiet } | Select-Object -First 1).Count) { $script:KitRunIds[$k] = $own[0].Name; return $own[0].Name }
  foreach ($rx in @(if ($fnv) { "$base.*-Fnv $fnv" }) + @(if (-not $FnvOnly) { $base })) {
    $hit = @($WfDirs | Where-Object { @(Get-ChildItem $_.FullName -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath $_.FullName -Pattern $rx -Quiet }).Count } | Select-Object -First 2)
    if ($hit.Count -eq 1 -or ($hit.Count -and $rx -ne $base)) { $id = $hit[0].Name; break }
  }
  $script:KitRunIds[$k] = $id; $id
}
# area state = least done item; failed call = unknown
$script:KitStates = 'unknown', 'start', 'build', 'open', 'merged', 'done'
$script:KitSteps = 'build', 'review', 'ci', 'merge', 'testing-doc', 'tracker'
$script:KitTasks = @{}   # per recover: one call per task, comment, MR
function Get-KitOnce([string]$Key, [scriptblock]$Get) { if (-not $script:KitTasks.ContainsKey($Key)) { $script:KitTasks[$Key] = & $Get }; $script:KitTasks[$Key] }
function Get-KitAreaState($Ag, [string[]]$Stored = @(), $Wts = @(), $Since = $null, [string[]]$Others = @(), [string[]]$Reported = @()) {   # MRs before $Since are earlier work
  $txt = "$($Ag.items) $($Ag.note)"; $tid = { param($x) Get-KitItemTasks $x }
  $tasks = @(& $tid "$($Ag.items)" | Select-Object -Unique); $c = @{}; $fail = $false
  $add = { param($repo, $n, $by) if ($repo -and $n -and $c["$repo!$n"].by -ne 'pin') { if (-not $c["$repo!$n"] -or $by -ne 'task') { $c["$repo!$n"] = @{ repo = $repo; n = "$n"; by = $by } } } }
  foreach ($u in @($Stored | ForEach-Object { ConvertFrom-MrUrl $_ } | Where-Object { $_ })) { & $add $u.repo $u.n pin }
  foreach ($u in @($Reported | ForEach-Object { ConvertFrom-MrUrl $_ } | Where-Object { $_ })) { & $add $u.repo $u.n report }
  foreach ($m in [regex]::Matches($txt, '([\w./-]+)!(\d+)')) { $mp = Get-HostProject $m.Groups[1].Value -Raw; if (-not $c["$mp!$($m.Groups[2].Value)"]) { & $add $mp $m.Groups[2].Value mention } }   # a note names any MR: on an area branch, else a task MR
  $kb = @{}   # repo -> area branches
  if ((Get-KitOnce online { Test-KitOnline })) {
    $global:KitHostFailed = $false
    foreach ($w in @($Wts | Where-Object branch)) {
      if ("$(git -C $w.dir remote get-url origin 2>$null)" -notmatch '^(?:\w+://)?(?:[^@/]+@)?[^/:]+[:/](?<p>.+?)(?:\.git)?/?$') { continue }
      $p = $Matches.p; $kb[$p] = @($kb[$p]) + $w.branch; foreach ($m in @(Invoke-HostVerb 'mr.list' @{ repo = $p; source_branch = $w.branch; state = 'all' } | Where-Object { $_ })) { & $add $p $m.iid branch }
    }
    foreach ($t in $tasks) { foreach ($r in @(Get-KitOnce "$t#mrs" { @(Find-TaskMrs $t) })) { if ("$r" -match '^(?<r>.+)!(?<n>\d+)$') { & $add (Get-HostProject $Matches.r -Raw) $Matches.n task } } }
    $fail = [bool]$global:KitHostFailed
  } elseif ($c.Count -or $tasks.Count -or @($Wts | Where-Object branch).Count) { $fail = $true }
  $mrs = @(foreach ($k in $c.Keys) { $h = if ((Get-KitOnce online { Test-KitOnline })) { Get-KitOnce "mr:$k" { try { Invoke-HostVerb 'mr.get' $c[$k] } catch { $null } } }
      [pscustomobject]@{ ref = $k; url = $(if ($h.web_url) { $h.web_url } else { $k }); repo = ($c[$k].repo -split '/')[-1]; state = $(if ($h.state) { "$($h.state)" } else { 'UNKNOWN' }); text = "$($h.source_branch) $($h.title)"; body = "$($h.description)$($h.body)"; pin = $c[$k].by -in 'pin', 'report'; by = $c[$k].by; branch = "$($h.source_branch)"; rp = $c[$k].repo; created = $h.created_at } })
  # area branch MRs only (task ids span areas); unreadable = unknown
  foreach ($m in @($mrs | Where-Object { $_.by -in 'pin', 'branch' -and $_.branch })) { $kb[$m.rp] = @($kb[$m.rp]) + $m.branch }
  $any = @(@($Ag.branch) + @($Ag.branches) | Where-Object { $_ })
  $mrs = @($mrs | Where-Object { $b = @(@($kb[$_.rp]) + $any | Where-Object { $_ }); if ($_.by -eq 'mention') { $_.pin = $_.branch -and $_.branch -in $b; return $_.pin -or ($_.branch -and -not $b.Count -and $_.branch -notin $Others) }; $_.by -in 'pin', 'branch' -or -not $_.branch -or $_.branch -in $b -or (-not $b.Count -and $_.branch -notin $Others) })
  $mrs = @($mrs | Where-Object { $_.state -ne 'closed' -and ($_.pin -or -not $Since -or -not $_.created -or [datetimeoffset]$_.created -ge ([datetimeoffset]$Since).AddMinutes(-10)) })   # offsets: host UTC, launches local
  $wip = @($Wts | Where-Object { $_.dirty -or $_.unpushed -ne '0' }).Count   # merged work ignores it: squash leaves the branch ahead
  $prev = ''; $its = @("$($Ag.items)" -split ',(?![^()]*\))' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $t = @(& $tid $_)[0]; if ($t) { $prev = $t } else { $t = $prev }; [pscustomobject]@{ item = $_; task = $t } })   # '<task> a, b': b is the same task
  $reg = (Read-KitTracking).tasks; if (-not $reg) { $reg = @{} }; $nr = { param($r) $x = "$r" -replace '^.*/', ''; if ($x -match '^(?<r>[\w.-]+)!(?<n>\d+)$' -and (Get-KitMember $KitConf.RepoAliases ($Matches.r))) { "$((Get-KitMember $KitConf.RepoAliases ($Matches.r)))!$($Matches.n)" } else { $x } }   # track add's ref form; tracked = tracker step done
  $hit = { param($m, $t) $t -and $m.text -match "(?i)(?<![a-z0-9])$([regex]::Escape($t))(?![a-z0-9])" }
  $loose = @($mrs | Where-Object { $m = $_; -not @($its | Where-Object { & $hit $m $_.task }).Count })
  $items = @(foreach ($it in $its) {
      $t = $it.task; $mine = @($mrs | Where-Object { & $hit $_ $t })
      $guess = -not $mine.Count -and $loose.Count -and $its.Count -gt 1
      if (-not $mine.Count -and $its.Count -eq 1) { $mine = $loose }
      $tk = if ($t) { Get-KitOnce $t { try { Get-TrackerTask $t } catch { $null } } }; $ts = "$($tk.status)"
      # registry: logical statuses: crafty/vocab.json statuses
      $late = $ts -and (Test-TrackerStatus $ts 'promoted', 'inTest', 'closed')   # dev steps done (failedTesting: back to dev)
      $rx = '(?i)testing doc(?: \(human\))?\W{0,6}(https?://[^\s)\]"<>]+)'   # description links block is current: read first
      $doc = if ($t -and -not $late) { if ("$($tk.description) $(@($mine.body) -join ' ')" -match $rx) { $Matches[1] } else {
          if ((Get-KitOnce "$t#c" { "$(try { Get-TrackerComments $t | ConvertTo-Json -Depth 4 -Compress } catch { '' })" }) -match $rx) { $Matches[1] } } }
      $open = @($mine | Where-Object state -eq 'opened').Count; $known = -not $fail -and -not $guess -and -not @($mine | Where-Object state -eq 'UNKNOWN').Count
      $done = @(if ($late) { $script:KitSteps } else {
          if ($known -and $mine.Count -and -not ($open -and $wip)) { 'build' }   # MRs open only after the local loop passed
          if ($known -and $mine.Count -and -not $open) { 'review', 'ci', 'merge' }
          if ($doc -and $mine.Count) { 'testing-doc' }   # a doc older than this run's MR is earlier work
          $tr = @($reg[$t].mrs | ForEach-Object { & $nr $_ }); if ($known -and $mine.Count -and -not $open -and -not $reg[$t].holdPromotion -and -not @($mine | Where-Object { (& $nr $_.ref) -notin $tr }).Count) { 'tracker' } })   # resume releases a HELD promotion
      $st = if ($done.Count -eq $script:KitSteps.Count) { 'done' } elseif ($done -contains 'merge') { 'merged' } elseif ($done -contains 'build') { 'open' } elseif (-not $known) { 'unknown' } elseif ($wip) { 'build' } else { 'start' }
      [pscustomobject]@{ item = $it.item; state = $st; done = $done; mrs = $mine; tracker = $ts; doc = $doc; deployed = [bool]($ts -and (Test-TrackerStatus $ts 'inTest', 'closed')) }
    })
  $area = @($items | Sort-Object { $script:KitStates.IndexOf($_.state) })[0].state; if (-not $area) { $area = 'start' }
  [pscustomobject]@{ state = $area; skip = @($script:KitSteps | Where-Object { $s1 = $_; $items.Count -and -not @($items | Where-Object { $_.done -notcontains $s1 }).Count }); items = $items; mrs = @($items.mrs | Where-Object { $_ } | Sort-Object ref -Unique) }
}
# ---- recover: stopped runs; area state from host, tracker, worktrees
function Invoke-Recover {
param([string]$RunId, [string[]]$Run = @(), [int]$Hours = 24, [int]$MaxSeconds = 150, [switch]$Everyone)
$Run = @(Split-KitList $Run)
if (-not $script:KitDeadline) { $script:KitDeadline = (Get-Date).AddSeconds($MaxSeconds); Invoke-KitHooks Close-KitFinishedRuns }   # resume did both: one budget, one scan
$runs = @(Get-StoppedRuns -Hours $Hours -All:([bool]($RunId -or $Run.Count)) | Where-Object { (-not $RunId -or $_.runId -eq $RunId) -and (-not $Run.Count -or $_.run -in $Run) })
if ($RunId -and -not $runs.Count) { "no launch record for $RunId within $Hours h (bossy.ps1 launch -List)"; exit 0 }
$wfDirs = @(Get-KitWorkflowDirs | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) })
foreach ($s in $runs) { if ($s.selfFile) { $r = Resolve-KitRunId $s $wfDirs -FnvOnly:([bool]$s.runId); if ($r) { $s.runId = $r } } }   # transcript beats time pairing
$runs = @(@($runs | Where-Object { -not $_.runId }) + @($runs | Where-Object runId | Group-Object runId | ForEach-Object { $_.Group | Sort-Object at | Select-Object -Last 1 }) | Sort-Object at)
$script:KitTasks = @{}; $ri = 0
foreach ($s in $runs) {
  # host + tracker calls add up per area: stop in time, say what is left
  if ((Get-Date) -ge $script:KitDeadline) { $rest = @($runs | Select-Object -Skip $ri); "partial: time budget ($MaxSeconds s) used; $($rest.Count) run(s) not checked: $(@($rest.run) -join ', '). Rerun: bossy.ps1 recover -Run '$(@($rest.run | Select-Object -Unique) -join ',')'"; break }
  $ri++; if (($ow = Get-KitOwnedLine $s $Everyone)) { $ow; continue }
  $lr = Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json; $a = $lr.args
  $aj = Get-LaunchArgsJson $lr; if (-not $a.runDir -and $lr.runDir) { $a | Add-Member -Force NoteProperty runDir $lr.runDir }
  "== $($s.leaf) run $(if ($s.runId) { $s.runId } else { '<id unknown>' }) ($($s.run)), launched $($s.at.ToString('yyyy-MM-dd HH:mm'))"
  if (-not $s.paused -and (Test-KitHolder $(if ($s.record) { $s.record } else { $lr })) -ne $true) { Invoke-KitStopLearn $s 'recover' | ForEach-Object { "  $_" } }
  "  args: $(if ($s.selfFile) { "$($s.selfFile) (.args, written by the workflow: exact)" } else { "$($s.file) (.args, typed by the coordinator: a missing field breaks resumeFromRunId)" })"
  $lin = Get-KitLineage $s $wfDirs; $board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.run -in $lin.runs })   # relaunch continues ancestors' agents
  foreach ($b in $board | Where-Object { $_.status -ne 'left' -or $_.paused -or $_.crashed } | Sort-Object agent) { "  board: $($b.agent) $(if ($b.paused) { 'paused' } elseif ($b.crashed) { 'crashed' } else { $b.status }), last beat $(([datetime]$b.beat).ToString('dd MMM HH:mm'))$(if ((Test-KitHolder $b) -eq $false) { ', session gone' }) | $($b.area)" }
  if (@($board | Where-Object status -eq 'left').Count) { "  board: $(@($board | Where-Object status -eq 'left').Count) entr(ies) left" }
  $brief = @(); $resume = [ordered]@{}
  $waves = @($lin.ids | ForEach-Object { Join-Path (Get-KitPath waves) "$_.json" } | Where-Object { Test-Path $_ } | ForEach-Object { (Get-Content $_ -Raw | ConvertFrom-Json).agents })   # bossy.ps1 report: agents.<id>.mrs[].url
  $agents = if ($a.agents) { @($a.agents) } else { @($board | Group-Object agent | ForEach-Object { [pscustomobject]@{ id = $_.Name; items = $_.Group[0].items } }) }
  # all areas first: an MR on a sibling's branch is the sibling's
  $own = @{}; $rep = @{}; $dirs = @{}; $ours = @{}; $cks = @{}; $sib = @{}
  for ($ix = 0; $ix -lt $agents.Count; $ix++) { $ag = $agents[$ix]
    $ck = @(@($lin.runs) | ForEach-Object { Get-KitCheckpoint $ag.id "$_" } | Where-Object { $_ -and $_.run -in $lin.runs })[0]; if (-not $ck) { $ck = Get-KitCheckpoint $ag.id }; $cks[$ix] = $ck; $ours[$ix] = $ck -and (-not $ck.run -or $ck.run -in $lin.runs); $pre = "$($ag.id)".ToLower()
    $own[$ix] = @(@(if ($ours[$ix]) { $ck.steps | Where-Object step -eq 'mr' | ForEach-Object evidence }) | Where-Object { $_ }); $rep[$ix] = @($waves | ForEach-Object { (Get-KitMember $_ ($ag.id)).mrs.url } | Where-Object { $_ })
    $at = @(Get-KitItemTasks "$($ag.items)")   # agent ids repeat across runs
    $dirs[$ix] = @(@(@(foreach ($root in $KitConf.WorktreeRoots) { Get-ChildItem $root -Directory -Filter "$pre-*" -ErrorAction SilentlyContinue | ForEach-Object FullName }) + @($board | Where-Object agent -eq $ag.id | ForEach-Object { $_.worktrees }) + @(if ($ours[$ix]) { $ck.worktrees }) |
      Where-Object { $d = "$_"; $d -and (Test-Path -LiteralPath $d -PathType Container) -and @($KitConf.WorktreeRoots | Where-Object { $d.Replace('\', '/').TrimEnd('/') -like "$("$_".Replace('\', '/').TrimEnd('/'))/*" }).Count } | ForEach-Object { (Get-Item -LiteralPath "$_").FullName.TrimEnd('\', '/') } | Sort-Object -Unique) |   # linked worktrees only
      ForEach-Object { [pscustomobject]@{ dir = $_; branch = "$(git -C $_ branch --show-current 2>$null)".Trim() } } | Where-Object { $b = $_.branch; $b -and (-not $at.Count -or @($at | Where-Object { $b -match "(?i)(?<![a-z0-9])$([regex]::Escape($_))(?![a-z0-9])" }).Count) })
    $sib[$ix] = @($dirs[$ix].branch)
  }
  for ($ix = 0; $ix -lt $agents.Count; $ix++) { $ag = $agents[$ix]
    $mine = @(); $ck = $cks[$ix]
    foreach ($w in @($dirs[$ix] | ForEach-Object { Get-Item -LiteralPath $_.dir | Add-Member -PassThru NoteProperty br $_.branch })) {
      $br = $w.br
      $gd = "$(git -C $w.FullName rev-parse --absolute-git-dir 2>$null)".Trim(); $tg = if ($gd -and (Test-Path "$gd/claude-target")) { "$(Get-Content "$gd/claude-target")".Trim() } else { '' }
      $dirty = @(git -C $w.FullName status --porcelain 2>$null).Count
      $ahead = if ($tg) { "$(git -C $w.FullName rev-list --count "origin/$tg..HEAD" 2>$null)".Trim() } else { '?' }
      $up = "$(git -C $w.FullName rev-list --count '@{u}..HEAD' 2>$null)".Trim(); if (-not $up) { $up = $ahead }   # no upstream: every commit unpushed
      $last = "$(git -C $w.FullName log -1 --format='%h %cr %s' 2>$null)".Trim()
      $line = "$($ag.id) $($w.FullName): branch $br (target $(if ($tg) { $tg } else { '?' })), $ahead commit(s) not on the target, $dirty uncommitted file(s); last: $last"
      "  worktree: $line"; $brief += "- $line"; $mine += [pscustomobject]@{ dir = $w.FullName; branch = $br; dirty = $dirty; unpushed = $up }
    }
    $st = Get-KitAreaState $ag $own[$ix] $mine $lin.since @($sib.Keys | Where-Object { $_ -ne $ix } | ForEach-Object { $sib[$_] }) $rep[$ix]
    $sl = "$($ag.id) state: $($st.state)$(if ($st.skip.Count) { " (skip: $($st.skip -join ', '))" })"; "  $sl"; $brief += "- $sl"
    $brief += @('', "| $($ag.id) item | State | Done: skipped | Missing: runs | MRs | Tracker | Testing doc | Deployed |", '|---|---|---|---|---|---|---|---|')
    foreach ($i in $st.items) {
      $mx = @($i.mrs | ForEach-Object { "$($_.url) $($_.state)" }) -join ', '; $miss = @($script:KitSteps | Where-Object { $i.done -notcontains $_ }) -join ', '
      "    item $($i.item): $($i.state); runs: $(if ($miss) { $miss } else { 'nothing' })$(if ($mx) { "; MRs: $mx" })$(if ($i.tracker) { "; tracker $($i.tracker)" })"
      $brief += "| $($i.item) | $($i.state) | $($i.done -join ', ') | $miss | $mx | $($i.tracker) | $($i.doc) | $(if ($i.deployed) { 'yes' } else { 'no' }) |"
    }
    $brief += ''
    $resume[$ag.id] = [ordered]@{ state = $st.state; skip = $st.skip; doc = "$(@($st.items.doc | Where-Object { $_ })[0])"; mrs = @($st.mrs | ForEach-Object { [ordered]@{ url = $_.url; repo = $_.repo; merged = $_.state -eq 'merged' } }); worktrees = @($mine.dir); uncommitted = @($mine | Where-Object dirty | ForEach-Object { "$($_.dir) ($($_.dirty) file(s))" }) }
    if ($ours[$ix] -and -not $ck.done) { $l = "$($ag.id) checkpoint: next $($ck.next); done: $(@($ck.steps | ForEach-Object { "$($_.step) $($_.evidence)".Trim() }) -join '; ')"; "  $l"; $brief += "- $l (start there; crafty.ps1 checkpoint -Agent $($ag.id) -Read)" }
  }
  foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ -and $_.run -eq $s.run })) { "  decision pending: $($d.id) $($d.agent) item $($d.item): $($d.question)" }
  if ($s.leaf -eq 'testy.js' -and $a.runDir) { "  QA run folder: $($a.runDir) (unpublished items: below)" }
  if ($s.leaf -eq 'buildy.js' -and $agents.Count) {
    $rf = Join-Path (Get-KitPath launches -Create) "$(ConvertTo-KitSlug $(if ($s.runId) { $s.runId } else { $s.run })).resume.md"
    $txt = @("# Resume brief: $($s.run) (``$($s.leaf)`` $($s.runId))", "**Result:** mode resume; the original brief ``$($a.brief)`` wins where this differs.",
      '**Takeover:** `board join -Agent <id> -Resume` (TAKEOVER); `crafty.ps1 wt lease -Branch <b>` per branch (the slot that has it) + `wt status`; read the task, comments, open / merged MRs;',
      'continue, never redo finished work; files changing under you (another writer): stop, report. Steps per item (host + tracker, checked now): build, review,',
      'ci, merge, testing-doc, tracker; done: skipped, missing: run; unknown = a call failed: check it first.', '', '## State at recovery', '') + $brief
    Write-KitAtomic $rf (($txt -join "`n") + "`n")
    "  resume brief: $rf"
  }
  if ($s.runId) { "  RESUME$(if ((Test-KitHolder $(if ($s.record) { $s.record } else { $lr })) -eq $false) { ' (refused: its session ended, use RELAUNCH)' }): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', resumeFromRunId: '$($s.runId)', args: $aj })" }
  if ($s.leaf -eq 'buildy.js' -and $agents.Count) { $na = $aj | ConvertFrom-Json -AsHashtable; $na.brief = $rf -replace '\\', '/'; $na.mode = 'resume'; $na.resume = $resume; if (-not $na.agents) { $na.agents = @($agents | ForEach-Object { [ordered]@{ id = $_.id; items = $_.items } }) }
    foreach ($ra in $resume.Keys) { foreach ($u in $resume[$ra].uncommitted) { "  UNCOMMITTED: $ra $u`: the relaunched agent keeps them (never reset)" } }
    "  RELAUNCH (resume refused; finished steps skipped per area): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: $($na | ConvertTo-Json -Depth 30 -Compress) })" }
  elseif ($a.runDir) { "  RELAUNCH (resume refused): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: { runDir: '$($a.runDir)', kitDir: '$($KitConf.Kit -replace '\\', '/')' } }) (item claims skip published items)" }
  "  then: bossy.ps1 launch -RunId <new id> ... ; the old one: bossy.ps1 launch -Done -RunId $(if ($s.runId) { $s.runId } else { '<id>' })"
}
if (-not $runs.Count) { 'no stopped workflow runs' }
foreach ($q in Get-OrphanQaItems -Hours $Hours) { "== QA $($q.run): tested, never published: $($q.codes -join ', ')$(if ($q.fails) { " (unverified FAIL in $($q.fails -join ', '): checky first)" })"; foreach ($c in $q.codes) { "  & $($KitCmd.qa) finalize -RunDir '$($q.dir)' -Code $c" } }
Invoke-KitHooks Get-KitRecoverLines   # env and phone leases with no live holder
foreach ($b in @(Get-KitHandoffs $Hours)) { "== HANDOFF $($b.agent) ($($b.run)): a fresh $(if ($b.type) { $b.type } else { 'agent' }) with -Agent $($b.agent) -Run $($b.run) continues from $($b.handoffBrief) (a workflow agent: its workflow starts it)" }
foreach ($l in @(Invoke-KitOutbox -DryRun)) { "== tracker outbox: $l (bossy.ps1 supervise -AutoFix replays it)" }
"== heartbeat: $(Get-KitBeatArmLine)"
}

# ---- pause: checkpoint, commit WIP, release leases, stop
function Get-KitWtState([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return [pscustomobject]@{ dir = $Dir; gone = $true; dirty = @() } }
  [pscustomobject]@{ dir = $Dir; branch = "$(git -C $Dir branch --show-current 2>$null)".Trim(); head = "$(git -C $Dir rev-parse --short HEAD 2>$null)".Trim(); dirty = @(git -C $Dir status --porcelain 2>$null | ForEach-Object { "$_".Substring(3) }) }
}
function Set-KitLaunchField([string[]]$Files, [string]$Name, $Value) {
  foreach ($x in @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) { Invoke-KitLocked $x { $j = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json; if ($null -eq $Value) { $j.PSObject.Members.Remove($Name) } else { $j | Add-Member -Force NoteProperty $Name $Value }; Write-KitState $x $j } }
}
# back in seconds, -Status, the finisher: supervise-resources.ps1 "pause"
function Invoke-Pause { param([string]$Run = '', [switch]$All, [string]$Reason = 'owner pause', [double]$Wait = 10, [switch]$Status, [string]$Finish, [switch]$Everyone) Start-KitPause @PSBoundParameters }

# ---- resume: paused and crashed runs; done steps verified (sha, MR), never redone
function Test-KitOnline([string]$HostName = $KitConf.GitHost, [int]$Ms = 5000, [int]$Port = [int](Get-KitParam 'net.probePort')) {   # all addresses at once: ConnectAsync(host) hung on dead IPv6
  if ($env:KIT_OFFLINE) { return $env:KIT_OFFLINE -eq '0' }
  $cs = @(try { foreach ($ad in [Net.Dns]::GetHostAddresses($HostName)) { $c = [Net.Sockets.TcpClient]::new($ad.AddressFamily); $null = $c.ConnectAsync($ad, $Port); $c } } catch {})
  $pm = [math]::Max(10, [int](Get-KitParam 'net.pollMs')); try { for ($t = 0; $cs.Count -and $cs.Connected -notcontains $true -and $t -lt $Ms; $t += $pm) { Start-Sleep -Milliseconds $pm }; $cs.Connected -contains $true } finally { $cs | ForEach-Object Dispose }
}
$script:KitMrNow = @{}   # one fresh read per MR per resume: agents share MRs
function Test-KitStepEvidence($st) {
  $e = "$($st.evidence)".Trim()
  $u = if ($e -match '^https?://') { ConvertFrom-MrUrl $e } elseif ($e -match '^(?<r>[\w./-]+)!(?<n>\d+)$') { @{ repo = (Get-HostProject $Matches.r -Raw); n = $Matches.n } }
  if ($u) { $mk = "$($u.repo)!$($u.n)"; if (-not $script:KitMrNow.ContainsKey($mk)) { $script:KitMrNow[$mk] = try { Invoke-HostVerb 'mr.get' $u -NoMemo } catch { $null } }; $h = $script:KitMrNow[$mk]; return [pscustomobject]@{ mr = $e; state = "$($h.state)"; text = "MR $(if ($h) { $h.state } else { 'UNKNOWN (host call failed): check it' })" } }
  $sha = if ($e -cmatch '^[0-9a-f]{7,40}$') { $e } else { $st.head }
  if ($st.dir -and $sha) { git -C $st.dir cat-file -e "$sha^{commit}" 2>$null; return [pscustomobject]@{ text = $(if ((Test-Path -LiteralPath $st.dir) -and -not $LASTEXITCODE) { "commit $sha present" } else { "commit $sha not found (rebased? check the branch; redo only what it lacks)" }) } }
  [pscustomobject]@{ text = $(if ($e -match '^https?://') { 'link recorded' } else { 'recorded' }) }
}
function Invoke-Resume {
param([string]$Run = '', [switch]$All, [double]$Wait = 0, [int]$Hours = 24, [int]$MaxSeconds = 150, [switch]$Everyone)   # paused runs: any age; crashed: $Hours
if (-not ($Run -or $All)) { 'usage: bossy.ps1 resume -Run <run> | -All [-Wait <min> for the network] [-Hours 24] [-MaxSeconds 150]'; exit 2 }
$until = (Get-Date).AddMinutes($Wait)
while (-not (Test-KitOnline)) {
  if ((Get-Date) -ge $until) { "OFFLINE: $($KitConf.GitHost):443 unreachable; resume needs the git host and the tracker. Connect, then run bossy.ps1 resume again (-Wait <min> waits for the network)"; exit 1 }
  Wait-KitPoll 30
}
$pauses = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($Everyone -or -not (Get-KitRunOwner $_)) -and ($All -or $_.run -in '*', $Run) })   # another live coordinator's pause: its own resume
foreach ($p in $pauses) { foreach ($r in @($p.runs)) { foreach ($pair in @(, @($r.file, $r.launch)) + @(, @($r.selfFile, $r.self))) {   # cleanup may have removed them
  if ($pair[0] -and $pair[1] -and -not (Test-Path -LiteralPath $pair[0])) { New-Item -ItemType Directory -Force (Split-Path $pair[0]) | Out-Null; Write-KitAtomic $pair[0] ($pair[1] | ConvertTo-Json -Depth 30) } } }
  foreach ($a in @($p.agents | Where-Object { $_.checkpoint })) { $cf = Get-KitCheckpointFile $a.agent "$($a.checkpoint.run)" -Write; if (-not (Test-Path -LiteralPath $cf)) { New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null; Write-KitAtomic $cf ($a.checkpoint | ConvertTo-Json -Depth 6) } } }   # cleanup: agents/ after 7 d
$script:KitDeadline = (Get-Date).AddSeconds($MaxSeconds)   # recover below shares it
Invoke-KitHooks Close-KitFinishedRuns   # adapters/supervise-resources.ps1
$null = Set-KitBoardCrashed
$go = @(); $todo = @(Get-StoppedRuns -Hours $Hours | Where-Object { $All -or $_.run -eq $Run }); $ri = 0
foreach ($s in $todo) {
  if ((Get-Date) -ge $script:KitDeadline) { $rest = @($todo | Select-Object -Skip $ri); "partial: time budget ($MaxSeconds s) used; $($rest.Count) run(s) not resumed: $(@($rest.run) -join ', '). Rerun: bossy.ps1 resume -Run <run> (one each); the pause stays"; $pauses = @(); break }
  $ri++; if (($ow = Get-KitOwnedLine $s $Everyone)) { $ow; $pauses = @($pauses | Where-Object run -ne $s.run); continue }   # its pause stays
  "== $($s.leaf) run $($s.run) ($(if ($s.paused) { 'paused' } else { 'crashed' }))"
  $board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object run -eq $s.run)
  $waiting = @($board | Where-Object { $_.paused -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 3 })   # paused agents beat every 1.5 min
  Set-KitLaunchField @($s.file, $s.selfFile) paused $null; Set-KitLaunchField @($s.file, $s.selfFile) learned $null   # next stop learns again
  if ($waiting.Count) { "  still running: $(@($waiting.agent) -join ', ') wait in board leave; released, they rejoin and continue (no relaunch)"; continue }
  $lr = Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json
  $wf = @(Get-KitWorkflowDirs | Where-Object { $s.runId -and $_.Name -eq $s.runId })[0]
  $jl = @(if ($wf -and (Test-Path (Join-Path $wf.FullName 'journal.jsonl'))) { Get-Content (Join-Path $wf.FullName 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } })
  $res = @($jl | Where-Object type -eq 'result' | ForEach-Object agentId)
  $steps = @($jl | Where-Object type -eq 'started' | ForEach-Object { [pscustomobject]@{ who = ($_.label -split ':', 2)[-1] -replace '@.*$', ''; done = $_.agentId -in $res } })
  $mrs = @(); $noMr = 0   # checky's checkpoints under its <CODE>
  $cks = @(Get-ChildItem (Get-KitPath agents) -Filter 'resume*.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.run -eq $s.run } | ForEach-Object agent)
  foreach ($ag in @(@(@($lr.args.agents) | ForEach-Object { $_.id }) + @($board.agent) + $cks | Where-Object { $_ } | Select-Object -Unique)) {
    $mySteps = @($steps | Where-Object who -eq $ag)
    $ck = Get-KitCheckpoint $ag "$($s.run)"
    if (-not $ck -or $ck.done -or ($ck.run -and $ck.run -ne $s.run)) { "  $ag`: no open checkpoint$(if ($mySteps.Count -and -not @($mySteps | Where-Object { -not $_.done }).Count) { '; its steps have journal results: not relaunched (resumeFromRunId keeps them)' })"; continue }
    $b = @("# Resume brief: $ag (run ``$($s.run)``)", "**Result:** Start AT step: $($ck.next); the steps below are done, verified: never redo them.", '', '## Done (verified)', '')
    if (-not @($ck.steps | Where-Object step -eq 'mr').Count) { $noMr++ }
    $b += Format-KitMdTable 'Step', 'Item', 'Evidence', 'Check' @(foreach ($st in @($ck.steps)) { $v = Test-KitStepEvidence $st; if ($v.mr) { $mrs += $v }; , @($st.step, $st.item, $st.evidence, $v.text) })
    $b += @('', "## Interrupted step ``$($ck.next)``", 'Rerun it from the kept diff (never discard it).', '') + @(Format-KitMdTable 'Worktree', 'Branch @ head', 'Uncommitted (kept)' @(foreach ($d in @($ck.worktrees)) { $w = Get-KitWtState $d; , @("``$d``", $(if ($w.gone) { 'GONE: recreate the worktree from its branch' } else { "$($w.branch) @ $($w.head)" }), "$($w.dirty -join ', ')") }))
    $b += @('', '## Open', '', "**Leases to take again:** $(@($ck.leases) -join ', ')", "**Decisions:** $(@($ck.decisions) -join ', ')")
    $bf = Get-KitResumeBriefFile $ag "$($s.run)"; Write-KitAtomic $bf (($b -join "`n") + "`n")
    "  $ag`: resume at '$($ck.next)' -> $bf"
  }   # streamed: each line as it is known
  $openMrs = @($mrs | Where-Object { $_.state -ne 'merged' })
  if ($mrs.Count -and -not $openMrs.Count -and -not $noMr) { "  all $($mrs.Count) MR(s) merged: the relaunch runs only the missing post-merge steps (recover's per-area skip list)" }
  $go += $s.run
}
# '*' pause resumed for one run: others stay paused
foreach ($p in $pauses) { Invoke-KitLocked $p.file { $j = Get-Content -LiteralPath $p.file -Raw | ConvertFrom-Json; if ($All -or $j.run -ne '*') { $j.state = 'resumed'; $j | Add-Member -Force NoteProperty resumedAt (Get-KitStamp) } else { $j | Add-Member -Force NoteProperty released @(@($j.released) + $Run | Where-Object { $_ } | Select-Object -Unique) }; Write-KitState $p.file $j } }
if ($go.Count) { Invoke-Recover -Run $go -Hours $Hours -MaxSeconds $MaxSeconds -Everyone:$Everyone } else { 'nothing to relaunch' }
}

# ---- program: coordinator state per program, read after a restart
function Invoke-Program {
param([Parameter(Position = 0)][ValidateSet('set', 'get', 'list')][string]$Action = 'list', [string]$Program, [string]$Key, [string]$Value, [switch]$Json)
$dir = Get-KitPath programs -Create
if ($Action -eq 'list') { Get-ChildItem $dir -Filter '*.json' | ForEach-Object BaseName; return }
if (-not $Program -or ($Action -eq 'set' -and -not $Key)) { 'usage: bossy.ps1 program set -Program <name> -Key <k> -Value <text | JSON> | get -Program <name> [-Key <k>] [-Json] | list'; exit 2 }
$f = Join-Path $dir "$(ConvertTo-KitSlug $Program).json"
$read = { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
if ($Action -eq 'set') {
  if ($Key -in 'schemaVersion', 'updated', 'holder') { "program set: '$Key' is a state field (STATE.md): pick another key"; exit 2 }
  $v = try { $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $Value }
  Invoke-KitLocked $f { $p = & $read; $p[$Key] = $v; $p.Remove('_updated'); Write-KitState $f $p }
  "program $Program`: $Key set"; return
}
$p = & $read
if ($Key) { if (-not $p.ContainsKey($Key)) { "program $Program has no key $Key"; exit 1 }; $p = $p[$Key] }
if ($Json -or $p -isnot [string]) { ConvertTo-Json -InputObject $p -Depth 20 } else { $p }
}

# open = no successor: none marked, no later row of that agent (not $Except) in its run, or any run for a one-per-machine agent
# named after its type (kitty ran as kit-build); area ids (D1) repeat across runs
# a handoff's successor: same run, or same type + area on the next letter suffix (kit-x-1520c -> kit-x-1520d)
function Test-KitRunLineage($Ho, $Row) { "$($Row.run)" -eq "$($Ho.run)" -or ($Ho.run -and $Ho.type -and $Row.type -eq $Ho.type -and "$($Row.area)" -eq "$($Ho.area)" -and ("$($Row.run)" -replace '(?<=\d)[a-z]$') -eq ("$($Ho.run)" -replace '(?<=\d)[a-z]$')) }
function Get-KitHandoffs([double]$Hours = 48, [string]$Except = '') {
  $boardRows = @(Read-KitJsonFiles (Get-KitPath board))
  @($boardRows | Where-Object { $ho = $_; $ho.handoffBrief -and -not $ho.continuedBy -and ((Get-Date) - [datetime]$ho.beat).TotalHours -lt $Hours -and
      -not @($boardRows | Where-Object { (($_.agent -eq $ho.agent -and ("$($_.run)" -eq "$($ho.run)" -or $ho.agent -eq $ho.type)) -or ($_.agent -ne $ho.agent -and (Test-KitRunLineage $ho $_) -and "$($_.run)" -ne "$($ho.run)")) -and $_.session -ne $Except -and $_.session -ne $ho.session -and $_.joined -and [datetime]$_.joined -gt [datetime]$ho.beat }).Count })
}

# task '0' broke every promote
function NormTask($id) {
  $id = "$id".Trim().Trim("'", '"').Trim()
  if ($id -match '\s|!\d+$') { $id = if (($rx = Get-KitTaskTagRx) -and $id -match $rx) { $Matches.id } else { '' } }   # a title -> its tagged id; an MR ref is no task
  if ($KitConf.TrackerTag) { $id = $id -replace "^(?i)$([regex]::Escape($KitConf.TrackerTag))", '' }
  if ($id -match '^(0+|-+|x+|none|null|undefined|n/?a|tbd|todo|task|id|task-?id|placeholder|<[^>]*>|\{[^}]*\})?$') { return '' }   # a brief's placeholder (PLACEHOLDER, <task>) is no id
  $id
}

# ---- param: learned parameters (lib.ps1)
function Invoke-Param {
param([Parameter(Position = 0)][ValidateSet('show', 'history', 'learn', 'pin', 'unpin', 'freeze', 'reset', 'approve')][string]$Action = 'show', [Parameter(Position = 1)][string]$Key, [Parameter(Position = 2)][string]$Value, [string]$Context = '', [switch]$Json)
if ($Action -eq 'learn') { foreach ($f in @(Invoke-ParamLearn)) { "[$($f.level)] $($f.what) -> $($f.action)" }; return }
$o = @(Invoke-KitParamVerb $Action $Key $Value $Context -Json:$Json); $o; if ("$($o[0])" -like 'ERROR*') { exit 2 }
}
# ---- track: task <-> MRs; promoted once all merge
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$repo" } else { $null } }
# search ignores in=source_branch
function Find-TaskMrs($task, $repos = $KitConf.TrackerRepos) {
  $tagged = "$($KitConf.TrackerTag)$task"
  @(foreach ($r in @($repos)) {
      $pp = ProjPath $r; if (-not $pp) { continue }
      @(@(Invoke-HostVerb 'mr.list' @{ repo = $pp; search = $tagged; searchIn = 'title'; state = 'all'; per_page = 50 }) +
        @(Invoke-HostVerb 'mr.list' @{ repo = $pp; state = 'all'; per_page = 100 } | Where-Object { "$($_.source_branch)" -match "(?i)$([regex]::Escape($tagged))(?![A-Za-z0-9])" })) |
        Where-Object { $_ -and $_.iid -and $_.state -ne 'closed' } | ForEach-Object { "$r!$($_.iid)" }
    }) | Select-Object -Unique
}
# a bug fix lands where the original ask shipped
function Get-TaskMrBranches([string[]]$Tasks) {
  foreach ($ref in @(@($Tasks | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Find-TaskMrs $_ }) | Select-Object -Unique)) {
    if ("$ref" -notmatch '^(?<r>[^!]+)!(?<i>\d+)$') { continue }
    $repo = $Matches.r; $iid = $Matches.i; $pp = ProjPath $repo; if (-not $pp) { continue }
    $m = Invoke-HostVerb 'mr.get' @{ repo = $pp; n = $iid }
    if ($m.target_branch) { [pscustomobject]@{ ref = $ref; repo = $repo; branch = [string]$m.target_branch } }
  }
}
# one stored ref per MR: URL, group/repo!n, alias -> repo!n
function NormRef($r) {
  $r = "$r".Trim().Trim("'", '"'); if ($u = ConvertFrom-MrUrl $r) { $r = "$($u.repo)!$($u.n)" }
  if ($g = $KitConf.GitlabGroup) { $r = $r -replace "^(?i)$([regex]::Escape($g))/(?=[\w./-]+!\d+$)" }
  if ($r -match '^([\w.-]+)!(\d+)$' -and ($al = (Get-KitMember $KitConf.RepoAliases ($Matches[1])))) { "$al!$($Matches[2])" } else { $r }
}
function ConvertTo-MrRef([string]$m) { if ($u = ConvertFrom-MrUrl $m) { "$(($u.repo -split '/')[-1])!$($u.n)" } else { $m.Trim() -replace '^[\w./-]+/(?=[\w.-]+!\d+$)' } }   # group/repo!n too
function Invoke-Track {
param([Parameter(Position = 0)][ValidateSet('add', 'run', 'show', 'rebuild', 'ignore', 'remove', 'rollup', 'forget-item', 'route')][string]$Action = 'show', [string]$Reason, [string]$From, [string]$To, [Alias('Items')][string[]]$Item = @(), [switch]$Rebuild, [switch]$Force, [string]$Task, [Alias('Mr')][string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @(), [string]$Wave, [switch]$Detail, [string]$HoldPromotion, [switch]$Status, [switch]$All, [switch]$Apply)
$ErrorActionPreference = 'SilentlyContinue'
if ($Rebuild) { $Action = 'rebuild' }
# throw is swallowed under SilentlyContinue
function Fail([string]$m) { Stop-KitVerb "track: $m" 1 }
if ($Action -eq 'ignore') { Add-KitMrIgnore @(Split-KitList $Mrs) $Reason
  # an MR of a task stays in its MR set: name the verb that drops it (a task waited on a closed, ignored MR)
  $igTasks = (Read-KitTracking).tasks; foreach ($igR in @(Split-KitList $Mrs | ForEach-Object { NormRef $_ })) { foreach ($igT in @($igTasks.Values | Where-Object { @($_.mrs | ForEach-Object { NormRef $_ }) -contains $igR })) { "NOTE $igR is an MR of task $($igT.task): ignore only hides it from the untracked-MR watch; to drop it from the task: bossy.ps1 track remove -Task $($igT.task) -Mrs $igR" } }; return }
if ($Action -eq 'show') { $rows = (Read-KitTracking).tasks
  foreach ($id in @(if ($Task) { NormTask $Task } else { $rows.Values | Where-Object { -not $_.done } | ForEach-Object task })) { $o = $rows[$id]; if (-not $o) { Fail "show: $Task untracked" }
    "$id : $(@($o.mrs) -join ', ') | $(if ($o.done) { 'done' } else { 'open' })$(if ($o.holdPromotion) { " | HELD: $($o.holdPromotion)" })" }; return }
$wavesDir = Get-KitPath waves
$script:holds = 0
function Hold($s) { if ($Quiet) { return }; if ($Detail -or $Task) { $s } else { $script:holds++ } }   # -Task (devtools.py finish): the held task named, not a count
$script:gone = @{}   # deleted in the tracker
$script:trackReadd = @()   # track add -Mrs: refs named again, out of the removed list
function TaskStatus($id) { try { [string](Get-TrackerTask $id).status } catch { if (Remove-KitGoneTask $id $_) { $script:gone[$id] = $true }; '' } }
# LAG only on the live status (no memo): moved on -> the LAG is dropped
function Test-LagLive($o) { $lv = try { [string](__Get-TrackerTask $o.task).status } catch { '' }; if (-not $lv -or (Test-TrackerStatus $lv 'open', 'inProgress', 'review')) { return $true }; $o.Remove('lagLine'); $null = Save $o -Run; $false }
# a held task already closed / in test is done (never promoted backwards); status read once per track.holdCheckMinutes
function HeldPast($o) { $nw = Get-Date; if ($o.holdCheckedAt -and ($nw - [datetime]$o.holdCheckedAt).TotalMinutes -lt [double](Get-KitParam 'track.holdCheckMinutes')) { return '' }
  $hs = TaskStatus $o.task; if (-not $hs -or $script:gone[$o.task]) { return '' }   # unread or deleted: retry next sweep, never re-saved
  $o.holdCheckedAt = (Get-KitStamp stored $nw); $past = Test-TrackerStatus $hs 'closed', 'inTest'
  if ($past) { $o.done = $true; $o.doneAt = $o.holdCheckedAt }; $null = Save $o -Run
  if ($past) { "DONE $($o.task): status '$hs' already past promoted; hold dropped ($(if ($o.holdPromotion) { $o.holdPromotion } else { 'planned areas' }))" } }
# a hold 'deferred items: <task> <why>, ...' whose every piece names another tracked task that is done is a fact gone stale:
# released with a line (owner 2026-11-23); free text ('pin 744') or the task's own id stays held
function Clear-KitStaleHold($o) {
  if ("$($o.holdPromotion)".Trim() -notmatch '^deferred items:\s*(?<l>.+)$') { return '' }
  $hp = "$($o.holdPromotion)"; $to = @([regex]::Split($Matches.l, ',(?![^()]*\))') | ForEach-Object { ($_.Trim() -split '[\s:]', 2)[0] } | Where-Object { $_ } | Select-Object -Unique)
  $all = (Read-KitTracking).tasks
  if (-not $to.Count -or @($to | Where-Object { $_ -eq $o.task -or -not $all[$_] -or -not $all[$_].done }).Count) { return '' }
  Update-KitTracking { param($t) if ($t.tasks[$o.task]) { $t.tasks[$o.task].Remove('holdPromotion') } }; $o.Remove('holdPromotion')
  "RELEASED $($o.task): hold '$hp' dropped: $($to -join ', ') done"
}
function Load($t) { $x = Read-KitState (Get-KitTaskFile $t); $o = if ($x.track -is [Collections.IDictionary]) { $x.track } else { (Read-KitTracking).tasks[$t] }   # one file, not all
  if ($o) { $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique) }; $o }   # old duplicates
function TaskOfMr($ref) {
  if (-not $KitConf.TrackerTag -or $ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return '' }
  $proj = ProjPath $Matches.repo; if (-not $proj) { return '' }
  $m = Invoke-HostVerb 'mr.get' @{ repo = $proj; n = $Matches.iid }
  foreach ($s in @($m.title, $m.source_branch)) { if ("$s" -match (Get-KitTaskTagRx)) { return (NormTask $Matches.id) } }
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
  # keep concurrent writes; -Run: track add owns holdPromotion / onMerged / wave / planReleased, add / remove own removed
  Update-KitTracking {
    param($all)
    $cur = $all.tasks[$o.task]
    if ($cur) {
      $newMrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ -and @($cur.mrs) -notcontains $_ })
      if ($o.done -and -not $cur.done -and [string]$cur.reopenedAt -ne [string]$o.reopenedAt) { $o.done = $false; $o.reopenedAt = $cur.reopenedAt; foreach ($k in $script:doneFields) { $o.Remove($k) } }
      elseif ($cur.done -and -not $o.done -and [string]$cur.reopenedAt -eq [string]$o.reopenedAt -and -not $newMrs.Count) { $o.done = $true; $o.doneAt = $cur.doneAt }
    }
    if ($cur -and $Run) { foreach ($k in 'holdPromotion', 'onMerged', 'wave', 'planReleased', 'removed', 'routes') { if ($cur.ContainsKey($k)) { $o[$k] = $cur[$k] } else { $o.Remove($k) } }
      $rmU = @(@($o.routedMrs) + @($cur.routedMrs) | Where-Object { $_ } | Select-Object -Unique); if ($rmU.Count) { $o.routedMrs = $rmU } else { $o.Remove('routedMrs') } }   # a route -Mrs during this run stays
    if ($cur) { foreach ($k in 'mrs', 'mergeAfter') { $o[$k] = @(@($o[$k]) + @($cur[$k]) | Where-Object { $_ } | Select-Object -Unique) }; if ($cur.discover) { $o.discover = $true } }
    # a removed MR stays off; track add -Mrs re-attaches it
    $rmSeen = @{}; $rmList = @(@($cur.removed) + @($o.removed) | Where-Object { $_ -and $_.mr -and -not $rmSeen.ContainsKey("$($_.mr)") -and "$($_.mr)" -notin $script:trackReadd } | ForEach-Object { $rmSeen["$($_.mr)"] = 1; $_ })
    if ($rmList.Count) { $o.removed = $rmList } else { $o.Remove('removed') }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ -and -not $rmSeen.ContainsKey($_) } | Select-Object -Unique)
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
    foreach ($p in (Get-KitProps $w.agents)) {
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
  if (-not $proj) { return 'bad-ref (use <group/repo>!<iid>, or set "gitHostGroup" in kit.local.json)' }
  $m = Invoke-HostVerb 'mr.get' @{ repo = $proj; n = $Matches.iid }
  if (-not $m) { return 'unknown' }
  if ($m.state -eq 'opened' -and $m.head_pipeline -and ($ps = ConvertTo-KitCiState "$($m.head_pipeline.status)") -in 'failed', 'canceled') { return "opened (pipeline $ps)" }
  if ($m.state -eq 'opened' -and ($m.has_conflicts -or $m.detailed_merge_status -eq 'conflict')) { return 'opened (conflict)' }
  $m.state
}
# a route's MRs: a run's from its wave file (agents.*.mrs), a task's from its tracking
function RouteRefs($rt) {
  $rr = if ("$($rt.kind)" -eq 'run') { $wf = Join-Path $wavesDir "$($rt.to).json"; if (Test-Path -LiteralPath $wf) { $w = Get-Content -LiteralPath $wf -Raw | ConvertFrom-Json; foreach ($p in (Get-KitProps $w.agents)) { foreach ($m in @($p.Value.mrs)) { if ($m.url) { $m.url } else { "$m" } } } } }
    else { @((Read-KitTracking).tasks["$($rt.to)"].mrs) }
  @(@($rr) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
}
# MR links: the task's Items checklist (adapters/task-rollup.ps1), no MRs comment
function Set-KitTaskMrItems($id) { if ($fn = Get-Command Update-KitTaskItems -ErrorAction Ignore) { try { $null = & $fn $id (Get-TrackerTask $id) -Force } catch { Write-Warning "Items of ${id} not updated: $_" } } }
switch ($Action) {
  'rebuild' { Invoke-TrackRebuild }
  'add' {
    $given = $Task; $Task = NormTask $Task
    $refs = @(@($Mrs -split '\s*,\s*') | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $titled = @($refs | ForEach-Object { TaskOfMr $_ } | Where-Object { $_ } | Select-Object -Unique)
    if ($Task) { if ($titled.Count -and $titled -notcontains $Task) { "NOTE: the MR title names $($titled -join ', '); registering under -Task $Task" } }
    elseif ($titled.Count -eq 1) { $Task = $titled[0]; "NOTE: registering under $Task (MR title)" }
    elseif ($titled.Count) { Fail "add: the MRs name different tasks in their titles ($($titled -join ', ')): register each task with its own MRs" }
    if (-not $Task) { Fail "add needs a real -Task id (got '$given'; the tracker id without its tag, as in the MR title)" }
    try { $Task = Resolve-TrackerId $Task } catch { Fail "add: $_" }   # kit key -> native id
    $o = Load $Task; if (-not $o) { $o = @{ task = $Task; mrs = @(); onMerged = @($OnMerged -split '\s*,\s*'); done = $false; created = (Get-KitStamp) } }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $before = @($o.mrs).Count; $script:trackReadd = @($refs)
    if ($Discover -and @($KitConf.TrackerRepos).Count) { $refs = @(@($refs) + @(Find-TaskMrs $Task) | Select-Object -Unique); $o.discoveredAt = (Get-KitStamp) }
    $o.mrs = @(@($o.mrs) + $refs | Where-Object { $_ } | Select-Object -Unique)
    if ($PSBoundParameters.ContainsKey('OnMerged')) { $o.onMerged = @($OnMerged -split '\s*,\s*') }
    if ($Discover) { $o.discover = $true }
    if ($Wave) { $o.wave = $Wave }
    if ($PSBoundParameters.ContainsKey('HoldPromotion')) { if ($HoldPromotion) { $o.holdPromotion = $HoldPromotion } else { $o.Remove('holdPromotion'); $o.planReleased = (Get-KitStamp) } }   # '' also releases the planned areas launched before now
    if ($MergeAfter) {
      $o.mergeAfter = @(@($o.mergeAfter) + @($MergeAfter -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique)
      # it would merge before its producer
      foreach ($pair in @($MergeAfter -split '\s*,\s*' | Where-Object { $_ })) {
        $p = $pair -split '>', 2; if ($p.Count -ne 2 -or (NormRef $p[0]) -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { continue }
        $pp = ProjPath $Matches.repo; $ci = $Matches.iid; if (-not $pp -or (MrState (NormRef $p[1])) -eq 'merged') { continue }
        $m = Invoke-HostVerb 'mr.get' @{ repo = $pp; n = $ci }
        if ($m.merge_when_pipeline_succeeds) { $null = Invoke-HostVerb 'mr.unauto' @{ repo = $pp; n = $ci }; "NOTE: cancelled the scheduled merge of $(NormRef $p[0]): it merges after $(NormRef $p[1])" }
      }
    }
    if ($o.done -and @($o.mrs).Count -gt $before) { $o.done = $false; $o.reopenedAt = (Get-KitStamp); foreach ($k in $script:doneFields) { $o.Remove($k) } }
    elseif (-not $o.done) { $o.done = $false }
    Save $o; $s = Load $Task; Set-KitTaskMrItems $Task
    "tracking $Task : $(@($s.mrs) -join ', ')$(if (@($s.mergeAfter).Count) { ' | merge-after: ' + (@($s.mergeAfter) -join ', ') }) -> on all merged: $(@($s.onMerged) -join ' -> ')$(if ($s.holdPromotion) { " (promotion HELD: $($s.holdPromotion))" })$(if ($Discover -and -not @($s.mrs).Count) { ' (no MR found yet: every run looks again)' })"
    if (@($s.mrs).Count -and -not @($s.mrs | Where-Object { (MrState $_) -ne 'merged' }).Count) { Invoke-Track run -Task $Task -Detail:$Detail -Quiet:$Quiet }
  }
  'run' {
    $script:planRecs = $null   # launches + waves: read once per run
    $igRefs = @((Read-KitState (Get-KitPath mr-ignore)).mrs.Keys | ForEach-Object { NormRef $_ })   # track ignore + closed: not a task's work
    # a later push cancels merge-when-green
    $am =(Read-KitTracking).automerge
    if ($am.Count -and -not $Task) {
      $keep = @{}
      foreach ($ref in @($am.Keys)) {
        if ($ref -notmatch '^(?<proj>.+)!(?<iid>\d+)$') { continue }
        $amProj = $Matches.proj; $iid = $Matches.iid
        $m = Invoke-HostVerb 'mr.get' @{ repo = $amProj; n = $iid }
        if (-not $m) { $keep[$ref] = $am[$ref]; continue }
        if ($m.state -ne 'opened') { continue }
        $keep[$ref] = $am[$ref]
        $hp = if ($m.head_pipeline) { ConvertTo-KitCiState "$($m.head_pipeline.status)" }
        if ($m.merge_when_pipeline_succeeds -or $m.draft -or $m.has_conflicts -or $m.detailed_merge_status -eq 'conflict' -or $hp -in 'failed', 'canceled') { continue }
        # no head pipeline: the host would merge at once
        if (-not $m.head_pipeline) { continue }
        if ((ProducerOpen $amProj $iid) -or (InFlight "$(($amProj -split '/')[-1])!$iid")) { continue }
        # repos[] mergeMethod / deleteBranch; not green yet: merge when green
        $r = Invoke-HostVerb 'mr.merge' @{ repo = $amProj; n = $iid; sha = $null; auto = ($hp -ne 'success') }
        "re-armed merge-when-green for $ref (it was dropped, probably by a push after scheduling): $(if ($r.state -eq 'merged') { 'merged' } elseif ($r.merge_when_pipeline_succeeds) { 'scheduled' } else { 'FAILED - check the MR' })"
      }
      $gone = @($am.Keys | Where-Object { -not $keep.ContainsKey($_) })
      if ($gone) { Update-KitTracking { param($t) foreach ($r in $gone) { $t.automerge.Remove($r) } } }
    }
    # a done task's stale hold still unticks its Items: released too
    if (-not $Task) { foreach ($sh in @((Read-KitTracking).tasks.Values | Where-Object { $_.done -and $_.holdPromotion })) { if (($rl = Clear-KitStaleHold $sh) -and -not $Quiet) { $rl } } }
    # least recently checked first: no starving
    foreach ($id in @((Read-KitTracking).tasks.Values | Where-Object { -not $_.done -and (-not $Task -or $_.task -eq $Task) } | Sort-Object { [string]$_.checkedAt } | ForEach-Object task)) {
      $o = Load $id; if (-not $o -or $o.done) { continue }   # fresh: a hold added meanwhile counts
      if (($real = NormTask $id) -ne $id) {   # an MR ref or title as task id (ATTENTION never cleared): moved
        if (-not $real) { $real = @($o.mrs | ForEach-Object { TaskOfMr $_ } | Where-Object { $_ })[0] }
        Update-KitTracking { param($t) if ($real) { $n = if ($t.tasks[$real]) { $t.tasks[$real] } else { $c = @{}; foreach ($f in $o.Keys) { $c[$f] = $o[$f] }; $c }   # hold, onMerged, wave kept
            $n.task = $real; foreach ($f in 'mrs', 'mergeAfter') { $n[$f] = @(@($n[$f]) + @($o[$f]) | Where-Object { $_ } | Select-Object -Unique) }; $t.tasks[$real] = $n }; $t.tasks.Remove($id) }
        if ($real) { "MOVED $id`: no tracker id; its MRs track under $real" } else { "ATTENTION $id`: no tracker id, dropped: register its MRs: bossy.ps1 track add -Task <id> -Mrs $(@($o.mrs) -join ',')" }; continue
      }
      $o.checkedAt = (Get-KitStamp); Save $o -Run
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      # merged 60+ min, not promoted, not HELD = LAG
      if ($o.lagLine -and -not $o.holdPromotion -and $o.lagAt -and ((Get-Date) - [datetime]$o.lagAt).TotalMinutes -lt (Get-KitParam 'track.lagRecheckMinutes') -and -not $Quiet -and (Test-LagLive $o)) { $o.lagLine }
      if (@($o.mrs).Count -and (-not $o.lagAt -or ((Get-Date) - [datetime]$o.lagAt).TotalMinutes -ge (Get-KitParam 'track.lagRecheckMinutes'))) {
        $o.lagAt = (Get-KitStamp); $o.Remove('lagLine'); Save $o -Run
        $ms = @($o.mrs | Where-Object { -not ((MrState $_) -eq 'closed' -and $_ -in $igRefs) } | ForEach-Object { MrState $_ }); $ls = TaskStatus $o.task
        if ($ls -and @($ms | Where-Object { "$_" -like 'opened*' }).Count -and (Test-TrackerStatus $ls 'open')) {
          $lr = try { if (($rv = "$(Set-TrackerStatus $o.task 'review')") -like 'SKIPPED*') { "KEPT $($o.task): $($rv.Substring(9))" } else { "DONE $($o.task): status '$ls' -> review (its MR is open)" } } catch { "ATTENTION $($o.task): could not set status 'review' (status '$ls' lags its open MR): $_" }
          if (-not $Quiet) { $lr }
        } elseif ($ls -and -not @($ms | Where-Object { $_ -ne 'merged' }).Count -and (Test-TrackerStatus $ls 'open', 'inProgress', 'review')) {
          if (-not $o.mergedSeenAt) { $o.mergedSeenAt = (Get-KitStamp); Save $o -Run }
          elseif (-not $o.holdPromotion -and ((Get-Date) - [datetime]$o.mergedSeenAt).TotalMinutes -ge (Get-KitParam 'track.lagMinutes') -and (Test-LagLive $o)) { $o.lagLine = "LAG $($o.task): all MRs merged at $(([datetime]$o.mergedSeenAt).ToString('HH:mm')), status still '$ls'"; Save $o -Run; if (-not $Quiet) { $o.lagLine } }
        }
      }
      foreach ($pair in @($o.mergeAfter)) {
        if ($pair -notmatch '^(?<dep>[^>]+)>(?<on>.+)$') { continue }
        $dep = $Matches.dep.Trim(); $on = $Matches.on.Trim()
        $owner = InFlight $dep
        if ($owner) { Hold "HOLD $($o.task): $dep waits for its review ($owner still running)"; continue }
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w./-]+)!(?<iid>\d+)$') {
          $rn = ($Matches.repo -split '/')[-1]; $wt = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ($_.name -eq $rn -or @($_.aliases) -contains $rn) } | ForEach-Object checkout | Select-Object -First 1
          if (-not $wt) { $wt = Join-Path $KitConf.ReposRoot $rn }
          $res = if (-not (Test-Path $wt)) { "no checkout at $wt - set repos[].checkout in kit.local.json" } else { python -X utf8 $KitCmd.devtools merge $wt $Matches.iid 2>&1 }
          if (-not $Quiet) { "MERGE-AFTER $($o.task): $on merged -> $dep : $res" }
        }
        if ($o.mrs -notcontains $dep) { $o.mrs = @(@($o.mrs) + $dep) }
      }
      if ($o.holdPromotion -and ($rl = Clear-KitStaleHold $o) -and -not $Quiet) { $rl }
      if ($o.holdPromotion -and ($hp = HeldPast $o)) { if (-not $Quiet) { $hp }; continue }
      if ($o.holdPromotion) { Hold "HOLD $($o.task): promotion held ($($o.holdPromotion)); release: bossy.ps1 track add -Task $($o.task) -HoldPromotion ''"; continue }
      # track route: the fix lands in other MRs; new ones join this task
      if (@($o.routes | Where-Object { $_ }).Count) {
        $rtOff = @(@($o.removed) | ForEach-Object { "$($_.mr)" }) + @($o.routes | ForEach-Object { @($_.base) })
        $rtNew = @($o.routes | ForEach-Object { RouteRefs $_ } | Where-Object { $_ -notin $rtOff -and @($o.mrs) -notcontains $_ } | Select-Object -Unique)
        if ($rtNew.Count) { $o.mrs = @(@($o.mrs) + $rtNew); $o.routedMrs = @(@($o.routedMrs) + $rtNew | Where-Object { $_ } | Select-Object -Unique); Save $o -Run; Set-KitTaskMrItems $o.task }
        if (-not @($o.routedMrs | Where-Object { $_ }).Count) { Hold "HOLD $($o.task): routed to $(@($o.routes.to) -join ', '), no new fix MR there yet (one merged already: bossy.ps1 track add -Task $($o.task) -Mrs <it>)"; continue }
      }
      if ($o.discover) {
        if (-not @($KitConf.TrackerRepos).Count -and -not @($o.mrs).Count) { if (-not $Quiet) { "CONFIG $($o.task): -Discover needs ""trackerRepos"" in kit.local.json (or register MRs: bossy.ps1 track add -Task $($o.task) -Mrs <repo>!<iid>)" } }
        # slow search: every 30 min once MRs are known
        if (-not @($o.mrs).Count -or -not $o.discoveredAt -or ((Get-Date) - [datetime]$o.discoveredAt).TotalMinutes -ge 30) { $o.mrs = @(@($o.mrs) + @(Find-TaskMrs $o.task) | Where-Object { $_ } | Select-Object -Unique); $o.discoveredAt = (Get-KitStamp); Save $o -Run }
        if (-not @($o.mrs).Count) { continue }
        $cur = TaskStatus $o.task
        if ($script:gone[$o.task]) { "DROPPED $($o.task): deleted in the tracker, no longer tracked"; continue }
        if (-not (Test-TrackerStatus $cur 'review')) {
          $allMerged = -not @(@($o.mrs) | Where-Object { ($am0 = MrState $_) -ne 'merged' -and -not ($am0 -eq 'closed' -and $_ -in $igRefs) }).Count
          if (-not $allMerged) { $o.Remove('allMergedAt'); Save $o -Run; continue }
          if (-not $o.allMergedAt) { $o.allMergedAt = (Get-KitStamp); Save $o -Run; continue }
          if (((Get-Date) - [datetime]$o.allMergedAt).TotalMinutes -lt 20) { continue }
          if (-not $Quiet) { "NOTE $($o.task): status '$cur' was never set to review, but all MRs merged 20+ min ago - completing it" }
        }
      }
      if (-not @($o.mrs).Count) { Hold "HOLD $($o.task): no MR registered yet (bossy.ps1 track add -Task $($o.task) -Mrs <repo>!<iid>)"; continue }
      $states = @{}; foreach ($m in $o.mrs) { $states[$m] = MrState $m }
      foreach ($m in @($states.Keys)) { if ($states[$m] -eq 'closed' -and $m -in $igRefs) { $states.Remove($m) } }
      if (-not $states.Count) { Hold "HOLD $($o.task): its only MRs are closed and ignored (bossy.ps1 track remove -Task $($o.task) -Mrs <ref>)"; continue }
      $failed = @($states.GetEnumerator() | Where-Object { $_.Value -match 'pipeline (failed|canceled)|closed|conflict' })
      if ($failed) { if (-not $Quiet) { "ATTENTION $($o.task): $(($failed | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')" }; continue }
      if (@($states.Values | Where-Object { $_ -ne 'merged' }).Count) { continue }
      if ($planned = @(Get-KitPlannedAreas $o.task $o.planReleased -Merged)) { if ($hp = HeldPast $o) { if (-not $Quiet) { $hp }; continue }; $st = @($planned | Where-Object { $script:planStale[$_] }); Hold "HOLD $($o.task): MRs merged, planned area(s) $($planned -join ', ') not delivered yet ($(if ($st.Count) { "stale: $($st -join ', ') never joined, run $($script:planStale[$st[0]]) ended" } else { 'a later batch or wave' })); dropped for good: bossy.ps1 track add -Task $($o.task) -HoldPromotion ''"; continue }
      $held =@(Get-ChildItem $wavesDir -Filter '*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) } | ForEach-Object {
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
      $ciTask = Get-KitCiTask $o.task   # a CI job's task: the job passing again is its test, no testing docs
      if ($todo -contains 'promoted' -and -not $ciTask -and $KitConf.TrackerType -ne 'none' -and -not ($pg = Test-KitProcessGate promote @{ task = $o.task }).ok) { if (-not $Quiet) { "ATTENTION $($o.task): MRs merged, $(if ($pg.how -eq 'builtin:testingDocs' -and $pg.why -match '^task id not readable') { $pg.why } elseif ($pg.how -eq 'builtin:testingDocs') { 'no testing-doc link (process.docs)' } else { "process.gates.promote refused ($($pg.how)): $($pg.why)" }): not promoted (devtools.py finish $($o.task) <testing.md> <solution.md> --ai <ai.md>); MRs $(@($o.mrs) -join ', ')" }; continue }
      $setFailed = $false; $kept = ''
      $fixBack = if (Test-TrackerStatus $now 'failedTesting') { "failed testing, fixed by $(@($(if (@($o.routedMrs | Where-Object { $_ }).Count) { $o.routedMrs } else { $o.mrs })) -join ', ')" } else { '' }
      foreach ($s in $todo) { try { if (($sr = "$(Set-TrackerStatus $o.task $s $fixBack)") -like 'SKIPPED*' -and $sr -notmatch 'has no \w+ status') { $kept = $sr.Substring(9); break } } catch { $setFailed = $true; if (-not $Quiet) { "ATTENTION $($o.task): could not set status '$s' (retried next run): $_" }; break } }
      if ($setFailed) { continue }
      if ($kept) { $o.done = $true; Save $o -Run; "KEPT $($o.task): $kept"; continue }
      if ($ciTask) { Set-KitTaskMrItems $o.task; $cj = Close-KitCiTask $o.task $ciTask @($o.mrs)
        if ($cj.state -eq 'wait') { Hold "HOLD $($o.task): $($cj.why)" } elseif ($cj.state -ne 'closed') { if (-not $Quiet) { "ATTENTION $($o.task): $($cj.why)" } } else { $o.done = $true; $o.doneAt = (Get-KitStamp); Save $o -Run; "DONE $($o.task): $($cj.why)"; $script:merged = $true }; continue }
      $cmts =@(try { Get-TrackerComments $o.task } catch {}) | ForEach-Object { [string]$_.text }
      if ((Test-KitTaskDocLink $o.task) -ne $true -and -not ($cmts | Where-Object { $_ -match [string](Get-KitSetting 'locale.testCommentPattern' '(?i)how to test|test(ing)? (steps|guide|instructions|doc)|tester guide|live check') })) {
        $steps = @(Get-KitWorkflowDirs | ForEach-Object { Get-Item (Join-Path $_.FullName 'journal.jsonl') -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) } | Sort-Object LastWriteTime -Descending | ForEach-Object {
            foreach ($line in Get-Content $_.FullName) {
              $j = try { $line | ConvertFrom-Json } catch { $null }
              $mine = (@($j.result.done) -match [regex]::Escape($o.task)) -or @(@($j.result.mrs) | Where-Object { $o.mrs -contains (NormRef $_.url) }).Count
              if ($j.type -eq 'result' -and $mine -and @($j.result.needsLiveCheck).Count) { @($j.result.needsLiveCheck) }
            } } | Where-Object { $_ } | Select-Object -Unique)
        if ($steps.Count) {
          try { $null = Add-TrackerComment $o.task ("How to test (from the dev agent's report; run after the next deploy of the MRs in the Items checklist):`n" + (($steps | ForEach-Object { "- $_" }) -join "`n")) } catch {}
          "COMMENTED $($o.task): posted $($steps.Count) how-to-test step(s) from the agent's report (its own testing comment was missing)"
        } else {
          "ATTENTION $($o.task): merged, but no solution/testing comment from its agent - post the solution, MR links and how-to-test on the task"
        }
      }
      $o.done = $true; $o.doneAt = (Get-KitStamp); Save $o -Run; Set-KitTaskMrItems $o.task   # its Items tick
      "DONE $($o.task): all $(@($o.mrs).Count) MRs merged -> status $($o.onMerged -join ' -> ')"
      $script:merged = $true
    }
    if ($script:holds) { "HOLD: $($script:holds) task(s) waiting for their review/fix round (-Detail lists them)" }
    if ($script:merged) {
      Start-Detached (Resolve-Tool pwsh) @('-NoProfile', '-NonInteractive', '-File', $(if ($KitIsWindows) { "`"$($KitCmd.orch)`"" } else { $KitCmd.orch }), 'cleanup', '-WorktreesOnly', '-WorktreeIdleHours', "$(Get-KitParam cleanup.worktreeIdleHours)", '-Quiet')
    }
    try { Invoke-KitHooks Invoke-KitTrackRollup @{ Quiet = $Quiet } } catch { "ROLLUP hook failed: $("$_".Split("`n")[0])" }   # adapters/task-rollup.ps1: parents' delivery sections
  }
  'remove' {
    $rmTask = NormTask $Task; $rmRefs = @(Split-KitList $Mrs | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $rmTask -or -not $rmRefs.Count) { Stop-KitVerb "usage: bossy.ps1 track remove -Task <id> -Mrs '<repo>!<iid>[,...]' [-Reason '<why>']" }
    $rmO = Load $rmTask; if (-not $rmO) { Fail "remove: $rmTask is not tracked" }
    $rmMiss = @($rmRefs | Where-Object { @($rmO.mrs) -notcontains $_ }); if ($rmMiss.Count) { Fail "remove: $($rmMiss -join ', ') not on $rmTask (its MRs: $(@($rmO.mrs) -join ', '))" }
    $rmAt = (Get-KitStamp)
    Update-KitTracking { param($all) $rmCur = $all.tasks[$rmTask]
      $rmCur.mrs = @(@($rmCur.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ -and $_ -notin $rmRefs })
      $rmCur.mergeAfter = @(@($rmCur.mergeAfter) | Where-Object { -not @(@("$_" -split '>', 2) | ForEach-Object { NormRef $_ } | Where-Object { $_ -in $rmRefs }).Count })
      $rmCur.removed = @(@($rmCur.removed) | Where-Object { $_ -and "$($_.mr)" -notin $rmRefs }) + @($rmRefs | ForEach-Object { [ordered]@{ mr = $_; at = $rmAt; reason = $Reason } })
      foreach ($rmK in 'allMergedAt', 'mergedSeenAt', 'lagLine', 'lagAt') { $rmCur.Remove($rmK) } }   # merge state is re-read from the MRs left
    Set-KitTaskMrItems $rmTask; $rmS = Load $rmTask
    "removed $($rmRefs -join ', ') from $rmTask$(if ($Reason) { " ($Reason)" }): its MRs now $(if (@($rmS.mrs).Count) { @($rmS.mrs) -join ', ' } else { 'none' }); listed under removed (track add -Mrs re-attaches)"
  }
  'route' {   # a failed or [Bug] task fixed in another task's or run's wave (contracts addendum): it follows those MRs
    $rtFrom = NormTask $From; $rtTo = "$To".Trim()
    if (-not $rtFrom -or -not $rtTo) { Stop-KitVerb "usage: bossy.ps1 track route -From <failed or [Bug] task> -To <task id | run id> [-Items <check ids>] [-Mrs <its fix MRs already open or merged>]" }
    $rtKind = if (Test-Path -LiteralPath (Join-Path $wavesDir "$rtTo.json")) { 'run' } else { 'task' }
    if ($rtKind -eq 'task') { $rtTo = NormTask $rtTo; if (-not $rtTo -or $rtTo -eq $rtFrom) { Fail "route: -To $To is neither a run (no waves/$To.json) nor another task id" } }
    $rtGiven = @(Split-KitList $Mrs | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $rtO = Load $rtFrom; if (-not $rtO) { $rtO = @{ task = $rtFrom; mrs = @(); onMerged = @('promoted'); done = $false; created = (Get-KitStamp) } }
    if ($rtO.done) { $rtO.routes = @(); $rtO.routedMrs = @() }   # a finished route (promoted, then failed again) never counts for this one
    $rtAt = (Get-KitStamp); $rtR = [ordered]@{ to = $rtTo; kind = $rtKind; items = @(Split-KitList $Item); at = $rtAt }
    if ($rtKind -eq 'run') { & $KitCmd.orch report -Run $rtTo *> $null }   # the wave file lists MRs merged since its last report
    # merged before the route: not this defect's fix (named in -Mrs: it is); an unread state could hide one
    $rtSt = @{}; foreach ($rtRef in @(RouteRefs $rtR | Where-Object { $_ -notin $rtGiven })) { $rtSt[$rtRef] = MrState $rtRef }
    $rtUnk = @($rtSt.Keys | Where-Object { $rtSt[$_] -in 'unknown', 'bad-ref' -or "$($rtSt[$_])" -like 'bad-ref*' }); if ($rtUnk.Count) { Fail "route: MR state of $($rtUnk -join ', ') not read (host auth / gitHostGroup): nothing routed" }
    $rtR.base = @($rtSt.Keys | Where-Object { $rtSt[$_] -eq 'merged' })
    $rtO.routes = @(@($rtO.routes) | Where-Object { $_ -and "$($_.to)" -ne $rtTo }) + @($rtR)
    if ($rtGiven.Count) { $rtO.mrs = @(@($rtO.mrs) + $rtGiven | Where-Object { $_ } | Select-Object -Unique); $rtO.routedMrs = @(@($rtO.routedMrs) + $rtGiven | Where-Object { $_ } | Select-Object -Unique); $script:trackReadd = $rtGiven }
    if ($rtKind -eq 'run') { $rtO.wave = $rtTo }   # held while that run still fixes
    $rtO.done = $false; foreach ($k in $script:doneFields) { $rtO.Remove($k) }; $rtO.reopenedAt = $rtAt
    Save $rtO
    "routed $rtFrom -> $rtKind $rtTo$(if ($rtR.items.Count) { " (checks $($rtR.items -join ', '))" }): its new MRs join $rtFrom; all merged -> $rtFrom $(@($rtO.onMerged) -join ' -> ')$(if ($rtR.base.Count) { " (already merged there, not counted: $($rtR.base -join ', '))" })"
    Invoke-Track run -Task $rtFrom -Detail -Quiet:$Quiet
  }
  'rollup' { Invoke-TaskRollup -Task $Task -From $From -Quiet:$Quiet -Status:$Status -All:$All -Apply:$Apply }
  'forget-item' { Invoke-KitForgetItems -Task $Task -Item $Item }
}
}

# the table only, no network
function Invoke-Status([switch]$Watch, [int]$Seconds = 30, [switch]$Json, [string]$Session) {
  $ErrorActionPreference = 'SilentlyContinue'   # a journal mid-write
  do {
    $now = Get-Date; $rows = @(Get-KitStatusRows $now $Session)
    if ($Json) { ConvertTo-Json @($rows | Select-Object name, task, state, since, last, doing, wait, done, stopped, left, next) -Depth 3; return }
    $out = @(Format-KitStatusTable $rows $now $script:KitTxVersions) + @(Format-KitResourceTable @(Get-KitResourceRows))
    if ($Watch) { Clear-Host; "status $($now.ToString('HH:mm:ss')), every $Seconds s (Ctrl+C stops)"; '' }; $out
    if ($Watch) { Start-Sleep -Seconds $Seconds }
  } while ($Watch)
}
function Get-KitFinishedRuns { @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { $_.completed -and $_.runId } | ForEach-Object runId) }
# ---- supervise: coordinator heartbeat (FLAGS ACT / WATCH / INFO)
# coordAt on disk as text: a session that stepped aside mid-sweep stamped it (ConvertFrom-Json makes a DateTime)
# the last sweep: the lock's start while its pwsh runs, else the last finished report (a dead or hung sweep's lock never counts)
function Get-KitLastSweepAt { $h = try { Read-KitText (Join-Path (Get-KitPath cache -Create) 'supervise.lock') | ConvertFrom-Json -AsHashtable } catch { $null }
  $ra = try { (Read-KitText (Get-KitPath supervise-state) | ConvertFrom-Json -AsHashtable).report.at } catch { $null }
  # a live pid (a reused one started later never counts): its start or, a long-lived host, the report it finished since
  if ($h.at -and $h.pid) { $sp = Get-Process -Id ([int]$h.pid) -ErrorAction SilentlyContinue; if ($sp -and $sp.StartTime -le ([datetime]$h.at).AddSeconds(5)) { return @(@([datetime]$h.at) + @(if ($ra) { [datetime]$ra }) | Sort-Object)[-1] } }
  if ($ra) { [datetime]$ra } }
function Get-KitDiskCoordAt([string]$File) { $cv = try { (Read-KitText $File | ConvertFrom-Json -AsHashtable).coordAt } catch { $null }; if ($cv -is [datetime]) { (Get-KitStamp stored $cv) } else { "$cv" } }
function Invoke-Supervise {
param([string]$Session, [switch]$Json, [switch]$AutoFix, [switch]$Brief, [Alias('Resume')][switch]$Takeover, [string]$Ack, [string]$Reason = '')
$ErrorActionPreference = 'SilentlyContinue'
if ($Ack) {   # flag hidden 24 h
  if ($Ack.Trim().Length -lt 20 -and -not (Test-KitAckWhole $Ack)) { "supervise -Ack: give the flag's start, 20+ characters, or a short flag's whole text (a short start would hide other problems)"; exit 2 }
  $ackRes = Add-KitFlagAck $Ack $Reason; $ackRes; if ("$ackRes" -like 'REFUSED*') { exit 1 }; return
}
$idleMin = [double](Get-KitParam 'supervise.stuckMinutes')   # no progress longer, waiting on nothing = STUCK
$wfAgents = New-Object System.Collections.ArrayList; $runTotal = 0; $toolErr = 0; $errRun = ''; $now = Get-Date; $t0 = $now
$liveLabels = New-Object System.Collections.ArrayList; $runningLabels = New-Object System.Collections.ArrayList; $doneLabels = New-Object System.Collections.ArrayList
$flags = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
# $what stays whole for dedupe and -Ack
$actSec = @{}; $lastWithin = @{ n = $null }; function Set-ActSection($lvl, $what) { $sn = if ($kitSweep.cur) { $kitSweep.cur } else { $lastWithin.n }; if ($lvl -eq 'ACT' -and $sn) { $actSec[(Get-KitFlagKey $what)] = $sn } }   # a skipped section keeps its ACTs (Add-KitActObs)
function Flag($lvl, $what, $action, $cols) { Set-ActSection $lvl $what; [void]$flags.Add([pscustomobject](@{ level = $lvl; what = $what; action = $action } + $(if ($cols) { $cols } else { @{} }))) }
function L($s) { [void]$lines.Add($s) }
$lk = Join-Path (Get-KitPath cache -Create) 'supervise.lock'
Start-KitSweepMemo; $me = Get-SuperviseOwner $Session; Update-KitCoordinatorBeat   # the registry: this session's coordinator row stays live
$script:aside = $null
Invoke-KitLocked $lk {
  $held = if (Test-Path $lk) { try { Get-Content $lk -Raw | ConvertFrom-Json } catch { $null } }
  $myHolder = Get-KitHolder   # only a live other process blocks (not a restart or a dead holder)
  $other = $held -and $held.session -ne $me -and -not ($held.holderPid -and $held.holderPid -eq $myHolder.holderPid -and $held.holderStart -eq $myHolder.holderStart) -and (Test-KitHolder $held) -ne $false
  # report at most ~a beat old: the OS timer ticks every osTimerTickMinutes, sweeps once the last sweep is a beat old; a session skips one under half a beat
  $lsa = Get-KitLastSweepAt; $agoMin = if ($lsa) { ((Get-Date) - $lsa).TotalMinutes } else { 1e9 }; $asideMin = if ($me -eq 'os-timer') { Get-KitOsBeatAsideMinutes } else { (Get-KitBeatMinutes) * 0.5 }
  if (-not $Takeover -and ($other -or $me -eq 'os-timer') -and $agoMin -lt $asideMin) { $script:aside = "another session's supervisor ran $([int]$agoMin) min ago (session $($held.session)): this heartbeat steps aside (stop it, or -Takeover)"
    # a session that skips still beats: health OVERDUE reads coordAt
    if ($me -ne 'os-timer') { try { $sf0 = Get-KitPath supervise-state -Create; $st0 = Read-KitText $sf0 | ConvertFrom-Json -AsHashtable; if ($st0) { $st0.coordAt = (Get-KitStamp); Write-KitAtomic $sf0 ($st0 | ConvertTo-Json -Depth 5) } } catch {} }; return }
  Write-KitAtomic $lk (([ordered]@{ session = $me; at = (Get-KitStamp); pid = $PID } + $myHolder) | ConvertTo-Json)
}
if ($script:aside) { $script:aside; Get-KitAsideFlags $me; if ($Brief) { [Console]::Error.WriteLine("NEXT=$(Get-KitBeatMinutes)"); [Console]::Error.WriteLine("HEARTBEAT_PROMPT=$(Get-KitBeatPrompt)") } else { "NEXT $(Get-KitBeatMinutes) min (another session supervises)" }; return }
$budgetSeconds = if ($Brief) { [int](Get-KitSetting 'supervise.briefSeconds' 40) } else { 240 }
$deadline = (Get-Date).AddSeconds($budgetSeconds)
$apiLedger = Start-KitApiBeat   # its children's calls count too; a beat's shared host answers (K93)
$env:KIT_NET_TIMEOUT_SEC = [string][math]::Min(20.0, (Get-KitNetTimeout)); $env:KIT_NET_TRIES = '2'
function Left { [math]::Max(5, [int]($deadline - (Get-Date)).TotalSeconds) }
$stateFile = Get-KitPath supervise-state -Create
$state = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $state) { $state = @{} }
$kitSweep = New-KitSweep $deadline $state; function Within($name) { $lastWithin.n = $name; Test-KitSweep $kitSweep $name }   # learned cost, starved first; a cut-short section still names its ACT
function Phase($name) { Start-KitSweepPhase $kitSweep $name }   # ungated work, timed apart
Phase 'prefetch'; $null = @(Invoke-KitHooks Start-KitSupervisePrefetch)   # slow children start now, their sections read them
function Invoke-Bounded([string]$Script, [string[]]$A) { $bn = "$(Split-Path $Script -Leaf) $($A[0..1] -join ' ')"; $md = Get-KitSweepMode $A; Invoke-KitSweepCall $kitSweep $bn $Script $A -Background:($md -eq 'background') -Detached:($md -eq 'detached') -Job "$bn$(if ("$($A[1])".StartsWith('-')) { " $($A[2])" })" }   # budget -Run: 90 s; plan, deployed, intest, scope timed out inline
Phase 'budget usage'; $null = Invoke-Bounded $KitCmd.orch @('budget', '-Usage')   # detached first, outside the budget (gated: skipped most sweeps); own phase: the last prefetch hook was charged with it
Phase 'param learn'
if (-not $state.quietRuns) { $state.quietRuns = @{} }; if (-not $state.closedRuns) { $state.closedRuns = @{} }
# learned params: 3 s, when due (d-20261029173533)
if ($AutoFix) { try { foreach ($x in @(Invoke-ParamLearn -Due -Deadline (Get-Date).AddSeconds(3))) { Flag $x.level $x.what $x.action } } catch { Flag 'WATCH' "param learn failed: $_" 'Look at .state/params.json (bossy.ps1 param show).' } }

# 1. workflows
Phase 'workflows'; $wfDirs = @(Get-KitRecentWorkflowDirs $Session | Sort-Object KitLastWrite -Descending)
$doneAt = @{}; $finishedRuns = Get-KitFinishedRuns; $lnch = @(Read-KitJsonFiles (Get-KitPath launches)); $pausedRuns = @($lnch | Where-Object { $_.paused -and $_.runId -and -not $_.completed } | ForEach-Object runId)
if (-not $Session) { foreach ($q in $state.quietRuns, $state.closedRuns) { foreach ($k in @($q.Keys)) { if ($k -notin @($wfDirs | ForEach-Object Name)) { $q.Remove($k) } } } }   # -Session sees only its own runs
foreach ($w in $wfDirs) {
  $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
  $ev = @(Get-Content $j | ForEach-Object { $_ | ConvertFrom-Json })
  $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($r in $ev | Where-Object type -eq 'result') { $res[$r.agentId] = $r }
  foreach ($r in $res.Values) { $dl = [string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label; [void]$doneLabels.Add($dl); foreach ($nm in LabelNames $dl) { if (-not $doneAt[$nm] -or $doneAt[$nm] -lt $w.LastWriteTime) { $doneAt[$nm] = $w.LastWriteTime } } }
  if ($w.Name -in $finishedRuns) { continue }
  $wrec = @(Get-KitWorkflowRecords $w $ev $lnch); $wsc = "$(@($wrec | Where-Object script)[0].script)"
  $done = [bool]($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }) -or ($wsc -and (Get-Command Test-KitJournalFinished -ErrorAction SilentlyContinue) -and (Test-KitJournalFinished $w.FullName (Split-Path $wsc -Leaf) $(if (@($wrec | Where-Object { (Test-KitHolder $_) -eq $true }).Count) { 10 } else { 2 })))   # the engine writes no end marker
  # stale and closeable (lib Test-KitRunCloseable): its record closes, it stops counting as running
  if (-not $done -and $AutoFix -and -not $state.closedRuns[$w.Name] -and (Test-KitRunCloseable $w $wrec $ev $now) -and (Within 'run records')) {
    $state.closedRuns[$w.Name] = (Get-KitStamp stored $now); $null = Invoke-KitBackground "launch -Done $($w.Name)" $KitCmd.orch @('launch', '-Done', '-RunId', $w.Name)
    Flag 'INFO' "auto-fixed: run $($w.Name) went quiet with no end record: its launch record closes in the background" 'Nothing to do.'; Phase 'workflows'; continue }
  if (-not $done -and (Get-KitWorkflowStop $w $wrec)) { continue }   # stopped (TaskStop, restart)
  if ($done -and $AutoFix -and -not $state.closedRuns[$w.Name] -and (Within 'run records')) {
    $state.closedRuns[$w.Name] = (Get-KitStamp stored $now)   # a child bossy took 3-8 s of the sweep (K20): in the background
    $null = Invoke-KitBackground "launch -Done $($w.Name)" $KitCmd.orch @('launch', '-Done', '-RunId', $w.Name); Flag 'INFO' "auto-fixed: run $($w.Name) finished: its launch record closes in the background" 'Nothing to do.'
    Phase 'workflows'
  }
  $silentH = ($now - (Get-Item $j).LastWriteTime).TotalHours
  if ($done -and $silentH -gt 2) { continue }
  if (-not $done) { $sr = Get-KitSilentRun $w.Name $silentH $state.quietRuns $now; if ($sr.flag) { Flag $sr.flag.level $sr.flag.what $sr.flag.action }; if ($sr.skip) { continue } }
  $running = @(Get-JournalRunning $started @($res.Keys))
  if ($w.Name -notin $pausedRuns) { $runTotal += $running.Count }
  $errs = @($res.Values | Where-Object { $_.result.error }).Count; $toolErr += $errs; if ($errs) { $errRun = $w.Name }
  L ("workflow {0}: {1} agents, {2} finished, {3} running{4}" -f $w.Name, $started.Count, $res.Count, $running.Count, $(if ($done) { ' (complete)' }))
  # `track` holds merges in review / fix
  if ($AutoFix -and $running.Count -and @($started | Where-Object { $_.label -match '^(build|review|fix):' }).Count) {
    if (Within 'wave reports') { $null = Invoke-Bounded $KitCmd.orch @('report', '-Run', $w.Name); Phase 'workflows' }
  }
  foreach ($a in $running) {
    $act = Get-KitLastActivity (Join-Path $w.FullName "agent-$($a.agentId).jsonl")   # the status rows' source: transcript + task outputs
    $idle = if ($act) { [int]($now - $act).TotalMinutes } else { -1 }
    L ("  {0,-18} idle {1} min" -f $a.label, $idle)
    if ($idle -ge 0 -and $idle -lt $idleMin) { [void]$liveLabels.Add($a.label) }
    [void]$runningLabels.Add($a.label); [void]$wfAgents.Add([pscustomobject]@{ label = $a.label; agentId = $a.agentId; dir = $w.FullName })
  }
  foreach ($r in $res.Values) {
    $label = [string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label
    [void]$doneLabels.Add($label)
    $sum = [string]$r.result.summary + [string]$r.result.error
    # build-stage merged=false is no proof
    $shipped = $r.result.mrs -and -not @($r.result.mrs | Where-Object { -not $_.merged }).Count
    if ($running.Count -and -not $shipped -and (Test-KitCollision $sum)) { Flag 'ACT' "$label in $($w.Name) reported a collision/halt" 'Read its result; resume it alone with RESUME_BRIEF after making sure no other writer is active (bossy.ps1 board check).' @{ kind = 'COLLISION'; who = "$label ($($w.Name))"; problem = 'reported a collision/halt' } }
    if ($done -and (Test-KitNoMrs $started @($res.Values) $label $r.result $sum)) { Flag 'WATCH' "$label finished without MRs" 'Resume it (buildy mode resume) unless it was deliberately stopped.' @{ kind = 'NO MRS'; who = "$label ($($w.Name))"; problem = 'finished without MRs' } }
  }
}

# 2. board
Phase 'board'; $board = Get-KitPath board
$entries = @(Read-KitJsonFiles $board)
$markLeft = { param($e, [string]$As = 'crashed') Update-BoardEntry (Join-Path $board "$($e.session).json") { param($x) $x.status = 'left'; $x | Add-Member -Force NoteProperty $As (Get-KitStamp); $x } }
foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -eq $false })) {
  if ($AutoFix) { & $markLeft $e; Flag 'INFO' "auto-fixed: board entry $($e.agent) ($($e.run)) marked left: its session process $($e.holderPid) is gone" 'Resume its work if unfinished (bossy.ps1 recover).' }
  else { Flag 'WATCH' "board entry $($e.agent) ($($e.run)): its session process $($e.holderPid) is gone" 'supervise -AutoFix marks it left; bossy.ps1 recover lists its work.' }
}
$bm = [double](Get-KitParam 'idle.beatMinutes'); $quiet = { param($e) $x = Get-KitLastActivity "$($e.transcript)" $e "$($e.tool)"; if ($x) { $now - $x } else { $now - [datetime]$e.beat } }   # beat or transcript write
$active = @($entries | Where-Object { $_.status -ne 'left' -and (& $quiet $_).TotalMinutes -lt $bm })
$stale = @($entries | Where-Object { $_.status -ne 'left' -and (& $quiet $_).TotalMinutes -ge $bm -and ($now - [datetime]$_.beat).TotalHours -lt 6 })
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
$liveNames = @($liveLabels | ForEach-Object { LabelNames $_ })
$runNames = @($runningLabels | ForEach-Object { LabelNames $_ })   # running even idle: an earlier decide:SD result closed a live resume:SD
$doneNames = @($doneLabels | ForEach-Object { LabelNames $_ } | Where-Object { $_ -and $_ -notin $liveNames -and $_ -notin $runNames })
# workflow steps for Test-KitLive
Write-KitAtomic (Get-KitPath live-steps -Create) (@{ at = (Get-KitStamp stored $now); running = @($runningLabels); labels = @(@($runningLabels) + @($doneLabels) | Where-Object { $_ } | Select-Object -Unique) } | ConvertTo-Json) -Volatile '"at":\s*"[^"]*"'
foreach ($s in $stale | Where-Object { $_.agent -in $doneNames -and (-not $doneAt[$_.agent] -or -not $_.joined -or [datetime]$_.joined -le $doneAt[$_.agent]) }) {   # an older result never closes a newer entry
  if ($AutoFix) { & $markLeft $s 'finished'; Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) left: its workflow step has a journal result" 'Nothing to do.' }
}
# others left = finished; kit calls since beat = alive; else silent
$calls = if (@($stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames }).Count) { @(Read-KitLog calls $now.AddMinutes(-$bm) | ForEach-Object agent | Select-Object -Unique) }
foreach ($s in $stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames -and $_.agent -notin $runNames }) {   # a running step: STUCK row, never left
  $sib = @($entries | Where-Object { $_.run -eq $s.run -and $_.session -ne $s.session })
  if ($AutoFix -and $s.run -and $sib.Count -and -not @($sib | Where-Object status -ne 'left').Count) { & $markLeft $s 'finished'; Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) left: every other agent of its run left" 'Nothing to do.'; continue }
  $dupBase = if ("$($s.agent)" -match '^(.+)-\d+$') { $Matches[1] }   # "<agent>-<n>" whose base agent of the run beats: a stale copy
  if ($AutoFix -and $dupBase -and @($entries | Where-Object { $_.agent -eq $dupBase -and $_.run -eq $s.run -and $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt $bm }).Count) { & $markLeft $s 'finished'; Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) left: a stale duplicate of $dupBase, which beats" 'Nothing to do.'; continue }
  if ($s.agent -in $calls) { continue }   # kit calls, no beat: alive (a silent one: a STUCK row)
  if ($AutoFix -and (& $quiet $s).TotalHours -ge 2) { & $markLeft $s; Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) silent $([int]($now - [datetime]$s.beat).TotalMinutes) min -> marked left" 'Nothing to do.'; continue }
}
foreach ($x in @(Get-KitPauseFlags @(Read-KitJsonFiles (Get-KitPath pauses)) $active $runTotal)) { Flag $x.level $x.what $x.action }
# local, so before network sections; STUCK = a flag
Phase 'status rows'; $rows = @(Get-KitStatusRows $now $Session); foreach ($x in @(@(Get-KitStuckFlags $rows $now $idleMin) + @(Get-KitQaQuestionFlags $now))) { [void]$flags.Add($x) }
# a subagent that returned but never left: left, never STUCK
foreach ($r in @($rows | Where-Object { $AutoFix -and $_.session -and $_.done -eq 'turn complete' -and "$($_.tx)" -match '[\\/]subagents[\\/]' -and $_.last -and ($now - [datetime]$_.last).TotalMinutes -ge $bm })) {
  foreach ($e in @($entries | Where-Object { $_.session -eq $r.session -and $_.status -ne 'left' })) { & $markLeft $e 'finished'; Flag 'INFO' "auto-fixed: board entry $($e.agent) ($($e.run)) left: its agent returned" 'Nothing to do.' }
}
$nAct = [math]::Max($active.Count, @(Get-KitLiveTranscripts $now 10 '*').Count)   # live agents without a fresh beat or row

# 3. memory, disk, guards
Phase 'memory'; $mem = Get-SysMem; $pct = [int](100 * (1 - $mem.AvailGB / $mem.TotalGB)); L "memory: $pct% used, $([math]::Round($mem.AvailGB, 1)) GB available"
$state.load = @{ at = (Get-KitStamp stored $now); availGB = $mem.AvailGB; cpu = (Get-SysCpu); agents = $nAct + $wfAgents.Count }   # for Get-KitLoadTags
$keepFree = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($mem.TotalGB * 0.15)))) }
# adapter hooks see $now, $mem, $keepFree, Within, Left; return a {level,what,action} flag, {name,by,gb} row, {info}, {ramNeed} or a line
$res = [Collections.Generic.List[object]]::new(); $script:ownerInfo = @(Get-KitParamChanges $(if ($state.settingsSeen) { [datetime]$state.settingsSeen } else { $now.AddHours(-1) })); if ($AutoFix -and $me -ne 'os-timer') { $state.settingsSeen = (Get-KitStamp stored $now) }; $script:ramNeed = 0   # SETTINGS changed since last beat
function Add-KitResult($x) { if ($x -is [string]) { L $x } elseif ($x.level) { Set-ActSection $x.level $x.what; [void]$flags.Add($x) } elseif ($x.info) { $script:ownerInfo += $x.info } elseif ($x.ramNeed) { $script:ramNeed = [math]::Max($script:ramNeed, [double]$x.ramNeed) } elseif ($x.name) { $res.Add($x) } }
# machine guards first (build gate, cache flush, phones, QA seats)
foreach ($x in @(Invoke-KitHooks Get-KitSuperviseGuard @{ AutoFix = $AutoFix })) { Add-KitResult $x }
$ramAct = [int](Get-KitSetting 'supervise.ramActPct' 90)
if ($pct -ge $ramAct) { Flag 'ACT' "RAM $pct% used" 'Hold new launches; run bossy.ps1 cleanup; check for orphaned java/node/chrome from finished agents.' }
if (Within 'storage') { try { foreach ($x in @(Get-KitStorageRound)) { Add-KitResult $x } } catch { Flag 'WATCH' "storage round failed: $($_.Exception.Message)" 'bossy.ps1 storage' } }
Phase 'guard log'; $blocks = @(Read-KitLog guard $now.AddHours(-1) | Where-Object event -eq 'deny')
if ($blocks.Count -ge 3) { $bWho = @($blocks | Group-Object { Get-KitDenyWho $_ $rows } | Sort-Object Count -Descending | Select-Object -First 2 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', '
  Flag 'WATCH' "guard blocked $($blocks.Count) commands in the last hour" 'Agents are tripping a rule: bossy.ps1 audit -Since 1h shows them; add a contracts note or a lesson so they stop.' @{ kind = 'GUARD'; who = $bWho; problem = "$($blocks.Count) commands blocked in the last hour" } }
# one beat with its run time
$g20 = @(Read-KitLog guard $now.AddMinutes(-[math]::Max(20.0, 1.25 * (Get-KitBeatMinutes)))); $crash = @($g20 | Where-Object event -eq 'crash'); $slow = @($g20 | Where-Object event -eq 'timeout')
if ($slow.Count -ge 3) { Flag 'WATCH' "guard timed out $($slow.Count)x in a beat: those calls ran unguarded" 'A loaded machine (Resources) or a dead warm guard server (guard_server.ps1 answers in ~0.1 s).' }   # K67: blocked, or let through by the owner's switch (guard_client.mjs header); one beat: a fixed crash stops flagging
if ($crash.Count) { Flag 'ACT' "guard crashed $($crash.Count)x in a beat ($(@($crash | Where-Object letThrough).Count) let through by the owner's switch), last: $(([string]$crash[-1].why).Substring(0, [math]::Min(120, ([string]$crash[-1].why).Length)))" 'Spawn a kitty (kind fix) on skills/crafty; the owner unsets the switch (guard_client.mjs header) after the push.' }

# 4. -AutoFix: tracker, outbox, cleanup (inTest: deploys adapter hook)
if ($AutoFix -and (Within 'tracker checks')) {
  # an agent with the MR branch checked out is on it
  function OwnerOf($repo, $iid) {
    $proj = if ($KitConf.GitHostGroup) { "$($KitConf.GitHostGroup)/$repo" } else { $repo }
    $src = try { (Invoke-HostVerb 'mr.get' @{ repo = $proj; n = $iid }).source_branch } catch { $null }   # a vendor host adapter throws
    if (-not $src) { return $null }
    foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 30 })) {
      foreach ($w in @($e.worktrees)) {
        $paths = if ([IO.Path]::IsPathRooted("$w")) { @("$w") } else { @($KitConf.WorktreeRoots | ForEach-Object { Join-Path $_ "$w" }) }
        foreach ($wp in $paths) { if ((Test-Path $wp) -and (git -C $wp branch --show-current 2>$null) -eq $src) { return $e.agent } }
      }
    }
    $null
  }
  $heldIds = @((Read-KitTracking).tasks.Values | Where-Object { $_.holdPromotion -and -not $_.done } | ForEach-Object task)
  foreach ($l in @(Invoke-Bounded $KitCmd.orch @('track', 'run', '-Detail'))) {   # the last background result
    if ((Test-KitHeldLine $l $heldIds) -or (Test-KitTrackLineStale $l)) { continue }
    if ($l -match '^ATTENTION \S+: no tracker id') { Flag 'ACT' $l 'Register its MRs under the real task id (the command in the line).' }
    elseif ($l -match '^(DONE|COMMENTED|DROPPED|MOVED|RELEASED)') { Flag 'INFO' "auto-fixed: $l" 'Tracker moved the task; nothing to do.' }
    elseif ($l -match '^CONFIG') { Flag 'INFO' $l 'A kit.local.json key is missing for this task; add it or register its MRs by hand.' }
    elseif ($l -match '^LAG') { Flag 'ACT' $l "Promote it (& $($KitCmd.dev) tracker status <id> <status>) or hold it on purpose (bossy.ps1 track add -Task <id> -HoldPromotion '<why>')." }
    elseif ($l -match '^HOLD \S+: .*\(stale: ') { Flag 'ACT' $l 'Its run ended with the area never started: relaunch the area, or drop the hold (the command in the line).' }
    elseif ($l -match '^HOLD') { Flag 'INFO' $l 'Merge/promotion waits for the review or fix round; it resumes by itself.' }
    elseif ($l -match '^ATTENTION \S+: could not set status') { Flag 'ACT' $l "MRs merged, the tracker refused the status (track retries each round): check auth and tracker.statuses (& $($KitCmd.dev) tracker view <id>), or set it by hand." }
    elseif ($l -match '^ATTENTION \S+: MRs merged, task id not readable') { Flag 'ACT' $l 'Re-track its MRs under the native id: track add -Task <id> -Mrs <refs>; track remove -Task <key> -Mrs <refs>.' }
    elseif ($l -match '^ATTENTION .*no (solution/testing comment|testing-doc link)') { Flag 'ACT' $l "Post the solution, MR links and how-to-test steps (testing doc link) on the task (& $($KitCmd.dev) tracker comment <id> -File <solution.md> -Kind comment-solution: the template, edited in place)." }
    elseif ($l -match '^ATTENTION .* (?<repo>[\w./-]+)!(?<iid>\d+) opened \((conflict|pipeline \w+)\)' -and ($owner = OwnerOf $Matches.repo $Matches.iid)) {
      Flag 'INFO' "$l - being handled by $owner" 'An active agent has that MR branch checked out; re-check next round.'
    }
    elseif ($l -match '^ATTENTION') { Flag 'ACT' $l 'A tracked MR failed its pipeline, was closed or conflicts (a sibling changed the same lines): get it fixed or rebased (resume its agent with RESUME_BRIEF).' }
  }
  foreach ($l in @(Invoke-KitOutbox)) { Flag $(if ($l -match '^GAVE UP') { 'ACT' } else { 'INFO' }) $(if ($l -match '^SENT') { "auto-fixed: outbox $l" } else { "outbox: $l" }) 'A tracker write lost to the network: do it by hand (crafty.ps1 tracker).' }
  foreach ($gone in $stale | Where-Object { (& $quiet $_).TotalHours -ge 2 -and $_.agent -notin $liveNames }) { & $markLeft $gone }   # a long workflow step beats nothing
  # idle daemons (cleanup.idleDaemons) hold GBs
  if ($pct -ge [int](Get-KitParam 'supervise.ramCleanupPct')) { foreach ($l in @(& $KitCmd.orch cleanup | Select-Object -First 1)) { Flag 'INFO' "auto-fixed: RAM $pct% -> bossy.ps1 cleanup: $l" 'Re-check memory next round.' } }
  elseif (Within 'cleanup') { $null = Invoke-Bounded $KitCmd.orch @('cleanup', '-IfDue', '-Quiet') }
  if (Within 'repo sync') { $null = Invoke-Bounded $KitCmd.dev @('wt', 'pool', '-Sync', '-Json') }   # sync.everyMinutes, detached (wt-pool.ps1 Sync-KitRepo)
  if ((Get-Command Invoke-KitWeeklyTests -ErrorAction SilentlyContinue) -and (Within 'kit tests')) { foreach ($l in @(Invoke-KitWeeklyTests (-not $active.Count -and -not $liveNames.Count))) { Flag 'ACT' $l 'Spawn kitty (kind fix) on the failed checks the log lists.' } }   # adapters/kit-admin.ps1: one full run a day while idle
}
# 4b. owner MRs merged in 24 h, untracked
if ($KitConf.TrackerType -ne 'none' -and (Within 'untracked MRs')) { foreach ($x in @(Get-KitUntrackedMrFlag $state $now { Within 'untracked MRs' })) { [void]$flags.Add($x) } }
if ((Test-Path (Get-KitPath scope-log)) -and (Within 'scope')) { foreach ($w in @(@(Invoke-Bounded $KitCmd.dev @('scope')) -match '^WATCH ')) { $wp = "$w".Substring(6) -split ' \| ', 2; Flag 'WATCH' $wp[0] $wp[1] } }

# 5. QA results: new [Bug], failedTesting tasks (bossy E6)
if (-not (Within 'QA bug tasks')) { foreach ($qv in @($script:KitQaBugs.views.Values | Where-Object { $_ })) { Stop-KitProcessTree $qv.p } }
else {
  # parents and their tracker views: Start-KitSupervisePrefetchQaBugs (process-gates.ps1), started with the sweep (failed: now)
  if (-not $script:KitQaBugs) { try { Start-KitSupervisePrefetchQaBugs } catch { Flag 'WATCH' "QA bug tasks: parents not read: $($_.Exception.Message)" 'Look at qa-parents.json (cache) and the QA runs; supervise asks again next round.' } }
  $qaRecent = @($script:KitQaBugs.recent); $parents = @($script:KitQaBugs.parents)
  if ($parents.Count) { $null = Update-KitQaParents { param($q) foreach ($qp in $parents) { if ($q[$qp]) { $q[$qp].seen = (Get-KitStamp stored $now) } } } }
  $tracked = @((Read-KitTracking).tasks.Keys)
  $openRuns = @{}
  foreach ($qr in @($qaRecent | Where-Object { ($now - $_.dir.LastWriteTime).TotalHours -lt 3 })) {
    $rd = $qr.dir; $rj = $qr.j
    $left = @($rj.items | Where-Object { -not (Test-Path (Join-Path $rd.FullName "$($_.code)/finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)/held.json")) }).Count
    if ($left -and $rj.tracker.parent) { $openRuns[$rj.tracker.parent] = "$($rd.Name) ($left item(s) left)" }
  }
  foreach ($par in $parents) {
    if (-not (Within 'QA bug tasks')) { break }
    $subs = Get-KitQaBugSubtasks $par ([math]::Min(20.0, (Left)))
    $new = @($subs | Where-Object { $_.name.StartsWith((Get-KitKindPrefix 'bug')) -and (Test-TrackerStatus $_.status 'open') -and $_.id -notin $tracked })
    if (-not $new.Count) { continue }
    $list = ($new | ForEach-Object { "$($_.id) $($_.name.Substring(0, [math]::Min(70, $_.name.Length)))" }) -join '; '
    $note = if ($openRuns[$par]) { " (run $($openRuns[$par]) is still testing: later bugs go into the next wave)" } else { '' }
    Flag 'ACT' "$($new.Count) new QA bug task(s) not being fixed$note`: $list" "ONE wave now: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> -Mandate '<owner words>' [-Hints ...] per task (brief, tracking, /buildy args), the briefs in one file (a section per agent), one /buildy; fixed in a running wave instead: & $($KitCmd.orch) track route -From <id> -To <task | run>." @{ ackNeeds = 'ref' }
  }
  foreach ($qv in @($script:KitQaBugs.views.Values | Where-Object { $_ -and -not $_.p.HasExited })) { Stop-KitProcessTree $qv.p }   # cut short: no view outlives the sweep
}
if (Within 'failedTesting tasks') {
  $ft = @{}; $ftAt = @{}; $uw = @()
  foreach ($fj in @(Get-KitQaRunFiles finalize.json -SinceDays 7)) {
    $fo = Get-Content $fj.FullName -Raw | ConvertFrom-Json
    foreach ($s in @($fo.subtasks | Where-Object { $_.failedTesting })) { $ft[[string]$s.id] = $fj.Directory.Parent.Name; $ftAt[[string]$s.id] = $fj.LastWriteTime }
    if ($fj.LastWriteTime -gt $now.AddDays(-1)) { foreach ($w in @($fo.watch | Where-Object { $_ })) { $uw += "$($fj.Directory.Parent.Name)/$($fj.Directory.Name) $($w.id) ($($w.task), $($w.screen)) on $($w.env)" } }
  }
  # pokey.ps1 finalize Test-Unproven: no [Bug] filed
  if ($uw.Count) { Flag 'WATCH' "$($uw.Count) unproven QA finding(s), verify inconclusive, no request named: $($uw -join '; ')" "One watchy kind triage per env for the finding's window (its results.json observed); a confirmed defect -> its [Bug]; then supervise -Ack." }
  $trk = (Read-KitTracking).tasks; if ($state.ftStatus -isnot [Collections.IDictionary]) { $state.ftStatus = @{} }
  foreach ($id in @($state.ftStatus.Keys)) { if ($id -notin $ft.Keys) { $state.ftStatus.Remove($id) } }
  # a route whose target brought no fix MR in 24 h is no link either
  $ids = @($ft.Keys | Where-Object { (($o = $trk[$_]).done -or -not $o -or (@($o.routes | Where-Object { $_ }).Count -and -not @($o.routedMrs | Where-Object { $_ }).Count -and ($now - [datetime]@($o.routes)[-1].at).TotalHours -ge 24)) -and -not ($o.doneAt -and [datetime]$o.doneAt -gt $ftAt[$_]) })   # merged after it: fixed
  $ttl = [math]::Max(15.0, 2 * (Get-KitBeatMinutes))   # closed: 6 h
  $due = @($ids | Where-Object { -not ($c = $state.ftStatus[$_]) -or ($now - [datetime]$c.at).TotalMinutes -ge $(if (Test-TrackerStatus $c.st 'closed') { 360 } else { $ttl }) })
  foreach ($l in @(if ($due.Count) { Invoke-Bounded $KitCmd.dev @('tracker', 'statuses', ($due -join ',')) })) {   # the last finished run: a view newer than the cache wins
    if ("$l" -match '^WATCH ') { Flag 'WATCH' "failedTesting views: $("$l".Substring(6))" 'Check tracker auth: crafty.ps1 tracker view <id>'; continue }
    if ("$l" -match '^(\S+) (\S+) (.+)$' -and $Matches[1] -in $ids -and (-not ($c = $state.ftStatus[$Matches[1]]) -or [datetimeoffset]$Matches[2] -gt [datetimeoffset]$c.at)) { $state.ftStatus[$Matches[1]] = @{ at = $Matches[2]; st = $Matches[3] } }
  }
  $back = @(Select-KitFailedLive $ids $trk $state.ftStatus | ForEach-Object { "$_ ($($ft[$_]))" })
  # $ids = no fix MR linked since the run (track add -Mrs / route reopen it): an -Ack needs a decision id or MR, hides 2 h
  if ($back.Count) { Flag 'ACT' "$($back.Count) task(s) failed testing, back to the dev flow, no fix MR linked: $($back -join '; ')" "Fixed in another task's or run's wave: & $($KitCmd.orch) track route -From <id> -To <task | run> [-Items <check ids>] [-Mrs <its fix MRs>], or & $($KitCmd.orch) track add -Task <id> -Mrs <fix MRs>; not fixed yet: ONE /buildy mode 'bugfix' for all: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> -Mandate '<owner words>' per task (reproduce locally first), then launch." @{ kind = 'FAILED TESTING'; who = @($back | ForEach-Object { ($_ -split ' ')[0] }) -join ', '; problem = "no fix MR linked: $($back -join '; ')"; ackNeeds = 'ref' } }
}
foreach ($w in @(Get-KitScopeWatch)) { Flag 'WATCH' $w.what $w.action }   # live status names of no role

# 6. decisions, ENV-FIX: every round until answered
Phase 'decisions'; $pd =@(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ })
foreach ($d in @($pd | Where-Object kind -eq 'envfix')) {
  $mins = "$([int]($now - [datetime]$d.at).TotalMinutes) min"
  Flag 'ACT' "ENV-FIX $($d.id) waiting $mins ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Fix it (you or kitty kind env: config, paths, a hung train, shared DB repair; never start a service no live lease or person asked for), then & $($KitCmd.orch) decide answer -Id $($d.id) -By coordinator -Answer 'done: <what you did>' (cannot: 'cannot: <why>')" @{ kind = 'ENV-FIX'; who = "$($d.agent) ($($d.run)), item $($d.item)"; age = $mins; problem = $d.question }
}
$dd = @($pd | Where-Object kind -ne 'envfix'); $blk = @($dd | Where-Object blocking -ne $false); $fyi = @($dd | Where-Object blocking -eq $false)
if ($blk.Count) {   # native question tool, 4 per call
  $b = @($blk | Select-Object -First 4); $mins = "$([int]($now - [datetime]$b[0].at).TotalMinutes) min"; $q = @($b.question) -join ' / '
  Flag 'ACT' "DECISION $(@($b.id) -join ', ') (blocking, oldest $mins$(if ($blk.Count -gt 4) { "; $($blk.Count - 4) more next" })): $q" "ONE AskUserQuestion call from bossy.ps1 decide list -Ask -Json (no tool or a missing id: its text); then decide answer -Id <id> per pick" @{ kind = 'DECISION'; who = @($b.agent) -join ', '; age = $mins; problem = $q }
}
if ($fyi.Count) { Flag 'WATCH' "DECISION $($fyi.Count) FYI: $(@($fyi.id) -join ', ')" "In your report: decide list -Fyi; the owner's '1 A, 2 B' -> decide answer per number" @{ kind = 'DECISION FYI'; who = @($fyi.agent) -join ', '; problem = @($fyi.question) -join ' / ' } }

# 7. adapters' checks: result shapes as in section 3
foreach ($x in @(Invoke-KitHooks Get-KitSuperviseFlags @{ AutoFix = $AutoFix })) { Add-KitResult $x }
if ($script:ramNeed -and $mem.AvailGB -lt $keepFree + $script:ramNeed) { Flag 'ACT' "RAM: $([math]::Round($mem.AvailGB, 1)) GB free < floor $keepFree + the largest waiting build $($script:ramNeed) GB" "Free the biggest: $((@($res | Where-Object { $_.gb } | Sort-Object { -$_.gb } | Select-Object -First 3 | ForEach-Object { "$($_.name) $([math]::Round($_.gb, 1)) GB" })) -join '; ')" }

# 8. retro due, budgets
Phase 'retro'; if (-not $runTotal) {
  $since = Get-KitRetroSince
  $finished = @($wfDirs | Where-Object { $_.LastWriteTime -gt $since -and (Select-String (Join-Path $_.FullName 'journal.jsonl') -Pattern '"label":"(build|test|retest|verify|fix):' -Quiet) }).Count
  $due = Get-KitRetroDue -RunFinished:([bool]$finished)
  if ($due) { Flag 'ACT' "retro due: $due, $finished dev/QA run(s) finished or stopped since, no workflow running" "E10, no owner ask: Workflow({ scriptPath: '$($KitConf.Kit -replace '\\', '/')/workflows/tidy.js', args: { kitDir: '$($KitConf.Kit -replace '\\', '/')' } })" }
}
foreach ($e in $active | Where-Object { $_.budget -and $_.spend -ge $_.handoff }) { Flag 'WATCH' "$($e.agent) ($($e.run)) past its handoff point: $($e.spend) of $($e.budget) tokens" 'It hands off at its next beat; silent 20 min -> stop it, continue fresh (bossy.ps1 recover).' @{ kind = 'BUDGET'; who = "$($e.agent) ($($e.run))"; problem = "past its handoff point: $($e.spend) of $($e.budget) tokens" } }
foreach ($h in Get-KitHandoffs 24 | Where-Object { ($now - [datetime]$_.beat).TotalMinutes -ge 15 }) { Flag 'ACT' "HANDOFF $($h.agent) ($($h.run)) $([int]($now - [datetime]$h.beat).TotalMinutes) min ago, no fresh agent yet" "Spawn a fresh $(if ($h.type) { $h.type } else { 'agent' }) (-Agent $($h.agent) -Run $($h.run) in its prompt): continue from $($h.handoffBrief)" @{ kind = 'HANDOFF'; who = "$($h.agent) ($($h.run))"; age = "$([int]($now - [datetime]$h.beat).TotalMinutes) min"; problem = 'handed off, no fresh agent yet' } }
foreach ($sf in @(Get-ChildItem (Get-KitPath launches) -Filter 'self-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-12) } | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
  $o = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $null }; if (-not $o.cap -or $o.completed -or -not (Within 'run budgets')) { continue }
  $bgo = @(Invoke-KitBackground "budget -Run $($o.run)" $KitCmd.orch @('budget', '-Run', $o.run, '-Json')); foreach ($x in @($bgo -match '^WATCH ')) { Flag 'WATCH' $x.Substring(6) "bossy.ps1 budget -Run $($o.run)" }   # the last sweep's result (it took 11 s inline, K20)
  $sp = try { @($bgo -notmatch '^WATCH ') -join '' | ConvertFrom-Json } catch { $null }
  if ($sp -and $sp.spent -ge $o.stopAt * $o.cap) { Flag 'WATCH' "run $($o.run) at $([int](100 * $sp.spent / $o.cap))% of its cap ($($sp.spent) / $($o.cap))" 'No new item starts; launch its next when it finishes (E7).' }
}

# 9. anomalies vs last round: outbox, agent errors
Phase 'anomalies'; $cur =@{ toolErrors = $toolErr; errorRun = $errRun; outbox = @(Get-Content (Get-KitPath outbox) -ErrorAction SilentlyContinue).Count }
$an = Get-KitAnomalies $cur $state.anom; foreach ($x in $an.flags) { Flag $x.level $x.what $x.action }; $state.anom = $an.state
foreach ($x in @(Get-KitApiBeatFlag $apiLedger)) { Flag $x.level $x.what $x.action }; Remove-Item Env:KIT_API_LEDGER -ErrorAction SilentlyContinue
$late = @($kitSweep.skipped | Where-Object { -not $kitSweep.ran.ContainsKey($_) -and (-not $kitSweep.every[$_] -or -not $kitSweep.last[$_] -or ($now - [datetime]$kitSweep.last[$_]).TotalMinutes -ge 2 * $kitSweep.every[$_]) })   # one round late: no news
if ($late.Count + $kitSweep.timedOut.Count) { Flag 'WATCH' "sweep hit its $budgetSeconds s budget: skipped $(@($late) + @($kitSweep.timedOut | ForEach-Object { "$_ (timed out)" }) -join ', '); slowest: $(@($kitSweep.ran.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 3 | ForEach-Object { '{0} {1:0} s' -f $_.Key, $_.Value }) -join ', ')" 'Partial result: the skipped sections go first next round; a repeat: speed up the slowest (calls log "sweep" lines).' }   # before the acks (-Ack)
$s1 = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; $state.acks = @{}; $a0 = $s1.acks   # re-read: an -Ack during this sweep
$state.known = @{}; foreach ($r in @(if ($s1.known) { $s1.known.Keys })) { if (($now - [datetime]$s1.known[$r]).TotalDays -lt $(if ("$r".StartsWith('noise:')) { 30 } else { 2 })) { $state.known[$r] = $s1.known[$r] } }   # -Ack refs: MRs 2 d, noise 30 d
foreach ($k in @(if ($a0) { $a0.Keys })) { if (($now - [datetime]$a0[$k].at).TotalHours -lt 24) { $state.acks[$k] = $a0[$k] } }
Set-KitFlagAge $flags $state $now   # the page and -Brief Age column
$state.lastFlags = @($flags | Where-Object level -ne 'INFO' | ForEach-Object { @{ level = $_.level; what = $_.what; action = $_.action; kind = $_.kind; who = $_.who; problem = $_.problem; refs = @($_.refs | Where-Object { $_ }); ackNeeds = $_.ackNeeds } })   # supervise -Ack; a stepped-aside session's own flags
$kept = @(Select-KitFlags $flags $state.acks $now); $flags.Clear(); foreach ($x in $kept) { [void]$flags.Add($x) }
$fails = 0; foreach ($b in @(@(Read-KitLog builds $now.AddHours(-2) | Where-Object event -eq 'end') | Sort-Object { [datetime]$_.at } -Descending)) { if ([int]$b.code) { $fails++ } else { break } }
$base = [double](Get-KitParam 'supervise.heartbeatMinutes'); $acts = @($flags | Where-Object level -eq 'ACT' | ForEach-Object { Get-KitFlagKey $_.what })
$freshActs = @(Add-KitActObs $state $acts $now $actSec @(@($kitSweep.ran.Keys) + $kitSweep.cur | Where-Object { $_ -and $_ -notin $kitSweep.skipped })); $freshFlags = @($flags | Where-Object { $_.level -eq 'ACT' -and (Get-KitFlagKey $_.what) -in $freshActs })
$next = Get-KitNextBeat $(if ($state.nextBeat) { [double]$state.nextBeat } else { $base }) $base $freshFlags.Count @($freshFlags | Where-Object what -like 'ENV-FIX*').Count ([bool]@($flags | Where-Object { $_.level -ne 'INFO' -and $_.what -like 'disk *' }).Count) $fails ($nAct + $wfAgents.Count) ($liveLabels.Count + $nAct) $runTotal
$state.nextBeat = $next.min; $nextLine = "NEXT $($next.min) min ($($next.why))"
L (Complete-KitSweep $kitSweep $state); $state.coordAt = if ($me -ne 'os-timer') { (Get-KitStamp stored $now) } elseif ($cd0 = Get-KitDiskCoordAt $stateFile) { $cd0 } elseif ($state.coordAt) { $state.coordAt } else { "$($state.report.at)" }; $state.report = @{ at = (Get-KitStamp stored $now) }; Write-KitAtomic $stateFile ($state | ConvertTo-Json -Depth 5)
$report = [pscustomobject]@{ rows = $rows; at = $now; versions = $script:KitTxVersions; mem = $mem; keepFree = $keepFree; resources = @($res); shells = $script:KitShellRows; flags = @($flags); info = $script:ownerInfo }
$secs = [int]((Get-Date) - $t0).TotalSeconds
L "sweep: $secs s"   # before the page: its Sweep time tile
$page = Write-KitSuperviseHtml $report $lines $nextLine
if ($Json) { [pscustomobject]@{ at = (Get-KitStamp stored $now); seconds = $secs; summary = @($lines); flags = @($flags); report = $report; nextBeat = $next } | ConvertTo-Json -Depth 5; exit 0 }
if ($Brief) {   # the coordinator replies with its actions only (supervise.output)
  $md = @(Format-KitReport $report)
  Write-KitSuperviseReport $report $md $lines $nextLine
  $shown = $report.PSObject.Copy(); $shown.rows = @(Select-KitBriefRows $report.rows $now)   # older finished: report file only
  Format-KitSuperviseOut $report $shown $page; [Console]::Error.WriteLine("NEXT=$($next.min)"); [Console]::Error.WriteLine("HEARTBEAT_PROMPT=$(Get-KitBeatPrompt)"); $global:LASTEXITCODE = 0; exit 0
}
"=== supervise $($now.ToString('HH:mm')) ==="; $lines; Format-KitStatusTable $rows $now $script:KitTxVersions
if ($flags.Count) { '--- FLAGS'; $flags | Sort-Object { @{ ACT = 0; WATCH = 1; INFO = 2 }[$_.level] } | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" } } else { '--- no flags: all good' }
$nextLine
$global:LASTEXITCODE = 0
}

# ---- report: a run from its journal (notifications truncate)
function Invoke-Report {
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json, [switch]$Detail, [switch]$Stopped)
$ErrorActionPreference = 'SilentlyContinue'
$dir = Get-KitWorkflowDirs $Session | Where-Object Name -eq $Run | Select-Object -First 1 -ExpandProperty FullName
if (-not $dir) { Stop-KitVerb "wave-report: workflow $Run not found under $((Invoke-KitAdapter transcript claude root).dir)" 1 }  # swallowed under SilentlyContinue
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
$started = @($ev | Where-Object type -eq 'started'); $doneIds = @($ev | Where-Object type -eq 'result' | ForEach-Object agentId)
$running = @(if ($Run -notin (Get-KitFinishedRuns)) { Get-JournalRunning $started $doneIds | ForEach-Object label })
$cut0 = @(if ($Stopped) { $running }); if ($Stopped) { $running = @() }   # stopped: those steps never finish

$agents = [ordered]@{}; $findings = New-Object System.Collections.ArrayList; $qa = [ordered]@{}; $learn = $null
$nuUrl = { param($u) ([string]$u -replace '[?#].*$', '').TrimEnd('/').ToLower() }
foreach ($x in $results) {
  $kind, $id = ($x.label -split ':', 2); $id = ($id -split '@')[0]
  switch ($kind) {
    { $_ -in 'build', 'fix' } {
      $p = if ($agents.Contains($id)) { $agents[$id] } else { $null }
      if ($x.r -is [System.Management.Automation.PSCustomObject]) {
        $rm = @($x.r.mrs | Where-Object { $_ }); $urls = @($rm | ForEach-Object { & $nuUrl $_.url })
        $mrs = @(@($p.mrs | Where-Object { $_ -and (& $nuUrl $_.url) -notin $urls }) + @($rm | ForEach-Object { [ordered]@{ url = $_.url; merged = [bool]$_.merged; mergeState = $(if ($_.mergeState) { [string]$_.mergeState } elseif ($_.merged) { 'MERGED' } else { 'OPEN' }) } }))
        $nd = @($x.r.deferred | Where-Object { $_ }); $ndIds = @($nd | ForEach-Object id)
        $agents[$id] = [ordered]@{ mrs = $mrs; done = @(@($p.done) + @($x.r.done) | Where-Object { $_ } | Select-Object -Unique)
          deferred = @(@($p.deferred | Where-Object { $_ -and $_.id -notin $ndIds }) + $nd)
          needsLiveCheck = @(@($p.needsLiveCheck) + @($x.r.needsLiveCheck) | Where-Object { $_ } | Select-Object -Unique); fixedRound = ($kind -eq 'fix' -or [bool]$p.fixedRound)
          localRounds = [int]$p.localRounds + [int]$x.r.localTest.rounds }   # outcomes.jsonl fix rounds
        if (-not $mrs.Count -and $x.r.summary) { $agents[$id].note = ([string]$x.r.summary).Substring(0, [math]::Min(300, ([string]$x.r.summary).Length)) }
      }
      elseif (-not $p) { $agents[$id] = [ordered]@{ mrs = @(); done = @(); deferred = @(); needsLiveCheck = @(); note = ([string]$x.r).Substring(0, [math]::Min(300, ([string]$x.r).Length)) } }
    }
    'ship' { if ($agents.Contains($id) -and $x.r.mrs) { foreach ($sm in @($x.r.mrs | Where-Object { $_ })) { $u = & $nuUrl $sm.url
      foreach ($m in $agents[$id].mrs) { if ((& $nuUrl $m.url) -eq $u -and $sm.mergeState) { $m.mergeState = [string]$sm.mergeState; $m.merged = ($sm.mergeState -eq 'MERGED') } } } } }
    'review' { foreach ($f in $x.r.findings) { [void]$findings.Add([ordered]@{ agent = $id; severity = $f.severity; file = $f.file; line = $f.line; problem = $f.problem; fix = $f.fix; mr = $f.mr }) } }
    { $_ -in 'test', 'retest' } { if ($x.r.checks) { $c = @($x.r.checks); $qa[$id] = [ordered]@{ checks = $c.Count; pass = @($c | Where-Object result -in 'PASS', 'PASS_WITH_NOTE').Count; fail = @($c | Where-Object result -eq 'FAIL').Count; notTested = @($c | Where-Object result -eq 'NOT_TESTED').Count } } }
    'close' { if ($qa.Contains($id)) { $qa[$id].published = [bool]$x.r.ok } }
    'learn' { $learn = $x.r }
  }
}
$addressed = @($findings | Where-Object { $_.severity -ne 'nit' -and $agents[$_.agent].fixedRound })
$open = @($findings | Where-Object { $_.severity -ne 'nit' -and -not $agents[$_.agent].fixedRound })
# host state wins
foreach ($a in $agents.Values) { foreach ($m in $a.mrs) { if ($u = ConvertFrom-MrUrl $m.url) {
  $h = try { Invoke-HostVerb 'mr.get' $u } catch { $null }   # a vendor host adapter throws
  if ($h.state -in 'merged', 'opened', 'closed') { $m.merged = $h.state -eq 'merged'; $m.mergeState = if ($m.merged) { 'MERGED' } elseif ($h.state -eq 'closed') { 'NOT_MERGED' } elseif ($h.merge_when_pipeline_succeeds) { 'SCHEDULED' } else { 'OPEN' } } } } }
$out = [ordered]@{ run = $Run; at = (Get-KitStamp); running = $running; stopped = $cut0; agents = $agents; openFindings = $open; qa = $qa; learn = $learn }
$wavesDir = Get-KitPath waves -Create
$wvf = Join-Path $wavesDir "$Run.json"; $wvt = "$wvf.$PID.tmp"; $out | ConvertTo-Json -Depth 8 | Set-Content $wvt; Move-Item -LiteralPath $wvt -Destination $wvf -Force
if ($Json) { $out | ConvertTo-Json -Depth 8; exit 0 }

"=== $Run $(if ($running) { "(running: $($running -join ', '))" } elseif ($Stopped) { "(stopped$(if ($cut0) { ": $($cut0 -join ', ') without result" }))" } else { '(complete)' })"
function Sum($xs, $k) { [int](@($xs | ForEach-Object { $_[$k] }) | Measure-Object -Sum).Sum }
$isSched = { param($m) -not $m.merged -and $m.mergeState -eq 'SCHEDULED' }
$cut = { param($s, $n) $s = [string]$s; $s.Substring(0, [math]::Min($n, $s.Length)) }
if ($Detail) {
  foreach ($k in $agents.Keys) { $a = $agents[$k]; $sc = @($a.mrs | Where-Object { & $isSched $_ }).Count
    '{0,-4} MRs {1}/{2} merged{3} | done [{4}] | deferred {5}{6}' -f $k, @($a.mrs | Where-Object merged).Count, @($a.mrs).Count, $(if ($sc) { ", $sc scheduled" }), ($a.done -join ','), @($a.deferred).Count, $(if ($a.note) { " | $(& $cut $a.note 80)" })
    foreach ($m in @($a.mrs | Where-Object { -not $_.merged })) { "       MR $($m.mergeState): $($m.url)" }
    foreach ($d in @($a.deferred)) { "       deferred $($d.id)$(if ($d.kind -eq 'people') { ' (people step, no hold)' }): $($d.reason)" }
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
    if ($um -or $dc -or $a.note) { '  {0}: {1}{2}{3}' -f $k, $(if ($um) { "$um MR(s) not merged$(if ($sc) { " ($sc scheduled)" }) " }), $(if ($dc) { "deferred $dc ($(@($a.deferred | ForEach-Object { "$($_.id)$(if ($_.kind -eq 'people') { ' people' })" }) -join ',')) " }), $(if ($a.note) { "| $(& $cut $a.note 80)" }) } }
  foreach ($k in $qa.Keys) { $q = $qa[$k]; if ($q.fail -or $q.notTested -or ($q.Contains('published') -and -not $q.published)) { '  {0}: fail {1}, not tested {2}{3}' -f $k, $q.fail, $q.notTested, $(if ($q.Contains('published') -and -not $q.published) { ', NOT published' }) } }
  if ($open.Count) { "--- OPEN review findings ($($open.Count))"; $open | ForEach-Object { "  [$($_.severity)] $($_.agent) $(Split-Path $_.file -Leaf):$($_.line) - $(& $cut $_.problem 100)" } }
}
if ($learn) { "--- learn: $($learn.signals) signal(s); lessons: $(@($learn.lessonsChanged).Count)" }
if ($Detail) { "saved: $(Join-Path $wavesDir "$Run.json")" } else { "(full: -Detail or waves\$Run.json)" }
if (-not $running -and ($due = Get-KitRetroDue -RunFinished)) { "ACT  retro due ($due): /tidy (E10)" }
}

# ---- audit: one timeline (kitlog, journal, board) of a run, agent or task
function Invoke-Audit {
param([string]$Run, [string]$Agent, [Alias('Item')][string]$Task, [string]$Since, [int]$Last = 0, [switch]$All, [switch]$Json)
$now = Get-Date
$from = if ($Since -match '^(\d+)([mhd]?)$') { $now.AddMinutes(-[int]$Matches[1] * (@{ m = 1; h = 60 }[$Matches[2]] ?? 1440)) } elseif ($Since) { [datetime]$Since } else { $null }
$names = @(); $agents = @(); $wf = $null
if ($Run) {   # kit run name or workflow run id
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
if ($wf -and (Test-Path $j)) {   # times: transcript first/last line
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

# ---- storage: free space per drive, folder scans, rescue (adapters/storage.ps1)
function Invoke-Storage { param([string]$Drive, [string]$Since = '24h', [switch]$Folders, [switch]$Scan) Show-KitStorage @PSBoundParameters }

# ---- bugbrief: bug-fix brief + /buildy args (adapters/bugbrief.ps1)

# ---- cleanup: kit-created leftovers only, never repos or in-use
function Invoke-Cleanup {
param([switch]$DryRun, [switch]$IfDue, [switch]$Quiet, [switch]$WorktreesOnly, [string[]]$WorktreeRoot = @(), [double]$WorktreeIdleHours = 2, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
$osTmp = [IO.Path]::GetTempPath().TrimEnd([char]'\', [char]'/')   # arch-ok: reads the OS temp (Claude's own temp, kit leftovers from before <runtime>/tmp)
if (-not $WorktreeRoot) { $WorktreeRoot = $KitConf.WorktreeRoots }
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
Invoke-KitHooks Invoke-KitCleanup   # test browsers, profiles, idle daemons (cleanup.idleDaemons)

# retention: kit.example.json _paths.keep; live browser locks, pending decisions stay
$pm = $script:KitPathMap
foreach ($p in @((Get-KitProps $pm.keep) | Where-Object Name -notlike '_*')) {
  $v = @($p.Value); $n = if ($v.Count -gt 1) { [int]$v[1] } else { 0 }
  foreach ($i in @(Get-ChildItem (Get-KitPath $p.Name) -Force | Where-Object { $_.Name -notmatch '^tabs-|\.lock$' -and -not ($p.Name -eq 'decisions' -and (Get-Content $_.FullName -Raw) -match '"status":\s*"pending"') } | Sort-Object LastWriteTime -Descending | Select-Object -Skip $n)) { if (Old $i $v[0]) { Gone $i.FullName "$($p.Name) > $($v[0]) h" } }
}
# QA run files: 7 d after report, 30 d without (results kept)
foreach ($r in Get-ChildItem (Get-KitPath qa-runs) -Directory | Where-Object { Old $_ 168 }) { $all = Old $r 720
  foreach ($sub in Get-ChildItem $r.FullName -Recurse -Directory | Where-Object Name -in 'shots', 'evidence', 'scripts') { if ($all -or (Test-Path (Join-Path $sub.Parent.FullName 'report.md'))) { Gone $sub.FullName 'QA run media (7 d published / 30 d)' } } }
# unnamed: root 72 h, work/ 168 h, cache/ logs/ 720 h; durable listed only
$known = @{}; foreach ($r in @((Get-KitProps $pm.runtime).Value)) { $s = ([string]$r).TrimEnd('/') -split '/'; $known[$s[0]] = 1; if ($s.Count -gt 1) { $known["$($s[0])/$($s[1])"] = 1 } }
$rt = Get-KitRuntime
foreach ($i in Get-ChildItem $rt -Force) { if (-not $known[$i.Name] -and (Old $i 72)) { Gone $i.FullName 'not in the layout (runtime root)' } }
foreach ($top in 'work', 'cache', 'logs') { $h = if ($top -eq 'work') { 168 } else { 720 }
  foreach ($i in Get-ChildItem (Join-Path $rt $top) -Force | Where-Object Name -notmatch '\.lock$') { if (-not $known["$top/$($i.Name)"] -and (Old $i $h)) { Gone $i.FullName "not in the layout ($top/)" } } }
$dk = @((Get-KitProps $pm.durable).Value | ForEach-Object { (([string]$_).TrimEnd('/') -split '/')[0] })
$sd = Split-Path (Get-KitPath tracking); $odd = @(Get-ChildItem $sd -Force | Where-Object { $_.Name -notin $dk -and $_.Name -notmatch '\.(lock|bad-.*)$' })
if ($odd) { $notes += "durable state not in the layout (kept; move or delete by hand): $(@($odd | ForEach-Object Name) -join ', ')" }

foreach ($f in Get-ChildItem (Get-KitGateLedger) -Filter '*.json' | Where-Object Name -ne 'history.json') {
  try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (-not (Test-KitPid $e.pid $e.start)) { Gone $f.FullName 'dead gate entry' } } catch {}
}

$ct = if ($DryRun) { [long](Size (Join-Path $osTmp 'claude')) }; if ($ct) { $notes += "Claude session temp (outside the kit, not managed): $([math]::Round($ct / 1MB)) MB in $(Join-Path $osTmp 'claude')" }

# legacy: kit files in the OS temp (the old build-gate ledger); 24 h idle: a not-yet-pulled kit copy keeps its live ones
foreach ($f in Get-ChildItem $osTmp -Force | Where-Object { $_.Name -match '^(kit-|claude-kit-|claude-build-gate$|wfc\.js$|gradletest$|report-preview\.html$|gate-debug\.ps1$|bad-findings\.json$|audit-test$|kitshots$|tsc\d\.log$|claude-wt-selftest$)' }) {
  if (Old $f 24) { Gone $f.FullName 'kit leftover in the OS temp (legacy)' }
}

}

# all repos' worktrees + branches: crafty.ps1 wt sweep (dirty, unpushed, held stay)
$rootList = $WorktreeRoot -join ','; $kept = @()
try { $sw = $(if ($DryRun) { & $KitCmd.dev wt sweep -Root $rootList -IdleHours $WorktreeIdleHours -Json -DryRun } else { & $KitCmd.dev wt sweep -Root $rootList -IdleHours $WorktreeIdleHours -Json }) -join "`n" | ConvertFrom-Json
  foreach ($x in @($sw.actions)) { $script:freed += [long]$x.bytes; [void]$actions.Add([pscustomobject]@{ mb = [long]$x.bytes / 1MB; why = $x.why; path = $x.path }) }; $kept = @($sw.kept); $notes += @($sw.notes) } catch { $notes += "worktree sweep failed: $($_.Exception.Message)" }

if (-not $WorktreesOnly) {
$envLogs = [IO.Path]::GetFullPath((Get-KitPath localenv-logs))   # local env rotates these (logMaxMB): a rewrite races the writer
foreach ($f in @(@(Get-ChildItem (Get-KitPath logs) -Filter '*.log' -File -Recurse | ForEach-Object FullName | Where-Object { -not $_.StartsWith($envLogs, [StringComparison]::OrdinalIgnoreCase) }) + @($script:KitLogMap.streams | Where-Object { (Get-KitMember $pm.durable $_) -and -not $script:KitLogTrim.ContainsKey($_) } | ForEach-Object { Get-KitPath $_ }))) {
  # shared read: a writer may hold it
  $over = try { $lr = [IO.StreamReader]::new([IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')); try { $ln = 0; while ($ln -le 5000 -and $null -ne $lr.ReadLine()) { $ln++ }; $ln -gt 5000 } finally { $lr.Dispose() } } catch { $false }
  if ($over) { if (-not $DryRun) { Invoke-KitLocked $f { $keep = Get-Content $f -Tail 5000; Set-Content $f $keep } }; [void]$actions.Add([pscustomobject]@{ mb = 0; why = 'rotated to 5000 lines'; path = $f }) }
}
foreach ($x in @(Invoke-KitLogTrim -DryRun:$DryRun)) { [void]$actions.Add([pscustomobject]@{ mb = 0; why = "rolled into logs-summary.jsonl ($($x.days) d kept raw)"; path = "$($x.stream): $($x.rolled) line(s), $($x.kept) kept" }) }   # signals, decisions, deploys
Gone "$(Get-KitPath tracking).migrated" 'tracking.json.migrated: its tasks live in tasks/'
# forgotten items past their kind's retention (kitbag.py forget)
foreach ($pl in @(& (Get-Python) -X utf8 $KitCmd.kitbag forget --purge $(if ($DryRun) { '--dry-run' }) 2>$null | Where-Object { $_ -match '^(would delete|deleted) ' })) { [void]$actions.Add([pscustomobject]@{ mb = 0; why = 'forgotten items past retention'; path = ($pl -replace '^(would delete|deleted) ', '') }) }

}
$summary = "$(if ($DryRun) { '[dry run] would free' } else { 'freed' }) $([math]::Round($script:freed / 1MB, 1)) MB in $($actions.Count) action(s)"
$groups = @($actions | Group-Object why | ForEach-Object { [pscustomobject]@{ why = $_.Name; n = $_.Count; mb = ($_.Group | Measure-Object mb -Sum).Sum; first = $_.Group[0].path } } | Sort-Object mb -Descending)
if (-not $DryRun) { if (-not $WorktreesOnly) { (Get-KitStamp stored $now) | Set-Content $mark }; Write-KitLog calls cleanup @{ freedMB = [math]::Round($script:freed / 1MB, 1); actions = $actions.Count; byWhy = @($groups | ForEach-Object { "$($_.why): $($_.n), $([math]::Round($_.mb, 1)) MB" }) } }
if (-not $Quiet) { $summary; $groups | ForEach-Object { '{0,9:N1} MB {1,5} x  {2}  (e.g. {3})' -f $_.mb, $_.n, $_.why, $_.first }; $notes
  if ($Detail) { "$(if ($DryRun) { 'would go' } else { 'gone' }):"; $actions | ForEach-Object { "  $($_.path)" }; "kept ($($kept.Count)):"; $kept | ForEach-Object { "  $_" } } }
$global:LASTEXITCODE = 0
}

# ---- learn: signals + LESSONS.md (rest: adapters/kit-admin.ps1)
# lessons as LF lines; a "## <name>" section as [start, end)
function Read-KitLessonLines([string]$Path) { if (Test-Path $Path) { , [Collections.Generic.List[string]]@(([IO.File]::ReadAllText($Path) -replace "`r", '') -split "`n") } else { , [Collections.Generic.List[string]]::new() } }
function Find-KitLessonSection($Lines, [string]$Name) { $s = $Lines.IndexOf("## $Name"); if ($s -lt 0) { return $null }; $e = $s + 1; while ($e -lt $Lines.Count -and $Lines[$e] -notmatch '^## ') { $e++ }; , @($s, $e) }
function Invoke-Learn {
  param(
    [string]$Skill, [string]$Kind,
    [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
    [switch]$Show, [int]$Last = 30, [switch]$Stats, [switch]$Read, [switch]$History, [string]$Grep,
    [string]$Lesson, [string]$When, [string]$Do, [string]$Why, [string]$Project, [string]$Fixed, [string]$Bump, [string]$Append, [switch]$Trim, [int]$Max = 40, [ValidateSet('code', 'local', 'ship')][string]$Phase
  )
  if ($Stats -or $History -or $Lesson -or $When -or $Fixed -or $Bump -or $Trim) {   # the retro's tools (kitty, /tidy)
    Invoke-LearnAdmin @PSBoundParameters; return
  }
  $file = Get-KitPath signals -Create
  if ($Show) { if (Test-Path $file) { Get-Content $file -Tail $Last | ForEach-Object { $s = $_ | ConvertFrom-Json; '{0} {1,-13} {2,-15} {3}{4}' -f ([datetime]$s.at).ToString('yyyy-MM-dd HH:mm'), $s.skill, $s.kind, $s.text, $(if ($s.ref) { " [$($s.ref)]" }) } }; return }
  if ($Read) {
    if (-not $Skill) { 'usage: learn -Read -Skill <skill>'; exit 2 }
    foreach ($f in (Join-Path $KitConf.Kit 'LESSONS.md'), (Join-Path $KitConf.Kit 'LESSONS.local.md')) {
      $L = Read-KitLessonLines $f; $r = Find-KitLessonSection $L $Skill; if (-not $r) { continue }
      # read cap (learn.readCap, -Max): most-hit lessons; the rest wait for /tidy -Trim
      $lines = @($L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^(##|###|- )' }); $rcap = if ($PSBoundParameters.ContainsKey('Max')) { $Max } else { [int](Get-KitParam 'learn.readCap') }
      $lines = @(Select-KitLessonScope $lines $Skill $Phase $Project)
      $lsIdx = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '- *' }); $lsOut = @($lsIdx | Sort-Object { if ($lines[$_] -match '\((\d+)[x×]\)\s*$') { -[int]$Matches[1] } else { -1 } }, { -$_ } | Select-Object -Skip $rcap)
      $lines = @(0..($lines.Count - 1) | Where-Object { $_ -notin $lsOut } | ForEach-Object { $lines[$_] }) + @(if ($lsOut.Count) { "($($lsOut.Count) more, fewest hits: learn -Read -Skill $Skill$(if ($Phase) { " -Phase $Phase" }) -Max 99)" })
      if ($lines.Count -gt 1) { "$(if ($f -like '*.local.md') { '(local) ' })$($lines -join "`n")" }
    }
    Get-KitRoleRules $Skill $Phase $Project
    return
  }
  $kinds = 'friction | failure | defect-missed | false-positive | rule-violation | stale-env | flaky | idea | win'
  if ($Kind -and $Kind -notin ($kinds -split ' \| ')) { "learn: -Kind $kinds (not '$Kind')"; exit 2 }
  if (-not ($Skill -and $Kind -and $Text)) { "need -Skill -Kind -Text (Kind: $kinds; or -Read, -Show; kit-admin: -Stats, -History, -When -Do -Why, -Bump, -Fixed, -Trim)"; exit 2 }
  if ($Text.Length -gt 400) { "learn: -Text $($Text.Length) chars > 400: what happened + what fixed it, one line"; exit 2 }
  Write-KitLog signals '' ([ordered]@{ skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source })
  "recorded ($Skill/$Kind)"
}

# ---- decide: decision pauses; only that item waits
# the task's Decisions checklist (Format-KitDecisionItems), no comment
function Publish-KitDecisions([string]$Task, [string]$Link) {
  $rows = @(Get-KitTaskDecisionRows $Task); if (-not $rows.Count) { return "NONE $Task`: no decision records for it (decide ask / record -Task)" }
  $tt = try { Get-TrackerTask $Task } catch { $null }; if (-not $tt.name) { return "SKIP $Task`: no readable tracker task (an item code?): nothing published" }   # -Item A2 resolves to task A2
  if (-not $Link) { $Link = "$((Read-KitState (Get-KitTaskFile $Task)).decisions.link)" }
  $items = @(Format-KitDecisionItems $rows $Link $Task)
  $null = Test-KitProse -Kind decisions -Text (@($items.text) -join "`n")   # warnings only: the records are the facts
  $r = Set-KitTaskChecklist $Task 'Decisions' $items
  Update-KitTaskIndex $Task { param($x) $x.decisions = [ordered]@{ rows = $rows; link = $Link; publishedAt = (Get-KitStamp) } }
  "PUBLISHED decisions of $Task ($(@($items | Where-Object { $_.done -and $_.text -notmatch ' → superseded by |^plan · ' }).Count) in force, $(@($items | Where-Object { -not $_.done }).Count) open): $(if ("$r") { "$r" } else { 'checklist updated' })"
}
function Invoke-Decide {
  param([Parameter(Position = 0)][ValidateSet('ask', 'list', 'answer', 'wait', 'record', 'check', 'publish', 'rules')][string]$Action = 'list',
    [string]$Run, [string]$Agent, [string]$Item, [string]$Question, [string[]]$Options = @(), [string]$Recommend, [string]$Contracts,
    [string]$Id, [string]$Answer, [string]$By = 'owner', [int]$MaxMinutes = 50, [switch]$Pending, [switch]$Json, [switch]$Fyi, [switch]$Ask, [int]$Max = 4,
    [ValidateSet('decision', 'envfix')][string]$Kind = 'decision',
    [string]$Task, [Alias('Mr')][string[]]$Mrs = @(), [string]$Commit, [string]$ParentId, [string]$Rationale,
    [string]$Gate = '',   # record: one of $kitGates; check -Id: a non-gate word is ignored
    [ValidateSet('', 'askuser', 'chat')][string]$Source = '', [int]$MaxHours = 12, [switch]$Use,
    [string[]]$Supersedes = @(), [string]$Link, [switch]$NoPublish, [switch]$Propose, [string]$Approve, [string]$Revoke, [string]$Context)
  $dir = Get-KitPath decisions -Create; $kitGates = @('deploy', 'merge', 'premerge', 'close', 'rollback', 'secret', 'data', 'scope', 'other')
  # a gate word is a person's: an agent or the coordinator as -By is none
  $crewNames = @('coordinator') + @(Get-ChildItem (Join-Path $KitConf.Kit 'agents') -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object BaseName)
  $crewRx = "(?i)^($(@($crewNames | ForEach-Object { [regex]::Escape($_) }) -join '|'))([-_ :]|$)"

  $get = { param($i) $f = Join-Path $dir "$i.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
  $save = {
    param($o)
    $f = Join-Path $dir "$($o.id).json"
    Invoke-KitLocked $f { Write-KitState $f $o 2 }
    Write-KitLog decisions-log $o.status ($o | Select-Object * -ExcludeProperty at, schemaVersion, updated, holder)   # at = this line's time
  }
  $note = { param($file, $text) if ($file -and (Test-Path (Split-Path $file))) { Add-Content -LiteralPath $file "`n$text" -Encoding utf8 } }
  $pub = { param($t, [bool]$Named) if ($t -and -not $NoPublish -and ($Named -or (Test-Path (Get-KitTaskFile $t)))) { try { Publish-KitDecisions $t $Link } catch { Write-Warning "Decisions checklist of $t not updated (decide publish -Task $t retries): $_" } } }
  $supIds = @(Split-KitList $Supersedes)
  switch ($Action) {
    'ask' {
      if (-not ($Agent -and $Question)) { 'usage: decide ask -Run <run> -Agent <id> -Item <item> -Context "today: <what happens now>" -Question "<q>" -Options "A: <label> — <its effect>","B: .." -Recommend A [-Fyi] [-Contracts <file>]'; exit 2 }
      $opts = @(Get-KitDecisionChoices @($Options | ForEach-Object { "$_" -split ',(?=\s*[A-Za-z0-9]+\s*:)' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) $Recommend)
      # owner 2026-11-23: today + why, each option's effect, a pick
      $miss = @(if ($Kind -eq 'decision') {
          if (-not $Context -and @("$Question" -split '\s+').Count -lt 15) { '-Context "today: <what happens now, a short example>; why it comes up"' }
          if ($opts.Count -lt 2) { 'two or more -Options' }
          if (@($opts | Where-Object { -not $_.description -and @("$($_.label)" -split '\s+').Count -lt 6 }).Count) { 'each option "<key>: <label> — <its effect on users / business / cost / risk, plain words>"' }
          if (-not $Recommend) { '-Recommend <key> (the default when the owner is not sure)' } })
      if ($miss.Count) { "decide ask refused: missing $($miss -join '; '). Plain words; a technical term gets a one-line explanation. Nothing was asked."; exit 2 }
      $shown = "$(if ($Context) { "Today: $(($Context.Trim() -replace '^(?i)today\s*:\s*').TrimEnd('.')). " })$("$Question".Trim())$(if ($Kind -eq 'decision' -and $Recommend -and -not $Fyi) { " Not sure? The default is $Recommend." })"
      $mrsClean = @(Split-KitList $Mrs | ForEach-Object { ConvertTo-MrRef $_ })
      $resolvedTask = if ($Task) { NormTask $Task } elseif ($Item -and (NormTask $Item)) { NormTask $Item } else { '' }
      $o = [ordered]@{ id = "$(if ($Kind -eq 'envfix') { 'e' } else { 'd' })-$(Get-Date -Format yyyyMMddHHmmss)-$($Agent.ToLower() -replace '[^\w-]', '')-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
        kind = $Kind; run = $Run; agent = $Agent; item = $Item; question = $Question
        options = $opts; recommend = $Recommend; blocking = -not $Fyi; contracts = $Contracts; status = 'pending'; at = (Get-KitStamp)
        task = $resolvedTask; mrs = $mrsClean; commit = $Commit; parentId = $ParentId; gate = $(if ($Gate -in $kitGates) { $Gate }) }
      $sr = if (Get-Command Get-KitStandingRuleAnswer -ErrorAction SilentlyContinue) { Get-KitStandingRuleAnswer ([pscustomobject]$o) }   # an owner-approved standing rule answers it (adapters/outcomes.ps1)
      if ($sr) { $o.status = 'answered'; $o.answer = $sr[0]; $o.by = "standing rule $($sr[1])"; $o.source = 'rule'; $o.answeredAt = $o.at }
      $o.question = $shown; $o.ask = "$Question"   # standing rules match the bare ask
      & $save ([pscustomobject]$o)
      if ($resolvedTask) {
        Update-KitTracking { param($t) if ($t.tasks[$resolvedTask]) { $t.tasks[$resolvedTask].decisions = @(@($t.tasks[$resolvedTask].decisions) + $o.id | Select-Object -Unique) } }
      }
      if ($Kind -eq 'envfix') {
        & $note $Contracts "## ENV-FIX NEEDED $($o.id) ($Agent, item $Item)$(if ($resolvedTask) { " [Task: $resolvedTask]" })`n$Question`nDone: pending (the coordinator appends it below)"
        "ENV-FIX $($o.id) pending: the coordinator fixes the local env; item $Item waits. Wait: bossy.ps1 decide wait -Id $($o.id)"; return
      }
      if ($sr) { & $note $Contracts "DECISION $($o.id) ANSWERED by standing rule $($sr[1]): $($sr[0])"; "DECISION $($o.id) ANSWERED by standing rule $($sr[1]): $($sr[0]) (the owner revokes: decide rules -Revoke $($sr[1])). Wait: bossy.ps1 decide wait -Id $($o.id)"; $null = & $pub $resolvedTask $false; return }
      $txt = (Format-KitDecision ([pscustomobject]$o)) -join "`n"; $null = Test-KitProse -Kind decision-request -Text $txt; & $note $Contracts $txt
      "DECISION $($o.id) pending: $(if ($Fyi) { "FYI, item $Item goes on" } else { "item $Item stops (needs decision); continue your other items" }). Wait: bossy.ps1 decide wait -Id $($o.id)"
      $null = & $pub $resolvedTask $false   # its open item; the DECISION line stays last
    }
    'list' {
      $all = @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not ($Pending -or $Ask -or $Fyi) -or $_.status -eq 'pending' })
      if ($Ask -or $Fyi) { $all = @($all | Where-Object { $_.kind -ne 'envfix' -and ($_.blocking -eq $false) -eq [bool]$Fyi }) }
      if ($Ask) { if ($Json) { ConvertTo-KitAskPayload $all $Max | ConvertTo-Json -Depth 6 } else { $all | Select-Object -First $Max | ForEach-Object { (Format-KitDecision $_) -join "`n"; '' } }; return }
      if ($Fyi) { Format-KitFyiList $all; return }
      if ($Json) { ConvertTo-Json @($all) -Depth 5; return }
      foreach ($d in $all) { "$($d.status.ToUpper()) $($d.id) $($d.run)/$($d.agent) item $($d.item)$(if ($d.task) { " [Task: $($d.task)]" }): $($d.question) | options: $(@(Get-KitDecisionOrder $d | ForEach-Object { "$($_.key): $($_.label)" }) -join ' ; ')$(if ($d.recommend) { " | recommended: $($d.recommend)" })$(if ($d.answer) { " | answer: $($d.answer)" })$(if ($d.rationale) { " | rationale: $($d.rationale)" })" }
      if (-not $all.Count) { 'no decisions' }
    }
    'answer' {
      $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
      if (-not $Answer) { 'usage: decide answer -Id <id> -Answer "<words>" [-Supersedes <ids>] [-Link <plan url>] [-NoPublish]'; exit 2 }
      $o.status = 'answered'; $o | Add-Member -Force answer $Answer; $o | Add-Member -Force by $By; $o | Add-Member -Force answeredAt (Get-KitStamp)
      if ($Rationale) { $o | Add-Member -Force rationale $Rationale }
      if ($supIds.Count) { $o | Add-Member -Force supersedes $supIds }
      & $save $o
      & $note $o.contracts "DECISION $Id ANSWERED by $($By): $Answer$(if ($Rationale) { " (Rationale: $Rationale)" })"
      "answered $Id ($($o.agent), item $($o.item)): $Answer"
      # a scope ask (-Gate scope, or naming `decide record -Gate scope`) answered by a recording pick: the scope word (wt commit -ScopeOk)
      $scItem = if ("$($o.question)" -match '-Gate scope -Item\s+(\S+)') { $Matches[1].TrimEnd('.,;)') } elseif ($o.gate -eq 'scope') { "$($o.item)" }
      $pick = @($o.options | Where-Object { $Answer -match "^\s*$([regex]::Escape("$($_.key)"))\b" })[0]
      if ($scItem -and $By -notmatch $crewRx) {
        if ($pick -and "$($pick.label)" -match '(?i)\b(record|approve|allow|widen|yes)\b' -and "$($pick.label)" -notmatch "(?i)\b(split|hold|revert|separate|no|not|don'?t|deny|reject|refuse|never|keep)\b") {
          $now = (Get-KitStamp); $sc = [pscustomobject][ordered]@{ id = "d-$(Get-Date -Format yyyyMMddHHmmss)-coordinator-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
            kind = 'decision'; run = $o.run; agent = 'coordinator'; item = $scItem; gate = 'scope'; question = $o.question; options = @(); blocking = $false; status = 'answered'; at = $now
            task = "$($o.task)"; mrs = @($o.mrs); answer = $Answer; by = $By; source = 'chat'; answeredAt = $now; supersedes = @(); parentId = $Id }
          & $save $sc; $o | Add-Member -Force scopeId $sc.id; & $save $o; & $note $o.contracts "DECISION $Id SCOPE WORD $($sc.id) ($scItem)"; "SCOPE RECORDED $($sc.id) (scope $scItem, from $Id): pass it to the agent (wt commit -ScopeOk $($sc.id))"
        } else { "scope ask $Id answered without a record / approve pick: no scope word (decide record -Gate scope -Item $scItem when the owner allows it)" }
      }
      if ($o.item -eq 'standing-rules' -and $By -notmatch $crewRx -and (Get-Command Set-KitStandingRuleAnswer -ErrorAction SilentlyContinue)) { Set-KitStandingRuleAnswer $Id $Answer $By }   # approved -> rules/standing-rules.local.md
      if ($o.kind -ne 'envfix') { & $pub "$($o.task)" $false }   # a known task only: -Item A2 / staging / 3 is no tracker task
    }
    'rules' { Invoke-KitStandingRules -Propose:$Propose -Approve $Approve -Revoke $Revoke -By $By -Json:$Json }
    'publish' {
      $pt = NormTask $Task; if (-not $pt) { 'usage: decide publish -Task <id> [-Link <plan / brief url>]   (the Decisions checklist of the task, items updated in place)'; exit 2 }
      $pr = Publish-KitDecisions $pt $Link; $pr; if ($pr -match '^(SKIP|NONE) ') { exit 1 }
    }
    'wait' {
      $until = (Get-Date).AddMinutes($MaxMinutes)
      while ($true) {
        $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
        if ($o.status -eq 'answered') { "ANSWERED $Id`: $($o.answer)$(if ($o.rationale) { " [Rationale: $($o.rationale)]" })$(if ($o.scopeId) { " [scope word: wt commit -ScopeOk $($o.scopeId)]" })"; return }
        if ((Get-Date) -ge $until) { "PENDING $Id (no answer within $MaxMinutes min; wait again)"; exit 1 }
        Wait-KitPoll 30
      }
    }
    'record' {
      if (-not ($Gate -in $kitGates -and $Item -and $Question -and $Answer -and $Source)) { "usage: decide record -Gate $($kitGates -join '|') -Item <env|task|MR> -Question <q> -Answer <pick, verbatim> -Source askuser|chat [-By <person>] [-Mrs] [-Task] [-Supersedes <ids>] [-NoPublish]"; exit 2 }
      if ($By -match $crewRx -or ($Agent -and $Agent -ne 'coordinator')) { "refused: -By names the person who gave the word, never an agent or the coordinator ($By): omit -By (default owner) or name the person; the coordinator runs it without -Agent"; exit 2 }
      $resolvedTask = if ($Task) { NormTask $Task } elseif (($tagRx = Get-KitTaskTagRx) -and $Item -match $tagRx) { NormTask $Item } else { '' }
      $now = (Get-KitStamp)
      $o = [pscustomobject][ordered]@{ id = "d-$(Get-Date -Format yyyyMMddHHmmss)-coordinator-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
        kind = 'decision'; run = $Run; agent = 'coordinator'; item = $Item; gate = $Gate; question = $Question
        options = @(); blocking = $false; contracts = $Contracts; status = 'answered'; at = $now; task = $resolvedTask
        mrs = @(Split-KitList $Mrs | ForEach-Object { ConvertTo-MrRef $_ }); answer = $Answer; by = $By; source = $Source; answeredAt = $now; supersedes = $supIds }
      & $save $o
      if ($resolvedTask) { Update-KitTracking { param($t) if ($t.tasks[$resolvedTask]) { $t.tasks[$resolvedTask].decisions = @(@($t.tasks[$resolvedTask].decisions) + $o.id | Select-Object -Unique) } } }
      & $note $Contracts "DECISION $($o.id) RECORDED ($Gate $Item) by $($By) via $($Source): $Answer"
      "RECORDED $($o.id) ($Gate $Item): `"$Answer`" by $By via $Source at $now. Pass the id to the agent (decide check -Id)"
      & $pub $resolvedTask ([bool]$Task)
    }
    'check' {
      if (-not ($Id -or ($Gate -and ($Item -or $Mrs)))) { 'usage: decide check (-Id <id> [-Item <env|task|mr>,..] [-Gate <g>,..] | -Gate <gate> (-Item <env|task> | -Mrs <refs>)) [-MaxHours 12] [-Use -Agent <id>]   (with -Id a non-gate -Gate such as ask is ignored)'; exit 2 }
      # -Item a,b: any of them (also a record's MR); -Id with -Gate a,b: the record's gate is one of them (buildy NONE word)
      $wantMrs = @(Split-KitList $Mrs | ForEach-Object { ConvertTo-MrRef $_ }); $items = @(Split-KitList $Item); $gates = @(Split-KitList $Gate)
      $wantTasks = @($items | ForEach-Object { NormTask $_ } | Where-Object { $_ })
      $since = (Get-Date).AddHours(-$MaxHours); $why = @()
      $found = @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.status -eq 'answered' -and $_.kind -ne 'envfix' } |
        Where-Object {
          # every key given matches: a staging yes never serves production
          $rec = $_; $itemOk = -not $items.Count -or $rec.item -in $items -or ($rec.task -and $rec.task -in $wantTasks) -or @($rec.mrs | Where-Object { $_ -in $items }).Count
          $mrOk = -not $wantMrs.Count -or -not @($wantMrs | Where-Object { $_ -notin @($rec.mrs) }).Count
          $gateOk = if ($Id) { $rec.id -eq $Id -and ($rec.gate -or $Item -or $wantMrs.Count) -and $(if ($gates.Count -gt 1) { $rec.gate -in $gates } else { -not $rec.gate -or $Gate -notin $kitGates -or $rec.gate -eq $Gate }) } else { $rec.gate -in $gates }
          $gateOk -and $itemOk -and $mrOk })
      foreach ($d in $found) {
        if ($d.by -match $crewRx -or $d.source -eq 'rule') { $why += "$($d.id) answered by $($d.by), no person"; continue }
        if ($d.usedAt) { $why += "$($d.id) already used by $($d.usedBy) at $($d.usedAt)"; continue }
        if ([datetime]$d.answeredAt -lt $since) { $why += "$($d.id) older than $MaxHours h"; continue }
        if ($Use) {   # under the record's lock: two agents never both use one word
          $df = Join-Path $dir "$($d.id).json"; $usedBy = if ($Agent) { $Agent } else { 'unknown' }
          $won = Invoke-KitLocked $df { $cur = Get-Content $df -Raw | ConvertFrom-Json; if ($cur.usedAt) { $cur } else { $cur | Add-Member -Force usedAt (Get-KitStamp); $cur | Add-Member -Force usedBy $usedBy; Write-KitState $df $cur 2; $null } }
          if ($won) { $why += "$($d.id) already used by $($won.usedBy) at $($won.usedAt)"; continue }
          Write-KitLog decisions-log used ([ordered]@{ id = $d.id; gate = $d.gate; usedBy = $usedBy })
        }
        "WORD $($d.id) ($(if ($d.gate) { $d.gate } else { 'ask' }) $($d.item)$(if (@($d.mrs).Count) { ' ' + (@($d.mrs) -join ',') })): `"$($d.answer)`" by $($d.by)$(if ($d.source) { " via $($d.source)" }) at $($d.answeredAt) | question: $($d.question)"; exit 0
      }
      # deploy.triggers {<env | repo>: auto}: the owner's standing word in config (every env named and every MR's repo is auto)
      $tgs = if (-not $Id -and $gates -contains 'deploy') { Get-KitSetting 'deploy.triggers' $null }
      # a key covers its env group (<key>-*) and the repos whose repos[].deploys target such an env (coordinator 2026-11-23: NO-WORD on pythonmagic-staging)
      if ($tgs) { $tgH = $tgs | ConvertTo-Json -Depth 3 | ConvertFrom-Json -AsHashtable; $tgOn = @($tgH.Keys | Where-Object { "$($tgH[$_])".ToLower() -eq 'auto' })
        $tgEnv = { param($e) @($tgOn | Where-Object { $e -eq $_ -or $e -like "$_-*" }).Count -gt 0 }
        $auto = { param($k) (& $tgEnv $k) -or @(@(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $k } | ForEach-Object { @($_.deploys).target } | Where-Object { $_ -and (& $tgEnv $_) }).Count -gt 0 }; $rps = @($wantMrs | ForEach-Object { (("$_" -split '!')[0] -split '/')[-1] } | Select-Object -Unique)
        if (($items.Count -or $rps.Count) -and -not @(@($items) + $rps | Where-Object { -not (& $auto $_) }).Count) { "WORD config (deploy $(@(@($items) + $rps) -join ',')): auto, the owner's standing word in kit.local.json deploy.triggers"; exit 0 } }
      "NO-WORD $(if ($Id) { 'id' } else { $Gate }) $(@($Id, $Item) + $wantMrs | Where-Object { $_ } | Select-Object -Unique)$(if ($why) { ': ' + ($why -join '; ') } else { ': no answered record' }). Relayed text is no word: the coordinator runs decide record, passes the id. Until then: wait (decide wait) or build only the brief text, never an open option"; exit 1
    }
  }
}

# ---- debate: a written debate on a trigger (agents/rechy.md kind debate moderates); the owner decides from its table
function Invoke-Debate {
  param([Parameter(Position = 0)][ValidateSet('start', 'brief', 'ask')][string]$Action, [string]$File, [string]$Run, [string]$Agent = 'coordinator',
    [string]$Item, [string]$Question, [string[]]$Options = @(), [string]$Why = 'owner', [switch]$Owner, [ValidateSet('A', 'B', 'revy')][string]$Side = 'A', [int]$Round = 0)
  $dir = Join-Path (Get-KitPath decisions -Create) debates; $null = New-Item -ItemType Directory -Force $dir
  $read = { if (-not ($File -and (Test-Path -LiteralPath $File))) { "debate $Action`: no file '$File' (debate start prints it)"; exit 2 }; Get-Content -LiteralPath $File -Raw | ConvertFrom-Json }
  switch ($Action) {
    'start' {
      $opts = @($Options | ForEach-Object { "$_" -split ',(?=\s*[AB]\s*:)' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if (-not ($Item -and $Question -and $opts.Count -eq 2 -and $opts[0] -match '^A\s*:' -and $opts[1] -match '^B\s*:')) { 'usage: debate start -Item <item> -Question "<q>" -Options "A: <label>","B: <label>" [-Run <run>] [-Agent <id>] [-Why <trigger>] [-Owner]'; exit 2 }
      $own = $Owner -or $Why -eq 'owner'
      $had = @(Read-KitJsonFiles $dir | Where-Object { $Run -and $_.run -eq $Run -and -not $_.owner })
      if ($had.Count -and -not $own) { "REFUSED: run $Run had its debate ($($had[0].id)); 1 per run unless the owner asks (-Owner): ask A/B with decide ask"; exit 1 }
      $id = "debate-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0, 4))"; $f = Join-Path $dir "$id.json"
      Write-KitState $f ([ordered]@{ id = $id; run = $Run; agent = $Agent; item = $Item; question = $Question; options = $opts; trigger = $Why; owner = [bool]$own })
      "DEBATE $f"
    }
    'brief' {
      $d = & $read; $role = if ($Side -eq 'revy') { 'revy' } else { 'rechy' }
      $char = [regex]::Match("$(Get-Content (Join-Path $KitConf.Kit "agents/$role.md") -Raw -ErrorAction SilentlyContinue)",'(?ms)^\*\*Character:\*\*.*?(?=\r?\n\s*\r?\n)').Value -replace '\s*\r?\n\s*', ' '
      "DEBATE $($d.id) ($($d.trigger)), item $($d.item): $($d.question)"; @($d.options) | ForEach-Object { "  $_" }
      "You are $(if ($Side -eq 'revy') { 'revy, the summariser (no vote, no new option)' } else { "the advocate of option $Side, fresh this round" }). $char (Re-read it each round: it shapes how you argue, never a rule.)"
      'Read-only: code, docs, data, a check through crafty.ps1 check; no edits, no builds of your own; <= 250 words; evidence = file:line, a link, a test or a measurement.'
      $(switch ("$Side$Round") {
          { $_ -match '^[AB]0$' } { "ROUND 0 (blind: you have not seen the other case): argue option $Side only. Return {label, change (what a user sees), cost, risk, effort, evidence: []}." }
          { $_ -match '^[AB]1$' } { 'ROUND 1, the last: the other option''s round-0 JSON is in your prompt. Return {against}: the strongest point against it, evidence only (no rhetoric, no repeat of your case).' }
          'revy1' { 'SUMMARY: check each side''s evidence (open every file:line). Return {recommend: A|B, why: one line naming the deciding evidence, settleBy: one read-only check (a test, a query, a measurement) that would settle it, else empty}.' }
          'revy2' { 'ROUND 2 (only to settle it): run the settleBy check once. Return {recommend, why, test: "<command> -> <result line>"}. Hard stop.' }
          default { "debate brief: no part for -Side $Side -Round $Round (A|B 0-1, revy 1-2)"; exit 2 } })
    }
    'ask' {
      $d = & $read; $rows = @($d.rows); $v = $d.verdict
      if ($rows.Count -ne 2 -or "$($v.recommend)" -notmatch '^[AB]$') { "debate ask: $File needs rows (A, B) and verdict.recommend A|B (agents/rechy.md kind debate step 4)"; exit 2 }
      $cell = { param($s) ((@($s) -join ' · ') -replace '[|\r\n]+', ' / ').Trim() }
      $t = @("## Debate $($d.id) ($($d.trigger)): $($d.question)", '| Option | User-visible change | Cost | Risk | Effort | Evidence | Strongest point against |', '|---|---|---|---|---|---|---|') +
        @($rows | ForEach-Object { "| $($_.option): $(& $cell $_.label) | $(& $cell $_.change) | $(& $cell $_.cost) | $(& $cell $_.risk) | $(& $cell $_.effort) | $(& $cell $_.evidence) | $(& $cell $_.against) |" }) +
        "**revy recommends $($v.recommend):** $(& $cell $v.why)$(if ($v.test) { " · test: $(& $cell $v.test)" })"
      $md = $File -replace '\.json$', '.md'; Set-Content -LiteralPath $md ($t -join "`n") -Encoding utf8; $t
      $opt = { param($r) ("$($r.option): $($r.label) — $($r.change); cost $($r.cost); risk $($r.risk); effort $($r.effort); against: $($r.against)" -replace ',(?=\s*\w+\s*:)', ';') -replace '[\r\n]+', ' ' }
      Invoke-Decide ask -Run $d.run -Agent $d.agent -Item $d.item -Question "$($d.question) (debate table: $md)" -Options @($rows | ForEach-Object { & $opt $_ }) -Recommend $v.recommend -Context "two advocates and a judge compared both options ($($d.trigger)); the table has the evidence"
    }
  }
}

# ---- health: SessionStart hook; no network
function Invoke-Health {
param([switch]$Flow, [switch]$Fetch, [switch]$Checks)
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$py = if (Get-Command (Get-Python) -ErrorAction SilentlyContinue) { Get-Python }
if ($Checks) {   # 6-7 s: background, health shows the last run
  if ($py) { "$(& $py -X utf8 $KitCmd.kitbag lint $kit --summary --warn --no-flow 2>$null)"; foreach ($c in 'port --deploy', 'port --check') { & $py -X utf8 $KitCmd.kitbag @($c -split ' ') 2>$null } }
  exit 0
}
if ($Flow -or $Fetch) {
  if ($Fetch -and (Test-Path (Join-Path $kit '.git'))) {
    # one fetch per 10 min across sessions; a failure = one hook-error line
    $fh = Join-Path $kit '.git/FETCH_HEAD'; if (-not (Test-Path -LiteralPath $fh) -or ((Get-Date) - (Get-Item -LiteralPath $fh).LastWriteTime).TotalMinutes -ge 10) { git -C $kit fetch --quiet 2>$null }
    $null = Test-KitWake   # reboot or wake: re-evaluate learned params
  }
  if ($Flow -and $py) {   # 15 s: only when the kit's tree or its uncommitted edits moved since the last build
    $fst = Get-KitPath kit-flow-stamp -Create; $tree = "$(git -C $kit rev-parse 'HEAD^{tree}' 2>$null)|$(Get-KitHash "$(@(git -C $kit diff HEAD 2>$null) + @(git -C $kit ls-files -o --exclude-standard 2>$null) -join "`n")")"
    $same = (Test-Path -LiteralPath (Get-KitPath kit-flow)) -and (Test-Path -LiteralPath $fst) -and ([IO.File]::ReadAllText($fst).Trim() -eq $tree)
    if (-not $same) { & $py -X utf8 $KitCmd.kitbag flow $kit | Out-Null; if ($LASTEXITCODE -eq 0) { Write-KitAtomic $fst $tree } }
  }
  exit 0
}

$msgs = @()
if (Test-Path (Join-Path $kit '.git')) {
  $exOut = try { @(& $KitCmd.orch setup -Exclude) } catch { @() }
  $st = @(git -C $kit status --porcelain=v1 --branch 2>$null)
  $head = [string]($st | Select-Object -First 1)
  $changes = @($st | Select-Object -Skip 1).Count
  $parts = @($exOut | Where-Object { "$_" -like 'dropped *' } | ForEach-Object { "$_ (pre-push refused them)" })
  if ($changes) { $parts += "$changes uncommitted change(s) (commit + push them, or list org-only paths in kit.local.json localOnly)" }
  if ($head -match '\.\.\.(?<up>\S+)') {
    $up = $Matches.up
    if ($head -match 'behind (?<b>\d+)') { $parts += "$($Matches.b) commit(s) behind $up (git -C $kit pull --rebase once no agents run)" }
    if ($head -match 'ahead (?<a>\d+)') { $parts += "$($Matches.a) commit(s) ahead of $up (push them)" }
  }
  if ((git -C $kit config core.hooksPath 2>$null) -ne '.githooks') { $parts += "pre-push gate off (run: pwsh -File $($KitCmd.orch) setup)" }
  $pf = Get-KitPath kit-protect
  $st = if (Test-Path $pf) { @(Get-Content $pf | Where-Object { $_ }) }; $bad = if (-not $st) { 'unchecked' } else { @($st | Where-Object { $_ -notmatch '^\S+ (ok|set|skip)' }) }
  if ($bad) { $parts += "origin main protection: $($bad -join ', ') (run: bossy.ps1 setup)" }
  if ($parts) { $msgs += "kit: " + ($parts -join '; ') }
} else {
  $msgs += "kit: $kit is not a git clone of the kit repo (install: README Install)"
}
# workflows die with their session
$hook = $null
if ([Console]::IsInputRedirected) { try { $hook = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch {} }
if (-not $hook -or $hook.source -ne 'compact') {
  # crash or power loss: a gone process -> crashed
  $crashed = @(Set-KitBoardCrashed); $closed = @(Invoke-KitHooks Close-KitFinishedRuns)   # finished, never closed: off the list
  if ($closed.Count) { $msgs += "closed $($closed.Count) finished run record(s) nobody closed" }
  foreach ($s in @(Get-StoppedRuns -Hours 24 | Where-Object { -not $_.paused })) { foreach ($x in @($s.file, $s.selfFile) | Where-Object { $_ }) { try { Invoke-KitLocked $x { $j = Get-Content -LiteralPath $x -Raw | ConvertFrom-Json; if (-not $j.crashed) { $j | Add-Member -Force NoteProperty crashed (Get-KitStamp); Write-KitAtomic $x ($j | ConvertTo-Json -Depth 30) } } } catch {} } }
  $stopped = @(& $KitCmd.orch launch -List -Brief -Hours 24 2>$null)   # resume -All's window
  if ($stopped.Count) { $msgs += "paused/crashed runs: $($stopped.Count) ($($stopped -join '; '))$(if ($crashed.Count) { "; $($crashed.Count) board agent(s) marked crashed" }). Do: & '$($KitCmd.orch)' resume -All (bossy E3); finished ones: bossy.ps1 launch -Done -RunId <id>." }
}
if ($py) { $msgs += @(Invoke-KitBackground 'health checks' $KitCmd.orch @('health', '-Checks')) }
$od = @(Get-KitBeatOverdue); $msgs += $od   # after a compaction too
if (-not $od.Count -and ($stopped.Count -or @(Read-KitJsonFiles (Get-KitPath board) | Where-Object status -NotIn 'left', 'crashed').Count)) { $msgs += "heartbeat: $(Get-KitBeatArmLine)" }
$msgs += @(Invoke-KitHooks Get-KitOsBeatHealth)   # adapters/os-timer.ps1
if ($rs = Get-KitRepoSweep) { $msgs += "repos ($(([datetime]$rs.at).ToString('MM-dd HH:mm')) sweep): $(@($rs.repos | ForEach-Object { "$($_.repo) $($_.branches) branches · $($_.worktrees) worktrees$(if ($_.removable) { " · $($_.removable) to clean" })$(if ($_.kept) { " · $($_.kept) kept" })" }) -join '; ') (kept = unpushed, open or dirty: bossy.ps1 cleanup -DryRun -Detail)" }
if ($due = Get-KitRetroDue) { $msgs += "Kit learning: $due. Run /tidy to turn them into lessons and rule updates." }
$msgs += @(Invoke-KitHooks Get-KitHealthLines)   # adapters/kit-admin.ps1: weekly audit nudge
Format-KitSessionStart $(if ($msgs) { ($msgs -join ' | ') + ' (bossy Events)' }) $hook
exit 0
}


# ---- setup: install / repair (idempotent)
# vendor CLI + OS-only allows: generated into settings.local.json from the configured adapters (settings.json stays generic)
function Get-KitAllowCatalogue {
  # host:<type>: a host CLI's allow, else <noun> * + auth status*
  $cat = [ordered]@{}; $own = @($script:KitHostCli.Values)
  foreach ($hx in @(Get-KitHostCli)) { $cat["host:$(if ($hx -in $own) { @($script:KitHostCli.Keys)[$own.IndexOf($hx)] } elseif ($hx.type) { $hx.type } else { $script:HostType })"] = @(@(if ($hx.allow) { $hx.allow } else { "$($hx.noun) *"; 'auth status*' }) | ForEach-Object { "PowerShell($($hx.exe) $_)" }) }
  $cat['report:gdocs'] = @('PowerShell(gws drive files export *)')
  $cat['os:windows'] = @('PowerShell(& *.claude\skills\*)', "PowerShell(& '*.claude\skills\*)", 'PowerShell(python *.claude\skills\*)'); $cat
}
function Set-KitAllowList {
  $gd = "$(git -C $KitConf.Kit rev-parse --path-format=absolute --git-dir 2>$null)".Trim(); $cd = "$(git -C $KitConf.Kit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($gd -and $cd -and $gd -ne $cd) { return 'allow: a linked kit worktree - generated only in the main clone' }
  $cat = Get-KitAllowCatalogue
  $kitHost = if ("$(git -C $KitConf.Kit remote get-url origin 2>$null)" -match '^(?:\w+://)?(?:[^@/]+@)?([^/:]+)') { Get-HostKind $Matches[1] }   # the kit's own releases (kitbag.py release)
  $on = @(@("host:$($script:HostType)", "host:$kitHost", "report:$($KitConf.ReportType)") + @(if ($KitIsWindows) { 'os:windows' }) | Select-Object -Unique)
  $want = @($on | Where-Object { $cat.Contains($_) } | ForEach-Object { $cat[$_] }); $all = @($cat.Values | ForEach-Object { $_ })
  $sl = Join-Path $KitConf.Kit 'settings.local.json'
  $s = if (Test-Path -LiteralPath $sl) { try { Get-Content -LiteralPath $sl -Raw | ConvertFrom-Json -AsHashtable } catch { $null } } else { @{} }
  if ($null -eq $s) { return 'allow: settings.local.json is not valid JSON: allow-list not written (fix the file, then re-run setup -Allow)' }
  if (-not $s['permissions']) { $s['permissions'] = [ordered]@{} }
  $old = @($s['permissions']['allow'] | Where-Object { $_ })
  $new = @(@($old | Where-Object { $_ -notin $all -or $_ -in $want }) + @($want | Where-Object { $_ -notin $old }))   # own entries kept; stale generated ones dropped
  if (($old -join "`n") -eq ($new -join "`n")) { return $null }
  $s['permissions']['allow'] = $new; [IO.File]::WriteAllText($sl, ($s | ConvertTo-Json -Depth 20))
  "allow: $($want.Count) generated entr$(if ($want.Count -eq 1) { 'y' } else { 'ies' }) in settings.local.json ($(@($on | Where-Object { $cat.Contains($_) }) -join ', '))"
}
function Invoke-Setup {
param([switch]$Exclude, [switch]$Quiet, [switch]$WriteLocal, [switch]$Allow, [switch]$BrowserPolicy, [switch]$Undo, [switch]$Clean)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
function Say($s) { if (-not $Quiet) { $s } }

function Set-Memory {
  try { $cfg = Read-KitText $KitConf.ConfigFile | ConvertFrom-Json } catch { $cfg = $null }
  # settings.json turns auto memory off; memory.keepDefault opts back in
  $keep = [bool]($cfg -and $cfg.memory -and $cfg.memory.keepDefault)
  $gd = "$(git -C $kit rev-parse --path-format=absolute --git-dir 2>$null)".Trim(); $cd = "$(git -C $kit rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($gd -and $cd -and $gd -ne $cd) { return $null }
  $sl = Join-Path $kit 'settings.local.json'
  $s = if (Test-Path $sl) { try { Get-Content $sl -Raw | ConvertFrom-Json -AsHashtable } catch { $null } } else { @{} }
  if ($null -eq $s) { return 'settings.local.json is not valid JSON: autoMemoryEnabled unchecked' }
  if ($keep -eq ($s['autoMemoryEnabled'] -eq $true)) { return $null }
  if ($keep) { $s['autoMemoryEnabled'] = $true } else { $s.Remove('autoMemoryEnabled') }
  [IO.File]::WriteAllText($sl, ($s | ConvertTo-Json -Depth 20))
  "memory: auto memory $(if ($keep) { 'on (memory.keepDefault)' } else { 'off (settings.json)' }) in settings.local.json; from the next session"
}

function Update-Exclude {
  if (-not (Test-Path (Join-Path $kit '.git'))) { return 'not a git clone: no .git/info/exclude' }
  $ex = "$(git -C $kit rev-parse --path-format=absolute --git-path info/exclude 2>$null)".Trim()
  if (-not $ex) { return 'git rev-parse --git-path info/exclude failed: excludes not written' }
  New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
  $paths = @()
  $kl = $KitConf.ConfigFile
  if (Test-Path $kl) { try { $paths = @((Get-Content $kl -Raw | ConvertFrom-Json).localOnly | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').Trim('/') }) } catch { return "kit.local.json is not valid JSON: $_" } }
  $begin = '# >>> kit localOnly (managed by skills/bossy/bossy.ps1 setup; edit kit.local.json "localOnly" instead)'
  $end = '# <<< kit localOnly'
  $old = if (Test-Path $ex) { Get-Content $ex -Raw } else { '' }
  $rest = [regex]::Replace($old, '(?s)\r?\n?# >>> kit localOnly[^\n]*.*?' + [regex]::Escape($end) + '\r?\n?', "`n").TrimEnd()
  # a line outside the block that hides a tracked file blocks pushes (pre-push LOCAL FILE): never ours to keep
  $dropped = @(); $rest = (@($rest -split '\r?\n' | Where-Object { $ln = $_.Trim(); if ($ln -and -not $ln.StartsWith('#') -and @(git -C $kit ls-files -c -i "--exclude=$ln" 2>$null).Count) { $dropped += $ln; $false } else { $true } }) -join "`n").TrimEnd()
  $block = if ($paths.Count) { "$begin`n" + (($paths | ForEach-Object { "/$_" }) -join "`n") + "`n$end" } else { '' }
  $new = (@($rest, $block) | Where-Object { $_ }) -join "`n`n"
  $new = if ($new) { $new + "`n" } else { '' }
  if ($new -ne $old) { [IO.File]::WriteAllText($ex, $new); "excluded $($paths.Count) localOnly path(s) in $ex" }
  if ($dropped) { "dropped .git/info/exclude line(s) hiding tracked files: $($dropped -join ', ')" }
}

if ($Allow) { $a = Set-KitAllowList; if ($a) { Say $a }; exit 0 }
if (-not $Exclude) { Invoke-KitHooks Get-KitSetupLines @{ Undo = $Undo; Clean = $Clean } | ForEach-Object { Say $_ }; if ($BrowserPolicy) { exit 0 } }
if ($Exclude) { $r = Update-Exclude; if ($r) { Say $r }; $m = Set-Memory; if ($m) { Say $m }; exit 0 }

if (-not (Test-Path (Join-Path $kit '.git'))) { Write-Warning "$kit is not a git clone: install per README ""Install""" }
else {
  if ((git -C $kit config core.hooksPath) -ne '.githooks') { git -C $kit config core.hooksPath .githooks; Say 'git: core.hooksPath = .githooks (pre-commit, pre-push, post-merge, post-rewrite on)' }
  Set-KitOriginProtection | Where-Object { $_ -notmatch ' ok$' } | ForEach-Object { Say $_ }
  $r = Update-Exclude; if ($r) { Say $r }
}
$m = Set-Memory; if ($m) { Say $m }
$al = Set-KitAllowList; if ($al) { Say $al }
foreach ($n in 'work', 'cache', 'logs') { $null = Get-KitPath $n -Create }
Say "runtime: $(Get-KitPath runtime) (work/ cache/ logs/; disposable)"
$ex = Get-Content (Join-Path $kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json
$want = [ordered]@{ 'skills/crafty/kit.local.json' = ($ex | Select-Object -Property * -ExcludeProperty localFiles, _paths, _manifest, _doc) }
Remove-KitLearnedKeys $want['skills/crafty/kit.local.json']
foreach ($p in (Get-KitProps $ex.localFiles)) { $want[$p.Name] = $p.Value }
foreach ($k in $want.Keys) {
  $f = Join-Path $kit $k; if (Test-Path $f) { continue }
  if ($WriteLocal) { $want[$k] | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding utf8; Say "wrote $k from kit.example.json: fill in the <...> values (git-ignored)" }
  else { Say "to do: $k is missing (setup -WriteLocal writes it from kit.example.json, then fill it in)" }
}
if (Test-Path "$kit/../.codex") { Say 'codex: approve the kit hooks once (/hooks)' }
Say 'kit ready.'
}

# ---- guard-sendmessage: a send RESUMES a second copy on the same worktree
function Invoke-GuardSendMessage {
$ErrorActionPreference = 'SilentlyContinue'
$in = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() | ConvertFrom-Json }  # by hand: no stdin wait
$to = "$($in.tool_input.to)".Trim()
if ($to -notmatch '^(?<id>a[0-9a-f]{12,})$') { exit 0 }
$id = $Matches.id
$meta = Invoke-KitAdapter transcript claude agent-meta @{ id = $id }   # SendMessage: a Claude Code tool
if (-not $meta) { exit 0 }
$label = (Get-Content $meta.FullName -Raw | ConvertFrom-Json).description
$why = "Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you."
[Console]::Error.WriteLine($why)
@{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
exit 0
}

# SessionStart hooks: one warning line, detail in the hook log
function Write-KitHookError([string]$Verb, $Err) { "kit: $Verb failed ($($Err.Exception.Message)); see bossy.ps1 audit -Since 1h"; exit 0 }
if ($MyInvocation.InvocationName -ne '.') {  # dot-sourced (tests): functions only
  trap { if ($__verb -in 'health', 'cleanup') { Write-KitHookError $__verb $_ } else { break } }
  $KitVerbOnError = { param($e) if ($__verb -in 'health', 'cleanup') { Write-KitHookError $__verb $e } }   # Invoke-KitVerb catches first
  if ($__verb -in '-h', '--help', 'help', '-?') { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
  switch ($__verb) {
    'board' {
      if ($__rest[0] -in 'dispute', 'disputes') { [Console]::Error.WriteLine('bossy.ps1 board dispute: no such verb; disputes run inside /buildy (devy fix round disputes[], revy answers once)'); exit 2 }
      else { Invoke-KitVerb Invoke-Board $__rest }
    }
    'learn' { Invoke-KitVerb Invoke-Learn $__rest }
    'launch' { Invoke-KitVerb Invoke-Launch $__rest }
    'track' { Invoke-KitVerb Invoke-Track $__rest }
    'supervise' { Invoke-KitVerb Invoke-Supervise $__rest | ConvertTo-KitLaneOut ('-Json' -in $__rest) }   # shown lane names (K55)
    'status' { Invoke-KitVerb Invoke-Status $__rest | ConvertTo-KitLaneOut ('-Json' -in $__rest) }
    'release' { Invoke-KitVerb Invoke-Release $__rest }
    'shells' { Invoke-KitVerb Invoke-Shells $__rest }
    'stats' { Invoke-KitVerb Invoke-Stats $__rest }
    'storage' { Invoke-KitVerb Invoke-Storage $__rest }
    'report' { Invoke-KitVerb Invoke-Report $__rest }
    'audit' { Invoke-KitVerb Invoke-Audit $__rest }
    'bugbrief' { Invoke-KitVerb Invoke-BugBrief $__rest }
    'cleanup' { Invoke-KitVerb Invoke-Cleanup $__rest }
    'tidy' { Invoke-KitVerb Invoke-Tidy $__rest }
    'deploy' { Invoke-KitVerb Invoke-Deploy $__rest }
    'decide' { Invoke-KitVerb Invoke-Decide $__rest }
    'debate' { Invoke-KitVerb Invoke-Debate $__rest }
    'recover' { Invoke-KitVerb Invoke-Recover $__rest }
    'pause' { Invoke-KitVerb Invoke-Pause $__rest }
    'resume' { Invoke-KitVerb Invoke-Resume $__rest }
    'program' { Invoke-KitVerb Invoke-Program $__rest }
    'param' { Invoke-KitVerb Invoke-Param $__rest }
    'budget' { Invoke-KitVerb Invoke-Budget $__rest }
    'usage' { Invoke-KitVerb Invoke-KitContextUsage $__rest }
    'heartbeat' { $fn = if ("$__rest" -match '^(install|uninstall|status|tick)\b') { 'Invoke-KitOsBeat' } else { 'Invoke-Heartbeat' }; Invoke-KitVerb $fn $__rest }
    'health' { Invoke-KitVerb Invoke-Health $__rest }
    'setup' { Invoke-KitVerb Invoke-Setup $__rest }
    'guard-sendmessage' { Invoke-KitVerb Invoke-GuardSendMessage $__rest }
    'prepush' { Invoke-KitVerb Invoke-PrePush $__rest }
    'precommit' { Invoke-KitVerb Invoke-PreCommit $__rest }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }
  }
}
