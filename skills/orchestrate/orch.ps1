<#
orch.ps1: the coordinator + kit commands in one file (orchestrate SKILL.md). Run from pwsh 7:
  & <kit>/skills/orchestrate/orch.ps1 <verb> [args]
  board join|beat|check|leave|show|msg|inbox|dispute|disputes ...  agent board (every agent's step 0), messages, disputes
  learn -Skill -Kind -Text | -Read -Skill | -Lesson | -Bump | -Fixed | -Trim | -Show | -Stats | -History  signals + LESSONS.md
  launch -RunId -Script -ArgsJson | -Self -Script -Run -ArgsFile -Fnv | -Done -RunId | -List [-Brief]  launch records (resume)
  recover [-RunId <id>] [-Hours 48]  stopped runs: state, resume brief, exact resume call; agents' handoff briefs
  budget [-Tool -Model -Window] [-Plan 'role/model:n,..'] [-Run <run>] [-Json]  agent budget, run cap + spend
  track add|remove|show|run|rebuild ...  task <-> MRs; promoted when all merged; merge order
  supervise [-Session <id>] [-AutoFix] [-Brief] [-Deep] [-Json] [-MarkStopped <run>] [-Takeover] | -App <name> -Answer keep|close  heartbeat
  report -Run <id> [-Detail]  a run from its journal (MR states, findings, verdicts)
  bugbrief -Task <id> -Agent <code> -Repos <r>,..  bug-fix brief (reproduce locally first) + /buildy args
  cleanup [-DryRun] [-Quiet] [-IfDue] [-WorktreesOnly] [-WorktreeIdleHours <h>]
  deploy plan|request|record|merge|intest ...  deploy batch (deploy.trigger), deploy-branch merge, inTest after deploy
  decide ask|list|answer|get|wait ...  decision pauses (needs decision -> owner answers -> item resumes)
  health [-Flow] [-Fetch]  SessionStart hook: git, gates, stopped runs, lint, ports, nudges (1 JSON line)
  nudge  retro / audit part of health
  setup [-Exclude] [-Quiet] [-Migrate] [-WriteLocal]  install / repair (idempotent); -Migrate moves an old layout
  guard-sendmessage  PreToolUse hook for SendMessage (exit 2 = block)
  prepush · precommit  git hooks' logic (.githooks/pre-push, pre-commit)
Inputs: kit.local.json (lib.ps1), runtime state (board, launches, decisions, deploys, waves), .state/tracking.json, kit clone.
Output: text (-Json where offered). Exit codes: 0 ok · 1 problem / not answered / blocked · 2 usage.
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---- board: who is alive; one writer per worktree
function Invoke-Board {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('join', 'beat', 'show', 'check', 'leave', 'msg', 'inbox', 'dispute', 'disputes')][string]$Action,
  [string]$Agent, [string]$Area = '', [string]$Items = '', [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree, [switch]$Resume, [string]$Type = '',
  [string]$To, [string]$Text, [switch]$All, [string]$With, [string]$Item, [string]$Claim, [string]$Evidence, [string]$Propose, [string]$Id,
  [ValidateSet('', 'agree', 'disagree')][string]$Answer = '', [switch]$Open, [switch]$Json, [string]$Model = '', [string]$Handoff = ''
)
$dir = Get-KitPath board -Create
$staleMin = 20
function All { foreach ($f in Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue) { try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; $e | Add-Member -Force NoteProperty file $f.FullName; $e } catch {} } }
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
# $Change returns $null = unchanged
function Update-BoardEntry([string]$Path, [scriptblock]$Change) {
  Invoke-KitLocked $Path { if (Test-Path $Path) { $e0 = Get-Content $Path -Raw | ConvertFrom-Json; $n0 = & $Change $e0; if ($null -ne $n0) { $n0 | ConvertTo-Json | Set-Content $Path } } }
}
function Print($act) {
  if (-not $act) { 'board: no other active agents'; return }
  'board (active agents):'
  $act | Sort-Object run, agent | ForEach-Object { $task = "$(if ($_.items) { $_.items } else { $_.area })"; $cl = (@($_.worktrees | ForEach-Object { Split-Path "$_" -Leaf }) -join ',')
    '  {0,-6} {1,-6} {2,-14} {3,-8} {4,-30} {5,-22} {6} | beat {7}{8}' -f $_.agent, "$($_.type)", $_.run, "$(if ($_.holderPid) { "s$($_.holderPid)" })", $task.Substring(0, [math]::Min(30, $task.Length)), $cl.Substring(0, [math]::Min(22, $cl.Length)), $_.status, ([datetime]$_.beat).ToString('HH:mm'), $(if ($_.budget) { " | spend $([int]($_.spend / 1000))k/$([int]($_.budget / 1000))k" }) }
}
$inboxDir = Join-Path $dir 'inbox'
function Send-BoardMsg([string]$from, [string]$to, [string]$text) {
  New-Item -ItemType Directory -Force $inboxDir | Out-Null; $f = Join-Path $inboxDir "$($to.ToLower() -replace '[^\w.-]', '_').jsonl"
  $line = [ordered]@{ at = (Get-Date).ToString('o'); from = $from; text = $text; read = $false } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
}
function Get-Unread([string]$who) { $f = Join-Path $inboxDir "$($who.ToLower() -replace '[^\w.-]', '_').jsonl"; if (Test-Path $f) { @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { -not $_.read }).Count } else { 0 } }

switch ($Action) {
  'join' {
    if (-not $Agent) { throw 'join needs -Agent' }
    $now = Get-Date
    $myClaims = @($Worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $same = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.status -ne 'left' })
    $notes = @()
    $rejoin = $same | Where-Object { -not $Resume -and ($now - [datetime]$_.beat).TotalMinutes -lt 2 -and ((@($_.worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique) -join '|') -eq ($myClaims -join '|')) } |
      Sort-Object { [datetime]$_.joined } -Descending | Select-Object -First 1
    if ($rejoin) { $tok = $rejoin.session; $joined = $rejoin.joined; $notes += "REJOIN: same agent, run and claims within 2 min - reusing session $tok" }
    else { $tok = "$Agent-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $joined = $now.ToString('o') }
    # the dead pid is the join shell's: not alone
    foreach ($o in @($same | Where-Object { $_.session -ne $tok })) {
      $alive = $o.pid -and [bool](Get-Process -Id ([int]$o.pid) -ErrorAction SilentlyContinue)
      $age = ($now - [datetime]$o.beat).TotalMinutes
      $shared = @(@($o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -and $_ -in $myClaims })
      $why = if ((Test-KitHolder $o) -eq $false) { "its session process $($o.holderPid) is gone (crash or restart)" } elseif (-not $alive -and $age -ge 3) { "no heartbeat for $([int]$age) min" } elseif ($Resume -and $shared.Count) { "-Resume on $($shared -join ', ')" } else { $null }
      if (-not $why) { continue }
      try {
        Update-BoardEntry $o.file { param($j) $j.status = 'left'; $j | Add-Member -Force NoteProperty takenOverBy $tok; $j | Add-Member -Force NoteProperty takenOverAt $now.ToString('o'); $j }
        $notes += "TAKEOVER: replaced session $($o.session) ($why; joined $(([datetime]$o.joined).ToString('HH:mm')), last beat $(([datetime]$o.beat).ToString('HH:mm')))"
      } catch { $notes += "could not take over session $($o.session): $_" }
    }
    $me = [ordered]@{ agent = $Agent; type = $(if ($Type) { $Type } else { "$env:CLAUDE_AGENT_TYPE" }); session = $tok; run = $Run; area = $Area; items = $Items; worktrees = @($Worktrees); contracts = $Contracts
                      status = 'working'; joined = $joined; beat = $now.ToString('o'); pid = $PID } + (Get-KitHolder)
    $bg = Get-KitBudget -Model $Model; $me += [ordered]@{ tool = $bg.tool; model = $bg.model; budget = $bg.budget; handoff = $bg.handoff; spend = 0 }
    $mf = Join-Path $dir "$tok.json"; Invoke-KitLocked $mf { $me | ConvertTo-Json | Set-Content $mf }
    $ho = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.handoffBrief -and -not $_.continuedBy } | Sort-Object { [datetime]$_.beat } -Descending)[0]
    if ($ho) { Update-BoardEntry $ho.file { param($x) $x | Add-Member -Force NoteProperty continuedBy $tok; $x }; "CONTINUE: the previous $Agent handed off at its budget: read its resume brief $($ho.handoffBrief) first, then go on from there" }
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
      if ($bg.handoff -and $sp.spend -ge $bg.handoff) { $hb = Join-Path (Get-KitPath briefs -Create) "handoff-$($me.agent -replace '[^\w.-]', '_')-$Session.md"; "HANDOFF: spend $($sp.spend) >= $($bg.handoff): write a resume brief (templates.md ""Resume brief"") to $hb, commit WIP, board leave -Session $Session -Handoff $hb, return handoff = $hb and stop: a fresh agent continues" }
    }
    $u = Get-Unread $me.agent; if ($u) { "INBOX: $u message(s) wait: orch.ps1 board inbox -Agent $($me.agent)" }
    $w = @(Warnings $me @(Active)); if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" }; exit 1 }
  }
  'show' { $act = @(Active | Where-Object { -not $Run -or $_.run -eq $Run }); Print $act; @($act | ForEach-Object { Warnings $_ $act }) | Sort-Object -Unique | ForEach-Object { "  ! $_" }
    foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath qa-seats) 'seats') -Filter *.json -ErrorAction SilentlyContinue)) { $o = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($o) { "  seat: $($o.agent) $($o.kind) $($o.need) GB since $($o.since)$(if ((Test-KitHolder $o) -eq $false) { ' (holder gone)' })" } }
    foreach ($f in @(Get-ChildItem (Get-KitPath localenv) -Filter *.json -ErrorAction SilentlyContinue)) { $o = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { $null }; foreach ($l in @($o.leases.PSObject.Properties)) { "  lease: $($f.BaseName) $($l.Name) on $(@($l.Value.services) + @($l.Value.repos) -join ', ') until $($l.Value.until)" } } }
  'check' {
    if (-not $Worktree) { 'usage: board check -Worktree <dir> -Session <token>'; exit 2 }
    $mine = Norm $Worktree
    $others = @(Active | Where-Object { $_.session -ne $Session -and (@($_.worktrees | ForEach-Object { Norm $_ }) -contains $mine) })
    if ($others) { $others | ForEach-Object { "OTHER WRITER: $($_.agent) (session $($_.session), status $($_.status), beat $(([datetime]$_.beat).ToString('HH:mm')))" }; exit 1 }
    'ok: no other active agent claims this worktree'; exit 0
  }
  'leave' {
    $f = Join-Path $dir "$Session.json"
    Update-BoardEntry $f { param($x) $x.status = 'left'; $x.beat = (Get-Date).ToString('o'); if ($Handoff) { $x | Add-Member -Force NoteProperty handoffBrief $Handoff }; $x }
    "left ($Session)$(if ($Handoff) { ": handoff brief $Handoff (a fresh agent continues: board join prints CONTINUE)" })"
  }
  'msg' {
    if (-not ($Agent -and $To -and $Text)) { 'usage: board msg -Agent <me> -To <agent id> -Text "<message>"'; exit 2 }
    Send-BoardMsg $Agent $To $Text
    $held = @(Active | Where-Object { $_.agent -eq $To }); "sent to $To$(if (-not $held) { ' (not on the board now: it reads it when it joins)' })"
  }
  'inbox' {
    if (-not $Agent) { 'usage: board inbox -Agent <me> [-All]'; exit 2 }
    $f = Join-Path $inboxDir "$($Agent.ToLower() -replace '[^\w.-]', '_').jsonl"; if (-not (Test-Path $f)) { 'inbox: empty'; return }
    Invoke-KitLocked $f {
      $m = @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json })
      $show = @($m | Where-Object { $All -or -not $_.read }); foreach ($x in $show) { "$(([datetime]$x.at).ToString('HH:mm')) from $($x.from): $($x.text)" }
      if (-not $show.Count) { 'inbox: nothing unread' }
      Set-Content -LiteralPath $f (@($m | ForEach-Object { $_.read = $true; $_ | ConvertTo-Json -Compress })) -Encoding utf8
    }
  }
  'dispute' {
    $dd = Get-KitPath disputes -Create
    if (-not $Id) {
      if (-not ($Agent -and $With -and $Claim -and $Evidence)) { 'usage: board dispute -Agent <me> -With <id> -Item <item> -Claim ".." -Evidence ".." -Propose ".." [-Run <run>] [-Contracts <file>]'; exit 2 }
      $did = "p-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
      $o = [ordered]@{ id = $did; run = $Run; item = $Item; from = $Agent; with = $With; propose = $Propose; contracts = $Contracts; status = 'open'; at = (Get-Date).ToString('s')
        rounds = @([ordered]@{ claim = $Claim; evidence = $Evidence; by = $Agent; answer = ''; answerEvidence = '' }) }
      $df = Join-Path $dd "$did.json"; Invoke-KitLocked $df { $o | ConvertTo-Json -Depth 6 | Set-Content $df -Encoding utf8 }
      Send-BoardMsg $Agent $With "DISPUTE $did (item $Item): $Claim | evidence: $Evidence | proposed: $Propose. Answer once: orch.ps1 board dispute -Id $did -Agent $With -Answer agree|disagree -Evidence '<yours>'"
      if ($Contracts -and (Test-Path (Split-Path $Contracts))) { Add-Content -LiteralPath $Contracts "`n## DISPUTE $did ($Agent vs $With, item $Item)`nClaim: $Claim · Evidence: $Evidence · Proposed: $Propose" -Encoding utf8 }
      "DISPUTE $did open: $With answers once (board msg sent); still split after 2 rounds -> the owner judges (decide ask)"; return
    }
    $df = Join-Path $dd "$Id.json"; if (-not (Test-Path $df)) { "no dispute $Id"; exit 1 }
    $script:dispOut = @()
    Invoke-KitLocked $df {
      $o = Get-Content $df -Raw | ConvertFrom-Json
      if ($o.status -ne 'open') { $script:dispOut = @("dispute $Id is $($o.status)$(if ($o.decision) { " ($($o.decision))" })"); return }
      $last = @($o.rounds)[-1]
      if ($Answer) {
        if ($last.answer) { $script:dispOut = @("round $(@($o.rounds).Count) is answered: the opener posts round 2 (-Claim -Evidence) or agrees"); return }
        $last.answer = $Answer; $last.answerEvidence = $Evidence
        if ($Answer -eq 'agree') { $o.status = 'agreed'; $o | Add-Member -Force verdict "agreed by $Agent in round $(@($o.rounds).Count)" }
        elseif (@($o.rounds).Count -ge 2) {
          $o.status = 'escalated'; $o | Add-Member -Force decision (Request-DisputeDecision $o "$($o.from): $($last.claim) [$($last.evidence)]; $($o.with): $($Evidence)")
        }
        Send-BoardMsg $Agent $o.from "DISPUTE ${Id}: $Answer - $Evidence"
      }
      elseif ($Claim) {
        if (-not $last.answer) { $script:dispOut = @('wait for the answer to the current round first'); return }
        if (@($o.rounds).Count -ge 2) { $script:dispOut = @('2 rounds done: the dispute escalates on the second disagree'); return }
        $o.rounds = @(@($o.rounds) + [pscustomobject]@{ claim = $Claim; evidence = $Evidence; by = $Agent; answer = ''; answerEvidence = '' })
        Send-BoardMsg $Agent $o.with "DISPUTE $Id round 2: $Claim | evidence: $Evidence. Answer once: board dispute -Id $Id -Agent $($o.with) -Answer agree|disagree -Evidence '<yours>'"
      }
      else { $script:dispOut = @('usage: board dispute -Id <id> -Agent <me> -Answer agree|disagree -Evidence ".." | -Claim ".." -Evidence ".."'); return }
      $o | ConvertTo-Json -Depth 6 | Set-Content $df -Encoding utf8
      $script:dispOut = @("DISPUTE $Id $($o.status)$(if ($o.decision) { ": DECISION $($o.decision) (the owner judges)" })")
      if ($o.status -ne 'open') { $sig = [ordered]@{ at = (Get-Date).ToString('s'); skill = 'orchestrate'; kind = 'friction'; text = "dispute $Id ($($o.from) vs $($o.with), item $($o.item)) $($o.status): $(@($o.rounds)[0].claim)"; ref = $Id; source = 'board' } | ConvertTo-Json -Compress; $sf = Get-KitPath signals -Create; Invoke-KitLocked $sf { Add-Content -LiteralPath $sf $sig -Encoding utf8 } }
    }
    $script:dispOut | ForEach-Object { $_ }
  }
  'disputes' {
    $dd = Get-KitPath disputes
    $dl = @(Get-ChildItem $dd -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not $Open -or $_.status -eq 'open' })
    if ($Json) { ConvertTo-Json @($dl) -Depth 6; return }
    foreach ($d in $dl) { "$($d.status.ToUpper()) $($d.id) $($d.from) vs $($d.with) item $($d.item): $(@($d.rounds)[0].claim) | rounds $(@($d.rounds).Count)$(if ($d.decision) { " | decision $($d.decision)" })$(if ($d.verdict) { " | $($d.verdict)" })" }
    if (-not $dl.Count) { 'no disputes' }
  }
}
}

# ---- budget: this agent's budget (the tool's default compaction point), a plan's run cap, a run's spend
function Get-KitPlanCap([string]$Plan) {   # 'role/model:n,...' (role without /model: an estimate unit, no budget)
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).budget; $cap = 0; $est = 0; $memo = @{}
  foreach ($p in @("$Plan" -split ',' | Where-Object { $_ -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$' })) {
    $null = $p -match '^\s*([\w-]+)(?:/([^:]*))?:(\d+)\s*$'; $role = $Matches[1]; $m = $Matches[2]; $n = [int]$Matches[3]; $hasM = $p -match '/'
    if ($hasM) { if (-not $memo.ContainsKey($m)) { $memo[$m] = (Get-KitBudget -Model $m).budget }; $cap += $n * $memo[$m] }
    $est += $n * [double](Get-KitSetting "budget.estimate.$role" $ex.estimate.$role)
  }
  [pscustomobject]@{ cap = [int]$cap; estimate = [int]$est; perModel = $memo }
}
function Invoke-Budget {
param([string]$Tool = '', [string]$Model = '', [int]$Window = 0, [string]$Plan = '', [string]$Run = '', [switch]$Json)
if ($Run) {   # a workflow run: the sum of its agents' spend vs the cap its launch -Self recorded
  $sf = @(Get-ChildItem (Get-KitPath launches -Create) -Filter 'self-*.json' | Sort-Object LastWriteTime -Descending | ForEach-Object { $o = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($o.run -eq $Run) { $o | Add-Member -Force NoteProperty file $_.FullName; $o } })[0]
  if (-not $sf) { "no launch record for run $Run"; exit 1 }
  $wf = if ($sf.wfDir -and (Test-Path $sf.wfDir)) { $sf.wfDir } else { $t = Find-KitTranscript "-Run '$Run' " 'agent-*.jsonl'; if ($t) { Split-Path $t } }
  $sp = @(if ($wf) { Get-ChildItem $wf -Filter 'agent-*.jsonl' | ForEach-Object { (Get-KitSpend $_.FullName).spend } })
  $o = [ordered]@{ run = $Run; spent = [int](($sp | Measure-Object -Sum).Sum); agents = $sp.Count; cap = [int]$sf.cap; estimate = [int]$sf.estimate; stopAt = [double]$sf.stopAt }
  Invoke-KitLocked $sf.file { $j = Get-Content $sf.file -Raw | ConvertFrom-Json; $j | Add-Member -Force NoteProperty wfDir $wf; $j | Add-Member -Force NoteProperty spent $o.spent; $j | ConvertTo-Json -Depth 30 | Set-Content $sf.file -Encoding utf8 }
  if ($Json) { $o | ConvertTo-Json -Compress } else { "run $Run`: spent $($o.spent) of the cap $($o.cap) ($($o.agents) agents; stop at $([int]($o.stopAt * 100))%)" }; exit 0
}
$b = Get-KitBudget -Tool $Tool -Model $Model -Window $Window
if ($Plan) { $c = Get-KitPlanCap $Plan; $b | Add-Member -Force NoteProperty cap $c.cap; $b | Add-Member -Force NoteProperty estimate $c.estimate }
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
  if (-not ($Script -and $Run -and $ArgsFile)) { 'usage: launch -Self -Script <wf>.js -Run <run> -ArgsFile <file> -Fnv <hash> [-RunDir <dir>]'; exit 2 }
  $raw = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ArgsFile).Path)).TrimStart([char]0xFEFF).TrimEnd("`r", "`n")
  $got = Get-KitFnv $raw
  if ($Fnv -and $got -ne $Fnv.Trim().ToLower()) { "MISMATCH: the file hashes to $got, not $Fnv ($($raw.Length) chars): write the args again, byte for byte"; exit 1 }
  try { $a = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { "MISMATCH: not valid JSON ($($_.Exception.Message))"; exit 1 }
  $leaf = Split-Path $Script -Leaf
  $rec = [ordered]@{ script = (Join-Path $kit "workflows/$leaf"); run = $Run; args = $a; argsRaw = $raw; runDir = $(if ($RunDir) { $RunDir } else { $a.runDir }); fnv = $got; at = (Get-Date).ToString('o') } + (Get-KitHolder)
  $bud = if ($Plan) { $c = Get-KitPlanCap $Plan; $b0 = Get-KitBudget; [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; handoffAt = $b0.handoffAt; plan = $Plan }; $rec += [ordered]@{ cap = $c.cap; estimate = $c.estimate; stopAt = $b0.runStopAt; plan = $Plan } }
  $rec | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Get-SelfLaunchFile $leaf $Run $got) -Encoding utf8
  "RECORDED $leaf $Run (fnv $got)"; if ($bud) { "BUDGET $($bud | ConvertTo-Json -Compress)" }; exit 0
}

if ($Done) {
  if (-not $RunId) { throw '-Done needs -RunId' }
  $f = Join-Path $dir "$(& $safe $RunId).json"
  if (-not (Test-Path -LiteralPath $f)) { Write-Host "[launch] no record for $RunId (nothing to mark)"; exit 0 }
  $r = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
  $r.completed = (Get-Date).ToString('o')
  $r | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $f -Encoding utf8
  Write-Host "[launch] $RunId marked completed"
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
  $rec | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $f -Encoding utf8
  Write-Host "[launch] recorded $RunId ($(Split-Path $Script -Leaf)) -> $f"
  exit 0
}

