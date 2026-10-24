<#
deploys.ps1 (goody deploys): the deploy batch of bossy E5, dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 deploy plan [-Env <target>] [-Json] [-Offline <fixture>]   merged-not-deployed MRs per test env, trigger, window
  bossy.ps1 deploy request -Mrs <refs> -Run <run> [-Note ..] · record -Env <target> [-Mrs <refs>] [-By ..] [-Note ..]
  bossy.ps1 deploy intest [-Apply] [-Quiet] [-Task <ids>]   promoted tasks whose MRs are live on a test env -> inTest
  bossy.ps1 deploy merge ...   adapters/deploy_merge.ps1
supervise -AutoFix calls Get-KitSuperviseFlagsDeploys: a done task live on a test env -> inTest; the plan cached 1 h (DEPLOY ASK).
Sections: L13 helpers · L23 intest · L102 deploy · L212 supervise
Exit codes: 0 ok · 2 usage.
#>
#Requires -Version 7

# ---- helpers: test-env filter, MR refs
# not a test env: deploys[].production, else productionPattern on the name; -Lanes: + laneApk
function Get-NoTestRx([switch]$Lanes) { $rx = Get-KitSetting 'deploy.productionPattern' '(?i)prod|critical'; $n = @(@(Get-KitValue 'repos' @()) | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and ($(if ($null -ne $_.production) { $_.production } else { $_.target -match $rx }) -or ($Lanes -and $_.laneApk)) } | ForEach-Object { [regex]::Escape($_.target) }); "^($($n -join '|'))$" }
# <alias>!<iid> -> <repo name>!<iid>
function Get-CanonMr([string]$m) {
  if ($m -notmatch '^(?<r>[\w.-]+)!(?<i>\d+)$') { return $m }
  $rp = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $Matches.r -or @($_.aliases) -contains $Matches.r } | Select-Object -First 1
  if ($rp) { "$($rp.name)!$($Matches.i)" } else { $m }
}

