<#
Phone leases: an app-testing agent owns its phone end to end. The coordinator never boots or shuts phones for a run.

  $P = '<workspace>/.claude/skills/android-swarm/phone.ps1'
  & $P acquire -Agent APP1 [-Lane Falcon] [-WaitMinutes 90]   # wait for a free lane (fair FIFO), boot it through the memory gate,
                                                              # install the current apk/app.apk if the phone has an older one;
                                                              # prints JSON {lane, serial, port, installed}
  & $P release -Agent APP1 [-Keep]    # close our app, free the lease; the phone shuts down unless another agent is waiting for it (or -Keep)
  & $P status                         # leases, waiting agents, running phones

Manual use (a person, not an agent): & $P acquire -Agent manual -Lane Osprey ... & $P release -Agent manual. A 'manual' lease is never reclaimed
by the supervisor (only a reminder after 4 h); agents wait for it like any lease.
-Lane: a lane is tied to its test login (swarm.config.json / the run's lanes), so pass it when your login belongs to one lane.
Without -Lane you get any free lane (a running one first). Re-acquiring a lane you already hold just returns it.
Leases live in <runtime>\phones\. A lease whose agent left the agent board (or has no board entry for 3 h) is reclaimed by
supervise.ps1 -AutoFix, which is only the safety net for crashed agents.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'release', 'status')][string]$Action,
  [string]$Agent, [string]$Lane, [int]$WaitMinutes = 90, [switch]$Keep, [switch]$NoInstall
)
$ErrorActionPreference = 'Stop'
$c = & (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')
$adb = $c.adb; $pkg = $c.app.package
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($PSCommandPath -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }
$dir = Join-Path $rt 'phones'; $waitDir = Join-Path $dir 'wait'
New-Item -ItemType Directory -Force $dir, $waitDir | Out-Null
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-phone-leases')
function Locked([scriptblock]$b) { [void]$mutex.WaitOne(); try { & $b } finally { $mutex.ReleaseMutex() } }
function Lease($name) { $f = Join-Path $dir "$name.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
function Running($l) { [bool]((& $adb devices) -match "^emulator-$($l.port)\s+device") }
. (Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'dev-kit/scripts/sysinfo.ps1')   # RAM, processes, SDK paths on Windows/Linux/macOS
function ApkStamp { $a = Get-Item (Join-Path $c.dir 'apk/app.apk') -ErrorAction SilentlyContinue; if ($a) { "$($a.Length)-$($a.LastWriteTimeUtc.Ticks)" } }

switch ($Action) {
  'status' {
    foreach ($l in $c.lanes) {
      $ls = Lease $l.name
      '{0,-8} {1,-14} {2,-8} {3}' -f $l.name, "emulator-$($l.port)", $(if (Running $l) { 'up' } else { 'down' }), $(if ($ls) { "leased by $($ls.agent) since $($ls.since)" } else { 'free' })
    }
    Get-ChildItem $waitDir -Filter '*.json' | Sort-Object LastWriteTime | ForEach-Object { $w = Get-Content $_.FullName -Raw | ConvertFrom-Json; "waiting: $($w.agent) for $(if ($w.lane) { $w.lane } else { 'any lane' }) since $($w.since)" }
  }

  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    $lanes = @($c.lanes | Where-Object { -not $Lane -or $_.name -eq $Lane })
    if (-not $lanes) { throw "unknown lane $Lane (lanes: $($c.lanes.name -join ', '))" }
    $wf = Join-Path $waitDir "$Agent.json"
    @{ agent = $Agent; lane = $Lane; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $wf
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $got = $null; $told = $false
    while (-not $got) {
      $got = Locked {
        $mine = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent } | Select-Object -First 1)
        if ($mine) { return $mine[0] }
        # fair: the oldest waiter whose wish a free lane can satisfy goes first
        $free = @($lanes | Where-Object { -not (Lease $_.name) })
        if (-not $free) { return $null }
        $ahead = @(Get-ChildItem $waitDir -Filter '*.json' | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Where-Object { $_.agent -ne $Agent -and ([datetime]$_.since) -lt (Get-Date (Get-Content $wf -Raw | ConvertFrom-Json).since) -and (-not $_.lane -or $free.name -contains $_.lane) })
        if ($ahead.Count -ge $free.Count) { return $null }
        # spawn or wait: a free phone that is already up is taken at once; booting another one needs memory for it
        # (free RAM - its 4.5 GB >= keepFreeGB). If memory is short but some phone is leased, wait for whichever comes first
        # (a release or memory). If nothing is leased, nothing will free up: take the lane and let the gate queue the boot.
        $up = @($free | Where-Object { Running $_ })
        $pick = if ($up) { $up[0] } else {
          $freeGB = Get-FreeGB
          $someLeased = @($lanes | Where-Object { Lease $_.name }).Count
          if ($freeGB - 4.5 -ge $c.keepFreeGB -or -not $someLeased) { $free[0] } else { $script:why = "only $freeGB GB free (a phone needs 4.5 + $($c.keepFreeGB) kept free)"; $null }
        }
        if (-not $pick) { return $null }
        @{ agent = $Agent; lane = $pick.name; serial = "emulator-$($pick.port)"; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $dir "$($pick.name).json")
        $pick
      }
      if (-not $got) {
        if ((Get-Date) -gt $deadline) { Remove-Item $wf -Force; throw "no phone free within $WaitMinutes min (phone.ps1 status shows who holds them)" }
        if (-not $told) { "$(if ($script:why) { $script:why } else { "all $(if ($Lane) { "$Lane is" } else { 'lanes are' }) leased" }); waiting for a release or memory (fair queue) ..."; $told = $true }
        $script:why = $null
        Start-Sleep 20
      }
    }
    Remove-Item $wf -Force -ErrorAction SilentlyContinue
    $serial = "emulator-$($got.port)"
    if (-not (Running $got)) { & (Join-Path $c.dir 'swarm-up.ps1') -Lanes $got.name -Mode None | Select-Object -Last 2 | Out-Host }
    if (-not (Running $got)) { Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force }; throw "$($got.name) did not boot (memory turn or emulator problem); lease released" }
    $installed = 'kept'
    if (-not $NoInstall -and $c.app.kind -and (ApkStamp)) {
      $onPhone = ((& $adb -s $serial shell 'cat /sdcard/.qa-apk-stamp 2>/dev/null') -join '').Trim()
      if ($onPhone -ne (ApkStamp)) {
        & (Join-Path $c.dir 'app-mode.ps1') -Mode Release -Serials $serial | Out-Host
        & $adb -s $serial shell "echo $(ApkStamp) > /sdcard/.qa-apk-stamp"
        $installed = 'updated (the app may need a fresh login)'
      }
    }
    [ordered]@{ lane = $got.name; serial = $serial; port = $got.port; user = $got.user; notes = $got.notes; installed = $installed } | ConvertTo-Json -Compress
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
        Remove-Item (Join-Path $dir "$($l.name).json") -Force
        @(Get-ChildItem $waitDir -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not $_.lane -or $_.lane -eq $l.name }).Count
      }
      if ($Keep -or $waiting) { "$($l.name) released (kept running: $(if ($Keep) { '-Keep' } else { "$waiting agent(s) waiting" }))" }
      elseif (Running $l) { & (Join-Path $c.dir 'swarm-down.ps1') -Lanes $l.name -KeepBrowsers | Out-Null; "$($l.name) released and shut down" }
      else { "$($l.name) released" }
    }
  }
}