$out = @(foreach ($s in Get-StoppedRuns -Hours $Hours) {
  $src = if ($s.selfFile) { "$($s.selfFile) (written by the workflow: exact)" } else { "$($s.file) (typed by the coordinator: may be short)" }
  if (-not $s.runId) { if ($Brief) { "$($s.leaf) run $($s.run): launched, run id never recorded (orch.ps1 recover finds it)" } else { "STOPPED? $($s.leaf) run $($s.run): no launch record with a run id; orch.ps1 recover finds it in the session journals; args $src" }; continue }
  if ($Brief) { "$($s.leaf) $($s.runId) (resumeFromRunId $($s.runId), args $(if ($s.selfFile) { $s.selfFile } else { $s.file }))" }
  else { "STOPPED? $($s.leaf) run $($s.runId) launched $($s.at.ToString('yyyy-MM-dd HH:mm'))$(if ($s.runDir) { ", runDir $($s.runDir)" })`n  resume: Workflow({ scriptPath: '$($s.script)', resumeFromRunId: '$($s.runId)', args: $(Get-LaunchArgsJson (Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json)) }) (args from $src)`n  details + resume brief: orch.ps1 recover -RunId $($s.runId) · finished already: orch.ps1 launch -Done -RunId $($s.runId)" }
})
foreach ($q in Get-OrphanQaItems -Hours ([math]::Max($Hours, 48))) {
  $out += if ($Brief) { "QA run $($q.run): $($q.codes.Count) item(s) tested, never published ($($q.codes -join ', ')): qa.ps1 finalize" }
          else { "UNPUBLISHED QA $($q.dir): $($q.codes -join ', ') have results.json but no finalize.json / held.json and no live workflow: per item & $($KitCmd.qa) finalize -RunDir '$($q.dir)' -Code <code> (idempotent)$(if ($q.fails) { "; unverified FAIL in $($q.fails -join ', '): verify first (checky) or relaunch testy only: [...]" })" }
}
$out | ForEach-Object { $_ }
exit 0
}

function Get-LaunchArgsJson($r) { if ($r.argsRaw) { return [string]$r.argsRaw }; if ($r.argsFile -and (Test-Path -LiteralPath $r.argsFile)) { return (Get-Content -LiteralPath $r.argsFile -Raw).Trim() }; $r.args | ConvertTo-Json -Depth 30 -Compress }
function Request-DisputeDecision($o, [string]$detail) {
  $ask = & $PSCommandPath decide ask -Run "$($o.run)" -Agent $o.from -Item "$($o.item)" -Question "Dispute $($o.id) ($($o.from) vs $($o.with), item $($o.item)): who is right? $detail" -Options "A: $($o.from): $($o.propose)", "B: $($o.with): keep its result" -Contracts "$($o.contracts)" 2>&1 | Out-String
  if ($ask -match '\b(d-\d{14}-[\w-]+)') { $Matches[1] } else { 'not raised' }
}
# silent 2 h: escalate to the owner
function Invoke-DisputeExpiry([double]$Hours = 2) {
  foreach ($f in @(Get-ChildItem (Get-KitPath disputes) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalHours -ge $Hours })) {
    $r = @{}   # re-read + raise under the lock: a reply in between wins, never a second decision
    Invoke-KitLocked $f.FullName { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json; if ($o.status -ne 'open') { return }
      $last = @($o.rounds)[-1]
      $o.status = 'escalated'; $o | Add-Member -Force decision (Request-DisputeDecision $o "no reply for $Hours h; $($o.from): $($last.claim) [$($last.evidence)]")
      $o | ConvertTo-Json -Depth 6 | Set-Content $f.FullName -Encoding utf8; $r.o = $o }
    if ($r.o) { "dispute $($r.o.id) ($($r.o.from) vs $($r.o.with)) silent $Hours h: escalated, DECISION $($r.o.decision)" }
  }
}
function Get-SelfLaunchFile([string]$Leaf, [string]$Run, [string]$Fnv = '') { Join-Path (Get-KitPath launches -Create) ("self-{0}-{1}{2}.json" -f (($Leaf -replace '\.js$', '') -replace '[^\w.-]', '_'), ($Run -replace '[^\w.-]', '_'), $(if ($Fnv) { "-$Fnv" } else { '' })) }
function Get-LaunchRunName($a) {
  if (-not $a) { return '' }
  if ($a.run) { return [string]$a.run }
  if ($a.brief) { return "$([IO.Path]::GetFileName([string]$a.brief) -replace '\.md$', '')-$((Get-KitFnv ([string]$a.brief)).Substring(0, 4))" }
  if ($a.runDir) { return (Split-Path ([string]$a.runDir) -Leaf) }
  if ($a.select) { return "select-$(if ($a.name) { $a.name } elseif ($a.target) { $a.target } else { 'run' })" }
  ''
}
# self records alone have no runId
function Get-StoppedRuns([int]$Hours = 24, [switch]$All) {
  $dir = Get-KitPath launches -Create; $since = (Get-Date).AddHours(-$Hours)
  $selfs = @(Get-ChildItem -LiteralPath $dir -Filter 'self-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $o = try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($o) { $o | Add-Member -Force NoteProperty file $_.FullName; $o } })
  $used = @{}
  foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'self-*' } | Sort-Object LastWriteTime) {
    $r = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($r.completed -or -not $r.script) { continue }   # args dumps and broken records are no launches
    $at = try { [datetime]$r.at } catch { $f.LastWriteTime }
    if ($at -lt $since) { continue }
    if (-not $All -and (Test-KitHolder $r) -eq $true) { continue }
    $leaf = Split-Path ([string]$r.script) -Leaf; $run = Get-LaunchRunName $r.args
    $sf = @($selfs | Where-Object { $run -and (Split-Path ([string]$_.script) -Leaf) -eq $leaf -and $_.run -eq $run } | Sort-Object { [math]::Abs(([datetime]$_.at - $at).TotalMinutes) }) | Select-Object -First 1 -ExpandProperty file
    if (-not $sf) { $sf = @($selfs | Where-Object { (Split-Path ([string]$_.script) -Leaf) -eq $leaf -and [math]::Abs(([datetime]$_.at - $at).TotalMinutes) -le 30 }) | Select-Object -First 1 -ExpandProperty file }
    if ($sf) { $used[$sf] = $true; $so = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json; if ($so.completed) { continue }; $run = $so.run }   # an owner-stopped self record ends the launch too
    [pscustomobject]@{ runId = $r.runId; leaf = $leaf; script = $r.script; run = $run; at = $at; file = $f.FullName; selfFile = $sf; runDir = $r.runDir; record = $r }
  }
  foreach ($s in $selfs | Where-Object { -not $used[$_.file] -and -not $_.completed -and [datetime]$_.at -ge $since }) {
    if (-not $All -and (Test-KitHolder $s) -eq $true) { continue }
    # only a completed record of THIS launch hides it
    $known = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Where-Object { $_.Name -notlike 'self-*' } | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.completed -and (Get-LaunchRunName $_.args) -eq $s.run -and [math]::Abs(([datetime]$_.at - [datetime]$s.at).TotalMinutes) -le 30 }).Count
    if ($known) { continue }
    [pscustomobject]@{ runId = $null; leaf = (Split-Path ([string]$s.script) -Leaf); script = $s.script; run = $s.run; at = [datetime]$s.at; file = $null; selfFile = $s.file; runDir = $(if ($s.runDir) { $s.runDir } else { $s.args.runDir }); record = $null }
  }
}
# ---- recover: stopped runs; no network
function Invoke-Recover {
param([string]$RunId, [int]$Hours = 48)
$runs = @(Get-StoppedRuns -Hours $Hours -All:([bool]$RunId) | Where-Object { -not $RunId -or $_.runId -eq $RunId })
if ($RunId -and -not $runs.Count) { "no launch record for $RunId within $Hours h (orch.ps1 launch -List)"; exit 0 }
$wfDirs = @(Get-ChildItem $KitConf.ClaudeProjectDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents/workflows') -Directory -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) })
foreach ($s in $runs) {
  if (-not $s.runId) {
    $hit = $wfDirs | Where-Object { @(Get-ChildItem $_.FullName -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue | Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch "launch -Self -Script $($s.leaf) -Run '$($s.run)' " -Quiet }).Count } | Select-Object -First 1
    if ($hit) { $s.runId = $hit.Name }
  }
  $lr = Get-Content -LiteralPath $(if ($s.selfFile) { $s.selfFile } else { $s.file }) -Raw | ConvertFrom-Json; $a = $lr.args
  $aj = Get-LaunchArgsJson $lr; if (-not $a.runDir -and $lr.runDir) { $a | Add-Member -Force NoteProperty runDir $lr.runDir }
  "== $($s.leaf) run $(if ($s.runId) { $s.runId } else { '<id unknown>' }) ($($s.run)), launched $($s.at.ToString('yyyy-MM-dd HH:mm'))"
  "  args: $(if ($s.selfFile) { "$($s.selfFile) (.args, written by the workflow: exact)" } else { "$($s.file) (.args, typed by the coordinator: a missing field breaks resumeFromRunId)" })"
  $board = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.run -eq $s.run })
  foreach ($b in $board | Where-Object status -ne 'left' | Sort-Object agent) { "  board: $($b.agent) $($b.status), last beat $(([datetime]$b.beat).ToString('dd MMM HH:mm'))$(if ((Test-KitHolder $b) -eq $false) { ', session gone' }) | $($b.area)" }
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
  }
  $wts
  if ($s.runId) {
    $wv = Join-Path (Get-KitPath waves) "$($s.runId).json"
    if (Test-Path $wv) { foreach ($x in @((Get-Content $wv -Raw | ConvertFrom-Json).agents)) { foreach ($m in @($x.report.mrs)) { "  MR: $($x.id) $($m.url) $(if ($m.mergeState) { $m.mergeState } elseif ($m.merged) { 'MERGED' } else { 'OPEN' })"; $brief += "- $($x.id) MR $($m.url) $($m.mergeState)" } } }
  }
  foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ -and $_.run -eq $s.run })) { "  decision pending: $($d.id) $($d.agent) item $($d.item): $($d.question)" }
  if ($s.leaf -eq 'testy.js' -and $a.runDir) { "  QA run folder: $($a.runDir) (unpublished items: below)" }
  if ($s.leaf -eq 'buildy.js' -and $agents.Count) {
    $rf = Join-Path (Get-KitPath launches -Create) "$(if ($s.runId) { $s.runId } else { $s.run }).resume.md"
    $txt = @("# Resume brief: $($s.run) ($($s.leaf) $($s.runId))", "Original brief: $($a.brief) (it wins where this differs). Mode: resume.",
      'A stopped agent''s work is below. Join the board with its id + -Resume (TAKEOVER, not DUPLICATE). Before editing: dev.ps1 wt status',
      '-Dir <wt> per worktree, the task + comments, open/merged MRs of the branch. Continue where it stopped (testing goals, local test',
      'loop, MRs); never redo finished work. Files changing under you = another writer: stop, report.', '', '## State at recovery') + $brief
    [IO.File]::WriteAllText($rf, ($txt -join "`n") + "`n")
    "  resume brief: $rf"
  }
  if ($s.runId) { "  RESUME: Workflow({ scriptPath: '$($s.script -replace '\\', '/')', resumeFromRunId: '$($s.runId)', args: $aj })" }
  if ($s.leaf -eq 'buildy.js') { "  RELAUNCH (resume refused): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: { ...the same args, brief: '<resume brief above>', mode: 'resume' } })" }
  elseif ($a.runDir) { "  RELAUNCH (resume refused): Workflow({ scriptPath: '$($s.script -replace '\\', '/')', args: { runDir: '$($a.runDir)', kitDir: '$($KitConf.Kit -replace '\\', '/')' } }) (item claims skip published items)" }
  "  then: orch.ps1 launch -RunId <new id> ... ; the old one: orch.ps1 launch -Done -RunId $(if ($s.runId) { $s.runId } else { '<id>' })"
}
if (-not $runs.Count) { 'no stopped workflow runs' }
foreach ($q in Get-OrphanQaItems -Hours $Hours) { "== QA $($q.run): tested, never published: $($q.codes -join ', ')$(if ($q.fails) { " (unverified FAIL in $($q.fails -join ', '): checky first)" })"; foreach ($c in $q.codes) { "  & $($KitCmd.qa) finalize -RunDir '$($q.dir)' -Code $c" } }
foreach ($f in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue) + @(Get-ChildItem (Get-KitPath phones) -Filter '*.json' -ErrorAction SilentlyContinue)) {   # README "Leases"
  $o = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { $null }; $ls = @{}; if ($o.lane) { $ls[$o.agent] = $o } else { foreach ($p in @($o.leases.PSObject.Properties) + @($o.holds.PSObject.Properties) | Where-Object { $_ }) { $ls[$p.Name] = $p.Value } }
  foreach ($k in @($ls.Keys)) { if ($k -notin '__stopping__', 'manual' -and -not (Test-KitLive $ls[$k])) { "== LEASE $($f.BaseName) $k [$(@($ls[$k].services) -join ',')]: no live holder, ends after idle.graceMinutes (now: $(if ($o.lane) { "swarm.ps1 release -Agent $k" } else { "localenv.ps1 release|unhold -Env $($f.BaseName) -Agent $k" }))" } }
}
foreach ($b in @(Get-KitHandoffs $Hours)) { "== HANDOFF $($b.agent) ($($b.run)): a fresh $(if ($b.type) { $b.type } else { 'agent' }) with the same -Agent and -Run continues from $($b.handoffBrief) (a workflow agent: its workflow starts it)" }
foreach ($l in @(Invoke-KitOutbox -DryRun)) { "== tracker outbox: $l (orch.ps1 supervise -AutoFix replays it)" }
"== heartbeat: a new session has none; arm ONE: CronCreate (cron */10 * * * *), prompt: ""Run & '$($KitCmd.orch -replace '\\', '/')' supervise -AutoFix -Brief, paste its output verbatim, one own line only when an ACT needs action (orchestrate E1)"""
}

# agents that handed off at their budget and no fresh agent took over yet
function Get-KitHandoffs([double]$Hours = 48) { @(Get-ChildItem (Get-KitPath board) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.handoffBrief -and -not $_.continuedBy -and ((Get-Date) - [datetime]$_.beat).TotalHours -lt $Hours }) }
function Get-OrphanQaItems([int]$Hours = 48) {
  $live = @(Get-ChildItem -LiteralPath (Get-KitPath launches -Create) -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} } |
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

