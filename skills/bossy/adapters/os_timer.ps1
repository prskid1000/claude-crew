<#
os_timer.ps1: the OS heartbeat: supervise -AutoFix -Brief every supervise.heartbeatMinutes with no session open
(the page, auto-fixes and flags stay fresh between sessions); dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 heartbeat install [-Minutes <n>] | uninstall | status | tick   tick = the task's run: skips while paused (pause -All),
    never a model call; status exits 1 when missing or stale (no tick for 2 intervals)
Inputs: supervise.osTimer (unset: health offers it · true: health keeps it installed · false: off · or a scheduler name).
Outputs: <state>/programs/os-timer.json (installed adapter name minutes at lastTick result); one OS task per kit folder.
Exit codes: 0 ok · 1 install / uninstall / tick failed, status missing or stale · 2 usage.
Sections: L12 os timer
#>
#Requires -Version 7
# ---- os timer: adapter scheduler (windows built; cron, launchd name the exact by-hand step)
function Get-KitOsBeatAdapter { $v = "$(Get-KitSetting 'supervise.osTimer' '')".Trim().ToLower(); if ($v -eq 'false') { 'none' } elseif ($v -and $v -ne 'true') { $v } elseif ($KitIsWindows) { 'windows' } elseif ($IsMacOS) { 'launchd' } else { 'cron' } }
# one task per kit folder: several workspaces share a machine
function Get-KitOsBeatArgs([double]$Minutes) {
  $pw = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if (-not $pw) { $pw = 'pwsh' }
  $tick = "-NoProfile -NonInteractive -File `"$($KitCmd.orch)`" heartbeat tick"
  @{ name = "claude-crew-heartbeat-$([Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$($KitConf.Kit)".ToLower()))).Substring(0, 8).ToLower())"
     minutes = [int][math]::Max(1, $Minutes); pwsh = $pw; tick = $tick; command = "`"$pw`" $tick" }
}
# adapter:scheduler/windows: Task Scheduler, this user while logged on; conhost --headless: no console flash; runs on battery, catches up after sleep
Register-KitAdapter 'scheduler' 'windows' @{
  'install' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop
    $act = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument "--headless `"$($a.pwsh)`" $($a.tick)"
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $a.minutes)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $null = Register-ScheduledTask -TaskName $a.name -Action $act -Trigger $trg -Settings $set -Description 'claude-crew: bossy.ps1 heartbeat tick (supervise.osTimer)' -Force -ErrorAction Stop }
  'uninstall' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop; if (Get-ScheduledTask -TaskName $a.name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $a.name -Confirm:$false -ErrorAction Stop } }
  'status' = { param($a) Import-Module ScheduledTasks -ErrorAction Stop; $t = Get-ScheduledTask -TaskName $a.name -ErrorAction SilentlyContinue; if (-not $t) { return @{ installed = $false } }
    $i = $t | Get-ScheduledTaskInfo; $rep = "$(@($t.Triggers)[0].Repetition.Interval)"
    @{ installed = $true; state = "$($t.State)"; lastRun = $(if ($i.LastRunTime.Year -gt 2000) { $i.LastRunTime }); lastResult = $i.LastTaskResult; nextRun = $i.NextRunTime; every = $(if ($rep -match '^PT(?:(\d+)H)?(?:(\d+)M)?$') { 60 * [int]$Matches[1] + [int]$Matches[2] }) } }
}
# adapter:scheduler/cron: not built yet: names the crontab line
Register-KitAdapter 'scheduler' 'cron' @{
  'install' = { param($a) throw "cron adapter not built: crontab -e, add: */$($a.minutes) * * * * $($a.command) # $($a.name)" }
  'uninstall' = { param($a) throw "cron adapter not built: crontab -e, delete the line ending # $($a.name)" }
  'status' = { param($a) @{ installed = $null; state = "UNKNOWN (cron adapter not built: crontab -l | grep $($a.name))" } }
}
# adapter:scheduler/launchd: not built yet: names the LaunchAgent
Register-KitAdapter 'scheduler' 'launchd' @{
  'install' = { param($a) throw "launchd adapter not built: write ~/Library/LaunchAgents/$($a.name).plist (StartInterval $(60 * $a.minutes), ProgramArguments: $($a.command)), then launchctl load it" }
  'uninstall' = { param($a) throw "launchd adapter not built: launchctl unload ~/Library/LaunchAgents/$($a.name).plist, then delete it" }
  'status' = { param($a) @{ installed = $null; state = "UNKNOWN (launchd adapter not built: launchctl list | grep $($a.name))" } }
}
# adapter:scheduler/none: supervise.osTimer false
Register-KitAdapter 'scheduler' 'none' @{ '*' = { param($a, $verb) if ($verb -eq 'status') { @{ installed = $false; state = 'off (supervise.osTimer false)' } } else { throw 'supervise.osTimer is false in kit.local.json' } } }
# adapter-end:scheduler
function Get-KitOsBeatFile { Join-Path (Get-KitPath programs -Create) 'os-timer.json' }
function Read-KitOsBeat { try { Get-Content -LiteralPath (Get-KitOsBeatFile) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} } }
# install / uninstall: one line, never exits (health calls it)
function Set-KitOsBeat([bool]$On, [double]$Minutes) {
  $ad = Get-KitOsBeatAdapter; $a = Get-KitOsBeatArgs $(if ($Minutes) { $Minutes } else { Get-KitParam 'supervise.heartbeatMinutes' })
  if ($On -and (Test-Path -LiteralPath (Join-Path $KitConf.Kit '.git') -PathType Leaf)) { return "UNKNOWN: $($KitConf.Kit) is a worktree (gone after its push): install from the live kit clone" }
  try { Invoke-KitAdapter scheduler $ad $(if ($On) { 'install' } else { 'uninstall' }) $a } catch { return "UNKNOWN: $ad $(if ($On) { 'install' } else { 'uninstall' }) failed: $_" }
  $s = Read-KitOsBeat; $s.installed = $On; $s.adapter = $ad; $s.name = $a.name; $s.minutes = $a.minutes; $s.at = (Get-Date).ToString('o')
  Write-KitState (Get-KitOsBeatFile) $s
  if ($On) { "installed: $ad task $($a.name), every $($a.minutes) min: bossy.ps1 heartbeat tick (supervise -AutoFix -Brief; skips while paused)" } else { "removed: $ad task $($a.name); health stays quiet (back: bossy.ps1 heartbeat install)" }
}
# the task's run: a paused kit skips; supervise in a child (its -Brief exits); no model call anywhere
function Invoke-KitOsBeatTick {
  $s = Read-KitOsBeat; $s.lastTick = (Get-Date).ToString('o')
  if ($p = Get-KitActivePause '') { $s.result = "skipped: paused ($($p.reason))" }
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
  $m = [double]$(if ($s.minutes) { $s.minutes } else { Get-KitParam 'supervise.heartbeatMinutes' }); $last = if ($s.lastTick) { [datetime]$s.lastTick } elseif ($s.at) { [datetime]$s.at }
  if ($last -and ((Get-Date) - $last).TotalMinutes -lt 2 * $m + 2) { return }
  $st = try { Invoke-KitAdapter scheduler $ad status (Get-KitOsBeatArgs $m) } catch { $null }
  if ($st.installed -eq $false) { return "OS heartbeat was missing: $(Set-KitOsBeat $true $m)" }
  "OS heartbeat stale: last tick $(if ($s.lastTick) { $last.ToString('MM-dd HH:mm') } else { "never (installed $(if ($last) { $last.ToString('MM-dd HH:mm') }))" })$(if ($s.result) { " ($($s.result))" }), task $($st.state): & '$($KitCmd.orch)' heartbeat status"
}
