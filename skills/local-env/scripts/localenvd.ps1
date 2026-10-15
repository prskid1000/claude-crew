#Requires -Version 7
<#
The controller of one local env (started by localenv.ps1 when needed; never by hand). Two modes:

  localenvd.ps1 -Env <env>               the env's loop: lifecycle (start what is needed, stop what idles past its grace or under
                                         memory pressure, restart crashes with backoff), and starts one train worker at a time for
                                         queued deploy / drop / refresh requests. One loop per env (a named mutex); it exits once
                                         nothing runs and nothing is asked for localEnv.loopExitMinutes (default 10).
  localenvd.ps1 -Env <env> -Train <id>   a train worker: takes the requests the loop gave it, merges every deployed branch on the
                                         target, builds through the gate, finds the culprit when the build fails (the others still
                                         go live), stages artifacts, waits for the leases it affects, switches over, rolls back a
                                         service whose new release does not come up, and records release n+1 with a result per request.
Log: Get-KitPath localenv-logs /<env>-loop.log and /<env>-train.log; events in /<env>-events.jsonl.
#>
param([Parameter(Mandatory)][Alias('Env')][string]$EnvName, [string]$Train)
. (Join-Path $PSScriptRoot 'localenv-lib.ps1')
$e = $EnvName
$ErrorActionPreference = 'Stop'

