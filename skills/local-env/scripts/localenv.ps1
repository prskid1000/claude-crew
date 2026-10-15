#Requires -Version 7
<#
The local environment: ONE shared, always-on running instance per configured environment (an app's API, web dev server,
workers, Metro, ...) on this machine, that every agent deploys its branch to and tests or debugs against. Stack-agnostic:
each service is a start command in a folder (Java/Spring, .NET, Node/React/Angular, Python, Go, React Native, ...).

  $L = '<workspace>/.claude/skills/local-env/scripts/localenv.ps1'
  & $L envs                                              # configured environments and their services
  & $L status  [-Env <env>] [-Json]                      # services (up/down, port, RAM), layers, leases, deploy queue
  & $L up      -Env <env> [-Service <s>]                  # start whatever is not running (idempotent; one instance per env)
  & $L use     -Env <env> -Agent <id> [-Minutes 15] [-Note "<what>"]   # shared lease while you test/debug (waits out a deploy)
  & $L release -Env <env> -Agent <id>
  & $L deploy  -Env <env> -Agent <id> (-Dir <your worktree> | -Branch <branch> [-Repo <repo>,...])   # add/update your layer
  & $L promote -Env <env> -Branch <branch> -Agent <id> [-Note "<what passed>"]   # your layer passed its local checks (pre-staging gate)
  & $L drop    -Env <env> -Branch <branch>               # remove a layer (redeploys without it)
  & $L refresh -Env <env>                                # rebuild every repo from its latest target + the current layers
  & $L task    -Env <env> -Task <name> -Agent <id>       # run a configured one-shot task from the env's code (build an APK, reset a DB, ...)
  & $L logs    -Env <env> -Service <s> [-Tail 80]
  & $L down    -Env <env> [-Service <s>]

Flow: dev (each agent's own worktree + branch) -> local (this env: target branch + every deployed agent branch merged on top
as a "layer") -> the test environments -> production. The env's code lives in one worktree per repo
(<worktree root>/localenv-<env>-<repo>, local branch localenv/<env>, never pushed: the guard hook blocks it). It is never the
source of an MR: code moves on only through each agent's own branch. A layer whose branch merged into the target drops itself.
The env is the pre-staging step: a branch is "promoted locally" (`promote`) once its checks passed here, with the other layers
running beside it; that stamp is what lets it go on to merge and the test environments.

Sharing (a readers/writer lock per env, state in Get-KitPath localenv /<env>.json):
- readers: `use` takes a lease (default 15 min, renew by calling `use` again; `release` when done). `use` waits while a deploy
  runs or is queued, so a test never sees half-deployed code.
- writers: deploy / drop / refresh / up / down / task-free starts queue first come first served (a queued writer stops new
  leases), wait for open leases to end (localEnv.drainMinutes, default 10; then they go ahead and say so), merge, build through
  the memory gate (gate.ps1), restart only the services of the repos that changed, wait for their health check.
  A queued or running writer whose process died is dropped automatically.
- a deploy whose build or health check fails is rolled back (the env redeploys without that layer); a layer that conflicts is
  refused with the conflicting files. Hot services (hot: true, e.g. a web dev server) are not restarted: they reload.
- a layer that touches migrations (localEnv.migrationPattern) is flagged: dropping it does not undo its schema change.

Resources: builds go through gate.ps1 (learned per-project RAM). A service start waits until available RAM minus the service's
need (learned peak per env/service, else ramGB, else a per-stack default) stays above the gate's keep-free floor and CPU is
below localEnv.cpuMaxPct; starts are one at a time machine-wide. Running services, emulators and builds all use live RAM, so
the gate, the phone lanes and this script see each other's load.

Config: kit.local.json "localEnv" (skills/dev-kit/reference/configuration.md). Secrets (DB passwords, cloud keys) go in a
dotenv file per env: envFile, default Get-KitPath localenv-env /<env>.env (git-ignored); never in kit.local.json.
Placeholders in start/build/health/task commands and env values: {port} {dir} {wt} {env} {kit} {workspace} {lanIp}.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('envs', 'status', 'up', 'use', 'release', 'deploy', 'promote', 'drop', 'refresh', 'task', 'logs', 'down', '_exec')][string]$Action,
  [Alias('Env')][string]$EnvName,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }),
  [string]$Branch, [string[]]$Repo, [string]$Dir, [string]$Service, [string]$Task, [string]$Note,
  [int]$Minutes = 0, [int]$Tail = 80, [switch]$Json, [switch]$Force
)
$ErrorActionPreference = 'Stop'
$DK = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit/scripts'
. (Join-Path $DK 'sysinfo.ps1')
. (Join-Path $DK 'kitconfig.ps1')
$Repo = @(Split-KitList $Repo)

