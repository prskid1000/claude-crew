#Requires -Version 7   # ConvertFrom-Json -AsHashtable; under Windows PowerShell 5.1 every load is null and actions run on empty ids
<#
Tracker automation: tie a tracker task to its MRs, and let the supervisor (-AutoFix) move the task when they are all merged —
so nobody has to watch pipelines and flip statuses by hand.

  $T = '<workspace>\.claude\skills\orchestrate\scripts\track.ps1'
  & $T add  -Task abc123 -Mrs backend!101,frontend!202 [-OnMerged "for review,promoted"]   # add MRs (repeatable; merges lists)
  & $T add  -Task abc124 -Discover                 # find the task's MRs itself (<tracker tag><id>, e.g. CU-<id>, in title/branch) on every run;
                                                  # completes only once the task is already in review (its agent sets that after all MRs)
  & $T add  -Task abc125 -MergeAfter 'frontend!203>backend!102'   # schedule the web merge only once the API MR merged
  & $T show                     # tracked tasks and MR states
  & $T run                      # check now: when every MR of a task is merged, set the statuses in order, comment once, mark done

Holds (no status change) while a still-running wave's saved report (<runtime>\waves\*.json) has a blocking review finding on one of the MRs.
MR refs: <repo>!<iid> in the kit.local.json "gitlabGroup" (or <group/repo>!<iid>). Default -OnMerged = "promoted" (logical tracker statuses
are mapped by tracker.statuses; a backend's own status names work too).
Config (skills\dev-kit\kit.local.json): gitHost, gitlabGroup, trackerRepos (searched by -Discover), repoAliases (short names agents use,
e.g. {"api":"backend"}), reposRoot (main checkouts, used to schedule -MergeAfter merges), tracker (dev-kit\scripts\tracker.ps1). glab for MRs.
Files: <.claude-runtime>\tracking\<task>.json. supervise.ps1 -AutoFix calls `run` every round.
#>
param([Parameter(Mandatory, Position = 0)][ValidateSet('add', 'show', 'run')][string]$Action, [string]$Task, [string[]]$Mrs = @(), [string]$OnMerged = 'promoted', [switch]$Quiet, [switch]$Discover, [string[]]$MergeAfter = @(), [string]$Wave)
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$dir = Join-Path $rt 'tracking'; New-Item -ItemType Directory -Force $dir | Out-Null
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts\tracker.ps1')   # $KitConf + Get-TrackerTask, Set-TrackerStatus, ...
function TaskStatus($id) { try { [string](Get-TrackerTask $id).status } catch { '' } }
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$group = $KitConf.GitlabGroup
$groupRx = if ($group) { '(?:' + [regex]::Escape($group) + '/)?' } else { '' }
$alias = @{}; if ($KitConf.RepoAliases) { foreach ($p in $KitConf.RepoAliases.PSObject.Properties) { $alias[$p.Name] = [string]$p.Value } }
function ProjPath($repo) { if ($repo -match '/') { $repo } elseif ($group) { "$group/$repo" } else { $null } }
# agents write refs loosely (web!6122, api!8201, a full MR URL): normalise to <repo>!<iid>
function NormRef($r) {
  $r = "$r".Trim().Trim("'", '"')   # pwsh -File passes 'a!1','b!2' with the quotes
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
# "<label>" of a still-running dev-wave stage (build:/review:/fix:<agent>) whose agent owns this MR, else $null.
# Reads <runtime>\waves\<run>.json (supervise refreshes them for every running workflow before calling `track run`).
function InFlight($ref) {
  if ($ref -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $null }
  $pat = "/$([regex]::Escape($Matches.r))/-/merge_requests/$($Matches.i)(\D|$)"
  foreach ($f in Get-ChildItem (Join-Path $rt 'waves') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-12) }) {
    $w = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if (-not @($w.running).Count) { continue }
    foreach ($p in $w.agents.PSObject.Properties) {
      if (@($p.Value.mrs | ForEach-Object { "$($_.url)$_" }) -match $pat) {
        $lbl = @($w.running) | Where-Object { $_ -match "^(build|review|fix|ship|ci):$([regex]::Escape($p.Name))$" } | Select-Object -First 1
        if ($lbl) {
          # the saved report goes stale once its workflow ends (supervise only refreshes RUNNING workflows): refresh before holding
          if ($f.LastWriteTime -lt (Get-Date).AddMinutes(-5)) {
            & (Join-Path $PSScriptRoot 'wave-report.ps1') -Run $w.run *> $null
            $w2 = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not (@($w2.running) -contains $lbl)) { continue }
          }
          return "$lbl ($($w.run))"
        }
      }
    }
  }
  $null
}
function MrState($ref) {
  if ($ref -notmatch '^(?<repo>[\w./-]+)!(?<iid>\d+)$') { return 'bad-ref' }
  $proj = ProjPath $Matches.repo
  if (-not $proj) { return 'bad-ref (use <group/repo>!<iid>, or set "gitlabGroup" in kit.local.json)' }
  $m = glab api "projects/$($proj -replace '/', '%2F')/merge_requests/$($Matches.iid)" 2>$null | ConvertFrom-Json
  if (-not $m) { return 'unknown' }
  if ($m.state -eq 'opened' -and $m.head_pipeline.status -in 'failed', 'canceled') { return "opened (pipeline $($m.head_pipeline.status))" }
  # a conflicting MR never merges, even with merge-when-green set (a sibling MR rewrote the same lines): someone must rebase it
  if ($m.state -eq 'opened' -and ($m.has_conflicts -or $m.detailed_merge_status -eq 'conflict')) { return 'opened (conflict)' }
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
    if ($Wave) { $o.wave = $Wave }   # a dev-wave still fixing this task (started before the task existed): hold until it ends
    if ($MergeAfter) { $o.mergeAfter = @(@($o.mergeAfter) + @($MergeAfter -split '\s*,\s*') | Where-Object { $_ } | Select-Object -Unique) }
    if (-not $o.done -or @($o.mrs).Count -gt $before) { $o.done = $false }   # a finished task stays finished unless new MRs were added
    Save $o; "tracking $Task : $($o.mrs -join ', ') -> on all merged: $($o.onMerged -join ' -> ')"
  }
  'show' { foreach ($f in Get-ChildItem $dir -Filter '*.json') { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json; "$($o.task) done=$($o.done) -> $($o.onMerged -join '>') : " + (($o.mrs | ForEach-Object { "$_=$(MrState $_)" }) -join ', ') } }
  'run' {
    # Re-arm merge-when-green that GitLab dropped: a push after scheduling (rebase, review fix) cancels it, and the MR then sits
    # open with a green pipeline. Intents come from devtools.py merge (<runtime>\automerge.json); merged/closed ones are forgotten.
    $amf = Join-Path $rt 'automerge.json'
    if (Test-Path $amf) {
      $am = Get-Content $amf -Raw | ConvertFrom-Json -AsHashtable; $keep = @{}
      foreach ($ref in @($am.Keys)) {
        if ($ref -notmatch '^(?<proj>.+)!(?<iid>\d+)$') { continue }
        $enc = $Matches.proj -replace '/', '%2F'; $iid = $Matches.iid
        $m = glab api "projects/$enc/merge_requests/$iid" 2>$null | ConvertFrom-Json
        if (-not $m) { $keep[$ref] = $am[$ref]; continue }
        if ($m.state -ne 'opened') { continue }
        $keep[$ref] = $am[$ref]
        if ($m.merge_when_pipeline_succeeds -or $m.draft -or $m.has_conflicts -or $m.detailed_merge_status -eq 'conflict' -or $m.head_pipeline.status -in 'failed', 'canceled') { continue }
        $a = @('-X', 'PUT', "projects/$enc/merge_requests/$iid/merge", '-f', 'squash=true', '-f', 'should_remove_source_branch=true')
        if ($m.head_pipeline.status -ne 'success') { $a += @('-f', 'merge_when_pipeline_succeeds=true') }
        $r = glab api @a 2>$null | ConvertFrom-Json
        "re-armed merge-when-green for $ref (it was dropped, probably by a push after scheduling): $(if ($r.state -eq 'merged') { 'merged' } elseif ($r.merge_when_pipeline_succeeds) { 'scheduled' } else { 'FAILED - check the MR' })"
      }
      $keep | ConvertTo-Json | Set-Content $amf -Encoding utf8
    }
    foreach ($f in Get-ChildItem $dir -Filter '*.json') {
      $o = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable; if ($o.done) { continue }
      $o.mrs = @(@($o.mrs) | ForEach-Object { NormRef $_ } | Where-Object { $_ } | Select-Object -Unique)
      if ($o.discover) {
        if (-not @($KitConf.TrackerRepos).Count) { if (-not $Quiet) { "ATTENTION $($o.task): -Discover needs ""trackerRepos"" in kit.local.json" } }
        foreach ($r in @($KitConf.TrackerRepos)) {
          $pp = ProjPath $r; if (-not $pp) { continue }
          $found = @(glab api "projects/$($pp -replace '/', '%2F')/merge_requests?search=$([uri]::EscapeDataString("$($KitConf.TrackerTag)$($o.task)"))&in=title,source_branch&state=all&per_page=50" 2>$null | ConvertFrom-Json | Where-Object { $_.state -ne 'closed' } | ForEach-Object { "$r!$($_.iid)" })
          $o.mrs = @(@($o.mrs) + $found | Where-Object { $_ } | Select-Object -Unique)
        }
        Save $o
        if (-not @($o.mrs).Count) { continue }
        $cur = TaskStatus $o.task
        if (-not (Test-TrackerStatus $cur 'review')) {
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
        # never merge an MR whose dev-wave agent is still in build/review/fix: the wave's own ship step merges it after a clean review
        # (merge-after once merged a dependent MR mid-review and a blocking regression landed on the target branch)
        $owner = InFlight $dep
        if ($owner) { if (-not $Quiet) { "HOLD $($o.task): $dep waits for its review ($owner still running)" }; continue }
        if ((MrState $on) -eq 'merged' -and (MrState $dep) -eq 'opened' -and $dep -match '^(?<repo>[\w.-]+)!(?<iid>\d+)$') {
          $wt = Join-Path $KitConf.ReposRoot (($Matches.repo -split '/')[-1])   # a checkout of that repo (devtools reads its origin remote)
          $res = if (-not (Test-Path $wt)) { "no checkout at $wt - set ""reposRoot"" in kit.local.json" } else { python (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\devtools.py') merge $wt $Matches.iid 2>&1 }
          if (-not $Quiet) { "MERGE-AFTER $($o.task): $on merged -> $dep : $res" }
        }
        if ($o.mrs -notcontains $dep) { $o.mrs = @(@($o.mrs) + $dep) }; if ($o.mrs -notcontains $on) { $o.mrs = @(@($o.mrs) + $on) }
      }
      $states = @{}; foreach ($m in $o.mrs) { $states[$m] = MrState $m }
      $failed = @($states.GetEnumerator() | Where-Object { $_.Value -match 'pipeline (failed|canceled)|closed|conflict' })
      if ($failed) { if (-not $Quiet) { "ATTENTION $($o.task): $(($failed | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')" }; continue }
      if (@($states.Values | Where-Object { $_ -ne 'merged' }).Count) { continue }
      # hold while a still-running wave has a blocking review finding on one of these MRs (its fix MR is on the way)
      $held = @(Get-ChildItem (Join-Path $rt 'waves') -Filter '*.json' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) } | ForEach-Object {
          $w = Get-Content $_.FullName -Raw | ConvertFrom-Json
          if (@($w.running).Count) { & (Join-Path $PSScriptRoot 'wave-report.ps1') -Run $w.run *> $null; $w = Get-Content $_.FullName -Raw | ConvertFrom-Json }   # refresh: the wave may have ended
          if (@($w.running).Count) { @($w.openFindings) | Where-Object { $_.severity -eq 'blocking' -and $_.mr -match '/(?<r>[\w.-]+)/-/merge_requests/(?<i>\d+)' -and $o.mrs -contains "$($Matches.r)!$($Matches.i)" } } })
      if ($held) { if (-not $Quiet) { "HOLD $($o.task): blocking review finding still being fixed ($($held[0].mr))" }; continue }
      # merged but its agent's review/fix round is still running: findings may still turn into a follow-up MR
      if ($o.wave) { $wf = Join-Path $rt "waves\$($o.wave).json"; & (Join-Path $PSScriptRoot 'wave-report.ps1') -Run $o.wave *> $null; $wj = if (Test-Path $wf) { Get-Content $wf -Raw | ConvertFrom-Json } else { $null }; if (-not $wj -or @($wj.running).Count) { if (-not $Quiet) { "HOLD $($o.task): wave $($o.wave) is still fixing it" }; continue } }
      $busy = @($o.mrs | ForEach-Object { InFlight $_ } | Where-Object { $_ } | Select-Object -Unique)
      if ($busy) { if (-not $Quiet) { "HOLD $($o.task): MRs merged but $($busy -join ', ') still in review/fix" }; continue }
      # never move a task backwards: QA may already have closed it (then later fix MRs registered on it merge)
      $now = TaskStatus $o.task
      if (Test-TrackerStatus $now 'closed', 'inTest') { $o.done = $true; Save $o; if (-not $Quiet) { "DONE $($o.task): all MRs merged; status '$now' kept (already past promoted)" }; continue }
      foreach ($s in $o.onMerged) { try { $null = Set-TrackerStatus $o.task $s } catch { if (-not $Quiet) { "ATTENTION $($o.task): could not set status '$s': $_" } } }
      $gitHost = if ($KitConf.GitHost) { $KitConf.GitHost } else { 'gitlab.com' }
      $urls = @($o.mrs | ForEach-Object { if ($_ -match '^(?:(?<g>[\w./-]+)/)?(?<r>[\w.-]+)!(?<i>\d+)$') { "https://$gitHost/$(if ($Matches.g) { $Matches.g } else { $group })/$($Matches.r)/-/merge_requests/$($Matches.i)" } })
      try { $null = Add-TrackerComment $o.task "All MRs merged: $($urls -join ' , '). Status set to $($o.onMerged[-1]) automatically by the coordinator's tracker." } catch {}
      # the task must also carry its agent's solution + testing steps (an agent that got the tracker syntax wrong posted nothing)
      $cmts = @(try { Get-TrackerComments $o.task } catch {}) | ForEach-Object { [string]$_.text } | Where-Object { $_ -notmatch '^All MRs merged' }
      if (-not ($cmts | Where-Object { $_ -match '(?i)how to test|test(ing)? (steps|guide|instructions)|tester guide|live check' })) {
        # agents often get the comment wrong: post the live checks from the dev agent's own report (workflow journal) instead of flagging
        $proj = $KitConf.ClaudeProjectDir
        $steps = @(Get-ChildItem $proj -Recurse -Filter 'journal.jsonl' -File | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) } | Sort-Object LastWriteTime -Descending | ForEach-Object {
            foreach ($line in Get-Content $_.FullName) {
              $j = try { $line | ConvertFrom-Json } catch { $null }
              # agents list item ids (B1) in done, not task ids: also match the agent by one of this task's MR urls
              $mine = (@($j.result.done) -match [regex]::Escape($o.task)) -or @(@($j.result.mrs) | Where-Object { $o.mrs -contains (NormRef $_.url) }).Count
              if ($j.type -eq 'result' -and $mine -and @($j.result.needsLiveCheck).Count) { @($j.result.needsLiveCheck) }
            } } | Where-Object { $_ } | Select-Object -Unique)
        if ($steps.Count) {
          try { $null = Add-TrackerComment $o.task ("How to test (from the dev agent's report; run after the next deploy of $($urls -join ' , ')):`n" + (($steps | ForEach-Object { "- $_" }) -join "`n")) } catch {}
          "COMMENTED $($o.task): posted $($steps.Count) how-to-test step(s) from the agent's report (its own testing comment was missing)"
        } else {
          "ATTENTION $($o.task): merged, but no solution/testing comment from its agent - post the solution, MR links and how-to-test on the task"
        }
      }
      $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); Save $o
      "DONE $($o.task): all $(@($o.mrs).Count) MRs merged -> status $($o.onMerged -join ' -> ')"
    }
  }
}
