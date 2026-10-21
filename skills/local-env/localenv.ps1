<#
localenv.ps1: ONE shared local instance per env (kit.local.json localEnv.envs) that agents deploy branches to, test and debug
on; a service = a start command in a folder (default dev.ps1 stack `run`). Model: local-env SKILL.md "Local testing".
  & <kit>/skills/local-env/localenv.ps1 <verb> [args]
Verbs: envs · status · deploy · wait · use · release · promote · logs · events
       (owner) up -Services [-Owner] · unhold · down · drop · refresh · _daemon -Env <env> [-Train <id>] (controller) · _exec (service wrapper)
In: kit.local.json localEnv, .state/localenv/<env>.env (secrets). Out: text; status -Json.
Exit codes: 0 ok · 1 refused / rejected / rolled back / failed / services not up / needs an extra · 2 usage (unknown env, no
  localEnv) · 3 still running (wait -Id; use got no lease within -Wait).
Extras: sandboxes, exact migration reverts, tasks, sql = localenv-sandbox (this script forwards to it); db.engine = db-engine-presets.
Sections: L20 config · L126 state · L162 leases · L184 code · L278 hooks · L314 processes · L444 daemon/train · L763 verbs
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
# extra localenv-sandbox installed: its full variant (sandboxes, exact reverts, tasks, sql) runs instead
if ($MyInvocation.InvocationName -ne '.' -and (Test-Path (Join-Path $PSScriptRoot 'localenv-sandbox.ps1'))) { & (Join-Path $PSScriptRoot 'localenv-sandbox.ps1') @args; exit $LASTEXITCODE }
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---- library (dot-sourced by the CLI and _daemon); state per env: Get-KitPath localenv /<env>.json (Update-State)
$ErrorActionPreference = 'Stop'

