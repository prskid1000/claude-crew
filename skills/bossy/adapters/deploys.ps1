<#
deploys.ps1: the deploy batch of bossy E5, dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 deploy plan [-Env <target>] [-Json] [-Offline <fixture>] [-TimeoutSec <deploy.deployedTimeoutSec, 100>]   merged-not-deployed MRs per test env, trigger, window; per MR its source / test files and OUT-OF-AREA (crafty.ps1 scope)
  bossy.ps1 deploy request -Mrs <refs> -Run <run> [-Note ..] [-Json] [-Quiet: recorded only, no plan] (a summary; the full plan: crafty.ps1 dir -Agent <run> -Name deploy-request.json) · record -Env <target> [-Mrs <refs>] [-By ..] [-Note ..]
  bossy.ps1 deploy intest [-Apply] [-Quiet] [-Task <ids> | -Mrs <refs> | -Env <targets>] [-Days 14]   promoted tasks (tracked: done in -Days; the owner's in trackerLists; -Mrs: only their tasks; -Env: its deploy records' MRs; pages: deploys/intest-cursor-<env>.json) whose MRs are live on a test env -> inTest; last line: tasks checked, where from, a count per outcome
  bossy.ps1 deploy merge ...   adapters/deploy-merge.ps1
  bossy.ps1 deploy run -To <target> [-Repo <name>] [-Mrs <refs>] [-Decision <id>]   each deploys[] row of <target> through its kind's deploy verb (a person's word first)
  bossy.ps1 deploy schedule -Env <target>[,..] [-Mrs <refs> | -Repo <names>] [-After <consumer>=<producer>,..] [-Strict ..] [-Mode auto|parallel|serial] [-Decision <id>] [-Json]   the deploy's shape (parallel / serial / staggered / mixed) from p50 / p90 pipeline history (host + deploy-log timing), edges, deploy.schedule limits; saved deploys/schedule-<env>.json
  bossy.ps1 deploy watch -Env <target>[,..] [-Started <name>=<sha>,..] [-Finished <name>=success|failed,..] [-WaitMinutes <deploy.pipelineWaitMinutes>] [-Json]   one bounded poll loop over the schedule's started pipelines: START (a gate opened) · DONE (verify it) · FAILED (its dependents held) · WAIT; logs actual vs predicted
  bossy.ps1 deploy restart -Env <target>[,..] [-Service <a,b>] [-WaitMinutes 20] [-RecheckSeconds 120] [-Ungated] [-Agent <ids> (laneApk: phones free or leased by them only)]   an ssh deploy's services; ssh.busy re-checked on the host right before each restart: busy past -WaitMinutes = REFUSED (exit 3)
supervise -AutoFix calls Get-KitSuperviseFlagsDeploys: a done task live on a test env -> inTest (one background run); the plan cached 1 h (DEPLOY ASK; an env's newest deploy word no / wait: one muted held / waiting line).
Sections: L17 helpers · L108 intest · L314 deploy · L533 schedule · L774 restart · L858 supervise
Exit codes: 0 ok · 1 failed / unknown (restart) · 2 usage · 3 restart refused: the host stayed busy.
#>
#Requires -Version 7
. (Join-Path $PSScriptRoot '../../pokey/adapters/deployed-checks.ps1')   # Get-DeployPaths, Test-DeployTouched: one paths rule for plan, intest, deployed
# ---- helpers: test-env filter, MR refs
# not a test env: deploys[].production, else deploy.productionPattern on the name (no default: nothing is production by name); -Lanes: + laneApk
function Get-NoTestRx([Alias('Lane')][switch]$Lanes) { $rx = [string](Get-KitSetting 'deploy.productionPattern' ''); $n = @(@(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and ($(if ($null -ne $_.production) { $_.production } else { $rx -and $_.target -match $rx }) -or ($Lanes -and $_.laneApk)) } | ForEach-Object { [regex]::Escape($_.target) }); "^($($n -join '|'))$" }
# <alias>!<iid> -> <repo name>!<iid>
# a QA run's start: its run.json started (testy-retest, old testy-<nnnn>); legacy folder name yyyy-MM-dd[-HHmmss]-<label> (date only: midnight); $null when none
function Get-KitQaRunStart([string]$Run) {
  if ($Run -notmatch '^\d{4}-') { $st = try { (Read-KitText (Join-Path (Get-KitPath qa-runs) "$Run/run.json") | ConvertFrom-Json).started } catch { $null }; if ($st) { return ([datetimeoffset]$st).LocalDateTime }; return }
  if ($Run -match '^(\d{4}-\d{2}-\d{2})(?:-(\d{2})(\d{2})(\d{2}))?(?:-|$)') { [datetime]"$($Matches[1])T$(if ($Matches[2]) { "$($Matches[2]):$($Matches[3]):$($Matches[4])" } else { '00:00:00' })" } }
function Get-CanonMr([string]$m) {
  if ($m -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $m }
  $rp = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $Matches.r -or @($_.aliases) -contains $Matches.r } | Select-Object -First 1
  if ($rp) { "$($rp.name)!$($Matches.i)" } else { $m }
}
# MR -> target branch memo, seeded once from pokey's merged-MR cache (deployed-rows.json: a merged MR's target never changes)
function Get-KitMrTbMemo {
  if ($null -eq $script:KitMrTb) {
    $script:KitMrTb = @{}; $rc = try { Read-KitText (Join-Path (Get-KitPath cache) 'deployed-rows.json') | ConvertFrom-Json -AsHashtable } catch { $null }
    if ($rc -is [hashtable]) { foreach ($rk in @($rc.Keys -like 'mr|*')) { if ($tb = "$($rc[$rk].mr.target_branch)") { $script:KitMrTb[$rk.Substring(3)] = $tb } } }
  }
  $script:KitMrTb
}
# an MR's target branch, one host call per MR (the memo above); $null = unknown
function Get-MrTargetBranch([string]$Mr, $Fx) {
  $c = Get-CanonMr (ConvertTo-MrRef $Mr); if ($Fx) { return ((Get-KitMember $Fx.mrs $Mr) ?? (Get-KitMember $Fx.mrs $c)).targetBranch }
  $null = Get-KitMrTbMemo
  if ($script:KitMrTb.ContainsKey($c)) { return $script:KitMrTb[$c] }
  $rn, $iid = $c -split '!', 2; $v = try { (Invoke-HostVerb 'mr.get' @{ repo = (Get-HostProject (($rn -split '/')[-1]) -Raw); n = $iid }).target_branch } catch { $null }
  if ($v) { $script:KitMrTb[$c] = $v }; $v   # a failed lookup is retried next time
}
# the targets an MR feeds: its repo's deploys, less those whose from (branches) lacks its target branch or whose paths (globs)
# it never touched; one repo, two products. A deploy MR (into deploys[].branch) feeds that target only. A failed or cut
# lookup, or one past $Until, keeps the deploy (shown, never hidden)
function Get-MrDeployTargets([string]$Mr, $Repos, $Fx, $Until, [switch]$NoPaths) {   # -NoPaths: a probe row already said N/A for paths it never touched
  $c = Get-CanonMr (ConvertTo-MrRef $Mr); $rn, $iid = $c -split '!', 2; $rn = ($rn -split '/')[-1]
  $deps = @(@($Repos | Where-Object { $_.name -eq $rn } | Select-Object -First 1).deploys | Where-Object { $_.target })
  $filt = @($deps | Where-Object { $_.from -or @(Get-DeployPaths $_).Count }).Count
  if ((-not $filt -and @($deps | Where-Object branch).Count -lt 2) -or ($Until -and (Get-Date) -gt $Until)) { return @($deps.target | Select-Object -Unique) }
  $fm = if ($Fx) { (Get-KitMember $Fx.mrs $Mr) ?? (Get-KitMember $Fx.mrs $c) }
  $tb = Get-MrTargetBranch $Mr $Fx
  $own = @($deps | Where-Object { $_.branch -and $_.branch -eq $tb }); if ($own.Count) { return @($own.target | Select-Object -Unique) }
  if (-not $filt) { return @($deps.target | Select-Object -Unique) }
  $deps = @($deps | Where-Object { -not $_.from -or -not $tb -or $tb -in @($_.from) })
  $files = @(); $cut = $false
  if (-not $NoPaths -and @($deps | Where-Object { @(Get-DeployPaths $_).Count }).Count) {
    $ch = if ($Fx) { [pscustomobject]@{ changes = @($fm.paths | ForEach-Object { [pscustomobject]@{ new_path = $_ } }); overflow = $fm.overflow } } else { try { Invoke-HostVerb 'mr.changes' @{ repo = (Get-HostProject $rn -Raw); n = $iid } } catch { } }
    $files = @(@($ch.changes) | ForEach-Object { $_.new_path; $_.old_path } | Where-Object { $_ } | Select-Object -Unique)
    $cut = [bool]$ch.overflow -or @($ch.changes).Count -ge 100   # gitlab overflow, github's first page: the list is partial
  }
  @($deps | Where-Object {
      $cut -or -not $files.Count -or (Test-DeployTouched $_ $files)
    } | ForEach-Object target | Select-Object -Unique)
}
# MRs in a CI deploy's last green job (its commit holds the merge): mr|target -> detail; per repo one MR list and one git
# rev-list per deploy instead of one pokey.ps1 deployed probe per MR (229 MRs ran past 600 s); past $Until the rest is probed
function Get-DeployedByAncestry([Alias('Mr')][string[]]$Mrs, $Repos, [string[]]$Targets, [int]$Days = 14, [datetime]$Until = (Get-Date).AddSeconds((Get-KitParam 'deploy.ancestryBudgetSec'))) {
  $hit = @{}; $env:GIT_TERMINAL_PROMPT = '0'
  foreach ($rp in $Repos) {
    if ((Get-Date) -gt $Until) { break }
    $dir = [string]$rp.checkout
    $deps = @($rp.deploys | Where-Object { $_.target -in $Targets -and $_.branch -and $_.job -and (Get-KitDeployKind $_) -eq 'ci-job' })
    $want = @{}; foreach ($m in $Mrs) { $c = Get-CanonMr (ConvertTo-MrRef $m); if ($c -match "^$([regex]::Escape($rp.name))!(\d+)$") { $want[$Matches[1]] = $m } }
    if (-not $want.Count -or -not $deps.Count -or -not $dir -or -not (Test-Path $dir)) { continue }
    $p = Get-HostProject $rp.name -Raw; $shaOf = @{}; $tb = @{}; $got = @{}; $det = @{}
    $after = (Get-Date).AddDays( - ($Days + 1)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    for ($pg = 1; $pg -le 5 -and $shaOf.Count -lt $want.Count -and (Get-Date) -lt $Until; $pg++) {   # newest first; an MR not listed is probed as before
      $page = @(try { Invoke-HostVerb 'mr.list' @{ repo = $p; state = 'merged'; updated_after = $after; order_by = 'updated_at'; per_page = 100; page = $pg } } catch { }) | Where-Object { $_ }
      foreach ($x in $page) { $s = @($x.squash_commit_sha, $x.merge_commit_sha, $x.sha) | Where-Object { $_ } | Select-Object -First 1; if ($s -and $want.ContainsKey("$($x.iid)")) { $shaOf["$($x.iid)"] = $s; if ($x.target_branch) { $tb[$x.target_branch] = 1 } } }
      if ($page.Count -lt 100) { break }
    }
    if (-not $shaOf.Count) { continue }
    $null = Invoke-GitFetch $dir ([math]::Max(10, [int]($Until - (Get-Date)).TotalSeconds)) @(@($deps.branch) + @($tb.Keys) | Select-Object -Unique) 3>$null   # bounded: an unbounded fetch ate the probes' time (late: the old refs; the probes judge the rest)
    $known = @($shaOf.Values | Select-Object -Unique | git -C $dir cat-file --batch-check 2>$null | Where-Object { $_ -match '^\S+ commit ' } | ForEach-Object { ($_ -split ' ')[0] })
    if (-not $known.Count) { continue }
    foreach ($d in $deps) {
      if ((Get-Date) -gt $Until) { break }
      $base = $null
      foreach ($pl in @(try { Invoke-HostVerb 'ci.runs' @{ repo = $p; ref = $d.branch; per_page = 10 } } catch { }) | Where-Object { $_ -and $_.sha }) {
        $job = @(try { Invoke-HostVerb 'ci.jobs' @{ repo = $p; id = $pl.id } } catch { }) | Where-Object { $_.name -like $d.job } | Select-Object -First 1
        if ((ConvertTo-KitCiState "$($job.status)") -eq 'success') { $base = [string]$pl.sha; break }
      }
      if (-not $base) { continue }
      $out = @($known | git -C $dir rev-list --stdin "^$base" 2>$null); if ($LASTEXITCODE) { continue }   # commits the base lacks
      $miss = [Collections.Generic.HashSet[string]]::new([string[]]$out)
      foreach ($i in $shaOf.Keys) { $s = $shaOf[$i]; if ($s -in $known -and -not $miss.Contains($s)) { $key = "$($want[$i])|$($d.target)"; $got[$key] = 1 + [int]$got[$key]; $det[$key] = "$($d.job) finished on $($base.Substring(0, [math]::Min(8, $base.Length))), which holds $($s.Substring(0, [math]::Min(8, $s.Length)))" } }
    }
    # a target counts only when every deploy of this repo to it holds the MR (pokey checks each)
    foreach ($key in $got.Keys) { $tgt = ($key -split '\|', 2)[1]; if ($got[$key] -eq @($rp.deploys | Where-Object { $_.target -eq $tgt }).Count) { $hit[$key] = $det[$key] } }
  }
  $hit
}

# ---- intest: promoted tasks live on a test env -> inTest
# the probe's seconds: what -BudgetSec leaves, never under one -TimeoutSec round (a 15 s floor cut every probe once the tracker
# lookups had used the 50 s default: -TimeoutSec 240 ignored, 18 tasks unmoved 2026-11-25); no budget: 10 x -TimeoutSec (K31)
function Get-KitInTestProbeSec([int]$BudgetSec, [Alias('TimeoutSeconds')][int]$TimeoutSec, [datetime]$Start) { if ($BudgetSec -gt 0) { [math]::Max($TimeoutSec + 10.0, $BudgetSec - ((Get-Date) - $Start).TotalSeconds) } else { 10.0 * $TimeoutSec } }
# deployed promoted tasks -> inTest
function Invoke-MarkInTest {
param([switch]$Apply, [switch]$Quiet, [Alias('Item')][string[]]$Task = @(), [Alias('TimeoutSeconds')][int]$TimeoutSec = 100, [int]$Days = 14, [string[]]$FromMrs = @(), [Alias('BudgetSeconds')][int]$BudgetSec = -1, [string[]]$Env = @())   # not $Mrs: pwsh names ignore case ($mrs below)
$ErrorActionPreference = 'SilentlyContinue'
$Env = @(Split-KitList $Env | Select-Object -Unique); $dueH = [double](Get-KitParam 'deploy.inTestDueHours'); if ($dueH -le 0) { $dueH = 24 }
# -Env without -Mrs: the MRs its deploy records name (deploy.inTestDueHours back, else each target's newest record)
if ($Env.Count -and -not $FromMrs.Count) {
  $recs = @(Read-KitLog deploy-log -Since (Get-Date).AddDays(-$Days) | Where-Object { $_.event -eq 'record' -and "$($_.target)" -in $Env })
  $cut = (Get-Date).AddHours(-$dueH); $recent = @($recs | Where-Object { [datetime]$_.at -ge $cut })
  if (-not $recent.Count) { $recent = @($recs | Group-Object target | ForEach-Object { $_.Group[-1] }) }
  $FromMrs = @($recent | ForEach-Object { @($_.mrs) } | Where-Object { $_ } | Select-Object -Unique)
  if (-not $FromMrs.Count) { "mark-in-test: no deploy record for $($Env -join ', '): nothing to check (deploy record -Env <target> -Mrs <refs> first, or pass -Mrs)"; return }
}
# bounded (-Mrs / -Task 50 s, else 240 s: one page fits an agent shell): named tasks first, the rest after 60% of it waits for a re-run; progress per task on stderr
if ($BudgetSec -lt 0) { $BudgetSec = if ($FromMrs.Count -or $Task.Count) { [math]::Max(50, $TimeoutSec + 30) } else { [math]::Max(240, $TimeoutSec + 30) } }; $t0 = Get-Date
function Write-InTestProgress([string]$s) { if (-not $Quiet) { [Console]::Error.WriteLine("intest $([int]((Get-Date) - $t0).TotalSeconds)s $s") } }
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }
# -Mrs / -Env (what opsy deployed): the kit maps each MR to its task (tracking, else the tag in its title), never the caller; only those
# tasks are checked (2026-11-25: 188 candidates paged 13 a call). Owner 2026-11-23 (a task deployed by anyone moves): the full sweep (no
# -Mrs / -Env / -Task), supervise's every deploy.inTestSweepMinutes
$track = (Read-KitTracking).tasks; $mapped = @(); $scoped = [bool]$FromMrs.Count
foreach ($m in @($FromMrs | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })) {
  $c = Get-CanonMr (ConvertTo-MrRef $m); $rn, $iid = $c -split '!', 2
  $own = @($track.Keys | Where-Object { $_ -notmatch '!|\s' -and @($track[$_].mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) }) -contains $c })
  if (-not $own.Count -and ($rx = Get-KitTaskTagRx) -and "$(try { (Invoke-HostVerb 'mr.get' @{ repo = (Get-HostProject (($rn -split '/')[-1]) -Raw); n = $iid }).title } catch { })" -match $rx) { $own = @($Matches.id) }
  Out-Line "MAP   $c -> $(if ($own.Count) { $own -join ', ' } else { 'no task (untracked, no tag in its title)' })"; $mapped = @(@($mapped) + $own)
}

