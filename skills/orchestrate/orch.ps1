<#
orch.ps1: the coordinator's commands in one file (orchestrate SKILL.md: steps, Events, state table). Run from pwsh 7:
  & <kit>/skills/orchestrate/orch.ps1 <verb> [args]
Verbs:
  board join|beat|check|leave|show ...     the agent board (every agent's step 0)
  learn -Skill -Kind -Text | -Read -Skill | -Lesson | -Bump | -Fixed | -Trim | -Show | -Stats   signals + LESSONS.md
  launch -RunId -Script -ArgsJson | -Done -RunId | -List [-Brief]   workflow launch records (resume after a restart)
  track add|remove|show|run|rebuild ...    task <-> MRs; promoted when all merged; merge order
  supervise [-Session <id>] [-AutoFix] [-Brief] [-Json] [-MarkStopped <run>] [-Takeover]   the heartbeat
  report -Run <id> [-Detail]               a workflow run from its journal (MR states, findings, verdicts)
  bugbrief -Task <id> -Agent <code> -Repos <r>,..   bug-fix brief (reproduce locally first) + /dev-wave args
  cleanup [-DryRun] [-Quiet] [-IfDue] [-WorktreesOnly] [-WorktreeIdleHours <h>]
  deploy plan|request|record|merge|intest ...   batched deploy check, deploy-branch merge, inTest after deploy
  decide ask|list|answer|get|wait ...      decision pauses (needs decision -> the owner answers -> the item resumes)
Inputs: kit.local.json (lib.ps1), runtime state (board, launches, decisions, deploys, waves), .state/tracking.json.
Outputs: text; JSON with -Json where offered. Exit codes: 0 ok · 1 problem found / not answered / blocked · 2 usage error.
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---------------------------------------------------------------- board: the agent board (join / beat / check / leave / show)
# Shared agent board: every agent (in any workflow or session) says what it's working on, so concurrent agents see each other,
# duplicates are caught at once, and two agents never write the same worktree.
#
#   $B = '<workspace>/.claude/skills/orchestrate/orch.ps1 board'
#   & $B join  -Agent A1 -Area "checkout form + view" -Items "FEAT-12,FEAT-13" -Claims <wt root>/a1-backend,<wt root>/a1-frontend [-Run checkout-v2] [-Contracts <file>] [-Resume]
#         (-Claims = anything exclusive: worktree paths, emulator serials like emulator-5556, browser ports like chrome:9601)
#         (-Resume = you continue a stopped agent's work (RESUME_BRIEF): take over its entry when you claim the same worktrees)
#         -> prints the other active agents, warnings, the contracts file to follow, and LAST the SESSION token (keep it)
#   & $B beat  -Session <token> [-Status "testing web"]   # heartbeat; do it when you start a build/test or push (cheap)
#   & $B show  [-Run checkout-v2]                           # who is doing what right now (+ warnings)
#   & $B check -Worktree <dir> -Session <token>             # is anyone else writing here? exit 1 = stop and tell the coordinator
#   & $B leave -Session <token> [-Status done]
#
# Entries go stale after 20 min without a heartbeat. On join, an entry of the same agent id in the same run is:
#   reused     - same claims and a heartbeat in the last 2 min (a quick re-join): the same SESSION token comes back (REJOIN);
#   taken over - its holder is gone (its pid is not running and no heartbeat for 3 min), or you pass -Resume and claim the same
#                worktrees: it is marked left and you get a new session (TAKEOVER). If its holder was still alive after all, its
#                next beat prints TAKEN OVER and exits 1, and `check` names you as the other writer: it must stop without writing.
# Warnings:
#   DUPLICATE  - the same agent id is active in two sessions (e.g. a resumed copy without -Resume): the newer one must stop.
#   CLAIM      - another active agent claims the same worktree / phone / port.
#   AREA       - another active agent in the same run lists overlapping items.
function Invoke-Board {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('join', 'beat', 'show', 'check', 'leave')][string]$Action,
  [string]$Agent, [string]$Area = '', [string]$Items = '', [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree, [switch]$Resume
)
$dir = Get-KitPath board -Create
$staleMin = 20
function All { foreach ($f in Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue) { try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; $e | Add-Member -Force NoteProperty file $f.FullName; $e } catch {} } }
function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
# paths are resolved; plain claims (emulator-5556, chrome:9601) only lowercased (GetFullPath made 'chrome:9601' <cwd>\chrome:9601)
function Norm($p) { if (-not $p) { return }; if ($p -match '[\\/]|^[A-Za-z]:') { [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } else { $p.ToLower() } }   # paths or plain claims (emulator-5556, chrome:9601)
# "86abc F2, X1, X2" -> 86abc F2, 86abc X1, 86abc X2: bug-fix items list check ids after their task id, and two bug tasks both have an X1
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
  $act | Sort-Object run, agent | ForEach-Object { '  {0,-6} {1,-14} {2,-34} {3} | beat {4}' -f $_.agent, $_.run, ("$($_.area)".Substring(0, [math]::Min(34, "$($_.area)".Length))), $_.status, ([datetime]$_.beat).ToString('HH:mm') }
}

