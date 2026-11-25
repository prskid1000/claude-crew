#Requires -Version 7
<#
waits.ps1: waits past their cap in bossy.ps1 supervise (dot-sourced by bossy.ps1 from skills/bossy/adapters/; owner 2026-11-19
"too much waiting"): WAIT OVER CAP (a test lock or phone lane wait past supervise.stuckMinutes, with its holder) and QA SLOW (a QA
package past qa.packageMinutes, learned per lane at pokey.ps1 seat release; it goes on, never NOT_TESTED for time). The build gate,
env starts and trains flag on their own (supervise-resources.ps1, localenv-supervise.ps1).
Usage: dot-sourced by bossy.ps1; supervise runs its hook Get-KitSuperviseFlagsWaits (Invoke-KitHooks Get-KitSuperviseFlags).
Exit codes: none (functions only).
Sections: L11 waits
#>
# ---- waits: test lock and phone waits at least $CapMin old -> { agent; why; min; holder; next }; QA packages past their learned time
function Get-KitWaitsOverCap([datetime]$Now, [double]$CapMin) {
  $st = Get-KitLockState; $phones = @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.lane -and $_.agent -and $_.agent -ne '__stopping__' })
  foreach ($w in @($st.waiting)) { $m = [int]($Now - [datetime]$w.at).TotalMinutes
    if ($m -ge $CapMin) { [pscustomobject]@{ agent = $w.holder; why = "test lock $($w.lock)"; min = $m; holder = "$($st.held[$w.lock].holder)"; next = 'crafty.ps1 check takes it when its holder ends' } } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($Now - $_.LastWriteTime).TotalMinutes -lt (Get-KitParam 'phone.waitFreshMinutes') })) {
    $w = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }; if (-not $w.since) { continue }; $m = [int]($Now - [datetime]$w.since).TotalMinutes
    $hs = @($phones | Where-Object { -not $w.lane -or $_.lane -eq $w.lane } | ForEach-Object { "$($_.agent) ($($_.lane))" })
    if ($m -ge $CapMin) { [pscustomobject]@{ agent = $w.agent; why = "phone $(if ($w.lane) { "lane $($w.lane)" } else { 'any lane' })"; min = $m; holder = ($hs -join ', '); next = 'phoney.ps1 acquire hands it the first lane released (phoney.ps1 status)' } } }
}
# a pokey seat (one per QA package) older than qa.packageMinutes for its lane -> { agent; kind; min; expect; now = its board status }
function Get-KitQaSlow([datetime]$Now) {
  $board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' })
  foreach ($s in @(Read-KitJsonFiles (Join-Path (Get-KitPath qa-seats) 'seats') | Where-Object { $_.since -and $_.kind })) {
    $m = [int]($Now - [datetime]$s.since).TotalMinutes; $x = [double](Get-KitParam 'qa.packageMinutes' $null "$($s.kind)"); if ($m -lt $x) { continue }
    $b = @($board | Where-Object { $_.agent -eq "$($s.lease)" } | Sort-Object { [datetime]$_.beat } -Descending)[0]
    [pscustomobject]@{ agent = "$($s.agent)"; kind = "$($s.kind)"; min = $m; expect = [int]$x; now = $(if ($b) { "$($b.status), beat $(([datetime]$b.beat).ToString('HH:mm'))" } else { 'no board row' }) }
  }
}
# a deploy nobody finishes: a schedule target done (a running CI target: its run asked, at most 4 calls a sweep) $Min+ ago and no
# deploy record for its target since (2026-11-25: opsy's new watch never armed; pipelines done 11:03, record / intest found 40 min later)
function Get-KitDeployIdle([datetime]$Now, [double]$Min) {
  $recs = @(Read-KitLog deploy-log -Since $Now.AddDays(-2) | Where-Object { $_.event -eq 'record' }); $calls = 0
  $who = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and "$($_.type)" -eq 'opsy' } | ForEach-Object agent)
  foreach ($f in @(Get-ChildItem (Get-KitPath deploys) -Filter 'schedule-*.json' -File -ErrorAction SilentlyContinue | Where-Object { ($Now - $_.LastWriteTime).TotalHours -lt 24 })) {
    $doc = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($i in @($doc.items | Where-Object { $_.status -in 'running', 'success', 'failed' })) {
      $fin = if ($i.status -ne 'running') { ConvertTo-KitOffset $i.finishedAt } elseif ($i.sha -and $i.branch -and $i.kind -in 'ci-job', 'branch-mr' -and ($calls++) -lt 4) {
        $r = @(@(try { Invoke-HostVerb 'ci.runs' @{ repo = (Get-HostProject $i.repo -Raw); ref = $i.branch; per_page = 10 } -NoMemo } catch { }) | Where-Object { $_ -and "$($_.sha)".StartsWith("$($i.sha)") })[0]
        if ($r -and (ConvertTo-KitCiState "$($r.status)") -in 'success', 'failed', 'canceled') { ConvertTo-KitOffset $r.updated_at } }
      if (-not $fin -or ($m = [int]($Now - $fin.LocalDateTime).TotalMinutes) -lt $Min) { continue }
      if (@($recs | Where-Object { "$($_.target)" -eq "$($i.target)" -and (ConvertTo-KitOffset $_.at) -ge $fin }).Count) { continue }
      [pscustomobject]@{ agent = $(if ($who.Count) { $who -join ', ' } else { 'no live opsy' }); name = "$($i.name)"; target = "$($i.target)"; min = $m } } }
}
# a turn that ended on a wait with nothing to wake it: the last model text says it waits / monitors, every background task or monitor
# it started has ended, idle $Min+ -> { agent; min; said } (subagents share one claude pid: the transcript is the only witness)
function Get-KitStalledWaits([datetime]$Now, [double]$Min) {
  $rx = '(?i)\b(waiting|i.ll wait|monitor(ing)?|(will|i.ll) (follow|watch|check back|report back|resume)|once (it|the|they|both)\b.{0,40}\b(finish|complete|done)|wakes? me)\b'
  foreach ($b in @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and $_.transcript })) {
    $fi = Get-Item -LiteralPath "$($b.transcript)" -ErrorAction SilentlyContinue; if (-not $fi -or ($m = [int]($Now - $fi.LastWriteTime).TotalMinutes) -lt $Min) { continue }
    $fs = [IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite, Delete'); try { $n = [int][math]::Min($fs.Length, 262144); $null = $fs.Seek(-$n, 'End'); $buf = [byte[]]::new($n); $null = $fs.Read($buf, 0, $n) } finally { $fs.Dispose() }
    $last = @([Text.Encoding]::UTF8.GetString($buf) -split "`n" | Where-Object { $_ -match '"type":"assistant"' })[-1]; $o = try { $last | ConvertFrom-Json -Depth 30 } catch { $null }
    if (-not $o -or @($o.message.content | Where-Object type -eq 'tool_use').Count) { continue }   # mid-tool or unreadable: not a stalled end
    $said = (@($o.message.content | Where-Object type -eq 'text' | ForEach-Object text) -join ' ').Trim(); if ($said -notmatch $rx) { continue }
    $on = @{}; foreach ($h in @(Select-String -LiteralPath $fi.FullName -Pattern 'background with ID: (\w+)|background \(ID: (\w+)\)|<task-id>(\w+)</task-id>.{0,400}?<status>(\w+)</status>' -AllMatches | ForEach-Object Matches)) {
      if ($h.Groups[4].Success) { if ($h.Groups[4].Value -match '^(completed|failed|killed|stopped|timeout|expired|error)$') { $on.Remove($h.Groups[3].Value) } } else { $on[@($h.Groups[1].Value, $h.Groups[2].Value | Where-Object { $_ })[0]] = 1 } }
    if ($on.Count) { continue }
    [pscustomobject]@{ agent = "$($b.agent)"; min = $m; said = $(if ($said.Length -gt 160) { $said.Substring(0, 160) + ' …' } else { $said }) } }
}
function Get-KitSuperviseFlagsWaits([switch]$AutoFix, [datetime]$At = (Get-Date)) {
  $cap = [double](Get-KitParam 'supervise.stuckMinutes')
  foreach ($d in @(Get-KitDeployIdle $At 10)) {
    [pscustomobject]@{ level = 'ACT'; what = "DEPLOY IDLE: $($d.name) -> $($d.target) finished $($d.min) min ago, no deploy record (agent: $($d.agent))"; kind = 'DEPLOY IDLE'; who = $d.agent; age = "$($d.min) min"; problem = 'verify / record / intest not run'
      action = "SendMessage $($d.agent): bossy.ps1 deploy watch -Env $($d.target) (as one background command), then opsy steps 5-7; no live opsy: respawn opsy (kind deploy, resume)" } }
  foreach ($s in @(Get-KitStalledWaits $At 10)) {
    [pscustomobject]@{ level = 'ACT'; what = "STALLED: $($s.agent) ended its turn waiting $($s.min) min ago with nothing to wake it: $($s.said)"; kind = 'STALLED'; who = $s.agent; age = "$($s.min) min"; problem = 'a wait with no live background command or monitor'
      action = "SendMessage $($s.agent): your wait has no waker: rerun the wait as one background command whose exit wakes you (deploy watch, crafty.ps1 pipes), or go on" } }
  foreach ($w in @(Get-KitWaitsOverCap $At $cap)) {
    [pscustomobject]@{ level = 'WATCH'; what = "WAIT OVER CAP: $($w.agent) waits $($w.min) min (cap $cap) for $($w.why), held by $($w.holder)"; kind = 'WAIT'; who = $w.agent; age = "$($w.min) min"; problem = $w.why
      action = "$($w.next); the holder releases right after its last use (bossy.ps1 release -Agent <holder>); a dead holder: supervise -AutoFix reclaims it after idle.graceMinutes" } }
  foreach ($q in @(Get-KitQaSlow $At)) {
    [pscustomobject]@{ level = 'WATCH'; what = "QA SLOW: $($q.agent) ($($q.kind)) $($q.min) min, learned $($q.expect) min; now: $($q.now)"; kind = 'QA SLOW'; who = $q.agent; age = "$($q.min) min"; problem = $q.now
      action = 'Read its transcript tail: waiting on a lane / env -> its holder releases; a hang -> restart that step; near its budget it hands off with the checks left' } }
}
