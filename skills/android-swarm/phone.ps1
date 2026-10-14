<#
Phone leases: an app-testing agent owns its phone end to end. The coordinator never boots or shuts phones for a run.

  $P = '<workspace>/.claude/skills/android-swarm/phone.ps1'
  & $P acquire -Agent APP1 [-Lane Falcon] [-WaitMinutes 90] [-Holder <board agent>]
                                      # wait for a free lane (fair FIFO), boot it through the memory gate, install the current
                                      # <out>/apk/app.apk if the phone has an older one; prints JSON {lane, serial, port, installed}.
                                      # -Holder: the agent-board code that holds the lease (supervise.ps1 counts it as live while
                                      # that board entry is); default: none (the board entry's worktrees name the serial or lane)
  & $P ensure -Agent APP1             # your leased lane dropped offline: cold-boot it through the memory gate (the lease is kept);
                                      # prints the same JSON as acquire (no install); fails when you hold no lease
  & $P release -Agent APP1 [-Keep]    # close our app, free the lease; the phone shuts down unless another agent is waiting for it (or -Keep)
  & $P status                         # leases ("down, leased by X" = offline but still held), waiting agents, running phones
A lease is kept when its lane goes offline: no other agent gets that lane, and a failed re-boot of a lane you already held keeps
the lease (run ensure again); a fresh acquire whose first boot fails (not for memory) retries once with a cold boot, lease
kept; only when that also fails does it give its new lease back.

Manual use (a person, not an agent): & $P acquire -Agent manual -Lane Osprey ... & $P release -Agent manual. A 'manual' lease is never reclaimed
by the supervisor (only a reminder after 4 h); agents wait for it like any lease.
-Lane: a lane is tied to its test login (swarm.config.json / the run's lanes), so pass it when your login belongs to one lane.
Without -Lane you get any free lane (a running one first). Re-acquiring a lane you already hold just returns it.
Leases live in <runtime>/work/phones/ (Get-KitPath phones). A lease that is 60+ min old with no live holder (no workflow step on
its lane, no non-left board entry naming its agent/holder or listing its serial/lane in worktrees with a live pid or a beat under 3 h)
is reclaimed by supervise.ps1 -AutoFix, which is only the safety net for crashed agents.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'ensure', 'release', 'status')][string]$Action,
  [string]$Agent, [string]$Lane, [int]$WaitMinutes = 90, [switch]$Keep, [switch]$NoInstall, [string]$Holder
)
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb; $pkg = $c.app.package
. (Join-Path (Split-Path (Split-Path $PSCommandPath)) 'dev-kit/scripts/kitpaths.ps1')
$dir = Get-KitPath phones; $waitDir = Join-Path $dir 'wait'
New-Item -ItemType Directory -Force $dir, $waitDir | Out-Null
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-phone-leases')
function Locked([scriptblock]$b) {
  # $held, not $got: $b runs in this scope, so a local $got would shadow the caller's lease variable
  $held = $false
  try { $held = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $held = $true }   # a killed holder hands the mutex over
  try { & $b } finally { if ($held) { $mutex.ReleaseMutex() } }
}
# waiters touch their file every loop; one not touched for 3 min died and must not block the queue
function Waiters { Get-ChildItem $waitDir -Filter '*.json' | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 } | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } }
function Lease($name) { $f = Join-Path $dir "$name.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
function Running($l) { [bool]((& $adb devices) -match "^emulator-$($l.port)\s+device") }
. (Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'dev-kit/scripts/sysinfo.ps1')   # RAM, processes, SDK paths on Windows/Linux/macOS
function ApkStamp { $a = Get-Item (Join-Path $c.apkDir 'app.apk') -ErrorAction SilentlyContinue; if ($a) { "$($a.Length)-$($a.LastWriteTimeUtc.Ticks)" } }
# What the lanes run (app-build.ps1 writes app.json) and whether the branch has moved on since (local ref only: no fetch)
function ApkInfo {
  $f = Join-Path $c.apkDir 'app.json'; if (-not (Test-Path $f)) { return $null }
  $i = Get-Content $f -Raw | ConvertFrom-Json
  $head = try { (git -C $i.appDir rev-parse --short "origin/$($i.branch)" 2>$null) } catch { $null }
  $warn = if ($head -and $head.Trim() -ne $i.commit) { "the APK is $($i.commit) but origin/$($i.branch) is at $($head.Trim()): ask the lead to rebuild (app-build.ps1)" }
  [ordered]@{ branch = $i.branch; commit = $i.commit; built = $i.built; warning = $warn }
}
# Memory admission is the gate's alone (one source of truth): a boot queues in gate.ps1 with builds, under the gate's keepFreeGB
# (-KeepFreeGB / env CLAUDE_GATE_KEEP_FREE_GB / kit.local.json gate.keepFreeGB, else 15% of RAM, min 6 GB; same formula as gate.ps1).
. (Join-Path (Split-Path (Split-Path $PSCommandPath)) 'dev-kit/scripts/kitconfig.ps1')
function GateKeepFreeGB { if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) } }
# Boot a lane through swarm-up (memory gate inside); returns $true when the gate gave no memory turn (queued behind memory).
# swarm-up waits up to 30 min for its gate turn; until -Until the boot is queued again instead of failing fast.
function Boot($l, [switch]$Cold, [datetime]$Until = (Get-Date)) {
  $a = @{ Lanes = $l.name; Mode = 'None' }; if ($Cold) { $a.ColdBoot = $true }
  do {
    $boot = @(& (Join-Path $c.dir 'swarm-up.ps1') @a 3>&1)   # 3>&1: catch the gate's "no memory turn" warning
    $boot | Select-Object -Last 2 | Out-Host
    $queued = [bool]($boot | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'no memory turn' })
    if ($queued -and (Get-Date) -lt $Until) { "$($l.name): still no memory turn in the gate; queuing the boot again (until $($Until.ToString('HH:mm')))" | Out-Host }
  } while ($queued -and -not (Running $l) -and (Get-Date) -lt $Until)
  $queued
}

