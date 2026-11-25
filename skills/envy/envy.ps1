<#
envy.ps1: ONE shared local instance per env (kit.local.json localEnv.envs) that agents deploy branches to, test and debug
on; a service = a start command in a folder (default crafty.ps1 stack `run`). Model: envy SKILL.md "Local testing".
  & <kit>/skills/envy/envy.ps1 <verb> [args]
Verbs: envs · status · doctor [-Fix] · deploy · wait (-Id | -Until up [-Services] [-Timeout s]) · use -Services <svc,..> (+ deps) | -All · release · promote · task · logs [-Grep <re>] [-Since <min>] · events ·
       migrations · sql -Query (read-only) · dbtemp [-Kill <id>] (temp per db connection; storage.db.use / kill) · mark [-Name <n>] (marks = list) ·
       seed [-Check] · drop -Agent <id> [-Note <why>] | -Stale [-DryRun] (bossy.ps1 release / supervise: layers of a finished agent,
       merged, gone or orphan ones)
       (owner) up -Services [-Owner] · unhold · restart -Services · down -Env <e> | -All · drop -Branch <b> · refresh · teardown · restore -Mark <n> | -Release <n>
       [-Schemas a,b] [-DryRun] [-UseToolRollback] · tenant list | drop -Name <t,..> [-DryRun] | import -From <source> -Tenant <schema>
       [-As <name>] -Mask <profile> [-DryRun] [-Refresh] (adapters/tenant-models.ps1) · cleanup [-Quick] [-DryRun] ·
       lanes -Migrate [-LanesOnly] [-DryRun] | -Sync [-DryRun] (wt-pool.ps1 lanes) ·
       <verb> an adapter registers (kind envy-verb) ·
       _daemon -Env <env> [-Train <id> | -Start <svc> | -Aot <svc>] (controller, workers) · _exec (service wrapper)
Lanes (envs.<env>.lanes.max > 1): -Env <env> = the agent's lane, else (deploy / use / task) the least busy warm one; a cold one past localEnv.lanes.openAfterMinutes of queue wait, with room;
  -Lane <k> pins one; -Env <env><k> names one; a deploy onto a lane another agent leases: a free lane with room, if any.
In: kit.local.json localEnv (envs inherit localEnv.defaults, then envs.<env>.extends; lanes), .state/localenv/<env>.env (secrets).
Out: text; status -Json, envs -Json.
Exit codes: 0 ok · 1 refused / rejected / rolled back / failed / services not up / seed not green / db presets missing · 2 usage
  (unknown env, no localEnv) · 3 still running (wait -Id; use / task got no lease within -Wait).
DB parts (README "Adapters"): db.engine = adapters/db-engines.ps1 (kind db-engine); marks, slices, restore, the cascade guard
  (db.cascadeGuard) = adapters/db-presets.ps1; tenants.model = adapters/tenant-models.ps1 + tenant-schema.ps1 (kind tenant-model);
  db.migrations.tool / migrations.tool = crafty/adapters/<tool>.ps1 (kind migration); db.rollback = any tool command, or the tool's
  name for its tag / rollback (only with db.restoreVia tool-then-kit or restore -UseToolRollback).
Sections: L36 config · L240 state · L287 layer drops · L362 leases · L471 code · L482 migrations ·
  L485 migration tool (kind migration; crafty/adapters/<tool>.ps1) · L634 shared builds · L765 hooks · L839 marks · L1023 seed ·
  L1090 processes · L1454 daemon · L1935 cleanup · L2007 verbs
#>
#Requires -Version 7
$__envyArgs = @($args); if ($__envyArgs.Count -and "$($__envyArgs[0])" -eq 'localenv') { $__envyArgs = @($__envyArgs | Select-Object -Skip 1) }   # agents repeat the old action word: envy.ps1 localenv mark
$__verb = if ($__envyArgs.Count) { [string]$__envyArgs[0] } else { '' }
. (Join-Path (Split-Path $PSScriptRoot) 'crafty/lib.ps1')
# library (dot-sourced by the CLI and _daemon); state per env: Get-KitPath localenv /<env>.json (Update-State)
$ErrorActionPreference = 'Stop'

