#Requires -Version 7
<#
Library dot-sourced by localenv.ps1 (CLI) and localenvd.ps1 (the per-env controller loop); never run by hand.
Config, state, layers/builds, processes, admission, leases and demand. See localenv.ps1 for the model.

State per env: Get-KitPath localenv /<env>.json, locked read-modify-write (Update-State). Fields:
  release   { n, at, train, repos: { <repo>: { target, targetSha, layers: [ { branch, agent, sha, migrations, promoted? } ] } } }
  releases  [ last releases (summaries) ]
  services  { <svc>: { status: up|starting|down|failed|blocked, pid, port, release, artifact, startedAt, upAt, lastNeed, gb, restarts[], why } }
  leases    { <agent>: { services[], repos[], until, release, session, note, at } }
  holds     { <who>: { services[], until } }
  requests  [ { id, kind: deploy|drop|refresh|stop, agent, branch, repos[], at, status: queued|in-train|done, result{ outcome, release, message } } ]
  train     { id, pid, phase, requests[], blockServices[], blockRepos[], at }      (set while a train worker runs)
  loop      { pid, beat }
#>
$ErrorActionPreference = 'Stop'
$script:DK = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts'
. (Join-Path $script:DK 'sysinfo.ps1')
. (Join-Path $script:DK 'kitconfig.ps1')