switch ($Action) {
  'status' {
    foreach ($l in $c.lanes) {
      $ls = Lease $l.name
      $up = Running $l
      $who = if ($ls) { "leased by $($ls.agent)$(if ($ls.holder) { " (holder $($ls.holder))" }) since $($ls.since)" } else { 'free' }
      '{0,-8} {1,-14} {2}' -f $l.name, "emulator-$($l.port)", $(if ($up) { "up       $who" } elseif ($ls) { "down, $who (offline: its agent runs phone.ps1 ensure)" } else { "down     $who" })
    }
    "memory: $((Get-SysMem).AvailGB) GB available; boots queue in the memory gate (keeps $(GateKeepFreeGB) GB free, a phone needs ~4.5 GB)"
    Get-ChildItem $waitDir -Filter '*.json' | Sort-Object LastWriteTime | ForEach-Object { $w = Get-Content $_.FullName -Raw | ConvertFrom-Json; "waiting: $($w.agent) for $(if ($w.lane) { $w.lane } else { 'any lane' }) since $($w.since)" }
  }

  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    $lanes = @($c.lanes | Where-Object { -not $Lane -or $_.name -eq $Lane })
    if (-not $lanes) { throw "unknown lane $Lane (lanes: $($c.lanes.name -join ', '))" }
    $wf = Join-Path $waitDir "$Agent.json"
    $since = (Get-Date).ToString('s')
    @{ agent = $Agent; lane = $Lane; since = $since } | ConvertTo-Json | Set-Content $wf
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $got = $null; $told = $false
    while (-not $got) {
      $got = Locked {
        if (Test-Path $wf) { (Get-Item $wf).LastWriteTime = Get-Date } else { @{ agent = $Agent; lane = $Lane; since = $since } | ConvertTo-Json | Set-Content $wf }   # heartbeat
        $mine = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent } | Select-Object -First 1)
        if ($mine) {   # already ours (also when it went offline: a held lane is never handed to anyone else)
          $script:had = $true
          if ($Holder) { $lf = Join-Path $dir "$($mine[0].name).json"; $o = Get-Content $lf -Raw | ConvertFrom-Json; if ($o.holder -ne $Holder) { $o | Add-Member -Force holder $Holder; $o | ConvertTo-Json | Set-Content $lf } }
          return $mine[0]
        }
        # fair: the oldest waiter whose wish a free lane can satisfy goes first
        $free = @($lanes | Where-Object { -not (Lease $_.name) })
        if (-not $free) { return $null }
        $ahead = @(Waiters | Where-Object { $_.agent -ne $Agent -and ([datetime]$_.since) -lt (Get-Date $since) -and (-not $_.lane -or $free.name -contains $_.lane) })
        if ($ahead.Count -ge $free.Count) { return $null }
        # a free phone that is already up is taken at once; otherwise take a free lane and let the memory gate queue its boot
        # (no memory pre-check here: the gate's keepFreeGB is the only floor, and the boot waits its fair turn with builds)
        $up = @($free | Where-Object { Running $_ })
        $pick = if ($up) { $up[0] } else { $free[0] }
        $new = [ordered]@{ agent = $Agent; lane = $pick.name; serial = "emulator-$($pick.port)"; since = (Get-Date).ToString('s') }; if ($Holder) { $new.holder = $Holder }
        $new | ConvertTo-Json | Set-Content (Join-Path $dir "$($pick.name).json")
        $pick
      }
      if (-not $got) {
        if ((Get-Date) -gt $deadline) { Remove-Item $wf -Force -ErrorAction SilentlyContinue; throw "no phone free within $WaitMinutes min (phone.ps1 status shows who holds them)" }
        if (-not $told) { "$(if ($script:why) { $script:why } else { "all $(if ($Lane) { "$Lane is" } else { 'lanes are' }) leased" }); waiting for a release or memory (fair queue) ..."; $told = $true }
        $script:why = $null
        Start-Sleep 20
      }
    }
    Remove-Item $wf -Force -ErrorAction SilentlyContinue
    $serial = "emulator-$($got.port)"
    $memQueued = $false
    if (-not (Running $got)) { $memQueued = Boot $got -Until $deadline }
    if (-not (Running $got) -and -not $script:had -and -not $memQueued) {
      # a new lease whose first boot failed for an emulator reason (not memory): one cold retry, lease kept (often a hung warm snapshot)
      "$($got.name): first boot failed, retrying once (cold boot; lease kept)" | Out-Host
      $memQueued = Boot $got -Cold -Until $deadline
    }
    if (-not (Running $got)) {
      if ($script:had) {   # a lane we already held went offline and did not come back: keep the lease, never hand it to another agent
        throw "$($got.name) is offline and did not boot$(if ($memQueued) { " (no memory turn in the gate within -WaitMinutes $WaitMinutes)" }); lease kept: run phone.ps1 ensure -Agent $Agent again, or release it"
      }
      Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force -ErrorAction SilentlyContinue }
      if ($memQueued) { throw "$($got.name) queued behind memory: the gate gave no memory turn within -WaitMinutes $WaitMinutes; lease released (acquire again later)" }
      throw "$($got.name) did not boot (emulator problem); lease released"
    }
    $installed = 'kept'
    if (-not $NoInstall -and $c.app.kind -and (ApkStamp)) {
      $onPhone = ((& $adb -s $serial shell 'cat /sdcard/.qa-apk-stamp 2>/dev/null') -join '').Trim()
      if ($onPhone -ne (ApkStamp)) {
        try {
          & (Join-Path $c.dir 'app-mode.ps1') -Mode Release -Serials $serial | Out-Host
          & $adb -s $serial shell "echo $(ApkStamp) > /sdcard/.qa-apk-stamp"
          $installed = 'updated (the app may need a fresh login)'
        } catch { Write-Warning "$serial : $_"; $installed = "install FAILED (the phone runs an older app): $_" }   # no stamp: the next acquire retries
      }
    }
    [ordered]@{ lane = $got.name; serial = $serial; port = $got.port; user = $got.user; notes = $got.notes; installed = $installed; apk = (ApkInfo) } | ConvertTo-Json -Compress -Depth 3
  }

  'ensure' {
    # your own leased lane only: cold-boot it when adb no longer lists it as 'device' (a warm snapshot is what usually hangs)
    if (-not $Agent) { throw 'ensure needs -Agent' }
    $got = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent } | Select-Object -First 1)
    if (-not $got) { throw "no phone leased by ${Agent}: use phone.ps1 acquire -Agent $Agent -Lane <name>" }
    $got = $got[0]; $serial = "emulator-$($got.port)"; $state = 'up'
    if (-not (Running $got)) {
      $memQueued = Boot $got -Cold -Until (Get-Date).AddMinutes($WaitMinutes)
      if (-not (Running $got)) { throw "$($got.name) did not come back$(if ($memQueued) { " (no memory turn in the gate within -WaitMinutes $WaitMinutes)" }); lease kept: run ensure again later, or release it" }
      $state = 'cold-booted (relaunch the app; it may need a fresh login)'
    }
    [ordered]@{ lane = $got.name; serial = $serial; port = $got.port; user = $got.user; notes = $got.notes; state = $state; installed = 'kept'; apk = (ApkInfo) } | ConvertTo-Json -Compress -Depth 3
  }

  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    Remove-Item (Join-Path $waitDir "$Agent.json") -Force -ErrorAction SilentlyContinue
    $mine = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent })
    if (-not $mine) { "no phone leased by $Agent"; return }
    foreach ($l in $mine) {
      $serial = "emulator-$($l.port)"
      if (Running $l) { & $adb -s $serial shell am force-stop $pkg 2>$null }
      $waiting = Locked {
        Remove-Item (Join-Path $dir "$($l.name).json") -Force -ErrorAction SilentlyContinue
        @(Waiters | Where-Object { -not $_.lane -or $_.lane -eq $l.name }).Count
      }
      if ($Keep -or $waiting) { "$($l.name) released (kept running: $(if ($Keep) { '-Keep' } else { "$waiting agent(s) waiting" }))" }
      elseif (Running $l) { & (Join-Path $c.dir 'swarm-down.ps1') -Lanes $l.name -KeepBrowsers | Out-Null; "$($l.name) released and shut down" }
      else { "$($l.name) released" }
    }
  }
}
