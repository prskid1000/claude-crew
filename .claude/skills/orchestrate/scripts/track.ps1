<#
Tracker automation: tie a ClickUp task to its MRs, and let the supervisor (-AutoFix) move the task when they are all merged —
so nobody has to watch pipelines and flip statuses by hand.

  $T = '<workspace>\.claude\skills\orchestrate\scripts\track.ps1'
  & $T add  -Task abc123 -Mrs backend!101,frontend!202 [-OnMerged "for review,promoted"]   # add MRs (repeatable; merges lists)
  & $T add  -Task abc124 -Discover                 # find the task's MRs itself (CU-<id> in title/branch) on every run;
                                                  # completes only once the task is already 'for review' (its agent sets that after all MRs)
  & $T add  -Task abc125 -MergeAfter 'frontend!203>backend!102'   # schedule the web merge only once the API MR merged
  & $T show                     # tracked tasks and MR states
  & $T run                      # check now: when every MR of a task is merged, set the statuses in order, comment once, mark done

Holds (no status change) while a still-running wave's saved report (<runtime>\waves\*.json) has a blocking review finding on one of the MRs.
MR refs: <repo>!<iid> in the kit.local.json "gitlabGroup" (or <group/repo>!<iid>). Default -OnMerged = "promoted".
Config (skills\dev-kit\kit.local.json): gitHost, gitlabGroup, trackerRepos (searched by -Discover), repoAliases (short names agents use,
e.g. {"api":"backend"}), reposRoot (main checkouts, used to schedule -MergeAfter merges). GitLab + ClickUp CLIs (glab, clickup).
Files: <.claude-runtime>\tracking\<task>.json. supervise.ps1 -AutoFix calls `run` every round.
#>
param([Parameter(Mandatory, Position = 0)][ValidateSet('add', 'show', 'run')][string]$Action, [string]$Task, [string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @())
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$dir = Join-Path $rt 'tracking'; New-Item -ItemType Directory -Force $dir | Out-Null
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts\kitconfig.ps1')
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$group = $KitConf.GitlabGroup
$groupRx = if ($group) { '(?:' + [regex]::Escape($group) + '/)?' } else { '' }
$alias = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $alias[$p.Name] = [string]$p.Value } }
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($group) { "$group/$repo" } else { $null } }
# agents write refs loosely (web!6122, api!8201, a full MR URL): normalise to <repo>!<iid>
function NormRef($r) {
  $r = "$r".Trim()
  if ($r -match "://[^/]+/$groupRx(?<repo>[\w./-]+?)/-/merge_requests/(?<iid>\d+)") { $r = "$($Matches.repo)!$($Matches.iid)" }
  if ($r -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$' -and $alias[$Matches.repo]) { $r = "$($alias[$Matches.repo])!$($Matches.iid)" }
  $r
}
function Load($t) { $f = Join-Path $dir "$t.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } }
function Save($o) {
  # another process (an agent's `add`) may have written since we loaded: keep its MRs / merge orders instead of overwriting them
  $cur = Load $o.task
  if ($cur) { foreach ($k in 'mrs', 'mergeAfter') { $o[$k] = @(@($o[$k]) + @($cur[$k]) | Where-Object { $_ } | Select-Object -Unique) }; if ($cur.discover) { $o.discover = $true } }
  $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
  $o.mergeAfter = @(@($o.mergeAfter) | Where-Object { $_ } | ForEach-Object { $p = $_ -split '>', 2; if ($p.Count -eq 2) { "$(NormRef $p[0])>$(NormRef $p[1])" } else { $_ } } | Select-Object -Unique)
  $o | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir "$($o.task).json")
}
function MrState($ref) {
  if ($ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return 'bad-ref' }
  $proj = ProjPath $Matches.repo
  if (-not $proj) { return 'bad-ref (use <group/repo>!<iid>, or set "gitlabGroup" in kit.local.json)' }
  $m = glab api "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)" 2>$null | ConvertFrom-Json
  if (-not $m) { return 'unknown' }
  if ($m.state -eq 'opened' -and $m.head_pipeline.status -in 'failed', 'canceled') { return "opened (pipeline $($m.head_pipeline.status))" }
  $m.state
}
switch ($Action) {
  'add' {
    if (-not $Task) { throw 'add needs -Task' }
    $o = Load $Task; if (-not $o) { $o = @{ task = $Task; mrs = @(); onMerged = @($OnMerged -split '\s*,\s*'); done = $false; created = (Get-Date).ToString('s') } }
    $before = @($o.mrs).Count
    $o.mrs = @(@($o.mrs) + @($Mrs -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique)
    if ($PSBoundParameters.ContainsKey('OnMerged')) { $o.onMerged = @($OnMerged -split '\s*,\s*') }
    if ($Discover) { $o.discover = $true }
    if ($MergeAfter) { $o.mergeAfter = @(@($o.mergeAfter) + @($MergeAfter -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique) }
    if (-not $o.done -or @($o.mrs).Count -gt $before) { $o.done = $false }   # a finished task stays finished unless new MRs were added
    Save $o; "tracking $Task : $($o.mrs -join ', ') -> on all merged: $($o.onMerged -join ' -> ')"
  }
  'show' { foreach ($f in Get-ChildItem $dir -Filter '*.json') { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json; "$($o.task) done=$($o.done) -> $($o.onMerged -join '>') : " + (($o.mrs | ForEach-Object { "$_=$(MrState $_)" }) -join ', ') } }
  'run' {
    foreach ($f in Get-ChildItem $dir -Filter '*.json') {
      $o = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable; if ($o.done) { continue }
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      if ($o.discover) {
        if (-not @($KitConf.TrackerRepos).Count) { if (-not $Quiet) { "ATTENTION $($o.task): -Discover needs ""trackerRepos"" in kit.local.json" } }
        foreach ($r in @($KitConf.TrackerRepos)) {
          $pp = ProjPath $r; if (-not $pp) { continue }
          $found = @(glab api "projects/$($pp -replace '/', '%2F')/merge_requests?search=CU-$($o.task)&in=title,source_branch&state=all&per_page=50" 2>$null | ConvertFrom-Json | Where-Object { $_.state -ne 'closed' } | ForEach-Object { "$r!$($_.iid)" })
          $o.mrs = @(@($o.mrs) + $found | Where-Object { $_ } | Select-Object -Unique)
        }
        Save $o
        if (-not @($o.mrs).Count) { continue }
        $cur = (clickup task view $o.task --json 2>$null | ConvertFrom-Json).status.status
        if ($cur -notin 'for review', 'in review') {
          # Its agent may still be shipping (more MRs to come) - or it shipped but failed to set the review status (a wrong
          # tracker command can leave a task untouched for hours). Once every discovered MR has been merged for 20 min, complete it.
          $allMerged = -not @(@($o.mrs) | Where-Object { (MrState $_) -ne 'merged' }).Count
          if (-not $allMerged) { $o.Remove('allMergedAt'); Save $o; continue }
          if (-not $o.allMergedAt) { $o.allMergedAt = (Get-Date).ToString('s'); Save $o; continue }
          if (((Get-Date) - [datetime]$o.allMergedAt).TotalMinutes -lt 20) { continue }
          if (-not $Quiet) { "NOTE $($o.task): status '$cur' was never set to review, but all MRs merged 20+ min ago - completing it" }
        }
      }
      # ordered merges: '<dependent>><dependency>' -> when the dependency merged, schedule the dependent (merge-when-green)
      foreach ($pair in @($o.mergeAfter)) {
        if ($pair -notmatch '^(?<dep>[^>]+)>(?<on>.+)$') { continue }
        $dep = $Matches.dep.Trim(); $on = $Matches.on.Trim()
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$') {
          $wt = Join-Path $KitConf.ReposRoot (($Matches.repo -split '/')[-1])   # a checkout of that repo (devtools reads its origin remote)
          $res = if (-not (Test-Path $wt)) { "no checkout at $wt - set ""reposRoot"" in kit.local.json" } else { python (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\devtools.py') merge $wt $Matches.iid 2>&1 }
          if (-not $Quiet) { "MERGE-AFTER $($o.task): $on merged -> $dep : $res" }
        }
        if ($o.mrs -notcontains $dep) { $o.mrs = @(@($o.mrs) + $dep) }; if ($o.mrs -notcontains $on) { $o.mrs = @(@($o.mrs) + $on) }
      }
      $states = @{}; foreach ($m in $o.mrs) { $states[$m] = MrState $m }
      $failed = @($states.GetEnumerator() | Where-Object { $_.Value -match 'pipeline (failed|canceled)|closed' })
      if ($failed) { if (-not $Quiet) { "ATTENTION $($o.task): $(($failed | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')" }; continue }
      if (@($states.Values | Where-Object { $_ -ne 'merged' }).Count) { continue }
      # hold while a still-running wave has a blocking review finding on one of these MRs (its fix MR is on the way)
      $held = @(Get-ChildItem (Join-Path $rt 'waves') -Filter '*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) } | ForEach-Object {
          $w = Get-Content $_.FullName -Raw | ConvertFrom-Json
          if (@($w.running).Count) { & (Join-Path $PSScriptRoot 'wave-report.ps1') -Run $w.run *> $null; $w = Get-Content $_.FullName -Raw | ConvertFrom-Json }   # refresh: the wave may have ended
          if (@($w.running).Count) { @($w.openFindings) | Where-Object { $_.severity -eq 'blocking' -and $_.mr -match '/(?<r>[\w.-]+)/-/merge_requests/(?<i>\d+)' -and $o.mrs -contains "$($Matches.r)!$($Matches.i)" } } })
      if ($held) { if (-not $Quiet) { "HOLD $($o.task): blocking review finding still being fixed ($($held[0].mr))" }; continue }
      foreach ($s in $o.onMerged) { clickup status set $s $o.task 2>&1 | Out-Null }
      clickup comment add $o.task "All MRs merged ($($o.mrs -join ', ')). Status set to $($o.onMerged[-1]) automatically by the coordinator's tracker." 2>&1 | Out-Null
      $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); Save $o
      "DONE $($o.task): all $(@($o.mrs).Count) MRs merged -> status $($o.onMerged -join ' -> ')"
    }
  }
}