# ---------------------------------------------------------------- config
$script:LE = Get-KitValue 'localEnv' $null
function Opt([string]$k, $def) { $v = Get-KitSetting "localEnv.$k" $null; if ($null -eq $v) { $def } else { $v } }
$script:LeaseMin = [int](Opt 'leaseMinutes' 30)
$script:MaxLeaseMin = [int](Opt 'maxLeaseMinutes' 120)
$script:CpuMax = [int](Opt 'cpuMaxPct' 90)
$script:RoomWaitMin = [int](Opt 'roomWaitMinutes' 30)
$script:IdleOn = "$(Opt 'idle.enabled' $true)" -ne 'False'
$script:IdleMinM = [double](Opt 'idle.minMinutes' 15)
$script:IdleMaxM = [double](Opt 'idle.maxMinutes' 60)
$script:LoopExitM = [double](Opt 'loopExitMinutes' 10)
$script:MigPattern = [string](Opt 'migrationPattern' '(?i)(^|/)(db/)?(changelog|migrations?|liquibase|flyway|alembic)(/|\.)')
# log lines that mean a start failed for good, whatever keeps the process alive (Spring devtools, a watcher): fail fast
$script:FailPattern = [string](Opt 'failPattern' 'APPLICATION FAILED TO START|Application run failed|EADDRINUSE|Address already in use|Port \d+ is already in use|Failed to bind to|Unhandled exception. System\.|Traceback \(most recent call last\)|panic: |Error: Cannot find module')
function Now { (Get-Date).ToString('o') }
function EnvNames { if ($script:LE -and $script:LE.envs) { @($script:LE.envs.PSObject.Properties.Name) } else { @() } }
function Get-EnvCfg([string]$e) { $c = $script:LE.envs.$e; if (-not $c) { throw "unknown env '$e' (configured: $((EnvNames) -join ', '))" }; $c }
function Get-RepoCfg([string]$name) {
  $r = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1
  if (-not $r) { throw "repo '$name' is not in kit.local.json repos[] (name or alias)" }
  $r
}
function EnvServices([string]$e) { @((Get-EnvCfg $e).services | Where-Object { $_ }) }
function Svc([string]$e, [string]$n) { $s = EnvServices $e | Where-Object name -eq $n; if (-not $s) { throw "env $e has no service '$n' ($((EnvServices $e).name -join ', '))" }; $s }
# A service is managed (started/stopped by the env) unless it is external infra without a start command (e.g. a shared DB server)
function Managed($s) { -not ($s.external -and -not $s.start) }
# Envs run side by side, so a port belongs to exactly one service across ALL envs. The only sharing allowed: external infra
# (external: true) that every env declares with the same start command (or none), e.g. one database server for every env.
function Test-PortClash {
  $by = @{}
  foreach ($n in EnvNames) { foreach ($s in @($script:LE.envs.$n.services | Where-Object { $_ -and $_.port })) { $by["$($s.port)"] = @($by["$($s.port)"]) + @([pscustomobject]@{ who = "$n/$($s.name)"; external = [bool]$s.external; start = [string]$s.start }) | Where-Object { $_ } } }
  foreach ($port in $by.Keys) {
    $u = @($by[$port]); if ($u.Count -lt 2) { continue }
    if (@($u | Where-Object { -not $_.external }).Count -or @($u.start | Select-Object -Unique).Count -gt 1) { "port $port is claimed by $(($u.who) -join ', ')" }
  }
}
# repos the env runs from: name -> { name, cfg, target, wt, live }. live = a service runs straight from the worktree (dev server,
# spring-boot:run): its code changes when the worktree changes, so a train syncs that repo only when its leases allow.
function EnvRepos([string]$e) {
  $map = [ordered]@{}
  $items = @(EnvServices $e) + @(if ((Get-EnvCfg $e).tasks) { (Get-EnvCfg $e).tasks.PSObject.Properties.Value })
  foreach ($s in $items | Where-Object { $_.repo }) {
    $r = Get-RepoCfg $s.repo
    $t = if ($s.target) { [string]$s.target } else { [string]$r.target }
    if ($map.Contains($r.name)) { if ($map[$r.name].target -ne $t) { throw "env $e uses repo $($r.name) with two targets ($($map[$r.name].target), $t): one env = one target per repo" } }
    else { $map[$r.name] = [pscustomobject]@{ name = $r.name; cfg = $r; target = $t; wt = (Join-Path @($KitConf.WorktreeRoots)[0] "localenv-$e-$(Split-Path $r.checkout -Leaf)"); live = $false } }
  }
  foreach ($s in EnvServices $e | Where-Object { $_.repo -and -not $_.artifact }) { $map[(Get-RepoCfg $s.repo).name].live = $true }
  $map
}
function RepoOf([string]$e, $s) { if ($s.repo) { (Get-RepoCfg $s.repo).name } else { $null } }
function SvcDir([string]$e, $s) {
  if (-not $s.repo) { return $(if ($s.dir) { $s.dir } else { $KitConf.Workspace }) }
  $wt = (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt
  if ($s.dir) { Join-Path $wt $s.dir } else { $wt }
}
# dependency closure: a need for a service is a need for everything it dependsOn
function Closure([string]$e, [string[]]$names) {
  $out = [Collections.Generic.List[string]]::new(); $todo = [Collections.Generic.Queue[string]]::new()
  foreach ($n in $names) { $todo.Enqueue($n) }
  while ($todo.Count) { $n = $todo.Dequeue(); if ($out.Contains($n)) { continue }; $out.Add($n); $s = EnvServices $e | Where-Object name -eq $n; foreach ($d in @($s.dependsOn | Where-Object { $_ })) { $todo.Enqueue($d) } }
  @($out)
}
# services that depend (directly or not) on any of $names
function Dependents([string]$e, [string[]]$names) { @(EnvServices $e | Where-Object { $n = $_.name; @(Closure $e @($n) | Where-Object { $_ -ne $n -and $_ -in $names }).Count } | ForEach-Object name) }
$script:lanIp = $null
function LanIp {
  if (-not $script:lanIp) {
    $script:lanIp = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin 'Loopback', 'Tunnel' } |
      ForEach-Object { $_.GetIPProperties().UnicastAddresses } | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
      ForEach-Object { "$($_.Address)" } | Where-Object { $_ -notmatch '^(169\.254|127\.)' } | Select-Object -First 1
    if (-not $script:lanIp) { $script:lanIp = '127.0.0.1' }
  }
  $script:lanIp
}
function Expand-Placeholders([string]$t, [string]$e, $s, [string]$dir, [string]$artifact) {
  if (-not $t) { return $t }
  $wt = if ($s.repo) { (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt } else { '' }
  $t.Replace('{port}', "$($s.port)").Replace('{dir}', $dir).Replace('{wt}', $wt).Replace('{env}', $e).Replace('{kit}', $KitConf.Kit).Replace('{workspace}', $KitConf.Workspace).Replace('{artifact}', "$artifact").Replace('{lanIp}', $(if ($t -match '\{lanIp\}') { LanIp } else { '' }))
}
$script:stacks = @{}
function StackOf([string]$dir) {
  if (-not $script:stacks.ContainsKey($dir)) { $script:stacks[$dir] = try { & (Join-Path $script:DK 'stack.ps1') -Dir $dir -Json | ConvertFrom-Json } catch { $null } }
  $script:stacks[$dir]
}
function StartCmd([string]$e, $s, [string]$artifact) {
  $dir = SvcDir $e $s
  $c = if ($s.start) { [string]$s.start } else { (StackOf $dir).commands.run }
  if (-not $c) { throw "service $e/$($s.name): no start command (set services[].start, or commands.run in a .claude-stack.json in $dir)" }
  Expand-Placeholders $c $e $s $dir $artifact
}
# dotenv file (KEY=VALUE, '#' comments, optional 'export ', optional quotes) + the env's and the item's env maps
function EnvVars([string]$e, $item) {
  $v = [ordered]@{}
  $f = if ((Get-EnvCfg $e).envFile) { [string](Get-EnvCfg $e).envFile } else { Join-Path (Get-KitPath localenv-env) "$e.env" }
  if (Test-Path -LiteralPath $f) {
    foreach ($l in Get-Content -LiteralPath $f) {
      if ($l -match '^\s*(#|$)') { continue }
      if ($l -match '^\s*(export\s+)?([A-Za-z_][\w.]*)\s*=\s*(.*?)\s*$') { $v[$Matches[2]] = $Matches[3] -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1' }
    }
  }
  foreach ($src in @((Get-EnvCfg $e).env, $item.env) | Where-Object { $_ }) { foreach ($p in $src.PSObject.Properties) { $v[$p.Name] = "$($p.Value)" } }
  $dir = if ($item.repo -or $item.dir) { SvcDir $e $item } else { $KitConf.Workspace }
  foreach ($k in @($v.Keys)) { $v[$k] = Expand-Placeholders $v[$k] $e $item $dir '' }
  $v
}
function With-Env($vars, [scriptblock]$body) {
  $old = @{}; foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  try { & $body } finally { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
}
function LogFile([string]$e, [string]$n) { Join-Path (Get-KitPath localenv-logs -Create) "$e-$n.log" }
function Event([string]$e, [string]$kind, [hashtable]$data = @{}) {
  $data.at = Now; $data.kind = $kind
  try { ($data | ConvertTo-Json -Compress -Depth 6) | Add-Content (Join-Path (Get-KitPath localenv-logs -Create) "$e-events.jsonl") } catch { }
}

# ---------------------------------------------------------------- state (one JSON per env, locked writes)
function StateFile([string]$e) { Join-Path (Get-KitPath localenv -Create) "$e.json" }
function Read-State([string]$e) {
  $f = StateFile $e; $st = $null
  if (Test-Path $f) { try { $st = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "localenv: $f unreadable, starting a fresh state ($_)" } }
  if ($st -isnot [hashtable]) { $st = @{} }
  foreach ($k in 'services', 'leases', 'holds') { if ($st[$k] -isnot [hashtable]) { $st[$k] = @{} } }
  foreach ($k in 'requests', 'releases') { $st[$k] = @(@($st[$k]) | Where-Object { $_ }) }
  if ($st.release -isnot [hashtable]) { $st.release = @{ n = 0; repos = @{} } }
  if ($st.release.repos -isnot [hashtable]) { $st.release.repos = @{} }
  # state written by the first (blocking) localenv version: layers lived at the top level
  if ($st.layers -is [hashtable] -and -not $st.release.repos.Count) { foreach ($rn in $st.layers.Keys) { $st.release.repos[$rn] = @{ layers = @($st.layers[$rn] | Where-Object { $_ }) } }; $st.Remove('layers') }
  $st
}
# $__state, not $s: the callers' scriptblocks read their own $s (a service) through PowerShell's dynamic scoping
function Update-State([string]$e, [scriptblock]$Change) {
  $f = StateFile $e
  Invoke-KitLocked $f {
    $__state = Read-State $e
    & $Change $__state
    $__state | ConvertTo-Json -Depth 10 | Set-Content "$f.tmp" -Encoding utf8
    Move-Item "$f.tmp" $f -Force
  }
}
function Alive($p) { $p -and [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function Layers($st, [string]$rn) { @($st.release.repos[$rn].layers | Where-Object { $_ }) }

# ---------------------------------------------------------------- leases, holds, demand
# A lease is alive until its time ends; with -Session (an agent-board token) it also ends at once when that agent's board entry
# left or went stale (> 20 min without a beat): a dead agent never blocks a deploy.
function SessionDead([string]$session) {
  if (-not $session) { return $false }
  $f = Join-Path (Get-KitPath board) "$session.json"
  if (-not (Test-Path $f)) { return $true }
  try { $b = Get-Content $f -Raw | ConvertFrom-Json } catch { return $false }
  $b.status -eq 'left' -or ((Get-Date) - [datetime]$b.beat).TotalMinutes -gt 20
}
function Prune($st) {
  foreach ($a in @($st.leases.Keys)) { $l = $st.leases[$a]; if ([datetime]$l.until -lt (Get-Date) -or (SessionDead $l.session)) { $st.leases.Remove($a) } }
  foreach ($a in @($st.holds.Keys)) { if ([datetime]$st.holds[$a].until -lt (Get-Date)) { $st.holds.Remove($a) } }
  $st.requests = @($st.requests | Where-Object { $_.status -ne 'done' -or ((Get-Date) - [datetime]$_.at).TotalHours -lt 24 } | Select-Object -Last 60)
  if ($st.train -and -not (Alive $st.train.pid)) {
    foreach ($r in $st.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($st.train.requests)) { $r.status = 'queued' } }   # worker died: the train runs again
    $st.train = $null
  }
}
# Processes on this machine that talk to a port as clients (browser tab, curl, an app), minus the env's own processes and headless
# browsers (agents hold leases instead). Windows only (elsewhere: leases and holds only).
function ClientPids([int]$port, [int[]]$exclude) {
  if (-not $KitIsWindows) { return @() }
  $pids = @(Get-NetTCPConnection -State Established -RemotePort $port -ErrorAction SilentlyContinue | ForEach-Object OwningProcess | Where-Object { $_ -and $_ -notin $exclude } | Select-Object -Unique)
  if (-not $pids) { return @() }
  @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + ($pids -join ' OR ProcessId=')) -Property ProcessId, CommandLine -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -notmatch '--headless' } | ForEach-Object ProcessId)
}
# Why each service is needed now: { svc: [reasons] } (dependency closure applied)
function Demand([string]$e, $st, [int[]]$envPids) {
  $need = @{}
  $add = { param($names, $why) foreach ($n in (Closure $e @($names))) { if (-not $need[$n]) { $need[$n] = @() }; $need[$n] += $why } }
  foreach ($a in $st.leases.Keys) { & $add @($st.leases[$a].services) "lease:$a" }
  foreach ($a in $st.holds.Keys) { & $add @($st.holds[$a].services) "hold:$a" }
  foreach ($s in EnvServices $e | Where-Object { $_.port -and $st.services[$_.name].status -eq 'up' }) {
    if (@(ClientPids ([int]$s.port) $envPids).Count) { & $add @($s.name) 'clients' }
  }
  $need
}

# ---------------------------------------------------------------- code: worktrees, layers, builds
function G([string]$d) { $o = & git -C $d @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' ') in $d : $o" }; $o }
function NoHooksDir { $d = Join-Path (Get-KitPath localenv -Create) '.no-hooks'; New-Item -ItemType Directory -Force $d | Out-Null; $d }   # local-only merges on localenv/<env>, never pushed
function Ensure-Worktree([string]$e, $r) {
  if (Test-Path (Join-Path $r.wt '.git')) { return }
  Write-Host "[$e] creating worktree $($r.wt) ($($r.name) @ $($r.target))"
  & (Join-Path $script:DK 'wt.ps1') new -Repo $r.cfg.checkout -Branch "localenv/$e" -Target $r.target -Name "localenv-$e" | ForEach-Object { Write-Host "  $_" }
}
# The dependency source of a target (kit.local.json repos[].linkFromByTarget / linkFrom, else the main checkout) can change
# (e.g. a clean install per target branch replaces a mismatched one): re-point the env worktree's node_modules / .venv links
# at it, so the env never runs on another branch's installs. Nothing is installed here.
function Sync-DepLinks([string]$e, $r) {
  $c = $r.cfg
  $src = if ($c.linkFromByTarget -and $c.linkFromByTarget.($r.target)) { [string]$c.linkFromByTarget.($r.target) } elseif ($c.linkFrom -and $r.target -eq $c.target) { [string]$c.linkFrom } else { [string]$c.checkout }
  if (-not (Test-Path $src)) { Write-Warning "[$e] dependency source $src for $($r.name) @ $($r.target) does not exist"; return }
  $src = (Resolve-Path $src).Path
  # node_modules next to every tracked package.json: one junction, or a farm when it holds workspace packages (sysinfo Set-NodeModules)
  foreach ($pj in (git -C $r.wt ls-files -- 'package.json' '*/package.json' | Where-Object { $_ -notmatch 'node_modules/' })) {
    $rel = Split-Path $pj; if (-not $rel) { $rel = '.' }; $from = Join-Path $src (Join-Path $rel 'node_modules'); $to = Join-Path $r.wt (Join-Path $rel 'node_modules')
    if ((Test-Path $from) -and (Set-NodeModules $to $from $src $r.wt)) { Write-Host "[$e] $($r.name): $(Join-Path $rel 'node_modules') linked from $src" }
  }
  foreach ($l in Get-DirLinks $r.wt 4 | Where-Object { $_.Name -eq '.venv' }) {
    $rel = [IO.Path]::GetRelativePath($r.wt, $l.FullName); $want = Join-Path $src $rel
    if (-not (Test-Path $want) -or "$(@($l.Target)[0])".TrimEnd('\', '/') -eq $want.TrimEnd('\', '/')) { continue }
    Remove-DirLink $l.FullName; New-DirLink $l.FullName $want
    Write-Host "[$e] $($r.name): $rel now links $want"
  }
}
function Resolve-Ref([string]$d, [string]$b) {
  foreach ($ref in "refs/heads/$b", "refs/remotes/origin/$b") { $x = git -C $d rev-parse -q --verify "$ref^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() } }
  git -C $d fetch -q origin $b 2>$null | Out-Null
  $x = git -C $d rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() }
  $null
}
function HasMigrations([string]$checkout, [string]$target, [string]$sha) { [bool](@(git -C $checkout diff --name-only "origin/$target...$sha" 2>$null) -match $script:MigPattern) }
# Point one repo's env branch at: origin/<target> (fetched unless -NoFetch) + $layers merged in order.
# Returns @{ kept; dropped = @(@{ layer; why; files }) ; targetSha }. Conflicting layers are dropped, never half-merged.
function Sync-Repo([string]$e, $r, [object[]]$layers, [switch]$NoFetch) {
  Ensure-Worktree $e $r
  Sync-DepLinks $e $r
  $d = $r.wt
  $dirty = @(git -C $d status --porcelain --untracked-files=no)
  if ($dirty.Count) { Write-Host "[$e] $d had $($dirty.Count) uncommitted edits: discarded (the env worktree is never edited by hand)"; G $d reset -q --hard HEAD | Out-Null }
  if (-not $NoFetch) { G $d fetch -q origin $r.target | Out-Null }
  G $d reset -q --hard "origin/$($r.target)" | Out-Null
  $base = "$(git -C $d rev-parse HEAD)".Trim()
  $kept = @(); $dropped = @(); $nh = NoHooksDir
  foreach ($l in $layers) {
    $sha = if ($l.sha -and $(git -C $d cat-file -e "$($l.sha)^{commit}" 2>$null; $LASTEXITCODE -eq 0)) { $l.sha } else { Resolve-Ref $d $l.branch }
    if (-not $sha) { $dropped += @{ layer = $l; why = 'branch and commit gone' }; continue }
    git -C $d merge-base --is-ancestor $sha "origin/$($r.target)" 2>$null
    if ($LASTEXITCODE -eq 0) { $dropped += @{ layer = $l; why = "merged into $($r.target)" }; continue }
    $out = git -C $d -c "core.hooksPath=$nh" -c user.name=localenv -c user.email=localenv@localhost merge -q --no-ff --no-edit -m "localenv layer $($l.branch) ($($l.agent))" $sha 2>&1
    if ($LASTEXITCODE) {
      $files = @(git -C $d diff --name-only --diff-filter=U 2>$null)
      git -C $d merge --abort 2>$null | Out-Null; git -C $d reset -q --hard HEAD 2>$null | Out-Null
      $dropped += @{ layer = $l; why = "conflicts with $($r.target) + earlier layers: $(($files | Select-Object -First 8) -join ', ')$(if (-not $files) { "$out" })"; files = $files }; continue
    }
    $l.sha = $sha; $kept += $l
  }
  @{ kept = $kept; dropped = $dropped; targetSha = $base }
}
# Build every service of a repo that has a build command (gated). Returns $null when all built, else "<svc>: <log tail>".
function Build-Repo([string]$e, [string]$rn) {
  foreach ($s in EnvServices $e | Where-Object { $_.build -and (RepoOf $e $_) -eq $rn }) {
    $dir = SvcDir $e $s; $cmd = Expand-Placeholders ([string]$s.build) $e $s $dir ''
    Write-Host "[$e] building $($s.name): $cmd"
    $log = LogFile $e "$($s.name)-build"
    With-Env (EnvVars $e $s) { & (Join-Path $script:DK 'gate.ps1') -Dir $dir -Cmd $cmd *>&1 | Tee-Object -FilePath $log | Select-String -Pattern '^\[gate\] (starting|waiting.*Biggest)' | ForEach-Object { Write-Host "  $_" } }
    if ($LASTEXITCODE) {
      $code = $LASTEXITCODE; $lines = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\[gate\]' })
      $errs = @($lines | Where-Object { $_ -match '(?i)\berror\b|failed|exception|cannot find|not found' } | Select-Object -First 10)
      return "$($s.name) (exit $code): $((@(if ($errs.Count) { $errs } else { $lines | Select-Object -Last 12 })) -join "`n")"
    }
  }
  $null
}
# Copy each built artifact of a repo's services to run/<env>/<svc>/r<release>/ (services run from the copy, so the next build can
# overwrite the worktree while they serve, and a rollback is a restart from the previous copy). Returns { svc: path }.
function Stage-Artifacts([string]$e, [string]$rn, [int]$release) {
  $out = @{}
  foreach ($s in EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -eq $rn }) {
    $dir = SvcDir $e $s
    $excl = if ($s.artifactExclude) { [string]$s.artifactExclude } else { 'original|sources|javadoc|plain' }
    $f = Get-ChildItem (Join-Path $dir $s.artifact) -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch $excl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { throw "[$e] $($s.name): no artifact matches $($s.artifact) in $dir after the build" }
    $to = Join-Path (Get-KitPath localenv -Create) "run/$e/$($s.name)/r$release"
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item $f.FullName $to -Force
    $out[$s.name] = Join-Path $to $f.Name
    # keep the copies of the last 3 releases (the live one, the rollback one, and a spare)
    Get-ChildItem (Split-Path $to) -Directory | Sort-Object { [int]($_.Name.TrimStart('r')) } -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
  $out
}

# ---------------------------------------------------------------- processes
function TreeIds([int]$root, $all) {
  if (-not $all) { $all = Get-SysProcs -NoCommandLine }
  $ids = [Collections.Generic.List[int]]::new(); $ids.Add($root); $i = 0
  while ($i -lt $ids.Count) { foreach ($c in $all) { if ($c.ParentId -eq $ids[$i] -and -not $ids.Contains($c.Id)) { $ids.Add($c.Id) } }; $i++ }
  @($ids)
}
function SvcPids([string]$e, $s, $st, $all) {
  $x = $st.services[$s.name]; $ids = @()
  if ($x -and (Alive $x.pid)) { $ids += TreeIds ([int]$x.pid) $all }
  if ($s.port) { $ids += @(Get-PortPids ([int]$s.port)) }
  @($ids | Where-Object { $_ } | Select-Object -Unique)
}
function TreeGB([int[]]$ids, $all) {
  if (-not $ids) { return 0 }
  if (-not $all) { $all = Get-SysProcs -NoCommandLine }
  [math]::Round((($all | Where-Object { $_.Id -in $ids } | Measure-Object WorkingSet -Sum).Sum) / 1GB, 2)
}
function Healthy([string]$e, $s) {
  if ($s.health) {
    try { $r = Invoke-WebRequest (Expand-Placeholders $s.health $e $s (SvcDir $e $s) '') -TimeoutSec 5 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; return $r.StatusCode -gt 0 -and $r.StatusCode -lt 500 } catch { return $false }
  }
  if ($s.port) { return Test-PortListening ([int]$s.port) }
  Alive (Read-State $e).services[$s.name].pid
}
function Stop-Svc([string]$e, $s, [string]$why = 'stopped') {
  $st = Read-State $e; $x = $st.services[$s.name]
  if ($x -and (Alive $x.pid)) {
    if ($KitIsWindows) { taskkill /PID $x.pid /T /F 2>&1 | Out-Null }
    else { $ids = TreeIds ([int]$x.pid); [array]::Reverse($ids); $ids | ForEach-Object { Stop-SysProcess $_ } }
  }
  # the env owns its ports, but never kills a process it did not start that serves the port of an external service
  if ($s.port -and -not ($s.external -and -not ($x -and $x.pid))) { foreach ($p in Get-PortPids ([int]$s.port)) { if ($p -gt 4) { Stop-SysProcess $p } } }
  Update-State $e { param($z) $o = $z.services[$s.name]; $z.services[$s.name] = @{ status = 'down'; port = $s.port; at = (Now); release = $o.release; artifact = $o.artifact; why = $why; restarts = @($o.restarts) } }
  Event $e 'stop' @{ service = $s.name; why = $why }
}
# history of real footprints and start times: <cache>/localenv-history.json { "<env>/<svc>": [gb...], "<env>/<svc>/startSec": [s...] }
function Get-LocalEnvHistory { $h = try { Get-Content (Get-KitPath localenv-history) -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if ($h -isnot [hashtable]) { $h = @{} }; $h }
function Save-LocalEnvHistory([string]$key, [double]$v) {
  if ($v -le 0) { return }
  $f = Get-KitPath localenv-history -Create
  Invoke-KitLocked $f { $h = Get-LocalEnvHistory; $h[$key] = @(@($h[$key] | Where-Object { $_ }) + $v | Select-Object -Last 5); $h | ConvertTo-Json -Depth 4 | Set-Content $f -Encoding utf8 }
}
function Need-GB([string]$e, $s) {
  if ($s.ramGB) { return [double]$s.ramGB }
  $xs = @((Get-LocalEnvHistory)["$e/$($s.name)"] | Where-Object { $_ })
  if ($xs.Count) { return [math]::Round(($xs | Measure-Object -Maximum).Maximum * 1.15, 1) }
  $st = if ($s.repo -or $s.dir) { "$((StackOf (SvcDir $e $s)).stack)" } else { '' }
  switch -regex ($st) { '^java|^gradle|^android' { 3 } '^angular' { 3 } '^dotnet' { 1.5 } '^node|^react' { 1.5 } '^python|^go|^rust' { 0.5 } default { 1 } }
}
# idle grace: about 3x the service's learned start time, clamped to idle.minMinutes..idle.maxMinutes (slow starters stay up longer)
function GraceMin([string]$e, $s) {
  $xs = @((Get-LocalEnvHistory)["$e/$($s.name)/startSec"] | Where-Object { $_ })
  $start = if ($xs.Count) { ($xs | Measure-Object -Maximum).Maximum } else { 120 }
  [math]::Min($script:IdleMaxM, [math]::Max($script:IdleMinM, [math]::Round(3 * $start / 60, 1)))
}
function KeepFreeGB { $m = Get-SysMem; [double](Get-KitSetting 'localEnv.keepFreeGB' (Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($m.TotalGB * 0.15, 1))))) }
# Memory pressure: RAM under the keep-free floor, or a gated build waiting for room for over a minute
function Pressure {
  if ((Get-SysMem).AvailGB -lt (KeepFreeGB)) { return 'RAM below the keep-free floor' }
  $q = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'queue'
  $w = @(Get-ChildItem $q -Filter *.json -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 1 -and (Alive ([int]$_.BaseName)) })
  if ($w.Count) { return "$($w.Count) gated build(s) waiting for RAM" }
  $null
}
# Wait until the machine has room: RAM above the keep-free floor after this service's need, CPU below cpuMaxPct.
function Wait-Room([string]$e, $s) {
  $need = Need-GB $e $s; $keep = KeepFreeGB
  $until = (Get-Date).AddMinutes($script:RoomWaitMin); $said = (Get-Date).AddMinutes(-5)
  while ($true) {
    $m = Get-SysMem; $cpu = Get-SysCpu
    $ramOk = ($m.AvailGB - $need) -ge $keep; $cpuOk = $cpu -lt $script:CpuMax
    if ($ramOk -and $cpuOk) { return }
    if ((Get-Date) -gt $until) {
      if (-not $ramOk) {
        $top = Get-SysProcs -NoCommandLine | Group-Object Name | ForEach-Object { [pscustomobject]@{ n = $_.Name; gb = [math]::Round(($_.Group | Measure-Object WorkingSet -Sum).Sum / 1GB, 1) } } | Sort-Object gb -Descending | Select-Object -First 6
        throw "[$e] no room to start $($s.name) after $($script:RoomWaitMin) min: needs $need GB + keep-free $keep GB, available $($m.AvailGB) GB. Biggest: $(($top | ForEach-Object { "$($_.n) $($_.gb)G" }) -join ', ')"
      }
      "[$e] CPU still $cpu% after $($script:RoomWaitMin) min: starting $($s.name) anyway"; return
    }
    if (((Get-Date) - $said).TotalSeconds -ge 60) { "[$e] waiting for room to start $($s.name): RAM avail $($m.AvailGB) GB (need $need + keep $keep), CPU $cpu% (max $($script:CpuMax)%)"; $said = Get-Date }
    Start-Sleep 10
  }
}
# Start one service (stops whatever holds its port first). $artifact: the staged copy to run (services with "artifact").
function Start-Svc([string]$e, $s, [int]$release, [string]$artifact) {
  $dir = SvcDir $e $s
  if (-not (Test-Path $dir)) { throw "[$e] $($s.name): folder $dir does not exist" }
  $cmd = StartCmd $e $s $artifact
  Stop-Svc $e $s 'restart'
  # one start at a time machine-wide (across envs): the RAM check and the ramp-up of the previous start must not overlap
  $mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { 'Global\kit-localenv-start' } else { 'kit-localenv-start' }))
  try { $null = $mx.WaitOne([TimeSpan]::FromMinutes(45)) } catch [Threading.AbandonedMutexException] { }
  try {
    Wait-Room $e $s
    $log = LogFile $e $s.name; if (Test-Path $log) { Move-Item $log "$log.prev" -Force }
    "[$e] starting $($s.name)$(if ($release) { " (release $release)" }): $cmd"
    $t0 = Get-Date
    $pwsh = (Get-Process -Id $PID).Path
    $a = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'localenv.ps1'), '_exec', '-Env', $e, '-Service', $s.name, '-Artifact', "$artifact")
    $p = $null
    if ($KitIsWindows) { $p = (Start-Process -FilePath $pwsh -ArgumentList (($a | ForEach-Object { if ("$_" -match '\s' -or "$_" -eq '') { "`"$_`"" } else { $_ } }) -join ' ') -WorkingDirectory $dir -WindowStyle Hidden -PassThru).Id }
    else {
      Start-Detached -FilePath $pwsh -ArgumentList $a -WorkingDirectory $dir -Log "$log.wrapper"
      Start-Sleep 1; $p = (Get-SysProcs | Where-Object { $_.CommandLine -match [regex]::Escape("_exec -Env $e -Service $($s.name)") } | Select-Object -First 1).Id
    }
    Update-State $e { param($x) $o = $x.services[$s.name]; $x.services[$s.name] = @{ status = 'starting'; pid = $p; port = $s.port; startedAt = (Now); lastNeed = (Now); release = $release; artifact = $artifact; restarts = @($o.restarts) } }
    $limit = (Get-Date).AddMinutes([double]$(if ($s.startMinutes) { $s.startMinutes } else { 10 }))
    $fail = if ($s.failPattern) { [string]$s.failPattern } else { $script:FailPattern }
    while (-not (Healthy $e $s)) {
      $hit = if ($fail -and (Test-Path $log)) { Select-String -LiteralPath $log -Pattern $fail -List | Select-Object -First 1 }
      $why = if ($hit) { "failed to start (log line $($hit.LineNumber): $($hit.Line.Trim()))" } elseif (-not (Alive $p)) { 'exited while starting' } elseif ((Get-Date) -gt $limit) { "not healthy within $(if ($s.startMinutes) { $s.startMinutes } else { 10 }) min" } else { $null }
      if ($why) {
        Stop-Svc $e $s $why; Update-State $e { param($x) $x.services[$s.name].status = 'failed' }
        Event $e 'start-failed' @{ service = $s.name; why = $why; release = $release }
        throw "[$e] $($s.name) $why. Log: $log`n$((Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n")"
      }
      Start-Sleep 5
    }
    $sec = [int]((Get-Date) - $t0).TotalSeconds
    $gb = TreeGB (@(TreeIds $p) + @(if ($s.port) { Get-PortPids ([int]$s.port) }))
    Save-LocalEnvHistory "$e/$($s.name)" $gb; Save-LocalEnvHistory "$e/$($s.name)/startSec" $sec
    Update-State $e { param($x) $x.services[$s.name].status = 'up'; $x.services[$s.name].gb = $gb; $x.services[$s.name].upAt = (Now) }
    Event $e 'up' @{ service = $s.name; release = $release; sec = $sec; gb = $gb }
    "[$e] $($s.name) up$(if ($s.port) { " on port $($s.port)" }) in $sec s ($gb GB)"
  } finally { $mx.ReleaseMutex(); $mx.Dispose() }
}
