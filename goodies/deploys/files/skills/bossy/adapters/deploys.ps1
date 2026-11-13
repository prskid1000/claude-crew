<#
deploys.ps1 (goody deploys): the deploy batch of bossy E5, dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 deploy plan [-Env <target>] [-Json] [-Offline <fixture>] [-TimeoutSec <deploy.deployedTimeoutSec, 100>]   merged-not-deployed MRs per test env, trigger, window
  bossy.ps1 deploy request -Mrs <refs> -Run <run> [-Note ..] · record -Env <target> [-Mrs <refs>] [-By ..] [-Note ..]
  bossy.ps1 deploy intest [-Apply] [-Quiet] [-Task <ids> | -Mrs <refs>] [-Days 14]   promoted tasks (tracked: done in -Days; the owner's in trackerLists; -Mrs: their tasks) whose MRs are live on a test env -> inTest; last line: tasks checked, where from, a count per outcome
  bossy.ps1 deploy merge ...   adapters/deploy_merge.ps1
  bossy.ps1 deploy restart -Env <target>[,..] [-Service <a,b>] [-WaitMinutes 20] [-RecheckSeconds 120] [-Ungated]   an ssh deploy's services; ssh.busy re-checked on the host right before each restart: busy past -WaitMinutes = REFUSED (exit 3)
supervise -AutoFix calls Get-KitSuperviseFlagsDeploys: a done task live on a test env -> inTest (one background run); the plan cached 1 h (DEPLOY ASK; an env's newest deploy word no / wait: one muted held / waiting line).
Sections: L14 helpers · L93 intest · L207 deploy · L367 restart · L400 supervise
Exit codes: 0 ok · 1 failed / unknown (restart) · 2 usage · 3 restart refused: the host stayed busy.
#>
#Requires -Version 7
. (Join-Path $PSScriptRoot '../../pokey/adapters/deployed_checks.ps1')   # Get-DeployPaths, Test-DeployTouched: one paths rule for plan, intest, deployed
# ---- helpers: test-env filter, MR refs
# not a test env: deploys[].production, else productionPattern on the name; -Lanes: + laneApk
function Get-NoTestRx([switch]$Lanes) { $rx = Get-KitSetting 'deploy.productionPattern' '(?i)prod|critical'; $n = @(@(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and ($(if ($null -ne $_.production) { $_.production } else { $_.target -match $rx }) -or ($Lanes -and $_.laneApk)) } | ForEach-Object { [regex]::Escape($_.target) }); "^($($n -join '|'))$" }
# <alias>!<iid> -> <repo name>!<iid>
function Get-CanonMr([string]$m) {
  if ($m -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $m }
  $rp = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $Matches.r -or @($_.aliases) -contains $Matches.r } | Select-Object -First 1
  if ($rp) { "$($rp.name)!$($Matches.i)" } else { $m }
}
# an MR's target branch, one host call per MR and process; $null = unknown
function Get-MrTargetBranch([string]$Mr, $Fx) {
  $c = Get-CanonMr (ConvertTo-MrRef $Mr); if ($Fx) { return ($Fx.mrs.$Mr ?? $Fx.mrs.$c).targetBranch }
  if (-not $script:KitMrTb) { $script:KitMrTb = @{} }
  if ($script:KitMrTb.ContainsKey($c)) { return $script:KitMrTb[$c] }
  $rn, $iid = $c -split '!', 2; $v = try { (Invoke-HostApi "projects/$(Get-HostProject (($rn -split '/')[-1]))/merge_requests/$iid").target_branch } catch { $null }
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
  $fm = if ($Fx) { $Fx.mrs.$Mr ?? $Fx.mrs.$c }
  $tb = Get-MrTargetBranch $Mr $Fx
  $own = @($deps | Where-Object { $_.branch -and $_.branch -eq $tb }); if ($own.Count) { return @($own.target | Select-Object -Unique) }
  if (-not $filt) { return @($deps.target | Select-Object -Unique) }
  $deps = @($deps | Where-Object { -not $_.from -or -not $tb -or $tb -in @($_.from) })
  $files = @(); $cut = $false
  if (-not $NoPaths -and @($deps | Where-Object { @(Get-DeployPaths $_).Count }).Count) {
    $ch = if ($Fx) { [pscustomobject]@{ changes = @($fm.paths | ForEach-Object { [pscustomobject]@{ new_path = $_ } }); overflow = $fm.overflow } } else { try { Invoke-HostApi "projects/$(Get-HostProject $rn)/merge_requests/$iid/changes?access_raw_diffs=true" } catch { } }
    $files = @(@($ch.changes) | ForEach-Object { $_.new_path; $_.old_path } | Where-Object { $_ } | Select-Object -Unique)
    $cut = [bool]$ch.overflow -or @($ch.changes).Count -ge 100   # gitlab overflow, github's first page: the list is partial
  }
  @($deps | Where-Object {
      $cut -or -not $files.Count -or (Test-DeployTouched $_ $files)
    } | ForEach-Object target | Select-Object -Unique)
}
# MRs in a CI deploy's last green job (its commit holds the merge): mr|target -> detail; per repo one MR list and one git
# rev-list per deploy instead of one pokey.ps1 deployed probe per MR (229 MRs ran past 600 s); past $Until the rest is probed
function Get-DeployedByAncestry([string[]]$Mrs, $Repos, [string[]]$Targets, [int]$Days = 14, [datetime]$Until = (Get-Date).AddSeconds(200)) {
  $hit = @{}; $env:GIT_TERMINAL_PROMPT = '0'
  foreach ($rp in $Repos) {
    if ((Get-Date) -gt $Until) { break }
    $dir = [string]$rp.checkout
    $deps = @($rp.deploys | Where-Object { $_.target -in $Targets -and $_.branch -and $_.job -and -not ($_.ssh -or $_.awsStack -or $_.probe -or $_.tag -or $_.manual -or $_.laneApk) })
    $want = @{}; foreach ($m in $Mrs) { $c = Get-CanonMr (ConvertTo-MrRef $m); if ($c -match "^$([regex]::Escape($rp.name))!(\d+)$") { $want[$Matches[1]] = $m } }
    if (-not $want.Count -or -not $deps.Count -or -not $dir -or -not (Test-Path $dir)) { continue }
    $p = Get-HostProject $rp.name; $shaOf = @{}; $tb = @{}; $got = @{}; $det = @{}
    $after = (Get-Date).AddDays( - ($Days + 1)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    for ($pg = 1; $pg -le 5 -and $shaOf.Count -lt $want.Count -and (Get-Date) -lt $Until; $pg++) {   # newest first; an MR not listed is probed as before
      $page = @(try { Invoke-HostApi "projects/$p/merge_requests?state=merged&updated_after=$after&order_by=updated_at&per_page=100&page=$pg" } catch { }) | Where-Object { $_ }
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
      foreach ($pl in @(try { Invoke-HostApi "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10" } catch { }) | Where-Object { $_ -and $_.sha }) {
        $job = @(try { Invoke-HostApi "projects/$p/pipelines/$($pl.id)/jobs?per_page=100" } catch { }) | Where-Object { $_.name -like $d.job } | Select-Object -First 1
        if ($job.status -eq 'success') { $base = [string]$pl.sha; break }
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
# deployed promoted tasks -> inTest
function Invoke-MarkInTest {
param([switch]$Apply, [switch]$Quiet, [string[]]$Task = @(), [int]$TimeoutSec = 100, [int]$Days = 14, [string[]]$FromMrs = @())   # not $Mrs: pwsh names ignore case ($mrs below)
$ErrorActionPreference = 'SilentlyContinue'
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }
# -Mrs (what opsy deployed): the kit maps each MR to its task (tracking, else the tag in its title), never the caller
$track = (Read-KitTracking).tasks
foreach ($m in @($FromMrs | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })) {
  $c = Get-CanonMr (ConvertTo-MrRef $m); $rn, $iid = $c -split '!', 2
  $own = @($track.Keys | Where-Object { $_ -notmatch '!|\s' -and @($track[$_].mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) }) -contains $c })
  if (-not $own.Count -and ($rx = Get-KitTaskTagRx) -and "$(try { (Invoke-HostApi "projects/$(Get-HostProject (($rn -split '/')[-1]))/merge_requests/$iid").title } catch { })" -match $rx) { $own = @($Matches.id) }
  Out-Line "MAP   $c -> $(if ($own.Count) { $own -join ', ' } else { 'no task (untracked, no tag in its title)' })"; $Task = @(@($Task) + $own)
}
if ($FromMrs.Count -and -not $Task.Count) { return }

# candidates: tasks this kit promoted in $Days (deploy plan's window: older ones it no longer offers), plus list tasks assigned to
# the owner (tracker.owner); -Task: those
$cand = [ordered]@{}   # tracking: tasks/<id>.json (skills/bossy/STATE.md)
foreach ($id in @($track.Keys)) { $o = $track[$id]; if ($Task.Count -or ($o.done -and $o.doneAt -and ((Get-Date) - [datetime]$o.doneAt).TotalDays -le $Days)) { $cand[$id] = @{ mrs = @($o.mrs); name = '' } } }
$nKit = $cand.Count; $nList = 0   # the summary says where the checked tasks came from
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
$lists = @(Get-KitValue 'trackerLists' @()) | Where-Object { $_ } | Select-Object -Unique
if ($lists.Count -and -not $ownerId -and -not $Task.Count) { Out-Line "SKIP  trackerLists: the owner is unknown (tracker.owner), so other people's tasks stay out" }
elseif ($lists.Count) {
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l 'promoted') } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name }; $nList++ } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes a,b as one string
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }

