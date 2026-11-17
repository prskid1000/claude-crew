#Requires -Version 7
<#
outcomes.ps1: result signals for the learning loop (dot-sourced by bossy.ps1 from skills/bossy/adapters/): per-task outcome rows
(.state/outcomes.jsonl, one row per state change), their summary (tidy prep digest, dashboard Kit internals), owner decision
patterns -> standing rule proposals; approved rules answer matching decide asks (never deploy, data, prod or customer-visible).
Usage: & <kit>/skills/bossy/bossy.ps1 tidy prep · decide rules [-Propose] [-Approve <ids|all>] [-Revoke <id>] [-Json]
Inputs: .state/tasks/*.json, work/waves/*.json, work/launches/self-*.json, .state/decisions.jsonl. Outputs: outcomes.jsonl,
standing-rules.json, rules/standing-rules.local.md (approved rules only).
Exit codes: 0 ok · 1 problem · 2 usage (bossy.ps1 decide).
Sections: L13 outcomes · L82 summary · L218 patterns · L253 rules
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
  foreach ($x in $c.ix.Values) { if ($x.parent -and ("$($x.spec.kind)" -match '(?i)bug' -or "$($x.spec.title)" -match '^\[Bug\]')) { $p = "$($x.parent)"; $c.bugs[$p] = [int]$c.bugs[$p] + 1; $b = ConvertTo-KitOutcomeIso $x.track.created; if ($b -and (-not $c.bugAt[$p] -or $b -lt $c.bugAt[$p])) { $c.bugAt[$p] = $b } } }
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
# supervise hook: a cheap sweep each beat (only when a task, wave or launch file changed)
function Get-KitSuperviseFlagsOutcomes([switch]$AutoFix) { try { $null = Update-KitOutcomes } catch { [pscustomobject]@{ level = 'WATCH'; what = "outcomes sweep failed: $($_.Exception.Message)"; action = 'bossy.ps1 tidy prep reruns it; else a kitty (kind fix)' } } }

# ---- summary: worst areas, repeat causes, most fix rounds (tidy prep digest, dashboard)
function Get-KitOutcomeStats([int]$Days = 30) {   # TODO-PARAM (fixed default)
  $since = (Get-Date).AddDays(-$Days); $last = @{}
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
  $causes = @(Get-KitSignalGroups $why @() 0.3 | Where-Object { $_.n -ge 2 } | Sort-Object { -$_.n })   # TODO-PARAM (fixed default)
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
  $from = try { [datetime]$Run.started } catch { $null }; $to = try { ([datetime]$Run.at).AddMinutes(60) } catch { $null }
  $hit = @(foreach ($x in @($Ix)) { foreach ($er in @($x.envRuns | Where-Object { $_ })) {
        $named = $Run.qaName -and "$($er.run)" -match "^\d{4}-\d\d-\d\d(-\d{6})?-$([regex]::Escape("$($Run.qaName)"))$"
        $inWin = "$($x.task)" -in @($Run.tasks) -and $from -and $er.at -and [datetime]$er.at -ge $from -and [datetime]$er.at -le $to
        if ($named -or $inWin) { [pscustomobject]@{ task = "$($x.task)"; pass = [int]$er.pass; fail = [int]$er.fail; nt = [int]$er.notTested } } } })
  if (-not $hit.Count) { return $null }
  [pscustomobject]@{ pass = [int]($hit | Measure-Object pass -Sum).Sum; fail = [int]($hit | Measure-Object fail -Sum).Sum; nt = [int]($hit | Measure-Object nt -Sum).Sum
    closed = @($hit | Where-Object { -not $_.fail -and -not $_.nt -and $_.pass } | ForEach-Object task | Select-Object -Unique); failed = @($hit | Where-Object fail | ForEach-Object task | Select-Object -Unique)
    untested = @($hit | Where-Object { -not $_.fail -and $_.nt } | ForEach-Object task | Select-Object -Unique) }
}
# the dashboard's Delivery fold (owner, 2026-11-16: graphs over text, Outcomes + runs in one panel): KPI tiles with weekly lines, the
# per-day chart (runs started, MRs merged, tasks closed, came back; a day click filters the lists), a stacked bar per repo (a segment
# click lists its tasks), $QaTile (QA checks per day), the task list; called by Format-KitSuperviseHtml: its helpers by dynamic scope; $UP = Format-KitUsageHtml
function Format-KitDeliveryHtml($S, $UP, [string]$QaTile = '') {
  $bk = $script:KitOutcomeBuckets; $tone = @{ r0 = 'sage'; r1 = 'slate'; r2 = 'watch'; r3 = 'plum'; rna = 'pale'; back = 'act'; wait = 'none' }
  $pc = { param($v) if ($null -eq $v) { '—' } else { "$v<small>%</small>" } }
  $wk = @($S.weekly)
  $tile = { param($label, $v, $sub, $vals, $cls, $what) "<div class='st dk' data-fit><div class=k>$(& $e $label)</div><div class=v>$v</div><div class=s>$(& $e $sub)</div>$(& $spark $vals $cls $what -NoNow)</div>" }
  $k = $S.kpi; $wTxt = "per week, $($wk.Count) weeks"
  $tiles = & $grid 'stats dlt' 150px @(
    (& $tile 'QA first pass' (& $pc $k.first) "$($k.firstOf) tasks QA'd clean on the first run" @($wk | ForEach-Object first) 'sage' $wTxt),
    (& $tile 'Came back' (& $pc $k.back) "$($k.backOf) reopened, failed testing or a [Bug] under them" @($wk | ForEach-Object back) 'act' $wTxt),
    (& $tile 'Median fix rounds' $(if ($null -ne $k.rounds) { & $n1 $k.rounds } else { '—' }) "over $($k.roundsOf) tasks with a wave report" @($wk | ForEach-Object rounds) 'slate' $wTxt),
    (& $tile 'Hours to promoted' $(if ($null -ne $k.hours) { "$(& $n1 $k.hours)<small> h p50</small>" } else { '—' }) "over $($k.hoursOf) promoted tasks" @($wk | ForEach-Object hours) 'plum' $wTxt),
    $UP.tpm) 5
  # per day (the usage window): a point per day, its tooltip the day's runs and counts; a click filters the task list and the runs to that day
  $dy = @($UP.days | Where-Object { $_ }); $dayOf = { param($iso) if ($iso) { try { ([datetimeoffset]$iso).LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } } }
  $closed = @{}; $back = @{}; foreach ($t in @($S.tasks)) { if ($c = & $dayOf $t.closedAt) { $closed[$c] = @(@($closed[$c]) + $t.id | Where-Object { $_ }) }; if ($b = & $dayOf $t.backAt) { $back[$b] = @(@($back[$b]) + $t.id | Where-Object { $_ }) } }
  $chart = if ($dy.Count) {
    $runsV = @($dy | ForEach-Object { [double]@($UP.dayRuns["$($_.day)"] | Where-Object { $_ }).Count }); $mrV = @($dy | ForEach-Object { [double]$_.merged })
    $clV = @($dy | ForEach-Object { [double]@($closed["$($_.day)"]).Where({ $_ }).Count }); $bkV = @($dy | ForEach-Object { [double]@($back["$($_.day)"]).Where({ $_ }).Count })
    $all = [math]::Max(1, [double](@($runsV + $mrV + $clV + $bkV) | Measure-Object -Maximum).Maximum) * 1.1
    $pts = @(for ($i = 0; $i -lt $dy.Count; $i++) { $dk = "$($dy[$i].day)"; $today = $i -eq $dy.Count - 1; $rr = @($UP.dayRuns[$dk] | Where-Object { $_ })
        @{ label = $(if ($today) { 'today' } else { $dk.Substring(5) }); x = $today; fv = "d$dk"
          tip = "$dk$(if ($today) { ' (today)' }): $($mrV[$i]) MR(s) merged · $($clV[$i]) task(s) closed · $($bkV[$i]) came back · $($rr.Count) run(s) started$(@($rr | Select-Object -First 6 | ForEach-Object { "`n- $(if ("$($_.label)".Trim()) { $_.label } else { $_.run }) ($(if ($_.kind) { $_.kind } else { 'run' }))" }) -join '')$(if ($rr.Count -gt 6) { "`n+ $($rr.Count - 6) more" })`nclick: show that day's tasks and runs" } })
    $fmt = { param($one, $many) { param($v) "$([int]$v) $(if ([int]$v -eq 1) { $one } else { $many })" }.GetNewClosure() }
    Format-KitLineChart $pts @(@{ vals = $mrV; tone = 'sage'; style = 'solid'; area = $true; max = $all; name = 'MRs merged'; fmt = (& $fmt 'MR' 'MRs') },
      @{ vals = $clV; tone = 'slate'; style = 'dash'; max = $all; name = 'tasks closed'; fmt = (& $fmt 'closed' 'closed') },
      @{ vals = $bkV; tone = 'act'; style = 'solid'; max = $all; name = 'came back'; fmt = (& $fmt 'back' 'back'); inline = $true },
      @{ vals = $runsV; tone = 'plum'; style = 'dot'; max = $all; name = 'runs started'; fmt = (& $fmt 'run' 'runs') }) "MRs merged, tasks closed, came back and runs started per day, $($dy.Count) days" 170 -Labels -Filter '#oc-tasks,#sec-runs' }
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
  $barsCard = & $fold 'dl-repos' 'Tasks per repo by outcome' $bars.Count "$($bars -join '')$leg$(if ($noMr) { "<p class=m>$noMr task(s) without an MR not shown</p>" })" -Open -tag h4 -cls 'sub st uc obc'
  # (owner, 2026-11-17) under the per-day chart: MRs merged per repo and day (rows = configured repos + any with an MR; none in the
  # window: folded), work in flight now by status (tap: its tasks), median MR lead time per day (open -> merged, git host only)
  $mrs = @($UP.mrs | Where-Object { $_ -and $_.ref }); $dk = @($dy | ForEach-Object { "$($_.day)" }); $nd = $dk.Count; $ic = [cultureinfo]::InvariantCulture
  $repoOf = { param($ref) ("$ref" -split '[!#]')[0] }
  $rdCard = if ($nd) {
    $mx = [math]::Max(1, [int](@($mrs | Group-Object { "$(& $repoOf $_.ref)|$($_.day)" } | ForEach-Object Count) + 0 | Measure-Object -Maximum).Maximum)
    $cols = "style='grid-template-columns:repeat($nd,minmax(0,1fr))'"
    $rows = @(foreach ($rn in @(@(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.name)" }) + @($mrs | ForEach-Object { & $repoOf $_.ref }) | Where-Object { $_ } | Select-Object -Unique)) {
        $per = @(foreach ($d in $dk) { , @($mrs | Where-Object { (& $repoOf $_.ref) -eq $rn -and "$($_.day)" -eq $d } | ForEach-Object { "$($_.ref)" }) }); $tot = [int](@($per | ForEach-Object { $_.Count }) + 0 | Measure-Object -Sum).Sum
        [pscustomobject]@{ busy = $tot -gt 0; html = "<div class=gk><span class=gn title='$(& $e "${rn}: $tot MR(s) merged in $nd days")'>$(& $e $rn)</span><span class='gs hm fh l-mr' $cols role=img aria-label='$(& $e "$rn, MRs merged per day, $nd days")'>" +
          (@(for ($i = 0; $i -lt $nd; $i++) { $c = @($per[$i]).Count; Format-KitHeatCell (Get-KitHeatShade ($c / $mx)) $(if ($c) { "$c" } else { '' }) "$($dk[$i])$(if ($i -eq $nd - 1) { ' (today)' }) · ${rn}: $c MR(s) merged$(if ($c) { ": $(@($per[$i] | Select-Object -First 8) -join ', ')" })" ($i -eq $nd - 1) }) -join '') + "</span><span class='gc$(if (-not $tot) { ' z' })'>$tot</span></div>" } })
    $head = "<div class='gk gh'><span class=gn>repo · day</span><span class='gs0 hrs' $cols aria-hidden=true>$(@(for ($i = 0; $i -lt $nd; $i++) { "<b$(if ($i -eq $nd - 1) { ' class=nw' })>$(if ($i -eq $nd - 1) { 'today' } else { try { ([datetime]$dk[$i]).ToString('ddd', $ic) } catch { $dk[$i] } })</b>" }) -join '')</span><span class=gc><small>$nd d</small></span></div>"
    & $fold 'dl-repoday' 'MRs merged per repo and day' "$($mrs.Count) MRs" "<div class='gks w1'>$head$(Format-KitHeatRows $rows 'repos')</div><div class=hk>a cell = MRs merged that day (shade by count) · outlined = today · tap a cell for its MRs</div>" -Open:([bool]$mrs.Count) -tag h4 -cls 'sub st uc dlr' }
  $flight = [ordered]@{ open = @('in progress', 'slate'); review = @('review', 'plum'); promoted = @('promoted', 'sage'); intest = @('in test', 'watch'); failedTesting = @('failed testing', 'act') }
  $stOf = { param([string]$s) if ($s -in 'deployed', 'untested') { 'intest' } elseif ($flight.Contains($s)) { $s } else { '' } }   # outcome stage -> status (passed: done, not in flight)
  $fl = @($S.tasks | ForEach-Object { $b = & $stOf $_.stage; if ($b) { [pscustomobject]@{ id = $_.id; b = $b } } })
  $fSegs = @(foreach ($kk in $flight.Keys) { $ids = @($fl | Where-Object b -eq $kk | ForEach-Object id); if (-not $ids.Count) { continue }; $lab = $flight[$kk][0]
      "<i class='ob-$($flight[$kk][1])' style='flex-grow:$($ids.Count)' tabindex=0 role=button data-tip='$(& $e "$lab`: $($ids.Count) task(s)`n$(@($ids | Select-Object -First 12) -join ', ')$(if ($ids.Count -gt 12) { " +$($ids.Count - 12)" })`nclick: list them")' aria-label='$(& $e "$lab`: $($ids.Count)")' data-ft='#oc-tasks' data-fv='st:$kk' data-fl='$(& $e $lab)'>$($ids.Count)</i>" })
  $flightCard = & $fold 'dl-flight' 'Work in flight now' $fl.Count "<div class=obr><span class=obn>tasks</span><span class=obar>$($fSegs -join '')</span></div><ul class='ocl obl'>$(@($flight.Keys | Where-Object { $k0 = $_; @($fl | Where-Object b -eq $k0).Count } | ForEach-Object { "<li><i class='ob-$($flight[$_][1])'></i>$(& $e $flight[$_][0])</li>" }) -join '')</ul>" -Open -tag h4 -cls 'sub st uc'
  $med = { param($v) $s = @($v | Sort-Object); if ($s.Count) { $s[[int][math]::Floor(($s.Count - 1) / 2)] } else { $null } }   # lower median, as the KPIs; $null keeps its day's slot
  $leadV = @(foreach ($d in $dk) { & $med @($mrs | Where-Object { "$($_.day)" -eq $d -and $null -ne $_.lead } | ForEach-Object { [double]$_.lead }) })
  $leadAll = & $med @($mrs | Where-Object { $null -ne $_.lead } | ForEach-Object { [double]$_.lead })
  $leadCard = if ($null -ne $leadAll) {
    $lp = @(for ($i = 0; $i -lt $nd; $i++) { @{ label = $(if ($i -eq $nd - 1) { 'today' } else { $dk[$i].Substring(5) }); x = $i -eq $nd - 1; tip = "$($dk[$i]): $(if ($null -ne $leadV[$i]) { "median $(& $n1 $leadV[$i]) h open -> merged" } else { 'no MR merged' })" } })
    & $fold 'dl-lead' 'MR lead time, median per day' "$(& $n1 $leadAll) h" (Format-KitLineChart $lp @(@{ vals = @($leadV | ForEach-Object { if ($null -ne $_) { $_ } else { 0 } }); tone = 'plum'; style = 'solid'; fmt = { param($v) if ([double]$v) { "$([math]::Round([double]$v, 1)) h" } else { '' } } }) "median MR lead time per day, $nd days" 80 -Labels) -Open -tag h4 -cls 'sub st uc' }
    else { & $fold 'dl-lead' 'MR lead time, median per day' 0 '' -tag h4 -cls 'sub st uc' }   # (0): no git-host list with open times
  # the tasks behind a click (a segment: repo + bucket, a grouped repo as "other"; a day: closed or came back that day; a status); hidden until a filter is set
  $rows = @($S.tasks | Where-Object { $_.repos.Count -or $_.closedAt -or $_.backAt -or (& $stOf $_.stage) } | ForEach-Object { $t = $_
      $fk = @(@($t.repos | ForEach-Object { "$(if ($_ -in $restNames) { 'other' } else { $_ }):$($t.bucket)" }) + @(if ($c = & $dayOf $t.closedAt) { "d$c" }) + @(if ($b = & $dayOf $t.backAt) { "d$b" }) + @(if ($s0 = & $stOf $t.stage) { "st:$s0" }) | Select-Object -Unique) -join ' '
      "<li data-fk='$(& $e $fk)'>$(& $taskA $t.id)<span class='chip ob-$($tone[$t.bucket])'>$(& $e $bk[$t.bucket])</span><span class=m>$(& $e ($t.repos -join ', '))</span></li>" })
  $list = "<div id=oc-tasks class='ftl uc'><p class=fclr hidden>Tasks: <b></b> <button type=button>Clear</button></p><ul class=otl>$($rows -join '')</ul></div>"
  # two balanced columns (owner 2026-11-17): cards pack into the shorter column, the last tile of each stretches (masonry data-fill)
  "$tiles<div class='ug dlv' style='--cmin:380px;--cmax:2' data-mas data-fill>$(if ($chart) { & $fold 'dl-days' 'Delivered per day' '' $chart -Open -tag h4 -cls 'sub st uc dlc' })$rdCard$barsCard$flightCard$leadCard$QaTile</div>$list"
}
# bucket order = the bar's segment order: passed QA by fix rounds before it (n/a: no wave report names the task), came back, not tested yet
$script:KitOutcomeBuckets = [ordered]@{ r0 = 'passed, 0 fix rounds'; r1 = 'passed, 1 round'; r2 = 'passed, 2 rounds'; r3 = 'passed, 3+ rounds'; rna = 'passed, rounds not recorded'; back = 'came back'; wait = 'not tested yet' }
function Get-KitOutcomeBucket($R) {
  if ($R.cameBack) { return 'back' }; if ("$($R.stage)" -ne 'passed') { return 'wait' }; if (-not @($R.agents | Where-Object { $_ }).Count) { return 'rna' }
  $n = [math]::Max(0, [int]$R.localRounds - 1) + [int]$R.reviewFix; if ($n -ge 3) { 'r3' } else { "r$n" }
}
function Get-KitOutcomeLines([int]$Days = 30) {   # TODO-PARAM (fixed default)
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
function Test-KitSameChoice($A, $B, [double]$Min = 0.8) {   # TODO-PARAM (fixed default)
  if (-not $A.Count -or -not $B.Count) { return $false }
  $neg = { param($s) [bool]@($s | Where-Object { $_ -in 'no', 'not', 'never', 'none', 'without', 'dont', 'cant', 'wont', 'nothing', 'neither', 'skip' }).Count }
  if ((& $neg $A) -ne (& $neg $B)) { return $false }
  $in = @($A | Where-Object { $B.Contains($_) }).Count; $in / [math]::Min($A.Count, $B.Count) -ge $Min
}
function Test-KitRuleSensitive([string]$Gate, [string]$Question) { $Gate -in $script:KitRuleNeverGates -or $Question -match $script:KitRuleNeverRx }
function Get-KitDecisionPatterns([int]$Min = 3, [double]$Topic = 0.5, [double]$Same = 0.8) {   # TODO-PARAM (fixed default)
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
function Find-KitStandingRule($Rules, [string]$Gate, $Words, [double]$Min = 0.5) {   # TODO-PARAM (fixed default)
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
