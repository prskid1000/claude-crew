<#
os_timer.ps1: the OS heartbeat: ticks every supervise.osTimerTickMinutes and runs supervise -AutoFix -Brief once the last
sweep (any session) is a beat old, so the page, auto-fixes and flags stay fresh while sessions are busy or closed; dot-sourced by bossy.ps1.
  bossy.ps1 heartbeat install [-Minutes <n>] | uninstall | status | tick   tick = the task's run: skips while paused (pause -All),
    steps aside in-process under a beat, never a model call; status exits 1 when missing or stale (no tick for 2 intervals)
Inputs: supervise.osTimer (unset: health offers it · true: health keeps it installed · false: off · or a scheduler name).
Outputs: <state>/programs/os-timer.json (installed adapter name minutes at lastTick result); one OS task per kit folder.
Exit codes: 0 ok · 1 install / uninstall / tick failed, status missing or stale · 2 usage.
Sections: L12 os timer
#>
#Requires -Version 7
# ---- os timer: adapter scheduler (windows Task Scheduler, cron, launchd; verbs install, uninstall, status)
function Get-KitOsBeatAdapter { $v = "$(Get-KitSetting 'supervise.osTimer' '')".Trim().ToLower(); if ($v -eq 'false') { 'none' } elseif ($v -and $v -ne 'true') { $v } elseif ($KitIsWindows) { 'windows' } elseif ($IsMacOS) { 'launchd' } else { 'cron' } }
# one task per kit folder: several workspaces share a machine
function Get-KitOsBeatArgs([double]$Minutes) {
  $pw = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if (-not $pw) { $pw = 'pwsh' }
  $argv = @('-NoProfile', '-NonInteractive', '-File', "$($KitCmd.orch)", 'heartbeat', 'tick'); $tick = "-NoProfile -NonInteractive -File `"$($KitCmd.orch)`" heartbeat tick"
  @{ name = "claude-crew-heartbeat-$((Get-KitHash ("$($KitConf.Kit)".ToLower()) SHA1).Substring(0, 8).ToLower())"
     minutes = [int][math]::Max(1, $Minutes); pwsh = $pw; tick = $tick; argv = $argv; command = "`"$pw`" $tick" }
}
# adapter:scheduler/windows: Task Scheduler, this user while logged on; conhost --headless: no console flash; runs on battery, catches up after sleep
Register-KitAdapter 'scheduler' 'windows' @{
  'install' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop
    $act = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument "--headless `"$($a.pwsh)`" $($a.tick)"
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $a.minutes)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes ([double](Get-KitParam 'supervise.osTimerLimitMinutes')))
    $null = Register-ScheduledTask -TaskName $a.name -Action $act -Trigger $trg -Settings $set -Description 'claude-crew: bossy.ps1 heartbeat tick (supervise.osTimer)' -Force -ErrorAction Stop }
  'uninstall' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop; if (Get-ScheduledTask -TaskName $a.name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $a.name -Confirm:$false -ErrorAction Stop } }
  'status' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop; $t = Get-ScheduledTask -TaskName $a.name -ErrorAction SilentlyContinue; if (-not $t) { return @{ installed = $false } }
    $i = $t | Get-ScheduledTaskInfo; $rep = "$(@($t.Triggers)[0].Repetition.Interval)"
    @{ installed = $true; state = "$($t.State)"; lastRun = $(if ($i.LastRunTime.Year -gt 2000) { $i.LastRunTime }); lastResult = $i.LastTaskResult; nextRun = $i.NextRunTime; every = $(if ($rep -match '^PT(?:(\d+)H)?(?:(\d+)M)?$') { 60 * [int]$Matches[1] + [int]$Matches[2] }) } }
}
# adapter:scheduler/cron: one crontab line per kit folder, tagged # <name>; crontab - replaces the table
function Invoke-KitSchedCmd([string]$Exe, [string[]]$ArgList = @(), [string]$Stdin = $null) {   # tests replace it: no real scheduling
  $o = if ($null -ne $Stdin) { $Stdin | & $Exe @ArgList 2>&1 } else { & $Exe @ArgList 2>&1 }; @{ code = $LASTEXITCODE; out = "$(($o | Out-String))".Trim() }
}
function Get-KitCronLines([string]$Name) { $r = Invoke-KitSchedCmd 'crontab' @('-l'); @(if ($r.code -eq 0) { "$($r.out)" -split "`r?`n" | Where-Object { $_ -and $_ -notmatch "#\s*$([regex]::Escape($Name))\s*$" } }) }   # no table yet: exit 1
function Get-KitCronSpec([int]$Minutes) { if ($Minutes -lt 60) { "*/$Minutes * * * *" } else { "0 */$([math]::Max(1, [int][math]::Round($Minutes / 60))) * * *" } }
Register-KitAdapter 'scheduler' 'cron' @{
  'install' = { param($a) $t = @(Get-KitCronLines $a.name) + "$(Get-KitCronSpec $a.minutes) $($a.command) >/dev/null 2>&1 # $($a.name)"
    $r = Invoke-KitSchedCmd 'crontab' @('-') (($t -join "`n") + "`n"); if ($r.code) { throw "crontab - exit $($r.code): $($r.out)" } }
  'uninstall' = { param($a) $r = Invoke-KitSchedCmd 'crontab' @('-') ((@(Get-KitCronLines $a.name) -join "`n") + "`n"); if ($r.code) { throw "crontab - exit $($r.code): $($r.out)" } }
  'status' = { param($a) $r = Invoke-KitSchedCmd 'crontab' @('-l'); $l = @("$($r.out)" -split "`r?`n" | Where-Object { $_ -match "#\s*$([regex]::Escape($a.name))\s*$" })[0]
    if (-not $l) { return @{ installed = $false; state = 'no crontab line' } }
    @{ installed = $true; state = 'Ready'; every = $(if ($l -match '^\*/(\d+) ') { [int]$Matches[1] } elseif ($l -match '^0 \*/(\d+) ') { 60 * [int]$Matches[1] }) } }
}
# adapter:scheduler/launchd: a LaunchAgent plist (StartInterval), launchctl load -w / unload
function Get-KitLaunchAgentDir { Join-Path $HOME 'Library/LaunchAgents' }   # tests replace it
function Get-KitLaunchPlist($a) {
  $x = { param($s) [Security.SecurityElement]::Escape("$s") }
  $argv = (@($a.pwsh) + @($a.argv) | ForEach-Object { "    <string>$(& $x $_)</string>" }) -join "`n"
  @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(& $x $a.name)</string>
  <key>ProgramArguments</key>
  <array>
$argv
  </array>
  <key>StartInterval</key><integer>$(60 * $a.minutes)</integer>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
"@
}
Register-KitAdapter 'scheduler' 'launchd' @{
  'install' = { param($a) $d = Get-KitLaunchAgentDir; $p = Join-Path $d "$($a.name).plist"; New-Item -ItemType Directory -Force $d | Out-Null
    if (Test-Path -LiteralPath $p) { $null = Invoke-KitSchedCmd 'launchctl' @('unload', $p) }
    [IO.File]::WriteAllText($p, ((Get-KitLaunchPlist $a) -replace "`r`n", "`n")); $r = Invoke-KitSchedCmd 'launchctl' @('load', '-w', $p); if ($r.code) { throw "launchctl load exit $($r.code): $($r.out)" } }
  'uninstall' = { param($a) $p = Join-Path (Get-KitLaunchAgentDir) "$($a.name).plist"
    if (Test-Path -LiteralPath $p) { $null = Invoke-KitSchedCmd 'launchctl' @('unload', '-w', $p); Remove-Item -LiteralPath $p -Force } }
  'status' = { param($a) $p = Join-Path (Get-KitLaunchAgentDir) "$($a.name).plist"; $r = Invoke-KitSchedCmd 'launchctl' @('list', $a.name)
    if ($r.code -or -not (Test-Path -LiteralPath $p)) { return @{ installed = $false; state = $(if (Test-Path -LiteralPath $p) { 'plist not loaded' } else { 'no plist' }) } }
    @{ installed = $true; state = 'Ready'; every = $(if ((Get-Content -LiteralPath $p -Raw) -match '<key>StartInterval</key><integer>(\d+)</integer>') { [int]([int]$Matches[1] / 60) }) } }
}
# adapter:scheduler/none: supervise.osTimer false
Register-KitAdapter 'scheduler' 'none' @{ '*' = { param($a, $verb) if ($verb -eq 'status') { @{ installed = $false; state = 'off (supervise.osTimer false)' } } else { throw 'supervise.osTimer is false in kit.local.json' } } }
# adapter-end:scheduler
function Get-KitOsBeatFile { Join-Path (Get-KitPath programs -Create) 'os-timer.json' }
function Read-KitOsBeat { $s = try { Read-KitText (Get-KitOsBeatFile) | ConvertFrom-Json -AsHashtable } catch { $null }; if ($s -is [hashtable]) { $s } else { @{} } }
# the tick sweeps once the last sweep (any session, its own too) is a beat old; 0.5 min = its own start-up before it stamps the lock
function Get-KitOsBeatAsideMinutes { [math]::Max(1.0, (Get-KitBeatMinutes) - 0.5) }
# when the OS timer sweeps next: its first tick (lastTick + k x minutes) at least a beat after $At; $null when it is off or not ticking
function Get-KitOsBeatNextSweep([datetime]$At, [datetime]$Now = (Get-Date)) {
  $s = Read-KitOsBeat; if (-not $s.installed -or -not $s.lastTick -or -not ([double]$s.minutes -gt 0)) { return $null }
  $m = [double]$s.minutes; $tk = [datetime]$s.lastTick; if (($Now - $tk).TotalMinutes -gt 2 * $m + 2) { return $null }
  $due = $At.AddMinutes((Get-KitOsBeatAsideMinutes)); $k = [math]::Max(1, [math]::Ceiling(($due - $tk).TotalMinutes / $m)); $tk.AddMinutes($k * $m)
}
# install / uninstall: one line, never exits (health calls it)
function Set-KitOsBeat([bool]$On, [double]$Minutes) {
  $ad = Get-KitOsBeatAdapter; $a = Get-KitOsBeatArgs $(if ($Minutes) { $Minutes } else { Get-KitParam 'supervise.osTimerTickMinutes' })
  if ($On -and (Test-Path -LiteralPath (Join-Path $KitConf.Kit '.git') -PathType Leaf)) { return "UNKNOWN: $($KitConf.Kit) is a worktree (gone after its push): install from the live kit clone" }
  try { Invoke-KitAdapter scheduler $ad $(if ($On) { 'install' } else { 'uninstall' }) $a } catch { return "UNKNOWN: $ad $(if ($On) { 'install' } else { 'uninstall' }) failed: $_" }
  $s = Read-KitOsBeat; $s.installed = $On; $s.adapter = $ad; $s.name = $a.name; $s.minutes = $a.minutes; $s.gate = 'beat'; $s.at = (Get-KitStamp)
  Write-KitState (Get-KitOsBeatFile) $s
  if ($On) { "installed: $ad task $($a.name), every $($a.minutes) min: bossy.ps1 heartbeat tick (supervise -AutoFix -Brief; skips while paused)" } else { "removed: $ad task $($a.name); health stays quiet (back: bossy.ps1 heartbeat install)" }
}
# the task's run: a paused kit skips; supervise in a child (its -Brief exits); no model call anywhere
function Invoke-KitOsBeatTick {
  $s = Read-KitOsBeat; $s.lastTick = (Get-KitStamp)
  if ($p = Get-KitActivePause '') { $s.result = "skipped: paused ($($p.reason))" }
  elseif (($last = Get-KitLastSweepAt) -and ($ago = ((Get-Date) - $last).TotalMinutes) -lt (Get-KitOsBeatAsideMinutes)) { $s.result = "stepped aside: last sweep $([int]$ago) min ago, under a beat" }   # no child pwsh
  else {
    $r = Invoke-KitExe ([Environment]::ProcessPath) @('-NoProfile', '-NonInteractive', '-File', $KitCmd.orch, 'supervise', '-Session', 'os-timer', '-AutoFix', '-Brief') 300
    $last = @("$($r.out)" -split "`r?`n" | Where-Object { $_.Trim() })[-1]
    $s.result = if ($r.timedOut) { 'timed out after 300 s' } elseif ($r.code) { "exit $($r.code): $last" } elseif ("$($r.out)" -match 'steps aside') { 'stepped aside: a session supervises' } else { "ok: $last" }
  }
  Write-KitState (Get-KitOsBeatFile) $s; $s.result
}
function Invoke-KitOsBeat {
param([Parameter(Position = 0, Mandatory)][ValidateSet('install', 'uninstall', 'status', 'tick')][string]$Action, [double]$Minutes = 0)
  switch ($Action) {
    'install' { $o = Set-KitOsBeat $true $Minutes; "heartbeat: $o"; if ($o -like 'UNKNOWN*') { exit 1 } }
    'uninstall' { $o = Set-KitOsBeat $false 0; "heartbeat: $o"; if ($o -like 'UNKNOWN*') { exit 1 } }
    'tick' { $r = Invoke-KitOsBeatTick; $r; exit $(if ($r -match '^(ok|skipped|stepped)') { 0 } else { 1 }) }   # the task's last result
    'status' {
      $s = Read-KitOsBeat; $ad = Get-KitOsBeatAdapter; $a = Get-KitOsBeatArgs $(if ($s.minutes) { $s.minutes } else { Get-KitParam 'supervise.heartbeatMinutes' })
      $st = try { Invoke-KitAdapter scheduler $ad status $a } catch { @{ installed = $null; state = "UNKNOWN: $_" } }
      $m = if ($st.every) { $st.every } else { $a.minutes }; $tick = if ($s.lastTick) { [datetime]$s.lastTick }
      "heartbeat: $(if ($st.installed) { 'installed' } elseif ($null -eq $st.installed) { 'UNKNOWN' } else { 'not installed' }) · $ad task $($a.name) · every $m min · state $($st.state)"
      "last tick: $(if ($tick) { "$($tick.ToString('MM-dd HH:mm')) $($s.result)" } else { 'none yet' })$(if ($st.nextRun) { " · next $(([datetime]$st.nextRun).ToString('HH:mm'))" })$(if ($st.lastRun -and $st.lastResult) { " · task result $($st.lastResult)" })"
      if (-not $st.installed -or -not $tick -or ((Get-Date) - $tick).TotalMinutes -gt 2 * $m + 2) { exit 1 }
    }
  }
}
# SessionStart (core health calls it when loaded): ticked within 2 intervals; gone -> reinstalled; never installed -> the install line
function Get-KitOsBeatHealth {
  $ad = Get-KitOsBeatAdapter; $s = Read-KitOsBeat; if ($ad -eq 'none' -or $s.installed -eq $false) { return }   # off, or removed on purpose
  if (-not $s.installed -and -not "$(Get-KitSetting 'supervise.osTimer' '')") { return "OS heartbeat off: the dashboard and auto-fixes stop when no session supervises; turn it on: & '$($KitCmd.orch)' heartbeat install" }
  # a task from before the beat gate fired once a beat; a worktree never installs (gone after its push)
  if ($s.installed -and $s.gate -ne 'beat' -and -not (Test-Path -LiteralPath (Join-Path $KitConf.Kit '.git') -PathType Leaf)) { $r = Set-KitOsBeat $true 0
    return $(if ($r -like 'UNKNOWN*') { "OS heartbeat still fires once a beat (re-register failed): $r" } else { "OS heartbeat re-registered (ticks between beats, sweeps once the last is a beat old): $r" }) }
  $m = [double]$(if ($s.minutes) { $s.minutes } else { Get-KitParam 'supervise.heartbeatMinutes' }); $last = if ($s.lastTick) { [datetime]$s.lastTick } elseif ($s.at) { [datetime]$s.at }
  if ($last -and ((Get-Date) - $last).TotalMinutes -lt 2 * $m + 2) { return }
  $st = try { Invoke-KitAdapter scheduler $ad status (Get-KitOsBeatArgs $m) } catch { $null }
  if ($st.installed -eq $false) { return "OS heartbeat was missing: $(Set-KitOsBeat $true $m)" }
  "OS heartbeat stale: last tick $(if ($s.lastTick) { $last.ToString('MM-dd HH:mm') } else { "never (installed $(if ($last) { $last.ToString('MM-dd HH:mm') }))" })$(if ($s.result) { " ($($s.result))" }), task $($st.state): & '$($KitCmd.orch)' heartbeat status"
}
