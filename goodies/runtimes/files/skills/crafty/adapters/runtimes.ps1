<#
runtimes.ps1 (goody runtimes): leases on machine runtimes agents start (a container engine, a WSL distro, a VM), so the kit
stops what it started once the last agent is done; a runtime the kit did not start is never stopped.
  & <kit>/skills/crafty/crafty.ps1 runtime use -Name <runtime> [-Agent <a>] [-Session <board session>]   lease; down -> start it
  & <kit>/skills/crafty/crafty.ps1 runtime release [-Name <runtime>] [-Agent <a>] [-Session <s>]   drop the lease; last one + kit-started -> down
  & <kit>/skills/crafty/crafty.ps1 runtime status [-Name <runtime>] [-Json]
Inputs: kit.local.json `runtimes.<name>`: isUp (command line; running = exit 0 + some output), up (optional: else the agent's
own command starts it), down, match (regex of commands that use it: crafty.ps1 guard leases for an agent that forgot). -Agent
defaults to $env:CLAUDE_AGENT, else main. State: <state>/runtimes/<name>.json. Command lines run in pwsh -Command.
Dot-sourced by lib.ps1 (adapters/*.ps1): crafty.ps1 gets the verb and the guard rule, bossy.ps1 supervise its sweep
(Get-KitSuperviseGuardRuntimes: a lease with no live holder for idle.graceMinutes -> released; kit-started + no lease -> down).
Exit codes: 0 ok · 1 problem (not configured, up or down failed) · 2 usage.
Sections: L16 state · L45 leases · L90 verb · L136 supervise
#>
#Requires -Version 7
# ---- state: names, state file, probes
function Get-KitRuntimeNames { $r = Get-KitSetting 'runtimes' $null; if ($r) { @($r.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' -and $r.$_.isUp }) } }
function Get-KitRuntimeFile([string]$Name) { Join-Path (Get-KitPath runtimes -Create) "$Name.json" }
function Get-KitRuntimeState([string]$Name) {
  $s = try { Get-Content (Get-KitRuntimeFile $Name) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
  if ($s -isnot [hashtable]) { $s = @{ name = $Name; startedByKit = $false } }
  $s.leases = @($s.leases | Where-Object { $_ }); $s
}
# one writer at a time: up / down run under the lock, so a use never races a stop
function Update-KitRuntimeState([string]$Name, [scriptblock]$Change) {
  $rtFile = Get-KitRuntimeFile $Name
  Invoke-KitLocked $rtFile {
    $st = Get-KitRuntimeState $Name; & $Change $st
    $st | ConvertTo-Json -Depth 6 | Set-Content "$rtFile.tmp" -Encoding utf8; Move-Item "$rtFile.tmp" $rtFile -Force
  }
}
# WSL_UTF8: wsl.exe prints UTF-8 instead of UTF-16
function Invoke-KitRuntimeCmd([string]$Line, [int]$TimeoutSec) { $env:WSL_UTF8 = '1'; Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-Command', $Line) $TimeoutSec }
# $true running · $false not running · $null unknown (timed out): unknown is never a state, so it never starts or stops anything
function Test-KitRuntimeUp([string]$Name, [int]$TimeoutSec = 20) {
  $r = Invoke-KitRuntimeCmd (Get-KitSetting "runtimes.$Name.isUp" '') $TimeoutSec
  if ($r.timedOut) { return $null }
  -not $r.code -and [bool]("$($r.out)" -replace "`0").Trim()
}
# an auto lease (the guard's) lives while its agent keeps running matching commands; an explicit one by the README "Leases" rule
function Test-KitRuntimeLease($l) {
  if ($l.auto) { return ((Get-Date) - [datetime]$l.used).TotalMinutes -lt [double](Get-KitSetting 'idle.beatMinutes' 20) -and (Test-KitHolder $l) -ne $false }
  Test-KitLive $l
}
# ---- leases: use, release, stop
# under the state lock; a failed down keeps startedByKit (supervise retries after idle.graceMinutes)
function Stop-KitRuntime([string]$Name, [hashtable]$St) {
  $down = Get-KitSetting "runtimes.$Name.down" ''
  if (-not $down) { return "runtime ${Name}: no lease left; no runtimes.$Name.down: left running" }
  $r = Invoke-KitRuntimeCmd $down 90   # + isUp stays under the 130 s a waiting writer gives the lock
  if ($r.code) { $St.emptySince = (Get-Date).ToString('o'); return "runtime ${Name}: down failed (exit $($r.code)): $(@("$($r.err)`n$($r.out)" -split "`n" | Where-Object { $_.Trim() })[0])" }
  $St.startedByKit = $false; $St.Remove('startedAt'); $St.Remove('emptySince')
  "runtime ${Name}: stopped ($down): the kit started it, no lease left"
}

function Use-KitRuntime([string]$Name, [string]$Agent, [string]$Session, [switch]$Auto, [switch]$NoWait) {
 Update-KitRuntimeState $Name { param($st)
    $script:up = Test-KitRuntimeUp $Name $(if ($NoWait) { 5 } else { 20 })
    $st.leases = @($st.leases | Where-Object { -not ($_.agent -eq $Agent -and "$($_.session)" -eq $Session) })   # one per agent + session
    $l = New-KitLease $Agent $Session; if ($Auto) { $l.auto = $true; $l.used = (Get-Date).ToString('o') }
    $st.leases += $l; $st.Remove('emptySince')
    if ($script:up -eq $false) { $st.startedByKit = $true; $st.startedAt = (Get-Date).ToString('o') }
  }
  $up = $script:up
  if ($up) { return "runtime ${Name}: running; leased by $Agent" }
  if ($null -eq $up) { return "runtime ${Name}: state unknown (isUp timed out); leased by $Agent, nothing started" }
  $line = Get-KitSetting "runtimes.$Name.up" ''
  if (-not $line) { return "runtime ${Name}: not running; leased by $Agent (no runtimes.$Name.up: your command starts it, the kit stops it after the last release)" }
  if ($NoWait) {   # the guard: a hook must answer in seconds
    Start-Detached 'pwsh' @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$env:WSL_UTF8 = '1'; $line")))
    return "runtime ${Name}: was not running: starting it ($line); leased by $Agent"
  }
  $r = Invoke-KitRuntimeCmd $line 300
  for ($i = 0; $i -lt 40 -and -not ($ok = Test-KitRuntimeUp $Name); $i++) { Wait-KitPoll 3 }
  if (-not $ok) { throw "runtime ${Name}: started ($line, exit $($r.code)) but isUp does not answer after 2 min: $(@("$($r.err)" -split "`n")[0])" }
  "runtime ${Name}: started by the kit ($line); leased by $Agent"
}

function Remove-KitRuntimeLease([string]$Name, [scriptblock]$Which, [string]$Why = 'released') {
  $script:rtMsg = ''
  Update-KitRuntimeState $Name { param($st)
    $gone = @($st.leases | Where-Object { & $Which $_ }); $st.leases = @($st.leases | Where-Object { -not (& $Which $_) })
    $script:rtMsg = "runtime ${Name}: $($gone.Count) lease(s) $Why ($((@($gone | ForEach-Object { $_.agent }) -join ', ')))$(if ($st.leases.Count) { "; $($st.leases.Count) left" })"
    if (-not $st.leases.Count -and $st.startedByKit) { $script:rtMsg += "`n" + (Stop-KitRuntime $Name $st) }
    elseif (-not $st.leases.Count) { $script:rtMsg += '; not started by the kit: left running' }
  }
  $script:rtMsg
}

# ---- verb: crafty.ps1 runtime
function Invoke-Runtime {
param([Parameter(Mandatory, Position = 0)][ValidateSet('use', 'release', 'status')][string]$Action, [string]$Name, [string]$Agent, [string]$Session, [switch]$Json)
$ErrorActionPreference = 'Stop'
if (-not $Agent) { $Agent = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' } }
$names = @(Get-KitRuntimeNames)
if ($Name -and $Name -notin $names) { [Console]::Error.WriteLine("runtime: no kit.local.json runtimes.$Name.isUp (configured: $(if ($names.Count) { $names -join ', ' } else { 'none' }))"); exit 1 }
switch ($Action) {
  'use' { if (-not $Name) { [Console]::Error.WriteLine('runtime use: -Name <runtime> is required'); exit 2 }; Use-KitRuntime $Name $Agent $Session }
  'release' {
    $mine = { param($l) $l.agent -eq $Agent -and (-not $Session -or "$($l.session)" -eq $Session) }
    $out = foreach ($n in @(if ($Name) { $Name } else { $names | Where-Object { @((Get-KitRuntimeState $_).leases | Where-Object { & $mine $_ }).Count } })) { Remove-KitRuntimeLease $n $mine }
    if (-not $out) { "runtime: no lease of $Agent" }
    $out; if ("$out" -match 'down failed') { exit 1 }
  }
  'status' {
    $rows = foreach ($n in @(if ($Name) { $Name } else { $names })) {
      $st = Get-KitRuntimeState $n
      [pscustomobject]@{ name = $n; running = (Test-KitRuntimeUp $n); startedByKit = [bool]$st.startedByKit
        leases = @($st.leases | ForEach-Object { [pscustomobject]@{ agent = $_.agent; session = $_.session; auto = [bool]$_.auto; live = [bool](Test-KitRuntimeLease $_); at = $_.at } }) }
    }
    if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 5; return }
    foreach ($r in $rows) { "runtime $($r.name): $(switch ($r.running) { $true { 'running' } $false { 'not running' } default { 'unknown' } })$(if ($r.startedByKit) { ' (started by the kit)' }); leases: $(if ($r.leases.Count) { ($r.leases | ForEach-Object { "$($_.agent)$(if ($_.auto) { ' (auto)' })$(if (-not $_.live) { ' (no live holder)' })" }) -join ', ' } else { 'none' })" }
  }
}
}

# crafty.ps1 guard: a command matching runtimes.<n>.match from an agent without a lease -> an auto lease (started if down), one line for it
Register-KitAdapter 'guard' 'runtimes' @{ check = { param($a)
    $raw = "$($a.raw)"; $rts = @(Get-KitRuntimeNames)
    if (-not $rts.Count -or $raw -match '(?:crafty|dev)\.ps1["'']?\s+runtime\b') { return }   # shim: remove after 2026-11-23 (dev.ps1)
    # what runs, one segment per command (match may anchor with ^): the command minus quoted data, plus what a shell -c /
    # -Command or the gate's -Cmd is told to run
    $text = "$($a.cmd)`n" + ((@([regex]::Matches($raw, '(?i)(?:^|\s)-(?:c|Command|Cmd)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')') | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value })) -join "`n")
    $segs = @($text -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() -replace '^&\s*' } | Where-Object { $_ })
    $who = if ($raw -match 'CLAUDE_AGENT\s*=\s*[''"]?([\w.@:-]+)') { $Matches[1] } elseif ($a.hook.agent_type) { "$($a.hook.agent_type)$(if ($a.hook.agent_id) { '-' + "$($a.hook.agent_id)".Substring(0, [math]::Min(8, "$($a.hook.agent_id)".Length)) })" } else { 'main' }
    $notes = foreach ($n in $rts) {
      $m = "$(Get-KitSetting "runtimes.$n.match" '')"; if (-not $m -or -not @($segs | Where-Object { $_ -match $m }).Count) { continue }
      if ((Test-Path "$(Get-KitRuntimeFile $n).lock") -and ((Get-Date) - (Get-Item "$(Get-KitRuntimeFile $n).lock").LastWriteTime).TotalMinutes -lt 2) { continue }   # a use / down in progress: never past the hook timeout; the next command retries
      $mine = @((Get-KitRuntimeState $n).leases | Where-Object { $_.agent -eq $who })
      if ($mine.Count) { if (@($mine | Where-Object { $_.auto }).Count) { Update-KitRuntimeState $n { param($st) foreach ($l in @($st.leases | Where-Object { $_.agent -eq $who -and $_.auto })) { $l.used = (Get-Date).ToString('o') } } }; continue }
      try { "$(Use-KitRuntime $n $who -Auto -NoWait). When done: & $($KitCmd.dev) runtime release -Name $n -Agent $who" } catch {}   # never fail a hook over a lease
    }
    if ($notes) { @{ note = ($notes -join "`n") } }
  } }

# ---- supervise: idle leases, kit-started runtimes
# bossy.ps1 supervise (section 3): lease liveness, -AutoFix releases dead leases and stops a kit-started runtime nobody holds
function Get-KitSuperviseGuardRuntimes([switch]$AutoFix) {
  $grace = [double](Get-KitParam 'idle.graceMinutes' 10)
  foreach ($n in Get-KitRuntimeNames) {
    if (-not (Test-Path (Get-KitRuntimeFile $n))) { continue }
    $pre = Get-KitRuntimeState $n; if (-not $pre.leases.Count -and -not $pre.startedByKit) { continue }
    $script:rtOut = @()
    Update-KitRuntimeState $n { param($st)
      $now = Get-Date; $running = Test-KitRuntimeUp $n 10
      # stopped outside the kit: whoever starts it next owns it (not while the kit's own start may still be booting)
      if ($running -eq $false -and $st.startedByKit -and -not ($st.startedAt -and ($now - [datetime]$st.startedAt).TotalMinutes -lt $grace)) { $st.startedByKit = $false; $st.Remove('emptySince') }
      $dead = @(foreach ($l in $st.leases) {
          if (Test-KitRuntimeLease $l) { $l.seen = $now.ToString('o'); continue }
          if (-not $l.seen) { $l.seen = $now.ToString('o') }
          if (($now - [datetime]$l.seen).TotalMinutes -ge $grace) { $l }
        })
      foreach ($l in $dead) {
        if ($AutoFix) { $st.leases = @($st.leases | Where-Object { $_ -ne $l }); $script:rtOut += [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: runtime ${n}: released the lease of $($l.agent) (no live holder for $grace+ min)"; action = 'Nothing to do.' } }
        else { $script:rtOut += [pscustomobject]@{ level = 'WATCH'; what = "runtime ${n}: the lease of $($l.agent) has no live holder"; action = 'supervise -AutoFix releases it (and stops the runtime when the kit started it).' } }
      }
      if ($st.startedByKit -and -not $st.leases.Count -and $null -ne $running) {   # unknown state: never a stop
        if (-not $st.emptySince) { $st.emptySince = $now.ToString('o') }
        if ($dead.Count -or ($now - [datetime]$st.emptySince).TotalMinutes -ge $grace) {
          if ($AutoFix) { $msg = Stop-KitRuntime $n $st; $script:rtOut += [pscustomobject]@{ level = $(if ($msg -match 'failed') { 'WATCH' } else { 'INFO' }); what = $(if ($msg -match 'failed') { $msg } else { "auto-fixed: $msg" }); action = $(if ($msg -match 'failed') { "Run runtimes.$n.down by hand; check the config." } else { 'Nothing to do.' }) } }
          else { $script:rtOut += [pscustomobject]@{ level = 'WATCH'; what = "runtime ${n}: started by the kit, no lease since $([int]($now - [datetime]$st.emptySince).TotalMinutes) min"; action = 'supervise -AutoFix stops it.' } }
        }
      }
      $script:rtOut += "runtime ${n}: $(switch ($running) { $true { 'running' } $false { 'not running' } default { 'unknown' } })$(if ($st.startedByKit) { ' (kit-started)' }), $($st.leases.Count) lease(s)"
    }
    $script:rtOut
  }
}
