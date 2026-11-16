#Requires -Version 7
<#
outcomes.ps1: result signals for the learning loop (dot-sourced by bossy.ps1 from skills/bossy/adapters/): per-task outcome rows
(.state/outcomes.jsonl, one row per state change), their summary (tidy prep digest, dashboard Kit internals), owner decision
patterns -> standing rule proposals; approved rules answer matching decide asks (never deploy, data, prod or customer-visible).
Usage: & <kit>/skills/bossy/bossy.ps1 tidy prep · decide rules [-Propose] [-Approve <ids|all>] [-Revoke <id>] [-Json]
Inputs: .state/tasks/*.json, work/waves/*.json, work/launches/self-*.json, .state/decisions.jsonl. Outputs: outcomes.jsonl,
standing-rules.json, rules/standing-rules.local.md (approved rules only).
Exit codes: 0 ok · 1 problem · 2 usage (bossy.ps1 decide).
Sections: L13 outcomes · L78 summary · L106 patterns · L141 rules
#>

# ---- outcomes: one row per task state change; tracker-generic (task index, wave reports, launches, decisions)
$script:KitOutcomeKeys = @('kind', 'parent', 'area', 'agents', 'stage', 'mrs', 'qaRuns', 'qaFirstPass', 'qaFails', 'bugs', 'cameBack', 'localRounds', 'reviewFix', 'decisions', 'hPromoted', 'hClosed', 'spend')
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
  foreach ($x in $c.ix.Values) { if ($x.parent -and ("$($x.spec.kind)" -match '(?i)bug' -or "$($x.spec.title)" -match '^\[Bug\]')) { $c.bugs["$($x.parent)"] = [int]$c.bugs["$($x.parent)"] + 1 } }
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
    area = @(@($tr.mrs | Where-Object { $_ }) | ForEach-Object { ("$_" -split '!')[0] } | Sort-Object -Unique) -join ','
    agents = @($Ctx.agents[$t] | Where-Object { $_ }); stage = $stage; mrs = @($tr.mrs | Where-Object { $_ }).Count; qaRuns = $runs.Count
    qaFirstPass = $(if ($runs.Count) { [bool](& $clean $runs[0]) } else { $null }); qaFails = $fails; bugs = $bugs
    cameBack = [bool]($tr.reopenedAt -or $fails -or $bugs); localRounds = [int]$Ctx.local[$t]; reviewFix = [int]$Ctx.review[$t]
    decisions = [int]$Ctx.decisions[$t]; hPromoted = $(if ($tr.done) { Get-KitOutcomeHours $tr.created $tr.doneAt })
    hClosed = $(if ($stage -eq 'passed') { Get-KitOutcomeHours $tr.created $last.at }); spend = [int][math]::Round([double]$Ctx.spend[$t])
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
  $n = 0; $sig = { param($o) ($script:KitOutcomeKeys | ForEach-Object { "$(@(Get-KitMember $o $_ | ForEach-Object { $_ }) -join ',')" }) -join '|' }
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
  $rows = @($last.Values); $qa = @($rows | Where-Object { [int]$_.qaRuns -gt 0 })
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
  [pscustomobject]@{ days = $Days; n = $rows.Count; qaN = $qa.Count; firstPass = @($qa | Where-Object qaFirstPass).Count; cameBack = @($rows | Where-Object cameBack).Count
    p50Promoted = $(if ($hp.Count) { $hp[[int][math]::Floor(($hp.Count - 1) / 2)] }); areas = $areas; agents = $agents; causes = $causes }
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