# ---------------------------------------------------------------- config
$LE = Get-KitValue 'localEnv' $null
function Opt([string]$k, $def) { $v = Get-KitSetting "localEnv.$k" $null; if ($null -eq $v) { $def } else { $v } }
$LeaseMin = [int](Opt 'leaseMinutes' 15)
$DrainMin = [int](Opt 'drainMinutes' 10)
$CpuMax = [int](Opt 'cpuMaxPct' 90)
$RoomWaitMin = [int](Opt 'roomWaitMinutes' 30)
# log lines that mean a start failed for good, whatever keeps the process alive (Spring devtools, a watcher): fail fast
$FailPattern = [string](Opt 'failPattern' 'APPLICATION FAILED TO START|Application run failed|EADDRINUSE|Address already in use|Port \d+ is already in use|Failed to bind to|Unhandled exception. System\.|Traceback \(most recent call last\)|panic: |Error: Cannot find module')
$MigPattern = [string](Opt 'migrationPattern' '(?i)(^|/)(db/)?(changelog|migrations?|liquibase|flyway|alembic)(/|\.)')
function Now { (Get-Date).ToString('o') }
function EnvNames { if ($LE -and $LE.envs) { @($LE.envs.PSObject.Properties.Name) } else { @() } }
# Envs run side by side, so a port belongs to exactly one service across ALL envs. The only sharing allowed: external infra
# (external: true) that every env declares with the same start command (or none), e.g. one database server for every env.
function Test-PortClash {
  $by = @{}
  foreach ($n in EnvNames) { foreach ($s in @($LE.envs.$n.services | Where-Object { $_ -and $_.port })) { $by["$($s.port)"] = @($by["$($s.port)"]) + @([pscustomobject]@{ who = "$n/$($s.name)"; external = [bool]$s.external; start = [string]$s.start }) | Where-Object { $_ } } }
  foreach ($port in $by.Keys) {
    $u = @($by[$port]); if ($u.Count -lt 2) { continue }
    if (@($u | Where-Object { -not $_.external }).Count -or @($u.start | Select-Object -Unique).Count -gt 1) { "port $port is claimed by $(($u.who) -join ', ')" }
  }
}
if (-not (EnvNames).Count -and $Action -ne 'envs') { throw 'No local environments configured: add "localEnv": { "envs": { "<env>": { "services": [...] } } } to kit.local.json (see skills/dev-kit/reference/configuration.md).' }
$clash = @(Test-PortClash)
if ($clash.Count) { $m = "localEnv port clash (envs run side by side; give each service its own port): $($clash -join '; ')"; if ($Action -in 'envs', 'status', 'logs', 'release', '_exec') { Write-Warning $m } else { throw $m } }
if (-not $EnvName -and $Action -notin 'envs', 'status') {
  if ((EnvNames).Count -eq 1) { $EnvName = (EnvNames)[0] } else { throw "-Env needed: $((EnvNames) -join ', ')" }
}
function Get-EnvCfg([string]$e) { $c = $LE.envs.$e; if (-not $c) { throw "unknown env '$e' (configured: $((EnvNames) -join ', '))" }; $c }
function Get-RepoCfg([string]$name) {
  $r = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1
  if (-not $r) { throw "repo '$name' is not in kit.local.json repos[] (name or alias)" }
  $r
}
function Services([string]$e) { @((Get-EnvCfg $e).services | Where-Object { $_ }) }
function Svc([string]$e, [string]$n) { $s = Services $e | Where-Object name -eq $n; if (-not $s) { throw "env $e has no service '$n' ($((Services $e).name -join ', '))" }; $s }
# repos the env runs from: name -> { cfg, target, wt }
function EnvRepos([string]$e) {
  $map = [ordered]@{}
  $items = @(Services $e) + @(if ((Get-EnvCfg $e).tasks) { (Get-EnvCfg $e).tasks.PSObject.Properties.Value })
  foreach ($s in $items | Where-Object { $_.repo }) {
    $r = Get-RepoCfg $s.repo
    $t = if ($s.target) { [string]$s.target } else { [string]$r.target }
    if ($map.Contains($r.name)) { if ($map[$r.name].target -ne $t) { throw "env $e uses repo $($r.name) with two targets ($($map[$r.name].target), $t): one env = one target per repo" }; continue }
    $map[$r.name] = [pscustomobject]@{ name = $r.name; cfg = $r; target = $t; wt = (Join-Path @($KitConf.WorktreeRoots)[0] "localenv-$e-$(Split-Path $r.checkout -Leaf)") }
  }
  $map
}
function SvcDir([string]$e, $s) {
  if (-not $s.repo) { return $(if ($s.dir) { $s.dir } else { $KitConf.Workspace }) }
  $wt = (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt
  if ($s.dir) { Join-Path $wt $s.dir } else { $wt }
}
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
function Expand([string]$t, [string]$e, $s, [string]$dir) {
  if (-not $t) { return $t }
  $wt = if ($s.repo) { (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt } else { '' }
  $t.Replace('{port}', "$($s.port)").Replace('{dir}', $dir).Replace('{wt}', $wt).Replace('{env}', $e).Replace('{kit}', $KitConf.Kit).Replace('{workspace}', $KitConf.Workspace).Replace('{lanIp}', $(if ($t -match '\{lanIp\}') { LanIp } else { '' }))
}
$script:stacks = @{}
function StackOf([string]$dir) {
  if (-not $script:stacks.ContainsKey($dir)) { $script:stacks[$dir] = try { & (Join-Path $DK 'stack.ps1') -Dir $dir -Json | ConvertFrom-Json } catch { $null } }
  $script:stacks[$dir]
}
function StartCmd([string]$e, $s) {
  $dir = SvcDir $e $s
  $c = if ($s.start) { [string]$s.start } else { (StackOf $dir).commands.run }
  if (-not $c) { throw "service $e/$($s.name): no start command (set services[].start, or commands.run in a .claude-stack.json in $dir)" }
  Expand $c $e $s $dir
}
# dotenv file (KEY=VALUE, '#' comments, optional 'export ', optional quotes) + the service's own env map
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
  foreach ($k in @($v.Keys)) { $v[$k] = Expand $v[$k] $e $item $dir }
  $v
}
function With-Env($vars, [scriptblock]$body) {
  $old = @{}; foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  try { & $body } finally { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
}
function LogFile([string]$e, [string]$n) { Join-Path (Get-KitPath localenv-logs -Create) "$e-$n.log" }

# ---------------------------------------------------------------- state (one JSON per env, locked writes)
function StateFile([string]$e) { Join-Path (Get-KitPath localenv -Create) "$e.json" }
function Read-State([string]$e) {
  $f = StateFile $e; $s = $null
  if (Test-Path $f) { try { $s = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "localenv: $f unreadable, starting a fresh state ($_)" } }
  if ($s -isnot [hashtable]) { $s = @{} }
  foreach ($k in 'services', 'layers', 'leases') { if ($s[$k] -isnot [hashtable]) { $s[$k] = @{} } }
  if ($null -eq $s.queue) { $s.queue = @() }; $s.queue = @($s.queue | Where-Object { $_ })
  if ($null -eq $s.version) { $s.version = 0 }
  $s
}
function Update-State([string]$e, [scriptblock]$Change) {
  $f = StateFile $e
  # $__state, not $s: the callers' scriptblocks read their own $s (a service) through PowerShell's dynamic scoping
  Invoke-KitLocked $f {
    $__state = Read-State $e
    & $Change $__state
    $__state | ConvertTo-Json -Depth 8 | Set-Content "$f.tmp" -Encoding utf8
    Move-Item "$f.tmp" $f -Force
  }
}
function Alive($p) { $p -and [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function Prune($s) {
  $s.queue = @($s.queue | Where-Object { Alive $_.pid })
  if ($s.writer -and -not (Alive $s.writer.pid)) { $s.writer = $null }
  foreach ($a in @($s.leases.Keys)) { if ([datetime]$s.leases[$a].until -lt (Get-Date)) { $s.leases.Remove($a) } }
}

# Writer: queue (FIFO), become the writer, drain leases. Returns the writer id; Exit-Writer in a finally.
function Enter-Writer([string]$e, [string]$op) {
  $id = [guid]::NewGuid().ToString('n').Substring(0, 8)
  Update-State $e { param($s) $s.queue = @($s.queue) + @(@{ id = $id; agent = $Agent; op = $op; pid = $PID; at = (Now) }) }
  $until = (Get-Date).AddMinutes(90); $said = $null; $o = @{ got = $false }
  try {
    while ($true) {
      Update-State $e { param($s)
        Prune $s
        if (-not $s.writer -and @($s.queue)[0].id -eq $id) { $s.writer = @($s.queue)[0]; $s.queue = @($s.queue | Select-Object -Skip 1); $o.got = $true }
        else { $o.ahead = @($s.writer) + @($s.queue | Where-Object { $_.id -ne $id } | Select-Object -First ([array]::IndexOf(@($s.queue.id), $id))) | Where-Object { $_ } | ForEach-Object { "$($_.agent):$($_.op)" } }
      }
      if ($o.got) { break }
      $msg = "waiting for $($o.ahead -join ', ')"; if ($msg -ne $said) { "[$e] $msg"; $said = $msg }
      if ((Get-Date) -gt $until) { throw "[$e] still queued after 90 min behind $($o.ahead -join ', ')" }
      Start-Sleep 5
    }
  } catch { Update-State $e { param($s) $s.queue = @($s.queue | Where-Object { $_.id -ne $id }) }; throw }
  # drain: leases other than mine end, or the drain time runs out
  $end = (Get-Date).AddMinutes($DrainMin); $said = $null
  while ($true) {
    $st = Read-State $e; Prune $st
    $others = @($st.leases.Keys | Where-Object { $_ -ne $Agent })
    if (-not $others) { break }
    if ((Get-Date) -gt $end) { "[$e] lease(s) of $($others -join ', ') still open after $DrainMin min: going ahead (they see the new version in status)"; break }
    $msg = "waiting for lease(s) of $($others -join ', ') to end (max $DrainMin min)"; if ($msg -ne $said) { "[$e] $msg"; $said = $msg }
    Start-Sleep 5
  }
  $id
}
function Exit-Writer([string]$e, [string]$id, [switch]$Bump) {
  Update-State $e { param($s) if ($s.writer -and $s.writer.id -eq $id) { $s.writer = $null }; if ($Bump) { $s.version = [int]$s.version + 1; $s.deployedAt = (Now) } }
}

# ---------------------------------------------------------------- code: worktrees and layers
function G([string]$d) { $o = & git -C $d @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' ') in $d : $o" }; $o }
$NoHooks = Join-Path (Get-KitPath localenv -Create) '.no-hooks'   # local-only merge commits on localenv/<env>, never pushed: no repo hooks
function Ensure-Worktree([string]$e, $r) {
  if (Test-Path (Join-Path $r.wt '.git')) { return }
  "[$e] creating worktree $($r.wt) ($($r.name) @ $($r.target))"
  & (Join-Path $DK 'wt.ps1') new -Repo $r.cfg.checkout -Branch "localenv/$e" -Target $r.target -Name "localenv-$e" | ForEach-Object { "  $_" }
}
# The dependency source of a target (kit.local.json repos[].linkFromByTarget / linkFrom, else the main checkout) can change
# (e.g. a clean install per target branch replaces a mismatched one): re-point the env worktree's node_modules / .venv links
# at it, so the env never runs on another branch's installs. Nothing is installed here.
function Sync-DepLinks([string]$e, $r) {
  $c = $r.cfg
  $src = if ($c.linkFromByTarget -and $c.linkFromByTarget.($r.target)) { [string]$c.linkFromByTarget.($r.target) } elseif ($c.linkFrom -and $r.target -eq $c.target) { [string]$c.linkFrom } else { [string]$c.checkout }
  if (-not (Test-Path $src)) { Write-Warning "[$e] dependency source $src for $($r.name) @ $($r.target) does not exist"; return }
  $src = (Resolve-Path $src).Path
  foreach ($l in Get-DirLinks $r.wt 4 | Where-Object { $_.Name -in 'node_modules', '.venv' }) {
    $rel = [IO.Path]::GetRelativePath($r.wt, $l.FullName)
    $want = Join-Path $src $rel
    $now = "$(@($l.Target)[0])".TrimEnd('\', '/')
    if (-not (Test-Path $want) -or $now -eq $want.TrimEnd('\', '/')) { continue }
    Remove-DirLink $l.FullName; New-DirLink $l.FullName $want
    "[$e] $($r.name): $rel now links $want"
  }
}
function Resolve-Ref([string]$d, [string]$b) {
  foreach ($ref in "refs/heads/$b", "refs/remotes/origin/$b") { $x = git -C $d rev-parse -q --verify "$ref^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() } }
  git -C $d fetch -q origin $b 2>$null | Out-Null
  $x = git -C $d rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() }
  $null
}
# Rebuild one repo's env branch: latest target + layers in order. Returns @{ kept; dropped=@(@{layer; why}) }.
function Sync-Repo([string]$e, $r, [object[]]$layers) {
  Ensure-Worktree $e $r
  Sync-DepLinks $e $r
  $d = $r.wt
  $dirty = @(git -C $d status --porcelain --untracked-files=no)
  if ($dirty.Count -and -not $Force) { throw "[$e] $d has uncommitted edits ($($dirty.Count) files): commit them on your own branch and deploy that, or pass -Force to discard them" }
  New-Item -ItemType Directory -Force $NoHooks | Out-Null
  G $d fetch -q origin $r.target | Out-Null
  G $d reset -q --hard "origin/$($r.target)" | Out-Null
  $kept = @(); $dropped = @()
  foreach ($l in $layers) {
    $sha = if ($l.sha -and $(git -C $d cat-file -e "$($l.sha)^{commit}" 2>$null; $LASTEXITCODE -eq 0)) { $l.sha } else { Resolve-Ref $d $l.branch }
    if (-not $sha) { $dropped += @{ layer = $l; why = 'branch and commit gone' }; continue }
    git -C $d merge-base --is-ancestor $sha "origin/$($r.target)" 2>$null
    if ($LASTEXITCODE -eq 0) { $dropped += @{ layer = $l; why = "merged into $($r.target)" }; continue }
    $out = git -C $d -c "core.hooksPath=$NoHooks" -c user.name=localenv -c user.email=localenv@localhost merge -q --no-ff --no-edit -m "localenv layer $($l.branch) ($($l.agent))" $sha 2>&1
    if ($LASTEXITCODE) {
      $files = @(git -C $d diff --name-only --diff-filter=U 2>$null)
      git -C $d merge --abort 2>$null | Out-Null; git -C $d reset -q --hard HEAD 2>$null | Out-Null
      $dropped += @{ layer = $l; why = "conflicts with $($r.target) + earlier layers: $(($files | Select-Object -First 8) -join ', ')$(if (-not $files) { "$out" })" }; continue
    }
    $l.sha = $sha; $kept += $l
  }
  @{ kept = $kept; dropped = $dropped }
}

# ---------------------------------------------------------------- processes
function TreeIds([int]$root) {
  $all = Get-SysProcs -NoCommandLine; $ids = @($root); $i = 0
  while ($i -lt $ids.Count) { $ids += @($all | Where-Object { $_.ParentId -eq $ids[$i] -and $_.Id -notin $ids } | ForEach-Object Id); $i++ }
  $ids
}
function TreeGB($svcState) {
  $ids = @(); if (Alive $svcState.pid) { $ids += TreeIds ([int]$svcState.pid) }
  if ($svcState.port) { $ids += @(Get-PortPids ([int]$svcState.port)) }
  $ids = $ids | Select-Object -Unique; if (-not $ids) { return 0 }
  [math]::Round(((Get-SysProcs -NoCommandLine | Where-Object { $_.Id -in $ids } | Measure-Object WorkingSet -Sum).Sum) / 1GB, 2)
}
function Healthy([string]$e, $s) {
  if ($s.health) {
    try { $r = Invoke-WebRequest (Expand $s.health $e $s (SvcDir $e $s)) -TimeoutSec 5 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; return $r.StatusCode -gt 0 -and $r.StatusCode -lt 500 } catch { return $false }
  }
  if ($s.port) { return Test-PortListening ([int]$s.port) }
  $st = (Read-State $e).services[$s.name]; Alive $st.pid
}
function Stop-Svc([string]$e, $s) {
  $st = (Read-State $e).services[$s.name]
  if (Alive $st.pid) {
    if ($KitIsWindows) { taskkill /PID $st.pid /T /F 2>&1 | Out-Null }
    else { $ids = TreeIds ([int]$st.pid); [array]::Reverse($ids); $ids | ForEach-Object { Stop-SysProcess $_ } }
  }
  if ($s.port) { foreach ($p in Get-PortPids ([int]$s.port)) { if ($p -gt 4) { Stop-SysProcess $p } } }   # the env owns its ports
  Update-State $e { param($x) $x.services[$s.name] = @{ status = 'down'; port = $s.port; at = (Now) } }
}
# History of real footprints: <cache>/localenv-history.json { "<env>/<svc>": [gb, ...] }
function Need-GB([string]$e, $s) {
  if ($s.ramGB) { return [double]$s.ramGB }
  $h = try { Get-Content (Get-KitPath localenv-history) -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
  $xs = @($h["$e/$($s.name)"] | Where-Object { $_ })
  if ($xs.Count) { return [math]::Round(($xs | Measure-Object -Maximum).Maximum * 1.15, 1) }
  $st = if ($s.repo -or $s.dir) { "$((StackOf (SvcDir $e $s)).stack)" } else { '' }
  switch -regex ($st) { '^java|^gradle|^android' { 3 } '^angular' { 3 } '^dotnet' { 1.5 } '^node|^react' { 1.5 } '^python|^go|^rust' { 0.5 } default { 1 } }
}
function Save-Footprint([string]$e, $s, [double]$gb) {
  if ($gb -le 0) { return }
  $f = Get-KitPath localenv-history -Create
  Invoke-KitLocked $f {
    $h = try { Get-Content $f -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if ($h -isnot [hashtable]) { $h = @{} }
    $k = "$e/$($s.name)"; $h[$k] = @(@($h[$k] | Where-Object { $_ }) + $gb | Select-Object -Last 5)
    $h | ConvertTo-Json -Depth 4 | Set-Content $f -Encoding utf8
  }
}
# Wait until the machine has room: RAM above the gate's keep-free floor after this service's need, CPU below cpuMaxPct.
function Wait-Room([string]$e, $s) {
  $need = Need-GB $e $s
  $m = Get-SysMem
  $keep = [double](Get-KitSetting 'localEnv.keepFreeGB' (Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($m.TotalGB * 0.15, 1)))))
  $until = (Get-Date).AddMinutes($RoomWaitMin); $said = (Get-Date).AddMinutes(-5)
  while ($true) {
    $m = Get-SysMem; $cpu = Get-SysCpu
    $ramOk = ($m.AvailGB - $need) -ge $keep; $cpuOk = $cpu -lt $CpuMax
    if ($ramOk -and $cpuOk) { return }
    if ((Get-Date) -gt $until) {
      if (-not $ramOk) {
        $top = Get-SysProcs -NoCommandLine | Group-Object Name | ForEach-Object { [pscustomobject]@{ n = $_.Name; gb = [math]::Round(($_.Group | Measure-Object WorkingSet -Sum).Sum / 1GB, 1) } } | Sort-Object gb -Descending | Select-Object -First 6
        throw "[$e] no room to start $($s.name) after $RoomWaitMin min: needs $need GB + keep-free $keep GB, available $($m.AvailGB) GB. Biggest: $(($top | ForEach-Object { "$($_.n) $($_.gb)G" }) -join ', ')"
      }
      "[$e] CPU still $cpu% after $RoomWaitMin min: starting $($s.name) anyway"; return
    }
    if (((Get-Date) - $said).TotalSeconds -ge 60) { "[$e] waiting for room to start $($s.name): RAM avail $($m.AvailGB) GB (need $need + keep $keep), CPU $cpu% (max $CpuMax%)"; $said = Get-Date }
    Start-Sleep 10
  }
}
function Start-Svc([string]$e, $s) {
  $dir = SvcDir $e $s
  if (-not (Test-Path $dir)) { throw "[$e] $($s.name): folder $dir does not exist" }
  $cmd = StartCmd $e $s
  Stop-Svc $e $s
  # one start at a time machine-wide (across envs): the RAM check and the ramp-up of the previous start must not overlap
  $mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { 'Global\kit-localenv-start' } else { 'kit-localenv-start' }))
  try { $null = $mx.WaitOne([TimeSpan]::FromMinutes(45)) } catch [Threading.AbandonedMutexException] { }
  try {
    Wait-Room $e $s
    $log = LogFile $e $s.name; if (Test-Path $log) { Move-Item $log "$log.prev" -Force }
    "[$e] starting $($s.name): $cmd   (log $log)"
    $pwsh = (Get-Process -Id $PID).Path
    $a = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '_exec', '-Env', $e, '-Service', $s.name)
    $p = $null
    if ($KitIsWindows) { $p = (Start-Process -FilePath $pwsh -ArgumentList (($a | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { $_ } }) -join ' ') -WorkingDirectory $dir -WindowStyle Hidden -PassThru).Id }
    else {
      Start-Detached -FilePath $pwsh -ArgumentList $a -WorkingDirectory $dir -Log "$log.wrapper"
      Start-Sleep 1; $p = (Get-SysProcs | Where-Object { $_.CommandLine -match [regex]::Escape("_exec -Env $e -Service $($s.name)") } | Select-Object -First 1).Id
    }
    Update-State $e { param($x) $x.services[$s.name] = @{ status = 'starting'; pid = $p; port = $s.port; startedAt = (Now) } }
    $limit = (Get-Date).AddMinutes([double]$(if ($s.startMinutes) { $s.startMinutes } else { 10 }))
    $fail = if ($s.failPattern) { [string]$s.failPattern } else { $FailPattern }
    while (-not (Healthy $e $s)) {
      $hit = if ($fail -and (Test-Path $log)) { Select-String -LiteralPath $log -Pattern $fail -List | Select-Object -First 1 }
      if ($hit) { Stop-Svc $e $s; Update-State $e { param($x) $x.services[$s.name].status = 'failed' }; throw "[$e] $($s.name) failed to start (log line $($hit.LineNumber): $($hit.Line.Trim())). Log: $log`n$((Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n")" }
      if (-not (Alive $p)) { Update-State $e { param($x) $x.services[$s.name].status = 'failed' }; throw "[$e] $($s.name) exited while starting. Last log lines:`n$((Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n")" }
      if ((Get-Date) -gt $limit) { Stop-Svc $e $s; Update-State $e { param($x) $x.services[$s.name].status = 'failed' }; throw "[$e] $($s.name) not healthy within $(if ($s.startMinutes) { $s.startMinutes } else { 10 }) min ($(if ($s.health) { $s.health } else { "port $($s.port)" })). Last log lines:`n$((Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n")" }
      Start-Sleep 5
    }
    $gb = TreeGB @{ pid = $p; port = $s.port }; Save-Footprint $e $s $gb
    Update-State $e { param($x) $x.services[$s.name].status = 'up'; $x.services[$s.name].gb = $gb; $x.services[$s.name].upAt = (Now) }
    "[$e] $($s.name) up$(if ($s.port) { " on port $($s.port)" }) ($gb GB)"
  } finally { $mx.ReleaseMutex(); $mx.Dispose() }
}
function Build-Svc([string]$e, $s) {
  if (-not $s.build) { return }
  $dir = SvcDir $e $s; $cmd = Expand ([string]$s.build) $e $s $dir
  "[$e] building $($s.name): $cmd"
  With-Env (EnvVars $e $s) { & (Join-Path $DK 'gate.ps1') -Dir $dir -Cmd $cmd | ForEach-Object { "  $_" } }
  if ($LASTEXITCODE) { throw "[$e] build of $($s.name) failed (exit $LASTEXITCODE)" }
}
# Start everything that is not running, in config order (dependencies first). External services (external: true) are only
# started when they have a start command and are down; otherwise just reported.
function Up-All([string]$e, [string]$only) {
  foreach ($r in (EnvRepos $e).Values) {
    if (-not (Test-Path (Join-Path $r.wt '.git'))) {
      $st = Read-State $e
      $res = Sync-Repo $e $r @($st.layers[$r.name] | Where-Object { $_ })
      Update-State $e { param($x) $x.layers[$r.name] = @($res.kept) }
    } else { Sync-DepLinks $e $r }
  }
  foreach ($s in Services $e | Where-Object { -not $only -or $_.name -eq $only }) {
    if (Healthy $e $s) { continue }
    if ($s.external -and -not $s.start) { Write-Warning "[$e] $($s.name) is down and external with no start command: start it yourself ($(if ($s.port) { "port $($s.port)" }))"; continue }
    Build-Svc $e $s
    Start-Svc $e $s
  }
}

# ---------------------------------------------------------------- deploy / drop / refresh
function Apply-Layers([string]$e, [hashtable]$want, [string[]]$repos, [string]$newBranch) {
  $envRepos = EnvRepos $e; $changed = @(); $refused = @(); $notes = @()
  foreach ($rn in $repos) {
    $r = $envRepos[$rn]
    $res = Sync-Repo $e $r @($want[$rn])
    foreach ($d in $res.dropped) {
      if ($newBranch -and $d.layer.branch -eq $newBranch) { $refused += "$rn : $($d.why)" }
      else { $notes += "dropped layer $($d.layer.branch) ($($d.layer.agent)) from $rn : $($d.why)$(if ($d.layer.migrations) { ' - it had migrations: the local DB keeps them' })" }
    }
    Update-State $e { param($x) $x.layers[$rn] = @($res.kept) }
    $changed += $rn
  }
  @{ changed = $changed; refused = $refused; notes = $notes }
}
function Restart-Repos([string]$e, [string[]]$repoNames) {
  $names = @($repoNames | ForEach-Object { (Get-RepoCfg $_).name })
  foreach ($s in Services $e | Where-Object { $_.repo -and -not $_.external -and (Get-RepoCfg $_.repo).name -in $names }) {
    Build-Svc $e $s
    if ($s.hot -and (Healthy $e $s)) { "[$e] $($s.name) is hot-reloading the new code"; continue }
    Start-Svc $e $s
  }
}
function Deploy([string]$e) {
  $envRepos = EnvRepos $e
  if ($Dir) {
    $Dir = (Resolve-Path $Dir).Path
    $Branch = "$(git -C $Dir rev-parse --abbrev-ref HEAD)".Trim()
    $common = Split-Path "$(git -C $Dir rev-parse --path-format=absolute --git-common-dir)".Trim()
    $hit = $envRepos.Values | Where-Object { (Resolve-Path $_.cfg.checkout).Path -eq (Resolve-Path $common).Path } | Select-Object -First 1
    if (-not $hit) { throw "[$e] $Dir is not a worktree of a repo this env runs ($($envRepos.Keys -join ', '))" }
    $Repo = @($hit.name)
    if (@(git -C $Dir status --porcelain --untracked-files=no).Count) { Write-Warning "$Dir has uncommitted changes: only committed work is deployed (wt.ps1 commit first)" }
  }
  if (-not $Branch) { throw 'deploy needs -Dir <your worktree> or -Branch <branch>' }
  if ($Branch -match '^localenv/') { throw 'that is the env branch itself' }
  $targets = if ($Repo) { @($Repo | ForEach-Object { (Get-RepoCfg $_).name }) } else { @($envRepos.Values | Where-Object { Resolve-Ref $_.cfg.checkout $Branch } | ForEach-Object name) }
  $targets = @($targets | Where-Object { $envRepos.Contains($_) })
  if (-not $targets) { throw "[$e] branch $Branch not found in any repo of this env ($($envRepos.Keys -join ', '))" }
  $id = Enter-Writer $e "deploy $Branch"
  $ok = $false
  try {
    $st = Read-State $e
    $want = @{}; $before = @{}
    foreach ($rn in $targets) {
      $cur = @($st.layers[$rn] | Where-Object { $_ }); $before[$rn] = $cur
      $sha = Resolve-Ref $envRepos[$rn].cfg.checkout $Branch
      if (-not $sha) { throw "[$e] $Branch not found in $rn" }
      $mig = [bool](@(git -C $envRepos[$rn].cfg.checkout diff --name-only "origin/$($envRepos[$rn].target)...$sha" 2>$null) -match $MigPattern)
      $want[$rn] = @($cur | Where-Object { $_.branch -ne $Branch }) + @(@{ branch = $Branch; agent = $Agent; sha = $sha; at = (Now); migrations = $mig })
    }
    $res = Apply-Layers $e $want $targets $Branch
    $res.notes | ForEach-Object { "[$e] $_" }
    if ($res.refused) { Restart-Repos $e $res.changed; throw "[$e] $Branch refused: $($res.refused -join '; '). Rebase it onto the target (wt.ps1 sync) and resolve; the env kept the other layers." }
    try { Restart-Repos $e $targets; $ok = $true }
    catch {
      "[$e] deploy of $Branch failed: rolling back to the env without it"
      $back = @{}; foreach ($rn in $targets) { $back[$rn] = @($before[$rn] | Where-Object { $_.branch -ne $Branch }) }
      Apply-Layers $e $back $targets '' | Out-Null
      try { Restart-Repos $e $targets } catch { Write-Warning "[$e] rollback restart failed too: $_ (run localenv.ps1 up)" }
      throw
    }
  } finally { Exit-Writer $e $id -Bump:$ok }
  $v = (Read-State $e).version
  "[$e] deployed $Branch to $($targets -join ', ') - env version $v. Take a lease while testing: localenv.ps1 use -Env $e -Agent $Agent"
}
function Drop-Layer([string]$e) {
  if (-not $Branch) { throw 'drop needs -Branch' }
  $id = Enter-Writer $e "drop $Branch"; $ok = $false
  try {
    $st = Read-State $e; $want = @{}; $repos = @()
    foreach ($rn in @($st.layers.Keys)) { $l = @($st.layers[$rn] | Where-Object { $_ }); if ($l.branch -contains $Branch) { $want[$rn] = @($l | Where-Object { $_.branch -ne $Branch }); $repos += $rn; if (@($l | Where-Object { $_.branch -eq $Branch -and $_.migrations })) { Write-Warning "[$e] $Branch had migrations in $rn : the local DB keeps them" } } }
    if (-not $repos) { "[$e] no layer $Branch"; return }
    (Apply-Layers $e $want $repos '').notes | ForEach-Object { "[$e] $_" }
    Restart-Repos $e $repos; $ok = $true
    "[$e] dropped $Branch from $($repos -join ', ')"
  } finally { Exit-Writer $e $id -Bump:$ok }
}
function Refresh([string]$e) {
  $id = Enter-Writer $e 'refresh'; $ok = $false
  try {
    $st = Read-State $e; $want = @{}; $repos = @((EnvRepos $e).Keys)
    foreach ($rn in $repos) { $want[$rn] = @($st.layers[$rn] | Where-Object { $_ }) }
    (Apply-Layers $e $want $repos '').notes | ForEach-Object { "[$e] $_" }
    Restart-Repos $e $repos; $ok = $true
    "[$e] refreshed from the latest targets"
  } finally { Exit-Writer $e $id -Bump:$ok }
}

# ---------------------------------------------------------------- leases
function Use([string]$e) {
  $needUp = @(Services $e | Where-Object { -not (Healthy $e $_) -and -not ($_.external -and -not $_.start) })
  if ($needUp) { $id = Enter-Writer $e 'up'; try { Up-All $e '' } finally { Exit-Writer $e $id } }
  $until = (Get-Date).AddMinutes(90); $said = $null; $o = @{}
  while ($true) {
    $o.ok = $false
    Update-State $e { param($s)
      Prune $s
      if (-not $s.writer -and -not @($s.queue).Count) {
        $s.leases[$Agent] = @{ until = (Get-Date).AddMinutes($(if ($Minutes) { $Minutes } else { $LeaseMin })).ToString('o'); note = $Note; at = (Now) }; $o.ok = $true; $o.v = $s.version
      } else { $o.w = @(@($s.writer) + @($s.queue) | Where-Object { $_ } | ForEach-Object { "$($_.agent):$($_.op)" }) -join ', ' }
    }
    if ($o.ok) { break }
    if ($o.w -ne $said) { "[$e] waiting for $($o.w)"; $said = $o.w }
    if ((Get-Date) -gt $until) { throw "[$e] no lease after 90 min (writers: $($o.w))" }
    Start-Sleep 5
  }
  "[$e] lease for $Agent until $((Get-Date).AddMinutes($(if ($Minutes) { $Minutes } else { $LeaseMin })).ToString('HH:mm')) - env version $($o.v). Renew with use, end with release."
  Show-Status $e
}

# ---------------------------------------------------------------- status
function Show-Status([string]$e) {
  $st = Read-State $e; Prune $st
  $svc = foreach ($s in Services $e) {
    $x = $st.services[$s.name]; $h = Healthy $e $s
    $gb = if ($h) { TreeGB @{ pid = $x.pid; port = $s.port } } else { 0 }
    $listens = @()
    if ($h -and $KitIsWindows) {
      $ids = @(if (Alive $x.pid) { TreeIds ([int]$x.pid) }) + @(if ($s.port) { Get-PortPids ([int]$s.port) })
      $listens = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $ids } | ForEach-Object LocalPort | Sort-Object -Unique)
    }
    [pscustomobject]@{ service = $s.name; state = $(if ($h) { if ($x.pid -and (Alive $x.pid)) { 'up' } else { 'up (not started here)' } } elseif ($x.status -in 'starting', 'failed') { $x.status } else { 'down' }); port = $s.port; gb = $gb; url = $(if ($s.url) { Expand $s.url $e $s '' } elseif ($s.port) { "localhost:$($s.port)" }); repo = $s.repo; hot = [bool]$s.hot; external = [bool]$s.external; listens = $listens }
  }
  $layers = foreach ($rn in $st.layers.Keys) { foreach ($l in @($st.layers[$rn] | Where-Object { $_ })) { [pscustomobject]@{ repo = $rn; branch = $l.branch; agent = $l.agent; sha = "$($l.sha)".Substring(0, [math]::Min(9, "$($l.sha)".Length)); migrations = [bool]$l.migrations; promoted = [bool]$l.promoted; at = $l.at } } }
  $leases = foreach ($a in $st.leases.Keys) { [pscustomobject]@{ agent = $a; until = ([datetime]$st.leases[$a].until).ToString('HH:mm'); note = $st.leases[$a].note } }
  $o = [pscustomobject]@{ env = $e; version = $st.version; deployedAt = $st.deployedAt; writer = $(if ($st.writer) { "$($st.writer.agent): $($st.writer.op)" }); queue = @($st.queue | ForEach-Object { "$($_.agent): $($_.op)" }); services = @($svc); layers = @($layers); leases = @($leases); worktrees = @((EnvRepos $e).Values | ForEach-Object { "$($_.name) @ $($_.target): $($_.wt)" }) }
  if ($Json) { return $o }
  "== $e  version $($o.version)$(if ($o.writer) { "  | WRITING: $($o.writer)" })$(if ($o.queue) { "  | queued: $($o.queue -join ', ')" })"
  $o.services | ForEach-Object { '  {0,-14} {1,-22} {2,-24} {3,5} GB{4}{5}' -f $_.service, $_.state, $_.url, $_.gb, $(if ($_.hot) { '  hot' } elseif ($_.external) { '  external' }), $(if (@($_.listens | Where-Object { $_ -ne 0 }).Count -gt 1) { "  listens: $($_.listens -join '/')" }) }
  if ($o.layers) { '  layers:'; $o.layers | ForEach-Object { '    {0,-12} {1,-40} {2,-10} {3}{4}{5}' -f $_.repo, $_.branch, $_.agent, $_.sha, $(if ($_.promoted) { '  PROMOTED' } else { '  testing' }), $(if ($_.migrations) { '  MIGRATIONS' }) } } else { '  layers: none (targets only)' }
  if ($o.leases) { "  leases: $(($o.leases | ForEach-Object { "$($_.agent) until $($_.until)$(if ($_.note) { " ($($_.note))" })" }) -join '; ')" }
}

# ---------------------------------------------------------------- actions
switch ($Action) {
  'envs' {
    foreach ($n in EnvNames) {
      "$n$(if ((Get-EnvCfg $n).description) { " - $((Get-EnvCfg $n).description)" })"
      foreach ($s in Services $n) { '  {0,-14} {1}{2}{3}' -f $s.name, $(if ($s.repo) { "$($s.repo)/$($s.dir)" } else { 'external' }), $(if ($s.port) { "  :$($s.port)" }), $(if ($s.hot) { '  hot' }) }
      if ((Get-EnvCfg $n).tasks) { "  tasks: $((Get-EnvCfg $n).tasks.PSObject.Properties.Name -join ', ')" }
    }
  }
  'status' { $names = if ($EnvName) { @($EnvName) } else { EnvNames }; $all = foreach ($n in $names) { Show-Status $n }; if ($Json) { $all | ConvertTo-Json -Depth 6 } else { $all } }
  'up' {
    $miss = @(Services $EnvName | Where-Object { (-not $Service -or $_.name -eq $Service) -and -not (Healthy $EnvName $_) })
    if ($miss) { $id = Enter-Writer $EnvName 'up'; try { Up-All $EnvName $Service } finally { Exit-Writer $EnvName $id } }
    Show-Status $EnvName
  }
  'use' { Use $EnvName }
  'release' { Update-State $EnvName { param($s) $s.leases.Remove($Agent) }; "[$EnvName] released $Agent" }
  'deploy' { Deploy $EnvName; Show-Status $EnvName }
  'promote' {
    if (-not $Branch) { throw 'promote needs -Branch' }
    $o = @{ hit = @() }
    Update-State $EnvName { param($s) foreach ($rn in @($s.layers.Keys)) { foreach ($l in @($s.layers[$rn] | Where-Object { $_ })) { if ($l.branch -eq $Branch) { $l.promoted = @{ by = $Agent; at = (Now); version = $s.version; note = $Note }; $o.hit += $rn } } } }
    if (-not $o.hit) { throw "[$EnvName] $Branch is not deployed here: deploy it first (localenv.ps1 deploy), test, then promote" }
    "[$EnvName] $Branch promoted locally in $($o.hit -join ', ') (env version $((Read-State $EnvName).version))"
  }
  'drop' { Drop-Layer $EnvName; Show-Status $EnvName }
  'refresh' { Refresh $EnvName; Show-Status $EnvName }
  'down' {
    $id = Enter-Writer $EnvName 'down'
    try { foreach ($s in Services $EnvName | Where-Object { (-not $Service -or $_.name -eq $Service) -and -not $_.external }) { Stop-Svc $EnvName $s; "[$EnvName] $($s.name) stopped" } }
    finally { Exit-Writer $EnvName $id }
  }
  'logs' {
    if (-not $Service) { throw 'logs needs -Service' }
    $f = LogFile $EnvName $Service; if (Test-Path $f) { Get-Content $f -Tail $Tail } else { "no log yet: $f" }
  }
  'task' {
    $t = (Get-EnvCfg $EnvName).tasks.$Task
    if (-not $t) { throw "env $EnvName has no task '$Task' ($(((Get-EnvCfg $EnvName).tasks.PSObject.Properties.Name) -join ', '))" }
    Use $EnvName | Select-Object -First 1   # a lease keeps the code still while the task reads it
    try {
      $dir = SvcDir $EnvName $t
      $cmd = Expand ([string]$t.cmd) $EnvName $t $dir
      "[$EnvName] task $Task in $dir : $cmd"
      With-Env (EnvVars $EnvName $t) {
        if ($t.gated) { & (Join-Path $DK 'gate.ps1') -Dir $dir -Cmd $cmd }
        else { Push-Location $dir; try { if ($KitIsWindows) { & cmd.exe /d /s /c $cmd } else { & /bin/sh -c $cmd } } finally { Pop-Location } }
      }
      $code = $LASTEXITCODE
    } finally { Update-State $EnvName { param($s) $s.leases.Remove($Agent) } }
    if ($code) { throw "[$EnvName] task $Task failed (exit $code)" }
  }
  '_exec' {
    # internal: the detached wrapper of one service (env vars from the env file, output to its log)
    $s = Svc $EnvName $Service; $dir = SvcDir $EnvName $s; $log = LogFile $EnvName $Service
    $cmd = StartCmd $EnvName $s
    foreach ($kv in (EnvVars $EnvName $s).GetEnumerator()) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value) }
    Set-Location $dir
    Add-Content $log "== $(Now) start in $dir : $cmd"
    if ($KitIsWindows) { & cmd.exe /d /s /c "$cmd >> `"$log`" 2>&1" } else { & /bin/sh -c "$cmd >> '$log' 2>&1" }
    Add-Content $log "== $(Now) exited $LASTEXITCODE"
  }
}
