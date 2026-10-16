<#
localenv.ps1: local environments, one file (local-env SKILL.md; agents: reference "Local testing" in that SKILL.md).
ONE shared running instance per configured env (kit.local.json localEnv.envs) that agents deploy their branches to, test,
reproduce bugs and debug against. Stack-agnostic: a service is a start command in a folder (default: dev.ps1 stack `run`).
  & <kit>/skills/local-env/localenv.ps1 <verb> [args]
Verbs: envs · status · deploy · wait · use · release · promote · task · logs · events · migrations · (owner) up · down · drop · refresh
       _daemon -Env <env> [-Train <id>] (controller, started by this script) · _exec (service wrapper)
Inputs: kit.local.json localEnv, .state/localenv/<env>.env (secrets). Outputs: text; status -Json.
Exit codes: 0 ok · 1 refused / rejected / rolled back / failed · 2 usage error (unknown env, no localEnv configured) · 3 still running (wait -Id).
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---------------------------------------------------------------- library (config, state, layers/builds, processes, admission, leases, demand)# Library dot-sourced by localenv.ps1 (CLI) and localenv.ps1 _daemon (the per-env controller loop); never run by hand.
# Config, state, layers/builds, processes, admission, leases and demand. See localenv.ps1 for the model.
#
# State per env: Get-KitPath localenv /<env>.json, locked read-modify-write (Update-State). Fields:
#   release   { n, at, train, repos: { <repo>: { target, targetSha, layers: [ { branch, agent, sha, migrations, mclass?, since?, mtag?, promoted? } ] } } }
#             mclass = { class, effective: light|heavy, why[], count, manifest, ids[] } (Get-MigClass); since = release it went live in
#   releases  [ last releases (summaries) ]
#   services  { <svc>: { status: up|starting|down|failed|blocked, pid, port, release, artifact, startedAt, upAt, lastNeed, gb, restarts[], why } }
#   leases    { <agent>: { services[], repos[], until, release, session, note, at } }
#   holds     { <who>: { services[], until } }
#   requests  [ { id, kind: deploy|drop|refresh|stop, agent, branch, repos[], at, status: queued|in-train|done, result{ outcome, release, message } } ]
#   train     { id, pid, phase, requests[], blockServices[], blockRepos[], waitingFor[], at }   (while a train worker runs)
#   sandboxes { sb<k>: { k, branch, agent, sha, repo, services[], at, lastUse, promoted? } }; snapshots [ { name, at, release, layers[] } ]
#   loop      { pid, beat }
$ErrorActionPreference = 'Stop'

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
function Svc([string]$e, [string]$n) {
  if ($n -match '^sb(\d+)-(.+)$') { return (SandboxSvc $e ([int]$Matches[1]) $Matches[2]) }
  $s = EnvServices $e | Where-Object name -eq $n; if (-not $s) { throw "env $e has no service '$n' ($((EnvServices $e).name -join ', '))" }; $s
}
# ---------------------------------------------------------------- migration sandboxes
# envs.<env>.sandbox = { services: [names run per sandbox: the migrating API and the infra it must not share, e.g. search],
#   max (2), portOffset (100), idleHours (4), env: { K: "..." }, db: { clone, drop, sweep } }. Placeholders: {suffix} = sb<k>, {k},
#   {+N} = N + portOffset*k (ports of the sandbox's own DB server / search). A deploy whose branch has migrations runs in sandbox k:
#   target + that branch only, its own build, its own DB server copy (clone hook), instances "sb<k>-<svc>" on port + portOffset*k.
function SandboxCfg([string]$e) { (Get-EnvCfg $e).sandbox }
function SandboxWt([string]$e, [int]$k, $r) { Join-Path @($KitConf.WorktreeRoots)[0] "localenv-$e-sb$k-$(Split-Path $r.cfg.checkout -Leaf)" }
function SandboxSvc([string]$e, [int]$k, [string]$base) {
  $b = EnvServices $e | Where-Object name -eq $base; if (-not $b) { throw "env $e has no service '$base'" }
  $sb = SandboxCfg $e; $off = [int]$(if ($sb.portOffset) { $sb.portOffset } else { 100 }) * $k
  $o = $b | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $o.name = "sb$k-$base"
  $suffix = "sb$k"
  if ($b.port) { $o.port = [int]$b.port + $off; if ($o.health) { $o.health = ([string]$o.health).Replace(":$($b.port)", ":$($o.port)") } }
  if ($b.debugPort) { $o.debugPort = [int]$b.debugPort + $off }
  $o | Add-Member -NotePropertyName offset -NotePropertyValue $off -Force
  $o | Add-Member -NotePropertyName k -NotePropertyValue $k -Force
  $o | Add-Member -NotePropertyName suffix -NotePropertyValue $suffix -Force
  $envMap = [ordered]@{}; foreach ($src in @($b.env, $sb.env) | Where-Object { $_ }) { foreach ($p in $src.PSObject.Properties) { $envMap[$p.Name] = [string]$p.Value } }
  $o | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]$envMap) -Force
  if ($b.repo) { $o | Add-Member -NotePropertyName wtOverride -NotePropertyValue (SandboxWt $e $k ((EnvRepos $e)[(Get-RepoCfg $b.repo).name])) -Force }
  $o | Add-Member -NotePropertyName dependsOn -NotePropertyValue @($b.dependsOn | Where-Object { $_ } | ForEach-Object { if ($_ -in @($sb.services)) { "sb$k-$_" } else { $_ } }) -Force
  $o
}
# A service is managed (started/stopped by the env) unless it is external infra without a start command (e.g. a shared DB server)
function Managed($s) { -not ($s.external -and -not $s.start) }
# Envs run side by side, so a port belongs to exactly one service across ALL envs. The only sharing allowed: external infra
# (external: true) that every env declares with the same start command (or none), e.g. one database server for every env.
function Test-PortClash {
  $by = @{}
  # one claim per owner: repeats of a port by the same sandbox (its search and its own ES env var, a port named in several hooks) are one
  $add = { param($port, $who, $ext, $start) $own = if ($who -match '^([^/]+/sb\d+)') { $Matches[1] } else { $who }; if (@($by["$port"] | Where-Object { $_ -and ($_.who -eq $who -or ($_.who -match '^([^/]+/sb\d+)' -and $Matches[1] -eq $own)) }).Count) { return }; $by["$port"] = @(@($by["$port"]) + @([pscustomobject]@{ who = $who; external = $ext; start = $start }) | Where-Object { $_ }) }
  foreach ($n in EnvNames) {
    $sb = $script:LE.envs.$n.sandbox
    foreach ($s in @($script:LE.envs.$n.services | Where-Object { $_ -and $_.port })) {
      & $add $s.port "$n/$($s.name)" ([bool]$s.external) ([string]$s.start)
      if ($sb -and $s.name -in @($sb.services)) {
        foreach ($k in 1..[int]$(if ($sb.max) { $sb.max } else { 2 })) {
          $off = [int]$(if ($sb.portOffset) { $sb.portOffset } else { 100 }) * $k
          & $add ([int]$s.port + $off) "$n/sb$k-$($s.name)" $false ''
          if ($s.debugPort) { & $add ([int]$s.debugPort + $off) "$n/sb$k-$($s.name) (debug)" $false '' }
        }
      }
      if ($s.debugPort) { & $add $s.debugPort "$n/$($s.name) (debug)" $false '' }
    }
    if ($sb) {
      $text = (@(@($sb.env.PSObject.Properties.Value) + @($sb.db.PSObject.Properties.Value)) -join ' ')
      foreach ($m in [regex]::Matches($text, '\{\+(\d+)\}')) { foreach ($k in 1..[int]$(if ($sb.max) { $sb.max } else { 2 })) { & $add ([int]$m.Groups[1].Value + [int]$(if ($sb.portOffset) { $sb.portOffset } else { 100 }) * $k) "$n/sb$k {+$($m.Groups[1].Value)}" $false '' } }
    }
  }
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
  $wt = if ($s.wtOverride) { $s.wtOverride } else { (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt }
  if ($s.dir) { Join-Path $wt $s.dir } else { $wt }
}
# dependency closure: a need for a service is a need for everything it dependsOn
function Closure([string]$e, [string[]]$names) {
  $out = [Collections.Generic.List[string]]::new(); $todo = [Collections.Generic.Queue[string]]::new()
  foreach ($n in $names) { $todo.Enqueue($n) }
  while ($todo.Count) { $n = $todo.Dequeue(); if ($out.Contains($n)) { continue }; $out.Add($n); $s = if ($n -match '^sb\d+-(.+)$') { EnvServices $e | Where-Object name -eq $Matches[1] } else { EnvServices $e | Where-Object name -eq $n }; foreach ($d in @($s.dependsOn | Where-Object { $_ })) { $todo.Enqueue($d) } }
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
  $wt = if ($s.wtOverride) { $s.wtOverride } elseif ($s.repo) { (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt } else { '' }
  $off = [int]$(if ($s.offset) { $s.offset } else { 0 })
  $t = [regex]::Replace($t, '\{\+(\d+)\}', { param($m) "$([int]$m.Groups[1].Value + $off)" })
  $t.Replace('{port}', "$($s.port)").Replace('{debugPort}', "$($s.debugPort)").Replace('{suffix}', "$($s.suffix)").Replace('{k}', "$($s.k)").Replace('{dir}', $dir).Replace('{wt}', $wt).Replace('{env}', $e).Replace('{kit}', $KitConf.Kit).Replace('{workspace}', $KitConf.Workspace).Replace('{artifact}', "$artifact").Replace('{lanIp}', $(if ($t -match '\{lanIp\}') { LanIp } else { '' }))
}
$script:stacks = @{}
function StackOf([string]$dir) {
  if (-not $script:stacks.ContainsKey($dir)) { $script:stacks[$dir] = try { & $KitCmd.dev stack -Dir $dir -Json | ConvertFrom-Json } catch { $null } }
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
  foreach ($k in 'services', 'leases', 'holds', 'sandboxes') { if ($st[$k] -isnot [hashtable]) { $st[$k] = @{} } }
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
    for ($i = 0; ; $i++) { try { [IO.File]::Move("$f.tmp", $f, $true); break } catch [IO.IOException] { if ($i -ge 40) { throw }; Start-Sleep -Milliseconds 50 } }   # a reader may hold it open
  }
}
function Alive($p) { $p -and [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function PStart($p) { try { (Get-Process -Id ([int]$p) -ErrorAction Stop).StartTime } catch { $null } }
function Owned($x) {
  if (-not ($x -and $x.pid -and (Alive $x.pid))) { return $false }
  if (-not $x.pstart) { return $true }
  $now = PStart $x.pid; $now -and [math]::Abs(($now - [datetime]$x.pstart).TotalSeconds) -lt 2
}
# a process serving one of the env's ports counts as the env's own when it runs from the env's run copies or worktrees
function EnvProcess([int]$p, [string]$e) {
  # Get-CimInstance does not exist off Windows (a missing command is fatal under Stop): ask ps there
  $c = if ($KitIsWindows) { "$((Get-CimInstance Win32_Process -Filter "ProcessId=$p" -Property CommandLine -ErrorAction SilentlyContinue).CommandLine)" } else { "$(ps -o args= -p $p 2>$null)" }
  $c -and ($c.Contains((Get-KitPath localenv)) -or $c -match [regex]::Escape("localenv-$e-") -or $c -match [regex]::Escape("_exec -Env $e "))
}
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
  foreach ($a in @($st.leases.Keys)) { $l = $st.leases[$a]; if ([datetime]$l.until -lt (Get-Date) -or (SessionDead $l.session) -or ($l.pid -and -not (Alive $l.pid))) { $st.leases.Remove($a) } }
  foreach ($a in @($st.holds.Keys)) { if ([datetime]$st.holds[$a].until -lt (Get-Date)) { $st.holds.Remove($a) } }
  $st.requests = @($st.requests | Where-Object { $_.status -ne 'done' -or ((Get-Date) - [datetime]$_.at).TotalHours -lt 24 } | Select-Object -Last 60)
  if ($st.train -and -not (Alive $st.train.pid) -and ($st.train.pid -or ((Get-Date) - [datetime]$st.train.at).TotalSeconds -gt 60)) {
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
  & $KitCmd.dev wt new -Repo $r.cfg.checkout -Branch "localenv/$e" -Target $r.target -Name "localenv-$e" | ForEach-Object { Write-Host "  $_" }
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
# a failed diff (unknown sha, no fetch) is not 'no migrations': treat it as having them, so the deploy is audited
function HasMigrations([string]$checkout, [string]$target, [string]$sha) { $d = @(git -C $checkout diff --name-only "origin/$target...$sha" 2>$null); if ($LASTEXITCODE) { return $true }; [bool]($d -match $script:MigPattern) }

# ---------------------------------------------------------------- migration classes: LIGHT = exact revert, HEAVY = sandbox / snapshot
# migrations.py audits the changeSets a branch adds (rules: localEnv.migrations + envs.<env>.migrations, see configuration.md).
# LIGHT counts only with a db.rollback hook (and migrations.mode != snapshot); otherwise every migration is handled as HEAVY.
function MigCfg([string]$e) {
  $m = [ordered]@{ pattern = $script:MigPattern }
  foreach ($src in @($script:LE.migrations, (Get-EnvCfg $e).migrations) | Where-Object { $_ }) { foreach ($p in $src.PSObject.Properties) { if ($p.Name -notlike '_*') { $m[$p.Name] = $p.Value } } }
  $m
}
function MigMode([string]$e) { if ("$((MigCfg $e).mode)" -ne 'snapshot' -and (Get-EnvCfg $e).db.rollback) { 'classify' } else { 'snapshot' } }
function MigRoot([string]$e) { Join-Path (Get-KitPath localenv -Create) "migrations/$e" }
function MigCfgFile([string]$e) {
  $t = (MigCfg $e) | ConvertTo-Json -Depth 8
  $f = Join-Path (MigRoot $e) "config-$([BitConverter]::ToString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($t))).Replace('-', '').Substring(0, 8)).json"
  if (-not (Test-Path $f)) { New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content $f $t -Encoding utf8 }
  $f
}
# the folders of the env's services in a repo: migrations elsewhere in the repo (another product) do not touch this env
function MigUnder([string]$e, [string]$rn) {
  $s = @(EnvServices $e | Where-Object { $_.repo -and (Get-RepoCfg $_.repo).name -eq $rn })
  if (-not $s.Count -or @($s | Where-Object { -not $_.dir }).Count) { return @() }
  @($s | ForEach-Object { "$($_.dir)".Replace('\', '/').Trim('/') } | Select-Object -Unique)
}
function Invoke-MigPy([string]$e, [string[]]$a) {
  $errF = LogFile $e 'migrations'
  $out = & (Get-Python) -X utf8 $KitCmd.migrations @a 2>> $errF
  if ($LASTEXITCODE) { throw "migrations.py $($a[0]) failed (exit $LASTEXITCODE): $((Get-Content $errF -Tail 3) -join ' | ')" }
  ($out -join "`n") | ConvertFrom-Json -AsHashtable
}
# Classify one repo's migrations of a deploy. $null = none for this env; else @{ class; effective; why[]; count; manifest; ids[] }
function Get-MigClass([string]$e, $r, [string]$sha) {
  try {
    $cf = MigCfgFile $e
    $d = Join-Path (MigRoot $e) "$($r.name)/$($sha.Substring(0, 12))-$([IO.Path]::GetFileNameWithoutExtension($cf).Substring(7))"
    $m = Join-Path $d 'manifest.json'
    if (-not (Test-Path $m)) {
      $a = @('classify', '--repo', $r.cfg.checkout, '--base', "origin/$($r.target)", '--head', $sha, '--config', $cf, '--save', $d)
      $u = MigUnder $e $r.name; if ($u.Count) { $a += @('--under', ($u -join ',')) }
      $null = Invoke-MigPy $e $a
    }
    $j = Get-Content $m -Raw | ConvertFrom-Json -AsHashtable
  } catch { return @{ class = 'heavy'; effective = 'heavy'; why = @("classification failed: $("$_".Split("`n")[0])"); count = 0; manifest = $null; ids = @() } }
  if ($j.class -eq 'none') { return $null }
  $eff = $j.class; $why = @($j.reasons)
  if ($eff -eq 'light' -and (MigMode $e) -ne 'classify') { $eff = 'heavy'; $why = @('no db.rollback hook (or migrations.mode snapshot): LIGHT changeSets are handled as HEAVY') }
  @{ class = $j.class; effective = $eff; why = $why; count = @($j.changesets).Count; manifest = $m; ids = @($j.changesets | ForEach-Object { "$($_.file)::$($_.id)" }) }
}
function MigText($mc) {
  if (-not $mc) { return '' }
  if ($mc.effective -eq 'light') { "MIGRATIONS LIGHT ($($mc.count) changeSets: no snapshot, exact revert when the layer leaves)" }
  else { "MIGRATIONS HEAVY ($(@($mc.why)[0])$(if (@($mc.why).Count -gt 1) { " +$(@($mc.why).Count - 1) more" }))" }
}
function LayerLight($l) { [bool]($l.migrations -and $l.mclass -and $l.mclass.effective -eq 'light' -and $l.mclass.manifest) }
function ReqHeavy($r, [string]$rn) { [bool]($r.migrations[$rn] -and -not ($r.mclass -and $r.mclass[$rn] -and $r.mclass[$rn].effective -eq 'light')) }
# Plan the revert of leaving LIGHT layers' changeSets that the new release no longer has (in $wt or in a staying layer), newest
# first. Returns @{ count; revert[]; kept[]; blocked[]; manifest; searchPath; changelog; cmd }: cmd = the db.rollback command.
function Get-MigRevertPlan([string]$e, [string]$rn, [object[]]$leaving, [object[]]$staying, [string]$wt, [string]$tag) {
  $out = Join-Path (MigRoot $e) "$rn/revert-$tag"
  Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
  Get-ChildItem (Split-Path $out) -Directory -Filter 'revert-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  $a = @('plan', '--config', (MigCfgFile $e), '--out', $out, '--leaving', (@($leaving | ForEach-Object { $_.mclass.manifest }) -join ','))
  $st = @($staying | Where-Object { $_.mclass.manifest }); if ($st.Count) { $a += @('--staying', (@($st | ForEach-Object { $_.mclass.manifest }) -join ',')) }
  if ($wt) { $a += @('--repo', $wt) }
  $p = Invoke-MigPy $e $a
  $p.branches = @($leaving.branch); $p.tag = @($leaving | ForEach-Object { $_.mtag } | Where-Object { $_ })[0]
  $p.vars = @{ manifest = $p.manifest; count = $p.count; searchPath = $p.searchPath; changelog = $p.changelog; tag = "$($p.tag)"; repo = $rn; repoWt = "$((EnvRepos $e)[$rn].wt)"; branch = ($p.branches -join ',') }
  $p.cmd = if ($p.count) { Get-HookCmd $e 'rollback' $p.vars } else { $null }
  $p
}
# Run a plan's db.rollback, then check with db.applied (when set) that no reverted changeSet is still listed. $null = done, else why.
function Invoke-MigRevertPlan([string]$e, $p) {
  if (-not $p.count) { return $null }
  $err = Invoke-Hook $e 'rollback' $p.vars
  if ($err) { return $err }
  if (-not (Get-EnvCfg $e).db.applied) { return $null }
  $err = Invoke-Hook $e 'applied' $p.vars
  if ($err) { return "revert ran, check failed: $err" }
  $left = @($p.revert | Where-Object { $k = "$($_.file)::$($_.id)::$($_.author)"; @($script:HookOut | Where-Object { "$_".Contains($k) }).Count })
  if ($left.Count) { return "revert ran but db.applied still lists $(@($left | ForEach-Object { "$($_.file)::$($_.id)" }) -join ', ')" }
  $null
}
function MigPlanText($p) {
  if (-not $p) { return '' }
  if ($p.blocked.Count) { return "revert blocked: $(@($p.blocked | ForEach-Object { "$($_.key) uses $(@($_.uses) -join ', ')" }) -join '; ')" }
  if (-not $p.count) { return "nothing to revert ($(@($p.kept).Count) changeSets stay in the release)" }
  "revert $($p.count) changeSets newest first ($(@($p.revert | Select-Object -First 4 | ForEach-Object { "$($_.file | Split-Path -Leaf)::$($_.id)" }) -join ', ')$(if ($p.count -gt 4) { ', ...' })): $(if ($p.cmd) { $p.cmd } else { 'no db.rollback hook' })"
}
# Point one repo's env branch at: origin/<target> (fetched unless -NoFetch) + $layers merged in order.
# Returns @{ kept; dropped = @(@{ layer; why; files }) ; targetSha }. Conflicting layers are dropped, never half-merged.
function Sync-Repo([string]$e, $r, [object[]]$layers, [switch]$NoFetch) {
  Ensure-Worktree $e $r
  Sync-DepLinks $e $r
  $d = $r.wt
  $top = "$(git -C $d rev-parse --show-toplevel 2>$null)".Trim()
  if (-not $top -or [IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($d).TrimEnd('\', '/')) { throw "[$e] $d is not its own git worktree (toplevel: $top): refusing to reset it" }
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
    $log = LogFile $e "$($s.name)-build"; Remove-Item $log -ErrorAction SilentlyContinue
    With-Env (EnvVars $e $s) { & $KitCmd.dev gate -Dir $dir -Cmd "$cmd > `"$log`" 2>&1" *>&1 | Select-String -Pattern '^\[gate\] (starting|waiting.*Biggest)' | ForEach-Object { Write-Host "  $_" } }
    if ($LASTEXITCODE) {
      $code = $LASTEXITCODE; $lines = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\[gate\]|^WARNING:' })
      $errs = @($lines | Where-Object { $_ -match '(?i)\berror\b|failed|exception|cannot find|not found' } | Select-Object -First 10)
      return "$($s.name) (exit $code): $((@(if ($errs.Count) { $errs } else { $lines | Select-Object -Last 12 })) -join "`n")"
    }
  }
  $null
}
# Copy each built artifact of a repo's services to run/<env>/<svc>/r<release>/ (services run from the copy, so the next build can
# overwrite the worktree while they serve, and a rollback is a restart from the previous copy). Returns { svc: path }.
function Stage-Artifacts([string]$e, [string]$rn, [string]$tag) {
  $out = @{}
  foreach ($s in EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -eq $rn }) {
    $dir = SvcDir $e $s
    $excl = if ($s.artifactExclude) { [string]$s.artifactExclude } else { 'original|sources|javadoc|plain' }
    $f = Get-ChildItem (Join-Path $dir $s.artifact) -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch $excl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { throw "[$e] $($s.name): no artifact matches $($s.artifact) in $dir after the build" }
    $to = Join-Path (Get-KitPath localenv -Create) "run/$e/$($s.name)/$tag"
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item $f.FullName $to -Force
    $out[$s.name] = Join-Path $to $f.Name
    # keep the copies of the last 3 releases (the live one, the rollback one, and a spare)
    $inUse = @((Read-State $e).services.Values | ForEach-Object { if ($_.artifact) { Split-Path $_.artifact } })
    Get-ChildItem (Split-Path $to) -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Where-Object { $_.FullName -notin $inUse } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
  $out
}

function Invoke-Shell([string]$cmd, [string]$log, $vars) {
  With-Env $(if ($vars) { $vars } else { @{} }) { if ($KitIsWindows) { & cmd.exe /d /c $cmd *>> $log } else { & /bin/sh -c $cmd *>> $log } }
  $LASTEXITCODE
}
# ---------------------------------------------------------------- hooks (db snapshot / restore) and smoke checks
# Run one env hook command (envs.<env>.db.<name>): placeholders as everywhere plus $vars ({snapshot}); env vars from the env file.
# Returns $null on success, else the error text. Output goes to <logs>/<env>-db.log.
function Get-HookCmd([string]$e, [string]$name, [hashtable]$vars = @{}) {
  $db = (Get-EnvCfg $e).db
  if (-not $db -or -not $db.$name) { return $null }
  $cmd = Expand-Placeholders ([string]$db.$name) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
  foreach ($k in $vars.Keys) { $cmd = $cmd.Replace("{$k}", "$($vars[$k])") }
  $cmd
}
# $script:HookOut = the hook's output lines (db.applied is read from it)
function Invoke-Hook([string]$e, [string]$name, [hashtable]$vars = @{}) {
  $cmd = Get-HookCmd $e $name $vars
  if (-not $cmd) { return "no db.$name hook configured" }
  $log = LogFile $e 'db'
  Add-Content $log "== $(Now) $name : $cmd"
  $n0 = @(Get-Content $log).Count
  $code = Invoke-Shell $cmd $log (EnvVars $e ([pscustomobject]@{}))
  $script:HookOut = @(Get-Content $log | Select-Object -Skip $n0)
  Event $e "db-$name" @{ code = $code; vars = $vars }
  if ($code) { return "db.$name failed (exit $code): $((Get-Content $log -Tail 8) -join ' | ')" }
  $null
}
# Smoke checks after a switch-over: envs.<env>.smoke = [ { name, url?, status? (regex on the HTTP status, default ^[23]|401|403),
# cmd? (exit 0 = pass), service? (skip while it is down), timeoutSec? (60, retried every 5 s) } ]. Returns $null when all pass, else "<name>: <why>".
function Test-Smoke([string]$e) {
  foreach ($c in @((Get-EnvCfg $e).smoke | Where-Object { $_ })) {
    if ($c.service -and -not (Healthy $e (Svc $e $c.service))) { continue }   # a check of a stopped (idle) service is skipped
    $until = (Get-Date).AddSeconds([double]$(if ($c.timeoutSec) { $c.timeoutSec } else { 60 })); $why = 'not run'
    while ($true) {
      if ($c.url) {
        $u = Expand-Placeholders ([string]$c.url) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        $want = if ($c.status) { [string]$c.status } else { '^[23]\d\d$|^401$|^403$' }
        try { $r = Invoke-WebRequest $u -TimeoutSec 15 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; if ("$($r.StatusCode)" -match $want) { $why = $null } else { $why = "$u returned $($r.StatusCode)" } } catch { $why = "$u : $($_.Exception.Message)" }
      } elseif ($c.cmd) {
        $cmd = Expand-Placeholders ([string]$c.cmd) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        $slog = LogFile $e 'smoke'; Remove-Item $slog -ErrorAction SilentlyContinue
        $code = Invoke-Shell $cmd $slog (EnvVars $e ([pscustomobject]@{}))
        $why = if ($code) { "exit $code : $((Get-Content $slog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')" } else { $null }
      }
      if (-not $why -or (Get-Date) -gt $until) { break }
      Start-Sleep 5
    }
    if ($why) { Event $e 'smoke-failed' @{ check = $c.name; why = $why }; return "$($c.name): $why" }
  }
  $null
}

# Create sandbox k for one deploy: worktree = target + the branch only, build, stage, clone the DB, start its instances.
# Returns @{ ok; message; services }.
function New-Sandbox([string]$e, [int]$k, $r, $layer) {
  $sb = SandboxCfg $e; $suffix = "sb$k"
  $wt = SandboxWt $e $k $r
  if (-not (Test-Path (Join-Path $wt '.git'))) {
    & $KitCmd.dev wt new -Repo $r.cfg.checkout -Branch "localenv/$e-$suffix" -Target $r.target -Name "localenv-$e-$suffix" | ForEach-Object { Write-Host "  $_" }
  }
  $names0 = @($sb.services | Where-Object { $_ -and ((RepoOf $e (Svc $e $_)) -eq $r.name -or -not (Svc $e $_).repo) })
  Update-State $e { param($x) $x.sandboxes["sb$k"] = @{ k = $k; branch = $layer.branch; agent = $layer.agent; sha = $layer.sha; repo = $r.name; services = @($names0 | ForEach-Object { "sb$k-$_" }); at = (Now); lastUse = (Now); request = $layer.request } }
  $rr = [pscustomobject]@{ name = $r.name; cfg = $r.cfg; target = $r.target; wt = $wt; live = $false }
  $res = Sync-Repo $e $rr @($layer)
  if ($res.dropped.Count) { return @{ ok = $false; message = "sandbox: $($res.dropped[0].why)" } }
  $inst = @($names0 | ForEach-Object { SandboxSvc $e $k $_ })
  foreach ($s in $inst | Where-Object { $_.build -and $_.repo }) {
    $d = SvcDir $e $s; $cmd = Expand-Placeholders ([string]$s.build) $e $s $d ''
    Write-Host "[$e] sandbox $suffix building $($s.name)"
    $log = LogFile $e "$($s.name)-build"; Remove-Item $log -ErrorAction SilentlyContinue
    With-Env (EnvVars $e $s) { & $KitCmd.dev gate -Dir $d -Cmd "$cmd > `"$log`" 2>&1" *>&1 | Out-Null }
    if ($LASTEXITCODE) { return @{ ok = $false; message = "sandbox build of $($s.name) failed: $((@(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '(?i)\berror\b|failed' -and $_ -notmatch '^WARNING:' }) | Select-Object -First 8) -join ' | ')" } }
  }
  if ($sb.db.clone) {
    $cmd = Expand-Placeholders ([string]$sb.db.clone) $e ([pscustomobject]@{ suffix = $suffix; k = $k; offset = [int]$(if ($sb.portOffset) { $sb.portOffset } else { 100 }) * $k }) $KitConf.Workspace ''; $log = LogFile $e 'db'; Add-Content $log "== $(Now) clone $suffix : $cmd"
    if (Invoke-Shell $cmd $log (EnvVars $e ([pscustomobject]@{}))) { return @{ ok = $false; message = "db clone failed: $((Get-Content $log -Tail 5) -join ' | ')" } }
  }
  $deps = @($inst | ForEach-Object { @($_.dependsOn) } | Where-Object { $_ -and $_ -notlike "sb$k-*" } | Select-Object -Unique)
  if ($deps.Count) {
    Update-State $e { param($x) $x.holds["sandbox-sb$k"] = @{ services = @(Closure $e $deps); until = (Get-Date).AddHours(24).ToString('o') } }
    $until = (Get-Date).AddMinutes(10)
    while (@($deps | Where-Object { $d = Svc $e $_; (Managed $d) -and -not (Healthy $e $d) }).Count) {
      if ((Get-Date) -gt $until) { return @{ ok = $false; message = "sandbox dependencies not up within 10 min: $($deps -join ', ')" } }
      Start-Sleep 5
    }
  }
  foreach ($s in $inst) {
    $art = $null
    if ($s.artifact) {
      $f = Get-ChildItem (Join-Path (SvcDir $e $s) $s.artifact) -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch $(if ($s.artifactExclude) { $s.artifactExclude } else { 'original|sources|javadoc|plain' }) | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if (-not $f) { return @{ ok = $false; message = "sandbox build of $($s.name) left no artifact matching $($s.artifact)" } }
      $to = Join-Path (Get-KitPath localenv -Create) "run/$e/$($s.name)"; New-Item -ItemType Directory -Force $to | Out-Null; Copy-Item $f.FullName $to -Force; $art = Join-Path $to $f.Name
    }
    try { Start-Svc $e $s 0 $art | Out-Host } catch { return @{ ok = $false; message = "sandbox $($s.name) did not start: $("$_".Split("`n")[0])"; services = @($inst.name) } }
  }
  @{ ok = $true; services = @($inst.name); message = "sandbox $suffix : $(($inst | ForEach-Object { "$($_.name) :$($_.port)$(if ($_.debugPort) { " (debug $($_.debugPort))" })" }) -join ', ')$(if ($sb.db.clone) { "; own DB copy (db.clone)" }). Test there; promote -> it joins the main env; drop -> removed." }
}
function Remove-Sandbox([string]$e, [string]$key) {
  $st = Read-State $e; $sbx = if ($st.sandboxes) { $st.sandboxes[$key] } else { $null }
  if (-not $sbx) { return }
  foreach ($n in @($sbx.services)) { try { Stop-Svc $e (Svc $e $n) 'sandbox removed' } catch { } }
  $sb = SandboxCfg $e
  if ($sb.db.drop) { $cmd = Expand-Placeholders ([string]$sb.db.drop) $e ([pscustomobject]@{ suffix = $key; k = [int]$sbx.k; offset = [int]$(if ($sb.portOffset) { $sb.portOffset } else { 100 }) * [int]$sbx.k }) $KitConf.Workspace ''; $null = Invoke-Shell $cmd (LogFile $e 'db') (EnvVars $e ([pscustomobject]@{})) }
  $r = (EnvRepos $e)[$sbx.repo]; $wt = SandboxWt $e ([int]$sbx.k) $r
  if ((Test-Path $wt) -and (Split-Path $wt -Leaf) -like "localenv-$e-sb*") {
    try { & $KitCmd.dev wt remove -Dir $wt -Force *>&1 | Out-Null } catch { Write-Host "[$e] dev.ps1 wt remove $wt : $_ - removing by path" }
    if (Test-Path $wt) {
      git -C $r.cfg.checkout worktree prune 2>$null | Out-Null
      foreach ($l in @(Get-DirLinks $wt 6 | Sort-Object { $_.FullName.Length } -Descending)) { try { if ($KitIsWindows) { [IO.Directory]::Delete($l.FullName) } else { Remove-DirLink $l.FullName } } catch { } }
      if (@(Get-DirLinks $wt 6).Count) { Write-Host "[$e] $wt still holds links: left in place (never deleting through a link)" }
      else { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  git -C $r.cfg.checkout branch -D "localenv/$e-$key" 2>$null | Out-Null
  foreach ($n in @($sbx.services)) { Remove-Item (Join-Path (Get-KitPath localenv) "run/$e/$n") -Recurse -Force -ErrorAction SilentlyContinue }   # its staged jars
  Update-State $e { param($x) $x.sandboxes.Remove($key); $x.holds.Remove("sandbox-$key"); foreach ($n in @($sbx.services)) { $x.services.Remove($n) } }
  Event $e 'sandbox-removed' @{ sandbox = $key; branch = $sbx.branch }
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
  if (Owned $x) { $ids += TreeIds ([int]$x.pid) $all }
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
  $mine = @(); if (Owned $x) { $mine = TreeIds ([int]$x.pid) }
  if (Owned $x) {
    if ($KitIsWindows) { taskkill /PID $x.pid /T /F 2>&1 | Out-Null }
    else { $ids = TreeIds ([int]$x.pid); [array]::Reverse($ids); $ids | ForEach-Object { Stop-SysProcess $_ } }
  }
  # a listener on the port is killed only when it is the env's own (its tree, or it runs from the env's copies / worktrees)
  if ($s.port) { foreach ($p in Get-PortPids ([int]$s.port)) { if ($p -gt 4 -and ($p -in $mine -or (EnvProcess $p $e))) { Stop-SysProcess $p } } }
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
function KeepFreeGB { if ($env:CLAUDE_GATE_KEEP_FREE_GB) { return [double]$env:CLAUDE_GATE_KEEP_FREE_GB }; $m = Get-SysMem; [double](Get-KitSetting 'localEnv.keepFreeGB' (Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($m.TotalGB * 0.15, 1))))) }
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
  if ($s.port -and (Test-PortListening ([int]$s.port))) {
    $holder = @(Get-PortPids ([int]$s.port)) -join ','
    Update-State $e { param($x) $x.services[$s.name].status = 'failed'; $x.services[$s.name].why = "port $($s.port) held by pid $holder (not started by the env)" }
    throw "[$e] $($s.name): port $($s.port) is held by pid $holder, which the env did not start: stop it or change the port"
  }
  # one start at a time machine-wide (across envs): the RAM check and the ramp-up of the previous start must not overlap
  $mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { 'Global\kit-localenv-start' } else { 'kit-localenv-start' }))
  $got = $false
  try { $got = $mx.WaitOne([TimeSpan]::FromMinutes(45)) } catch [Threading.AbandonedMutexException] { $got = $true }
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
    Update-State $e { param($x) $o = $x.services[$s.name]; $x.services[$s.name] = @{ status = 'starting'; pid = $p; pstart = "$(if (PStart $p) { (PStart $p).ToString('o') })"; port = $s.port; startedAt = (Now); lastNeed = (Now); release = $release; artifact = $artifact; restarts = @($o.restarts) } }
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
  } finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
}

# ---------------------------------------------------------------- _daemon: the per-env controller (started by this script, never by hand)
# Controller of one local env; started by localenv.ps1, never by hand. Model: ../SKILL.md.
#   localenv.ps1 _daemon -Env <env>               env loop: lifecycle (stop idle / under pressure, start what is needed, restart crashes),
#                                          sandbox upkeep, one train worker at a time. One per env (mutex); exits after loopExitMinutes idle.
#   localenv.ps1 _daemon -Env <env> -Train <id>   train worker: sandbox routing (HEAVY migrations), merge, gated build, culprit search, stage,
#                                          lease waits, exact revert of leaving LIGHT migration layers, DB snapshot (HEAVY), switch-over,
#                                          smoke, rollback, release record.
# Logs: <logs>/<env>-loop.log, <env>-train.log, <env>-events.jsonl.
function Invoke-Daemon {
param([Parameter(Mandatory)][Alias('Env')][string]$EnvName, [string]$Train)
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
      $wp = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -NonInteractive -File `"$PSCommandPath`" _daemon -Env $e -Train $tid" -WindowStyle Hidden -PassThru
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
}

# ---------------------------------------------------------------- the local-env commands
# Local environments: ONE shared running instance per configured env (API, web dev server, workers, Metro, search, ...) on this
# machine, that agents deploy their branches to and test against. Optional: used when the owner or a brief asks for a local
# check. Stack-agnostic: a service is a start command in a folder (default from dev-kit dev.ps1 stack `run`).
#
#   $L = '<workspace>/.claude/skills/local-env/localenv.ps1'
#   & $L envs                                             # configured envs and services
#   & $L status  [-Env <env>] [-Agent <id>] [-Json]       # release, services (state, why needed, idle), train, queue, leases
#   & $L deploy  -Env <env> -Agent <id> (-Dir <worktree> | -Branch <b> [-Repo r,..]) [-Wait 8]   # request; your branch joins the next train
#   & $L wait    -Env <env> -Id <request> [-Wait 8]       # until a request is done (call again when it says "still")
#   & $L use     -Env <env> -Agent <id> [-Services api,web] [-Minutes 30] [-Session <board token>] [-Note "<checks>"]
#   & $L release -Env <env> -Agent <id>
#   & $L promote -Env <env> -Agent <id> -Branch <b> [-Note "<passed>"]
#   & $L task    -Env <env> -Task <name> -Agent <id>      # a configured one-shot command on the env's code (APK, DB reset, ...)
#   & $L migrations -Env <env> [-Branch <b> | -Dir <worktree>]   # LIGHT/HEAVY per changeSet + revert plan (dry run, no deploy)
#   & $L logs    -Env <env> -Service <s> [-Tail 80];  & $L events -Env <env> [-Tail 30]
#   owner / coordinator:
#   & $L up      -Env <env> [-Services ..] [-Minutes 120] # hold services up (a person working in the browser)
#   & $L down    -Env <env> [-Services ..]                # stop now: drops holds and leases on them, ignores browser traffic 30 min
#   & $L drop    -Env <env> -Branch <b>;  & $L refresh -Env <env>   # remove a layer / rebuild everything on the latest targets
#
# Model, lifecycle, leases, trains, sandboxes: ../SKILL.md. Calls return within -Wait min (8); requests keep going in the controller.
function Invoke-LocalEnv {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('envs', 'status', 'deploy', 'wait', 'use', 'release', 'promote', 'task', 'logs', 'events', 'migrations', 'up', 'down', 'drop', 'refresh', '_exec')][string]$Action,
  [Alias('Env')][string]$EnvName,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }),
  [string]$Branch, [string[]]$Repo, [string]$Dir, [string[]]$Services, [string]$Service, [string]$Task, [string]$Note, [string]$Id,
  [string]$Session, [string]$Artifact,
  [int]$Minutes = 0, [double]$Wait = 8, [int]$Tail = 80, [switch]$Json
)
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
  $null = Start-Process -FilePath $pwsh -ArgumentList "-NoProfile -NonInteractive -File `"$PSCommandPath`" _daemon -Env $e" -WindowStyle Hidden -PassThru
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
# the header's exit codes for a queued request: a refused / rejected / rolled-back deploy used to exit 0
function Exit-Request($r) { if ($r -and $r.status -ne 'done') { exit 3 }; if ($r -and "$($r.result.outcome)" -match '(?i)refus|reject|error|roll|fail') { exit 1 } }
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
      foreach ($s in EnvServices $n) { '  {0,-14} {1,-28}{2}{5}{3}{4}' -f $s.name, $(if ($s.repo) { "$($s.repo)/$($s.dir)" } else { 'external' }), $(if ($s.port) { "  :$($s.port)" }), $(if ($s.dependsOn) { "  needs $(@($s.dependsOn) -join ',')" }), $(if ($s.hot) { '  hot' } elseif ($s.artifact) { '  runs from artifact' }), $(if ($s.debugPort) { "  debug :$($s.debugPort)" }) }
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
      if (@(git -C $Dir status --porcelain --untracked-files=no).Count) { Write-Warning "$Dir has uncommitted changes: only committed work is deployed (dev.ps1 wt commit first)" }
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
    Exit-Request (Wait-Request $rid)
  }
  'drop' { if (-not $Branch) { throw 'drop needs -Branch' }; $rid = New-Request @{ kind = 'drop'; branch = $Branch }; "[$e] drop $Branch queued as $rid"; Exit-Request (Wait-Request $rid) }
  'refresh' { $rid = New-Request @{ kind = 'refresh'; branch = '' }; "[$e] refresh queued as $rid"; Exit-Request (Wait-Request $rid) }
  'wait' { if (-not $Id) { throw 'wait needs -Id <request>' }; Exit-Request (Wait-Request $Id) }
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
      Exit-Request (Wait-Request $rid)
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
        if ($t.gated) { & $KitCmd.dev gate -Dir $dir -Cmd $cmd }
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
}

if ($MyInvocation.InvocationName -eq '.') { }   # dot-sourced (tests): functions only
elseif ($__verb -eq '_daemon') { Invoke-KitVerb Invoke-Daemon @($args | Select-Object -Skip 1) }
elseif (-not $__verb) { Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1; exit 2 }
else { Invoke-KitVerb Invoke-LocalEnv @($args) }