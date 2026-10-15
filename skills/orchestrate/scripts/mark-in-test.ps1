#Requires -Version 7
<#
Move promoted tasks to "in test" once their MRs are really deployed on a test environment, judged from the CI (qa-kit deployed.ps1), never from memory.

  $M = '<workspace>/.claude/skills/orchestrate/scripts/mark-in-test.ps1'
  & $M                 # plan only: one line per candidate (MARK / WAIT / SKIP), nothing changes
  & $M -Apply          # set the tracker status to inTest + one comment per task naming the environments and MRs
  & $M -Apply -Quiet   # only print the tasks it changed (for a loop)
  & $M -Task abc123,abc124 -Apply

Candidates: the owner's tasks whose tracker status is promoted, from (a) tracking.local.json (track.ps1) and (b) the tracker lists named in
kit.local.json "trackerLists" (ClickUp only: ids of lists; tasks assigned to the tracker owner). A task's MRs come from tracking, else from a
merged-MR search for its tracker tag (<tracker tag><id>) in "trackerRepos". A task is marked only when it has MRs, every MR is MERGED and every
MR is DEPLOYED on at least one test deploy target (production, critical and emulator-lane targets never count); any MR with NO-TARGET / MANUAL /
NOT-DEPLOYED keeps the task promoted (WAIT / SKIP with the reason). Several products on one deploy branch: "productTargets" in kit.local.json maps the
paths an MR changes to the target that must have it, e.g. [{ "pathRegex": "^product-a/", "targetRegex": "^a-", "label": "product A test env" }];
without it any deployed test target is enough.
Tasks the owner moved on by hand (status no longer promoted) are never touched. Safe to run repeatedly.
#>
param([switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts\tracker.ps1')   # $KitConf, Get-KitPath, Get-TrackerTask, Set-TrackerStatus, ...
$deployed = Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'qa-kit\scripts\deployed.ps1'
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }
$group = $KitConf.GitlabGroup
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }

# --- candidates -------------------------------------------------------------------------------------------------------------------
$cand = [ordered]@{}   # task id -> @{ mrs = @(); name = '' }
$trackFile = Get-KitPath tracking
$track = if ($trackFile -and (Test-Path $trackFile)) { Get-Content $trackFile -Raw | ConvertFrom-Json } else { $null }
if ($track) { foreach ($p in $track.tasks.PSObject.Properties) { $cand[$p.Name] = @{ mrs = @($p.Value.mrs); name = '' } } }
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
$lists = @(Get-KitValue 'trackerLists' @()) | Where-Object { $_ } | Select-Object -Unique
if ($KitConf.TrackerType -eq 'clickup' -and $lists.Count) {   # through the tracker adapter (Get-TrackerTasks), never the CLI directly
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l 'promoted') } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name } } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes -Task a,b as one string: split it
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }

$productTargets = @(Get-KitValue 'productTargets' @())   # which test env a changed path needs; none configured = any deployed test env
$pathMemo = @{}
function Get-MrPaths([string]$mr) {   # files an MR changes (decides which product's test environment must have it)
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = glab api "projects/$([uri]::EscapeDataString("$group/$repo"))/merge_requests/$iid/changes" 2>$null | ConvertFrom-Json
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

# --- one pass ---------------------------------------------------------------------------------------------------------------------
$marked = 0; $wait = 0
foreach ($id in $cand.Keys) {
  $info = Get-TrackerTask $id
  if (-not $info) { continue }
  if (-not (Test-TrackerStatus ([string]$info.status) 'promoted')) { continue }   # only promoted tasks; never override a person's status
  $name = if ($info.name) { $info.name } else { $cand[$id].name }
  $short = if ($name.Length -gt 70) { $name.Substring(0, 70) } else { $name }
  $mrs = @($cand[$id].mrs | Where-Object { $_ })
  if (-not $mrs.Count -and $KitConf.TrackerRepos) {   # untracked task: find its merged MRs by the tracker tag
    $tag = "$($KitConf.TrackerTag)$id"
    foreach ($r in @($KitConf.TrackerRepos)) {
      $res = glab api "projects/$([uri]::EscapeDataString("$group/$r"))/merge_requests?search=$tag&state=merged&per_page=20" 2>$null | ConvertFrom-Json
      foreach ($m in @($res)) { if ($m.iid -and ("$($m.title) $($m.source_branch)" -match [regex]::Escape($tag))) { $mrs += "$r!$($m.iid)" } }
    }
    $mrs = @($mrs | Select-Object -Unique)
  }
  if (-not $mrs.Count) { Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $live = @(); $why = $null
  foreach ($mr in $mrs) {
    $rows = @(& pwsh -NoProfile -File $deployed -Mrs $mr -Json 2>$null | Out-String | ConvertFrom-Json)
    # only real test environments count (not prod, not the emulator-lane APK); a merge sitting on another product's deploy branch is no proof
    $ok = @($rows | Where-Object { $_.state -eq 'DEPLOYED' -and $_.target -notmatch 'prod|critical|lane' })
    $paths = Get-MrPaths $mr
    $missing = @(); $matched = $false
    foreach ($pt in $productTargets) {   # kit.local.json productTargets: [{ pathRegex, targetRegex, label }]
      if ($paths | Where-Object { $_ -match $pt.pathRegex }) { $matched = $true; if (-not ($ok | Where-Object { $_.target -match $pt.targetRegex })) { $missing += $pt.label } }
    }
    if (-not $matched -and -not $ok.Count) { $missing += 'any test env' }
    if ($ok.Count -and -not $missing.Count) { $live += "$mr on $((($ok | ForEach-Object { $_.target }) -join '+'))"; continue }
    $r0 = $rows | Where-Object { $_.state -ne 'DEPLOYED' } | Select-Object -First 1
    $why = "$mr not live on: " + $(if ($missing.Count) { $missing -join ', ' } else { 'a test env' }) + $(if ($r0) { " ($($r0.state): $($r0.detail))" } else { '' }); break
  }
  if ($why) { $wait++; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    Set-TrackerStatus $id 'inTest'
    Add-TrackerComment $id ("In test: every MR of this task is deployed on a test environment (checked from the CI, " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "): " + ($live -join '; ') + '.')
    $marked++; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
if (-not $Quiet) { "mark-in-test: $($cand.Count) candidate(s), $marked marked, $wait waiting on a deploy" }
