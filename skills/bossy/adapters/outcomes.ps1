#Requires -Version 7
<#
outcomes.ps1: result signals for the learning loop (dot-sourced by bossy.ps1 from skills/bossy/adapters/): per-task outcome rows
(.state/outcomes.jsonl, one row per state change), their summary (tidy prep digest, dashboard Kit internals), owner decision
patterns -> standing rule proposals; approved rules answer matching decide asks (never deploy, data, prod or customer-visible);
the retro-due rule and the tidy verb (from bossy.ps1: its token cap).
Usage: & <kit>/skills/bossy/bossy.ps1 tidy prep · decide rules [-Propose] [-Approve <ids|all>] [-Revoke <id>] [-Json]
Inputs: .state/tasks/*.json, work/waves/*.json, work/launches/self-*.json, .state/decisions.jsonl. Outputs: outcomes.jsonl,
standing-rules.json, rules/standing-rules.local.md (approved rules only).
Exit codes: 0 ok · 1 problem · 2 usage (bossy.ps1 decide).
Sections: L14 outcomes · L83 summary · L214 patterns · L249 rules · L327 retro due · L337 tidy
#>

# ---- outcomes: one row per task state change; tracker-generic (task index, wave reports, launches, decisions)
$script:KitOutcomeKeys = @('kind', 'parent', 'area', 'agents', 'stage', 'mrs', 'qaRuns', 'qaFirstPass', 'qaFails', 'bugs', 'cameBack', 'localRounds', 'reviewFix', 'decisions', 'hPromoted', 'hClosed', 'spend', 'doneAt', 'closedAt', 'backAt')
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
  $c = @{ ix = @{}; agents = @{}; local = @{}; review = @{}; bugs = @{}; decisions = @{}; spend = @{} }
  foreach ($x in @(Read-KitJsonFiles (Get-KitPath tasks))) { if ($x.task) { $c.ix["$($x.task)"] = $x } }
  $c.bugAt = @{}
  foreach ($x in $c.ix.Values) { if ($x.parent -and ("$($x.spec.kind)" -match '(?i)bug' -or (Test-KitBugName "$($x.spec.title)"))) { $p = "$($x.parent)"; $c.bugs[$p] = [int]$c.bugs[$p] + 1; $b = ConvertTo-KitOutcomeIso $x.track.created; if ($b -and (-not $c.bugAt[$p] -or $b -lt $c.bugAt[$p])) { $c.bugAt[$p] = $b } } }
  foreach ($w in @(Read-KitJsonFiles (Get-KitPath waves))) {
    foreach ($p in @(Get-KitProps $w.agents)) { foreach ($t in @($p.Value.done | Where-Object { $_ })) {
      $c.agents[$t] = @(@($c.agents[$t]) + $p.Name | Where-Object { $_ } | Select-Object -Unique)
      $c.local[$t] = [int]$c.local[$t] + [int]$p.Value.localRounds; $c.review[$t] = [int]$c.review[$t] + [int][bool]$p.Value.fixedRound } }
  }
  foreach ($d in @(Get-KitOwnerAnswers | Where-Object task)) { $c.decisions["$($d.task)"] = [int]$c.decisions["$($d.task)"] + 1 }
  $ids = @($c.ix.Keys)
  foreach ($l in @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Where-Object { [double]$_.spent -gt 0 })) {   # a run's spend split over the tasks its args name
    $raw = "$($l.argsRaw)$(if (-not $l.argsRaw) { $l.args | ConvertTo-Json -Compress -Depth 8 })"; $hit = @($ids | Where-Object { $raw.Contains($_) })
    foreach ($t in $hit) { $c.spend[$t] = [double]$c.spend[$t] + [double]$l.spent / $hit.Count }
  }
  $c
}
function Get-KitTaskOutcome($Ix, $Ctx) {
  $t = "$($Ix.task)"; $tr = $Ix.track; $runs = @($Ix.envRuns | Where-Object { $_ }); $last = $runs | Select-Object -Last 1
  $clean = { param($r) $r -and [int]$r.fail -eq 0 -and [int]$r.notTested -eq 0 -and [int]$r.pass -gt 0 }
  $fails = @($runs | Where-Object { [int]$_.fail -gt 0 }).Count; $bugs = [int]$Ctx.bugs[$t]
  $stage = if ($last) { if ([int]$last.fail) { 'failedTesting' } elseif (& $clean $last) { 'passed' } else { 'untested' } } elseif (@($tr.liveOn | Where-Object { $_ }).Count) { 'deployed' } elseif ($tr.done) { 'promoted' } elseif (@($tr.mrs | Where-Object { $_ }).Count) { 'review' } else { 'open' }
  [ordered]@{ task = $t; kind = "$($Ix.spec.kind)"; parent = "$($Ix.parent)"
    area = @(@($tr.mrs | Where-Object { $_ }) | ForEach-Object { Get-KitRepoName ((("$_" -split '[!#]')[0] -split '/')[-1]) } | Sort-Object -Unique) -join ','
    agents = @($Ctx.agents[$t] | Where-Object { $_ }); stage = $stage; mrs = @($tr.mrs | Where-Object { $_ }).Count; qaRuns = $runs.Count
    qaFirstPass = $(if ($runs.Count) { [bool](& $clean $runs[0]) } else { $null }); qaFails = $fails; bugs = $bugs
    cameBack = [bool]($tr.reopenedAt -or $fails -or $bugs); localRounds = [int]$Ctx.local[$t]; reviewFix = [int]$Ctx.review[$t]
    decisions = [int]$Ctx.decisions[$t]; hPromoted = $(if ($tr.done) { Get-KitOutcomeHours $tr.created $tr.doneAt })
    hClosed = $(if ($stage -eq 'passed') { Get-KitOutcomeHours $tr.created $last.at }); spend = [int][math]::Round([double]$Ctx.spend[$t])
    doneAt = $(if ($tr.done) { ConvertTo-KitOutcomeIso $tr.doneAt }); closedAt = $(if ($stage -eq 'passed') { ConvertTo-KitOutcomeIso $last.at })   # the day chart's points
    backAt = @(@(ConvertTo-KitOutcomeIso $tr.reopenedAt) + @($runs | Where-Object { [int]$_.fail -gt 0 } | ForEach-Object { ConvertTo-KitOutcomeIso $_.at }) + @($Ctx.bugAt[$t]) | Where-Object { $_ } | Sort-Object)[0]
    seen = $(if ($Ix.updated) { ([datetime]$Ix.updated).ToString('o') }) }   # the task's last change (window); not in the row signature
}
function Read-KitOutcomeRows { $f = Get-KitPath outcomes; if (Test-Path -LiteralPath $f) { foreach ($l in [IO.File]::ReadAllLines($f)) { try { $l | ConvertFrom-Json } catch {} } } }
# rows changed since the last sweep (-All: every task); cumulative fields never shrink (wave reports and launches age out)
function Update-KitOutcomes([switch]$All) {
  $t0 = Get-Date; $stampFile = Get-KitPath outcomes-sweep -Create
  $stamp = if (-not $All -and (Test-Path -LiteralPath $stampFile)) { try { [datetime](Get-Content -LiteralPath $stampFile -Raw).Trim() } catch { $null } }
  $fresh = { param($n, $f) @(Get-ChildItem -LiteralPath (Get-KitPath $n) -Filter $f -File -ErrorAction SilentlyContinue | Where-Object { -not $stamp -or $_.LastWriteTime -gt $stamp }).Count }
  if ($stamp -and -not ((& $fresh tasks '*.json') + (& $fresh waves '*.json') + (& $fresh launches 'self-*.json'))) { Set-Content -LiteralPath $stampFile $t0.ToString('o'); return 0 }
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
  Set-Content -LiteralPath $stampFile $t0.ToString('o'); $n
}
# supervise hook: every 30 min (lib.ps1 New-KitSweep; 1.5-3 s while tasks change; tidy prep runs its own), only when a task, wave or launch file changed
function Get-KitSuperviseFlagsOutcomes([switch]$AutoFix) { if (-not (Within 'outcomes')) { return }; try { $null = Update-KitOutcomes } catch { [pscustomobject]@{ level = 'WATCH'; what = "outcomes sweep failed: $($_.Exception.Message)"; action = 'bossy.ps1 tidy prep reruns it; else a kitty (kind fix)' } } }

# ---- summary: worst areas, repeat causes, most fix rounds (tidy prep digest, dashboard)
function Get-KitOutcomeStats([int]$Days = (Get-KitParam 'outcomes.days'), [datetime]$StatsFrom = [datetime]::MinValue) {   # the page: Get-KitStatsCutoff
  $since = (Get-Date).AddDays(-$Days); if ($StatsFrom -gt $since) { $since = $StatsFrom }; $last = @{}
  foreach ($r in @(Read-KitOutcomeRows)) { $w = @($r.seen, $r.at | Where-Object { $_ })[0]; if ($r.task) { if ($w -and [datetime]$w -ge $since) { $last["$($r.task)"] = $r } else { $last.Remove("$($r.task)") } } }
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
      week = [int][math]::Floor(((Get-Date) - [datetime]@($r.doneAt, $r.seen, $r.at | Where-Object { $_ })[0]).TotalDays / 7); closedAt = (ConvertTo-KitOutcomeIso $r.closedAt); backAt = (ConvertTo-KitOutcomeIso $r.backAt)
      firstPass = [bool]$r.qaFirstPass; qa = [int]$r.qaRuns -gt 0; back = [bool]$r.cameBack; hPromoted = $r.hPromoted; stage = "$($r.stage)" } })
  $repos = @($tasks | ForEach-Object { $t = $_; foreach ($rp in $t.repos) { [pscustomobject]@{ repo = $rp; t = $t } } } | Group-Object repo | ForEach-Object {
      $g = @($_.Group.t); $b = [ordered]@{}; foreach ($k in $script:KitOutcomeBuckets.Keys) { $b[$k] = @($g | Where-Object bucket -eq $k | ForEach-Object id) }
      [pscustomobject]@{ repo = $_.Name; n = $g.Count; tested = @($g | Where-Object { $_.bucket -ne 'wait' }).Count; buckets = $b } } | Sort-Object { -$_.n }, repo)
  $med = { param($v) $s = @($v | Sort-Object); if ($s.Count) { $s[[int][math]::Floor(($s.Count - 1) / 2)] } }   # lower median, as p50Promoted
  $kpi = { param($ts) $q = @($ts | Where-Object qa); $bq = @($ts | Where-Object { $_.qa -or $_.back }); $rd = @($ts | Where-Object { $null -ne $_.rounds } | ForEach-Object { [double]$_.rounds }); $h = @($ts | Where-Object { $null -ne $_.hPromoted } | ForEach-Object { [double]$_.hPromoted })
    [pscustomobject]@{ first = $(if ($q.Count) { [math]::Round(100 * @($q | Where-Object firstPass).Count / $q.Count) }); firstOf = "$(@($q | Where-Object firstPass).Count)/$($q.Count)"
      back = $(if ($bq.Count) { [math]::Round(100 * @($bq | Where-Object back).Count / $bq.Count) }); backOf = "$(@($bq | Where-Object back).Count)/$($bq.Count)"
      rounds = (& $med $rd); roundsOf = $rd.Count; hours = (& $med $h); hoursOf = $h.Count } }
  $weeks = [int][math]::Ceiling($Days / 7)
  [pscustomobject]@{ days = $Days; n = $rows.Count; qaN = $qa.Count; firstPass = @($qa | Where-Object qaFirstPass).Count; cameBack = @($rows | Where-Object cameBack).Count
    p50Promoted = $(if ($hp.Count) { $hp[[int][math]::Floor(($hp.Count - 1) / 2)] }); areas = $areas; agents = $agents; causes = $causes
    tasks = $tasks; repos = $repos; kpi = (& $kpi $tasks); weekly = @(for ($w = $weeks - 1; $w -ge 0; $w--) { & $kpi @($tasks | Where-Object week -eq $w) }) }
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
# (MRs merged per repo, tasks closed, came back, runs started + $More rows @{ d = dates; v }; a day click filters the lists), a stacked
# bar per repo (a segment click lists its tasks), $QaTile, $Blocks (spend, repos), the task list; helpers by dynamic scope; $UP = Format-KitUsageHtml
function Format-KitDeliveryHtml($S, $UP, [string]$QaTile = '', $More = @(), [string]$Blocks = '') {
  if (-not $S) { $S = [pscustomobject]@{ kpi = [pscustomobject]@{}; tasks = @(); repos = @() } }   # no outcome stats yet: the rest still shows
  $bk = $script:KitOutcomeBuckets; $tone = @{ r0 = 'sage'; r1 = 'slate'; r2 = 'watch'; r3 = 'plum'; rna = 'pale'; back = 'act'; wait = 'none' }
  $pc = { param($v) if ($null -eq $v) { '—' } else { "$v<small>%</small>" } }
  # KPI tiles: the value and its base once (owner 2026-11-19: no sparklines; the weekly trend is read in a retro)
  $tile = { param($label, $v, [string]$u, $sub) @{ v = $(if ($null -ne $v) { & $n1 $v } else { '—' }); u = $(if ($null -ne $v) { $u }); l = $label; tip = "${label}: $sub" } }
  $k = $S.kpi
  $kt = @((& $tile 'QA first pass' $k.first '%' "$($k.firstOf) tasks QA'd clean on the first run"), (& $tile 'came back' $k.back '%' "$($k.backOf) reopened, failed testing or a [Bug] under them"),
    (& $tile 'median fix rounds' $k.rounds '' "over $($k.roundsOf) tasks with a wave report"), (& $tile 'hours to promoted, p50' $k.hours ' h' "over $($k.hoursOf) promoted tasks"))
  $tiles = "<div class=tls data-mk=trend-tiles>$((Format-KitTiles $kt) -replace '^<div class=tls>|</div>$')$($UP.tpm)$($UP.tiles)</div>"
  $dy = @($UP.days | Where-Object { $_ }); $dayOf = { param($iso) if ($iso) { try { ([datetimeoffset]$iso).LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } } }
  $closed = @{}; $back = @{}; foreach ($t in @($S.tasks)) { if ($c = & $dayOf $t.closedAt) { $closed[$c] = @(@($closed[$c]) + $t.id | Where-Object { $_ }) }; if ($b = & $dayOf $t.backAt) { $back[$b] = @(@($back[$b]) + $t.id | Where-Object { $_ }) } }
  # a stacked bar per repo with a QA'd task; the untested ones: one "other (a, b)" bar when 2+, a single one by its own name; the legend once
  $rp = @($S.repos | Where-Object tested); $rest = @($S.repos | Where-Object { -not $_.tested }); if ($rest.Count -eq 1) { $rp += $rest; $rest = @() }; $restNames = @($rest.repo)
  if ($rest.Count) { $ob = [ordered]@{}; foreach ($kk in $bk.Keys) { $ob[$kk] = @($rest | ForEach-Object { @($_.buckets[$kk]) } | Where-Object { $_ } | Select-Object -Unique) }; $rp += [pscustomobject]@{ repo = 'other'; who = (@($rest.repo) -join ', '); n = [int]($rest | Measure-Object n -Sum).Sum; buckets = $ob } }
  $bars = @($rp | ForEach-Object { $r = $_; $nm = if ($r.who) { "other ($($r.who))" } else { $r.repo }
      $segs = @(foreach ($kk in $bk.Keys) { $ids = @($r.buckets[$kk] | Where-Object { $_ }); if (-not $ids.Count) { continue }
          $lab = "$nm · $($bk[$kk])"; $tip = "$lab`: $($ids.Count) task(s)`n$(@($ids | Select-Object -First 12) -join ', ')$(if ($ids.Count -gt 12) { " +$($ids.Count - 12)" })`nclick: list them"
          "<i class='ob-$($tone[$kk])' style='flex-grow:$($ids.Count)' tabindex=0 role=button data-tip='$(& $e $tip)' aria-label='$(& $e "$lab`: $($ids.Count)")' data-ft='#oc-tasks' data-fv='$(& $e "$($r.repo):$kk")' data-fl='$(& $e $lab)'>$($ids.Count)</i>" })
      "<div class=obr><span class=obn>$(& $e $nm) <b>$($r.n)</b></span><span class=obar>$($segs -join '')</span></div>" })
  $leg = "<ul class='ocl obl'>$(@($bk.Keys | ForEach-Object { "<li><i class='ob-$($tone[$_])'></i>$(& $e $bk[$_])</li>" }) -join '')</ul>"
  $noMr = @($S.tasks | Where-Object { -not $_.repos.Count }).Count
  $barsCard = & $fold 'dl-repos' 'Tasks per repo by outcome' $bars.Count "<div data-mk=tasks-outcome>$($bars -join '')</div>$leg$(if ($noMr) { "<p class=m>$noMr task(s) without an MR not shown</p>" })" -Open -tag h4 -cls 'sub st uc obc'
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
    $fb = @($sumRows | Where-Object { @($_.v | Where-Object { $_ }).Count })[0]; if ($fb) { $fb.gl = $true }   # the rule above the first shown one (idle rows fold)
    $mr0 = @($More | Where-Object { $_ } | ForEach-Object { & $align $_ }); if ($mr0.Count) { $mr0[0].gl = $true }
    & $fold 'dl-days' 'Per day' "$($mrs.Count) MRs$(if ($null -ne $leadAll) { " · lead time p50 $(& $n1 $leadAll) h" })" "$(Format-KitDayHeat (@($repoRows) + @($sumRows) + $mr0) $dk 'repo · series · day')$(Format-KitLegend "outlined = today · $(Format-KitSplitLegend)" "a cell = that day's value, shaded by the row's peak · the right column: 7 days (sum, or as the row's tooltip says) · a click on tasks closed, came back or runs started filters the tasks and runs · est. cost and tokens: a tile per type, each shaded by its own 7-day peak; a narrow cell shows the total over a bar · hover a cell for every value and its cost")" -Open -tag h4 -cls 'sub st uc dlr' }
  $flight = [ordered]@{ open = @('in progress', 'slate'); review = @('review', 'plum'); promoted = @('promoted', 'sage'); intest = @('in test', 'watch'); failedTesting = @('failed testing', 'act') }
  $stOf = { param([string]$s) if ($s -in 'deployed', 'untested') { 'intest' } elseif ($flight.Contains($s)) { $s } else { '' } }   # outcome stage -> status (passed: done, not in flight)
  $fl = @($S.tasks | ForEach-Object { $b = & $stOf $_.stage; if ($b) { [pscustomobject]@{ id = $_.id; b = $b } } })
  $fSegs = @(foreach ($kk in $flight.Keys) { $ids = @($fl | Where-Object b -eq $kk | ForEach-Object id); if (-not $ids.Count) { continue }; $lab = $flight[$kk][0]
      "<i class='ob-$($flight[$kk][1])' style='flex-grow:$($ids.Count)' tabindex=0 role=button data-tip='$(& $e "$lab`: $($ids.Count) task(s)`n$(@($ids | Select-Object -First 12) -join ', ')$(if ($ids.Count -gt 12) { " +$($ids.Count - 12)" })`nclick: list them")' aria-label='$(& $e "$lab`: $($ids.Count)")' data-ft='#oc-tasks' data-fv='st:$kk' data-fl='$(& $e $lab)'>$($ids.Count)</i>" })
  $flightCard = & $fold 'dl-flight' 'Work in flight now' $fl.Count "<div class=obr data-mk=tasks-flight><span class=obn>tasks</span><span class=obar>$($fSegs -join '')</span></div><ul class='ocl obl'>$(@($flight.Keys | Where-Object { $k0 = $_; @($fl | Where-Object b -eq $k0).Count } | ForEach-Object { "<li><i class='ob-$($flight[$_][1])'></i>$(& $e $flight[$_][0])</li>" }) -join '')</ul>" -Open -tag h4 -cls 'sub st uc'
  # the tasks behind a click (a segment: repo + bucket, a grouped repo as "other"; a day: closed or came back that day; a status); hidden until a filter is set
  $rows = @($S.tasks | Where-Object { $_.repos.Count -or $_.closedAt -or $_.backAt -or (& $stOf $_.stage) } | ForEach-Object { $t = $_
      $fk = @(@($t.repos | ForEach-Object { "$(if ($_ -in $restNames) { 'other' } else { $_ }):$($t.bucket)" }) + @(if ($c = & $dayOf $t.closedAt) { "dc$c" }) + @(if ($b = & $dayOf $t.backAt) { "db$b" }) + @(if ($s0 = & $stOf $t.stage) { "st:$s0" }) | Select-Object -Unique) -join ' '
      "<li data-fk='$(& $e $fk)'>$(& $taskA $t.id)<span class='chip ob-$($tone[$t.bucket])'>$(& $e $bk[$t.bucket])</span><span class=m>$(& $e ($t.repos -join ', '))</span></li>" })
  $list = "<div id=oc-tasks class='ftl uc'><p class=fclr hidden>Tasks: <b></b> <button type=button>Clear</button></p><ul class=otl>$($rows -join '')</ul></div>"
  # two balanced columns (owner 2026-11-17): cards pack into the shorter column, the last tile of each stretches (masonry data-fill)
  "$tiles$dayCard<div class='ug dlv' style='--cmin:380px;--cmax:2' data-mas data-fill>$barsCard$flightCard$QaTile</div>$Blocks$list"
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
  "$($s.n) task(s) in $Days d: QA first pass $($s.firstPass)/$($s.qaN), came back $($s.cameBack) (reopened, failedTesting or a [Bug] under it)$(if ($null -ne $s.p50Promoted) { ", p50 $($s.p50Promoted) h to promoted" })"
  foreach ($a in @($s.areas | Where-Object score | Select-Object -First 5)) { "area $($a.area): $($a.n) task(s), first pass $($a.firstPass)/$($a.qaN), came back $($a.cameBack), fix rounds $($a.rounds)" }
  foreach ($a in @($s.agents | Select-Object -First 5)) { "agent $($a.agent): $($a.rounds) fix round(s) over $($a.tasks) task(s)" }
  foreach ($g in @($s.causes | Select-Object -First 5)) { "cause $($g.n)x: $(& $cut $g.text)$(if ($g.refs) { " ($(@($g.refs | Select-Object -First 3) -join ', '))" })" }
}

# ---- patterns: one topic, the same owner choice 3+ times, no contrary answer -> a standing rule proposal
$script:KitRuleNeverGates = @('deploy', 'rollback', 'secret', 'data', 'close', 'merge', 'premerge')
$script:KitRuleNeverRx = '(?i)\b(prod\w*|deploy\w*|release|rollback|secret\w*|credential\w*|customer\w*|client[- ]facing|\w+[- ](visible|facing)|tenant\w*|migrat\w*|backfill\w*|delete\w*|drop|truncate|purge|data)\b'   # over-blocking costs one ask
function Get-KitTopicWords([string]$Question) { Get-KitWordSet ("$Question" -replace '\([^)]*\)', ' ' -replace '\b[A-Za-z]+-\d+[a-z]?\b', ' ' -replace '\b[0-9a-z_]*\d[0-9a-z_]*\b', ' ') }
# choice words keep short ones (no, keep, all): polarity matters
function Get-KitChoiceWords([string]$Answer) {
  $s = "$Answer".ToLower() -replace '\(recommended\)', ' ' -replace '\((owner|by|via|standing)[^)]*\)', ' ' -replace '^\s*[a-z0-9]{1,2}\s*[:.)]\s+', '' -replace '\b[de]-\d{14}\S*', ' ' -replace "\b(don|doesn|didn|won|can|shouldn|wouldn|isn|aren|couldn)['’]?t\b|\bcannot\b", ' not '
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
    $w = Get-KitTopicWords $d.question; if ($w.Count -lt 2) { continue }
    $hit = $null; foreach ($g in $groups) { if ($g.gate -eq "$($d.gate)" -and @($g.words | Where-Object { (Get-KitOverlap $_ $w) -ge $Topic }).Count) { $hit = $g; break } }
    if ($hit) { $hit.items.Add($d); $hit.words.Add($w) } else { $groups.Add([pscustomobject]@{ gate = "$($d.gate)"; items = [Collections.Generic.List[object]]@(, $d); words = [Collections.Generic.List[object]]@(, $w) }) }
  }
  foreach ($g in $groups) {
    if ($g.items.Count -lt $Min) { continue }
    $ref = $g.items[$g.items.Count - 1]; $rw = Get-KitChoiceWords $ref.answer
    $agree = @($g.items | Where-Object { Test-KitSameChoice (Get-KitChoiceWords $_.answer) $rw $Same })
    if ($agree.Count -lt $Min -or $agree.Count -ne $g.items.Count) { continue }   # one contrary answer: no pattern
    [pscustomobject]@{ gate = $g.gate; question = "$($ref.question)"; answer = "$($ref.answer)"; evidence = @($g.items.id); words = @((Get-KitTopicWords $ref.question) | ForEach-Object { $_ })
      auto = -not @($g.items | Where-Object { Test-KitRuleSensitive "$($_.gate)" "$($_.question)" }).Count }
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
    $named = @([regex]::Matches("$Answer", 'sr-[0-9a-f]{4,}') | ForEach-Object Value)
    if ("$Answer" -match '(?i)\b(except|but not|excluding)\b') { foreach ($r in $mine) { $r.askId = '' }; Save-KitStandingRules $rules; return }   # unclear pick: the next prep asks again
    $all = -not $named.Count -and "$Answer" -match '(?i)^\s*(a\s*([:.)]|$)|approve all\b|all\b|yes\b)'
    foreach ($r in $mine) { if ($all -or $r.id -in $named) { $r.status = 'approved'; $r.approvedAt = (Get-Date).ToString('o'); $r.approvedBy = $By } else { $r.status = 'rejected' } }
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
      foreach ($r in $hit) { if ($Revoke) { $r.status = 'revoked'; $r.revokedAt = (Get-Date).ToString('o') } else { $r.status = 'approved'; $r.approvedAt = (Get-Date).ToString('o'); $r.approvedBy = $By } }   # read back as hashtables (Read-KitState): keys, not Add-Member
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
        $r = [pscustomobject][ordered]@{ id = "sr-$([guid]::NewGuid().ToString('N').Substring(0, 6))"; status = 'proposed'; gate = $p.gate; question = $p.question; answer = $p.answer
          evidence = @($p.evidence); words = @($p.words); auto = $p.auto; proposedAt = (Get-Date).ToString('o'); askId = '' }
        $rules.Add($r); $added += $r
      }
      Save-KitStandingRules @($rules); $added
    }
    $new = @($new | Where-Object { $_ })
    $open = @(Read-KitStandingRules | Where-Object { $_.status -eq 'proposed' -and -not $_.askId })
    if ($open.Count -and -not @(Read-KitJsonFiles (Get-KitPath decisions) | Where-Object { $_.item -eq 'standing-rules' -and $_.status -eq 'pending' }).Count) {
      $each = @($open | ForEach-Object { $_.id + ': asked "' + $_.question + '" -> "' + $_.answer + '"' + $(if (-not $_.auto) { ' [guidance only]' }) + ' (evidence ' + (@($_.evidence) -join ', ') + ')' })
      $q = 'Standing rules from repeated answers (approve once; decide ask then answers matching questions, logged, revocable): ' + ($each -join ' · ')
      $ask = @(Invoke-Decide ask -Run tidy -Agent coordinator -Item standing-rules -Question $q -Options 'A: approve all — each answers its future matches', 'B: approve none — keep asking', 'C: approve only the sr- ids I name — the rest stay asked' -Recommend A -NoPublish)
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
# 15+ signals and guard blocks since the last retro, or any after a run
function Get-KitRetroDue([switch]$RunFinished) {
  $since = Get-KitRetroSince
  $n = @(Get-Content (Get-KitPath signals) -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '"kind":"retired"' -and $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Read-KitLog guard $since | Where-Object event -eq 'deny').Count
  if ($n + $g -ge 15 -or ($RunFinished -and $n)) { "$n signal(s) + $g guard block(s) since the last retro" }
}

# ---- tidy: /tidy script step (digest + upkeep) and retro stamp
function Invoke-Tidy {
param([Parameter(Position = 0)][string]$Action, [string]$At, [switch]$DryRun, [switch]$Json)
if ($Action -eq 'done') {   # signals up to the prep time count as reviewed
  $t = try { [datetime]$At } catch { $null }; if (-not $t) { 'usage: tidy done -At <time>'; exit 2 }
  $m = Get-KitPath last-retro -Create
  if (-not $DryRun) { Set-Content $m $t.ToString('o'); Remove-Item "$m.start" -ErrorAction SilentlyContinue }   # .start: the old workflow's marker
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
& $part 'Guard blocks' (& $top $deny { & $cut $_.why 110 })
& $part 'Script errors (crash or usage)' (& $top $errs { "$($_.script) $($_.verb): $(if ($_.error) { & $cut $_.error 90 } else { "exit $($_.rc), message on stderr only (not a crash)" })" })
& $part 'Builds per kind (gate)' @($bld | Group-Object kind | ForEach-Object { $q = @($_.Group.sec | ForEach-Object { [double]$_ } | Sort-Object); "$($_.Name): $($_.Count), $(@($_.Group | Where-Object { "$($_.code)" -ne '0' }).Count) failed, p50 $($q[[int][math]::Floor(($q.Count - 1) / 2)]) s, max $($q[-1]) s, wait max $(($_.Group.waitSec | Measure-Object -Maximum).Maximum) s, peak max $(($_.Group.peakGB | Measure-Object -Maximum).Maximum) GB" })
& $part 'Local env failures' (& $top $envF { "$($_.event) $($_.env) $($_.service)".Trim() } 8)
& $part 'Runs since' @(@($runs | Select-Object -Last 15 | ForEach-Object { "$($_.run) ($(Split-Path "$($_.script)" -Leaf)) spent $([int]$_.spent) of $([int]$_.cap)" }) + @($qa | Select-Object -Last 10 | ForEach-Object { "QA $($_.Name)$(Get-KitQaRunGap $_.FullName)" }))
& $part 'Upkeep (no LLM)' @(@($steps | ForEach-Object { "$($_.step): $($_.state) ($($_.sec) s)$(if ($_.out) { ': ' + (& $cut ($_.out -join ' | ') 400) })" }) + @(Invoke-KitHooks Get-KitHealthLinesAudit))
$file = Join-Path (Get-KitPath retros -Create) "digest-$($t0.ToString('yyyy-MM-dd-HHmm')).md"
[IO.File]::WriteAllText($file, (($d -join "`n") + "`n"))
$stamped = -not $work -and -not $DryRun -and -not @($steps | Where-Object state -eq 'failed').Count
if ($stamped) { $null = Invoke-Tidy done -At $t0.ToString('o') }   # nothing to judge
$o = [ordered]@{ digest = $file; at = $t0.ToString('o'); work = $work; groups = @($groups | Where-Object n -ge 2).Count; minutes = $min; stamped = $stamped; sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); steps = @($steps | ForEach-Object { "$($_.step) $($_.state) $($_.sec)s" }) }
if ($Json) { $o | ConvertTo-Json -Compress; return }
"DIGEST $file"; "AT $($o.at)"; "WORK $work ($($o.groups) group(s) of 2+)$(if ($stamped) { '; nothing to judge: last retro stamped' })"; "MINUTES $min"; $o.steps | ForEach-Object { "  $_" }
}