# ---- track: task <-> MRs; promoted once all merge
function Invoke-Track {
param([Parameter(Position = 0)][ValidateSet('add', 'remove', 'show', 'run', 'rebuild')][string]$Action, [switch]$Rebuild, [switch]$Force, [string]$Task, [string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @(), [string]$Wave, [switch]$Detail, [string]$HoldPromotion)
$ErrorActionPreference = 'SilentlyContinue'
if ($Rebuild) { $Action = 'rebuild' }
# a throw is swallowed under SilentlyContinue
function Fail([string]$m) { [Console]::Error.WriteLine("track: $m"); exit 1 }
if (-not $Action) { Fail 'usage: orch.ps1 track add|remove|show|run|rebuild ... (or -Rebuild)' }
$wavesDir = Get-KitPath waves
$script:holds = 0
function Hold($s) { if ($Quiet) { return }; if ($Detail) { $s } else { $script:holds++ } }
function TaskStatus($id) { try { [string](Get-TrackerTask $id).status } catch { '' } }
$group = $KitConf.GitlabGroup
$groupRx = if ($group) { '(?:' + [regex]::Escape($group) + '/)?' } else { '' }
$alias = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $alias[$p.Name] = [string]$p.Value } }
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($group) { "$group/$repo" } else { $null } }
function NormRef($r) {
  $r = "$r".Trim().Trim("'", '"')  # with the quotes
  if ($u = ConvertFrom-MrUrl $r) { $r = "$($u.repo -replace "^(?i)$groupRx", '')!$($u.n)" }
  if ($r -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$' -and $alias[$Matches.repo]) { $r = "$($alias[$Matches.repo])!$($Matches.iid)" }
  $r
}
function Load($t) { (Read-KitTracking).tasks[$t] }
# task '0' broke every promote
function NormTask($id) {
  $id = "$id".Trim().Trim("'", '"').Trim()
  if ($KitConf.TrackerTag) { $id = $id -replace "^(?i)$([regex]::Escape($KitConf.TrackerTag))", '' }
  if ($id -match '^(0+|-+|none|null|undefined|n/?a|tbd|task|id)?$') { return '' }
  $id
}
function TaskOfMr($ref) {
  if (-not $KitConf.TrackerTag -or $ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return '' }
  $proj = ProjPath $Matches.repo; if (-not $proj) { return '' }
  $m = Invoke-HostApi "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)"
  foreach ($s in @($m.title, $m.source_branch)) { if ("$s" -match "(?i)$([regex]::Escape($KitConf.TrackerTag))(?<id>[A-Za-z0-9]+)") { return (NormTask $Matches.id) } }
  ''
}
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
function Save($o) {
  # keep what another process wrote since load
  Update-KitTracking {
    param($all)
    $cur = $all.tasks[$o.task]
    if ($cur) {
      # run vs add race
      $newMrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ -and @($cur.mrs) -notcontains $_ })
      if ($o.done -and -not $cur.done -and [string]$cur.reopenedAt -ne [string]$o.reopenedAt) { $o.done = $false; $o.reopenedAt = $cur.reopenedAt; foreach ($k in $script:doneFields) { $o.Remove($k) } }
      elseif ($cur.done -and -not $o.done -and [string]$cur.reopenedAt -eq [string]$o.reopenedAt -and -not $newMrs.Count) { $o.done = $true; $o.doneAt = $cur.doneAt }
    }
    if ($cur) { foreach ($k in 'mrs', 'mergeAfter') { $o[$k] = @(@($o[$k]) + @($cur[$k]) | Where-Object { $_ } | Select-Object -Unique) }; if ($cur.discover) { $o.discover = $true } }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
    $o.mergeAfter = @(@($o.mergeAfter) | Where-Object { $_ } | ForEach-Object { $p = $_ -split '>', 2; if ($p.Count -eq 2) { "$(NormRef $p[0])>$(NormRef $p[1])" } else { $_ } } | Select-Object -Unique)
    $all.tasks[$o.task] = $o
  }
}
function InFlight($ref) {
  if ($ref -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $null }
  $pat = "/$([regex]::Escape($Matches.r))/$MrSegRx/$($Matches.i)(\D|$)"
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
  'rebuild' {
    $tf = Get-KitPath tracking
    if ((Test-Path $tf) -and -not $Force) { "tracking file exists ($tf, $(@((Read-KitTracking).tasks.Keys).Count) task(s)): nothing to rebuild (-Force merges discovered tasks into it)"; return }
    $tag = $KitConf.TrackerTag; $repos = @($KitConf.TrackerRepos)
    if (-not $tag -or -not $repos.Count) {
      Update-KitTracking { param($t) }
      "rebuilt $tf with no tasks: discovery needs ""trackerRepos"" and a tracker tag (tracker.branchTag) in kit.local.json. Re-add open tasks with: orch.ps1 track add -Task <id> -Discover"
      return
    }
    $since = (Get-Date).AddDays(-14).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $found = @{}
    foreach ($r in $repos) {
      $pp = ProjPath $r; if (-not $pp) { "skip $r : use <group/repo> or set ""gitlabGroup"""; continue }
      $q = "projects/$($pp -replace '/', '%2F')/merge_requests?search=$([uri]::EscapeDataString($tag))&in=title,source_branch&state=all&updated_after=$since&per_page=100"
      foreach ($m in @(Invoke-HostApi $q) | Where-Object { $_ -and $_.state -ne 'closed' }) {
        if ("$($m.source_branch) $($m.title)" -notmatch "(?i)$([regex]::Escape($tag))(?<id>[A-Za-z0-9]+)") { continue }
        $id = $Matches.id
        if (-not $found[$id]) { $found[$id] = @{ mrs = @(); states = @() } }
        $found[$id].mrs += "$r!$($m.iid)"; $found[$id].states += $m.state
      }
    }
    $n = 0; $nDone = 0
    foreach ($id in $found.Keys) {
      if ((Load $id) -and -not $Force) { continue }
      $o = @{ task = $id; mrs = @($found[$id].mrs); onMerged = @('promoted'); discover = $true; done = $false; created = (Get-Date).ToString('s'); rebuilt = $true }
      if (-not @($found[$id].states | Where-Object { $_ -ne 'merged' }).Count -and (Test-TrackerStatus (TaskStatus $id) 'promoted', 'inTest', 'closed')) { $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); $nDone++ }
      Save $o; $n++
      if ($Detail) { "  $id : $($o.mrs -join ', ')$(if ($o.done) { ' (done)' })" }
    }
    if (-not (Test-Path $tf)) { Update-KitTracking { param($t) } }
    "rebuilt $tf : $n task(s) from $($repos.Count) repo(s) ($nDone already done; MRs with $tag<id> updated in the last 14 days)"
  }
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
  'remove' {
    $raw = "$Task".Trim().Trim("'", '"')
    $Task = if ($raw -and (Read-KitTracking).tasks.ContainsKey($raw)) { $raw } else { NormTask $raw }
    if (-not $Task) { Fail 'remove needs -Task' }
    $rm = @(@($Mrs -split '\s*,\s*') | ForEach-Object { NormRef $_ } | Where-Object { $_ })
    $script:hit = $false
    Update-KitTracking {
      param($all)
      if (-not $all.tasks.ContainsKey($Task)) { return }
      $script:hit = $true
      if (-not $rm.Count) { $all.tasks.Remove($Task); return }
      $x = $all.tasks[$Task]
      $x.mrs = @(@($x.mrs) | Where-Object { (NormRef $_) -notin $rm })
      $x.mergeAfter = @(@($x.mergeAfter) | Where-Object { $p = "$_" -split '>', 2; (NormRef $p[0]) -notin $rm -and (NormRef $p[-1]) -notin $rm })
    }
    if (-not $script:hit) { "not tracked: $Task" } elseif ($rm.Count) { "removed $($rm -join ', ') from $Task" } else { "removed task $Task" }
  }
  'show' {
    $all = @((Read-KitTracking).tasks.Values | ForEach-Object { [pscustomobject]$_ })
    foreach ($o in $all | Where-Object { $Detail -or -not $_.done }) { "$($o.task) done=$($o.done) -> $($o.onMerged -join '>') : " + (($o.mrs | ForEach-Object { "$_=$(MrState $_)" }) -join ', ') + $(if (@($o.mergeAfter).Count) { " | merge-after: $(@($o.mergeAfter) -join ', ')" }) }
    if (-not $Detail) { "($(@($all | Where-Object done).Count) finished task(s) hidden; -Detail lists them)" }
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
    foreach ($o in @((Read-KitTracking).tasks.Values | Where-Object { -not $_.done } | Sort-Object { [string]$_.checkedAt })) {
      $o.checkedAt = (Get-Date).ToString('s'); Save $o
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      foreach ($pair in @($o.mergeAfter)) {
        if ($pair -notmatch '^(?<dep>[^>]+)>(?<on>.+)$') { continue }
        $dep = $Matches.dep.Trim(); $on = $Matches.on.Trim()
        # the ship step merges it
        $owner = InFlight $dep
        if ($owner) { Hold "HOLD $($o.task): $dep waits for its review ($owner still running)"; continue }
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$') {
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
        if (-not @($o.mrs).Count -or -not $o.discoveredAt -or ((Get-Date) - [datetime]$o.discoveredAt).TotalMinutes -ge 30) { $o.mrs = @(@($o.mrs) + @(Find-TaskMrs $o.task) | Where-Object { $_ } | Select-Object -Unique); $o.discoveredAt = (Get-Date).ToString('s'); Save $o }
        if (-not @($o.mrs).Count) { continue }
        $cur = TaskStatus $o.task
        if (-not (Test-TrackerStatus $cur 'review')) {
          $allMerged = -not @(@($o.mrs) | Where-Object { (MrState $_) -ne 'merged' }).Count
          if (-not $allMerged) { $o.Remove('allMergedAt'); Save $o; continue }
          if (-not $o.allMergedAt) { $o.allMergedAt = (Get-Date).ToString('s'); Save $o; continue }
          if (((Get-Date) - [datetime]$o.allMergedAt).TotalMinutes -lt 20) { continue }
          if (-not $Quiet) { "NOTE $($o.task): status '$cur' was never set to review, but all MRs merged 20+ min ago - completing it" }
        }
      }
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
      if (Test-TrackerStatus $now 'closed', 'inTest') { $o.done = $true; Save $o; if (-not $Quiet) { "DONE $($o.task): all MRs merged; status '$now' kept (already past promoted)" }; continue }
      $todo = @($o.onMerged)
      for ($q = $todo.Count - 1; $q -ge 0; $q--) { if (Test-TrackerStatus $now $todo[$q]) { $todo = @($todo | Select-Object -Skip ($q + 1)); break } }
      $setFailed = $false
      foreach ($s in $todo) { try { $null = Set-TrackerStatus $o.task $s } catch { $setFailed = $true; if (-not $Quiet) { "ATTENTION $($o.task): could not set status '$s' (retried next run): $_" }; break } }
      if ($setFailed) { continue }
      $urls = @($o.mrs | ForEach-Object { if ($_ -match '^(?<r>[\w./-]+)!(?<i>\d+)$' -and ($pp = ProjPath $Matches.r)) { Invoke-HostVerb 'mr.url' @{ repo = $pp; n = $Matches.i } } })
      # a run killed before Save would post again
      $allC = @(try { Get-TrackerComments $o.task } catch {}) | ForEach-Object { [string]$_.text }
      if (-not $o.mergedCommentAt -and -not @($allC | Where-Object { $_ -match '^All MRs merged' }).Count) {
        $o.mergedCommentAt = (Get-Date).ToString('s'); Save $o
        try { $null = Add-TrackerComment $o.task "All MRs merged: $($urls -join ' , '). Status set to $($o.onMerged[-1]) automatically by the coordinator's tracker." } catch {}
      }
      $cmts = @($allC | Where-Object { $_ -notmatch '^All MRs merged' })
      if (-not ($cmts | Where-Object { $_ -match [string](Get-KitSetting 'locale.testCommentPattern' '(?i)how to test|test(ing)? (steps|guide|instructions)|tester guide|live check') })) {
        $proj = $KitConf.ClaudeProjectDir
        $steps = @(Get-ChildItem $proj -Recurse -Filter 'journal.jsonl' -File | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) } | Sort-Object LastWriteTime -Descending | ForEach-Object {
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
      $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); Save $o
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

# ---- report: supervise -Brief = the owner's round report as final markdown (no LLM step); pure on $d, so fixtures test it
$script:KitTypeIcon = @{ devy = '🛠️'; revy = '🔍'; checky = '🧪'; kitty = '🧹'; other = '🤖' }
# label prefix of a workflow agent() -> crew type
function Get-KitLabelType([string]$Label) {
  $p = ($Label -split ':')[0]
  if ($p -match '^(build|fix|local|local-strong|resume|envfix-resume|duel|debate|ship|track|ci|record-args|deploy-batch|duel-ask|duel-close|decide)') { 'devy' }
  elseif ($p -match '^(review|duel-compare|duel-moderate)') { 'revy' }
  elseif ($p -match '^(test|retest|verify|audit|close|hold|prepare|load-run|envfix|release|add-followups)') { 'checky' }
  elseif ($p -match '^(learn|cleanup|analyse|apply|stamp)') { 'kitty' } else { 'other' }
}
function Format-KitReport($d, [switch]$Ascii, [int]$Width = 160, [switch]$Agents) {   # -Agents: the coordinator's agent table first
  $g1 = { param($x) [math]::Round([double]$x, 1) }; $kd = { param($x) "+$([int]([double]$x / 1000))kT" }
  $L = [Collections.Generic.List[string]]::new()
  # 1. agents: one row per crew type; tokens = spend added since the last report
  if ($Agents) { $L.Add('| Agent | Doing |'); $L.Add('|---|---|') }
  $all = @($d.agents); $dt = { param($as) @($as | Where-Object { $null -ne $_.spend } | ForEach-Object { [math]::Max(0, [double]$_.spend - [double]$_.prevSpend) }) }
  foreach ($t in @('devy', 'revy', 'checky', 'kitty', 'other')) {
    $as = @($all | Where-Object { $_.type -eq $t }); if (-not $as.Count) { continue }
    $doing = (@($as | Group-Object mode | ForEach-Object { "$(if (@($_.Group | Where-Object wait).Count -eq $_.Count) { '⏸ ' })$($_.Name) $($_.Count) ($((@($_.Group | ForEach-Object name) -join ', ')))" }) -join ' · ')
    $x = & $dt $as; if ($Agents) { $L.Add("| $($script:KitTypeIcon[$t]) $($as.Count) × $t$(if ($x.Count) { " ($(& $kd ($x | Measure-Object -Average).Average))" }) | $doing |") }
  }
  if ($Agents -and -not $all.Count) { $L.Add('| — | nothing running |') }
  # 2. RAM: 7 categories + free (Available) as exactly 20 squares (largest remainder); legend on two lines; top apps; resources
  $m = $d.mem; $used = $m.TotalGB - $m.AvailGB; $rs = @($d.resources | Sort-Object { -[double]$_.gb }); $low = $m.AvailGB -lt $d.keepFree
  $rk = $d.ram; $fc = if ($low) { '🟥' } else { '⬜' }
  $bs = @(@('kit', '🟦', 'K', 'Kit'), @('browsers', '🟨', 'B', 'Your browsers'), @('apps', '🟧', 'A', 'Your apps'), @('servers', '🟩', 'S', 'Servers'),
    @('vms', '🟪', 'V', 'WSL'), @('windows', '🟫', 'W', 'Windows'), @('unknown', '⬛', 'U', 'Unknown'), @('free', $fc, '.', 'Free'))
  $val = @($bs | ForEach-Object { if ($_[0] -eq 'free') { [double]$m.AvailGB } else { [math]::Max(0, [double]$rk.($_[0])) } }); $tot = [math]::Max(0.1, ($val | Measure-Object -Sum).Sum)
  $q = @($val | ForEach-Object { 20 * $_ / $tot }); $cnt = @($q | ForEach-Object { [int][math]::Floor($_) })
  foreach ($i in @(0..($q.Count - 1) | Sort-Object { -($q[$_] - $cnt[$_]) } | Select-Object -First (20 - ($cnt | Measure-Object -Sum).Sum))) { $cnt[$i]++ }
  $sb = (@(0..($bs.Count - 1) | ForEach-Object { $(if ($Ascii) { $bs[$_][2] } else { $bs[$_][1] }) * $cnt[$_] })) -join ''; if ($Ascii) { $sb = "[$sb]" }
  if ($L.Count) { $L.Add('') }; $L.Add("🖥️ **RAM** $sb **$(& $g1 $used) / $(& $g1 $m.TotalGB) GB**")
  $lg = { param($i) "$($bs[$i][1]) $($bs[$i][3]) $(& $g1 $val[$i])$(if ($bs[$i][0] -eq 'unknown' -and @($d.unknown).Count) { " ($(@($d.unknown) -join ', '))" })" }
  $L.Add((@(0..3 | ForEach-Object { & $lg $_ })) -join ' · '); $L.Add("$((@(4..7 | ForEach-Object { & $lg $_ })) -join ' · ') · 🛡️ Floor $($d.keepFree)")
  if (@($d.top).Count) { $L.Add("top apps: $((@($d.top | ForEach-Object { "$($_.name) $(& $g1 $_.gb)$(if ($_.mark) { " $($_.mark)" })" })) -join ' · ') (💤 idle · 📈 +1 GB)") }
  if ($rs.Count -gt 10) { $rs = @($rs | Select-Object -First 9) + [pscustomobject]@{ name = "…$($rs.Count - 9) more"; type = 'more'; by = '—'; gb = (@($rs | Select-Object -Skip 9 | ForEach-Object { [double]$_.gb }) | Measure-Object -Sum).Sum } }
  $cell = { param($r) if ($r) { "$($r.name) | $(if ($r.by) { $r.by } else { '—' }) | $(if ($r.gb) { & $g1 $r.gb } else { '—' })" } else { ' | | ' } }
  if ($rs.Count) {
    $two = $Width -ge 120 -and $rs.Count -gt 1; $h = if ($two) { [math]::Ceiling($rs.Count / 2) } else { $rs.Count }
    $L.Add(''); $L.Add("| Resource | Used by | RAM$(if ($two) { ' | Resource | Used by | RAM' }) |"); $L.Add("|---|---|---$(if ($two) { '|---|---|---' })|")
    for ($i = 0; $i -lt $h; $i++) { $L.Add("| $(& $cell $rs[$i])$(if ($two) { " | $(& $cell $(if ($i + $h -lt $rs.Count) { $rs[$i + $h] }))" }) |") }
  }  # 3. flags: ACT, WATCH, then what waits for the owner as info (deploy-ready envs)
  $fl = @(@($d.flags | Where-Object { $_.level -ne 'INFO' } | Sort-Object { @{ ACT = 0; WATCH = 1; ASK = 2 }[$_.level] }) + @($d.info | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }))
  $L.Add(''); $L.Add("🚩 **Flags**$(if (-not $fl.Count) { ': none' })")
  foreach ($f in $fl | Select-Object -First 8) { $L.Add("- $(if ($f.level -eq 'ASK') { '❓ ' })**$($f.level)** $(if ($f.level -eq 'ASK') { '· ' })$($f.what)$(if ($f.action) { " -> $($f.action)" })") }; if ($fl.Count -gt 8) { $L.Add("- …$($fl.Count - 8) more: $($d.detailFile)") }
  $out = @($L)
  if ($Ascii) { $out = @($out | ForEach-Object { ($_ -replace '→', '->' -replace '·', '-' -replace '…', '...' -replace '×', 'x' -replace '—', '-' -replace '[^\x00-\x7F]+ ?', '').Trim() }) }
  $out
}
# ---- anomalies (pure: $c this round, $p last round's state.anom) -> flags + next state
function Get-KitAnomalies($c, $p, [datetime]$Now) {
  $f = [Collections.Generic.List[object]]::new(); $AddF = { param($w, $a) $f.Add([pscustomobject]@{ level = 'WATCH'; what = $w; action = $a }) }; if (-not $p) { $p = @{} }
  $n = @{ usedGB = $c.usedGB; outbox = $c.outbox; toolErrors = $c.toolErrors; cpuHighSince = $null; trains = @{} }
  foreach ($r in @($c.runs | Where-Object { $_ })) { $m = ($Now - [datetime]$r.at).TotalMinutes; if ($m -ge 20) { & $AddF "STALL: run $($r.id) no journal progress for $([int]$m) min" "evidence $($r.path); a stuck agent: orch.ps1 recover" } }
  foreach ($t in @($c.trains | Where-Object { $_ })) { $o = $p.trains.($t.env); $since = if ($o -and $o.key -eq $t.key) { [datetime]$o.since } else { $Now }; $n.trains[$t.env] = @{ key = $t.key; since = $since.ToString('o') }
    if (($Now - $since).TotalMinutes -ge 20) { & $AddF "STALL: $($t.env) train $($t.key) for $([int]($Now - $since).TotalMinutes) min" "evidence localenv.ps1 events -Env $($t.env)" } }
  foreach ($l in @($c.logs | Where-Object { $_.errors -gt 0 })) { & $AddF "ERROR SPIKE: $($l.errors) new error line(s) in $($l.path)" "first: $($l.first)" }
  foreach ($r in @($c.restarts | Where-Object { $_.n -gt 2 })) { & $AddF "RESTART LOOP: $($r.env) $($r.svc) restarted $($r.n) times in 30 min" "evidence localenv.ps1 logs -Env $($r.env) -Service $($r.svc)" }
  if ($null -ne $p.usedGB -and $c.usedGB - [double]$p.usedGB -ge 3) { & $AddF "RESOURCE SPIKE: RAM +$([math]::Round($c.usedGB - [double]$p.usedGB, 1)) GB since the last round" 'evidence: the resources and top apps above' }
  if ($c.cpu -gt 90) { $n.cpuHighSince = if ($p.cpuHighSince) { $p.cpuHighSince } else { $Now.ToString('o') }; $m = ($Now - [datetime]$n.cpuHighSince).TotalMinutes; if ($m -ge 10) { & $AddF "RESOURCE SPIKE: CPU $($c.cpu)% for $([int]$m) min" 'evidence: the busiest process (a runaway build or test?)' } }
  if ($null -ne $p.outbox -and $c.outbox -gt [int]$p.outbox) { & $AddF "SILENT FAILURE: tracker outbox grew to $($c.outbox) write(s)" 'evidence .state/outbox.jsonl: tracker auth / network' }
  if ($null -ne $p.toolErrors -and $c.toolErrors -gt [int]$p.toolErrors) { & $AddF "SILENT FAILURE: $($c.toolErrors - [int]$p.toolErrors) new agent result error(s)" "evidence $($c.errorRun) journal" }
  if ($c.lint) { & $AddF "SILENT FAILURE: kit main lint red: $($c.lint)" 'kitty fixes it (kittool.py lint)' }
  foreach ($u in @($c.adopted | Where-Object { $_ })) { & $AddF "UNKNOWN: $($u.env) $($u.svc) port $($u.port) is served by a process the kit did not start" "stop it or change the port (localenv.ps1 status -Env $($u.env))" }
  foreach ($u in @($c.stray | Where-Object { $_ })) { & $AddF "UNKNOWN: $u in the kit root is not tracked or ignored" 'move it to .runtime / .state or delete it' }
  [pscustomobject]@{ flags = @($f); state = $n }
}
# new error lines per log since its last size (ERROR SPIKE)
function Get-KitLogErrors([string[]]$Files, $Sizes) {
  foreach ($x in $Files) { $i = Get-Item $x -ErrorAction SilentlyContinue; if (-not $i) { continue }; $from = [long]$Sizes.($i.FullName); if (-not $Sizes.Contains($i.FullName)) { $from = $i.Length } elseif ($from -gt $i.Length) { $from = 0 }; $from = [math]::Max($from, $i.Length - 1MB)   # rotated: from 0; 1 MB at most
    $new = if ($i.Length -gt $from) { $s = [IO.File]::Open($i.FullName, 'Open', 'Read', 'ReadWrite'); try { [void]$s.Seek($from, 'Begin'); [IO.StreamReader]::new($s).ReadToEnd() } finally { $s.Dispose() } } else { '' }
    $hits = @($new -split "`r?`n" | Where-Object { $_ -match '\b(ERROR|FATAL)\b|Exception\b|Traceback|\b(status|HTTP/\S+)\W+5\d\d\b' })
    [pscustomobject]@{ path = $i.FullName; size = $i.Length; errors = $hits.Count; first = "$($hits | Select-Object -First 1)".Trim() } }
}
# orphan consoles: kit-owned, childless, idle a round (>= 5 min), parent gone (conhost: only then) or > 30 min old;
# $Keep: tool shells, this process' ancestors (and their children)
function Get-KitOrphanConsoles($Procs, $Kit, $PrevCpu, [double]$SinceMin, $Keep) {
  if ($SinceMin -lt 5) { return @() }
  $ids = @{}; $kids = @{}; foreach ($p in $Procs) { $ids[$p.Id] = $p; if ($p.Name -notmatch '^conhost') { $kids[$p.ParentId] = 1 } }
  @($Procs | Where-Object { $n = $_.Name -replace '\.exe$'; $pv = $PrevCpu["$($_.Id)"]; $gone = -not $ids[$_.ParentId]
    $n -match '^(cmd|conhost|pwsh|powershell|python\d*|py)$' -and $Kit[$_.Id] -and -not $kids[$_.Id] -and -not $Keep[$_.Id] -and -not $Keep[$_.ParentId] -and "$($_.CommandLine)" -notmatch '_daemon|_exec' -and
    $null -ne $pv -and [double]$_.Cpu - [double]$pv -lt 0.1 -and ($gone -or ($n -ne 'conhost' -and $_.Created -and ((Get-Date) - [datetime]$_.Created).TotalMinutes -gt 30)) })
}
# ---- supervise: coordinator heartbeat (FLAGS ACT / WATCH / INFO)
function Invoke-Supervise {
param([string]$Session, [switch]$Json, [int]$IdleMin = 25, [switch]$AutoFix,
  [string]$MarkStopped,  # lead stopped that run (TaskStop)
  [switch]$Brief,  # the /loop form
  [switch]$Takeover, [switch]$Ascii, [int]$Width = 0, [switch]$Agents,   # -Brief: the final markdown report (-Ascii: no emoji; -Width < 120: one stacked list)
  [int]$BudgetSeconds = 240, [switch]$Deep, [string]$App, [ValidateSet('', 'keep', 'close')][string]$Answer = '')
$ErrorActionPreference = 'SilentlyContinue'
if ($App) { $af = Get-KitPath owner-apps -Create; Invoke-KitLocked $af { $o = try { Get-Content $af -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $o) { $o = @{} }; $o[$App] = $Answer; $o | ConvertTo-Json | Set-Content $af }; "owner answer for ${App}: $(if ($Answer) { $Answer } else { 'cleared' })"; return }
$skills = Split-Path $PSScriptRoot
$swarm = Join-Path $skills 'android-swarm'
$wfAgents = New-Object System.Collections.ArrayList; $runTotal = 0; $runsNow = @(); $toolErr = 0; $errRun = ''; $now = Get-Date; $liveLabels = New-Object System.Collections.ArrayList; $runningLabels = New-Object System.Collections.ArrayList; $doneLabels = New-Object System.Collections.ArrayList; $flags = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
# a timed-out sweep still shows them
function Flag($lvl, $what, $action) { [void]$flags.Add([pscustomobject]@{ level = $lvl; what = $what; action = $action }) }
function L($s) { [void]$lines.Add($s) }
$lk = Join-Path (Get-KitPath cache -Create) 'supervise.lock'
$me = if ($Session) { $Session } else { "pid$PID" }
$script:aside = $null
Invoke-KitLocked $lk {
  $held = if (Test-Path $lk) { try { Get-Content $lk -Raw | ConvertFrom-Json } catch { $null } }
  if (-not $Takeover -and -not $MarkStopped -and $held -and $held.session -ne $me -and ((Get-Date) - [datetime]$held.at).TotalMinutes -lt 30) { $script:aside = "another session's supervisor ran $([int]((Get-Date) - [datetime]$held.at).TotalMinutes) min ago (session $($held.session)): this heartbeat steps aside (stop it, or -Takeover)"; return }
  @{ session = $me; at = (Get-Date).ToString('s'); pid = $PID } | ConvertTo-Json | Set-Content $lk
}
if ($script:aside) { $script:aside; return }
$t0 = Get-Date; $deadline = $t0.AddSeconds($BudgetSeconds); $script:skipped = @()
function Within($name) { if ((Get-Date) -lt $deadline) { $true } else { if ($name -notin $script:skipped) { $script:skipped += $name }; $false } }
$env:KIT_NET_TIMEOUT_SEC = [string][math]::Min(20, (Get-KitNetTimeout)); $env:KIT_NET_TRIES = '2'
function Left { [math]::Max(5, [int]($deadline - (Get-Date)).TotalSeconds) }
function Invoke-Bounded([string]$Script, [string[]]$A) { $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $Script) + $A) (Left); if ($r.timedOut) { $script:skipped += "$(Split-Path $Script -Leaf) $($A[0]) (timed out)" }; @($r.out -split "`r?`n" | Where-Object { $_ }) }

$proj = $KitConf.ClaudeProjectDir
$wfDirs = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents/workflows') -Directory } | Sort-Object LastWriteTime -Descending | Select-Object -First 6
$stoppedDir = Get-KitPath stopped
if ($MarkStopped) { $null = Get-KitPath stopped -Create; Set-Content (Join-Path $stoppedDir $MarkStopped) (Get-Date).ToString('s'); "marked $MarkStopped as stopped" }
foreach ($w in $wfDirs) {
  if (Test-Path (Join-Path $stoppedDir $w.Name)) { continue }
  $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
  $ev = @(Get-Content $j | ForEach-Object { $_ | ConvertFrom-Json })
  $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($r in $ev | Where-Object type -eq 'result') { $res[$r.agentId] = $r }
  $done = [bool]($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' })
  if ($done -and (($now - $w.LastWriteTime).TotalHours -gt 2)) { continue }
  $running = @($started | Where-Object { -not $res.ContainsKey($_.agentId) })
  # a 529-dead agent writes no result
  $itemOf = { param($label) (([string]$label -split ':', 2)[-1] -split '@')[0] }
  $finishedAt = @{}
  foreach ($s in $started) { if ($res.ContainsKey($s.agentId)) { $k = & $itemOf $s.label; $i = [array]::IndexOf($started, $s); if (-not $finishedAt.ContainsKey($k) -or $finishedAt[$k] -lt $i) { $finishedAt[$k] = $i } } }
  $running = @($running | Where-Object { $k = & $itemOf $_.label; -not ($finishedAt.ContainsKey($k) -and $finishedAt[$k] -gt [array]::IndexOf($started, $_)) })
  $running = @($running | Where-Object { $lbl = $_.label; $i = [array]::IndexOf($started, $_); -not @($started | Where-Object { $_.label -eq $lbl -and [array]::IndexOf($started, $_) -gt $i }).Count })
  $runTotal += $running.Count; $toolErr += @($res.Values | Where-Object { $_.result.error }).Count; if (@($res.Values | Where-Object { $_.result.error }).Count) { $errRun = $w.Name }
  if (-not $done -and $running.Count) { $runsNow += [pscustomobject]@{ id = $w.Name; at = (Get-Item $j).LastWriteTime.ToString('o'); path = $j } }
  L ("workflow {0}: {1} agents, {2} finished, {3} running{4}" -f $w.Name, $started.Count, $res.Count, $running.Count, $(if ($done) { ' (complete)' }))
  # `track` holds merges in review / fix
  if ($AutoFix -and $running.Count -and @($started | Where-Object { $_.label -match '^(build|review|fix):' }).Count) {
    if (Within 'wave reports') { $null = Invoke-Bounded $KitCmd.orch @('report', '-Run', $w.Name) }
  }
  foreach ($a in $running) {
    $tf = Get-ChildItem $w.FullName -Recurse -File -Filter "*$($a.agentId)*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idle = if ($tf) { [int]($now - $tf.LastWriteTime).TotalMinutes } else { -1 }
    L ("  {0,-18} idle {1} min" -f $a.label, $idle)
    if ($idle -ge 0 -and $idle -lt $IdleMin) { [void]$liveLabels.Add($a.label) }
    [void]$runningLabels.Add($a.label); [void]$wfAgents.Add([pscustomobject]@{ label = $a.label; agentId = $a.agentId; dir = $w.FullName })
    if ($idle -ge $IdleMin) { Flag 'WATCH' "$($a.label) in $($w.Name) has written nothing for $idle min" "Waiting on the gate is fine (board, gate queue); idle > 60 min with no build: let the workflow finish it, then resume it with RESUME_BRIEF." }
  }
  foreach ($r in $res.Values) {
    [void]$doneLabels.Add([string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label)
    $sum = [string]$r.result.summary + [string]$r.result.error
    # build-stage merged=false is no proof
    $shipped = $r.result.mrs -and -not @($r.result.mrs | Where-Object { -not $_.merged }).Count
    # "duplicate" matched bug summaries
    if ($running.Count -and -not $shipped -and $sum -match '(?i)duplicate (agent|copy|writer|instance|session)|(agent|copy|writer)s? collid|collid\w* with (another|an?other agent|agent)|another (agent|writer)|halted|stopped editing') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) in $($w.Name) reported a collision/halt" 'Read its result; resume it alone with RESUME_BRIEF after making sure no other writer is active (orch.ps1 board check).' }
    if ($null -ne $r.result.mrs -and @($r.result.mrs).Count -eq 0 -and $sum -match '(?i)not done|no MRs') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) finished without MRs" 'Resume it (buildy mode resume) unless it was deliberately stopped.' }
  }
}