# candidates: tasks this kit promoted in $Days (deploy plan's window: older ones it no longer offers), plus list tasks assigned to
# the owner (tracker.owner); -Task: those; -Mrs / -Env: their tasks only
$cand = [ordered]@{}   # tracking: tasks/<id>.json (skills/bossy/STATE.md)
foreach ($id in @($track.Keys | Where-Object { -not $scoped -or $Task.Count })) { $o = $track[$id]; if ($Task.Count -or ($o.done -and $o.doneAt -and ((Get-Date) - [datetime]$o.doneAt).TotalDays -le $Days)) { $cand[$id] = @{ mrs = @($o.mrs); name = '' } } }
$nKit = $cand.Count; $nList = 0   # the summary says where the checked tasks came from
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
# the role merged work waits in: promoted, else (tracker.statuses.promoted null / []) review, else inProgress
$srcRole = @(@('promoted', 'review', 'inProgress') | Where-Object { -not (Test-TrackerStatusOff $_) })[0]
$lists = @(Get-KitValue 'trackerLists' @() | Where-Object { $_ -and -not $scoped } | Select-Object -Unique)
if ($lists.Count -and -not $ownerId -and -not $Task.Count) { Out-Line "SKIP  trackerLists: the owner is unknown (tracker.owner), so other people's tasks stay out" }
elseif ($lists.Count) {
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l $srcRole) } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name }; $nList++ } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes a,b as one string
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }
foreach ($k in @($mapped | Select-Object -Unique)) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @($track[$k].mrs | Where-Object { $_ }); name = '' }; $nKit++ } }
$first = @(@($mapped) + @($Task | ForEach-Object { "$_" -split '[,\s]+' }) | Where-Object { $_ -and $cand.Contains($_) } | Select-Object -Unique)
# pages: a cursor per env (-Env, else 'all' / 'mrs-<hash of the set>'; no -Apply: its own '-dry' one; -Task runs none): a sweep's order is
# fixed at its first page, each page goes on where the last stopped and never re-checks a done task (2026-11-25: check-time order re-ran
# the same 13 of 188); a new sweep when the last ended, the -Mrs set changed or it is deploy.inTestDueHours old
$scope = if ($scoped) { @($FromMrs | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) } | Sort-Object -Unique) -join ',' } else { 'all' }
$curKey = if ($Env.Count) { $Env -join '-' } elseif ($scoped) { 'mrs-' + "$(Get-KitHash $scope 'SHA1')".Substring(0, 8) } else { 'all' }
$cur = $null; $curF = if (-not $Task.Count) { Join-Path (Get-KitPath deploys -Create) "intest-cursor-$(ConvertTo-KitSlug "$curKey$(if (-not $Apply) { '-dry' })").json" }
if ($curF) { $cur = try { Get-Content -LiteralPath $curF -Raw | ConvertFrom-Json -AsHashtable } catch { $null } }
if ($cur -isnot [hashtable] -or "$($cur.scope)" -ne $scope -or -not @($cur.left).Count -or -not $cur.startedAt -or [datetime]$cur.startedAt -lt (Get-Date).AddHours(-$dueH)) {
  $cur = @{ scope = $scope; startedAt = (Get-Date).ToString('o'); page = 0; done = @(); left = @(@($first) + @($cand.Keys | Where-Object { $_ -notin $first } | Sort-Object @{ e = { try { [datetime]$track[$_].doneAt } catch { [datetime]::MinValue } }; Descending = $true }, @{ e = { $_ } })) }
}
$cur.page = [int]$cur.page + 1; $curDone = [Collections.Generic.HashSet[string]]::new([string[]]@($cur.done | Where-Object { $_ }))
$order = @(@($first) + @($cur.left) + @($cand.Keys) | Where-Object { $cand.Contains($_) -and -not $curDone.Contains($_) } | Select-Object -Unique)   # deployed first, then the sweep's order, then tasks new since
$first = @($first | Where-Object { -not $curDone.Contains($_) })
$c2 = [ordered]@{}; foreach ($k in $order) { $c2[$k] = $cand[$k] }; $cand = $c2

