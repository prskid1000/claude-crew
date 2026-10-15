#Requires -Version 7
<#
Controller of one local env; started by localenv.ps1, never by hand. Model: ../SKILL.md.
  localenvd.ps1 -Env <env>               env loop: lifecycle (stop idle / under pressure, start what is needed, restart crashes),
                                         sandbox upkeep, one train worker at a time. One per env (mutex); exits after loopExitMinutes idle.
  localenvd.ps1 -Env <env> -Train <id>   train worker: sandbox routing (HEAVY migrations), merge, gated build, culprit search, stage,
                                         lease waits, exact revert of leaving LIGHT migration layers, DB snapshot (HEAVY), switch-over,
                                         smoke, rollback, release record.
Logs: <logs>/<env>-loop.log, <env>-train.log, <env>-events.jsonl.
#>
param([Parameter(Mandatory)][Alias('Env')][string]$EnvName, [string]$Train)
. (Join-Path $PSScriptRoot 'localenv-lib.ps1')
$e = $EnvName
$ErrorActionPreference = 'Stop'

# ================================================================ train worker
# Wait until no lease covers $services / $repos. Leases of agents whose own requests ride this train are skipped (they asked for
# the change; waiting for them would deadlock). Leases end by time (capped), by release, or when their owner dies (Prune).
function Wait-Leases([string[]]$services, [string[]]$repos, [string[]]$skipAgents) {
  $said = $null
  while ($true) {
    $o = @{ who = @() }
    Update-State $e { param($x)
      Prune $x
      $o.who = @($x.leases.Keys | Where-Object { $_ -notin $skipAgents } | Where-Object { $l = $x.leases[$_]; @($l.services | Where-Object { $_ -in $services }).Count -or @($l.repos | Where-Object { $_ -in $repos }).Count })
      if ($x.train) { $x.train.waitingFor = @($o.who) }
    }
    if (-not $o.who.Count) { return }
    $msg = "waiting for lease(s) of $($o.who -join ', ') on $(@($services) + @($repos) -join ', ')"; if ($msg -ne $said) { "[$e] $msg"; $said = $msg }
    Start-Sleep 5
  }
}
function Phase([string]$p, [string[]]$blockServices = @(), [string[]]$blockRepos = @()) {
  Update-State $e { param($x) if ($x.train) { $x.train.phase = $p; $x.train.blockServices = @($blockServices); $x.train.blockRepos = @($blockRepos); $x.train.waitingFor = @() } }
  "[$e] train $Train : $p"
}
function Key($l) { "$($l.branch)@$($l.sha)" }