switch ($Action) {
  'join' {
    if (-not $Agent) { throw 'join needs -Agent' }
    $now = Get-Date
    $myClaims = @($Worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $same = @(All | Where-Object { $_.agent -eq $Agent -and "$($_.run)" -eq "$Run" -and $_.status -ne 'left' })
    $notes = @()
    # quick re-join (same agent, run and claims, heartbeat < 2 min): keep that session token instead of a second entry
    $rejoin = $same | Where-Object { -not $Resume -and ($now - [datetime]$_.beat).TotalMinutes -lt 2 -and ((@($_.worktrees | ForEach-Object { Norm $_ } | Where-Object { $_ } | Sort-Object -Unique) -join '|') -eq ($myClaims -join '|')) } |
      Sort-Object { [datetime]$_.joined } -Descending | Select-Object -First 1
    if ($rejoin) { $tok = $rejoin.session; $joined = $rejoin.joined; $notes += "REJOIN: same agent, run and claims within 2 min - reusing session $tok" }
    else { $tok = "$Agent-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)); $joined = $now.ToString('o') }
    # takeover: the old holder is gone (pid not running and no beat for 3 min; the pid is the shell that ran join, often short-lived,
    # so it alone proves nothing), or -Resume claims the same worktrees. It is marked left; its next beat tells it to stop.
    foreach ($o in @($same | Where-Object { $_.session -ne $tok })) {
      $alive = $o.pid -and [bool](Get-Process -Id ([int]$o.pid) -ErrorAction SilentlyContinue)
      $age = ($now - [datetime]$o.beat).TotalMinutes
      $shared = @(@($o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -and $_ -in $myClaims })
      $why = if (-not $alive -and $age -ge 3) { "no heartbeat for $([int]$age) min" } elseif ($Resume -and $shared.Count) { "-Resume on $($shared -join ', ')" } else { $null }
      if (-not $why) { continue }
      try {
        $j = Get-Content $o.file -Raw | ConvertFrom-Json
        $j.status = 'left'; $j | Add-Member -Force NoteProperty takenOverBy $tok; $j | Add-Member -Force NoteProperty takenOverAt $now.ToString('o')
        $j | ConvertTo-Json | Set-Content $o.file
        $notes += "TAKEOVER: replaced session $($o.session) ($why; joined $(([datetime]$o.joined).ToString('HH:mm')), last beat $(([datetime]$o.beat).ToString('HH:mm')))"
      } catch { $notes += "could not take over session $($o.session): $_" }
    }
    $me = [ordered]@{ agent = $Agent; session = $tok; run = $Run; area = $Area; items = $Items; worktrees = @($Worktrees); contracts = $Contracts
                      status = 'working'; joined = $joined; beat = $now.ToString('o'); pid = $PID }
    $me | ConvertTo-Json | Set-Content (Join-Path $dir "$tok.json")
    $act = @(Active | Where-Object session -ne $tok)
    Print $act
    $notes | ForEach-Object { $_ }
    $w = @(Warnings ([pscustomobject]$me) $act)
    if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" } }
    $c = if ($Contracts) { $Contracts } else { (Active | Where-Object { $_.run -eq $Run -and $_.contracts } | Select-Object -First 1).contracts }
    if ($c -and (Test-Path $c)) { "CONTRACTS ($c) - re-read before every push:"; Get-Content $c | Select-Object -First 60 | ForEach-Object { "  $_" } }
    "SESSION $tok   (pass -Session $tok to beat / check / leave)"
  }
  'beat' {
    $f = Join-Path $dir "$Session.json"; if (-not (Test-Path $f)) { throw "unknown session $Session - join first" }
    $me = Get-Content $f -Raw | ConvertFrom-Json
    if ($me.status -eq 'left' -and $me.takenOverBy) { "TAKEN OVER: session $($me.takenOverBy) replaced $Session at $(([datetime]$me.takenOverAt).ToString('HH:mm')). Stop without writing and tell the coordinator."; exit 1 }
    $me.beat = (Get-Date).ToString('o'); if ($Status) { $me.status = $Status }
    $me | ConvertTo-Json | Set-Content $f
    $w = @(Warnings $me @(Active)); if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" }; exit 1 }
  }
  'show' { $act = @(Active | Where-Object { -not $Run -or $_.run -eq $Run }); Print $act; @($act | ForEach-Object { Warnings $_ $act }) | Sort-Object -Unique | ForEach-Object { "  ! $_" } }
  'check' {
    $mine = Norm $Worktree
    $others = @(Active | Where-Object { $_.session -ne $Session -and (@($_.worktrees | ForEach-Object { Norm $_ }) -contains $mine) })
    if ($others) { $others | ForEach-Object { "OTHER WRITER: $($_.agent) (session $($_.session), status $($_.status), beat $(([datetime]$_.beat).ToString('HH:mm')))" }; exit 1 }
    'ok: no other active agent claims this worktree'; exit 0
  }
  'leave' {
    $f = Join-Path $dir "$Session.json"
    if (Test-Path $f) { $me = Get-Content $f -Raw | ConvertFrom-Json; $me.status = 'left'; $me.beat = (Get-Date).ToString('o'); $me | ConvertTo-Json | Set-Content $f }
    "left ($Session)"
  }
}
}

# ---------------------------------------------------------------- launch: workflow launch records (resume after a restart)
# Restartable workflow launches. A session restart (usage limit, crash, a new terminal) stops every workflow it ran, and the
# coordinator then had to rebuild each launch by hand (which script, which args, which QA run, the heartbeat). The coordinator
# records every launch right after the Workflow tool returns its run id; at SessionStart kit.ps1 health lists the runs that never
# completed, with what is needed to resume them, plus QA run folders whose autoclose watcher is gone.
#
#   $O = '<workspace>/.claude/skills/orchestrate'
#   & $O launch -RunId <runId> -Script <kit>/workflows/dev-wave.js -ArgsJson '<the exact args JSON>'   # step 3 / step 7, after launch
#   & $O launch -RunId <runId> -Script <path> -ArgsFile <args.json> [-RunDir <qa run>] [-Session <id>]
#   & $O launch -Done -RunId <runId>     # E5: the workflow finished (any outcome)
#   & $O launch -List [-Hours 24]         # unfinished launches (resume lines) + orphaned autoclose run folders
#   & $O launch -List -Brief              # the same in one line per item (kit.ps1 health, SessionStart)
#
# Record: <runtime>/work/launches/<runId>.json = { runId, script, args, argsFile, runDir, session, at, completed }. The args are
# stored in full so the resume is exact: Workflow({ scriptPath: <script>, resumeFromRunId: <runId>, args: <args from the record> }).
# runDir defaults to args.runDir (test-and-close). orch.ps1 cleanup prunes records older than 3 days.
function Invoke-Launch {
param(
  [string]$RunId, [string]$Script, [string]$ArgsJson, [string]$ArgsFile, [string]$RunDir, [string]$Session,
  [switch]$Done, [switch]$List, [switch]$Brief, [int]$Hours = 24
)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
$dir = Get-KitPath launches -Create
$RunId = "$RunId".Trim().Trim('''"')
$safe = { param($id) ($id -replace '[^\w.-]', '_') }

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
    runDir = $(if ($RunDir) { $RunDir } else { $null }); session = $(if ($Session) { $Session } else { $null }); at = (Get-Date).ToString('o'); completed = $null }
  $f = Join-Path $dir "$(& $safe $RunId).json"
  $rec | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $f -Encoding utf8
  Write-Host "[launch] recorded $RunId ($(Split-Path $Script -Leaf)) -> $f"
  exit 0
}

# -List: launches with no completion in the last -Hours, and QA run folders whose autoclose watcher stopped
$since = (Get-Date).AddHours(-$Hours)
$out = @()
foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime) {
  try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
  if ($r.completed) { continue }
  $at = try { [datetime]$r.at } catch { $f.LastWriteTime }
  if ($at -lt $since) { continue }
  $name = Split-Path ([string]$r.script) -Leaf
  $out += if ($Brief) { "$name $($r.runId) (resumeFromRunId $($r.runId), args $($f.FullName))" }
          else { "STOPPED? $name run $($r.runId) launched $($at.ToString('yyyy-MM-dd HH:mm'))$(if ($r.runDir) { ", runDir $($r.runDir)" })`n  resume: Workflow({ scriptPath: '$($r.script)', resumeFromRunId: '$($r.runId)', args: <args in $($f.FullName)> })`n  finished already: orch.ps1 launch -Done -RunId $($r.runId)" }
}
# autoclose (qa-kit) writes <run>/autoclose.log every few minutes while it watches; a recent run whose log went quiet with codes
# still unhandled has lost its watcher (it dies with the session or its -MaxHours)
$qa = Get-KitPath qa-runs
foreach ($d in Get-ChildItem -LiteralPath $qa -Directory -ErrorAction SilentlyContinue) {
  $rj = Join-Path $d.FullName 'run.json'
  if (-not (Test-Path -LiteralPath $rj) -or (Get-Item -LiteralPath $rj).LastWriteTime -lt $since) { continue }
  $log = Join-Path $d.FullName 'autoclose.log'
  if (-not (Test-Path -LiteralPath $log)) { continue }   # never started here (skipClose runs, retests): nothing to re-arm
  if ((Get-Item -LiteralPath $log).LastWriteTime -gt (Get-Date).AddMinutes(-15)) { continue }   # still watching
  $codes = @(try { (Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json).items | ForEach-Object { [string]$_.code } } catch { })
  $handled = @(Get-Content -LiteralPath (Join-Path $d.FullName 'autoclose_done.txt') -ErrorAction SilentlyContinue)
  $open = @($codes | Where-Object { $_ -and $handled -notcontains $_ })
  if (-not $open.Count) { continue }
  $out += if ($Brief) { "autoclose gone for $($d.Name) ($($open.Count) unhandled)" }
          else { "ORPHANED autoclose: $($d.FullName) - $($open.Count) item(s) not handled ($($open -join ', ')); restart it (orchestrate step 7) once the workflow runs again" }
}
$out | ForEach-Object { $_ }
exit 0
}

# ---------------------------------------------------------------- track: tracker task <-> MRs; promoted once all merge; merge-after order
# Tracker automation: tie a tracker task to its MRs, and let the supervisor (-AutoFix) move the task when they are all merged —
# so nobody has to watch pipelines and flip statuses by hand.
#
#   $T = '<workspace>/.claude/skills/orchestrate/orch.ps1 track'
#   & $T add  -Task abc123 -Mrs backend!101,frontend!202 [-OnMerged "for review,promoted"]   # add MRs (repeatable; merges lists)
#   & $T add  -Task abc124 -Discover                 # find the task's MRs itself (<tracker tag><id>, e.g. CU-<id>, in title/branch) on every run;
#                                                   # completes only once the task is already in review (its agent sets that after all MRs)
#   & $T add  -Task abc125 -MergeAfter 'frontend!203>backend!102'   # schedule the web merge only once the API MR merged
#   & $T remove -Task abc125 [-Mrs frontend!203]  # forget a wrongly registered task (or only those MRs and their merge-after pairs)
#   & $T show [-Detail]           # open tracked tasks and MR states (-Detail: finished ones too)
#   & $T -Rebuild [-Force]        # tracking file lost? recreate it (also `rebuild`): every open (or merged in the last 14 d) MR in
#                                 # trackerRepos whose branch/title carries <tracker tag><id> becomes a -Discover task again (done
#                                 # when all its MRs merged and the tracker status is already promoted or later); -Force merges into
#                                 # an existing file. Without trackerRepos / a tracker tag it writes an empty file and says why.
#   & $T run [-Detail]            # check now: when every MR of a task is merged, set the statuses in order, comment once, mark done
#                                 # (prints actions only; HOLD lines are counted unless -Detail - supervise uses -Detail)
#
# -Task is the tracker id without its tag (CU-abc123 -> abc123); a placeholder ('0', 'none', '-') is refused. An MR whose title carries
# <tracker tag><id> of another task is registered under the title's task (the title wins over -Task and the branch name).
# Holds (no status change) while a still-running wave's saved report (<runtime>/work/waves/*.json) has a blocking review finding on one of the MRs.
# MR refs: <repo>!<iid> in the kit.local.json "gitlabGroup" (or <group/repo>!<iid>). Default -OnMerged = "promoted" (logical tracker statuses
# are mapped by tracker.statuses; a backend's own status names work too).
# Config (skills/dev-kit/kit.local.json): gitHost, gitlabGroup, trackerRepos (searched by -Discover), repoAliases (short names agents use,
# e.g. {"api":"backend"}), reposRoot (main checkouts, used to schedule -MergeAfter merges), tracker (dev-kit/lib.ps1). MRs through dev-kit/lib.ps1 Invoke-HostApi (GitLab / GitHub).
# File: <kit>/tracking.local.json (durable, git-ignored; Get-KitPath tracking): { tasks: {<task>: ...}, automerge: {<ref>: time} }
# (automerge = merge-when-green intents from devtools.py merge, re-armed by `run`). orch.ps1 supervise -AutoFix calls `run` every round.
function Invoke-Track {
param([Parameter(Position = 0)][ValidateSet('add', 'remove', 'show', 'run', 'rebuild')][string]$Action, [switch]$Rebuild, [switch]$Force, [string]$Task, [string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @(), [string]$Wave, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
if ($Rebuild) { $Action = 'rebuild' }
# a throw does not stop this script ($ErrorActionPreference = 'SilentlyContinue' suppresses it): refuse with Fail
function Fail([string]$m) { [Console]::Error.WriteLine("track: $m"); exit 1 }
if (-not $Action) { Fail 'usage: orch.ps1 track add|remove|show|run|rebuild ... (or -Rebuild)' }
$wavesDir = Get-KitPath waves
$script:holds = 0
# HOLD = waiting by design (review/fix still running): listed with -Detail, otherwise only counted at the end of `run`
function Hold($s) { if ($Quiet) { return }; if ($Detail) { $s } else { $script:holds++ } }
function TaskStatus($id) { try { [string](Get-TrackerTask $id).status } catch { '' } }
$group = $KitConf.GitlabGroup
$groupRx = if ($group) { '(?:' + [regex]::Escape($group) + '/)?' } else { '' }
$alias = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $alias[$p.Name] = [string]$p.Value } }
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($group) { "$group/$repo" } else { $null } }
# agents write refs loosely (web!6122, api!8201, a full MR URL): normalise to <repo>!<iid>
function NormRef($r) {
  $r = "$r".Trim().Trim("'", '"')   # pwsh -File passes 'a!1','b!2' with the quotes
  if ($r -match "://[^/]+/$groupRx(?<repo>[\w./-]+?)/-/merge_requests/(?<iid>\d+)") { $r = "$($Matches.repo)!$($Matches.iid)" }
  if ($r -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$' -and $alias[$Matches.repo]) { $r = "$($alias[$Matches.repo])!$($Matches.iid)" }
  $r
}
function Load($t) { (Read-KitTracking).tasks[$t] }
# a task id as stored: no tag (CU-abc -> abc), no quotes; '' for a placeholder ('0' once registered an MR under task 0 and every
# promote failed on /task/0)
function NormTask($id) {
  $id = "$id".Trim().Trim("'", '"').Trim()
  if ($KitConf.TrackerTag) { $id = $id -replace "^(?i)$([regex]::Escape($KitConf.TrackerTag))", '' }
  if ($id -match '^(0+|-+|none|null|undefined|n/?a|tbd|task|id)?$') { return '' }
  $id
}
# the task an MR's title (else its branch) names with <tracker tag><id>; '' when neither does or the MR cannot be read
function TaskOfMr($ref) {
  if (-not $KitConf.TrackerTag -or $ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return '' }
  $proj = ProjPath $Matches.repo; if (-not $proj) { return '' }
  $m = Invoke-HostApi "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)"
  foreach ($s in @($m.title, $m.source_branch)) { if ("$s" -match "(?i)$([regex]::Escape($KitConf.TrackerTag))(?<id>[A-Za-z0-9]+)") { return (NormTask $Matches.id) } }
  ''
}
# open/merged MRs of a task in trackerRepos: <tracker tag><task> in the title (GitLab search), or in the source branch of an open MR
# (the MR search has no branch scope: in=source_branch was ignored, so branch-only tags were never found)
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
# an unmerged producer registered for this MR (any task's mergeAfter '<this>><producer>'): re-arming it would break the merge order
function ProducerOpen($proj, $iid) {
  foreach ($x in @((Read-KitTracking).tasks.Values)) {
    foreach ($pair in @($x.mergeAfter)) {
      $p = "$pair" -split '>', 2; if ($p.Count -ne 2) { continue }
      if ((NormRef $p[0]) -match '^(?<r>[\w./-]+)!(?<i>\d+)$' -and $Matches.i -eq $iid -and ($proj -ieq $Matches.r -or $proj -like "*/$($Matches.r)") -and (MrState (NormRef $p[1])) -ne 'merged') { return $true }
    }
  }
  $false
}
$script:doneFields = 'doneAt', 'liveOn', 'liveCheckedAt', 'qaCovered'   # state of a finished task (supervise: deploy / QA); cleared on reopen
function Save($o) {
  # another process (an agent's `add`) may have written since we loaded: keep its MRs / merge orders instead of overwriting them
  Update-KitTracking {
    param($all)
    $cur = $all.tasks[$o.task]
    if ($cur) {
      # done/reopen written by another process since we loaded wins: a `run` must not finish a task an `add` just reopened, and an
      # `add` that brought no new MRs must not reopen what a `run` just finished
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
# "<label>" of a still-running dev-wave stage (build:/review:/fix:<agent>) whose agent owns this MR, else $null.
# Reads <runtime>/work/waves/<run>.json (supervise refreshes them for every running workflow before calling `track run`).
function InFlight($ref) {
  if ($ref -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $null }
  $pat = "/$([regex]::Escape($Matches.r))/-/merge_requests/$($Matches.i)(\D|$)"
  foreach ($f in Get-ChildItem $wavesDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-12) }) {
    $w = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if (-not @($w.running).Count) { continue }
    foreach ($p in $w.agents.PSObject.Properties) {
      if (@($p.Value.mrs | ForEach-Object { "$($_.url)$_" }) -match $pat) {
        $lbl = @($w.running) | Where-Object { $_ -match "^(build|review|fix|ship|ci):$([regex]::Escape($p.Name))$" } | Select-Object -First 1
        if ($lbl) {
          # the saved report goes stale once its workflow ends (supervise only refreshes RUNNING workflows): refresh before holding
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
function MrState($ref) {
  if ($ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return 'bad-ref' }
  $proj = ProjPath $Matches.repo
  if (-not $proj) { return 'bad-ref (use <group/repo>!<iid>, or set "gitlabGroup" in kit.local.json)' }
  $m = Invoke-HostApi "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)"
  if (-not $m) { return 'unknown' }
  if ($m.state -eq 'opened' -and $m.head_pipeline.status -in 'failed', 'canceled') { return "opened (pipeline $($m.head_pipeline.status))" }
  # a conflicting MR never merges, even with merge-when-green set (a sibling MR rewrote the same lines): someone must rebase it
  if ($m.state -eq 'opened' -and ($m.has_conflicts -or $m.detailed_merge_status -eq 'conflict')) { return 'opened (conflict)' }
  $m.state
}
switch ($Action) {
  'rebuild' {
    $tf = Get-KitPath tracking
    if ((Test-Path $tf) -and -not $Force) { "tracking file exists ($tf, $(@((Read-KitTracking).tasks.Keys).Count) task(s)): nothing to rebuild (-Force merges discovered tasks into it)"; return }
    $tag = $KitConf.TrackerTag; $repos = @($KitConf.TrackerRepos)
    if (-not $tag -or -not $repos.Count) {
      Update-KitTracking { param($t) }   # an empty, valid file: track run / supervise work again; tasks come back as agents `add` them
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
    # the MR title's task wins: a placeholder or a branch-name id (a reused branch) once registered MRs under the wrong task
    $titled = @($refs | ForEach-Object { TaskOfMr $_ } | Where-Object { $_ } | Select-Object -Unique)
    if ($titled.Count -eq 1 -and $titled[0] -ne $Task) { "NOTE: the MR title names task $($titled[0]) - registering under it$(if ($Task) { ", not $Task" })"; $Task = $titled[0] }
    elseif ($titled.Count -gt 1 -and (-not $Task -or $titled -notcontains $Task)) { Fail "add: the MRs name different tasks in their titles ($($titled -join ', ')): register each task with its own MRs" }
    if (-not $Task) { Fail "add needs a real -Task id (got '$given'; the tracker id without its tag, as in the MR title)" }
    $o = Load $Task; if (-not $o) { $o = @{ task = $Task; mrs = @(); onMerged = @($OnMerged -split '\s*,\s*'); done = $false; created = (Get-Date).ToString('s') } }
    $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)   # normalised before counting: a known MR given as a URL is not new
    $before = @($o.mrs).Count
    if ($Discover -and @($KitConf.TrackerRepos).Count) { $refs = @(@($refs) + @(Find-TaskMrs $Task) | Select-Object -Unique) }   # now, not only at the next run
    $o.mrs = @(@($o.mrs) + $refs | Where-Object { $_ } | Select-Object -Unique)
    if ($PSBoundParameters.ContainsKey('OnMerged')) { $o.onMerged = @($OnMerged -split '\s*,\s*') }
    if ($Discover) { $o.discover = $true }
    if ($Wave) { $o.wave = $Wave }   # a dev-wave still fixing this task (started before the task existed): hold until it ends
    if ($MergeAfter) {
      $o.mergeAfter = @(@($o.mergeAfter) + @($MergeAfter -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique)
      # a consumer already scheduled (merge-when-green) before its order was registered would merge first: cancel it, merge-after re-schedules it
      foreach ($pair in @($MergeAfter -split '\s*,\s*' | Where-Object { $_ })) {
        $p = $pair -split '>', 2; if ($p.Count -ne 2 -or (NormRef $p[0]) -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { continue }
        $pp = ProjPath $Matches.repo; $ci = $Matches.iid; if (-not $pp -or (MrState (NormRef $p[1])) -eq 'merged') { continue }
        $enc = $pp -replace '/', '%2F'; $m = Invoke-HostApi "projects/$enc/merge_requests/$ci"
        if ($m.merge_when_pipeline_succeeds) { $null = Invoke-HostApi "projects/$enc/merge_requests/$ci/cancel_merge_when_pipeline_succeeds" -Method POST; "NOTE: cancelled the scheduled merge of $(NormRef $p[0]): it merges after $(NormRef $p[1])" }
      }
    }
    # a finished task stays finished unless new MRs were added; reopened, its deploy/QA state belonged to the earlier MRs
    if ($o.done -and @($o.mrs).Count -gt $before) { $o.done = $false; $o.reopenedAt = (Get-Date).ToString('o'); foreach ($k in $script:doneFields) { $o.Remove($k) } }
    elseif (-not $o.done) { $o.done = $false }
    Save $o; $s = Load $Task   # print what is stored (other processes' MRs and merge orders merged in): a re-add shows the real state
    "tracking $Task : $(@($s.mrs) -join ', ')$(if (@($s.mergeAfter).Count) { ' | merge-after: ' + (@($s.mergeAfter) -join ', ') }) -> on all merged: $(@($s.onMerged) -join ' -> ')$(if ($Discover -and -not @($s.mrs).Count) { ' (no MR found yet: every run looks again)' })"
  }
  'remove' {
    $raw = "$Task".Trim().Trim("'", '"')   # an exact stored key first (legacy entries: '0', 'CU-<id>'), else the normalised id
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
    # Re-arm merge-when-green that GitLab dropped: a push after scheduling (rebase, review fix) cancels it, and the MR then sits
    # open with a green pipeline. Intents come from devtools.py merge (.state/tracking.json "automerge"); merged/closed ones are forgotten.
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
        # no head pipeline (yet): GitLab would merge a merge-when-green request at once - wait for the next round
        if (-not $m.head_pipeline) { continue }
        # a registered producer still open (-MergeAfter added after this was scheduled), or its review still running: merge-after merges it later
        if ((ProducerOpen $amProj $iid) -or (InFlight "$(($amProj -split '/')[-1])!$iid")) { continue }
        $fl = @{ squash = 'true'; should_remove_source_branch = 'true' }
        if ($m.head_pipeline.status -ne 'success') { $fl.merge_when_pipeline_succeeds = 'true' }
        $r = Invoke-HostApi "projects/$enc/merge_requests/$iid/merge" -Method PUT -Fields $fl
        "re-armed merge-when-green for $ref (it was dropped, probably by a push after scheduling): $(if ($r.state -eq 'merged') { 'merged' } elseif ($r.merge_when_pipeline_succeeds) { 'scheduled' } else { 'FAILED - check the MR' })"
      }
      # forget only what was checked here: devtools.py may have added an intent meanwhile
      $gone = @($am.Keys | Where-Object { -not $keep.ContainsKey($_) })
      if ($gone) { Update-KitTracking { param($t) foreach ($r in $gone) { $t.automerge.Remove($r) } } }
    }
    foreach ($o in @((Read-KitTracking).tasks.Values)) {
      if ($o.done) { continue }
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      # ordered merges: '<dependent>><dependency>' -> when the dependency merged, schedule the dependent (merge-when-green) - before the discover/status gates below, which skip a task that is still in progress
      foreach ($pair in @($o.mergeAfter)) {
        if ($pair -notmatch '^(?<dep>[^>]+)>(?<on>.+)$') { continue }
        $dep = $Matches.dep.Trim(); $on = $Matches.on.Trim()
        # never merge an MR whose dev-wave agent is still in build/review/fix: the wave's own ship step merges it after a clean review
        # (merge-after once merged a dependent MR mid-review and a blocking regression landed on the target branch)
        $owner = InFlight $dep
        if ($owner) { Hold "HOLD $($o.task): $dep waits for its review ($owner still running)"; continue }
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$') {
          $wt = Join-Path $KitConf.ReposRoot (($Matches.repo -split '/')[-1])   # a checkout of that repo (devtools reads its origin remote)
          $res = if (-not (Test-Path $wt)) { "no checkout at $wt - set ""reposRoot"" in kit.local.json" } else { python $KitCmd.devtools merge $wt $Matches.iid 2>&1 }
          if (-not $Quiet) { "MERGE-AFTER $($o.task): $on merged -> $dep : $res" }
        }
        if ($o.mrs -notcontains $dep) { $o.mrs = @(@($o.mrs) + $dep) }   # only the dependent: the producer may be another task's MR
      }
      if ($o.discover) {
        # a config gap, not an MR problem: only worth saying when nothing was registered by hand either
        if (-not @($KitConf.TrackerRepos).Count -and -not @($o.mrs).Count) { if (-not $Quiet) { "CONFIG $($o.task): -Discover needs ""trackerRepos"" in kit.local.json (or register MRs: orch.ps1 track add -Task $($o.task) -Mrs <repo>!<iid>)" } }
        $o.mrs = @(@($o.mrs) + @(Find-TaskMrs $o.task) | Where-Object { $_ } | Select-Object -Unique)
        Save $o
        if (-not @($o.mrs).Count) { continue }
        $cur = TaskStatus $o.task
        if (-not (Test-TrackerStatus $cur 'review')) {
          # Its agent may still be shipping (more MRs to come) - or it shipped but failed to set the review status (a wrong
          # tracker command can leave a task untouched for hours). Once every discovered MR has been merged for 20 min, complete it.
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
      # hold while a still-running wave has a blocking review finding on one of these MRs (its fix MR is on the way)
      $held = @(Get-ChildItem $wavesDir -Filter '*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) } | ForEach-Object {
          $w = Get-Content $_.FullName -Raw | ConvertFrom-Json
          if (@($w.running).Count) { & $KitCmd.orch report -Run $w.run *> $null; $w = Get-Content $_.FullName -Raw | ConvertFrom-Json }   # refresh: the wave may have ended
          if (@($w.running).Count) { @($w.openFindings) | Where-Object { $_.severity -eq 'blocking' -and $_.mr -match '/(?<r>[\w.-]+)/-/merge_requests/(?<i>\d+)' -and $o.mrs -contains "$($Matches.r)!$($Matches.i)" } } })
      if ($held) { Hold "HOLD $($o.task): blocking review finding still being fixed ($($held[0].mr))"; continue }
      # merged but its agent's review/fix round is still running: findings may still turn into a follow-up MR
      if ($o.wave) {
        $wf = Join-Path $wavesDir "$($o.wave).json"; & $KitCmd.orch report -Run $o.wave *> $null
        # no report = no journal for that run (wrong or expired id): not running, else the task would hold forever
        if (-not (Test-Path $wf)) { if (-not $Quiet) { "CONFIG $($o.task): wave $($o.wave) has no journal/report (wrong or expired run id) - not holding for it" } }
        elseif (@((Get-Content $wf -Raw | ConvertFrom-Json).running).Count) { Hold "HOLD $($o.task): wave $($o.wave) is still fixing it"; continue }
      }
      $busy = @($o.mrs | ForEach-Object { InFlight $_ } | Where-Object { $_ } | Select-Object -Unique)
      if ($busy) { Hold "HOLD $($o.task): MRs merged but $($busy -join ', ') still in review/fix"; continue }
      # never move a task backwards: QA may already have closed it (then later fix MRs registered on it merge)
      $now = TaskStatus $o.task
      if (Test-TrackerStatus $now 'closed', 'inTest') { $o.done = $true; Save $o; if (-not $Quiet) { "DONE $($o.task): all MRs merged; status '$now' kept (already past promoted)" }; continue }
      $setFailed = $false
      foreach ($s in $o.onMerged) { try { $null = Set-TrackerStatus $o.task $s } catch { $setFailed = $true; if (-not $Quiet) { "ATTENTION $($o.task): could not set status '$s' (retried next run): $_" }; break } }
      if ($setFailed) { continue }   # not done: the next run retries (no "status set" comment either)
      $gitHost = if ($KitConf.GitHost) { $KitConf.GitHost } else { 'gitlab.com' }
      $urls = @($o.mrs | ForEach-Object { if ($_ -match '^(?:(?<g>[\w./-]+)/)?(?<r>[\w.-]+)!(?<i>\d+)$') { "https://$gitHost/$(if ($Matches.g) { $Matches.g } else { $group })/$($Matches.r)/-/merge_requests/$($Matches.i)" } })
      try { $null = Add-TrackerComment $o.task "All MRs merged: $($urls -join ' , '). Status set to $($o.onMerged[-1]) automatically by the coordinator's tracker." } catch {}
      # the task must also carry its agent's solution + testing steps (an agent that got the tracker syntax wrong posted nothing)
      $cmts = @(try { Get-TrackerComments $o.task } catch {}) | ForEach-Object { [string]$_.text } | Where-Object { $_ -notmatch '^All MRs merged' }
      if (-not ($cmts | Where-Object { $_ -match '(?i)how to test|test(ing)? (steps|guide|instructions)|tester guide|live check' })) {
        # agents often get the comment wrong: post the live checks from the dev agent's own report (workflow journal) instead of flagging
        $proj = $KitConf.ClaudeProjectDir
        $steps = @(Get-ChildItem $proj -Recurse -Filter 'journal.jsonl' -File | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) } | Sort-Object LastWriteTime -Descending | ForEach-Object {
            foreach ($line in Get-Content $_.FullName) {
              $j = try { $line | ConvertFrom-Json } catch { $null }
              # agents list item ids (B1) in done, not task ids: also match the agent by one of this task's MR urls
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
    # a task's MRs all merged (also when a person merged them after its wave ended): its worktrees and local branches are
    # finished now - sweep them once, in the background (the wave/QA flows sweep at their own end; nothing else triggers it)
    if ($script:merged) {
      $cl = ({ & $KitCmd.orch cleanup @args })
      Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-File', $cl, '-WorktreesOnly', '-WorktreeIdleHours', '0', '-Quiet' | Out-Null
    }
  }
}
}

# ---------------------------------------------------------------- supervise: the coordinator heartbeat (flags ACT / WATCH / INFO)
# Coordinator's periodic check-up (what a human lead would look at every 10-15 minutes). Prints a compact digest and a list
# of FLAGS with a suggested action each. The coordinator (main session) runs it on a loop and acts on the flags.
#
#   & <workspace>/.claude/skills/orchestrate/orch.ps1 supervise [-Session <claude session id>] [-AutoFix] [-Brief] [-Json]
#   -Brief: only the flags, one line each (auto-fixed INFO lines counted), or one line "ok: N running, mem X%" when nothing needs you -
#           the cheap form for a /loop heartbeat. Without it: the full digest + flags.
#
# Looks at:
#   - workflows of this project (journal.jsonl): agents running / finished, per-agent idle time (transcript not written)
#   - agent board: active, stale (no heartbeat, not left), duplicates, claim clashes
#   - memory gate: queue length, longest wait, running builds, repeated build failures per project
#   - machine: RAM pressure, disk space; guard blocks in the last hour; contracts file age
#   - phones: agents lease them (swarm.ps1); with -AutoFix orphan leases are released and unleased idle phones shut down after 10 min
# FLAG levels: ACT (do something now), WATCH (check again next round), INFO.
function Invoke-Supervise {
param([string]$Session, [switch]$Json, [int]$IdleMin = 25, [switch]$AutoFix,   # -AutoFix: perform SAFE fixes itself (idle emulators) instead of only flagging
  [string]$MarkStopped,   # -MarkStopped <run id>: the lead stopped that workflow (TaskStop); its unfinished steps are no longer listed as running
  [switch]$Brief,         # -Brief: flags only, one line each (or one 'ok' line) - for the /loop heartbeat
  [switch]$Takeover,      # -Takeover: run although another session's supervisor ran in the last 30 min
  [int]$BudgetSeconds = 240)   # hard time budget: heavy sections past it are skipped (partial result, named in a WATCH flag)
$ErrorActionPreference = 'SilentlyContinue'
$skills = Split-Path $PSScriptRoot   # <kit>/skills
$swarm = Join-Path $skills 'android-swarm'
$runTotal = 0; $now = Get-Date; $liveLabels = New-Object System.Collections.ArrayList; $runningLabels = New-Object System.Collections.ArrayList; $doneLabels = New-Object System.Collections.ArrayList; $flags = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
function Flag($lvl, $what, $action) { [void]$flags.Add([pscustomobject]@{ level = $lvl; what = $what; action = $action }) }
function L($s) { [void]$lines.Add($s) }
# one supervisor per machine: a second session's heartbeat steps aside (two sessions once fixed and flagged the same things twice)
$lk = Join-Path (Get-KitPath cache -Create) 'supervise.lock'
$me = if ($Session) { $Session } else { "pid$PID" }
$held = if (Test-Path $lk) { try { Get-Content $lk -Raw | ConvertFrom-Json } catch { $null } }
if (-not $Takeover -and -not $MarkStopped -and $held -and $held.session -ne $me -and ((Get-Date) - [datetime]$held.at).TotalMinutes -lt 30) { "another session's supervisor ran $([int]((Get-Date) - [datetime]$held.at).TotalMinutes) min ago (session $($held.session)): this heartbeat steps aside (stop it, or -Takeover)"; return }
@{ session = $me; at = (Get-Date).ToString('s'); pid = $PID } | ConvertTo-Json | Set-Content $lk
$t0 = Get-Date; $deadline = $t0.AddSeconds($BudgetSeconds); $script:skipped = @()
function Within($name) { if ((Get-Date) -lt $deadline) { $true } else { $script:skipped += $name; $false } }

# 1. workflows (newest first, this project's sessions)
$proj = $KitConf.ClaudeProjectDir   # this workspace's Claude Code sessions
$wfDirs = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'subagents\workflows') -Directory } | Sort-Object LastWriteTime -Descending | Select-Object -First 6
# a stopped workflow (TaskStop) leaves started-but-unfinished steps in its journal forever: the lead marks it once, it is skipped after
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
  # An agent that died on an API error (e.g. 529 Overloaded) never writes a result and would look "running" forever. If a later
  # agent for the same item (label "<stage>:<code>[@lane]") has already finished, the workflow moved on: treat it as superseded.
  $itemOf = { param($label) (([string]$label -split ':', 2)[-1] -split '@')[0] }
  $finishedAt = @{}
  foreach ($s in $started) { if ($res.ContainsKey($s.agentId)) { $k = & $itemOf $s.label; $i = [array]::IndexOf($started, $s); if (-not $finishedAt.ContainsKey($k) -or $finishedAt[$k] -lt $i) { $finishedAt[$k] = $i } } }
  $running = @($running | Where-Object { $k = & $itemOf $_.label; -not ($finishedAt.ContainsKey($k) -and $finishedAt[$k] -gt [array]::IndexOf($started, $_)) })
  # A replacement started for the same label (a stopped agent re-run after a usage limit or API error) supersedes it too, even
  # before the replacement finishes: only the latest start per label is live (else the dead one flags "written nothing" for hours).
  $running = @($running | Where-Object { $lbl = $_.label; $i = [array]::IndexOf($started, $_); -not @($started | Where-Object { $_.label -eq $lbl -and [array]::IndexOf($started, $_) -gt $i }).Count })
  $runTotal += $running.Count
  L ("workflow {0}: {1} agents, {2} finished, {3} running{4}" -f $w.Name, $started.Count, $res.Count, $running.Count, $(if ($done) { ' (complete)' }))
  # keep <runtime>/work/waves/<run>.json current for running dev waves: orch.ps1 track reads it to hold merges/promotions while an MR's
  # agent is still in review or fix (a wave nobody had reported on yet was invisible to it, and merge-after merged mid-review)
  if ($AutoFix -and $running.Count -and @($started | Where-Object { $_.label -match '^(build|review|fix):' }).Count) {
    & $KitCmd.orch report -Run $w.Name *> $null
  }
  foreach ($a in $running) {
    $tf = Get-ChildItem $w.FullName -Recurse -File -Filter "*$($a.agentId)*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $idle = if ($tf) { [int]($now - $tf.LastWriteTime).TotalMinutes } else { -1 }
    L ("  {0,-18} idle {1} min" -f $a.label, $idle)
    if ($idle -ge 0 -and $idle -lt $IdleMin) { [void]$liveLabels.Add($a.label) }
    [void]$runningLabels.Add($a.label)   # quiet or not: a tester blocked in a long boot/memory wait still owns its phone
    if ($idle -ge $IdleMin) { Flag 'WATCH' "$($a.label) in $($w.Name) has written nothing for $idle min" "Check its worktree/board status and the gate queue; if it is waiting on the gate that's fine. If idle > 60 min with no build, it may be stuck: let the workflow finish it, then resume that agent with RESUME_BRIEF." }
  }
  foreach ($r in $res.Values) {
    [void]$doneLabels.Add([string]($started | Where-Object agentId -eq $r.agentId | Select-Object -First 1).label)
    $sum = [string]$r.result.summary + [string]$r.result.error
    # A collision only matters while the wave is still running (two writers right now). Once no agent of the workflow is running
    # it is over and orch.ps1 report covers its outcome; an agent whose MRs all merged also shipped fine. (Build-stage results
    # report merged=false because merging happens later in the same wave, so "shipped" alone is not enough.)
    $shipped = $r.result.mrs -and -not @($r.result.mrs | Where-Object { -not $_.merged }).Count
    # agent-coordination wording only: a bare "duplicate" fired on bug summaries about duplicate records/lines/names
    if ($running.Count -and -not $shipped -and $sum -match '(?i)duplicate (agent|copy|writer|instance|session)|(agent|copy|writer)s? collid|collid\w* with (another|an?other agent|agent)|another (agent|writer)|halted|stopped editing') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) in $($w.Name) reported a collision/halt" 'Read its result; resume it alone with RESUME_BRIEF after making sure no other writer is active (orch.ps1 board check).' }
    if ($null -ne $r.result.mrs -and @($r.result.mrs).Count -eq 0 -and $sum -match '(?i)not done|no MRs') { Flag 'ACT' "$($started | Where-Object agentId -eq $r.agentId | ForEach-Object label) finished without MRs" 'Resume it (dev-wave mode resume) unless it was deliberately stopped.' }
  }
}

# 2. agent board
$board = Get-KitPath board
$entries = @(Get-ChildItem $board -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
$active = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 })
$stale = @($entries | Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -ge 20 -and ($now - [datetime]$_.beat).TotalHours -lt 6 })
L "board: $($active.Count) active, $($stale.Count) stale"
# group by run + agent: two waves (or sessions) may both name an agent X1 - that is not a duplicate
foreach ($g in $active | Group-Object { "$($_.run)/$($_.agent)" } | Where-Object Count -gt 1) {
  # an agent that joined the board twice (same run) leaves its first entry behind: if only the newest entry still beats
  # it is a re-join, not two copies -> mark the old entries left instead of an ACT flag
  $byBeat = @($g.Group | Sort-Object { [datetime]$_.beat } -Descending); $newest = [datetime]$byBeat[0].beat
  $old = @($byBeat | Select-Object -Skip 1)
  # superseded = same run AND (it stopped beating 5+ min before the newest, OR it never beat after joining and joined within 2 min
  # of the newest entry: the same agent ran `board join` twice). A resumed copy joins much later and keeps beating -> real duplicate.
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
# skip board entries whose agent the workflow journal shows as active (testers don't heartbeat during long checks)
# a label "verify:W1" may be on the board as "W1" or "W1-verify" (QA verifiers): accept both forms
function LabelNames($l) { $p = $l -split ':'; $n = ($p[-1] -split '@')[0]; @($n) + $(if ($p.Count -gt 1) { "$n-$($p[0])" }) }
$liveNames = @($liveLabels | ForEach-Object { LabelNames $_ })
# agents whose workflow step finished (no copy still running) just forgot to `leave`: close their entry instead of flagging
$doneNames = @($doneLabels | ForEach-Object { LabelNames $_ } | Where-Object { $_ -and $_ -notin $liveNames })
foreach ($s in $stale | Where-Object { $_.agent -in $doneNames }) {
  if ($AutoFix) { $f = Join-Path $board "$($s.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }; Flag 'INFO' "auto-fixed: board entry $($s.agent) marked left (its workflow step finished)" 'Nothing to do.' }
}
foreach ($s in $stale | Where-Object { $_.agent -notin $liveNames -and $_.agent -notin $doneNames }) {
  # -AutoFix marks entries silent >= 2 h as left later in this same run: report that, not a WATCH for something already handled
  if ($AutoFix -and ($now - [datetime]$s.beat).TotalHours -ge 2) { Flag 'INFO' "auto-fixed: board entry $($s.agent) ($($s.run)) silent $([int]($now - [datetime]$s.beat).TotalMinutes) min -> marked left" 'Nothing to do.'; continue }
  Flag 'WATCH' "board entry $($s.agent) ($($s.run)) has no heartbeat for $([int]($now - [datetime]$s.beat).TotalMinutes) min" 'It may have finished without leaving, or be stuck. Cross-check with the workflow journal.' }

# 3. memory gate
$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
$queue = @(Get-ChildItem (Join-Path $ledger 'queue') -Filter '*.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
$runningB = @(Get-ChildItem $ledger -Filter '*.json' | Where-Object Name -ne 'history.json' | ForEach-Object { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (Get-Process -Id $t.pid) { $t } })
$oldest = $queue | Sort-Object { [datetime]$_.since } | Select-Object -First 1
$wait = if ($oldest) { [int]($now - [datetime]$oldest.since).TotalMinutes } else { 0 }
L "gate: $($runningB.Count) running ($((@($runningB | ForEach-Object { "$($_.kind)" }) -join ', '))), $($queue.Count) queued, longest wait $wait min"
if ($wait -ge 30) { Flag 'ACT' "gate: $($oldest.owner) $($oldest.kind) has waited $wait min" 'Memory is the bottleneck: pause starting new agents/workflows, stop idle headless browsers (orch.ps1 cleanup), or ask the user to close big apps. Consider -MaxParallel or fewer agents per wave.' }
elseif ($queue.Count -ge 6) { Flag 'WATCH' "gate: $($queue.Count) builds queued" 'Do not launch more build-heavy agents until the queue drains.' }
$hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
foreach ($k in $hist.Keys) { $last = @($hist[$k] | Select-Object -Last 3); if ($last.Count -eq 3 -and -not ($last | Where-Object { $_.ok })) { Flag 'WATCH' "builds '$k' failed 3 times in a row" 'Look at that agent: repeated failing builds burn memory turns; it may need help or a brief fix.' } }

# 3b. idle emulators: running but no active app test lane and no board claim uses them
$stateFile = Get-KitPath supervise-state -Create
$state = try { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $state) { $state = @{} }; if (-not $state.idleSince) { $state.idleSince = @{} }
$adb = Join-Path (Get-AndroidSdk) (Join-Path 'platform-tools' (Get-ExeName 'adb'))
if (Test-Path $adb) {
  $serials = @(& $adb devices 2>$null | Where-Object { $_ -match '^(emulator-\d+)\s+device' } | ForEach-Object { $Matches[1] })
  $swarmCfg = try { Get-Content (Join-Path $swarm 'swarm.config.json') -Raw | ConvertFrom-Json } catch { $null }
  # Agents own phones through leases (android-swarm/swarm.ps1 acquire/release): they boot, wait and shut down phones themselves.
  # The supervisor is only the safety net: (1) a lease whose holder is gone (no live workflow step on that lane, no live board entry
  # holding it, at least 60 min old) is released, which shuts the phone down; (2) a running phone with NO lease (booted by hand) and
  # our app closed for 10 min is shut down.
  $P = ({ & $KitCmd.swarm @args })
  $leaseDir = Get-KitPath phones
  # A board entry holds a lease when it is not left, names the lease agent / holder or lists the lease serial or lane in its
  # worktrees ("emulator-5556", "app:Falcon", comma-joined lists), and is alive: its pid runs or it beat in the last 3 h.
  # (The lease agent is "qa-<run>-<lane>" while board codes are item codes, so the agent name alone never matched.)
  $holdsLease = { param($e, $ls)
    if ($e.status -eq 'left') { return $false }
    $names = @($ls.agent, $ls.holder) | Where-Object { $_ }
    $tokens = @((@($e.worktrees) -join ',') -split ',' | ForEach-Object { ("$_".Trim() -split ':')[-1].Trim() } | Where-Object { $_ })
    $named = ($e.agent -in $names) -or @($tokens | Where-Object { ($ls.serial -and $_ -eq $ls.serial) -or ($ls.lane -and $_ -eq $ls.lane) }).Count
    if (-not $named) { return $false }
    $pidLive = $e.pid -and [bool](Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)
    $beatOk = try { ($now - [datetime]$e.beat).TotalHours -lt 3 } catch { $false }
    [bool]($pidLive -or $beatOk)
  }
  foreach ($lf in @(Get-ChildItem $leaseDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $ls = Get-Content $lf.FullName -Raw | ConvertFrom-Json
    # any running (unfinished, not superseded) workflow step on the lane holds it, however long it has been quiet: releasing on
    # idle shut phones down under testers waiting in a boot or memory queue. A dead step is replaced by the workflow anyway.
    $laneLive = @($runningLabels | Where-Object { $_ -match "@$([regex]::Escape($ls.lane))$" }).Count
    $boardLive = @($entries | Where-Object { & $holdsLease $_ $ls }).Count
    $age = [int]($now - [datetime]$ls.since).TotalMinutes
    if ($ls.agent -eq 'manual') {   # booted by hand (swarm.ps1 acquire -Agent manual): the user owns it; never reclaimed, only a reminder
      if ($age -ge 240) { Flag 'WATCH' "phone $($ls.lane) booted by hand $([int]($age / 60)) h ago is still up" "If you are done with it: & $P release -Agent manual" }
      continue
    }
    if ($laneLive -or $boardLive -or $age -lt 60) { continue }
    if ($AutoFix) { $r = & $P release -Agent $ls.agent 2>&1; Flag 'INFO' "auto-fixed: released orphan phone lease $($ls.lane) held by $($ls.agent) for $age min: $r" 'Its holder is gone (crashed or finished without release).' }
    else { Flag 'ACT' "phone lease $($ls.lane) held by $($ls.agent) for $age min, holder not active" "& $P release -Agent $($ls.agent)" }
  }
  $pkg = if ($swarmCfg) { $swarmCfg.app.package } else { $null }
  foreach ($sr in $serials) {
    $lane = if ($swarmCfg) { ($swarmCfg.lanes | Where-Object { "emulator-$($_.port)" -eq $sr } | Select-Object -First 1).name } else { $null }
    if ($lane -and (Test-Path (Join-Path $leaseDir "$lane.json"))) { $state.idleSince.Remove($sr) | Out-Null; continue }   # leased: its agent decides
    $appRunning = $pkg -and [bool]((& $adb -s $sr shell pidof $pkg 2>$null) -join '').Trim()
    if ($appRunning) { $state.idleSince.Remove($sr) | Out-Null; continue }
    if (-not $state.idleSince.ContainsKey($sr)) { $state.idleSince[$sr] = $now.ToString('o') }
    $idleFor = [int]($now - [datetime]$state.idleSince[$sr]).TotalMinutes
    if (-not $lane) {   # not a swarm lane (started by hand / another tool): nothing here can shut it down by lane name
      if ($idleFor -ge 10) { Flag 'WATCH' "emulator $sr is not in swarm.config.json and our app has been closed on it for $idleFor min" "If nobody uses it: & $adb -s $sr emu kill" }
    } elseif ($AutoFix -and $idleFor -ge 10) {
      & $KitCmd.swarm down -Lanes $lane -KeepBrowsers | Out-Null
      $state.idleSince.Remove($sr) | Out-Null
      Flag 'INFO' "auto-fixed: shut down unleased emulator $sr ($lane): app closed for $idleFor min" 'Agents get phones with swarm.ps1 acquire.'
    } else { Flag $(if ($idleFor -ge 10) { 'ACT' } else { 'WATCH' }) "unleased emulator $sr ($lane): app closed for $idleFor min" "& $($KitCmd.swarm) down -Lanes $lane -KeepBrowsers (or run supervise with -AutoFix)." }
  }
  # 3c. crashed / hung emulators. Emulators run without a console window (swarm.ps1 up), so a dead one is invisible: its
  # processes stay up holding RAM while adb shows it offline or not at all. Kill: (a) emulator/qemu processes of a lane whose
  # serial is not 'device' and whose newest process is older than 8 min (normal boot < 6 min); (b) an emulator.exe whose qemu
  # child is gone (qemu crashed) for 2+ min.
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
                 elseif (-not $qemu.Count -and $youngest -ge 2) { "the emulator process is up but its qemu process is gone (crashed)" } }
      $why = & $whyOf
      # the adb daemon may just have restarted (`adb devices` lists nothing for a few seconds): ask once more before calling it dead
      if ($why -and $adbState[$sr] -ne 'device' -and -not $rechecked) { Start-Sleep -Seconds 10; $adbState = & $adbStates; $rechecked = $true; $why = & $whyOf }
      if (-not $why) { continue }
      if (Test-Path (Join-Path $leaseDir "$($ln.name).json")) {   # leased: never killed under its holder (an orphan lease is released above first)
        Flag 'WATCH' "leased emulator $sr ($($ln.name)) looks dead: $why" "Its lease holder re-boots it with swarm.ps1 ensure (or its next acquire); if the holder is gone, the lease is released after 60 min."; continue
      }
      if ($AutoFix) {
        $mine | ForEach-Object { Stop-SysProcess $_.Id }
        Flag 'INFO' "auto-fixed: killed dead emulator $sr ($($ln.name)): $why" 'Nothing to do.'
      } else { Flag 'ACT' "dead emulator $sr ($($ln.name)): $why" "Kill it: & $($KitCmd.swarm) down -Lanes $($ln.name) -KeepBrowsers (or run supervise with -AutoFix)." }
    }
  }
}
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile

# 4. machine
$mem = Get-SysMem; $tot = $mem.TotalGB; $avail = $mem.AvailGB
$pct = [int](100 * (1 - $avail / $tot)); L "memory: $pct% used, $([math]::Round($avail,1)) GB available"
$ramAct = [int](Get-KitSetting 'supervise.ramActPct' 90); $diskMin = [double](Get-KitSetting 'supervise.minDiskFreeGB' 30)   # kit.local.json
if ($pct -ge $ramAct) { Flag 'ACT' "RAM $pct% used" 'Hold new launches; run orch.ps1 cleanup; check for orphaned java/node/chrome from finished agents.' }
# the drive / file system the workspace (repos, worktrees, runtime) lives on
$drive = if ($KitIsWindows) { $KitConf.Workspace.Substring(0, 1) } else { $KitConf.Workspace }
$freeGB = try { [math]::Round([IO.DriveInfo]::new($(if ($KitIsWindows) { "${drive}:\" } else { $drive })).AvailableFreeSpace / 1GB) } catch { 999 }
L "disk ${drive}: $freeGB GB free"
if ($freeGB -lt $diskMin) { Flag 'ACT' "disk ${drive}: only $freeGB GB free" 'Run orch.ps1 cleanup; remove finished worktrees.' }
$gl = Get-KitPath guard-log
$blocks = @(Get-Content $gl | Where-Object { $_ -match '^(\S+)\t' -and ($now - [datetime]$Matches[1]).TotalMinutes -lt 60 })
if ($blocks.Count -ge 3) { Flag 'WATCH' "guard blocked $($blocks.Count) commands in the last hour" 'Agents are tripping a rule: read guard.log; add a contracts note or a lesson so they stop.' }

# 5. ONE heartbeat does the housekeeping too (no separate crons): tracker statuses, stale board entries, due cleanup
if ($AutoFix -and (Within 'tracker + deploy checks')) {
  $S = $PSScriptRoot
  # who (an active board agent, heartbeat < 30 min) has this MR's source branch checked out in one of its worktrees?
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
  foreach ($l in @(& $KitCmd.orch track run -Detail)) {   # -Detail: HOLD lines become INFO flags
    if ($l -match '^(DONE|COMMENTED)') { Flag 'INFO' "auto-fixed: $l" 'Tracker moved the task; nothing to do.' }
    elseif ($l -match '^CONFIG') { Flag 'INFO' $l 'A kit.local.json key is missing for this task; add it or register its MRs by hand.' }
    elseif ($l -match '^HOLD') { Flag 'INFO' $l 'Merge/promotion waits for the review or fix round; it resumes by itself.' }
    elseif ($l -match '^ATTENTION \S+: could not set status') { Flag 'ACT' $l "All MRs merged but the tracker refused the status change (orch.ps1 track retries every round): check tracker auth and status names (tracker.statuses in kit.local.json; & $($KitCmd.dev) tracker view <id>), or set it by hand." }
    elseif ($l -match '^ATTENTION .*no solution/testing comment') { Flag 'ACT' $l "Post the solution, MR links and how-to-test steps on the task (& $($KitCmd.dev) tracker comment <id> <file.md>)." }
    elseif ($l -match '^ATTENTION .* (?<repo>[\w./-]+)!(?<iid>\d+) opened \((conflict|pipeline \w+)\)' -and ($owner = OwnerOf $Matches.repo $Matches.iid)) {
      Flag 'INFO' "$l - being handled by $owner" 'An active agent has that MR branch checked out; re-check next round.'
    }
    elseif ($l -match '^ATTENTION') { Flag 'ACT' $l 'A tracked MR failed its pipeline, was closed or has merge conflicts (a sibling MR changed the same lines): get it fixed or rebased (resume its agent with RESUME_BRIEF; the agent may have stopped).' }
  }
  # promoted tasks whose MRs went live on a test environment: QA can start now (never guess "not deployed yet" by hand)
  $D = ({ & $KitCmd.qa deployed @args })
  foreach ($o in @((Read-KitTracking).tasks.Values)) {   # durable <kit>/tracking.local.json (orch.ps1 track)
    # liveOn does not stop the check: a repo can deploy to several test environments (one live first is often not the one the
    # task is tested on), so keep looking for newly live ones until the 3-day window ends
    if (-not $o.done -or -not $o.doneAt -or ($now - [datetime]$o.doneAt).TotalDays -gt 3) { continue }
    if ($o.qaCovered) { continue }
    # deploys take > 10 min; don't re-ask the git host every run. Already live somewhere: only look for another environment hourly
    # (a 10-min re-check of every live task made rounds run past 4 min)
    if ($o.liveCheckedAt -and ($now - [datetime]$o.liveCheckedAt).TotalMinutes -lt $(if (@($o.liveOn).Count) { 60 } else { 10 })) { continue }
    # a QA run already has it (often closed already): nothing to launch, so skip the git-host deploy lookup (10+ calls per task)
    $covered = @(Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter 'run.json' -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($o.task) } | ForEach-Object { $_.Directory.Name })
    if ($covered.Count) { Set-KitTaskFields $o.task @{ qaCovered = @($covered) }; continue }
    $rows = @(& $D -Mrs (@($o.mrs) -join ',') -Json | ConvertFrom-Json)
    $o.liveCheckedAt = $now.ToString('o')
    $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -ne 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
    $new = @($live | Where-Object { $_ -notin @($o.liveOn) })
    $fields = @{ liveCheckedAt = $o.liveCheckedAt }; if ($new.Count) { $fields.liveOn = @(@($o.liveOn) + $new | Where-Object { $_ } | Select-Object -Unique) }
    Set-KitTaskFields $o.task $fields
    # a person may have tested and closed the task by hand (no QA run covers it): only read the tracker once a deploy is new
    if ($new.Count -and (Test-TrackerStatus $(try { (Get-TrackerTask $o.task).status } catch { '' }) 'closed')) {
      Set-KitTaskFields $o.task @{ qaCovered = @('closed') }; continue
    }
    if ($new.Count) {
      # deployed = in test (the org's rule: never before the deploy); human testers use the testing doc, agent QA only on request
      if ($AutoFix) { foreach ($l2 in @(& $KitCmd.orch deploy intest -Task $o.task -Apply -Quiet)) { Flag 'INFO' "auto-fixed: LIVE $($o.task) on $($new -join ', '): $l2" 'Tracker set to inTest; nothing to do.' } }
      else { Flag 'ACT' "LIVE $($o.task): all MRs ($(@($o.mrs) -join ', ')) deployed to $($new -join ', ')" "& $($KitCmd.orch) deploy intest -Task $($o.task) -Apply (inTest). Agent QA on staging only when the owner asks (/test-and-close)." }
    }
  }
  foreach ($gone in $stale | Where-Object { ($now - [datetime]$_.beat).TotalHours -ge 2 }) {   # finished without `leave` (not $s: same variable as $S, the scripts folder used below)
    $f = Join-Path $board "$($gone.session).json"; if (Test-Path $f) { $o = Get-Content $f -Raw | ConvertFrom-Json; $o.status = 'left'; $o | ConvertTo-Json | Set-Content $f }
  }
  # under memory pressure clean now (idle Gradle/Kotlin daemons alone held ~6 GB at 91%); otherwise only when due
  if ($pct -ge 85) { foreach ($l in @(& $KitCmd.orch cleanup | Select-Object -First 1)) { Flag 'INFO' "auto-fixed: RAM $pct% -> orch.ps1 cleanup: $l" 'Re-check memory next round.' } }
  else { & $KitCmd.orch cleanup -IfDue -Quiet }
}

# 6. new bug tasks raised by QA that no bug-fix agent owns yet (parents taken from the QA runs' tracker config)
if (Within 'QA bug tasks') {
$parents = @(Get-ChildItem (Get-KitPath qa-runs) -Directory | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'run.json') -Raw | ConvertFrom-Json).tracker.parent } catch {} } | Where-Object { $_ } | Select-Object -Unique)
$tracked = @((Read-KitTracking).tasks.Keys)
# New QA bug tasks are fixed at once, all open ones in ONE wave. $openRuns only adds a note that a run is still testing.
$openRuns = @{}
foreach ($rd in Get-ChildItem (Get-KitPath qa-runs) -Directory | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }) {
  try { $rj = Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { continue }
  $left = @($rj.items | Where-Object { -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) }).Count   # held.json = skipClose item finished
  if ($left -and $rj.tracker.parent) { $openRuns[$rj.tracker.parent] = "$($rd.Name) ($left item(s) left)" }
}
foreach ($par in $parents) {
  $subs = try { (Get-TrackerTask $par).subtasks } catch { @() }
  $new = @($subs | Where-Object { $_.name -match '^\[Bug\]' -and (Test-TrackerStatus $_.status 'open') -and $_.id -notin $tracked })
  if (-not $new.Count) { continue }
  $list = ($new | ForEach-Object { "$($_.id) $($_.name.Substring(0, [math]::Min(70, $_.name.Length)))" }) -join '; '
  # Fix at once (the owner's standing mandate: QA bugs are fixed without waiting to be asked) - but as ONE wave for every bug open
  # right now, not one wave per bug. A still-running QA run is only mentioned: later bugs from it go into the next wave.
  $note = if ($openRuns[$par]) { " (run $($openRuns[$par]) is still testing: later bugs go into the next wave)" } else { '' }
  Flag 'ACT' "$($new.Count) new QA bug task(s) not being fixed$note`: $list" "Start the fixes now as ONE wave: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> [-Hints ...] per task (writes the brief, starts tracking, prints /dev-wave args incl. mandate), combine the briefs into one file with a section per agent, then launch a single /dev-wave."
}

}
# 6b. tasks QA sent back (failedTesting: an own check failed or testing was incomplete) that no fix wave owns: tracking done or none
if (Within 'failedTesting tasks') {
$ft = @{}
foreach ($fj in Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter finalize.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddDays(-7) }) {
  foreach ($s in @((Get-Content $fj.FullName -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.failedTesting })) { $ft[[string]$s.id] = $fj.Directory.Parent.Name }
}
$trk = (Read-KitTracking).tasks
$back = @(foreach ($id in $ft.Keys) { $o = $trk[$id]; if ($o -and -not $o.done) { continue }
    $st = try { [string](Get-TrackerTask $id).status } catch { '' }
    if ((Test-TrackerStatus $st 'failedTesting') -or ($o.done -and (Test-TrackerStatus $st 'inProgress'))) { "$id ($($ft[$id]))" } })
if ($back.Count) { Flag 'ACT' "$($back.Count) task(s) failed testing, back to the dev flow: $($back -join '; ')" "ONE /dev-wave mode 'bugfix' for all: & $($KitCmd.orch) bugbrief -Task <id> -Agent B-<code> -Repos <repos> per task (reproduce locally first), then launch." }
}
# 6c. decision pauses waiting for the owner (an agent stopped an item: a behaviour change not asked for, or several valid paths)
foreach ($d in @(Invoke-Decide list -Pending -Json | Out-String | ConvertFrom-Json | Where-Object { $_ })) {
  Flag 'ACT' "DECISION $($d.id) ($($d.run)/$($d.agent), item $($d.item)): $($d.question)" "Ask the owner (options: $(@($d.options) -join ' ; ')$(if ($d.recommend) { "; recommended: $($d.recommend)" })), then & $($KitCmd.orch) decide answer -Id $($d.id) -Answer '<their words>'"
}
# 6d. deploy asks (dev flow step 5): merged work not deployed, window open; checked hourly (deploy plan asks the CI and the git host)
if (Within 'deploy plan') {
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'
$cache = if (Test-Path $pc) { try { Get-Content $pc -Raw | ConvertFrom-Json } catch { $null } }
if (-not $cache -or ($now - [datetime]$cache.at).TotalMinutes -ge 60) {
  $plan = @(Invoke-Deploy plan -Json | Out-String | ConvertFrom-Json | Where-Object { $_ })
  $cache = [pscustomobject]@{ at = $now.ToString('s'); ask = @($plan | Where-Object status -eq 'ASK' | ForEach-Object { "$($_.target): $(@($_.mrs).Count) MR(s) ($((@($_.mrs) | ForEach-Object mr) -join ', '))" }) }
  $cache | ConvertTo-Json -Depth 4 | Set-Content $pc -Encoding utf8
}
foreach ($a in @($cache.ask)) { Flag 'ACT' "DEPLOY ASK $a merged, not deployed, window open" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; after the deploy: deploy record -Env <target> -Mrs <refs>, then deploy intest -Apply." }
}
# 7. capacity: scale QA workers with memory. Seats (qa-kit/qa.ps1 seat) already hold new agents back while free RAM < keepFreeGB,
#    so shrinking is automatic. Growing: if a QA run has items nobody has started and memory has room, say how many extra workers fit.
# one memory floor for the machine: the gate's (env CLAUDE_GATE_KEEP_FREE_GB, kit.local.json gate.keepFreeGB, else 15% of RAM, min 6 GB), as qa.ps1 seat
$keepFree = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
$freeNow = Get-FreeGB
$seatDir = Get-KitPath qa-seats
$seatsNow = @(Get-ChildItem (Join-Path $seatDir 'seats') -Filter *.json -ErrorAction SilentlyContinue).Count
$waitNow = @(Get-ChildItem (Join-Path $seatDir 'wait') -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddMinutes(-3) }).Count
L "qa seats: $seatsNow taken, $waitNow waiting for memory; free RAM $freeNow GB"
foreach ($rd in Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $now.AddHours(-8) }) {
  $run = try { Get-Content (Join-Path $rd.FullName 'run.json') -Raw | ConvertFrom-Json } catch { $null }
  if (-not $run) { continue }
  $queued = @($run.items | Where-Object { $_.lane -ne 'app' -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\finalize.json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\held.json")) -and
      -not (Test-Path (Join-Path $seatDir "claims\$($rd.Name)__$($_.code).json")) -and -not (Test-Path (Join-Path $rd.FullName "$($_.code)\shots")) } | ForEach-Object code)
  if (-not $queued) { continue }
  # a run launched before seats/claims existed: its agents don't claim items, so an extra worker would test the same items twice
  $legacy = @($run.items | Where-Object { (Test-Path (Join-Path $rd.FullName "$($_.code)\shots")) -and -not (Test-Path (Join-Path $seatDir "claims\$($rd.Name)__$($_.code).json")) }).Count
  if ($legacy) { continue }
  $room = [math]::Floor(($freeNow - $keepFree) / 1.5)          # a web tester needs ~1.5 GB; keep keepFreeGB free
  if ($room -ge 2 -and $waitNow -eq 0) {
    $n = [math]::Min($room, $queued.Count)
    Flag 'INFO' "capacity: $($rd.Name) has $($queued.Count) queued item(s) ($($queued -join ', ')) and room for ~$room more QA agents ($freeNow GB free)" "Add workers: Workflow test-and-close with args { runDir: '$($rd.FullName)', kitDir: '$($KitConf.Kit)', instance: 'w<next>', webParallel: $n, only: [$(($queued | ForEach-Object { "'$_'" }) -join ', ')] } - item claims stop two runs testing the same item."
  } elseif ($freeNow -lt $keepFree) { Flag 'WATCH' "memory tight ($freeNow GB free): QA seats are holding new agents back" 'Do not launch more agents until it recovers; close big apps if it persists.' }
}

# 8. retro due (orchestrate E14): learning signals since the last /kit-retro and no workflow (dev-wave, test-and-close, kit-retro) of
#    this session still running - one retro then covers every finished run (counted as kit.ps1 nudge does)
if (-not $runTotal) {
  $sigF = Get-KitPath signals; $markF = Get-KitPath last-retro
  $since = if (Test-Path $markF) { [datetime](Get-Content $markF -Raw).Trim() } else { [datetime]::MinValue }
  $nSig = if (Test-Path $sigF) { @(Get-Content $sigF | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count } else { 0 }
  # due when a dev-wave / test-and-close finished after the last retro (its journal has build/test steps and was written since),
  # or when signals piled up anyway (15, as kit.ps1 nudge); one stray signal right after a retro is not worth five agents
  $finished = @($wfDirs | Where-Object { $_.LastWriteTime -gt $since -and (Test-Path (Join-Path $_.FullName 'journal.jsonl')) -and
      (Select-String (Join-Path $_.FullName 'journal.jsonl') -Pattern '"label":"(build|test|retest|verify|fix):' -Quiet) }).Count
  if ($nSig -ge 15 -or ($nSig -ge 1 -and $finished)) { Flag 'ACT' "retro due: $nSig signals since the last retro, $finished dev/QA run(s) finished since, no workflow running" '/kit-retro (E14)' }
}

$secs = [int]((Get-Date) - $t0).TotalSeconds
if ($script:skipped.Count) { Flag 'WATCH' "sweep hit its $BudgetSeconds s budget: skipped $($script:skipped -join ', ')" 'Partial result: the skipped sections run next round (or raise -BudgetSeconds).' }
L "sweep: $secs s"
$out = [pscustomobject]@{ at = $now.ToString('s'); seconds = $secs; summary = @($lines); flags = @($flags) }
if ($Json) { $out | ConvertTo-Json -Depth 4; exit 0 }
if ($Brief) {
  # one line per flag that needs the lead; auto-fixed INFO lines only counted; nothing to do -> a single 'ok' line
  $auto = @($flags | Where-Object { $_.level -eq 'INFO' -and $_.what -match '^auto-fixed' }).Count
  $show = @($flags | Where-Object { -not ($_.level -eq 'INFO' -and $_.what -match '^auto-fixed') } | Sort-Object { @{ ACT = 0; WATCH = 1; INFO = 2 }[$_.level] })
  $tail = if ($auto) { " ($auto auto-fixed)" } else { '' }
  if (-not @($show | Where-Object level -ne 'INFO').Count) { "ok: $runTotal running, mem $pct%, sweep $secs s$tail" }
  $show | ForEach-Object { "[$($_.level)] $($_.what) -> $($_.action)" }
  if (@($show | Where-Object level -ne 'INFO').Count -and $tail) { "(+$auto auto-fixed)" }
  $global:LASTEXITCODE = 0; exit 0
}
"=== supervise $($now.ToString('HH:mm')) ==="; $lines
if ($flags.Count) { '--- FLAGS'; $flags | Sort-Object { @{ ACT = 0; WATCH = 1; INFO = 2 }[$_.level] } | ForEach-Object { "[$($_.level)] $($_.what)`n        -> $($_.action)" } } else { '--- no flags: all good' }
$global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------- report: a finished (or running) workflow run from its journal
# Readable summary of a finished (or running) workflow, built from its journal — the reliable source; the Workflow tool's
# notification text is truncated and not plain JSON. Works for /dev-wave, /test-and-close and /kit-retro runs.
#
#   & <workspace>/.claude/skills/orchestrate/orch.ps1 report -Run wf_de575b4e-f98 [-Session <id>] [-Detail] [-Json]
#   -> default (compact): one totals line, then only what needs the lead: agents with unmerged MRs / deferrals / notes, QA packages
#      with FAIL or NOT_TESTED, OPEN review findings (non-nit, not fixed by a fix: round), learn-step changes.
#      -Detail: every agent and package, done lists, deferral reasons, live checks, full findings with their fix.
#      Always writes the full JSON to <runtime>/work/waves/<run>.json (Get-KitPath waves) for later rounds / follow-up briefs.
function Invoke-Report {
param([Parameter(Mandatory)][string]$Run, [string]$Session, [switch]$Json, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
$proj = $KitConf.ClaudeProjectDir   # this workspace's Claude Code sessions
$dir = Get-ChildItem $proj -Directory | Where-Object { -not $Session -or $_.Name -eq $Session } | ForEach-Object { Join-Path $_.FullName "subagents\workflows\$Run" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dir) { [Console]::Error.WriteLine("wave-report: workflow $Run not found under $proj"); exit 1 }   # throw is suppressed under SilentlyContinue
$ev = @(Get-Content (Join-Path $dir 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 30 })
$label = @{}; foreach ($e in $ev | Where-Object type -eq 'started') { $label[$e.agentId] = $e.label }
$results = @($ev | Where-Object type -eq 'result' | ForEach-Object { [pscustomobject]@{ label = $label[$_.agentId]; r = $_.result } })
# running = started without a result, minus (as orch.ps1 supervise does) steps superseded by a later finished agent for the same item
# (died on an API error, retried) and every step of a workflow the lead stopped (orch.ps1 supervise -MarkStopped)
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
        # a report object: read done/deferred/live checks from it even with no MRs (an agent that deferred everything still has a
        # report; it once showed as "deferred 0" plus a raw @{mrs=...} dump). A fix round reports only the MRs it touched: merge with
        # the build round's by URL, and deferred items by id (the newer entry wins).
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
    # the ship step's report holds devtools.py merge's confirmed state per MR (the build/fix reports are snapshots from before it)
    'ship' { if ($agents.Contains($id) -and $x.r.mrs) { foreach ($sm in @($x.r.mrs | Where-Object { $_ })) { $u = ([string]$sm.url).TrimEnd('/').ToLower()
      foreach ($m in $agents[$id].mrs) { if (([string]$m.url).TrimEnd('/').ToLower() -eq $u -and $sm.mergeState) { $m.mergeState = [string]$sm.mergeState; $m.merged = ($sm.mergeState -eq 'MERGED') } } } } }
    'review' { foreach ($f in $x.r.findings) { [void]$findings.Add([ordered]@{ agent = $id; severity = $f.severity; file = $f.file; line = $f.line; problem = $f.problem; fix = $f.fix; mr = $f.mr }) } }
    { $_ -in 'test', 'retest' } { if ($x.r.checks) { $c = @($x.r.checks); $qa[$id] = [ordered]@{ checks = $c.Count; pass = @($c | Where-Object result -in 'PASS', 'PASS_WITH_NOTE').Count; fail = @($c | Where-Object result -eq 'FAIL').Count; notTested = @($c | Where-Object result -eq 'NOT_TESTED').Count } } }
    'close' { if ($qa.Contains($id)) { $qa[$id].published = [bool]$x.r.ok } }
    'learn' { $learn = $x.r }
  }
}
# A non-nit finding (blocking or should-fix) counts as addressed when that agent had a fix: round - the fix round answers every
# non-nit finding (fix, or a reasoned rebuttal in its summary). Listed separately so the lead can still read what was done.
$addressed = @($findings | Where-Object { $_.severity -ne 'nit' -and $agents[$_.agent].fixedRound })
$open = @($findings | Where-Object { $_.severity -ne 'nit' -and -not $agents[$_.agent].fixedRound })
# the agent's "merged" is a snapshot from when it finished (usually merge-when-green still pending): ask GitLab now, before the
# JSON is saved, so waves/<run>.json and -Json carry the live state too
# (glab talks to the host it is logged in to; self-hosted: GITLAB_HOST / kit.local.json "gitHost")
foreach ($a in $agents.Values) { foreach ($m in $a.mrs) { if (-not $m.merged -and $m.url -match '://[^/]+/(?<p>.+?)/-/merge_requests/(?<i>\d+)') {
  $h = Invoke-HostApi "projects/$($Matches.p -replace '/', '%2F')/merge_requests/$($Matches.i)"
  if ($h.state -eq 'merged') { $m.merged = $true; $m.mergeState = 'MERGED' } elseif ($h.merge_when_pipeline_succeeds) { $m.mergeState = 'SCHEDULED' } }
  elseif (-not $m.merged -and $m.url -match '://[^/]+/[^/]+/[^/]+/pull/\d+') {   # GitHub PRs
  $h = gh pr view $m.url --json state,autoMergeRequest 2>$null | ConvertFrom-Json
  if ($h.state -eq 'MERGED') { $m.merged = $true; $m.mergeState = 'MERGED' } elseif ($h.autoMergeRequest) { $m.mergeState = 'SCHEDULED' } } } }
$out = [ordered]@{ run = $Run; at = (Get-Date).ToString('s'); running = $running; agents = $agents; openFindings = $open; qa = $qa; learn = $learn }
$wavesDir = Get-KitPath waves -Create
$out | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $wavesDir "$Run.json")
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
# every finished run ends with a kit retro (orchestrate E14) when signals arrived since the last one (as kit.ps1 nudge counts them)
if (-not $running) {
  $sig = Get-KitPath signals; $mark = Get-KitPath last-retro
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  if ((Test-Path $sig) -and (Get-Content $sig | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since } | Select-Object -First 1)) { 'ACT  retro due: /kit-retro (E14)' }
}
}

# ---------------------------------------------------------------- bugbrief: a bug-fix brief from a [Bug] or failedTesting task
# Writes a bug-fix wave brief from a QA-raised "[Bug] … failed checks" task, so the coordinator only adds judgement (hints, overlaps),
# not boilerplate. It pulls the failed checks (id, screen, what was seen) from the task, adds the repo table, the evidence/guide location
# of the QA run that raised it, ownership, branch/board/merge rules, and prints the /dev-wave args to launch (incl. mandate).
#
#   $BB = '<workspace>/.claude/skills/orchestrate/orch.ps1 bugbrief'
#   & $BB -Task 86abc123 -Agent B-CHK -Repos api,web [-Hints 'X3: reuse the existing time zone helper'] [-Range 20260101000000-20260101005959]
#
# Repos: names or aliases from kit.local.json "repos" (each: { name, checkout, target, linkFrom?, aliases[] }); `name@branch` overrides the
# target for this bug (e.g. web@main when the same repo ships two products from different branches). The brief lands next to the
# other briefs (<runtime>/work/briefs/<task>.md); the script prints the path and the Workflow args JSON.
# Mandate: kit.local.json "bugfixMandate" (the task owner's own words asking the coordinator to fix QA bugs), else -Mandate.
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
$kit = Split-Path $PSScriptRoot                                  # .../.claude/skills
$claude = Split-Path $kit
$cfgFile = Join-Path $kit 'dev-kit\kit.local.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { $null }
if (-not $cfg -or -not $cfg.repos) { throw "add a ""repos"" list to $cfgFile (see kit.example.json)" }

$j = Get-TrackerTask $Task
if (-not $j.name) { throw "cannot read task $Task from the tracker ($($KitConf.TrackerType)) - check its CLI auth / tracker config" }
$desc = [string]$j.description
$texts = @($desc) + @(@(try { Get-TrackerComments $Task } catch { @() }) | Sort-Object date -Descending | ForEach-Object { [string]$_.text })   # failedTesting: the QA results comment carries the checks
# failed checks: "### <id> — <screen>" then "**Saw:** ..."
$checks = @(); $cur = $null
foreach ($line in (@($texts | Where-Object { $_ -match '(?m)^###\s+\S+\s+[—-]\s+' } | Select-Object -First 1) -split "`n")) {
  if ($line -match '^###\s+(?<id>\S+)\s+[—-]\s+(?<screen>.+)$') { if ($cur) { $checks += $cur }; $cur = [ordered]@{ id = $Matches.id; screen = $Matches.screen.Trim(); saw = '' } }
  elseif ($cur -and $line -match '^\*\*Saw:\*\*\s*(?<s>.+)$') { $s = ($Matches.s -split '\| Independent re-test')[0].Trim(); $cur.saw = if ($s.Length -gt 500) { $s.Substring(0, 497) + '...' } else { $s } }
}
if ($cur) { $checks += $cur }
if (-not $checks) { throw "no '### <id> — <screen>' failed checks found in $Task" }

# the QA run that raised it: the run folder whose finalize.json names this bug
$runItem = $null
foreach ($fin in Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter finalize.json -ErrorAction SilentlyContinue) {
  $o = Get-Content $fin.FullName -Raw | ConvertFrom-Json
  if (@($o.subtasks | Where-Object { $_.bug -eq $Task }).Count) { $runItem = $fin.Directory; break }
}
$evidence = if ($runItem) { "Evidence + exported guide: ``$($runItem.FullName)\`` and ``$(Split-Path $runItem.FullName)\guides\$($runItem.Name).txt``." } else { 'Evidence: the results doc linked in the task.' }

$Repos = @($Repos -split '\s*,\s*' | Where-Object { $_ })   # "api,web" passed as one string (variables, other shells) works like api,web
$rows = foreach ($spec in $Repos) {
  $r, $branch = $spec -split '@', 2
  $repo = @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0]
  if (-not $repo) { throw "unknown repo '$r' (kit.local.json repos: $(@($cfg.repos.name) -join ', '))" }
  # an overridden target must not borrow deps linked for the default target (different package versions break builds)
  $deps = if ($branch -and $branch -ne $repo.target) { "a checkout on ``$branch`` (not ``$($repo.linkFrom)``, which is on ``$($repo.target)``; dev.ps1 wt warns on a mismatch)" } elseif ($repo.linkFrom) { "``$($repo.linkFrom)`` (-LinkFrom)" } else { 'main checkout' }
  "| $($repo.name) | ``$($repo.checkout)`` | ``$(if ($branch) { $branch } else { $repo.target })`` | $deps |"
}
$ids = ($checks | ForEach-Object id) -join ', '
$slugAgent = $Agent.ToLower()
$runName = "bugfix-$($Task)"
$md = @"
# Bug-fix brief: $($j.name)

Follow ``$claude\skills\dev-kit\templates.md`` "Bug-fix brief", ``$claude\skills\dev-kit\SKILL.md`` and ``$claude\skills\local-env\SKILL.md`` "Debug locally".
This brief wins where they differ.

Task: $($j.url) — checks $ids to fix (steps, what was seen, the independent re-test, evidence; a failedTesting task has them in its latest QA comment).
**Reproduce each check on the local env FIRST** (lease, baseline data, the steps, logs, DB state, debugger) and record it in the
testing-goals doc; cannot reproduce locally -> say why there, then reproduce on the test env. After the fix the same reproduction is
the first local check, then every testing goal.
$evidence

## Failed checks
$(($checks | ForEach-Object { "- **$($_.id)** — $($_.screen): $($_.saw)" }) -join "`n")
$(if ($Hints) { "`n## Coordinator notes`n" + (($Hints | ForEach-Object { "- $_" }) -join "`n") + "`n" })
**No deferrals.** Fix every check above (root cause + test) or prove it stale/expected with evidence. Fix only these checks.
Product calls: pick the behaviour of the reference product/decisions in memory and say so. Additive changes only; existing users and
tenants with the feature off must see no change (crash/500/data-loss fixes may apply to everyone - list them under "Kept for everyone").

## Repos
| Repo | Main checkout | Target | Link deps from |
|---|---|---|---|
$($rows -join "`n")

## Ownership
| Agent | Bug task | Items | Migration range |
|---|---|---|---|
| $Agent | $Task | $ids | $(if ($Range) { $Range } else { 'ask the coordinator if you need one' }) |

Branches ``fix/$($KitConf.TrackerTag)$Task-<slug>``; worktree prefix ``$slugAgent``; board run ``$runName``. Tracker (``$claude\skills\dev-kit\dev.ps1 tracker``):
in progress → review (orch.ps1 track sets promoted when all merge). The workflow merges after review: do NOT merge yourself.
Register: ``$claude\skills\orchestrate\orch.ps1 track add -Task $Task -Discover``.
Phones (app bugs): the local-env APK (``swarm.ps1 build -Local``, ``swarm.ps1 acquire -Agent $Agent -Apk local``); release it when done.
"@
$dir = Get-KitPath briefs -Create
$out = Join-Path $dir "$Task.md"
Set-Content $out $md -Encoding utf8
$null = Test-KitProse -Kind bug-brief -Path $out
$m = if ($Mandate) { $Mandate } elseif ($cfg.bugfixMandate) { @($cfg.bugfixMandate) } else { Write-Warning 'no mandate: pass -Mandate or set kit.local.json "bugfixMandate" (agents drop their items for later chat messages without one)'; @() }
# model: dev-wave builds on sonnet unless the agent is marked complex (strongest model). Complex = more than 2 failed checks, or any
# check that isn't cosmetic (label / colour / i18n / raw key / date format / typo / alignment ...): logic, data or crash bugs.
$cosmetic = '(?i)label|translation|i18n|raw (translation )?key|colou?r|date format|typo|spelling|alignment|padding|wording|icon'
$complex = $checks.Count -gt 2 -or @($checks | Where-Object { ($_.screen + ' ' + $_.saw) -notmatch $cosmetic }).Count
$agentArgs = [ordered]@{ id = $Agent; items = "$Task $ids" }; if ($complex) { $agentArgs.complex = $true }
$wfArgs = [ordered]@{ brief = $out; run = $runName; mode = 'bugfix'; review = $true; mandate = $m; agents = @($agentArgs) }
$wfArgs.agents[0].area = (($checks | ForEach-Object screen) -join '; ').Substring(0, [math]::Min(160, (($checks | ForEach-Object screen) -join '; ').Length))
"brief: $out ($($checks.Count) checks: $ids; model: $(if ($complex) { 'strongest (complex: true)' } else { 'sonnet (small/cosmetic)' }))"
"Workflow args (scriptPath $claude\workflows\dev-wave.js):"
$wfArgs | ConvertTo-Json -Depth 5 -Compress
$tj = Get-KitPath tracking   # durable <kit>/tracking.local.json (orch.ps1 track)
$tracked = (Test-Path $tj) -and @((Get-Content $tj -Raw | ConvertFrom-Json).tasks.PSObject.Properties.Name) -contains $Task
if ($tracked) { "already tracked: $Task" } else { & $KitCmd.orch track add -Task $Task -Discover | Out-Null; "tracking $Task (-Discover)" }
}

# ---------------------------------------------------------------- cleanup: kit-created leftovers (worktrees, browsers, daemons, runtime)
# Self-cleaning for the kit: removes temp things the kit's own scripts, agents and workflows produce, and logs what it freed.
# Runs automatically: at the end of every workflow (Learn step) and once a day from the SessionStart hook (-IfDue, in the background).
#
#   & <workspace>/.claude/skills/orchestrate/orch.ps1 cleanup            # clean now
#   & ... orch.ps1 cleanup -DryRun                                              # show what would go, delete nothing
#   & ... orch.ps1 cleanup -IfDue                                               # only if the last cleanup was > 20 h ago
#
# What it cleans (only kit-created things; never repos, never anything in use):
#   - headless test browsers (<runtime>/cache/chrome-profiles) running > 3 h, or > 30 min when no QA agent is active on the board;
#     then their profile folders idle > 1 day; and when no QA seat/agent is active, only the cleanup.maxBrowserProfiles
#     (kit.local.json, default 4) most recently used profiles are kept - a profile in use is never removed
#   - idle Gradle / Kotlin compile daemons (GBs each) when no gated Gradle build is running
#   - shared web logins (cache/sessions) > 8 h, API tokens (cache/tokens) > 3 days, stop markers (cache/stopped) > 7 days, launch records (work/launches) > 3 days
#   - loose evidence (work/evidence) > 14 days, android shots / temp xml (work/shots, cache/android-tmp) > 3 days
#   - wave reports (work/waves) > 14 days, bug briefs and markdown docs (work/briefs, work/docs) > 30 days, retro and kit audit
#     reports (logs/retros, logs/kit-audits) > 90 days
#   - QA run folders > 30 days (results.json, finalize.json and report.html are kept as a record)
#   - tsc incremental caches > 30 days; gate ledger entries of dead builds
#   - Claude session temp dirs (<OS temp>/claude/<project>/<session>: scratchpad, task outputs) untouched > 7 days
#   - kit test leftovers in the OS temp folder (kit-*, claude-kit-*, wfc.js, gradletest, report-preview.html, ...) > 1 day
#   - worktrees that are finished: remote branch deleted (MR merged + source branch removed), no uncommitted changes,
#     no unpushed work, untouched > 2 h -> dev.ps1 wt remove
#   - local branches whose remote branch is gone, only when the git host shows a merged MR/PR at exactly the branch's tip
#     (nothing on it can be lost; never a checked-out branch) - in the worktrees' repos and every repo under reposRoot
#   -WorktreesOnly runs just those two (no daily stamp): orch.ps1 track starts it in the background when a task's MRs have all
#   merged; dev-wave and test-and-close run the full cleanup at their end. Supervise rounds never run it (too heavy).
#   - log rotation: logs/*.log and the durable .state/learning.jsonl (kept to the newest 5000 lines)
# Paths come from Get-KitPath (paths.json). Everything under <runtime> is disposable; durable state lives at the kit root.
# Claude Code's own transcripts are left to its `cleanupPeriodDays` setting.
function Invoke-Cleanup {
param([switch]$DryRun, [switch]$IfDue, [switch]$Quiet, [switch]$WorktreesOnly, [string[]]$WorktreeRoot = @(), [double]$WorktreeIdleHours = 2)   # -WorktreesOnly: just step 7 (supervise runs it every round)   # WorktreeRoot default: kit.local.json "worktreeRoots" (else <reposRoot>-wt); idle 0 right after a wave finished (still-open MRs are protected by their remote branch)
$ErrorActionPreference = 'SilentlyContinue'
$K = Join-Path (Split-Path $PSScriptRoot) 'dev-kit'
$tmp = Get-KitTemp
if (-not $WorktreeRoot) { $WorktreeRoot = $KitConf.WorktreeRoots }
$keepBranches = '^(' + ((@('main', 'master', 'develop', 'localenv/.+') + @($KitConf.ProtectedBranches | ForEach-Object { [regex]::Escape($_) })) -join '|') + ')$'
$mark = Get-KitPath last-cleanup -Create; $log = Get-KitPath cleanup-log -Create
if ($IfDue -and (Test-Path $mark) -and ((Get-Date) - [datetime](Get-Content $mark -Raw).Trim()).TotalHours -lt 20) { exit 0 }

$now = Get-Date; $freed = 0L; $actions = New-Object System.Collections.ArrayList
function Size($p) { if (Test-Path $p -PathType Leaf) { (Get-Item $p).Length } else { (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
function Gone($path, $why) {
  if (-not (Test-Path $path)) { return }
  $sz = [long](Size $path)
  # Remove-Item -Force also clears read-only files ([IO.Directory]::Delete threw on them and the same dirs were "freed" every run)
  if (-not $DryRun) { try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { [void]$actions.Add(('  FAILED    {0}  ({1}): {2}' -f $path, $why, $_.Exception.Message)); return } }
  $script:freed += $sz
  [void]$actions.Add(('{0,8:N1} MB  {1}  ({2})' -f ($sz / 1MB), $path, $why))
}
function Old($item, $hours) { ($now - $item.LastWriteTime).TotalHours -gt $hours }

if (-not $WorktreesOnly) {   # steps 1-6: everything but worktrees/branches
# 1. headless test browsers left running, then idle profiles
$profiles = Get-KitPath chrome-profiles
$chromes = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|google chrome|microsoft edge)(\.exe)?$' | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match [regex]::Escape($profiles) }
$qaRuns = @(Get-ChildItem (Get-KitPath qa-runs) -Directory | ForEach-Object Name)
$qaActive = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
  Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 -and ($_.run -in $qaRuns -or "$($_.worktrees)" -match 'chrome:') }).Count
$browserLimitH = if ($qaActive) { 3 } else { 0.5 }
foreach ($c in $chromes | Where-Object { $_.ParentId -notin $chromes.Id }) {   # browser roots only
  if (($now - $c.Created).TotalHours -gt $browserLimitH) { [void]$actions.Add("killed headless browser pid $($c.Id) (running $([int]($now - $c.Created).TotalHours) h)"); if (-not $DryRun) { Stop-SysProcess $c.Id } }
}
$inUse = @($chromes | ForEach-Object { if ($_.CommandLine -match 'chrome-profiles[\\/](\d+)') { $Matches[1] } } | Sort-Object -Unique)
foreach ($p in Get-ChildItem $profiles -Directory) { if ($p.Name -notin $inUse -and (Old $p 24)) { Gone $p.FullName 'idle browser profile' } }
# cap: with no QA seat taken (qa.ps1 seat; seats older than 3 h are stale) and no QA agent on the board, keep the N most recently used
$seatsActive = @(Get-ChildItem (Join-Path (Get-KitPath qa-seats) 'seats') -Filter '*.json' | Where-Object { ($now - $_.LastWriteTime).TotalHours -lt 3 }).Count
$maxProfiles = [math]::Max(0, [int]$KitConf.MaxBrowserProfiles)
if (-not $seatsActive -and -not $qaActive) {
  # Chrome rewrites "Local State" when a profile is used/closed; the folder's own time is the fallback
  $left = @(Get-ChildItem $profiles -Directory | Where-Object { Test-Path $_.FullName } | ForEach-Object {
      $ls = Get-Item (Join-Path $_.FullName 'Local State') -Force
      [pscustomobject]@{ dir = $_; used = $(if ($ls) { $ls.LastWriteTime } else { $_.LastWriteTime }) } } | Sort-Object used -Descending)
  foreach ($x in @($left | Select-Object -Skip $maxProfiles)) { if ($x.dir.Name -notin $inUse) { Gone $x.dir.FullName "browser profile beyond the newest $maxProfiles (cleanup.maxBrowserProfiles)" } }
}

# 1b. idle Gradle / Kotlin daemons (they keep GBs after a build) - only when no gated Gradle build is running
$gradleBusy = @(Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json' |
  ForEach-Object { try { $e = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($e.kind -match 'android|gradle' -and (Get-Process -Id $e.pid)) { $e } } catch {} }).Count
if (-not $gradleBusy) {
  foreach ($d in Get-SysProcs -Name '^java(\.exe)?$' | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' }) {
    if (($now - $d.Created).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($d.CommandLine -match 'Kotlin') { 'Kotlin daemon' } else { 'Gradle daemon' }), $d.Id, ($d.WorkingSet / 1GB))); $script:freed += [long]$d.WorkingSet; if (-not $DryRun) { Stop-SysProcess $d.Id } }
  }
}

# 2. logins, tokens, loose evidence, android temp
foreach ($f in Get-ChildItem (Get-KitPath sessions) -File) { if (Old $f 8) { Gone $f.FullName 'expired shared web login' } }
foreach ($f in Get-ChildItem (Get-KitPath tokens) -File) { if (Old $f 72) { Gone $f.FullName 'old API token' } }
foreach ($f in Get-ChildItem (Get-KitPath stopped) -File) { if (Old $f (7 * 24)) { Gone $f.FullName 'stop marker > 7 d' } }
foreach ($f in Get-ChildItem (Get-KitPath evidence) -File) { if (Old $f (14 * 24)) { Gone $f.FullName 'loose evidence > 14 d' } }
foreach ($d in 'android-tmp', 'shots') { foreach ($f in Get-ChildItem (Get-KitPath $d) -Recurse -File) { if (Old $f 72) { Gone $f.FullName "$d temp > 3 d" } } }
foreach ($f in Get-ChildItem (Get-KitPath waves) -File) { if (Old $f (14 * 24)) { Gone $f.FullName 'wave report > 14 d' } }
foreach ($f in Get-ChildItem (Get-KitPath launches) -File) { if (Old $f 72) { Gone $f.FullName 'launch record > 3 d' } }
foreach ($d in 'briefs', 'docs') { foreach ($f in Get-ChildItem (Get-KitPath $d) -File) { if (Old $f (30 * 24)) { Gone $f.FullName "$d > 30 d" } } }
foreach ($f in Get-ChildItem (Get-KitPath retros) -File) { if (Old $f (90 * 24)) { Gone $f.FullName 'retro report > 90 d' } }
foreach ($f in Get-ChildItem (Get-KitPath kit-audits) -File) { if (Old $f (90 * 24)) { Gone $f.FullName 'kit audit report > 90 d' } }

# 3. old QA runs: keep the record, drop the bulk
foreach ($r in Get-ChildItem (Get-KitPath qa-runs) -Directory) {
  if (Old $r (30 * 24)) { foreach ($sub in Get-ChildItem $r.FullName -Recurse -Directory | Where-Object Name -in 'shots', 'evidence', 'scripts') { Gone $sub.FullName 'QA run > 30 d (results/report kept)' } }
}
foreach ($f in Get-ChildItem (Get-KitPath tsbuild) -File) { if (Old $f (30 * 24)) { Gone $f.FullName 'tsc cache > 30 d' } }

# 4. gate ledger: entries of builds that are no longer running
foreach ($f in Get-ChildItem (Join-Path $tmp 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json') {
  try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (-not (Get-Process -Id $e.pid -ErrorAction SilentlyContinue)) { Gone $f.FullName 'dead gate entry' } } catch {}
}

# 5. Claude session temp dirs (scratchpad, task outputs) untouched for a week
foreach ($proj in Get-ChildItem (Join-Path $tmp 'claude') -Directory) {
  foreach ($sess in Get-ChildItem $proj.FullName -Directory | Where-Object Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {   # session ids only
    $newest = Get-ChildItem $sess.FullName -Recurse -File -Force | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $last = if ($newest) { $newest.LastWriteTime } else { $sess.LastWriteTime }
    if (($now - $last).TotalDays -gt 7) { Gone $sess.FullName 'Claude session temp untouched > 7 d' }
  }
}

# 6. kit test leftovers in the OS temp folder
foreach ($f in Get-ChildItem $tmp -Force | Where-Object { $_.Name -match '^(kit-|claude-kit-|wfc\.js$|gradletest$|report-preview\.html$|gate-debug\.ps1$|bad-findings\.json$|audit-test$|kitshots$|tsc\d\.log$|claude-wt-selftest$)' }) {
  if (Old $f 24) { Gone $f.FullName 'kit test leftover' }
}

}

# 7. finished worktrees, then their local branches
# A local branch is deleted only when the git host shows a MERGED MR/PR whose head is exactly this branch's tip: then
# nothing on it is lost (squash merges included). Anything else (unmerged, extra local commits, host unreachable) stays.
function MergedTip($repo, $br) {
  $url = "$(git -C $repo remote get-url origin 2>$null)".Trim()
  # https://host/group/repo(.git) or git@host:group/repo(.git) -> host + group/repo
  if ($url -notmatch '^(?:https?://(?:[^@/]+@)?(?<host>[^/]+)/|[^@]+@(?<host>[^:]+):)(?<path>.+?)(?:\.git)?/?$') { return $null }
  $hostName = $Matches.host; $path = $Matches.path
  $script:HostType = if ($hostName -match 'github') { 'github' } else { 'gitlab' }   # the worktree's own remote decides (lib.ps1 Invoke-HostApi)
  if ($script:HostType -eq 'gitlab') { $env:GITLAB_HOST = $hostName }
  $mrs = Invoke-HostApi "projects/$([uri]::EscapeDataString($path))/merge_requests?source_branch=$([uri]::EscapeDataString($br))&state=merged&per_page=20"
  return @($mrs | ForEach-Object sha)
}
$repos = @{}
foreach ($root in $WorktreeRoot) {
  foreach ($w in Get-ChildItem $root -Directory) {
    $d = $w.FullName
    if (-not (git -C $d rev-parse --is-inside-work-tree 2>$null)) { continue }
    $br = git -C $d rev-parse --abbrev-ref HEAD 2>$null
    if (-not $br -or $br -eq 'HEAD' -or $br -match $keepBranches) { continue }
    if (git -C $d status --porcelain 2>$null) { continue }                                   # uncommitted work
    $newest = (Get-ChildItem $d -File -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue | Where-Object FullName -notmatch '[\\/](node_modules|\.git|target|build)[\\/]' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($newest -and ($now - $newest).TotalHours -lt $WorktreeIdleHours) { continue }
    if (-not (Invoke-GitFetch -Dir $d)) { continue }                                          # offline / auth / timed out: decide nothing
    $heads = git -C $d ls-remote --heads origin $br 2>$null
    if ($LASTEXITCODE -ne 0 -or $heads) { continue }                                          # still on the remote, or remote unreachable (offline/auth)
    $unpushed = git -C $d log --oneline "@{upstream}..HEAD" 2>$null
    if ($LASTEXITCODE -eq 0 -and $unpushed) { continue }
    $main = Split-Path (git -C $d rev-parse --path-format=absolute --git-common-dir 2>$null)   # the repo the worktree belongs to
    # "not on the remote" also fits a fresh worktree whose branch was never pushed (another wave's cleanup at idle 0 deleted
    # agents' new worktrees mid-run): remove only when the host shows a merged MR/PR at exactly this branch's tip
    $tip = (git -C $d rev-parse HEAD 2>$null)
    if (-not $main -or $tip -notin @(MergedTip $main $br)) { continue }
    [void]$actions.Add("worktree $d (branch $br merged + deleted on remote, clean, idle > $WorktreeIdleHours h) -> dev.ps1 wt remove")
    if (-not $DryRun) { & $KitCmd.dev wt remove -Dir $d | Out-Null }
    if ($main) { $repos[$main] = $true }
  }
}
# local branches whose remote branch is gone ([gone]) in the repos above and the configured repos root: worktree-less
# leftovers of merged MRs too (SourceTree lists them all); a branch checked out anywhere is never touched
$roots = @($KitConf.ReposRoot) | Where-Object { $_ -and (Test-Path $_) }
foreach ($r in $roots) { foreach ($c in Get-ChildItem $r -Directory) { if (Test-Path (Join-Path $c.FullName '.git')) { $repos[$c.FullName] = $true } } }
foreach ($repo in @($repos.Keys)) {
  if (-not (git -C $repo rev-parse --git-dir 2>$null)) { continue }
  if (-not (Invoke-GitFetch -Dir $repo)) { continue }                                       # offline / auth / timed out: decide nothing
  $out = @(git -C $repo worktree list --porcelain 2>$null | Where-Object { $_ -like 'branch refs/heads/*' } | ForEach-Object { $_.Substring(18) })
  foreach ($line in git -C $repo for-each-ref --format='%(refname:short)|%(objectname)|%(upstream:track)' refs/heads) {
    $b, $tip, $track = $line -split '\|', 3
    if ($track -ne '[gone]' -or $b -match $keepBranches -or $b -in $out) { continue }
    $merged = MergedTip $repo $b
    if (-not $merged -or $tip -notin $merged) { continue }                                     # not proven merged at this exact tip
    [void]$actions.Add("branch $b in $repo (MR merged at its tip, remote branch deleted) -> deleted")
    if (-not $DryRun) { git -C $repo branch -D $b 2>$null | Out-Null }
  }
}

# 8. rotate logs
if (-not $WorktreesOnly) {
foreach ($f in @(@(Get-ChildItem (Get-KitPath logs) -Filter '*.log' -File | ForEach-Object FullName) + (Get-KitPath signals))) {
  if ((Test-Path $f) -and @(Get-Content $f).Count -gt 5000) { if (-not $DryRun) { $keep = Get-Content $f -Tail 5000; Set-Content $f $keep }; [void]$actions.Add("rotated $f to 5000 lines") }
}

}
$summary = "$(if ($DryRun) { '[dry run] would free' } else { 'freed' }) $([math]::Round($freed / 1MB, 1)) MB in $($actions.Count) action(s)"
if (-not $DryRun) {
  if (-not $WorktreesOnly) { $now.ToString('s') | Set-Content $mark }   # a worktree sweep is not the daily cleanup
  "$($now.ToString('s')) $summary" | Add-Content $log; $actions | ForEach-Object { "  $_" } | Add-Content $log
}
if (-not $Quiet) { $summary; $actions }
$global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------- deploy intest: tasks whose MRs are live -> inTest
# Move promoted tasks to "in test" once their MRs are really deployed on a test environment, judged from the CI (qa-kit qa.ps1 deployed), never from memory.
#
#   $M = '<workspace>/.claude/skills/orchestrate/orch.ps1 deploy intest'
#   & $M                 # plan only: one line per candidate (MARK / WAIT / SKIP), nothing changes
#   & $M -Apply          # set the tracker status to inTest + one comment per task naming the environments and MRs
#   & $M -Apply -Quiet   # only print the tasks it changed (for a loop)
#   & $M -Task abc123,abc124 -Apply
#
# Candidates: the owner's tasks whose tracker status is promoted, from (a) .state/tracking.json (orch.ps1 track) and (b) the tracker lists named in
# kit.local.json "trackerLists" (ClickUp only: ids of lists; tasks assigned to the tracker owner). A task's MRs come from tracking, else from a
# merged-MR search for its tracker tag (<tracker tag><id>) in "trackerRepos". A task is marked only when it has MRs, every MR is MERGED and every
# MR is DEPLOYED on at least one test deploy target (production, critical and emulator-lane targets never count); any MR with NO-TARGET / MANUAL /
# NOT-DEPLOYED keeps the task promoted (WAIT / SKIP with the reason). Several products on one deploy branch: "productTargets" in kit.local.json maps the
# paths an MR changes to the target that must have it, e.g. [{ "pathRegex": "^product-a/", "targetRegex": "^a-", "label": "product A test env" }];
# without it any deployed test target is enough.
# Tasks the owner moved on by hand (status no longer promoted) are never touched. Safe to run repeatedly.
function Invoke-MarkInTest {
param([switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
$ErrorActionPreference = 'SilentlyContinue'
$group = $KitConf.GitlabGroup
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }

# --- candidates -------------------------------------------------------------------------------------------------------------------
$cand = [ordered]@{}   # task id -> @{ mrs = @(); name = '' }
$trackFile = Get-KitPath tracking
$track = if ($trackFile -and (Test-Path $trackFile)) { Get-Content $trackFile -Raw | ConvertFrom-Json } else { $null }
if ($track) { foreach ($p in $track.tasks.PSObject.Properties) { $cand[$p.Name] = @{ mrs = @($p.Value.mrs); name = '' } } }
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
$lists = @(Get-KitValue 'trackerLists' @()) | Where-Object { $_ } | Select-Object -Unique
if ($lists.Count) {   # any backend through the tracker adapter (Get-TrackerTasks): lists / repos / project keys
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l 'promoted') } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name } } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes -Task a,b as one string: split it
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }

$productTargets = @(Get-KitValue 'productTargets' @())   # which test env a changed path needs; none configured = any deployed test env
$pathMemo = @{}
function Get-MrPaths([string]$mr) {   # files an MR changes (decides which product's test environment must have it)
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = Invoke-HostApi "projects/$(Get-HostProject $repo)/merge_requests/$iid/changes"
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

# --- one pass ---------------------------------------------------------------------------------------------------------------------
$marked = 0; $wait = 0
foreach ($id in $cand.Keys) {
  $info = Get-TrackerTask $id
  if (-not $info) { continue }
  if (-not (Test-TrackerStatus ([string]$info.status) 'promoted')) { continue }   # only promoted tasks; never override a person's status
  $name = if ($info.name) { $info.name } else { $cand[$id].name }
  $short = if ($name.Length -gt 70) { $name.Substring(0, 70) } else { $name }
  $mrs = @($cand[$id].mrs | Where-Object { $_ })
  if (-not $mrs.Count -and $KitConf.TrackerRepos) {   # untracked task: find its merged MRs by the tracker tag
    $tag = "$($KitConf.TrackerTag)$id"
    foreach ($r in @($KitConf.TrackerRepos)) {
      $res = Invoke-HostApi "projects/$(Get-HostProject $r)/merge_requests?search=$tag&state=merged&per_page=20"
      foreach ($m in @($res)) { if ($m.iid -and ("$($m.title) $($m.source_branch)" -match [regex]::Escape($tag))) { $mrs += "$r!$($m.iid)" } }
    }
    $mrs = @($mrs | Select-Object -Unique)
  }
  if (-not $mrs.Count) { Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $live = @(); $why = $null
  foreach ($mr in $mrs) {
    $rows = @(& $KitCmd.qa deployed -Mrs $mr -Json 2>$null | Out-String | ConvertFrom-Json)
    # only real test environments count (not prod, not the emulator-lane APK); a merge sitting on another product's deploy branch is no proof
    $ok = @($rows | Where-Object { $_.state -eq 'DEPLOYED' -and $_.target -notmatch 'prod|critical|lane' })
    $paths = Get-MrPaths $mr
    $missing = @(); $matched = $false
    foreach ($pt in $productTargets) {   # kit.local.json productTargets: [{ pathRegex, targetRegex, label }]
      if ($paths | Where-Object { $_ -match $pt.pathRegex }) { $matched = $true; if (-not ($ok | Where-Object { $_.target -match $pt.targetRegex })) { $missing += $pt.label } }
    }
    if (-not $matched -and -not $ok.Count) { $missing += 'any test env' }
    if ($ok.Count -and -not $missing.Count) { $live += "$mr on $((($ok | ForEach-Object { $_.target }) -join '+'))"; continue }
    $r0 = $rows | Where-Object { $_.state -ne 'DEPLOYED' } | Select-Object -First 1
    $why = "$mr not live on: " + $(if ($missing.Count) { $missing -join ', ' } else { 'a test env' }) + $(if ($r0) { " ($($r0.state): $($r0.detail))" } else { '' }); break
  }
  if ($why) { $wait++; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    Set-TrackerStatus $id 'inTest'
    Add-TrackerComment $id ("In test: every MR of this task is deployed on a test environment (checked from the CI, " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "): " + ($live -join '; ') + '.')
    $marked++; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
if (-not $Quiet) { "mark-in-test: $($cand.Count) candidate(s), $marked marked, $wait waiting on a deploy" }
}

# ---------------------------------------------------------------- deploy merge: main line into a deploy branch (hooks run)
# Merges a source branch (the repo's main line) into a deploy branch (repos[].deploys[].branch in kit.local.json, e.g. staging)
# so merged fixes reach the test environment.
# Automates the one conflict rule that is always safe: a deploy-branch file that is byte-identical to SOME earlier version of the
# same file on the source branch (it came in through an earlier squashed/cherry-picked merge) takes the source's current version.
# Any other conflict stops the script with the list, for a human or agent to resolve.
#
#   & <kit>/skills/orchestrate/orch.ps1 deploy merge -Repo <main checkout> -To <deploy branch> [-From <branch>] [-Push] [-Check <dir to compile>]
#
# -From default: kit.local.json repos[].target of this checkout, else the remote's default branch (origin/HEAD), else main.
#
# Steps: fresh worktree from origin/<To> (dev.ps1 wt new), merge --no-ff --no-commit origin/<From>, auto-resolve as above, ALWAYS commit
# with hooks (dev.ps1 wt commit; a plain merge commit skips pre-commit and CI jobs that check its marker fail), optional compile (dev.ps1 check -Dir <worktree>/<Check>), then with -Push a plain (fast-forward) push to <To>.
# Without -Push it stops after the commit so you can look first. Prints the worktree; remove it afterwards with dev.ps1 wt remove.
function Invoke-DeployMerge {
param(
  [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$To, [string]$From,
  [string]$Check, [switch]$Push, [int]$History = 300
)
$ErrorActionPreference = 'Stop'
$K = $PSScriptRoot
if (-not $From) {
  $rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
  $From = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and $_.target -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1 -ExpandProperty target
  if (-not $From) { $h = (git -C $Repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null); if ($h) { $From = ($h -replace '^origin/', '').Trim() } }
  if (-not $From) { $From = 'main' }
  "source branch: $From"
}
$name = 'deploymerge-' + ($To -replace '[^\w]+', '-')
$br = "deploy/$($To -replace '[^\w]+', '-')-$(Get-Date -Format yyyyMMddHHmm)"
$out = & $KitCmd.dev wt new -Repo $Repo -Branch $br -Target $To -Name $name
$wt = ($out | Where-Object { $_ -match '^worktree:\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
if (-not $wt) { throw "dev.ps1 wt new failed: $out" }
"worktree: $wt"
git -C $wt fetch -q origin $From $To
if ($LASTEXITCODE) { "fetch of origin $From $To FAILED (exit $LASTEXITCODE): wrong -From/-To or offline; worktree left at $wt"; exit 1 }
$ahead = "$(git -C $wt rev-list --count "origin/$To..origin/$From")".Trim()
if ($LASTEXITCODE -or $ahead -notmatch '^\d+$') { "rev-list origin/$To..origin/$From FAILED: '$ahead'; worktree left at $wt"; exit 1 }   # [int]'' is 0: read as 'nothing to merge'
if ([int]$ahead -eq 0) { & $KitCmd.dev wt remove -Dir $wt -Force | Out-Null; git -C $Repo branch -D $br 2>$null | Out-Null; "nothing to merge: origin/$From has no commits that origin/$To lacks (worktree removed)"; exit 0 }
$mo = git -C $wt merge --no-ff --no-commit "origin/$From" 2>&1; $mrc = $LASTEXITCODE   # committed below through dev.ps1 wt commit (hooks)
$mo | Select-Object -Last 3
$conf = @(git -C $wt diff --name-only --diff-filter=U)
if ($mrc -and -not $conf.Count) { "merge FAILED (not a conflict) in $wt"; exit 1 }
$left = @()
foreach ($f in $conf) {
  $theirs = git -C $wt rev-parse "origin/${To}:$f" 2>$null   # the deploy branch's blob before the merge
  $known = $false
  $fromHas = $null -ne (git -C $wt rev-parse -q --verify "origin/${From}:$f" 2>$null)   # deleted on From (modify/delete): no --theirs side
  if ($theirs -and $fromHas) { foreach ($c in @(git -C $wt rev-list -n $History "origin/$From" -- $f)) { if ((git -C $wt rev-parse "${c}:$f" 2>$null) -eq $theirs) { $known = $true; break } } }
  if ($known) { git -C $wt checkout --theirs -- $f; git -C $wt add -- $f; "auto: $f (deploy copy = an older $From version -> took $From)" }
  else { $left += $f }
}
if ($left.Count) { "UNRESOLVED (deploy branch has its own changes): "; $left | ForEach-Object { "  $_" }; "Resolve in $wt, git add, then dev.ps1 wt commit -Dir $wt -NoStage and push yourself."; exit 2 }
$msg = "chore(deploy): merge $From into $To" + $(if ($conf.Count) { "`n`nAdd/add conflicts from an earlier squashed merge: the $To copies equalled older $From versions, so $From's current version was taken." })
& $KitCmd.dev wt commit -Dir $wt -NoStage -Message $msg
if ($LASTEXITCODE) { "commit FAILED (hooks?) in $wt"; exit 1 }
if ($Check) { & $KitCmd.dev check -Dir (Join-Path $wt $Check); if ($LASTEXITCODE) { "compile FAILED - not pushing"; exit 1 } }
if (-not $Push) { "ready: review $wt, then push with: git -C $wt push origin HEAD:$To"; exit 0 }
git -C $wt fetch -q origin $To
git -C $wt merge-base --is-ancestor "origin/$To" HEAD
if ($LASTEXITCODE) { "origin/$To moved while merging - re-run"; exit 1 }
git -C $wt push origin "HEAD:$To"
if ($LASTEXITCODE) { "push FAILED (exit $LASTEXITCODE): nothing reached $To; worktree kept: $wt"; exit 1 }
"pushed $(git -C $wt rev-parse --short HEAD) to $To ($ahead commits from $From)"
}

# ---------------------------------------------------------------- learn: signals + the one LESSONS.md (a section per skill)
# Record one learning signal (anything that cost time, failed, surprised you, or worked unusually well); keep the lessons short.
#   & $O learn -Skill dev-kit -Kind friction -Text "<what happened + what fixed it>" [-Ref <id>]
#   & $O learn -Read -Skill dev-kit            # step 0 of every skill: that skill's section of LESSONS.md (+ LESSONS.local.md)
#   & $O learn -Show [-Last 30] · -Stats       # recent signals / counts since the last retro
#   & $O learn -Skill qa-kit -Lesson "(2×) <one actionable line>" [-Project <name>]   # new active lesson (top of the section)
#   & $O learn -Skill dev-kit -Bump "<unique words>" [-Append "<clause>"] · -Fixed "<unique words>" · -Trim [-Max 40]
# LESSONS.md (kit root) = "## <skill>" sections of active one-line rules, newest first, then "## History" (moved lines, verbatim,
# never read for work). Org / project lessons (-Project, or a line that holds an orgTerms word) go to the git-ignored
# LESSONS.local.md with the same shape: the published kit stays generic and the pre-push gate never trips on a lesson.
# -Skill: orchestrate | dev-kit | qa-kit | android-swarm | local-env | kit-audit | tech-audit
# -Kind : friction | failure | defect-missed | false-positive | rule-violation | stale-env | flaky | idea | win
# Signals: .state/learning.jsonl (Get-KitPath signals); last retro: .state/learning.stamp. Exit codes: 0 ok · 1 no match · 2 usage.
function Invoke-Learn {
  param(
    [string]$Skill, [ValidateSet('friction', 'failure', 'defect-missed', 'false-positive', 'rule-violation', 'stale-env', 'flaky', 'idea', 'win')][string]$Kind,
    [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
    [switch]$Show, [int]$Last = 30, [switch]$Stats, [switch]$Read,
    [string]$Lesson, [string]$Project, [string]$Fixed, [string]$Bump, [string]$Append, [switch]$Trim, [int]$Max = 40
  )
  $file = Get-KitPath signals -Create
  $mark = Get-KitPath last-retro
  $pub = Join-Path $KitConf.Kit 'LESSONS.md'; $loc = Join-Path $KitConf.Kit 'LESSONS.local.md'
  if ($Show) { if (Test-Path $file) { Get-Content $file -Tail $Last | ForEach-Object { $s = $_ | ConvertFrom-Json; '{0} {1,-13} {2,-15} {3}{4}' -f ([datetime]$s.at).ToString('yyyy-MM-dd HH:mm'), $s.skill, $s.kind, $s.text, $(if ($s.ref) { " [$($s.ref)]" }) } }; return }
  if ($Stats) {
    $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
    $all = if (Test-Path $file) { @(Get-Content $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [datetime]$_.at -gt $since }) } else { @() }
    "signals since last retro ($(if ($since -eq [datetime]::MinValue) { 'never' } else { $since.ToString('d MMM HH:mm') })): $($all.Count)"
    $all | Group-Object skill, kind | Sort-Object Count -Descending | ForEach-Object { '  {0,3}  {1}' -f $_.Count, $_.Name }
    return
  }
  # a file's lines + the [start, end) range of "## <name>" (end = next "## " or EOF)
  $load = { param($f) if (Test-Path $f) { , [Collections.Generic.List[string]]@(([IO.File]::ReadAllText($f) -replace "`r", '') -split "`n") } else { , [Collections.Generic.List[string]]::new() } }   # comma: keep the List (not unrolled)
  $range = { param($L, $name) $s = $L.IndexOf("## $name"); if ($s -lt 0) { return $null }; $e = $s + 1; while ($e -lt $L.Count -and $L[$e] -notmatch '^## ') { $e++ }; , @($s, $e) }
  if ($Read) {
    if (-not $Skill) { 'usage: learn -Read -Skill <skill>'; exit 2 }
    foreach ($f in $pub, $loc) {
      $L = & $load $f; $r = & $range $L $Skill; if (-not $r) { continue }
      $lines = @($L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^(##|###|- )' })
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
    if ($f -eq $loc -and -not (Test-Path $loc)) { [IO.File]::WriteAllText($loc, "# Kit lessons - org / project (LOCAL ONLY: git-ignored, never published)`nRead with LESSONS.md at step 0 (learn -Read prints both). Same shape: ## <skill>, one line each.`n") }
    if ($orgWord -and -not $Project) { "lesson names an org term: written to LESSONS.local.md (never published)" }
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
      if ($hit.Count -ne 1) { "-Bump must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; exit 1 }
      $s = $L[$hit[0]]
      if ($Append) { $c = $Append.Trim().TrimEnd('.'); $s = if ($s -match '^(.*?)\.?(\s*\(\d+×\))$') { "$($Matches[1]). $c.$($Matches[2])" } else { "$($s.TrimEnd('.')). $c." } }
      $m = [regex]::Match($s, '\((\d+)×\)')
      $L[$hit[0]] = if ($m.Success) { $s.Remove($m.Index, $m.Length).Insert($m.Index, "($([int]$m.Groups[1].Value + 1)×)") } else { "$s (2×)" }
      "lesson bumped in ## $Skill"
    }
    if ($Fixed) {
      $hit = @(& $idx | Where-Object { $L[$_].Contains($Fixed) })
      if ($hit.Count -ne 1) { "-Fixed must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; exit 1 }
      $moved.Add(($L[$hit[0]] -replace '^- (\(fixed in kit\) )?', '- (fixed in kit) ')); $L.RemoveAt($hit[0]); $r = & $range $L $Skill
    }
    # cap per section: the oldest (bottom-most) general lines first (project lines below "### Project:" stay)
    while (@(& $idx).Count -gt $Max) {
      $gen = @(& $idx | Where-Object { $i = $_; -not @($r[0]..$i | Where-Object { $L[$_] -like '### *' }).Count })
      $i = if ($gen.Count) { $gen[-1] } else { @(& $idx)[-1] }
      $moved.Add($L[$i]); $L.RemoveAt($i); $r = & $range $L $Skill
    }
    if ($moved.Count) {
      if ($L.IndexOf('## History') -lt 0) { $L.Add(''); $L.Add('## History'); $L.Add('Moved by learn (-Fixed / -Trim), verbatim, oldest first. Never read for work; /kit-retro checks it for regressions.') }
      $h = & $range $L 'History'; $sub = "### $Skill"; $p = -1; for ($i = $h[0]; $i -lt $h[1]; $i++) { if ($L[$i] -eq $sub) { $p = $i } }
      if ($p -lt 0) { $L.Add($sub); foreach ($x in $moved) { $L.Add($x) } }
      else { $q = $p + 1; while ($q -lt $L.Count -and $L[$q] -match '^- ') { $q++ }; foreach ($x in $moved) { $L.Insert($q++, $x) } }
    }
    [IO.File]::WriteAllText($f, (($L -join "`n") + "`n"))
    "$(Split-Path $f -Leaf) ## ${Skill}: $(@(& $idx).Count) lines (max $Max)$(if ($moved.Count) { "; moved $($moved.Count) to ## History" })"
    return
  }
  if (-not ($Skill -and $Kind -and $Text)) { 'need -Skill -Kind -Text (or -Read / -Show / -Stats / -Lesson / -Bump / -Fixed / -Trim)'; exit 2 }
  $sig = [ordered]@{ at = (Get-Date).ToString('s'); skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source } | ConvertTo-Json -Compress
  Invoke-KitLocked $file { Add-Content -LiteralPath $file $sig -Encoding utf8 }   # many agents record at once: locked append
  "recorded ($Skill/$Kind)"
}

# ---------------------------------------------------------------- decide: decision pauses (a business-logic change the task did not ask for, or several valid paths)
#   & $O decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options "A: ..","B: .." [-Recommend A] [-Contracts <brief>.contracts.md]
#   & $O decide list [-Pending] [-Json]          # the coordinator (supervise shows pending ones as ACT)
#   & $O decide answer -Id <id> -Answer "<the owner's words>" [-By <who>]
#   & $O decide get -Id <id> · wait -Id <id> [-MaxMinutes 50]   # the agent / the workflow waits; exit 0 answered, 1 still pending
# A decision request stops only that item ("needs decision"); the workflow continues the others and resumes the item with the answer.
# Files: <runtime>/work/decisions/<id>.json; the question and the answer are also appended to the contracts file (agents re-read it).
function Invoke-Decide {
  param([Parameter(Position = 0)][ValidateSet('ask', 'list', 'answer', 'get', 'wait')][string]$Action = 'list',
    [string]$Run, [string]$Agent, [string]$Item, [string]$Question, [string[]]$Options = @(), [string]$Recommend, [string]$Contracts,
    [string]$Id, [string]$Answer, [string]$By = 'owner', [int]$MaxMinutes = 50, [switch]$Pending, [switch]$Json)
  $dir = Get-KitPath decisions -Create
  $get = { param($i) $f = Join-Path $dir "$i.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
  $save = { param($o) $f = Join-Path $dir "$($o.id).json"; Invoke-KitLocked $f { $o | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding utf8 } }
  $note = { param($file, $text) if ($file -and (Test-Path (Split-Path $file))) { Add-Content -LiteralPath $file "`n$text" -Encoding utf8 } }
  switch ($Action) {
    'ask' {
      if (-not ($Agent -and $Question)) { 'usage: decide ask -Run <run> -Agent <id> -Item <item> -Question "<q>" -Options "A: ..","B: .." [-Recommend A] [-Contracts <file>]'; exit 2 }
      $opts = @($Options | ForEach-Object { "$_" -split ',(?=\s*[A-Za-z0-9]+\s*:)' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # 'A: ..','B: ..'
      $o = [ordered]@{ id = "d-$(Get-Date -Format yyyyMMddHHmmss)-$($Agent.ToLower() -replace '[^\w-]', '')"; run = $Run; agent = $Agent; item = $Item; question = $Question
        options = $opts; recommend = $Recommend; contracts = $Contracts; status = 'pending'; at = (Get-Date).ToString('s') }
      & $save ([pscustomobject]$o)
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

# ---------------------------------------------------------------- deploy: the batched deploy check (dev flow step 5)
#   & $O deploy plan [-Env <target>] [-Json]          # per test env: merged-not-deployed MRs (all sessions), last deploy, window -> ASK | WAIT | NOTHING | DEPLOYING
#   & $O deploy request -Mrs <repo>!<iid>,... -Run <run> [-Note "<what>"]   # a workflow / session registers work that needs a deploy (then plan)
#   & $O deploy record -Env <target> [-Mrs ...] [-By <person>] [-Note ..]   # after a person-approved deploy: log it, clear those pending MRs
#   & $O deploy merge -Repo <checkout> -To <deploy branch> [-From <branch>] [-Check <module>] [-Push]   # main line into a deploy branch, hooks run
#   & $O deploy intest [-Task <ids>] [-Apply] [-Quiet]  # tasks whose MRs are all live on a test env -> tracker inTest (+ comment)
# Deploys always need a person's yes: the coordinator shows plan's batch and asks ONCE per env; never more than one deploy per env
# within deploy.minIntervalHours (kit.local.json: a number, or { "default": 4, "<target>": 24 }). Neighbours count: every tracked
# task (all sessions write tracking), every pending request (work/deploys/pending.json) and the CI's last deploy on the deploy branch.
# -Offline <fixture.json> (tests): { mrs: { "<ref>": { state, rows: [ { target, state, detail } ] } }, lastCi: { "<target>": "<iso>" } }
function Invoke-Deploy {
  param([Parameter(Position = 0)][ValidateSet('plan', 'request', 'record', 'merge', 'intest')][string]$Action = 'plan',
    [string]$Env, [string[]]$Mrs = @(), [string]$Run, [string]$Note, [string]$By = 'owner', [switch]$Json, [string]$Offline, [int]$Days = 14,
    [string]$Repo, [string]$To, [string]$From, [string]$Check, [switch]$Push, [int]$History = 300,
    [switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
  if ($Action -eq 'merge') { Invoke-DeployMerge -Repo $Repo -To $To -From $From -Check $Check -Push:$Push -History $History; return }
  if ($Action -eq 'intest') { Invoke-MarkInTest -Apply:$Apply -Quiet:$Quiet -Task $Task; return }
  $Mrs = @(Split-KitList $Mrs)
  $dd = Get-KitPath deploys -Create; $pf = Join-Path $dd 'pending.json'; $log = Get-KitPath deploy-log -Create
  $fx = if ($Offline) { Get-Content $Offline -Raw | ConvertFrom-Json } else { $null }
  if ($Action -eq 'request') {
    if (-not $Mrs.Count) { 'usage: deploy request -Mrs <repo>!<iid>,... -Run <run> [-Note ..]'; exit 2 }
    Invoke-KitLocked $pf { $p = if (Test-Path $pf) { Get-Content $pf -Raw | ConvertFrom-Json } else { [pscustomobject]@{ requests = @() } }
      $p.requests = @(@($p.requests) + [pscustomobject]@{ at = (Get-Date).ToString('s'); run = $Run; mrs = $Mrs; note = $Note }); $p | ConvertTo-Json -Depth 5 | Set-Content $pf -Encoding utf8 }
    "requested a deploy for $($Mrs -join ', ') ($Run)"
  }
  if ($Action -eq 'record') {
    if (-not $Env) { 'usage: deploy record -Env <target> [-Mrs ..] [-By ..] [-Note ..]'; exit 2 }
    Invoke-KitLocked $log { Add-Content -LiteralPath $log ([ordered]@{ at = (Get-Date).ToString('s'); target = $Env; mrs = $Mrs; by = $By; note = $Note } | ConvertTo-Json -Compress) -Encoding utf8 }
    if (Test-Path $pf) {
      Invoke-KitLocked $pf { $p = Get-Content $pf -Raw | ConvertFrom-Json
        foreach ($q in @($p.requests)) { $q.mrs = @(@($q.mrs) | Where-Object { $Mrs.Count -and $_ -notin $Mrs }) }
        $p.requests = @(@($p.requests) | Where-Object { @($_.mrs).Count }); $p | ConvertTo-Json -Depth 5 | Set-Content $pf -Encoding utf8 }
    }
    "recorded the deploy of $Env$(if ($Mrs.Count) { " ($($Mrs -join ', '))" }). Next: once qa.ps1 deployed shows them live, orch.ps1 deploy intest -Apply"
    return
  }
  # ---- plan
  $repos = @(Get-KitValue 'repos' @())
  $targets = @($repos | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and -not $_.laneApk -and $_.target -notmatch '(?i)prod|critical' } | ForEach-Object target | Select-Object -Unique)
  if ($Env) { $targets = @($targets | Where-Object { $_ -eq $Env }) }
  $taskOf = @{}; $cand = [ordered]@{}
  $tr = Read-KitTracking
  foreach ($t in $tr.tasks.Values) {
    if ($t.done -and $t.doneAt -and ((Get-Date) - [datetime]$t.doneAt).TotalDays -gt $Days) { continue }
    foreach ($m in @($t.mrs)) { $taskOf[$m] = $t.task; $cand[$m] = 'tracked' }
  }
  $pend = if (Test-Path $pf) { @((Get-Content $pf -Raw | ConvertFrom-Json).requests) } else { @() }
  foreach ($q in $pend) { foreach ($m in @($q.mrs)) { $cand[$m] = "requested by $($q.run)" } }
  foreach ($m in $Mrs) { $cand[$m] = "requested by $Run" }
  $rows = @{}
  foreach ($m in $cand.Keys) {
    $rows[$m] = if ($fx) { @($fx.mrs.$m.rows) } else { @(& $KitCmd.qa deployed -Mrs $m -Json 2>$null | Out-String | ConvertFrom-Json) }
  }
  $win = Get-KitSetting 'deploy.minIntervalHours' 4
  $winOf = { param($t) if ($win -is [psobject] -and $win.PSObject.Properties.Name -contains $t) { [double]$win.$t } elseif ($win -is [psobject] -and $win.PSObject.Properties.Name -contains 'default') { [double]$win.default } elseif ($win -is [psobject]) { 4 } else { [double]$win } }
  $logged = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $plan = foreach ($t in $targets) {
    $batch = @(foreach ($m in $cand.Keys) { foreach ($r in @($rows[$m] | Where-Object { $_.target -eq $t -and $_.state -in 'NOT-DEPLOYED', 'MANUAL' })) { [pscustomobject]@{ mr = $m; task = $taskOf[$m]; state = $r.state; detail = $r.detail; why = $cand[$m] } } })
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
            if ($pl.status -eq 'success') { $at = [datetime]$(if ($pl.updated_at) { $pl.updated_at } else { $pl.created_at }); if (-not $last -or $at -gt $last) { $last = $at; $src = "CI $($r.name) $($d.branch)" }; break }
          } } }
    }
    $h = & $winOf $t
    $next = if ($last) { $last.AddHours($h) } else { $null }
    $status = if (-not $batch.Count) { 'NOTHING' } elseif ($running) { 'DEPLOYING' } elseif ($next -and (Get-Date) -lt $next) { 'WAIT' } else { 'ASK' }
    [pscustomobject]@{ target = $t; status = $status; last = $(if ($last) { $last.ToString('s') }); lastSource = $src; windowHours = $h; nextAllowed = $(if ($next) { $next.ToString('s') }); mrs = $batch; pending = @($pend | ForEach-Object { "$($_.run) $($_.at)" }) }
  }
  if ($Json) { ConvertTo-Json @($plan) -Depth 6; return }
  foreach ($p in $plan) {
    $when = switch ($p.status) { 'WAIT' { " until $(([datetime]$p.nextAllowed).ToString('dd MMM HH:mm')) (one deploy per $($p.windowHours) h)" } 'ASK' { ': ask the owner ONCE with this batch' } 'DEPLOYING' { ': a deploy pipeline runs now (wait, then plan again)' } default { '' } }
    "DEPLOY $($p.target): $($p.status)$when | last $(if ($p.last) { "$(([datetime]$p.last).ToString('dd MMM HH:mm')) ($($p.lastSource))" } else { 'unknown' })"
    foreach ($b in $p.mrs) { "  - $($b.mr)$(if ($b.task) { " task $($b.task)" }) $($b.state): $($b.detail) [$($b.why)]" }
  }
  if (-not @($plan).Count) { 'no test deploy targets in kit.local.json repos[].deploys' }
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
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
    default { Get-Content $PSCommandPath -TotalCount 18 | Select-Object -Skip 1; exit 2 }
  }
}
