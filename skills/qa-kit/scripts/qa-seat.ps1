<#
QA seats: lets a QA run use as many parallel agents as memory allows, and makes extra workers safe.
  - Memory seat: an agent waits (fair FIFO) until free RAM minus the GB the memory gate promised (running + queued builds/phones)
    minus its need stays >= the gate's keepFreeGB, then takes a seat; it releases
    the seat when done. So the effective number of QA agents grows when memory is free (e.g. phones shut down) and shrinks when it's tight,
    whatever the run's webParallel / apiParallel cap says.
  - Item claim: the first worker to claim <run>/<code> owns the item; another worker instance (an extra test-and-close launched by the
    coordinator for queued items) gets ALREADY and skips it. Claims end when the item's finalize.json exists or after 6 h.

  $S = '<workspace>/.claude/skills/qa-kit/scripts/qa-seat.ps1'
  & $S acquire -Agent test:GT7 -Kind web [-RunDir <runDir> -Code GT7 -Owner w1]   # exit 0 = go; 2 = still waiting, call again; 3 = ALREADY (skip item)
  & $S release -Agent test:GT7
  & $S status                                                                        # seats, waiters, claims, free RAM
Needs per kind: web 1.5 GB (a Chrome session), api 0.4 GB, verify = same as its kind. keepFreeGB = the memory gate's (-KeepFreeGB,
env CLAUDE_GATE_KEEP_FREE_GB, kit.local.json gate.keepFreeGB, else 15% of RAM, min 6 GB). -WaitMinutes (default 8) keeps one call under the tool timeout: on exit 2 just run the same command again.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'release', 'status')][string]$Action,
  [string]$Agent, [ValidateSet('web', 'api', 'app')][string]$Kind = 'web',
  [string]$RunDir, [string]$Code, [string]$Owner = 'w1',
  [int]$WaitMinutes = 8, [double]$KeepFreeGB = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts/kitconfig.ps1')   # $KitConf, Get-KitPath
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts/sysinfo.ps1')     # Get-FreeGB on Windows, Linux and macOS
$dir = Get-KitPath qa-seats; $seats = Join-Path $dir 'seats'; $wait = Join-Path $dir 'wait'; $claims = Join-Path $dir 'claims'
New-Item -ItemType Directory -Force $seats, $wait, $claims | Out-Null
# One memory floor for the machine: the gate's keepFreeGB (same order and default as gate.ps1: env CLAUDE_GATE_KEEP_FREE_GB,
# kit.local.json gate.keepFreeGB, else 15% of RAM, min 6 GB)
if (-not $KeepFreeGB) {
  $KeepFreeGB = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
}
# GB the memory gate has already promised: running gated builds/phones (their estimate minus what their process tree uses now,
# as gate.ps1 counts it) plus builds queued in the gate (their full need: a seat must not take the memory they wait for)
$gateLedger = Join-Path (Get-KitTemp) 'claude-build-gate'
function Get-GatePromisedGB([string]$Ledger = $gateLedger) {
  $run = @(Get-ChildItem $Ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.pid })
  $queued = @(Get-ChildItem (Join-Path $Ledger 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.pid })
  if (-not ($run.Count + $queued.Count)) { return 0 }
  $ws = @{}; $kids = @{}
  foreach ($p in Get-SysProcs -NoCommandLine) { $ws[$p.Id] = $p.WorkingSet; if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.ArrayList]::new() }; [void]$kids[$p.ParentId].Add($p.Id) }
  $sum = 0.0
  foreach ($e in $run) {
    if (-not $ws.ContainsKey([int]$e.pid)) { continue }
    $used = 0; $st = [Collections.Stack]::new(); $st.Push([int]$e.pid)
    while ($st.Count) { $n = $st.Pop(); if ($ws.ContainsKey($n)) { $used += $ws[$n] }; if ($kids.ContainsKey($n)) { foreach ($k in $kids[$n]) { $st.Push($k) } } }
    $sum += [math]::Max(0, [double]$e.need - $used / 1GB)
  }
  foreach ($t in $queued) { if ($ws.ContainsKey([int]$t.pid)) { $sum += [double]$t.need } }
  [math]::Round($sum, 1)
}
$need = @{ web = 1.5; api = 0.4; app = 0.4 }[$Kind]
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-qa-seats')
function Locked([scriptblock]$b) {
  $got = $false
  try { $got = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed holder hands the mutex over
  try { & $b } finally { if ($got) { $mutex.ReleaseMutex() } }
}
function FreeGB { Get-FreeGB }
function Safe($s) { $s -replace '[^\w.-]', '_' }
function Seats { @(Get-ChildItem $seats -Filter *.json | ForEach-Object { $o = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (((Get-Date) - [datetime]$o.since).TotalHours -gt 3) { Remove-Item $_.FullName -Force } else { $o } }) }

switch ($Action) {
  'status' {
    $s = Seats
    "free RAM $(FreeGB) GB, $(Get-GatePromisedGB) GB promised by the memory gate, keep $KeepFreeGB GB free (gate.keepFreeGB); $($s.Count) seat(s): $(($s | ForEach-Object { "$($_.agent) ($($_.kind))" }) -join ', ')"
    Get-ChildItem $wait -Filter *.json | Sort-Object LastWriteTime | ForEach-Object { $w = Get-Content $_.FullName -Raw | ConvertFrom-Json; "waiting: $($w.agent) ($($w.kind)) since $($w.since)" }
    Get-ChildItem $claims -Filter *.json | ForEach-Object { $c = Get-Content $_.FullName -Raw | ConvertFrom-Json; "claim: $($c.run)/$($c.code) by $($c.owner) since $($c.since)" }
  }

  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    Remove-Item (Join-Path $seats "$(Safe $Agent).json"), (Join-Path $wait "$(Safe $Agent).json") -Force -ErrorAction SilentlyContinue
    "seat released: $Agent"
  }

  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    # 1. item claim (only the first worker instance tests an item)
    if ($RunDir -and $Code) {
      $run = Split-Path $RunDir -Leaf
      $cf = Join-Path $claims "$(Safe $run)__$(Safe $Code).json"
      $verdict = Locked {
        if (Test-Path (Join-Path $RunDir "$Code\finalize.json")) { return "ALREADY: $Code was finished and published" }
        if (Test-Path (Join-Path $RunDir "$Code\held.json")) { return "ALREADY: $Code was tested; results held for the lead to publish" }
        if (Test-Path $cf) {
          $c = Get-Content $cf -Raw | ConvertFrom-Json
          if ($c.owner -ne $Owner -and ((Get-Date) - [datetime]$c.since).TotalHours -lt 6) { return "ALREADY: $Code is being tested by worker $($c.owner)" }
        }
        @{ run = $run; code = $Code; owner = $Owner; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $cf
        $null
      }
      if ($verdict) { $verdict; exit 3 }
    }
    # 2. memory seat (fair FIFO among waiters)
    $me = Safe $Agent; $wf = Join-Path $wait "$me.json"
    if (Test-Path (Join-Path $seats "$me.json")) { "seat already held: $Agent"; exit 0 }
    if (-not (Test-Path $wf)) { @{ agent = $Agent; kind = $Kind; need = $need; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $wf }
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $told = $false
    while ($true) {
      $ok = Locked {
        $mine = Get-Content $wf -Raw | ConvertFrom-Json
        $mine | Add-Member -Force beat (Get-Date).ToString('s'); $mine | ConvertTo-Json | Set-Content $wf    # heartbeat: dead waiters must not block the queue
        $ahead = @(Get-ChildItem $wait -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Where-Object { $_.agent -ne $Agent -and [datetime]$_.since -lt [datetime]$mine.since -and ((Get-Date) - [datetime]$(if ($_.beat) { $_.beat } else { $_.since })).TotalMinutes -lt 3 })
        # seats taken in the last 3 min have not allocated their memory yet: count them as promised
        # plus what the memory gate has promised to running and queued builds / phones
        $promised = [double](@(Seats | Where-Object { ((Get-Date) - [datetime]$_.since).TotalMinutes -lt 3 }) | Measure-Object need -Sum).Sum + 0
        $promised = [math]::Round($promised + (Get-GatePromisedGB), 1)
        $left = (FreeGB) - [double]$promised - $need
        if ($ahead.Count -eq 0 -and $left -ge $KeepFreeGB) {
          @{ agent = $Agent; kind = $Kind; need = $need; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $seats "$me.json")
          Remove-Item $wf -Force
          return "seat taken: $Agent ($Kind, ~$need GB); free RAM after it ~$([math]::Round($left, 1)) GB"
        }
        $script:why = if ($ahead.Count) { "$($ahead.Count) agent(s) ahead in the queue" } else { "free RAM $(FreeGB) GB - promised $promised GB - need $need GB < keep $KeepFreeGB GB" }
        $null
      }
      if ($ok) { $ok; exit 0 }
      if (-not $told) { "waiting for a seat: $script:why"; $told = $true }
      if ((Get-Date) -gt $deadline) { "STILL WAITING ($script:why): run the same command again"; exit 2 }
      Start-Sleep 15
    }
  }
}