function Run-Train {
  $st = Read-State $e
  if (-not $st.train -or $st.train.id -ne $Train) { "[$e] train $Train is not the env's current train: nothing to do"; return }
  $reqs = @($st.requests | Where-Object { $_.id -in @($st.train.requests) })
  $own = @($reqs.agent | Where-Object { $_ } | Select-Object -Unique)
  $envRepos = EnvRepos $e
  $results = @{}; foreach ($r in $reqs) { $results[$r.id] = @{ outcome = 'live'; message = '' } }
  $notes = [Collections.Generic.List[string]]::new(); $migNote = @{}

  # 1. sandboxes first: a migration deploy (repo with sandbox services) never reaches the main env from here
  $sandboxed = @{}
  $sbCfg = SandboxCfg $e
  if ($sbCfg) {
    foreach ($r in @($reqs | Where-Object { $_.kind -eq 'deploy' -and -not $_.noSandbox })) {
      $rn = @($r.shas.Keys | Where-Object { $repo = $_; (ReqHeavy $r $repo) -and @($sbCfg.services | Where-Object { (RepoOf $e (Svc $e $_)) -eq $repo }).Count }) | Select-Object -First 1
      if (-not $rn) { continue }
      $sandboxed[$r.id] = $true
      $live = (Read-State $e).sandboxes
      foreach ($key in @($live.Keys | Where-Object { $live[$_].branch -eq $r.branch })) { Phase "replacing sandbox $key ($($r.branch))"; Remove-Sandbox $e $key }
      $used = @((Read-State $e).sandboxes.Keys | ForEach-Object { [int]"$_".Substring(2) })
      $k = 1..[int]$(if ($sbCfg.max) { $sbCfg.max } else { 2 }) | Where-Object { $_ -notin $used } | Select-Object -First 1
      if (-not $k) { $results[$r.id] = @{ outcome = 'refused'; message = "all sandboxes busy ($(((Read-State $e).sandboxes.Values | ForEach-Object { "$($_.branch) ($($_.agent))" }) -join ', ')): deploy again once one is promoted or dropped" }; continue }
      Phase "sandbox sb$k for $($r.branch) (migrations)"
      $res = New-Sandbox $e $k $envRepos[$rn] @{ branch = $r.branch; agent = $r.agent; sha = $r.shas[$rn]; migrations = $true; request = $r.id }
      $results[$r.id] = if ($res.ok) { @{ outcome = 'sandbox'; message = "$(if ($r.mclass) { "$(MigText $r.mclass[$rn]): " })$($res.message)" } } else { @{ outcome = 'rejected'; message = $res.message } }
      if (-not $res.ok) { Remove-Sandbox $e "sb$k" }
    }
  }
  foreach ($r in @($reqs | Where-Object { $_.kind -eq 'drop' })) {
    $live = (Read-State $e).sandboxes
    foreach ($key in @($live.Keys | Where-Object { $live[$_].branch -eq $r.branch })) { Phase "removing sandbox $key"; Remove-Sandbox $e $key; $results[$r.id].message = "sandbox $key removed" }
  }

  # 2. what the main env should run: current layers +/- this train's requests
  $cur = @{}; $want = @{}; foreach ($rn in $envRepos.Keys) { $cur[$rn] = @(Layers $st $rn); $want[$rn] = @($cur[$rn]) }
  $affected = [Collections.Generic.List[string]]::new(); $byBranch = @{}
  foreach ($r in @($reqs | Where-Object { -not $sandboxed[$_.id] })) {
    switch ($r.kind) {
      'deploy' { foreach ($rn in @($r.shas.Keys)) {
          $l = @{ branch = $r.branch; agent = $r.agent; sha = $r.shas[$rn]; at = $r.at; migrations = [bool]$r.migrations[$rn]; mclass = $(if ($r.mclass) { $r.mclass[$rn] }); request = $r.id }
          if ($l.migrations) { $migNote[$r.id] = "$rn $(MigText $(if ($l.mclass) { $l.mclass } else { @{ effective = 'heavy'; why = @('promoted from its sandbox') } }))" }
          $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }) + @($l); if (-not $affected.Contains($rn)) { $affected.Add($rn) }; $byBranch["$rn|$($r.branch)"] = $r.id } }
      'drop' { foreach ($rn in $envRepos.Keys) { if (@($want[$rn].branch) -contains $r.branch) { $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }); if (-not $affected.Contains($rn)) { $affected.Add($rn) } } } }
      'refresh' { foreach ($rn in $envRepos.Keys) { if (-not $affected.Contains($rn)) { $affected.Add($rn) } } }
    }
  }
  $newN = [int]$st.release.n + 1; $tag = "r$newN-$Train"
  $repoOut = @{}; $artifacts = @{}; $newLayers = @{}
  $ok = [Collections.Generic.List[string]]::new()
  if (-not $affected.Count) { Record-Train; return }

  # 3. code: wait for leases that read the worktrees (tasks on these repos, services running straight from them, and services
  #    adopted from before run-from-copy that lock their build output)
  $liveSvcs = @(EnvServices $e | Where-Object { $_.repo -and -not $_.artifact -and (RepoOf $e $_) -in $affected } | ForEach-Object name)
  $adopted = @(EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -in $affected -and $st.services[$_.name].status -eq 'up' -and -not $st.services[$_.name].artifact } | ForEach-Object name)
  $codeSvcs = @(@($liveSvcs) + $adopted | Select-Object -Unique)
  $codeBlock = @(@($codeSvcs) + @(Dependents $e $codeSvcs) | Select-Object -Unique)
  Phase 'waiting for leases (code)' $codeBlock @($affected)
  Wait-Leases $codeBlock @($affected) $own
  foreach ($n in $adopted) { "[$e] $n runs from its build output (started before run-from-copy): stopping it for the build"; Stop-Svc $e (Svc $e $n) 'rebuilt: restarts from a staged copy' }
  Phase 'merging and building' $codeBlock @($affected)

  foreach ($rn in $affected) {
    $r = $envRepos[$rn]
    $prevKeys = @($cur[$rn] | ForEach-Object { Key $_ })
    $isNew = { param($l) (Key $l) -notin $prevKeys }
    $res = Sync-Repo $e $r @($want[$rn])
    foreach ($d in $res.dropped) {
      $rid = $byBranch["$rn|$($d.layer.branch)"]
      if ($rid -and (& $isNew $d.layer)) { $results[$rid] = @{ outcome = 'refused'; message = "$rn : $($d.why)" } }
      else { $notes.Add("dropped layer $($d.layer.branch) ($($d.layer.agent)) from $rn : $($d.why)$(if (LayerLight $d.layer) { ' - its LIGHT migrations are reverted with this release' } elseif ($d.layer.migrations) { ' - it had HEAVY migrations: the local DB keeps them' })") }
    }
    $kept = @($res.kept); $targetSha = $res.targetSha
    # nothing to do when the result equals the live release and every artifact service of the repo has its staged copy
    $live = $st.release.repos[$rn]
    $missing = @(EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -eq $rn -and -not ($st.services[$_.name].artifact -and (Test-Path $st.services[$_.name].artifact)) })
    if ([int]$st.release.n -gt 0 -and $live -and $live.targetSha -eq $targetSha -and -not $missing.Count -and (@($kept | ForEach-Object { Key $_ }) -join '|') -eq ($prevKeys -join '|')) {
      "[$e] $rn unchanged (same target commit and layers): no build"
      foreach ($l in $kept) { if ($l.request -and $results[$l.request].outcome -eq 'live') { $results[$l.request].message = 'already live' } }
      continue
    }
    $err = Build-Repo $e $rn
    if ($err) {
      # culprit search: the old layers built before, so look among the new ones (smallest failing prefix, one build per step)
      $base = @($kept | Where-Object { -not (& $isNew $_) }); $cands = @($kept | Where-Object { & $isNew $_ })
      $state = @{ err = $err }
      $try = { param($set) $null = Sync-Repo $e $r @($set) -NoFetch; $state.err = Build-Repo $e $rn; -not $state.err }
      Phase "build failed in $rn : finding the culprit among $($cands.Count) new layer(s)" $codeBlock @($affected)
      if (-not $cands.Count -or -not (& $try $base)) {
        foreach ($l in $cands) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : the target + the layers already live do not build either: $($state.err)" } } }
        $notes.Add("$rn does not build on its target + current layers: kept the running release ($($state.err))")
        $null = Sync-Repo $e $r @($cur[$rn]) -NoFetch   # leave the worktree on the live release's code
        continue
      }
      while ($cands.Count) {
        if (& $try (@($base) + @($cands))) { break }
        $lo = 1; $hi = $cands.Count; $failLog = $state.err
        while ($lo -lt $hi) { $mid = [int][math]::Floor(($lo + $hi) / 2); if (& $try (@($base) + @($cands[0..($mid - 1)]))) { $lo = $mid + 1 } else { $hi = $mid; $failLog = $state.err } }
        $bad = $cands[$lo - 1]
        if ($bad.request) { $results[$bad.request] = @{ outcome = 'rejected'; message = "$rn : the build fails with this branch (and passes without it): $failLog" } }
        "[$e] culprit in $rn : $($bad.branch) ($($bad.agent))"
        $cands = @($cands | Where-Object { (Key $_) -ne (Key $bad) })
      }
      $kept = @($base) + @($cands)
      $null = Sync-Repo $e $r $kept -NoFetch
      $err = Build-Repo $e $rn
      if ($err) { $notes.Add("$rn still does not build after removing culprits: kept the running release ($err)"); foreach ($l in $kept | Where-Object { & $isNew $_ }) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : $err" } } }; continue }
    }
    $newLayers[$rn] = @($kept | Where-Object { & $isNew $_ })
    $artifacts += (Stage-Artifacts $e $rn $tag)
    $repoOut[$rn] = @{ target = $r.target; targetSha = $targetSha; layers = @($kept) }
    $ok.Add($rn)
  }
  # a request is all or nothing: refused/rejected in one repo -> taken out of every other repo of this train too
  $failed = @($results.Keys | Where-Object { $results[$_].outcome -ne 'live' })
  foreach ($rn in @($ok)) {
    if (-not @($repoOut[$rn].layers | Where-Object { $_.request -in $failed }).Count) { continue }
    $keep = @($repoOut[$rn].layers | Where-Object { $_.request -notin $failed })
    "[$e] $rn : taking out layers whose request failed in another repo"
    $null = Sync-Repo $e $envRepos[$rn] $keep -NoFetch
    $err = Build-Repo $e $rn
    if ($err) { $null = $ok.Remove($rn); $repoOut.Remove($rn); foreach ($s in @($artifacts.Keys | Where-Object { (RepoOf $e (Svc $e $_)) -eq $rn })) { $artifacts.Remove($s) }; $notes.Add("$rn : rebuild without the failed requests failed, kept the running release ($err)"); continue }
    $repoOut[$rn].layers = $keep; $newLayers[$rn] = @($newLayers[$rn] | Where-Object { $_.request -notin $failed })
    foreach ($kv in (Stage-Artifacts $e $rn $tag).GetEnumerator()) { $artifacts[$kv.Key] = $kv.Value }
  }

  # 4. switch over (fresh state: services the loop started meanwhile are included, ones stopped meanwhile are not)
  $st2 = Read-State $e
  $switch = @(EnvServices $e | Where-Object { (RepoOf $e $_) -in $ok -and (Managed $_) -and $st2.services[$_.name].status -eq 'up' -and -not ($_.hot -and -not $_.artifact) })
  $switchNames = @($switch | ForEach-Object name)
  $block = @(@($switchNames) + @(Dependents $e $switchNames) | Select-Object -Unique)
  if ($switch.Count) { Phase 'waiting for leases (switch-over)' $block @($affected); Wait-Leases $block @() $own }
  # LIGHT migration layers leaving the main env (dropped, replaced, conflicting, gone): plan the exact revert of the changeSets the
  # new release no longer has; it runs at the switch-over with the repo's services stopped. A staying layer that uses what a revert
  # removes blocks it: then the latest snapshot from before the leaving layer is restored, else the DB keeps them (said in notes).
  $reverts = @{}; $restores = @{}
  foreach ($rn in @($ok)) {
    $keepKeys = @($repoOut[$rn].layers | ForEach-Object { Key $_ })
    foreach ($l in @($cur[$rn] | Where-Object { $_.migrations -and -not (LayerLight $_) -and (Key $_) -notin $keepKeys })) { $notes.Add("HEAVY migration layer $($l.branch) left $rn : the DB keeps its changes (no exact revert; restore a snapshot from before it to undo)") }
    $leaving = @($cur[$rn] | Where-Object { (LayerLight $_) -and (Key $_) -notin $keepKeys })
    if (-not $leaving.Count) { continue }
    try { $p = Get-MigRevertPlan $e $rn $leaving @($repoOut[$rn].layers | Where-Object { $_.migrations -and $_.mclass }) $envRepos[$rn].wt $tag }
    catch { $notes.Add("revert plan for $($leaving.branch -join ', ') in $rn failed, the DB keeps their changeSets: $("$_".Split("`n")[0])"); continue }
    if ($p.blocked.Count) {
      $since = [int](@($leaving | ForEach-Object { if ($_.since) { [int]$_.since } else { [int]$st.release.n } }) | Measure-Object -Minimum).Minimum
      $sn = @($st.snapshots | Where-Object { $_ -and [int]$_.release -le $since }) | Select-Object -Last 1
      if ($sn -and (Get-EnvCfg $e).db.restore) { $restores[$rn] = $sn.name; $notes.Add("$rn : $(MigPlanText $p) -> restoring snapshot $($sn.name) instead (the services re-apply the live layers' migrations on start)") }
      else { $notes.Add("$rn : $(MigPlanText $p); no snapshot from before $($leaving.branch -join ', '): the DB keeps their changeSets") }
      continue
    }
    if ($p.count -and -not $p.cmd) { $notes.Add("$rn : $(MigPlanText $p)"); continue }
    if ($p.count) { $reverts[$rn] = $p; Phase "planned db revert in $rn : $($p.count) changeSets of $($leaving.branch -join ', ')" $block @($affected) }
  }
  # a release with new HEAVY migration layers: snapshot the DB first (db.snapshot hook), so a failed start or smoke can restore it.
  # New LIGHT layers take no snapshot: a db.tag hook (optional) marks the DB before them, a failure reverts their changeSets.
  $snap = $null
  $migRepos = @($ok | Where-Object { @($newLayers[$_] | Where-Object { $_.migrations }).Count })
  $lightNew = @($migRepos | ForEach-Object { @($newLayers[$_] | Where-Object { LayerLight $_ }) })
  if ($lightNew.Count) {
    $notes.Add("LIGHT migration layers $(@($lightNew.branch) -join ', '): no snapshot; their changeSets are reverted exactly when they leave")
    if ((Get-EnvCfg $e).db.tag) { $mt = "$e-$tag"; $err = Invoke-Hook $e 'tag' @{ tag = $mt }; if ($err) { $notes.Add("db.tag failed: $err") } else { foreach ($l in $lightNew) { $l.mtag = $mt } } }
  }
  $mig = @($migRepos | ForEach-Object { @($newLayers[$_] | Where-Object { $_.migrations -and -not (LayerLight $_) }) })
  $migRepos = @($ok | Where-Object { @($newLayers[$_] | Where-Object { $_.migrations -and -not (LayerLight $_) }).Count })
  if ($mig.Count -and (Get-EnvCfg $e).db.snapshot) {
    Phase 'db snapshot (migration layers)' $block @($affected)
    $snap = "$e-before-$tag"
    $err = Invoke-Hook $e 'snapshot' @{ snapshot = $snap }
    if ($err) { $notes.Add("db snapshot failed, release goes on without a restore point: $err"); $snap = $null }
    else { Update-State $e { param($x) $x.snapshots = @(@($x.snapshots) + @(@{ name = $snap; at = (Now); release = $newN; layers = @($mig.branch) }) | Where-Object { $_ } | Select-Object -Last 10) } }
  } elseif ($mig.Count) { $notes.Add("migration layers ($(@($mig.branch) -join ', ')) change the shared DB: no db.snapshot hook, no restore point") }

  # one rollback path (failed start or smoke): a DB restore undoes every migration of this train, so every repo with migration
  # layers rolls back with it; services stop before the restore and restart on their previous release
  $prevSvc = @{}; foreach ($s in $switch) { $prevSvc[$s.name] = $st2.services[$s.name] }
  $flag = @{ restored = $false; reverted = @() }
  $rollback = { param([string[]]$repos, $why)
    $set = [Collections.Generic.List[string]]::new(); foreach ($x in $repos) { if ($x -in $ok -and -not $set.Contains($x)) { $set.Add($x) } }
    if ($snap -and -not $flag.restored -and @($set | Where-Object { $_ -in $migRepos }).Count) { foreach ($x in $migRepos) { if ($x -in $ok -and -not $set.Contains($x)) { $set.Add($x) } } }
    foreach ($rn in $set) {
      "[$e] rolling back $rn : $why"
      foreach ($l in @($newLayers[$rn])) { if ($l.request) { $results[$l.request] = @{ outcome = 'rolled back'; message = $why } } }
      $repoOut.Remove($rn); $null = $ok.Remove($rn)
      foreach ($s in @($artifacts.Keys | Where-Object { (RepoOf $e (Svc $e $_)) -eq $rn })) { $artifacts.Remove($s) }
    }
    $svcs = @($switch | Where-Object { (RepoOf $e $_) -in $set })
    if ($snap -and -not $flag.restored -and @($set | Where-Object { $_ -in $migRepos }).Count) {
      foreach ($s in $svcs) { Stop-Svc $e $s 'rollback: DB restore' }
      $err = Invoke-Hook $e 'restore' @{ snapshot = $snap }; $notes.Add($(if ($err) { "db restore of $snap FAILED: $err" } else { "db restored from $snap" })); $flag.restored = $true
    }
    # no snapshot covers them: revert the changeSets the new LIGHT layers may have applied (those the previous release has stay)
    foreach ($rn in $set) {
      if ($flag.restored -and $rn -in $migRepos) { continue }
      $nl = @($newLayers[$rn] | Where-Object { LayerLight $_ }); if (-not $nl.Count) { continue }
      foreach ($s in @($svcs | Where-Object { (RepoOf $e $_) -eq $rn })) { Stop-Svc $e $s 'rollback: db revert' }
      try { $p = Get-MigRevertPlan $e $rn $nl @($cur[$rn] | Where-Object { $_.migrations -and $_.mclass }) '' "rb-$tag"; $err = if ($p.blocked.Count) { MigPlanText $p } else { Invoke-MigRevertPlan $e $p } } catch { $err = "$_".Split("`n")[0] }
      $notes.Add($(if ($err) { "db revert of $(@($nl.branch) -join ', ') in $rn FAILED, the DB may keep their changeSets: $err" } else { "db revert of $(@($nl.branch) -join ', ') in $rn : $($p.count) changeSets reverted" }))
    }
    foreach ($rn in @($set | Where-Object { $_ -in $flag.reverted })) { $notes.Add("$rn rolled back after its leaving layers' changeSets were reverted: the previous release re-applies them when it starts") }
    foreach ($rn in $set) {
      $rs = @($svcs | Where-Object { (RepoOf $e $_) -eq $rn })
      $noCopy = @($rs | Where-Object { $_.artifact -and -not ($prevSvc[$_.name].artifact -and (Test-Path $prevSvc[$_.name].artifact)) })
      $prevArt = @{}
      if (@($rs | Where-Object { -not $_.artifact }).Count -or $envRepos[$rn].live -or $noCopy.Count) {
        $null = Sync-Repo $e $envRepos[$rn] @($cur[$rn]) -NoFetch
        $berr = Build-Repo $e $rn
        if ($berr) { $notes.Add("rollback build of $rn failed: $berr") } elseif ($noCopy.Count) { $prevArt = Stage-Artifacts $e $rn "r$($st.release.n)-rb$Train" }
      }
      foreach ($s in $rs) {
        $p = $prevSvc[$s.name]
        $art = if ($prevArt[$s.name]) { $prevArt[$s.name] } elseif ($s.artifact -and $p.artifact -and (Test-Path $p.artifact)) { $p.artifact } else { $null }
        if ($s.artifact -and -not $art) { $notes.Add("rollback of $($s.name): no build of the previous release, left stopped"); continue }
        try { Start-Svc $e $s ([int]$p.release) $art } catch { $notes.Add("rollback of $($s.name) failed too: $("$_".Split("`n")[0])") }
      }
    }
  }
  # leaving layers' DB changes go first, with the repo's services stopped (the new release must not start on them)
  foreach ($rn in @(@($reverts.Keys) + @($restores.Keys) | Select-Object -Unique)) {
    if ($rn -notin $ok) { continue }
    foreach ($s in @($switch | Where-Object { (RepoOf $e $_) -eq $rn })) { Stop-Svc $e $s 'db revert of leaving migration layers' }
    if ($restores[$rn]) {
      Phase "db restore $($restores[$rn]) ($rn)" $block @($affected)
      $err = Invoke-Hook $e 'restore' @{ snapshot = $restores[$rn] }
      if ($err) { & $rollback @($rn) "db restore of $($restores[$rn]) failed: $err"; continue }
      $notes.Add("db restored from $($restores[$rn])"); $flag.reverted += $rn; continue
    }
    $p = $reverts[$rn]
    Phase "db revert in $rn : $($p.count) changeSets of $($p.branches -join ', ')" $block @($affected)
    $err = Invoke-MigRevertPlan $e $p
    if ($err) {
      & $rollback @($rn) "db revert failed: $err"
      foreach ($q in @($reqs | Where-Object { $_.kind -eq 'drop' -and $_.branch -in $p.branches })) { $results[$q.id] = @{ outcome = 'rolled back'; message = "db revert failed, the layer stays: $err" } }
      continue
    }
    $flag.reverted += $rn
    $notes.Add("db revert in $rn : $($p.count) changeSets of $($p.branches -join ', ') reverted$(if ((Get-EnvCfg $e).db.applied) { ', verified (db.applied)' } else { ' (not verified: no db.applied hook)' })")
  }
  Phase 'switching over' $block @($affected)
  foreach ($s in $switch) {
    $rn = RepoOf $e $s
    if ($rn -notin $ok) { continue }
    try { Start-Svc $e $s $newN $artifacts[$s.name] }
    catch { & $rollback @($rn) "$($s.name) did not come up with it: $("$_".Split("`n")[0])" }
  }
  if ($switch.Count -and $ok.Count -and (Get-EnvCfg $e).smoke) {
    Phase 'smoke checks' $block @($affected)
    $sf = Test-Smoke $e
    if ($sf) { & $rollback @($ok) "smoke check failed: $sf" }
  }
  Record-Train
}

# Record the release and every request's result; clears the train. Uses Run-Train's variables (dynamic scope).
function Record-Train {
  $changed = @($repoOut.Keys)
  Update-State $e { param($x)
    if ($changed.Count) {
      foreach ($rn in $changed) {
        # promotions made while the train ran (same branch + commit) are kept
        foreach ($l in @($repoOut[$rn].layers)) {
          $was = @($x.release.repos[$rn].layers | Where-Object { $_ -and (Key $_) -eq (Key $l) }) | Select-Object -First 1
          if ($was.promoted) { $l.promoted = $was.promoted }
          $l.since = if ($was -and $was.since) { $was.since } elseif ($was) { [int]$x.release.n } else { $newN }   # first release with this commit live
        }
        $x.release.repos[$rn] = $repoOut[$rn]
      }
      $x.release.n = $newN; $x.release.at = (Now); $x.release.train = $Train
      foreach ($sn in $artifacts.Keys) { if (-not $x.services[$sn]) { $x.services[$sn] = @{ status = 'down' } }; if ($x.services[$sn].status -ne 'up') { $x.services[$sn].artifact = $artifacts[$sn]; $x.services[$sn].release = $newN } }
      $x.releases = @(@($x.releases) + @(@{ n = $newN; at = (Now); train = $Train; changed = $changed; notes = @($notes) }) | Select-Object -Last 20)
    }
    foreach ($id in @($migNote.Keys)) { if ($results[$id] -and $results[$id].outcome -eq 'live') { $results[$id].message = (@($results[$id].message, $migNote[$id]) | Where-Object { $_ }) -join '; ' } }
    foreach ($r in $x.requests) { if ($results.ContainsKey($r.id)) { $r.status = 'done'; $r.result = $results[$r.id]; $r.result.release = $(if ($results[$r.id].outcome -eq 'live') { $(if ($changed.Count) { $newN } else { $x.release.n }) }) } }
    $x.train = $null
  }
  foreach ($r in @($reqs | Where-Object { $_.noSandbox -and $results[$_.id].outcome -eq 'live' })) {
    $live = (Read-State $e).sandboxes
    foreach ($key in @($live.Keys | Where-Object { $live[$_].branch -eq $r.branch })) { Remove-Sandbox $e $key; $notes.Add("sandbox $key removed: $($r.branch) is live in the main env") }
  }
  Event $e 'release' @{ n = $(if ($changed.Count) { $newN } else { $null }); train = $Train; changed = $changed; results = $results; notes = @($notes) }
  $notes | ForEach-Object { "[$e] $_" }
  "[$e] train $Train done: $(if ($changed.Count) { "release $newN ($($changed -join ', '))" } else { 'no new release' })"
}

if ($Train) {
  # the loop writes the train record before it starts this worker; wait briefly for it
  for ($i = 0; $i -lt 20 -and -not ((Read-State $e).train.id -eq $Train); $i++) { Start-Sleep -Milliseconds 250 }
  try { Run-Train *>&1 | Tee-Object -FilePath (LogFile $e 'train') -Append }
  catch {
    $why = "$_"; "[$e] train $Train crashed: $why $($_.ScriptStackTrace)" | Add-Content (LogFile $e 'train')
    Update-State $e { param($x) foreach ($r in $x.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($x.train.requests)) { $r.status = 'done'; $r.result = @{ outcome = 'error'; message = "train crashed: $why" } } }; $x.train = $null }
  }
  exit
}

# ================================================================ the env loop
$mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { "Global\kit-localenv-loop-$e" } else { "kit-localenv-loop-$e" }))
$owned = $false
try { $owned = $mx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit }
$log = LogFile $e 'loop'
function Say([string]$m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Add-Content $log }
Say "loop started (pid $PID)"
$quietSince = Get-Date; $tick = 0; $clientNeed = @{}
try {
  while ($true) {
    $tick++
    Update-State $e { param($x) Prune $x; $x.loop = @{ pid = $PID; beat = (Now) } }
    $st = Read-State $e

    # ---- trains: one worker at a time takes every queued request (a batch). The record comes first, then the process.
    $queued = @($st.requests | Where-Object { $_.status -eq 'queued' })
    if (-not $st.train -and $queued.Count) {
      $tid = [guid]::NewGuid().ToString('n').Substring(0, 6); $ids = @($queued.id)
      Update-State $e { param($x) $x.train = @{ id = $tid; pid = $null; phase = 'starting'; requests = $ids; at = (Now); blockServices = @(); blockRepos = @() }; foreach ($r in $x.requests) { if ($r.id -in $ids) { $r.status = 'in-train' } } }
      $wp = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -NonInteractive -File `"$PSCommandPath`" -Env $e -Train $tid" -WindowStyle Hidden -PassThru
      Update-State $e { param($x) if ($x.train -and $x.train.id -eq $tid) { $x.train.pid = $wp.Id } }
      Say "train $tid started for $($ids.Count) request(s): $(($queued | ForEach-Object { "$($_.kind) $($_.branch)" }) -join '; ')"
      $st = Read-State $e
    }

    # ---- demand (client traffic is probed every 5th tick: it is the slow part)
    $all = Get-SysProcs -NoCommandLine
    $envPids = @(foreach ($s in EnvServices $e) { SvcPids $e $s $st $all })
    if ($tick % 5 -eq 1) { $clientNeed = @{}; foreach ($s in EnvServices $e | Where-Object { $_.port -and $st.services[$_.name].status -eq 'up' -and -not ($st.suppress -and $_.name -in @($st.suppress.services) -and [datetime]$st.suppress.until -gt (Get-Date)) }) { if (@(ClientPids ([int]$s.port) $envPids).Count) { $clientNeed[$s.name] = $true } } }
    $need = @{}
    $addNeed = { param($names, $why) foreach ($n in (Closure $e @($names))) { if (-not $need[$n]) { $need[$n] = @() }; $need[$n] += $why } }
    foreach ($a in $st.leases.Keys) { & $addNeed @($st.leases[$a].services) "lease:$a" }
    foreach ($a in $st.holds.Keys) { & $addNeed @($st.holds[$a].services) "hold:$a" }
    foreach ($n in $clientNeed.Keys) { & $addNeed @($n) 'clients' }
    $block = @($st.train.blockServices)
    $needNames = @($need.Keys)
    Update-State $e { param($z) foreach ($n in @($z.services.Keys)) { if ($z.services[$n].need -and $n -notin $needNames) { $z.services[$n].need = @() } } }   # reasons that ended

    # ---- stop first (frees RAM for what must start): idle past its grace (dependents first), or idle at once under pressure
    $pressure = Pressure
    $running = @(EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -eq 'up' -and -not $need[$_.name] -and $_.name -notin $block })
    $idle = @($running | Where-Object {
        $n = $_.name; $x = $st.services[$n]
        $since = [datetime]$(if ($x.lastNeed) { $x.lastNeed } elseif ($x.upAt) { $x.upAt } else { (Now) })
        $dependentsUp = @(Dependents $e @($n) | Where-Object { $st.services[$_].status -eq 'up' })
        -not $dependentsUp.Count -and ($pressure -or ($IdleOn -and ((Get-Date) - $since).TotalMinutes -ge (GraceMin $e $_)))
      } | Sort-Object { -[double]$st.services[$_.name].gb })
    if ($idle.Count) {
      $s = $idle[0]   # one per tick, biggest first
      $why = if ($pressure) { "idle, stopped under memory pressure ($pressure)" } else { "idle for $(GraceMin $e $s) min" }
      Say "stopping $($s.name): $why"; Stop-Svc $e $s $why
      $st = Read-State $e
    }

    # ---- start what is needed (dependencies first), restart crashes with backoff
    $needsBuild = $false
    foreach ($s in EnvServices $e | Where-Object { Managed $_ }) {
      $x = $st.services[$s.name]
      if (-not $need[$s.name]) { continue }
      Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{ status = 'down' } }; $z.services[$s.name].lastNeed = (Now); $z.services[$s.name].need = @($need[$s.name]) }
      if ($s.name -in $block) { continue }
      if (Healthy $e $s) { if ($x.status -ne 'up') { Update-State $e { param($z) $z.services[$s.name].status = 'up' } }; continue }
      if ($x.status -eq 'starting' -and (Owned $x) -and $x.startedAt -and ((Get-Date) - [datetime]$x.startedAt).TotalMinutes -lt [double]$(if ($s.startMinutes) { $s.startMinutes } else { 10 })) { continue }
      if (@($s.dependsOn | Where-Object { $_ -and -not (Healthy $e (Svc $e $_)) }).Count) { continue }   # its dependencies come up first
      $recent = @($x.restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 })
      if ($x.status -eq 'failed' -and $recent.Count -ge 3) { continue }   # backoff: 3 tries in 30 min, then failed until a deploy or `up`
      if ($s.repo -and ([int]$st.release.n -eq 0 -or ($s.artifact -and -not ($x.artifact -and (Test-Path $x.artifact))))) { $needsBuild = $true; continue }
      Update-State $e { param($z) $z.services[$s.name].restarts = @(@($recent) + @(Now)) }
      try { Start-Svc $e $s ([int]$st.release.n) $x.artifact *>&1 | ForEach-Object { Say "$_" } } catch { Say "start of $($s.name) failed: $("$_".Split("`n")[0])" }
      $st = Read-State $e
    }
    # nothing built yet (first use, or an artifact missing): queue one refresh, which builds and stages
    if ($needsBuild -and -not $st.train -and -not @($st.requests | Where-Object { $_.status -ne 'done' }).Count) {
      $rid = [guid]::NewGuid().ToString('n').Substring(0, 8)
      Update-State $e { param($z) $z.requests = @($z.requests) + @(@{ id = $rid; kind = 'refresh'; agent = 'controller'; at = (Now); status = 'queued' }) }
      Say 'queued a refresh: a needed service has no build yet'
    }

    # ---- sandboxes: a lease on an instance keeps it; idle past sandbox.idleHours (4) -> drop (instances, DB copy, worktree go)
    if ($st.sandboxes.Count) {
      $sbIdleH = [double]$(if ((SandboxCfg $e).idleHours) { (SandboxCfg $e).idleHours } else { 4 })
      foreach ($key in @($st.sandboxes.Keys)) {
        $sbx = $st.sandboxes[$key]
        $inUse = @($st.leases.Values | Where-Object { @($_.services | Where-Object { $_ -like "$key-*" }).Count }).Count
        if ($inUse) { Update-State $e { param($z) if ($z.sandboxes[$key]) { $z.sandboxes[$key].lastUse = (Now) } }; continue }
        if (((Get-Date) - [datetime]$sbx.lastUse).TotalHours -ge $sbIdleH -and -not @($st.requests | Where-Object { $_.status -ne 'done' -and $_.branch -eq $sbx.branch }).Count) {
          $rid = [guid]::NewGuid().ToString('n').Substring(0, 8)
          Update-State $e { param($z) $z.requests = @($z.requests) + @(@{ id = $rid; kind = 'drop'; branch = $sbx.branch; agent = 'controller'; at = (Now); status = 'queued' }) }
          Say "sandbox $key ($($sbx.branch)) idle $sbIdleH h: drop queued"
        }
      }
    }
    # DB copies no sandbox owns (left by a crash): sandbox.db.sweep with {keep} = this env's live sandboxes, every ~30 min
    if ((SandboxCfg $e).db.sweep -and $tick % 600 -eq 2) {
      $keep = @($st.sandboxes.Keys) -join ','
      $cmd = (Expand-Placeholders ([string](SandboxCfg $e).db.sweep) $e ([pscustomobject]@{}) $KitConf.Workspace '').Replace('{keep}', $(if ($keep) { $keep } else { 'none' }))
      $null = Invoke-Shell $cmd (LogFile $e 'db') (EnvVars $e ([pscustomobject]@{}))
    }

    # ---- exit once nothing runs and nothing is asked for a while
    $st = Read-State $e
    $busy = $st.train -or @($st.requests | Where-Object { $_.status -ne 'done' }).Count -or $st.leases.Count -or $st.holds.Count -or $st.sandboxes.Count -or
      @(EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -in 'up', 'starting' }).Count
    if ($busy) { $quietSince = Get-Date } elseif (((Get-Date) - $quietSince).TotalMinutes -ge $LoopExitM) { Say 'idle: loop exits'; break }
    Start-Sleep 3
  }
} catch { Say "loop crashed: $_ $($_.ScriptStackTrace)" }
finally {
  Update-State $e { param($x) if ($x.loop -and $x.loop.pid -eq $PID) { $x.loop = $null } }
  try { $mx.ReleaseMutex() } catch { }
}
