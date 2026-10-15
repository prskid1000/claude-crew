<#
Shared agent board: every agent (in any workflow or session) says what it's working on, so concurrent agents see each other,
duplicates are caught at once, and two agents never write the same worktree.

  $B = '<workspace>/.claude/skills/orchestrate/scripts/board.ps1'
  & $B join  -Agent A1 -Area "checkout form + view" -Items "FEAT-12,FEAT-13" -Claims <wt root>/a1-backend,<wt root>/a1-frontend [-Run checkout-v2] [-Contracts <file>] [-Resume]
        (-Claims = anything exclusive: worktree paths, emulator serials like emulator-5556, browser ports like chrome:9601)
        (-Resume = you continue a stopped agent's work (RESUME_BRIEF): take over its entry when you claim the same worktrees)
        -> prints the other active agents, warnings, the contracts file to follow, and LAST the SESSION token (keep it)
  & $B beat  -Session <token> [-Status "testing web"]   # heartbeat; do it when you start a build/test or push (cheap)
  & $B show  [-Run checkout-v2]                           # who is doing what right now (+ warnings)
  & $B check -Worktree <dir> -Session <token>             # is anyone else writing here? exit 1 = stop and tell the coordinator
  & $B leave -Session <token> [-Status done]

Entries go stale after 20 min without a heartbeat. On join, an entry of the same agent id in the same run is:
  reused     - same claims and a heartbeat in the last 2 min (a quick re-join): the same SESSION token comes back (REJOIN);
  taken over - its holder is gone (its pid is not running and no heartbeat for 3 min), or you pass -Resume and claim the same
               worktrees: it is marked left and you get a new session (TAKEOVER). If its holder was still alive after all, its
               next beat prints TAKEN OVER and exits 1, and `check` names you as the other writer: it must stop without writing.
Warnings:
  DUPLICATE  - the same agent id is active in two sessions (e.g. a resumed copy without -Resume): the newer one must stop.
  CLAIM      - another active agent claims the same worktree / phone / port.
  AREA       - another active agent in the same run lists overlapping items.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('join', 'beat', 'show', 'check', 'leave')][string]$Action,
  [string]$Agent, [string]$Area = '', [string]$Items = '', [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree, [switch]$Resume
)
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts/kitpaths.ps1')   # Get-KitPath (kitpaths.json)
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