$productTargets = @(Get-KitValue 'productTargets' @()); $repos = @(Get-KitValue 'repos' @())
$recOf = @{}; $dlog = Get-KitPath deploy-log   # recorded deploys: mr|target
if (Test-Path $dlog) { foreach ($x in @(Get-Content $dlog | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })) { foreach ($m in @($x.mrs)) { $recOf["$(Get-CanonMr (ConvertTo-MrRef $m))|$($x.target)"] = 1 } } }
$pathMemo = @{}
function Get-MrPaths([string]$mr) {
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = Invoke-HostApi "projects/$(Get-HostProject $repo)/merge_requests/$iid/changes"
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

$gone = @(); $tally = [ordered]@{}   # outcome -> task ids (and why)
function Add-Tally([string]$Outcome, [string]$Detail) { if (-not $tally.Contains($Outcome)) { $tally[$Outcome] = [Collections.Generic.List[string]]::new() }; $tally[$Outcome].Add($Detail) }
foreach ($id in $cand.Keys) {
  # a task deleted in the tracker: skipped, reported, dropped from tracking; another task's failure never ends the batch
  $info = try { Get-TrackerTask $id } catch { if (Remove-KitGoneTask $id $_) { $gone += $id; Add-Tally 'deleted in the tracker' $id; Out-Line "GONE  $id  deleted in the tracker: skipped, no longer tracked" } else { Add-Tally 'unreadable' "$id`: $($_.Exception.Message)"; Out-Line "ERROR $id  tracker view failed: $($_.Exception.Message)" }; continue }
  if (-not $info) { Add-Tally 'unreadable' "$id`: the tracker returned nothing"; if ($Task.Count) { Out-Line "SKIP  $id  the tracker returned nothing" }; continue }
  if (-not (Test-TrackerStatus ([string]$info.status) 'promoted')) {   # never override a person
    Add-Tally $(if (Test-TrackerStatus ([string]$info.status) 'closed') { 'already closed' } elseif (Test-TrackerStatus ([string]$info.status) 'inTest') { 'already in test' } else { "now '$($info.status)'" }) $id
    if ($Task.Count) { Out-Line "SKIP  $id  status '$($info.status)', not promoted" }; continue }
  $name = if ($info.name) { $info.name } else { $cand[$id].name }
  $short = if ($name.Length -gt 70) { $name.Substring(0, 70) } else { $name }
  $mrs = @($cand[$id].mrs | Where-Object { $_ })
  if (-not $mrs.Count -and $KitConf.TrackerRepos) {
    $tag = "$($KitConf.TrackerTag)$id"
    foreach ($r in @($KitConf.TrackerRepos)) {
      $res = Invoke-HostApi "projects/$(Get-HostProject $r)/merge_requests?search=$([uri]::EscapeDataString($tag))&state=merged&per_page=20"
      foreach ($m in @($res)) { if ($m.iid -and ("$($m.title) $($m.source_branch)" -match [regex]::Escape($tag))) { $mrs += "$r!$($m.iid)" } }
    }
    $mrs = @($mrs | Select-Object -Unique)
  }
  if (-not $mrs.Count) { Add-Tally 'no MRs found' $id; Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $live = @(); $why = $null
  foreach ($mr in $mrs) {
    $rows = @(& $KitCmd.qa deployed -Mrs $mr -Json -Exclude (Get-NoTestRx) 2>$null | Out-String | ConvertFrom-Json)
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
  if ($why) { Add-Tally 'not deployed yet' $id; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Add-Tally 'would move to in test (no -Apply)' $id; Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    Set-TrackerStatus $id 'inTest'
    $null = Set-TrackerKitComment $id 'comment-intest' ("In test: every MR is deployed on a test env (checked " + [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + " UTC): " + ($live -join '; ') + '.')
    Add-Tally 'moved to in test' $id; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Add-Tally 'blocked' "$id`: $($_.Exception.Message)"; Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
if (-not $Quiet -or $gone.Count -or $tally.Contains('blocked') -or $tally.Contains('unreadable')) { Format-KitInTestSummary $cand.Count $nKit $nList $Days ([bool]$Task.Count) $tally }
}
# "mark-in-test: <n> tasks checked (<where from>): <n> <outcome>, ..."; ids where a person acts (blocked, unreadable, deleted)
function Format-KitInTestSummary([int]$Total, [int]$FromKit, [int]$FromLists, [int]$Days, [bool]$Named, $Tally) {
  $src = if ($Named) { 'the tasks named (-Task / -Mrs)' } else { @(if ($FromKit) { "$FromKit promoted by the kit in $Days d, subtasks included" }; if ($FromLists) { "$FromLists more assigned to you in trackerLists" }) -join ', ' }
  $order = @('moved to in test', 'would move to in test (no -Apply)', 'already closed', 'already in test') + @($Tally.Keys | Where-Object { $_ -like 'now *' }) + @('not deployed yet', 'no MRs found', 'blocked', 'unreadable', 'deleted in the tracker')
  $parts = foreach ($k in $order | Where-Object { $Tally.Contains($_) }) { "$($Tally[$k].Count) $k$(if ($k -in 'blocked', 'unreadable', 'deleted in the tracker') { " ($($Tally[$k] -join '; '))" })" }
  "mark-in-test: $Total task(s) checked$(if ($src) { " ($src)" }): $(if ($parts) { $parts -join ', ' } else { 'nothing to do' })"
}

# ---- deploy: plan, request, record
function Invoke-Deploy {  param([Parameter(Position = 0)][ValidateSet('plan', 'request', 'record', 'merge', 'intest', 'restart')][string]$Action = 'plan',
    [string]$Env, [string[]]$Mrs = @(), [string]$Run, [string]$Note, [string]$By = 'owner', [switch]$Json, [string]$Offline, [int]$Days = 14,
    [string]$Repo, [string]$To, [string]$From, [string]$Check, [switch]$Push, [switch]$Mr, [string]$Decision, [int]$WaitMinutes = 45, [int]$History = 300,
    [string]$Service, [int]$RecheckSeconds = 120, [switch]$Ungated,
    [switch]$Apply, [switch]$Quiet, [string[]]$Task = @(), [int]$TimeoutSec = (Get-KitParam 'deploy.deployedTimeoutSec'))
  if ($Action -eq 'restart') {
    if (-not $Env) { 'usage: deploy restart -Env <target>[,<target>..] [-Service <a,b>] [-WaitMinutes 20] [-Ungated]'; exit 2 }
    Invoke-DeployRestart @(Split-KitList @($Env)) $Service $(if ($PSBoundParameters.ContainsKey('WaitMinutes')) { $WaitMinutes } else { 20 }) $RecheckSeconds -Ungated:$Ungated; return
  }
  if ($Action -eq 'merge' -and (-not $Repo -or -not $To)) { throw "deploy merge: -$(if (-not $Repo) { 'Repo' } else { 'To' }) missing. Usage: bossy.ps1 deploy merge -Repo <checkout> -To <env|deploy branch> [-From <branch>] -Mr [-Mrs <refs>] [-Decision <id>] (tag deploys: -Push)" }
  if ($Action -eq 'merge') { $mergeFn = Assert-KitExtra Invoke-DeployMerge 'deploy merge' 'deploys'; & $mergeFn -Repo $Repo -To $To -From $From -Check $Check -Push:$Push -Mr:$Mr -Mrs $Mrs -Decision $Decision -WaitMinutes $WaitMinutes -History $History; return }
  if ($Action -eq 'intest') { Invoke-MarkInTest -Apply:$Apply -Quiet:$Quiet -Task $Task -Days $Days -FromMrs @(Split-KitList $Mrs); return }
  $Mrs = @(Split-KitList $Mrs)
  $dd = Get-KitPath deploys -Create; $pf = Join-Path $dd 'pending.json'; $log = Get-KitPath deploy-log -Create
  $fx = if ($Offline) { Get-Content $Offline -Raw | ConvertFrom-Json } else { $null }
  $pendEdit = { param($b) Invoke-KitLocked $pf { $p = if (Test-Path $pf) { Get-Content $pf -Raw | ConvertFrom-Json } else { [pscustomobject]@{ requests = @() } }; & $b $p; $p | ConvertTo-Json -Depth 5 | Set-Content $pf -Encoding utf8 } }   # change pending.json under its lock
  if ($Action -eq 'request') {
    if (-not $Mrs.Count) { 'usage: deploy request -Mrs <repo>!<iid>,... -Run <run> [-Note ..]'; exit 2 }
    $Mrs = @($Mrs | ForEach-Object { ConvertTo-MrRef $_ })
    & $pendEdit { param($p) $p.requests = @(@($p.requests) + [pscustomobject]@{ at = (Get-Date).ToString('s'); run = $Run; mrs = $Mrs; note = $Note }) }
    "requested a deploy for $($Mrs -join ', ') ($Run)"
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
    if (Test-Path $pf) { & $pendEdit { param($p) foreach ($q in @($p.requests)) { $q.mrs = @(@($q.mrs) | Where-Object { -not $done.Count -or (Get-CanonMr (ConvertTo-MrRef $_)) -notin $done }) }; $p.requests = @(@($p.requests) | Where-Object { @($_.mrs).Count }) } }
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
    foreach ($m in @($t.mrs)) {
      # live on every test env of its repo (supervise liveOn): nothing to deploy, no lookup
      $need = @($tOf[(& $repoOf $m)] | Where-Object { $_ -in $targets })
      if ($need.Count -and -not @($need | Where-Object { $_ -notin @($t.liveOn) }).Count) { continue }
      $taskOf[$m] = $t.task; $cand[$m] = 'tracked'
    }
  }
  $pend = @()   # a request older than -Days expires (the plan's window; deploys by CI never record it)
  $stale = { param($q) $q.at -and $(try { ((Get-Date) - [datetime]$q.at).TotalDays -gt $Days } catch { $false }) }   # an unreadable date stays
  if (Test-Path $pf) { $pend = @((Get-Content $pf -Raw | ConvertFrom-Json).requests); if (@($pend | Where-Object { & $stale $_ }).Count) { & $pendEdit { param($p) $p.requests = @(@($p.requests) | Where-Object { -not (& $stale $_) }) }; $pend = @($pend | Where-Object { -not (& $stale $_) }) } }
  foreach ($q in $pend) { foreach ($m in @($q.mrs)) { $cand[$m] = "requested by $($q.run)" } }
  foreach ($m in $Mrs) { $cand[$m] = "requested by $Run" }
  # no network = UNKNOWN, no hang
  $rows = @{}; $failOf = @{}   # target -> why its check gave no rows (timeout, crash): that target is UNKNOWN, the others stand
  $rowsOf = { param($m) if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] } }
  if ($fx) { foreach ($m in $cand.Keys) { $rows[$m] = @($fx.mrs.$m.rows) } }
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
    while (@($runs | Where-Object rl).Count -and (Get-Date) -lt $until) { foreach ($q in $runs) { & $take $q 0; if ($q.rl -and $q.p.HasExited) { & $take $q 300; $q.rl = $null } }; Start-Sleep -Milliseconds 200 }
    foreach ($q in $runs) {
      $fin = $q.p.WaitForExit([int][math]::Max(1000, ($until - (Get-Date)).TotalMilliseconds)); if (-not $fin) { try { $q.p.Kill($true) } catch {} }
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
      foreach ($x in @($parsed | ForEach-Object { $_ })) { if ($x.mr) { if (-not $rows.ContainsKey($x.mr)) { $rows[$x.mr] = @() }; $rows[$x.mr] += $x; if ($x.branch) { if (-not $script:KitMrTb) { $script:KitMrTb = @{} }; $script:KitMrTb[(Get-CanonMr $x.mr)] = $x.branch } } }   # Get-MrTargetBranch's memo
    }
    if (-not $Json -and $runs.Count) { [Console]::Error.WriteLine("deploy plan probes: $((@($script:probeCount.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key) $($_.Value)" }) + @(if ($anc.Count) { "DEPLOYED (green job) $($anc.Count)" })) -join ' · ')") }
  }
  $trigger = ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower()
  $win = Get-KitSetting 'deploy.minIntervalHours' 4
  $winOf = { param($t) if ($win -is [psobject] -and $win.PSObject.Properties.Name -contains $t) { [double]$win.$t } elseif ($win -is [psobject] -and $win.PSObject.Properties.Name -contains 'default') { [double]$win.default } elseif ($win -is [psobject]) { 4 } else { [double]$win } }
  $logged = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $hostErr = $null
  $recOf = @{}; foreach ($x in $logged) { foreach ($m in @($x.mrs)) { $recOf["$(Get-CanonMr (ConvertTo-MrRef $m))|$($x.target)"] = 1 } }   # MANUAL (no check can see it): a recorded deploy is the proof
  $feeds = @{}   # no deadline here: a cut lookup would batch an MR for a target it never feeds
  $plan = foreach ($t in $targets) {
    $batch = @(foreach ($m in @($cand.Keys)) { foreach ($r in @($(if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] }) | Where-Object { $_.target -eq $t -and ($_.state -eq 'NOT-DEPLOYED' -or ($_.state -eq 'MANUAL' -and -not $recOf["$(Get-CanonMr $m)|$t"])) })) { if (-not $feeds.ContainsKey($m)) { $feeds[$m] = @(Get-MrDeployTargets $m $repos $fx $null -NoPaths:(-not $fx)) }; if ($t -notin $feeds[$m]) { continue }; [pscustomobject]@{ mr = $m; task = $taskOf[$m]; state = $r.state; detail = $r.detail; why = $cand[$m] } } })   # feeds-lookup only for a not-deployed row
    $last = $null; $src = ''
    $l = @($logged | Where-Object { $_.target -eq $t } | Sort-Object { [datetime]$_.at }) | Select-Object -Last 1
    if ($l) { $last = [datetime]$l.at; $src = "kit log ($($l.by))" }
    $running = $false
    if ($fx) { if ($fx.lastCi.$t) { $ci = [datetime]$fx.lastCi.$t; if (-not $last -or $ci -gt $last) { $last = $ci; $src = 'CI' } } }
    else {
      foreach ($r in $repos) { foreach ($d in @($r.deploys | Where-Object { $_.target -eq $t -and $_.branch -and $_.job })) {
          $p = Get-HostProject $r.name
          $pls = try { @(Invoke-HostApi "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=5") } catch { if (-not $hostErr) { $hostErr = "$($_.Exception.Message)" }; @() }
          foreach ($pl in $pls) {
            if ($pl.status -in 'running', 'pending', 'created') { $running = $true; continue }
            if ($pl.status -eq 'success') { $at = ([datetime]$(if ($pl.updated_at) { $pl.updated_at } else { $pl.created_at })).ToLocalTime(); if (-not $last -or $at -gt $last) { $last = $at; $src = "CI $($r.name) $($d.branch)" }; break }
          } } }
    }
    $h = & $winOf $t
    $next = if ($last) { $last.AddHours($h) } else { $null }
    $mine = @($cand.Keys | Where-Object { $t -in $tOf[(& $repoOf $_)] })   # its repo deploys there (a feeds lookup per MR here cost 40 s): only for UNKNOWN reasons
    $unk = @(foreach ($m in $mine) { @(& $rowsOf $m) | Where-Object { $_ -and $_.target -eq $t -and $_.state -eq 'UNKNOWN' } | Where-Object { if (-not $feeds.ContainsKey($m)) { $feeds[$m] = @(Get-MrDeployTargets $m $repos $fx $null -NoPaths:(-not $fx)) }; $t -in $feeds[$m] } | ForEach-Object { "${m}: $($_.detail)" } })   # an UNKNOWN for a target it never feeds is no reason
    $why = if ($unk.Count) { $unk -join '; ' } elseif ($failOf[$t] -and $mine.Count -and -not @($mine | Where-Object { @(& $rowsOf $_) | Where-Object { $_ -and $_.target -eq $t } }).Count) { $failOf[$t] }
    $status = if ($why -and -not $batch.Count) { 'UNKNOWN' } elseif (-not $batch.Count) { 'NOTHING' } elseif ($running) { 'DEPLOYING' } elseif ($trigger -ne 'ask') { 'READY' } elseif ($next -and (Get-Date) -lt $next) { 'WAIT' } else { 'ASK' }
    [pscustomobject]@{ target = $t; status = $status; trigger = $trigger; last = $(if ($last) { $last.ToString('s') }); lastSource = $src; windowHours = $h; nextAllowed = $(if ($next) { $next.ToString('s') }); mrs = $batch; why = $why; pending = @($pend | ForEach-Object { "$($_.run) $($_.at)" }) }
  }
  if ($idle) { [Console]::Error.WriteLine("deploy plan: $idle open task(s) idle over $Days days left out (-Days widens)") }
  if ($Json) { ConvertTo-Json @($plan) -Depth 6; return }
  foreach ($p in $plan) {
    $when = switch ($p.status) { 'WAIT' { " until $(([datetime]$p.nextAllowed).ToString('yyyy-MM-dd HH:mm')) (one deploy per $($p.windowHours) h)" } 'ASK' { ': ask the owner ONCE with this batch' } 'READY' { ": waits for a person's 'deploy $($p.target)' (deploy.trigger owner: nobody asks)" } 'UNKNOWN' { ": the deploy check failed: $($p.why) (plan again)" } 'DEPLOYING' { ': a deploy pipeline runs now (wait, then plan again)' } default { '' } }
    "DEPLOY $($p.target): $($p.status)$when | last $(if ($p.last) { "$(([datetime]$p.last).ToString('yyyy-MM-dd HH:mm')) ($($p.lastSource))" } else { 'unknown' })"
    foreach ($b in $p.mrs) { "  - $($b.mr)$(if ($b.task) { " task $($b.task)" }) $($b.state): $($b.detail) [$($b.why)]" }
  }
  if (-not @($plan).Count) { 'no test deploy targets in kit.local.json repos[].deploys' }
  if ($hostErr) { "last deploy unknown: $hostErr" }   # once, not per target
}

