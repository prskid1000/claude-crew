<#
Shared agent board: every agent (in any workflow or session) says what it's working on, so concurrent agents see each other,
duplicates are caught at once, and two agents never write the same worktree.

  $B = '<workspace>\.claude\skills\orchestrate\scripts\board.ps1'
  & $B join  -Agent A1 -Area "checkout form + view" -Items "FEAT-12,FEAT-13" -Claims <wt root>\a1-backend,<wt root>\a1-frontend [-Run checkout-v2] [-Contracts <file>]
        (-Claims = anything exclusive: worktree paths, emulator serials like emulator-5556, browser ports like chrome:9601)
        -> prints a SESSION token (keep it), the other active agents, warnings, and the contracts file to follow
  & $B beat  -Session <token> [-Status "testing web"]   # heartbeat; do it when you start a build/test or push (cheap)
  & $B show  [-Run checkout-v2]                           # who is doing what right now (+ warnings)
  & $B check -Worktree <dir> -Session <token>             # is anyone else writing here? exit 1 = stop and tell the coordinator
  & $B leave -Session <token> [-Status done]

Entries go stale after 20 min without a heartbeat. Warnings:
  DUPLICATE  - the same agent id is active in two sessions (e.g. a resumed copy): the newer one must stop.
  CLAIM      - another active agent claims the same worktree / phone / port.
  AREA       - another active agent in the same run lists overlapping items.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('join', 'beat', 'show', 'check', 'leave')][string]$Action,
  [string]$Agent, [string]$Area = '', [string]$Items = '', [Alias('Claims')][string[]]$Worktrees = @(), [string]$Run = '', [string]$Contracts = '',
  [string]$Session, [string]$Status = '', [string]$Worktree
)
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$dir = Join-Path $rt 'board'; New-Item -ItemType Directory -Force $dir | Out-Null
$staleMin = 20
function All { foreach ($f in Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue) { try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; $e | Add-Member -Force NoteProperty file $f.FullName; $e } catch {} } }
function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
function Norm($p) { if (-not $p) { return }; if ($p -match '[\\/:]') { [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower() } else { $p.ToLower() } }   # paths or plain claims (emulator-5556, chrome:9601)
function Warnings($me, $act) {
  foreach ($o in $act | Where-Object { $_.session -ne $me.session }) {
    if ($o.agent -eq $me.agent -and (-not $me.run -or $o.run -eq $me.run)) { "DUPLICATE: agent $($o.agent) is also active in session $($o.session) (joined $(([datetime]$o.joined).ToString('HH:mm'))). The newer session must stop without writing." }
    $shared = @($o.worktrees | ForEach-Object { Norm $_ }) | Where-Object { $_ -in @($me.worktrees | ForEach-Object { Norm $_ }) }
    if ($shared) { "CLAIM: $($o.agent) also claims $($shared -join ', ') (worktree / phone / port). Don't both use it - tell the coordinator." }
    if ($me.run -and $o.run -eq $me.run -and $me.items -and $o.items) {
      $common = @($me.items -split '\s*,\s*') | Where-Object { $_ -and $_ -in @($o.items -split '\s*,\s*') }
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
    $tok = "$Agent-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $me = [ordered]@{ agent = $Agent; session = $tok; run = $Run; area = $Area; items = $Items; worktrees = @($Worktrees); contracts = $Contracts
                      status = 'working'; joined = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o'); pid = $PID }
    $me | ConvertTo-Json | Set-Content (Join-Path $dir "$tok.json")
    "SESSION $tok   (pass -Session $tok to beat / check / leave)"
    $act = @(Active | Where-Object session -ne $tok)
    Print $act
    $w = @(Warnings ([pscustomobject]$me) $act)
    if ($w) { 'WARNINGS:'; $w | ForEach-Object { "  $_" } }
    $c = if ($Contracts) { $Contracts } else { (Active | Where-Object { $_.run -eq $Run -and $_.contracts } | Select-Object -First 1).contracts }
    if ($c -and (Test-Path $c)) { "CONTRACTS ($c) - re-read before every push:"; Get-Content $c | Select-Object -First 60 | ForEach-Object { "  $_" } }
  }
  'beat' {
    $f = Join-Path $dir "$Session.json"; if (-not (Test-Path $f)) { throw "unknown session $Session - join first" }
    $me = Get-Content $f -Raw | ConvertFrom-Json; $me.beat = (Get-Date).ToString('o'); if ($Status) { $me.status = $Status }
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