# ---- config
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
$script:MigPattern = [string](Opt 'migrationPattern' '(?i)^(?!.*\.(md|txt|rst|adoc)$)(.*/)?(db/)?(changelog|migrations?|migrate|liquibase|flyway|alembic)(/|\.)')
# optional parts (kittool.py extra add <name>) are dot-sourced from adapters/ (db-engine-presets fills unset db hooks)
foreach ($__adapter in Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue) { . $__adapter.FullName }
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
  $s = EnvServices $e | Where-Object name -eq $n; if (-not $s) { throw "env $e has no service '$n' ($((EnvServices $e).name -join ', '))" }; $s
}
function Managed($s) { -not ($s.external -and -not $s.start) }
function Test-PortClash {
  $by = @{}
  foreach ($n in EnvNames) {
    foreach ($s in @($script:LE.envs.$n.services | Where-Object { $_ -and $_.port })) {
      $by["$($s.port)"] = @($by["$($s.port)"]) + @([pscustomobject]@{ who = "$n/$($s.name)"; external = [bool]$s.external; start = [string]$s.start }) | Where-Object { $_ }
      if ($s.debugPort) { $by["$($s.debugPort)"] = @($by["$($s.debugPort)"]) + @([pscustomobject]@{ who = "$n/$($s.name) (debug)"; external = $false; start = '' }) | Where-Object { $_ } }
    }
  }
  foreach ($port in $by.Keys) {
    $u = @($by[$port]); if ($u.Count -lt 2) { continue }
    # one external service shared by several envs (same start or none) is fine
    if (@($u | Where-Object { -not $_.external }).Count -or @($u.start | Select-Object -Unique).Count -gt 1) { "port $port is claimed by $(($u.who) -join ', ')" }
  }
}
function EnvRepos([string]$e) {
  $map = [ordered]@{}
  foreach ($s in EnvServices $e | Where-Object { $_.repo }) {
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
function Closure([string]$e, [string[]]$names) {
  $out = [Collections.Generic.List[string]]::new(); $todo = [Collections.Generic.Queue[string]]::new()
  foreach ($n in $names) { $todo.Enqueue($n) }
  while ($todo.Count) { $n = $todo.Dequeue(); if ($out.Contains($n)) { continue }; $out.Add($n); $s = EnvServices $e | Where-Object name -eq $n; foreach ($d in @($s.dependsOn | Where-Object { $_ })) { $todo.Enqueue($d) } }
  @($out)
}
function Dependents([string]$e, [string[]]$names) { @(EnvServices $e | Where-Object { $n = $_.name; @(Closure $e @($n) | Where-Object { $_ -ne $n -and $_ -in $names }).Count } | ForEach-Object name) }
function Expand-Placeholders([string]$t, [string]$e, $s, [string]$dir, [string]$artifact) {
  if (-not $t) { return $t }
  $wt = if ($s.repo) { (EnvRepos $e)[(Get-RepoCfg $s.repo).name].wt } else { '' }
  $t.Replace('{port}', "$($s.port)").Replace('{debugPort}', "$($s.debugPort)").Replace('{dir}', $dir).Replace('{wt}', $wt).Replace('{env}', $e).Replace('{kit}', $KitConf.Kit).Replace('{workspace}', $KitConf.Workspace).Replace('{artifact}', "$artifact")
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

# ---- state (one JSON per env, locked writes)
function StateFile([string]$e) { Join-Path (Get-KitPath localenv -Create) "$e.json" }
# readers take the file's lock too (Update-State already holds it): an open reader made the writer's rename fail
function Read-State([string]$e) {
  $f = StateFile $e; $st = $null
  if (Test-Path $f) { try { $st = $(if ($script:stateLocked) { Get-Content $f -Raw } else { Invoke-KitLocked $f { Get-Content $f -Raw } }) | ConvertFrom-Json -AsHashtable } catch { Write-Warning "localenv: $f unreadable, starting a fresh state ($_)" } }
  if ($st -isnot [hashtable]) { $st = @{} }
  foreach ($k in 'services', 'leases', 'holds') { if ($st[$k] -isnot [hashtable]) { $st[$k] = @{} } }
  foreach ($k in 'requests', 'releases') { $st[$k] = @(@($st[$k]) | Where-Object { $_ }) }
  if ($st.release -isnot [hashtable]) { $st.release = @{ n = 0; repos = @{} } }
  if ($st.release.repos -isnot [hashtable]) { $st.release.repos = @{} }
  $st
}
function Update-State([string]$e, [scriptblock]$Change) {
  $f = StateFile $e
  Invoke-KitLocked $f {
    $script:stateLocked = $true
    try { $__state = Read-State $e } finally { $script:stateLocked = $false }
    & $Change $__state
    $__state | ConvertTo-Json -Depth 10 | Set-Content "$f.tmp" -Encoding utf8
    for ($i = 0; ; $i++) { try { [IO.File]::Move("$f.tmp", $f, $true); break } catch [IO.IOException], [UnauthorizedAccessException] { if ($i -ge 100) { throw }; [Threading.Thread]::Sleep(50) } }   # an open reader (Windows: access denied) blocks the rename; a real wait
  }
}
function Alive($p) { $p -and [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function PStart($p) { try { (Get-Process -Id ([int]$p) -ErrorAction Stop).StartTime } catch { $null } }
function Owned($x) {
  if (-not ($x -and $x.pid -and (Alive $x.pid))) { return $false }
  if (-not $x.pstart) { return $true }
  $now = PStart $x.pid; $now -and [math]::Abs(($now - [datetime]$x.pstart).TotalSeconds) -lt 2
}
function EnvProcess([int]$p, [string]$e) {
  $c = if ($KitIsWindows) { "$((Get-CimInstance Win32_Process -Filter "ProcessId=$p" -Property CommandLine -ErrorAction SilentlyContinue).CommandLine)" } else { "$(ps -o args= -p $p 2>$null)" }
  $c -and ($c.Contains((Get-KitPath localenv)) -or $c -match [regex]::Escape("localenv-$e-") -or $c -match [regex]::Escape("_exec -Env $e "))
}
function Layers($st, [string]$rn) { @($st.release.repos[$rn].layers | Where-Object { $_ }) }

# ---- leases, holds, demand: a lease ends at its time, or with no live holder past the grace (Update-KitLease)
function Prune($st) {
  foreach ($a in @($st.leases.Keys)) { if (-not (Update-KitLease $st.leases[$a])) { $st.leases.Remove($a) } }
  foreach ($a in @($st.holds.Keys)) { if (-not (Update-KitLease $st.holds[$a])) { $st.holds.Remove($a) } }
  $st.requests = @($st.requests | Where-Object { $_.status -ne 'done' -or ((Get-Date) - [datetime]$_.at).TotalHours -lt 24 } | Select-Object -Last 60)
  if ($st.train -and -not (Alive $st.train.pid) -and ($st.train.pid -or ((Get-Date) - [datetime]$st.train.at).TotalSeconds -gt 60)) {
    foreach ($r in $st.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($st.train.requests)) { $r.status = 'queued' } }   # worker died: the train runs again
    $st.train = $null
  }
}
function Leased($why) { [bool]@($why | Where-Object { "$_" -match '^(lease|hold):' }).Count }
function IdleWhy([double]$min, [string]$pressure) { if ($pressure) { "idle, stopped under memory pressure ($pressure)" } else { "idle: no holder for $min min (starts on the next lease)" } }
function ClientPids([int]$port, [int[]]$exclude) {
  $pids = if ($KitIsWindows) { @(Get-NetTCPConnection -State Established -RemotePort $port -ea 0 | ForEach-Object OwningProcess) }
    elseif (Resolve-Tool ss) { @([regex]::Matches("$(ss -tnpH state established "( dport = :$port )" 2>$null)", 'pid=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }) }
    elseif (Resolve-Tool lsof) { @(lsof -nP "-iTCP@127.0.0.1:$port" -sTCP:ESTABLISHED -Fp 2>$null | Where-Object { $_ -match '^p\d+$' } | ForEach-Object { [int]$_.Substring(1) }) }
  $pids = @($pids | Where-Object { $_ -and $_ -notin $exclude } | Select-Object -Unique)
  if (-not $pids) { return @() }
  $ps = if ($KitIsWindows) { @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + ($pids -join ' OR ProcessId=')) -Property ProcessId, CommandLine -ErrorAction SilentlyContinue | ForEach-Object { @{ Id = $_.ProcessId; CommandLine = $_.CommandLine } }) } else { Get-SysProcs }
  @($ps | Where-Object { $_.Id -in $pids -and "$($_.CommandLine)" -notmatch '--headless' } | ForEach-Object { $_.Id })
}

# ---- code: worktrees, layers, builds
function G([string]$d) { $o = & git -C $d @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' ') in $d : $o" }; $o }
function NoHooksDir { $d = Join-Path (Get-KitPath localenv -Create) '.no-hooks'; New-Item -ItemType Directory -Force $d | Out-Null; $d }   # local-only merges, never pushed
function Ensure-Worktree([string]$e, $r) {
  if (Test-Path (Join-Path $r.wt '.git')) { return }
  Write-Host "[$e] creating worktree $($r.wt) ($($r.name) @ $($r.target))"
  & $KitCmd.dev wt new -Repo $r.cfg.checkout -Branch "localenv/$e" -Target $r.target -Name "localenv-$e" | ForEach-Object { Write-Host "  $_" }
}
function Sync-DepLinks([string]$e, $r) {
  $c = $r.cfg
  $src = if ($c.linkFromByTarget -and $c.linkFromByTarget.($r.target)) { [string]$c.linkFromByTarget.($r.target) } elseif ($c.linkFrom -and $r.target -eq $c.target) { [string]$c.linkFrom } else { [string]$c.checkout }
  if (-not (Test-Path $src)) { Write-Warning "[$e] dependency source $src for $($r.name) @ $($r.target) does not exist"; return }
  $src = (Resolve-Path $src).Path
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
function HasMigrations([string]$checkout, [string]$target, [string]$sha) { $d = @(git -C $checkout diff --name-only "origin/$target...$sha" 2>$null); if ($LASTEXITCODE) { return $true }; [bool]($d -match '(^|/)((deploy|revert)/[^/]+|\d+[_.-][^/]*)\.sql$|(^|/)versions/\w+\.py$' -or $d -match $script:MigPattern) }

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
    $inUse = @((Read-State $e).services.Values | ForEach-Object { if ($_.artifact) { Split-Path $_.artifact } })
    Get-ChildItem (Split-Path $to) -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Where-Object { $_.FullName -notin $inUse } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
  $out
}

function Invoke-Shell([string]$cmd, [string]$log, $vars) {
  With-Env $(if ($vars) { $vars } else { @{} }) { if ($KitIsWindows) { & cmd.exe /d /c $cmd *>> $log } else { & /bin/sh -c $cmd *>> $log } }
  $LASTEXITCODE
}
# ---- hooks (db snapshot / restore) and smoke checks
function Invoke-Hook([string]$e, [string]$name, [hashtable]$vars = @{}) {
  $db = (Get-EnvCfg $e).db
  if (-not $db.$name) { return "no db.$name hook configured" }
  $cmd = Expand-Placeholders ([string]$db.$name) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
  foreach ($k in $vars.Keys) { $cmd = $cmd.Replace("{$k}", "$($vars[$k])") }
  $log = LogFile $e 'db'
  Add-Content $log "== $(Now) $name : $cmd"
  $code = Invoke-Shell $cmd $log (EnvVars $e ([pscustomobject]@{}))
  Event $e "db-$name" @{ code = $code; vars = $vars }
  if ($code) { return "db.$name failed (exit $code): $((Get-Content $log -Tail 8) -join ' | ')" }
  $null
}
function Test-Smoke([string]$e) {
  foreach ($c in @((Get-EnvCfg $e).smoke | Where-Object { $_ })) {
    if ($c.service -and -not (Healthy $e (Svc $e $c.service))) { continue }   # skip while its service is idle
    $until = (Get-Date).AddSeconds([double]$(if ($c.timeoutSec) { $c.timeoutSec } else { 60 })); $why = 'not run'
    while ($true) {
      if ($c.url) {
        $u = Expand-Placeholders ([string]$c.url) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        $want = if ($c.status) { [string]$c.status } else { '^[23]\d\d$|^401$|^403$' }
        try { $r = Invoke-WebRequest $u -ConnectionTimeoutSeconds 15 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; if ("$($r.StatusCode)" -match $want) { $why = $null } else { $why = "$u returned $($r.StatusCode)" } } catch { $why = "$u : $($_.Exception.Message)" }
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

# ---- processes
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
function StartMin($s) { [double]$(if ($s.startMinutes) { $s.startMinutes } else { 10 }) }
function Healthy([string]$e, $s) {
  if ($s.port -and -not (Test-PortListening ([int]$s.port))) { return $false }   # nothing listens: no HTTP wait (status -Json stays fast)
  if ($s.health) {
    try { $r = Invoke-WebRequest (Expand-Placeholders $s.health $e $s (SvcDir $e $s) '') -ConnectionTimeoutSeconds 5 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; return $r.StatusCode -gt 0 -and $r.StatusCode -lt 500 } catch { return $false }
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
  if ($s.port) { foreach ($p in Get-PortPids ([int]$s.port)) { if ($p -gt 4 -and ($p -in $mine -or (EnvProcess $p $e))) { Stop-SysProcess $p } } }
  Update-State $e { param($z) $o = $z.services[$s.name]; $z.services[$s.name] = @{ status = 'down'; port = $s.port; at = (Now); release = $o.release; artifact = $o.artifact; why = $why; restarts = @($o.restarts) } }
  Event $e 'stop' @{ service = $s.name; why = $why }
}
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
function GraceMin([string]$e, $s) {
  $xs = @((Get-LocalEnvHistory)["$e/$($s.name)/startSec"] | Where-Object { $_ })
  $start = if ($xs.Count) { ($xs | Measure-Object -Maximum).Maximum } else { 120 }
  [math]::Min($script:IdleMaxM, [math]::Max($script:IdleMinM, [math]::Round(3 * $start / 60, 1)))
}
function KeepFreeGB { if ($env:CLAUDE_GATE_KEEP_FREE_GB) { return [double]$env:CLAUDE_GATE_KEEP_FREE_GB }; $m = Get-SysMem; [double](Get-KitSetting 'localEnv.keepFreeGB' (Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round($m.TotalGB * 0.15, 1))))) }
function Pressure {
  if ((Get-SysMem).AvailGB -lt (KeepFreeGB)) { return 'RAM below the keep-free floor' }
  $q = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'queue'
  $w = @(Get-ChildItem $q -Filter *.json -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 1 -and (Alive ([int]$_.BaseName)) })
  if ($w.Count) { return "$($w.Count) gated build(s) waiting for RAM" }
  $null
}
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
function Start-Pwsh([string[]]$a, [string]$dir, [string]$match, [string]$log) {
  $a = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'localenv.ps1')) + $a; $pwsh = (Get-Process -Id $PID).Path
  if ($KitIsWindows) { return (Start-Process -FilePath $pwsh -ArgumentList (($a | ForEach-Object { if ("$_" -match '\s' -or "$_" -eq '') { "`"$_`"" } else { $_ } }) -join ' ') -WorkingDirectory $dir -WindowStyle Hidden -PassThru).Id }
  Start-Detached -FilePath $pwsh -ArgumentList $a -WorkingDirectory $dir -Log $log
  Start-Sleep 1; (Get-SysProcs | Where-Object { $_.CommandLine -match [regex]::Escape($match) } | Select-Object -First 1).Id
}
function Start-Svc([string]$e, $s, [int]$release, [string]$artifact) {
  $dir = SvcDir $e $s
  if (-not (Test-Path $dir)) { throw "[$e] $($s.name): folder $dir does not exist" }
  $cmd = StartCmd $e $s $artifact
  Stop-Svc $e $s 'stopped before a new start'
  if ($s.port -and (Test-PortListening ([int]$s.port))) {
    $holder = @(Get-PortPids ([int]$s.port)) -join ','
    Update-State $e { param($x) $x.services[$s.name].status = 'failed'; $x.services[$s.name].why = "port $($s.port) held by pid $holder (not started by the env)" }
    throw "[$e] $($s.name): port $($s.port) is held by pid $holder, which the env did not start: stop it or change the port"
  }
  $mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { 'Global\kit-localenv-start' } else { 'kit-localenv-start' }))
  $got = $false
  try { $got = $mx.WaitOne([TimeSpan]::FromMinutes(45)) } catch [Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $mx.Dispose(); throw "[$e] $($s.name): another service start held the machine-wide start lock for 45 min - not started (localenv.ps1 events)" }
  try {
    Wait-Room $e $s
    $log = LogFile $e $s.name; if (Test-Path $log) { Move-Item $log "$log.prev" -Force }
    "[$e] starting $($s.name)$(if ($release) { " (release $release)" }): $cmd"
    $t0 = Get-Date
    $p = Start-Pwsh @('_exec', '-Env', $e, '-Service', $s.name, '-Artifact', "$artifact") $dir "_exec -Env $e -Service $($s.name)" "$log.wrapper"
    Update-State $e { param($x) $o = $x.services[$s.name]; $x.services[$s.name] = @{ status = 'starting'; pid = $p; pstart = "$(if (PStart $p) { (PStart $p).ToString('o') })"; port = $s.port; startedAt = (Now); lastNeed = (Now); release = $release; artifact = $artifact; restarts = @($o.restarts) } }
    $limit = (Get-Date).AddMinutes((StartMin $s))
    $fail = if ($s.failPattern) { [string]$s.failPattern } else { $script:FailPattern }
    while (-not (Healthy $e $s)) {
      $hit = if ($fail -and (Test-Path $log)) { Select-String -LiteralPath $log -Pattern $fail -List | Select-Object -First 1 }
      $why = if ($hit) { "failed to start (log line $($hit.LineNumber): $($hit.Line.Trim()))" } elseif (-not (Alive $p)) { 'exited while starting' } elseif ((Get-Date) -gt $limit) { "not healthy within $(StartMin $s) min" } else { $null }
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

# ---- _daemon (this script only): -Env = loop, -Train = worker; logs <logs>/<env>-loop.log, -train.log, -events.jsonl
function Invoke-Daemon {
param([Parameter(Mandatory)][Alias('Env')][string]$EnvName, [string]$Train)
$e = $EnvName
$ErrorActionPreference = 'Stop'

# ==== train worker: wait until no lease covers $services / $repos (skip this train's agents)
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

  $cur = @{}; $want = @{}; foreach ($rn in $envRepos.Keys) { $cur[$rn] = @(Layers $st $rn); $want[$rn] = @($cur[$rn]) }
  $affected = [Collections.Generic.List[string]]::new(); $byBranch = @{}
  foreach ($r in $reqs) {
    switch ($r.kind) {
      'deploy' { foreach ($rn in @($r.shas.Keys)) {
          $l = @{ branch = $r.branch; agent = $r.agent; sha = $r.shas[$rn]; at = $r.at; migrations = [bool]$r.migrations[$rn]; request = $r.id }
          if ($l.migrations) { $migNote[$r.id] = "$rn has migrations: they change the shared local DB$(if ((Get-EnvCfg $e).db.snapshot) { ' (snapshot first)' })" }
          $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }) + @($l); if (-not $affected.Contains($rn)) { $affected.Add($rn) }; $byBranch["$rn|$($r.branch)"] = $r.id } }
      'drop' { foreach ($rn in $envRepos.Keys) { if (@($want[$rn].branch) -contains $r.branch) { $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }); if (-not $affected.Contains($rn)) { $affected.Add($rn) } } } }
      'refresh' { foreach ($rn in $envRepos.Keys) { if (-not $affected.Contains($rn)) { $affected.Add($rn) } } }
    }
  }
  $newN = [int]$st.release.n + 1; $tag = "r$newN-$Train"
  $repoOut = @{}; $artifacts = @{}; $newLayers = @{}
  $ok = [Collections.Generic.List[string]]::new()
  if (-not $affected.Count) { Record-Train; return }

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
      else { $notes.Add("dropped layer $($d.layer.branch) ($($d.layer.agent)) from $rn : $($d.why)$(if ($d.layer.migrations) { ' - it had migrations: the local DB keeps them' })") }
    }
    $kept = @($res.kept); $targetSha = $res.targetSha
    $live = $st.release.repos[$rn]
    $missing = @(EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -eq $rn -and -not ($st.services[$_.name].artifact -and (Test-Path $st.services[$_.name].artifact)) })
    if ([int]$st.release.n -gt 0 -and $live -and $live.targetSha -eq $targetSha -and -not $missing.Count -and (@($kept | ForEach-Object { Key $_ }) -join '|') -eq ($prevKeys -join '|')) {
      "[$e] $rn unchanged (same target commit and layers): no build"
      foreach ($l in $kept) { if ($l.request -and $results[$l.request].outcome -eq 'live') { $results[$l.request].message = 'already live' } }
      continue
    }
    $err = Build-Repo $e $rn
    if ($err) {
      $base = @($kept | Where-Object { -not (& $isNew $_) }); $cands = @($kept | Where-Object { & $isNew $_ })
      $state = @{ err = $err }
      $try = { param($set) $null = Sync-Repo $e $r @($set) -NoFetch; $state.err = Build-Repo $e $rn; -not $state.err }
      Phase "build failed in $rn : finding the culprit among $($cands.Count) new layer(s)" $codeBlock @($affected)
      if (-not $cands.Count -or -not (& $try $base)) {
        foreach ($l in $cands) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : the target + the layers already live do not build either: $($state.err)" } } }
        $notes.Add("$rn does not build on its target + current layers: kept the running release ($($state.err))")
        $null = Sync-Repo $e $r @($cur[$rn]) -NoFetch   # worktree back on the live code
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

  $st2 = Read-State $e
  $switch = @(EnvServices $e | Where-Object { (RepoOf $e $_) -in $ok -and (Managed $_) -and $st2.services[$_.name].status -eq 'up' -and -not ($_.hot -and -not $_.artifact) })
  $switchNames = @($switch | ForEach-Object name)
  $block = @(@($switchNames) + @(Dependents $e $switchNames) | Select-Object -Unique)
  if ($switch.Count) { Phase 'waiting for leases (switch-over)' $block @($affected); Wait-Leases $block @() $own }
  foreach ($rn in @($ok)) {
    $keepKeys = @($repoOut[$rn].layers | ForEach-Object { Key $_ })
    foreach ($l in @($cur[$rn] | Where-Object { $_.migrations -and (Key $_) -notin $keepKeys })) { $notes.Add("migration layer $($l.branch) left $rn : the DB keeps its changes (restore a snapshot from before it to undo)") }
  }
  $snap = $null
  $migRepos = @($ok | Where-Object { @($newLayers[$_] | Where-Object { $_.migrations }).Count })
  $mig = @($migRepos | ForEach-Object { @($newLayers[$_] | Where-Object { $_.migrations }) })
  if ($mig.Count -and (Get-EnvCfg $e).db.snapshot) {
    Phase 'db snapshot (migration layers)' $block @($affected)
    $snap = "$e-before-$tag"
    $err = Invoke-Hook $e 'snapshot' @{ snapshot = $snap }
    if ($err) { $notes.Add("db snapshot failed, release goes on without a restore point: $err"); $snap = $null }
    else { Update-State $e { param($x) $x.snapshots = @(@($x.snapshots) + @(@{ name = $snap; at = (Now); release = $newN; layers = @($mig.branch) }) | Where-Object { $_ } | Select-Object -Last 10) } }
  } elseif ($mig.Count) { $notes.Add("migration layers ($(@($mig.branch) -join ', ')) change the shared DB: no db.snapshot hook, no restore point") }

  $prevSvc = @{}; foreach ($s in $switch) { $prevSvc[$s.name] = $st2.services[$s.name] }
  $flag = @{ restored = $false }
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

function Record-Train {
  $changed = @($repoOut.Keys)
  Update-State $e { param($x)
    if ($changed.Count) {
      foreach ($rn in $changed) {
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
  Event $e 'release' @{ n = $(if ($changed.Count) { $newN } else { $null }); train = $Train; changed = $changed; results = $results; notes = @($notes) }
  $notes | ForEach-Object { "[$e] $_" }
  "[$e] train $Train done: $(if ($changed.Count) { "release $newN ($($changed -join ', '))" } else { 'no new release' })"
}

if ($Train) {
  for ($i = 0; $i -lt 20 -and -not ((Read-State $e).train.id -eq $Train); $i++) { Start-Sleep -Milliseconds 250 }
  try { Run-Train *>&1 | Tee-Object -FilePath (LogFile $e 'train') -Append }
  catch {
    $why = "$_"; "[$e] train $Train crashed: $why $($_.ScriptStackTrace)" | Add-Content (LogFile $e 'train')
    Update-State $e { param($x) foreach ($r in $x.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($x.train.requests)) { $r.status = 'done'; $r.result = @{ outcome = 'error'; message = "train crashed: $why" } } }; $x.train = $null }
  }
  exit
}

# ==== env loop
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

    # ---- trains: one worker takes all queued requests
    $queued = @($st.requests | Where-Object { $_.status -eq 'queued' })
    if (-not $st.train -and $queued.Count) {
      $tid = [guid]::NewGuid().ToString('n').Substring(0, 6); $ids = @($queued.id)
      Update-State $e { param($x) $x.train = @{ id = $tid; pid = $null; phase = 'starting'; requests = $ids; at = (Now); blockServices = @(); blockRepos = @() }; foreach ($r in $x.requests) { if ($r.id -in $ids) { $r.status = 'in-train' } } }
      $wp = Start-Pwsh @('_daemon', '-Env', $e, '-Train', $tid) $PSScriptRoot "_daemon -Env $e -Train $tid" (LogFile $e "train-$tid")
      Update-State $e { param($x) if ($x.train -and $x.train.id -eq $tid) { $x.train.pid = $wp } }
      Say "train $tid started for $($ids.Count) request(s): $(($queued | ForEach-Object { "$($_.kind) $($_.branch)" }) -join '; ')"
      $st = Read-State $e
    }

    # ---- demand (traffic probed every 5th tick: slow)
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

    # ---- stop first: idle past grace, or idle under pressure
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
      $why = IdleWhy (GraceMin $e $s) $pressure
      Say "stopping $($s.name): $why"; Stop-Svc $e $s $why
      $st = Read-State $e
    }

    # ---- start needed, restart crashes with backoff
    $needsBuild = $false
    foreach ($s in EnvServices $e | Where-Object { Managed $_ }) {
      $x = $st.services[$s.name]
      if (-not $need[$s.name]) { continue }
      Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{ status = 'down' } }; $z.services[$s.name].lastNeed = (Now); $z.services[$s.name].need = @($need[$s.name]) }
      if ($s.name -in $block) { continue }
      if (Healthy $e $s) { if ($x.status -ne 'up') { Update-State $e { param($z) $z.services[$s.name].status = 'up' } }; continue }
      if (-not (Leased $need[$s.name])) { continue }
      if ($x.status -eq 'starting' -and (Owned $x) -and $x.startedAt -and ((Get-Date) - [datetime]$x.startedAt).TotalMinutes -lt (StartMin $s)) { continue }
      if (@($s.dependsOn | Where-Object { $_ -and -not (Healthy $e (Svc $e $_)) }).Count) { continue }   # dependencies first
      $recent = @($x.restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 })
      if ($x.status -eq 'failed' -and $recent.Count -ge 3) { continue }   # backoff: 3 tries / 30 min
      if ($s.repo -and ([int]$st.release.n -eq 0 -or ($s.artifact -and -not ($x.artifact -and (Test-Path $x.artifact))))) { $needsBuild = $true; continue }
      Update-State $e { param($z) $z.services[$s.name].restarts = @(@($recent) + @(Now)) }
      try { Start-Svc $e $s ([int]$st.release.n) $x.artifact *>&1 | ForEach-Object { Say "$_" } } catch { Say "start of $($s.name) failed: $("$_".Split("`n")[0])" }
      $st = Read-State $e
    }
    if ($needsBuild -and -not $st.train -and -not @($st.requests | Where-Object { $_.status -ne 'done' }).Count) {
      $rid = [guid]::NewGuid().ToString('n').Substring(0, 8)
      Update-State $e { param($z) $z.requests = @($z.requests) + @(@{ id = $rid; kind = 'refresh'; agent = 'controller'; at = (Now); status = 'queued' }) }
      Say 'queued a refresh: a needed service has no build yet'
    }

    # ---- exit when idle
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
}

# ---- commands (owner / brief asks); calls return within -Wait min (8)
function Invoke-LocalEnv {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('envs', 'status', 'deploy', 'wait', 'use', 'release', 'promote', 'logs', 'events', 'up', 'unhold', 'down', 'drop', 'refresh', '_exec')][string]$Action,
  [Alias('Env')][string]$EnvName,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }),
  [string]$Branch, [string[]]$Repo, [string]$Dir, [string[]]$Services, [string]$Service, [string]$Note, [string]$Id,
  [string]$Session, [string]$Artifact, [switch]$Owner,
  [int]$Minutes = 0, [double]$Wait = 8, [int]$Tail = 80, [switch]$Json
)
$Repo = @(Split-KitList $Repo); $Services = @(Split-KitList $Services)
if ($Service -and -not $Services) { $Services = @($Service) }
if (-not (EnvNames).Count -and $Action -ne 'envs') { throw 'No local environments configured: add "localEnv": { "envs": { "<env>": { "services": [...] } } } to kit.local.json (see README "Configuration", localEnv).' }
$clash = @(Test-PortClash)
if ($clash.Count) { $m = "localEnv port clash (envs run side by side; give each service its own port): $($clash -join '; ')"; if ($Action -in 'envs', 'status', 'logs', 'events', 'release', '_exec') { Write-Warning $m } else { throw $m } }
if (-not $EnvName -and $Action -notin 'envs', 'status') { if (@(EnvNames).Count -eq 1) { $EnvName = @(EnvNames)[0] } else { throw "-Env needed: $((EnvNames) -join ', ')" } }
$e = $EnvName
# config that asks for a removed feature stops with one line before anything changes
$needs = @(foreach ($n in @($e)) {
    $c = $script:LE.envs.$n
    if ($c.sandbox -or $c.tasks -or $c.db.rollback -or $c.db.applied -or $c.db.tag) { "env $n (sandbox / tasks / db.rollback): migration sandboxes and exact reverts are an extra: run kittool.py extra add localenv-sandbox" }
    if ($c.db.engine -and -not $script:DbPresets -and -not ($c.db.snapshot -and $c.db.restore)) { "env $n (db.engine): db.engine presets are an extra: run kittool.py extra add db-engine-presets" }
  })
if ($needs.Count -and $Action -in 'deploy', 'drop', 'refresh', 'promote') { [Console]::Error.WriteLine("localenv.ps1: $($needs[0])"); exit 1 }

function Ensure-Loop {
  $st = Read-State $e
  if ($st.loop -and (Alive $st.loop.pid)) { return }
  $null = Start-Pwsh @('_daemon', '-Env', $e) $PSScriptRoot "_daemon -Env $e" (LogFile $e 'loop')
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 300; if ((Read-State $e).loop) { break } }
}
function New-Request([hashtable]$r) {
  $r.id = [guid]::NewGuid().ToString('n').Substring(0, 8); $r.at = Now; $r.status = 'queued'; $r.agent = $Agent
  Update-State $e { param($x) $x.requests = @($x.requests) + @($r) }
  Event $e 'request' @{ id = $r.id; kind = $r.kind; agent = $Agent; branch = $r.branch }
  Ensure-Loop
  $r.id
}
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
    $listens = if ($h -and $KitIsWindows -and $ids) { @(Get-NetTCPConnection -State Listen -ea 0 | Where-Object { $_.OwningProcess -in $ids } | ForEach-Object LocalPort | Sort-Object -Unique) }
      elseif ($h -and $ids -and (Resolve-Tool lsof)) { @(lsof -nP -a -p ($ids -join ',') -iTCP -sTCP:LISTEN -Fn 2>$null | Where-Object { $_ -match ':(\d+)$' } | ForEach-Object { [int]$Matches[1] } | Sort-Object -Unique) } else { @() }
    $idleMin = if ($h -and $x.lastNeed) { [int]((Get-Date) - [datetime]$x.lastNeed).TotalMinutes } else { $null }
    [pscustomobject]@{
      service = $s.name; state = $(if ($h) { if (-not (Managed $s)) { 'up (external)' } elseif (Owned $x) { 'up' } else { 'up (adopted)' } } elseif ($x.status -in 'starting', 'failed') { $x.status } else { 'down' })
      port = $s.port; gb = $(if ($ids) { TreeGB $ids $all } else { 0 }); release = $x.release; need = @($x.need | Where-Object { $_ }); idleMin = $idleMin; graceMin = $(if (Managed $s) { GraceMin $env1 $s }); listens = $listens
      why = $x.why; hot = [bool]$s.hot
    }
  }
  $o = [pscustomobject]@{
    env = $env1; release = $st.release.n; releasedAt = $st.release.at
    repos = @($st.release.repos.Keys | ForEach-Object { $rr = $st.release.repos[$_]; [pscustomobject]@{ repo = $_; target = $rr.target; targetSha = "$($rr.targetSha)".Substring(0, [math]::Min(9, "$($rr.targetSha)".Length)); layers = @($rr.layers | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ branch = $_.branch; agent = $_.agent; sha = "$($_.sha)".Substring(0, [math]::Min(9, "$($_.sha)".Length)); migrations = [bool]$_.migrations; promoted = $(if ($_.promoted) { "release $($_.promoted.release)" }) } }) } })
    train = $(if ($st.train) { [pscustomobject]@{ id = $st.train.id; phase = $st.train.phase; waitingFor = @($st.train.waitingFor); requests = @($st.train.requests).Count } })
    queue = @($st.requests | Where-Object status -eq 'queued' | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch)" })
    services = @($svc)
    leases = @($st.leases.Keys | ForEach-Object { $l = $st.leases[$_]; [pscustomobject]@{ agent = $_; services = @($l.services); until = $(if ($l.owner) { ([datetime]$l.until).ToString('HH:mm') }); release = $l.release; note = $l.note; graceLeft = $l.graceLeft } })
    holds = @($st.holds.Keys | ForEach-Object { $h = $st.holds[$_]; [pscustomobject]@{ who = $_; services = @($h.services); owner = [bool]$h.owner; until = $(if ($h.until) { ([datetime]$h.until).ToString('HH:mm') }); at = $h.at; graceLeft = $h.graceLeft } })
    recent = @($st.requests | Where-Object status -eq 'done' | Select-Object -Last 5 | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch) -> $($_.result.outcome)$(if ($_.result.release) { " (release $($_.result.release))" })" })
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
  foreach ($r in $o.repos) { "  $($r.repo) @ $($r.target) $($r.targetSha)$(if (-not $r.layers.Count) { ' (no layers)' })"; foreach ($l in $r.layers) { '    + {0,-42} {1,-10} {2}{3}{4}' -f $l.branch, $l.agent, $l.sha, $(if ($l.promoted) { "  PROMOTED ($($l.promoted))" }), $(if ($l.migrations) { '  MIGRATIONS' }) } }
  $gr = { param($x) if ($null -ne $x.graceLeft) { " ⏳ no live holder: ends in $($x.graceLeft) min" } }
  if ($o.leases) { "  leases: $(($o.leases | ForEach-Object { "$($_.agent) [$($_.services -join ',')] $(if ($_.until) { "owner until $($_.until)" } else { 'while live' }) (r$($_.release))$(if ($_.note) { " $($_.note)" })$(& $gr $_)" }) -join '; ')" }
  if ($o.holds) { "  holds: $(($o.holds | ForEach-Object { "$($_.who) [$($_.services -join ',')] $(if ($_.owner) { "owner until $($_.until)" } else { 'while live' })$(& $gr $_)" }) -join '; ')" }
  if ($o.recent) { "  recent: $($o.recent -join '; ')" }
  if ($o.mine) { "  YOU ($Agent): $($o.mine)" }
}

switch ($Action) {
  'envs' {
    foreach ($n in EnvNames) {
      "$n$(if ((Get-EnvCfg $n).description) { " - $((Get-EnvCfg $n).description)" })"
      foreach ($s in EnvServices $n) { '  {0,-14} {1,-28}{2}{5}{3}{4}' -f $s.name, $(if ($s.repo) { "$($s.repo)/$($s.dir)" } else { 'external' }), $(if ($s.port) { "  :$($s.port)" }), $(if ($s.dependsOn) { "  needs $(@($s.dependsOn) -join ',')" }), $(if ($s.hot) { '  hot' } elseif ($s.artifact) { '  runs from artifact' }), $(if ($s.debugPort) { "  debug :$($s.debugPort)" }) }
    }
  }
  'status' { $names = if ($EnvName) { @($EnvName) } else { EnvNames }; $out = foreach ($n in $names) { Show-Status $n }; if ($Json) { $out | ConvertTo-Json -Depth 8 } else { $out } }
  'deploy' {
    $envRepos = EnvRepos $e
    if ($Dir) {
      $Dir = (Resolve-Path $Dir).Path
      $Branch = "$(git -C $Dir rev-parse --abbrev-ref HEAD)".Trim()
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
    $shas = @{}; $mig = @{}
    foreach ($rn in $targets) {   # the commit at request time
      $sha = Resolve-Ref $envRepos[$rn].cfg.checkout $Branch; if (-not $sha) { throw "[$e] $Branch not found in $rn" }
      $shas[$rn] = $sha; $mig[$rn] = HasMigrations $envRepos[$rn].cfg.checkout $envRepos[$rn].target $sha
    }
    $rid = New-Request @{ kind = 'deploy'; branch = $Branch; shas = $shas; migrations = $mig }
    "[$e] deploy $Branch ($(($shas.Keys | ForEach-Object { $s = $shas[$_]; "$_ @ $(if ($s.Length -ge 9) { $s.Substring(0, 9) } else { $s })" }) -join ', ')) queued as request $rid"
    foreach ($rn in @($mig.Keys | Where-Object { $mig[$_] })) { "[$e]   $rn has migrations: they change the shared local DB ($(if ((Get-EnvCfg $e).db.snapshot) { 'snapshot first, restored on rollback' } else { 'no db.snapshot hook: no restore point' }))" }
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
        if ($old -and $blocked.Count) {   # a train waits on it: kept, not extended
          $o.ok = $true; $o.rel = $old.release; $o.capped = $true
        } elseif (-not $blocked.Count) {
          $x.leases[$Agent] = @{ services = $names; repos = @(); release = [int]$x.release.n; note = $Note } + (New-KitLease $Agent $Session $(if ($Owner) { $min }))   # no live holder: Prune frees it
          $o.ok = $true; $o.rel = $x.release.n
        } else { $o.why = "train $($x.train.id) is switching $($blocked -join ', ') ($($x.train.phase))" }
      }
      if ($o.ok) { break }
      if ($o.why -ne $said) { "[$e] lease waits: $($o.why)"; $said = $o.why }
      Ensure-Loop
      if ((Get-Date) -gt $until) { "[$e] no lease yet after $Wait min: call use again to keep waiting"; exit 3 }
      Start-Sleep 3
    }
    Event $e 'lease' @{ agent = $Agent; services = $names; minutes = $min }
    "[$e] lease for $Agent on $($names -join ', ') $(if ($Owner) { "for $min min (owner)" } else { 'while you are live' }) (release $($o.rel)).$(if ($o.capped) { ' Kept as is: a train waits for it - release when done.' } else { ' End: release.' })"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e } else { exit 1 }
  }
  'release' { Update-State $e { param($x) $x.leases.Remove($Agent) }; Event $e 'release-lease' @{ agent = $Agent }; "[$e] lease of $Agent released" }
  'up' {   # -Owner: the owner's hold for -Minutes (120); else a hold that lives while its holder does
    if (-not $Services) { $st = Read-State $e; Prune $st; "[$e] up needs -Services <svc,..>. Leases need: $(@($st.leases.Keys | ForEach-Object { "$_ [$(@($st.leases[$_].services) -join ',')]" }) -join '; ')$(if (-not $st.leases.Count) { 'nothing' })"; exit 1 }
    $names = @(Closure $e $Services); $min = if ($Minutes) { $Minutes } else { 120 }
    Update-State $e { param($x) $x.holds[$Agent] = @{ services = $names } + (New-KitLease $Agent $Session $(if ($Owner) { $min })); $x.suppress = $null }
    "[$e] holding $($names -join ', ') for $Agent $(if ($Owner) { "(owner) for $min min: unhold when done" } else { 'while it is live (board beat / step / pid): unhold when done' })"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e } else { exit 1 }
  }
  'unhold' {   # ends a hold (-Services: only those); services stop when idle, never at once
    Update-State $e { param($x) if ($x.holds[$Agent]) { $left = @($x.holds[$Agent].services | Where-Object { $Services -and $_ -notin (Closure $e $Services) }); if ($left.Count) { $x.holds[$Agent].services = $left } else { $x.holds.Remove($Agent) } } }
    Event $e 'unhold' @{ agent = $Agent; services = @($Services) }; "[$e] hold of $Agent $(if ($Services) { "on $($Services -join ', ') " })removed: services stop after their idle grace"
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
    $order = @(EnvServices $e | Where-Object { $_.name -in $names }); [array]::Reverse($order)   # dependents first
    foreach ($s in $order) { if ((Managed $s) -and (Healthy $e $s)) { Stop-Svc $e $s 'stopped by down'; "[$e] $($s.name) stopped" } }
  }
  'promote' {
    if (-not $Branch) { throw 'promote needs -Branch' }
    $o = @{ hit = @() }
    Update-State $e { param($x) foreach ($rn in @($x.release.repos.Keys)) { foreach ($l in @($x.release.repos[$rn].layers | Where-Object { $_ })) { if ($l.branch -eq $Branch) { $l.promoted = @{ by = $Agent; at = (Now); release = $x.release.n; sha = $l.sha; note = $Note }; $o.hit += $rn } } } }
    if (-not $o.hit) { throw "[$e] $Branch is not live here: deploy it first, test, then promote" }
    Event $e 'promote' @{ agent = $Agent; branch = $Branch; release = (Read-State $e).release.n }
    "[$e] $Branch promoted locally in $($o.hit -join ', ') (release $((Read-State $e).release.n))"
  }
  'logs' { if (-not $Services) { throw 'logs needs -Service' }; $f = LogFile $e $Services[0]; if (Test-Path $f) { Get-Content $f -Tail $Tail } else { "no log yet: $f" } }
  'events' { $f = Join-Path (Get-KitPath localenv-logs) "$e-events.jsonl"; if (Test-Path $f) { Get-Content $f -Tail $Tail } else { 'no events yet' } }
  '_exec' {
    $s = Svc $e $Services[0]; $dir = SvcDir $e $s; $log = LogFile $e $s.name
    $cmd = StartCmd $e $s $Artifact
    foreach ($kv in (EnvVars $e $s).GetEnumerator()) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value) }
    Set-Location $dir
    Add-Content $log "== $(Now) start in $dir : $cmd"
    if ($KitIsWindows) { $bat = Join-Path (Get-KitPath localenv -Create) "run/$e-$($s.name).cmd"; New-Item -ItemType Directory -Force (Split-Path $bat) | Out-Null; Set-Content -LiteralPath $bat "@echo off`r`n$cmd >> `"$log`" 2>&1" -Encoding ascii; & cmd.exe /d /c "`"$bat`"" }
    else { & /bin/sh -c "$cmd >> '$log' 2>&1" }
    Add-Content $log "== $(Now) exited $LASTEXITCODE"
  }
}
}

if ($MyInvocation.InvocationName -eq '.') { }   # dot-sourced (tests): functions only
elseif ($__verb -eq '_daemon') { Invoke-KitVerb Invoke-Daemon @($args | Select-Object -Skip 1) }
elseif (-not $__verb) { Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1; exit 2 }
else {   # usage errors exit 2; any other crash exits 1 (Invoke-KitVerb)
  $KitVerbOnError = { param($e) $m = "$($e.Exception.Message)"; if ($m -match 'unknown env|-Env needed|No local environments configured|needs -') { [Console]::Error.WriteLine("localenv.ps1: $m"); exit 2 } }
  Invoke-KitVerb Invoke-LocalEnv @($args)
}