$board = Get-KitPath board
$entries = @(Get-ChildItem $board -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
foreach ($e in @($entries | Where-Object { $_.status -ne 'left' -and (Test-KitHolder $_) -eq $false })) {
  if ($AutoFix) { $f = Join-Path $board "$($e.session).json"; $e.status = 'left'; if (Test-Path $f) { $e | ConvertTo-Json | Set-Content $f }; Flag 'INFO' "auto-fixed: board entry $($e.agent) ($($e.run)) marked left: its session process $($e.holderPid) is gone" 'Resume its work if unfinished (orch.ps1 recover).' }
  else { Flag 'WATCH' "board entry $($e.agent) ($($e.run)): its session process $($e.holderPid) is gone" 'supervise -AutoFix marks it left; orch.ps1 recover lists its work.' }
}
$active =@($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 })
$stale = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -ge 20 -and ($now - [datetime]$_.beat).TotalHours -lt 6 })
L "board: $($active.Count) active, $($stale.Count) stale"
# two waves may both have X1
foreach ($g in $active | Group-Object { "$($_.run)/$($_.agent)" } | Where-Object Count -gt 1) {
  $byBeat = @($g.Group | Sort-Object { [datetime]$_.beat } -Descending); $newest = [datetime]$byBeat[0].beat
  $old = @($byBeat | Select-Object -Skip 1)
  # a resumed duplicate keeps beating
  $superseded = { param($o) $o.run -eq $byBeat[0].run -and ((($newest - [datetime]$o.beat).TotalMinutes -ge 5) -or
      ((([datetime]$o.beat - [datetime]$o.joined).TotalSeconds -lt 5) -and [math]::Abs(([datetime]$o.joined - [datetime]$byBeat[0].joined).TotalMinutes) -le 2)) }
  $rejoin = -not @($old | Where-Object { -not (& $superseded $_) }).Count
  if ($rejoin) {
    if ($AutoFix) { foreach ($o in $old) { $f = Join-Path $board "$($o.session).json"; if (Test-Path $f) { $j = Get-Content $f -Raw | ConvertFrom-Json; $j.status = 'left'; $j | ConvertTo-Json | Set-Content $f } }; Flag 'INFO' "auto-fixed: $($g.Name) re-joined the board; $($old.Count) old entry/entries marked left" 'Nothing to do.' }
    else { Flag 'WATCH' "$($g.Name) has $($g.Count) board entries but only the newest beats (re-join, not a duplicate)" 'Run supervise with -AutoFix to tidy the board.' }
    continue
  }
  Flag 'ACT' "DUPLICATE agent $($g.Name) active in $($g.Count) sessions" 'Stop the newer copy (TaskStop the resumed task, never the workflow agent); never SendMessage a workflow agent by id.'
}
# testers don't beat in long checks
function LabelNames($l) { $p = $l -split ':'; $n = ($p[-1] -split '@')[0]; @($n) + $(if ($p.Count -gt 1) { "$n-$($p[0])" }) }
$liveNames = @($liveLabels | ForEach-Object { LabelNames $_ })
$doneNames = @($doneLabels | ForEach-Object { LabelNames $_ } | Where-Object { $_ -and $_ -notin $liveNames })
# workflow steps for Test-KitLive; ⏳ rows = holders in their grace
@{ at = $now.ToString('o'); running = @($runningLabels); labels = @(@($runningLabels) + @($doneLabels) | Where-Object { $_ } | Select-Object -Unique) } | ConvertTo-Json | Set-Content (Get-KitPath live-steps -Create); $graceRows = @{}
foreach ($s in $stale | Where-Object { $_.agent -in $doneNames }) {
  if ($AutoFix) { $f = Join-Path $board "$($s.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }; Flag 'INFO' "auto-fixed: board entry $($s.agent) marked left (its workflow step finished)" 'Nothing to do.' }
}
foreach ($s in $stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames }) {
  if ($AutoFix -and ($now - [datetime]$s.beat).TotalHours -ge 2) { Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) silent $([int]($now - [datetime]$s.beat).TotalMinutes) min -> marked left" 'Nothing to do.'; continue }
  Flag 'WATCH' "board entry $($s.agent) ($($s.run)) has no heartbeat for $([int]($now - [datetime]$s.beat).TotalMinutes) min" 'It may have finished without leaving, or be stuck. Cross-check with the workflow journal.' }

$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
$queue = @(Get-ChildItem (Join-Path $ledger 'queue') -Filter '*.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
$runningB = @(Get-ChildItem $ledger -Filter '*.json' | Where-Object Name -ne 'history.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
foreach ($t in @($runningB | Where-Object { $_.gate })) {   # holder = its gate process (then its owner agent)
  $bl = @{ agent = $t.owner; pid = $t.gate; seen = $t.seen }; $keep = Update-KitLease $bl; if ("$($bl.seen)" -ne "$($t.seen)") { $t | Add-Member -Force seen $bl.seen; $t | ConvertTo-Json | Set-Content (Join-Path $ledger "$($t.pid).json") }
  $bp = Get-Process -Id ([int]$t.pid) -ErrorAction SilentlyContinue; if (-not $bp -or $bp.StartTime -gt ([datetime]$t.started).AddSeconds(5)) { continue }   # pid reused: not ours
  if ($keep) { if ($null -ne $bl.graceLeft) { $graceRows["🔨 $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"] = $bl.graceLeft }; continue }
  if ($AutoFix) { try { $bp.Kill($true) } catch {}; Flag 'INFO' "auto-fixed: stopped build $($t.kind) of $($t.owner) (pid $($t.pid)): no live holder" 'Nothing to do.' }
  else { Flag 'ACT' "build $($t.kind) of $($t.owner) (pid $($t.pid)) runs with no live holder" 'supervise -AutoFix stops it.' }
}
$oldest = $queue | Sort-Object { [datetime]$_.since } | Select-Object -First 1
$wait = if ($oldest) { [int]($now - [datetime]$oldest.since).TotalMinutes } else { 0 }
L "gate: $($runningB.Count) running ($((@($runningB | ForEach-Object { "$($_.kind)" }) -join ', '))), $($queue.Count) queued, longest wait $wait min"
if ($wait -ge 30) { Flag 'ACT' "gate: $($oldest.owner) $($oldest.kind) has waited $wait min" 'Memory-bound: start no new agents, run orch.ps1 cleanup, ask the owner to close big apps (❓ ASK rows); fewer agents per wave.' }
elseif ($queue.Count -ge 6) { Flag 'WATCH' "gate: $($queue.Count) builds queued" 'Do not launch more build-heavy agents until the queue drains.' }
$hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
foreach ($k in $hist.Keys) { $last = @($hist[$k] | Select-Object -Last 3); if ($last.Count -eq 3 -and -not ($last | Where-Object { $_.ok })) { Flag 'WATCH' "builds '$k' failed 3 times in a row" 'Look at that agent: repeated failing builds burn memory turns; it may need help or a brief fix.' } }

$stateFile = Get-KitPath supervise-state -Create
$state = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $state) { $state = @{} }; if (-not $state.idleSince) { $state.idleSince = @{} }
$adb = Join-Path (Get-AndroidSdk) (Join-Path 'platform-tools' (Get-ExeName 'adb'))
$devT = Get-KitSetting 'devices.type' 'android'
if ($devT -ne 'none' -and ($devT -eq 'ios' -or (Test-Path $adb))) {
  $serials = @(if ($devT -eq 'android') { & $adb devices 2>$null | Where-Object { $_ -match '^(emulator-\d+)\s+device' } | ForEach-Object { $Matches[1] } })
  $swarmCfg = try { Get-Content (Join-Path $swarm 'swarm.config.json') -Raw | ConvertFrom-Json } catch { $null }
  # safety net for leases whose holder is gone
  $P = ({ & $KitCmd.swarm @args })
  $leaseDir = Get-KitPath phones
  foreach ($lf in @(Get-ChildItem $leaseDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $ls = Get-Content $lf.FullName -Raw | ConvertFrom-Json; $age = [int]($now - [datetime]$ls.since).TotalMinutes
    if ($ls.agent -eq 'manual') {
      if ($age -ge 240) { Flag 'WATCH' "phone $($ls.lane) booted by hand $([int]($age / 60)) h ago is still up" "If you are done with it: & $($KitCmd.swarm) release -Agent manual" }
      continue
    }
    if ($ls.agent -eq '__stopping__') { continue }
    $s0 = "$($ls.seen)"; $keep = Update-KitLease $ls
    if ($keep -and (-not $s0 -or ([datetime]$ls.seen - [datetime]$s0).TotalMinutes -ge 1) -and (Test-Path $lf.FullName)) { $ls | ConvertTo-Json -Depth 5 | Set-Content "$($lf.FullName).sv"; Move-Item "$($lf.FullName).sv" $lf.FullName -Force }   # atomic, never resurrects
    if ($keep) { if ($null -ne $ls.graceLeft) { $graceRows["📱 $($ls.lane)"] = $ls.graceLeft }; continue }   # seen persists
    if ($AutoFix) { $r = & $P release -Agent $ls.agent 2>&1; Flag 'INFO' "auto-fixed: released phone $($ls.lane) of $($ls.agent) (no live holder): $r" 'Nothing to do.' }
    else { Flag 'ACT' "phone lease $($ls.lane) held by $($ls.agent): no live holder" "& $($KitCmd.swarm) release -Agent $($ls.agent)" }
  }
  $pkg = if ($swarmCfg) { $swarmCfg.app.package } else { $null }
  foreach ($sr in $serials) {
    $lane = if ($swarmCfg) { ($swarmCfg.lanes | Where-Object { "emulator-$($_.port)" -eq $sr } | Select-Object -First 1).name } else { $null }
    if ($lane -and (Test-Path (Join-Path $leaseDir "$lane.json"))) { $state.idleSince.Remove($sr) | Out-Null; continue }
    $appRunning = $pkg -and [bool]((& $adb -s $sr shell pidof $pkg 2>$null) -join '').Trim()
    if ($appRunning) { $state.idleSince.Remove($sr) | Out-Null; continue }
    if (-not $state.idleSince.ContainsKey($sr)) { $state.idleSince[$sr] = $now.ToString('o') }
    $idleFor = [int]($now - [datetime]$state.idleSince[$sr]).TotalMinutes
    if (-not $lane) {
      if ($idleFor -ge 10) { Flag 'WATCH' "emulator $sr is not in swarm.config.json and our app is closed on it for $idleFor min" "If nobody uses it: & $adb -s $sr emu kill" }
    } elseif ($AutoFix -and $idleFor -ge 10) {
      & $KitCmd.swarm down -Lanes $lane -KeepBrowsers | Out-Null
      $state.idleSince.Remove($sr) | Out-Null
      Flag 'INFO' "auto-fixed: shut down unleased emulator $sr ($lane): app closed for $idleFor min" 'Agents get phones with swarm.ps1 acquire.'
    } else { Flag $(if ($idleFor -ge 10) { 'ACT' } else { 'WATCH' }) "unleased emulator $sr ($lane): app closed for $idleFor min" "& $($KitCmd.swarm) down -Lanes $lane -KeepBrowsers (or supervise -AutoFix)" }
  }
  # 3c. crashed / hung emulators
  if ($swarmCfg) {
    $adbStates = { $st = @{}; foreach ($ln in @(& $adb devices 2>$null)) { if ($ln -match '^(emulator-\d+)\s+(\S+)') { $st[$Matches[1]] = $Matches[2] } }; $st }
    $adbState = & $adbStates; $rechecked = $false
    $emuProcs = @(Get-SysProcs -Name '^(emulator|qemu-system)')
    foreach ($ln in $swarmCfg.lanes) {
      $sr = "emulator-$($ln.port)"
      $mine = @($emuProcs | Where-Object { $_.CommandLine -match "-port\s+$($ln.port)\b" })
      if (-not $mine.Count) { continue }
      $youngest = [int](($mine | ForEach-Object { ($now - $_.Created).TotalMinutes } | Measure-Object -Minimum).Minimum)
      $qemu = @($mine | Where-Object Name -like 'qemu-system*')
      $whyOf = { if ($adbState[$sr] -ne 'device' -and $youngest -ge 8) { "adb shows it '$(if ($adbState[$sr]) { $adbState[$sr] } else { 'absent' })' $youngest min after start (crashed or hung)" }
                elseif (-not $qemu.Count -and $youngest -ge 2) { "its qemu process is gone (crashed)" } }
      $why = & $whyOf
      # adb may have just restarted
      if ($why -and $adbState[$sr] -ne 'device' -and -not $rechecked) { Start-Sleep -Seconds 10; $adbState = & $adbStates; $rechecked = $true; $why = & $whyOf }
      if (-not $why) { continue }
      if (Test-Path (Join-Path $leaseDir "$($ln.name).json")) {  # leased: never killed
        Flag 'WATCH' "leased emulator $sr ($($ln.name)) looks dead: $why" "Its holder re-boots it (swarm.ps1 ensure or its next acquire); with no live holder its lease ends after idle.graceMinutes."; continue
      }
      if ($AutoFix) {
        $mine | ForEach-Object { Stop-SysProcess $_.Id }
        Flag 'INFO' "auto-fixed: killed dead emulator $sr ($($ln.name)): $why" 'Nothing to do.'
      } else { Flag 'ACT' "dead emulator $sr ($($ln.name)): $why" "& $($KitCmd.swarm) down -Lanes $($ln.name) -KeepBrowsers (or supervise -AutoFix)" }
    }
  }
}
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile

$mem = Get-SysMem; $tot = $mem.TotalGB; $avail = $mem.AvailGB
$pct = [int](100 * (1 - $avail / $tot)); L "memory: $pct% used, $([math]::Round($avail,1)) GB available"
$ramAct = [int](Get-KitSetting 'supervise.ramActPct' 90); $diskMin = [double](Get-KitSetting 'supervise.minDiskFreeGB' 30)
if ($pct -ge $ramAct) { Flag 'ACT' "RAM $pct% used" 'Hold new launches; run orch.ps1 cleanup; check for orphaned java/node/chrome from finished agents.' }
$drive = if ($KitIsWindows) { $KitConf.Workspace.Substring(0, 1) } else { $KitConf.Workspace }
$freeGB = try { [math]::Round([IO.DriveInfo]::new($(if ($KitIsWindows) { "${drive}:\" } else { $drive })).AvailableFreeSpace / 1GB) } catch { 999 }
L "disk ${drive}: $freeGB GB free"
if ($freeGB -lt $diskMin) { Flag 'ACT' "disk ${drive}: only $freeGB GB free" 'Run orch.ps1 cleanup; remove finished worktrees.' }
$gl = Get-KitPath guard-log
$blocks = @(Get-Content $gl | Where-Object { $_ -match '^(\S+)\t' -and ($now - [datetime]$Matches[1]).TotalMinutes -lt 60 })
if ($blocks.Count -ge 3) { Flag 'WATCH' "guard blocked $($blocks.Count) commands in the last hour" 'Agents are tripping a rule: read guard.log; add a contracts note or a lesson so they stop.' }

if ($AutoFix -and (Within 'tracker + deploy checks')) {
  $S = $PSScriptRoot
  function OwnerOf($repo, $iid) {
    $proj = if ($KitConf.GitlabGroup) { "$($KitConf.GitlabGroup)/$repo" } else { $repo }
    $src = (Invoke-HostApi "projects/$([uri]::EscapeDataString($proj))/merge_requests/$iid").source_branch
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
  $D = ({ & $KitCmd.qa deployed @args })
  foreach ($o in @((Read-KitTracking).tasks.Values)) {
    if (-not (Within 'deploy checks')) { break }
    # a repo may deploy to several test envs
    if (-not $o.done -or -not $o.doneAt -or ($now - [datetime]$o.doneAt).TotalDays -gt 3) { continue }
    if ($o.qaCovered) { continue }
    if ($o.liveCheckedAt -and ($now - [datetime]$o.liveCheckedAt).TotalMinutes -lt $(if (@($o.liveOn).Count) { 60 } else { 10 })) { continue }
    # skip the deploy lookup (10+ calls)
    $covered = @(Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter 'run.json' -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($o.task) } | ForEach-Object { $_.Directory.Name })
    if ($covered.Count) { Set-KitTaskFields $o.task @{ qaCovered = @($covered) }; continue }
    $rows = @(Invoke-Bounded $KitCmd.qa @('deployed', '-Mrs', (@($o.mrs) -join ','), '-Json') | Out-String | ConvertFrom-Json)
    $o.liveCheckedAt = $now.ToString('o')
    $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -ne 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
    $new = @($live | Where-Object { $_ -notin @($o.liveOn) })
    $fields = @{ liveCheckedAt = $o.liveCheckedAt }; if ($new.Count) { $fields.liveOn = @(@($o.liveOn) + $new | Where-Object { $_ } | Select-Object -Unique) }
    Set-KitTaskFields $o.task $fields
    if ($new.Count -and (Test-TrackerStatus $(try { (Get-TrackerTask $o.task).status } catch { '' }) 'closed')) {
      Set-KitTaskFields $o.task @{ qaCovered = @('closed') }; continue
    }
    if ($new.Count) {
      # deployed = in test (never before)
      if ($AutoFix) { foreach ($l2 in @(Invoke-Bounded $KitCmd.orch @('deploy', 'intest', '-Task', $o.task, '-Apply', '-Quiet'))) { Flag 'INFO' "auto-fixed: LIVE $($o.task) on $($new -join ', '): $l2" 'Tracker set to inTest; nothing to do.' } }
      else { Flag 'ACT' "LIVE $($o.task): all MRs ($(@($o.mrs) -join ', ')) deployed to $($new -join ', ')" "& $($KitCmd.orch) deploy intest -Task $($o.task) -Apply (inTest). Agent QA on staging only when the owner asks (/testy)." }
    }
  }
  foreach ($gone in $stale | Where-Object { ($now - [datetime]$_.beat).TotalHours -ge 2 }) {
    $f = Join-Path $board "$($gone.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }
  }
  # idle Gradle / Kotlin daemons hold GBs
  if ($pct -ge 85) { foreach ($l in @(& $KitCmd.orch cleanup | Select-Object -First 1)) { Flag 'INFO' "auto-fixed: RAM $pct% -> orch.ps1 cleanup: $l" 'Re-check memory next round.' } }
  elseif (Within 'cleanup') { $null = Invoke-Bounded $KitCmd.orch @('cleanup', '-IfDue', '-Quiet') }
}

if (Within 'QA bug tasks') {
$parents = @(Get-ChildItem (Get-KitPath qa-runs) -Directory | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'run.json') -Raw | ConvertFrom-Json).tracker.parent } catch {} } | Where-Object { $_ } | Select-Object -Unique)
$tracked = @((Read-KitTracking).tasks.Keys)
$openRuns = @{}
foreach ($rd in Get-ChildItem (Get-KitPath qa-runs) -Directory | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }) {
  try { $rj = Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { continue }
  $left = @($rj.items | Where-Object { -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) }).Count
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
$back = @(foreach ($id in $ft.Keys) { if (-not (Within 'failedTesting tasks')) { break }; $o = $trk[$id]; if ($o -and -not $o.done) { continue }
    $st = try { [string](Get-TrackerTask $id).status } catch { '' }
    if ((Test-TrackerStatus $st 'failedTesting') -or ($o.done -and (Test-TrackerStatus $st 'inProgress'))) { "$id ($($ft[$id]))" } })
if ($back.Count) { Flag 'ACT' "$($back.Count) task(s) failed testing, back to the dev flow: $($back -join '; ')" "ONE /buildy mode 'bugfix' for all: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> per task (reproduce locally first), then launch." }
}
foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ })) {
  # ENV-FIX: the coordinator's job
  $age = "waiting $([int]($now - [datetime]$d.at).TotalMinutes) min"   # every round until answered
  if ($d.kind -eq 'envfix') { Flag 'ACT' "ENV-FIX $($d.id) $age ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Fix the local env (local-env: localenv.ps1 up/refresh/drop, shared DB repair), then & $($KitCmd.orch) decide answer -Id $($d.id) -By coordinator -Answer 'done: <what you did>' (cannot: 'cannot: <why>')"; continue }
  Flag 'ACT' "DECISION $($d.id) $age ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Ask the owner (options: $(@($d.options) -join ' ; ')$(if ($d.recommend) { "; recommended: $($d.recommend)" })), then & $($KitCmd.orch) decide answer -Id $($d.id) -Answer '<their words>'"
}
if (Within 'deploy plan') {
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'
$cache = if (Test-Path $pc) { try { Get-Content $pc -Raw | ConvertFrom-Json } catch { $null } }
if (-not $cache -or ($now - [datetime]$cache.at).TotalMinutes -ge 60) {
  $plan = @(Invoke-Bounded $KitCmd.orch @('deploy', 'plan', '-Json') | Out-String | ConvertFrom-Json | Where-Object { $_ })
  $cache = [pscustomobject]@{ at = $now.ToString('s'); ready = @($plan | Where-Object status -in 'READY', 'ASK' | ForEach-Object { "$($_.target) ($(@($_.mrs).Count) MR(s))" }); ask = @($plan | Where-Object status -eq 'ASK' | ForEach-Object { "$($_.target): $(@($_.mrs).Count) MR(s) ($((@($_.mrs) | ForEach-Object mr) -join ', '))" }) }
  $cache | ConvertTo-Json -Depth 4 | Set-Content $pc -Encoding utf8
}
foreach ($a in @($cache.ask | Where-Object { ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower() -eq 'ask' })) { Flag 'ACT' "DEPLOY ASK $a merged, not deployed, window open" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; after the deploy: deploy record -Env <target> -Mrs <refs>, then deploy intest -Apply." }
}
$keepFree = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
$freeNow = Get-FreeGB
$seatDir = Get-KitPath qa-seats
foreach ($sf in @(Get-ChildItem (Join-Path $seatDir 'seats'), (Join-Path $seatDir 'wait'), (Join-Path $seatDir 'claims') -Filter *.json -ErrorAction SilentlyContinue)) {
  $so = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $null }
  if ($so -and (Test-KitHolder $so) -eq $false) {
    if ($AutoFix) { Remove-Item $sf.FullName -Force; Flag 'INFO' "auto-fixed: freed QA $(Split-Path $sf.DirectoryName -Leaf) $($sf.BaseName): its session process $($so.holderPid) is gone" 'Nothing to do.' }
    else { Flag 'WATCH' "QA $(Split-Path $sf.DirectoryName -Leaf) $($sf.BaseName): its session process $($so.holderPid) is gone" 'supervise -AutoFix frees it.' }
  }
}
if ($AutoFix -and (Within 'browser tabs') -and (Test-Path (Join-Path $KitConf.Kit 'skills/qa-kit/node_modules/puppeteer-core')) -and @(Get-ChildItem (Get-KitPath sessions) -Filter 'tabs-*.json' -ErrorAction SilentlyContinue).Count) {
  $r = Invoke-KitExe 'node' @('--input-type=module', '-e', "const m = await import('$([Uri]::new((Join-Path $KitConf.Kit 'skills/qa-kit/browser.mjs')).AbsoluteUri)'); console.log(await m.sweepAll())") (Left)
  if ($r.code -eq 0 -and "$($r.out)".Trim() -match '^[1-9]\d*$') { Flag 'INFO' "auto-fixed: closed $($r.out.Trim()) orphan browser tab(s) (holder gone or left the board)" 'Nothing to do.' }
}
if ($AutoFix) { foreach ($l in @(Invoke-DisputeExpiry)) { Flag 'INFO' "auto-fixed: $l" 'The owner judges it (orchestrate E4).' } }
$seatsNow =@(Get-ChildItem (Join-Path $seatDir 'seats') -Filter *.json -ErrorAction SilentlyContinue).Count
$waitNow = @(Get-ChildItem (Join-Path $seatDir 'wait') -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddMinutes(-3) }).Count
L "qa seats: $seatsNow taken, $waitNow waiting for memory; free RAM $freeNow GB"
foreach ($rd in Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-8) }) {
  $run = try { Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { $null }
  if (-not $run) { continue }
  $queued = @($run.items | Where-Object { $_.lane -ne 'app' -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) -and
      -not (Test-Path (Join-Path $seatDir "claims/$($rd.Name)__$($_.code).json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)/shots")) } | ForEach-Object code)
  if (-not $queued) { continue }
  # an extra worker would test items twice
  $legacy = @($run.items | Where-Object { (Test-Path (Join-Path $rd.FullName "$($_.code)/shots")) -and -not (Test-Path (Join-Path $seatDir "claims/$($rd.Name)__$($_.code).json")) }).Count
  if ($legacy) { continue }
  $room = [math]::Floor(($freeNow - $keepFree) / 1.5)
  if ($room -ge 2 -and $waitNow -eq 0) {
    $n = [math]::Min($room, $queued.Count)
    Flag 'INFO' "capacity: $($rd.Name) has $($queued.Count) queued item(s) ($($queued -join ', ')) and room for ~$room more QA agents ($freeNow GB free)" "Add workers: Workflow testy with args { runDir: '$($rd.FullName)', kitDir: '$($KitConf.Kit)', instance: 'w<next>', webParallel: $n, only: [$(($queued | ForEach-Object { "'$_'" }) -join ', ')] } - item claims stop two runs testing the same item."
  } elseif ($freeNow -lt $keepFree) { Flag 'WATCH' "memory tight ($freeNow GB free): QA seats are holding new agents back" 'Do not launch more agents until it recovers; close big apps if it persists.' }
}