# ---- intest: promoted tasks live on a test env -> inTest
# deployed promoted tasks -> inTest
function Invoke-MarkInTest {
param([switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
$ErrorActionPreference = 'SilentlyContinue'
function Out-Line($s) { if (-not $Quiet -or $s -like 'MARKED*') { $s } }

$cand = [ordered]@{}
$trackFile = Get-KitPath tracking
$track = if ($trackFile -and (Test-Path $trackFile)) { Get-Content $trackFile -Raw | ConvertFrom-Json } else { $null }
if ($track) { foreach ($p in $track.tasks.PSObject.Properties) { $cand[$p.Name] = @{ mrs = @($p.Value.mrs); name = '' } } }
$ownerId = try { "$(Get-TrackerOwner)".Trim() } catch { '' }
$lists = @(Get-KitValue 'trackerLists' @()) | Where-Object { $_ } | Select-Object -Unique
if ($lists.Count) {
  foreach ($l in $lists) {
    $arr = try { @(Get-TrackerTasks $l 'promoted') } catch { Write-Warning "mark-in-test: list $l lookup failed: $($_.Exception.Message)"; @() }
    foreach ($t in $arr) {
      if ($ownerId -and -not (@($t.assignees | ForEach-Object { "$($_.id)" }) -contains $ownerId)) { continue }
      if (-not $cand.Contains($t.id)) { $cand[$t.id] = @{ mrs = @(); name = $t.name } } elseif (-not $cand[$t.id].name) { $cand[$t.id].name = $t.name }
    }
  }
}
# pwsh -File passes a,b as one string
if ($Task.Count) { $keep = @($Task | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ }); foreach ($k in @($cand.Keys)) { if ($k -notin $keep) { $cand.Remove($k) } }; foreach ($k in $keep) { if (-not $cand.Contains($k)) { $cand[$k] = @{ mrs = @(); name = '' } } } }

$productTargets = @(Get-KitValue 'productTargets' @())
$pathMemo = @{}
function Get-MrPaths([string]$mr) {
  if ($pathMemo.ContainsKey($mr)) { return $pathMemo[$mr] }
  $repo, $iid = $mr -split '!'
  $res = Invoke-HostApi "projects/$(Get-HostProject $repo)/merge_requests/$iid/changes"
  $pathMemo[$mr] = @($res.changes | ForEach-Object { $_.new_path } | Where-Object { $_ })
  $pathMemo[$mr]
}

$marked = 0; $wait = 0; $gone = @()
foreach ($id in $cand.Keys) {
  # a task deleted in the tracker: skipped, reported, dropped from tracking; another task's failure never ends the batch
  $info = try { Get-TrackerTask $id } catch { if (Remove-KitGoneTask $id $_) { $gone += $id; Out-Line "GONE  $id  deleted in the tracker: skipped, no longer tracked" } else { Out-Line "ERROR $id  tracker view failed: $($_.Exception.Message)" }; continue }
  if (-not $info) { continue }
  if (-not (Test-TrackerStatus ([string]$info.status) 'promoted')) { continue }  # never override a person
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
  if (-not $mrs.Count) { Out-Line "SKIP  $id  no MRs found | $short"; continue }
  $live = @(); $why = $null
  foreach ($mr in $mrs) {
    $rows = @(& $KitCmd.qa deployed -Mrs $mr -Json -Exclude (Get-NoTestRx) 2>$null | Out-String | ConvertFrom-Json)
    # another product's deploy branch proves nothing
    $ok = @($rows | Where-Object { $_.state -eq 'DEPLOYED' -and $_.target -notmatch (Get-NoTestRx -Lanes) })
    $paths = Get-MrPaths $mr
    $missing = @(); $matched = $false; $need = @()
    foreach ($pt in $productTargets) {
      if ($paths | Where-Object { $_ -match $pt.pathRegex }) { $matched = $true; if (-not ($ok | Where-Object { $_.target -match $pt.targetRegex })) { $missing += $pt.label; $need += $pt.targetRegex } }
    }
    if (-not $matched -and -not $ok.Count) { $missing += 'any test env' }
    if ($ok.Count -and -not $missing.Count) { $live += "$mr on $((($ok | ForEach-Object { $_.target }) -join '+'))"; continue }
    $r0 = $rows | Where-Object { $t0 = $_.target; $_.state -ne 'DEPLOYED' -and (-not $need.Count -or @($need | Where-Object { $t0 -match $_ }).Count) } | Select-Object -First 1
    $why = "$mr not live on: " + $(if ($missing.Count) { $missing -join ', ' } else { 'a test env' }) + $(if ($r0) { " ($($r0.state): $($r0.detail))" } else { '' }); break
  }
  if ($why) { $wait++; Out-Line "WAIT  $id  $why | $short"; continue }
  if (-not $Apply) { Out-Line "MARK  $id  would set in test ($($live -join '; ')) | $short"; continue }
  try {
    Set-TrackerStatus $id 'inTest'
    Add-TrackerComment $id ("In test: every MR is deployed on a test env (checked " + [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + " UTC): " + ($live -join '; ') + '.')
    $marked++; Out-Line "MARKED  $id  in test ($($live -join '; ')) | $short"
  } catch { Out-Line "ERROR $id  could not set status: $($_.Exception.Message)" }
}
if (-not $Quiet -or $gone.Count) { "mark-in-test: $($cand.Count) candidate(s), $marked marked, $wait waiting on a deploy$(if ($gone.Count) { ", $($gone.Count) deleted in the tracker (missing: $($gone -join ', '))" })" }
}

# ---- deploy: plan, request, record
function Invoke-Deploy {  param([Parameter(Position = 0)][ValidateSet('plan', 'request', 'record', 'merge', 'intest')][string]$Action = 'plan',
    [string]$Env, [string[]]$Mrs = @(), [string]$Run, [string]$Note, [string]$By = 'owner', [switch]$Json, [string]$Offline, [int]$Days = 14,
    [string]$Repo, [string]$To, [string]$From, [string]$Check, [switch]$Push, [int]$History = 300,
    [switch]$Apply, [switch]$Quiet, [string[]]$Task = @())
  if ($Action -eq 'merge') { $mergeFn = Assert-KitExtra Invoke-DeployMerge 'deploy merge' 'deploys'; & $mergeFn -Repo $Repo -To $To -From $From -Check $Check -Push:$Push -History $History; return }
  if ($Action -eq 'intest') { Invoke-MarkInTest -Apply:$Apply -Quiet:$Quiet -Task $Task; return }
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
    if (-not $Env) { 'usage: deploy record -Env <target> [-Mrs ..] [-By ..] [-Note ..]'; exit 2 }
    Write-KitLog deploy-log record ([ordered]@{ target = $Env; mrs = $Mrs; by = $By; note = $Note })
    $done = @($Mrs | ForEach-Object { Get-CanonMr (ConvertTo-MrRef $_) })
    if (Test-Path $pf) { & $pendEdit { param($p) foreach ($q in @($p.requests)) { $q.mrs = @(@($q.mrs) | Where-Object { -not $done.Count -or (Get-CanonMr (ConvertTo-MrRef $_)) -notin $done }) }; $p.requests = @(@($p.requests) | Where-Object { @($_.mrs).Count }) } }
    "recorded the deploy of $Env$(if ($Mrs.Count) { " ($($Mrs -join ', '))" }). Next: once pokey.ps1 deployed shows them live, bossy.ps1 deploy intest -Apply"
    return
  }
  $repos = @(Get-KitValue 'repos' @())
  $targets = @($repos | ForEach-Object { @($_.deploys) } | Where-Object { $_.target -and -not $_.laneApk -and $_.target -notmatch (Get-NoTestRx) } | ForEach-Object target | Select-Object -Unique)
  if ($Env) { $targets = @($targets | Where-Object { $_ -eq $Env }) }
  # an MR is checked only against the deploys of its own repo
  $tOf = @{}; foreach ($x in $repos) { $tOf[[string]$x.name] = @($x.deploys | ForEach-Object target) }
  $repoOf = { param($m) ((ConvertTo-MrRef $m) -split '!')[0] -split '/' | Select-Object -Last 1 }
  if ($Action -eq 'request') { $targets = @($targets | Where-Object { $t = $_; @($Mrs | Where-Object { $t -in $tOf[(& $repoOf $_)] }).Count }) }
  $taskOf = @{}; $cand = [ordered]@{}
  $tr = Read-KitTracking
  foreach ($t in $tr.tasks.Values) {
    if ($t.done -and (-not $t.doneAt -or ((Get-Date) - [datetime]$t.doneAt).TotalDays -gt $Days)) { continue }   # no doneAt: an old record
    foreach ($m in @($t.mrs)) {
      # live on every test env of its repo (supervise liveOn): nothing to deploy, no lookup
      $need = @($tOf[(& $repoOf $m)] | Where-Object { $_ -in $targets })
      if ($need.Count -and -not @($need | Where-Object { $_ -notin @($t.liveOn) }).Count) { continue }
      $taskOf[$m] = $t.task; $cand[$m] = 'tracked'
    }
  }
  $pend = if (Test-Path $pf) { @((Get-Content $pf -Raw | ConvertFrom-Json).requests) } else { @() }
  foreach ($q in $pend) { foreach ($m in @($q.mrs)) { $cand[$m] = "requested by $($q.run)" } }
  foreach ($m in $Mrs) { $cand[$m] = "requested by $Run" }
  # no network = UNKNOWN, no hang
  $rows = @{}; $failOf = @{}   # target -> why its check gave no rows (timeout, crash): that target is UNKNOWN, the others stand
  $rowsOf = { param($m) if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] } }
  if ($fx) { foreach ($m in $cand.Keys) { $rows[$m] = @($fx.mrs.$m.rows) } }
  elseif ($cand.Count) {
    $lim = [int](Get-KitSetting 'deploy.planTimeoutSec' 180)
    # one pokey.ps1 deployed per target, all at once, each with its own MRs and the same deadline: one slow env no longer blanks the rest
    $runs = @(foreach ($t in @(if ($Env) { $Env } else { $targets })) {
        $tm = @($cand.Keys | Where-Object { $t -in @($tOf[(& $repoOf $_)]) }); if (-not $tm.Count) { continue }
        $si = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        foreach ($x in @('-NoProfile', '-NonInteractive', '-File', $KitCmd.qa, 'deployed', '-Mrs', ($tm -join ','), '-Target', $t, '-Json', '-Exclude', (Get-NoTestRx))) { $si.ArgumentList.Add([string]$x) }
        $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
        $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $p = [Diagnostics.Process]::Start($si); [pscustomobject]@{ t = $t; p = $p; so = $p.StandardOutput.ReadToEndAsync(); se = $p.StandardError.ReadToEndAsync() }
      })
    if (-not $Json) { [Console]::Error.WriteLine("deploy plan: checking $($cand.Count) MR(s) on $($runs.Count) test env(s) in parallel (max $lim s each) ...") }
    $until = (Get-Date).AddSeconds($lim)
    foreach ($q in $runs) {
      if (-not $q.p.WaitForExit([int][math]::Max(1000, ($until - (Get-Date)).TotalMilliseconds))) { try { $q.p.Kill($true) } catch {}; $failOf[$q.t] = "pokey.ps1 deployed timed out after $lim s on $($q.t)"; continue }
      $null = [Threading.Tasks.Task]::WaitAll(@($q.so, $q.se), 5000); $txt = "$(if ($q.so.IsCompleted) { $q.so.Result })"; $j0 = $txt.IndexOf('[')
      $parsed = if ($j0 -ge 0) { try { @(ConvertFrom-Json $txt.Substring($j0) -NoEnumerate) } catch { $null } } else { $null }
      if ($q.p.ExitCode -notin 0, 1 -or $null -eq $parsed -or -not @($parsed | Where-Object { $_.mr }).Count) { $failOf[$q.t] = "pokey.ps1 deployed exit $($q.p.ExitCode) on $($q.t): $(("$txt$(if ($q.se.IsCompleted) { $q.se.Result })" -split "`n" | Where-Object { $_ } | Select-Object -First 1))"; continue }
      foreach ($x in @($parsed | ForEach-Object { $_ })) { if ($x.mr) { if (-not $rows.ContainsKey($x.mr)) { $rows[$x.mr] = @() }; $rows[$x.mr] += $x } }
    }
  }
  $trigger = ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower()
  $win = Get-KitSetting 'deploy.minIntervalHours' 4
  $winOf = { param($t) if ($win -is [psobject] -and $win.PSObject.Properties.Name -contains $t) { [double]$win.$t } elseif ($win -is [psobject] -and $win.PSObject.Properties.Name -contains 'default') { [double]$win.default } elseif ($win -is [psobject]) { 4 } else { [double]$win } }
  $logged = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $hostErr = $null
  $plan = foreach ($t in $targets) {
    $batch = @(foreach ($m in $cand.Keys) { foreach ($r in @($(if ($rows.ContainsKey($m)) { $rows[$m] } else { $rows[(Get-CanonMr $m)] }) | Where-Object { $_.target -eq $t -and $_.state -in 'NOT-DEPLOYED', 'MANUAL' })) { [pscustomobject]@{ mr = $m; task = $taskOf[$m]; state = $r.state; detail = $r.detail; why = $cand[$m] } } })
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
    $mine = @($cand.Keys | Where-Object { $t -in @($tOf[(& $repoOf $_)]) })
    $unk = @(foreach ($m in $mine) { @(& $rowsOf $m) | Where-Object { $_ -and $_.target -eq $t -and $_.state -eq 'UNKNOWN' } | ForEach-Object { "${m}: $($_.detail)" } })
    $why = if ($unk.Count) { $unk -join '; ' } elseif ($failOf[$t] -and $mine.Count -and -not @($mine | Where-Object { @(& $rowsOf $_) | Where-Object { $_ -and $_.target -eq $t } }).Count) { $failOf[$t] }
    $status = if ($why -and -not $batch.Count) { 'UNKNOWN' } elseif (-not $batch.Count) { 'NOTHING' } elseif ($running) { 'DEPLOYING' } elseif ($trigger -ne 'ask') { 'READY' } elseif ($next -and (Get-Date) -lt $next) { 'WAIT' } else { 'ASK' }
    [pscustomobject]@{ target = $t; status = $status; trigger = $trigger; last = $(if ($last) { $last.ToString('s') }); lastSource = $src; windowHours = $h; nextAllowed = $(if ($next) { $next.ToString('s') }); mrs = $batch; why = $why; pending = @($pend | ForEach-Object { "$($_.run) $($_.at)" }) }
  }
  if ($Json) { ConvertTo-Json @($plan) -Depth 6; return }
  foreach ($p in $plan) {
    $when = switch ($p.status) { 'WAIT' { " until $(([datetime]$p.nextAllowed).ToString('yyyy-MM-dd HH:mm')) (one deploy per $($p.windowHours) h)" } 'ASK' { ': ask the owner ONCE with this batch' } 'READY' { ": waits for a person's 'deploy $($p.target)' (deploy.trigger owner: nobody asks)" } 'UNKNOWN' { ": the deploy check failed: $($p.why) (plan again)" } 'DEPLOYING' { ': a deploy pipeline runs now (wait, then plan again)' } default { '' } }
    "DEPLOY $($p.target): $($p.status)$when | last $(if ($p.last) { "$(([datetime]$p.last).ToString('yyyy-MM-dd HH:mm')) ($($p.lastSource))" } else { 'unknown' })"
    foreach ($b in $p.mrs) { "  - $($b.mr)$(if ($b.task) { " task $($b.task)" }) $($b.state): $($b.detail) [$($b.why)]" }
  }
  if (-not @($plan).Count) { 'no test deploy targets in kit.local.json repos[].deploys' }
  if ($hostErr) { "last deploy unknown: $hostErr" }   # once, not per target
}

# ---- supervise: inTest moves, the cached plan
# supervise (called from Invoke-Supervise: $now, Within and Invoke-Bounded are its own): -AutoFix moves a done task that is live on a
# test env to inTest (never before); the deploy plan is cached 1 h: READY envs are report info, DEPLOY ASK only under trigger ask
function Get-KitSuperviseFlagsDeploys([switch]$AutoFix) {
  $flag = { param($level, $what, $action) [pscustomobject]@{ level = $level; what = $what; action = $action } }
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
      $rows = @(Invoke-Bounded $KitCmd.qa @('deployed', '-Mrs', (@($o.mrs) -join ','), '-Json') | Out-String | ConvertFrom-Json)
      $o.liveCheckedAt = $now.ToString('o')
      $live = @($rows.target | Where-Object { $_ } | Select-Object -Unique | Where-Object { $t = $_; -not @($rows | Where-Object { $_.target -eq $t -and $_.state -ne 'DEPLOYED' }).Count -and @($o.mrs).Count -eq @($rows | Where-Object { $_.target -eq $t }).Count })
      $new = @($live | Where-Object { $_ -notin @($o.liveOn) })
      $fields = @{ liveCheckedAt = $o.liveCheckedAt }; if ($new.Count) { $fields.liveOn = @(@($o.liveOn) + $new | Where-Object { $_ } | Select-Object -Unique) }
      Set-KitTaskFields $o.task $fields
      if ($new.Count -and (Test-TrackerStatus $(try { (Get-TrackerTask $o.task).status } catch { '' }) 'closed')) { Set-KitTaskFields $o.task @{ qaCovered = @('closed') }; continue }
      # deployed = in test (never before)
      if ($new.Count) { foreach ($l2 in @(Invoke-Bounded $KitCmd.orch @('deploy', 'intest', '-Task', $o.task, '-Apply', '-Quiet'))) { & $flag 'INFO' "auto-fixed: LIVE $($o.task) on $($new -join ', '): $l2" 'Tracker set to inTest; nothing to do.' } }
    }
  }
  if (Within 'deploy plan') {
    $pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'
    $cache = if (Test-Path $pc) { try { Get-Content $pc -Raw | ConvertFrom-Json } catch { $null } }
    if (-not $cache -or ($now - [datetime]$cache.at).TotalMinutes -ge 60) {
      $plan = @(Invoke-Bounded $KitCmd.orch @('deploy', 'plan', '-Json') | Out-String | ConvertFrom-Json | Where-Object { $_ })
      $cache = [pscustomobject]@{ at = $now.ToString('s'); ready = @($plan | Where-Object status -in 'READY', 'ASK' | ForEach-Object { "$($_.target) ($(@($_.mrs).Count) MR(s))" }); ask = @($plan | Where-Object status -eq 'ASK' | ForEach-Object { "$($_.target): $(@($_.mrs).Count) MR(s) ($((@($_.mrs) | ForEach-Object mr) -join ', '))" }) }
      $cache | ConvertTo-Json -Depth 4 | Set-Content $pc -Encoding utf8
    }
    foreach ($a in @($cache.ask | Where-Object { ([string](Get-KitSetting 'deploy.trigger' 'owner')).ToLower() -eq 'ask' })) { & $flag 'ACT' "DEPLOY ASK $a merged, not deployed, window open" "& $($KitCmd.orch) deploy plan: show the batch, ask the owner ONCE for this env; after the deploy: deploy record -Env <target> -Mrs <refs>, then deploy intest -Apply." }
  }
  # what waits for a person's deploy <env> (the cached plan): INFO lines of the supervise report
  $ready = try { (Get-Content (Join-Path (Get-KitPath deploys) 'plan-cache.json') -Raw | ConvertFrom-Json).ready } catch { @() }
  foreach ($r in @($ready | Where-Object { $_ })) { [pscustomobject]@{ info = "deploy ready: $r (waits for a person's deploy <env>)" } }
}
