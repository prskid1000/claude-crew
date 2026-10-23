#Requires -Version 7
# Extra track-rebuild (kittool.py extra add track-rebuild): orch.ps1 track -Rebuild, dot-sourced by orch.ps1.
# Recreates .state/tracking.json from MRs tagged with the tracker tag (last 14 days); runs inside Invoke-Track (its helpers).
function Invoke-TrackRebuild {
  $tf = Get-KitPath tracking
  if ((Test-Path $tf) -and -not $Force) { "tracking file exists ($tf, $(@((Read-KitTracking).tasks.Keys).Count) task(s)): nothing to rebuild (-Force merges discovered tasks into it)"; return }
  $tag = $KitConf.TrackerTag; $repos = @($KitConf.TrackerRepos)
  if (-not $tag -or -not $repos.Count) {
    Update-KitTracking { param($t) }
    "rebuilt $tf with no tasks: discovery needs ""trackerRepos"" and a tracker tag (tracker.branchTag) in kit.local.json. Re-add open tasks with: orch.ps1 track add -Task <id> -Discover"
    return
  }
  $since = (Get-Date).AddDays(-14).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $found = @{}
  foreach ($r in $repos) {
    $pp = ProjPath $r; if (-not $pp) { "skip $r : use <group/repo> or set ""gitlabGroup"""; continue }
    $q = "projects/$($pp -replace '/', '%2F')/merge_requests?search=$([uri]::EscapeDataString($tag))&in=title,source_branch&state=all&updated_after=$since&per_page=100"
    foreach ($m in @(Invoke-HostApi $q) | Where-Object { $_ -and $_.state -ne 'closed' }) {
      if ("$($m.source_branch) $($m.title)" -notmatch "(?i)$([regex]::Escape($tag))(?<id>[A-Za-z0-9]+)") { continue }
      $id = $Matches.id
      if (-not $found[$id]) { $found[$id] = @{ mrs = @(); states = @() } }
      $found[$id].mrs += "$r!$($m.iid)"; $found[$id].states += $m.state
    }
  }
  $n = 0; $nDone = 0
  foreach ($id in $found.Keys) {
    if ((Load $id) -and -not $Force) { continue }
    $o = @{ task = $id; mrs = @($found[$id].mrs); onMerged = @('promoted'); discover = $true; done = $false; created = (Get-Date).ToString('s'); rebuilt = $true }
    if (-not @($found[$id].states | Where-Object { $_ -ne 'merged' }).Count -and (Test-TrackerStatus (TaskStatus $id) 'promoted', 'inTest', 'closed')) { $o.done = $true; $o.doneAt = (Get-Date).ToString('s'); $nDone++ }
    Save $o; $n++
    if ($Detail) { "  $id : $($o.mrs -join ', ')$(if ($o.done) { ' (done)' })" }
  }
  if (-not (Test-Path $tf)) { Update-KitTracking { param($t) } }
  "rebuilt $tf : $n task(s) from $($repos.Count) repo(s) ($nDone already done; MRs with $tag<id> updated in the last 14 days)"
}