if (-not $runTotal) {
  $sigF = Get-KitPath signals; $markF = Get-KitPath last-retro
  $since = if (Test-Path $markF) { [datetime](Get-Content $markF -Raw).Trim() } else { [datetime]::MinValue }
  $nSig = if (Test-Path $sigF) { @(Get-Content $sigF | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count } else { 0 }
  $finished = @($wfDirs | Where-Object { $_.LastWriteTime -gt $since -and (Test-Path (Join-Path $_.FullName 'journal.jsonl')) -and
      (Select-String (Join-Path $_.FullName 'journal.jsonl') -Pattern '"label":"(build|test|retest|verify|fix):' -Quiet) }).Count
  if ($nSig -ge 15 -or ($nSig -ge 1 -and $finished)) { Flag 'ACT' "retro due: $nSig signals since the last retro, $finished dev/QA run(s) finished since, no workflow running" '/tidy (E10)' }
}

# budget: past handoff, handoffs not continued, runs at their stop line
foreach ($e in $active | Where-Object { $_.budget -and $_.spend -ge $_.handoff }) { Flag 'WATCH' "$($e.agent) ($($e.run)) past its handoff point: $($e.spend) of $($e.budget) tokens" 'It hands off at its next beat; silent 20 min -> stop it, continue fresh (orch.ps1 recover).' }
foreach ($h in Get-KitHandoffs 24 | Where-Object { ($now - [datetime]$_.beat).TotalMinutes -ge 15 }) { Flag 'ACT' "HANDOFF $($h.agent) ($($h.run)) $([int]($now - [datetime]$h.beat).TotalMinutes) min ago, no fresh agent yet" "Spawn a fresh $(if ($h.type) { $h.type } else { 'agent' }) (same -Agent, -Run): continue from $($h.handoffBrief)" }
foreach ($sf in @(Get-ChildItem (Get-KitPath launches) -Filter 'self-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-12) } | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
  $o = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $null }; if (-not $o.cap -or -not (Within 'run budgets')) { continue }
  $sp = try { & $KitCmd.orch budget -Run $o.run -Json | ConvertFrom-Json } catch { $null }
  if ($sp -and $sp.spent -ge $o.stopAt * $o.cap) { Flag 'WATCH' "run $($o.run) at $([int](100 * $sp.spent / $o.cap))% of its cap ($($sp.spent) / $($o.cap))" 'No new item starts; launch its next when it finishes (E7).' }
}
# the round report from one process snapshot
$rep = if ($state.report) { $state.report } else { @{ spend = @{} } }; $spendNow = @{}
$ags = [Collections.Generic.List[object]]::new()
foreach ($e in $active) { $ags.Add([pscustomobject]@{ type = $(if ($e.type) { $e.type } else { 'other' }); name = $e.agent; mode = $(if ($e.status -and $e.status -ne 'working') { $e.status } else { $e.run }); wait = $e.status -match 'wait'; spend = $e.spend }) }
foreach ($a in $wfAgents) {
  $nm = (($a.label -split ':', 2)[-1] -split '@')[0]; if (@($ags | Where-Object name -eq $nm).Count) { continue }
  $p = ($a.label -split ':')[0]; $sp = Get-KitSpend (Join-Path $a.dir "agent-$($a.agentId).jsonl")
  $ags.Add([pscustomobject]@{ type = Get-KitLabelType $a.label; name = $nm; mode = $(if ($p -match 'envfix') { 'env-fix' } elseif ($p -match 'wait|decide') { 'decision' } else { $p }); wait = $p -match 'wait|decide'; spend = $sp.spend })
}
foreach ($x in $ags) { $spendNow[$x.name] = $x.spend; $x | Add-Member -Force NoteProperty prevSpend $(if ($rep.spend -and $null -ne $rep.spend[$x.name]) { $rep.spend[$x.name] } else { $x.spend }) }
$ps = @(Get-SysProcs); $kids = @{}; foreach ($p in $ps) { $kids[$p.ParentId] = @($kids[$p.ParentId]) + $p }; $byId = @{}; foreach ($p in $ps) { $byId[$p.Id] = $p }
$seen = @{}; $tree = { param($r) $g = 0.0; $st = [Collections.Stack]::new(); $st.Push($r); while ($st.Count) { $q = $st.Pop(); if (-not $q -or $seen[$q.Id]) { continue }; $seen[$q.Id] = 1; $g += $q.WorkingSet; foreach ($c in @($kids[$q.Id])) { if ($c) { $st.Push($c) } } }; $g / 1GB }
$res = [Collections.Generic.List[object]]::new(); $ownerInfo = @()
$le = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'status', '-Json') ([math]::Min(30, (Left)))
foreach ($ev in @(try { "$($le.out)" | ConvertFrom-Json } catch { @() }) | Where-Object { $_.env -and @($_.services).Count }) {
  $down = @($ev.services | Where-Object { $_.state -notmatch '^up' })
  foreach ($sv in @($ev.services | Where-Object { $_.state -match '^up' })) {
    $hl = @(@($ev.leases) + @($ev.holds) | Where-Object { $_ -and $sv.service -in @($_.services) }); $gl = @($hl | Where-Object { $null -ne $_.graceLeft } | ForEach-Object graceLeft | Sort-Object)[0]
    $res.Add([pscustomobject]@{ name = "🟢 $($ev.env) · $($sv.service)"; type = 'local env'; by = "$((@($hl | ForEach-Object { if ($_.agent) { $_.agent } else { $_.who } }) | Select-Object -Unique) -join ', ')$(if ($null -ne $gl) { " ⏳ $gl min" })"; gb = $sv.gb })
    $why = @($sv.need); $h1 = @($ev.holds | Where-Object { $sv.service -in @($_.services) -and $_.at -and ($now - [datetime]$_.at).TotalMinutes -ge 30 })[0]
    if ($h1 -and $why.Count -and -not @($why | Where-Object { $_ -notmatch '^hold:' }).Count) { Flag 'WATCH' "$($ev.env) $($sv.service) kept up only by $($h1.who)'s hold for $([int]($now - [datetime]$h1.at).TotalMinutes) min (no lease)" "Done with it: & $($KitCmd.local) unhold -Env $($ev.env) -Agent $($h1.who)" }
  }
  foreach ($h in @($ev.holds | Where-Object owner)) { $ownerInfo += "⏳ owner hold $($ev.env) [$(@($h.services) -join ',')] until $($h.until) (unhold -Env $($ev.env) -Agent $($h.who) when done)" }
  if ($down.Count) { $res.Add([pscustomobject]@{ name = "🔴 $($ev.env) · $(($down | ForEach-Object service) -join ' · ')"; type = 'local env'; by = "down: $(@($down | ForEach-Object { if ("$($_.why)" -match 'memory|RAM') { 'memory' } elseif ($_.why) { "$($_.why)".Substring(0, [math]::Min(30, "$($_.why)".Length)) } else { $_.state } } | Select-Object -Unique) -join ', ')"; gb = 0 }) }
}
$ports = try { Get-Content (Get-KitPath browser-ports) -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }; $keyOf = @{}; foreach ($k in $ports.Keys) { $keyOf["$($ports[$k])"] = $k }
$isBr = { param($p) $p.Name -match '^(chrome|msedge|chromium)(\.exe)?$' }
foreach ($b in @($ps | Where-Object { (& $isBr $_) -and -not ($byId[$_.ParentId] -and (& $isBr $byId[$_.ParentId])) })) {
  if ($b.CommandLine -match '--remote-debugging-port=(\d+)' -and $keyOf[$Matches[1]]) {
    $k = $keyOf[$Matches[1]]; $tf = Get-Item (Join-Path (Get-KitPath sessions) "tabs-$($k -replace '\|', '__').json") -ErrorAction SilentlyContinue; $tabs = try { Get-Content $tf.FullName -Raw | ConvertFrom-Json } catch { $null }
    $idleM = ($now - $(if ($tabs._idle) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$tabs._idle).LocalDateTime } else { [datetime]$b.Created })).TotalMinutes   # no tab holder since (browser.mjs sweep)
    if ($tabs._idle -and -not @($tabs.PSObject.Properties | Where-Object Name -notmatch '^_').Count -and $idleM -ge [double](Get-KitSetting 'idle.graceMinutes' 10)) {
      if ($AutoFix) { try { (Get-Process -Id $b.Id).Kill($true) } catch {}; Flag 'INFO' "auto-fixed: closed test browser $k (no tab holder for $([int]$idleM) min)" 'Nothing to do.'; continue }
    }
    $res.Add([pscustomobject]@{ name = "🌐 $(($k -split '\|' | Where-Object { $_ }) -join '·')"; type = 'test browser'; by = (@($tabs.PSObject.Properties | Where-Object { $_.Name -ne '_key' -and $_.Value.agent } | ForEach-Object { $_.Value.agent }) | Select-Object -Unique) -join ', '; gb = & $tree $b })
  }
}
$lanes = try { (Get-Content (Join-Path $swarm 'swarm.config.json') -Raw | ConvertFrom-Json).lanes } catch { @() }
foreach ($p in @($ps | Where-Object { $_.Name -match '^emulator' -and $_.CommandLine -match '-port\s+(\d+)' })) { $port = $Matches[1]; $ln = @($lanes | Where-Object { "$($_.port)" -eq $port })[0]; $nm = if ($ln) { $ln.name } else { "emulator-$port" }
  $ls = try { Get-Content (Join-Path (Get-KitPath phones) "$nm.json") -Raw | ConvertFrom-Json } catch { $null }; $res.Add([pscustomobject]@{ name = "📱 $nm"; type = 'phone'; by = $(if ($ls) { $ls.agent } else { 'no lease' }); gb = & $tree $p }) }
foreach ($wq in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($now - $_.LastWriteTime).TotalMinutes -lt 3 })) {   # queued / booting lanes
  $w = try { Get-Content $wq.FullName -Raw | ConvertFrom-Json } catch { continue }
  $held = @(Get-ChildItem (Get-KitPath phones) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.agent -eq $w.agent })[0]
  $res.Add([pscustomobject]@{ name = "📱 $(if ($held) { $held.lane } elseif ($w.lane) { $w.lane } else { 'next lane' })"; type = 'phone'; by = "$($w.agent) ⏳ $(if ($held) { 'waiting for RAM' } else { 'waiting for a lane' })"; gb = 0 })
}
foreach ($t in @($runningB | Where-Object { $_.kind -ne 'emulator' })) { $p = $byId[[int]$t.pid]; $res.Add([pscustomobject]@{ name = "🔨 $(Split-Path "$($t.dir)" -Leaf) $($t.kind)"; type = 'build'; by = $t.owner; gb = $(if ($p) { [math]::Max((& $tree $p), 0.1) } else { [double]$t.need }) }) }
foreach ($r in $res | Where-Object { $graceRows.ContainsKey($_.name) }) { $r.by = "$($r.by) ⏳ $($graceRows[$r.name]) min" }
# RAM buckets: kit trees first (resources, Claude Code + MCP, kit scripts, env DBs), then _manifest.ram names
$rn = (Get-Content (Join-Path $KitConf.Kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest.ram; foreach ($x in @((Get-KitSetting 'supervise.ramNames' $null).PSObject.Properties | Where-Object { $_ })) { $rn | Add-Member -Force NoteProperty $x.Name $x.Value }   # per key
$bare = { param($p) $p.Name -replace '\.exe$' }
$kd = @(@($KitConf.Kit) + @($KitConf.WorktreeRoots) | Where-Object { $_ })   # kit scripts, env services and builds run from these
foreach ($p in @($ps | Where-Object { $cl = "$($_.CommandLine)"; (& $bare $_) -match $rn.kit -or @($kd | Where-Object { $cl.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count })) { $null = & $tree $p }
foreach ($sv in @((Get-KitValue 'localEnv' $null).envs.PSObject.Properties.Value | ForEach-Object { @($_.services) } | Where-Object { $_.port })) { foreach ($q in @(Get-PortPids ([int]$sv.port))) { if ($byId[[int]$q]) { $null = & $tree $byId[[int]$q] } } }   # env services incl. external DBs
$keep = @{}; $q = $byId[$PID]; for ($i = 0; $q -and $i -lt 64; $i++) { $keep[$q.Id] = 1; $q = $byId[$q.ParentId] }; foreach ($p in $ps) { if ($byId[$p.ParentId] -and (& $bare $byId[$p.ParentId]) -match $rn.kit) { $keep[$p.Id] = 1 } }
$cons = @(Get-KitOrphanConsoles $ps $seen $(if ($rep.cons) { $rep.cons } else { @{} }) $(if ($rep.at) { ($now - [datetime]$rep.at).TotalMinutes } else { 0 }) $keep); $consNow = @{}; foreach ($p in $ps) { if ($seen[$p.Id] -and $p.Name -match '^(cmd|conhost|pwsh|powershell|python\d*|py)(\.exe)?$') { $consNow["$($p.Id)"] = $p.Cpu } }
if ($cons.Count) { $cg = [math]::Round((@($cons | ForEach-Object { $_.WorkingSet }) | Measure-Object -Sum).Sum / 1GB, 1)
  if ($AutoFix) { $cons | ForEach-Object { Stop-SysProcess $_.Id }; Flag 'INFO' "auto-fixed: closed $($cons.Count) orphan kit console(s), $cg GB" 'Nothing to do.' } else { Flag 'WATCH' "ORPHAN CONSOLES: $($cons.Count) idle kit console(s), $cg GB ($((@($cons | ForEach-Object Name | Select-Object -Unique)) -join ', '))" 'supervise -AutoFix closes them (kit-owned only)' } }
$cats = 'browsers', 'apps', 'servers', 'vms', 'windows'   # after the kit trees; the rest is unknown
$cls = { param($p) if ($seen[$p.Id]) { return 'kit' }; $n = & $bare $p; foreach ($k in $cats) { if ($rn.$k -and $n -match $rn.$k) { return $k } }; 'unknown' }
$bk = @{ kit = 0.0; windows = [double]$mem.PoolGB }; foreach ($k in $cats) { if (-not $bk[$k]) { $bk[$k] = 0.0 } }; $apps = @{}
foreach ($p in $ps) { $c = & $cls $p; if ($c -ne 'unknown') { $bk[$c] += $p.WorkingSet / 1GB }; if ($c -notin 'kit', 'windows') { $n = & $bare $p; if (-not $apps[$n]) { $apps[$n] = @{ priv = 0.0; ws = 0.0; cpu = 0.0; cls = $c } }; $apps[$n].priv += $p.Private / 1GB; $apps[$n].ws += $p.WorkingSet / 1GB; $apps[$n].cpu += [double]$p.Cpu } }
$bk.unknown = [math]::Max(0, $mem.TotalGB - $mem.AvailGB - (@($bk.Values) | Measure-Object -Sum).Sum)   # unclassified processes + what no process owns
$unk = @($apps.Keys | Where-Object { $apps[$_].cls -eq 'unknown' -and $apps[$_].ws -ge 0.5 } | Sort-Object { -$apps[$_].ws } | ForEach-Object { "$_ $([math]::Round($apps[$_].ws, 1))" })
$prevA = if ($rep.apps) { $rep.apps } else { @{} }; $dtS = if ($rep.at) { [math]::Max(1, ($now - [datetime]$rep.at).TotalSeconds) } else { 0 }
$top = @($apps.Keys | Sort-Object { -$apps[$_].priv } | Select-Object -First 3 | ForEach-Object { $a = $apps[$_]; $pv = $prevA[$_]
  $mark = if ($pv -and $a.priv - [double]$pv.priv -ge 1) { '📈' } elseif ($dtS -and $pv -and $a.ws -lt 0.1 * $a.priv -and ($a.cpu - [double]$pv.cpu) / $dtS -lt 0.01) { '💤' } else { '' }
  [pscustomobject]@{ name = $_; gb = [math]::Round($a.priv, 1); mark = $mark; cls = $a.cls } })
# ❓ ASK: a big, idle or growing app, once per app; answers (supervise -App -Answer) in .state
$af = Get-KitPath owner-apps; $ans = try { Get-Content $af -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $ans) { $ans = @{} }
foreach ($t in $top) {
  $a = $ans[$t.name]
  if ($a -eq 'close' -and $AutoFix -and $t.cls -in 'browsers', 'apps') { Get-Process -Name $t.name -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }; Flag 'INFO' "closed $($t.name) ($($t.gb) GB): the owner said close" 'Nothing to do.'; continue }
  if ($a -or $t.gb -lt 0.5 -or -not ($t.gb -ge [double](Get-KitSetting 'supervise.askOwnerGB' 2) -or $t.mark)) { continue }
  $ans[$t.name] = 'asked'; Flag 'ASK' "$($t.name) $($t.gb) GB$(if ($t.mark) { " $($t.mark)" }) — close it?" "ask the owner once, record: supervise -App '$($t.name)' -Answer keep|close (never close it without a yes)"
}
Invoke-KitLocked $af { $o = try { Get-Content $af -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $o) { $o = @{} }; foreach ($k in $ans.Keys) { if (-not $o[$k]) { $o[$k] = $ans[$k] } }; $o | ConvertTo-Json | Set-Content $af }   # an answer written meanwhile wins
if ($mem.CommitLimitGB -and $mem.CommitGB -gt 0.95 * $mem.CommitLimitGB) { Flag 'WATCH' "commit $($mem.CommitGB) of $($mem.CommitLimitGB) GB (> 95%), biggest $(@($apps.Keys | Sort-Object { -$apps[$_].priv })[0])" 'allocations may fail: close it or grow the page file' }
$pools = @(@($rep.pools) + @(@{ at = $now.ToString('o'); gb = [double]$mem.PoolGB }) | Where-Object { $_ -and ($now - [datetime]$_.at).TotalHours -lt 2 })
$p0 = $pools[0]; $h0 = ($now - [datetime]$p0.at).TotalHours; if ($h0 -ge 0.5 -and ($mem.PoolGB - $p0.gb) / $h0 -gt 1.5) { Flag 'WATCH' "kernel pools growing $([math]::Round(($mem.PoolGB - $p0.gb) / $h0, 1)) GB/h (now $($mem.PoolGB) GB): possible driver leak" 'find the tag (poolmon / RAMMap), update or remove that driver; a reboot frees it' }
$need = [double](@(@($queue | ForEach-Object { [double]$_.need }) + 0) | Measure-Object -Maximum).Maximum
if ($mem.AvailGB -lt $keepFree + $need -and $need) { Flag 'ACT' "RAM: $([math]::Round($mem.AvailGB, 1)) GB free < floor $keepFree + the largest waiting build $need GB" "Free the biggest: $((@($res | Where-Object { $_.gb } | Sort-Object { -$_.gb } | Select-Object -First 3 | ForEach-Object { "$($_.name) $([math]::Round($_.gb, 1)) GB" })) -join '; ')" }
$deployInfo = @(@(try { (Get-Content (Join-Path (Get-KitPath deploys -Create) 'plan-cache.json') -Raw | ConvertFrom-Json).ready } catch { }) | Where-Object { $_ } | ForEach-Object { "deploy ready: $_ (waits for a person's deploy <env>)" }) + $ownerInfo
$mf = Get-KitPath mem-samples -Create; Add-KitMemSample $mem.AvailGB; $smp = @(Get-Content $mf -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(\S+)\t([\d.]+)' -and (-not $rep.at -or [datetime]$Matches[1] -gt [datetime]$rep.at) } | ForEach-Object { [double](($_ -split "`t")[1]) })
@(Get-Content $mf -ErrorAction SilentlyContinue | Select-Object -Last 200) | Set-Content $mf
# anomalies vs the last round; -Deep (each 6th round): kit lint + hour digest
$state.round = 1 + [int]$state.round; $isDeep = $Deep -or $state.round % 6 -eq 0; $pa = $state.anom; $les = @(); $restarts = @()
foreach ($sf in @(Get-ChildItem (Get-KitPath localenv) -Filter '*.json' -ErrorAction SilentlyContinue)) { $x = try { Get-Content $sf.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $x) { continue }
  if ($x.train) { $les += [pscustomobject]@{ env = $sf.BaseName; key = "$($x.train.id) $($x.train.phase)" } }
  foreach ($sn in @($x.services.Keys)) { $c = @($x.services[$sn].restarts | Where-Object { $_ -and ($now - [datetime]$_).TotalMinutes -lt 30 }).Count; if ($c) { $restarts += [pscustomobject]@{ env = $sf.BaseName; svc = $sn; n = $c } } } }
$logs = @(Get-ChildItem (Get-KitPath localenv-logs) -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-2) -and $_.BaseName -notmatch '-build$|^loop' } | ForEach-Object FullName)
$le2 = @(try { "$($le.out)" | ConvertFrom-Json } catch { @() })
$cur = @{ usedGB = $mem.TotalGB - $mem.AvailGB; cpu = (Get-SysCpu); runs = $runsNow; trains = $les; restarts = $restarts; toolErrors = $toolErr; errorRun = $errRun
  logs = @(Get-KitLogErrors $logs $(if ($pa.logSizes) { $pa.logSizes } else { @{} })); outbox = @(Get-Content (Get-KitPath outbox) -ErrorAction SilentlyContinue).Count
  adopted = @($le2 | ForEach-Object { $ev = $_; @($ev.services | Where-Object state -eq 'up (adopted)' | ForEach-Object { [pscustomobject]@{ env = $ev.env; svc = $_.service; port = $_.port } }) })
  stray = @(git -C $KitConf.Kit status --porcelain 2>$null | Where-Object { $_ -match '^\?\? ([^/\\]+/?)$' } | ForEach-Object { $Matches[1] })
  lint = $(if ($isDeep -and (Within 'deep lint')) { $l = & (Get-Python) -X utf8 $KitCmd.kittool lint $KitConf.Kit --summary --warn --no-flow 2>$null | Select-Object -Last 1; if ("$l" -match '[1-9]\d* problem') { "$l" } }) }
$an = Get-KitAnomalies $cur $pa $now; foreach ($x in $an.flags) { Flag $x.level $x.what $x.action }
$an.state.logSizes = @{}; foreach ($x in $cur.logs) { $an.state.logSizes[$x.path] = $x.size }; $state.anom = $an.state
$state.hist = @(@($state.hist) + @(@{ at = $now.ToString('s'); used = [math]::Round($cur.usedGB, 1); act = @($flags | Where-Object level -eq 'ACT').Count; watch = @($flags | Where-Object level -eq 'WATCH').Count; top = "$(@($flags | Where-Object level -ne 'INFO')[0].what)" -replace '\|', '/' }) | Where-Object { $_ } | Select-Object -Last 12)
if ($isDeep) { @("# supervise digest $($now.ToString('s')) (last hour, newest last)", '', '| Round | RAM used | ACT | WATCH | First flag |', '|---|---|---|---|---|') + @($state.hist | ForEach-Object { "| $($_.at) | $($_.used) GB | $($_.act) | $($_.watch) | $($_.top) |" }) + @('', '## Flags now') + @($flags | ForEach-Object { "- [$($_.level)] $($_.what) -> $($_.action)" }) | Set-Content (Get-KitPath supervise-digest -Create) -Encoding utf8; L "digest: $(Get-KitPath supervise-digest)" }
$report = [pscustomobject]@{ avgFree =$(if ($smp.Count) { ($smp | Measure-Object -Average).Average }); agents = @($ags); mem = $mem; ram = [pscustomobject]$bk; unknown = @($unk); top = @($top); keepFree = $keepFree; disk = "${drive}: $freeGB GB free"; resources = @($res); flags = @($flags); info = $deployInfo; detailFile = (Get-KitPath supervise-report)
  totals = [pscustomobject]@{ agents = $ags.Count; tokensSinceLast = [int](@($ags | Where-Object { $null -ne $_.spend } | ForEach-Object { [math]::Max(0, $_.spend - $_.prevSpend) }) | Measure-Object -Sum).Sum } }
$state.report = @{ spend = $spendNow; at = $now.ToString('s'); apps = $apps; pools = $pools; cons = $consNow }; $state | ConvertTo-Json -Depth 5 | Set-Content $stateFile
$secs = [int]((Get-Date) - $t0).TotalSeconds
if ($script:skipped.Count) { Flag 'WATCH' "sweep hit its $BudgetSeconds s budget: skipped $($script:skipped -join ', ')" 'Partial result: the skipped sections run next round (or raise -BudgetSeconds).' }
L "sweep: $secs s"
$out = [pscustomobject]@{ at = $now.ToString('s'); seconds = $secs; summary = @($lines); flags = @($flags); report = $report }
if ($Json) { $out | ConvertTo-Json -Depth 5; exit 0 }
if ($Brief) {   # the final markdown the coordinator pastes verbatim; the long detail goes to a file read only on ACT
  $w = if ($Width) { $Width } else { try { [Console]::WindowWidth } catch { 0 } }; if ($w -lt 40) { $w = 160 }
  $md = @(Format-KitReport $report -Ascii:$Ascii -Width $w -Agents:$Agents)
  @("# supervise $($now.ToString('s'))") + $md + @('', '## All flags') + @($flags | ForEach-Object { "- [$($_.level)] $($_.what) -> $($_.action)" }) + @('', '## Sweep') + @($lines) | Set-Content (Get-KitPath supervise-report -Create) -Encoding utf8
  $md; $nAct = @($flags | Where-Object level -eq 'ACT').Count; if ($nAct) { "ACT: $nAct line(s): act on each now (orchestrate E2); the next heartbeat re-checks" }; $global:LASTEXITCODE = 0; exit 0
}"=== supervise $($now.ToString('HH:mm')) ==="; $lines
if ($flags.Count) { '--- FLAGS'; $flags | Sort-Object { @{ ACT = 0; WATCH = 1; ASK = 1.5; INFO = 2 }[$_.level] } | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" } } else { '--- no flags: all good' }
$global:LASTEXITCODE = 0
}

# ---- report: a run from its journal (notifications truncate)
function Invoke-Report {
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
$proj = $KitConf.ClaudeProjectDir
$dir = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Join-Path $_.FullName "subagents/workflows/$Run" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dir) { [Console]::Error.WriteLine("wave-report: workflow $Run not found under $proj"); exit 1 }  # swallowed under SilentlyContinue
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
$started = @($ev | Where-Object type -eq 'started'); $doneIds = @($ev | Where-Object type -eq 'result' | ForEach-Object agentId)
$itemOf = { param($l) (([string]$l -split ':', 2)[-1] -split '@')[0] }
$lastDone = @{}; for ($i = 0; $i -lt $started.Count; $i++) { if ($started[$i].agentId -in $doneIds) { $lastDone[(& $itemOf $started[$i].label)] = $i } }
$running = @(for ($i = 0; $i -lt $started.Count; $i++) { $s = $started[$i]; if ($s.agentId -notin $doneIds -and -not ($lastDone[(& $itemOf $s.label)] -gt $i)) { $s.label } })
if (Test-Path (Join-Path (Get-KitPath stopped) $Run)) { $running = @() }

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
  $h = Invoke-HostVerb 'mr.get' $u
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
if (-not $running) {
  $sig = Get-KitPath signals; $mark = Get-KitPath last-retro
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  if ((Test-Path $sig) -and (Get-Content $sig | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since } | Select-Object -First 1)) { 'ACT  retro due: /tidy (E10)' }
}
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

Follow ``$claude/skills/dev-kit/templates.md`` "Bug-fix brief", ``$claude/skills/dev-kit/SKILL.md`` and ``$claude/skills/local-env/SKILL.md`` "Debug locally".
This brief wins where they differ.

Task: $($j.url) — checks $ids to fix. **Reproduce each check on the local env FIRST** (template steps 1-4).
$evidence

## Failed checks
$(($checks | ForEach-Object { "- **$($_.id)** — $($_.screen): $($_.saw)" }) -join "`n")
$(if ($Hints) { "`n## Coordinator notes`n" + (($Hints | ForEach-Object { "- $_" }) -join "`n") + "`n" })
**No deferrals.** Fix every check above (root cause + test) or prove it stale/expected with evidence. Fix only these checks.
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
Phones (app bugs): the local-env APK (``swarm.ps1 build -Local``, ``swarm.ps1 acquire -Agent $Agent -Apk local``); release it when done.
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
$mark = Get-KitPath last-cleanup -Create; $log = Get-KitPath cleanup-log -Create
if ($IfDue -and (Test-Path $mark) -and ((Get-Date) - [datetime](Get-Content $mark -Raw).Trim()).TotalHours -lt 20) { exit 0 }

$now = Get-Date; $freed = 0L; $actions = New-Object System.Collections.ArrayList
function Size($p) { if (Test-Path $p -PathType Leaf) { (Get-Item $p).Length } else { (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
function Gone($path, $why) {
  if (-not (Test-Path $path)) { return }
  $sz = [long](Size $path)
  if (-not $DryRun) { try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { [void]$actions.Add(('  FAILED    {0}  ({1}): {2}' -f $path, $why, $_.Exception.Message)); return } }
  $script:freed += $sz
  [void]$actions.Add(('{0,8:N1} MB  {1}  ({2})' -f ($sz / 1MB), $path, $why))
}
function Old($item, $hours) { ($now - $item.LastWriteTime).TotalHours -gt $hours }

if (-not $WorktreesOnly) {
$profiles = Get-KitPath chrome-profiles
$chromes = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|google chrome|microsoft edge)(\.exe)?$' | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match [regex]::Escape($profiles) }
$qaRuns = @(Get-ChildItem (Get-KitPath qa-runs) -Directory | ForEach-Object Name)
$qaActive = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
  Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 -and ($_.run -in $qaRuns -or "$($_.worktrees)" -match 'chrome:') }).Count
$browserLimitH = if ($qaActive) { 3 } else { 0.5 }
foreach ($c in $chromes | Where-Object { $_.ParentId -notin $chromes.Id }) {
  if (($now - $c.Created).TotalHours -gt $browserLimitH) { [void]$actions.Add("killed headless browser pid $($c.Id) (running $([int]($now - $c.Created).TotalHours) h)"); if (-not $DryRun) { Stop-SysProcess $c.Id } }
}
$inUse = @($chromes | ForEach-Object { if ($_.CommandLine -match 'chrome-profiles[\\/](\d+)') { $Matches[1] } } | Sort-Object -Unique)
foreach ($p in Get-ChildItem $profiles -Directory) { if ($p.Name -notin $inUse -and (Old $p 24)) { Gone $p.FullName 'idle browser profile' } }
$seatsActive = @(Get-ChildItem (Join-Path (Get-KitPath qa-seats) 'seats') -Filter '*.json' | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }).Count
$maxProfiles = [math]::Max(0, [int]$KitConf.MaxBrowserProfiles)
if (-not $seatsActive -and -not $qaActive) {
  # Chrome rewrites "Local State" on use
  $left = @(Get-ChildItem $profiles -Directory | Where-Object { Test-Path $_.FullName } | ForEach-Object {
      $ls = Get-Item (Join-Path $_.FullName 'Local State') -Force
      [pscustomobject]@{ dir = $_; used = $(if ($ls) { $ls.LastWriteTime } else { $_.LastWriteTime }) } } | Sort-Object used -Descending)
  foreach ($x in @($left | Select-Object -Skip $maxProfiles)) { if ($x.dir.Name -notin $inUse) { Gone $x.dir.FullName "browser profile beyond the newest $maxProfiles (cleanup.maxBrowserProfiles)" } }
}

$gradleBusy = @(Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json' |
  ForEach-Object { try { $e = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($e.kind -match 'android|gradle' -and (Get-Process -Id $e.pid)) { $e } } catch {} }).Count
if (-not $gradleBusy) {
  foreach ($d in Get-SysProcs -Name '^java(\.exe)?$' | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' }) {
    if (($now - $d.Created).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($d.CommandLine -match 'Kotlin') { 'Kotlin daemon' } else { 'Gradle daemon' }), $d.Id, ($d.WorkingSet / 1GB))); $script:freed += [long]$d.WorkingSet; if (-not $DryRun) { Stop-SysProcess $d.Id } }
  }
}