# ---- config: kit.local.json localEnv, env and service lookups
$script:LE = Get-KitValue 'localEnv' $null
# objects merge deep; lists of named objects merge by name (base order, then new names); anything else: the override wins
function Merge-Cfg($base, $over) {
  if ($null -eq $base) { return $over }; if ($null -eq $over) { return $base }
  if ($base -is [pscustomobject] -and $over -is [pscustomobject]) {
    $o = [ordered]@{}; foreach ($p in (Get-KitProps $base)) { $o[$p.Name] = $p.Value }
    foreach ($p in (Get-KitProps $over)) { $o[$p.Name] = Merge-Cfg $o[$p.Name] $p.Value }
    return [pscustomobject]$o
  }
  $named = { param($l) $l -is [array] -and $l.Count -and -not @($l | Where-Object { $_ -isnot [pscustomobject] -or -not $_.name }).Count }   # [] clears
  if ((& $named $base) -and (& $named $over)) {
    $by = [ordered]@{}; foreach ($x in @($base) + @($over)) { $by[[string]$x.name] = Merge-Cfg $by[[string]$x.name] $x }
    return , @($by.Values)
  }
  $over
}
# envs.<env> = localEnv.defaults <- envs.<extends> <- its own keys; a copy per env (presets write into it)
function Resolve-EnvCfg([string]$n, [string[]]$seen = @()) {
  if ($n -in $seen) { throw "localEnv.envs.$n.extends loops ($(@($seen + $n) -join ' -> '))" }
  $own = (Get-KitMember $script:LE.envs $n); if (-not $own) { throw "localEnv.envs.$($seen[-1]).extends names '$n', which is no env" }
  $base = if ($own.extends) { Resolve-EnvCfg ([string]$own.extends) (@($seen) + $n) } else { $script:LE.defaults }
  $mine = $own | Select-Object * -ExcludeProperty extends
  Merge-Cfg ($base | ConvertTo-Json -Depth 20 | ConvertFrom-Json) ($mine | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}
# every string of a config (objects, lists), rewritten by $fix
function Update-CfgText($o, [scriptblock]$fix) {
  if ($o -is [pscustomobject]) { foreach ($p in @((Get-KitProps $o))) { if ($p.Value -is [string]) { $p.Value = & $fix $p.Value } else { Update-CfgText $p.Value $fix } } }
  elseif ($o -is [array]) { for ($i = 0; $i -lt $o.Count; $i++) { if ($o[$i] -is [string]) { $o[$i] = & $fix $o[$i] } else { Update-CfgText $o[$i] $fix } } }
}
# lane $k of env $g (lanes { max, portStep }; lane 1 = $g, lane k = $g<k>), every lane the same way: ports of services the env
# runs + (k-1) x portStep, then envs.<g><k> keys ($over), then every string: {lane} ('' / k), {port:<svc>}, ":<old port>" -> new
function Get-LaneCfg($base, [string]$g, [int]$k, $over) {
  $c = $base | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $off = ($k - 1) * [int]$(if ($base.lanes.portStep) { $base.lanes.portStep } else { 100 })
  foreach ($s in @($c.services | Where-Object { $_ -and -not ($_.external -and -not $_.start) })) { foreach ($pk in 'port', 'debugPort') { if ((Get-KitMember $s $pk)) { Set-KitMember $s $pk ([int](Get-KitMember $s $pk) + $off) } } }
  if ($over) { $c = Merge-Cfg $c ($over | Select-Object * -ExcludeProperty extends | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
  $map = @{}; $ports = @{}
  foreach ($s in @($c.services | Where-Object { $_.name })) {
    $b = @($base.services | Where-Object name -eq $s.name)[0]; if ($s.port) { $ports[[string]$s.name] = "$($s.port)" }
    foreach ($pk in 'port', 'debugPort') { if ((Get-KitMember $b $pk) -and (Get-KitMember $s $pk) -and "$((Get-KitMember $b $pk))" -ne "$((Get-KitMember $s $pk))") { $map["$((Get-KitMember $b $pk))"] = "$((Get-KitMember $s $pk))" } }
  }
  $lane = if ($k -gt 1) { "$k" } else { '' }; $bird = "$(Get-KitBirdName $k)".ToLower()
  Update-CfgText $c { param([string]$t)
    $t = [regex]::Replace($t.Replace('{lane}', $lane).Replace('{bird}', $bird), '\{port:([\w.-]+)\}', { param($m) if ($ports.ContainsKey($m.Groups[1].Value)) { $ports[$m.Groups[1].Value] } else { $m.Value } })
    if ($map.Count) { $t = [regex]::Replace($t, '(?<=:)\d{2,5}(?!\d)', { param($m) if ($map.ContainsKey($m.Value)) { $map[$m.Value] } else { $m.Value } }) }
    $t }
  if ($c.db.port -and $map.ContainsKey("$($c.db.port)")) { $c.db.port = [int]$map["$($c.db.port)"] }
  $c | Add-Member group $g -Force; $c | Add-Member lane $k -Force; $c
}
if ($script:LE.envs) {
  $__envs = [ordered]@{}; $__res = [ordered]@{}; foreach ($__n in @((Get-KitProps $script:LE.envs).Name)) { $__res[$__n] = Resolve-EnvCfg $__n }
  $__bird = "$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'bird'; $script:EnvAlias = @{}; $script:EnvKeysRaw = @($__res.Keys)   # laneIds "bird": <product>-<bird> (shop-kestrel); "nn": lane-<nn> (wt-pool Get-KitLaneMap)
  $__lm = @{}; $__lanes = @{}; foreach ($__r in @(Get-KitLaneMap)) { $__lm["$($__r.env)|$($__r.k)"] = $__r.id; $__lanes[$__r.id] = $true }
  foreach ($__n in $__res.Keys) { for ($__k = 2; $__k -le [int]$__res[$__n].lanes.max; $__k++) { $__lanes["$__n$__k"] = $true; $__lanes["$__n-$("$(Get-KitBirdName $__k)".ToLower())"] = $true } }
  foreach ($__n in @($__res.Keys | Where-Object { -not $__lanes.ContainsKey($_) })) {   # envs.<lane id> / <env><k> / <env>-<bird> of a laned env: that lane's keys, no env of its own
    for ($__k = 1; $__k -le [math]::Max(1, [int]$__res[$__n].lanes.max); $__k++) { $__old = if ($__k -gt 1) { "$__n$__k" } else { $__n }; $__bd = "$__n-$("$(Get-KitBirdName $__k)".ToLower())"
      $__ln = if ($__lm.Count) { $__lm["$__n|$__k"] ?? $__old } elseif ($__bird) { $__bd } else { $__old }; foreach ($__a in @($__old, $__bd)) { if ($__a -ne $__ln -and ($__bird -or $__lm.Count)) { $script:EnvAlias[$__a] = $__ln } }
      $__ov = if ($__k -gt 1) { @($__ln, $__bd, $__old | ForEach-Object { Get-KitMember $script:LE.envs $_ } | Where-Object { $_ })[0] }; $__envs[$__ln] = Get-LaneCfg $__res[$__n] $__n $__k $__ov }
  }
  $script:LE.envs = [pscustomobject]$__envs
  # a static service runs from a staged copy of its built files, like an artifact
  foreach ($__s in @($__envs.Values | ForEach-Object { @($_.services) } | Where-Object { $_ -and $_.static -and -not $_.artifact })) { $__s | Add-Member artifact ([string]$__s.static) -Force }
}
function Opt([string]$k, $def) { $v = Get-KitSetting "localEnv.$k" $null; if ($null -eq $v) { $def } else { $v } }
$script:LeaseMin = [int](Get-KitParam 'localEnv.leaseMinutes')   # how long a train waits for a lease before it deploys anyway (holders are told)
$script:MaxLeaseMin = [int](Opt 'maxLeaseMinutes' 120)
$script:TrainStallMin = [double](Get-KitParam 'localEnv.trainStallMinutes')   # a train phase with no log line this long hangs: worker killed, requests requeued
$script:EnvLeaseWhy = @{}   # Prune's reason per "leases|<key>" / "holds|<key>" (leases.jsonl)
$script:LeaseIdleMin = [double](Opt 'leaseIdleMinutes' (Get-KitParam 'idle.graceMinutes' 10))   # a lease unused this long is released (learned unless set)
$script:CpuMax = [int](Opt 'cpuMaxPct' 90)
# a busy CPU only delays a start this long (owner 2026-11-19: a 90% CPU held a leased start 55 min); RAM waits roomWaitMinutes
$script:CpuWaitMin = [double](Get-KitParam 'localEnv.cpuWaitMinutes')
$script:RoomWaitMin = [int](Opt 'roomWaitMinutes' 30)   # TODO-PARAM (fixed default)
$script:IdleOn = "$(Opt 'idle.enabled' $true)" -ne 'False'
$script:IdleMinM = [double](Opt 'idle.minMinutes' 15)   # TODO-PARAM (fixed default)
$script:IdleMaxM = [double](Opt 'idle.maxMinutes' 60)   # TODO-PARAM (fixed default)
$script:LoopExitM = [double](Opt 'loopExitMinutes' 10)
$script:LogMaxMB = [double](Opt 'logMaxMB' 100)   # a service log past this (services[].logMaxMB first) moves to .prev (one generation) (TODO-PARAM)
$script:KeepReleases = [int](Opt 'keepReleases' 2)   # staged builds kept per service: live + the previous one (rollback) (TODO-PARAM)
# a start's ready line (services[].readyPattern first): health is checked at once, not at the next 5 s poll (TODO-PARAM)
$script:ReadyPattern = [string](Opt 'readyPattern' '(?i)\bStarted \S+ in [\d.]+ seconds|Application startup complete|Server running at|Compiled successfully|ready in [\d.]+ ?m?s|Now listening on|Listening on')
$script:MigPattern = [string](Opt 'migrationPattern' '(?i)^(?!.*\.(md|txt|rst|adoc)$)(.*/)?(db/)?(changelog|migrations?|migrate|liquibase|flyway|alembic)(/|\.)')
# adapters/ files are dot-sourced in name order (db-engines.ps1 registers the engines db-presets.ps1 fills unset db hooks from)
foreach ($__adapter in Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name) { . $__adapter.FullName }
foreach ($__k in 'db-engine', 'tenant-model', 'migration', 'envy-verb') { if (-not $KitAdapters[$__k]) { $KitAdapters[$__k] = @{} } }   # a kind nobody registered: lookups find nothing, never a null index
$script:OomPattern = 'JavaScript heap out of memory|Reached heap limit'   # also scanned in running services' logs
$script:FailPattern = [string](Opt 'failPattern' "APPLICATION FAILED TO START|Application run failed|EADDRINUSE|Address already in use|Port \d+ is already in use|Failed to bind to|Unhandled exception. System\.|Traceback \(most recent call last\)|panic: |Error: Cannot find module|$script:OomPattern|java\.lang\.OutOfMemoryError")
function Now { (Get-KitStamp) }
function EnvNames { if ($script:LE -and $script:LE.envs) { @((Get-KitProps $script:LE.envs).Name) } else { @() } }
function Get-EnvCfg([string]$e) { $c = (Get-KitMember $script:LE.envs $e); if (-not $c) { $c = (Get-KitMember $script:LE.envs (Resolve-EnvAlias $e)) }; if (-not $c) { throw "unknown env '$e' (configured: $((EnvNames) -join ', '))" }; $c }
function LaneNames([string]$e) { $g = (Get-EnvCfg $e).group; @(EnvNames | Where-Object { (Get-KitMember $script:LE.envs $_).group -eq $g }) }   # lane order
function Get-RepoCfg([string]$name) {
  $name = ($name -split '@', 2)[0]   # an env-repo key <repo>@<target> (RepoOf)
  $r = @(Get-KitValue 'repos' @()) | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1
  if (-not $r) { throw "repo '$name' is not in kit.local.json repos[] (name or alias)" }
  $r
}
function EnvServices([string]$e) { @((Get-EnvCfg $e).services | Where-Object { $_ }) }
function Svc([string]$e, [string]$n) {
  $s = EnvServices $e | Where-Object name -eq $n; if (-not $s) { throw "env $e has no service '$n' ($((EnvServices $e).name -join ', '))" }; $s
}
function Managed($s) { -not ($s.external -and -not $s.start) }
function EnvRepos([string]$e) {
  $map = [ordered]@{}
  $items = @(EnvServices $e) + @(if ((Get-EnvCfg $e).tasks) { (Get-KitProps (Get-EnvCfg $e).tasks).Value })
  foreach ($s in $items | Where-Object { $_.repo }) {
    $rk = RepoOf $e $s; if ($map.Contains($rk)) { continue }
    $r = Get-RepoCfg $s.repo; $t = if ($s.target) { [string]$s.target } else { [string]$r.target }
    $map[$rk] = [pscustomobject]@{ name = $rk; cfg = $r; target = $t; wt = (Get-KitLaneWorktree $e $r.checkout); live = $false }
    if ($rk -ne $r.name) {   # a second target of the repo: its own lane worktree and branch
      $ts = ($t -replace '[^\w.-]+', '-').ToLower(); $map[$rk].wt = Join-Path @($KitConf.WorktreeRoots)[0] "lane-$(Get-KitLaneSlug $e)-$ts-$(Split-Path $r.checkout -Leaf)"
      $map[$rk] | Add-Member branch "$(Get-KitLaneBranch $e)-$ts"; $map[$rk] | Add-Member wtName "lane-$(Get-KitLaneSlug $e)-$ts" }
  }
  foreach ($s in EnvServices $e | Where-Object { $_.repo -and -not $_.artifact }) { $map[(RepoOf $e $s)].live = $true }
  $map
}
# env-repo key: the repo name, or <repo>@<target> for a second target in the env (K61e)
function RepoOf([string]$e, $s) {
  if (-not $s.repo) { return $null }
  $r = Get-RepoCfg $s.repo; $t = if ($s.target) { [string]$s.target } else { [string]$r.target }
  $first = @(@(EnvServices $e) + @(if ((Get-EnvCfg $e).tasks) { (Get-KitProps (Get-EnvCfg $e).tasks).Value }) | Where-Object { $_.repo -and (Get-RepoCfg $_.repo).name -eq $r.name })[0]
  $t0 = if ($first.target) { [string]$first.target } else { [string]$r.target }
  if ($t -eq $t0) { $r.name } else { "$($r.name)@$t" }
}
function SvcDir([string]$e, $s) {
  if (-not $s.repo) { return $(if ($s.dir) { $s.dir } else { $KitConf.Workspace }) }
  $wt = (EnvRepos $e)[(RepoOf $e $s)].wt
  if ($s.dir) { Join-Path $wt $s.dir } else { $wt }
}
function Closure([string]$e, [string[]]$names) {
  $out = [Collections.Generic.List[string]]::new(); $todo = [Collections.Generic.Queue[string]]::new()
  foreach ($n in $names) { $todo.Enqueue($n) }
  while ($todo.Count) { $n = $todo.Dequeue(); if ($out.Contains($n)) { continue }; $out.Add($n); $s = EnvServices $e | Where-Object name -eq $n; foreach ($d in @($s.dependsOn | Where-Object { $_ })) { $todo.Enqueue($d) } }
  @($out)
}
function Dependents([string]$e, [string[]]$names) { @(EnvServices $e | Where-Object { $n = $_.name; @(Closure $e @($n) | Where-Object { $_ -ne $n -and $_ -in $names }).Count } | ForEach-Object name) }
$script:lanIp = $null
function LanIp {
  if (-not $script:lanIp) {
    $script:lanIp = & (Join-Path (Split-Path $PSScriptRoot) 'crafty/flagged.ps1') ipv4 | Where-Object { $_ -notmatch '^(169\.254|127\.)' } | Select-Object -First 1
    if (-not $script:lanIp) { $script:lanIp = '127.0.0.1' }
  }
  $script:lanIp
}
function Expand-Placeholders([string]$t, [string]$e, $s, [string]$dir, [string]$artifact) {
  if (-not $t) { return $t }
  $wt = if ($s.repo) { (EnvRepos $e)[(RepoOf $e $s)].wt } else { '' }
  if ($t -match '\{aot\}') {   # the AOT cache once a training run wrote it (services[].aotUse, default the JDK 24+ option), else nothing
    $af = AotFile $artifact; $t = $t.Replace('{aot}', $(if ($af -and (Test-Path -LiteralPath $af)) { $(if ($s.aotUse) { [string]$s.aotUse } else { '-XX:AOTCache="{aotFile}"' }).Replace('{aotFile}', $af) } else { '' }))
  }
  if ($artifact -and $t.Contains('{javaArgs}')) {   # services[].classpathFile: the argfile of the release being started (its own artifact + libraries)
    $ja = JavaArgsFile $artifact; if (-not (Test-Path -LiteralPath $ja)) { throw "[$e] $($s.name): no java.args next to $artifact (staged before services[].classpathFile was set): deploy again" }
    $t = $t.Replace('{javaArgs}', $ja)
  }
  if ($t -match '\{cache\}') { $t = $t.Replace('{cache}', (Join-Path (Get-KitPath cache -Create) "localenv/$e-$($s.name)")) }   # a build cache outside the repo
  $t.Replace('{port}', "$($s.port)").Replace('{debugPort}', "$($s.debugPort)").Replace('{dir}', $dir).Replace('{wt}', $wt).Replace('{env}', $e).Replace('{lane}', $(if ($t.Contains('{lane}') -and [int](Get-EnvCfg $e).lane -gt 1) { "$((Get-EnvCfg $e).lane)" } else { '' })).Replace('{kit}', $KitConf.Kit).Replace('{workspace}', $KitConf.Workspace).Replace('{artifact}', "$artifact").Replace('{lanIp}', $(if ($t -match '\{lanIp\}') { LanIp } else { '' }))
}
$script:stacks = @{}
function StackOf([string]$dir) {
  if (-not $script:stacks.ContainsKey($dir)) { $script:stacks[$dir] = if ([IO.Path]::IsPathRooted($dir) -and (Test-Path -LiteralPath $dir)) { try { & $KitCmd.dev stack -Dir $dir -Json | ConvertFrom-Json } catch { $null } } }
  $script:stacks[$dir]
}
function StartCmd([string]$e, $s, [string]$artifact) {
  $dir = SvcDir $e $s
  $c = if ($s.start) { [string]$s.start } elseif ($s.static) { "node `"$(StaticServer)`" `"{artifact}`" {port}" } else { (StackOf $dir).commands.run }
  if (-not $c) { throw "service $e/$($s.name): no start command (set services[].start, or commands.run in a .claude-stack.json in $dir)" }
  Expand-Placeholders $c $e $s $dir $artifact
}
function EnvVars([string]$e, $item) {
  $v = [ordered]@{}
  $fs = if ((Get-EnvCfg $e).envFile) { @([string](Get-EnvCfg $e).envFile) } else { @("$((Get-EnvCfg $e).group)", $e | Select-Object -Unique | ForEach-Object { Join-Path (Get-KitPath localenv-env) "$_.env" }) }   # a lane: its env's file, then its own
  foreach ($f in @($fs | Where-Object { Test-Path -LiteralPath $_ })) {
    foreach ($l in Get-Content -LiteralPath $f) {
      if ($l -match '^\s*(#|$)') { continue }
      if ($l -match '^\s*(export\s+)?([A-Za-z_][\w.]*)\s*=\s*(.*?)\s*$') { $v[$Matches[2]] = $Matches[3] -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1' }
    }
  }
  foreach ($src in @((Get-EnvCfg $e).env, $item.env) | Where-Object { $_ }) { foreach ($p in (Get-KitProps $src)) { $v[$p.Name] = "$($p.Value)" } }
  $dir = if ($item.repo -or $item.dir) { SvcDir $e $item } else { $KitConf.Workspace }
  foreach ($k in @($v.Keys)) { $v[$k] = Expand-Placeholders $v[$k] $e $item $dir '' }
  $v
}
# $null or '' unsets (pwsh passes $null to a [string] as '': an unset var came back EMPTY and every child of the loop inherited it)
function Set-EnvVar([string]$k, $v) { if ("$v" -eq '') { [Environment]::SetEnvironmentVariable($k, [NullString]::Value) } else { [Environment]::SetEnvironmentVariable($k, "$v") } }
# _exec: an inherited empty var (a key gone from the env file, an older loop's leak) never reaches a service (Spring reads ''
# as a value); Linux: drops deliberate empties too (NO_COLOR=)
function Clear-EmptyEnv { foreach ($ev in @(Get-ChildItem env: | Where-Object { "$($_.Value)" -eq '' })) { Set-EnvVar $ev.Name '' } }
function With-Env($vars, [scriptblock]$body) {
  $old = @{}; foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); Set-EnvVar $k $vars[$k] }
  try { & $body } finally { foreach ($k in $old.Keys) { Set-EnvVar $k $old[$k] } }
}
function LogFile([string]$e, [string]$n) { Join-Path (Get-KitPath localenv-logs -Create) "$e-$n.log" }
# a failed start's log, kept past the next start's rotation (last 3 per service; TODO-PARAM fixed default) -> "<cause line>. Log: <kept>"
function Save-FailLog([string]$log, $release) {
  $keep = $log -replace '\.log$', ".fail-$(ConvertTo-KitSlug $(if ($release) { $release } else { New-KitId fail -Number })).log"   # NAME-NUMBER: seq
  $t = @(Get-Content -LiteralPath $log -Tail 2000 -ErrorAction SilentlyContinue); Copy-Item -LiteralPath $log $keep -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath (Split-Path $log) -Filter "$([IO.Path]::GetFileNameWithoutExtension($log)).fail-*.log" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
  $c = @($t | Where-Object { $_ -match '^\s*Caused by:' })[-1]; if (-not $c) { $c = @($t | Where-Object { $_ -match '\bERROR\b|Exception' })[0] }
  "$(if ($c) { "Cause: $($c.Trim()). " })Log: $keep"
}
function Event([string]$e, [string]$kind, [hashtable]$data = @{}) {
  $data.env = $e; Write-KitLog env $kind $data
}

# ---- state: one JSON per env, locked writes
function StateFile([string]$e) { Join-Path (Get-KitPath localenv -Create) "$e.json" }
# readers take the file's lock too (Update-State already holds it): an open reader made the writer's rename fail
function Read-State([string]$e) {
  $f = StateFile $e; $st = $null
  if (Test-Path $f) { try { $st = $(if ($script:stateLocked) { Get-Content $f -Raw } else { Invoke-KitLocked $f { Get-Content $f -Raw } }) | ConvertFrom-Json -AsHashtable } catch { Write-Warning "localenv: $f unreadable, starting a fresh state ($_)" } }
  if ($st -isnot [hashtable]) { $st = @{} }
  $st.Remove('sandboxes')   # retired
  foreach ($k in 'services', 'leases', 'holds', 'notices') { if ($st[$k] -isnot [hashtable]) { $st[$k] = @{} } }
  foreach ($k in 'requests', 'releases') { $st[$k] = @(@($st[$k]) | Where-Object { $_ }) }
  if ($st.release -isnot [hashtable]) { $st.release = @{ n = 0; repos = @{} } }
  if ($st.release.repos -isnot [hashtable]) { $st.release.repos = @{} }
  if ($st.layers -is [hashtable] -and -not $st.release.repos.Count) { foreach ($rn in $st.layers.Keys) { $st.release.repos[$rn] = @{ layers = @($st.layers[$rn] | Where-Object { $_ }) } }; $st.Remove('layers') }
  $st
}
function Update-State([string]$e, [scriptblock]$Change) {
  $f = StateFile $e
  Invoke-KitLocked $f {
    $script:stateLocked = $true
    try { $__state = Read-State $e } finally { $script:stateLocked = $false }
    $__was = $__state | ConvertTo-Json -Depth 10; $script:EnvLeaseWhy = @{}; $__had = @{}; foreach ($k in 'leases', 'holds') { foreach ($n in @($__state[$k].Keys)) { $__had["$k|$n"] = $__state[$k][$n] } }
    & $Change $__state
    $__json = $__state | ConvertTo-Json -Depth 10
    if ($__json -ceq $__was -and (Test-Path $f)) { return }   # nothing changed: no write (the loop calls this every tick)
    $__json | Set-Content "$f.tmp" -Encoding utf8
    for ($i = 0; ; $i++) { try { [IO.File]::Move("$f.tmp", $f, $true); break } catch [IO.IOException], [UnauthorizedAccessException] { if ($i -ge 100) { throw }; [Threading.Thread]::Sleep(50) } }   # an open reader (Windows: access denied) blocks the rename; a real wait
    try { foreach ($k in 'leases', 'holds') {   # leases.jsonl: every lease / hold that came or went (README "Leases"); never fails a write
      foreach ($n in @($__state[$k].Keys | Where-Object { -not $__had.ContainsKey("$k|$_") })) { $l = [hashtable]::new($__state[$k][$n]); if (-not $l.agent) { $l.agent = $n }; Write-KitLeaseLog acquire env $e $l }
      foreach ($hk in @($__had.Keys | Where-Object { $_ -like "$k|*" -and -not $__state[$k].ContainsKey($_.Substring($k.Length + 1)) })) { $l = [hashtable]::new($__had[$hk]); if (-not $l.agent) { $l.agent = $hk.Substring($k.Length + 1) }; Write-KitLeaseLog release env $e $l $script:EnvLeaseWhy[$hk] }
    } } catch {}
  }
}
function Alive($p) { $p -and [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }
function PStart($p) { try { (Get-Process -Id ([int]$p) -ErrorAction Stop).StartTime } catch { $null } }
# a recorded process (pid + pstart): a reused pid is not ours; an old record without pstart: its command line must hold $Tag
function Owned($x, [string]$Tag) {
  if (-not ($x -and $x.pid -and (Alive $x.pid))) { return $false }
  if ($x.pstart) { return Test-KitPid $x.pid $x.pstart }
  -not $Tag -or (CmdLine ([int]$x.pid)).Contains($Tag)
}
function Mine([int]$p) { @{ pid = $p; pstart = "$(Get-KitPidStart $p)" } }
function CmdLine([int]$p) { if ($KitIsWindows) { "$((Get-CimInstance Win32_Process -Filter "ProcessId=$p" -Property CommandLine -ErrorAction SilentlyContinue).CommandLine)" } else { "$(ps -o args= -p $p 2>$null)" } }
function EnvProcess([int]$p, [string]$e) {
  $c = CmdLine $p
  $c -and ($c.Contains((Get-KitPath localenv)) -or $c -match [regex]::Escape("localenv-$e-") -or $c -match [regex]::Escape("lane-$(Get-KitLaneSlug $e)-") -or $c -match [regex]::Escape("_exec -Env $e "))
}
function Layers($st, [string]$rn) { @($st.release.repos[$rn].layers | Where-Object { $_ }) }
# ---- layer drops: release (finished), supervise (merged, gone, orphan); each queued with its reason (leases.jsonl kind env-layer)
# paused or handed off (its newest board entry): its successor keeps its layers
function Test-Parked([string]$a) { $b = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.agent -eq $a } | Sort-Object { "$($_.beat)" })[-1]; if (-not $b) { return $false }; if ($b.paused -or $b.handoffBrief) { return $true }
  # an open PAUSE on its run: the pause steps release leases before board leave -Status paused (a resume had to redeploy, 2026-11-20)
  # a row already left without paused = finished: its layers go
  $b.status -ne 'left' -and [bool]@(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' -and ($_.run -eq "$($b.run)" -or ($_.run -eq '*' -and "$($b.run)" -notin @($_.released))) }).Count }
# one drop request per branch; nobody leases or holds the env: it waits for the next lease or request (no rebuild while idle)
function Add-LayerDrops([string]$e, [object[]]$drops) {
  $o = @{ out = @() }
  Update-State $e { param($x)
    Prune $x
    $pending = @($x.requests | Where-Object { $_.kind -eq 'drop' -and $_.status -ne 'done' } | ForEach-Object branch)
    $due = -not $x.leases.Count -and -not $x.holds.Count
    foreach ($dp in @($drops)) {
      if ($dp.branch -in $pending) { continue }; $pending += $dp.branch
      $id = [guid]::NewGuid().ToString('n').Substring(0, 8)
      $x.requests = @($x.requests) + @(@{ id = $id; kind = 'drop'; branch = $dp.branch; agent = $dp.agent; by = $Agent; why = $dp.why; at = (Now); status = $(if ($due) { 'deferred' } else { 'queued' }) })
      $o.out += "[$e] drop $($dp.branch) $(if ($due) { 'due on the next lease' } else { "queued as $id" }): $($dp.why)"
    }
  }
  if (@($o.out).Count -and @((Read-State $e).requests | Where-Object status -eq 'queued').Count) { Ensure-Loop }   # Ensure-Loop, Wait-Request: the verbs' (Invoke-LocalEnv)
  $o.out
}
# leases.jsonl kind env-layer, name <env>/<repo>: a layer that went live (acquire) or left (release, reason "<merged|finished|orphan|...>: <branch> ...")
function Write-LayerLog([string]$e, [string]$rn, [object[]]$was, [object[]]$kept, [object[]]$reqs, [hashtable]$dropWhy) {
  $keptB = @($kept | ForEach-Object branch); $wasB = @($was | ForEach-Object branch)
  foreach ($l in @($kept | Where-Object { $_.branch -notin $wasB })) { Write-KitLeaseLog acquire env-layer "$e/$rn" @{ agent = $l.agent; since = $l.at } "layer: $($l.branch)" }
  foreach ($l in @($was | Where-Object { $_.branch -notin $keptB })) {
    $q = @($reqs | Where-Object { $_.kind -eq 'drop' -and $_.branch -eq $l.branch })[0]; $sw = "$($dropWhy["$rn|$($l.branch)"])"
    $why = if ($q.why) { $q.why } elseif ($sw -like 'merged*') { "merged: $($l.branch) $sw" } elseif ($sw -eq 'branch and commit gone') { "orphan: $($l.branch) $sw" } elseif ($sw) { "conflict: $($l.branch) $sw" } elseif ($q) { "drop: $($l.branch) by $($q.agent)" } else { "left: $($l.branch)" }
    Write-KitLeaseLog release env-layer "$e/$rn" @{ agent = $l.agent; since = $l.at } $why
  }
}
# status "recent": the env's last 3 layer drops from leases.jsonl
function Get-LayerDrops([string]$e) {
  $lf = Get-KitLogFile leases; if (-not (Test-Path -LiteralPath $lf)) { return }
  @(Get-Content -LiteralPath $lf | Where-Object { $_ -match '"env-layer"' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.event -ne 'acquire' -and "$($_.name)" -like "$e/*" } | Select-Object -Last 3 | ForEach-Object { "layer $($_.reason) ($($_.agent), $(([datetime]$_.at).ToString('HH:mm')))" })
}
# the env's deferred drops queued now; -Wait: until they are live (a lease starts on the refreshed code)
function Wake-Deferred([string]$e, [switch]$UntilDone) {   # not -Wait: Wait-Request reads the verb's [double]$Wait through the caller's scope
  $o = @{ ids = @() }
  Update-State $e { param($x) foreach ($q in @($x.requests | Where-Object { $_.status -eq 'deferred' })) { $q.status = 'queued'; $o.ids += $q.id } }
  if (-not $o.ids.Count) { return }
  Ensure-Loop; if ($UntilDone) { foreach ($id in $o.ids) { $null = Wait-Request $id } }
}
# stale layers: merged into the target, branch gone from origin, or no live holder past idle.graceMinutes (paused / handed off: kept)
function Get-StaleLayers([string]$e, [switch]$DryRun) {   # -DryRun: reads only (no grace clock starts)
  $st = Read-State $e; $envRepos = EnvRepos $e; $why = @{}
  $pending = @($st.requests | Where-Object { $_.kind -eq 'drop' -and $_.status -ne 'done' } | ForEach-Object branch)
  foreach ($rn in @($st.release.repos.Keys)) {
    $r = $envRepos[$rn]; $ls = @(Layers $st $rn | Where-Object { $_.branch -notin $pending }); if (-not $r -or -not $ls.Count) { continue }
    $d = if (Test-Path (Join-Path $r.wt '.git')) { $r.wt } else { $r.cfg.checkout }
    git -C $d fetch -q origin $r.target 2>$null | Out-Null; $fetched = $LASTEXITCODE -eq 0
    $heads = @(git -C $d ls-remote --heads origin @($ls.branch) 2>$null); $listed = $LASTEXITCODE -eq 0
    foreach ($l in $ls) {
      $mw = if ($fetched -and $l.sha) { Get-MergedWhy $d $l.branch $l.sha $r.target "origin/$($r.target)" }
      $why["$rn|$($l.branch)"] = if ($mw) { "merged: $($l.branch) $mw" } elseif ($listed -and -not @($heads -match "\srefs/heads/$([regex]::Escape($l.branch))$").Count -and -not $(git -C $d rev-parse -q --verify "refs/heads/$($l.branch)" 2>$null)) { "orphan: $($l.branch) is gone from origin" }   # a local, unpushed branch stays
    }
  }
  $judge = { param($x)   # each layer's holder keeps its grace clock in the state
    foreach ($rn in @($x.release.repos.Keys)) { foreach ($l in @(Layers $x $rn)) {
      if ($why["$rn|$($l.branch)"] -or $l.branch -in $pending -or -not $l.agent -or (Test-Parked $l.agent)) { continue }
      if ($DryRun) { $h = if ($l.holder) { [hashtable]::new($l.holder) } else { @{ agent = $l.agent } }; $gm = [double]$(if ($h.graceMin) { $h.graceMin } else { Get-KitParam 'idle.graceMinutes' 10 })
        if (-not (Test-KitLive $h) -and $h.seen -and ((Get-Date) - [datetime]$h.seen).TotalMinutes -ge $gm) { $why["$rn|$($l.branch)"] = "orphan: $($l.branch) has no live holder ($($l.agent)) for $gm min" }; continue }
      if (-not $l.holder) { $l.holder = @{ agent = $l.agent } }
      if (-not (Update-KitLease $l.holder)) { $why["$rn|$($l.branch)"] = "orphan: $($l.branch) has no live holder ($($l.agent)) for $($l.holder.graceMin) min" }
    } }
  }
  if ($DryRun) { & $judge $st } else { Update-State $e $judge }
  $st = Read-State $e
  foreach ($g in @(foreach ($rn in @($st.release.repos.Keys)) { foreach ($l in @(Layers $st $rn)) { [pscustomobject]@{ branch = $l.branch; agent = $l.agent; why = $why["$rn|$($l.branch)"] } } }) | Group-Object branch) {
    if (-not @($g.Group | Where-Object { -not $_.why }).Count) { @{ branch = $g.Name; agent = $g.Group[0].agent; why = $g.Group[0].why } }   # every repo's layer of the branch is stale
  }
}

# ---- leases: holds, demand; a lease ends at its time, with no live holder past the grace (Update-KitLease), or unused for leaseIdleMinutes
function Prune($st) {
  foreach ($a in @($st.leases.Keys)) {
    $l = $st.leases[$a]
    if (-not (Update-KitLease $l)) { $st.leases.Remove($a); $script:EnvLeaseWhy["leases|$a"] = $(if ($l.graceMin) { "reclaim: no live holder for $($l.graceMin) min" } else { 'owner lease ended' }); continue }
    if (-not $l.owner -and $l.lastUse -and ((Get-Date) - [datetime]$l.lastUse).TotalMinutes -ge $script:LeaseIdleMin) {   # nobody uses it: trains need not wait, services may idle
      if (Test-KitAgentBusy $(if ($l.agent) { "$($l.agent)" } else { ($a -split '/')[0] })) { $l.lastUse = (Now); continue }   # its check runs (gate, browser.mjs): a use
      $st.leases.Remove($a); $script:EnvLeaseWhy["leases|$a"] = "unused for $($script:LeaseIdleMin) min"; Set-Notice $st $(if ($l.agent) { $l.agent } else { $a }) "lease on $(@($l.services) -join ',') released: unused for $($script:LeaseIdleMin) min (use again to re-lease)"
    }
  }
  foreach ($a in @($st.holds.Keys)) { if (-not (Update-KitLease $st.holds[$a])) { $script:EnvLeaseWhy["holds|$a"] = $(if ($st.holds[$a].graceMin) { "reclaim: no live holder for $($st.holds[$a].graceMin) min" } else { 'owner hold ended' }); $st.holds.Remove($a) } }
  if ($st.notices -isnot [hashtable]) { $st.notices = @{} }
  foreach ($a in @($st.notices.Keys)) { if (((Get-Date) - [datetime]$st.notices[$a].at).TotalHours -ge 2) { $st.notices.Remove($a) } }
  $st.requests = @($st.requests | Where-Object { $_.status -ne 'done' -or ((Get-Date) - [datetime]$_.at).TotalHours -lt 24 } | Select-Object -Last 60)
  $t = $st.train; $stall = if ($t) { TrainStall $st $e }
  if ($t -and ($stall -or (-not (Owned $t "-Train $($t.id)") -and ($t.pid -or ((Get-Date) - [datetime]$t.at).TotalSeconds -gt 60)))) {
    if ($stall -and (Owned $t "-Train $($t.id)")) { if ($KitIsWindows) { taskkill /PID $t.pid /T /F 2>&1 | Out-Null } else { Stop-SysProcess ([int]$t.pid) } }
    $why = if ($stall) { $stall } else { 'worker gone (or its pid reused)' }; $failed = @()
    foreach ($r in $st.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($t.requests)) {   # worker died or hung: the train runs again; a crash loop ends too
      $r.stalls = [int]$r.stalls + 1
      if ([int]$r.stalls -ge $(if ($stall) { 2 } else { 3 })) { $r.status = 'done'; $r.result = @{ outcome = 'failed'; message = "train stalled or died $($r.stalls) times: $why" }; $failed += $r.id } else { $r.status = 'queued' }
    } }
    $st.trainDead = @{ id = $t.id; phase = $t.phase; why = $why; at = (Now); requests = @($t.requests); failed = $failed }   # supervise: TRAIN STALLED
    if ("$($t.phase)" -match '^restore to (\S+): \d+ structure') { $st.halfRestored = @{ mark = $Matches[1]; at = (Now); why = "train $($t.id) died in '$($t.phase)': $why" } }
    Event $e 'train-dead' @{ id = $t.id; pid = $t.pid; phase = $t.phase; why = $why; failed = $failed }
    $st.train = $null
  }
}
# a train quiet (no phase change, no train / build / migrations / smoke log line) for trainStallMinutes hangs; lease waits have their
# own clock; a loop that has not beaten for 3 min (laptop asleep, loop dead) judges nothing: its next tick restarts the clock
function TrainQuietMin($t, [string]$e) {
  $logs = @(Get-ChildItem -LiteralPath (Get-KitPath localenv-logs -Create) -Filter "$e-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$([regex]::Escape($e))-(train(-\w+)?|.+-build|migrations|smoke)\.log$" })
  $last = @(@($t.phaseAt, $t.at) + @($logs.LastWriteTime) | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1]
  if ($last) { [int]((Get-Date) - $last).TotalMinutes } else { 0 }
}
function TrainStall($st, [string]$e) {
  $t = $st.train; if ("$($t.phase)" -like 'waiting for leases*' -or -not $st.loop.beat -or ((Get-Date) - [datetime]$st.loop.beat).TotalMinutes -ge 3) { return $null }
  $q = TrainQuietMin $t $e; if ($q -ge $script:TrainStallMin) { "phase '$($t.phase)' quiet $q min (localEnv.trainStallMinutes $($script:TrainStallMin))" }
}
function Set-Notice($st, [string]$agent, [string]$text) { if ($st.notices -isnot [hashtable]) { $st.notices = @{} }; $st.notices[$agent] = @{ at = (Now); text = $text } }   # status -Agent shows it
# a use of the lease (use, status / logs / events / deploy / wait by its agent, client traffic on its services): resets its idle clock
function Touch-Lease([string]$e, [string]$agent) {
  $st = Read-State $e; $l = $st.leases[$agent]
  if (-not $l -or $l.owner -or ($l.lastUse -and ((Get-Date) - [datetime]$l.lastUse).TotalSeconds -lt 30)) { return }
  Update-State $e { param($x) if ($x.leases[$agent]) { $x.leases[$agent].lastUse = (Now) } }
}
# the holders' board inbox (bossy.ps1 board msg) + their status -Agent notice
function Send-LeaseNotice([string]$e, [string[]]$keys, [string]$text) {
  $who = @{}
  Update-State $e { param($x) foreach ($k in $keys) { $a = if ($x.leases[$k].agent) { [string]$x.leases[$k].agent } else { ($k -split '/')[0] }; $who[$a] = $true; Set-Notice $x $a $text } }
  foreach ($a in $who.Keys) { $null = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.orch, 'board', 'msg', '-Agent', "localenv-$e", '-To', $a, '-Text', "[$e] $text") 30 }
  Event $e 'lease-notice' @{ agents = @($who.Keys); text = $text }
}
# a train waits for the leases on what it changes at most leaseMinutes (one clock per train); then it tells every holder and goes on
$script:Preempted = @(); $script:LeaseWait0 = $null; $script:DoneWord = 'deploy'
function Wait-Leases([string]$e, [string[]]$services, [string[]]$repos, [string[]]$skipAgents) {
  $said = $null; $held = @(); $w0 = $null   # this call's holders and wait start: one lease-wait event when it ends (supervise lease waits)
  $logWait = { if ($held.Count) { Event $e 'lease-wait' @{ services = @($services); holders = @($held); min = [math]::Round(((Get-Date) - $w0).TotalMinutes, 1) } } }
  while ($true) {
    $o = @{ who = @() }
    Update-State $e { param($x)
      Prune $x
      $queued = @($x.requests | Where-Object { $_.kind -eq 'deploy' -and $_.status -eq 'queued' } | ForEach-Object agent)   # blocked in envy deploy behind this train: not testing, never waited for
      $o.who = @($x.leases.Keys | Where-Object { $_ -notin $skipAgents -and $_ -notin $script:Preempted -and $_ -notin $queued } | Where-Object { $l = $x.leases[$_]; @($l.services | Where-Object { $_ -in $services }).Count -or @($l.repos | Where-Object { $_ -in $repos }).Count })
      if ($o.who.Count -and -not $script:LeaseWait0) { $script:LeaseWait0 = Get-Date }   # one clock per train, from the first blocking lease
      if ($x.train) { $x.train.waitingFor = @($o.who); $x.train.waitSince = $(if ($script:LeaseWait0) { Get-KitStamp stored $script:LeaseWait0 }) }
    }
    if (-not $o.who.Count) { & $logWait; return }
    $held = @(@($held) + @($o.who) | Select-Object -Unique); if (-not $w0) { $w0 = Get-Date }; $waited = ((Get-Date) - $script:LeaseWait0).TotalMinutes; $on = @(@($services) + @($repos) | Where-Object { $_ }) -join ', '
    if ($waited -ge $script:LeaseMin) {
      Send-LeaseNotice $e $o.who "deploy of $on starting (a train waited $([int]$waited) min, leaseMinutes $($script:LeaseMin)): pause your checks there; resume after 'deploy done'"
      $script:Preempted = @(@($script:Preempted) + @($o.who) | Select-Object -Unique)
      "[$e] told $($o.who -join ', ') after $([int]$waited) min: deploying while their leases stay"
      & $logWait; return
    }
    $msg = "waiting for lease(s) of $($o.who -join ', ') on $on (at most $($script:LeaseMin) min)"; if ($msg -ne $said) { "[$e] $msg"; $said = $msg }
    Start-Sleep 5
  }
}
function Leased($why) { [bool]@($why | Where-Object { "$_" -match '^(lease|hold):' }).Count }
# a service in start backoff (failed, 3 starts / 30 min) gets a fresh try: a new release staged for it, an asked restart
function Clear-StartBackoff($v, [string]$why) { if ($v -and $v.status -eq 'failed') { $v.status = 'down'; $v.restarts = @(); $v.why = "${why}: backoff cleared (was: $($v.why))" } }
function IdleWhy([double]$min, [string]$pressure) { if ($pressure) { "idle, stopped under memory pressure ($pressure)" } else { "idle: no holder for $min min (starts on the next lease)" } }
# the services a train protects from idle stops: none while it only waits for leases (it changes nothing yet)
function Get-IdleBlock($st, [string]$e) {   # + the env's own DB: a train's marks, slices and migration checks need it
  if (-not $st.train -or "$($st.train.phase)" -like 'waiting for leases*') { return @() }
  @(@($st.train.blockServices) + @(if ($e) { (DbSvc $e).name }) | Where-Object { $_ } | Select-Object -Unique)
}
# up, unneeded, no dependent up, starting, waiting or in a train, past the idle grace (or any idle one under pressure); biggest first
function Get-IdleServices([string]$e, $st, $need, [string[]]$block, [string]$pressure) {
  @(EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -eq 'up' -and -not $need[$_.name] -and $_.name -notin $block } | Where-Object {
      $n = $_.name; $x = $st.services[$n]
      $since = [datetime]$(if ($x.lastNeed) { $x.lastNeed } elseif ($x.upAt) { $x.upAt } else { (Now) })
      -not @(Dependents $e @($n) | Where-Object { $v = $st.services[$_]; $v.status -in 'up', 'starting' -or ($v.status -eq 'waiting' -and (Test-KitPid $v.waitPid $v.waitStart)) -or $_ -in $block }).Count -and ($pressure -or ($script:IdleOn -and ((Get-Date) - $since).TotalMinutes -ge (GraceMin $e $_)))
    } | Sort-Object { -[double]$st.services[$_.name].gb })
}
# established clients of a port from one connection snapshot per 2 s; -Any: headless browsers too (lease use, not demand)
$script:EstabSnap = $null
function ClientPids([int]$port, [int[]]$exclude, [switch]$Any) {
  $pids = if ($KitIsWindows) {
      if (-not $script:EstabSnap -or ((Get-Date) - $script:EstabSnap.at).TotalSeconds -gt 2) { $script:EstabSnap = @{ at = Get-Date; c = @(Get-KitTcpRows | Where-Object { $_.OwningProcess -and $_.RemotePort -and $_.State -notmatch '^(TIME_|CLOSE|FIN_|LAST_|SYN_)' }) } }   # localized: counts
      @($script:EstabSnap.c | Where-Object RemotePort -eq $port | ForEach-Object OwningProcess) }
    elseif (Resolve-Tool ss) { @([regex]::Matches("$(ss -tnpH state established "( dport = :$port )" 2>$null)", 'pid=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }) }
    elseif (Resolve-Tool lsof) { @(lsof -nP "-iTCP@127.0.0.1:$port" -sTCP:ESTABLISHED -Fp 2>$null | Where-Object { $_ -match '^p\d+$' } | ForEach-Object { [int]$_.Substring(1) }) }
  $pids = @($pids | Where-Object { $_ -and $_ -notin $exclude } | Select-Object -Unique)
  if (-not $pids -or $Any) { return @($pids) }
  $ps = if ($KitIsWindows) { @(Get-CimInstance Win32_Process -Filter ("ProcessId=" + ($pids -join ' OR ProcessId=')) -Property ProcessId, CommandLine -ErrorAction SilentlyContinue | ForEach-Object { @{ Id = $_.ProcessId; CommandLine = $_.CommandLine } }) } else { Get-SysProcs }
  @($ps | Where-Object { $_.Id -in $pids -and "$($_.CommandLine)" -notmatch '--headless' } | ForEach-Object { $_.Id })
}
# ---- code: worktrees, layers, builds
function G([string]$d) { $o = & git -C $d @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' ') in $d : $o" }; $o }
function NoHooksDir { $d = Join-Path (Get-KitPath localenv -Create) '.no-hooks'; New-Item -ItemType Directory -Force $d | Out-Null; $d }   # local-only merges, never pushed
function Resolve-Ref([string]$d, [string]$b) {
  foreach ($ref in "refs/heads/$b", "refs/remotes/origin/$b") { $x = git -C $d rev-parse -q --verify "$ref^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() } }
  git -C $d fetch -q origin $b 2>$null | Out-Null
  $x = git -C $d rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>$null; if ($LASTEXITCODE -eq 0 -and $x) { return "$x".Trim() }
  $null
}
function HasMigrations([string]$checkout, [string]$target, [string]$sha) { $d = @(git -C $checkout diff --name-only "origin/$target...$sha" 2>$null); if ($LASTEXITCODE) { return $true }; [bool]($d -match '(^|/)((deploy|revert)/[^/]+|\d+[_.-][^/]*)\.sql$|(^|/)versions/\w+\.py$' -or $d -match $script:MigPattern) }

# ---- migrations: a layer or a target change with migrations changes the shared DB; its release mark keeps what its DDL destroys
#      (slices: the CREATE text of each touched table, + the rows of a dropped / retyped column or a dropped table); restore undoes it
function MigRoot([string]$e) { Join-Path (Get-KitPath localenv -Create) "slices/$e" }
# ---- migration tool (kind migration; crafty/adapters/<tool>.ps1): db.migrations { tool, sets, runAt, cmd }; tool default
#      migrations.tool, else the adapter db.rollback names, else none (no tool verbs: touched tables from the changed files)
function Get-MigTool([string]$e) {
  $db = (Get-EnvCfg $e).db; $t = if ($db.migrations.tool) { $db.migrations.tool } else { Get-KitSetting 'migrations.tool' $null }
  if (-not $t -and $db.rollback -and $KitAdapters['migration']["$($db.rollback)".ToLower()]) { $t = $db.rollback }
  if ($t) { "$t".ToLower() } else { 'none' }
}
function Test-MigVerb([string]$tool, [string]$verb) { $ad = $KitAdapters['migration'][$tool]; [bool]($ad -and $ad[$verb] -is [scriptblock]) }
function Invoke-MigVerb([string]$tool, [string]$verb, [hashtable]$a) { if (-not (Test-MigVerb $tool $verb)) { throw "migration ${tool}: verb $verb not implemented" }; & $KitAdapters['migration'][$tool][$verb] $a $verb }
# the tenant registry's scope (tenants.registry.schema or tenants.schema): tagged first, rolled back last
function Get-RegistryScope([string]$e) { $t = (Get-EnvCfg $e).tenants; if ($t.registry) { $t = $t.registry }; if ($t.schema) { [string]$t.schema } }
# the env's migration sets: db.migrations.sets [{ name, tool, repo, changelog | dir, searchPath, schemas | schemasQuery, registry }]
# (paths relative to the repo's service folder), else the tool's discover verb -> { name, tool, repo, base, changelog, dir, searchPath,
# schemas, registry, ambiguous (several masters, no sets: tag / rollback / touched refuse) }
function Resolve-MigSets([string]$e) {
  $tool = Get-MigTool $e; $cfg = (Get-EnvCfg $e).db.migrations; $reg = Get-RegistryScope $e
  $dirs = @(EnvServices $e | Where-Object { $_.repo } | ForEach-Object { try { [pscustomobject]@{ repo = RepoOf $e $_; dir = SvcDir $e $_ } } catch { } } | Where-Object { $_ -and $_.dir })
  $sets = @($cfg.sets | Where-Object { $_ })
  $hist = $null   # scopes holding the tool's history table: a registry row without schema or history is none
  if ($sets.Count -and $tool -ne 'none' -and (Test-MigVerb $tool 'historyScopes')) { $hist = try { @(Invoke-MigVerb $tool 'historyScopes' @{ e = $e }) } catch { $null } }
  if (-not $sets.Count) { if ($tool -eq 'none' -or -not (Test-MigVerb $tool 'discover')) { return @() }; return @(Invoke-MigVerb $tool 'discover' @{ e = $e; dirs = $dirs; registry = $reg }) }
  foreach ($s in $sets) {
    $rel = [string]$(if ($s.changelog) { $s.changelog } else { $s.dir }); $cand = @($dirs | Where-Object { -not $s.repo -or $_.repo -eq $s.repo })
    $b = @($cand | Where-Object { $rel -and (Test-Path -LiteralPath (Join-Path $_.dir $rel)) })[0]; if (-not $b) { $b = $cand[0] }   # not checked out yet: the first
    $full = { param($x) if ($x -and $b) { [IO.Path]::GetFullPath((Join-Path $b.dir ([string]$x))) } }
    $sc = @($s.schemas | Where-Object { $_ } | ForEach-Object { "$_" }); if ($s.schemasQuery) { $sc += @(Invoke-DbSql $e ([string]$s.schemasQuery) | ForEach-Object { $_[0] }) }
    $sc = @($sc | Where-Object { $_ -and ($null -eq $hist -or $_ -in $hist) } | Select-Object -Unique)
    [pscustomobject]@{ name = [string]$s.name; tool = $(if ($s.tool) { "$($s.tool)".ToLower() } else { $tool }); repo = $b.repo; base = $b.dir; changelog = & $full $s.changelog; dir = & $full $s.dir
      searchPath = & $full $s.searchPath; schemas = $sc; registry = [bool]($s.registry -or ($reg -and $reg -in $sc)); ambiguous = @(); masters = @() }
  }
}
# sets in run order: the registry's set and scope first (tag), last with -Rollback; several masters without sets refuse
function Get-OrderedMigSets([string]$e, [switch]$Rollback) {
  $sets = @(Resolve-MigSets $e); $amb = @($sets | Where-Object { @($_.ambiguous).Count })
  if ($amb.Count) { throw "several migration masters ($(@($amb | ForEach-Object { $_.ambiguous }) -join ', ')) and no db.migrations.sets: refused (one set per master: name, changelog, schemas | schemasQuery)" }
  $reg = Get-RegistryScope $e; $o = @(@($sets | Where-Object registry) + @($sets | Where-Object { -not $_.registry }))
  foreach ($s in $o) { $x = @(@($s.schemas | Where-Object { $_ -eq $reg }) + @($s.schemas | Where-Object { $_ -ne $reg })); if ($Rollback) { [array]::Reverse($x) }; $s.schemas = $x }
  if ($Rollback) { [array]::Reverse($o) }
  , $o
}
# db.rollback names the tool (or "tool"): its tag before a release's migrations, its rollback on restore -UseToolRollback
function Test-MigToolRollback([string]$e) { $rb = "$((Get-EnvCfg $e).db.rollback)".ToLower(); $t = Get-MigTool $e; [bool]($rb -and $t -ne 'none' -and $rb -in 'tool', $t -and (Test-MigVerb $t 'tag')) }
function Invoke-MigTagRollback([string]$e, [string]$verb, [string]$tag) {
  $sets = try { @(Get-OrderedMigSets $e -Rollback:($verb -eq 'rollback')) } catch { return "$_" }
  if (-not $sets.Count) { return "no migration set (db.migrations.tool $(Get-MigTool $e))" }
  $done = @()
  foreach ($s in $sets) {
    $err = try { Invoke-MigVerb $s.tool $verb @{ e = $e; set = $s; tag = $tag } } catch { "$_" }
    if ($err) { return "$err$(if ($done.Count) { "; PARTLY: already done on set(s) $($done -join ', ')" })" }
    $done += $s.name
  }
  $null
}
# tables / columns the migrations between $base and $head of repo $rn change: db.migrateSql (the tool's dry-run SQL, run in the
# repo's service folder of the env worktree), else each set's pendingSql (its first scope), else every table the changed migration
# files name (a superset; files under a set's dir count too)
function Get-MigTouched([string]$e, [string]$rn, [string]$base, [string]$head) {
  $r = (EnvRepos $e)[$rn]; $db = (Get-EnvCfg $e).db; $files = @(); $via = @()
  $s = @(EnvServices $e | Where-Object { $_.repo -and (RepoOf $e $_) -eq $rn })[0]; $dir = if ($s) { SvcDir $e $s } else { $r.wt }
  $sets = @(if (-not $db.migrateSql -and (Get-MigTool $e) -ne 'none') { Resolve-MigSets $e | Where-Object { -not $_.repo -or $_.repo -eq $rn } })
  if (@($sets | Where-Object { @($_.ambiguous).Count }).Count) { throw "several migration masters ($(@($sets.ambiguous) -join ', ')) in $rn and no db.migrations.sets: the touched tables are unknown" }
  if ($db.migrateSql) {
    $f = Join-Path (MigRoot $e) "pending-$rn.sql"; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
    $code = Invoke-Shell "$(Expand-Placeholders ([string]$db.migrateSql) $e $(if ($s) { $s } else { [pscustomobject]@{ port = '' } }) $dir '') > `"$f`"" (LogFile $e 'migrations') (EnvVars $e ([pscustomobject]@{})) 600
    if (-not $code -and (Test-Path $f)) { $files = @($f); $via = @('db.migrateSql') }
  } else {
    foreach ($ms in @($sets | Where-Object { @($_.schemas).Count -and (Test-MigVerb $_.tool 'pendingSql') })) {   # the pending SQL of the set's first scope (the others run the same changelog)
      $f = Join-Path (MigRoot $e) "pending-$rn-$(ConvertTo-KitSlug $ms.name).sql"; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
      $err = try { Invoke-MigVerb $ms.tool 'pendingSql' @{ e = $e; set = $ms; out = $f } } catch { "$_" }
      if (-not $err -and (Test-Path $f) -and (Get-Item $f).Length) { $files += $f; $via += "$($ms.tool) update-sql$(if ($ms.name -ne 'default') { " ($($ms.name))" })" }
    }
  }
  if (-not $files.Count) {
    $setDirs = @($sets | Where-Object { $_.dir -and $r.wt } | ForEach-Object { [IO.Path]::GetRelativePath($r.wt, $_.dir).Replace('\', '/').TrimEnd('/') + '/' } | Where-Object { $_ -notmatch '^\.\./' })
    $files = @(git -C $r.wt diff --name-only "$base...$head" 2>$null | Where-Object { $f0 = $_; $_ -match $script:MigPattern -or $_ -match '(^|/)((deploy|revert)/[^/]+|\d+[_.-][^/]*)\.sql$|(^|/)versions/\w+\.py$' -or @($setDirs | Where-Object { $f0.StartsWith($_) }).Count } | ForEach-Object { Join-Path $r.wt $_ } | Where-Object { Test-Path -LiteralPath $_ })
    $via = @("$($files.Count) migration file(s)")
  }
  if (-not $files.Count) { return @{ items = @(); unknown = $true; via = 'nothing found' } }
  $j = Invoke-DbFb $e 'touched' @('--files', ($files -join ','))
  @{ items = @($j.items); unknown = -not @($j.items).Count; via = ($via -join ', ') }
}
# the tool's resetEdited verb: a rebuilt layer edited an applied migration unit (liquibase: changeSet checksums reset) -> notes
function Reset-EditedChecksums([string]$e, $envRepos, $cur, $newLayers) {
  $tool = Get-MigTool $e; if (Test-MigVerb $tool 'resetEdited') { Invoke-MigVerb $tool 'resetEdited' @{ e = $e; envRepos = $envRepos; cur = $cur; newLayers = $newLayers } }
}

# restore.after: derived state outside the DB (marker resets, reindex, cache clears); after a restore, and before a release with
# migrations starts unless the hook says "onMigrations": false
function Invoke-RestoreAfter([string]$e, [string]$mark, [switch]$Migrations) {
  foreach ($h in @((Get-EnvCfg $e).restore.after | Where-Object { $_.cmd -and -not ($Migrations -and $_.onMigrations -eq $false) })) {
    $code = Invoke-Shell (Expand-Placeholders ([string]$h.cmd).Replace('{mark}', $mark) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '') (LogFile $e 'restore') (EnvVars $e ([pscustomobject]@{})) 1800
    "restore.after $($h.name): $(if ($code) { "FAILED ($(Get-ShellWhy $code)): $((@($script:ShellOut) | Select-Object -Last 2) -join ' | ')" } else { "ok$(if (@($script:ShellOut).Count) { ": $((@($script:ShellOut) | Select-Object -Last 2) -join ' | ')" })" })"
  }
}
# before a release's migrations run: the slices of every touched table in every env schema -> the mark's slices
function Save-Slices([string]$e, [string]$mark, [hashtable]$byRepo) {
  $items = @($byRepo.Values | ForEach-Object { @($_.items) } | Where-Object { $_ }); $unknown = @($byRepo.Keys | Where-Object { $byRepo[$_].unknown })
  $dir = Join-Path (MigRoot $e) $mark; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  $spec = @(foreach ($s in EnvSchemas $e) { foreach ($i in $items) { @{ schema = $s; table = $i.table; kind = $i.kind; columns = @($i.columns) } } })
  $res = @{ dir = $dir; bytes = 0; unknown = $unknown; tables = @($items | ForEach-Object table | Select-Object -Unique); objects = $true }
  New-Item -ItemType Directory -Force $dir | Out-Null; $sf = Join-Path $dir 'spec.json'; ConvertTo-Json -InputObject @($spec) -Depth 5 | Set-Content $sf -Encoding utf8
  $j = Invoke-DbFb $e 'slice' @('--spec', $sf, '--out', $dir, '--objects', (@(EnvSchemas $e) -join ',')) -Fail; $res.bytes = [long]$j.bytes; $res.noPk = @($j.noPk)   # + view / routine / trigger / event definitions
  Update-State $e { param($x) foreach ($m in @($x.marks)) { if ($m -and $m.name -eq $mark) { $m.slices = $res } } }
  $res
}
function Remove-MarkSlices([string]$e, [string[]]$names) { foreach ($n in $names) { if ($n) { Remove-Item (Join-Path (MigRoot $e) $n) -Recurse -Force -ErrorAction SilentlyContinue } } }
# layer in the target: ancestry, else a merged host MR at / past it or rebased; -NoHost: ancestry
function Get-MergedWhy([string]$d, [string]$branch, [string]$sha, [string]$target, [string]$tref, [switch]$NoHost) {
  git -C $d merge-base --is-ancestor $sha $tref 2>$null
  if ($LASTEXITCODE -eq 0) { return "merged into $target" }
  if ($NoHost -or $tref -ne "origin/$target" -or -not (Get-Command Get-MergedMrs -ErrorAction SilentlyContinue)) { return $null }
  $mr = try { @(Get-MergedMrs $d $branch $target | Where-Object { $_.sha -and ($_.sha -eq $sha -or $(git -C $d cat-file -e "$($_.sha)^{commit}" 2>$null; if ($LASTEXITCODE) { git -C $d fetch -q origin $_.sha 2>$null }; git -C $d merge-base --is-ancestor $sha $_.sha 2>$null; $LASTEXITCODE -eq 0) -or (Test-KitRebasedCopy $d $sha $_.sha)) })[0] } catch { $null }
  if ($mr) { "merged into $target (MR $($mr.iid))" }
}
function Sync-Repo([string]$e, $r, [object[]]$layers, [switch]$NoFetch, [string]$Base, [switch]$KeepRunning) {   # -Base: a target commit (restore), else origin/<target>; -KeepRunning: no train restarts them (lane resync)
  Ensure-Worktree $e $r
  Sync-DepLinks $e $r
  $d = $r.wt
  if (-not (Test-LaneWorktree $d)) { throw "[$e] $d is not its own git worktree: not reset (envy.ps1 doctor -Env $e -Fix)" }
  if (-not $KeepRunning) { Stop-TreeHolders $e $r }
  $dirty = @(git -C $d status --porcelain --untracked-files=no)
  if ($dirty.Count) { Write-Host "[$e] $d had $($dirty.Count) uncommitted edits: discarded (the env worktree is never edited by hand)"; G $d reset -q --hard HEAD | Out-Null }
  if (-not $NoFetch) { G $d fetch -q origin $r.target | Out-Null }
  $tref = if ($Base) { $Base } else { "origin/$($r.target)" }; G $d reset -q --hard $tref | Out-Null
  $base = "$(git -C $d rev-parse HEAD)".Trim()
  $kept = @(); $dropped = @(); $nh = NoHooksDir
  foreach ($l in $layers) {
    $sha = if ($l.sha -and $(git -C $d cat-file -e "$($l.sha)^{commit}" 2>$null; $LASTEXITCODE -eq 0)) { $l.sha } else { Resolve-Ref $d $l.branch }
    if (-not $sha) { $dropped += @{ layer = $l; why = 'branch and commit gone' }; continue }
    $mw = Get-MergedWhy $d $l.branch $sha $r.target $tref -NoHost:$NoFetch
    if ($mw) { $dropped += @{ layer = $l; why = $mw }; continue }
    $out = git -C $d -c "core.hooksPath=$nh" -c user.name=localenv -c user.email=localenv@localhost merge -q --no-ff --no-edit -m "localenv layer $($l.branch) ($($l.agent))" $sha 2>&1
    if ($LASTEXITCODE) {
      $files = @(git -C $d diff --name-only --diff-filter=U 2>$null)
      if (Resolve-LaneKeepBoth $e $r $d $files $nh) { Write-Host "[$e] $($l.branch): append-only conflict in $($files -join ', '): both sides kept"; $l.sha = $sha; $kept += $l; continue }
      git -C $d merge --abort 2>$null | Out-Null; git -C $d reset -q --hard HEAD 2>$null | Out-Null
      $dropped += @{ layer = $l; why = "conflicts with $($r.target) + earlier layers: $(($files | Select-Object -First 8) -join ', ')$(if (-not $files) { "$out" })"; files = $files }; continue
    }
    $l.sha = $sha; $kept += $l
  }
  # services[].prepare: a local-only edit of the env worktree after every sync (a build cache path, ...): committed on localenv/<env>, never pushed
  foreach ($s in EnvServices $e | Where-Object { $_.prepare -and $_.repo -and (RepoOf $e $_) -eq $r.name }) {
    $sd = SvcDir $e $s; $cd = if ($KitIsWindows) { "cd /d `"$sd`"" } else { "cd `"$sd`"" }
    $code = Invoke-Shell "$cd && $(Expand-Placeholders ([string]$s.prepare) $e $s $sd '')" (LogFile $e "$($s.name)-build") (EnvVars $e $s) ([int](Get-KitParam 'localEnv.prepareTimeoutSec'))
    if ($code) { Write-Warning "[$e] $($s.name) prepare failed ($(Get-ShellWhy $code)): $((@($script:ShellOut) | Select-Object -Last 2) -join ' | ')"; continue }
    if (@(git -C $d status --porcelain --untracked-files=no).Count) { G $d -c "core.hooksPath=$nh" -c user.name=localenv -c user.email=localenv@localhost commit -q -a -m "localenv prepare $($s.name) (local only)" | Out-Null }
  }
  @{ kept = $kept; dropped = $dropped; targetSha = $base }
}
# ---- shared builds: a recorded copy of the same code + build config is staged, no build (reuseBuilds: own lane; shareBuild: any)
function Build-Repo([string]$e, [string]$rn) {
  $script:Killed = ''
  foreach ($s in EnvServices $e | Where-Object { $_.build -and (RepoOf $e $_) -eq $rn }) {
    $script:SharedStage.Remove($s.name); $script:BuildKeys[$s.name] = $key = BuildKey $e $s
    $script:CheckBuild.Remove($s.name)
    if ($cb = Find-CheckBuild $e $s) { Write-Host "[$e] $($s.name): a check built the same code ($($cb.path)): staged, no build"; $script:CheckBuild[$s.name] = $cb; Event $e 'build-check' @{ service = $s.name; repo = $rn; from = $cb.path }; continue }
    $hit = if ($key) { Find-SharedBuild $e $s $key }
    if ($hit) { Write-Host "[$e] $($s.name): lane $($hit.lane) built the same code: its copy is staged, no build"; $script:SharedStage[$s.name] = $hit; Event $e 'build-shared' @{ service = $s.name; repo = $rn; from = $hit.lane; key = $key }; continue }
    $dir = SvcDir $e $s; $cmd = Expand-Placeholders ([string]$s.build) $e $s $dir ''
    if ($cmd -match '\{reactor\}') { $cmd = $cmd.Replace('{reactor}', (Write-Reactor $e $s)) }
    elseif ($lr = Get-LayerReactorFlags $e $s $cmd) { $cmd = Add-ToolFlags $cmd $lr }
    Write-Host "[$e] building $($s.name): $cmd"
    $log = LogFile $e "$($s.name)-build"; Remove-Item $log -ErrorAction SilentlyContinue; $t0 = Get-Date
    With-Env (LaneEnv $e $s) { & $KitCmd.dev gate -Dir $dir -Cmd "$cmd > `"$log`" 2>&1" *>&1 | Select-String -Pattern '^\[gate\] (starting|waiting.*Biggest|stopped by the kit|PAUSE)' | ForEach-Object { if ("$_" -match 'kit: (.+?) \(exit|\] (PAUSE.+)') { $script:Killed = "$($Matches[1])$($Matches[2])" }; Write-Host "  $_" } }
    $bc = $LASTEXITCODE
    Event $e 'build' @{ service = $s.name; repo = $rn; ok = -not $bc; code = $bc; sec = [int]((Get-Date) - $t0).TotalSeconds; sha = "$(git -C (EnvRepos $e)[$rn].wt rev-parse --short HEAD 2>$null)".Trim() }   # durations feed the learned parameters
    if ($bc -and $script:Killed) { return "killed: $($s.name): $script:Killed" }
    if ($bc) {
      $code = $bc; $lines = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\[gate\]|^WARNING:' })
      $errs = @($lines | Where-Object { $_ -match '(?i)\berror\b|failed|exception|cannot find|not found' } | Select-Object -First 10)
      return "$($s.name) (exit $code): $((@(if ($errs.Count) { $errs } else { $lines | Select-Object -Last 12 })) -join "`n")"
    }
  }
  $null
}
# a release = a runnable copy per service (the worktree builds on while it serves); keepReleases + the ones in use kept
function Stage-Artifacts([string]$e, [string]$rn, [string]$tag) {
  $out = @{}; $cpUsed = @()
  foreach ($s in EnvServices $e | Where-Object { ($_.artifact -or $_.static) -and (RepoOf $e $_) -eq $rn }) {
    $dir = SvcDir $e $s; $t0 = Get-Date
    $to = Join-Path (Get-KitPath localenv -Create) "run/$e/$($s.name)/$tag"
    $live = @((Read-State $e).services.Values | ForEach-Object { ReleaseDirOf (Split-Path $to) "$($_.artifact)" }) + $script:SharedStage[$s.name].dir
    for ($i = 2; $to -in $live; $i++) { $to = Join-Path (Get-KitPath localenv) "run/$e/$($s.name)/$tag-$i" }   # a running copy or the one staged from is never replaced
    Remove-Item -LiteralPath $to -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $to | Out-Null
    $bk = $script:BuildKeys[$s.name]; $sh = $script:SharedStage[$s.name]; $shared = [bool]$sh; $shLane = $null; $script:BuildKeys.Remove($s.name); $script:SharedStage.Remove($s.name)   # one build, one stage
    for ($try = 0; $sh -and $try -lt 3; $try++) {   # pruned meanwhile: the next
      try {
        if (-not (Test-Path -LiteralPath $sh.path)) { throw 'gone' }
        Add-ReleaseFiles $sh.dir $to -Release
        $rel = [IO.Path]::GetRelativePath($sh.dir, $sh.path); $out[$s.name] = if ($rel -eq '.') { $to } else { Join-Path $to $rel }; $shLane = $sh.lane; break
      } catch { Get-ChildItem -LiteralPath $to -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; $sh = Find-SharedBuild $e $s $bk }
    }
    if ($out[$s.name]) { }
    elseif ($shared) { throw "[$e] $($s.name): the recorded copies of this build are gone since the build step (pruned): deploy again (it builds then)" }
    elseif ($s.static) {
      $src = Join-Path $dir $s.static
      if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "[$e] $($s.name): no built files in $src after the build (static)" }
      Add-ReleaseFiles $src $to; $out[$s.name] = $to
    } else {
      $excl = if ($s.artifactExclude) { [string]$s.artifactExclude } else { 'original|sources|javadoc|plain' }
      $cbf = $script:CheckBuild[$s.name]; $script:CheckBuild.Remove($s.name)   # a check's artifact is copied: its worktree keeps it
      if ($cbf -and -not ((Test-Path -LiteralPath $cbf.path) -and (Get-Item -LiteralPath $cbf.path).LastWriteTimeUtc -eq $cbf.t)) { throw "[$e] $($s.name): the check build $($cbf.path) is gone or rebuilt since the build step: deploy again (it builds then)" }
      $f = if ($cbf) { Get-Item -LiteralPath $cbf.path } else { Get-ChildItem (Join-Path $dir $s.artifact) -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch $excl | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
      if (-not $f) { throw "[$e] $($s.name): no artifact matches $($s.artifact) in $dir after the build" }
      $out[$s.name] = $null
      if ($s.unpack) {   # a failed unpack: the plain artifact goes live, the event says why
        try { $out[$s.name] = Expand-Artifact $e $s $f.FullName $to }
        catch { $why = "$_".Split("`n")[0]; Write-Host "[$e] $($s.name): $why - staged the plain artifact instead"; Event $e 'unpack-fallback' @{ service = $s.name; tag = $tag; why = $why }; Get-ChildItem -LiteralPath $to -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
      }
      if (-not $out[$s.name]) { if (-not $cbf -and (Opt 'stageLinks' $true) -and -not @(EnvServices $e | Where-Object { $_.name -ne $s.name -and "$($_.artifact)" -eq $s.artifact -and (SvcDir $e $_) -eq $dir }).Count) { Move-Item -LiteralPath $f.FullName $to -Force } else { Copy-Item $f.FullName $to -Force }; $out[$s.name] = Join-Path $to $f.Name }
    }
    if ($s.classpathFile -and -not $s.static) {   # consumed: never a stale one staged
      $cpSrc = if ($shared) { $null } else { Join-Path $dir $s.classpathFile }; Write-JavaArgs $e $s $cpSrc $to $out[$s.name]
      if ($cpSrc) { $cpUsed += $cpSrc }
    }
    $bo = $out[$s.name]
    if ($bk) { Update-State $e { param($x) if ($x.builds -isnot [hashtable]) { $x.builds = @{} }; $x.builds[$s.name] = @(@(@($x.builds[$s.name]) | Where-Object { $_ -and $_.key -ne $bk }) + @(@{ key = $bk; dir = $to; path = $bo; at = (Now) }) | Select-Object -Last 3) } }
    Event $e 'stage' @{ service = $s.name; tag = $tag; sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); unpacked = [bool]$s.unpack; shared = $shLane }
    $null = Remove-OldReleases $e $s (Split-Path $to)
  }
  $cpUsed | Select-Object -Unique | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }   # after every service sharing it staged
  $out
}
# localEnv.stageLinks: a release links, never copies (flagged.ps1 linkfiles; store <service>/_lib); off: copies, no AOT cache
function Add-ReleaseFiles([string]$from, [string]$to, [switch]$Release, [switch]$Move) {
  if (Opt 'stageLinks' $true) { & (Join-Path $script:KitLibDir 'flagged.ps1') linkfiles -Text $from -To $to -Release:$Release -Move:$Move; return }
  $null = New-Item -ItemType Directory -Force $to; Copy-Item (Join-Path $from '*') $to -Recurse -Force -Exclude 'app.aot'
}
# the release folder an artifact path lies in (artifact = a file in it, or the folder itself)
# ReleaseDirOf, Remove-OldReleases (keepReleases): adapters/shared-builds.ps1
# services[].unpack: unpacks {artifact} into {out}: a runnable file of its type + libraries
function Expand-Artifact([string]$e, $s, [string]$file, [string]$to) {
  $tmp = Join-Path (Split-Path $to) '_unpack'; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  $code = Invoke-Shell (Expand-Placeholders ([string]$s.unpack) $e $s (SvcDir $e $s) $file).Replace('{out}', $tmp) (LogFile $e "$($s.name)-build") (EnvVars $e $s) ([int](Get-KitParam 'localEnv.buildTimeoutSec'))
  if ($code) { throw "[$e] $($s.name): unpack failed ($(Get-ShellWhy $code)): $((@($script:ShellOut) | Select-Object -Last 3) -join ' | ')" }
  Add-ReleaseFiles $tmp $to -Move; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  $run = Get-ChildItem -LiteralPath $to -File | Where-Object Extension -eq ([IO.Path]::GetExtension($file)) | Select-Object -First 1
  if (-not $run) { throw "[$e] $($s.name): unpack left no $([IO.Path]::GetExtension($file)) file in $to" }
  $run.FullName
}
# the AOT cache of an artifact (services[].aotTrain): {aot} in the start command uses it once a training run wrote it
function AotFile([string]$artifact) { if ($artifact) { Join-Path $(if (Test-Path -LiteralPath $artifact -PathType Container) { $artifact } else { Split-Path $artifact }) 'app.aot' } }
# after a start that is up: one background training run per artifact (gated: RAM), never two at a time
function Start-AotTrain([string]$e, $s, [string]$artifact) {
  if (-not $s.aotTrain -or -not $artifact -or (Test-Path -LiteralPath (AotFile $artifact))) { return }
  $x = (Read-State $e).services[$s.name]; if (Owned $x.aot) { return }
  $p = Start-Pwsh @('_daemon', '-Env', $e, '-Aot', $s.name, '-Artifact', $artifact) $PSScriptRoot "_daemon -Env $e -Aot $($s.name)" (LogFile $e "aot-$($s.name)")
  Update-State $e { param($z) if ($z.services[$s.name]) { $z.services[$s.name].aot = Mine $p } }
}
function Invoke-AotTrain([string]$e, $s, [string]$artifact) {
  $f = AotFile $artifact; $tmp = "$f.tmp"; Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  $cmd = (Expand-Placeholders ([string]$s.aotTrain) $e $s (SvcDir $e $s) $artifact).Replace('{aotFile}', $tmp); $t0 = Get-Date
  $log = LogFile $e "aot-$($s.name)"; Add-Content $log "== $(Now) training: $cmd"
  With-Env (LaneEnv $e $s) { & $KitCmd.dev gate -Dir (Split-Path $f) -Cmd "$cmd >> `"$log`" 2>&1" *>&1 | Out-Null }
  $ok = -not $LASTEXITCODE -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length
  if ($ok) { Move-Item -LiteralPath $tmp $f -Force } else { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  Event $e 'aot-train' @{ service = $s.name; ok = [bool]$ok; sec = [int]((Get-Date) - $t0).TotalSeconds; artifact = $artifact }
}
# the static server of services[].static (no start command): serves the staged files, unknown routes get index.html
function StaticServer {
  $f = Join-Path (Get-KitPath localenv -Create) 'run/static-server.mjs'
  $js = @'
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const [root, port, host = '::'] = process.argv.slice(2); const base = path.resolve(root);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.map': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.txt': 'text/plain', '.wasm': 'application/wasm', '.webmanifest': 'application/manifest+json' };
const send = (res, code, f) => fs.readFile(f, (err, buf) => { if (err) { res.writeHead(404); return res.end(); } const x = path.extname(f).toLowerCase(); res.writeHead(code, { 'Content-Type': types[x] || 'application/octet-stream', 'Cache-Control': x === '.html' ? 'no-cache' : 'max-age=3600' }); res.end(buf); });
const srv = http.createServer((req, res) => {
  let p; try { p = decodeURIComponent(new URL(req.url, 'http://x').pathname); } catch { res.writeHead(400); return res.end(); }
  if (p.includes('\0')) { res.writeHead(400); return res.end(); }
  const f = path.join(base, p); if (f !== base && !f.startsWith(base + path.sep)) { res.writeHead(403); return res.end(); }
  fs.stat(f, (err, st) => { if (!err && st.isFile()) return send(res, 200, f); if (!err && st.isDirectory()) return send(res, 200, path.join(f, 'index.html'));
    if (path.extname(p)) { res.writeHead(404); return res.end(); } send(res, 200, path.join(base, 'index.html')); });
});
const up = (h) => srv.listen(+port, h, () => console.log(`Listening on ${h}:${port} (${base})`));
srv.on('error', (e) => { if (e.code === 'EAFNOSUPPORT' && host === '::') { up('0.0.0.0'); } else { throw e; } }); up(host);
'@
  if (-not (Test-Path -LiteralPath $f) -or (Get-Content -LiteralPath $f -Raw) -ne $js) { New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content -LiteralPath $f $js -NoNewline -Encoding utf8 }
  $f
}

# ---- hooks: db query / exec / rollback / applied / tag, smoke checks; db.timeoutSec = seconds for every hook or { <hook>: seconds }
# a shell command, time-bounded (lib Invoke-KitExe kills the tree), output appended to $log and kept in $script:ShellOut; -1 = timed out
$script:Misconfigured = @(64, 127, 9009)   # usage error / command not found (sh, cmd): fail fast, never retried
function Invoke-Shell([string]$cmd, [string]$log, $vars, [Alias('TimeoutSeconds')][int]$TimeoutSec = 1800) {
  $r = With-Env $(if ($vars) { $vars } else { @{} }) {
    if ($KitIsWindows) { Invoke-KitExe 'cmd.exe' @() $TimeoutSec -Raw "/d /s /c `"$cmd`"" } else { Invoke-KitExe '/bin/sh' @('-c', $cmd) $TimeoutSec }
  }
  $script:ShellOut = @(@($r.out, $r.err) | Where-Object { $_ } | ForEach-Object { "$_" -split "`r?`n" })
  if ($r.timedOut) { $script:ShellOut += "== timed out after $TimeoutSec s (killed)" }
  if ($script:ShellOut.Count) { Add-Content $log $script:ShellOut }
  if ($r.code -gt 0 -and ($script:ShellOut -match "^'[^']+' is not recognized as an internal or external command|^(/bin/)?(ba)?sh: (line )?\d*:? ?.+: (command )?not found$").Count) { return 127 }   # cmd /c says 1
  $r.code
}
function Get-ShellWhy([int]$code) { if ($code -eq -1) { 'timed out' } elseif ($code -in $script:Misconfigured) { "misconfigured (exit ${code}: command not found or bad usage; envy.ps1 doctor)" } else { "exit $code" } }
function HookTimeout([string]$e, [string]$name) {
  $t = (Get-EnvCfg $e).db.timeoutSec
  if ($t -is [pscustomobject]) { $t = (Get-KitMember $t $name) }
  if ($t) { return [int]$t }
  if ($name -in 'query', 'tag') { 120 } elseif ($name -eq 'applied') { 300 } else { 1800 }   # TODO-PARAM (fixed default)
}
function Get-HookCmd([string]$e, [string]$name, [hashtable]$vars = @{}) {
  $db = (Get-EnvCfg $e).db
  $cmd = if ((Get-KitMember $db $name)) { Expand-Placeholders ([string](Get-KitMember $db $name)) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '' }
  if (-not $cmd) { return $null }
  foreach ($k in $vars.Keys) { $cmd = $cmd.Replace("{$k}", "$($vars[$k])") }
  $cmd
}
function Invoke-Hook([string]$e, [string]$name, [hashtable]$vars = @{}) {
  $cmd = Get-HookCmd $e $name $vars
  if (-not $cmd -and $name -eq 'query' -and (Get-Command Invoke-DbQueryVerb -ErrorAction SilentlyContinue) -and (Get-DbEngine $e).sql -is [scriptblock]) { return Invoke-DbQueryVerb $e "$($vars.sql)" }
  if (-not $cmd) { return "no db.$name hook configured" }
  $log = LogFile $e 'db'
  Add-Content $log "== $(Now) $name : $cmd"
  $hv = EnvVars $e ([pscustomobject]@{}); if ("$($cmd)" -match 'KIT_DB_URI') { $hv['KIT_DB_URI'] = "$((Get-EnvCfg $e).db.uri)" }   # mongosh: db.uri off argv
  $code = Invoke-Shell $cmd $log $hv (HookTimeout $e $name)
  $script:HookOut = @($script:ShellOut)
  Event $e "db-$name" @{ code = $code; vars = $vars }
  if ($code) { return "db.$name failed ($(Get-ShellWhy $code)): $((@($script:HookOut) | Select-Object -Last 8) -join ' | ')" }
  $null
}
function Test-Smoke([string]$e) {
  foreach ($c in @((Get-EnvCfg $e).smoke | Where-Object { $_ })) {
    if ($c.service -and -not (Healthy $e (Svc $e $c.service))) { continue }   # skip while its service is idle
    $until = (Get-Date).AddSeconds([double]$(if ($c.timeoutSec) { $c.timeoutSec } else { 60 })); $why = 'not run'; $final = $false
    while ($true) {
      if ($c.url) {
        $u = Expand-Placeholders ([string]$c.url) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        $want = if ($c.status) { [string]$c.status } else { '^[23]\d\d$|^401$|^403$' }
        try { $r = Invoke-WebRequest $u -ConnectionTimeoutSeconds 15 -OperationTimeoutSeconds 30 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; if ("$($r.StatusCode)" -match $want) { $why = $null } else { $why = "$u returned $($r.StatusCode)" } } catch { $why = "$u : $($_.Exception.Message)" }
      } elseif ($c.login) {   # POST login.body (${VAR}: env file) to login.url: a token in the reply passes; login.get: a GET with it
        $lv = EnvVars $e ([pscustomobject]@{}); $none = [pscustomobject]@{ port = '' }
        $x = { param($t) [regex]::Replace((Expand-Placeholders "$t" $e $none $KitConf.Workspace ''), '\$\{(\w+)\}', { param($mm) "$($lv[$mm.Groups[1].Value])" }) }
        $body = [ordered]@{}; foreach ($pp in @((Get-KitProps $c.login.body))) { $body[$pp.Name] = if ($pp.Value -is [string]) { & $x $pp.Value } else { $pp.Value } }
        $u = & $x $c.login.url
        try {
          $r = Invoke-RestMethod $u -Method Post -Body ($body | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 30 -SkipCertificateCheck
          $tok = @($(if ($c.login.token) { (Get-KitMember $r $($c.login.token)) } else { $r.id_token; $r.access_token; $r.token }) | Where-Object { $_ })[0]
          $why = if (-not $tok) { "$u : login returned no token" } else { $null }
          if ($tok -and $c.login.get) { $null = Invoke-RestMethod (& $x $c.login.get) -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 30 -SkipCertificateCheck }
        } catch { $why = "$u : $($_.Exception.Message)" }
      } elseif ($c.cmd) {
        $cmd = Expand-Placeholders ([string]$c.cmd) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        $slog = LogFile $e 'smoke'; Remove-Item $slog -ErrorAction SilentlyContinue
        $code = Invoke-Shell $cmd $slog (EnvVars $e ([pscustomobject]@{})) ([int][math]::Max(5.0, ($until - (Get-Date)).TotalSeconds))
        $final = $code -in $script:Misconfigured
        $why = if ($code) { "$(Get-ShellWhy $code) : $((@($script:ShellOut) | Where-Object { "$_".Trim() } | Select-Object -Last 3) -join ' | ')" } else { $null }
      }
      if (-not $why -or $final -or (Get-Date) -gt $until) { break }
      Start-Sleep 5
    }
    if ($why) { Event $e 'smoke-failed' @{ check = $c.name; why = $why }; return "$($c.name): $why" }
  }
  $null
}
# ---- marks: a named binlog position + the code live then (zero bytes); restore = the row changes after it flashed back, the
# migrations recorded after it rolled back, its code started (db.engine mysql / mariadb: adapters/db-presets.ps1)
$script:MarkMax = [int](Opt 'marks.max' 60)   # TODO-PARAM (fixed default)
function MarksOn([string]$e) { [bool](Get-Command Test-DbMarks -ErrorAction SilentlyContinue) -and ((Test-DbMarks $e) -or (SnapOn $e)) }
function SnapOn([string]$e) { [bool](Get-Command Test-DbSnap -ErrorAction SilentlyContinue) -and (Test-DbSnap $e) }
# the env's data scopes (schemas / databases): db.schemas (names) + db.schemasQuery (one name per row), else db.name; + the tenant
# model's scopes verb (adapters/tenant-models.ps1), when it has one
function Get-DataScopes([string]$e) {
  $db = (Get-EnvCfg $e).db; $s = @($db.schemas | Where-Object { $_ } | ForEach-Object { "$_" })
  if ($db.schemasQuery) { $s += @(Invoke-DbSql $e ([string]$db.schemasQuery) | ForEach-Object { $_[0] }) }
  if (-not $s.Count -and $db.name) { $s = @("$($db.name)") }
  $m = "$((Get-EnvCfg $e).tenants.model)".ToLower(); $ad = if ($m) { $KitAdapters['tenant-model'][$m] }
  if ($ad -and $ad.scopes -is [scriptblock]) { $s += @(& $ad.scopes @{ e = $e } 'scopes') }
  @($s | Where-Object { $_ } | Select-Object -Unique)
}
function EnvSchemas([string]$e) { Get-DataScopes $e }
# a restore's scopes: the mark's own (recorded when it was taken) that still exist, else today's; a scope gone since (a dropped
# tenant) or made after it: a warning line (restore output), never a refusal (a drop then a restore is the normal data flow)
function Get-MarkScopes([string]$e, $m) {
  $now = @(Get-DataScopes $e); $script:ScopeWarn = @()
  if (-not @($m.schemas).Count) { return $now }
  $gone = @($m.schemas | Where-Object { $_ -notin $now }); $reg = Get-RegistryScope $e
  if ($gone.Count -and $reg -and $reg -in @($m.schemas)) { $script:ScopeWarn += "scope(s) $($gone -join ', ') of mark $($m.name) are gone since: their $reg rows come back without their data (re-import them, or drop them again)" }
  $new = @($now | Where-Object { $_ -notin @($m.schemas) }); if ($new.Count) { $script:ScopeWarn += "scope(s) $($new -join ', ') made after mark $($m.name): left as they are$(if ($reg) { " (their $reg rows go: the tenant verb list shows them)" })" }
  @($m.schemas | Where-Object { $_ -notin $gone })
}
# restore -Schemas without the registry scope: that tenant's registry rows stay as they are now (a warning line)
function Test-RestoreScopes([string]$e, [string[]]$schemas) {
  $reg = Get-RegistryScope $e; $script:ScopeWarn = @()
  if ($reg -and $reg -notin $schemas -and @($schemas | Where-Object { $_ -ne $reg }).Count -and (Get-DataScopes $e) -contains $reg) { $script:ScopeWarn += "restore -Schemas $($schemas -join ',') leaves out the registry scope ${reg}: their registry rows stay as they are now (add $reg to restore them too)" }
  $schemas
}
# kind: release | use | owner | baseline; $repos = the code it stands for (default: the live release)
# the env's own DB service (a service it runs on db.port, e.g. a lane's copy); down = nothing writes: marks wait, watchdog rests
function DbSvc([string]$e) { $p = (Get-EnvCfg $e).db.port; if ($p) { @(EnvServices $e | Where-Object { (Managed $_) -and "$($_.port)" -eq "$p" })[0] } }
function DbSvcDown([string]$e) { $d = DbSvc $e; [bool]($d -and -not (Test-PortListening ([int]$d.port))) }
function New-Mark([string]$e, [string]$name, [string]$kind, $repos, [int]$release = -1) {
  if (-not (MarksOn $e)) { return $null }
  $name = ConvertTo-KitSlug $name
  if (DbSvcDown $e) {   # taken when that service starts, before anything else connects (Start-SvcOnce)
    Update-State $e { param($x) $x.pendingMarks = @(@($x.pendingMarks) | Where-Object { $_ -and $_.name -ne $name }) + @(@{ name = $name; kind = $kind; repos = $repos; release = $release }) }
    return $name
  }
  $sch = try { @(Get-DataScopes $e) } catch { @() }
  if ((Get-Command Test-CascadeGuard -ErrorAction SilentlyContinue) -and (Test-CascadeGuard $e)) {   # a scope no earlier mark had (a tenant added since): its triggers before the position
    $last = @(@((Read-State $e).marks) | Where-Object { $_ -and @($_.schemas).Count } | Select-Object -Last 1)[0]
    if ($last -and @($sch | Where-Object { $_ -notin @($last.schemas) }).Count) { try { $null = Install-DbGuard $e } catch { Write-Warning "[$e] mark ${name}: cascade guard not reinstalled for the new scope(s): $("$_".Split("`n")[0])" } }
  }
  $pos = Get-DbPos $e; if (SnapOn $e) { Add-DbSnap $e $pos $sch }
  Update-State $e { param($x)
    $code = if ($repos) { $repos } else { $x.release.repos }
    $m = @{ name = $name; kind = $kind; at = (Now); pos = $pos; schemas = $sch; release = $(if ($release -ge 0) { $release } else { [int]$x.release.n }); repos = ($code | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable) }
    $all = @(@($x.marks) | Where-Object { $_ -and $_.name -ne $name }) + @($m)
    $x.marks = @(@($all | Where-Object { $_.kind -ne 'baseline' } | Select-Object -Last $script:MarkMax) + @($all | Where-Object kind -eq 'baseline' | Select-Object -Last 2) | Sort-Object { [datetime]$_.at })
  }
  Event $e 'mark' @{ name = $name; kind = $kind; pos = $pos }
  $name
}
# daily: marks whose binlog file is gone expire; the binlog retention is kept for status and doctor
function Update-Marks([string]$e) {
  if (-not (MarksOn $e)) { return }; if (SnapOn $e) { return Update-SnapMarks $e }
  $logs = @(Get-DbBinlogs $e); $sec = [double]@(Invoke-DbSql $e "SHOW GLOBAL VARIABLES LIKE 'binlog_expire_logs_seconds'")[0][1]; $o = @{ gone = @() }
  Update-State $e { param($x)
    $o.gone = @(@($x.marks) | Where-Object { $_ -and ($_.pos -split ':(?=\d+$)')[0] -notin $logs })
    if ($o.gone.Count) { $x.expiredMarks = @(@($x.expiredMarks) + @($o.gone.name) | Where-Object { $_ } | Select-Object -Last 10); $x.marks = @(@($x.marks) | Where-Object { $_ -and $_.name -notin $o.gone.name }) }
    $x.undone = @(@($x.undone) | Where-Object { $_ -and (($_ -split '~')[1] -split ':(?=\d+$)')[0] -in $logs })
    $x.binlog = @{ days = [math]::Round($sec / 86400, 1); oldest = $logs[0]; checkedAt = (Now) }
  }
  "[$e] marks: $(@((Read-State $e).marks).Count) kept$(if ($o.gone.Count) { ", expired (binlog gone): $(@($o.gone.name) -join ', ')" }); the binlog keeps $([math]::Round($sec / 86400, 1)) d"
}
function Find-Mark($st, [string]$mark, [int]$release) {
  $n = if ($mark) { ConvertTo-KitSlug $mark } else { "release-$release" }
  $m = @($st.marks | Where-Object { $_ -and $_.name -eq $n })[0]
  if (-not $m) { throw "no mark $n$(if ($n -in @($st.expiredMarks)) { ' (expired: its binlog is gone)' } elseif ($n -in @(@($st.pendingMarks) | Where-Object { $_ } | ForEach-Object name)) { ' yet: queued until the DB service starts (nothing changed since)' }) - marks: $(@($st.marks | Where-Object { $_ } | ForEach-Object name) -join ', ')" }
  $m
}
# what a restore to mark $m changes (read-only): the row flashback plan, the tables whose structure changed (binlog DDL) and how
# each comes back (the slices of a mark at or after $m taken before that DDL; created after $m: dropped; renamed: renamed back)
function Get-RestorePlan([string]$e, $m, [string[]]$schemas, [string]$tag) {
  if (SnapOn $e) { return Get-SnapRestorePlan $e $m $schemas }
  $st = Read-State $e; $to = Get-DbPos $e
  $p = Invoke-DbFlashback $e -From $m.pos -To $to -Schemas $schemas -Skip @($st.undone)
  $p.to = $to; $p.steps = @(); $p.drops = @(); $p.objects = @(); $p.objectDrops = @(); $p.renames = @(@($p.ddl | Where-Object { $_.kind -eq 'rename' }) | Sort-Object { DbPosKey $_.at } -Descending)
  $p.fallback = @($p.fallback | Where-Object { $_ })
  $later = @($st.marks | Where-Object { $_ -and $_.slices -and -not (Test-DbPosBefore $_.pos $m.pos) } | Sort-Object { DbPosKey $_.pos })
  $first = @{}; foreach ($d in @($p.ddl | Where-Object { $_.table -and $_.kind -ne 'object' })) { $k = "$($d.schema).$($d.table)"; if (-not $first[$k]) { $first[$k] = $d } }
  # views / routines / triggers / events changed after the mark: back to the oldest later mark's definitions, else dropped when created after it
  $objFirst = [ordered]@{}; foreach ($d in @($p.ddl | Where-Object { $_.kind -eq 'object' -and $_.table -notlike 'kit_cg_*' })) { $k = "$($d.object):$($d.schema).$($d.table)"; if (-not $objFirst[$k]) { $objFirst[$k] = $d } }
  # a schema dropped after the mark (then created again) changed all its tables and objects then, with no per-object DDL
  $dbAt = @{}; foreach ($d in @($p.ddl | Where-Object { $_.kind -eq 'database' -and $_.sql -match '(?i)^\s*(/\*.*?\*/\s*)?DROP\s' })) { if (-not $dbAt[$d.schema]) { $dbAt[$d.schema] = $d } }
  $byDb = { param($d) $x = $dbAt[$d.schema]; if ($x -and (Test-DbPosBefore $x.at $d.at)) { $x } }
  $objBy = [ordered]@{}
  foreach ($k in $objFirst.Keys) {
    $d = $objFirst[$k]; $x = & $byDb $d; $at = if ($x) { $x.at } else { $d.at }
    $mk = @($later | Where-Object { $_.slices.objects -and -not (Test-DbPosBefore $at $_.pos) })[0]
    if ($mk) { if (-not $objBy[$mk.name]) { $objBy[$mk.name] = @{ mark = $mk.name; dir = $mk.slices.dir; names = @() } }; $objBy[$mk.name].names += $k }
    elseif ($x) { $p.warnings = @($p.warnings) + "$k : its schema was dropped / created after the mark ($($x.at)), no mark kept its definition: left as it is now" }
    elseif ($d.op -eq 'CREATE' -and $d.sql -notmatch '(?i)^\s*CREATE\s+OR\s+REPLACE') { $p.objectDrops = @($p.objectDrops) + $k }
    else { $p.warnings = @($p.warnings) + "$k : changed after the mark ($($d.op) at $($d.at)) and no mark kept its definition: left as it is now" }
  }
  $p.objects = @($objBy.Values)
  $cover = @{}
  foreach ($k in $first.Keys) {
    $d = $first[$k]; $tb = ($k -split '\.', 2)[1]; $x = & $byDb $d; if ($x) { $d = $x }
    $mk = @($later | Where-Object { $tb -in @($_.slices.tables) -and -not (Test-DbPosBefore $d.at $_.pos) })[0]   # the oldest mark kept before that DDL
    if ($mk) { $cover[$k] = $mk.name; continue }
    if ($d.kind -eq 'create') { $p.drops = @($p.drops) + $k; continue }
    if (@($p.renames | Where-Object { $_.to -eq $k }).Count) { continue }   # renamed into place: renamed back
    $why = @($later | Where-Object { -not (Test-DbPosBefore $d.at $_.pos) -and @($_.slices.unknown).Count } | ForEach-Object { "$($_.name): the migrations' tables were not found" })
    $p.fallback = @(@($p.fallback | Where-Object { $_.table -ne $k }) + @{ table = $k; why = "structure changed after the mark ($($d.kind) at $($d.at)) and no mark kept its slice$(if ($why) { " ($($why -join '; '))" }): it keeps today's structure" })
  }
  foreach ($mk in @($later | Sort-Object { DbPosKey $_.pos } -Descending)) {   # newest first: each step = the structure at that mark
    $tabs = @(foreach ($k in @($cover.Keys | Sort-Object)) {
        if (($k -split '\.', 2)[1] -notin @($mk.slices.tables)) { continue }
        $after = @($p.ddl | Where-Object { "$($_.schema).$($_.table)" -eq $k -and -not (Test-DbPosBefore $_.at $mk.pos) })
        if ($after.Count) { $k }
      })
    if ($tabs.Count) { $p.steps = @($p.steps) + @{ mark = $mk.name; dir = $mk.slices.dir; tables = $tabs } }
  }
  $p.bytes = [long](@($later | ForEach-Object { [long]$_.slices.bytes }) | Measure-Object -Sum).Sum
  $p
}
function RestorePlanText($p) {
  $t = @($p.tables.Keys | Sort-Object | ForEach-Object { $c = $p.tables[$_]; "  $_ : $($c.insert) insert(s) -> delete, $($c.update) update(s) -> back, $($c.delete) delete(s) -> back in" })
  @($(if ($p.snapshot) { "snapshot: $($p.snapshot)" } else { "rows: $($p.statements) change(s) undone in $(@($p.tables.Keys).Count) table(s)" })) + $t +
    @($p.renames | ForEach-Object { "structure: $($_.to) renamed back to $($_.schema).$($_.table)" }) +
    @($p.steps | ForEach-Object { "structure: $(@($_.tables) -join ', ') back to mark $($_.mark) (its CREATE text + slices)" }) +
    @($p.drops | ForEach-Object { "structure: $_ dropped (created after the mark)" }) +
    @($p.objects | ForEach-Object { "objects: $(@($_.names) -join ', ') back to mark $($_.mark)" }) + @($p.objectDrops | ForEach-Object { "objects: $_ dropped (created after the mark)" }) +
    @($p.fallback | ForEach-Object { "FALLBACK $($_.table) : $($_.why) -> seed" }) +
    @($p.warnings | ForEach-Object { "WARN $_" }) + @($p.refused | ForEach-Object { "REFUSED $_" })
}
# a restore's DB part (writers stopped): [db.rollback] renames, structure, created tables dropped, objects, row flashback; inexact
# tables -> $script:RestoreFallback (seeded); range recorded undone, its marks dropped (unless no row written); $null = ok
function Invoke-RestoreDb([string]$e, $m, [string[]]$schemas, $plan, [switch]$UseTool) {
  if (SnapOn $e) { return Invoke-SnapRestoreDb $e $m $schemas }
  $st = Read-State $e; $db = (Get-EnvCfg $e).db; $script:RestoreFallback = @(@($plan.fallback) | Where-Object { $_ }); $noRows = $true   # until the row flashback runs
  if (-not @($schemas).Count) { return 'restore has no schemas' }
  $ev = @(Invoke-DbSql $e "SELECT EVENT_SCHEMA, EVENT_NAME FROM information_schema.EVENTS WHERE STATUS = 'ENABLED' AND EVENT_SCHEMA IN ($(@($schemas | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '))")
  try {
    foreach ($x in $ev) { $null = Invoke-DbSql $e "ALTER EVENT ``$($x[0])``.``$($x[1])`` DISABLE" }   # no writer while it runs; a failed one: the finally enables them all again
    if ($UseTool -or "$($db.restoreVia)" -eq 'tool-then-kit') {
      if (-not $db.rollback) { return 'restoreVia tool-then-kit needs db.rollback' }
      $err = if (Test-MigToolRollback $e) { Invoke-MigTagRollback $e 'rollback' "release-$($m.release)" }
        else { Invoke-Hook $e 'rollback' @{ mark = $m.name; release = "$($m.release)"; tag = "release-$($m.release)" } }
      if ($err) { return $(if ($err -match '; PARTLY: ') { "db.rollback failed part way (the DB is partly rolled back; restore again or seed): $err" } else { "db.rollback failed, the DB is unchanged by the kit: $err" }) }
    }
    foreach ($r in @($plan.renames)) { try { $null = Invoke-DbSql $e "RENAME TABLE ``$(($r.to -split '\.', 2) -join '`.`')`` TO ``$($r.schema)``.``$($r.table)``" } catch { } }
    foreach ($s in @($plan.steps)) {
      $j = Invoke-DbFb $e 'structure' @('--dir', $s.dir, '--tables', (@($s.tables) -join ','), '--apply')
      $script:RestoreFallback += @($j.fallback | Where-Object { $_ })
      if ($j.error -or -not $j.verified) { return "structure back to mark $($s.mark) failed: $(if ($j.error) { $j.error } else { "still differs: $(@($j.differs) -join ', ')" })" }
    }
    # one session, FK checks off: post-mark tables reference each other (mysql 3730)
    $dropList = @($plan.drops | ForEach-Object { '`' + (($_ -split '\.', 2) -join '`.`') + '`' }) -join ', '
    if ($dropList) { $null = Invoke-DbSql $e "SET FOREIGN_KEY_CHECKS = 0; DROP TABLE IF EXISTS $dropList; SET FOREIGN_KEY_CHECKS = 1" }
    foreach ($k in @($plan.objectDrops)) { $t, $n = $k -split ':', 2; $null = Invoke-DbSql $e "DROP $t IF EXISTS ``$(($n -split '\.', 2) -join '`.`')``" }
    foreach ($o in @($plan.objects)) { $null = Invoke-DbFb $e 'objects' @('--dir', $o.dir, '--names', (@($o.names) -join ','), '--apply') -Fail }
    $ex = @($script:RestoreFallback | ForEach-Object table)
    $preFb = Get-DbPos $e
    try { $fb = Invoke-DbFlashback $e -From $m.pos -To $plan.to -Schemas $schemas -Skip @($st.undone) -Exclude $ex -Apply } catch { $noRows = (Get-DbPos $e) -eq $preFb; return "row flashback failed: $("$_".Split("`n")[0])" }
    $script:RestoreFallback += @($fb.fallback | Where-Object { $_ -and $_.table -notin $ex })
    if (@($fb.refused).Count) { return "row flashback refused: $(@($fb.refused | Select-Object -First 3) -join '; ')" }
    if (-not $fb.applied) { return "row flashback failed: $($fb.error)" }
    $noRows = $false   # recorded undone only now: a failed flashback recorded it and the next restore skipped the range
  } finally {
    foreach ($x in $ev) { try { $null = Invoke-DbSql $e "ALTER EVENT ``$($x[0])``.``$($x[1])`` ENABLE" } catch { } }
    $end = Get-DbPos $e
    $gone = @()
    # a flashback that wrote no row: not recorded undone (the next restore would skip them)
    if (-not $noRows) { Update-State $e { param($x) $x.undone = @(@($x.undone | Where-Object { $_ }) + "$($m.pos)~$end"); $script:goneMarks = @(@($x.marks) | Where-Object { $_ -and (Test-DbPosBefore $m.pos $_.pos) } | ForEach-Object name); $x.marks = @(@($x.marks) | Where-Object { $_ -and $_.name -notin $script:goneMarks }) }
    Remove-MarkSlices $e $script:goneMarks }
    Event $e 'restore-db' @{ mark = $m.name; end = $end; fallback = @($script:RestoreFallback | ForEach-Object table); recorded = (-not $noRows) }
  }
  $null
}
# the tables a restore could not bring back exactly: the seed items that name them (seed item tables), else the whole seed -> a note
function Invoke-RestoreFallback([string]$e) {
  $t = @($script:RestoreFallback | ForEach-Object table | Select-Object -Unique); if (-not $t.Count) { return $null }
  $script:SeedBad = $false
  $out = try { @(Invoke-Seed $e -Tables $t) } catch { @("seed failed: $("$_".Split("`n")[0])"); $script:SeedBad = $true }
  "fallback (not restored exactly, seeded): $(@($script:RestoreFallback | ForEach-Object { "$($_.table) ($($_.why))" }) -join '; ') -> seed $(if ($script:SeedBad) { 'NOT green' } else { 'green' }): $(@($out | Select-Object -First 1))"
}

# ---- seed: the env's baseline data (envs.<env>.seed; items format: envy db.md "seed")
function SeedFile([string]$e) { $f = (Get-EnvCfg $e).seed; if ($f) { Expand-Placeholders ([string]$f) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '' } else { Join-Path (Get-KitPath localenv-env) "$((Get-EnvCfg $e).group).seed.json" } }   # lanes share their envs fixtures
# -> ok | missing | drift (the value differs from expect) | error
function Test-SeedItem([string]$e, $it) {
  $log = LogFile $e 'seed'
  if ($it.check.cmd) {
    $code = Invoke-Shell (Expand-Placeholders ([string]$it.check.cmd) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '') $log (EnvVars $e ([pscustomobject]@{})) 120
    return @{ state = $(switch ($code) { 0 { 'ok' } 1 { 'missing' } default { 'error' } }); got = "exit $code" }
  }
  if (-not $it.check.sql) { return @{ state = 'error'; got = 'no check' } }
  $err = Invoke-Hook $e 'query' @{ sql = [string]$it.check.sql }
  if ($err) { return @{ state = 'error'; got = $err } }
  $v = "$(@($script:HookOut | Where-Object { "$_".Trim() })[0])".Trim()
  $want = if ($it.check.expect) { [string]$it.check.expect } else { '^[1-9]\d*$' }
  @{ state = $(if (-not $v -or $v -eq '0') { 'missing' } elseif ($v -notmatch $want) { 'drift' } else { 'ok' }); got = $v }
}
# why seed skips a create (drift needs create.upsert: an insert adds rows); none = it runs
function Get-SeedSkipWhy($it, $r) {
  if ($r.state -eq 'blocked') { return "$($r.got) first" }; if ($r.state -eq 'error') { return "check failed: $($r.got)" }; if (-not $it.create.cmd) { return 'no create.cmd' }
  if ($r.state -ne 'drift') { return }; if (-not $it.create.upsert) { return 'create.upsert not set' }
  if ("$($it.check.expect)" -match '^\^(\d+)\$$' -and [long]$Matches[1] -lt ("$($r.got)" -as [long])) { "has $($r.got), expects $($Matches[1]): remove extras by hand" }
}
# the tool's missingRoutines verb: routines a scope's applied migrations made that it lacks (dropped by a reset) -> @{ schema; names; files }
function Get-MissingRoutines([string]$e) { $tool = Get-MigTool $e; if (Test-MigVerb $tool 'missingRoutines') { Invoke-MigVerb $tool 'missingRoutines' @{ e = $e } } }
# rerunRoutines: a scope's missing routines made pending -> notes
function Reset-MissingRoutines([string]$e, [string]$s) { $tool = Get-MigTool $e; if (Test-MigVerb $tool 'rerunRoutines') { Invoke-MigVerb $tool 'rerunRoutines' @{ e = $e; schema = $s } } }

# -Tables (a restore's fallback): the items naming one (schema.table or table) + their needs; none named: all
function Invoke-Seed([string]$e, [switch]$Check, [string[]]$Tables) {
  $f = SeedFile $e; if (-not (Test-Path -LiteralPath $f)) { throw "[$e] no seed file $f (envs.$e.seed)" }
  $items = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).items | Where-Object { $_ })
  if ($Tables) {
    $short = @($Tables | ForEach-Object { ($_ -split '\.', 2)[-1] })
    $pick = @($items | Where-Object { @($_.tables | Where-Object { $_ -in $Tables -or $_ -in $short }).Count } | ForEach-Object name)
    for ($i = 0; $i -lt 10; $i++) { $pick = @($pick + @($items | Where-Object { $_.name -in $pick } | ForEach-Object { @($_.needs) }) | Where-Object { $_ } | Select-Object -Unique) }   # TODO-PARAM (fixed default)
    if ($pick.Count) { $items = @($items | Where-Object { $_.name -in $pick }) }
  }
  $res = [ordered]@{}; $lines = [Collections.Generic.List[string]]::new(); $skipped = [Collections.Generic.List[string]]::new()
  foreach ($it in $items) {
    $blocked = @($it.needs | Where-Object { $_ -and $res[$_] -ne 'ok' })
    $r = if ($blocked.Count) { @{ state = 'blocked'; got = "needs $($blocked -join ', ')" } } else { Test-SeedItem $e $it }
    $why = if (-not $Check -and $r.state -ne 'ok') { Get-SeedSkipWhy $it $r }
    if (-not $Check -and $r.state -in 'missing', 'drift' -and -not $why) {
      $code = Invoke-Shell (Expand-Placeholders ([string]$it.create.cmd) $e ([pscustomobject]@{ port = '' }) $KitConf.Workspace '') (LogFile $e 'seed') (EnvVars $e ([pscustomobject]@{})) 600
      $r = if ($code) { @{ state = 'error'; got = "create $(Get-ShellWhy $code): $((@($script:ShellOut) | Select-Object -Last 2) -join ' | ')" } } else { $x = Test-SeedItem $e $it; $x.created = $true; $x }
      if ($r.state -ne 'ok') { $why = "create ran, still $($r.state): $($r.got)$(Get-SeedDownHint $e)" }
    }
    $res[[string]$it.name] = $r.state
    if ($why) { $skipped.Add("$($it.name) ($why)") }
    $lines.Add(('  {0,-8} {1}{2}' -f $r.state.ToUpper(), $it.name, $(if ($r.state -eq 'ok') { if ($r.created) { ' (created)' } } else { " - $(if ($why) { $why } else { $r.got })$(if ($it.how -and $r.state -ne 'blocked' -and ($why -or ($r.state -eq 'missing' -and -not $it.create.cmd))) { "; how: $($it.how)" })" })))
  }
  if (-not $Tables) {
    foreach ($g in @(try { Get-MissingRoutines $e } catch { $res['routines'] = 'error'; $items += @{ name = 'routines' }; $lines.Add("  ERROR    routines - $("$_".Split("`n")[0])") })) {
      if (-not $g.schema) { continue }
      $res["routines:$($g.schema)"] = 'drift'; $items += @{ name = "routines:$($g.schema)" }
      $lines.Add("  DRIFT    routines:$($g.schema) - $($g.names -join ', ') missing, DATABASECHANGELOG says $($g.files -join ', ') ran; how: delete those rows in $($g.schema), reset its migration skip marker (restore.after) and restart the service")
    }
  }
  $bad = @($res.Keys | Where-Object { $res[$_] -ne 'ok' })
  if (-not $Tables) { Update-State $e { param($x) $x.seed = @{ at = (Now); ok = (-not $bad.Count); missing = @($bad | Where-Object { $res[$_] -in 'missing', 'blocked' }); drift = @($bad | Where-Object { $res[$_] -in 'drift', 'error' }) } } }
  Event $e 'seed' @{ check = [bool]$Check; bad = $bad }
  "[$e] seed$(if ($Check) { ' -Check' })$(if ($Tables) { " ($(@($items).Count) item(s) for $($Tables -join ', '))" }): $($items.Count - $bad.Count)/$($items.Count) ok ($f)"; $lines
  if ($skipped.Count) { "[$e] seed could not create $($skipped.Count): $($skipped -join '; ')" }
  if (-not $bad.Count -and -not $Check -and -not $Tables) { $n = New-Mark $e (New-KitName baseline $e) 'baseline'; if ($n) { "[$e] mark ${n}: restore -Mark $n brings the env back to this seed" } }
  if ($bad.Count) { $script:SeedBad = $true }
}

# ---- processes: CPU load, port owners, service processes
# CPU load and port owners (only the local env uses them)
function Get-SysCpu {
  if ($KitIsWindows) { return [math]::Round([double](Get-CimInstance Win32_Processor -Property LoadPercentage | Measure-Object LoadPercentage -Average).Average, 0) }
  if (Test-Path /proc/stat) {
    $read = { $f = ((Get-Content /proc/stat -TotalCount 1) -split '\s+' | Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object { [double]$_ }); @{ idle = $f[3] + $f[4]; all = ($f | Measure-Object -Sum).Sum } }
    $a = & $read; Start-Sleep -Milliseconds 500; $b = & $read
    $d = $b.all - $a.all; if ($d -le 0) { return 0 }
    return [math]::Round(100 * (1 - ($b.idle - $a.idle) / $d), 0)
  }
  $sum = (ps -A -o %cpu= 2>$null | ForEach-Object { [double]"$_".Trim() } | Measure-Object -Sum).Sum
  [math]::Min(100.0, [math]::Round($sum / [Environment]::ProcessorCount, 0))
}
# one listen-table snapshot per 2 s (netstat takes ~0.2 s); Stop-Svc drops it
$script:ListenSnap = $null
# a listener = state Listen or no remote end (some Windows boots report state 0)
function Test-ListenRow($c) { "$($c.State)" -eq 'Listen' -or ([int]$c.RemotePort -eq 0 -and "$($c.RemoteAddress)" -in '0.0.0.0', '::') }
function Get-PortPids([int]$Port) {
  if ($KitIsWindows) {
    if (-not $script:ListenSnap -or ((Get-Date) - $script:ListenSnap.at).TotalSeconds -gt $(if ($script:StatusSnap) { 60 } else { 2 })) {
      $m = @{}; foreach ($c in @(Get-KitTcpRows | Where-Object { Test-ListenRow $_ })) { $k = "$($c.LocalPort)"; if (-not $m[$k]) { $m[$k] = [Collections.Generic.List[int]]::new() }; if (-not $m[$k].Contains([int]$c.OwningProcess)) { $m[$k].Add([int]$c.OwningProcess) } }
      $script:ListenSnap = @{ at = Get-Date; ports = $m }
    }
    return @($script:ListenSnap.ports["$Port"] | Where-Object { $_ })
  }
  if (Resolve-Tool lsof) { return @(lsof -t -nP -iTCP:$Port -sTCP:LISTEN 2>$null | ForEach-Object { [int]$_ } | Select-Object -Unique) }
  if (Resolve-Tool fuser) { return @(("$(fuser -n tcp $Port 2>$null)" -split '\s+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
  @()
}
# up = an IPv4 connect succeeds (127.0.0.1, else the LAN address of a {lanIp}-bound service); a ::1-only server is not up
function Test-PortListening([int]$Port) {
  if ($KitIsWindows -and -not @(Get-PortPids $Port).Count) { return $false }   # the listen table first: a refused connect costs ~2 s there
  foreach ($ip in @('127.0.0.1', $(if ($KitIsWindows) { LanIp }) | Select-Object -Unique)) {
    $t = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try { if ($t.ConnectAsync($ip, $Port).Wait(1000) -and $t.Connected) { return $true } } catch { } finally { $t.Dispose() }
  }
  $false
}
# process trees from one lib Get-KitProcSnap (children map: linear, not a scan of every process per id)
function TreeIds([int]$root, $snap) {
  if (-not $snap) { $snap = Get-KitProcSnap }
  $ids = [Collections.Generic.List[int]]::new(); $ids.Add($root)
  for ($i = 0; $i -lt $ids.Count; $i++) { foreach ($c in @($snap.kids[$ids[$i]])) { if ($null -ne $c -and -not $ids.Contains([int]$c)) { $ids.Add([int]$c) } } }
  @($ids)
}
function SvcPids([string]$e, $s, $st, $snap) {
  $x = $st.services[$s.name]; $ids = @()
  if (Owned $x) { $ids += TreeIds ([int]$x.pid) $snap }
  if ($s.port) { $ids += @(Get-PortPids ([int]$s.port)) }
  @($ids | Where-Object { $_ } | Select-Object -Unique)
}
function TreeGB([int[]]$ids, $snap) {
  if (-not $ids) { return 0 }
  if (-not $snap) { $snap = Get-KitProcSnap }
  [math]::Round((@($ids | Select-Object -Unique | ForEach-Object { [double]$snap.procs[$_] }) | Measure-Object -Sum).Sum / 1GB, 2)
}
# the first line matching $pattern written to $f since the last call (byte offset per file in $pos; the first call starts at the end)
function Find-NewLogLine([string]$f, [string]$pattern, [hashtable]$pos) {
  $i = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue; if (-not $i) { return $null }
  $from = if (-not $pos.ContainsKey($f)) { $i.Length } elseif ($pos[$f] -gt $i.Length) { 0 } else { $pos[$f] }   # shorter: rotated
  if ($i.Length -le $from) { $pos[$f] = $i.Length; return $null }
  $at = [math]::Max($from, $i.Length - 4MB); $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
  try { [void]$fs.Seek($at, 'Begin'); $bs = [byte[]]::new($i.Length - $at); $n = $fs.Read($bs, 0, $bs.Length) } finally { $fs.Dispose() }
  $end = if ($n) { [array]::LastIndexOf($bs, [byte]10, $n - 1) } else { -1 }; $pos[$f] = $at + $end + 1   # in bytes: a line still being written is read again
  $m = [regex]::Match([Text.Encoding]::UTF8.GetString($bs, 0, $end + 1), "(?m)^.*(?:$pattern).*$"); if ($m.Success) { $m.Value.Trim() } else { $null }
}
function Read-FileRange([string]$f, [long]$from, [long]$to) {
  $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
  try { [void]$fs.Seek($from, 'Begin'); $b = [byte[]]::new($to - $from); $n = $fs.Read($b, 0, $b.Length); [Text.Encoding]::UTF8.GetString($b, 0, $n) } finally { $fs.Dispose() }
}
# a log's last lines, read from the end in 1 MB steps (never the whole file): -Grep filters, -Since keeps entries whose leading
# timestamp (yyyy-MM-dd HH:mm:ss, ISO, Z or an offset) is newer than that many minutes; untimed lines belong to the entry above
function Read-LogTail([string]$f, [int]$tail, [string]$grep, [double]$sinceMin) {
  $len = (Get-Item -LiteralPath $f).Length; $cut = if ($sinceMin -gt 0) { [DateTimeOffset]::Now.AddMinutes(-$sinceMin) } else { $null }
  $lines = [Collections.Generic.List[string]]::new(); $hold = [Collections.Generic.List[string]]::new(); $end = $len; $carry = ''; $done = $false; $timed = $false
  while ($end -gt 0 -and -not $done -and ($len - $end) -lt $(if ($cut -and -not $timed) { 16MB } else { 256MB })) {
    $from = [math]::Max(0, $end - 1MB); $parts = ((Read-FileRange $f $from $end) + $carry) -split "`r?`n"
    $carry = if ($from -gt 0) { $parts[0] } else { '' }; $chunk = @($parts | Select-Object -Skip ([int]($from -gt 0)))
    [array]::Reverse($chunk)
    foreach ($l in $chunk) {
      if ($l -eq '' -or ($grep -and $l -notmatch $grep -and -not $cut)) { continue }
      if ($cut) {
        if ($l -match '^\W{0,3}(\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?(?:Z|[+-]\d\d:?\d\d)?)') {
          $timed = $true; $t = [DateTimeOffset]::MinValue
          if ([DateTimeOffset]::TryParse(($Matches[1] -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$t) -and $t -lt $cut) { $done = $true; break }
          foreach ($h in @($hold) + $l) { if (-not $grep -or $h -match $grep) { $lines.Add($h) } }; $hold.Clear()
        } else { $hold.Add($l) }   # kept only if its entry is new enough
        continue
      }
      $lines.Add($l); if ($lines.Count -ge $tail) { $done = $true; break }
    }
    $end = $from
  }
  if ($cut -and -not $done) { foreach ($h in $hold) { if (-not $grep -or $h -match $grep) { $lines.Add($h) } } }
  $out = @($lines); [array]::Reverse($out); @($out | Select-Object -Last $tail)
}
function StartMin($s) { [double]$(if ($s.startMinutes) { $s.startMinutes } else { Get-KitParam 'localEnv.startMinutes' }) }
function Healthy([string]$e, $s) {
  if ($s.port -and -not (Test-PortListening ([int]$s.port))) { return $false }   # nothing listens: no HTTP wait (status -Json stays fast)
  if ($s.health) {
    try { $r = Invoke-WebRequest (Expand-Placeholders $s.health $e $s (SvcDir $e $s) '') -ConnectionTimeoutSeconds 5 -OperationTimeoutSeconds 10 -UseBasicParsing -SkipCertificateCheck -SkipHttpErrorCheck; return $r.StatusCode -gt 0 -and $r.StatusCode -lt 500 } catch { return $false }
  }
  if ($s.port) { return $true }
  Owned (Read-State $e).services[$s.name]
}
function Stop-Svc([string]$e, $s, [string]$why = 'stopped') {
  $st = Read-State $e; $x = $st.services[$s.name]
  $mine = @(); if (Owned $x) { $mine = TreeIds ([int]$x.pid) }
  $ran = (Owned $x) -or ($s.port -and @(Get-PortPids ([int]$s.port)).Count)   # the stop event only when something ran
  if (Owned $x) {
    if ($KitIsWindows) { taskkill /PID $x.pid /T /F 2>&1 | Out-Null }
    else { $ids = TreeIds ([int]$x.pid); [array]::Reverse($ids); $ids | ForEach-Object { Stop-SysProcess $_ } }
  }
  if ($s.port) { foreach ($p in Get-PortPids ([int]$s.port)) { if ($p -gt 4 -and ($p -in $mine -or (EnvProcess $p $e))) { Stop-SysProcess $p } } }
  $script:ListenSnap = $null
  if ($x.peakGB) { Save-LocalEnvHistory "$e/$($s.name)" ([double]$x.peakGB) }   # the learned need: its peak while it ran, not its size at start
  Update-State $e { param($z) $o = $z.services[$s.name]; $z.services[$s.name] = @{ status = 'down'; port = $s.port; at = (Now); release = $o.release; artifact = $o.artifact; why = $why; restarts = @($o.restarts); aot = $o.aot } }
  if ($ran) { Event $e 'stop' @{ service = $s.name; why = $why } }
}
function Get-LocalEnvHistory { $h = try { Read-KitText (Get-KitPath localenv-history) | ConvertFrom-Json -AsHashtable } catch { $null }; if ($h -isnot [hashtable]) { $h = @{} }; $h }
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
  # a first start's guess per stack family (params.registry.json localEnv.needGB.<family>), until a start is measured
  $fam = switch -regex ($st) { '^java|^gradle|^android' { 'jvm' } '^angular' { 'angular' } '^dotnet' { 'dotnet' } '^node|^react' { 'node' } '^python|^go|^rust' { 'light' } default { 'other' } }
  [double](Get-KitParam "localEnv.needGB.$fam")
}
function GraceMin([string]$e, $s) {
  $xs = @((Get-LocalEnvHistory)["$e/$($s.name)/startSec"] | Where-Object { $_ })
  $start = if ($xs.Count) { ($xs | Measure-Object -Maximum).Maximum } else { 120 }
  if ([int](Get-EnvCfg $e).lane -gt 1) { return [math]::Max([double](Get-KitParam 'idle.graceMinutes'), [math]::Round(3 * $start / 60, 1)) }   # K58: an extra lane closes after the idle grace (3 starts at least)
  [math]::Min($script:IdleMaxM, [math]::Max($script:IdleMinM, [math]::Round(3 * $start / 60, 1)))
}
# free RAM (avail + half the file cache), one sample a minute while a controller runs, 24 h kept (localenv-history "ram")
function Add-RamSample([double]$gb) {
  $f = Get-KitPath localenv-history -Create
  Invoke-KitLocked $f {
    $h = Get-LocalEnvHistory; $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $xs = @(@($h.ram) | Where-Object { $_ -and $now - [long]$_[0] -lt 86400 })
    if ($xs.Count -and $now - [long]$xs[-1][0] -lt 55) { return }   # another env's controller sampled
    $h.ram = @($xs) + , @($now, [math]::Round($gb, 1)); $h | ConvertTo-Json -Depth 4 | Set-Content $f -Encoding utf8
  }
}
# the keep-free floor from samples (oldest first): a sane minimum + how far free RAM falls in 10 min + how often it dipped under 6 GB
function Get-KeepFreeFrom([double[]]$xs, [double]$total) {
  $min = [math]::Max(3.0, [math]::Round($total * 0.05, 1))   # TODO-PARAM (fixed default)
  $floor = [double](Get-KitParam 'localEnv.keepFreeFloorGB')
  if ($xs.Count -lt 60) { return @{ gb = [math]::Max($floor, [math]::Round($total * 0.15, 1)); why = "learning ($($xs.Count)/60 free-RAM samples): max($floor GB, 15% of RAM)" } }
  $drops = @(for ($i = 10; $i -lt $xs.Count; $i++) { [math]::Max(0.0, $xs[$i - 10] - $xs[$i]) }) | Sort-Object
  $swing = [math]::Round([double]@($drops)[[int][math]::Floor(0.9 * (@($drops).Count - 1))], 1)
  $dips = @(for ($i = 1; $i -lt $xs.Count; $i++) { if ($xs[$i] -lt $floor -and $xs[$i - 1] -ge $floor) { 1 } }).Count
  $gb = [math]::Max($min, [math]::Min([math]::Round($total * 0.25, 1), [math]::Round($min + $swing + 0.5 * [math]::Min($dips, 8), 1)))
  @{ gb = $gb; why = "min $min + 10-min fall $swing (p90 of 24 h) + $dips dip(s) under $floor GB x 0.5" }
}
$script:KeepFree = $null
function Get-KeepFree {
  if ($env:CLAUDE_GATE_KEEP_FREE_GB) { return @{ gb = [double]$env:CLAUDE_GATE_KEEP_FREE_GB; why = 'fixed (CLAUDE_GATE_KEEP_FREE_GB)' } }
  $fixed = Get-KitSetting 'localEnv.keepFreeGB' (Get-KitSetting 'gate.keepFreeGB' $null)
  if ($null -ne $fixed) { return @{ gb = [double]$fixed; why = 'fixed (keepFreeGB)' } }
  if ($script:KeepFree -and ((Get-Date) - $script:KeepFree.at).TotalSeconds -lt 60) { return $script:KeepFree }
  $xs = @(@((Get-LocalEnvHistory).ram) | Where-Object { $_ } | ForEach-Object { [double]$_[1] })
  $script:KeepFree = (Get-KeepFreeFrom $xs (Get-SysMem).TotalGB) + @{ at = Get-Date }; $script:KeepFree
}
function KeepFreeGB { [double](Get-KeepFree).gb }
function Pressure {
  if ((Get-GateAvailGB (Get-SysMem)) -lt (KeepFreeGB)) { return 'RAM below the keep-free floor' }
  $q = Join-Path (Get-KitGateLedger) 'queue'
  $w = @(Get-ChildItem $q -Filter *.json -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 1 -and $(try { $tk = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; Test-KitPid $tk.pid $tk.start } catch { $false }) })
  if ($w.Count) { return "$($w.Count) gated build(s) waiting for RAM" }
  # a start waiting for RAM in any env: idle unleased services elsewhere make room (the caller stops them biggest first);
  # a CPU wait or a dependent's start claim is no pressure (a stop frees no CPU)
  $ws = @(foreach ($n in EnvNames) { $st = Read-State $n; foreach ($k in @($st.services.Keys)) { $v = $st.services[$k]; if ($v.status -eq 'waiting' -and "$($v.waitFor)" -in '', 'RAM' -and (Test-KitPid $v.waitPid $v.waitStart)) { "$n/$k" } } })
  if ($ws.Count) { return "start(s) waiting for RAM: $($ws -join ', ')" }
  $null
}
function Test-Room([string]$e, $s, [double]$waitedMin) { $m = Get-SysMem; Test-GateStart ((Get-GateAvailGB $m) - (Need-GB $e $s)) (KeepFreeGB) $waitedMin $m.TotalGB }
# Wait-Room (RAM + the CPU queue): adapters/shared-builds.ps1 "start room"
function Start-Pwsh([string[]]$a, [string]$dir, [string]$match, [string]$log) {
  $a = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'envy.ps1')) + $a; $pwsh = (Get-Process -Id $PID).Path
  if ($KitIsWindows) { return (Start-Process -FilePath $pwsh -ArgumentList (($a | ForEach-Object { if ("$_" -match '\s' -or "$_" -eq '') { "`"$_`"" } else { $_ } }) -join ' ') -WorkingDirectory $dir -WindowStyle Hidden -PassThru).Id }
  Start-Detached -FilePath $pwsh -ArgumentList $a -WorkingDirectory $dir -Log $log
  Start-Sleep 1; (Get-SysProcs | Where-Object { $_.CommandLine -match [regex]::Escape($match) } | Select-Object -First 1).Id
}
# a start waits for its dependsOn to be HEALTHY (one waiting for room: past startMinutes); dependency connection failure: wait, retry once
$script:DepFailPattern = [string](Opt 'logClasses.dependency' '(?i)connection refused|ECONNREFUSED|ConnectException|UnknownHostException|could not connect|connection (timed out|reset)')   # a dependency down at start (localEnv.logClasses.dependency)
# a dependency that is down and that nobody starts is claimed (status waiting, waitFor dep: the loop leaves it) and started here
# a train's DB steps (marks, slices, migration checks, the guard, a restore) on a lane whose own DB service rests: a start in
# progress is waited for, else the train starts it (-Latest: a start that got there first wins) -> its lines; throws when it fails
function Test-SvcStartLive([string]$e, [string]$name) {   # a start in progress: owned starting, a live claim (room, lock, dep) or the loop's worker pre-claim
  $x = (Read-State $e).services[$name]
  if (($x.status -eq 'starting' -and (Owned $x)) -or ($x.status -eq 'waiting' -and (Test-KitPid $x.waitPid $x.waitStart))) { return $true }
  [bool]@(Get-SysProcs | Where-Object { "$($_.CommandLine)" -match "$([regex]::Escape("_daemon -Env $e -Start $name"))(\s|$)" }).Count
}
function Ensure-DbUp([string]$e, [int]$release) {
  $d = DbSvc $e; if (-not $d -or -not (DbSvcDown $e)) { return }
  $until = (Get-Date).AddMinutes((StartMin $d))
  while ((DbSvcDown $e) -and (Get-Date) -lt $until) {
    if (-not (Test-SvcStartLive $e $d.name)) { break }
    Start-Sleep 2
  }
  if (DbSvcDown $e) { "[$e] $($d.name) rests: started for the train's DB steps"; Start-Svc $e $d $release '' -Latest }
}
function Wait-Deps([string]$e, $s) {
  foreach ($d in @($s.dependsOn | Where-Object { $_ })) {
    $ds = Svc $e $d; if (-not $ds) { continue }; $t0 = Get-Date; $until = $t0.AddMinutes((StartMin $ds)); $said = $false
    $hard = $t0.AddMinutes($script:RoomWaitMin + (StartMin $ds)); $saidLive = $t0   # its own start still waiting for room: its room wait + start
    $xd = (Read-State $e).services[$d]
    if (-not (Healthy $e $ds) -and (Managed $ds) -and -not ($ds.repo -and $ds.artifact -and -not ($xd.artifact -and (Test-Path -LiteralPath $xd.artifact)))) {   # no build yet: the loop queues one
      $c = @{ ok = $false }
      Update-State $e { param($x) if (-not $x.services[$d]) { $x.services[$d] = @{ status = 'down' } }; $v = $x.services[$d]
        if (-not ((Owned $v) -or ($v.status -eq 'waiting' -and (Test-KitPid $v.waitPid $v.waitStart)))) {
          $v.status = 'waiting'; $v.waitFor = 'dep'; $v.waitPid = $PID; $v.waitStart = Get-KitPidStart $PID; $c.ok = $true; $c.rel = [int]$x.release.n; $c.art = "$($v.artifact)" } }
      if ($c.ok) {
        "[$e] $($s.name): its dependency $d is down: starting it first"; Event $e 'dep-start' @{ service = $d; for = $s.name }
        try { Start-Svc $e $ds $c.rel $c.art -Latest }
        catch { $de = "$_".Split("`n")[0]; Update-State $e { param($x) if ($x.services[$d].status -eq 'waiting' -and $x.services[$d].waitPid -eq $PID) { $x.services[$d].status = 'failed'; $x.services[$d].why = $de } }; throw "[$e] $($s.name): dependency down: $d did not start ($de) - not started" }
      }
    }
    while (-not (Healthy $e $ds)) {
      $now = Get-Date
      if ($now -gt $until) {
        if ($now -gt $hard -or -not (Test-SvcStartLive $e $d)) { throw "[$e] $($s.name): dependency down: $d was not healthy within $([int]($now - $t0).TotalMinutes) min - not started" }
        if (($now - $saidLive).TotalMinutes -ge 5) { "[$e] $($s.name) still waits for $d`: its start is in progress (up to $([int]($hard - $t0).TotalMinutes) min)"; $saidLive = $now }
      }
      if (-not $said) { "[$e] $($s.name) waits for $d to be healthy"; $said = $true }; Wait-KitPoll 5
    }
  }
}
function Start-Svc([string]$e, $s, [int]$release, [string]$artifact, [switch]$Latest) {
  Wait-Deps $e $s
  try { Start-SvcOnce $e $s $release $artifact -Latest:$Latest }
  catch {
    if ("$_" -notmatch $script:DepFailPattern) { throw }
    "[$e] $($s.name) failed on a dependency connection: waiting for $(if (@($s.dependsOn).Count) { @($s.dependsOn) -join ', ' } else { '30 s (no dependsOn)' }), then one retry"
    Event $e 'start-retry' @{ service = $s.name; why = "$_".Split("`n")[0] }
    if (@($s.dependsOn | Where-Object { $_ }).Count) { Wait-Deps $e $s } else { Wait-KitPoll 30 }
    try { Start-SvcOnce $e $s $release $artifact -Latest:$Latest }
    catch {
      $down = @($s.dependsOn | Where-Object { $_ -and (Svc $e $_) -and -not (Healthy $e (Svc $e $_)) })
      if ("$_" -match $script:DepFailPattern -and $down.Count) { throw "[$e] $($s.name): dependency down: $($down -join ', ') went down during its start - not started" }
      throw
    }
  }
}
# -Latest (start worker): the copy the state names once room and lock are got; trains staged and pruned while it waited
function Start-SvcOnce([string]$e, $s, [int]$release, [string]$artifact, [switch]$Latest) {
  $dir = Resolve-SvcDir $e $s
  if (-not (Test-Path $dir)) { throw "[$e] $($s.name): folder $dir does not exist" }
  $cmd = StartCmd $e $s $artifact
  $x0 = (Read-State $e).services[$s.name]
  # a service never started here (an on-demand lane DB): its row is made first, or Wait-Room's / the up write's .status set fails on null
  if ($null -eq $x0) { Update-State $e { param($x) if ($x.services[$s.name] -isnot [hashtable]) { $x.services[$s.name] = @{ status = 'down' } } } }
  $freed = @{ v = $false }
  $free = { param([string]$why) $xs = (Read-State $e).services[$s.name]
    if ((Owned $xs) -or ($s.port -and @(Get-PortPids ([int]$s.port)).Count)) { Stop-Svc $e $s $why; $freed.v = $true }   # only when it runs or holds its port
    if ($s.port -and (Test-PortListening ([int]$s.port))) {
      $holder = @(Get-PortPids ([int]$s.port)) -join ','
      Update-State $e { param($x) $x.services[$s.name].status = 'failed'; $x.services[$s.name].why = "port $($s.port) held by pid $holder (not started by the env)" }
      throw "[$e] $($s.name): port $($s.port) is held by pid $holder, which the env did not start: stop it or change the port"
    } }
  & $free 'stopped before a new start'
  if ($s.init.cmd -and -not ($s.init.creates -and (Test-Path -LiteralPath (Expand-Placeholders ([string]$s.init.creates) $e $s $dir '')))) {   # before a start while init.creates is missing (a lane's own data)
    $ic = Expand-Placeholders ([string]$s.init.cmd) $e $s $dir ''; $ilog = LogFile $e "$($s.name)-init"; Add-Content $ilog "== $(Now) init: $ic"
    "[$e] $($s.name): init (once; log $ilog)"; $t0i = Get-Date
    $code = Invoke-Shell $ic $ilog (EnvVars $e $s) ([int]$(if ($s.init.timeoutSec) { $s.init.timeoutSec } else { 1800 }))
    if ($code) { Event $e 'init-failed' @{ service = $s.name; why = (Get-ShellWhy $code) }; throw "[$e] $($s.name): init failed ($(Get-ShellWhy $code)): $((@($script:ShellOut) | Select-Object -Last 5) -join ' | '). Log: $ilog" }
    Event $e 'init' @{ service = $s.name; sec = [int]((Get-Date) - $t0i).TotalSeconds }
    if ((DbSvc $e).name -eq $s.name) { $null = New-Mark $e (New-KitName baseline $e) 'baseline' }
  }
  # RAM first, then the machine-wide start lock for launch + health only; RAM is checked again under the lock
  $mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { 'Global\kit-localenv-start' } else { 'kit-localenv-start' }))
  $got = $false; $tw = Get-Date; $dbStarted = $false
  try {
    for ($round = 1; ; $round++) {
      Wait-Room $e $s
      try { $got = $mx.WaitOne([TimeSpan]::FromMinutes((Get-KitParam 'localEnv.startLockMinutes'))) } catch [Threading.AbandonedMutexException] { $got = $true }
      if (-not $got) { throw "[$e] $($s.name): another service start held the machine-wide start lock for $(Get-KitParam 'localEnv.startLockMinutes') min (localEnv.startLockMinutes) - not started (envy.ps1 events)" }
      if (Test-Room $e $s ((Get-Date) - $tw).TotalMinutes) { break }
      $mx.ReleaseMutex(); $got = $false
      if ($round -ge 3) { throw "[$e] $($s.name): RAM was taken while it waited for the start lock (3 rounds) - not started" }
      "[$e] RAM fell while $($s.name) waited for the start lock: waiting for room again"
    }
    $xl = if ($Latest) { (Read-State $e).services[$s.name] }
    if ($Latest -and ((Healthy $e $s) -or ($xl.status -eq 'starting' -and (Owned $xl) -and $xl.pid -ne $x0.pid))) { "[$e] $($s.name): started by another process meanwhile"; return }   # a worker or a dependent's start got there first
    $freed.v = $false; & $free 'stopped before a new start (another start ran it while this one waited for room)'   # 2026-11-13: r356 kept 8443 + debug port, r357 "came up" on it
    if ($freed.v) { Update-State $e { param($x) $v = $x.services[$s.name]; $v.status = 'waiting'; $v.waitFor = 'lock'; $v.waitPid = $PID; $v.waitStart = Get-KitPidStart $PID } }   # the stop wrote down: keep the claim so the loop queues no second start
    if ($xl.artifact -and "$($xl.artifact)" -ne $artifact) { "[$e] $($s.name): a newer staged copy since this start was queued (release $($xl.release))"; $artifact = "$($xl.artifact)"; if ($xl.release) { $release = [int]$xl.release }; $cmd = StartCmd $e $s $artifact }
    $log = LogFile $e $s.name; $logFrom = 0   # a reader holding the log (tidy, logs -Grep): append, scan only the new lines
    if (Test-Path $log) { try { Move-Item $log "$log.prev" -Force -ErrorAction Stop } catch { $logFrom = (Get-Item $log).Length; "[$e] $($s.name): $log is open elsewhere, appending to it" } }
    "[$e] starting $($s.name)$(if ($release) { " (release $release)" }): $cmd"
    $t0 = Get-Date
    $p = Start-Pwsh @('_exec', '-Env', $e, '-Service', $s.name, '-Artifact', "$artifact") $dir "_exec -Env $e -Service $($s.name)" "$log.wrapper"
    Update-State $e { param($x) $o = $x.services[$s.name]; $x.services[$s.name] = @{ status = 'starting'; pid = $p; pstart = "$(if (PStart $p) { (PStart $p).ToString('o') })"; port = $s.port; startedAt = (Now); lastNeed = (Now); release = $release; artifact = $artifact; restarts = @($o.restarts); aot = $o.aot } }
    $limit = (Get-Date).AddMinutes((StartMin $s))
    $fail = if ($s.failPattern) { [string]$s.failPattern } else { $script:FailPattern }
    $ready = if ($s.readyPattern) { [string]$s.readyPattern } else { $script:ReadyPattern }
    $failPos = @{ $log = $logFrom }; $readyPos = @{ $log = $logFrom }; $seen = $false
    # 1 s poll: fail / ready lines each second, health each 5 s until ready, then each second
    for ($i = 0; ; $i++) {
      if (-not $seen -and $ready -and (Find-NewLogLine $log $ready $readyPos)) { $seen = $true }
      if (($seen -or $i % 5 -eq 0) -and (Healthy $e $s)) { break }
      $hit = if ($fail) { Find-NewLogLine $log $fail $failPos }
      $why = if ($hit) { "failed to start (log line: $hit)" } elseif (-not (Alive $p)) { 'exited while starting' } elseif ((Get-Date) -gt $limit) { "not healthy within $(StartMin $s) min" } else { $null }
      if ($why) {
        Stop-Svc $e $s $why; Update-State $e { param($x) $x.services[$s.name].status = 'failed' }
        Event $e 'start-failed' @{ service = $s.name; why = $why; release = $release }
        throw "[$e] $($s.name) $why. $(Save-FailLog $log $release)`n$((Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n")"   # the tail: DepFailPattern reads it
      }
      # poll-ok: bounded
      Start-Sleep 1
    }
    $sec = [int]((Get-Date) - $t0).TotalSeconds
    $snap = Get-KitProcSnap; $gb = TreeGB (@(TreeIds $p $snap) + @(if ($s.port) { Get-PortPids ([int]$s.port) })) $snap
    Save-LocalEnvHistory "$e/$($s.name)" $gb; Save-LocalEnvHistory "$e/$($s.name)/startSec" $sec
    Update-State $e { param($x) $x.services[$s.name].status = 'up'; $x.services[$s.name].gb = $gb; $x.services[$s.name].upAt = (Now) }
    Event $e 'up' @{ service = $s.name; release = $release; sec = $sec; gb = $gb; aot = [bool]($artifact -and (Test-Path -LiteralPath "$(AotFile $artifact)")) }
    "[$e] $($s.name) up$(if ($s.port) { " on port $($s.port)" }) in $sec s ($gb GB)"
    if ((DbSvc $e).name -eq $s.name) {   # marks queued while the DB was down
      $pm = @((Read-State $e).pendingMarks | Where-Object { $_ })
      foreach ($m in $pm) { try {   # each leaves the queue only once taken (a failed one waits for the next start)
        "[$e] mark $(New-Mark $e $m.name $m.kind $m.repos ([int]$m.release)) (waited for $($s.name))"; Update-State $e { param($x) $x.pendingMarks = @(@($x.pendingMarks) | Where-Object { $_ -and $_.name -ne $m.name }) }
      } catch { "[$e] mark $($m.name) still queued: $("$_".Split("`n")[0])" } }
      $dbStarted = $true
    }
    Start-AotTrain $e $s $artifact
  } finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose(); Update-State $e { param($x) $v = $x.services[$s.name]; if ($v -and $v.status -eq 'waiting' -and $v.waitPid -eq $PID) { $v.status = 'down' } } }   # a claim never outlives its start
  if ($dbStarted) { Add-SeedBaseline $e $s.name }   # after the start lock: other starts never wait on the check
}
# the env's DB up with no baseline mark: a green seed -Check marks one (SQL checks only: a cmd check may need the app)
function Add-SeedBaseline([string]$e, [string]$by) {
  if (-not (MarksOn $e) -or @((Read-State $e).marks | Where-Object { $_ -and $_.kind -eq 'baseline' }).Count) { return }
  try {
    $f = SeedFile $e; if (-not (Test-Path -LiteralPath $f)) { return }
    if (@((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).items | Where-Object { $_ -and -not $_.check.sql }).Count) { return "[$e] no baseline mark: its seed has non-SQL checks (envy.ps1 seed -Env $e once the env is up)" }
    $script:SeedBad = $false; $null = Invoke-Seed $e -Check
    if ($script:SeedBad) { "[$e] no baseline mark: the seed check is not green (envy.ps1 seed -Env $e)" } else { "[$e] mark $(New-Mark $e (New-KitName baseline $e) 'baseline') (seed check green at the $by start)" }
  } catch { "[$e] no baseline mark: $("$_".Split("`n")[0])" }
}

# the loop's db chores -> lines to say: temp watchdog and buffer pool once a minute (TODO-PARAM), mark expiry once a day; all rest
# while the env's own DB service is down (a lane's copy stopped idle or under memory pressure: no client errors, it starts on a lease)
function Invoke-DbChores([string]$e, $st, [hashtable]$at) {
  if (DbSvcDown $e) { return }
  if (((Get-Date) - $at.temp).TotalSeconds -ge 60 -and (Get-Command Invoke-DbTempWatch -ErrorAction SilentlyContinue) -and ((Test-DbTemp $e) -or ((Get-Command Test-DbTempUse -ErrorAction SilentlyContinue) -and (Test-DbTempUse $e)))) {
    $at.temp = Get-Date   # the top temp user above db.tempMaxGB is killed; one gone before the KILL: said
    try { foreach ($k in @(Invoke-DbTempWatch $e)) { $k; Event $e 'db-kill' @{ by = 'watchdog'; what = $k } } } catch { "db temp watchdog: $("$_".Split("`n")[0])" }
  }
  if (((Get-Date) - $at.pool).TotalSeconds -ge 60 -and (Get-Command Invoke-DbPool -ErrorAction SilentlyContinue)) {   # adapters/db-presets.ps1, db.bufferPool
    $at.pool = Get-Date; try { foreach ($k in @(Invoke-DbPool $e)) { $k; Event $e 'db-pool' @{ what = $k } } } catch { "db pool: $("$_".Split("`n")[0])" }
  }
  if ((MarksOn $e) -and ((Get-Date) - $at.marks).TotalSeconds -ge 60 -and (-not $st.binlog -or ((Get-Date) - [datetime]$st.binlog.checkedAt).TotalHours -ge 24)) { $at.marks = Get-Date; try { Update-Marks $e } catch { "marks: $("$_".Split("`n")[0])" } }
}
# the loop's inputs: kit.local.json, envy.ps1, lib.ps1 and the dot-sourced adapters; a changed stamp = a fresh loop between trains
function Get-LoopStamp {
  $fs = @($__cfgFile, (Join-Path $PSScriptRoot 'envy.ps1'), (Join-Path (Split-Path $PSScriptRoot) 'crafty/lib.ps1')) + @($script:KitAdapterFiles) + @(Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object FullName)
  @($fs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { "$(Split-Path $_ -Leaf)=$((Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks)" }) -join ','
}
# ---- daemon: this script only; -Env = loop, -Train = train worker, -Start = start worker; logs <logs>/<env>-loop.log, -train.log; events: kitlog stream env
function Invoke-Daemon {
param([Parameter(Mandatory)][Alias('Env')][string]$EnvName, [string]$Train, [string]$Start, [string]$Aot, [int]$Release, [string]$Artifact)
$e = $EnvName
$ErrorActionPreference = 'Stop'

# ==== train worker
function Phase([string]$p, [string[]]$blockServices = @(), [string[]]$blockRepos = @()) {
  Update-State $e { param($x) if ($x.train) { if ($x.train.phase -ne $p) { $x.train.phaseAt = (Now) }; $x.train.phase = $p; $x.train.blockServices = @($blockServices); $x.train.blockRepos = @($blockRepos); $x.train.waitingFor = @() } }
  $script:Phases += @{ phase = $p; at = (Get-Date -Format 's') }   # the release event's phases: where a train's minutes went
  "$(Get-Date -Format 'HH:mm:ss') [$e] train $Train : $p"
}
$script:Phases = @()
function Key($l) { "$($l.branch)@$($l.sha)" }

function Run-Train {
  $st = Read-State $e
  if (-not $st.train -or $st.train.id -ne $Train) { "[$e] train $Train is not the env's current train: nothing to do"; return }
  $reqs = @($st.requests | Where-Object { $_.id -in @($st.train.requests) })
  if ($reqs.Count -eq 1 -and $reqs[0].kind -eq 'restore') { Run-Restore $st $reqs[0]; return }
  $own = @($reqs.agent | Where-Object { $_ } | Select-Object -Unique)
  $envRepos = EnvRepos $e
  $results = @{}; foreach ($r in $reqs) { $results[$r.id] = @{ outcome = 'live'; message = '' } }
  $notes = [Collections.Generic.List[string]]::new(); $migNote = @{}; $dropWhy = @{}   # "<repo>|<branch>" -> why Sync-Repo dropped it

  $cur = @{}; $want = @{}; foreach ($rn in $envRepos.Keys) { $cur[$rn] = @(Layers $st $rn); $want[$rn] = @($cur[$rn]) }
  $affected = [Collections.Generic.List[string]]::new(); $byBranch = @{}
  foreach ($r in $reqs) {
    switch ($r.kind) {
      'deploy' { foreach ($rn in @($r.shas.Keys)) {
          $l = @{ branch = $r.branch; agent = $r.agent; sha = $r.shas[$rn]; at = $r.at; migrations = [bool]$r.migrations[$rn]; request = $r.id }
          if ($l.migrations) { $migNote[$r.id] = "$rn MIGRATIONS: they change the shared DB$(if (MarksOn $e) { ' (the release mark keeps what their DDL destroys: restore -Release undoes them)' })" }
          $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }) + @($l); if (-not $affected.Contains($rn)) { $affected.Add($rn) }; $byBranch["$rn|$($r.branch)"] = $r.id } }
      'drop' { foreach ($rn in $envRepos.Keys) { if (@($want[$rn].branch) -contains $r.branch) { $want[$rn] = @($want[$rn] | Where-Object { $_.branch -ne $r.branch }); if (-not $affected.Contains($rn)) { $affected.Add($rn) } } } }
      'refresh' { foreach ($rn in $envRepos.Keys) { if (-not $affected.Contains($rn)) { $affected.Add($rn) } } }
    }
  }
  $newN = [int]$st.release.n + 1; $tag = "r$newN-$Train"
  $repoOut = @{}; $artifacts = @{}; $newLayers = @{}; $noSwitch = @(); $skippedRepos = @()   # services whose inputs did not change: they keep running
  $ok = [Collections.Generic.List[string]]::new()
  if (-not $affected.Count) { Record-Train; return }

  $liveSvcs = @(EnvServices $e | Where-Object { $_.repo -and -not $_.artifact -and (RepoOf $e $_) -in $affected } | ForEach-Object name)
  $adopted = @(EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -in $affected -and $st.services[$_.name].status -eq 'up' -and -not $st.services[$_.name].artifact } | ForEach-Object name)
  $codeSvcs = @(@($liveSvcs) + $adopted | Select-Object -Unique)
  $codeBlock = @(@($codeSvcs) + @(Dependents $e $codeSvcs) | Select-Object -Unique)
  Phase 'waiting for leases (code)' $codeBlock @($affected)
  Wait-Leases $e $codeBlock @($affected) $own
  foreach ($n in $adopted) { "[$e] $n runs from its build output (started before run-from-copy): stopping it for the build"; Stop-Svc $e (Svc $e $n) 'rebuilt: restarts from a staged copy' }
  Phase 'merging and building' $codeBlock @($affected)

  foreach ($rn in $affected) {
    $r = $envRepos[$rn]
    $prevKeys = @($cur[$rn] | ForEach-Object { Key $_ })
    $isNew = { param($l) (Key $l) -notin $prevKeys }
    # warm lane (owner 2026-11-25): its layers unchanged, no refresh -> it stays on its live target commit, so a target move alone
    # (another MR merged) rebuilds nothing; refresh or a changed layer of this repo move it
    $pinBase = Get-TrainPinBase $st $rn @($want[$rn] | ForEach-Object { Key $_ }) $prevKeys @($reqs.kind)
    $res = if ($pinBase) { Sync-Repo $e $r @($want[$rn]) -Base $pinBase } else { Sync-Repo $e $r @($want[$rn]) }
    foreach ($d in $res.dropped) {
      $rid = $byBranch["$rn|$($d.layer.branch)"]
      if (-not $dropWhy.ContainsKey("$rn|$($d.layer.branch)")) { $dropWhy["$rn|$($d.layer.branch)"] = $d.why }
      if ($rid -and (& $isNew $d.layer)) { $results[$rid] = @{ outcome = 'refused'; message = "$rn : $($d.why)" } }
      else { $notes.Add("dropped layer $($d.layer.branch) ($($d.layer.agent)) from $rn : $($d.why)$(if ($d.layer.migrations) { " - the DB keeps its migrations$(if ((MarksOn $e) -and $d.layer.since) { " (restore -Release $($d.layer.since) undoes them)" })" })") }
    }
    $kept = @($res.kept); $targetSha = $res.targetSha
    $live = $st.release.repos[$rn]
    $missing = @(EnvServices $e | Where-Object { $_.artifact -and (RepoOf $e $_) -eq $rn -and -not (Test-ReleaseArtifact $_ $st.services[$_.name].artifact) })
    if ([int]$st.release.n -gt 0 -and $live -and $live.targetSha -eq $targetSha -and -not $missing.Count -and (@($kept | ForEach-Object { Key $_ }) -join '|') -eq ($prevKeys -join '|')) {
      "[$e] $rn unchanged (same target commit and layers$(if ($pinBase) { "; kept on $("$pinBase".Substring(0, [math]::Min(9, "$pinBase".Length))), not the moved $($r.target): refresh moves it" })): no build"
      foreach ($l in $kept) { if ($l.request -and $results[$l.request].outcome -eq 'live') { $results[$l.request].message = 'already live' } }
      continue
    }
    $repoSvcs = @(EnvServices $e | Where-Object { (Managed $_) -and (RepoOf $e $_) -eq $rn }); $same = @(if ([int]$st.release.n -gt 0 -and -not $missing.Count) { Get-SameInputs $e $rn $st })
    if ($repoSvcs.Count -and $same.Count -eq $repoSvcs.Count -and -not @($kept | Where-Object { (& $isNew $_) -and $_.migrations }).Count) {   # the layers / target moved outside its inputs (no new migrations): the running release is this code
      "[$e] $rn : inputs of $($same -join ', ') unchanged (services[].inputs): no build, no restart"; Event $e 'build-skip' @{ repo = $rn; services = $same }
      foreach ($l in $kept) { if ($l.request -and $results[$l.request].outcome -eq 'live') { $results[$l.request].message = "inputs of $($same -join ', ') unchanged: no restart" } }
      $newLayers[$rn] = @($kept | Where-Object { & $isNew $_ }); $repoOut[$rn] = @{ target = $r.target; targetSha = $targetSha; layers = @($kept) }; $ok.Add($rn); $noSwitch += $same; $skippedRepos += $rn
      continue
    }
    $err = Build-Repo $e $rn
    if ($script:Killed -notmatch '^$|PAUSE') { $err = Build-Repo $e $rn }
    try { if ($script:Killed) { throw $err }
    if ($err) {
      $base = @($kept | Where-Object { -not (& $isNew $_) }); $cands = @($kept | Where-Object { & $isNew $_ })
      $state = @{ err = $err }
      $try = { param($set) $null = Sync-Repo $e $r @($set) -NoFetch; $state.err = Build-Repo $e $rn; if ($script:Killed) { throw $state.err }; -not $state.err }
      Phase "build failed in $rn : finding the culprit among $($cands.Count) new layer(s)" $codeBlock @($affected)
      if (-not $cands.Count -or -not (& $try $base)) {
        foreach ($l in $cands) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : the target + the layers already live do not build either: $($state.err)" } } }
        $notes.Add("$rn does not build on its target + current layers: kept the running release ($($state.err))")
        foreach ($q in @($reqs | Where-Object { $_.kind -eq 'drop' -and @($cur[$rn].branch) -contains $_.branch })) { $results[$q.id] = @{ outcome = 'failed'; message = "$rn does not build without it either: the layer stays ($($state.err))" } }
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
      $err = Build-Repo $e $rn; if ($script:Killed) { throw $err }
      if ($err) { $notes.Add("$rn still does not build after removing culprits: kept the running release ($err)"); foreach ($l in $kept | Where-Object { & $isNew $_ }) { if ($l.request) { $results[$l.request] = @{ outcome = 'rejected'; message = "$rn : $err" } } }; $null = Sync-Repo $e $r @($cur[$rn]) -NoFetch; continue }
    }
    } catch { if ("$_" -notlike 'killed:*') { throw }; Set-KilledBuild "$_" $kept $isNew $reqs $cur $rn $results; $null = Sync-Repo $e $r @($cur[$rn]) -NoFetch; continue }
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
    if ($rn -in $skippedRepos) { $repoOut[$rn].layers = $keep; $newLayers[$rn] = @($newLayers[$rn] | Where-Object { $_.request -notin $failed }); continue }   # skipped (inputs unchanged): fewer layers, still no build
    $err = Build-Repo $e $rn
    if ($err) { $null = $ok.Remove($rn); $repoOut.Remove($rn); foreach ($s in @($artifacts.Keys | Where-Object { (RepoOf $e (Svc $e $_)) -eq $rn })) { $artifacts.Remove($s) }; $notes.Add("$rn : rebuild without the failed requests failed, kept the running release ($err)"); $null = Sync-Repo $e $envRepos[$rn] @($cur[$rn]) -NoFetch; continue }
    $repoOut[$rn].layers = $keep; $newLayers[$rn] = @($newLayers[$rn] | Where-Object { $_.request -notin $failed })
    foreach ($kv in (Stage-Artifacts $e $rn $tag).GetEnumerator()) { $artifacts[$kv.Key] = $kv.Value; $noSwitch = @($noSwitch | Where-Object { $_ -ne $kv.Key }) }
  }

  Restart-TreeStopped $e -Keep @($ok | Where-Object { $_ -notin $skippedRepos })   # the sync stopped them, no switch-over starts them: back before smoke checks
  $st2 = Read-State $e
  # up services switch over; a down one a lease needs starts on the new release here too (verified now, rolled back on failure,
  # never left live unchecked for the loop's next start); a down one nobody needs starts on it at its next lease
  $wanted = @(@($st2.leases.Values) + @($st2.holds.Values) | ForEach-Object { Closure $e @($_.services | Where-Object { $_ }) } | Select-Object -Unique)
  $switch = @(EnvServices $e | Where-Object { (RepoOf $e $_) -in $ok -and $_.name -notin $noSwitch -and (Managed $_) -and -not ($_.hot -and -not $_.artifact) -and ($st2.services[$_.name].status -eq 'up' -or $script:TreeStopped.Contains($_.name) -or ($_.artifact -and $_.name -in $wanted)) })
  $verifyDown = @($switch | Where-Object { $st2.services[$_.name].status -ne 'up' } | ForEach-Object name)
  $switchNames = @($switch | Where-Object { $_.name -notin $verifyDown } | ForEach-Object name)   # leases wait only for what runs
  $block = @(@($switchNames) + @(Dependents $e $switchNames) | Select-Object -Unique)
  if ($switch.Count) { Phase 'waiting for leases (switch-over)' $block @($affected); Wait-Leases $e $block @() $own }
  $undo = { param($l) if ((MarksOn $e) -and $l.since) { " (envy.ps1 restore -Env $e -Release $($l.since) undoes it)" } else { '' } }
  foreach ($rn in @($ok)) {
    $keepKeys = @($repoOut[$rn].layers | ForEach-Object { Key $_ })
    foreach ($l in @($cur[$rn] | Where-Object { $_.migrations -and (Key $_) -notin $keepKeys })) { $notes.Add("migration layer $($l.branch) left $rn : the DB keeps its changes$(& $undo $l)") }
  }
  $relMark = $null
  # repos whose release brings migrations: new layers with migrations, or a target that moved past migration files
  $migRepos = @($ok | Where-Object { $rn = $_; @($newLayers[$rn] | Where-Object { $_.migrations }).Count -or ($st.release.repos[$rn].targetSha -and $st.release.repos[$rn].targetSha -ne $repoOut[$rn].targetSha -and (HasMigrations $envRepos[$rn].cfg.checkout $envRepos[$rn].target $st.release.repos[$rn].targetSha)) })
  if ($migRepos.Count -and -not (MarksOn $e)) { $notes.Add("migrations in $($migRepos -join ', ') change the shared DB: no marks (db.engine mysql / mariadb), no way back") }

  $prevSvc = @{}; foreach ($s in $switch) { $prevSvc[$s.name] = $st2.services[$s.name] }
  $flag = @{ restored = $false; reverted = @() }; $keptRepos = @()
  $rollback = { param([string[]]$repos, $why)
    $set = [Collections.Generic.List[string]]::new(); foreach ($x in $repos) { if ($x -in $ok -and -not $set.Contains($x)) { $set.Add($x) } }
    if ($relMark -and -not $flag.restored -and @($set | Where-Object { $_ -in $migRepos }).Count) { foreach ($x in $migRepos) { if ($x -in $ok -and -not $set.Contains($x)) { $set.Add($x) } } }
    foreach ($rn in $set) {
      "[$e] rolling back $rn : $why"
      foreach ($l in @($newLayers[$rn])) { if ($l.request) { $results[$l.request] = @{ outcome = 'rolled back'; message = $why } } }
      $repoOut.Remove($rn); $null = $ok.Remove($rn)
      foreach ($s in @($artifacts.Keys | Where-Object { (RepoOf $e (Svc $e $_)) -eq $rn })) { $artifacts.Remove($s) }
    }
    $svcs = @($switch | Where-Object { (RepoOf $e $_) -in $set })
    if ($relMark -and -not $flag.restored -and @($set | Where-Object { $_ -in $migRepos }).Count) {
      foreach ($s in $svcs) { Stop-Svc $e $s 'rollback: DB restore' }
      $rm = Find-Mark (Read-State $e) $relMark 0; $sch = try { @(Get-MarkScopes $e $rm) } catch { @(Get-DataScopes $e) }
      $err = try { $rp = Get-RestorePlan $e $rm $sch "rb-$tag"; if (@($rp.refused).Count) { "refused: $(@($rp.refused | Select-Object -First 3) -join '; ')" } else { Invoke-RestoreDb $e $rm $sch $rp } } catch { "$_".Split("`n")[0] }
      $notes.Add($(if ($err) { "db restore to mark $relMark FAILED, the DB keeps the migrations' changes: $err" } else { "db restored to mark $relMark (structure from its slices, rows by flashback)" })); $flag.restored = $true; $flag.fallback = -not $err -and @($script:RestoreFallback).Count
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
        try {
          if ($s.artifact) { Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{} }; $z.services[$s.name].artifact = $art; $z.services[$s.name].release = [int]$p.release } }   # a failed restart never leaves the rolled-back copy for the next lease
          Start-Svc $e $s ([int]$p.release) $art
        } catch { $notes.Add("rollback of $($s.name) failed too: $("$_".Split("`n")[0])") }
      }
    }
  }
  if ($ok.Count -and ((MarksOn $e) -or $migRepos.Count)) { Phase 'db up for the release marks and checks' $block @($affected); try { Ensure-DbUp $e $newN } catch { $notes.Add("db service did not start for the release's DB steps: $("$_".Split("`n")[0])") } }
  if ($ok.Count -and (MarksOn $e)) {   # the DB before this release's code first runs: restore -Release / a rollback come back here
    $code = @{}; foreach ($k in $st2.release.repos.Keys) { $code[$k] = $st2.release.repos[$k] }; foreach ($k in $repoOut.Keys) { $code[$k] = $repoOut[$k] }
    $relMark = try { New-Mark $e "release-$newN" 'release' $code $newN } catch { $notes.Add("mark release-$newN failed (no restore point): $("$_".Split("`n")[0])"); $null }
    if ($relMark -and $migRepos.Count -and (Test-MigToolRollback $e)) {   # opt-in tool rollback: its tag (the registry's set and scope first)
      $te = Invoke-MigTagRollback $e 'tag' "release-$newN"; if ($te) { $notes.Add("$(Get-MigTool $e) tag release-$newN failed (restore -UseToolRollback cannot use it): $te") }
    }
    if ($relMark -and $migRepos.Count) {
      Phase "slices before the migrations of $($migRepos -join ', ')" $block @($affected)
      try {
        $by = @{}; foreach ($rn in $migRepos) { $by[$rn] = Get-MigTouched $e $rn "$(if ($st.release.repos[$rn].targetSha) { $st.release.repos[$rn].targetSha } else { "origin/$($envRepos[$rn].target)" })" (git -C $envRepos[$rn].wt rev-parse HEAD) }
        $sl = Save-Slices $e $relMark $by
        $notes.Add("mark ${relMark}: $(@($sl.tables).Count) touched table(s) sliced ($([math]::Round($sl.bytes / 1KB)) KB; via $(@($by.Values | ForEach-Object via | Select-Object -Unique) -join ', '))$(if (@($sl.unknown).Count) { "; tables not found in $($sl.unknown -join ', '): a restore past their DDL is refused (seed restores the data)" })")
      } catch { $notes.Add("slices for $relMark failed: a restore past this release's DDL is refused ($("$_".Split("`n")[0]))") }
    }
  }
  $migLive = @($ok | Where-Object { $_ -in $migRepos })
  if ($migLive.Count) {   # a layer's changeSet included above the target's newest one: a "latest changeSet" marker would skip it
    Phase "migration checks before the switch-over ($($migLive -join ', '))" $block @($affected)
    $mn = @($newLayers.Keys | Where-Object { $_ -in $migLive }); $sub = @{}; foreach ($rn in $mn) { $sub[$rn] = $newLayers[$rn] }
    foreach ($n in @(try { Reset-EditedChecksums $e $envRepos $cur $sub } catch { "checksum reset failed: $("$_".Split("`n")[0])" }) + @(Invoke-RestoreAfter $e "release-$newN" -Migrations)) { $notes.Add($n); Add-Content (LogFile $e 'migrations') "== $(Now) $n" }
  }
  Phase 'switching over' $block @($affected)
  foreach ($s in $switch) {
    $rn = RepoOf $e $s
    if ($rn -notin $ok) { continue }
    if ($s.name -notin $verifyDown -and (Read-State $e).services[$s.name].status -ne 'up') { "[$e] $($s.name) stopped idle while the train waited: it starts on release $newN at its next lease"; continue }
    try { Start-Svc $e $s $newN $artifacts[$s.name] }
    catch {
      $sw = "$_".Split("`n")[0]
      if ($sw -notmatch ': dependency down: ') { & $rollback @($rn) "$($s.name) did not come up with it: $sw"; continue }
      # not the code: the release stays, the service waits stopped; the loop starts it once its dependency is up
      Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{} }; $z.services[$s.name].release = $newN; if ($artifacts[$s.name]) { $z.services[$s.name].artifact = $artifacts[$s.name] } }
      Stop-Svc $e $s "waits for its dependency: $sw"
      $notes.Add("$($s.name) kept release $newN but is not up ($sw): it starts when its dependency is up (no rollback)"); $keptRepos += $rn
    }
  }
  if ($switch.Count -and $ok.Count -and (Get-EnvCfg $e).smoke) {
    Phase 'smoke checks' $block @($affected)
    $sf = Test-Smoke $e
    if ($sf) { $rb = @($ok | Where-Object { $_ -notin $keptRepos }); if ($rb.Count) { & $rollback $rb "smoke check failed: $sf" }; if ($keptRepos.Count) { $notes.Add("smoke check failed with $($keptRepos -join ', ') waiting for a dependency (kept): $sf") } }
  }
  if ($migRepos.Count -and (MarksOn $e) -and (Test-CascadeGuard $e)) {   # migrations may add / change cascading foreign keys or the child columns the guard copies
    try { $g = Install-DbGuard $e; if ($g.installed -or $g.removed) { $notes.Add("cascade guard after the migrations: $($g.installed) trigger(s) installed, $($g.removed) removed") } }
    catch { $notes.Add("cascade guard re-install failed (a restore past a cascading delete seeds the child tables): $("$_".Split("`n")[0])") }
  }
  if ($flag.fallback) { $fbn = Invoke-RestoreFallback $e; if ($fbn) { $notes.Add($fbn) } }
  Record-Train
}

# a restore train (its request alone): holders told to pause, the mark's code built, writers stopped, the DB restored, started
function Run-Restore($st, $req) {
  $script:DoneWord = 'restore'
  $results = @{}; $results[$req.id] = @{ outcome = 'live'; message = '' }
  $notes = [Collections.Generic.List[string]]::new(); $migNote = @{}; $repoOut = @{}; $artifacts = @{}
  $newN = [int]$st.release.n + 1; $tag = "r$newN-$Train"; $envRepos = EnvRepos $e
  $back = { foreach ($k in @($repoOut.Keys)) { $null = Sync-Repo $e $envRepos[$k] @(Layers $st $k) -NoFetch -Base "$($st.release.repos[$k].targetSha)" }; $repoOut.Clear(); $artifacts.Clear() }
  $refuse = { param($why) & $back; $results[$req.id] = @{ outcome = 'refused'; message = "nothing changed: $why" }; Record-Train }
  $m = try { Find-Mark $st $req.mark 0 } catch { & $refuse "$_"; return }
  $schemas = @($req.schemas | Where-Object { $_ }); if (-not $schemas.Count) { $schemas = try { @(Get-MarkScopes $e $m) } catch { & $refuse "$_".Split("`n")[0]; return }; foreach ($w in @($script:ScopeWarn)) { $notes.Add($w) } }
  Phase "restore to $($m.name): plan"
  try { Ensure-DbUp $e ([int]$st.release.n) } catch { & $refuse "the db service did not start: $("$_".Split("`n")[0])"; return }
  $plan = try { Get-RestorePlan $e $m $schemas $tag } catch { & $refuse "plan failed: $("$_".Split("`n")[0])"; return }
  if (@($plan.refused).Count) { & $refuse (@($plan.refused | Select-Object -First 3) -join '; '); return }
  $all = @(EnvServices $e | Where-Object { Managed $_ } | ForEach-Object name)
  $holders = @($st.leases.Keys | Where-Object { $_ -ne $req.agent -and $_ -ne "$($req.agent)/task" })
  if ($holders.Count) { Send-LeaseNotice $e $holders "restore of $e to mark $($m.name) starting: pause your checks; resume after 'restore done'"; $script:Preempted = $holders }
  Phase "restore to $($m.name): code" $all @($envRepos.Keys)
  foreach ($rn in @($envRepos.Keys)) {
    $mr = $m.repos[$rn]; $live = $st.release.repos[$rn]
    if (-not $mr -or ($live -and "$($live.targetSha)" -eq "$($mr.targetSha)" -and (@($live.layers | Where-Object { $_ } | ForEach-Object { Key $_ }) -join '|') -eq (@($mr.layers | Where-Object { $_ } | ForEach-Object { Key $_ }) -join '|'))) { continue }   # not deployed then, or the same code
    $res = Sync-Repo $e $envRepos[$rn] @($mr.layers | Where-Object { $_ }) -Base "$($mr.targetSha)"
    foreach ($d in $res.dropped) { $notes.Add("$rn : layer $($d.layer.branch) of the mark left out: $($d.why)") }
    $repoOut[$rn] = @{ target = $envRepos[$rn].target; targetSha = $res.targetSha; layers = @($res.kept) }
    $err = Build-Repo $e $rn
    if ($err) { & $refuse "the code of mark $($m.name) does not build in $rn : $err"; return }
    $artifacts += (Stage-Artifacts $e $rn $tag)
  }
  $stop = @(EnvServices $e | Where-Object { $_.repo -and (Managed $_) -and ((Healthy $e $_) -or $script:TreeStopped.Contains($_.name)) }); [array]::Reverse($stop)   # dependents first
  Phase "restore to $($m.name): stopping $(@($stop.name) -join ', ')" $all @($envRepos.Keys)
  foreach ($s in $stop) { Stop-Svc $e $s "restore to $($m.name)" }
  Phase "restore to $($m.name): $(@($plan.steps).Count + @($plan.drops).Count + @($plan.renames).Count) structure step(s), $($plan.statements) row change(s)" $all @($envRepos.Keys)
  $p2 = try { Get-RestorePlan $e $m $schemas $tag } catch { $null }   # writers stopped: the end position is final
  $err = if (-not $p2 -or @($p2.refused).Count) { "plan after stopping the writers: $(if ($p2) { @($p2.refused | Select-Object -First 3) -join '; ' } else { 'failed' }); the DB is unchanged by the kit" } else { $plan = $p2; try { Invoke-RestoreDb $e $m $schemas $plan -UseTool:([bool]$req.useTool) } catch { "restore crashed part way (the DB is half-restored): $("$_".Split("`n")[0])" } }
  if ($err -match 'the DB is unchanged') { & $back }   # the live code runs on the unchanged DB again
  Update-State $e { param($x) $x.halfRestored = if ($err -and $err -notmatch 'the DB is unchanged') { @{ mark = $m.name; at = (Now); why = $err } } else { $null } }   # status + supervise ACT until a restore passes
  [array]::Reverse($stop)
  foreach ($s in $stop) {
    $art = if ($artifacts[$s.name]) { $artifacts[$s.name] } else { (Read-State $e).services[$s.name].artifact }
    try { Start-Svc $e $s $(if ($repoOut[(RepoOf $e $s)]) { $newN } else { [int](Read-State $e).services[$s.name].release }) $art } catch { $notes.Add("$($s.name) did not come up after the restore: $("$_".Split("`n")[0])") }
  }
  $sf = if ($stop.Count -and (Get-EnvCfg $e).smoke) { Test-Smoke $e }
  if ($sf) { $notes.Add("smoke check failed after the restore: $sf") }
  $fbn = if (-not $err) { Invoke-RestoreFallback $e }; if ($fbn) { $notes.Add($fbn) }
  foreach ($n in @(Invoke-RestoreAfter $e $m.name)) { $notes.Add($n) }
  $results[$req.id] = if ($err) { @{ outcome = 'failed'; message = $err } } else { @{ outcome = 'live'; message = "DB and code at mark $($m.name) (release $($m.release)): $($plan.statements) row change(s) undone, $(@($plan.steps).Count) structure step(s), $(@($plan.objects).Count + @($plan.objectDrops).Count) object step(s)$(if ($fbn) { "; $fbn" })$(if (@($plan.warnings).Count) { "; WARN $(@($plan.warnings) -join '; ')" })$(if ($sf) { "; smoke FAILED: $sf" })" } }
  Record-Train
}

function Record-Train {
  $changed = @($repoOut.Keys)
  Restart-TreeStopped $e $changed $newN
  Update-State $e { param($x)
    if ($changed.Count) {
      foreach ($rn in $changed) {
        foreach ($l in @($repoOut[$rn].layers)) {
          $was = @($x.release.repos[$rn].layers | Where-Object { $_ -and (Key $_) -eq (Key $l) }) | Select-Object -First 1
          if ($was.promoted) { $l.promoted = $was.promoted }
          $l.since = if ($was -and $was.since) { $was.since } elseif ($was) { [int]$x.release.n } else { $newN }   # first release with this commit live
        }
        try { Write-LayerLog $e $rn @(Layers $x $rn) @($repoOut[$rn].layers) $reqs $dropWhy } catch {}   # never fails a release
        $x.release.repos[$rn] = $repoOut[$rn]
      }
      $x.release.n = $newN; $x.release.at = (Now); $x.release.train = $Train
      foreach ($sn in $artifacts.Keys) { if (-not $x.services[$sn]) { $x.services[$sn] = @{ status = 'down' } }; if ($x.services[$sn].status -ne 'up') { $x.services[$sn].artifact = $artifacts[$sn]; $x.services[$sn].release = $newN
        Clear-StartBackoff $x.services[$sn] "release $newN staged" } }
      $x.releases = @(@($x.releases) + @(@{ n = $newN; at = (Now); train = $Train; changed = $changed; notes = @($notes) }) | Select-Object -Last 20)
    }
    foreach ($id in @($migNote.Keys)) { if ($results[$id] -and $results[$id].outcome -eq 'live') { $results[$id].message = (@($results[$id].message, $migNote[$id]) | Where-Object { $_ }) -join '; ' } }
    foreach ($r in $x.requests) { if ($results.ContainsKey($r.id)) { $r.status = 'done'; $r.result = $results[$r.id]; $r.result.release = $(if ($results[$r.id].outcome -eq 'live') { $(if ($changed.Count) { $newN } else { $x.release.n }) }) } }
    $x.train = $null
  }
  if ($script:Preempted.Count) { Send-LeaseNotice $e $script:Preempted "$script:DoneWord done$(if ($changed.Count) { " (release $newN)" }): re-run your checks; your lease continues" }
  Event $e 'release' @{ n = $(if ($changed.Count) { $newN } else { $null }); train = $Train; changed = $changed; results = $results; notes = @($notes); phases = @($script:Phases) }
  $notes | ForEach-Object { "[$e] $_" }
  "$(Get-Date -Format 'HH:mm:ss') [$e] train $Train done: $(if ($changed.Count) { "release $newN ($($changed -join ', '))" } else { 'no new release' })"
}

$script:SayLog = LogFile $e 'loop'
function Say([string]$m) { $line = "$(Get-Date -Format 'HH:mm:ss') $m`n"; for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($script:SayLog, $line); return } catch { Start-Sleep -Milliseconds 50 } } }   # loop + start workers share it
if ($Train) {
  for ($i = 0; $i -lt 20 -and -not ((Read-State $e).train.id -eq $Train); $i++) { Start-Sleep -Milliseconds 250 }
  try { Run-Train *>&1 | Tee-Object -FilePath (LogFile $e 'train') -Append }
  catch {
    $why = "$_"; "[$e] train $Train crashed: $why $($_.ScriptStackTrace)" | Add-Content (LogFile $e 'train')
    try { Restart-TreeStopped $e *>&1 | Add-Content (LogFile $e 'train') } catch {}   # never left stopped by the sync
    if ($script:Preempted.Count) { Send-LeaseNotice $e $script:Preempted 'deploy ended without a release (train crashed): resume your checks; your lease continues' }
    Update-State $e { param($x) foreach ($r in $x.requests) { if ($r.status -eq 'in-train' -and $r.id -in @($x.train.requests)) { $r.status = 'done'; $r.result = @{ outcome = 'error'; message = "train crashed: $why" } } }; $x.train = $null }
  }
  exit
}
if ($Aot) {   # AOT training worker: one run for one artifact, gated, off the loop and the start lock
  try { Invoke-AotTrain $e (Svc $e $Aot) $Artifact } catch { Say "aot training of $Aot failed: $("$_".Split("`n")[0])" }
  exit
}
if ($Start) {   # start worker: one service start (RAM wait, lock, health) off the loop
  $s = Svc $e $Start
  try {
    if (Healthy $e $s) { Say "start of ${Start}: already up"; Update-State $e { param($z) if ($z.services[$Start] -and $z.services[$Start].status -ne 'up') { $z.services[$Start].status = 'up' } } }
    else {   # a restart counts only when one runs (backoff: 3 / 30 min), never an "already up"
      Update-State $e { param($z) if (-not $z.services[$Start]) { $z.services[$Start] = @{ status = 'down' } }; $z.services[$Start].restarts = @(@($z.services[$Start].restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 }) + @(Now)) }
      Start-Svc $e $s $Release $Artifact -Latest *>&1 | ForEach-Object { Say "$_" }
    }
  }
  catch {
    $why = "$_".Split("`n")[0]; Say "start of $Start failed: $why"
    Update-State $e { param($z) if (-not $z.services[$Start]) { $z.services[$Start] = @{} }; $z.services[$Start].status = 'failed'; $z.services[$Start].why = $why }
  }
  exit
}

# ==== env loop
$mx = [Threading.Mutex]::new($false, $(if ($KitIsWindows) { "Global\kit-localenv-loop-$e" } else { "kit-localenv-loop-$e" }))
$owned = $false
try { $owned = $mx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit }
Say "loop started (pid $PID)"
$cfgAt = Get-LoopStamp; $reload = $false   # kit.local.json and the scripts as read at start
$quietSince = Get-Date; $tick = 0; $clientNeed = @{}; $starters = @{}; $misses = @{}; $logPos = @{}; $fails = 0; $lastErr = $null; $beatAt = [datetime]::MinValue; $ramAt = [datetime]::MinValue; $choreAt = @{ temp = [datetime]::MinValue; pool = [datetime]::MinValue; marks = [datetime]::MinValue }
try {
  while ($true) {
    $tick++
    try {   # a failing tick is logged and retried with backoff; the controller keeps running
      $beat = ((Get-Date) - $beatAt).TotalSeconds -ge 60
      Update-State $e { param($x) if ($x.train -and $x.loop.beat -and ((Get-Date) - [datetime]$x.loop.beat).TotalMinutes -ge 3) { $x.train.phaseAt = (Now) }   # asleep or a new loop: the stall clock restarts
        Prune $x; if ($beat -or -not $x.loop -or $x.loop.pid -ne $PID) { $x.loop = (Mine $PID) + @{ beat = (Now) } } }   # a write only on change or once a minute
      if ($beat) { $beatAt = Get-Date }
      if (((Get-Date) - $ramAt).TotalSeconds -ge 60) { Add-RamSample (Get-GateAvailGB (Get-SysMem)); $ramAt = Get-Date }
      $st = Read-State $e
      # ---- config or env scripts edited: between trains a fresh loop takes over (all else stays)
      $cfgNow = Get-LoopStamp
      if (-not $st.train -and $cfgNow -ne $cfgAt -and $(try { $null = -not $__cfgFile -or (Get-Content -LiteralPath $__cfgFile -Raw | ConvertFrom-Json); $true } catch { $false })) { Say "kit.local.json or the env scripts changed: the loop restarts with them"; Event $e 'loop-reload' @{ pid = $PID }; $reload = $true; break }   # a half-written file waits

      # ---- trains: one worker takes all queued requests
      $queued = @($st.requests | Where-Object { $_.status -eq 'queued' })
      $rq = @($queued | Where-Object kind -eq 'restore')[0]; if ($rq) { $queued = @($rq) } else { $queued = @($queued | Where-Object kind -ne 'restore') }   # a restore runs alone
      if (-not $st.train -and $queued.Count) {
        $tid = [guid]::NewGuid().ToString('n').Substring(0, 6); $ids = @($queued.id)
        Update-State $e { param($x) $x.train = @{ id = $tid; pid = $null; phase = 'starting'; requests = $ids; at = (Now); blockServices = @(); blockRepos = @() }; foreach ($r in $x.requests) { if ($r.id -in $ids) { $r.status = 'in-train' } } }
        $wp = Start-Pwsh @('_daemon', '-Env', $e, '-Train', $tid) $PSScriptRoot "_daemon -Env $e -Train $tid" (LogFile $e "train-$tid")
        Update-State $e { param($x) if ($x.train -and $x.train.id -eq $tid) { $m = Mine $wp; $x.train.pid = $m.pid; $x.train.pstart = $m.pstart } }
        Say "train $tid started for $($ids.Count) request(s): $(($queued | ForEach-Object { "$($_.kind) $($_.branch)" }) -join '; ')"
        foreach ($q in @($queued | Where-Object { $_.kind -eq 'deploy' -and $_.at })) { Add-KitParamObs 'localEnv.lanes.openAfterMinutes' ((Get-Date) - [datetime]$q.at).TotalMinutes }   # queue waits teach Select-Lane's cold-lane threshold
        $st = Read-State $e
      }

      # ---- demand; every 5th tick: client traffic, lease use, peak RAM, out-of-memory lines
      $snap = Get-KitProcSnap
      $envPids = @(foreach ($s in EnvServices $e) { SvcPids $e $s $st $snap })
      if ($tick % 5 -eq 1) {
        $clientNeed = @{}; $used = @{}
        foreach ($s in EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -eq 'up' }) {
          $x = $st.services[$s.name]
          if ($s.port -and @(ClientPids ([int]$s.port) $envPids -Any).Count) {
            $used[$s.name] = $true
            if (-not ($st.suppress -and $s.name -in @($st.suppress.services) -and [datetime]$st.suppress.until -gt (Get-Date)) -and @(ClientPids ([int]$s.port) $envPids).Count) { $clientNeed[$s.name] = $true }
          }
          $gb = TreeGB (SvcPids $e $s $st $snap) $snap
          if ($gb -gt [double]$x.peakGB + 0.05) { Update-State $e { param($z) if ($z.services[$s.name]) { $z.services[$s.name].peakGB = $gb } } }
          $oom = Find-NewLogLine (LogFile $e $s.name) $script:OomPattern $logPos
          if ($oom) {
            Say "$($s.name) ran out of memory ($oom): restarting it"; Event $e 'oom' @{ service = $s.name; line = $oom }
            Stop-Svc $e $s "out of memory: $oom"; Update-State $e { param($z) $z.services[$s.name].status = 'failed' }
          }
        }
        $usedNames = @($used.Keys)
        if ($usedNames.Count) { Update-State $e { param($z) foreach ($l in $z.leases.Values) { if (-not $l.owner -and @(Closure $e @($l.services) | Where-Object { $_ -in $usedNames }).Count -and -not ($l.lastUse -and ((Get-Date) - [datetime]$l.lastUse).TotalSeconds -lt 60)) { $l.lastUse = (Now) } } } }
        $st = Read-State $e
      }
      $need = @{}
      $addNeed = { param($names, $why) foreach ($n in (Closure $e @($names))) { if (-not $need[$n]) { $need[$n] = @() }; $need[$n] += $why } }
      foreach ($a in $st.leases.Keys) { & $addNeed @($st.leases[$a].services) "lease:$a" }
      foreach ($a in $st.holds.Keys) { & $addNeed @($st.holds[$a].services) "hold:$a" }
      foreach ($n in $clientNeed.Keys) { & $addNeed @($n) 'clients' }
      $block = @($st.train.blockServices)
      $needNames = @($need.Keys)
      Update-State $e { param($z) foreach ($n in @($z.services.Keys)) { if ($z.services[$n].need -and $n -notin $needNames) { $z.services[$n].need = @() } } }   # reasons that ended

      # ---- stop first: every service idle past its grace, or idle under pressure, in this tick (dependents first, biggest first);
      #      a train still waiting for leases changes nothing yet: its services stop when idle too
      $pressure = Pressure
      $idleBlock = Get-IdleBlock $st $e
      for ($round = 0; $round -lt 20; $round++) {
        $idle = @(Get-IdleServices $e $st $need $idleBlock $pressure)
        if (-not $idle.Count) { break }
        foreach ($s in @(if ($pressure) { $idle[0] } else { $idle })) { $why = IdleWhy (GraceMin $e $s) $pressure; Say "stopping $($s.name): $why"; Stop-Svc $e $s $why }
        $st = Read-State $e
        if ($pressure) { break }   # under pressure the biggest idle one per tick, then pressure is measured again
      }

      # ---- start needed (a start worker each), restart crashes with backoff
      $needsBuild = $false
      foreach ($s in EnvServices $e | Where-Object { Managed $_ }) {
        $x = $st.services[$s.name]
        if (-not $need[$s.name]) { continue }
        $nw = @($need[$s.name])
        if (-not $x -or -not $x.lastNeed -or ((Get-Date) - [datetime]$x.lastNeed).TotalSeconds -ge 60 -or (@($x.need) -join ',') -ne ($nw -join ',')) {
          Update-State $e { param($z) if (-not $z.services[$s.name]) { $z.services[$s.name] = @{ status = 'down' } }; $z.services[$s.name].lastNeed = (Now); $z.services[$s.name].need = $nw }
        }
        if ($s.name -in $block) { continue }
        if (Owned $starters[$s.name]) { continue }   # its start worker runs
        if (Healthy $e $s) { $misses[$s.name] = 0; if ($x.status -ne 'up') { Update-State $e { param($z) $z.services[$s.name].status = 'up' } }; continue }
        if ($x.status -eq 'up' -and (Owned $x) -and ++$misses[$s.name] -lt 3) { continue }   # a busy service: 3 health misses in a row first
        if (-not (Leased $need[$s.name])) { continue }
        if ($x.status -eq 'starting' -and (Owned $x) -and $x.startedAt -and ((Get-Date) - [datetime]$x.startedAt).TotalMinutes -lt (StartMin $s)) { continue }
        if ($x.status -eq 'waiting' -and (Test-KitPid $x.waitPid $x.waitStart)) { continue }   # a worker of an earlier controller waits for RAM
        if (@($s.dependsOn | Where-Object { $_ -and -not (Healthy $e (Svc $e $_)) }).Count) { continue }   # dependencies first
        $recent = @($x.restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 })
        if ($x.status -eq 'failed' -and $recent.Count -ge 3) { continue }   # backoff: 3 tries / 30 min
        if ($x.status -eq 'failed' -and "$($x.why)" -match ': config: ' -and "$($x.why)" -eq "$(Get-SvcConfigError $e $s)") { continue }   # a config error: once, until the config changes
        if ($s.repo -and ([int]$st.release.n -eq 0 -or ($s.artifact -and -not ($x.artifact -and (Test-Path $x.artifact))))) { $needsBuild = $true; continue }
        $starters[$s.name] = Mine (Start-Pwsh @('_daemon', '-Env', $e, '-Start', $s.name, '-Release', "$([int]$st.release.n)", '-Artifact', "$($x.artifact)") $PSScriptRoot "_daemon -Env $e -Start $($s.name)" (LogFile $e "start-$($s.name)"))
        Say "start of $($s.name): worker pid $($starters[$s.name].pid)"
        $st = Read-State $e
      }
      if ($needsBuild -and -not $st.train -and -not @($st.requests | Where-Object { $_.status -notin 'done', 'deferred' }).Count) {
        $rid = [guid]::NewGuid().ToString('n').Substring(0, 8)
        Update-State $e { param($z) $z.requests = @($z.requests) + @(@{ id = $rid; kind = 'refresh'; agent = 'controller'; at = (Now); status = 'queued' }) }
        Say 'queued a refresh: a needed service has no build yet'
      }

      foreach ($k in @(Invoke-DbChores $e $st $choreAt)) { Say $k }

      # ---- exit when idle
      $st = Read-State $e
      $busy = $st.train -or @($st.requests | Where-Object { $_.status -notin 'done', 'deferred' }).Count -or $st.leases.Count -or $st.holds.Count -or
        @($starters.Values | Where-Object { Owned $_ }).Count -or @(EnvServices $e | Where-Object { (Managed $_) -and $st.services[$_.name].status -in 'up', 'starting' }).Count
      if ($busy) { $quietSince = Get-Date } elseif (((Get-Date) - $quietSince).TotalMinutes -ge $LoopExitM) { if ((Get-Command Invoke-DbPool -ErrorAction SilentlyContinue) -and -not (DbSvcDown $e)) { try { foreach ($k in @(Invoke-DbPool $e -Now)) { Say $k } } catch { } }; Say 'idle: loop exits'; break }
    } catch {
      $fails++; $m = "$_".Split("`n")[0]
      if ($m -ne $lastErr) { Say "tick $tick failed ($fails in a row, retrying): $_ $($_.ScriptStackTrace)"; $lastErr = $m }
      if ($fails -ge 30) { Say 'loop gives up after 30 failed ticks in a row (the next request starts it again)'; break }
      Start-Sleep ([math]::Min(60.0, 3 * [math]::Pow(2, [math]::Min($fails, 5)))); continue
    }
    $fails = 0; $lastErr = $null
    Wait-KitFileChange (StateFile $e) $(if ($busy -or $pressure) { 3 } else { 15 })   # idle: 15 s, a request wakes it
  }
} catch { Say "loop crashed: $_ $($_.ScriptStackTrace)" }
finally {
  Update-State $e { param($x) if ($x.loop -and $x.loop.pid -eq $PID) { $x.loop = $null } }
  try { $mx.ReleaseMutex() } catch { }
  if ($reload) { $null = Start-Pwsh @('_daemon', '-Env', $e) $PSScriptRoot "_daemon -Env $e" (LogFile $e 'loop') }   # after the mutex: the new loop owns it
}
}