# ---- restart: services of an ssh deploy, gated by its busy check in the same shell, right before each restart
# deploys[].ssh.busy: a host shell command whose output = live work (e.g. a running agent turn); busy -> wait, re-check, bounded
function Invoke-DeployRestart([string[]]$Targets, [string]$Service, [int]$WaitMinutes = 20, [int]$RecheckSeconds = 120, [switch]$Ungated) {
  foreach ($t in $Targets) {
    $d = @(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -eq $t } | Select-Object -First 1
    if (-not $d.ssh.host) { "deploy restart: $t has no repos[].deploys[].ssh (host, key, service): restart it by the org's deploy rules"; exit 2 }
    $s = $d.ssh; $svcs = @(Split-KitList @($(if ($Service) { $Service } else { $s.service })))
    if (-not $svcs.Count) { "deploy restart: no -Service and no deploys[].ssh.service for $t"; exit 2 }
    if (-not $s.busy -and -not $Ungated) { "REFUSED deploy restart ${t}: no deploys[].ssh.busy (a shell command that prints live work on the host, e.g. running agent turns): set it, or -Ungated when nothing on $($s.host) can be cut; nothing restarted"; exit 2 }
    $end = (Get-Date).AddMinutes($WaitMinutes); $done = @(); $sec = [int](Get-KitParam 'deploy.sshTimeoutSeconds'); $key = [string]$s.key -replace '^~', $HOME
    while ($true) {
      $left = @($svcs | Where-Object { $_ -notin $done })
      $sh = @(
        "SU=$(if ($s.sudo -ne $false) { "'sudo -n'" })"
        foreach ($v in $left) {   # the busy check runs immediately before each restart: no gap for a new turn to start unseen
          if ($s.busy) { "B=`$(sh -c $(Sq $s.busy) </dev/null 2>/dev/null); if [ -n `"`$B`" ]; then echo BUSY=1; printf '%s\n' `"`$B`" | head -n 5 | sed 's/^/LIVE=/'; exit 0; fi" }
          "`$SU systemctl restart $(Sq $v); R=`$?; echo `"DONE=$v `$R`"; echo `"ACTIVE=$v `$(systemctl is-active $(Sq $v) 2>/dev/null)`"; [ `$R -eq 0 ] || exit 0"   # a failed restart stops the rest
        }
        'echo END=1'
      ) -join "`n"
      $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
      $lines = @(Invoke-BoundedSsh @(@(if ($key) { '-i', $key }) + @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$([math]::Min(15, $sec))", '-o', 'StrictHostKeyChecking=accept-new', $s.host, "echo $b64 | base64 -d | bash")) ($sec + 120))
      foreach ($x in @($lines -match '^DONE=')) { $nm, $rc = ($x -replace '^DONE=', '') -split ' ', 2; if ("$rc".Trim() -ne '0') { "FAILED deploy restart ${t}: systemctl restart $nm exit $rc on $($s.host)$(if ($done) { " (restarted before: $($done -join ', '))" })"; exit 1 }; $done += $nm }
      $act = @($lines -match '^ACTIVE=' -replace '^ACTIVE=', '')
      if ($lines -match '^END=1') { Write-KitLog deploy-log restart ([ordered]@{ target = $t; services = $svcs; gated = (-not $Ungated) }); "RESTARTED ${t}: $($svcs -join ', ') on $($s.host) ($($act -join '; '))$(if ($Ungated) { ' (ungated)' })"; break }
      if (-not ($lines -match '^BUSY=1')) { "UNKNOWN deploy restart ${t}: no answer from $($s.host) (ssh failed or timed out)$(if ($done) { "; restarted: $($done -join ', ')" }); restart state unknown: check systemctl on the host before a retry"; exit 1 }
      $live = @($lines -match '^LIVE=' -replace '^LIVE=', '') -join ' | '
      if ((Get-Date).AddSeconds($RecheckSeconds) -gt $end) { "REFUSED deploy restart ${t}: live work on $($s.host) after $WaitMinutes min ($live); $(if ($done) { "restarted: $($done -join ', '), not: " } else { 'not restarted: ' })$(@($svcs | Where-Object { $_ -notin $done }) -join ', ') (bossy.ps1 decide ask)"; exit 3 }
      "BUSY ${t}: live work on $($s.host) ($live): re-check in $RecheckSeconds s (until $($end.ToString('HH:mm')))"; Start-Sleep $RecheckSeconds
    }
  }
}

# ---- supervise: inTest moves, the cached plan
# a deploy word's kind from its answer: yes | wait | no (an unclear answer silences nothing)
function Get-KitDeployWordKind([string]$Answer) {
  $a = "$Answer".Trim()
  if ($a -match '(?i)^(yes|y|ok|okay|go|approved?|deploy)\b') { 'yes' }
  elseif ($a -match '(?i)^(wait|later|retry|not yet)\b') { 'wait' }
  elseif ($a -match "(?i)\b(no|don['’]?t|do not|never|skip|hold|not now|stop)\b") { 'no' }
  else { 'yes' }
}
# the newest answered deploy word per env of the cached plan (decisions log, 30 d): a no -> held until a later yes or an MR it did not
# cover (state ask: one fresh ask, then -Fold covers it); it covers its -Mrs, else the env's MRs when first seen (cache held.<env>);
# a wait -> waiting until its retry (a HH:mm in the answer, else 20 min: the busy wait of deploy restart), then due
function Get-KitDeployHolds($Cache, [string]$CacheFile, [datetime]$Now = (Get-Date), [switch]$Fold) {
  $hold = @{}; if (-not $Cache) { return $hold }
  $tgs = @(@(@($Cache.ask) | ForEach-Object { ("$_" -split ':', 2)[0].Trim() }) + @(@($Cache.ready) | ForEach-Object { "$_" -replace '\s*\(\d+ MR\(s\)\)$' }) | Where-Object { $_ } | Select-Object -Unique)
  if (-not $tgs.Count) { return $hold }
  $tick = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime().Ticks } else { Get-KitUtcTicks $v } }   # JSON gives a DateTime: "$x" drops the offset
  $word = @{}; foreach ($d in @(Read-KitLog decisions-log $Now.AddDays(-30) | Where-Object { $_.event -eq 'answered' -and $_.gate -eq 'deploy' -and $_.kind -ne 'envfix' -and "$($_.answer)".Trim() } | Sort-Object { & $tick $_.answeredAt })) { foreach ($t in @(Split-KitList @("$($d.item)"))) { $word[$t] = $d } }
  $dirty = $false
  foreach ($t in $tgs) {
    $d = $word[$t]; if (-not $d) { continue }
    $sid = ("$($d.id)" -split '-')[-1]; $ans = "$($d.answer)".Trim(); $kind = Get-KitDeployWordKind $ans
    $at = if ($d.answeredAt -is [datetime]) { $d.answeredAt } else { try { [datetime]"$($d.answeredAt)" } catch { $Now } }
    if ($kind -eq 'wait') {
      $retry = if ($ans -match '\b([01]?\d|2[0-3]):([0-5]\d)\b') { $rt = $at.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]); if ($rt -le $at) { $rt.AddDays(1) } else { $rt } } else { $at.AddMinutes(20) }
      $why = if ("$($d.question) $ans" -match '(?i)\bbusy\b') { 'host busy' } else { "wait ($($d.by))" }
      $hold[$t] = [pscustomobject]@{ target = $t; state = $(if ($Now -lt $retry) { 'waiting' } else { 'due' }); sid = $sid; why = $why; retry = $retry; text = "$t waiting: $why, retry $($retry.ToString('HH:mm')) ($sid)" }
    }
    elseif ($kind -eq 'no') {
      $known = $Cache.mrsOf -and @($Cache.mrsOf.PSObject.Properties.Name) -contains $t   # an old cache without MR lists: held, nothing snapshotted
      $mrs = @(@($Cache.mrsOf.$t) | Where-Object { $_ }); $snap = $Cache.held.$t; $mine = $snap -and "$($snap.id)" -eq "$($d.id)"
      $cov = @(@($d.mrs) + @(if ($mine) { $snap.mrs } elseif (-not @($d.mrs).Count) { $mrs }) | Where-Object { $_ } | ForEach-Object { Get-CanonMr "$_" })
      $new = @($mrs | Where-Object { (Get-CanonMr "$_") -notin $cov })
      if ($known -and ((-not $mine -and -not @($d.mrs).Count) -or ($Fold -and $new.Count))) {
        if (-not $Cache.held) { $Cache | Add-Member -Force NoteProperty held ([pscustomobject]@{}) }
        $Cache.held | Add-Member -Force NoteProperty $t ([pscustomobject]@{ id = "$($d.id)"; mrs = @(@($cov) + @($new | ForEach-Object { Get-CanonMr "$_" }) | Select-Object -Unique) }); $dirty = $true
      }
      $hold[$t] = [pscustomobject]@{ target = $t; state = $(if ($new.Count) { 'ask' } else { 'held' }); sid = $sid; new = $new; text = "$t held by $(if ($d.by) { $d.by } else { 'owner' }): $sid" }
    }
  }
  if ($dirty -and $CacheFile) { $Cache | ConvertTo-Json -Depth 5 | Set-Content $CacheFile -Encoding utf8 }
  $hold
}
# supervise (called from Invoke-Supervise: $now, Within and Invoke-Bounded are its own): -AutoFix moves a done task that is live on a
# test env to inTest (never before); the deploy plan is cached 1 h (a failed refresh keeps the last good one, marked stale): READY envs are report info, DEPLOY ASK only under trigger ask
function Get-KitSuperviseFlagsDeploys([switch]$AutoFix) {
  $flag = { param($level, $what, $action) [pscustomobject]@{ level = $level; what = $what; action = $action } }; $holds = $null
  if ($AutoFix) {
    foreach ($o in @((Read-KitTracking).tasks.Values)) {
      if (-not (Within 'deploy checks')) { break }
      # a repo may deploy to several test envs
      if (-not $o.done -or -not $o.doneAt -or ($now - [datetime]$o.doneAt).TotalDays -gt 3) { continue }
      if ($o.qaCovered) { continue }
      if ($o.liveCheckedAt -and ($now - [datetime]$o.liveCheckedAt).TotalMinutes -lt $(if (@($o.liveOn).Count) { 60 } else { 10 })) { continue }
      # a QA run already covers it: skip the deploy lookup (10+ calls); exact id: 12 is no AB-12
      $covered = @(Get-ChildItem (Get-KitPath qa-runs) -Recurse -Filter 'run.json' -ErrorAction SilentlyContinue | Where-Object { $j = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }; (@($j.items.subtasks.id) + @($j.tracker.parent) | ForEach-Object { "$_" }) -contains "$($o.task)" } | ForEach-Object { $_.Directory.Name })
      if ($covered.Count) { Set-KitTaskFields $o.task @{ qaCovered = @($covered) }; continue }
      $raw = @(Invoke-Bounded $KitCmd.qa @('deployed', '-Mrs', (@($o.mrs) -join ','), '-Json'))   # a background run: none yet (started now, still running) or failed = ask again next round
      if (($raw -join "`n").Trim() -notmatch '^[\[{]') { foreach ($w in @($raw -match '^WATCH ')) { & $flag 'WATCH' "deployed check $($o.task): $($w -replace '^WATCH ')" 'Supervise checks it again next round.' }; continue }
      $rows = @($raw | Out-String | ConvertFrom-Json)
      $o.liveCheckedAt = $now.ToString('o')
      $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -notin 'DEPLOYED', 'N/A' }).Count -and @($rows | Where-Object { $_.target -eq $t -and $_.state -eq 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
      $new = @($live | Where-Object { $_ -notin @($o.liveOn) })
      $fields = @{ liveCheckedAt = $o.liveCheckedAt }; if ($new.Count) { $fields.liveOn = @(@($o.liveOn) + $new | Where-Object { $_ } | Select-Object -Unique) }
      Set-KitTaskFields $o.task $fields
      if ($new.Count -and (Test-TrackerStatus $(try { (Get-TrackerTask $o.task).status } catch { '' }) 'closed')) { Set-KitTaskFields $o.task @{ qaCovered = @('closed') }; continue }
      if ($new.Count) { Set-KitTaskFields $o.task @{ inTestDue = $now.ToString('o') } }
    }
    # deployed = in test (never before): one background run for every due task (inline it outran the sweep); each line names its own task
    $due = @((Read-KitTracking).tasks.Values | Where-Object { $_.inTestDue -and ($now - [datetime]$_.inTestDue).TotalHours -lt 24 } | ForEach-Object task | Sort-Object)
    foreach ($l2 in @(if ($due.Count) { Invoke-Bounded $KitCmd.orch @('deploy', 'intest', '-Apply', '-Task', ($due -join ',')) })) {
      if ($l2 -match '^WATCH ') { & $flag 'WATCH' "deploy intest: $($l2 -replace '^WATCH ')" 'Supervise runs it again next round.' }
      if ($l2 -notmatch '^(?<w>MARKED|WAIT|SKIP|GONE|ERROR)\s+(?<t>\S+)') { continue }
      if ($Matches.w -ne 'ERROR') { Set-KitTaskFields $Matches.t @{ inTestDue = $null } }   # ERROR: asked again next round
      if ($Matches.w -eq 'MARKED') { & $flag 'INFO' "auto-fixed: $l2" 'Tracker set to inTest; nothing to do.' }
    }
  }
  if (Within 'deploy plan') {
    $pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'
    $cache = if (Test-Path $pc) { try { Get-Content $pc -Raw | ConvertFrom-Json } catch { $null } }
    $plan = $null; $asked = $null
    if (-not $cache -or ($now - [datetime]$cache.at).TotalMinutes -ge 60) {
      $from = $cache.asked; $asked = $now.ToString('o')   # a background run: this call returns the plan started at the last ask and starts a fresh one
      $out = @(Invoke-Bounded $KitCmd.orch @('deploy', 'plan', '-Json', '-TimeoutSec', [int](Get-KitParam 'deploy.planTimeoutSec')))
      # timed out, still running in the background or failed (no JSON): keep the last good plan, plan again next round
      try { if (($out -join "`n").Trim() -match '^[\[{]') { $plan = @($out | Out-String | ConvertFrom-Json -ErrorAction Stop | Where-Object { $_ }) } } catch { $plan = $null }
      if ($null -eq $plan) { foreach ($w in @($out | Where-Object { $_ -match '^WATCH ' })) { & $flag 'WATCH' "deploy plan: $($w -replace '^WATCH ')" 'Kept the last good plan; supervise plans again next round.' } }
    }
    if ($null -ne $plan) {
      $mrsOf = [ordered]@{}; foreach ($p in @($plan | Where-Object { $_.status -in 'READY', 'ASK' -and $_.target })) { $mrsOf["$($p.target)"] = @(@($p.mrs) | ForEach-Object mr) }
      $cache = [pscustomobject]@{ at = $(if ($from) { $from } else { $now.ToString('o') }); ready = @($plan | Where-Object status -in 'READY', 'ASK' | ForEach-Object { "$($_.target) ($(@($_.mrs).Count) MR(s))" }); ask = @($plan | Where-Object { $_.status -eq 'ASK' -and $_.target -and @($_.mrs).Count } | ForEach-Object { "$($_.target): $(@($_.mrs).Count) MR(s) ($((@($_.mrs) | ForEach-Object mr) -join ', '))" }); mrsOf = [pscustomobject]$mrsOf; held = $cache.held }
    }
    if ($asked -and $cache -and $null -eq $plan -and $cache.asked -and -not @($out -match '^WATCH ').Count) { $asked = $null }   # no output: the run of the last ask still goes, keep its time
    if ($asked -and $cache) { $cache | Add-Member -Force NoteProperty asked $asked; $cache | ConvertTo-Json -Depth 4 | Set-Content $pc -Encoding utf8 }
    $askAge = if ($cache.at) { [int]($now - [datetime]$cache.at).TotalMinutes } else { 0 }
    $askStale = if ($askAge -ge 60) { " (plan $askAge min old, refresh pending: plan again before asking)" } else { '' }
    $holds = Get-KitDeployHolds $cache $pc $now -Fold:$AutoFix
    foreach ($a in @($cache.ask | Where-Object { "$_".Trim() -and ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower() -eq 'ask' })) {
      $h = $holds[("$a" -split ':', 2)[0].Trim()]
      if ($h.state -in 'held', 'waiting') { continue }   # its muted line below
      if ($h.state -eq 'due') { & $flag 'ACT' "DEPLOY RETRY $($h.target): $($h.why), wait $($h.sid) due since $($h.retry.ToString('HH:mm'))" "Deploy $($h.target) again per its deploy rules (the busy check runs first); still busy: a new wait with its retry time (decide record -Gate deploy -Item $($h.target) -Answer 'wait: retry HH:mm')."; continue }
      & $flag 'ACT' "DEPLOY ASK $a merged, not deployed, window open$(if ($h.state -eq 'ask') { " (new since hold $($h.sid): $($h.new -join ', '))" })$askStale" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; their yes: decide record -Gate deploy -Item <env> -Source askuser, its id to opsy; after the deploy: deploy record -Env <target> -Mrs <refs>, then deploy intest -Apply."
    }
  }
  # what waits for a person's deploy <env> (the cached plan): INFO lines of the supervise report; a held or waiting env: one muted line
  $pcf = Join-Path (Get-KitPath deploys) 'plan-cache.json'
  $pcd = try { Get-Content $pcf -Raw | ConvertFrom-Json } catch { $null }
  if ($null -eq $holds) { $holds = Get-KitDeployHolds $pcd $pcf $now }
  $age = if ($pcd.at) { [int]($now - [datetime]$pcd.at).TotalMinutes } else { 0 }
  $stale = if ($age -ge 60) { "; plan $age min old, refresh pending" } else { '' }
  foreach ($r in @($pcd.ready | Where-Object { $_ })) { $h = $holds["$r" -replace '\s*\(\d+ MR\(s\)\)$']; [pscustomobject]@{ info = $(if ($h.state -in 'held', 'waiting') { "deploy $($h.text)" } else { "deploy ready: $r (waits for a person's deploy <env>$stale)" }) } }
}