# name, max h, why
foreach ($x in @(('sessions', 8, 'expired shared web login'), ('tokens', 72, 'old API token'), ('stopped', 168, 'stop marker > 7 d'), ('evidence', 336, 'loose evidence > 14 d'), ('waves', 336, 'wave report > 14 d'), ('launches', 72, 'launch record > 3 d'), ('briefs', 720, 'briefs > 30 d'), ('docs', 720, 'docs > 30 d'), ('retros', 2160, 'retro report > 90 d'), ('kitty-audits', 2160, 'kit audit report > 90 d'), ('tsbuild', 720, 'tsc cache > 30 d'))) {
  foreach ($f in Get-ChildItem (Get-KitPath $x[0]) -File) { if (Old $f $x[1]) { Gone $f.FullName $x[2] } } }
foreach ($d in 'android-tmp', 'shots') { foreach ($f in Get-ChildItem (Get-KitPath $d) -Recurse -File) { if (Old $f 72) { Gone $f.FullName "$d temp > 3 d" } } }
foreach ($r in Get-ChildItem (Get-KitPath qa-runs) -Directory) {
  if (Old $r (30 * 24)) { foreach ($sub in Get-ChildItem $r.FullName -Recurse -Directory | Where-Object Name -in 'shots', 'evidence', 'scripts') { Gone $sub.FullName 'QA run > 30 d (results/report kept)' } }
}

foreach ($f in Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json') {
  try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (-not (Get-Process -Id $e.pid -ErrorAction SilentlyContinue)) { Gone $f.FullName 'dead gate entry' } } catch {}
}

foreach ($proj in Get-ChildItem (Join-Path $tmp 'claude') -Directory) {
  foreach ($sess in Get-ChildItem $proj.FullName -Directory | Where-Object Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    $newest = Get-ChildItem $sess.FullName -Recurse -File -Force | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $last = if ($newest) { $newest.LastWriteTime } else { $sess.LastWriteTime }
    if (($now - $last).TotalDays -gt 7) { Gone $sess.FullName 'Claude session temp untouched > 7 d' }
  }
}

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
$repos = @{}
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
    $lr = Invoke-KitExe 'git' @('-C', $d, 'ls-remote', '--heads', 'origin', $br) (Get-KitNetTimeout)
    if ($lr.code -ne 0 -or $lr.timedOut -or "$($lr.out)".Trim()) { continue }
    $unpushed = git -C $d log --oneline "@{upstream}..HEAD" 2>$null
    if ($LASTEXITCODE -eq 0 -and $unpushed) { continue }
    $main = "$(git -C $d rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
    $tip = (git -C $d rev-parse HEAD 2>$null)
    if (-not $main -or $tip -notin @(MergedTip $main $br)) { continue }
    [void]$actions.Add("worktree $d ($br merged, remote gone, clean, idle > $WorktreeIdleHours h) -> wt remove")
    if (-not $DryRun) { & $KitCmd.dev wt remove -Dir $d | Out-Null }
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
    [void]$actions.Add("branch $b in $repo (merged at its tip, remote gone) -> deleted")
    if (-not $DryRun) { git -C $repo branch -D $b 2>$null | Out-Null }
  }
}

if (-not $WorktreesOnly) {
foreach ($f in @(@(Get-ChildItem (Get-KitPath logs) -Filter '*.log' -File | ForEach-Object FullName) + (Get-KitPath signals))) {
  if ((Test-Path $f) -and @(Get-Content $f).Count -gt 5000) { if (-not $DryRun) { Invoke-KitLocked $f { $keep = Get-Content $f -Tail 5000; Set-Content $f $keep } }; [void]$actions.Add("rotated $f to 5000 lines") }
}

}
$summary = "$(if ($DryRun) { '[dry run] would free' } else { 'freed' }) $([math]::Round($freed / 1MB, 1)) MB in $($actions.Count) action(s)"
if (-not $DryRun) {
  if (-not $WorktreesOnly) { $now.ToString('s') | Set-Content $mark }
  "$($now.ToString('s')) $summary" | Add-Content $log; $actions | ForEach-Object { "  $_" } | Add-Content $log
}
if (-not $Quiet) { $summary; $actions }
$global:LASTEXITCODE = 0
}

# ---- deploy intest: deployed promoted tasks -> inTest
function Invoke-MarkInTest {
param([switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
$ErrorActionPreference = 'SilentlyContinue'
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }

$cand = [ordered]@{}
$trackFile = Get-KitPath tracking
$track = if ($trackFile -and (Test-Path $trackFile)) { Get-Content $trackFile -Raw | ConvertFrom-Json } else { $null }
if ($track) { foreach ($p in $track.tasks.PSObject.Properties) { $cand[$p.Name] = @{ mrs = @($p.Value.mrs); name = '' } } }
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
$lists = @(Get-KitValue 'trackerLists' @()) | Where-Object { $_ } | Select-Object -Unique
if ($lists.Count) {
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l 'promoted') } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name } } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes a,b as one string
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }

$productTargets = @(Get-KitValue 'productTargets' @())
$pathMemo = @{}
function Get-MrPaths([string]$mr) {
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = Invoke-HostApi "projects/$(Get-HostProject $repo)/merge_requests/$iid/changes"
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

$marked = 0; $wait = 0
foreach ($id in $cand.Keys) {
  $info = Get-TrackerTask $id
  if (-not $info) { continue }
  if (-not (Test-TrackerStatus ([string]$info.status) 'promoted')) { continue }  # never override a person
  $name = if ($info.name) { $info.name } else { $cand[$id].name }
  $short = if ($name.Length -gt 70) { $name.Substring(0, 70) } else { $name }
  $mrs = @($cand[$id].mrs | Where-Object { $_ })
  if (-not $mrs.Count -and $KitConf.TrackerRepos) {
    $tag = "$($KitConf.TrackerTag)$id"
    foreach ($r in @($KitConf.TrackerRepos)) {
      $res = Invoke-HostApi "projects/$(Get-HostProject $r)/merge_requests?search=$([uri]::EscapeDataString($tag))&state=merged&per_page=20"
      foreach ($m in @($res)) { if ($m.iid -and ("$($m.title) $($m.source_branch)" -match [regex]::Escape($tag))) { $mrs += "$r!$($m.iid)" } }
    }
    $mrs = @($mrs | Select-Object -Unique)
  }
  if (-not $mrs.Count) { Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $live = @(); $why = $null
  foreach ($mr in $mrs) {
    $rows = @(& $KitCmd.qa deployed -Mrs $mr -Json -Exclude (Get-NoTestRx) 2>$null | Out-String | ConvertFrom-Json)
    # another product's deploy branch proves nothing
    $ok = @($rows | Where-Object { $_.state -eq 'DEPLOYED' -and $_.target -notmatch (Get-NoTestRx -Lanes) })
    $paths = Get-MrPaths $mr
    $missing = @(); $matched = $false; $need = @()
    foreach ($pt in $productTargets) {
      if ($paths | Where-Object { $_ -match $pt.pathRegex }) { $matched = $true; if (-not ($ok | Where-Object { $_.target -match $pt.targetRegex })) { $missing += $pt.label; $need += $pt.targetRegex } }
    }
    if (-not $matched -and -not $ok.Count) { $missing += 'any test env' }
    if ($ok.Count -and -not $missing.Count) { $live += "$mr on $((($ok | ForEach-Object { $_.target }) -join '+'))"; continue }
    $r0 = $rows | Where-Object { $t0 = $_.target; $_.state -ne 'DEPLOYED' -and (-not $need.Count -or @($need | Where-Object { $t0 -match $_ }).Count) } | Select-Object -First 1
    $why = "$mr not live on: " + $(if ($missing.Count) { $missing -join ', ' } else { 'a test env' }) + $(if ($r0) { " ($($r0.state): $($r0.detail))" } else { '' }); break
  }
  if ($why) { $wait++; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    Set-TrackerStatus $id 'inTest'
    Add-TrackerComment $id ("In test: every MR is deployed on a test env (checked " + [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + " UTC): " + ($live -join '; ') + '.')
    $marked++; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
if (-not $Quiet) { "mark-in-test: $($cand.Count) candidate(s), $marked marked, $wait waiting on a deploy" }
}

# ---- deploy merge: main line into a deploy branch
function Invoke-DeployMerge {
param(
  [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$To, [string]$From,
  [string]$Check, [switch]$Push, [int]$History = 300
)
$ErrorActionPreference = 'Stop'
$rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
$rc = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1
if (-not $From) {
  $From = $rc.target
  if (-not $From) { $h = (git -C $Repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null); if ($h) { $From = ($h -replace '^origin/', '').Trim() } }
  if (-not $From) { $From = 'main' }
  "source branch: $From"
}
# -To: a deploys[] target or branch; tag: tags origin/<From>; trunk (branch = From): no merge
$dep = @($rc.deploys) | Where-Object { $_.target -eq $To -or $_.branch -eq $To } | Select-Object -First 1
if ($dep.tag) {
  $tag = ([string]$dep.tag).Replace('{date}', [datetime]::UtcNow.ToString('yyyyMMddHHmm')); git -C $Repo fetch -q origin $From
  git -C $Repo tag -a $tag "origin/$From" -m "deploy $To"; if ($LASTEXITCODE) { "tag $tag FAILED"; exit 1 }
  if (-not $Push) { "tagged ${tag}: git -C $Repo push origin $tag"; exit 0 }
  git -C $Repo push origin $tag; if ($LASTEXITCODE) { "push of $tag FAILED"; exit 1 }; "pushed $tag"; exit 0
}
if ($dep.branch) { $To = $dep.branch }
if ($To -eq $From) { "trunk: $To deploys from itself, nothing to merge (deploy record, qa.ps1 deployed)"; exit 0 }
$name = 'deploymerge-' + ($To -replace '[^\w]+', '-')
$br = "deploy/$($To -replace '[^\w]+', '-')-$(Get-Date -Format yyyyMMddHHmm)"
$out = & $KitCmd.dev wt new -Repo $Repo -Branch $br -Target $To -Name $name
$wt = ($out | Where-Object { $_ -match '^worktree:\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
if (-not $wt) { throw "dev.ps1 wt new failed: $out" }
"worktree: $wt"
git -C $wt fetch -q origin $From $To
if ($LASTEXITCODE) { "fetch origin $From $To FAILED (exit ${LASTEXITCODE}: wrong -From/-To or offline); worktree kept: $wt"; exit 1 }
$ahead = "$(git -C $wt rev-list --count "origin/$To..origin/$From")".Trim()
if ($LASTEXITCODE -or $ahead -notmatch '^\d+$') { "rev-list origin/$To..origin/$From FAILED: '$ahead'; worktree left at $wt"; exit 1 }  # [int]'' is 0
if ([int]$ahead -eq 0) { & $KitCmd.dev wt remove -Dir $wt -Force | Out-Null; git -C $Repo branch -D $br 2>$null | Out-Null; "nothing to merge: origin/$To has all of origin/$From (worktree removed)"; exit 0 }
$mo = git -C $wt merge --no-ff --no-commit "origin/$From" 2>&1; $mrc = $LASTEXITCODE
$mo | Select-Object -Last 3
$conf = @(git -C $wt diff --name-only --diff-filter=U)
if ($mrc -and -not $conf.Count) { "merge FAILED (not a conflict) in $wt"; exit 1 }
$left = @()
foreach ($f in $conf) {
  $theirs = git -C $wt rev-parse "origin/${To}:$f" 2>$null
  $known = $false
  $fromHas = $null -ne (git -C $wt rev-parse -q --verify "origin/${From}:$f" 2>$null)  # modify/delete: no --theirs
  if ($theirs -and $fromHas) { foreach ($c in @(git -C $wt rev-list -n $History "origin/$From" -- $f)) { if ((git -C $wt rev-parse "${c}:$f" 2>$null) -eq $theirs) { $known = $true; break } } }
  if ($known) { git -C $wt checkout --theirs -- $f; git -C $wt add -- $f; "auto: $f (deploy copy = an older $From version -> took $From)" }
  else { $left += $f }
}
if ($left.Count) { "UNRESOLVED (deploy branch has its own changes): "; $left | ForEach-Object { "  $_" }; "Resolve in $wt, git add, dev.ps1 wt commit -Dir $wt -NoStage, push."; exit 2 }
$msg = "chore(deploy): merge $From into $To" + $(if ($conf.Count) { "`n`nAdd/add conflicts (old squash merge): $To held older $From versions; took $From's." })
& $KitCmd.dev wt commit -Dir $wt -NoStage -Message $msg
if ($LASTEXITCODE) { "commit FAILED (hooks?) in $wt"; exit 1 }
if ($Check) { & $KitCmd.dev check -Dir (Join-Path $wt $Check); if ($LASTEXITCODE) { "compile FAILED - not pushing"; exit 1 } }
if (-not $Push) { "ready: review $wt, then git -C $wt push origin HEAD:$To"; exit 0 }
git -C $wt fetch -q origin $To
git -C $wt merge-base --is-ancestor "origin/$To" HEAD
if ($LASTEXITCODE) { "origin/$To moved while merging - re-run"; exit 1 }
git -C $wt push origin "HEAD:$To"
if ($LASTEXITCODE) { "push FAILED (exit $LASTEXITCODE): nothing reached $To; worktree kept: $wt"; exit 1 }
"pushed $(git -C $wt rev-parse --short HEAD) to $To ($ahead commits from $From)"
}

# ---- learn: signals + LESSONS.md
function Invoke-Learn {
  param(
    [string]$Skill, [ValidateSet('friction', 'failure', 'defect-missed', 'false-positive', 'rule-violation', 'stale-env', 'flaky', 'idea', 'win')][string]$Kind,
    [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
    [switch]$Show, [int]$Last = 30, [switch]$Stats, [switch]$Read, [switch]$History, [string]$Grep,
    [string]$Lesson, [string]$Project, [string]$Fixed, [string]$Bump, [string]$Append, [switch]$Trim, [int]$Max = 40
  )
  $file = Get-KitPath signals -Create
  $mark = Get-KitPath last-retro
  $pub = Join-Path $KitConf.Kit 'LESSONS.md'; $loc = Join-Path $KitConf.Kit 'LESSONS.local.md'
  if ($Show) { if (Test-Path $file) { Get-Content $file -Tail $Last | ForEach-Object { $s = $_ | ConvertFrom-Json; '{0} {1,-13} {2,-15} {3}{4}' -f ([datetime]$s.at).ToString('yyyy-MM-dd HH:mm'), $s.skill, $s.kind, $s.text, $(if ($s.ref) { " [$($s.ref)]" }) } }; return }
  if ($Stats) {
    $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
    $all = if (Test-Path $file) { @(Get-Content $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [datetime]$_.at -gt $since -and $_.kind -ne 'retired' }) } else { @() }
    "signals since last retro ($(if ($since -eq [datetime]::MinValue) { 'never' } else { $since.ToString('yyyy-MM-dd HH:mm') })): $($all.Count)"
    $all | Group-Object skill, kind | Sort-Object Count -Descending | ForEach-Object { '  {0,3}  {1}' -f $_.Count, $_.Name }
    return
  }
  $load = { param($f) if (Test-Path $f) { , [Collections.Generic.List[string]]@(([IO.File]::ReadAllText($f) -replace "`r", '') -split "`n") } else { , [Collections.Generic.List[string]]::new() } }
  $range = { param($L, $name) $s = $L.IndexOf("## $name"); if ($s -lt 0) { return $null }; $e = $s + 1; while ($e -lt $L.Count -and $L[$e] -notmatch '^## ') { $e++ }; , @($s, $e) }
  if ($History) {
    $now = (@($pub, $loc) | Where-Object { Test-Path $_ } | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
    $key = { param($s) ($s -replace '^-\s*', '' -replace '\(fixed in kit\)\s*', '' -replace '\s*\(\d+×\)', '').Trim() }
    $seen = @{}; $rows = [Collections.Generic.List[string]]::new(); $meta = ''
    foreach ($l in @(git -C $KitConf.Kit log --no-merges --date=short '--format=KITLOG %ad %h' -p --unified=0 -- LESSONS.md 2>$null)) {
      if ($l -like 'KITLOG *') { $meta = $l.Substring(7); continue }
      if ($l -notmatch '^-- ') { continue }
      $s = $l.Substring(1); $k0 = & $key $s
      if (-not $k0 -or $seen[$k0] -or $now.Contains($k0)) { continue }
      $seen[$k0] = 1; $rows.Add("$meta $s")
    }
    if (Test-Path $file) { foreach ($j in @(Get-Content $file | Where-Object { $_ -match '"kind":"retired"' } | ForEach-Object { $_ | ConvertFrom-Json })) { $k0 = & $key $j.text; if (-not $seen[$k0]) { $seen[$k0] = 1; $rows.Insert(0, "$(([datetime]$j.at).ToString('yyyy-MM-dd')) $($j.skill) $($j.text)") } } }
    $h = @(if (Test-Path $loc) { $L = & $load $loc; $r = & $range $L 'History'; if ($r) { $L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^- ' } } })
    $all = @(@($rows) + $h | Where-Object { -not $Grep -or $_ -match [regex]::Escape($Grep) } | Select-Object -First $Last)
    if ($all.Count) { $all } else { 'no retired lessons' }
    return
  }
  if ($Read) {
    if (-not $Skill) { 'usage: learn -Read -Skill <skill>'; exit 2 }
    foreach ($f in $pub, $loc) {
      $L = & $load $f; $r = & $range $L $Skill; if (-not $r) { continue }
      $lines = @($L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^(##|###|- )' } | Select-Object -First 41)   # step-0 read cap: 40 lessons
      if ($lines.Count -gt 1) { "$(if ($f -eq $loc) { '(local) ' })$($lines -join "`n")" }
    }
    return
  }
  if ($Lesson -or $Fixed -or $Bump -or $Trim) {
    if (-not $Skill) { 'need -Skill <skill> with -Lesson / -Bump / -Fixed / -Trim'; exit 2 }
    $terms = @(Get-KitValue 'orgTerms' @()) | Where-Object { $_ -and $_ -notmatch '^<' }
    $key = if ($Bump) { $Bump } elseif ($Fixed) { $Fixed } else { $null }
    $orgWord = $Lesson -and @($terms | Where-Object { $Lesson -match [regex]::Escape($_) }).Count
    $inLocal = $key -and (Test-Path $loc) -and ([IO.File]::ReadAllText($loc)).Contains($key) -and -not ([IO.File]::ReadAllText($pub)).Contains($key)
    $f = if ($Project -or $orgWord -or $inLocal) { $loc } else { $pub }
    if ($f -eq $loc -and -not (Test-Path $loc)) { [IO.File]::WriteAllText($loc, "# Kit lessons - org / project (LOCAL ONLY, never published)`nShape of LESSONS.md; learn -Read prints both.`n") }
    if ($orgWord -and -not $Project) { "org term: written to LESSONS.local.md" }
    # concurrent learners lost lines
    $script:learnRc = 0
    $sigF = $file  # $file inside would be ITS -File (case-insensitive)
    Invoke-KitLocked $f {
    $L = & $load $f; while ($L.Count -and $L[$L.Count - 1] -eq '') { $L.RemoveAt($L.Count - 1) }
    $r = & $range $L $Skill
    if (-not $r) { $h = $L.IndexOf('## History'); $at = if ($h -ge 0) { $h } else { $L.Count }; $L.Insert($at, ''); $L.Insert($at, "## $Skill"); $r = & $range $L $Skill }
    $moved = [Collections.Generic.List[string]]::new()
    $idx = { @($r[0]..($r[1] - 1) | Where-Object { $L[$_] -match '^- ' }) }
    if ($Lesson) {
      $line = '- ' + ($Lesson.Trim() -replace '^-\s*', '')
      if ($Project) {
        $ph = "### Project: $Project"; $p = -1; for ($i = $r[0]; $i -lt $r[1]; $i++) { if ($L[$i] -eq $ph) { $p = $i } }
        if ($p -lt 0) { $L.Insert($r[1], $line); $L.Insert($r[1], $ph) } else { $L.Insert($p + 1, $line) }
      } else { $L.Insert($r[0] + 1, $line) }
      $r = & $range $L $Skill
      "lesson added to $(Split-Path $f -Leaf) ## $Skill"
    }
    if ($Bump) {
      $hit = @(& $idx | Where-Object { $L[$_].Contains($Bump) })
      if ($hit.Count -ne 1) { "-Bump must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; $script:learnRc = 1; return }
      $s = $L[$hit[0]]
      if ($Append) { $c = $Append.Trim().TrimEnd('.'); $s = if ($s -match '^(.*?)\.?(\s*\(\d+×\))$') { "$($Matches[1]). $c.$($Matches[2])" } else { "$($s.TrimEnd('.')). $c." } }
      $m = [regex]::Match($s, '\((\d+)×\)')
      $L[$hit[0]] = if ($m.Success) { $s.Remove($m.Index, $m.Length).Insert($m.Index, "($([int]$m.Groups[1].Value + 1)×)") } else { "$s (2×)" }
      "lesson bumped in ## $Skill"
    }
    if ($Fixed) {
      $hit = @(& $idx | Where-Object { $L[$_].Contains($Fixed) })
      if ($hit.Count -ne 1) { "-Fixed must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; $script:learnRc = 1; return }
      $moved.Add(($L[$hit[0]] -replace '^- (\(fixed in kit\) )?', '- (fixed in kit) ')); $L.RemoveAt($hit[0]); $r = & $range $L $Skill
    }
    # "### Project:" lines stay
    while (@(& $idx).Count -gt $Max) {
      $gen = @(& $idx | Where-Object { $i = $_; -not @($r[0]..$i | Where-Object { $L[$_] -like '### *' }).Count })
      $i = if ($gen.Count) { $gen[-1] } else { @(& $idx)[-1] }
      $moved.Add($L[$i]); $L.RemoveAt($i); $r = & $range $L $Skill
    }
    [IO.File]::WriteAllText($f, (($L -join "`n") + "`n"))
    if ($moved.Count) {
      $at = (Get-Date).ToString('s'); $lines = @($moved | ForEach-Object { [ordered]@{ at = $at; skill = $Skill; kind = 'retired'; text = $_; ref = $(if ($Fixed) { 'fixed' } else { 'trim' }); source = 'learn' } | ConvertTo-Json -Compress })
      Invoke-KitLocked $sigF { Add-Content -LiteralPath $sigF $lines -Encoding utf8 }
    }
    "$(Split-Path $f -Leaf) ## ${Skill}: $(@(& $idx).Count) lines (max $Max)$(if ($moved.Count) { "; retired $($moved.Count) (learn -History lists them)" })"
    }
    if ($script:learnRc) { exit $script:learnRc }
    return
  }
  if (-not ($Skill -and $Kind -and $Text)) { 'need -Skill -Kind -Text (or -Read, -Show, -Stats, -History, -Lesson, -Bump, -Fixed, -Trim)'; exit 2 }
  $sig = [ordered]@{ at = (Get-Date).ToString('s'); skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source } | ConvertTo-Json -Compress
  Invoke-KitLocked $file { Add-Content -LiteralPath $file $sig -Encoding utf8 }
  "recorded ($Skill/$Kind)"
}

# ---- decide: decision pauses; only that item waits
function Invoke-Decide {
  param([Parameter(Position = 0)][ValidateSet('ask', 'list', 'answer', 'get', 'wait')][string]$Action = 'list',
    [string]$Run, [string]$Agent, [string]$Item, [string]$Question, [string[]]$Options = @(), [string]$Recommend, [string]$Contracts,
    [string]$Id, [string]$Answer, [string]$By = 'owner', [int]$MaxMinutes = 50, [switch]$Pending, [switch]$Json,
    [ValidateSet('decision', 'envfix')][string]$Kind = 'decision')
  $dir = Get-KitPath decisions -Create
  $get = { param($i) $f = Join-Path $dir "$i.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
  $save = { param($o) $f = Join-Path $dir "$($o.id).json"; Invoke-KitLocked $f { $o | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding utf8 } }
  $note = { param($file, $text) if ($file -and (Test-Path (Split-Path $file))) { Add-Content -LiteralPath $file "`n$text" -Encoding utf8 } }
  switch ($Action) {
    'ask' {
      if (-not ($Agent -and $Question)) { 'usage: decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options "A: ..","B: .." [-Recommend A] [-Contracts <file>]'; exit 2 }
      $opts = @($Options | ForEach-Object { "$_" -split ',(?=\s*[A-Za-z0-9]+\s*:)' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      $o = [ordered]@{ id = "$(if ($Kind -eq 'envfix') { 'e' } else { 'd' })-$(Get-Date -Format yyyyMMddHHmmss)-$($Agent.ToLower() -replace '[^\w-]', '')-$([guid]::NewGuid().ToString('N').Substring(0, 4))"; kind = $Kind; run = $Run; agent = $Agent; item = $Item; question = $Question
        options = $opts; recommend = $Recommend; contracts = $Contracts; status = 'pending'; at = (Get-Date).ToString('s') }
      & $save ([pscustomobject]$o)
      if ($Kind -eq 'envfix') {
        & $note $Contracts "## ENV-FIX NEEDED $($o.id) ($Agent, item $Item)`n$Question`nDone: pending (the coordinator appends it below)"
        "ENV-FIX $($o.id) pending: the coordinator fixes the local env; item $Item waits. Wait: orch.ps1 decide wait -Id $($o.id)"; return
      }
      $null = Test-KitProse -Kind decision-request -Text ("$Question`nOptions:`n$(($opts | ForEach-Object { "- $_" }) -join "`n")`nRecommended: $Recommend")
      & $note $Contracts ("## DECISION NEEDED $($o.id) ($Agent, item $Item)`n$Question`nOptions:`n$(($opts | ForEach-Object { "- $_" }) -join "`n")`nRecommended: $(if ($Recommend) { $Recommend } else { 'none' })`nAnswer: pending (the coordinator appends it below)")
      "DECISION $($o.id) pending: item $Item stops (needs decision); continue your other items. Wait: orch.ps1 decide wait -Id $($o.id)"
    }
    'list' {
      $all = @(Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not $Pending -or $_.status -eq 'pending' })
      if ($Json) { ConvertTo-Json @($all) -Depth 5; return }
      foreach ($d in $all) { "$($d.status.ToUpper()) $($d.id) $($d.run)/$($d.agent) item $($d.item): $($d.question) | options: $(@($d.options) -join ' ; ')$(if ($d.recommend) { " | recommended: $($d.recommend)" })$(if ($d.answer) { " | answer: $($d.answer)" })" }
      if (-not $all.Count) { 'no decisions' }
    }
    'answer' {
      $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
      if (-not $Answer) { 'usage: decide answer -Id <id> -Answer "<words>"'; exit 2 }
      $o.status = 'answered'; $o | Add-Member -Force answer $Answer; $o | Add-Member -Force by $By; $o | Add-Member -Force answeredAt (Get-Date).ToString('s')
      & $save $o
      & $note $o.contracts "DECISION $Id ANSWERED by $($By): $Answer"
      "answered $Id ($($o.agent), item $($o.item)): $Answer"
    }
    'get' { $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }; $o | ConvertTo-Json -Depth 5 }
    'wait' {
      $until = (Get-Date).AddMinutes($MaxMinutes)
      while ($true) {
        $o = & $get $Id; if (-not $o) { "no decision $Id"; exit 1 }
        if ($o.status -eq 'answered') { "ANSWERED $Id`: $($o.answer)"; return }
        if ((Get-Date) -ge $until) { "PENDING $Id (no answer within $MaxMinutes min; wait again)"; exit 1 }
        Start-Sleep -Seconds 30
      }
    }
  }
}

# ---- deploy: batched deploy check; a person always approves
# not a test env: deploys[].production, else productionPattern on the name; -Lanes: + laneApk
function Get-NoTestRx([switch]$Lanes) { $rx = Get-KitSetting 'deploy.productionPattern' '(?i)prod|critical'; $n = @(@(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and ($(if ($null -ne $_.production) { $_.production } else { $_.target -match $rx }) -or ($Lanes -and $_.laneApk)) } | ForEach-Object { [regex]::Escape($_.target) }); "^($($n -join '|'))$" }
# MR / PR URL -> <repo>!<iid>
function ConvertTo-MrRef([string]$m) { if ($u = ConvertFrom-MrUrl $m) { "$(($u.repo -split '/')[-1])!$($u.n)" } else { $m.Trim() } }
# <alias>!<iid> -> <repo name>!<iid>
function Get-CanonMr([string]$m) {
  if ($m -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $m }
  $rp = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $Matches.r -or @($_.aliases) -contains $Matches.r } | Select-Object -First 1
  if ($rp) { "$($rp.name)!$($Matches.i)" } else { $m }
}
function Invoke-Deploy {  param([Parameter(Position = 0)][ValidateSet('plan', 'request', 'record', 'merge', 'intest')][string]$Action = 'plan',
    [string]$Env, [string[]]$Mrs = @(), [string]$Run, [string]$Note, [string]$By = 'owner', [switch]$Json, [string]$Offline, [int]$Days = 14,
    [string]$Repo, [string]$To, [string]$From, [string]$Check, [switch]$Push, [int]$History = 300,
    [switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
  if ($Action -eq 'merge') { Invoke-DeployMerge -Repo $Repo -To $To -From $From -Check $Check -Push:$Push -History $History; return }
  if ($Action -eq 'intest') { Invoke-MarkInTest -Apply:$Apply -Quiet:$Quiet -Task $Task; return }
  $Mrs = @(Split-KitList $Mrs)
  $dd = Get-KitPath deploys -Create; $pf = Join-Path $dd 'pending.json'; $log = Get-KitPath deploy-log -Create
  $fx = if ($Offline) { Get-Content $Offline -Raw | ConvertFrom-Json } else { $null }
  $pendEdit = { param($b) Invoke-KitLocked $pf { $p = if (Test-Path $pf) { Get-Content $pf -Raw | ConvertFrom-Json } else { [pscustomobject]@{ requests = @() } }; & $b $p; $p | ConvertTo-Json -Depth 5 | Set-Content $pf -Encoding utf8 } }   # change pending.json under its lock
  if ($Action -eq 'request') {
    if (-not $Mrs.Count) { 'usage: deploy request -Mrs <repo>!<iid>,... -Run <run> [-Note ..]'; exit 2 }
    $Mrs = @($Mrs | ForEach-Object { ConvertTo-MrRef $_ })
    & $pendEdit { param($p) $p.requests = @(@($p.requests) + [pscustomobject]@{ at = (Get-Date).ToString('s'); run = $Run; mrs = $Mrs; note = $Note }) }
    "requested a deploy for $($Mrs -join ', ') ($Run)"
  }
  if ($Action -eq 'record') {
    if (-not $Env) { 'usage: deploy record -Env <target> [-Mrs ..] [-By ..] [-Note ..]'; exit 2 }
    Invoke-KitLocked $log { Add-Content -LiteralPath $log ([ordered]@{ at = (Get-Date).ToString('s'); target = $Env; mrs = $Mrs; by = $By; note = $Note } | ConvertTo-Json -Compress) -Encoding utf8 }
    $done = @($Mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) })
    if (Test-Path $pf) { & $pendEdit { param($p) foreach ($q in @($p.requests)) { $q.mrs = @(@($q.mrs) | Where-Object { -not $done.Count -or (Get-CanonMr (ConvertTo-MrRef $_)) -notin $done }) }; $p.requests = @(@($p.requests) | Where-Object { @($_.mrs).Count }) } }
    "recorded the deploy of $Env$(if ($Mrs.Count) { " ($($Mrs -join ', '))" }). Next: once qa.ps1 deployed shows them live, orch.ps1 deploy intest -Apply"
    return
  }
  $repos = @(Get-KitValue 'repos' @())
  $targets = @($repos | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and -not $_.laneApk -and $_.target -notmatch (Get-NoTestRx) } | ForEach-Object target | Select-Object -Unique)
  if ($Env) { $targets = @($targets | Where-Object { $_ -eq $Env }) }
  # an MR is checked only against the deploys of its own repo
  $tOf = @{}; foreach ($x in $repos) { $tOf[[string]$x.name] = @($x.deploys | ForEach-Object target) }
  $repoOf = { param($m) ((ConvertTo-MrRef $m) -split '!')[0] -split '/' | Select-Object -Last 1 }
  if ($Action -eq 'request') { $targets = @($targets | Where-Object { $t = $_; @($Mrs | Where-Object { $t -in $tOf[(& $repoOf $_)] }).Count }) }
  $taskOf = @{}; $cand = [ordered]@{}
  $tr = Read-KitTracking
  foreach ($t in $tr.tasks.Values) {
    if ($t.done -and $t.doneAt -and ((Get-Date) - [datetime]$t.doneAt).TotalDays -gt $Days) { continue }
    foreach ($m in @($t.mrs)) { $taskOf[$m] = $t.task; $cand[$m] = 'tracked' }
  }
  $pend = if (Test-Path $pf) { @((Get-Content $pf -Raw | ConvertFrom-Json).requests) } else { @() }
  foreach ($q in $pend) { foreach ($m in @($q.mrs)) { $cand[$m] = "requested by $($q.run)" } }
  foreach ($m in $Mrs) { $cand[$m] = "requested by $Run" }
  # no network = UNKNOWN, no hang
  $rows = @{}; $timedOut = $false; $fail = 'no answer'
  $rowsOf = { param($m) if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] } }
  if ($fx) { foreach ($m in $cand.Keys) { $rows[$m] = @($fx.mrs.$m.rows) } }
  elseif ($cand.Count) {
    $lim = [int](Get-KitSetting 'deploy.planTimeoutSec' 180)
    if (-not $Json) { [Console]::Error.WriteLine("deploy plan: checking $($cand.Count) MR(s) on $(@($targets).Count) test env(s) (max $lim s) ...") }
    $pa = @('-NoProfile', '-NonInteractive', '-File', $KitCmd.qa, 'deployed', '-Mrs', (@($cand.Keys) -join ','), '-Json', '-Exclude', (Get-NoTestRx))
    if ($Env) { $pa += @('-Target', $Env) }
    $r = Invoke-KitExe 'pwsh' $pa $lim
    $timedOut = $r.timedOut
    $txt = "$($r.out)"; $j0 = $txt.IndexOf('[')
    $parsed = if ($j0 -ge 0) { try { @(ConvertFrom-Json $txt.Substring($j0) -NoEnumerate) } catch { $null } } else { $null }
    if ($r.code -notin 0, 1 -or $null -eq $parsed -or -not @($parsed | Where-Object { $_.mr }).Count) { $timedOut = $true; $fail = if ($r.timedOut) { "qa.ps1 deployed timed out after $lim s" } else { "qa.ps1 deployed exit $($r.code): $(("$($r.out)$($r.err)" -split "`n" | Where-Object { $_ } | Select-Object -First 1))" } }
    foreach ($x in @($parsed | ForEach-Object { $_ })) { if ($x.mr) { if (-not $rows.ContainsKey($x.mr)) { $rows[$x.mr] = @() }; $rows[$x.mr] += $x } }
  }
  $trigger = ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower()
  $win = Get-KitSetting 'deploy.minIntervalHours' 4
  $winOf = { param($t) if ($win -is [psobject] -and $win.PSObject.Properties.Name -contains $t) { [double]$win.$t } elseif ($win -is [psobject] -and $win.PSObject.Properties.Name -contains 'default') { [double]$win.default } elseif ($win -is [psobject]) { 4 } else { [double]$win } }
  $logged = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $plan = foreach ($t in $targets) {
    $batch = @(foreach ($m in $cand.Keys) { foreach ($r in @($(if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] }) | Where-Object { $_.target -eq $t -and $_.state -in 'NOT-DEPLOYED', 'MANUAL' })) { [pscustomobject]@{ mr = $m; task = $taskOf[$m]; state = $r.state; detail = $r.detail; why = $cand[$m] } } })
    $last = $null; $src = ''
    $l = @($logged | Where-Object { $_.target -eq $t } | Sort-Object { [datetime]$_.at }) | Select-Object -Last 1
    if ($l) { $last = [datetime]$l.at; $src = "kit log ($($l.by))" }
    $running = $false
    if ($fx) { if ($fx.lastCi.$t) { $ci = [datetime]$fx.lastCi.$t; if (-not $last -or $ci -gt $last) { $last = $ci; $src = 'CI' } } }
    else {
      foreach ($r in $repos) { foreach ($d in @($r.deploys | Where-Object { $_.target -eq $t -and $_.branch -and $_.job })) {
          $p = Get-HostProject $r.name
          foreach ($pl in @(Invoke-HostApi "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=5")) {
            if ($pl.status -in 'running', 'pending', 'created') { $running = $true; continue }
            if ($pl.status -eq 'success') { $at = ([datetime]$(if ($pl.updated_at) { $pl.updated_at } else { $pl.created_at })).ToLocalTime(); if (-not $last -or $at -gt $last) { $last = $at; $src = "CI $($r.name) $($d.branch)" }; break }
          } } }
    }
    $h = & $winOf $t
    $next = if ($last) { $last.AddHours($h) } else { $null }
    $mine = @($cand.Keys | Where-Object { $t -in @($tOf[(& $repoOf $_)]) })
    $unk = @(foreach ($m in $mine) { @(& $rowsOf $m) | Where-Object { $_ -and $_.target -eq $t -and $_.state -eq 'UNKNOWN' } | ForEach-Object { "${m}: $($_.detail)" } })
    $why = if ($unk.Count) { $unk -join '; ' } elseif ($timedOut -and $mine.Count -and -not @($mine | Where-Object { @(& $rowsOf $_) | Where-Object { $_ -and $_.target -eq $t } }).Count) { $fail }
    $status = if ($why -and -not $batch.Count) { 'UNKNOWN' } elseif (-not $batch.Count) { 'NOTHING' } elseif ($running) { 'DEPLOYING' } elseif ($trigger -ne 'ask') { 'READY' } elseif ($next -and (Get-Date) -lt $next) { 'WAIT' } else { 'ASK' }
    [pscustomobject]@{ target = $t; status = $status; trigger = $trigger; last = $(if ($last) { $last.ToString('s') }); lastSource = $src; windowHours = $h; nextAllowed = $(if ($next) { $next.ToString('s') }); mrs = $batch; why = $why; pending = @($pend | ForEach-Object { "$($_.run) $($_.at)" }) }
  }
  if ($Json) { ConvertTo-Json @($plan) -Depth 6; return }
  foreach ($p in $plan) {
    $when = switch ($p.status) { 'WAIT' { " until $(([datetime]$p.nextAllowed).ToString('yyyy-MM-dd HH:mm')) (one deploy per $($p.windowHours) h)" } 'ASK' { ': ask the owner ONCE with this batch' } 'READY' { ": waits for a person's 'deploy $($p.target)' (deploy.trigger owner: nobody asks)" } 'UNKNOWN' { ": the deploy check failed: $($p.why) (plan again)" } 'DEPLOYING' { ': a deploy pipeline runs now (wait, then plan again)' } default { '' } }
    "DEPLOY $($p.target): $($p.status)$when | last $(if ($p.last) { "$(([datetime]$p.last).ToString('yyyy-MM-dd HH:mm')) ($($p.lastSource))" } else { 'unknown' })"
    foreach ($b in $p.mrs) { "  - $($b.mr)$(if ($b.task) { " task $($b.task)" }) $($b.state): $($b.detail) [$($b.why)]" }
  }
  if (-not @($plan).Count) { 'no test deploy targets in kit.local.json repos[].deploys' }
}

# ---- health: SessionStart hook; no network
function Invoke-Health {
param([switch]$Flow, [switch]$Fetch)
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
if ($Flow -or $Fetch) {
  if ($Fetch -and (Test-Path (Join-Path $kit '.git'))) { git -C $kit fetch --quiet 2>$null }
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
  if ($parts) { $msgs += "kit: " + ($parts -join '; ') }
} else {
  $msgs += "kit: $kit is not a git clone of the kit repo (install: README Install)"
}
$legacy = Join-Path $kit '.claude-runtime'
if ((Test-Path $legacy) -and -not (Get-Item $legacy).LinkType) { $msgs += "old runtime at $($legacy): move it once no agents run: pwsh -File $($KitCmd.orch) setup -Migrate" }
$mv = @((Get-Content (Join-Path $kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._paths.legacy.moved.PSObject.Properties | Where-Object { $v = ([string]$_.Value).TrimEnd('/'); (Test-Path (Join-Path (Get-KitPath runtime) $v)) -or (Test-Path (Join-Path (Split-Path (Get-KitPath signals)) $v)) })
if ($mv.Count) { $msgs += "renamed state under its old name ($(($mv | ForEach-Object Value) -join ', ')): pwsh -File $($KitCmd.orch) setup -Migrate once no agents run" }
# workflows die with their session
$hook = $null
if ([Console]::IsInputRedirected) { try { $hook = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch {} }
if (-not $hook -or $hook.source -ne 'compact') {
  $stopped = @(& $KitCmd.orch launch -List -Brief 2>$null)
  if ($stopped.Count) { $msgs += "after a restart: $($stopped -join '; '). Do: & '$($KitCmd.orch)' recover (resume calls, resume briefs, qa.ps1 finalize lines; orchestrate E3); finished ones: orch.ps1 launch -Done -RunId <id>. No heartbeat runs in this session: start one (orchestrate E1)" }
}
if ($py) {
  $lint =& $py -X utf8 $KitCmd.kittool lint $kit --summary --warn --no-flow 2>$null
  if ($lint) { $msgs += ($lint -join ' ') }
  & $py -X utf8 $KitCmd.kittool port --check 2>$null | ForEach-Object { $msgs += $_ }
}
foreach ($n in @(& $KitCmd.orch nudge | ForEach-Object { try { ($_ | ConvertFrom-Json).systemMessage } catch { } } | Where-Object { $_ })) { $msgs += $n }
if ($msgs) {
  $text = ($msgs -join ' | ') + ' (orchestrate Events)'
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
}

# ---- nudge: retro / audit due (part of health)
function Invoke-Nudge {
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$msgs = @()

$file = Get-KitPath signals; $mark = Get-KitPath last-retro; $guard = Get-KitPath guard-log
if ((Test-Path $file) -or (Test-Path $guard)) {
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  $n = @(Get-Content $file | Where-Object { $_ -notmatch '"kind":"retired"' -and $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Get-Content $guard | Where-Object { $_ -match '^(\S+)\t' -and [datetime]$Matches[1] -gt $since }).Count
  if (($n + $g) -ge 15) { $msgs += "Kit learning: $n signals + $g guard blocks since the last retro. Run /tidy to turn them into lessons and rule updates." }
}

$every = 7
try { $c = Get-Content (Join-Path $kit 'skills/dev-kit/kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($null -ne $c.kitAudit.everyDays) { $every = [double]$c.kitAudit.everyDays } } catch {}
if ($every -gt 0) {
  $am = Get-KitPath last-kitty-audit
  $last = $null; if (Test-Path $am) { try { $last = [datetime]((Get-Content $am -Raw).Trim()) } catch {} }
  if (-not $last -or ((Get-Date) - $last).TotalDays -ge $every) {
    $busy = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
        Where-Object { $_.agent -eq 'kitty' -and $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 }).Count
    if (-not $busy) { $msgs += "Kit audit due (last $(if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }), every $every days): spawn one kitty agent (orchestrate E13)." }
  }
}

if ($msgs) {
  $text = $msgs -join ' | '
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
}

# ---- setup: install / repair (idempotent)
function Invoke-Setup {
param([switch]$Exclude, [switch]$Quiet, [switch]$Migrate, [switch]$WriteLocal)
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

if ($Migrate) {
  $map = (Get-Content (Join-Path $kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._paths
  $oldRt = Join-Path $kit $map.legacy.runtimeDir; $newRt = Get-KitPath runtime
  # an existing folder $dst gets the entries it lacks; $src goes once empty
  function Move-Into($src, $dst) { if (-not (Test-Path $dst)) { Move-Item $src $dst } elseif ((Get-Item $src).PSIsContainer) { foreach ($e in Get-ChildItem $src -Force) { if (-not (Test-Path (Join-Path $dst $e.Name))) { Move-Item $e.FullName $dst } }; if (-not @(Get-ChildItem $src -Force).Count) { Remove-Item $src -Force } } }
  # never while launches, live board entries, leases or seats exist
  $live = @()
  $live += @(& $KitCmd.orch launch -List -Brief 2>$null | Where-Object { $_ })
  foreach ($rt in @($oldRt, $newRt) | Where-Object { Test-Path $_ }) {
    $readLive = { param($sub) @(Get-ChildItem (Join-Path $rt $sub) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $o = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($o) { $o | Add-Member -Force NoteProperty name $_.BaseName; $o } } | Where-Object { (Test-KitHolder $_) -ne $false }) }
    $live += @(& $readLive 'work/board' | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 } | ForEach-Object { "board: $($_.agent) ($($_.run))" })
    $live += @(& $readLive 'work/phones' | ForEach-Object { "phone lease: $($_.name)" })
    $live += @(& $readLive 'work/qa-seats/seats' | Where-Object { ((Get-Date) - [datetime]$_.since).TotalHours -lt 3 } | ForEach-Object { "QA seat: $($_.name)" })
  }
  if ($live.Count) { "migrate refused: something still runs - $(($live | Select-Object -First 6) -join '; '). Run it again once nothing runs."; exit 1 }
  if ((Test-Path $oldRt) -and -not ((Get-Item $oldRt).LinkType)) {
    Move-Into $oldRt $newRt; if (Test-Path $oldRt) { "kept $oldRt (entries already in $newRt)" }
    if (-not (Test-Path $oldRt)) { New-DirLink -Path $oldRt -Target $newRt; "runtime: $oldRt -> $newRt (a link stays at the old path for one release)" }
  }
  foreach ($p in $map.legacy.durable.PSObject.Properties) {
    $src = Join-Path $kit ([string]$p.Value).TrimEnd('/'); if (-not (Test-Path $src)) { continue }
    $dst = Get-KitPath $p.Name -Create; Move-Into $src $dst
    if (Test-Path $src) { "kept $src ($dst exists: merge by hand)" } else { "state: $($p.Value) -> $dst" }
  }
  foreach ($p in @($map.legacy.moved.PSObject.Properties)) {
    $root = if ($map.runtime.($p.Name)) { $newRt } else { Join-Path $kit $map.stateDir }
    $src = Join-Path $root ([string]$p.Value).TrimEnd('/'); $dst = Get-KitPath $p.Name; if (-not (Test-Path $src)) { continue }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Move-Into $src $dst
    if (Test-Path $src) { "kept $src ($dst exists: merge by hand)" } else { "renamed: $($p.Value) -> $dst" }
  }
  $ll = Join-Path $kit 'LESSONS.local.md'
  foreach ($sk in Get-ChildItem (Join-Path $kit 'skills') -Directory) {
    foreach ($n in 'LESSONS.local.md', 'HISTORY.local.md') {
      $src = Join-Path $sk.FullName $n; if (-not (Test-Path $src)) { continue }
      $body = @((Get-Content $src) | Where-Object { $_ -match '^(- |### )' -or $_ -match '^## Project' } | ForEach-Object { $_ -replace '^## Project', '### Project' })
      if ($body.Count) { Add-Content $ll ("`n## $($sk.Name)$(if ($n -like 'HISTORY*') { ' (history)' })`n" + ($body -join "`n")) -Encoding utf8 }
      Move-Item $src (Join-Path (Get-KitPath cache -Create) "migrated-$($sk.Name)-$n") -Force; "lessons: skills/$($sk.Name)/$n -> LESSONS.local.md"
    }
  }
  $ren = (Get-Content (Join-Path $kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest.renamed
  foreach ($p in @($ren.PSObject.Properties)) {
    $o = [regex]::Escape($p.Name); $n = [string]$p.Value
    foreach ($f in @(Get-ChildItem (Get-KitPath launches) -Filter '*.json' -ErrorAction SilentlyContinue)) {
      $t = [IO.File]::ReadAllText($f.FullName); $t2 = [regex]::Replace($t, "workflows([\\/]+)$o\.js", "workflows`$1$n.js")
      if ($t2 -ne $t) { [IO.File]::WriteAllText($f.FullName, $t2); "launch record $($f.Name): $($p.Name).js -> $n.js" }
    }
    $sf = Get-KitPath signals; $from = '"skill":"' + $p.Name + '"'; $to = '"skill":"' + $n + '"'
    if ((Test-Path $sf) -and $p.Name -notmatch '\.') { Invoke-KitLocked $sf { $t = [IO.File]::ReadAllText($sf); $t2 = $t.Replace($from, $to); if ($t2 -ne $t) { [IO.File]::WriteAllText($sf, $t2); "learning signals: skill $($p.Name) -> $n" } } }
    if ((Test-Path $ll) -and $p.Name -notmatch '\.') { $t = [IO.File]::ReadAllText($ll); $t2 = [regex]::Replace($t, "(?m)^## $o(\s*(\(history\))?)$", "## $n`$1"); if ($t2 -ne $t) { [IO.File]::WriteAllText($ll, $t2); "LESSONS.local.md: ## $($p.Name) -> ## $n" } }
  }
  'migrated. The old paths are gone (runtime: a link for one release). Nothing else changed.'
  exit 0
}
if (-not (Test-Path (Join-Path $kit '.git'))) { Write-Warning "$kit is not a git clone: install per README ""Install""" }
else {
  if ((git -C $kit config core.hooksPath) -ne '.githooks') { git -C $kit config core.hooksPath .githooks; Say 'git: core.hooksPath = .githooks (pre-commit, pre-push, post-merge on)' }
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
if ((Test-Path (Join-Path $kit '.claude-runtime')) -and -not (Get-Item (Join-Path $kit '.claude-runtime')).LinkType) { Say "old layout found: orch.ps1 setup -Migrate (once nothing runs)" }
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
[Console]::Error.WriteLine("Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you.")
exit 2
}

# ---- prepush: block local files, org terms, stale ports
function Invoke-PrePush {
$ErrorActionPreference = 'Stop'
$root = $KitConf.Kit
$zero = '0' * 40
$updates = @($(if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }) -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_ -split '\s+'; [pscustomobject]@{ lsha = $p[1]; rsha = $p[3] } } | Where-Object { $_.lsha -ne $zero })
$hits = @()

$revs = foreach ($u in $updates) { if ($u.rsha -eq $zero) { git -C $root rev-list $u.lsha --not --remotes } else { git -C $root rev-list "$($u.rsha)..$($u.lsha)" } }
$revs = @($revs | Where-Object { $_ } | Select-Object -Unique)

if ($revs.Count) {
  $files = @($revs | ForEach-Object { git -C $root diff-tree --no-commit-id --name-only --diff-filter=ACMR -r $_ } | Where-Object { $_ } | Select-Object -Unique)
  if ($files.Count) {
    # pwsh piping appends CR
    $ign = @(for ($i = 0; $i -lt $files.Count; $i += 100) { git -C $root check-ignore --no-index -- @($files[$i..([math]::Min($i + 99, $files.Count - 1))]) 2>$null })
    foreach ($f in $ign) { $hits += "LOCAL FILE  $f is git-ignored or local-only (.gitignore / .git/info/exclude) but a pushed commit carries it: git rm --cached it and amend" }
  }
}

$terms = @()
$cfg = $KitConf.ConfigFile
if ($env:KIT_ORG_TERMS) { $terms = @($env:KIT_ORG_TERMS -split ',' | Where-Object { $_.Trim() }) }
elseif (Test-Path $cfg) { try { $terms = @((Get-Content $cfg -Raw | ConvertFrom-Json).orgTerms | Where-Object { $_ }) } catch { $hits += "CONFIG      $cfg is not valid JSON: $_" } }
if (-not $terms.Count) { Write-Host 'pre-push: no orgTerms in skills/dev-kit/kit.local.json - org-term scan skipped' }
else {
  $py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
  if (-not $py) { $hits += 'PYTHON      python is not installed: the org-term scan (kittool.py lint) cannot run' }
  else {
    $out = Join-Path ([IO.Path]::GetTempPath()) "kit-prepush-$PID.json"
    & $py -X utf8 $KitCmd.kittool lint $root --warn --no-flow --org-terms ($terms -join ',') --json $out | Out-Null
    if (-not (Test-Path $out)) { $hits += "LINT        kittool.py lint failed (exit $LASTEXITCODE, no JSON): the org-term scan of the working tree did not run" }
    $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
    foreach ($p in $probs | Where-Object code -eq 'ORG-TERM') { $hits += "ORG TERM    $($p.where): $($p.problem)" }
    $other = @($probs | Where-Object code -ne 'ORG-TERM')
    if ($other.Count) { Write-Host "pre-push: warning: kit-lint reports $($other.Count) other problem(s) (python skills/orchestrate/kittool.py lint)" }
  }
  $rx = @($terms | ForEach-Object { $t = $_.Trim(); $stem = $t.TrimEnd('*'); [pscustomobject]@{ term = $t; rx = [regex]::new('(?<![\w-])' + [regex]::Escape($stem) + $(if ($t.EndsWith('*')) { '' } else { '(?![\w-])' }), $(if ($stem -cne $stem.ToLower()) { 'None' } else { 'IgnoreCase' })) } })
  foreach ($r in $revs) {
    foreach ($line in @(git -C $root show --format= --unified=0 --no-color $r)) {
      if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
      foreach ($x in $rx) { if ($x.rx.IsMatch($line)) { $hits += "ORG TERM    commit $($r.Substring(0, 8)) adds ""$($x.term)"": $($line.Substring(0, [math]::Min(120, $line.Length)))"; break } }
    }
  }
}

$py3 = Get-Python
if ($py3) { $pc = & $py3 -X utf8 $KitCmd.kittool port --check 2>&1; if ($LASTEXITCODE) { $hits += "PORTS       stale generated ports: $("$pc".Trim()) - run kittool.py port and commit" } }

if ($hits.Count) {
  Write-Host "pre-push: BLOCKED - $($hits.Count) problem(s):" -ForegroundColor Red
  $hits | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
  Write-Host 'Fix them (the kit is public and generic: org values belong in *.local.* files or localOnly paths), then push again.'
  exit 1
}
exit 0
}

# ---- precommit: regenerate + stage README graph and ports
# never stage the user's changes
function Test-UnstagedEdits([string]$Root, [string]$Path) { [bool]@(git -C $Root status --porcelain -- $Path | Where-Object { $_.Length -gt 1 -and $_[1] -ne ' ' }).Count }
function Invoke-PreCommit {
  $root = $KitConf.Kit
  $py = Get-Python
  if (-not $py -or -not (Get-Command $py -ErrorAction SilentlyContinue)) { Write-Host 'pre-commit: BLOCKED - python is not installed (kittool lint / flow / port cannot run)' -ForegroundColor Red; exit 1 }
  $userEdits = Test-UnstagedEdits $root 'README.md'
  & $py -X utf8 $KitCmd.kittool flow --readme $root | Out-Null
  if ($LASTEXITCODE) { Write-Host "pre-commit: kittool flow failed (exit $LASTEXITCODE)"; exit 1 }
  if ($userEdits) { Write-Host 'pre-commit: README.md has unstaged edits: graph sections regenerated but NOT staged (git add README.md yourself if they belong)' }
  elseif (@(git -C $root status --porcelain -- README.md).Count) { git -C $root add -- README.md; Write-Host 'pre-commit: README graph sections regenerated and staged' }
  & $py -X utf8 $KitCmd.kittool port | Out-Null
  if ($LASTEXITCODE) { Write-Host "pre-commit: BLOCKED - kittool port failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }
  $gen = @('.codex', '.agents', 'GEMINI.md') | Where-Object { Test-Path (Join-Path $root $_) }
  if (@(git -C $root status --porcelain -- @gen).Count) { git -C $root add -A -- @gen; Write-Host 'pre-commit: ports regenerated and staged' }
  $chk = & $py -X utf8 $KitCmd.kittool port --check 2>&1
  if ($LASTEXITCODE) { Write-Host "pre-commit: BLOCKED - ports still differ after regeneration: $chk" -ForegroundColor Red; exit 1 }
  $out = Join-Path ([IO.Path]::GetTempPath()) "kit-precommit-$PID.json"
  & $py -X utf8 $KitCmd.kittool lint $root --no-flow --json $out | Out-Null
  if ($LASTEXITCODE -gt 1 -or -not (Test-Path $out)) { Write-Host "pre-commit: BLOCKED - kittool lint did not run (exit $LASTEXITCODE, no JSON)" -ForegroundColor Red; exit 1 }
  $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
  if ($probs.Count) { Write-Host "pre-commit: BLOCKED - kit-lint: $($probs.Count) problem(s):" -ForegroundColor Red; $probs | Select-Object -First 25 | ForEach-Object { Write-Host "  $($_.code) $($_.where): $($_.problem)" }; exit 1 }
  exit 0
}

# SessionStart hooks never surface an error: one warning line, the detail in the hook log
function Write-KitHookError([string]$Verb, $Err) { try { Add-Content (Get-KitPath hook-log -Create) "$((Get-Date).ToString('s'))`t$Verb`t$Err`t$($Err.InvocationInfo.PositionMessage -replace '\s+', ' ')" } catch {}; "kit: $Verb failed ($($Err.Exception.Message)); see $(Get-KitPath hook-log)"; exit 0 }
if ($MyInvocation.InvocationName -ne '.') {  # dot-sourced (tests): functions only
  trap { if ($__verb -in 'health', 'cleanup') { Write-KitHookError $__verb $_ } else { break } }
  if ($__verb -in '-h', '--help', 'help', '-?') { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
  switch ($__verb) {
    'board' { Invoke-KitVerb Invoke-Board $__rest }
    'learn' { Invoke-KitVerb Invoke-Learn $__rest }
    'launch' { Invoke-KitVerb Invoke-Launch $__rest }
    'track' { Invoke-KitVerb Invoke-Track $__rest }
    'supervise' { Invoke-KitVerb Invoke-Supervise $__rest }
    'report' { Invoke-KitVerb Invoke-Report $__rest }
    'bugbrief' { Invoke-KitVerb Invoke-BugBrief $__rest }
    'cleanup' { Invoke-KitVerb Invoke-Cleanup $__rest }
    'deploy' { Invoke-KitVerb Invoke-Deploy $__rest }
    'decide' { Invoke-KitVerb Invoke-Decide $__rest }
    'recover' { Invoke-KitVerb Invoke-Recover $__rest }
    'budget' { Invoke-KitVerb Invoke-Budget $__rest }
    'health' { Invoke-KitVerb Invoke-Health $__rest }
    'nudge' { Invoke-KitVerb Invoke-Nudge $__rest }
    'setup' { Invoke-KitVerb Invoke-Setup $__rest }
    'guard-sendmessage' { Invoke-KitVerb Invoke-GuardSendMessage $__rest }
    'prepush' { Invoke-KitVerb Invoke-PrePush $__rest }
    'precommit' { Invoke-KitVerb Invoke-PreCommit $__rest }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }
  }
}
