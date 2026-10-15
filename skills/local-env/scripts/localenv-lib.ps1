#Requires -Version 7
<#
Library dot-sourced by localenv.ps1 (CLI) and localenvd.ps1 (the per-env controller loop); never run by hand.
Config, state, layers/builds, processes, admission, leases and demand. See localenv.ps1 for the model.

State per env: Get-KitPath localenv /<env>.json, locked read-modify-write (Update-State). Fields:
  release   { n, at, train, repos: { <repo>: { target, targetSha, layers: [ { branch, agent, sha, migrations, mclass?, since?, mtag?, promoted? } ] } } }
            mclass = { class, effective: light|heavy, why[], count, manifest, ids[] } (Get-MigClass); since = release it went live in
  releases  [ last releases (summaries) ]
  services  { <svc>: { status: up|starting|down|failed|blocked, pid, port, release, artifact, startedAt, upAt, lastNeed, gb, restarts[], why } }
  leases    { <agent>: { services[], repos[], until, release, session, note, at } }
  holds     { <who>: { services[], until } }
  requests  [ { id, kind: deploy|drop|refresh|stop, agent, branch, repos[], at, status: queued|in-train|done, result{ outcome, release, message } } ]
  train     { id, pid, phase, requests[], blockServices[], blockRepos[], waitingFor[], at }   (while a train worker runs)
  sandboxes { sb<k>: { k, branch, agent, sha, repo, services[], at, lastUse, promoted? } }; snapshots [ { name, at, release, layers[] } ]
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
  $c = "$((Get-CimInstance Win32_Process -Filter "ProcessId=$p" -Property CommandLine -ErrorAction SilentlyContinue).CommandLine)"
  if (-not $KitIsWindows) { $c = "$(ps -o args= -p $p 2>$null)" }
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
  $out = & (Get-Python) -X utf8 (Join-Path $PSScriptRoot 'migrations.py') @a 2>> $errF
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
    With-Env (EnvVars $e $s) { & (Join-Path $script:DK 'gate.ps1') -Dir $dir -Cmd "$cmd > `"$log`" 2>&1" *>&1 | Select-String -Pattern '^\[gate\] (starting|waiting.*Biggest)' | ForEach-Object { Write-Host "  $_" } }
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
    & (Join-Path $script:DK 'wt.ps1') new -Repo $r.cfg.checkout -Branch "localenv/$e-$suffix" -Target $r.target -Name "localenv-$e-$suffix" | ForEach-Object { Write-Host "  $_" }
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
    With-Env (EnvVars $e $s) { & (Join-Path $script:DK 'gate.ps1') -Dir $d -Cmd "$cmd > `"$log`" 2>&1" *>&1 | Out-Null }
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
    try { & (Join-Path $script:DK 'wt.ps1') remove -Dir $wt -Force *>&1 | Out-Null } catch { Write-Host "[$e] wt.ps1 remove $wt : $_ - removing by path" }
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