$productTargets = @(Get-KitValue 'productTargets' @()); $repos = @(Get-KitValue 'repos' @())
$recOf = @{}; $dlog = Get-KitPath deploy-log   # recorded deploys: mr|target
if (Test-Path $dlog) { foreach ($x in @(Get-Content $dlog | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })) { foreach ($m in @($x.mrs)) { $recOf["$(Get-CanonMr (ConvertTo-MrRef $m))|$($x.target)"] = 1 } } }
$pathMemo = @{}
function Get-MrPaths([string]$mr) {
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = Invoke-HostVerb 'mr.changes' @{ repo = (Get-HostProject $repo -Raw); n = $iid }
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

$gone = @(); $tally = [ordered]@{}; $ready = [Collections.Generic.List[object]]::new()   # outcome -> task ids (and why); tasks whose MRs are probed
function Add-Tally([string]$Outcome, [string]$Detail) { if (-not $tally.Contains($Outcome)) { $tally[$Outcome] = [Collections.Generic.List[string]]::new() }; $tally[$Outcome].Add($Detail) }
$nIt = 0; $chk = [Collections.Generic.List[string]]::new(); $unpr = [Collections.Generic.List[string]]::new()
foreach ($id in $cand.Keys) {
  # every page checks at least one task (a slow start never leaves the next page where this one began)
  $nIt++; if ($BudgetSec -and $id -notin $first -and $nIt -gt $first.Count + 1 -and ((Get-Date) - $t0).TotalSeconds -gt 0.6 * $BudgetSec) { Add-Tally 'not checked (time budget)' $id; continue }
  Write-InTestProgress "task $nIt/$($cand.Count) $id"; $chk.Add($id)
  # a task deleted in the tracker: skipped, reported, dropped from tracking; another task's failure never ends the batch
  $info = try { Get-TrackerTask $id } catch { if (Remove-KitGoneTask $id $_) { $gone += $id; Add-Tally 'deleted in the tracker' $id; Out-Line "GONE  $id  deleted in the tracker: skipped, no longer tracked" } else { Add-Tally 'unreadable' "$id`: $($_.Exception.Message)"; Out-Line "ERROR $id  tracker view failed: $($_.Exception.Message)" }; continue }
  if (-not $info) { Add-Tally 'unreadable' "$id`: the tracker returned nothing"; if ($Task.Count) { Out-Line "SKIP  $id  the tracker returned nothing" }; continue }
  if (-not (Test-TrackerStatus ([string]$info.status) $srcRole)) {   # never override a person
    Add-Tally $(if (Test-TrackerStatus ([string]$info.status) 'closed') { 'already closed' } elseif (Test-TrackerStatus ([string]$info.status) 'inTest') { 'already in test' } else { "now '$($info.status)'" }) $id
    if ($Task.Count) { Out-Line "SKIP  $id  status '$($info.status)', not $srcRole" }; continue }
  $name = if ($info.name) { $info.name } else { $cand[$id].name }
  $short = if ($name.Length -gt 70) { $name.Substring(0, 70) } else { $name }
  $mrs = @($cand[$id].mrs | Where-Object { $_ })
  if (-not $mrs.Count -and $KitConf.TrackerRepos) {
    $tag = "$($KitConf.TrackerTag)$id"
    foreach ($r in @($KitConf.TrackerRepos)) {
      $res = Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $r -Raw); search = $tag; state = 'merged'; per_page = 20 }
      foreach ($m in @($res)) { if ($m.iid -and ("$($m.title) $($m.source_branch)" -match [regex]::Escape($tag))) { $mrs += "$r!$($m.iid)" } }
    }
    $mrs = @($mrs | Select-Object -Unique)
  }
  if (-not $mrs.Count) { Add-Tally 'no MRs found' $id; Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $ready.Add([pscustomobject]@{ id = $id; short = $short; mrs = $mrs })
}
# ONE deployed probe for every task's MRs (pokey memoises the branch lookups per repo); rounds re-probe what its -TimeoutSec left
# unchecked until none is left or a round checks nothing (a hung host: K31). Per-MR calls in one budget left 4 of 10 tasks unchecked
$rowsOf = @{}; $whyOf = @{}; $round = 0; $probeEnd = (Get-Date).AddSeconds((Get-KitInTestProbeSec $BudgetSec $TimeoutSec $t0))
$todo = @($ready | ForEach-Object { $_.mrs } | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) } | Select-Object -Unique)
while ($todo.Count) {
  Write-InTestProgress "probe round $($round + 1): $($todo.Count) MR(s)"; $round++; $cap = [int][math]::Max(5.0, [math]::Min($TimeoutSec * 1.5 + 5.0, ($probeEnd - (Get-Date)).TotalSeconds))
  $si = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
  foreach ($x in @('-NoProfile', '-NonInteractive', '-File', $KitCmd.qa, 'deployed', '-Mrs', ($todo -join ','), '-Lines', '-Exclude', (Get-NoTestRx), '-TimeoutSec', $TimeoutSec)) { $si.ArgumentList.Add([string]$x) }
  $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($si); $so = $pr.StandardOutput.ReadToEndAsync(); $se = $pr.StandardError.ReadToEndAsync()
  $fin = $pr.WaitForExit($cap * 1000); if (-not $fin) { Stop-KitProcessTree $pr }; $null = $so.Wait(5000); $null = $se.Wait(1000)
  $got = [ordered]@{}; $skip = @{}; $lastMr = $null
  foreach ($ln in @("$($so.Result)" -split "`r?`n" | Where-Object { $_ -match '^\s*[\[{]' })) {
    foreach ($x in @(try { $ln | ConvertFrom-Json } catch { })) {
      if (-not $x.mr) { continue }; $k = Get-CanonMr (ConvertTo-MrRef $x.mr)
      if ($x.state -eq 'UNKNOWN' -and "$($x.detail)" -like 'not checked:*') { $skip[$k] = 1; continue }   # past -TimeoutSec: next round
      if (-not $got.Contains($k)) { $got[$k] = [Collections.Generic.List[object]]::new() }; $got[$k].Add($x); $lastMr = $k
    }
  }
  if (-not $fin -and $lastMr) { $got.Remove($lastMr) }   # cut mid-MR: its rows may be partial
  foreach ($k in $got.Keys) { $rowsOf[$k] = @($got[$k]) }
  if ($fin) { foreach ($k in @($todo | Where-Object { -not $got.Contains($_) -and -not $skip.ContainsKey($_) })) { $rowsOf[$k] = @() } }   # finished, no row: nothing on any test env
  $done = @($todo | Where-Object { $rowsOf.ContainsKey($_) }).Count; $todo = @($todo | Where-Object { -not $rowsOf.ContainsKey($_) })
  if ($todo.Count -and -not $done) {
    $err = ("$($se.Result)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    foreach ($k in $todo) { $whyOf[$k] = if (-not $fin) { "$k deployed check timed out after $cap s (deploy.deployedTimeoutSec, round $round)" } else { "$k not checked: round $round checked none of $($todo.Count) MR(s)$(if ($err) { " ($err)" })" } }
    break
  }
  if ($todo.Count -and (Get-Date) -gt $probeEnd) { foreach ($k in $todo) { $whyOf[$k] = "$k not checked: the probe used its $([int]($probeEnd - $t0).TotalSeconds) s budget in $round round(s); run deploy intest again" }; break }
}
if ($round -gt 1) { Out-Line "PROBE $(@($rowsOf.Keys).Count) MR(s) checked in $round round(s)$(if ($whyOf.Count) { ", $($whyOf.Count) left: $(@($whyOf.Keys) -join ', ')" })" }
$igMr = @(@((Read-KitState (Get-KitPath mr-ignore)).mrs.Keys) | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) })   # track ignore + closed: not the task's work
foreach ($rd in $ready) {
  $id = $rd.id; $short = $rd.short; $mrs = $rd.mrs
  $live = @(); $why = $null; $unprobed = $false
  foreach ($mr in $mrs) {
    $mk = Get-CanonMr (ConvertTo-MrRef $mr)
    if (-not $rowsOf.ContainsKey($mk)) { $why = if ($whyOf[$mk]) { $whyOf[$mk] } else { "$mr not checked" }; $unprobed = "$why" -match 'budget'; break }
    $rows = @($rowsOf[$mk])
    if ($mk -in $igMr -and @($rows | Where-Object { $_.state -eq 'NOT-MERGED' -and "$($_.detail)" -eq 'closed' }).Count) { continue }
    # another product's deploy branch proves nothing
    $ok = @($rows | Where-Object { $_.state -eq 'DEPLOYED' -and $_.target -notmatch (Get-NoTestRx -Lanes) })
    $missing = @(); $matched = $false; $need = @()
    # a deploy MR or a repo with deploys[].from / paths: every test target it feeds (the plan's set), a deploy MR's also by its record
    $rn = (((Get-CanonMr (ConvertTo-MrRef $mr)) -split '!')[0] -split '/')[-1]; $deps = @(@($repos | Where-Object name -eq $rn | Select-Object -First 1).deploys | Where-Object { $_.target -and $_.target -notmatch (Get-NoTestRx -Lanes) })
    $tb = if (@($deps | Where-Object branch).Count -ge 2 -or @($deps | Where-Object { $_.from -or @(Get-DeployPaths $_).Count }).Count) { Get-MrTargetBranch $mr $null }; $dm = $tb -and @($deps | Where-Object branch -eq $tb).Count
    $fed = if ($dm -or @($deps | Where-Object { $_.from -or @(Get-DeployPaths $_).Count }).Count) { @(Get-MrDeployTargets $mr $repos $null $null | Where-Object { $_ -in $deps.target }) } else { @() }
    $tst = @($rows | Where-Object { $_.target -notmatch (Get-NoTestRx -Lanes) })   # an MR with nothing for any test target (docs): nothing to wait for
    if (-not $fed.Count -and -not $ok.Count -and $tst.Count -and -not @($tst | Where-Object state -ne 'N/A').Count) { $live += "$mr n/a on every test target"; continue }
    if ($fed.Count) {
      $missing = @($fed | Where-Object { $t1 = $_; -not @($ok | Where-Object target -eq $t1).Count -and -not ($dm -and $recOf["$(Get-CanonMr (ConvertTo-MrRef $mr))|$t1"]) })
      $need = @($missing | ForEach-Object { "^$([regex]::Escape($_))$" })
      if (-not $missing.Count) { $live += "$mr on $($fed -join '+')"; continue }
      $matched = $true
    }
    $paths = if (-not $fed.Count) { Get-MrPaths $mr }
    foreach ($pt in @($productTargets | Where-Object { -not $fed.Count })) {
      if ($paths | Where-Object { $_ -match $pt.pathRegex }) { $matched = $true; if (-not ($ok | Where-Object { $_.target -match $pt.targetRegex })) { $missing += $pt.label; $need += $pt.targetRegex } }
    }
    if (-not $matched -and -not $ok.Count) { $missing += 'any test env' }
    if ($ok.Count -and -not $missing.Count) { $live += "$mr on $((($ok | ForEach-Object { $_.target }) -join '+'))"; continue }
    $r0 = $rows | Where-Object { $t0 = $_.target; $_.state -notin 'DEPLOYED', 'N/A' -and (-not $need.Count -or @($need | Where-Object { $t0 -match $_ }).Count) } | Select-Object -First 1
    $why = "$mr not live on: " + $(if ($missing.Count) { $missing -join ', ' } else { 'a test env' }) + $(if ($r0) { " ($($r0.state): $($r0.detail))" } else { '' }); break
  }
  if (-not $why -and -not $live.Count) { $why = "its only MRs are closed and ignored (bossy.ps1 track remove -Task $id -Mrs <ref>)" }
  # the probe's budget ran out: the next page starts with it, never 'not deployed yet'
  if ($unprobed) { Add-Tally 'not checked (time budget)' $id; $unpr.Add($id); continue }
  if ($why) { Add-Tally 'not deployed yet' $id; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Add-Tally 'would move to in test (no -Apply)' $id; Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    if ("$(Set-TrackerStatus $id 'inTest')" -match '^SKIPPED: (.*)') { Add-Tally $(if ($Matches[1] -match 'has no inTest status') { 'kept (its scope has no inTest status)' } else { 'kept (follows its subtasks)' }) $id; Out-Line "KEPT  $id  $($Matches[1]) | $short"; continue }
    $null = Set-TrackerKitComment $id 'comment-intest' ("In test: every MR is deployed on a test env (checked " + [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + " UTC): " + (@($live | ForEach-Object { $_ -replace '^\S+', { Format-KitMrLink $_.Value } }) -join '; ') + '.')   # full MR URLs (owner)
    Add-Tally 'moved to in test' $id; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Add-Tally 'blocked' "$id`: $($_.Exception.Message)"; Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
# the cursor: checked tasks done, the budget's leftovers lead the next page
$sw = $null
if ($curF) {
  $cur.done = @(@($curDone) + @($chk | Where-Object { $_ -notin $unpr }) | Select-Object -Unique); $cur.left = @(@($unpr) + @($order | Where-Object { $_ -notin $chk }) | Select-Object -Unique)
  try { Write-KitAtomic $curF ($cur | ConvertTo-Json -Compress -Depth 3) } catch { }
  $sw = @{ page = $cur.page; done = @($cur.done).Count; left = @($cur.left).Count; file = Split-Path $curF -Leaf }
}
if (-not $Quiet -or $gone.Count -or $tally.Contains('blocked') -or $tally.Contains('unreadable')) { Format-KitInTestSummary $cand.Count $nKit $nList $Days ([bool]($Task.Count -or $scoped)) $tally $sw }
}
# "mark-in-test: <n> tasks checked (<where from>): <n> <outcome>, ..."; ids where a person acts (blocked, unreadable, deleted); -Sweep: the cursor's page
function Format-KitInTestSummary([int]$Total, [int]$FromKit, [int]$FromLists, [int]$Days, [bool]$Named, $Tally, [hashtable]$Sweep) {
  $src = if ($Named) { 'the tasks named (-Task / -Mrs / -Env)' } else { @(if ($FromKit) { "$FromKit promoted by the kit in $Days d, subtasks included" }; if ($FromLists) { "$FromLists more assigned to you in trackerLists" }) -join ', ' }
  $order = @('moved to in test', 'would move to in test (no -Apply)', 'already closed', 'already in test') + @($Tally.Keys | Where-Object { $_ -like 'now *' }) + @('not deployed yet', 'no MRs found', 'not checked (time budget)', 'blocked', 'unreadable', 'deleted in the tracker')
  $parts = foreach ($k in $order | Where-Object { $Tally.Contains($_) }) { "$($Tally[$k].Count) $k$(if ($k -in 'blocked', 'unreadable', 'deleted in the tracker') { " ($($Tally[$k] -join '; '))" } elseif ($k -eq 'not checked (time budget)') { " ($(@($Tally[$k] | Select-Object -First 5) -join '; ')$(if ($Tally[$k].Count -gt 5) { "; +$($Tally[$k].Count - 5) more" }); run deploy intest again: the next page starts with them)" })" }
  $left = if ($Tally.Contains('not checked (time budget)')) { $Tally['not checked (time budget)'].Count } else { 0 }
  "mark-in-test: $(if ($left) { "$($Total - $left) of " })$Total task(s) checked$(if ($src) { " ($src)" }): $(if ($parts) { $parts -join ', ' } else { 'nothing to do' })"
  if ($Sweep -and $Sweep.left) { "PAGE  $($Sweep.left) task(s) left in this sweep (page $($Sweep.page), $($Sweep.done) done; cursor $($Sweep.file)): run deploy intest again (same flags): it goes on with them" }
  elseif ($left) { "PAGE  $left task(s) left by the time budget: run deploy intest again (same flags): it resumes with them" }
  elseif ($Sweep -and $Sweep.page -gt 1) { "SWEEP done in $($Sweep.page) page(s): $($Sweep.done) task(s) checked" }
}

# ---- deploy: plan, request, record
function Invoke-Deploy {  param([Parameter(Position = 0)][ValidateSet('plan', 'request', 'record', 'merge', 'intest', 'restart', 'run', 'schedule', 'watch')][string]$Action = 'plan',
    [string]$Env, [string[]]$Mrs = @(), [string]$Run, [string]$Note, [string]$By = 'owner', [switch]$Json, [string]$Offline, [int]$Days = 14,
    [object]$Repo, [string]$To, [string]$From, [string]$Commit, [string]$Check, [switch]$Push, [switch]$Mr, [string]$Decision, [int]$WaitMinutes = 45, [int]$History = 300,
    [string]$Service, [int]$RecheckSeconds = 120, [switch]$Ungated, [string]$Agent,
    [string[]]$After = @(), [string[]]$Strict = @(), [string]$Mode, [string[]]$Started = @(), [string[]]$Finished = @(),
    [switch]$Apply, [switch]$Quiet, [Alias('Item')][string[]]$Task = @(), [Alias('TimeoutSeconds')][int]$TimeoutSec = (Get-KitParam 'deploy.deployedTimeoutSec'))
  if ($Action -in 'schedule', 'watch') {
    $envs = @(Split-KitList @($Env) | Select-Object -Unique); if (-not $envs.Count) { "usage: deploy schedule -Env <target>[,..] [-Mrs <refs> | -Repo <names>] [-After <consumer>=<producer>,..] [-Strict ..] [-Mode auto|parallel|serial] [-Decision <id>] [-Json] · deploy watch -Env <target>[,..] [-Started <name>=<sha>,..] [-Finished <name>=success|failed,..] [-WaitMinutes]"; exit 2 }
    if ($Action -eq 'schedule') { Invoke-DeploySchedule $envs @(Split-KitList $Mrs) @(Split-KitList @($Repo)) @(Split-KitList $After) @(Split-KitList $Strict) $Mode $Decision -Json:$Json; return }
    Invoke-DeployWatch $envs @(Split-KitList $Started) @(Split-KitList $Finished) $(if ($PSBoundParameters.ContainsKey('WaitMinutes')) { $WaitMinutes } else { Get-KitParam 'deploy.pipelineWaitMinutes' }) -Json:$Json; return
  }
  if ($Action -eq 'restart') {
    if (-not $Env) { 'usage: deploy restart -Env <target>[,<target>..] [-Service <a,b>] [-WaitMinutes 20] [-Ungated] [-Agent <ids>]'; exit 2 }
    Invoke-DeployRestart @(Split-KitList @($Env)) $Service $(if ($PSBoundParameters.ContainsKey('WaitMinutes')) { $WaitMinutes } else { 20 }) $RecheckSeconds -Ungated:$Ungated -Agent $Agent; return
  }
  if ($Action -eq 'merge' -and (-not $Repo -or -not $To)) { throw "deploy merge: -$(if (-not $Repo) { 'Repo' } else { 'To' }) missing. Usage: bossy.ps1 deploy merge -Repo <checkout> -To <env|deploy branch> [-From <branch>] [-Commit <sha>] -Mr [-Mrs <refs>] [-Decision <id>] (tag deploys: -Push)" }
  if ($Action -eq 'merge') { Invoke-DeployMerge -Repo "$Repo" -To $To -From $From -Commit $Commit -Check $Check -Push:$Push -Mr:$Mr -Mrs $Mrs -Decision $Decision -WaitMinutes $(if ($PSBoundParameters.ContainsKey('WaitMinutes')) { $WaitMinutes } else { 8 }) -History $History; return }   # 8 min: one call fits an agent shell (10 min); a re-run resumes the open MR
  if ($Action -eq 'run') { if (-not $To) { 'usage: deploy run -To <target> [-Repo <name>] [-Mrs <refs>] [-Decision <id> -Agent <you>]'; exit 2 }; Invoke-DeployRun $To "$Repo" @(Split-KitList $Mrs) $Decision $Agent; return }
  if ($Action -eq 'intest') { Invoke-MarkInTest -Apply:$Apply -Quiet:$Quiet -Task $Task -Days $Days -FromMrs @(Split-KitList $Mrs) -Env @(Split-KitList @($Env)) -TimeoutSec $TimeoutSec; return }
  $Mrs = @(Split-KitList $Mrs)
  $dd = Get-KitPath deploys -Create; $pf = Join-Path $dd 'pending.json'; $log = Get-KitPath deploy-log -Create
  $fx = if ($Offline) { Get-Content $Offline -Raw | ConvertFrom-Json } else { $null }
  $pendEdit = { param($b) Invoke-KitLocked $pf { $p = if (Test-Path $pf) { Get-Content $pf -Raw | ConvertFrom-Json } else { [pscustomobject]@{ requests = @() } }; & $b $p; $p | ConvertTo-Json -Depth 5 | Set-Content $pf -Encoding utf8 } }   # change pending.json under its lock
  if ($Action -eq 'request') {
    if (-not $Mrs.Count) { 'usage: deploy request -Mrs <repo>!<iid>,... -Run <run> [-Note ..]'; exit 2 }
    $Mrs = @($Mrs | ForEach-Object { ConvertTo-MrRef $_ })
    # a dev-env change (its task closes on merge: track add -OnMerged closed, crafty ship.md) asks for no deploy
    $canon = { param($m) Get-CanonMr (ConvertTo-MrRef "$m") }   # a stored ref keeps its group path
    $dv = @(@((Read-KitTracking).tasks.Values) | Where-Object { $_ -and (@($_.onMerged) -join ',') -eq 'closed' } | ForEach-Object { @($_.mrs) | ForEach-Object { & $canon $_ } })
    $noDep = @($Mrs | Where-Object { (& $canon $_) -in $dv }); $Mrs = @($Mrs | Where-Object { $_ -notin $noDep })
    if ($noDep.Count -and -not $Json) { "no deploy request for $($noDep -join ', '): its task closes on merge (a dev-env change)" }
    if (-not $Mrs.Count) { if ($Json) { ConvertTo-Json @([ordered]@{ trigger = 'none'; mrs = @(); devEnv = @($noDep) }) -Compress -Depth 4 }; return }
    & $pendEdit { param($p) $p.requests = @(@($p.requests) + [pscustomobject]@{ at = (Get-Date).ToString('s'); run = $Run; mrs = $Mrs; note = $Note }) }
    if (-not $Json) { "requested a deploy for $($Mrs -join ', ') ($Run)" }
    # -Quiet (buildy.js deploy step): recorded only; the plan probes the host for minutes (the step's calls ran up to 594 s, 37 of 276 failed): supervise plans, cached
    if ($Quiet) { if ($Json) { ConvertTo-Json @([ordered]@{ trigger = ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower(); mrs = @($Mrs) }) -Compress -Depth 4 }; return }
  }
  if ($Action -eq 'record') {
    if (-not $Env) { 'usage: deploy record -Env <target>[,<target>..] [-Mrs ..] [-By ..] [-Note ..]'; exit 2 }
    # one line per repos[].deploys target: a name the plan does not know (a host group) never clears its batch
    $known = @(@(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | ForEach-Object target | Where-Object { $_ } | Select-Object -Unique)
    $envs = @(Split-KitList @($Env) | Select-Object -Unique); $odd = @($envs | Where-Object { $_ -notin $known })
    if (-not $envs.Count) { 'usage: deploy record -Env <target>[,<target>..] [-Mrs ..] [-By ..] [-Note ..]'; exit 2 }
    if ($odd.Count) { "deploy record: unknown target(s) $($odd -join ', '): use the repos[].deploys names ($(if ($known) { $known -join ', ' } else { 'none configured' })); nothing recorded"; exit 2 }
    foreach ($e in $envs) { Write-KitLog deploy-log record ([ordered]@{ target = $e; mrs = $Mrs; by = $By; note = $Note }) }; Add-KitParamTrigger deploy   # learned params re-evaluated
    $Env = $envs -join ', '
    $bgPlan = Join-Path (Get-KitPath background) (ConvertTo-KitSlug 'bossy.ps1 deploy plan')   # supervise's last plan predates this deploy: no second ask, no stale "deploy ready"
    Remove-Item -LiteralPath (Join-Path (Get-KitPath deploys) 'plan-cache.json') -ErrorAction SilentlyContinue
    if (-not (Test-KitPid ($r = try { Get-Content -LiteralPath "$bgPlan.json" -Raw | ConvertFrom-Json } catch { $null }).pid $r.start)) { Remove-Item -LiteralPath "$bgPlan.json", "$bgPlan.out", "$bgPlan.err" -ErrorAction SilentlyContinue }   # a running one is left whole
    $done = @($Mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) })
    $hit = @(@(Get-KitValue 'repos' @()) | Where-Object { @(@($_.deploys) | Where-Object { $_.target -in $envs }).Count } | ForEach-Object { "$($_.name)" })   # no -Mrs: the recorded targets' repos only
    if (Test-Path $pf) { & $pendEdit { param($p) foreach ($q in @($p.requests)) { $q.mrs = @(@($q.mrs) | Where-Object { if ($done.Count) { (Get-CanonMr (ConvertTo-MrRef $_)) -notin $done } else { (((ConvertTo-MrRef $_) -split '!')[0] -split '/')[-1] -notin $hit } }) }; $p.requests = @(@($p.requests) | Where-Object { @($_.mrs).Count }) } }
    "recorded the deploy of $Env$(if ($Mrs.Count) { " ($($Mrs -join ', '))" }). Next: once pokey.ps1 deployed shows them live, bossy.ps1 deploy intest -Apply"
    return
  }
  $repos = @(Get-KitValue 'repos' @())
  $targets = @($repos | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and -not $_.laneApk -and $_.target -notmatch (Get-NoTestRx) } | ForEach-Object target | Select-Object -Unique)
  if ($Env) { $targets = @($targets | Where-Object { $_ -eq $Env }) }
  # an MR is checked only against the deploys of its own repo (tOf: no lookup); tgtOf: the ones it feeds (deploys[].from / paths)
  $tOf = @{}; foreach ($x in $repos) { $tOf[[string]$x.name] = @($x.deploys | ForEach-Object target) }
  $repoOf = { param($m) ((ConvertTo-MrRef $m) -split '!')[0] -split '/' | Select-Object -Last 1 }
  $fedOf = @{}; $tgtOf = { param($m) if (-not $fedOf.ContainsKey($m)) { $fedOf[$m] = @(Get-MrDeployTargets $m $repos $fx $until) }; $fedOf[$m] }
  if ($Action -eq 'request') { $targets = @($targets | Where-Object { $t = $_; @($Mrs | Where-Object { $t -in @(& $tgtOf $_) }).Count }) }
  $taskOf = @{}; $cand = [ordered]@{}; $idle = 0
  $tr = Read-KitTracking
  foreach ($t in $tr.tasks.Values) {
    if ($t.done -and (-not $t.doneAt -or ((Get-Date) - [datetime]$t.doneAt).TotalDays -gt $Days)) { continue }   # no doneAt: an old record
    $act = @(@($t.created, $t.reopenedAt, $t.allMergedAt, $t.mergedSeenAt) | ForEach-Object { try { [datetime]$_ } catch {} } | Sort-Object)[-1]
    if (-not $t.done -and $act -and ((Get-Date) - $act).TotalDays -gt $Days) { $idle++; continue }   # open, untouched for -Days: not this plan's (94 MRs of October filled it)
    foreach ($m in @($t.mrs | Where-Object { $_ })) {   # a tracked task without MRs yet: @($null) crashed the plan
      # live on every test env of its repo (supervise liveOn): nothing to deploy, no lookup
      $need = @($tOf[(& $repoOf $m)] | Where-Object { $_ -in $targets })
      if ($need.Count -and -not @($need | Where-Object { $_ -notin @($t.liveOn) }).Count) { continue }
      $taskOf[$m] = $t.task; $cand[$m] = 'tracked'
    }
  }
  $pend = @()   # a request older than -Days expires (the plan's window; deploys by CI never record it)
  $stale = { param($q) $q.at -and $(try { ((Get-Date) - [datetime]$q.at).TotalDays -gt $Days } catch { $false }) }   # an unreadable date stays
  if (Test-Path $pf) { $pend = @((Get-Content $pf -Raw | ConvertFrom-Json).requests); if (@($pend | Where-Object { & $stale $_ }).Count) { & $pendEdit { param($p) $p.requests = @(@($p.requests) | Where-Object { -not (& $stale $_) }) }; $pend = @($pend | Where-Object { -not (& $stale $_) }) } }
  foreach ($q in $pend) { foreach ($m in @($q.mrs | Where-Object { $_ })) { $cand[$m] = "requested by $($q.run)" } }
  foreach ($m in $Mrs) { $cand[$m] = "requested by $Run" }
  # no network = UNKNOWN, no hang
  $rows = @{}; $failOf = @{}   # target -> why its check gave no rows (timeout, crash): that target is UNKNOWN, the others stand
  $rowsOf = { param($m) if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] } }
  if ($fx) { foreach ($m in $cand.Keys) { $rows[$m] = @((Get-KitMember $fx.mrs $m).rows) } }
  elseif ($cand.Count) {
    $lim = [math]::Max(2, $TimeoutSec); $t0 = Get-Date   # 100 (default): a foreground call ends under a 120 s tool timeout; supervise passes deploy.planTimeoutSec
    $until = $t0.AddSeconds([math]::Max($lim * 0.9, $lim - 10))   # one deadline for all; the rest of the plan fits in the remainder
    $anc = Get-DeployedByAncestry @($cand.Keys) $repos $targets $Days $t0.AddSeconds($lim / 3)
    foreach ($kv in $anc.GetEnumerator()) { $km, $kt = $kv.Key -split '\|', 2; if (-not $rows.ContainsKey($km)) { $rows[$km] = @() }; $rows[$km] += [pscustomobject]@{ mr = $km; target = $kt; state = 'DEPLOYED'; detail = $kv.Value } }
    # one pokey.ps1 deployed per repo (its MR and change-list calls once for all targets), each MR on the targets it still needs,
    # all at once with the same deadline: 5 env processes refetched every MR and timed out (94 MRs on one env)
    $grp = [ordered]@{}; foreach ($m in $cand.Keys) {
      # its repo's targets, not the ones it feeds: that lookup is 1-2 host calls per MR, serial (144 MRs: 240 s, the probes got -TimeoutSec 1); the batch below drops a target it does not feed
      $need = @($tOf[(& $repoOf $m)] | Where-Object { $_ -in $targets -and -not $anc.ContainsKey("$m|$_") } | Sort-Object -Unique); if (-not $need.Count) { continue }
      $gk = "$(& $repoOf $m)|$($need -join ',')"; if (-not $grp.Contains($gk)) { $grp[$gk] = [pscustomobject]@{ t = $need -join ','; m = [Collections.Generic.List[string]]::new() } }; $grp[$gk].m.Add($m)
    }
    # a process checks its MRs one by one (2+ host calls each): slices of <= $per run side by side, at most 16 processes
    $nm = @($grp.Values | ForEach-Object { $_.m.Count } | Measure-Object -Sum).Sum; $per = [math]::Max(4, [math]::Ceiling($nm / 16))
    $grp = @(foreach ($g in $grp.Values) { for ($i = 0; $i -lt $g.m.Count; $i += $per) { [pscustomobject]@{ t = $g.t; m = @($g.m)[$i..([math]::Min($i + $per, $g.m.Count) - 1)] } } })
    if (($until - (Get-Date)).TotalSeconds -lt $lim / 2) { $until = (Get-Date).AddSeconds($lim / 2) }   # the ancestry step ran late: probes still get half (they got -TimeoutSec 1)
    # probes as in a supervise beat: pokey's kept answers (merged MRs, settled rows) and one shared host answer per call (a plan ran past 120 s)
    # an owner's plan keeps a DEPLOYED row deploy.planKeepHours only (a rollback shows); env restored in finally
    $ownBeat = -not $env:KIT_API_BEAT; $keep0 = $env:KIT_PARAM_DEPLOY_DEPLOYEDKEEPHOURS
    if ($ownBeat) { $env:KIT_API_BEAT = "plan-$PID-$([DateTime]::UtcNow.Ticks)"; if (-not $keep0) { $env:KIT_PARAM_DEPLOY_DEPLOYEDKEEPHOURS = "$(Get-KitParam 'deploy.planKeepHours')" } }
    try {
    $runs = @(foreach ($g in $grp) {
        $t = $g.t; $tm = @($g.m)
        $si = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        foreach ($x in @('-NoProfile', '-NonInteractive', '-File', $KitCmd.qa, 'deployed', '-Mrs', ($tm -join ','), '-Target', $t, '-Lines', '-Exclude', (Get-NoTestRx), '-TimeoutSec', [math]::Max(1, [int](($until - (Get-Date)).TotalSeconds) - 2))) { $si.ArgumentList.Add([string]$x) }
        $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
        $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $p = [Diagnostics.Process]::Start($si); [pscustomobject]@{ t = $t; m = $tm; p = $p; out = [Collections.Generic.List[string]]::new(); rl = $p.StandardOutput.ReadLineAsync(); se = $p.StandardError.ReadToEndAsync() }
      })
    if (-not $Json) { [Console]::Error.WriteLine("deploy plan: $($anc.Count) MR x env in a green deploy job; probing the rest in $($runs.Count) repo run(s) in parallel (max $lim s each) ...") }
    # a row to act on (NOT-MERGED / NOT-DEPLOYED) is printed (stderr) as it comes, the rest only counted (a 200-row wall hid them)
    $script:probeCount = [ordered]@{}
    $take = { param($q, [int]$ms) while ($q.rl -and $q.rl.Wait($ms)) { $ln = $q.rl.Result; if ($null -eq $ln) { $q.rl = $null; break }; $q.out.Add($ln); $q.rl = $q.p.StandardOutput.ReadLineAsync()
        if (-not $Json -and $ln -match '^\s*\{') { try { $x = $ln | ConvertFrom-Json; $script:probeCount["$($x.state)"] = 1 + [int]$script:probeCount["$($x.state)"]; if ($x.state -in 'NOT-MERGED', 'NOT-DEPLOYED') { [Console]::Error.WriteLine("  $($x.mr) @ $($x.target): $($x.state) $($x.detail)") } } catch {} } } }
    # an exited run is done once drained: a grandchild (git, ssh) holding its stdout kept the plan waiting to the deadline (45 s idle)
    while (@($runs | Where-Object rl).Count -and (Get-Date) -lt $until) { foreach ($q in $runs) { & $take $q 0; if ($q.rl -and $q.p.HasExited) { & $take $q 300; $q.rl = $null } }; Start-Sleep -Milliseconds (Get-KitParam 'deploy.planPollMs') }
    foreach ($q in $runs) {
      $fin = $q.p.WaitForExit([int][math]::Max(1000.0, ($until - (Get-Date)).TotalMilliseconds)); if (-not $fin) { Stop-KitProcessTree $q.p }
      & $take $q 2000; $null = $q.se.Wait($(if ($fin) { 300 } else { 5000 })); $txt = $q.out -join "`n"   # exited: stderr held open by a grandchild cost 5 s a run
      $parsed = @($txt -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.mr })   # -Lines: one row per line
      $qts = @($q.t -split ','); $fw = $null
      if (-not $fin -or ($parsed.Count -and $q.p.ExitCode -notin 0, 1)) {   # a timeout or crash keeps the rows already checked
        $fw = "pokey.ps1 deployed $(if ($fin) { "exit $($q.p.ExitCode)" } else { "timed out after $lim s" }) on $($q.t)"
      }
      elseif (-not $parsed.Count -or $q.p.ExitCode -notin 0, 1) { $fw = "pokey.ps1 deployed exit $($q.p.ExitCode) on $($q.t): $(("$txt$(if ($q.se.IsCompleted) { $q.se.Result })" -split "`n" | Where-Object { $_ } | Select-Object -First 1))" }
      if ($fw) { foreach ($y in $qts) { $failOf[$y] = $fw } }
      $parsed = @(foreach ($x in $parsed) { if ($x.target -in $qts) { $x } else { foreach ($y in $qts) { [pscustomobject]@{ mr = $x.mr; target = $y; state = $x.state; detail = $x.detail } } } })   # a row for no one target (NOT-MERGED, the deadline): one per target
      $seen = @($parsed | ForEach-Object { "$(Get-CanonMr $_.mr)|$($_.target)" })
      $parsed += @(foreach ($y in $qts) { $q.m | Where-Object { "$(Get-CanonMr $_)|$y" -notin $seen } | ForEach-Object { [pscustomobject]@{ mr = $_; target = $y; state = 'UNKNOWN'; detail = "not checked: $(if ($fw) { $fw } else { "no row from pokey.ps1 deployed on $y" })" } } })   # an MR x target without a row never vanishes: UNKNOWN each
      foreach ($x in @($parsed | ForEach-Object { $_ })) { if ($x.mr) { if (-not $rows.ContainsKey($x.mr)) { $rows[$x.mr] = @() }; $rows[$x.mr] += $x; if ($x.branch) { $null = Get-KitMrTbMemo; $script:KitMrTb[(Get-CanonMr $x.mr)] = $x.branch } } }   # Get-MrTargetBranch's memo
    }
    } finally { if ($ownBeat) { Remove-Item -LiteralPath (Join-Path (Get-KitPath cache) "api-memo/$env:KIT_API_BEAT") -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Env:KIT_API_BEAT; $env:KIT_PARAM_DEPLOY_DEPLOYEDKEEPHOURS = $keep0 } }   # walk-ok: this plan's folder
    if (-not $Json -and $runs.Count) { [Console]::Error.WriteLine("deploy plan probes: $((@($script:probeCount.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key) $($_.Value)" }) + @(if ($anc.Count) { "DEPLOYED (green job) $($anc.Count)" })) -join ' · ')") }
  }
  # a deploy MR ships work, it is none: out of the batch (opsy 2026-11-21: merged deploy MRs listed NOT-DEPLOYED) = into a deploys[].branch
  # from a deploys[].from / branch or a deploy source (Test-KitDeployMr: protected, deploy/*; a hotfix branch into it is work); never a -Mrs one; no host call (memo, rows)
  $named = @($Mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) })
  $depMrs = @(foreach ($m in @($cand.Keys)) {
      $rp = @($repos | Where-Object { $_.name -eq (& $repoOf $m) } | Select-Object -First 1)[0]; $rws = @(& $rowsOf $m | Where-Object { $_ -and $_.state -in 'NOT-DEPLOYED', 'MANUAL' })
      if ((Get-CanonMr (ConvertTo-MrRef $m)) -in $named -or -not $rws.Count) { continue }
      $tb = @($rws.branch | Where-Object { $_ })[0]; if (-not $tb) { $tb = if ($fx) { Get-MrTargetBranch $m $fx } else { (Get-KitMrTbMemo)[(Get-CanonMr (ConvertTo-MrRef $m))] } }
      $sb = @($rws.source | Where-Object { $_ })[0]
      if ($tb -and $tb -in @($rp.deploys.branch) -and $sb -and ((Test-KitDeployMr $rp.name $sb '') -or $sb -in @(@($rp.deploys) | ForEach-Object { @($_.from) + @($_.branch) }))) { $m } })
  foreach ($m in $depMrs) { $cand.Remove($m) }
  if ($depMrs.Count -and -not $Json) { [Console]::Error.WriteLine("deploy plan: $($depMrs.Count) deploy MR(s) left out (merged into a deploy branch, not work): $($depMrs -join ', ')") }
  $trigger = ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower()
  $win = if ($env:KIT_PARAM_DEPLOY_MININTERVALHOURS) { Get-KitParam 'deploy.minIntervalHours' } else { Get-KitSetting 'deploy.minIntervalHours' (Get-KitParam 'deploy.minIntervalHours') }   # env > kit.local.json (a per-target object too)
  $winScope = ([string](Get-KitSetting 'deploy.minIntervalScope' 'repo')).ToLower()
  $winOf = { param($t) if ($win -is [psobject] -and (Get-KitProps $win).Name -contains $t) { [double](Get-KitMember $win $t) } elseif ($win -is [psobject] -and (Get-KitProps $win).Name -contains 'default') { [double]$win.default } elseif ($win -is [psobject]) { [double](Get-KitParam 'deploy.minIntervalHours') } else { [double]$win } }
  $logged = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $hostErr = $null
  $recOf = @{}; foreach ($x in $logged) { foreach ($m in @($x.mrs)) { $recOf["$(Get-CanonMr (ConvertTo-MrRef $m))|$($x.target)"] = 1 } }   # MANUAL (no check can see it): a recorded deploy is the proof
  $feeds = @{}   # no deadline here: a cut lookup would batch an MR for a target it never feeds
  $plan = foreach ($t in $targets) {
    $batch = @(foreach ($m in @($cand.Keys)) { foreach ($r in @($(if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] }) | Where-Object { $_.target -eq $t -and ($_.state -eq 'NOT-DEPLOYED' -or ($_.state -eq 'MANUAL' -and -not $recOf["$(Get-CanonMr $m)|$t"])) })) { if (-not $feeds.ContainsKey($m)) { $feeds[$m] = @(Get-MrDeployTargets $m $repos $fx $null -NoPaths:(-not $fx)) }; if ($t -notin $feeds[$m]) { continue }; [pscustomobject]@{ mr = $m; task = $taskOf[$m]; state = $r.state; detail = $r.detail; why = $cand[$m]; mrState = "$($r.mrState)"; mergedAt = $(if ($r.mergedAt -is [datetime]) { ([datetimeoffset]$r.mergedAt).ToString('yyyy-MM-ddTHH:mm:sszzz') } else { "$($r.mergedAt)" }) } } })   # feeds-lookup only for a not-deployed row; mrState: the host's mr.get (pokey row), never inferred
    $last = $null; $src = ''; $lastBy = @{}; $envAt = $null   # lastBy: each repo's own last deploy here; envAt: one of no known repo (CI fixture)
    foreach ($l in @($logged | Where-Object { $_.target -eq $t })) { $la = [datetime]$l.at; if (-not $last -or $la -gt $last) { $last = $la; $src = "kit log ($($l.by))" }
      if (-not @($l.mrs | Where-Object { $_ }).Count -and (-not $envAt -or $la -gt $envAt)) { $envAt = $la }   # a record without -Mrs: every repo's window
      foreach ($lr in @(@($l.mrs) | ForEach-Object { & $repoOf $_ } | Select-Object -Unique)) { if (-not $lastBy[$lr] -or $la -gt $lastBy[$lr]) { $lastBy[$lr] = $la } } }
    $running = Test-KitDeployRunning $t
    if ($fx) { if ((Get-KitMember $fx.lastCi $t)) { $ci = [datetime](Get-KitMember $fx.lastCi $t); if (-not $envAt -or $ci -gt $envAt) { $envAt = $ci }; if (-not $last -or $ci -gt $last) { $last = $ci; $src = 'CI' } } }
    else {
      # each deploy row's kind: lastDeploy (@{ at; source }) and isRunning (a deploy in flight); a kind without them adds nothing
      foreach ($r in $repos) { foreach ($d in @($r.deploys | Where-Object { $_.target -eq $t -and ((Get-KitDeployKind $_) -ne 'ci-job' -or ($_.branch -and $_.job)) })) {
          $ka = @{ repo = (Get-HostProject $r.name -Raw); name = "$($r.name)" }
          try {
            if (Invoke-KitDeployKind $d 'isRunning' $ka) { $running = $true }
            $ld = Invoke-KitDeployKind $d 'lastDeploy' $ka; if ($ld.at -and (-not $last -or [datetime]$ld.at -gt $last)) { $last = [datetime]$ld.at; $src = "$($ld.source)" }
            if ($ld.at -and (-not $lastBy["$($r.name)"] -or [datetime]$ld.at -gt $lastBy["$($r.name)"])) { $lastBy["$($r.name)"] = [datetime]$ld.at }
          } catch { if (-not $hostErr) { $hostErr = "$($_.Exception.Message)" } }
        } }
    }
    $h = & $winOf $t
    # deploy.minIntervalScope repo (default): a batch repo's own last deploy here counts, another repo's not; the batch waits only while every repo does
    $ref = if ($winScope -eq 'env' -or -not $batch.Count) { $last } else {
      $rl = @(@($batch | ForEach-Object { & $repoOf $_.mr } | Select-Object -Unique) | ForEach-Object { $x = $lastBy[$_]; if ($envAt -and (-not $x -or $envAt -gt $x)) { $x = $envAt }; $x })
      if (@($rl | Where-Object { -not $_ }).Count) { $null } else { @($rl | Sort-Object)[0] } }
    $next = if ($ref) { $ref.AddHours($h) } else { $null }
    $mine = @($cand.Keys | Where-Object { $t -in $tOf[(& $repoOf $_)] })   # its repo deploys there (a feeds lookup per MR here cost 40 s): only for UNKNOWN reasons
    $unk = @(foreach ($m in $mine) { @(& $rowsOf $m) | Where-Object { $_ -and $_.target -eq $t -and $_.state -eq 'UNKNOWN' } | Where-Object { if (-not $feeds.ContainsKey($m)) { $feeds[$m] = @(Get-MrDeployTargets $m $repos $fx $null -NoPaths:(-not $fx)) }; $t -in $feeds[$m] } | ForEach-Object { "${m}: $($_.detail)" } })   # an UNKNOWN for a target it never feeds is no reason
    $why = if ($unk.Count) { $unk -join '; ' } elseif ($failOf[$t] -and $mine.Count -and -not @($mine | Where-Object { @(& $rowsOf $_) | Where-Object { $_ -and $_.target -eq $t } }).Count) { $failOf[$t] }
    $status = if ($why -and -not $batch.Count) { 'UNKNOWN' } elseif (-not $batch.Count) { 'NOTHING' } elseif ($running) { 'DEPLOYING' } elseif ($trigger -ne 'ask') { 'READY' } elseif ($next -and (Get-Date) -lt $next) { 'WAIT' } else { 'ASK' }
    [pscustomobject]@{ target = $t; status = $status; trigger = $trigger; last = $(if ($last) { $last.ToString('s') }); lastSource = $src; windowHours = $h; windowScope = $winScope; nextAllowed = $(if ($next) { $next.ToString('s') }); mrs = $batch; why = $why; pending = @($pend | ForEach-Object { "$($_.run) $($_.at)" }) }
  }
  # each batch MR's source / test files and OUT-OF-AREA (its diff outside its brief area; crafty.ps1 scope): seen before anyone says deploy <env>
  $bm = @($plan | ForEach-Object { @($_.mrs) } | ForEach-Object mr | Where-Object { $_ } | Select-Object -Unique); $scopeOf = @{}
  if ($bm.Count -and ($fx -or (Test-Path -LiteralPath (Get-KitPath scope-log)))) {   # areas in use (devtools.py mr / merge log them); 30 s at most
    $sr = if ($fx) { @($fx.scope) } else { $sx = Invoke-KitExe (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source @('-NoProfile', '-NonInteractive', '-File', $KitCmd.dev, 'scope', '-Mrs', ($bm -join ','), '-Json') 30; if (-not $sx.code) { try { @("$($sx.out)" | ConvertFrom-Json) } catch { @() } } }   # an older core (no scope verb) or a timeout: no columns
    foreach ($s in @($sr | Where-Object { $_.mr })) { $scopeOf["$($s.mr)"] = $s }
    foreach ($b in @($plan | ForEach-Object { @($_.mrs) })) { if ($s = $scopeOf["$($b.mr -replace '^.*/')"]) { $b | Add-Member -Force NoteProperty files ([int]$s.files); $b | Add-Member -Force NoteProperty source @($s.source); $b | Add-Member -Force NoteProperty test ([int]$s.test); $b | Add-Member -Force NoteProperty outOfArea @($s.outside); $b | Add-Member -Force NoteProperty globs @($s.globs) } }
  }
  if ($idle) { [Console]::Error.WriteLine("deploy plan: $idle open task(s) idle over $Days days left out (-Days widens)") }
  if ($Action -eq 'request') {   # a batch's full plan ran 58 KB: the plan goes to crafty.ps1 dir -Agent <run>, a summary out
    $rqDir = Join-Path (Get-KitPath agents) (ConvertTo-KitSlug $(if ($Run) { $Run } else { 'deploys' })); New-Item -ItemType Directory -Force $rqDir | Out-Null
    $rqFile = Join-Path $rqDir 'deploy-request.json'; ConvertTo-Json @($plan) -Depth 6 | Set-Content -LiteralPath $rqFile -Encoding utf8
    $rqSum = @($plan | ForEach-Object { [ordered]@{ target = $_.target; status = $_.status; trigger = $_.trigger; mrs = @(@($_.mrs) | ForEach-Object mr | Where-Object { $_ }); why = $_.why; file = $rqFile } })
    if ($Json) { ConvertTo-Json @($rqSum) -Depth 4 } else { foreach ($s in $rqSum) { "DEPLOY $($s.target): $($s.status)$(if ($s.status -eq 'UNKNOWN') { ": the deploy check failed: $($s.why)" }) · $(@($s.mrs).Count) MR(s)$(if (@($s.mrs).Count) { ": $(@($s.mrs) -join ', ')" })" }; "full plan: $rqFile" }
    return
  }
  if ($Json) { ConvertTo-Json @($plan) -Depth 6; return }
  foreach ($p in $plan) {
    $when = switch ($p.status) { 'WAIT' { " until $(([datetime]$p.nextAllowed).ToString('yyyy-MM-dd HH:mm')) (one deploy per $($p.windowHours) h)" } 'ASK' { ': ask the owner ONCE with this batch' } 'READY' { ": waits for a person's 'deploy $($p.target)' (deploy.trigger owner: nobody asks)" } 'UNKNOWN' { ": the deploy check failed: $($p.why) (plan again)" } 'DEPLOYING' { ': a deploy pipeline runs now (wait, then plan again)' } default { '' } }
    "DEPLOY $($p.target): $($p.status)$when | last $(if ($p.last) { "$(([datetime]$p.last).ToString('yyyy-MM-dd HH:mm')) ($($p.lastSource))" } else { 'unknown' })"
    foreach ($b in $p.mrs) {
      $ms = (@($b.mrState, $b.mergedAt) | Where-Object { $_ }) -join ' '
      "  - $($b.mr)$(if ($b.task) { " task $($b.task)" })$(if ($ms) { " $ms," }) $($b.state): $($b.detail) [$($b.why)]$(if ($b.files) { " · $($b.files) file(s): $(@($b.source).Count) source, $($b.test) test" })"
      if (($bo = @($b.outOfArea | Where-Object { $_ })).Count) { "    OUT-OF-AREA: $($b.mr) changes $($bo.Count) file(s) outside its area ($(@($b.globs) -join ', ')): $($bo -join ', ')" }
    }
  }
  if (-not @($plan).Count) { 'no test deploy targets in kit.local.json repos[].deploys' }
  if ($hostErr) { "last deploy unknown: $hostErr" }   # once, not per target
}

# ---- schedule: the deploy's shape from past pipeline times; one poll loop for every started pipeline
# a host or log time (string, DateTime, DateTimeOffset) -> DateTimeOffset; $null when unreadable
function ConvertTo-KitOffset($V) { if ($V -is [datetimeoffset]) { $V } elseif ($V -is [datetime]) { [datetimeoffset]$V } elseif ("$V") { try { [datetimeoffset]::Parse("$V", [Globalization.CultureInfo]::InvariantCulture) } catch { $null } } }
function Get-KitMinutes($From, $To) { $a = ConvertTo-KitOffset $From; $b = ConvertTo-KitOffset $To; if ($a -and $b) { [math]::Round(($b - $a).TotalMinutes, 1) } }
# one finished run: total, build (to the last non-deploy job), deploy minutes; deploy jobs = the row's job, else deploy.schedule.deployJobRx
function Get-KitRunSplit([string]$Project, $Run, $Row) {
  $tot = Get-KitMinutes $Run.created_at $Run.updated_at; $rx = [string](Get-KitSetting 'deploy.schedule.deployJobRx' '(?i)deploy|release|rollout')
  $jobs = @(@(try { Invoke-HostVerb 'ci.jobs' @{ repo = $Project; id = $Run.id } } catch { }) | Where-Object { $_ -and $_.finished_at })
  $bEnd = @($jobs | Where-Object { if ($Row.job) { "$($_.name)" -notlike "$($Row.job)" } else { "$($_.name) $($_.stage)" -notmatch $rx } } | ForEach-Object { ConvertTo-KitOffset $_.finished_at } | Where-Object { $_ } | Sort-Object)[-1]
  $b = if ($bEnd -and $jobs.Count -gt 1) { Get-KitMinutes $Run.created_at $bEnd }
  [ordered]@{ at = "$((ConvertTo-KitOffset $Run.created_at)?.ToString('o'))"; sha = "$($Run.sha)"; total = $tot; build = $b; deploy = $(if ($null -ne $b -and $null -ne $tot) { [math]::Round($tot - $b, 1) }) }
}
# past runs of a deploy row, newest first: the host's green pipelines on its deploy branch (cached: a finished run never changes),
# then the kit's timing records (deploy watch; any kind) of other commits
function Get-KitDeployHistory([string]$Repo, $Row, [int]$Runs = (Get-KitParam 'deploy.schedule.historyRuns')) {
  $out = [Collections.Generic.List[object]]::new(); $seen = @{}
  if ($Row.branch -and (Get-KitDeployKind $Row) -in 'ci-job', 'branch-mr') {
    $cf = Join-Path (Get-KitPath cache -Create) 'deploy-timings.json'; $cache = try { Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if ($cache -isnot [hashtable]) { $cache = @{} }
    $p = Get-HostProject $Repo -Raw; $n0 = $cache.Count
    foreach ($r in @(@(try { Invoke-HostVerb 'ci.runs' @{ repo = $p; ref = $Row.branch; per_page = 2 * $Runs } } catch { }) | Where-Object { $_ -and (ConvertTo-KitCiState "$($_.status)") -eq 'success' } | Select-Object -First $Runs)) {
      $key = "$Repo|$($Row.branch)|$($Row.job)|$($r.id)"; if (-not $cache.ContainsKey($key)) { $cache[$key] = Get-KitRunSplit $p $r $Row }
      # a cached at reads back as a DateTime: ISO again, so the sort below compares like with like
      $x = $cache[$key]; if ($null -ne $x.total) { $e = [ordered]@{} + $x; $e.at = "$((ConvertTo-KitOffset $x.at)?.ToString('o'))"; $e.src = 'host'; $out.Add($e); $seen["$($x.sha)"] = 1 }
    }
    if ($cache.Count -ne $n0) { $keep = @{}; foreach ($k in @($cache.Keys | Sort-Object { ConvertTo-KitOffset $cache[$_].at } -Descending | Select-Object -First 500)) { $keep[$k] = $cache[$k] }; try { Write-KitAtomic $cf ($keep | ConvertTo-Json -Depth 3 -Compress) } catch { } }
  }
  foreach ($t in @(Read-KitLog deploy-log -Since (Get-Date).AddDays(-(Get-KitParam 'deploy.schedule.historyDays')) | Where-Object { $_.event -eq 'timing' -and "$($_.repo)" -eq $Repo -and "$($_.target)" -eq "$($Row.target)" -and $_.status -eq 'success' -and -not $seen.ContainsKey("$($_.sha)") })) {
    $out.Add([ordered]@{ at = "$((ConvertTo-KitOffset $t.at)?.ToString('o'))"; sha = "$($t.sha)"; total = $t.totalMin; build = $t.buildMin; deploy = $t.deployMin; src = 'log' })
  }
  @($out | Sort-Object { ConvertTo-KitOffset $_.at } -Descending | Select-Object -First $Runs)
}
# p50 / p90 / fastest of a row's history; n 0 = no timing (its edges wait for live)
function Get-KitDeployTiming([string]$Repo, $Row, [int]$Runs = (Get-KitParam 'deploy.schedule.historyRuns')) {
  $h = @(Get-KitDeployHistory $Repo $Row $Runs); $q = { param($f, $p) $v = [double[]]@($h | ForEach-Object { $_[$f] } | Where-Object { $null -ne $_ }); if ($v.Count) { Get-KitQuantile $v $p } }
  $tot = [double[]]@($h | ForEach-Object { $_.total } | Where-Object { $null -ne $_ })
  [ordered]@{ n = $tot.Count; p50 = (& $q total 0.5); p90 = (& $q total 0.9); min = $(if ($tot.Count) { ($tot | Measure-Object -Minimum).Minimum }); build = (& $q build 0.5); deploy = (& $q deploy 0.5)
    basis = $(if ($tot.Count) { "$($tot.Count) run(s): $(@($h | Group-Object { $_.src } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')" } else { 'no history' }) }
}
# the shape: items [ordered]@{ name; p50; p90; min; after = names; strict = names; lock; why = @{ <dep> = reason } } -> gates, predicted start / finish,
# stages and a label (single | parallel | serial | staggered | mixed). Edge gates: after = <dep> has <= (p50 - margin) left on its p50,
# strict = <= (fastest - margin) left on its p90, unknown timing = <dep> live; maxParallel (0 = none) and lock (one at a time) hold the rest
function Get-KitDeployShape([object[]]$Items, [string]$Mode = 'auto', [int]$MaxParallel = 0, [double]$Margin = 2) {
  $names = @($Items | ForEach-Object { $_.name }); $by = @{}; foreach ($i in $Items) { $by[$i.name] = $i }; $why = [Collections.Generic.List[string]]::new()
  foreach ($i in $Items) { $i.strict = @($i.strict | Where-Object { $_ -in $names -and $_ -ne $i.name }); $i.after = @($i.after | Where-Object { $_ -in $names -and $_ -ne $i.name -and $_ -notin $i.strict }); if ($Mode -eq 'parallel') { $i.after = @() } }
  $order = [Collections.Generic.List[object]]::new(); $left = [Collections.Generic.List[object]]::new([object[]]$Items)
  while ($left.Count) {   # producers first (input order among equals); a cycle keeps the input order
    $nx = @($left | Where-Object { $c = $_; -not @(@($c.after) + @($c.strict) | Where-Object { $d = $_; @($left | Where-Object { $_.name -eq $d }).Count }).Count })[0]
    if (-not $nx) { $nx = $left[0]; $why.Add("cycle among $(@($left | ForEach-Object { $_.name }) -join ', '): input order") }
    $order.Add($nx); [void]$left.Remove($nx)
  }
  $prev = $null
  foreach ($i in $order) {
    $i.gates = @(); $s = 0.0; $unk = $false
    $deps = @(@($i.after | ForEach-Object { @{ on = $_; k = 'left' } }) + @($i.strict | ForEach-Object { @{ on = $_; k = 'left90' } }))
    if ($Mode -eq 'serial' -and $prev) { $deps = @(@{ on = $prev.name; k = 'live' }) }
    foreach ($e in $deps) {
      $d = $by[$e.on]; $lead = if ($e.k -eq 'left') { $i.p50 } elseif ($e.k -eq 'left90') { $i.min }; if ($null -ne $lead) { $lead = [math]::Round($lead - $Margin, 1) }
      $span = if ($e.k -eq 'left90') { $d.p90 } else { $d.p50 }
      if ($e.k -ne 'live' -and ($null -eq $lead -or $lead -le 0 -or $null -eq $span)) { $e.k = 'live' }
      $i.gates += [ordered]@{ on = $e.on; kind = $e.k; lead = $(if ($e.k -ne 'live') { $lead }) }
      if ($null -eq $d.start -or $null -eq $d.finish) { $unk = $true } else { $s = [math]::Max($s, $(if ($e.k -eq 'live') { $d.finish } else { [math]::Max($d.start, $d.start + $span - $lead) })) }
      $rs = "$($i.name) after $($e.on)$(if ($i.why -and $i.why[$e.on]) { " ($($i.why[$e.on]))" }): "; $why.Add($rs + $(switch ($e.k) { 'live' { if ($Mode -eq 'serial') { 'serial mode' } elseif ($null -eq $span -or $null -eq $i.p50) { 'no timing history: starts once it is live' } else { 'starts once it is live' } } 'left' { "starts when $($e.on) has <= $lead min left (p50 $($d.p50) / $($i.p50), margin $Margin): finishes at or just after it" } default { "strict: starts when $($e.on) has <= $lead min left on its p90 ($($d.p90)): never live before it" } }))
    }
    # slots and locks: the earliest predicted end of a blocker; one of unknown length holds until it is live
    for ($g = 0; -not $unk -and $g -lt $Items.Count; $g++) {
      $on = @($order | Where-Object { $_ -ne $i -and $null -ne $_.start -and ($null -eq $_.finish -or ($_.start -le $s -and $_.finish -gt $s)) -and $order.IndexOf($_) -lt $order.IndexOf($i) })
      $lk = @($on | Where-Object { $i.lock -and $_.lock -eq $i.lock }); $full = $MaxParallel -gt 0 -and $on.Count -ge $MaxParallel
      if (-not $lk.Count -and -not $full) { break }
      $bl = @($(if ($lk.Count) { $lk } else { $on }) | Sort-Object { if ($null -eq $_.finish) { [double]::MaxValue } else { $_.finish } })[0]
      $why.Add("$($i.name) waits for $($bl.name): $(if ($lk.Count) { "lock $($i.lock) (one at a time)" } else { "maxParallel $MaxParallel" })")
      if ($null -eq $bl.finish) { $unk = $true } else { $s = $bl.finish }
    }
    $i.start = if ($unk -or @($order | Where-Object { $_ -ne $i -and $_.name -in $deps.on -and $null -eq $_.start }).Count) { $null } else { [math]::Round($s, 1) }
    $i.finish = if ($null -ne $i.start -and $null -ne $i.p50) { [math]::Round($i.start + $i.p50, 1) }
    $prev = $i
  }
  # stages: items whose predicted runs overlap (unknown start: a stage of its own, last)
  $stages = [Collections.Generic.List[object]]::new(); $endAt = -1.0
  foreach ($i in @($order | Sort-Object @{ e = { $null -eq $_.start } }, @{ e = { $_.start } })) {
    $fe = if ($null -eq $i.finish) { [double]::MaxValue } else { $i.finish }
    if ($null -ne $i.start -and $stages.Count -and $i.start -lt $endAt) { $stages[-1].Add($i.name); $endAt = [math]::Max($endAt, $fe) } else { $stages.Add([Collections.Generic.List[string]]@($i.name)); $endAt = $fe }
  }
  $shape = if ($order.Count -le 1) { 'single' } elseif ($stages.Count -eq $order.Count) { 'serial' } elseif ($stages.Count -eq 1 -and -not @($order | Where-Object { $_.start -ne 0 }).Count) { 'parallel' } elseif ($stages.Count -eq 1) { 'staggered' } else { 'mixed' }
  $fin = @($order | ForEach-Object { $_.finish }); $ser = ($order | ForEach-Object { $_.p50 } | Measure-Object -Sum).Sum
  [ordered]@{ shape = $shape; mode = $Mode; stages = @($stages | ForEach-Object { , @($_) }); finish = $(if ($null -notin $fin) { ($fin | Measure-Object -Maximum).Maximum }); serial = $(if ($null -notin @($order | ForEach-Object { $_.p50 })) { $ser }); why = @($why); items = @($order) }
}
# a runtime gate: <dep> live, or its predicted time left (p50 / p90 minus elapsed; past its p90: unknown = wait for live) <= lead
function Test-KitDeployGate($Gate, $Dep, [datetimeoffset]$Now) {
  if ($Dep.status -eq 'success') { return @{ ok = $true; text = "$($Dep.name) is live" } }
  if ($Dep.status -ne 'running' -or $Gate.kind -eq 'live') { return @{ ok = $false; text = "waits for $($Dep.name) live ($($Dep.status))" } }
  $el = Get-KitMinutes $Dep.startedAt $Now; $span = if ($Gate.kind -eq 'left90') { $Dep.p90 } else { $Dep.p50 }
  if ($el -gt $span) { $span = $Dep.p90 }   # slower than its p50: replanned on its p90
  if ($null -eq $el -or $el -gt $span) { return @{ ok = $false; text = "REPLAN $($Dep.name) runs $el min, past its p90 $($Dep.p90): waits for it live" } }
  $rem = [math]::Round($span - $el, 1); @{ ok = $rem -le $Gate.lead; text = "$($Dep.name) has ~$rem min left (start at <= $($Gate.lead))" }
}
# a producer's migrations in this deploy (owner 2026-11-25: additive = no strict edge): the added lines of its migration files between
# the deploy branch's tree and the source's (or the pin's), rollback blocks and undo files skipped; kind breaking (drop / rename / type change /
# not null / delete: the old consumer may break; a file it cannot read, not .xml / .yaml / .sql / .json, too) | additive | '' (none, or
# unknown: note says why). -U0 shows added lines only: a line added inside an old rollback block reads as breaking (the safe side)
function Get-KitMigrationKind([string]$Checkout, [string]$Branch, [string]$Src) {
  $res = { param($k, $f, $h, $n) [pscustomobject]@{ kind = $k; files = @($f); hit = $h; note = $n } }
  if (-not $Checkout -or -not $Branch -or -not $Src -or -not (Test-Path -LiteralPath $Checkout)) { return & $res '' @() '' '' }   # no checkout here: nothing to read, no note
  $null = Invoke-GitFetch $Checkout 30 @($Branch, $(if ($Src -like 'origin/*') { $Src.Substring(7) }) | Where-Object { $_ })   # a stale clone would miss the batch
  if ($Src -notlike 'origin/*') { $null = git -C $Checkout cat-file -e "$Src^{commit}" 2>&1; if ($LASTEXITCODE) { return & $res '' @() '' "pin $Src not in this checkout" } }
  # the deploy branch's tree vs the source's, not a commit range: a squash-merged deploy keeps an old merge base, and its live
  # changelogs would read as new (coordinator 2026-11-25); a file identical on the branch is live, only the lines it lacks count
  $rng = @("origin/$Branch", $Src); $pathRx = [string](Get-KitSetting 'deploy.schedule.migrationPathRx' '(?i)(^|/)(db|migrations?|changelogs?)(/|\.|$)|changelog[^/]*\.(xml|ya?ml|sql|json)$')
  $fs = @(git -C $Checkout -c core.quotepath=off diff --no-renames --name-only --diff-filter=AM $rng 2>$null)
  if ($LASTEXITCODE) { return & $res '' @() '' "git diff $($rng -join ' ') failed" }
  # and changed on the source since the merge base: a hotfix only on the deploy branch is no new migration
  $src1 = @(git -C $Checkout -c core.quotepath=off diff --no-renames --name-only --diff-filter=AM "origin/$Branch...$Src" 2>$null)
  $fs = @($fs | Where-Object { $_ -match $pathRx -and $_ -notmatch '(^|/)U\d+[_.]' -and $_ -in $src1 }); if (-not $fs.Count) { return & $res '' @() '' '' }
  if (($unk = @($fs | Where-Object { $_ -notmatch '\.(xml|ya?ml|sql|json)$' })).Count) { return & $res 'breaking' $fs "$($unk[0]) (not read: code)" '' }
  $brk = [string](Get-KitSetting 'deploy.schedule.breakingMigrationRx' '(?i)\b(dropColumn|dropTable|dropView|renameColumn|renameTable|renameView|modifyDataType|addNotNullConstraint|mergeColumns|dropPrimaryKey|dropForeignKeyConstraint)\b|\bDROP\s+(TABLE|COLUMN|VIEW|FOREIGN|CONSTRAINT)\b|\bRENAME\s+(TABLE|COLUMN|TO)\b|\bRENAME\s+\w+\s+TO\b|\bALTER\s+TABLE\b.*\b(DROP|MODIFY|CHANGE)\b|^\s*(MODIFY|CHANGE|RENAME|ALTER\s+COLUMN)\s+\S|^\s*DROP\s+(?!INDEX\b)\S|\bALTER\s+COLUMN\b.*\bTYPE\b|\bSET\s+NOT\s+NULL\b|\bTRUNCATE\b|\bDELETE\s+FROM\b|^\s*<delete\b|^\s*-\s*delete:')
  $inRb = $false; $rbInd = -1; $hit = ''
  foreach ($l in @(git -C $Checkout -c core.quotepath=off diff --no-renames -U0 $rng -- @($fs) 2>$null)) {
    if ($l -match '^\+\+\+ ') { $inRb = $false; $rbInd = -1; continue }
    if ($l -notmatch '^\+(?<t>.*)$') { continue }; $t = $Matches.t; $ind = $t.Length - $t.TrimStart().Length
    # a YAML rollback block ends at a lower indent, or its own indent unless a list item ("rollback:" then "- dropTable:")
    if ($rbInd -ge 0 -and $t.Trim() -and ($ind -lt $rbInd -or ($ind -eq $rbInd -and $t.TrimStart() -notmatch '^-'))) { $rbInd = -1 }
    if ($t -match '^\s*-?\s*rollback:\s*$') { $rbInd = $ind; continue }
    if ($t -match '(?i)<rollback\b' -and $t -notmatch '(?i)</rollback>|/>\s*$') { $inRb = $true; continue }
    if ($inRb) { if ($t -match '(?i)</rollback>') { $inRb = $false }; continue }
    if ($rbInd -ge 0 -or $t -match '^\s*--\s*rollback\b' -or $t -match '(?i)<rollback\b') { continue }
    if (-not $hit -and $t -match $brk) { $hit = $t.Trim() }
  }
  & $res $(if ($hit) { 'breaking' } else { 'additive' }) $fs $hit ''
}
# deploy schedule: items of -Env (one per repo x target: -Mrs' repos, -Repo, else every repo with a row there) -> the shape, saved for deploy watch
function Invoke-DeploySchedule([string[]]$Envs, [Alias('Mr')][string[]]$Mrs, [string[]]$RepoNames, [string[]]$After, [string[]]$Strict, [string]$Mode, [string]$Decision, [switch]$Json) {
  if (-not $Mode) { $Mode = [string](Get-KitSetting 'deploy.schedule.mode' 'auto') }
  if ($Mode -notin 'auto', 'parallel', 'serial') { "deploy schedule: mode $Mode unknown (auto | parallel | serial)"; exit 2 }
  $sp = try { Get-KitDecisionPin $Decision } catch { "deploy schedule: $_; nothing scheduled"; exit 2 }
  $spOut = @($Mrs | Where-Object { $_ -and $sp -and -not (Test-KitDeployPinCovers $sp "$_") })
  if ($spOut.Count -or ($sp.pinned -and -not $sp.commit -and -not @($Mrs | Where-Object { $_ }).Count)) { "deploy schedule: word $Decision is pinned$(if ($spOut.Count) { ", does not cover $($spOut -join ', ')" } else { ': pass -Mrs <the refs it covers>' }); nothing scheduled"; exit 2 }
  $mrOf = @{}; foreach ($m in $Mrs) { $c = Get-CanonMr (ConvertTo-MrRef $m); $rn = (($c -split '!')[0] -split '/')[-1]; $mrOf[$rn] = @(@($mrOf[$rn]) + $c | Where-Object { $_ }) }
  $want = @(@($mrOf.Keys) + @($RepoNames | ForEach-Object { Get-KitRepoName $_ }) | Select-Object -Unique)
  $edges = @{}; foreach ($pr in @(@($After | ForEach-Object { , @($_, 'after') }) + @($Strict | ForEach-Object { , @($_, 'strict') }))) { $c, $p = "$($pr[0])" -split '=', 2; if (-not $p) { "deploy schedule: -$($pr[1]) takes <consumer>=<producer> ($($pr[0]))"; exit 2 }; $edges["$(Get-KitRepoName $c)|$(Get-KitRepoName $p)"] = $pr[1] }
  $items = @(foreach ($rp in @(Get-KitValue 'repos' @())) {
      if ($want.Count -and "$($rp.name)" -notin $want) { continue }
      foreach ($d in @($rp.deploys | Where-Object { "$($_.target)" -in $Envs })) {
        $t = Get-KitDeployTiming "$($rp.name)" $d
        [ordered]@{ name = $(if ($Envs.Count -gt 1) { "$($rp.name)@$($d.target)" } else { "$($rp.name)" }); repo = "$($rp.name)"; target = "$($d.target)"; branch = "$($d.branch)"; from = "$(@($d.from)[0] ?? $rp.target)"; checkout = "$($rp.checkout)"; kind = (Get-KitDeployKind $d)
          role = "$($rp.role)"; rowAfter = @($d.after | Where-Object { $_ }); lock = "$($d.lock)"; mrs = @($mrOf["$($rp.name)"]); n = $t.n; p50 = $t.p50; p90 = $t.p90; min = $t.min; build = $t.build; deploy = $t.deploy; basis = $t.basis; job = "$($d.job)"; after = @(); strict = @(); why = @{}; status = 'pending' }
      } })
  if (-not $items.Count) { "deploy schedule: nothing to deploy to $($Envs -join ', ')$(if ($want.Count) { " for $($want -join ', ')" }) (repos[].deploys targets)"; exit 2 }
  # edges per target: role producer -> consumer, deploys[].after, -After / -Strict (the MR bodies, briefs, contracts, migrations opsy read)
  foreach ($i in $items) {
    foreach ($j in @($items | Where-Object { $_ -ne $i -and $_.target -eq $i.target })) {
      $k = $edges["$($i.repo)|$($j.repo)"]
      if ($k -eq 'strict') { $i.strict += $j.name; $i.why[$j.name] = '-Strict' }
      elseif ($k) { $i.after += $j.name; $i.why[$j.name] = '-After' }
      elseif ($j.repo -in $i.rowAfter) { $i.after += $j.name; $i.why[$j.name] = 'deploys[].after' }
      elseif ($i.role -eq 'consumer' -and $j.role -eq 'producer') { $i.after += $j.name; $i.why[$j.name] = 'repos[].role producer -> consumer' }
    }
  }
  # migrations decide strict, not the caller: a breaking one makes its consumers' edges strict; additive stays a p50 edge (both run in parallel)
  foreach ($j in @($items | Where-Object { $jn = $_.name; @($items | Where-Object { $jn -in @($_.after) }).Count })) {
    $mk = Get-KitMigrationKind $j.checkout $j.branch $(if ($sp.commit) { $sp.commit } elseif ($j.from) { "origin/$($j.from)" })
    foreach ($i in @($items | Where-Object { $j.name -in @($_.after) })) {
      if ($mk.kind -eq 'breaking') { $i.after = @($i.after | Where-Object { $_ -ne $j.name }); $i.strict += $j.name; $i.why[$j.name] = "breaking migration: $($mk.hit)" }
      elseif ($mk.kind) { $i.why[$j.name] += "; additive migrations ($(@($mk.files).Count) file(s)): not strict" }
      elseif ($mk.note) { $i.why[$j.name] += "; migrations unknown ($($mk.note)): -Strict when breaking" }
    }
  }
  $sh = Get-KitDeployShape $items $Mode ([int](Get-KitParam 'deploy.schedule.maxParallel')) ([double](Get-KitParam 'deploy.schedule.marginMinutes'))
  $key = ConvertTo-KitSlug ($Envs -join '-'); $f = Join-Path (Get-KitPath deploys -Create) "schedule-$key.json"
  $old = try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null }; $busy = @($old.items | Where-Object { $_.status -eq 'running' } | ForEach-Object { $_.name })
  if ($busy.Count) { "deploy schedule: $($busy -join ', ') still running in $(Split-Path $f -Leaf): deploy watch -Env $($Envs -join ',') until they finish (a new schedule would drop their state)"; exit 1 }
  $doc =[ordered]@{ envs = $Envs; at = (Get-Date).ToString('o'); decision = $Decision; pin = "$($sp.commit)"; maxParallel = [int](Get-KitParam 'deploy.schedule.maxParallel') } + $sh
  Write-KitAtomic $f ($doc | ConvertTo-Json -Depth 6 -Compress)
  if ($Json) { $doc | ConvertTo-Json -Depth 6; return }
  $fmt = { param($v) if ($null -eq $v) { '?' } else { $v } }
  "SHAPE $($sh.shape) (mode $Mode): $(@($sh.stages | ForEach-Object { @($_) -join ' + ' }) -join ', then ') · predicted finish $(if ($null -ne $sh.finish) { "+$($sh.finish) min" } else { 'unknown (no history for a gated target)' })$(if ($null -ne $sh.serial -and $null -ne $sh.finish -and $sh.serial -gt $sh.finish) { " (serial +$($sh.serial), saves $([math]::Round($sh.serial - $sh.finish, 1)))" })"
  foreach ($i in $sh.items) {
    $g = @($i.gates | ForEach-Object { if ($_.kind -eq 'live') { "$($_.on) live" } else { "$($_.on) has <= $($_.lead) min left$(if ($_.kind -eq 'left90') { ' (p90)' })" } })
    "  $($i.name) -> $($i.target): start $(if ($i.start -eq 0 -and -not $g.Count) { 'now' } elseif ($null -ne $i.start) { "+$($i.start)" } else { 'on its gate' }) · finish $(if ($null -ne $i.finish) { "+$($i.finish)" } else { '?' }) · p50 $(& $fmt $i.p50) / p90 $(& $fmt $i.p90) min$(if ($null -ne $i.build) { " (build $($i.build), deploy $(& $fmt $i.deploy))" }) · basis $($i.basis)$(if ($g.Count) { " · gate: $($g -join ', ')" })$(if ($i.lock) { " · lock $($i.lock)" })"
  }
  foreach ($w in $sh.why) { "WHY  $w" }
  "Next: deploy each 'start now' target (deploy merge / deploy run), then bossy.ps1 deploy watch -Env $($Envs -join ',') -Started <name>=<merge sha>,.. in the background: one loop polls them all, prints START / DONE / FAILED and ends itself (schedule $(Split-Path $f -Leaf))"
}
# deploy watch: the saved schedule's started pipelines polled in one loop (bounded: deploy.pipelineWaitMinutes); ends at the first START
# (a gate opened: opsy starts it, runs watch again), when nothing runs, or at the time limit. DONE = verify that target now; FAILED =
# step 6 for that target only, its dependents held, the rest go on. Each finish logs actual vs predicted (deploy-log timing)
function Invoke-DeployWatch([string[]]$Envs, [string[]]$Started, [string[]]$Finished, [double]$WaitMinutes, [switch]$Json) {
  $f = Join-Path (Get-KitPath deploys -Create) "schedule-$(ConvertTo-KitSlug ($Envs -join '-')).json"
  $doc = try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
  if (-not $doc) { "deploy watch: no schedule for $($Envs -join ', '): run bossy.ps1 deploy schedule -Env $($Envs -join ',') first"; exit 2 }
  $by = @{}; foreach ($i in $doc.items) { $by[$i.name] = $i }; $now = { [datetimeoffset](Get-Date) }
  foreach ($pr in @(@($Started | ForEach-Object { , @($_, 'running') }) + @($Finished | ForEach-Object { , @($_, '') }))) {
    $n, $v = "$($pr[0])" -split '=', 2; $i = $by[$n]; if (-not $i) { "deploy watch: $n is not in the schedule ($(@($by.Keys) -join ', '))"; exit 2 }
    # no sha: the branch's newest run is the last deploy's (a false DONE)
    if ($pr[1] -and -not "$v".Trim() -and $i.branch -and $i.kind -in 'ci-job', 'branch-mr') { "deploy watch: -Started $n needs =<merge sha> (a CI target is matched by its sha)"; exit 2 }
    if (-not $pr[1] -and $v -notin 'success', 'failed') { "deploy watch: -Finished $n=${v}: use success or failed"; exit 2 }
    if ($pr[1]) { if ($i.status -eq 'pending') { $i.status = 'running'; $i.sha = "$v"; $i.startedAt = (& $now).ToString('o') } } elseif ($v -in 'success', 'failed') { $i.status = $v; $i.finishedAt = (& $now).ToString('o'); $i.recorded = $false }
  }
  $out = [Collections.Generic.List[string]]::new(); $end = (Get-Date).AddMinutes($WaitMinutes); $bk = @{}; $pz = ''
  $held = { param($bad) foreach ($x in $doc.items) { if ($x.status -eq 'pending' -and @($x.gates | Where-Object { $_.on -eq $bad }).Count) { $x.status = 'held'; $out.Add("HELD $($x.name): its producer $bad failed (never started past it)"); & $held $x.name } } }
  do {
    foreach ($i in @($doc.items | Where-Object { $_.status -eq 'running' -and $_.branch -and $_.kind -in 'ci-job', 'branch-mr' })) {
      $p = Get-HostProject $i.repo -Raw
      $r = @(@(try { Invoke-HostVerb 'ci.runs' @{ repo = $p; ref = $i.branch; per_page = 10 } -NoMemo } catch { }) | Where-Object { $_ -and (-not $i.sha -or "$($_.sha)".StartsWith("$($i.sha)")) })[0]
      $st = if ($r) { ConvertTo-KitCiState "$($r.status)" } else { 'pending' }
      if ($st -in 'success', 'failed', 'canceled') { $i.status = if ($st -eq 'success') { 'success' } else { 'failed' }; $i.finishedAt = "$((ConvertTo-KitOffset $r.updated_at)?.ToString('o'))"; $i.run = $r; $i.recorded = $false }
    }
    foreach ($i in @($doc.items | Where-Object { $_.status -in 'success', 'failed' -and $_.recorded -eq $false })) {
      $sp = if ($i.run) { Get-KitRunSplit (Get-HostProject $i.repo -Raw) ([pscustomobject]$i.run) ([pscustomobject]@{ job = $i.job }) } else { @{ total = (Get-KitMinutes $i.startedAt $i.finishedAt) } }
      $tot = if ($i.run -and $null -ne $sp.total) { $sp.total } else { Get-KitMinutes $i.startedAt $i.finishedAt }
      Write-KitLog deploy-log timing ([ordered]@{ target = $i.target; repo = $i.repo; sha = $i.sha; status = $i.status; startedAt = $i.startedAt; totalMin = $tot; buildMin = $sp.build; deployMin = $sp.deploy; predictedMin = $i.p50; p90Min = $i.p90 })
      $i.recorded = $true; $i.actual = $tot; $i.Remove('run')
      $vs = if ($null -ne $i.p50 -and $null -ne $tot) { "predicted $($i.p50), p90 $($i.p90): $(if ($tot -gt $i.p90) { 'slower than p90' } elseif ($tot -lt $i.p50) { 'faster' } else { 'on time' })" } else { 'no prediction' }
      if ($i.status -eq 'success') { $out.Add("DONE $($i.name) -> $($i.target) in $tot min ($vs): verify it now (opsy step 5); the others go on") }
      else { $out.Add("FAILED $($i.name) -> $($i.target)$(if ($tot) { " after $tot min" }): opsy step 6 for this target only; the others go on"); & $held $i.name }
    }
    $run = @($doc.items | Where-Object { $_.status -eq 'running' }); $go = @()
    foreach ($i in @($doc.items | Where-Object { $_.status -eq 'pending' })) {
      $res = @($i.gates | ForEach-Object { Test-KitDeployGate $_ $by[$_.on] (& $now) })
      $lk = @(@($run) + @($go) | Where-Object { $i.lock -and $_.lock -eq $i.lock }); $full = $doc.maxParallel -gt 0 -and ($run.Count + $go.Count) -ge $doc.maxParallel
      $i.wait = (@($res | ForEach-Object text) + @($(if ($lk.Count) { "lock $($i.lock) held by $($lk[0].name)" }; if ($full) { "maxParallel $($doc.maxParallel)" })) | Where-Object { $_ }) -join '; '
      if (-not @($res | Where-Object { -not $_.ok }).Count -and -not $lk.Count -and -not $full) { $go += $i }
    }
    $pq = "$(@($doc.items | ForEach-Object { "$($_.name) $($_.status)" }))"; if ($pq -ne $pz) { [Console]::Error.WriteLine("watch $(Get-Date -f HH:mm:ss) $pq"); $pz = $pq }
    $live = @($run | Where-Object { $_.branch -and $_.kind -in 'ci-job', 'branch-mr' })
    if ($go.Count -or -not $live.Count -or $out.Count -or (Get-Date) -gt $end) { break }
    Wait-KitBackoff $bk $pq 30 $end
  } while ((Get-Date) -le $end)
  foreach ($i in $go) { $out.Add("START $($i.name) -> $($i.target) now ($(if ($i.wait) { $i.wait } else { 'no gate' })): bossy.ps1 deploy $(if ($i.kind -in 'ci-job', 'branch-mr') { "merge -Repo $($i.checkout) -To $($i.target) -Mr$(if ($doc.pin) { " -Commit $($doc.pin)" })" } else { "run -To $($i.target) -Repo $($i.repo)" })$(if (@($i.mrs).Count) { " -Mrs $(@($i.mrs) -join ',')" })$(if ($doc.decision) { " -Decision $($doc.decision)" }); then deploy watch -Env $($Envs -join ',') -Started $($i.name)=<merge sha>") }
  foreach ($i in @($doc.items | Where-Object { $_.status -eq 'pending' -and $_ -notin $go })) { $out.Add("WAIT $($i.name): $($i.wait)") }
  foreach ($i in @($doc.items | Where-Object { $_.status -eq 'running' -and -not ($_.branch -and $_.kind -in 'ci-job', 'branch-mr') })) { $out.Add("RUNNING $($i.name): no CI run to poll ($($i.kind)): deploy watch -Finished $($i.name)=success|failed once it returns") }
  # another watch (a -Started / -Finished call while this one polled) may have moved an item on: the further state wins
  $rank = @{ pending = 0; running = 1; success = 2; failed = 2; held = 2 }
  Invoke-KitLocked $f {
    $disk = try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
    foreach ($d in @($disk.items)) { $mine = $by[$d.name]; if ($mine -and $rank["$($d.status)"] -gt $rank["$($mine.status)"]) { foreach ($dk in @($d.Keys)) { $mine[$dk] = $d[$dk] } } }
    Write-KitAtomic $f ($doc | ConvertTo-Json -Depth 6 -Compress)
  }
  $cnt =@($doc.items | Group-Object { $_.status } | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
  if ($Json) { [ordered]@{ done = -not @($doc.items | Where-Object { $_.status -in 'pending', 'running' }).Count; lines = @($out); items = @($doc.items | ForEach-Object { [ordered]@{ name = $_.name; status = $_.status; actual = $_.actual; p50 = $_.p50 } }) } | ConvertTo-Json -Depth 4 -Compress; return }
  $out; "watch: $cnt$(if (@($doc.items | Where-Object { $_.status -in 'pending', 'running' }).Count) { ' · Next: act on the lines above, then deploy watch again (same -Env)' } else { ' · all finished' })"
}

# ---- restart: services of an ssh deploy, gated by its busy check in the same shell, right before each restart
# deploys[].ssh.busy: a host shell command whose output = live work (e.g. a running agent turn); busy -> wait, re-check, bounded
# a row's command.restart first, else its deploy kind's restart (ssh: below; awsStack: ecsService; laneApk: free or own phones), else its
# ssh block; none of them = refused
# deploy run (README "Adapters" deploy-kind deploy): only on a person's word (deploy.trigger); a kind without a deploy verb prints
# UNSUPPORTED + its plan line (a person deploys, then deploy record); DEPLOY / FAILED per row
function Invoke-DeployRun([string]$To, [string]$Repo, [Alias('Mr')][string[]]$Mrs, [string]$Decision, [string]$Agent) {
  $rows = @(foreach ($r in @(Get-KitValue 'repos' @())) { if (-not $Repo -or $r.name -eq $Repo) { foreach ($d in @($r.deploys | Where-Object { "$($_.target)" -eq $To })) { [pscustomobject]@{ r = $r; d = $d } } } })
  if (-not $rows.Count) { "deploy run: no repos[].deploys[] row with target $To$(if ($Repo) { " in $Repo" })"; exit 2 }
  # a person's word first (AGENTS.md): checked, not used; a word the caller used itself (decide check -Use -Agent) still serves its deploy
  $drWord = if ($Decision) { "$(& pwsh -NoProfile -File $KitCmd.orch decide check -Id $Decision -Gate deploy -Item $To $(if ($Agent) { '-Agent', $Agent }) 2>&1)" } else { '' }
  if ($drWord -notmatch '^WORD ') { "REFUSED deploy run -To ${To}: no person's deploy word (decide record -Gate deploy -Item $To, then -Decision <id>)$(if ($drWord) { ": $drWord" })"; exit 1 }
  # a pinned word: its MRs only; a commit pin deploys through deploy merge -Commit (a run deploys the head)
  $drPin = try { Get-KitDecisionPin $Decision } catch { "REFUSED deploy run -To ${To}: $_"; exit 1 }
  $drOut = @($Mrs | Where-Object { $_ -and -not (Test-KitDeployPinCovers $drPin "$_") })
  if ($drPin.commit -or $drOut.Count -or ($drPin.pinned -and -not @($Mrs | Where-Object { $_ }).Count)) { "REFUSED deploy run -To ${To}: word $Decision is pinned ($(if ($drPin.commit) { "at $($drPin.commit): deploy merge -Commit" } elseif ($drOut.Count) { "not $($drOut -join ', ')" } else { 'pass -Mrs <the refs it covers>' }))"; exit 1 }
  foreach ($x in $rows) {
    $kd = Get-KitDeployKind $x.d; $cmdDeploy = $x.d.command.deploy -and $kd -ne 'command'   # fallback: a row's command.deploy line (any kind)
    if (-not (Test-KitCap 'deploy-kind' $kd 'deploy') -and -not $cmdDeploy) { "UNSUPPORTED deploy-kind/$kd/deploy $($x.r.name) -> ${To}: a person deploys ($(Invoke-KitDeployKind $x.d 'plan')), then deploy record -Env $To"; continue }
    $rf = Join-Path (Get-KitPath deploys -Create) "running-$(ConvertTo-KitSlug $To).json"   # isRunning fallback (Test-KitDeployRunning)
    @{ pid = $PID; start = (Get-Date).ToString('o'); kind = $kd; repo = "$($x.r.name)" } | ConvertTo-Json -Compress | Set-Content -LiteralPath $rf -Encoding utf8
    $o = try { if (-not (Test-KitCap 'deploy-kind' $kd 'deploy')) { $global:KitHostFailed = $false; $co = "$(__DkCmd $x.d 'deploy' @{ sha = (__DkHead $x.r $x.d); repo = "$($x.r.name)"; mr = (@($Mrs) -join ',') })".Trim(); if ($global:KitHostFailed) { @{ note = 'command.deploy failed' } } else { @{ id = $(if ($co) { $co } else { 'command.deploy' }) } } } else { Invoke-KitDeployKind $x.d 'deploy' @{ repo = $x.r; env = $To; mrs = $Mrs; decision = $Decision } } } catch { @{ note = "$_" } } finally { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
    "$(if ($o.id) { 'DEPLOY' } else { 'FAILED' }) $($x.r.name) -> $To ($kd)$(if ($o.id) { ": $(@($o.url, $o.id) | Where-Object { $_ } | Select-Object -First 1)" })$(if ($o.note) { " · $($o.note)" })"
  }
}
# a deploy run of the target in flight (its marker's process alive): the plan's DEPLOYING for a kind with no isRunning of its own
function Test-KitDeployRunning([string]$To) {
  $j = try { Get-Content -LiteralPath (Join-Path (Get-KitPath deploys) "running-$(ConvertTo-KitSlug $To).json") -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
  $pr = if ($j) { Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue }   # a reused pid started after the marker is not it
  [bool]($pr -and (-not $pr.StartTime -or -not $j.start -or $pr.StartTime -le ([datetimeoffset]"$($j.start)").LocalDateTime.AddSeconds(1)))
}
function Invoke-DeployRestart([string[]]$Targets, [string]$Service, [int]$WaitMinutes = 20, [int]$RecheckSeconds = 120, [switch]$Ungated, [string]$Agent) {
  foreach ($t in $Targets) {
    $d = @(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -eq $t } | Select-Object -First 1
    $kd = if ($d) { Get-KitDeployKind $d }
    # the kind's own restart, unless the row names its command.restart (that wins); @{ skip } = not set up on this row: the fallbacks below
    if ($d -and $kd -ne 'ssh' -and ($kd -eq 'command' -or -not $d.command.restart) -and $KitAdapters['deploy-kind'][$kd].restart) {
      $global:KitHostFailed = $false; $o = Invoke-KitDeployKind $d 'restart' @{ service = $Service; agent = $Agent }
      if (-not ($o -is [hashtable] -and $o.skip)) {
        if ($null -eq $o -or $global:KitHostFailed) { "FAILED deploy restart ${t}: deploy kind $kd restart$(if ($o) { ": $o" } else { ' gave no answer' })"; exit 1 }
        Write-KitLog deploy-log restart ([ordered]@{ target = $t; services = @(Split-KitList @($Service)); gated = $false; kind = $kd }); "RESTARTED ${t} (deploy kind $kd): $o"; continue
      }
    }
    if ($d -and $kd -ne 'ssh' -and $d.command.restart) {   # fallback: the row's command.restart line
      $global:KitHostFailed = $false; $o = __DkCmd $d 'restart' @{ service = $Service }; if ($global:KitHostFailed) { "FAILED deploy restart ${t}: command.restart failed"; exit 1 }
      Write-KitLog deploy-log restart ([ordered]@{ target = $t; services = @(Split-KitList @($Service)); gated = $false; kind = "$kd command.restart" }); "RESTARTED ${t} (deploy kind $kd, command.restart): $o"; continue
    }
    if (-not $d.ssh.host) { "deploy restart: $t has no repos[].deploys[].ssh (host, key, service) and its kind ($(if ($kd) { $kd } else { 'none' })) has no restart: restart it by the org's deploy rules"; exit 2 }
    Invoke-DeployRestartSsh $t $d $Service $WaitMinutes $RecheckSeconds -Ungated:$Ungated
  }
}
# ssh rows: ssh.manager's restart / status commands (systemd | docker | pm2 | custom), ssh.sudo true = sudo -n
function Invoke-DeployRestartSsh([string]$t, $d, [string]$Service, [int]$WaitMinutes = 20, [int]$RecheckSeconds = 120, [switch]$Ungated) {
  if ($true) {
    $s = $d.ssh; $svcs = @(Split-KitList @($(if ($Service) { $Service } else { $s.service })))
    if (-not $svcs.Count) { "deploy restart: no -Service and no deploys[].ssh.service for $t"; exit 2 }
    if (-not (Get-KitSshServiceCmd $s 'restart' 'x')) { "REFUSED deploy restart ${t}: deploys[].ssh has no manager (systemd | docker | pm2) or restartCmd: set one; nothing restarted"; exit 2 }
    if (-not $s.busy -and -not $Ungated) { "REFUSED deploy restart ${t}: no deploys[].ssh.busy (a shell command that prints live work on the host, e.g. running agent turns): set it, or -Ungated when nothing on $($s.host) can be cut; nothing restarted"; exit 2 }
    $end = (Get-Date).AddMinutes($WaitMinutes); $done = @(); $busySaid = $null; $sec = [int](Get-KitParam 'deploy.sshTimeoutSeconds'); $key = [string]$s.key -replace '^~', $HOME
    while ($true) {
      $left = @($svcs | Where-Object { $_ -notin $done })
      $sh = @(
        "SU=$(if (Test-KitSshSudo $s) { "'sudo -n'" })"
        foreach ($v in $left) {   # the busy check runs immediately before each restart: no gap for a new turn to start unseen
          if ($s.busy) { "B=`$(sh -c $(Sq $s.busy) </dev/null 2>/dev/null); if [ -n `"`$B`" ]; then echo BUSY=1; printf '%s\n' `"`$B`" | head -n 5 | sed 's/^/LIVE=/'; exit 0; fi" }
          $st = Get-KitSshServiceCmd $s 'status' $v
          "`$SU $(Get-KitSshServiceCmd $s 'restart' $v); R=`$?; echo `"DONE=$v `$R`"; echo `"ACTIVE=$v $(if ($st) { "`$($st 2>/dev/null)" })`"; [ `$R -eq 0 ] || exit 0"   # a failed restart stops the rest
        }
        'echo END=1'
      ) -join "`n"
      $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
      $lines = @(Invoke-BoundedSsh @(@(if ($key) { '-i', $key }) + @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$([math]::Min(15, $sec))", '-o', 'StrictHostKeyChecking=accept-new', $s.host, "echo $b64 | base64 -d | bash")) ($sec + 120))
      foreach ($x in @($lines -match '^DONE=')) { $nm, $rc = ($x -replace '^DONE=', '') -split ' ', 2; if ("$rc".Trim() -ne '0') { "FAILED deploy restart ${t}: $(@("$($s.manager)", [string](Get-KitSetting 'deploy.ssh.manager' ''), 'custom' | Where-Object { $_ })[0].ToLower()) restart $nm exit $rc on $($s.host)$(if ($done) { " (restarted before: $($done -join ', '))" })"; exit 1 }; $done += $nm }
      $act = @($lines -match '^ACTIVE=' -replace '^ACTIVE=', '')
      if ($lines -match '^END=1') { Write-KitLog deploy-log restart ([ordered]@{ target = $t; services = $svcs; gated = (-not $Ungated) }); "RESTARTED ${t}: $($svcs -join ', ') on $($s.host) ($($act -join '; '))$(if ($Ungated) { ' (ungated)' })"; break }
      if (-not ($lines -match '^BUSY=1')) { "UNKNOWN deploy restart ${t}: no answer from $($s.host) (ssh failed or timed out)$(if ($done) { "; restarted: $($done -join ', ')" }); restart state unknown: check the services on the host before a retry"; exit 1 }
      $live = @($lines -match '^LIVE=' -replace '^LIVE=', '') -join ' | '
      if ((Get-Date).AddSeconds($RecheckSeconds) -gt $end) { "REFUSED deploy restart ${t}: live work on $($s.host) after $WaitMinutes min ($live); $(if ($done) { "restarted: $($done -join ', '), not: " } else { 'not restarted: ' })$(@($svcs | Where-Object { $_ -notin $done }) -join ', ') (bossy.ps1 decide ask)"; exit 3 }
      # printed when the live work changes, not on every re-check
      if ($live -ne $busySaid) { "BUSY ${t}: live work on $($s.host) ($live): re-check every $RecheckSeconds s (until $($end.ToString('HH:mm')))" }; $busySaid = $live; Start-Sleep $RecheckSeconds
    }
  }
}

