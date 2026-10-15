#Requires -Version 7
<#
Local environments: ONE shared running instance per configured env (API, web dev server, workers, Metro, search, ...) on this
machine, that agents deploy their branches to and test against. Optional: used when the owner or a brief asks for a local
check. Stack-agnostic: a service is a start command in a folder (default from dev-kit stack.ps1 `run`).

  $L = '<workspace>/.claude/skills/local-env/scripts/localenv.ps1'
  & $L envs                                             # configured envs and services
  & $L status  [-Env <env>] [-Agent <id>] [-Json]       # release, services (state, why needed, idle), train, queue, leases
  & $L deploy  -Env <env> -Agent <id> (-Dir <worktree> | -Branch <b> [-Repo r,..]) [-Wait 8]   # request; your branch joins the next train
  & $L wait    -Env <env> -Id <request> [-Wait 8]       # until a request is done (call again when it says "still")
  & $L use     -Env <env> -Agent <id> [-Services api,web] [-Minutes 30] [-Session <board token>] [-Note "<checks>"]
  & $L release -Env <env> -Agent <id>
  & $L promote -Env <env> -Agent <id> -Branch <b> [-Note "<passed>"]
  & $L task    -Env <env> -Task <name> -Agent <id>      # a configured one-shot command on the env's code (APK, DB reset, ...)
  & $L migrations -Env <env> [-Branch <b> | -Dir <worktree>]   # LIGHT/HEAVY per changeSet + revert plan (dry run, no deploy)
  & $L logs    -Env <env> -Service <s> [-Tail 80];  & $L events -Env <env> [-Tail 30]
  owner / coordinator:
  & $L up      -Env <env> [-Services ..] [-Minutes 120] # hold services up (a person working in the browser)
  & $L down    -Env <env> [-Services ..]                # stop now: drops holds and leases on them, ignores browser traffic 30 min
  & $L drop    -Env <env> -Branch <b>;  & $L refresh -Env <env>   # remove a layer / rebuild everything on the latest targets

Model, lifecycle, leases, trains, sandboxes: ../SKILL.md. Calls return within -Wait min (8); requests keep going in the controller.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('envs', 'status', 'deploy', 'wait', 'use', 'release', 'promote', 'task', 'logs', 'events', 'migrations', 'up', 'down', 'drop', 'refresh', '_exec')][string]$Action,
  [Alias('Env')][string]$EnvName,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }),
  [string]$Branch, [string[]]$Repo, [string]$Dir, [string[]]$Services, [string]$Service, [string]$Task, [string]$Note, [string]$Id,
  [string]$Session, [string]$Artifact,
  [int]$Minutes = 0, [double]$Wait = 8, [int]$Tail = 80, [switch]$Json
)
. (Join-Path $PSScriptRoot 'localenv-lib.ps1')
$Repo = @(Split-KitList $Repo); $Services = @(Split-KitList $Services)
if ($Service -and -not $Services) { $Services = @($Service) }
if (-not (EnvNames).Count -and $Action -ne 'envs') { throw 'No local environments configured: add "localEnv": { "envs": { "<env>": { "services": [...] } } } to kit.local.json (see skills/dev-kit/reference/configuration.md).' }
$clash = @(Test-PortClash)
if ($clash.Count) { $m = "localEnv port clash (envs run side by side; give each service its own port): $($clash -join '; ')"; if ($Action -in 'envs', 'status', 'logs', 'events', 'release', '_exec') { Write-Warning $m } else { throw $m } }
if (-not $EnvName -and $Action -notin 'envs', 'status') { if (@(EnvNames).Count -eq 1) { $EnvName = @(EnvNames)[0] } else { throw "-Env needed: $((EnvNames) -join ', ')" } }
$e = $EnvName