# ---- cleanup: what no configured env uses (env worktrees, logs, run files, children of localEnv.cleanup.dataRoots); -Quick also
#      the old staged releases (keepReleases) and localEnv.cleanup.quick [ { name, paths: [globs], olderThanDays, cmd } ]
function Get-EnvOrphans {
  $out = [Collections.Generic.List[object]]::new(); $envs = @(EnvNames | Sort-Object Length -Descending)
  $add = { param($kind, $path, $why, $dirty) $out.Add([pscustomobject]@{ kind = $kind; path = $path; why = $why; dirty = [bool]$dirty }) }
  $wts = @(foreach ($n in $envs) { foreach ($r in (EnvRepos $n).Values) { [IO.Path]::GetFullPath($r.wt).TrimEnd('\', '/').ToLower() } })
  foreach ($root in @($KitConf.WorktreeRoots)) {
    foreach ($w in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^(localenv|lane)-') {
      if ($w.FullName.TrimEnd('\', '/').ToLower() -in $wts) { continue }
      $ch = @(git -C $w.FullName status --porcelain 2>$null); $failed = $LASTEXITCODE   # an unreadable worktree counts as dirty
      & $add 'worktree' $w.FullName 'no configured env runs it' ($ch.Count -or $failed)
    }
  }
  $known = '^(loop|train(-\w+)?|db|smoke|migrations|seed|restore|tenant)$'   # no <env>-events.jsonl: events = kitlog stream env (envy.ps1 events)
  $mine = { param([string]$base) if ($base -eq 'cleanup-quick') { return $true }; foreach ($n in $envs) { if ($base.StartsWith("$n-")) { $rest = $base.Substring($n.Length + 1) -replace '^(start|aot|task)-', '' -replace '-build$', ''
        return ($rest -match $known -or $rest -in @(EnvServices $n).name -or ($base -match "^$([regex]::Escape($n))-task-" -and (Get-KitMember (Get-EnvCfg $n).tasks $rest))) } }; $false }
  foreach ($f in Get-ChildItem -LiteralPath (Get-KitPath localenv-logs -Create) -File -ErrorAction SilentlyContinue) {
    $b = $f.Name -replace '(\.(log|prev|wrapper))+$', ''
    if (-not (& $mine $b) -and ((Get-Date) - $f.LastWriteTime).TotalDays -ge 1) { & $add 'log' $f.FullName 'no configured env or service writes it' $false }
  }
  $run = Join-Path (Get-KitPath localenv -Create) 'run'
  foreach ($f in Get-ChildItem -LiteralPath $run -File -Filter '*.cmd' -ErrorAction SilentlyContinue) { if (-not (& $mine $f.BaseName)) { & $add 'run' $f.FullName 'no configured env or service runs it' $false } }
  foreach ($d in Get-ChildItem -LiteralPath $run -Directory -ErrorAction SilentlyContinue) {
    if ($d.Name -notin $envs) { & $add 'run' $d.FullName 'no configured env' $false; continue }
    foreach ($sd in Get-ChildItem -LiteralPath $d.FullName -Directory) { if ($sd.Name -notin @(EnvServices $d.Name).name) { & $add 'run' $sd.FullName "env $($d.Name) has no service $($sd.Name)" $false } }
  }
  $none = [pscustomobject]@{ port = '' }
  $text = (@(foreach ($n in $envs) { foreach ($s in EnvServices $n) { foreach ($k in 'start', 'build', 'dataDir') { if ((Get-KitMember $s $k)) { Expand-Placeholders ([string](Get-KitMember $s $k)) $n $s $KitConf.Workspace '' } }; foreach ($v in @((Get-KitProps $s.env).Value)) { "$v" } } }; ($script:LE | ConvertTo-Json -Depth 20).Replace('\\', '\')) -join "`n").Replace('\', '/').ToLower()   # + every config value (db, stop, ...)
  foreach ($root in @($script:LE.cleanup.dataRoots) | Where-Object { $_ }) {   # a folder, or { dir, match }: only children whose name matches (an install folder holds more)
    $rp = Expand-Placeholders ([string]$(if ($root -is [string]) { $root } else { $root.dir })) '' $none $KitConf.Workspace ''; $mt = if ($root -isnot [string] -and $root.match) { [string]$root.match } else { '.' }
    foreach ($c in Get-ChildItem -LiteralPath $rp -Directory -ErrorAction SilentlyContinue | Where-Object Name -match $mt) { if (-not $text.Contains($c.FullName.Replace('\', '/').ToLower())) { & $add 'data' $c.FullName "no env service names it (cleanup.dataRoots $rp)" $false } }
  }
  @($out)
}
function Invoke-EnvCleanup([switch]$Quick, [switch]$DryRun) {
  $verb = if ($DryRun) { 'would remove' } else { 'removed' }
  $size = { param($p) if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { [long](Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
  $gone = { param($p, $why) $b = & $size $p
    if (-not $DryRun) { try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } catch { "  FAILED $p : $($_.Exception.Message)"; return } }
    $script:cleanFreed += $b; '  {0} {1,9:N1} MB  {2} ({3})' -f $verb, ($b / 1MB), $p, $why }
  $script:cleanFreed = 0L
  foreach ($o in Get-EnvOrphans) {
    if ($o.kind -eq 'worktree') {
      if ($o.dirty) { "  KEPT $($o.path): uncommitted files (never deleted; commit or remove by hand)"; continue }
      $b = & $size $o.path; if (-not $DryRun) { & $KitCmd.dev wt remove -Dir $o.path | Out-Null }; $script:cleanFreed += $b; '  {0} {1,9:N1} MB  {2} (worktree: {3})' -f $verb, ($b / 1MB), $o.path, $o.why; continue
    }
    & $gone $o.path $o.why
  }
  if ($Quick) {
    foreach ($n in EnvNames) { foreach ($s in EnvServices $n | Where-Object { $_.artifact }) { $root = Join-Path (Get-KitPath localenv -Create) "run/$n/$($s.name)"; if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($p in @(Remove-OldReleases $n $s $root -DryRun)) { & $gone $p "old release (keepReleases $($script:KeepReleases))" }; if (-not $DryRun) { $null = Remove-OldReleases $n $s $root } } }   # the second call prunes the library store
    # never what a service runs from or writes: its release, folder and dataDir while up or starting
    $inUse = @(@(foreach ($n in EnvNames) { $st = Read-State $n; foreach ($k in @($st.services.Keys)) { $x = $st.services[$k]; if ($x.artifact) { ReleaseDirOf (Join-Path (Get-KitPath localenv) "run/$n") "$($x.artifact)" }
          if ($x.status -in 'up', 'starting') { $sv = @(EnvServices $n | Where-Object name -eq $k)[0]; if ($sv) { if ($sv.repo -or $sv.dir) { try { SvcDir $n $sv } catch { } }; if ($sv.dataDir) { Expand-Placeholders ([string]$sv.dataDir) $n $sv $KitConf.Workspace '' } } } } }) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/') })
    foreach ($q in @($script:LE.cleanup.quick) | Where-Object { $_ }) {
      foreach ($g in @($q.paths | Where-Object { $_ })) {
        $pat = Expand-Placeholders ([string]$g) '' ([pscustomobject]@{ port = '' }) $KitConf.Workspace ''
        foreach ($i in @(Get-Item -Path $pat -Force -ErrorAction SilentlyContinue)) {
          if ($q.olderThanDays -and ((Get-Date) - $i.LastWriteTime).TotalDays -lt [double]$q.olderThanDays) { continue }
          if (@($inUse | Where-Object { $_ -and ($i.FullName -eq $_ -or $_.StartsWith($i.FullName + [IO.Path]::DirectorySeparatorChar) -or $i.FullName.StartsWith($_ + [IO.Path]::DirectorySeparatorChar)) }).Count) { "  KEPT $($i.FullName): a service runs from it"; continue }
          & $gone $i.FullName "quick: $($q.name)"
        }
      }
      if ($q.cmd) { if ($DryRun) { "  would run ($($q.name)): $($q.cmd)" } else { $code = Invoke-Shell (Expand-Placeholders ([string]$q.cmd) '' ([pscustomobject]@{ port = '' }) $KitConf.Workspace '') (LogFile 'cleanup' 'quick') $null 600; "  ran ($($q.name)): $(if ($code) { "FAILED ($(Get-ShellWhy $code))" } else { 'ok' })" } }
    }
  }
  "localenv cleanup$(if ($Quick) { ' -Quick' }): $verb $([math]::Round($script:cleanFreed / 1MB, 1)) MB$(if ($DryRun) { ' (dry run)' })"
}
function Test-ReadOnlySql([string]$q) {
  $q -match '(?i)^\s*(select|show|describe|desc|explain|with|pragma)\b|^\s*db\.\w+\.(find|findOne|count\w*|aggregate|distinct)\(' -and $q -notmatch '["`]|;\s*\S' -and
    $q -notmatch '(?i)\b(insert|update|delete|drop|alter|create|truncate|replace|merge|grant|revoke|rename|call|exec|execute|set|load|copy|attach|into|out)\b|\.(insert|update|delete|drop|remove)\w*\('
}
# ---- verbs: owner / brief asks; calls return within -Wait min (8). Adapters add verbs (kind envy-verb: @{ run = { ... }; ops = @(..) },
#      run inside Invoke-LocalEnv with its parameters and helpers in scope; e.g. tenant in adapters/tenant-models.ps1)
$script:EnvyVerbs = @('help', 'envs', 'status', 'doctor', 'deploy', 'wait', 'use', 'release', 'promote', 'task', 'logs', 'events', 'migrations', 'sql', 'dbtemp', 'mark', 'marks', 'restore', 'seed', 'teardown', 'cleanup', 'up', 'unhold', 'restart', 'down', 'drop', 'refresh', 'lanes', '_exec')
function Test-EnvyVerb([string]$v) {
  $reg = if ($KitAdapters['envy-verb']) { @($KitAdapters['envy-verb'].Keys) } else { @() }
  if ($v -in $script:EnvyVerbs -or $v -in $reg) { return $true }
  throw "unknown verb '$v' (verbs: $(@($script:EnvyVerbs + $reg | Where-Object { $_ -notlike '_*' }) -join ', '); adapters/*.ps1 add more: kind envy-verb)"
}
function Invoke-LocalEnv {
param(
  [Parameter(Mandatory, Position = 0)][ValidateScript({ Test-EnvyVerb $_ })][string]$Action,
  [Parameter(Position = 1)][string]$Op = '',   # a registered verb's operation (tenant list | drop | import)
  [string]$From, [string]$Tenant, [string]$As, [string]$Mask,
  [Alias('Env')][string]$EnvName,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }),
  [string]$Branch, [string[]]$Repo, [string[]]$Dir, [string[]]$Services, [string]$Service, [Alias('Item')][string]$Task, [string]$Note, [string]$Id,
  [string]$Session, [string]$Artifact, [string]$Query, [string]$Kill, [switch]$Owner, [string]$Name, [string]$Mark, [int]$Release = -1, [string[]]$Schemas,
  [switch]$DryRun, [switch]$Refresh, [switch]$Stale, [switch]$Migrate, [switch]$LanesOnly, [switch]$Sync, [switch]$Quick, [switch]$Check, [switch]$UseToolRollback, [switch]$Fix, [int]$Minutes = 0, [double]$Wait = 8, [int]$Tail = 80, [string]$Grep, [double]$Since = 0, [switch]$Json,
  [int]$Lane = 0, [string]$Until, [int]$Timeout = 600, [Alias('All')][switch]$AllServices
)
if ($Action -eq 'help') { foreach ($hl in @(Get-Content $PSCommandPath | Select-Object -Skip 1)) { if ($hl -eq '#>') { break }; $hl }; return }   # the verbs, before any env check
if ($Action -eq 'marks') { if ($Name) { throw "marks lists the marks; to make one: mark -Name $Name" }; $Action = 'mark' }   # the list form agents guess
$Repo = @(Split-KitList $Repo); $Services = @(Split-KitList $Services); $Schemas = @(Split-KitList $Schemas)
if ($Service -and -not $Services) { $Services = @($Service) }
if (-not (EnvNames).Count -and $Action -ne 'envs') { throw 'No local environments configured: add "localEnv": { "envs": { "<env>": { "services": [...] } } } to kit.local.json (see README "Configuration", localEnv).' }
if ($EnvName) { $EnvName = ConvertFrom-KitLaneLabel $EnvName }   # -Env takes the id or the shown name (shop·Kestrel, shop-kestrel)
$clash = @(Test-PortClash)
if ($clash.Count) { $m = "localEnv port clash (envs run side by side; give each service its own port): $($clash -join '; ')"; if ($Action -in 'envs', 'status', 'doctor', 'logs', 'events', 'release', '_exec') { Write-Warning $m } else { throw $m } }
if ($EnvName) { $EnvName = Resolve-EnvAlias $EnvName }
# release without -Env: the env (lane) the agent leases (retro 2026-11-23: release needed -Env)
if (-not $EnvName -and $Action -eq 'release') { $relHeld = @(EnvNames | Where-Object { (Read-State $_).leases.ContainsKey($Agent) }); if ($relHeld.Count -eq 1) { $EnvName = $relHeld[0] } elseif ($relHeld.Count) { throw "-Env needed: $Agent leases $($relHeld -join ', ') (envy.ps1 release -Env <env>)" } }
# down without -Env: -All stops every env and lane (owner "down all"); else usage + env list, no crash
if (-not $EnvName -and $Action -eq 'down' -and @(EnvNames).Count -gt 1) { if ($AllServices) { foreach ($downEnv in @(EnvNames)) { Invoke-LocalEnv down -Env $downEnv -Agent $Agent }; return }; Stop-KitVerb "usage: envy.ps1 down -Env <env> [-Services <s>] | down -All (every env and lane). Envs: $((EnvNames) -join ', ')" }
if (-not $EnvName -and $Action -notin 'envs', 'status', 'doctor', 'cleanup', 'lanes' -and -not $Stale) { if (@(EnvNames).Count -eq 1) { $EnvName = @(EnvNames)[0] } else { throw "-Env needed: $((EnvNames) -join ', ') (e.g. envy.ps1 $Action -Env $(@(EnvNames)[0])$(if ($Action -eq 'mark') { " -Name <name>; list: envy.ps1 marks -Env $(@(EnvNames)[0])" }))" } }
if ($EnvName -and $Lane -or ($EnvName -and $Agent -ne 'main' -and $Action -in 'deploy', 'wait', 'use', 'release', 'promote', 'task', 'logs', 'events', 'status', 'migrations', 'sql', 'drop' -and -not ($Action -eq 'drop' -and ($Branch -or $Stale)) -and (Get-EnvCfg $EnvName).lane -eq 1 -and @(LaneNames $EnvName).Count -gt 1)) { $EnvName = Select-Lane $EnvName $Agent $Lane $Action $Id }
elseif ($EnvName -and $Agent -ne 'main' -and ($Action -eq 'deploy' -or ($Action -eq 'wait' -and $Id)) -and [int](Get-EnvCfg $EnvName).lane -gt 1) { $EnvName = Select-Lane $EnvName $Agent 0 $Action $Id $EnvName }   # an agent's named lane another agent leases: a deploy takes a free one (wait -Id follows it)
$e = $EnvName
# db.engine without its presets (adapters/db-presets.ps1 missing): stop before anything changes
$needs = @(foreach ($n in @($e)) { $c = (Get-KitMember $script:LE.envs $n); if ($c.db.engine -and -not $script:DbPresets) { "env $n (db.engine): db.engine presets missing: restore adapters/db-presets.ps1" } })
if ($needs.Count -and $Action -in 'deploy', 'drop', 'refresh', 'promote', 'mark', 'restore', 'seed', 'teardown', 'tenant') { [Console]::Error.WriteLine("envy.ps1: $($needs[0])"); exit 1 }

function Ensure-Loop {
  $st = Read-State $e
  if (Owned $st.loop "_daemon -Env $e") { return }
  $null = Start-Pwsh @('_daemon', '-Env', $e) $PSScriptRoot "_daemon -Env $e" (LogFile $e 'loop')
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 300; if ((Read-State $e).loop) { break } }
}
function New-Request([hashtable]$r) {
  $r.id = [guid]::NewGuid().ToString('n').Substring(0, 8); $r.at = Now; $r.status = 'queued'; $r.agent = $Agent
  Update-State $e { param($x) foreach ($q in @($x.requests | Where-Object { $_.status -eq 'deferred' })) { $q.status = 'queued' }; $x.requests = @($x.requests) + @($r) }   # due drops ride along
  Event $e 'request' @{ id = $r.id; kind = $r.kind; agent = $Agent; branch = $r.branch }
  Ensure-Loop
  $r.id
}
function Exit-Request($r) { if ($r -and $r.status -ne 'done') { exit 3 }; if ($r -and "$($r.result.outcome)" -match '(?i)refus|reject|error|roll|fail') { exit 1 } }
# wait -Until <state> [-Services] [-Timeout s] (K48): one process polls (no agent status loop of pwsh starts); 0 reached, 1 failed / timeout
function Wait-Until([string]$e, [string]$state, [string[]]$names, [int]$sec) {
  $Json = $true; $end = (Get-Date).AddSeconds($sec); $want = if ($names.Count) { $names } else { @(EnvServices $e | Where-Object { Managed $_ } | ForEach-Object name) }
  while ($true) { $script:StatusSnap = Get-KitProcSnap; $bad = @((Show-Status $e).services | Where-Object { $_.service -in $want -and "$($_.state)" -notlike "$state*" })
    if (-not $bad.Count) { "[$e] $($want -join ', '): $state"; return }
    $why = @($bad | ForEach-Object { "$($_.service) $($_.state)" }) -join ', '
    if (@($bad | Where-Object state -eq 'failed').Count -and $state -ne 'failed') { "[$e] failed: $why"; exit 1 }
    if ((Get-Date) -ge $end) { "[$e] not $state after $sec s: $why"; exit 1 }
    Wait-KitPoll 5 }
}
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
    if ((Get-Date) -gt $until) { Write-Host "[$e] still $($r.status) after $Wait min - it keeps going; continue with: envy.ps1 wait -Env $e -Id $rid"; return $r }
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
    if ($failed.Count) { Write-Host "[$e] $($failed -join ', ') failed 3 times: see envy.ps1 logs -Env $e -Service $($failed[0])"; return $false }
    if ((Get-Date) -gt $until) { Write-Host "[$e] not up yet after $Wait min (it keeps starting): call the same command again to keep waiting"; return $false }
    Ensure-Loop
    Start-Sleep 3
  }
}

function Show-Status([string]$env1) {
  $script:e = $env1; if (Test-Path (StateFile $env1)) { Update-State $env1 { param($x) Prune $x } }; $st = Read-State $env1; Prune $st   # the prune persists: status and supervise reclaim
  $all = $script:StatusSnap ?? (Get-KitProcSnap)
  $svc = foreach ($s in EnvServices $env1) {
    $x = $st.services[$s.name]; $h = Healthy $env1 $s
    $ids = if ($h) { SvcPids $env1 $s $st $all } else { @() }
    $listens = if ($h -and $KitIsWindows -and $ids) { $null = Get-PortPids 0; @($script:ListenSnap.ports.Keys | Where-Object { @($script:ListenSnap.ports[$_] | Where-Object { $_ -in $ids }).Count } | ForEach-Object { [int]$_ } | Sort-Object -Unique) }
      elseif ($h -and $ids -and (Resolve-Tool lsof)) { @(lsof -nP -a -p ($ids -join ',') -iTCP -sTCP:LISTEN -Fn 2>$null | Where-Object { $_ -match ':(\d+)$' } | ForEach-Object { [int]$Matches[1] } | Sort-Object -Unique) } else { @() }
    $idleMin = if ($h -and $x.lastNeed) { [int]((Get-Date) - [datetime]$x.lastNeed).TotalMinutes } else { $null }
    [pscustomobject]@{
      service = $s.name; state = $(if ($h) { if (-not (Managed $s)) { 'up (external)' } elseif (Owned $x) { 'up' } else { 'up (adopted)' } } elseif ($x.status -in 'starting', 'failed') { $x.status } elseif ($x.status -eq 'waiting' -and (Test-KitPid $x.waitPid $x.waitStart)) { "waiting ($(if ($x.waitFor) { $x.waitFor } else { 'RAM' })$(if ($x.waitUntil -and "$($x.waitFor)" -in '', 'RAM', 'CPU') { ', until ' + ([datetime]$x.waitUntil).ToString('HH:mm') }))" } else { 'down' })
      port = $s.port; gb = $(if ($ids) { TreeGB $ids $all } else { 0 }); release = $x.release; need = @($x.need | Where-Object { $_ }); idleMin = $idleMin; graceMin = $(if (Managed $s) { GraceMin $env1 $s }); listens = $listens
      why = $(if (-not ($x.status -eq 'waiting' -and (Test-KitPid $x.waitPid $x.waitStart))) { $x.why }); hot = [bool]$s.hot; waitMin = $(if ($x.status -eq 'waiting' -and $x.waitSince -and (Test-KitPid $x.waitPid $x.waitStart)) { [int]((Get-Date) - [datetime]$x.waitSince).TotalMinutes }); restarts30 = @($x.restarts | Where-Object { $_ -and ((Get-Date) - [datetime]$_).TotalMinutes -lt 30 }).Count
    }
  }
  $o = [pscustomobject]@{
    env = $env1; release = $st.release.n; releasedAt = $st.release.at; lastUsed = Format-KitLeaseLast (Get-KitLeaseLast)["env|$env1"]
    repos = @($st.release.repos.Keys | ForEach-Object { $rr = $st.release.repos[$_]; [pscustomobject]@{ repo = $_; target = $rr.target; targetSha = "$($rr.targetSha)".Substring(0, [math]::Min(9, "$($rr.targetSha)".Length)); layers = @($rr.layers | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ branch = $_.branch; agent = $_.agent; sha = "$($_.sha)".Substring(0, [math]::Min(9, "$($_.sha)".Length)); migrations = [bool]$_.migrations; promoted = $(if ($_.promoted) { "release $($_.promoted.release)" }) } }) } })
    train = $(if ($st.train) { [pscustomobject]@{ id = $st.train.id; phase = $st.train.phase; waitingFor = @($st.train.waitingFor); waitSince = $st.train.waitSince; requests = @($st.train.requests).Count
      quietMin = TrainQuietMin $st.train $env1; stallMin = $script:TrainStallMin } })
    trainDead = $(if ($st.trainDead -and ((Get-Date) - [datetime]$st.trainDead.at).TotalHours -lt 2) { [pscustomobject]$st.trainDead })
    halfRestored = $(if ($st.halfRestored) { [pscustomobject]$st.halfRestored })
    queue = @($st.requests | Where-Object status -eq 'queued' | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch)" })
    services = @($svc)
    leases = @($st.leases.Keys | ForEach-Object { $l = $st.leases[$_]; [pscustomobject]@{ agent = $_; services = @($l.services); until = $(if ($l.owner) { ([datetime]$l.until).ToString('HH:mm') }); release = $l.release; note = $l.note; graceLeft = $l.graceLeft
      ageMin = $(if ($l.at) { [int]((Get-Date) - [datetime]$l.at).TotalMinutes }); usedMinAgo = $(if ($l.lastUse) { [int]((Get-Date) - [datetime]$l.lastUse).TotalMinutes })
      trainWaits = $(if ($st.train -and $_ -in @($st.train.waitingFor)) { "train $($st.train.id) waits $(if ($st.train.waitSince) { [int]((Get-Date) - [datetime]$st.train.waitSince).TotalMinutes } else { 0 })/$($script:LeaseMin) min" }) } })
    holds = @($st.holds.Keys | ForEach-Object { $h = $st.holds[$_]; [pscustomobject]@{ who = $_; services = @($h.services); owner = [bool]$h.owner; until = $(if ($h.until) { ([datetime]$h.until).ToString('HH:mm') }); at = $h.at; graceLeft = $h.graceLeft } })
    due = @($st.requests | Where-Object status -eq 'deferred' | ForEach-Object { "$($_.agent): drop $($_.branch) ($($_.why))" })
    recent = @(@($st.requests | Where-Object status -eq 'done' | Select-Object -Last 5 | ForEach-Object { "$($_.agent): $($_.kind) $($_.branch) -> $($_.result.outcome)$(if ($_.result.release) { " (release $($_.result.release))" })" }) + @(Get-LayerDrops $env1))
    keepFree = $("$((Get-KeepFree).gb) GB: $((Get-KeepFree).why)"); keepFreeGB = [double](Get-KeepFree).gb
    marks = $(if (@($st.marks | Where-Object { $_ }).Count -or $st.binlog) { $ms = @($st.marks | Where-Object { $_ }); $b = @($ms | Where-Object kind -eq 'baseline')[-1]
      [pscustomobject]@{ count = $ms.Count; newest = @($ms)[-1].name; baseline = $b.name; baselineAgeDays = $(if ($b) { [math]::Round(((Get-Date) - [datetime]$b.at).TotalDays, 1) }); expired = @($st.expiredMarks | Where-Object { $_ }); binlogDays = $st.binlog.days; dbDown = (DbSvcDown $env1) } })
    schemaSizes = [bool]$(if (Get-Command Get-DbEngine -ErrorAction SilentlyContinue) { (Get-DbEngine $env1).schemaSizes -or (Get-DbEngine $env1).sizes })   # the engine reads schema sizes (supervise: data growth)
    seed = $(if ($st.seed) { [pscustomobject]@{ at = $st.seed.at; ok = [bool]$st.seed.ok; missing = @($st.seed.missing | Where-Object { $_ }); drift = @($st.seed.drift | Where-Object { $_ }) } })
    loop = $(if (Owned $st.loop "_daemon -Env $env1") { "running (pid $($st.loop.pid))" } else { 'stopped (starts on the next request)' })
    lanesOpen = Get-LanesOpen $env1
  }
  if ($Agent -and $st.notices[$Agent]) { $o | Add-Member -NotePropertyName notice -NotePropertyValue "$(([datetime]$st.notices[$Agent].at).ToString('HH:mm')) $($st.notices[$Agent].text)" }
  if ($Agent -and $Agent -ne 'main' -and $st.leases[$Agent]) {
    $l = $st.leases[$Agent]; $since = [int]$l.release
    $chg = @($st.releases | Where-Object { [int]$_.n -gt $since } | ForEach-Object { $rel = $_; @($_.changed) | ForEach-Object { "$_ in release $($rel.n)" } })
    $mine = @(Closure $env1 @($l.services) | ForEach-Object { RepoOf $env1 (Svc $env1 $_) } | Where-Object { $_ } | Select-Object -Unique)
    $hits = @($chg | Where-Object { ($_ -split ' ')[0] -in $mine })
    $o | Add-Member -NotePropertyName mine -NotePropertyValue $(if ($hits.Count) { "CHANGED since your lease started (release $since): $($hits -join '; ') - re-run the checks that touch them" } else { "unchanged since your lease started (release $since)" })
  }
  if ($Json) { return $o }
  "== $env1  release $($o.release)$(if ($o.releasedAt) { " ($(([datetime]$o.releasedAt).ToString('HH:mm')))" })   controller: $($o.loop)   keep-free $($o.keepFree)   last used $($o.lastUsed)"
  if ($o.train) { "  TRAIN $($o.train.id): $($o.train.phase)$(if ($o.train.waitingFor.Count) { " - waiting for $($o.train.waitingFor -join ', ')" }) ($($o.train.requests) request(s); quiet $($o.train.quietMin)/$($o.train.stallMin) min)" }
  if ($o.halfRestored) { "  HALF-RESTORED to $($o.halfRestored.mark) at $(([datetime]$o.halfRestored.at).ToString('HH:mm')): $($o.halfRestored.why)" }
  if ($o.trainDead) { "  TRAIN $($o.trainDead.id) ended $(([datetime]$o.trainDead.at).ToString('HH:mm')): $($o.trainDead.why); requeued$(if (@($o.trainDead.failed).Count) { ", failed: $(@($o.trainDead.failed) -join ', ')" })" }
  if ($o.lanesOpen -and (Get-EnvCfg $env1).lane -eq 1) { "  lanes open $($o.lanesOpen.open) of $($o.lanesOpen.of) ($($o.lanesOpen.why))" }
  if ($o.queue) { "  queued: $($o.queue -join '; ')" }
  if ($o.due) { "  on the next lease: $($o.due -join '; ')" }
  foreach ($x in $o.services) {
    $extra = @()
    if ($x.need.Count -and $x.state -like 'up*') { $extra += "needed: $($x.need -join ', ')" } elseif ($x.state -like 'up*' -and $null -ne $x.idleMin -and $x.graceMin) { $extra += "idle $($x.idleMin)/$($x.graceMin) min" }
    if ($x.release) { $extra += "r$($x.release)" }
    if (@($x.listens | Where-Object { $_ -ne $x.port }).Count) { $extra += "listens $($x.listens -join '/')" }
    if ($x.state -in 'down', 'failed' -and $x.why) { $extra += $x.why }
    '  {0,-14} {1,-16} {2,6} {3,6} GB  {4}' -f $x.service, $x.state, $(if ($x.port) { ":$($x.port)" }), $x.gb, ($extra -join ' | ')
  }
  foreach ($r in $o.repos) { "  $($r.repo) @ $($r.target) $($r.targetSha)$(if (-not $r.layers.Count) { ' (no layers)' })"; foreach ($l in $r.layers) { '    + {0,-42} {1,-10} {2}{3}{4}' -f $l.branch, $l.agent, $l.sha, $(if ($l.promoted) { "  PROMOTED ($($l.promoted))" }), $(if ($l.migrations) { '  MIGRATIONS' }) } }
  $gr = { param($x) if ($null -ne $x.graceLeft) { " - no live holder: ends in $($x.graceLeft) min" } }
  if ($o.leases) { "  leases: $(($o.leases | ForEach-Object { "$($_.agent) [$($_.services -join ',')] $(if ($_.until) { "owner until $($_.until)" } else { 'while live' }) (r$($_.release)), age $($_.ageMin) min$(if ($null -ne $_.usedMinAgo) { ", used $($_.usedMinAgo) min ago" })$(if ($_.note) { " $($_.note)" })$(if ($_.trainWaits) { " - $($_.trainWaits)" })$(& $gr $_)" }) -join '; ')" }
  if ($o.holds) { "  holds: $(($o.holds | ForEach-Object { "$($_.who) [$($_.services -join ',')] $(if ($_.owner) { "owner until $($_.until)" } else { 'while live' })$(& $gr $_)" }) -join '; ')" }
  if ($o.recent) { "  recent: $($o.recent -join '; ')" }
  if ($o.marks) { "  marks: $($o.marks.count) (newest $($o.marks.newest); baseline $(if ($o.marks.baseline) { "$($o.marks.baseline), $($o.marks.baselineAgeDays) d old" } else { 'none: seed' }); binlog keeps $($o.marks.binlogDays) d)$(if ($o.marks.expired.Count) { "; expired $($o.marks.expired -join ', ')" })" }
  if ($o.seed -and -not $o.seed.ok) { "  seed: DRIFT $(@($o.seed.missing + $o.seed.drift) -join ', ') ($(([datetime]$o.seed.at).ToString('MM-dd HH:mm'))): seed -Env $env1" }
  if ($o.mine) { "  YOU ($Agent): $($o.mine)" }
  if ($o.notice) { "  NOTICE ($Agent): $($o.notice)" }
}

switch ($Action) {
  'envs' {   # -Json: env, group, lane, ports (pokey.ps1 lane targets)
    if ($Json) { @(EnvNames | ForEach-Object { $ec = Get-EnvCfg $_; $pm = [ordered]@{}; foreach ($s in EnvServices $_ | Where-Object port) { $pm[$s.name] = [int]$s.port }; [pscustomobject]@{ env = $_; group = $ec.group; lane = $ec.lane; ports = [pscustomobject]$pm } }) | ConvertTo-Json -Depth 4 -AsArray; return }
    foreach ($n in EnvNames) {
      $ln = @(LaneNames $n); "$n$(if ($ln.Count -gt 1) { " (lane $((Get-EnvCfg $n).lane) of $($ln[0]); -Env $($ln[0]) picks one)" })$(if ((Get-EnvCfg $n).description) { " - $((Get-EnvCfg $n).description)" })"
      foreach ($s in EnvServices $n) { '  {0,-14} {1,-28}{2}{5}{3}{4}' -f $s.name, $(if ($s.repo) { "$($s.repo)/$($s.dir)" } else { 'external' }), $(if ($s.port) { "  :$($s.port)" }), $(if ($s.dependsOn) { "  needs $(@($s.dependsOn) -join ',')" }), ("$(if ($s.hot) { '  hot' } elseif ($s.static) { '  static (built files)' } elseif ($s.artifact) { '  runs from artifact' })" + "$(if ($s.aiStack) { '  AI path' })"), $(if ($s.debugPort) { "  debug :$($s.debugPort)" }) }
      if ((Get-EnvCfg $n).tasks) { "  tasks: $((Get-KitProps (Get-EnvCfg $n).tasks).Name -join ', ')" }
    }
  }
  'status' { $names = if ($EnvName) { @($EnvName) } else { EnvNames }; if ($Agent -ne 'main') { foreach ($n in $names) { Touch-Lease $n $Agent } }
    $script:StatusSnap = Get-KitProcSnap
    $out = foreach ($n in $names) { Show-Status $n }; if ($Json) { $out | ConvertTo-Json -Depth 8 } else { $out } }
  'doctor' {
    $rows = @(foreach ($n in $(if ($EnvName) { @($EnvName) } else { EnvNames })) { $d = @(Get-Doctor $n -Fix:$Fix); if ($d.Count) { $d } else { [pscustomobject]@{ level = 'OK'; env = $n; what = 'nothing to fix' } } })
    if ($Json) { $rows | ConvertTo-Json -Depth 4 } else { $rows | ForEach-Object { '{0,-4} {1}: {2}' -f $_.level, $_.env, $_.what } }
    if (@($rows | Where-Object level -eq 'FAIL').Count) { exit 1 }
  }
  'mark' {   # -Name: a mark of the DB now (zero bytes); without: the env's marks
    if (-not (MarksOn $e)) { throw "[$e] marks need db.engine with marks (adapters/db-engines.ps1): this env has none" }
    if ($Name) { $n = New-Mark $e $Name 'owner'; "[$e] mark $n at $(@((Read-State $e).marks | Where-Object name -eq $n)[0].pos): envy.ps1 restore -Env $e -Mark $n [-DryRun]"; return }
    $st = Read-State $e
    foreach ($m in @($st.marks | Where-Object { $_ })) { '  {0,-34} {1,-8} {2:yyyy-MM-dd HH:mm}  release {3,-4} {4}' -f $m.name, $m.kind, [datetime]$m.at, $m.release, $m.pos }
    if (@($st.expiredMarks).Count) { "  expired (binlog gone): $(@($st.expiredMarks) -join ', ')" }
    if ($st.binlog) { "  the binlog keeps $($st.binlog.days) d (oldest $($st.binlog.oldest))" }
  }
  'restore' {   # owner / coordinator: DB (flashback + rollbacks) and code back to a mark; -DryRun: the plan
    if (-not (MarksOn $e)) { throw "[$e] restore needs marks: a marks engine (envy.ps1 mark says which)" }
    if (-not $Mark -and $Release -lt 0) { throw 'restore needs -Mark <name> or -Release <n> (envy.ps1 mark -Env <env> lists them)' }
    $st = Read-State $e; $m = Find-Mark $st $Mark $Release
    $sch = if ($Schemas.Count) { Test-RestoreScopes $e $Schemas } else { @(Get-MarkScopes $e $m) }
    if ($DryRun) {
      $p = Get-RestorePlan $e $m $sch "dryrun-$($m.name)"
      "[$e] restore to $($m.name) ($($m.kind), $(([datetime]$m.at).ToString('yyyy-MM-dd HH:mm')), release $($m.release)) - dry run, nothing changes:"
      foreach ($w in @($script:ScopeWarn)) { "  WARN $w" }
      RestorePlanText $p | ForEach-Object { "  $_" }
      foreach ($rn in @($m.repos.Keys)) { $mr = $m.repos[$rn]; "  code $rn : $("$($mr.targetSha)".Substring(0, [math]::Min(9, "$($mr.targetSha)".Length))) + $(@($mr.layers | Where-Object { $_ }).Count) layer(s): $(@($mr.layers | Where-Object { $_ } | ForEach-Object branch) -join ', ')" }
      if (@($p.refused).Count) { exit 1 }; return
    }
    foreach ($w in @($script:ScopeWarn)) { "[$e] WARN $w" }
    $rid = New-Request @{ kind = 'restore'; branch = $m.name; mark = $m.name; schemas = $sch; useTool = [bool]$UseToolRollback }
    "[$e] restore to $($m.name) queued as $rid (holders are told to pause)"; Exit-Request (Wait-Request $rid)
  }
  'seed' { Invoke-Seed $e -Check:$Check; if ($script:SeedBad) { exit 1 } }
  default {   # a verb an adapter registered (kind envy-verb)
    $vd = $KitAdapters['envy-verb'][$Action]
    if (@($vd.ops).Count -and $Op -and $Op -notin @($vd.ops)) { throw "$Action $Op : unknown ($(@($vd.ops) -join ', '))" }
    & $vd.run
  }
  'lanes' { if ($Sync) { Invoke-LaneResync -DryRun:$DryRun } elseif ($Migrate) { Invoke-LaneMigrate -LanesOnly:$LanesOnly -DryRun:$DryRun } else { throw 'usage: envy.ps1 lanes -Migrate [-LanesOnly] [-DryRun] | -Sync [-DryRun]' } }   # owner / supervise / wt pool -Sync
  'cleanup' { Invoke-EnvCleanup -Quick:$Quick -DryRun:$DryRun }   # owner / coordinator: orphans of envs no longer configured; -Quick: old releases + cleanup.quick
  'teardown' {   # owner: the cascade guard's triggers and journal schema removed (doctor installs them again)
    if (-not (MarksOn $e)) { throw "[$e] teardown: no marks here (db.engine mysql or mariadb, adapters/db-presets.ps1)" }
    $g = Install-DbGuard $e -Remove; "[$e] cascade guard removed: $($g.removed) trigger(s), the journal schema dropped; envy.ps1 doctor -Env $e installs it again"
  }
  'deploy' {
    $bad = @(Get-Doctor $e | Where-Object level -eq 'FAIL')
    if ($bad.Count) { $bad | ForEach-Object { "FAIL $($_.what)" }; [Console]::Error.WriteLine("envy.ps1: deploy stopped: fix the FAIL lines (envy.ps1 doctor -Env $e)"); exit 1 }
    Touch-Lease $e $Agent
    $envRepos = EnvRepos $e
    if ($Dir) {   # one worktree per repo (-Dir a,b), all on one branch
      $dirBranches = @{}; $Repo = @()
      foreach ($dd in @(Split-KitList $Dir -Sep ',')) {   # commas only: a path may hold a space
        $dd = (Resolve-Path $dd).Path
        $ddCommon = "$(git -C $dd rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim(); if (-not $ddCommon) { throw "[$e] $dd is not a git worktree" }
        $dirBranches[$dd] = "$(git -C $dd rev-parse --abbrev-ref HEAD)".Trim()
        $common = (Resolve-Path $ddCommon).Path
        $hit = $envRepos.Values | Where-Object { (Resolve-Path "$(git -C $_.cfg.checkout rev-parse --path-format=absolute --git-common-dir)".Trim() -ErrorAction SilentlyContinue).Path -eq $common } | Select-Object -First 1
        if (-not $hit) { throw "[$e] $dd is not a worktree of a repo this env runs ($($envRepos.Keys -join ', '))" }
        $Repo += $hit.name
        if (@(git -C $dd status --porcelain --untracked-files=no).Count) { Write-Warning "$dd has uncommitted changes: only committed work is deployed (crafty.ps1 wt commit first)" }
      }
      $oneBranch = @($dirBranches.Values | Select-Object -Unique)
      if ($oneBranch.Count -gt 1) { throw "[$e] -Dir worktrees are on different branches ($(@($dirBranches.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join '; ')): one deploy per branch; deploy one -Dir per call" }
      $Branch = $oneBranch[0]
    }
    if (-not $Branch) { throw 'deploy needs -Dir <your worktree> or -Branch <branch>' }
    if ($Branch -match '^(localenv|lane)/') { throw 'that is the env branch itself' }
    # a second target only by name (-Repo <repo>@<target>)
    $targets = if ($Repo) { @($Repo | ForEach-Object { if ($envRepos.Contains("$_")) { "$_" } else { (Get-RepoCfg $_).name } }) } else { @($envRepos.Values | Where-Object { $_.name -notlike '*@*' -and (Resolve-Ref $_.cfg.checkout $Branch) } | ForEach-Object name) }
    $targets = @($targets | Where-Object { $envRepos.Contains($_) })
    if (-not $targets) { throw "[$e] branch $Branch not found in any repo of this env ($($envRepos.Keys -join ', '))" }
    $shas = @{}; $mig = @{}
    foreach ($rn in $targets) {   # the commit at request time
      $sha = Resolve-Ref $envRepos[$rn].cfg.checkout $Branch; if (-not $sha) { throw "[$e] $Branch not found in $rn" }
      $shas[$rn] = $sha; $mig[$rn] = HasMigrations $envRepos[$rn].cfg.checkout $envRepos[$rn].target $sha
    }
    $rid = New-Request @{ kind = 'deploy'; branch = $Branch; shas = $shas; migrations = $mig }
    "[$e] deploy $Branch ($(($shas.Keys | ForEach-Object { $s = $shas[$_]; "$_ @ $(if ($s.Length -ge 9) { $s.Substring(0, 9) } else { $s })" }) -join ', ')) queued as request $rid"
    foreach ($rn in @($mig.Keys | Where-Object { $mig[$_] })) { "[$e]   $rn MIGRATIONS: they change the shared local DB$(if (MarksOn $e) { '; the release mark keeps what their DDL destroys (envy.ps1 migrations -Env ' + $e + ' -Branch ' + $Branch + ' lists the tables)' })" }
    Exit-Request (Wait-Request $rid)
  }
  'drop' {   # -Agent (release): a finished agent's layers; -Stale (supervise): merged, gone or orphan layers of all envs
    if ($Stale) { foreach ($n in $(if ($EnvName) { @($EnvName) } else { EnvNames })) { $e = $n; $sl = @(Get-StaleLayers $n -DryRun:$DryRun); if ($DryRun) { $sl | ForEach-Object { "[$n] stale $($_.why)" } } elseif ($sl.Count) { Add-LayerDrops $n $sl } }; return }
    if (-not $Branch -and $PSBoundParameters.ContainsKey('Agent')) {
      if (Test-Parked $Agent) { "[$e] layers of $Agent kept: it paused or handed off"; return }
      $st = Read-State $e; $mine = @(foreach ($rn in @($st.release.repos.Keys)) { Layers $st $rn | Where-Object { $_.agent -eq $Agent } })
      if (-not $mine.Count) { "[$e] $Agent has no layer"; return }
      Add-LayerDrops $e @($mine | ForEach-Object { @{ branch = $_.branch; agent = $Agent; why = "finished: $($_.branch) ($(if ($Note) { $Note } else { 'agent finished' }))" } }); return
    }
    if (-not $Branch) { throw 'drop needs -Branch, -Agent or -Stale' }; $rid = New-Request @{ kind = 'drop'; branch = $Branch }; "[$e] drop $Branch queued as $rid"; Exit-Request (Wait-Request $rid) }
  'refresh' { $rid = New-Request @{ kind = 'refresh'; branch = '' }; "[$e] refresh queued as $rid"; Exit-Request (Wait-Request $rid) }
  'wait' { if ($Until) { Wait-Until $e $Until $Services $Timeout; return }; if (-not $Id) { throw 'wait needs -Id <request> or -Until <state> [-Services a,b] [-Timeout 600]' }; Touch-Lease $e $Agent; Exit-Request (Wait-Request $Id) }
  'use' {
    # a lease starts only what it names (+ deps): a whole-env lease held a staging run's shop env 1 h+; owner 2026-11-20 "a lane might not need all resources"
    if (-not $Services -and "$Agent" -like 'test:*') { "[$e] use refused for ${Agent}: name the services its checks call (-Services api[,web]); a tester never leases the whole env"; exit 2 }
    # a QA tester (test:<CODE>@<run tag>) leases only for an item run.json gives a local env (localParts, localEnv): 2026-11-20 a staging
    # item's tester ran a suite's tenant restore 6x on two lanes (4.7 GB of lane MySQL writes in 40 min)
    if ("$Agent" -match '^test:(?<c>[^@]+)@(?<t>.+)$') { $tc = $Matches.c; $tt = $Matches.t   # the tag: testy.js RUNTAG (HHmmss, else the dir name)
      $tj = @(Get-ChildItem -LiteralPath (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $tt -or $_.Name -match "^\d{4}-\d\d-\d\d-$([regex]::Escape($tt))(-|$)" } |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'run.json' } | Where-Object { Test-Path -LiteralPath $_ })[0]
      $tr = if ($tj) { try { Get-Content -LiteralPath $tj -Raw | ConvertFrom-Json } catch { $null } }
      $ti = if ($tr) { $tx = @($tr.items | Where-Object { "$($_.code)" -eq $tc })[0]; if ($tx) { $tx } else { @($tr.items | Where-Object { "$($_.code)" -eq ($tc -creplace '[A-Z]$') })[0] } }
      if ($ti -and -not @($ti.localParts | Where-Object { $_ }).Count -and -not "$($ti.localEnv)" -and -not "$($tr.localEnv)") {
        "[$e] use refused for ${Agent}: item $tc tests target $(if ($ti.target) { $ti.target } else { $tr.target }) and run.json gives it no localParts or localEnv; a check that needs the local env: NOT_TESTED with env_fix / a lead-notes question (the lead adds localParts), never a lease of its own"; exit 1 } }
    if (-not $Services -and -not $AllServices) { "[$e] use refused for ${Agent}: name the services you test (-Services $(@(All-Managed) -join ',' ) or a part; their dependencies come along); the whole env only with -All"; exit 2 }
    $names = @(Closure $e $(if ($Services) { $Services } else { All-Managed }))
    foreach ($n in $names) { $null = Svc $e $n }
    $min = [math]::Min($(if ($Minutes) { $Minutes } else { $LeaseMin }), $MaxLeaseMin)
    Wake-Deferred $e -UntilDone   # drops due since the env went idle: the lease starts on the refreshed code
    $until = (Get-Date).AddMinutes($Wait); $said = $null; $o = @{}
    while ($true) {
      $o.ok = $false
      Update-State $e { param($x)
        Prune $x
        $blocked = @($x.train.blockServices | Where-Object { $_ -in $names })
        $old = $x.leases[$Agent]; $o.fresh = -not $old
        if ($old -and $blocked.Count) {   # a train waits on it: kept, not extended
          $o.ok = $true; $o.rel = $old.release; $o.capped = $true
        } elseif (-not $blocked.Count) {
          # a second use adds its services; the release moves to the current one when it changed meanwhile
          $x.leases[$Agent] = @{ services = @(@($old.services) + $names | Where-Object { $_ } | Select-Object -Unique); repos = @($old.repos | Where-Object { $_ }); release = $(if ($old -and [int]$old.release -eq [int]$x.release.n) { [int]$old.release } else { [int]$x.release.n }); note = $(if ($Note) { $Note } else { "$($old.note)" }); lastUse = (Now) } + (New-KitLease $Agent $Session $(if ($Owner) { $min }))   # no live holder: Prune frees it
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
    if ($o.fresh -and (MarksOn $e)) { try { $mk = New-Mark $e "use-$Agent" 'use'; "[$e] mark $mk (restore -Mark $mk brings the DB back to this start)" } catch { Write-Warning "[$e] no mark at the lease: $("$_".Split("`n")[0])" } }
    "[$e] lease for $Agent on $($names -join ', ') $(if ($Owner) { "for $min min (owner)" } else { 'while you are live' }) (release $($o.rel)).$(if ($o.capped) { ' Kept as is: a train waits for it - release when done.' } else { ' End: release.' })"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e } else { exit 1 }
  }
  'release' { Update-State $e { param($x) $x.leases.Remove($Agent) }; Event $e 'release-lease' @{ agent = $Agent }; "[$e] lease of $Agent released" }
  'up' {   # -Owner: the owner's hold for -Minutes (120); else a hold that lives while its holder does
    if (-not $Services) { $st = Read-State $e; Prune $st; "[$e] up needs -Services <svc,..>. Leases need: $(@($st.leases.Keys | ForEach-Object { "$_ [$(@($st.leases[$_].services) -join ',')]" }) -join '; ')$(if (-not $st.leases.Count) { 'nothing' })"; exit 1 }
    $names = @(Closure $e $Services); $min = if ($Minutes) { $Minutes } else { 120 }; Wake-Deferred $e -UntilDone
    Update-State $e { param($x) $x.holds[$Agent] = @{ services = $names } + (New-KitLease $Agent $Session $(if ($Owner) { $min })); $x.suppress = $null }
    "[$e] holding $($names -join ', ') for $Agent $(if ($Owner) { "(owner) for $min min: unhold when done" } else { 'while it is live (board beat / step / pid): unhold when done' })"
    Ensure-Loop
    if (Wait-Up $names) { Show-Status $e } else { exit 1 }
  }
  'unhold' {   # ends a hold (-Services: only those); services stop when idle, never at once
    Update-State $e { param($x) if ($x.holds[$Agent]) { $left = @($x.holds[$Agent].services | Where-Object { $Services -and $_ -notin (Closure $e $Services) }); if ($left.Count) { $x.holds[$Agent].services = $left } else { $x.holds.Remove($Agent) } } }
    Event $e 'unhold' @{ agent = $Agent; services = @($Services) }; "[$e] hold of $Agent $(if ($Services) { "on $($Services -join ', ') " })removed: services stop after their idle grace"
  }
  'restart' {   # down would end leases and stop dependents: this stops -Services only; the controller restarts them
    if (-not $Services) { throw 'restart needs -Services <svc,..>' }
    $order = @(EnvServices $e | Where-Object { $_.name -in $Services -and (Managed $_) }); [array]::Reverse($order)
    foreach ($s in $order) { if (Healthy $e $s) { Stop-Svc $e $s 'restarted' }; "[$e] $($s.name) restarting$(if ((Read-State $e).services[$s.name].artifact) { " from $((Read-State $e).services[$s.name].artifact)" })" }
    Update-State $e { param($x) foreach ($s in $order) { Clear-StartBackoff $x.services[$s.name] 'restart asked' } }
    Event $e 'restart' @{ agent = $Agent; services = @($order.name) }
    $st = Read-State $e; Prune $st; $wanted = @(@($st.leases.Values) + @($st.holds.Values) | ForEach-Object { Closure $e @($_.services) })
    $idle = @($order.name | Where-Object { $_ -notin $wanted }); if ($idle.Count) { "[$e] no lease or hold needs $($idle -join ', '): down until the next use / up" }
    $back = @($order.name | Where-Object { $_ -in $wanted })
    if ($back.Count) { Ensure-Loop; if (Wait-Up $back) { Show-Status $e } else { exit 1 } }
  }
  'down' {
    $names = if ($Services) { @(@($Services) + @(Dependents $e $Services) | Select-Object -Unique) } else { All-Managed }
    $o = @{ lost = @() }
    Update-State $e { param($x)
      foreach ($a in @($x.holds.Keys)) { $x.holds[$a].services = @($x.holds[$a].services | Where-Object { $_ -notin $names }); if (-not $x.holds[$a].services.Count) { $x.holds.Remove($a) } }
      foreach ($a in @($x.leases.Keys)) { if (@($x.leases[$a].services | Where-Object { $_ -in $names }).Count) { $o.lost += $a; $x.leases.Remove($a) } }
      $x.suppress = @{ services = $names; until = (Get-KitStamp stored (Get-Date).AddMinutes(30)) }
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
  'task' {
    $t = (Get-KitMember (Get-EnvCfg $e).tasks $Task)
    if (-not $t) { throw "env $e has no task '$Task' ($(((Get-KitProps (Get-EnvCfg $e).tasks).Name) -join ', '))" }
    $rn = RepoOf $e $t; $key = "$Agent/task"; Wake-Deferred $e -UntilDone
    $until = (Get-Date).AddMinutes($Wait); $o = @{}
    while ($true) {
      Update-State $e { param($x) Prune $x; if ($rn -notin @($x.train.blockRepos)) { $x.leases[$key] = @{ services = @(); repos = @($rn); release = [int]$x.release.n; note = "task $Task" } + (New-KitLease $Agent $Session -ProcessId $PID); $o.ok = $true } }
      if ($o.ok) { break }
      if ((Get-Date) -gt $until) { "[$e] a train is changing $rn : run the task again later"; exit 3 }
      Start-Sleep 3
    }
    try {
      $r = (EnvRepos $e)[$rn]; if (-not (Test-Path (Join-Path $r.wt '.git'))) { throw "[$e] $rn has no env worktree yet: run envy.ps1 refresh -Env $e first" }
      Sync-DepLinks $e $r
      $sdir = SvcDir $e $t; $cmd = Expand-Placeholders ([string]$t.cmd) $e $t $sdir ''
      "[$e] task $Task in $sdir : $cmd"
      With-Env (EnvVars $e $t) {
        if ($t.gated) { & $KitCmd.dev gate -Dir $sdir -Cmd $cmd }
        else { Push-Location $sdir; try { if ($KitIsWindows) { $bat = Join-Path (Get-KitPath localenv -Create) "run/$e-task-$Task.cmd"; New-Item -ItemType Directory -Force (Split-Path $bat) | Out-Null; Set-Content -LiteralPath $bat "@echo off`r`n$cmd" -Encoding ascii; & cmd.exe /d /c "`"$bat`"" } else { & /bin/sh -c $cmd } } finally { Pop-Location } }
      }
      $code = $LASTEXITCODE
    } finally { Update-State $e { param($x) $x.leases.Remove($key) } }
    if ($code) { throw "[$e] task $Task failed (exit $code)" }
  }
  'migrations' {   # the migration layers live, or the tables -Branch's migrations touch (what its release mark slices)
    $envRepos = EnvRepos $e; $st = Read-State $e
    if ($Dir -and -not $Branch) { $Branch = "$(git -C (Resolve-Path @(Split-KitList $Dir -Sep ',')[0]).Path rev-parse --abbrev-ref HEAD)".Trim() }
    if (-not $Branch) { foreach ($rn in $st.release.repos.Keys) { foreach ($l in @(Layers $st $rn | Where-Object { $_.migrations })) { "[$e] $rn $($l.branch) ($($l.agent)) since release $($l.since): MIGRATIONS" } }; return }
    foreach ($r in $envRepos.Values) {
      $sha = Resolve-Ref $r.cfg.checkout $Branch; if (-not $sha -or -not (HasMigrations $r.cfg.checkout $r.target $sha)) { continue }
      $tm = Get-MigTouched $e $r.name "origin/$($r.target)" $sha
      "== $($r.name) ${Branch}: $(@($tm.items).Count) table(s) touched (via $($tm.via))$(if ($tm.unknown) { ' - none found: a restore past its DDL is refused' })"
      foreach ($i in @($tm.items)) { '   {0,-7} {1}{2}' -f $i.kind, $i.table, $(if (@($i.columns).Count) { " ($(@($i.columns) -join ', '))" }) }
    }
  }
  'sql' {   # read-only, through db.query (a db.engine preset or the env's hook); -Query schemaSizes = the engine's own query
    if ($Query -eq 'schemaSizes' -and (Get-DbEngine $e).sizes -is [scriptblock]) { & (Get-DbEngine $e).sizes @{ e = $e }; return }
    if ($Query -eq 'schemaSizes') { $Query = (Get-DbEngine $e).schemaSizes; if (-not $Query) { throw "engine $(Get-DbEngineName $e): no schemaSizes query (adapters/db-engines.ps1)" } }
    if (-not (Test-ReadOnlySql $Query)) { throw 'sql needs -Query with ONE read-only statement (select / show / explain / with ...)' }
    $err = Invoke-Hook $e 'query' @{ sql = $Query }; $script:HookOut; if ($err) { throw $err }
  }
  'dbtemp' {   # '<id> <temp GB> <seconds> <query>' per connection (storage.db.use); -Kill <id> ends one (storage.db.kill)
    if (-not (Get-Command Get-DbTempUse -ErrorAction SilentlyContinue) -or -not (Get-Command Test-DbTempUse -ErrorAction SilentlyContinue) -or -not (Test-DbTempUse $e)) { throw "[$e] dbtemp needs an engine with tempSql (adapters/db-engines.ps1)" }
    # storage.db.use polls a resting lane DB every tick (11 refused errors): no connections, no temp
    if (DbSvcDown $e) { "[$e] dbtemp: $((DbSvc $e).name) rests (starts with a lease): no temp"; return }
    # a DB port no managed service owns (base server, a stale port): a hint, never the client's raw ERROR 2003 (retro 2026-11-20, 3x)
    $dtCfg = (Get-EnvCfg $e).db; $dtLocal = -not $dtCfg.host -or "$($dtCfg.host)" -in '127.0.0.1', 'localhost', '::1'   # a remote db.host: the probe sees only this machine
    $dtPort = $dtCfg.port; if ($dtLocal -and $dtPort -and -not (Test-PortListening ([int]$dtPort))) { "[$e] dbtemp: nothing listens on the env DB port $dtPort (db.port): no temp. Start that MySQL (envy.ps1 status -Env $e names the services; up -Services <db> as owner) or fix db.port"; return }
    if ($Kill) { Stop-DbConn $e $Kill; Event $e 'db-kill' @{ id = $Kill; by = $Agent }; "[$e] db connection $Kill killed"; return }
    foreach ($q in @(Get-DbTempUse $e)) { '{0} {1} {2} {3}' -f $q.id, $q.gb.ToString([Globalization.CultureInfo]::InvariantCulture), $q.secs, (Protect-KitText $q.query) }
  }
  'logs' {
    if (-not $Services) {   # no -Service: localEnv.defaultService (when running), else the only service, else a usage line (never a crash)
      $sn = @(EnvServices $e | ForEach-Object name); $dsv = [string](Opt 'defaultService' ''); $Services = @(if ($dsv -and $dsv -in $sn) { $dsv } elseif ($sn.Count -eq 1) { $sn[0] })
      if (-not $Services) { "logs needs -Service: one of $($sn -join ', ') (envy.ps1 logs -Env $e -Service <name>)"; exit 2 }
    }
    Touch-Lease $e $Agent; $f = LogFile $e $Services[0]; if (Test-Path $f) { Read-LogTail $f $Tail $Grep $Since } else { "no log yet: $f" } }
  'events' { Touch-Lease $e $Agent; $ev = @(Read-KitLog env (Get-Date).AddDays(-30) | Where-Object env -eq $e | Select-Object -Last $Tail); if ($ev) { $ev | ForEach-Object { $_ | Select-Object * -ExcludeProperty stream | ConvertTo-Json -Compress } } else { 'no events yet' } }
  '_exec' {
    $s = Svc $e $Services[0]; $sdir = SvcDir $e $s; $log = LogFile $e $s.name
    $cmd = StartCmd $e $s $Artifact
    # its temp files (java.io.tmpdir, the embedded server's base dir) in one folder per service, emptied each start; env vars below win
    $stmp = Join-Path (Get-KitPath localenv -Create) "tmp/$e-$($s.name)"; if (-not ($s.port -and (Test-PortListening ([int]$s.port)))) { Remove-Item -LiteralPath $stmp -Recurse -Force -ErrorAction SilentlyContinue }   # a live instance keeps its files
    $env:TMP = $env:TEMP = $env:TMPDIR = (New-Item -ItemType Directory -Force $stmp).FullName   # arch-ok: kit temp
    Clear-EmptyEnv
    foreach ($kv in (EnvVars $e $s).GetEnumerator()) { Set-EnvVar $kv.Key $kv.Value }
    Set-Location $sdir
    Add-Content $log "== $(Now) start in $sdir : $cmd"
    # the output (stdout + stderr, merged by the shell) is copied byte for byte; past logMaxMB the log moves to .prev
    $si = if ($KitIsWindows) {
      $bat = Join-Path (Get-KitPath localenv -Create) "run/$e-$($s.name).cmd"; New-Item -ItemType Directory -Force (Split-Path $bat) | Out-Null
      Set-Content -LiteralPath $bat "@echo off`r`n($cmd`r`n) 2>&1" -Encoding ascii; [Diagnostics.ProcessStartInfo]::new('cmd.exe', "/d /c `"$bat`"")
    } else { $x = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $x.ArgumentList.Add('-c'); $x.ArgumentList.Add("{ $cmd`n} 2>&1"); $x }
    $si.UseShellExecute = $false; $si.RedirectStandardOutput = $true; $si.WorkingDirectory = $sdir
    $p = [Diagnostics.Process]::Start($si); $in = $p.StandardOutput.BaseStream; $buf = [byte[]]::new(65536); $cap = [long]([double]$(if ($s.logMaxMB) { $s.logMaxMB } else { $script:LogMaxMB }) * 1MB)
    $open = { [IO.FileStream]::new($log, 'Append', 'Write', 'ReadWrite, Delete') }; $out = & $open
    try {
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n); $out.Flush()
        if ($cap -gt 0 -and $out.Length -gt $cap) { $out.Dispose(); try { Move-Item -LiteralPath $log "$log.prev" -Force } catch { }; $out = & $open }   # a reader holding it: next time
      }
      $p.WaitForExit()
    } finally { $out.Dispose() }
    Add-Content $log "== $(Now) exited $($p.ExitCode)"
  }
}
}

if ($MyInvocation.InvocationName -eq '.') { }   # dot-sourced (tests): functions only
elseif ($__verb -eq '_daemon') { Invoke-KitVerb Invoke-Daemon @($__envyArgs | Select-Object -Skip 1) }
elseif (-not $__verb) { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit 2 }
else {   # usage errors exit 2; any other crash exits 1 (Invoke-KitVerb)
  $KitVerbOnError = { param($e) $m = "$($e.Exception.Message)"; if ($m -match 'unknown env|-Env needed|No local environments configured|needs -|marks lists the marks') { [Console]::Error.WriteLine("envy.ps1: $m"); exit 2 } }
  Invoke-KitVerb Invoke-LocalEnv @($__envyArgs) | ConvertTo-KitLaneOut (("-Json" -in $__envyArgs) -or $__verb -in "sql", "logs", "api", "events")   # shown lane names (K55); data verbs as they are
}
