#Requires -Version 7
<#
outcomes.ps1: result signals for the learning loop (dot-sourced by bossy.ps1 from skills/bossy/adapters/): per-task outcome rows
(.state/outcomes.jsonl, one row per state change), their summary (tidy prep digest, dashboard Kit internals), owner decision
patterns -> standing rule proposals; approved rules answer matching decide asks (never deploy, data, prod or customer-visible);
the retro-due rule, open collisions and the tidy verb (from bossy.ps1: its token cap).
Usage: & <kit>/skills/bossy/bossy.ps1 tidy prep · decide rules [-Propose] [-Approve <ids|all>] [-Revoke <id>] [-Json]
Inputs: .state/tasks/*.json, work/waves/*.json, work/launches/self-*.json, .state/decisions.jsonl. Outputs: outcomes.jsonl,
standing-rules.json, rules/standing-rules.local.md (approved rules only).
Exit codes: 0 ok · 1 problem · 2 usage (bossy.ps1 decide).
Sections: L14 outcomes · L112 summary · L272 patterns · L309 rules · L387 retro due · L398 tidy · L500 collisions · L518 decisions
#>

# ---- outcomes: one row per task state change; tracker-generic (task index, wave reports, launches, decisions)
$script:KitOutcomeKeys = @('kind', 'parent', 'area', 'agents', 'stage', 'mrs', 'qaRuns', 'qaFirstPass', 'qaFails', 'bugs', 'cameBack', 'backWhy', 'backChecks', 'localRounds', 'reviewFix', 'decisions', 'hPromoted', 'hStart', 'hClosed', 'spend', 'doneAt', 'closedAt', 'backAt')
function ConvertTo-KitOutcomeIso($At) { if (-not $At) { return $null }; try { ([datetimeoffset]$At).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { $null } }   # UTC text: sorts and compares as a string
function Get-KitOutcomeHours($From, $To) { if (-not $From -or -not $To) { return $null }; try { [math]::Round(([datetime]$To - [datetime]$From).TotalHours, 1) } catch { $null } }
# a person's answer, not an agent's, a standing rule's or a superseded one
function Get-KitOwnerAnswers {
  $crew = @('coordinator') + @(Get-ChildItem (Join-Path $KitConf.Kit 'agents') -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object BaseName)
  $crewRx = "(?i)^($(@($crew | ForEach-Object { [regex]::Escape($_) }) -join '|'))([-_ :]|$)"
  $last = [ordered]@{}; foreach ($r in @(Read-KitLog decisions-log ([datetime]::MinValue))) { if ($r.id -and $r.event -eq 'answered') { $last["$($r.id)"] = $r } }
  $gone = @($last.Values | ForEach-Object { @($_.supersedes) } | Where-Object { $_ })
  @($last.Values | Where-Object { $_.kind -ne 'envfix' -and $_.item -ne 'standing-rules' -and $_.answer -and "$($_.by)" -notmatch $crewRx -and "$($_.source)" -ne 'rule' -and "$($_.by)" -notmatch '^standing rule' -and $_.id -notin $gone })
}
function Get-KitOutcomeContext {
  $c = @{ ix = @{}; agents = @{}; local = @{}; review = @{}; bugs = @{}; decisions = @{}; spend = @{}; startAt = @{} }
  foreach ($x in @(Read-KitJsonFiles (Get-KitPath tasks))) { if ($x.task) { $c.ix["$($x.task)"] = $x } }
  # [Bug] tasks under a task (its count; never its came-back: owner 2026-11-26, a new defect is not the task failing)
  foreach ($x in $c.ix.Values) { if ($x.parent -and ("$($x.spec.kind)" -match '(?i)bug' -or (Test-KitBugName "$($x.spec.title)") -or 'bug' -in @($x.tags))) { $c.bugs["$($x.parent)"] = @(@($c.bugs["$($x.parent)"]) + "$($x.task)") } }
  # local rounds = the Rows of the goals doc's Rounds table (devtools.py ROUNDS_TABLE), its newest published version
  $c.goals = @{}; $rx = '(?im)^\|\s*Round\s*\|\s*Date\s*\|\s*Cases run\s*\|\s*Result\s*\|\s*Bugs found\s*\|\s*Fix commit\s*\|\s*Retest\s*\|[^\n]*\n\|[-:| ]+\|[ \t]*\n?((?:\|[^\n]*\n?)*)'
  foreach ($t in $c.ix.Keys) { $pf = Join-Path (Get-KitPath published) "$($t -replace '[^\w.-]+', '_')_testing-ai.json"
    if (Test-Path -LiteralPath $pf) { try { $b = "$(@((Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json).rounds)[-1].body)"; if ($b -match $rx) { $c.goals[$t] = @($Matches[1] -split '\r?\n' | Where-Object { $_.Trim() }).Count } } catch { } } }
  foreach ($w in @(Read-KitJsonFiles (Get-KitPath waves))) {
    foreach ($p in @(Get-KitProps $w.agents)) { foreach ($t in @($p.Value.done | Where-Object { $_ })) {
      $c.agents[$t] = @(@($c.agents[$t]) + $p.Name | Where-Object { $_ } | Select-Object -Unique)
      $c.local[$t] = [int]$c.local[$t] + [int]$p.Value.localRounds; $c.review[$t] = [int]$c.review[$t] + [int][bool]$p.Value.fixedRound } }
  }
  foreach ($d in @(Get-KitOwnerAnswers | Where-Object task)) { $c.decisions["$($d.task)"] = [int]$c.decisions["$($d.task)"] + 1 }
  $ids = @($c.ix.Keys)
  foreach ($l in @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { $_.at -and "$($_.script)" -match 'buildy' })) {   # agent start: the first build run naming the task
    $raw = "$($l.argsRaw)$(if (-not $l.argsRaw) { $l.args | ConvertTo-Json -Compress -Depth 8 })"; $la = ConvertTo-KitOutcomeIso $l.at
    foreach ($t in @($ids | Where-Object { $raw.Contains($_) })) { if (-not $c.startAt[$t] -or $la -lt $c.startAt[$t]) { $c.startAt[$t] = $la } }
  }
  foreach ($l in @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { [double]$_.spent -gt 0 })) {   # a run's spend split over the tasks its args name
    $raw = "$($l.argsRaw)$(if (-not $l.argsRaw) { $l.args | ConvertTo-Json -Compress -Depth 8 })"; $hit = @($ids | Where-Object { $raw.Contains($_) })
    foreach ($t in $hit) { $c.spend[$t] = [double]$c.spend[$t] + [double]$l.spent / $hit.Count }
  }
  $c
}
function Get-KitTaskOutcome($Ix, $Ctx) {
  $t = "$($Ix.task)"; $tr = $Ix.track; $runs = @($Ix.envRuns | Where-Object { $_ }); $last = $runs | Select-Object -Last 1
  $clean = { param($r) $r -and [int]$r.fail -eq 0 -and [int]$r.notTested -eq 0 -and [int]$r.pass -gt 0 }
  # came back = its own checks failed in QA (envRuns fail: pokey finalize counts own defects only), else reopened (MRs after promoted)
  $own = @($runs | Where-Object { [int]$_.fail -gt 0 }); $fails = $own.Count; $why = if ($fails) { 'qa' } elseif ($tr.reopenedAt) { 'reopened' } else { '' }
  $bugs = @(@($Ctx.bugs[$t]) + @($runs | ForEach-Object { "$($_.bug)" }) | Where-Object { $_ } | Select-Object -Unique).Count   # [Bug] tasks under it + the ones its runs raised
  $stage = if ($last) { if ([int]$last.fail) { 'failedTesting' } elseif (& $clean $last) { 'passed' } else { 'untested' } } elseif (@($tr.liveOn | Where-Object { $_ }).Count) { 'deployed' } elseif ($tr.done) { 'promoted' } elseif (@($tr.mrs | Where-Object { $_ }).Count) { 'review' } else { 'open' }
  [ordered]@{ task = $t; kind = "$($Ix.spec.kind)"; parent = "$($Ix.parent)"
    area = @(@($tr.mrs | Where-Object { $_ }) | ForEach-Object { Get-KitRepoName ((("$_" -split '[!#]')[0] -split '/')[-1]) } | Sort-Object -Unique) -join ','
    agents = @($Ctx.agents[$t] | Where-Object { $_ }); stage = $stage; mrs = @($tr.mrs | Where-Object { $_ }).Count; qaRuns = $runs.Count
    qaFirstPass = $(if ($runs.Count) { [bool](& $clean $runs[0]) } else { $null }); qaFails = $fails; bugs = $bugs
    cameBack = [bool]$why; backWhy = $why; backChecks = @($own | ForEach-Object { @($_.failIds) } | Where-Object { $_ } | Select-Object -Unique) -join ','
    localRounds = [math]::Max([int]$Ctx.local[$t], [int]$Ctx.goals[$t]); reviewFix = [int]$Ctx.review[$t]
    decisions = [int]$Ctx.decisions[$t]; hPromoted = $(if ($tr.done) { Get-KitOutcomeHours $tr.created $tr.doneAt })
    hStart = $(if ($tr.done) { Get-KitOutcomeHours (@(@($Ctx.startAt[$t], (ConvertTo-KitOutcomeIso $tr.created)) | Where-Object { $_ } | Sort-Object)[0]) $tr.doneAt })   # agent start (a build run, else the first track add) -> promoted
    hClosed = $(if ($stage -eq 'passed') { Get-KitOutcomeHours $tr.created $last.at }); spend = [int][math]::Round([double]$Ctx.spend[$t])
    doneAt = $(if ($tr.done) { ConvertTo-KitOutcomeIso $tr.doneAt }); closedAt = $(if ($stage -eq 'passed') { ConvertTo-KitOutcomeIso $last.at })   # the day chart's points
    backAt = @(@(ConvertTo-KitOutcomeIso $tr.reopenedAt) + @($runs | Where-Object { [int]$_.fail -gt 0 } | ForEach-Object { ConvertTo-KitOutcomeIso $_.at }) | Where-Object { $_ } | Sort-Object)[0]
    seen = $(if ($Ix.updated) { (Get-KitStamp stored ([datetime]$Ix.updated)) }) }   # the task's last change (window); not in the row signature
}
function Read-KitOutcomeRows { $f = Get-KitPath outcomes; if (Test-Path -LiteralPath $f) { foreach ($l in [IO.File]::ReadAllLines($f)) { try { $l | ConvertFrom-Json } catch {} } } }
# rows changed since the last sweep (-All: every task); cumulative fields never shrink (wave reports and launches age out)
function Update-KitOutcomes([switch]$All) {
  $t0 = Get-Date; $stampFile = Get-KitPath outcomes-sweep -Create
  $stamp = if (-not $All -and (Test-Path -LiteralPath $stampFile)) { try { [datetime](Get-Content -LiteralPath $stampFile -Raw).Trim() } catch { $null } }
  $fresh = { param($n, $f) @(Get-ChildItem -LiteralPath (Get-KitPath $n) -Filter $f -File -ErrorAction SilentlyContinue | Where-Object { -not $stamp -or $_.LastWriteTime -gt $stamp }).Count }
  if ($stamp -and -not ((& $fresh tasks '*.json') + (& $fresh waves '*.json') + (& $fresh launches 'self-*.json'))) { Set-Content -LiteralPath $stampFile (Get-KitStamp stored $t0); return 0 }
  $ctx = Get-KitOutcomeContext
  $n = Invoke-KitLocked (Get-KitPath outcomes -Create) {   # supervise and tidy prep: one sweep at a time, else duplicate rows
  $prev = @{}; foreach ($r in @(Read-KitOutcomeRows)) { if ($r.task) { $prev["$($r.task)"] = $r } }
  $n = 0; $sig = { param($o) ($script:KitOutcomeKeys | ForEach-Object { "$(@(Get-KitMember $o $_ | ForEach-Object { if ($_ -is [datetime]) { ConvertTo-KitOutcomeIso $_ } else { $_ } }) -join ',')" }) -join '|' }   # a read-back row holds times as DateTime
  foreach ($ix in $ctx.ix.Values) {
    $row = Get-KitTaskOutcome $ix $ctx; $p = $prev[$row.task]
    if ($p) { foreach ($k in 'localRounds', 'reviewFix', 'decisions', 'spend') { $row[$k] = [math]::Max([int]$row[$k], [int](Get-KitMember $p $k)) }; $row.agents = @(@($p.agents) + @($row.agents) | Where-Object { $_ } | Select-Object -Unique) }
    if ($p -and (& $sig $p) -eq (& $sig $row)) { continue }
    Write-KitLog outcomes 'state' $row; $n++
  }
  $n }
  Set-Content -LiteralPath $stampFile (Get-KitStamp stored $t0); $n
}
# supervise hook: every 30 min (lib.ps1 New-KitSweep; 1.5-3 s while tasks change; tidy prep runs its own), only when a task, wave or launch file changed
function Get-KitSuperviseFlagsOutcomes([switch]$AutoFix) { if (-not (Within 'outcomes')) { return }; try { $null = Update-KitOutcomes } catch { [pscustomobject]@{ level = 'WATCH'; what = "outcomes sweep failed: $($_.Exception.Message)"; action = 'bossy.ps1 tidy prep reruns it; else a kitty (kind fix)' } }; Get-KitMrSpreadFlags }
# multi-repo tasks (rechy-5: 2 MRs p50 2.7 h vs 1 MR 36 min): an open task's first MR per repo opened more than track.mrSpreadMinutes apart
# -> one WATCH per task; open times cached per ref (one mr.get each, at most 10 new per sweep: a first sweep stays short)
function Get-KitMrSpreadFlags {
  $cf = Join-Path (Get-KitPath cache -Create) 'mr-opened.json'; $op = @{}; if (Test-Path -LiteralPath $cf) { try { $op = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json -AsHashtable } catch { } }; if ($op -isnot [hashtable]) { $op = @{} }   # an empty file reads as null
  if (-not $op.flagged) { $op.flagged = @() }; $lim = [double](Get-KitParam 'track.mrSpreadMinutes'); $new = 0
  foreach ($o in @((Read-KitTracking).tasks.Values | Where-Object { $_ -and -not $_.done -and "$($_.task)" -notin $op.flagged -and @($_.mrs | Where-Object { $_ }).Count -ge 2 })) {
    $first = @{}; $cut = $false
    # a repo's lowest iid is its first MR: one host call per repo (27 refs over 3 tasks took 3 sweeps of 10 calls, 2026-11-25)
    foreach ($ref in @($o.mrs | Where-Object { "$_" -match '^[\w./-]+!\d+$' } | Group-Object { ("$_" -split '!')[0] } | ForEach-Object { @($_.Group | Sort-Object { [long](("$_" -split '!')[1]) })[0] })) { $rp, $n = "$ref" -split '!', 2
      if (-not $op.ContainsKey("$ref")) { if ($new -ge 10) { $cut = $true; continue }; $new++; $m = try { Invoke-HostVerb 'mr.get' @{ repo = (Get-HostProject $rp -Raw); n = $n } } catch { $null }; if (-not $m.created_at) { continue }; $op["$ref"] = ConvertTo-KitOutcomeIso $m.created_at }
      $ra = [datetimeoffset]$op["$ref"]; $rn = ($rp -split '/')[-1]; if (-not $first[$rn] -or $ra -lt $first[$rn]) { $first[$rn] = $ra } }
    $at = @($first.Values | Sort-Object)
    if (-not $cut -and $at.Count -ge 2 -and ($sp = [math]::Round(($at[-1] - $at[0]).TotalMinutes)) -gt $lim) { $op.flagged = @(@($op.flagged) + "$($o.task)")
      [pscustomobject]@{ level = 'WATCH'; what = "MR-SPREAD $($o.task): its repos' first MRs opened $sp min apart (over $lim; $(@($first.Keys | Sort-Object) -join ', '))"; action = 'devy opens every MR of a task together and merges each, producers first, once green (crafty ship.md); retro: why the late MR' } }
  }
  if ($new -or $op.flagged.Count) { Write-KitAtomic $cf ($op | ConvertTo-Json -Depth 4 -Compress) }
}

# ---- summary: worst areas, repeat causes, most fix rounds (tidy prep digest, dashboard)
function Get-KitOutcomeStats([int]$Days = (Get-KitParam 'outcomes.days'), [datetime]$StatsFrom = [datetime]::MinValue) {   # the page: Get-KitStatsCutoff
  $since = (Get-Date).AddDays(-$Days); if ($StatsFrom -gt $since) { $since = $StatsFrom }; $last = @{}; $allRows = @(Read-KitOutcomeRows)
  foreach ($r in $allRows) { $w = @($r.seen, $r.at | Where-Object { $_ })[0]; if ($r.task) { if ($w -and [datetime]$w -ge $since) { $last["$($r.task)"] = $r } else { $last.Remove("$($r.task)") } } }
  # status per past day (owner 2026-11-25): the rows replayed to each day's end, the same window rule; a day before the first row or StatsFrom: none
  $stageDays = @{}; $byAt = @($allRows | Where-Object { $_.task -and $_.at } | Sort-Object { [datetimeoffset]$_.at }); $asOf = @{}; $ri = 0
  if ($byAt.Count) { foreach ($back in ([math]::Max(2, [int](Get-KitParam 'supervise.statsDays')) - 1)..1) { $dayEnd = [datetimeoffset](Get-Date).Date.AddDays(1 - $back)
      if ($dayEnd -le [datetimeoffset]$byAt[0].at -or $dayEnd.LocalDateTime -le $StatsFrom) { continue }
      while ($ri -lt $byAt.Count -and [datetimeoffset]$byAt[$ri].at -lt $dayEnd) { $asOf["$($byAt[$ri].task)"] = $byAt[$ri]; $ri++ }
      $winFrom = $dayEnd.AddDays(-$Days); if ($StatsFrom -gt $winFrom.LocalDateTime) { $winFrom = [datetimeoffset]$StatsFrom }
      $stageDays[$dayEnd.AddDays(-1).ToString('yyyy-MM-dd')] = @($asOf.Values | Where-Object { [datetimeoffset]@($_.seen, $_.at | Where-Object { $_ })[0] -ge $winFrom } | ForEach-Object { [pscustomobject]@{ id = "$($_.task)"; stage = "$($_.stage)" } }) } }
  $rows = @($last.Values); foreach ($r in $rows) { $r.area = @("$($r.area)" -split ',' | Where-Object { $_ } | ForEach-Object { Get-KitRepoName $_ } | Sort-Object -Unique) -join ',' }   # rows written before alias names
  $qa = @($rows | Where-Object { [int]$_.qaRuns -gt 0 })
  $rounds = { param($r) [math]::Max(0, [int]$r.localRounds - 1) + [int]$r.reviewFix }
  $hp = @($rows | Where-Object { $null -ne $_.hPromoted } | ForEach-Object { [double]$_.hPromoted } | Sort-Object)
  $areas = @($rows | ForEach-Object { $r = $_; foreach ($a in @("$($r.area)" -split ',' | Where-Object { $_ })) { [pscustomobject]@{ area = $a; r = $r } } } | Group-Object area | ForEach-Object {
    $g = @($_.Group.r); $gq = @($g | Where-Object { [int]$_.qaRuns -gt 0 })
    [pscustomobject]@{ area = $_.Name; n = $g.Count; qaN = $gq.Count; firstPass = @($gq | Where-Object qaFirstPass).Count; cameBack = @($g | Where-Object cameBack).Count
      rounds = [int](@($g | ForEach-Object { & $rounds $_ }) | Measure-Object -Sum).Sum; spend = [int](@($g.spend) | Measure-Object -Sum).Sum } } |
    ForEach-Object { $_ | Add-Member -PassThru score ((2 * $_.cameBack) + ($_.qaN - $_.firstPass) + $_.rounds) } | Sort-Object { -$_.score }, area)
  $agents = @($rows | ForEach-Object { $r = $_; foreach ($a in @($r.agents | Where-Object { $_ })) { [pscustomobject]@{ agent = $a; n = & $rounds $r } } } | Group-Object agent |
    ForEach-Object { [pscustomobject]@{ agent = $_.Name; tasks = $_.Count; rounds = [int](@($_.Group.n) | Measure-Object -Sum).Sum } } | Where-Object rounds | Sort-Object { -$_.rounds }, agent)
  $why = @(foreach ($w in @(Read-KitJsonFiles (Get-KitPath waves) | Where-Object { $_.at -and [datetime]$_.at -ge $since })) { foreach ($p in @(Get-KitProps $w.agents)) { foreach ($d in @($p.Value.deferred | Where-Object { $_.reason })) { [pscustomobject]@{ skill = 'outcome'; kind = "$($d.kind)"; text = "$($d.reason)"; ref = "$($w.run)/$($p.Name)" } } } })
  $causes = @(Get-KitSignalGroups $why @() ([double](Get-KitParam 'outcomes.causeSimilarity')) | Where-Object { $_.n -ge 2 } | Sort-Object { -$_.n })
  # dashboard: one bucket per task, a stacked bar per repo, KPIs with weekly points (the task's promoted day, else its last change)
  $tasks = @(foreach ($r in $rows) { [pscustomobject]@{ id = "$($r.task)"; repos = @("$($r.area)" -split ',' | Where-Object { $_ }); bucket = (Get-KitOutcomeBucket $r); rounds = $(if (@($r.agents | Where-Object { $_ }).Count) { & $rounds $r })
      week = [int][math]::Floor(((Get-Date) - [datetime]@($r.doneAt, $r.seen, $r.at | Where-Object { $_ })[0]).TotalDays / 7); at = (ConvertTo-KitOutcomeIso @($r.doneAt, $r.seen, $r.at | Where-Object { $_ })[0]); closedAt = (ConvertTo-KitOutcomeIso $r.closedAt); backAt = (ConvertTo-KitOutcomeIso $r.backAt)
      firstPass = [bool]$r.qaFirstPass; qa = [int]$r.qaRuns -gt 0; back = [bool]$r.cameBack; why = "$($r.backWhy)"; backChecks = "$($r.backChecks)"; hPromoted = $r.hPromoted; hStart = $r.hStart; nMr = [int]$r.mrs; stage = "$($r.stage)" } })
  $repos = @($tasks | ForEach-Object { $t = $_; foreach ($rp in $t.repos) { [pscustomobject]@{ repo = $rp; t = $t } } } | Group-Object repo | ForEach-Object {
      $g = @($_.Group.t); $b = [ordered]@{}; foreach ($k in $script:KitOutcomeBuckets.Keys) { $b[$k] = @($g | Where-Object bucket -eq $k | ForEach-Object id) }
      [pscustomobject]@{ repo = $_.Name; n = $g.Count; tested = @($g | Where-Object { $_.bucket -ne 'wait' }).Count; buckets = $b } } | Sort-Object { -$_.n }, repo)
  $med = { param($v) $s = @($v | Sort-Object); if ($s.Count) { $s[[int][math]::Floor(($s.Count - 1) / 2)] } }   # lower median, as p50Promoted
  $kpi = { param($ts) $q = @($ts | Where-Object qa); $bq = @($ts | Where-Object { $_.qa -or $_.back }); $rd = @($ts | Where-Object { $null -ne $_.rounds } | ForEach-Object { [double]$_.rounds }); $h = @($ts | Where-Object { $null -ne $_.hPromoted } | ForEach-Object { [double]$_.hPromoted }); $hs = @($ts | Where-Object { $null -ne $_.hStart } | ForEach-Object { [double]$_.hStart })
    $h1 = @($ts | Where-Object { $null -ne $_.hPromoted -and $_.nMr -le 1 } | ForEach-Object { [double]$_.hPromoted }); $hm = @($ts | Where-Object { $null -ne $_.hPromoted -and $_.nMr -gt 1 } | ForEach-Object { [double]$_.hPromoted })
    [pscustomobject]@{ first = $(if ($q.Count) { [math]::Round(100 * @($q | Where-Object firstPass).Count / $q.Count) }); firstOf = "$(@($q | Where-Object firstPass).Count)/$($q.Count)"
      back = $(if ($bq.Count) { [math]::Round(100 * @($bq | Where-Object back).Count / $bq.Count) }); backOf = "$(@($bq | Where-Object back).Count)/$($bq.Count)"
      rounds = (& $med $rd); roundsOf = $rd.Count; hours = (& $med $h); hoursOf = $h.Count; start = (& $med $hs); startOf = $hs.Count; one = (& $med $h1); oneOf = $h1.Count; multi = (& $med $hm); multiOf = $hm.Count } }
  $weeks = [int][math]::Ceiling($Days / 7)
  [pscustomobject]@{ days = $Days; n = $rows.Count; qaN = $qa.Count; firstPass = @($qa | Where-Object qaFirstPass).Count; cameBack = @($rows | Where-Object cameBack).Count
    p50Promoted = $(if ($hp.Count) { $hp[[int][math]::Floor(($hp.Count - 1) / 2)] }); areas = $areas; agents = $agents; causes = $causes
    tasks = $tasks; repos = $repos; stageDays = $stageDays; kpi = (& $kpi $tasks); weekly = @(for ($w = $weeks - 1; $w -ge 0; $w--) { & $kpi @($tasks | Where-Object week -eq $w) }) }
}
# a test run's QA outcome from the task index: its env runs named <date>[-<time>]-<name>, else its tasks' env runs inside its window
function Get-KitRunQa($Run, $Ix) {
  $from = try { [datetime]$Run.started } catch { $null }; $to = try { ([datetime]$Run.at).AddMinutes([double](Get-KitParam 'outcomes.runWindowMinutes')) } catch { $null }
  $hit = @(foreach ($x in @($Ix)) { foreach ($er in @($x.envRuns | Where-Object { $_ })) {
        $named = $Run.qaName -and "$($er.run)" -match "^\d{4}-\d\d-\d\d(-\d{6})?-$([regex]::Escape("$($Run.qaName)"))$"
        $inWin = "$($x.task)" -in @($Run.tasks) -and $from -and $er.at -and [datetime]$er.at -ge $from -and [datetime]$er.at -le $to
        if ($named -or $inWin) { [pscustomobject]@{ task = "$($x.task)"; pass = [int]$er.pass; fail = [int]$er.fail; nt = [int]$er.notTested } } } })
  if (-not $hit.Count) { return $null }
  [pscustomobject]@{ pass = [int]($hit | Measure-Object pass -Sum).Sum; fail = [int]($hit | Measure-Object fail -Sum).Sum; nt = [int]($hit | Measure-Object nt -Sum).Sum
    closed = @($hit | Where-Object { -not $_.fail -and -not $_.nt -and $_.pass } | ForEach-Object task | Select-Object -Unique); failed = @($hit | Where-Object fail | ForEach-Object task | Select-Object -Unique)
    untested = @($hit | Where-Object { -not $_.fail -and $_.nt } | ForEach-Object task | Select-Object -Unique) }
}
# the dashboard's Trends band (owner 2026-11-19: Delivery + Usage + Activity in one): one tile strip (KPIs + $UP tiles), ONE day heatmap
# in row groups (Delivery: MRs merged per repo, tasks closed, came back, runs started; tasks by outcome; work in flight; then $More rows
# @{ d = dates; v } and group headers; a day click filters the lists), $Blocks (spend), the task list; helpers by dynamic scope; $UP = Format-KitUsageHtml
# $Clock = Get-KitTaskClock (task-clock.ps1): each task row carries its clock, the Delivery line its live / over / stopped counts
function Format-KitDeliveryHtml($S, $UP, $More = @(), [string]$Blocks = '', $Clock = $(if (Get-Command Get-KitTaskClock -ErrorAction SilentlyContinue) { try { Get-KitTaskClock $at } catch { } })) {
  if (-not $S) { $S = [pscustomobject]@{ kpi = [pscustomobject]@{}; tasks = @(); repos = @() } }   # no outcome stats yet: the rest still shows
  $bk = $script:KitOutcomeBuckets; $tone = @{ r0 = 'sage'; r1 = 'slate'; r2 = 'watch'; r3 = 'plum'; rna = 'pale'; back = 'act'; wait = 'none' }
  $pc = { param($v) if ($null -eq $v) { '—' } else { "$v<small>%</small>" } }
  # KPI tiles: the value and its base once (owner 2026-11-19: no sparklines; the weekly trend is read in a retro)
  $tile = { param($label, $v, [string]$u, $sub) @{ v = $(if ($null -ne $v) { & $n1 $v } else { '—' }); u = $(if ($null -ne $v) { $u }); l = $label; tip = "${label}: $sub" } }
  $k = $S.kpi
  # came back, by reason (owner 2026-11-26: the split lives in this tile and the outcomes group line, no new section)
  $wyN = { param([string]$w) @($S.tasks | Where-Object { $_.back -and "$($_.why)" -eq $w }).Count }
  $wySplit = "own QA checks failed $(& $wyN 'qa') · reopened (MRs after promoted) $(& $wyN 'reopened')$(if ($nr = & $wyN '') { " · reason not recorded $nr" })"
  $kt = @((& $tile 'QA first pass' $k.first '%' "$($k.firstOf) tasks QA'd clean on the first run"), (& $tile 'came back' $k.back '%' "$($k.backOf) tasks: $wySplit (a [Bug] under a task never counts)"),
    (& $tile 'median fix rounds' $k.rounds '' "over $($k.roundsOf) tasks with a wave report"), (& $tile 'agent start to promoted, p50' $k.start ' h' "over $($k.startOf) promoted tasks (start: the first build run naming the task, else its first MR)"),
    (& $tile 'first MR to promoted, p50' $k.hours ' h' "over $($k.hoursOf) promoted tasks (first MR: the task's first track add)"), (& $tile 'tasks with 1 MR to promoted, p50' $k.one ' h' "first MR to promoted over $($k.oneOf) tasks with one MR"),
    (& $tile 'tasks with 2+ MRs to promoted, p50' $k.multi ' h' "first MR to promoted over $($k.multiOf) tasks with 2+ MRs"))
  $tiles = "<div class=tls data-mk=trend-tiles>$((Format-KitTiles $kt) -replace '^<div class=tls>|</div>$')$($UP.tpm)$($UP.tiles)</div>"
  $dy = @($UP.days | Where-Object { $_ }); $dayOf = { param($iso) if ($iso) { try { ([datetimeoffset]$iso).LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } } }
  $closed = @{}; $back = @{}; foreach ($t in @($S.tasks)) { if ($c = & $dayOf $t.closedAt) { $closed[$c] = @(@($closed[$c]) + $t.id | Where-Object { $_ }) }; if ($b = & $dayOf $t.backAt) { $back[$b] = @(@($back[$b]) + $t.id | Where-Object { $_ }) } }
  $noMr = @($S.tasks | Where-Object { -not $_.repos.Count }).Count
  $flight = [ordered]@{ open = @('in progress', ''); review = @('review', ''); promoted = @('promoted', 'ws'); intest = @('in test', 'fh l-watch'); failedTesting = @('failed testing', 'fh l-act') }
  $stOf = { param([string]$s) if ($s -in 'deployed', 'untested') { 'intest' } elseif ($flight.Contains($s)) { $s } else { '' } }   # outcome stage -> status (passed: done, not in flight)
  $fl = @($S.tasks | ForEach-Object { $b = & $stOf $_.stage; if ($b) { [pscustomobject]@{ id = $_.id; b = $b } } })
  # Delivered per day (owner 2026-11-19: one day heatmap for the merges, the old per-day chart and lead-time line dropped): a row per repo
  # (configured + any with an MR; MRs merged, its MRs, median lead time and came-back tasks in the tooltip), then tasks closed, came back and
  # runs started (a cell click filters the task list and the runs to that day)
  $mrs = @($UP.mrs | Where-Object { $_ -and $_.ref }); $dk = @($dy | ForEach-Object { "$($_.day)" }); if (-not $dk.Count) { $dk = @(6..0 | ForEach-Object { $at.AddDays(-$_).ToString('yyyy-MM-dd') }) }; $nd = $dk.Count
  # a $More row's values by its own dates (d), onto this map's days
  $align = { param($r) if (-not $r.d) { return $r }; $r2 = @{} + $r; $ix = @{}; for ($i = 0; $i -lt @($r.d).Count; $i++) { $ix["$(@($r.d)[$i])"] = $i }
    foreach ($fk in 'v', 'tips', 'so') { if ($r[$fk]) { $r2[$fk] = @(foreach ($d in $dk) { if ($ix.ContainsKey($d)) { @($r[$fk])[$ix[$d]] } else { $null } }) } }; $r2 }
  $repoOf = { param($ref) ("$ref" -split '[!#]')[0] }
  $med = { param($v) $sv = @($v | Sort-Object); if ($sv.Count) { $sv[[int][math]::Floor(($sv.Count - 1) / 2)] } else { $null } }   # lower median, as the KPIs
  $leadAll = & $med @($mrs | Where-Object { $null -ne $_.lead } | ForEach-Object { [double]$_.lead })
  $idList = { param($l) $l1 = @($l | Where-Object { $_ }); "$(@($l1 | Select-Object -First 8) -join ', ')$(if ($l1.Count -gt 8) { " +$($l1.Count - 8)" })" }
  $dayCard = if ($nd) {
    $repoRows = @(foreach ($rn in @(@(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.name)" }) + @($mrs | ForEach-Object { & $repoOf $_.ref }) | Where-Object { $_ } | Select-Object -Unique)) {
        $per = @(foreach ($d in $dk) { , @($mrs | Where-Object { (& $repoOf $_.ref) -eq $rn -and "$($_.day)" -eq $d }) }); $tot = [int](@($per | ForEach-Object { @($_).Count }) + 0 | Measure-Object -Sum).Sum
        $bkR = @($S.tasks | Where-Object { $rn -in $_.repos -and $_.backAt } | ForEach-Object { [pscustomobject]@{ d = (& $dayOf $_.backAt); id = $_.id } })
        $lr = & $med @($mrs | Where-Object { (& $repoOf $_.ref) -eq $rn -and $null -ne $_.lead } | ForEach-Object { [double]$_.lead })
        @{ n = $rn; id = $true; mk = "mrs-day-$rn"; cls = 'fh l-mr'; t = "$tot"; title = "${rn}: $tot MR(s) merged in $nd days$(if ($null -ne $lr) { " · lead time p50 $(& $n1 $lr) h (open -> merged)" })"
          v = @(for ($i = 0; $i -lt $nd; $i++) { [double]@($per[$i]).Count })
          tips = @(for ($i = 0; $i -lt $nd; $i++) { $m0 = @($per[$i]); $lt = & $med @($m0 | Where-Object { $null -ne $_.lead } | ForEach-Object { [double]$_.lead }); $b0 = @($bkR | Where-Object d -eq $dk[$i] | ForEach-Object id)
            "$($m0.Count) MR(s) merged$(if ($m0.Count) { ": $(& $idList @($m0 | ForEach-Object ref))" })$(if ($null -ne $lt) { " · lead time p50 $(& $n1 $lt) h" })$(if ($b0.Count) { " · came back: $(& $idList $b0)" })" }) } })
    $runsOf = { param($d) @($(if ($UP.dayRuns) { $UP.dayRuns[$d] }) | Where-Object { $_ } | ForEach-Object { if ("$($_.label)".Trim()) { $_.label } else { $_.run } }) }
    $fvOf = { param([string]$p) @($dk | ForEach-Object { "$p$_" }) }   # a closed / came-back cell filters the tasks, a runs cell the runs (one key each)
    $sumRow = { param([string]$n, [string]$cls, [string]$what, $lists, [string]$ft, $fv) $cs = @(foreach ($l in $lists) { @($l | Where-Object { $_ }).Count })
      @{ n = $n; mk = "$($n -replace ' ', '-')-day"; cls = $cls; ft = $ft; fv = $fv; v = @($cs | ForEach-Object { [double]$_ }); t = "$([int](@($cs) + 0 | Measure-Object -Sum).Sum)"
        tips = @(for ($i = 0; $i -lt $nd; $i++) { "$($cs[$i]) $what$(if ($cs[$i]) { ": $(& $idList @($lists[$i])) · click: list them" })" }) } }
    $sumRows = @((& $sumRow 'tasks closed' '' 'closed' @(foreach ($d in $dk) { , @($closed[$d]) }) '#oc-tasks' (& $fvOf dc)), (& $sumRow 'came back' 'fh l-act' 'came back' @(foreach ($d in $dk) { , @($back[$d]) }) '#oc-tasks' (& $fvOf db)),
      (& $sumRow 'runs started' 'fh l-fixed' 'run(s) started' @(foreach ($d in $dk) { , @(& $runsOf $d) }) '#sec-runs' (& $fvOf d)))
    # tasks by outcome (owner 2026-11-24: the per-repo bars folded in): a row per bucket, a cell = its tasks whose last change (came back:
    # that day) fell on the day; the name's line: per repo over the outcome window; right: the window's count
    $tDay = { param($t) & $dayOf $(if ($t.bucket -eq 'back' -and $t.backAt) { $t.backAt } else { $t.at }) }
    $obCls = @{ back = 'fh l-act'; wait = '' }; $repoTx = { param($t) if ($t.repos.Count) { $t.repos -join ', ' } else { 'no MR' } }
    $obRows = @(foreach ($kk in $bk.Keys) { $ts = @($S.tasks | Where-Object bucket -eq $kk); $per = @(foreach ($d in $dk) { , @($ts | Where-Object { (& $tDay $_) -eq $d }) })
        $rc = @($ts | ForEach-Object { if ($_.repos.Count) { $_.repos } else { 'no MR' } } | Group-Object | Sort-Object { -$_.Count }, Name | ForEach-Object { "$($_.Name) $($_.Count)" })
        @{ n = $bk[$kk]; sub = ($rc -join ' · '); mk = "tasks-$kk-day"; cls = $(if ($obCls.ContainsKey($kk)) { $obCls[$kk] } else { 'ws' }); t = "$($ts.Count)"; ft = '#oc-tasks'; fv = @($dk | ForEach-Object { "o$kk$_" })
          title = "$($bk[$kk]): $($ts.Count) task(s) in $(if ($S.days) { $S.days } else { '?' }) days (right column)$(if ($rc.Count) { ", per repo: $($rc -join ', ')" }) · a cell: those whose last change fell on that day"
          v = @($per | ForEach-Object { [double]@($_).Count }); tips = @($per | ForEach-Object { $l = @($_); "$($l.Count) task(s)$(if ($l.Count) { ": $(& $idList @($l | ForEach-Object { "$($_.id) ($(& $repoTx $_))" })) · click: list them" })" }) } })
    # work in flight in Delivery (owner 2026-11-25): a row per status; a past day = its tasks at that day's end (stageDays), today = now;
    # only today's cell filters the list (it holds today's statuses); a row with today only folds into the group line (Format-KitDayHeat)
    $sd = if ($S.stageDays -is [Collections.IDictionary]) { $S.stageDays } else { @{} }
    $fRows = @(foreach ($kk in $flight.Keys) { $ids = @($fl | Where-Object b -eq $kk | ForEach-Object id)
        $per = @(for ($i = 0; $i -lt $nd; $i++) { if ($i -eq $nd - 1) { , $ids } elseif ($sd.Contains($dk[$i])) { , @(@($sd[$dk[$i]]) | Where-Object { $_ -and (& $stOf "$($_.stage)") -eq $kk } | ForEach-Object id) } else { , $null } })
        @{ n = $flight[$kk][0]; mk = "flight-$kk"; cls = $flight[$kk][1]; t = "$($ids.Count)"; ft = '#oc-tasks'; fv = @(for ($i = 0; $i -lt $nd; $i++) { if ($i -eq $nd - 1) { "st:$kk" } else { '' } }); title = "$($flight[$kk][0]): $($ids.Count) task(s) now (right column) · a past day: its tasks at the day's end"
          v = @(for ($i = 0; $i -lt $nd; $i++) { if ($null -eq $per[$i]) { $null } else { [double]@($per[$i]).Count } })
          tips = @(for ($i = 0; $i -lt $nd; $i++) { $l = @($per[$i] | Where-Object { $_ }); if ($null -eq $per[$i]) { 'no status record' } elseif ($i -eq $nd - 1) { "$($l.Count) task(s) now$(if ($l.Count) { ": $(& $idList $l) · click: list them" })" } else { "$($l.Count) task(s) at the day's end$(if ($l.Count) { ": $(& $idList $l)" })" } }) } })
    # a group line: its 2-4 most useful facts over the map's days (owner 2026-11-25)
    $mrTx = @($repoRows | Where-Object { [int]$_.t } | Sort-Object { -[int]$_.t }, n | ForEach-Object { "$($_.n) $($_.t)" })
    $ckLine = if (@($Clock | Where-Object { $_ }).Count) { Get-KitTaskClockLine $Clock }
    $dlEx = "$($mrs.Count) MRs merged$(if ($mrTx.Count) { " ($($mrTx -join ' · '))" }) · $($sumRows[0].t) tasks closed · $($sumRows[1].t) came back$(if ($ckLine) { " · $ckLine" })"
    $obN = { param([string[]]$ks) @($S.tasks | Where-Object { $_.bucket -in $ks }).Count }
    $obEx = "passed $(& $obN 'r0', 'r1', 'r2', 'r3', 'rna') · came back $(& $obN 'back')$(if (& $obN 'back') { " ($wySplit)" }) · not tested yet $(& $obN 'wait')$(if ($null -ne $S.kpi.first) { " · QA first pass $($S.kpi.first)%" })"
    # test checks join the outcome group (owner 2026-11-26): their header's line after the outcomes', their rows under it
    $qaH = @($More | Where-Object { $_ -and $_.g -eq 'qa' -and $_.hd })[0]; $More = @($More | Where-Object { $_ -and -not ($_.g -eq 'qa' -and $_.hd) })
    $grp = { param([string]$g, [string]$hd, $cn, [string]$ex = '') @{ hd = $hd; g = $g; cn = $cn; ex = $ex } }
    $all = @(& $grp 'mr' 'Delivery' '' (& $e $dlEx)) + $repoRows + $sumRows + $fRows + @(& $grp 'out' $(if ($qaH) { 'Outcomes and test checks' } else { 'Tasks by outcome' }) @($S.tasks).Count "$(& $e $obEx)$(if ($qaH) { " &#183; $(& $e "$($qaH.cn) checks") $($qaH.ex)" })") + $obRows + @($More | Where-Object { $_ } | ForEach-Object { & $align $_ })
    & $fold 'dl-days' 'Per day' "$($mrs.Count) MRs$(if ($null -ne $leadAll) { " · lead time p50 $(& $n1 $leadAll) h" })" "$(Format-KitDayHeat $all $dk 'series · day')$(Format-KitLegend "outlined = today · $(Format-KitSplitLegend)" "a cell = that day's value, shaded by the row's peak · the right column: 7 days (sum, or as the row's tooltip says) · a group header folds its rows · a click on a task row's cell or runs started filters the tasks and runs · est. cost and tokens: a tile per type, each shaded by its own 7-day peak; a narrow cell shows the total over a bar · hover a cell for every value and its cost")$(if ($noMr) { "<p class=m>$noMr task(s) without an MR (outcome rows: no MR)</p>" })" -Open -tag h4 -cls 'sub st uc dlr' }
  # the tasks behind a click (a day: closed, came back or its outcome that day; a status); hidden until a filter is set; a task with a
  # clock: its clock on the row (task-clock.ps1 Format-KitTaskClockCell), a clocked task with no outcome record lists under in progress
  $ck = @{}; foreach ($c in @($Clock | Where-Object { $_ })) { $ck["$($c.task)"] = $c }
  $ckOf = { param($id) if ($ck.ContainsKey("$id")) { $c0 = $ck["$id"]; $ck.Remove("$id"); Format-KitTaskClockCell $c0 } }
  $rows = @($S.tasks | ForEach-Object { $t = $_
      $fk = @(@(if ($c = & $dayOf $t.closedAt) { "dc$c" }) + @(if ($b = & $dayOf $t.backAt) { "db$b" }) + @(if ($od = & $dayOf $(if ($t.bucket -eq 'back' -and $t.backAt) { $t.backAt } else { $t.at })) { "o$($t.bucket)$od" }) + @(if ($s0 = & $stOf $t.stage) { "st:$s0" }) | Select-Object -Unique) -join ' '
      if ($fk) { "<li data-fk='$(& $e $fk)'>$(& $taskA $t.id)<span class='chip ob-$($tone[$t.bucket])'>$(& $e $bk[$t.bucket])</span><span class=m>$(& $e "$($t.repos -join ', ')$(if ($t.back) { " · came back: $(if ($t.why -eq 'qa') { "own checks$(if ($t.backChecks) { " $($t.backChecks)" }) failed" } elseif ($t.why) { 'reopened' } else { 'reason not recorded' })" })")</span>$(& $ckOf $t.id)</li>" } })
  $rows += @(foreach ($c in @($ck.Values | Where-Object { -not $_.done } | Sort-Object { -$_.min })) { "<li data-fk='st:open'>$(& $taskA $c.task)$(Format-KitTaskClockCell $c)</li>" })
  $list = "<div id=oc-tasks class='ftl uc'><p class=fclr hidden>Tasks: <b></b> <button type=button>Clear</button></p><ul class=otl>$($rows -join '')</ul></div>"
  "$tiles$dayCard$Blocks$list"
}
# bucket order = the bar's segment order: passed QA by fix rounds before it (n/a: no wave report names the task), came back, not tested yet
$script:KitOutcomeBuckets = [ordered]@{ r0 = 'passed, 0 fix rounds'; r1 = 'passed, 1 round'; r2 = 'passed, 2 rounds'; r3 = 'passed, 3+ rounds'; rna = 'passed, rounds not recorded'; back = 'came back'; wait = 'not tested yet' }
function Get-KitOutcomeBucket($R) {
  if ($R.cameBack) { return 'back' }; if ("$($R.stage)" -ne 'passed') { return 'wait' }; if (-not @($R.agents | Where-Object { $_ }).Count) { return 'rna' }
  $n = [math]::Max(0, [int]$R.localRounds - 1) + [int]$R.reviewFix; if ($n -ge 3) { 'r3' } else { "r$n" }
}
function Get-KitOutcomeLines([int]$Days = (Get-KitParam 'outcomes.days')) {
  $s = Get-KitOutcomeStats $Days; if (-not $s.n) { return }
  $cut = { param($x, [int]$m = 120) $x = "$x" -replace '\s+', ' '; if ($x.Length -gt $m) { $x.Substring(0, $m - 3) + '...' } else { $x } }
  "$($s.n) task(s) in $Days d: QA first pass $($s.firstPass)/$($s.qaN), came back $($s.cameBack) (own QA checks failed, or reopened)$(if ($null -ne $s.p50Promoted) { ", p50 $($s.p50Promoted) h to promoted" })"
  foreach ($a in @($s.areas | Where-Object score | Select-Object -First 5)) { "area $($a.area): $($a.n) task(s), first pass $($a.firstPass)/$($a.qaN), came back $($a.cameBack), fix rounds $($a.rounds)" }
  foreach ($a in @($s.agents | Select-Object -First 5)) { "agent $($a.agent): $($a.rounds) fix round(s) over $($a.tasks) task(s)" }
  foreach ($g in @($s.causes | Select-Object -First 5)) { "cause $($g.n)x: $(& $cut $g.text)$(if ($g.refs) { " ($(@($g.refs | Select-Object -First 3) -join ', '))" })" }
}

# ---- patterns: one topic, the same owner choice 3+ times, no contrary answer -> a standing rule proposal
$script:KitRuleNeverGates = @('deploy', 'rollback', 'secret', 'data', 'close', 'merge', 'premerge')
# words a question never gets a standing rule for (the kit's hard rule) + decide.neverAuto (an org's regex words); over-blocking costs one ask
$script:KitRuleNeverRx = '(?i)\b(' + ((@('prod\w*', 'deploy\w*', 'release', 'rollback', 'secret\w*', 'credential\w*', 'customer\w*', 'client[- ]facing', '\w+[- ](visible|facing)', 'tenant\w*', 'migrat\w*', 'backfill\w*', 'delete\w*', 'drop', 'truncate', 'purge', 'data') + @(Get-KitSetting 'decide.neverAuto' @() | Where-Object { $_ -and $(try { $null = [regex]::new($_); $true } catch { Write-Warning "decide.neverAuto '$_' is no regex: skipped"; $false }) })) -join '|') + ')\b'
function Get-KitTopicWords([string]$Question) { Get-KitWordSet ("$Question" -replace '\([^)]*\)', ' ' -replace '\b[A-Za-z]+-\d+[a-z]?\b', ' ' -replace '\b[0-9a-z_]*\d[0-9a-z_]*\b', ' ') }
# choice words keep short ones (no, keep, all): polarity matters
function Get-KitChoiceWords([string]$Answer) {
  $s = "$Answer".ToLower() -replace '\(recommended\)', ' ' -replace '\((owner|by|via|standing)[^)]*\)', ' ' -replace '^\s*[a-z0-9]{1,2}\s*[:.)]\s+', '' -replace '\b(?:[de]-\d{14}\S*|(?:dec|envfix|debate)-[a-z0-9]+(?:-[a-z0-9]+)*)', ' ' -replace "\b(don|doesn|didn|won|can|shouldn|wouldn|isn|aren|couldn)['’]?t\b|\bcannot\b", ' not '
  $h = [Collections.Generic.HashSet[string]]::new(); foreach ($m in [regex]::Matches($s, '[a-z][a-z0-9-]+')) { if ($m.Value -notin 'the', 'an', 'of', 'to', 'on', 'in', 'for', 'and', 'or', 'as', 'is', 'it', 'be', 'by', 'at', 'its') { [void]$h.Add($m.Value) } }; , $h
}
function ConvertTo-KitWordSet($Words) { $h = [Collections.Generic.HashSet[string]]::new(); foreach ($x in @($Words)) { if ($x) { [void]$h.Add("$x") } }; , $h }
# one choice: the shorter answer's words sit in the longer one (an owner often adds a reason) and both say no, or neither does
function Test-KitSameChoice($A, $B, [double]$Min = (Get-KitParam 'decide.sameChoice')) {
  if (-not $A.Count -or -not $B.Count) { return $false }
  $neg = { param($s) [bool]@($s | Where-Object { $_ -in 'no', 'not', 'never', 'none', 'without', 'dont', 'cant', 'wont', 'nothing', 'neither', 'skip' }).Count }
  if ((& $neg $A) -ne (& $neg $B)) { return $false }
  $in = @($A | Where-Object { $B.Contains($_) }).Count; $in / [math]::Min($A.Count, $B.Count) -ge $Min
}
function Test-KitRuleSensitive([string]$Gate, [string]$Question) { $Gate -in $script:KitRuleNeverGates -or $Question -match $script:KitRuleNeverRx }
function Get-KitDecisionPatterns([int]$Min = (Get-KitParam 'decide.patternMin'), [double]$Topic = (Get-KitParam 'decide.topicSimilarity'), [double]$Same = (Get-KitParam 'decide.sameChoice')) {
  $groups = [Collections.Generic.List[object]]::new()
  foreach ($d in @(Get-KitOwnerAnswers | Sort-Object { [datetime]$_.at })) {
    $w = Get-KitTopicWords "$(if ($d.ask) { $d.ask } else { $d.question })"; if ($w.Count -lt 2) { continue }   # ask: the bare question (no plain-words context)
    $hit = $null; foreach ($g in $groups) { if ($g.gate -eq "$($d.gate)" -and @($g.words | Where-Object { (Get-KitOverlap $_ $w) -ge $Topic }).Count) { $hit = $g; break } }
    if ($hit) { $hit.items.Add($d); $hit.words.Add($w) } else { $groups.Add([pscustomobject]@{ gate = "$($d.gate)"; items = [Collections.Generic.List[object]]@(, $d); words = [Collections.Generic.List[object]]@(, $w) }) }
  }
  foreach ($g in $groups) {
    if ($g.items.Count -lt $Min) { continue }
    $ref = $g.items[$g.items.Count - 1]; $rw = Get-KitChoiceWords $ref.answer
    $agree = @($g.items | Where-Object { Test-KitSameChoice (Get-KitChoiceWords $_.answer) $rw $Same })
    if ($agree.Count -lt $Min -or $agree.Count -ne $g.items.Count) { continue }   # one contrary answer: no pattern
    $rq = "$(if ($ref.ask) { $ref.ask } else { $ref.question })"
    [pscustomobject]@{ gate = $g.gate; question = $rq; answer = "$($ref.answer)"; evidence = @($g.items.id); words = @((Get-KitTopicWords $rq) | ForEach-Object { $_ })
      auto = -not @($g.items | Where-Object { Test-KitRuleSensitive "$($_.gate)" "$(if ($_.ask) { $_.ask } else { $_.question })" }).Count }
  }
}

# ---- rules: proposals, the owner's approval (one decide ask), rules/standing-rules.local.md, auto-answers
function Read-KitStandingRules { @((Read-KitState (Get-KitPath standing-rules)).rules | Where-Object { $_ }) }
function Save-KitStandingRules($Rules) {
  Write-KitState (Get-KitPath standing-rules -Create) ([ordered]@{ rules = @($Rules) }) 1
  $md = Join-Path $KitConf.Kit 'rules/standing-rules.local.md'; $ok = @($Rules | Where-Object status -eq 'approved')
  if (-not $ok.Count) { Remove-Item -LiteralPath $md -ErrorAction SilentlyContinue; return }
  $null = New-Item -ItemType Directory -Force (Split-Path $md)
  $lines = @('# Standing rules (owner-approved; written by bossy.ps1 decide rules, never by hand)', 'A question that matches one is answered by it: say "standing rule <id>". `decide ask` answers matching asks itself, except deploy, data, prod and customer-visible ones (marked guidance). Revoke: `bossy.ps1 decide rules -Revoke <id>`.', '') +
    @($ok | ForEach-Object { "- $($_.id): asked `"$($_.question)`" -> `"$($_.answer)`"$(if (-not $_.auto) { ' (guidance: never auto-answered)' }) (evidence $(@($_.evidence) -join ', '); approved $("$($_.approvedAt)".Substring(0, [math]::Min(10, "$($_.approvedAt)".Length))) by $($_.approvedBy))" })
  [IO.File]::WriteAllText($md, (($lines -join "`n") + "`n"))
}
function Find-KitStandingRule($Rules, [string]$Gate, $Words, [double]$Min = (Get-KitParam 'decide.ruleMatch')) {
  @($Rules | Where-Object { "$($_.gate)" -eq $Gate } | ForEach-Object { $rw = ConvertTo-KitWordSet $_.words; [pscustomobject]@{ r = $_; s = (Get-KitOverlap $rw $Words) } } | Where-Object { $_.s -ge $Min } | Sort-Object { -$_.s } | Select-Object -First 1).r
}
# the answer picks: "A" / "all" = every rule of the ask; else the sr- ids it names; the rest of the ask -> rejected
function Set-KitStandingRuleAnswer([string]$AskId, [string]$Answer, [string]$By) {
  $file = Get-KitPath standing-rules -Create
  Invoke-KitLocked $file {
    $rules = @(Read-KitStandingRules); $mine = @($rules | Where-Object { $_.askId -eq $AskId -and $_.status -eq 'proposed' }); if (-not $mine.Count) { return }
    $named = @($mine | Where-Object { "$Answer" -match "(?<![\w-])$([regex]::Escape($_.id))(?![\w-])" } | ForEach-Object id)   # a proposed rule's own id (old sr-<hex>, new rule-<words>); prose 'rule-based' is none
    if ("$Answer" -match '(?i)\b(except|but not|excluding)\b') { foreach ($r in $mine) { $r.askId = '' }; Save-KitStandingRules $rules; return }   # unclear pick: the next prep asks again
    $all = -not $named.Count -and "$Answer" -match '(?i)^\s*(a\s*([:.)]|$)|approve all\b|all\b|yes\b)'
    foreach ($r in $mine) { if ($all -or $r.id -in $named) { $r.status = 'approved'; $r.approvedAt = (Get-KitStamp); $r.approvedBy = $By } else { $r.status = 'rejected' } }
    Save-KitStandingRules $rules
  }
}
# a pending ask matching an approved, auto rule -> answered by it (decide ask); $null = ask the owner
function Get-KitStandingRuleAnswer($Ask) {
  if ($Ask.kind -ne 'decision' -or $Ask.item -eq 'standing-rules' -or (Test-KitRuleSensitive "$($Ask.gate)" "$($Ask.question)")) { return }
  $r = Find-KitStandingRule @(Read-KitStandingRules | Where-Object { $_.status -eq 'approved' -and $_.auto }) "$($Ask.gate)" (Get-KitTopicWords $Ask.question); if (-not $r) { return }
  $rw = Get-KitChoiceWords $r.answer; $opts = @($Ask.options | Where-Object { $_ })
  if (-not $opts.Count) { return "$($r.answer) (standing rule $($r.id))", $r.id }
  # options that make the rule's choice; two such: the closer one, a tie asks the owner
  $fit = @($opts | ForEach-Object { $ow = Get-KitChoiceWords "$($_.label)"; [pscustomobject]@{ o = $_; ok = (Test-KitSameChoice $ow $rw); s = (Get-KitOverlap $ow $rw) } } | Where-Object ok | Sort-Object { -$_.s })
  if (-not ($fit.Count -and ($fit.Count -eq 1 -or $fit[0].s -gt $fit[1].s))) { return }
  $file = Get-KitPath standing-rules; Invoke-KitLocked $file { $rules = @(Read-KitStandingRules); foreach ($x in @($rules | Where-Object id -eq $r.id)) { $x.used = [int]$x.used + 1 }; Save-KitStandingRules $rules }
  "$($fit[0].o.key): $($fit[0].o.label) (standing rule $($r.id))", $r.id
}
function Invoke-KitStandingRules([switch]$Propose, [string]$Approve, [string]$Revoke, [string]$By = 'owner', [switch]$Json) {
  $file = Get-KitPath standing-rules -Create
  if ($Revoke -or $Approve) {
    $ids = @(Split-KitList @($Revoke, $Approve | Where-Object { $_ }))
    $out = Invoke-KitLocked $file {
      $rules = @(Read-KitStandingRules); $hit = @($rules | Where-Object { $_.id -in $ids -or ($Approve -eq 'all' -and $_.status -eq 'proposed') })
      foreach ($r in $hit) { if ($Revoke) { $r.status = 'revoked'; $r.revokedAt = (Get-KitStamp) } else { $r.status = 'approved'; $r.approvedAt = (Get-KitStamp); $r.approvedBy = $By } }   # read back as hashtables (Read-KitState): keys, not Add-Member
      if ($hit.Count) { Save-KitStandingRules $rules }; $hit
    }
    if (-not @($out).Count) { "no standing rule $($ids -join ', ')"; exit 1 }
    @($out | ForEach-Object { "$($_.status.ToUpper()) $($_.id): asked `"$($_.question)`" -> `"$($_.answer)`"" }); return
  }
  if ($Propose) {
    $new = Invoke-KitLocked $file {
      $rules = [Collections.Generic.List[object]]@(Read-KitStandingRules); $added = @()
      foreach ($p in @(Get-KitDecisionPatterns)) {
        $have = Find-KitStandingRule $rules $p.gate (ConvertTo-KitWordSet $p.words)
        if ($have) { $have.evidence = @(@($have.evidence) + @($p.evidence) | Select-Object -Unique); continue }   # rejected / revoked stay so: the owner re-opens with -Approve
        $r = [pscustomobject][ordered]@{ id = (New-KitName rule "$($p.question)" -Cap 20); status = 'proposed'; gate = $p.gate; question = $p.question; answer = $p.answer
          evidence = @($p.evidence); words = @($p.words); auto = $p.auto; proposedAt = (Get-KitStamp); askId = '' }
        $rules.Add($r); $added += $r
      }
      Save-KitStandingRules @($rules); $added
    }
    $new = @($new | Where-Object { $_ })
    $open = @(Read-KitStandingRules | Where-Object { $_.status -eq 'proposed' -and -not $_.askId })
    if ($open.Count -and -not @(Read-KitJsonFiles (Get-KitPath decisions) | Where-Object { $_.item -eq 'standing-rules' -and $_.status -eq 'pending' }).Count) {
      $each = @($open | ForEach-Object { $_.id + ': asked "' + $_.question + '" -> "' + $_.answer + '"' + $(if (-not $_.auto) { ' [guidance only]' }) + ' (evidence ' + (@($_.evidence) -join ', ') + ')' })
      $q = 'Standing rules from repeated answers (approve once; decide ask then answers matching questions, logged, revocable): ' + ($each -join ' · ')
      $ask = @(Invoke-Decide ask -Run tidy -Agent coordinator -Item standing-rules -Context 'you answered these questions the same way 3+ times' -Question $q -Options 'A: approve all — each answers its future matches', 'B: approve none — keep asking', 'C: approve only the sr- ids I name — the rest stay asked' -Recommend A -NoPublish)
      $askId = if ("$($ask -join ' ')" -match 'DECISION (\S+)') { $Matches[1] }
      if ($askId) { Invoke-KitLocked $file { $rules = @(Read-KitStandingRules); foreach ($r in @($rules | Where-Object { $_.id -in @($open.id) })) { $r.askId = $askId }; Save-KitStandingRules $rules } }
      "PROPOSED $($open.Count) standing rule(s) ($(@($open.id) -join ', ')): ask $askId"
    } elseif ($new.Count) { "PROPOSED $($new.Count) standing rule(s): they join the next ask (one is pending)" }
    return
  }
  $all = @(Read-KitStandingRules); if ($Json) { ConvertTo-Json @($all) -Depth 5; return }
  if (-not $all.Count) { 'no standing rules (decide rules -Propose finds patterns)'; return }
  $all | ForEach-Object { "$($_.status.ToUpper()) $($_.id)$(if ($_.gate) { " [$($_.gate)]" }): asked `"$($_.question)`" -> `"$($_.answer)`"$(if (-not $_.auto) { ' (guidance)' }) | evidence $(@($_.evidence) -join ', ')$(if ($_.used) { " | used $($_.used)x" })" }
}
# ---- retro due: one rule for health, supervise and report
function Get-KitRetroSince { $m = Get-KitPath last-retro; if (Test-Path $m) { [datetime](Get-Content $m -Raw).Trim() } else { [datetime]::MinValue } }
# signals since the last retro after a finished run, or retro.dueSignals of them without one; guard blocks only shown (retro 1549:
# blocks alone re-raised the ACT every ~40 min with 0 runs finished)
function Get-KitRetroDue([switch]$RunFinished) {
  $since = Get-KitRetroSince
  $n = @(Get-Content (Get-KitPath signals) -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '"kind":"retired"' -and $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Read-KitLog guard $since | Where-Object event -eq 'deny').Count
  if ($n -ge [int](Get-KitParam 'retro.dueSignals') -or ($RunFinished -and $n)) { "$n signal(s) + $g guard block(s) since the last retro" }
}

# ---- tidy: /tidy script step (digest + upkeep) and retro stamp
function Invoke-Tidy {
param([Parameter(Position = 0)][string]$Action, [string]$At, [switch]$DryRun, [switch]$Json)
if ($Action -eq 'done') {   # signals up to the prep time count as reviewed
  $t = try { [datetime]$At } catch { $null }; if (-not $t) { 'usage: tidy done -At <time>'; exit 2 }
  $m = Get-KitPath last-retro -Create
  if (-not $DryRun) { Set-Content $m (Get-KitStamp stored $t); Remove-Item "$m.start" -ErrorAction SilentlyContinue }   # .start: the old workflow's marker
  "last retro = $($t.ToString('s'))"; return
}
if ($Action -ne 'prep') { 'usage: tidy prep [-DryRun] [-Json] | tidy done -At <time> [-DryRun]'; exit 2 }
$t0 = Get-Date; $since = Get-KitRetroSince; $winDays = [double](Get-KitParam 'tidy.windowDays'); $from = if ($since -gt $t0.AddDays(-$winDays)) { $since } else { $t0.AddDays(-$winDays) }
$cut = { param($s, [int]$n = 140) $s = "$s" -replace '\s+', ' '; if ($s.Length -gt $n) { $s.Substring(0, $n - 3) + '...' } else { $s } }
$steps = [Collections.Generic.List[object]]::new()
$run = { param([string]$Name, [scriptblock]$Body) $s0 = Get-Date; $st = 'ok'
  $o = @(try { & $Body *>&1 | ForEach-Object { if ($_.what) { "$($_.level) $($_.what)" } else { "$_" } } | Where-Object { "$_".Trim() } } catch { $st = 'failed'; "$($_.Exception.Message)" })
  if ($o.Count -and "$($o[0])" -like 'skip:*') { $st = 'skip' }
  $steps.Add([pscustomobject]@{ step = $Name; state = $st; sec = [math]::Round(((Get-Date) - $s0).TotalSeconds, 1); out = @($o | Select-Object -Last 12) }) }
$py = { param([string[]]$A) $o = @(& (Get-Python) -X utf8 $KitCmd.kitbag @A 2>&1 | ForEach-Object { "$_" }); if ($LASTEXITCODE) { throw "kitbag $($A[0..1] -join ' ') rc $LASTEXITCODE`: $($o | Select-Object -Last 1)" }; $o }
$busy = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and $_.beat -and ($t0 - [datetime]$_.beat).TotalMinutes -lt [double](Get-KitParam 'tidy.busyBeatMinutes') })
$idle = if ($busy) { "skip: $($busy.Count) live board agent(s) ($(@($busy.agent | Select-Object -First 4) -join ', ')): waits for an idle kit" }
$opt = { param([string]$Fn, [scriptblock]$Call) $c = Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue; if ($c) { & $Call $c } else { "skip: $Fn not in this kit yet" } }   # function from another kit change

# upkeep: a failed step is listed, the rest still run
& $run 'param learn' { if ($DryRun) { 'skip: dry run' } else { & $opt Invoke-ParamLearn { param($c) & $c } } }
& $run 'cleanup' { Invoke-Cleanup -DryRun:$DryRun | Select-Object -First 6 }
& $run 'worktree prune' { $ga = @('-C', $KitConf.Kit, 'worktree', 'prune', '-v') + @(if ($DryRun) { '-n' }); git @ga 2>&1; if (-not $?) { throw 'git worktree prune failed' } }
& $run 'outcomes' { if ($DryRun) { 'skip: dry run' } else { & $opt Update-KitOutcomes { param($c) "$(& $c) new row(s)" } } }
& $run 'standing rules' { if ($DryRun) { 'skip: dry run' } else { & $opt Invoke-KitStandingRules { param($c) & $c -Propose } } }
& $run 'lint' { $l = @(& (Get-Python) -X utf8 $KitCmd.kitbag lint --warn --no-flow 2>&1 | ForEach-Object { "$_" }); @($l | Where-Object { $_ -like 'kitbag lint:*' }) + @($l | Where-Object { $_ -notlike 'kitbag lint:*' } | Select-Object -First 10) }   # count first: digest keeps the head

$pn = @(try { & $py @('parity', 'next', '--n', '3') | Where-Object { $_ -notlike 'parity next:*' } } catch { })   # parity proposals (owner 2026-11-24): never judge work
$sig = @(Get-Content (Get-KitPath signals) -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
$new = @($sig | Where-Object { $_.kind -ne 'retired' -and [datetime]$_.at -gt $since })
$lessons = @(foreach ($f in (Join-Path $KitConf.Kit 'LESSONS.md'), (Join-Path $KitConf.Kit 'LESSONS.local.md')) { $sk = ''; foreach ($l in (Read-KitLessonLines $f)) { if ($l -match '^## (.+)$') { $sk = $Matches[1].Trim() } elseif ($l -match '^- (.+)$' -and $sk) { [pscustomobject]@{ skill = $sk; text = $Matches[1] } } } })
$groups = @(Get-KitSignalGroups $new $lessons | Sort-Object n -Descending)
$retired = @($sig | Where-Object kind -eq 'retired' | ForEach-Object { [pscustomobject]@{ skill = $_.skill; text = $_.text; words = (Get-KitWordSet $_.text) } })
$regSim = [double](Get-KitParam 'tidy.regressionSimilarity'); $back = @(foreach ($s in $new) { $w = Get-KitWordSet $s.text; $r = @($retired | Where-Object { $_.skill -eq $s.skill -and (Get-KitOverlap $_.words $w) -ge $regSim } | Select-Object -First 1); if ($r) { "$($s.skill): $(& $cut $s.text 100) <- retired: $(& $cut $r[0].text 100)" } })
$log = @(Read-KitLog -Since $from | Where-Object { [datetime]$_.at -gt $since })
$by = { param($S, $E) @($log | Where-Object { $_.stream -eq $S -and $_.event -match $E }) }; $deny = & $by guard '^deny$'
$errs = @($log | Where-Object { $_.stream -eq 'calls' -and ($_.event -eq 'error' -or "$($_.rc)" -eq '2' -or ($_.event -eq 'end' -and $_.error)) })   # end + error: Stop-KitVerb
$bld = & $by builds '^end$'
$envF = & $by env 'fail'
$runs = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { $_.at -and [datetime]$_.at -gt $since } | Sort-Object { [datetime]$_.at })
$qa = @(Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)
$lp = if ("$(@($steps | Where-Object step -eq 'lint').out)" -match '(\d+) problem') { [int]$Matches[1] } else { 0 }
$oc = @(if (Get-Command Get-KitOutcomeLines -ErrorAction SilentlyContinue) { Get-KitOutcomeLines })
$srs = @(if (Get-Command Read-KitStandingRules -ErrorAction SilentlyContinue) { if ($DryRun) { Get-KitDecisionPatterns | ForEach-Object { "candidate: asked `"$(& $cut $_.question)`" -> `"$(& $cut $_.answer 90)`" ($(@($_.evidence) -join ', '))" } } else { Read-KitStandingRules | Where-Object status -eq 'proposed' | ForEach-Object { "$($_.id) (ask $($_.askId)): asked `"$(& $cut $_.question)`" -> `"$(& $cut $_.answer 90)`"" } } })
$work = $new.Count + $deny.Count + $errs.Count + $back.Count + $lp + @($steps | Where-Object state -eq 'failed').Count + @($oc | Where-Object { $_ -like 'cause *' }).Count + $srs.Count   # failed steps, lint, repeat causes, rule proposals: the judge sees them
$min = [double](Get-KitParam 'tidy.judgeMinutes')
$hit = { param($g) "$(& $cut $g.text)$(if ($g.refs) { " refs $($g.refs -join ',')" })$(if ($g.lesson) { " -> lesson ($($g.score)): $(& $cut $g.lesson 90)" })" }
$top = { param($Items, [scriptblock]$Key, [int]$Max = 10) @($Items | Group-Object $Key | Sort-Object Count -Descending | Select-Object -First $Max | ForEach-Object { "$($_.Count)x $($_.Name)" }) }
$d = [Collections.Generic.List[string]]::new(); $part = { param($T, $Lines) if ($Lines) { $d.Add(''); $d.Add("## $T"); foreach ($x in $Lines) { $d.Add("- $x") } } }
$d.Add("# tidy digest $($t0.ToString('yyyy-MM-dd HH:mm'))"); $d.Add("Since the last retro ($(if ($since -eq [datetime]::MinValue) { "never; logs from $($from.ToString('yyyy-MM-dd'))" } else { $since.ToString('yyyy-MM-dd HH:mm') })): $($new.Count) signal(s), $($deny.Count) guard block(s), $($errs.Count) script error(s), $($runs.Count) run(s), $($qa.Count) QA run(s).")
& $part 'Signal groups (2+ = lesson candidate; a matched lesson = bump it)' @($groups | Where-Object n -ge 2 | Select-Object -First 25 | ForEach-Object { "$($_.n)x $($_.skill) [$($_.kinds)] $(& $hit $_)" })
& $part 'Single signals' @($groups | Where-Object n -lt 2 | Select-Object -First 30 | ForEach-Object { "$($_.skill) [$($_.kinds)] $(& $hit $_)" })
& $part 'Retired lessons seen again (regression candidates)' @($back | Select-Object -First 10)
& $part 'Outcomes, 30 days (worst areas, most fix rounds, repeat causes: lesson or rule candidates)' $oc
& $part 'Standing rules proposed (owner answers repeated 3+ times; the owner approves in one decide ask)' $srs
& $part 'Parity next (proposals; a parity kitty closes them: supervise PARITY)' $pn
& $part 'Guard blocks' (& $top $deny { & $cut $_.why 110 })
& $part 'Script errors (crash or usage)' (& $top $errs { "$($_.script) $($_.verb): $(if ($_.error) { & $cut $_.error 90 } else { "exit $($_.rc), message on stderr only (not a crash)" })" })
& $part 'Builds per kind (gate)' @($bld | Group-Object kind | ForEach-Object { $q = @($_.Group.sec | ForEach-Object { [double]$_ } | Sort-Object); "$($_.Name): $($_.Count), $(@($_.Group | Where-Object { "$($_.code)" -ne '0' }).Count) failed, p50 $($q[[int][math]::Floor(($q.Count - 1) / 2)]) s, max $($q[-1]) s, wait max $(($_.Group.waitSec | Measure-Object -Maximum).Maximum) s, peak max $(($_.Group.peakGB | Measure-Object -Maximum).Maximum) GB" })
& $part 'Local env failures' (& $top $envF { "$($_.event) $($_.env) $($_.service)".Trim() } 8)
& $part 'Runs since' @(@($runs | Select-Object -Last 15 | ForEach-Object { "$($_.run) ($(Split-Path "$($_.script)" -Leaf)) spent $([int]$_.spent) of $([int]$_.cap)" }) + @($qa | Select-Object -Last 10 | ForEach-Object { "QA $($_.Name)$(Get-KitQaRunGap $_.FullName)" }))
& $part 'Upkeep (no LLM)' @(@($steps | ForEach-Object { "$($_.step): $($_.state) ($($_.sec) s)$(if ($_.out) { ': ' + (& $cut ($_.out -join ' | ') 400) })" }) + @(Invoke-KitHooks Get-KitHealthLinesAudit))
$file = Join-Path (Get-KitPath retros -Create) "$(New-KitName digest '' (Get-KitPath retros)).md"   # digest, a tie digest-2; its time is the at field
[IO.File]::WriteAllText($file, (($d -join "`n") + "`n"))
$stamped = -not $work -and -not $DryRun -and -not @($steps | Where-Object state -eq 'failed').Count
if ($stamped) { $null = Invoke-Tidy done -At (Get-KitStamp stored $t0) }   # nothing to judge
$o = [ordered]@{ digest = $file; at = (Get-KitStamp stored $t0); work = $work; groups = @($groups | Where-Object n -ge 2).Count; minutes = $min; stamped = $stamped; parity = $pn; sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); steps = @($steps | ForEach-Object { "$($_.step) $($_.state) $($_.sec)s" }) }
if ($Json) { $o | ConvertTo-Json -Compress; return }
"DIGEST $file"; "AT $($o.at)"; "WORK $work ($($o.groups) group(s) of 2+)$(if ($stamped) { '; nothing to judge: last retro stamped' })"; "MINUTES $min"; $o.steps | ForEach-Object { "  $_" }
}
# signals of one skill joined when any two overlap >= $Min; each group with its closest lesson (bump candidate)
function Get-KitSignalGroups($Signals, $Lessons, [double]$Min = (Get-KitParam 'tidy.groupSimilarity')) {
  $groups = [Collections.Generic.List[object]]::new()
  foreach ($s in $Signals) {
    $w = Get-KitWordSet $s.text; $hit = $null
    foreach ($g in $groups) { if ($g.skill -eq $s.skill -and @($g.words | Where-Object { (Get-KitOverlap $_ $w) -ge $Min }).Count) { $hit = $g; break } }
    if ($hit) { $hit.items.Add($s); $hit.words.Add($w) } else { $groups.Add([pscustomobject]@{ skill = $s.skill; items = [Collections.Generic.List[object]]@($s); words = [Collections.Generic.List[object]]@(, $w) }) }
  }
  foreach ($g in $groups) {
    $best = $null; $bs = 0
    foreach ($l in @($Lessons | Where-Object skill -eq $g.skill)) { $lw = Get-KitWordSet $l.text; $sc = @($g.words | ForEach-Object { Get-KitOverlap $_ $lw } | Measure-Object -Maximum).Maximum; if ($sc -gt $bs) { $bs = $sc; $best = $l } }
    [pscustomobject]@{ skill = $g.skill; n = $g.items.Count; kinds = @($g.items.kind | Select-Object -Unique) -join ','; text = $g.items[0].text; refs = @($g.items.ref | Where-Object { $_ } | Select-Object -Unique); lesson = $(if ($bs -ge $Min) { $best.text }); score = [math]::Round($bs, 2) }
  }
}
function Get-OrphanQaItems([int]$Hours = 48) {
  $live = @(Read-KitJsonFiles (Get-KitPath launches -Create) |
      Where-Object { -not $_.completed -and (Test-KitHolder $_) -ne $false } | ForEach-Object { [string]$(if ($_.runDir) { $_.runDir } else { $_.args.runDir }) } | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf })
  foreach ($d in Get-ChildItem -LiteralPath (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) -and $_.Name -notin $live }) {
    $codes = @(); $fails = @()
    foreach ($it in @(try { (Read-KitText (Join-Path $d.FullName 'run.json') | ConvertFrom-Json).items } catch { })) {
      $c = [string]$it.code; $id = Join-Path $d.FullName $c
      if (-not $c -or -not (Test-Path (Join-Path $id 'results.json')) -or (Test-Path (Join-Path $id 'finalize.json')) -or (Test-Path (Join-Path $id 'held.json'))) { continue }
      $codes += $c
      $res = try { Get-Content (Join-Path $id 'results.json') -Raw | ConvertFrom-Json } catch { $null }
      if (@($res.checks | Where-Object { $_.result -eq 'FAIL' -and -not $_.verify }).Count) { $fails += $c }
    }
    if ($codes.Count) { [pscustomobject]@{ run = $d.Name; dir = $d.FullName; codes = $codes; fails = $fails } }
  }
}
# ---- collisions: a step result that reports a collision / halt, open until a later run delivers its area (supervise)
# 'another agent' alone appears in normal fix reports (false ACT)
function Test-KitCollision([string]$Text) {
  $Text -match '(?i)duplicate (agent|copy|writer|instance|session)|\b(agents?|cop(y|ies)|writers?|sessions?) collid|collid\w* with (an)?other (agent|writer|session)|two (agents|writers|sessions) (on|in|editing|writing) the same|another (agent|writer|session) (is|was) (also )?(editing|writing|running) (in |on )?(the same|this|my)|(halted|stopped editing)\b.{0,60}\b(another|other|duplicate|second) (agent|writer|session)'
}
# a step label's area: build:area-ASK-3, fix:ASK-3@2 and resume:ASK-3 share ASK-3
function Get-KitAreaKey([string]$Label) { ("$Label" -split ':')[-1] -replace '@.*$' -replace '^area-' }
# collisions still open: no later run (created after) delivered MRs for that area
function Select-KitOpenCollisions($Collisions, [hashtable]$DeliveredAt) { @($Collisions | Where-Object { -not ($DeliveredAt[(Get-KitAreaKey $_.label)] -gt $_.created) }) }

# track add with no -Task, MRs titled for 2+ tasks (buildy track step): one add per task, every other flag passed on; an MR naming
# no task (title or branch) is named in a NOTE, never a silent drop
function Invoke-KitTrackAddPerTask($Refs, $Bound) {
  $by = @{}; foreach ($r in $Refs) { $by[$r] = TaskOfMr $r }
  $un = @($Refs | Where-Object { -not $by[$_] }); if ($un.Count) { "NOTE: $($un -join ', ') name(s) no task in title or branch: not registered (track add -Task <id> -Mrs ...)" }
  $sp = @{} + $Bound; foreach ($x in 'Mrs', 'Task', 'Action') { $sp.Remove($x) }
  foreach ($t in @($by.Values | Where-Object { $_ } | Select-Object -Unique)) { Invoke-Track add -Task $t -Mrs @($Refs | Where-Object { $by[$_] -eq $t }) @sp }
}
# ---- decisions: the Decisions checklist, scope-word branches (from bossy.ps1: its token cap)
# the task's Decisions checklist (Format-KitDecisionItems), no comment
function Publish-KitDecisions([string]$Task, [string]$Link) {
  $rows = @(Get-KitTaskDecisionRows $Task); if (-not $rows.Count) { return "NONE $Task`: no decision records for it (decide ask / record -Task)" }
  $tt = try { Get-TrackerTask $Task } catch { $null }; if (-not $tt.name) { return "SKIP $Task`: no readable tracker task (an item code?): nothing published" }   # -Item A2 resolves to task A2
  if (-not $Link) { $Link = "$((Read-KitState (Get-KitTaskFile $Task)).decisions.link)" }
  $items = @(Format-KitDecisionItems $rows $Link $Task)
  $null = Test-KitProse -Kind decisions -Text (@($items.text) -join "`n")   # warnings only: the records are the facts
  $r = Set-KitTaskChecklist $Task 'Decisions' $items
  Update-KitTaskIndex $Task { param($x) $x.decisions = [ordered]@{ rows = $rows; link = $Link; publishedAt = (Get-KitStamp) } }
  "PUBLISHED decisions of $Task ($(@($items | Where-Object { $_.done -and $_.text -notmatch ' → superseded by |^plan · ' }).Count) in force, $(@($items | Where-Object { -not $_.done }).Count) open): $(if ("$r") { "$r" } else { 'checklist updated' })"
}
# an agent's branches (its leased pool slots, its checkpoint worktrees): an answered scope ask records them (wt commit checks by branch)
function Get-KitAgentBranches([string]$Agent, [string]$Run = '') {
  if (-not $Agent) { return @() }
  $ck = Get-KitCheckpoint $Agent $Run
  @(@(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.agent -eq $Agent -and -not $_.parked } | ForEach-Object branch) +
    @(@($ck.worktrees) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { "$(git -C $_ branch --show-current 2>$null)".Trim() }) | Where-Object { $_ } | Select-Object -Unique)
}