function Ensure-Loop {
  $st = Read-State $e
  if ($st.loop -and (Alive $st.loop.pid)) { return }
  $pwsh = (Get-Process -Id $PID).Path
  $null = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile -NonInteractive -File `"$(Join-Path $PSScriptRoot 'localenvd.ps1')`" -Env $e" -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 300; if ((Read-State $e).loop) { break } }
}
function New-Request([hashtable]$r) {
  $r.id = [guid]::NewGuid().ToString('n').Substring(0, 8); $r.at = Now; $r.status = 'queued'; $r.agent = $Agent
  Update-State $e { param($x) $x.requests = @($x.requests) + @($r) }
  Event $e 'request' @{ id = $r.id; kind = $r.kind; agent = $Agent; branch = $r.branch }
  Ensure-Loop
  $r.id
}
# Wait for a request; prints the train's phase as it changes. Returns the request (done or not).
function Wait-Request([string]$rid) {
  $until = (Get-Date).AddMinutes($Wait); $said = $null
  while ($true) {
    $st = Read-State $e
    $r = $st.requests | Where-Object id -eq $rid | Select-Object -First 1
    if (-not $r) { throw "[$e] no request $rid" }
    if ($r.status -eq 'done') {
      $res = $r.result
      Write-Host "[$e] $($r.kind) $($r.branch) -> $("$($res.outcome)".ToUpper())$(if ($res.release) { " in release $($res.release)" })$(if ($res.message) { ": $($res.message)" })"
      return $r
    }
    $msg = if ($r.status -eq 'queued') { "queued$(if ($st.train) { " (train $($st.train.id) running: $($st.train.phase))" })" } else { "in train $($st.train.id): $($st.train.phase)$(if (@($st.train.waitingFor).Count) { " - waiting for $(@($st.train.waitingFor) -join ', ')" })" }
    if ($msg -ne $said) { Write-Host "[$e] $($r.kind) $($r.branch): $msg"; $said = $msg }
    if ((Get-Date) -gt $until) { Write-Host "[$e] still $($r.status) after $Wait min - it keeps going; continue with: localenv.ps1 wait -Env $e -Id $rid"; return $r }
    Ensure-Loop
    Start-Sleep 3
  }
}
function All-Managed { @(EnvServices $e | Where-Object { Managed $_ } | ForEach-Object name) }
# Wait until the given services are healthy (or the wait runs out)
function Wait-Up([string[]]$names) {
  $until = (Get-Date).AddMinutes($Wait); $said = $null
  while ($true) {
    $st = Read-State $e
    $down = @($names | Where-Object { $s = Svc $e $_; (Managed $s) -and -not (Healthy $e $s) })
    if (-not $down.Count) { return $true }
    $msg = "waiting for $(($down | ForEach-Object { "$_ ($($st.services[$_].status))" }) -join ', ')$(if ($st.train) { "; train: $($st.train.phase)" })"
    if ($msg -ne $said) { Write-Host "[$e] $msg"; $said = $msg }
    $failed = @($down | Where-Object { $st.services[$_].status -eq 'failed' -and @($st.services[$_].restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 }).Count -ge 3 })
    if ($failed.Count) { Write-Host "[$e] $($failed -join ', ') failed 3 times: see localenv.ps1 logs -Env $e -Service $($failed[0])"; return $false }
    if ((Get-Date) -gt $until) { Write-Host "[$e] not up yet after $Wait min (it keeps starting): call the same command again to keep waiting"; return $false }
    Ensure-Loop
    Start-Sleep 3
  }
}