# ================================================================ train worker
function Wait-Leases([string[]]$services, [string[]]$repos) {
  $said = $null
  while ($true) {
    $o = @{ who = @() }
    Update-State $e { param($x)
      Prune $x
      $o.who = @($x.leases.Keys | Where-Object { $l = $x.leases[$_]; @($l.services | Where-Object { $_ -in $services }).Count -or @($l.repos | Where-Object { $_ -in $repos }).Count })
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
function Run-Train {
  $st = Read-State $e
  if (-not $st.train -or $st.train.id -ne $Train) { "[$e] train $Train is not the env's current train: nothing to do"; return }
  $reqs = @($st.requests | Where-Object { $_.id -in @($st.train.requests) })
  $envRepos = EnvRepos $e
  $cur = @{}; foreach ($rn in $envRepos.Keys) { $cur[$rn] = @(Layers $st $rn) }
  $want = @{}; foreach ($rn in $envRepos.Keys) { $want[$rn] = @($cur[$rn]) }
  $affected = [Collections.Generic.List[string]]::new()
  $byBranch = @{}   # "<repo>|<branch>" -> request id (whose result a layer decides)
  foreach ($r in $reqs) {
    switch ($r.kind) {
      'deploy' { foreach ($rn in @($r.shas.Keys)) {
          $l = @{ branch = $r.branch; agent = $r.agent; sha = $r.shas[$rn]; at = $r.at; migrations = [bool]$r.migrations[$rn]; request = $r.id }
          $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }) + @($l); if (-not $affected.Contains($rn)) { $affected.Add($rn) }; $byBranch["$rn|$($r.branch)"] = $r.id } }
      'drop' { foreach ($rn in $envRepos.Keys) { if (@($want[$rn].branch) -contains $r.branch) { $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }); if (-not $affected.Contains($rn)) { $affected.Add($rn) } } } }
      'refresh' { foreach ($rn in $envRepos.Keys) { if (-not $affected.Contains($rn)) { $affected.Add($rn) } } }
    }
  }
  $results = @{}; foreach ($r in $reqs) { $results[$r.id] = @{ outcome = 'live'; message = '' } }
  $notes = [Collections.Generic.List[string]]::new()
  $newN = [int]$st.release.n + 1
  $repoOut = @{}; $artifacts = @{}; $okRepos = @()

  # 1. code: wait for task leases on the repos (they read the worktree); a live repo (a service runs from its worktree) also waits
  #    for the leases on those services, because syncing it changes what they serve
  $liveSvcs = @(EnvServices $e | Where-Object { $_.repo -and -not $_.artifact -and (RepoOf $e $_) -in $affected } | ForEach-Object name)
  $liveBlock = @(@($liveSvcs) + @(Dependents $e $liveSvcs) | Select-Object -Unique)
  Phase 'waiting for leases (code)' $liveBlock @($affected)
  Wait-Leases $liveBlock @($affected)
  Phase 'merging and building' $liveBlock @($affected)

  foreach ($rn in $affected) {
    $r = $envRepos[$rn]
    $prevKey = @($cur[$rn] | ForEach-Object { "$($_.branch)@$($_.sha)" })
    $isNew = { param($l) "$($l.branch)@$($l.sha)" -notin $prevKey }
    $res = Sync-Repo $e $r @($want[$rn])
    foreach ($d in $res.dropped) {
      $rid = $byBranch["$rn|$($d.layer.branch)"]
      if ($rid -and (& $isNew $d.layer)) { $results[$rid] = @{ outcome = 'refused'; message = "$rn : $($d.why)" } }
      else { $notes.Add("dropped layer $($d.layer.branch) ($($d.layer.agent)) from $rn : $($d.why)$(if ($d.layer.migrations) { ' - it had migrations: the local DB keeps them' })") }
    }
    $kept = @($res.kept); $targetSha = $res.targetSha
    $live = $st.release.repos[$rn]
    if ([int]$st.release.n -gt 0 -and $live -and $live.targetSha -eq $targetSha -and (@($kept | ForEach-Object { "$($_.branch)@$($_.sha)" }) -join '|') -eq (@($cur[$rn] | ForEach-Object { "$($_.branch)@$($_.sha)" }) -join '|')) {
      "[$e] $rn unchanged (same target commit and layers): no build"
      foreach ($l in $kept) { if ($l.request -and $results[$l.request].outcome -eq 'live') { $results[$l.request].message = 'already live' } }
      continue
    }
    $err = Build-Repo $e $rn
    if ($err) {
      # culprit search: the old layers built before, so look among the new ones (smallest failing prefix, one build per step)
      $base = @($kept | Where-Object { -not (& $isNew $_) }); $cands = @($kept | Where-Object { & $isNew $_ })
      $try = { param($set) $null = Sync-Repo $e $r @($set) -NoFetch; $script:lastErr = Build-Repo $e $rn; -not $script:lastErr }
      Phase "build failed in $rn : finding the culprit among $($cands.Count) new layer(s)" $liveBlock @($affected)
      if (-not $cands.Count -or -not (& $try $base)) {
        foreach ($l in $cands) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : the target + the layers already live do not build either, so nothing new can go live: $($script:lastErr)" } } }
        $notes.Add("$rn does not build on its target + current layers: kept the running release")
        $kept = $base; $cands = @()
      }
      while ($cands.Count) {
        if (& $try (@($base) + @($cands))) { break }
        $lo = 1; $hi = $cands.Count; $failLog = $script:lastErr
        while ($lo -lt $hi) { $mid = [int][math]::Floor(($lo + $hi) / 2); if (& $try (@($base) + @($cands[0..($mid - 1)]))) { $lo = $mid + 1 } else { $hi = $mid; $failLog = $script:lastErr } }
        $bad = $cands[$lo - 1]
        if ($bad.request) { $results[$bad.request] = @{ outcome = 'rejected'; message = "$rn : the build fails with this branch (and passes without it): $failLog" } }
        "[$e] culprit in $rn : $($bad.branch) ($($bad.agent))"
        $cands = @($cands | Where-Object { $_ -ne $bad })
      }
      $kept = @($base) + @($cands)
      $null = Sync-Repo $e $r $kept -NoFetch
      $err = Build-Repo $e $rn
      if ($err) { $notes.Add("$rn still does not build after removing culprits: kept the running release ($err)"); foreach ($l in $kept | Where-Object { & $isNew $_ }) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : $err" } } }; continue }
    }
    $artifacts += (Stage-Artifacts $e $rn $newN)
    $repoOut[$rn] = @{ target = $r.target; targetSha = $targetSha; layers = @($kept) }
    $okRepos += $rn
  }

  # 2. switch over: restart the running services of the repos that changed (hot ones reload by themselves)
  $switch = @(EnvServices $e | Where-Object { (RepoOf $e $_) -in $okRepos -and (Managed $_) -and $st.services[$_.name].status -eq 'up' -and -not ($_.hot -and -not $_.artifact) })
  $switchNames = @($switch | ForEach-Object name)
  $block = @(@($switchNames) + @(Dependents $e $switchNames) | Select-Object -Unique)
  if ($switch.Count) { Phase 'waiting for leases (switch-over)' $block @(); Wait-Leases $block @() }
  Phase 'switching over' $block @()
  foreach ($s in $switch) {
    $prev = (Read-State $e).services[$s.name]
    try { Start-Svc $e $s $newN $artifacts[$s.name] }
    catch {
      $why = "$_".Split("`n")[0]
      "[$e] $($s.name) failed on release $newN : rolling back"
      $rn = RepoOf $e $s
      foreach ($l in @($repoOut[$rn].layers | Where-Object { "$($_.branch)@$($_.sha)" -notin @($cur[$rn] | ForEach-Object { "$($_.branch)@$($_.sha)" }) })) { if ($l.request) { $results[$l.request] = @{ outcome = 'rolled back'; message = "$($s.name) did not come up with it: $why" } } }
      $repoOut.Remove($rn); $okRepos = @($okRepos | Where-Object { $_ -ne $rn })
      if ($s.artifact -and $prev.artifact -and (Test-Path $prev.artifact)) { try { Start-Svc $e $s ([int]$prev.release) $prev.artifact } catch { $notes.Add("rollback of $($s.name) failed too: $_") } }
      else { $null = Sync-Repo $e $envRepos[$rn] @($cur[$rn]) -NoFetch; $null = Build-Repo $e $rn; try { Start-Svc $e $s ([int]$prev.release) $null } catch { $notes.Add("rollback of $($s.name) failed too: $_") } }
    }
  }

  # 3. record the release and every request's result
  $changed = @($repoOut.Keys)
  Update-State $e { param($x)
    if ($changed.Count) {
      foreach ($rn in $changed) { $x.release.repos[$rn] = $repoOut[$rn] }
      $x.release.n = $newN; $x.release.at = (Now); $x.release.train = $Train
      foreach ($sn in $artifacts.Keys) { if (-not $x.services[$sn]) { $x.services[$sn] = @{ status = 'down' } }; if ($x.services[$sn].status -ne 'up' -or $x.services[$sn].release -ne $newN) { if ($x.services[$sn].status -ne 'up') { $x.services[$sn].artifact = $artifacts[$sn]; $x.services[$sn].release = $newN } } }
      $x.releases = @(@($x.releases) + @(@{ n = $newN; at = (Now); train = $Train; changed = $changed; notes = @($notes) }) | Select-Object -Last 20)
    }
    foreach ($r in $x.requests) { if ($results.ContainsKey($r.id)) { $r.status = 'done'; $r.result = $results[$r.id]; $r.result.release = $(if ($results[$r.id].outcome -eq 'live') { $(if ($changed.Count) { $newN } else { $x.release.n }) }) } }
    $x.train = $null
  }
  Event $e 'release' @{ n = $(if ($changed.Count) { $newN } else { $null }); train = $Train; changed = $changed; results = $results; notes = @($notes) }
  $notes | ForEach-Object { "[$e] $_" }
  "[$e] train $Train done: $(if ($changed.Count) { "release $newN ($($changed -join ', '))" } else { 'no new release' })"
}