# ---- supervise: inTest moves, the cached plan
# a deploy word's kind: wait | no | yes | unclear (yes and unclear silence nothing; "no problem" inside a yes is no no); a no is env-wide
# (noAll: new MRs stay held) when it says all / any / never / keep ... held / until
# deploy.answerWords {yes, no, noAll, wait}: an org's own leading words (any language), read before the built-in English ones
function Get-KitDeployWordKind([string]$Answer) {
  $a = "$Answer".Trim()
  $aw = Get-KitSetting 'deploy.answerWords' $null
  foreach ($awKind in 'noAll', 'no', 'wait', 'yes') { $awRx = @(@((Get-KitMember $aw $awKind)) | Where-Object { $_ } | ForEach-Object { [regex]::Escape("$_") }) -join '|'; if ($awRx -and $a -match "(?i)^($awRx)(?=\W|$)") { return $awKind } }
  if ($a -match "(?i)^(no (problem|worries|issues?|objections?)|(do not|d[o]?n['’]?t|no need to) wait)\b" -and $a -notmatch '(?i)\b(but|except|however|hold|held|keep|until|tomorrow|later)\b') { return 'yes' }   # a go, not a no; a qualifier reads on
  if ($a -match '(?i)^(wait|later|retry|not yet)\b' -or ($a -notmatch '(?i)^(no|nope|nah)\b' -and $a -match '(?i)\b(tomorrow|tonight|later today)\b')) { return 'wait' }
  $no = $a -match "(?i)^(no|nope|nah|d[o]?n['’]?t|do not|never|skip|hold|held|not now|stop)\b" -or $a -match "(?i)\b(keep|keeps|stays?|remains?|leave)\b[^.;]*\b(held|on hold)\b|\b(no|never|d[o]?n['’]?t|do not)\s+deploy|\b(hold|held)\s+(all|every|any)\b"
  if ($no) { if ($a -match "(?i)\b(all|any|every|never|until)\b|\b(keep|keeps|stays?|remains?|leave)\b[^.;]*\bheld\b") { 'noAll' } else { 'no' } }
  elseif ($a -match '(?i)^(yes|y|sure|proceed|please|confirmed?|ok|okay|go|approved?|deploy)\b') { 'yes' }
  else { 'unclear' }
}
# deploy merge / run / schedule -Decision: the record, else its answered log line (.runtime is disposable); none = throw (fail closed)
function Get-KitDecisionPin([string]$Id) {
  if (-not $Id) { return $null }
  $f = Join-Path (Get-KitPath decisions) "$Id.json"
  $d = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } else { @(Read-KitLog decisions-log ([datetime]'2000-01-01') | Where-Object { $_.event -eq 'answered' -and $_.id -eq $Id }) | Select-Object -Last 1 }
  if (-not $d) { throw "decision $Id not found: its pin cannot be checked" }
  Get-KitDeployWordPin $d
}
# a wait or no on a condition: 'until run <run> done', 'until tasks <ids> merged', or 'until (all of) <phrase> is merged|done' whose
# letters and digits name one launched run ('v2 wave 1' = v2-wave1); else $null (a plain wait / no)
function Get-KitDeployCondition([string]$Answer) {
  if ($Answer -match '(?i)\buntil\s+run\s+(?<r>[\w.-]+)\s+(is\s+)?(done|finished|ended|merged)\b') { return [pscustomobject]@{ kind = 'run'; id = $Matches.r; text = "run $($Matches.r) done" } }
  if ($Answer -match '(?i)\buntil\s+tasks?\s+(?<k>[\w-]+(\s*,\s*[\w-]+)*)\s+(is\s+|are\s+)?merged\b') { $ks = @(Split-KitList $Matches.k); return [pscustomobject]@{ kind = 'tasks'; keys = $ks; text = "tasks $($ks -join ', ') merged" } }
  if ($Answer -notmatch '(?i)\buntil\s+(all\s+of\s+)?(the\s+)?(?<p>[\w .-]+?)\s+(is\s+|are\s+)?(merged|done|finished)\b') { return $null }
  $want = ($Matches.p -replace '[^A-Za-z0-9]').ToLower(); if (-not $want) { return $null }
  $rn = @(Get-KitDeployRunRecords | ForEach-Object run | Where-Object { ($_ -replace '[^A-Za-z0-9]').ToLower() -eq $want } | Select-Object -Unique)
  if ($rn.Count -eq 1) { [pscustomobject]@{ kind = 'run'; id = $rn[0]; text = "run $($rn[0]) done" } }
}
# launch records (self-*.json and workflow records, not args files) with their run name
function Get-KitDeployRunRecords { @(Read-KitJsonFiles (Get-KitPath launches) | Where-Object { (Split-Path "$($_.file)" -Leaf) -notlike 'args-*' } | ForEach-Object { $r = if ($_.run) { "$($_.run)" } elseif ($_.args.run) { "$($_.args.run)" }; if ($r) { $_ | Add-Member -Force NoteProperty run $r -PassThru } }) }
# run: launched and every launch record completed; tasks: each tracked (id or key) with all MRs merged (allMergedAt) or done
function Test-KitDeployCondition($Cond) {
  if ($Cond.kind -eq 'run') {   # the newest record per script: a relaunch supersedes an older open one
    $rs = @(Get-KitDeployRunRecords | Where-Object run -eq $Cond.id | Group-Object { Split-Path "$($_.script)" -Leaf } | ForEach-Object { $_.Group | Sort-Object { try { [datetimeoffset]$_.at } catch { [datetimeoffset]::MinValue } } | Select-Object -Last 1 })
    return ($rs.Count -gt 0 -and -not @($rs | Where-Object { -not $_.completed }).Count) }
  $tks = @((Read-KitTracking).tasks.Values)
  -not @($Cond.keys | Where-Object { $k = $_; $tk = @($tks | Where-Object { "$($_.task)" -eq $k -or "$($_.key)" -eq $k })[0]; -not ($tk -and ($tk.allMergedAt -or $tk.done)) }).Count
}
# per env of the cached plan, its deploy words (decisions log, 30 d) and kit.local.json deploy.hold (env-wide, no word needed):
# the newest a no -> held until a later yes or an MR it did not cover (state ask: one fresh ask, then -Fold covers it; it covers its -Mrs,
# else the env's MRs when first seen, cache held.<env>); noAll / deploy.hold -> held whatever MRs come; a wait -> waiting until its retry
# (a HH:mm in the answer, else 20 min: the busy wait of deploy restart), then due; a yes after a wait of the last 12 h: that retry; a yes: go
# a wait / no on a condition (Get-KitDeployCondition): until (muted) -> met (one DEPLOY ASK, cache condAsked.<env> = its id) -> asked
function Get-KitDeployHolds($Cache, [string]$CacheFile, [datetime]$Now = (Get-Date), [switch]$Fold) {
  $hold = @{}; if (-not $Cache) { return $hold }
  $tgs = @(@(@($Cache.ask) | ForEach-Object { ("$_" -split ':', 2)[0].Trim() }) + @(@($Cache.ready) | ForEach-Object { "$_" -replace '\s*\(\d+ MR\(s\)\)$' }) | Where-Object { $_ } | Select-Object -Unique)
  if (-not $tgs.Count) { return $hold }
  $atOf = { param($d) if ($d.answeredAt -is [datetime]) { $d.answeredAt } else { try { [datetime]"$($d.answeredAt)" } catch { $Now } } }   # JSON gives a DateTime: "$x" drops the offset
  $words = @{}; foreach ($d in @(Read-KitLog decisions-log $Now.AddDays(-(Get-KitParam 'deploy.wordsDays')) | Where-Object { $_.event -eq 'answered' -and $_.gate -eq 'deploy' -and $_.kind -ne 'envfix' -and "$($_.answer)".Trim() } | Sort-Object { (& $atOf $_).ToUniversalTime().Ticks })) { foreach ($t in @(Split-KitList @("$($d.item)"))) { if (-not $words[$t]) { $words[$t] = [Collections.Generic.List[object]]::new() }; $words[$t].Add($d) } }
  $cfgHold = @(Split-KitList @(Get-KitSetting 'deploy.hold' @()))
  $waitOf = { param($t, $d) $ans = "$($d.answer)".Trim(); $at = & $atOf $d; $sid = if ("$($d.id)" -match '^(?:dec|envfix)-(.+)$') { $Matches[1] } else { ("$($d.id)" -split '-')[-1] }
    $retry = if ($ans -match '\b([01]?\d|2[0-3]):([0-5]\d)\b') { $rt = $at.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]); if ($rt -le $at) { $rt.AddDays(1) } else { $rt } } else { $at.AddMinutes((Get-KitParam 'deploy.waitRetryMinutes')) }
    $why = if ("$($d.question) $ans" -match '(?i)\bbusy\b') { 'host busy' } else { "wait ($($d.by))" }
    [pscustomobject]@{ target = $t; state = $(if ($Now -lt $retry) { 'waiting' } else { 'due' }); sid = $sid; why = $why; retry = $retry; text = "$t waiting: $why, retry $($retry.ToString('HH:mm')) ($sid)" } }
  $dirty = $false; $used = $null
  foreach ($t in $tgs) {
    if ($t -in $cfgHold) { $hold[$t] = [pscustomobject]@{ target = $t; state = 'held'; sid = 'deploy.hold'; new = @(); text = "$t held by config: deploy.hold" }; continue }
    $ws = @($words[$t] | Where-Object { $_ }); if (-not $ws.Count) { continue }
    $d = $ws[-1]; $sid = if ("$($d.id)" -match '^(?:dec|envfix)-(.+)$') { $Matches[1] } else { ("$($d.id)" -split '-')[-1] }; $kind = Get-KitDeployWordKind "$($d.answer)"
    $cond = if ($kind -in 'wait', 'no', 'noAll') { Get-KitDeployCondition "$($d.answer)" }
    if ($cond) { $askedId = "$(Get-KitMember $Cache.condAsked $t)"; $met = Test-KitDeployCondition $cond
      $st = if (-not $met) { 'until' } elseif ($askedId -eq "$($d.id)") { 'asked' } else { 'met' }
      if ($st -eq 'met' -and $Fold) { if (-not $Cache.condAsked) { $Cache | Add-Member -Force NoteProperty condAsked ([pscustomobject]@{}) }; $Cache.condAsked | Add-Member -Force NoteProperty $t "$($d.id)"; $dirty = $true }   # one ask a word
      $hold[$t] = [pscustomobject]@{ target = $t; state = $st; sid = $sid; why = $cond.text; text = $(if ($met) { "$t condition met: $($cond.text) ($sid), owner asked" } else { "$t held until $($cond.text) ($sid)" }) }; continue }
    if ($kind -eq 'wait') { $hold[$t] = & $waitOf $t $d }
    elseif ($kind -eq 'yes') {
      # a used yes is spent (its deploy ran): the env's MRs since need a new yes; the log's used event counts, the record file may be gone
      if ($null -eq $used) { $used = Get-KitUsedWords $Now.AddDays(-(Get-KitParam 'deploy.wordsDays')) }
      if ($used.ContainsKey("$($d.id)")) { $ub = $used["$($d.id)"]   # its deploy still runs (the user live on the board): muted, no second ask
        if ($ub -and @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { "$($_.agent)" -eq $ub -and $_.status -ne 'left' }).Count) { $hold[$t] = [pscustomobject]@{ target = $t; state = 'held'; sid = $sid; new = @(); text = "$t deploying: word $sid used by $ub" } }
        continue }
      $w = @($ws | Where-Object { (Get-KitDeployWordKind "$($_.answer)") -eq 'wait' -and ($Now - (& $atOf $_)).TotalHours -lt (Get-KitParam 'deploy.waitWordHours') } | Select-Object -Last 1)
      $pin = Get-KitDeployWordPin $d; $mrs = @(@((Get-KitMember $Cache.mrsOf $t)) | Where-Object { $_ })
      $cov = @($mrs | Where-Object { Test-KitDeployPinCovers $pin "$_" }); $out = @($mrs | Where-Object { "$_" -notin $cov })
      if ($pin.pinned -and $mrs.Count -and -not $cov.Count) { continue }   # the pin covers none of the batch: a new ask
      $hold[$t] = if ($w.Count) { & $waitOf $t $w[0] } else { [pscustomobject]@{ target = $t; state = 'go'; sid = $sid; by = $d.by; pin = $pin; cov = $cov; out = $out; text = "$t approved: $sid" } }
    }
    elseif ($kind -in 'no', 'noAll') {
      $by = if ($d.by) { $d.by } else { 'owner' }
      if ($kind -eq 'noAll') { $hold[$t] = [pscustomobject]@{ target = $t; state = 'held'; sid = $sid; new = @(); text = "$t held by $($by): $sid" }; continue }
      $known = $Cache.mrsOf -and @((Get-KitProps $Cache.mrsOf).Name) -contains $t   # an old cache without MR lists: held, nothing snapshotted
      $mrs = @(@((Get-KitMember $Cache.mrsOf $t)) | Where-Object { $_ }); $snap = (Get-KitMember $Cache.held $t); $mine = $snap -and "$($snap.id)" -eq "$($d.id)"
      $cov = @(@($d.mrs) + @(if ($mine) { $snap.mrs } elseif (-not @($d.mrs).Count) { $mrs }) | Where-Object { $_ } | ForEach-Object { Get-CanonMr "$_" })
      $new = @($mrs | Where-Object { (Get-CanonMr "$_") -notin $cov })
      if ($known -and ((-not $mine -and -not @($d.mrs).Count) -or ($Fold -and $new.Count))) {
        if (-not $Cache.held) { $Cache | Add-Member -Force NoteProperty held ([pscustomobject]@{}) }
        $Cache.held | Add-Member -Force NoteProperty $t ([pscustomobject]@{ id = "$($d.id)"; mrs = @(@($cov) + @($new | ForEach-Object { Get-CanonMr "$_" }) | Select-Object -Unique) }); $dirty = $true
      }
      $hold[$t] = [pscustomobject]@{ target = $t; state = $(if ($new.Count) { 'ask' } else { 'held' }); sid = $sid; new = $new; text = "$t held by $($by): $sid" }
    }
  }
  if ($dirty -and $CacheFile) { $Cache | ConvertTo-Json -Depth 5 | Set-Content $CacheFile -Encoding utf8 }
  $hold
}
# repo name -> its deploy branches' heads ("<sha>\trefs/heads/<b>;..."), one git ls-remote a repo a process (= a beat), run side by
# side; $null = unknown (no checkout, no deploy branch, a failed call)
function Get-KitDeployHeads([string[]]$Names) {
  if ($null -eq $script:KitDeployHeads) { $script:KitDeployHeads = @{} }
  $c = $script:KitDeployHeads; $runs = @{}
  foreach ($n in @($Names | Where-Object { $_ -and -not $c.ContainsKey($_) } | Select-Object -Unique)) {
    $c[$n] = $null; $rp = @(@(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $n })[0]
    $bs = @(@($rp.deploys) | ForEach-Object { "$($_.branch)" } | Where-Object { $_ } | Sort-Object -Unique)
    if ($bs.Count -and $rp.checkout -and (Test-Path -LiteralPath $rp.checkout)) { $runs[$n] = try { Start-KitExe 'git' (@('-C', "$($rp.checkout)", 'ls-remote', 'origin') + @($bs | ForEach-Object { "refs/heads/$_" })) } catch { $null } }
  }
  foreach ($n in @($runs.Keys)) { if (-not $runs[$n]) { continue }; $x = Receive-KitExe $runs[$n] 20; if (-not $x.code -and "$($x.out)".Trim()) { $c[$n] = @("$($x.out)" -split "`r?`n" | Where-Object { $_ } | Sort-Object) -join ';' } }
  $c
}
# a probe's rows need no new probe while the heads hold: every row live, n/a, or not on its deploy branch yet (a deploy job or host
# install can finish with the head unchanged: those rows are asked again)
function Test-KitDeployRowsSettled($Rows) { @($Rows).Count -and -not @($Rows | Where-Object { $_.state -notin 'DEPLOYED', 'N/A' -and -not ($_.state -eq 'NOT-DEPLOYED' -and "$($_.detail)" -like 'not on * yet') }).Count }
# supervise (called from Invoke-Supervise: $now, Within and Invoke-Bounded are its own): -AutoFix moves a done task that is live on a
# test env to inTest (never before); the deploy plan is cached 1 h (a failed refresh keeps the last good one, marked stale): READY envs are report info, DEPLOY ASK only under trigger ask
function Get-KitSuperviseFlagsDeploys([switch]$AutoFix) {
  $flag = { param($level, $what, $action) [pscustomobject]@{ level = $level; what = $what; action = $action } }; $holds = $null; $qaRunsByTask = $null
  if ($AutoFix) {
    foreach ($o in @((Read-KitTracking).tasks.Values)) {
      if (-not (Within 'deploy checks')) { break }
      # a repo may deploy to several test envs
      if (-not $o.done -or -not $o.doneAt -or ($now - [datetime]$o.doneAt).TotalDays -gt (Get-KitParam 'deploy.doneLookbackDays')) { continue }
      # a QA run covers only the promotion it tested: one started before doneAt (a reopen, a fix wave) never holds the inTest move
      $doneT = [datetime]$o.doneAt; $after = { param($r) if ($r -eq 'closed') { return $true }; $rs = Get-KitQaRunStart $r; $null -ne $rs -and $rs -ge $doneT }
      if (@($o.qaCovered | Where-Object { & $after "$_" }).Count) { continue }
      if ($o.liveCheckedAt -and ($now - [datetime]$o.liveCheckedAt).TotalMinutes -lt $(if (@($o.liveOn).Count) { 60 } else { 10 })) { continue }
      # a QA run already covers it: skip the deploy lookup (10+ calls); exact id: 12 is no AB-12
      # one read of the run.json files per sweep, not per task (each task re-walked 12k QA files)
      if ($null -eq $qaRunsByTask) { $qaRunsByTask = @{}; foreach ($rf in @(Get-KitQaRunFiles run.json)) { $j = try { [IO.File]::ReadAllText($rf.FullName) | ConvertFrom-Json } catch { $null }; foreach ($qid in @(@($j.items.subtasks.id) + @($j.tracker.parent) | ForEach-Object { "$_" } | Where-Object { $_ } | Select-Object -Unique)) { $qaRunsByTask[$qid] = @(@($qaRunsByTask[$qid] | Where-Object { $_ }) + $rf.Directory.Name) } } }
      $covered = @($qaRunsByTask["$($o.task)"] | Where-Object { $_ -and (& $after "$_") })
      if ($covered.Count) { Set-KitTaskFields $o.task @{ qaCovered = @($covered) }; continue }
      # heads of its repos' deploy branches unmoved since its last settled answer: no probe (D13: 111 host verbs a beat re-asked them)
      $rns = @(@($o.mrs) | ForEach-Object { ((Get-CanonMr (ConvertTo-MrRef "$_")) -split '!', 2)[0] } | Where-Object { $_ } | Sort-Object -Unique)
      $hs = Get-KitDeployHeads $rns; $hk = if ($rns.Count -and -not @($rns | Where-Object { -not $hs[$_] }).Count) { "$(@($o.mrs | Sort-Object) -join ',')|$(@($rns | ForEach-Object { "$_=$($hs[$_])" }) -join '|')" }   # its MR list too: a new MR is asked
      if ($hk -and $o.liveSettled -and $o.liveHeads -eq $hk) { Set-KitTaskFields $o.task @{ liveCheckedAt = (Get-KitStamp stored $now) }; continue }
      $raw = @(Invoke-Bounded $KitCmd.qa @('deployed', '-Mrs', (@($o.mrs) -join ','), '-Json'))   # a background run: none yet (started now, still running) or failed = ask again next round
      if (($raw -join "`n").Trim() -notmatch '^[\[{]') { foreach ($w in @($raw -match '^WATCH ')) { & $flag 'WATCH' "deployed check $($o.task): $($w -replace '^WATCH ')" 'Supervise checks it again next round.' }; continue }
      $rows = @($raw | Out-String | ConvertFrom-Json)
      $o.liveCheckedAt = (Get-KitStamp stored $now)
      $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -notin 'DEPLOYED', 'N/A' }).Count -and @($rows | Where-Object { $_.target -eq $t -and $_.state -eq 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
      $new = @($live | Where-Object { $_ -notin @($o.liveOn) })
      # these rows came from the run started last time (heads then: livePending); the run started now sees $hk
      $fields = @{ liveCheckedAt = $o.liveCheckedAt; liveHeads = $o.livePending; liveSettled = [bool]($o.livePending -and (Test-KitDeployRowsSettled $rows)); livePending = $hk }
      if ($new.Count) { $fields.liveOn = @(@($o.liveOn) + $new | Where-Object { $_ } | Select-Object -Unique) }
      Set-KitTaskFields $o.task $fields
      if ($new.Count -and (Test-TrackerStatus $(try { (Get-TrackerTask $o.task).status } catch { '' }) 'closed')) { Set-KitTaskFields $o.task @{ qaCovered = @('closed') }; continue }
      if ($new.Count) { Set-KitTaskFields $o.task @{ inTestDue = (Get-KitStamp stored $now) } }
    }
    # in test: opsy moves every promoted task after its deploy; the safety net (owner 2026-11-23): while no opsy is live, ALL promoted
    # tasks (tracked + trackerLists, whoever deployed) when a task went live or every deploy.inTestSweepMinutes; one background run
    $due = @((Read-KitTracking).tasks.Values | Where-Object { $_.inTestDue -and ($now - [datetime]$_.inTestDue).TotalHours -lt (Get-KitParam 'deploy.inTestDueHours') } | ForEach-Object task | Sort-Object)
    $swf = Join-Path (Get-KitPath deploys -Create) 'intest-sweep.json'; $swAt = try { [datetime](Get-Content $swf -Raw | ConvertFrom-Json).at } catch { [datetime]::MinValue }
    $opsy = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { ($_.type -eq 'opsy' -or "$($_.agent)" -match '^opsy') -and $_.status -ne 'left' -and (Test-KitHolder $_) -ne $false -and (-not $_.beat -or ($now - [datetime]$_.beat).TotalMinutes -lt (Get-KitParam 'deploy.opsyBeatMinutes')) }).Count
    $out = @(if (-not $opsy -and (($due.Count -and ($now - $swAt).TotalMinutes -ge (Get-KitParam 'deploy.inTestRetryMinutes')) -or ($now - $swAt).TotalMinutes -ge (Get-KitParam 'deploy.inTestSweepMinutes'))) {   # a due retry: at most every 10 min
        Set-Content $swf (@{ at = (Get-KitStamp stored $now) } | ConvertTo-Json -Compress) -Encoding utf8; foreach ($t1 in $due) { Set-KitTaskFields $t1 @{ inTestDue = $null } }
        Invoke-Bounded $KitCmd.orch @('deploy', 'intest', '-Apply') })
    foreach ($l2 in $out) {
      if ($l2 -match '^WATCH ') { & $flag 'WATCH' "deploy intest: $($l2 -replace '^WATCH ')" 'Supervise runs it again next round.'; continue }
      if ($l2 -match '^MARKED\s+(?<t>\S+)\s+in test \((?<l>[^|]*?)\)\s*(\||$)') { & $flag 'INFO' "auto-fixed: FIXED $($Matches.t): promoted -> in test, every MR live ($($Matches.l))" 'Tracker set to inTest; nothing to do.' }
      elseif ($l2 -match '^ERROR (?<t>\S+)\s+(?<w>.*)') { Set-KitTaskFields $Matches.t @{ inTestDue = (Get-KitStamp stored $now) }; & $flag 'WATCH' "STATUS $($Matches.t): every MR live, still promoted: $($Matches.w)" "& $($KitCmd.dev) tracker status $($Matches.t) inTest (supervise retries next round)" }
      elseif ($l2 -match '^WAIT\s+(?<t>\S+)\s+(?<w>[^|]*(not checked|timed out|UNKNOWN)[^|]*?)\s*(\||$)') { & $flag 'WATCH' "STATUS $($Matches.t): deployed state unknown: $($Matches.w)" 'Supervise checks it again next round; still unknown: & bossy.ps1 deploy intest -Task <id> shows the probe (opsy kind status).' }
    }
  }
  if (Within 'deploy plan') {
    $pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'
    $cache = if (Test-Path $pc) { try { Get-Content $pc -Raw | ConvertFrom-Json } catch { $null } }
    $plan = $null; $asked = $null
    if (-not $cache -or ($now - [datetime]$cache.at).TotalMinutes -ge (Get-KitParam 'deploy.planCacheMinutes')) {
      $from = $cache.asked; $asked = (Get-KitStamp stored $now)   # a background run: this call returns the plan started at the last ask and starts a fresh one
      $out = @(Invoke-Bounded $KitCmd.orch @('deploy', 'plan', '-Json', '-TimeoutSec', [int](Get-KitParam 'deploy.planTimeoutSec')))
      # timed out, still running in the background or failed (no JSON): keep the last good plan, plan again next round
      try { if (($out -join "`n").Trim() -match '^[\[{]') { $plan = @($out | Out-String | ConvertFrom-Json -ErrorAction Stop | Where-Object { $_ }) } } catch { $plan = $null }
      if ($null -eq $plan) { foreach ($w in @($out | Where-Object { $_ -match '^WATCH ' })) { & $flag 'WATCH' "deploy plan: $($w -replace '^WATCH ')" 'Kept the last good plan; supervise plans again next round.' } }
    }
    if ($null -ne $plan) {
      $mrsOf = [ordered]@{}; foreach ($p in @($plan | Where-Object { $_.status -in 'READY', 'ASK' -and $_.target })) { $mrsOf["$($p.target)"] = @(@($p.mrs) | ForEach-Object mr) }
      $cache = [pscustomobject]@{ at = $(if ($from) { $from } else { (Get-KitStamp stored $now) }); ready = @($plan | Where-Object status -in 'READY', 'ASK' | ForEach-Object { "$($_.target) ($(@($_.mrs).Count) MR(s))" }); ask = @($plan | Where-Object { $_.status -eq 'ASK' -and $_.target -and @($_.mrs).Count } | ForEach-Object { "$($_.target): $(@($_.mrs).Count) MR(s) ($((@($_.mrs) | ForEach-Object mr) -join ', '))" }); mrsOf = [pscustomobject]$mrsOf; held = $cache.held; condAsked = $cache.condAsked
        outOfArea = @($plan | ForEach-Object { @($_.mrs) } | Where-Object { $_.outOfArea } | ForEach-Object { "$($_.mr) ($(@($_.outOfArea).Count) file(s) outside its area)" } | Select-Object -Unique) }
    }
    if ($asked -and $cache -and $null -eq $plan -and $cache.asked -and -not @($out -match '^WATCH ').Count) { $asked = $null }   # no output: the run of the last ask still goes, keep its time
    if ($asked -and $cache) { $cache | Add-Member -Force NoteProperty asked $asked; $cache | ConvertTo-Json -Depth 4 | Set-Content $pc -Encoding utf8 }
    $askAge = if ($cache.at) { [int]($now - [datetime]$cache.at).TotalMinutes } else { 0 }
    $askStale = if ($askAge -ge 60) { " (plan $askAge min old, refresh pending: plan again before asking)" } else { '' }
    $holds = Get-KitDeployHolds $cache $pc $now -Fold:$AutoFix
    foreach ($a in @($cache.ask | Where-Object { "$_".Trim() -and ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower() -eq 'ask' })) {
      $h = $holds[("$a" -split ':', 2)[0].Trim()]
      if ($h.state -in 'held', 'waiting', 'until', 'met', 'asked') { continue }   # its muted line below; met: the ask below
      if ($h.state -eq 'due') { & $flag 'ACT' "DEPLOY RETRY $($h.target): $($h.why), wait $($h.sid) due since $($h.retry.ToString('HH:mm'))" "Deploy $($h.target) again per its deploy rules (the busy check runs first); still busy: a new wait with its retry time (decide record -Gate deploy -Item $($h.target) -Answer 'wait: retry HH:mm')."; continue }
      if ($h.state -eq 'go') { $pn = $h.pin; $pt = if ($pn.commit -and -not @($pn.mrs).Count) { " pinned at $($pn.commit): only MRs at or before it$(if (@($h.out).Count) { ", never $(@($h.out) -join ', ')" }), later ones need a new yes;" } elseif ($pn.pinned) { " pinned$(if ($pn.commit) { " at $($pn.commit)" }): covers $(@($h.cov).Count) MR(s) ($(@($h.cov) -join ', '))$(if (@($h.out).Count) { "; not covered, a new yes: $(@($h.out) -join ', ')" })" } else { ", $(("$a" -split ':', 2)[1].Trim())" }
        & $flag 'ACT' "DEPLOY GO $($h.target): approved ($($h.sid), $($h.by))$pt not deployed" "Deploy $($h.target) now with that decision (opsy, bossy E5)$(if ($pn.commit) { ", deploy merge -Commit $($pn.commit)" })$(if ($pn.pinned) { ', only the MRs it covers' }); no ask."; continue }
      & $flag 'ACT' "DEPLOY ASK $a merged, not deployed, window open$(if ($h.state -eq 'ask') { " (new since hold $($h.sid): $($h.new -join ', '))" })$askStale" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; their yes: decide record -Gate deploy -Item <env> -Source askuser, its id to opsy; after the deploy: deploy record -Env <target> -Mrs <refs>, then deploy intest -Apply."
    }
    # a condition wait that now holds: the owner asked to be asked (any deploy.trigger), once a word
    foreach ($h in @($holds.Values | Where-Object state -eq 'met')) { & $flag 'ACT' "DEPLOY ASK $($h.target): $($h.why) (wait $($h.sid)), merged, not deployed" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; their yes: decide record -Gate deploy -Item <env> -Source askuser, its id to opsy." }
  }
  # what waits for a person's deploy <env> (the cached plan): INFO lines of the supervise report; a held or waiting env: one muted line
  $pcf = Join-Path (Get-KitPath deploys) 'plan-cache.json'
  $pcd = try { Get-Content $pcf -Raw | ConvertFrom-Json } catch { $null }
  if ($null -eq $holds) { $holds = Get-KitDeployHolds $pcd $pcf $now }
  $age = if ($pcd.at) { [int]($now - [datetime]$pcd.at).TotalMinutes } else { 0 }
  $stale = if ($age -ge 60) { "; plan $age min old, refresh pending" } else { '' }
  if (($oa = @($pcd.outOfArea | Where-Object { $_ })).Count) { [pscustomobject]@{ info = "deploy batch has OUT-OF-AREA MR(s): $($oa -join ', ') (bossy.ps1 deploy plan lists the files; tell the owner before any deploy <env>)" } }
  foreach ($r in @($pcd.ready | Where-Object { $_ })) { $h = $holds["$r" -replace '\s*\(\d+ MR\(s\)\)$']; [pscustomobject]@{ info = $(if ($h.state -in 'held', 'waiting', 'until', 'asked') { "deploy $($h.text)" } else { "deploy ready: $r (waits for a person's deploy <env>$stale)" }) } }
}