function Show-Status([string]$env1) {
  $script:e = $env1; $st = Read-State $env1; Prune $st
  $all = Get-SysProcs -NoCommandLine
  $svc = foreach ($s in EnvServices $env1) {
    $x = $st.services[$s.name]; $h = Healthy $env1 $s
    $ids = if ($h) { SvcPids $env1 $s $st $all } else { @() }
    $listens = if ($h -and $KitIsWindows -and $ids) { @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $ids } | ForEach-Object LocalPort | Sort-Object -Unique) } else { @() }
    $idleMin = if ($h -and $x.lastNeed) { [int]((Get-Date) - [datetime]$x.lastNeed).TotalMinutes } else { $null }
    [pscustomobject]@{
      service = $s.name; state = $(if ($h) { if (-not (Managed $s)) { 'up (external)' } elseif (Owned $x) { 'up' } else { 'up (adopted)' } } elseif ($x.status -in 'starting', 'failed') { $x.status } else { 'down' })
      port = $s.port; gb = $(if ($ids) { TreeGB $ids $all } else { 0 }); release = $x.release; need = @($x.need | Where-Object { $_ }); idleMin = $idleMin; graceMin = $(if (Managed $s) { GraceMin $env1 $s }); listens = $listens
      why = $x.why; hot = [bool]$s.hot
    }
  }
  $o = [pscustomobject]@{
    env = $env1; release = $st.release.n; releasedAt = $st.release.at
    repos = @($st.release.repos.Keys | ForEach-Object { $rr = $st.release.repos[$_]; [pscustomobject]@{ repo = $_; target = $rr.target; targetSha = "$($rr.targetSha)".Substring(0, [math]::Min(9, "$($rr.targetSha)".Length)); layers = @($rr.layers | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ branch = $_.branch; agent = $_.agent; sha = "$($_.sha)".Substring(0, [math]::Min(9, "$($_.sha)".Length)); migrations = [bool]$_.migrations; mclass = $(if ($_.migrations) { if ($_.mclass) { "$($_.mclass.effective)".ToUpper() } else { 'HEAVY' } }); mcount = $_.mclass.count; mwhy = @($_.mclass.why); promoted = $(if ($_.promoted) { "release $($_.promoted.release)" }) } }) } })
    train = $(if ($st.train) { [pscustomobject]@{ id = $st.train.id; phase = $st.train.phase; waitingFor = @($st.train.waitingFor); requests = @($st.train.requests).Count } })
    queue = @($st.requests | Where-Object status -eq 'queued' | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch)" })
    services = @($svc)
    leases = @($st.leases.Keys | ForEach-Object { $l = $st.leases[$_]; [pscustomobject]@{ agent = $_; services = @($l.services); until = ([datetime]$l.until).ToString('HH:mm'); release = $l.release; note = $l.note } })
    holds = @($st.holds.Keys | ForEach-Object { [pscustomobject]@{ who = $_; services = @($st.holds[$_].services); until = ([datetime]$st.holds[$_].until).ToString('HH:mm') } })
    recent = @($st.requests | Where-Object status -eq 'done' | Select-Object -Last 5 | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch) -> $($_.result.outcome)$(if ($_.result.release) { " (release $($_.result.release))" })" })
    sandboxes = @($st.sandboxes.Keys | Sort-Object | ForEach-Object { $x = $st.sandboxes[$_]; "$_ $($x.branch) ($($x.agent)) $(@($x.services | ForEach-Object { $s = Svc $env1 $_; "$_ :$($s.port) $(if (Healthy $env1 $s) { 'up' } else { 'down' })" }) -join ', ')$(if ($x.promoted) { ' PROMOTED' })" })
    loop = $(if ($st.loop -and (Alive $st.loop.pid)) { "running (pid $($st.loop.pid))" } else { 'stopped (starts on the next request)' })
  }
  if ($Agent -and $Agent -ne 'main' -and $st.leases[$Agent]) {
    $l = $st.leases[$Agent]; $since = [int]$l.release
    $chg = @($st.releases | Where-Object { [int]$_.n -gt $since } | ForEach-Object { $rel = $_; @($_.changed) | ForEach-Object { "$_ in release $($rel.n)" } })
    $mine = @(Closure $env1 @($l.services) | ForEach-Object { RepoOf $env1 (Svc $env1 $_) } | Where-Object { $_ } | Select-Object -Unique)
    $hits = @($chg | Where-Object { ($_ -split ' ')[0] -in $mine })
    $o | Add-Member -NotePropertyName mine -NotePropertyValue $(if ($hits.Count) { "CHANGED since your lease started (release $since): $($hits -join '; ') - re-run the checks that touch them" } else { "unchanged since your lease started (release $since)" })
  }
  if ($Json) { return $o }
  "== $env1  release $($o.release)$(if ($o.releasedAt) { " ($(([datetime]$o.releasedAt).ToString('HH:mm')))" })   controller: $($o.loop)"
  if ($o.train) { "  TRAIN $($o.train.id): $($o.train.phase)$(if ($o.train.waitingFor.Count) { " - waiting for $($o.train.waitingFor -join ', ')" }) ($($o.train.requests) request(s))" }
  if ($o.queue) { "  queued: $($o.queue -join '; ')" }
  foreach ($x in $o.services) {
    $extra = @()
    if ($x.need.Count -and $x.state -like 'up*') { $extra += "needed: $($x.need -join ', ')" } elseif ($x.state -like 'up*' -and $null -ne $x.idleMin -and $x.graceMin) { $extra += "idle $($x.idleMin)/$($x.graceMin) min" }
    if ($x.release) { $extra += "r$($x.release)" }
    if (@($x.listens | Where-Object { $_ -ne $x.port }).Count) { $extra += "listens $($x.listens -join '/')" }
    if ($x.state -in 'down', 'failed' -and $x.why) { $extra += $x.why }
    '  {0,-14} {1,-16} {2,6} {3,6} GB  {4}' -f $x.service, $x.state, $(if ($x.port) { ":$($x.port)" }), $x.gb, ($extra -join ' | ')
  }
  foreach ($r in $o.repos) { "  $($r.repo) @ $($r.target) $($r.targetSha)$(if (-not $r.layers.Count) { ' (no layers)' })"; foreach ($l in $r.layers) { '    + {0,-42} {1,-10} {2}{3}{4}' -f $l.branch, $l.agent, $l.sha, $(if ($l.promoted) { "  PROMOTED ($($l.promoted))" }), $(if ($l.migrations) { "  MIGRATIONS $($l.mclass)$(if ($l.mclass -eq 'LIGHT') { " ($($l.mcount) changeSets, exact revert on leave)" } elseif (@($l.mwhy).Count) { ": $(@($l.mwhy)[0])" } else { ' (snapshot)' })" }) } }
  if ($o.sandboxes) { "  sandboxes: $($o.sandboxes -join '; ')" }
  if ($o.leases) { "  leases: $(($o.leases | ForEach-Object { "$($_.agent) [$($_.services -join ',')] until $($_.until) (r$($_.release))$(if ($_.note) { " $($_.note)" })" }) -join '; ')" }
  if ($o.holds) { "  holds: $(($o.holds | ForEach-Object { "$($_.who) [$($_.services -join ',')] until $($_.until)" }) -join '; ')" }
  if ($o.recent) { "  recent: $($o.recent -join '; ')" }
  if ($o.mine) { "  YOU ($Agent): $($o.mine)" }
}