if ($Train) {
  try { Run-Train *>&1 | Tee-Object -FilePath (LogFile $e 'train') -Append }
  catch {
    "[$e] train $Train crashed: $_ $($_.ScriptStackTrace)" | Add-Content (LogFile $e 'train')
    Update-State $e { param($x) foreach ($r in $x.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($x.train.requests)) { $r.status = 'done'; $r.result = @{ outcome = 'error'; message = "train crashed: $_" } } }; $x.train = $null }
  }
  exit
}

# ================================================================ the env loop
$mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { "Global\kit-localenv-loop-$e" } else { "kit-localenv-loop-$e" }))
try { if (-not $mx.WaitOne(0)) { exit } } catch [Threading.AbandonedMutexException] { }
$log = LogFile $e 'loop'
function Say([string]$m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Add-Content $log }
Say "loop started (pid $PID)"
$quietSince = Get-Date; $tick = 0; $clientNeed = @{}
try {
  while ($true) {
    $tick++
    Update-State $e { param($x) Prune $x; $x.loop = @{ pid = $PID; beat = (Now) } }
    $st = Read-State $e

    # ---- trains: one worker at a time takes every queued request (a batch)
    $queued = @($st.requests | Where-Object { $_.status -eq 'queued' })
    if (-not $st.train -and $queued.Count) {
      $tid = [guid]::NewGuid().ToString('n').Substring(0, 6)
      $pwsh = (Get-Process -Id $PID).Path
      $wp = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile -NonInteractive -File `"$PSCommandPath`" -Env $e -Train $tid" -WindowStyle Hidden -PassThru
      $ids = @($queued.id)
      Update-State $e { param($x) $x.train = @{ id = $tid; pid = $wp.Id; phase = 'starting'; requests = $ids; at = (Now); blockServices = @(); blockRepos = @() }; foreach ($r in $x.requests) { if ($r.id -in $ids) { $r.status = 'in-train' } } }
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
    $needsBuild = $false
    $needNames = @($need.Keys)
    Update-State $e { param($z) foreach ($n in @($z.services.Keys)) { if ($n -notin $needNames -and $z.services[$n].need) { $z.services[$n].need = @() } } }   # reasons that ended

    # ---- lifecycle: start what is needed (dependencies first), restart crashes with backoff
    foreach ($s in EnvServices $e | Where-Object { Managed $_ }) {
      $x = $st.services[$s.name]
      if (-not $need[$s.name]) { continue }
      Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{ status = 'down' } }; $z.services[$s.name].lastNeed = (Now); $z.services[$s.name].need = @($need[$s.name]) }
      if (($s.name -in $block) -or ($x.status -eq 'starting' -and (Alive $x.pid))) { continue }
      if (Healthy $e $s) { if ($x.status -ne 'up') { Update-State $e { param($z) $z.services[$s.name].status = 'up' } }; continue }
      if (@($s.dependsOn | Where-Object { $_ -and -not (Healthy $e (Svc $e $_)) }).Count) { continue }   # its dependencies come up first
      $recent = @($x.restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 })
      if ($x.status -eq 'failed' -and $recent.Count -ge 3) { continue }   # backoff: 3 tries in 30 min, then it stays failed until a deploy or `up`
      if ($s.repo -and ([int]$st.release.n -eq 0 -or ($s.artifact -and -not ($x.artifact -and (Test-Path $x.artifact))))) { $needsBuild = $true; continue }
      Update-State $e { param($z) $z.services[$s.name].restarts = @(@($recent) + @(Now)) }
      try { Start-Svc $e $s ([int]$st.release.n) $x.artifact *>&1 | ForEach-Object { Say "$_" } } catch { Say "start of $($s.name) failed: $("$_".Split("`n")[0])" }
      $st = Read-State $e
    }
    # nothing built yet (first use, or an artifact missing): queue a refresh, which builds release 1 / re-stages artifacts
    if ($needsBuild -and -not $st.train -and -not @($st.requests | Where-Object { $_.status -ne 'done' }).Count) {
      $rid = [guid]::NewGuid().ToString('n').Substring(0, 8)
      Update-State $e { param($z) $z.requests = @($z.requests) + @(@{ id = $rid; kind = 'refresh'; agent = 'controller'; at = (Now); status = 'queued' }) }
      Say 'queued a refresh: a needed service has no build yet'
    }

    # ---- stop what idles past its grace (dependents first), or anything idle at once under memory pressure
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
    }

    # ---- exit once nothing runs and nothing is asked for a while
    $st = Read-State $e
    $busy = $st.train -or @($st.requests | Where-Object { $_.status -ne 'done' }).Count -or $st.leases.Count -or $st.holds.Count -or
      @(EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -in 'up', 'starting' }).Count
    if ($busy) { $quietSince = Get-Date } elseif (((Get-Date) - $quietSince).TotalMinutes -ge $LoopExitM) { Say 'idle: loop exits'; break }
    Start-Sleep 3
  }
} catch { Say "loop crashed: $_ $($_.ScriptStackTrace)" }
finally {
  Update-State $e { param($x) if ($x.loop -and $x.loop.pid -eq $PID) { $x.loop = $null } }
  try { $mx.ReleaseMutex() } catch { }
}
