#Requires -Version 7
<#
waits.ps1: waits past their cap in bossy.ps1 supervise (dot-sourced by bossy.ps1 from skills/bossy/adapters/; owner 2026-11-19
"too much waiting"): WAIT OVER CAP (a test lock or phone lane wait past supervise.stuckMinutes, with its holder) and QA SLOW (a QA
package past qa.packageMinutes, learned per lane at pokey.ps1 seat release; it goes on, never NOT_TESTED for time). The build gate,
env starts and trains flag on their own (supervise_resources.ps1, localenv_supervise.ps1).
Usage: dot-sourced by bossy.ps1; supervise runs its hook Get-KitSuperviseFlagsWaits (Invoke-KitHooks Get-KitSuperviseFlags).
Exit codes: none (functions only).
Sections: L11 waits
#>
# ---- waits: test lock and phone waits at least $CapMin old -> { agent; why; min; holder; next }; QA packages past their learned time
function Get-KitWaitsOverCap([datetime]$Now, [double]$CapMin) {
  $st = Get-KitLockState; $phones = @(Read-KitJsonFiles (Get-KitPath phones) | Where-Object { $_.lane -and $_.agent -and $_.agent -ne '__stopping__' })
  foreach ($w in @($st.waiting)) { $m = [int]($Now - [datetime]$w.at).TotalMinutes
    if ($m -ge $CapMin) { [pscustomobject]@{ agent = $w.holder; why = "test lock $($w.lock)"; min = $m; holder = "$($st.held[$w.lock].holder)"; next = 'crafty.ps1 check takes it when its holder ends' } } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($Now - $_.LastWriteTime).TotalMinutes -lt 3 })) {
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
function Get-KitSuperviseFlagsWaits([switch]$AutoFix, [datetime]$At = (Get-Date)) {
  $cap = [double](Get-KitParam 'supervise.stuckMinutes')
  foreach ($w in @(Get-KitWaitsOverCap $At $cap)) {
    [pscustomobject]@{ level = 'WATCH'; what = "WAIT OVER CAP: $($w.agent) waits $($w.min) min (cap $cap) for $($w.why), held by $($w.holder)"; kind = 'WAIT'; who = $w.agent; age = "$($w.min) min"; problem = $w.why
      action = "$($w.next); the holder releases right after its last use (bossy.ps1 release -Agent <holder>); a dead holder: supervise -AutoFix reclaims it after idle.graceMinutes" } }
  foreach ($q in @(Get-KitQaSlow $At)) {
    [pscustomobject]@{ level = 'WATCH'; what = "QA SLOW: $($q.agent) ($($q.kind)) $($q.min) min, learned $($q.expect) min; now: $($q.now)"; kind = 'QA SLOW'; who = $q.agent; age = "$($q.min) min"; problem = $q.now
      action = 'Read its transcript tail: waiting on a lane / env -> its holder releases; a hang -> restart that step; near its budget it hands off with the checks left' } }
}