switch ($Action) {
  'envs' {
    foreach ($n in EnvNames) {
      "$n$(if ((Get-EnvCfg $n).description) { " - $((Get-EnvCfg $n).description)" })"
      foreach ($s in EnvServices $n) { '  {0,-14} {1,-28}{2}{3}{4}' -f $s.name, $(if ($s.repo) { "$($s.repo)/$($s.dir)" } else { 'external' }), $(if ($s.port) { "  :$($s.port)" }), $(if ($s.dependsOn) { "  needs $(@($s.dependsOn) -join ',')" }), $(if ($s.hot) { '  hot' } elseif ($s.artifact) { '  runs from artifact' }) }
      if ((Get-EnvCfg $n).tasks) { "  tasks: $((Get-EnvCfg $n).tasks.PSObject.Properties.Name -join ', ')" }
    }
  }
  'status' { $names = if ($EnvName) { @($EnvName) } else { EnvNames }; $out = foreach ($n in $names) { Show-Status $n }; if ($Json) { $out | ConvertTo-Json -Depth 8 } else { $out } }
  'deploy' {
    $envRepos = EnvRepos $e
    if ($Dir) {
      $Dir = (Resolve-Path $Dir).Path
      $Branch = "$(git -C $Dir rev-parse --abbrev-ref HEAD)".Trim()
      # same repository = same common git dir (a submodule's is <super>/.git/modules/<name>, not <checkout>/.git)
      $common = (Resolve-Path "$(git -C $Dir rev-parse --path-format=absolute --git-common-dir)".Trim()).Path
      $hit = $envRepos.Values | Where-Object { (Resolve-Path "$(git -C $_.cfg.checkout rev-parse --path-format=absolute --git-common-dir)".Trim() -ErrorAction SilentlyContinue).Path -eq $common } | Select-Object -First 1
      if (-not $hit) { throw "[$e] $Dir is not a worktree of a repo this env runs ($($envRepos.Keys -join ', '))" }
      $Repo = @($hit.name)
      if (@(git -C $Dir status --porcelain --untracked-files=no).Count) { Write-Warning "$Dir has uncommitted changes: only committed work is deployed (wt.ps1 commit first)" }
    }
    if (-not $Branch) { throw 'deploy needs -Dir <your worktree> or -Branch <branch>' }
    if ($Branch -match '^localenv/') { throw 'that is the env branch itself' }
    $targets = if ($Repo) { @($Repo | ForEach-Object { (Get-RepoCfg $_).name }) } else { @($envRepos.Values | Where-Object { Resolve-Ref $_.cfg.checkout $Branch } | ForEach-Object name) }
    $targets = @($targets | Where-Object { $envRepos.Contains($_) })
    if (-not $targets) { throw "[$e] branch $Branch not found in any repo of this env ($($envRepos.Keys -join ', '))" }
    $shas = @{}; $mig = @{}; $mcls = @{}
    foreach ($rn in $targets) {   # the commit deployed is the one at request time: later commits need a new deploy
      $sha = Resolve-Ref $envRepos[$rn].cfg.checkout $Branch; if (-not $sha) { throw "[$e] $Branch not found in $rn" }
      $shas[$rn] = $sha; $mig[$rn] = HasMigrations $envRepos[$rn].cfg.checkout $envRepos[$rn].target $sha
      if ($mig[$rn]) { $mcls[$rn] = Get-MigClass $e $envRepos[$rn] $sha; if (-not $mcls[$rn]) { $mig[$rn] = $false; $mcls.Remove($rn) } }
    }
    $rid = New-Request @{ kind = 'deploy'; branch = $Branch; shas = $shas; migrations = $mig; mclass = $mcls }
    "[$e] deploy $Branch ($(($shas.Keys | ForEach-Object { "$_ @ $($shas[$_].Substring(0, 9))" }) -join ', ')) queued as request $rid"
    foreach ($rn in $mcls.Keys) {
      $mc = $mcls[$rn]
      "[$e]   $rn $(MigText $mc) - they change the shared local DB"
      if ($mc.effective -eq 'light') { "[$e]   changeSets: $(@($mc.ids | Select-Object -First 6) -join ', ')$(if ($mc.count -gt 6) { ', ...' }); plan: localenv.ps1 migrations -Env $e -Branch $Branch" }
      else { foreach ($w in @($mc.why | Select-Object -First 5)) { "[$e]   HEAVY because $w" }; "[$e]   -> $(if (SandboxCfg $e) { 'own sandbox (own DB copy)' } elseif ((Get-EnvCfg $e).db.snapshot) { 'main env, DB snapshot first' } else { 'main env, no restore point (no db.snapshot hook)' })" }
    }
    $null = Wait-Request $rid
  }
  'drop' { if (-not $Branch) { throw 'drop needs -Branch' }; $rid = New-Request @{ kind = 'drop'; branch = $Branch }; "[$e] drop $Branch queued as $rid"; $null = Wait-Request $rid }
  'refresh' { $rid = New-Request @{ kind = 'refresh'; branch = '' }; "[$e] refresh queued as $rid"; $null = Wait-Request $rid }
  'wait' { if (-not $Id) { throw 'wait needs -Id <request>' }; $null = Wait-Request $Id }
  'use' {
    $names = @(Closure $e $(if ($Services) { $Services } else { All-Managed }))
    foreach ($n in $names) { $null = Svc $e $n }
    $min = [math]::Min($(if ($Minutes) { $Minutes } else { $LeaseMin }), $MaxLeaseMin)
    $until = (Get-Date).AddMinutes($Wait); $said = $null; $o = @{}
    while ($true) {
      $o.ok = $false
      Update-State $e { param($x)
        Prune $x
        $blocked = @($x.train.blockServices | Where-Object { $_ -in $names })
        $old = $x.leases[$Agent]
        if ($old -and $blocked.Count) {   # a train waits on this lease: the lease stays, but is not extended (no starvation)
          $o.ok = $true; $o.rel = $old.release; $o.until = [datetime]$old.until; $o.capped = $true
        } elseif (-not $blocked.Count) {
          $x.leases[$Agent] = @{ services = $names; repos = @(); until = (Get-Date).AddMinutes($min).ToString('o'); release = [int]$x.release.n; session = $Session; note = $Note; at = (Now) }
          $o.ok = $true; $o.rel = $x.release.n; $o.until = (Get-Date).AddMinutes($min)
        } else { $o.why = "train $($x.train.id) is switching $($blocked -join ', ') ($($x.train.phase))" }
      }
      if ($o.ok) { break }
      if ($o.why -ne $said) { "[$e] lease waits: $($o.why)"; $said = $o.why }
      Ensure-Loop
      if ((Get-Date) -gt $until) { "[$e] no lease yet after $Wait min: call use again to keep waiting"; return }
      Start-Sleep 3
    }
    Event $e 'lease' @{ agent = $Agent; services = $names; minutes = $min }
    "[$e] lease for $Agent on $($names -join ', ') until $($o.until.ToString('HH:mm')) (release $($o.rel)).$(if ($o.capped) { ' Not extended: a train waits for it - release when done.' } else { ' Renew: use again; end: release.' })"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e }
  }
  'release' { Update-State $e { param($x) $x.leases.Remove($Agent) }; Event $e 'release-lease' @{ agent = $Agent }; "[$e] lease of $Agent released" }
  'up' {
    $names = @(Closure $e $(if ($Services) { $Services } else { All-Managed })); $min = if ($Minutes) { $Minutes } else { 120 }
    Update-State $e { param($x) $x.holds[$Agent] = @{ services = $names; until = (Get-Date).AddMinutes($min).ToString('o') }; $x.suppress = $null }
    "[$e] holding $($names -join ', ') up for $min min (for $Agent)"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e }
  }
  'down' {
    $names = if ($Services) { @(@($Services) + @(Dependents $e $Services) | Select-Object -Unique) } else { All-Managed }
    $o = @{ lost = @() }
    Update-State $e { param($x)
      foreach ($a in @($x.holds.Keys)) { $x.holds[$a].services = @($x.holds[$a].services | Where-Object { $_ -notin $names }); if (-not $x.holds[$a].services.Count) { $x.holds.Remove($a) } }
      foreach ($a in @($x.leases.Keys)) { if (@($x.leases[$a].services | Where-Object { $_ -in $names }).Count) { $o.lost += $a; $x.leases.Remove($a) } }
      $x.suppress = @{ services = $names; until = (Get-Date).AddMinutes(30).ToString('o') }
    }
    if ($o.lost.Count) { "[$e] ended the leases of $($o.lost -join ', ')" }
    $order = @(EnvServices $e | Where-Object { $_.name -in $names }); [array]::Reverse($order)   # dependents (listed later) first
    foreach ($s in $order) { if ((Managed $s) -and (Healthy $e $s)) { Stop-Svc $e $s 'stopped by down'; "[$e] $($s.name) stopped" } }
  }
  'promote' {
    if (-not $Branch) { throw 'promote needs -Branch' }
    $sbs = (Read-State $e).sandboxes; $key = @($sbs.Keys | Where-Object { $sbs[$_].branch -eq $Branch }) | Select-Object -First 1
    if ($key) {
      # promoted in its sandbox: deploy the same commit into the main env (migrations: snapshot first); the sandbox goes once live
      $sbx = $sbs[$key]
      Update-State $e { param($x) $x.sandboxes[$key].promoted = @{ by = $Agent; at = (Now); note = $Note } }
      $rid = New-Request @{ kind = 'deploy'; branch = $Branch; shas = @{ $sbx.repo = $sbx.sha }; migrations = @{ $sbx.repo = $true }; noSandbox = $true }
      "[$e] $Branch promoted in sandbox $key; deploying it into the main env as request $rid (migrations: the shared DB changes)"
      $null = Wait-Request $rid
      return
    }
    $o = @{ hit = @() }
    Update-State $e { param($x) foreach ($rn in @($x.release.repos.Keys)) { foreach ($l in @($x.release.repos[$rn].layers | Where-Object { $_ })) { if ($l.branch -eq $Branch) { $l.promoted = @{ by = $Agent; at = (Now); release = $x.release.n; sha = $l.sha; note = $Note }; $o.hit += $rn } } } }
    if (-not $o.hit) { throw "[$e] $Branch is not live here: deploy it first, test, then promote" }
    Event $e 'promote' @{ agent = $Agent; branch = $Branch; release = (Read-State $e).release.n }
    "[$e] $Branch promoted locally in $($o.hit -join ', ') (release $((Read-State $e).release.n))"
  }
  'task' {
    $t = (Get-EnvCfg $e).tasks.$Task
    if (-not $t) { throw "env $e has no task '$Task' ($(((Get-EnvCfg $e).tasks.PSObject.Properties.Name) -join ', '))" }
    $rn = (Get-RepoCfg $t.repo).name; $key = "$Agent/task"
    # a code lease on the repo: no train changes its worktree while the task reads it
    $until = (Get-Date).AddMinutes($Wait); $o = @{}
    while ($true) {
      Update-State $e { param($x) Prune $x; if ($rn -notin @($x.train.blockRepos)) { $x.leases[$key] = @{ services = @(); repos = @($rn); until = (Get-Date).AddMinutes($MaxLeaseMin).ToString('o'); release = [int]$x.release.n; note = "task $Task"; at = (Now); pid = $PID }; $o.ok = $true } }
      if ($o.ok) { break }
      if ((Get-Date) -gt $until) { "[$e] a train is changing $rn : run the task again later"; return }
      Start-Sleep 3
    }
    try {
      $r = (EnvRepos $e)[$rn]; if (-not (Test-Path (Join-Path $r.wt '.git'))) { throw "[$e] $rn has no env worktree yet: run localenv.ps1 refresh -Env $e first" }
      Sync-DepLinks $e $r
      $dir = SvcDir $e $t; $cmd = Expand-Placeholders ([string]$t.cmd) $e $t $dir ''
      "[$e] task $Task in $dir : $cmd"
      With-Env (EnvVars $e $t) {
        if ($t.gated) { & (Join-Path $script:DK 'gate.ps1') -Dir $dir -Cmd $cmd }
        else { Push-Location $dir; try { if ($KitIsWindows) { $bat = Join-Path (Get-KitPath localenv -Create) "run/$e-task-$Task.cmd"; New-Item -ItemType Directory -Force (Split-Path $bat) | Out-Null; Set-Content -LiteralPath $bat "@echo off`r`n$cmd" -Encoding ascii; & cmd.exe /d /c "`"$bat`"" } else { & /bin/sh -c $cmd } } finally { Pop-Location } }
      }
      $code = $LASTEXITCODE
    } finally { Update-State $e { param($x) $x.leases.Remove($key) } }
    if ($code) { throw "[$e] task $Task failed (exit $code)" }
  }
  'migrations' {
    # dry run: the class of each changeSet and the exact revert (db.rollback command) that would run if the layer left now
    $envRepos = EnvRepos $e; $st = Read-State $e
    "[$e] migrations mode: $(MigMode $e)$(if ((MigMode $e) -ne 'classify') { ' (no db.rollback hook: every migration is HEAVY)' })"
    if ($Dir -and -not $Branch) { $Branch = "$(git -C (Resolve-Path $Dir).Path rev-parse --abbrev-ref HEAD)".Trim() }
    $items = if ($Branch) {
      foreach ($r in $envRepos.Values) { $sha = Resolve-Ref $r.cfg.checkout $Branch; if ($sha -and (HasMigrations $r.cfg.checkout $r.target $sha)) { $mc = Get-MigClass $e $r $sha; if ($mc) { @{ rn = $r.name; layer = @{ branch = $Branch; sha = $sha; migrations = $true; mclass = $mc }; staying = @() } } } }
    } else {
      foreach ($rn in $st.release.repos.Keys) { $ls = @(Layers $st $rn); foreach ($l in $ls | Where-Object { $_.migrations }) { @{ rn = $rn; layer = $l; staying = @($ls | Where-Object { $_.branch -ne $l.branch }) } } }
    }
    if (-not @($items).Count) { "[$e] no migration layers$(if ($Branch) { " in $Branch" })"; return }
    foreach ($it in $items) {
      $l = $it.layer; $mc = $l.mclass
      "== $($it.rn) $($l.branch) @ $("$($l.sha)".Substring(0, 9)): $(if ($mc) { MigText $mc } else { 'MIGRATIONS HEAVY (deployed before classification)' })"
      if ($mc.manifest -and (Test-Path $mc.manifest)) {
        foreach ($c in @((Get-Content $mc.manifest -Raw | ConvertFrom-Json).changesets)) { '   {0,-5} {1}::{2}{3}{4}' -f "$($c.class)".ToUpper(), $c.file, $c.id, $(if ($c.why) { "  [$($c.rule)] $($c.why)" }), $(if ($c.guarded) { '  (precondition may MARK_RAN)' }) }
      }
      if (LayerLight $l) {
        $p = Get-MigRevertPlan $e $it.rn @($l) $it.staying '' "dryrun-$(Get-Date -Format 'yyyyMMddHHmmss')"
        "   on leave: $(MigPlanText $p)"
      } else { "   on leave: no revert (HEAVY): $(if (SandboxCfg $e) { 'its sandbox goes; ' })the main env DB keeps it unless a snapshot from before it is restored" }
    }
  }
  'logs' { if (-not $Services) { throw 'logs needs -Service' }; $f = LogFile $e $Services[0]; if (Test-Path $f) { Get-Content $f -Tail $Tail } else { "no log yet: $f" } }
  'events' { $f = Join-Path (Get-KitPath localenv-logs) "$e-events.jsonl"; if (Test-Path $f) { Get-Content $f -Tail $Tail } else { 'no events yet' } }
  '_exec' {
    # internal: the detached wrapper of one service (env vars from the env file, output to its log)
    $s = Svc $e $Services[0]; $dir = SvcDir $e $s; $log = LogFile $e $s.name
    $cmd = StartCmd $e $s $Artifact
    foreach ($kv in (EnvVars $e $s).GetEnumerator()) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value) }
    Set-Location $dir
    Add-Content $log "== $(Now) start in $dir : $cmd"
    # Windows: through a .cmd file (cmd /s /c mangles a command that starts with a quote; a % in a start command must be %%)
    if ($KitIsWindows) { $bat = Join-Path (Get-KitPath localenv -Create) "run/$e-$($s.name).cmd"; New-Item -ItemType Directory -Force (Split-Path $bat) | Out-Null; Set-Content -LiteralPath $bat "@echo off`r`n$cmd >> `"$log`" 2>&1" -Encoding ascii; & cmd.exe /d /c "`"$bat`"" }
    else { & /bin/sh -c "$cmd >> '$log' 2>&1" }
    Add-Content $log "== $(Now) exited $LASTEXITCODE"
  }
}
