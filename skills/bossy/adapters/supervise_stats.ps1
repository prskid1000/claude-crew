<#
supervise_stats.ps1 (core): the supervise page's history graphs from the logs the kit already writes, dot-sourced by bossy.ps1
(skills/bossy/adapters/): the build gate per kind (builds log), lease waits per resource (leases log, builds log, local-env
lease-wait events, live queues), test-run results per day (qa-runs results.json), CPU + RAM per lane process and the top other
processes (one process snapshot per sweep), flags per hour, agents shell progress (bossy.ps1 shells); their heatmap cards (shared cells, idle-row fold, card fold) and the
page drawer render inside Format-KitSuperviseHtml.
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L12 gate · L64 waits · L90 qa · L106 cpu · L141 writes (owner 2026-11-18 · L302 cards · L498 flags · L588 shells
#>
#Requires -Version 7
# ---- gate: the build gate per kind, 24 h
# the gate's card row of a build: kind (crafty.ps1 GateKinds) to a group; gate.labels { "<label>": "<kind regex>" } first, then the
# built-in stack presets' kinds, else the kind itself (presets only label: every kind that ran is its own row); a local env's build = env deploy
$script:KitGateBuiltinLabels = @(@('maven test', '^maven-test$'), @('maven build', '^maven$'), @('web build', '^(web-build|rn-bundle)$'), @('typecheck / lint', '^(typecheck|tsc-lint)$'),
  @('js tests', '^(js-test|ng-test)$'), @('python', '^python$'), @('cypress / e2e', '^(e2e|cypress)$'), @('docker', '^docker$'), @('android', '^(android-build|android-test|gradle)$'), @('emulator', '^emulator$'))
function Get-KitGateGroup([string]$Kind, [string]$Who) {
  if ($Who -match 'localenv-') { return 'env deploy' }
  if (-not $script:KitGateLabels) { $gl = Get-KitSetting 'gate.labels' $null; $script:KitGateLabels = @(@(if ($gl) { foreach ($p in (Get-KitProps $gl)) { if ($p.Name -notlike '_*' -and $p.Value) { , @($p.Name, "$($p.Value)") } } }) + $script:KitGateBuiltinLabels) }   # cached per process
  foreach ($l in $script:KitGateLabels) { if ($l[0] -and $Kind -match $l[1]) { return $l[0] } }
  if ("$Kind".Trim()) { "$Kind".Trim() } else { 'other' }
}
# minutes of [$S, $E] spread over the 24 clock hours from $H0 (index 0..23) -> & $Add <hour> <minutes>
function Split-KitHours([datetime]$H0, [datetime]$S, [datetime]$E, [scriptblock]$Add) {
  for ($hi = [math]::Max(0, [int][math]::Floor(($S - $H0).TotalHours)); $hi -le [math]::Min(23, [int][math]::Floor(($E - $H0).TotalHours)); $hi++) {
    $hs = $H0.AddHours($hi); $ov = ([datetime]::new([math]::Min($E.Ticks, $hs.AddHours(1).Ticks)) - [datetime]::new([math]::Max($S.Ticks, $hs.Ticks))).TotalMinutes; if ($ov -gt 0) { & $Add $hi $ov } }
}
# the gate from its builds log (24 h), not a sweep sample (one missed a build between sweeps):
# per group running / queued now, done today, avg / peak wait, RAM promised, an hourly heatmap (24 clock hours, the last = the current one:
# @(builds ended, busy min, max wait min) each, h0 = the first hour); phone lanes and emulators
# builds per owner (worktree or lane) from builds-log end lines, QA seat leases aside -> @{ name; n; min; failed }, most first
function Get-KitBuildsByOwner($Ends) {
  $by = [ordered]@{}
  foreach ($x in @($Ends | Where-Object { $_ -and $_.owner -and "$($_.project)" -notmatch '(^|[\\/])qa-seats$' })) {
    $o = "$($x.owner)"; if (-not $by.Contains($o)) { $by[$o] = [ordered]@{ name = $o; n = 0; min = 0.0; failed = 0 } }
    $by[$o].n++; $by[$o].min += [double]$x.sec / 60; if ([int]$x.code) { $by[$o].failed++ } }
  @($by.Values | ForEach-Object { [pscustomobject]@{ name = $_.name; n = $_.n; min = [math]::Round($_.min); failed = $_.failed } } | Sort-Object @{ Expression = 'n'; Descending = $true }, @{ Expression = 'min'; Descending = $true })
}
function Get-KitGateStats([datetime]$Now = (Get-Date), $Resources = @()) {
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $from = $h0; $led = Get-KitGateLedger; $rd = { param($f) try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
  $at = { param($v) if ($v -is [datetime]) { $v } else { try { [datetime]"$v" } catch { $null } } }
  $run = @(Get-ChildItem $led -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ -and $_.pid -and (Test-KitPid $_.pid $_.start) })
  $que = @(Get-ChildItem (Join-Path $led 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ })
  $ends = @(Read-KitLog builds $from | Where-Object { $_.event -eq 'end' -and (& $at $_.at) })
  $g = [ordered]@{}; $row = { param($n) if (-not $g.Contains($n)) { $g[$n] = [ordered]@{ name = $n; running = 0; queued = 0; done = 0; waits = [Collections.Generic.List[double]]::new(); ram = 0.0; peakGB = 0.0; hours = @(0..23 | ForEach-Object { , @(0, 0.0, 0.0) }) } }; $g[$n] }
  # busy minutes spread over the clock hours a build overlapped; its count and wait go to the hour it ended in
  $busy = { param($r, [datetime]$s1, [datetime]$e1) Split-KitHours $h0 $s1 $e1 { param($hi, $ov) $r.hours[$hi][1] += $ov } }
  foreach ($x in $ends) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $e1 = & $at $x.at; $s1 = $e1.AddSeconds(-[double]$x.sec); $wm = [double]$x.waitSec / 60
    if ($e1 -ge $Now.Date) { $r.done++; $r.waits.Add($wm) }; & $busy $r $s1 $e1; $hi = [int][math]::Floor(($e1 - $h0).TotalHours); if ($hi -ge 0 -and $hi -le 23) { $r.hours[$hi][0]++; $r.hours[$hi][2] = [math]::Max($r.hours[$hi][2], $wm) } }
  foreach ($x in @(Read-KitLog builds $Now.Date | Where-Object { $_.event -eq 'start' })) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $r.peakGB = [math]::Max($r.peakGB, [double]$x.needGB) }
  foreach ($x in $run) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.dir)"); $r.running++; $r.ram += [double]$x.need; $s1 = & $at $x.started; if ($s1) { & $busy $r $s1 $Now } }
  foreach ($x in $que) { (& $row (Get-KitGateGroup "$($x.kind)" "$($x.owner)")).queued++ }
  $rows = @($g.Values | ForEach-Object { [pscustomobject]@{ name = $_.name; running = $_.running; queued = $_.queued; done = $_.done; ram = [math]::Round($_.ram, 1); peakGB = [math]::Round($_.peakGB, 1)
        waitAvg = $(if ($_.waits.Count) { [math]::Round(($_.waits | Measure-Object -Average).Average, 1) } else { 0 }); waitMax = $(if ($_.waits.Count) { [math]::Round(($_.waits | Measure-Object -Maximum).Maximum, 1) } else { 0 })
        hours = @($_.hours | ForEach-Object { , @([int]$_[0], [math]::Round($_[1], 1), [math]::Round($_[2], 1)) }) } } | Sort-Object { - ($_.running * 1000 + $_.queued * 100 + $_.done) })
  $owners = @(Get-KitBuildsByOwner @($ends | Where-Object { (& $at $_.at) -ge $Now.Date }))
  $lanes = @(try { (Read-KitText (Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json') | ConvertFrom-Json).lanes } catch { })
  [pscustomobject]@{ h0 = $h0.ToString('o'); running = $run.Count; queued = $que.Count; today = [int](($rows | Measure-Object done -Sum).Sum); waitMax = [double](@($rows.waitMax) + 0 | Measure-Object -Maximum).Maximum
    ram = [math]::Round([double](($run | Measure-Object need -Sum).Sum), 1); rows = $rows; owners = $owners
    lanes = $lanes.Count; leased = @($lanes | Where-Object { $_.name -and (Test-Path (Join-Path (Get-KitPath phones) "$($_.name).json")) }).Count; emulators = @($Resources | Where-Object { "$($_.name)" -like 'phone *' }).Count
    browsers = @($Resources | Where-Object { "$($_.name)" -like 'browser *' }).Count; browserGB = [math]::Round([double](@($Resources | Where-Object { "$($_.name)" -like 'browser *' } | ForEach-Object { [double]$_.gb }) + 0 | Measure-Object -Sum).Sum, 1) }   # leases, never gated
}

# ---- waits: minutes agents waited for a lease, per resource and clock hour (24 h)
# sources: leases.jsonl acquire lines (since = when the caller began to wait: locks, browser tabs, phone lanes, GPU), builds log
# start waitSec (the gate), the local env's lease-wait events (a train waiting for holders), and the waits still open now;
# a row = @{ name; n; min; max; hours = 24 x @(waits ended, minutes waited, longest, who) }; waits under 30 s are no wait
function Get-KitLeaseWaits([datetime]$Now = (Get-Date)) {
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $rows = [ordered]@{}
  $add = { param([string]$res, $s, $e, [string]$who) if ($null -eq $s -or $null -eq $e) { return }; $s = [datetime]$s; $e = [datetime]$e; if (($e - $s).TotalMinutes -lt 0.5 -or $e -lt $h0) { return }
    if (-not $rows.Contains($res)) { $rows[$res] = [ordered]@{ name = $res; n = 0; min = 0.0; max = 0.0; hours = @(0..23 | ForEach-Object { , @(0, 0.0, 0.0, '') }) } }
    $r = $rows[$res]; $wm = ($e - $s).TotalMinutes; $r.n++; $r.min += $wm; $r.max = [math]::Max($r.max, $wm)
    Split-KitHours $h0 $s $e { param($hi, $ov) $r.hours[$hi][1] += $ov }
    $hi = [math]::Min(23, [int][math]::Floor(($e - $h0).TotalHours)); $c = $r.hours[$hi]; $c[0]++; $c[2] = [math]::Max($c[2], $wm); if ($who -and ", $($c[3])," -notlike "*, $who,*") { $c[3] = (@($c[3], $who) | Where-Object { $_ }) -join ', ' } }
  # only the lines that matter are parsed (env.jsonl holds every local-env event of the day)
  $grep = { param([string]$file, [string]$pat) if (Test-Path -LiteralPath $file) { Select-String -LiteralPath $file -SimpleMatch $pat | ForEach-Object { try { $_.Line | ConvertFrom-Json } catch { } } | Where-Object { $_.at -and [datetime]$_.at -ge $h0 } } }
  $days = @($h0.Date, $Now.Date | Select-Object -Unique | ForEach-Object { Join-Path (Get-KitPath audit) $_.ToString('yyyy-MM-dd') })
  foreach ($x in @(& $grep (Get-KitLogFile leases) '"event":"acquire"')) { if (-not $x.since -or "$($x.kind)" -in 'build', 'env', 'env-layer') { continue }
    $nm = switch ("$($x.kind)") { 'tab' { 'browser seats' } 'lane' { "phone $($x.name)" } default { "$($x.kind) $($x.name)" } }; & $add $nm $x.since $x.at "$($x.agent)" }
  foreach ($d in $days) {
    foreach ($x in @(& $grep (Join-Path $d 'builds.jsonl') '"event":"start"')) { if ([double]$x.waitSec -ge 30) { & $add 'build gate' ([datetime]$x.at).AddSeconds(-[double]$x.waitSec) $x.at "$($x.owner)" } }
    foreach ($x in @(& $grep (Join-Path $d 'env.jsonl') '"event":"lease-wait"')) { foreach ($sv in @($x.services)) { & $add "$($x.env) · $sv" ([datetime]$x.at).AddMinutes(-[double]$x.min) $x.at "train ($(@($x.holders) -join ', '))" } } }
  # still waiting: up to now (the gate queue, test locks, the phone queue)
  foreach ($q in @(Get-ChildItem (Join-Path (Get-KitGateLedger) 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } } | Where-Object { $_.since -and (Test-KitPid $_.pid $_.start) })) { & $add 'build gate' $q.since $Now "$($q.owner)" }
  foreach ($w in @(try { (Get-KitLockState).waiting } catch { })) { if ($w.at) { & $add "lock $($w.lock)" $w.at $Now "$($w.holder)" } }
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($Now - $_.LastWriteTime).TotalMinutes -lt 3 })) { $w = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }; & $add "phone $(if ($w.lane) { $w.lane } else { 'any lane' })" $w.since $Now "$($w.agent)" }
  [pscustomobject]@{ h0 = $h0.ToString('o'); rows = @($rows.Values | Sort-Object { - $_.min } | ForEach-Object { [pscustomobject]@{ name = $_.name; n = $_.n; min = [math]::Round($_.min, 1); max = [math]::Round($_.max, 1); hours = @($_.hours | ForEach-Object { , @([int]$_[0], [math]::Round($_[1], 1), [math]::Round($_[2], 1), "$($_[3])") }) } }) }
}

# ---- qa: checks per day from the QA runs' results.json (7 days): PASS / FAIL / NOT_TESTED / OUT_OF_SCOPE, NOT_TESTED causes, runs per day
$script:KitQaCauses = 'env-data', 'phone-only', 'tool-down', 'no-mail-sandbox', 'undeployed'   # testy.js CHECKS_SCHEMA cause; anything else: other
function Get-KitQaDays([datetime]$Now = (Get-Date), [int]$Days = 7) {
  $from = $Now.Date.AddDays(1 - $Days); $byDay = [ordered]@{}; foreach ($i in ($Days - 1)..0) { $byDay[$Now.Date.AddDays(-$i).ToString('yyyy-MM-dd')] = [ordered]@{} }
  $causes = [ordered]@{}; foreach ($c in @($script:KitQaCauses) + 'other') { $causes[$c] = 0 }
  # <qa-runs>/<run>/<item>/results.json, dated by its last write (a retest rewrites it)
  foreach ($f in @(Get-ChildItem (Get-KitPath qa-runs) -Filter 'results.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $from)) {
    $res = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }; $dk = $f.LastWriteTime.ToString('yyyy-MM-dd'); $run = Split-Path (Split-Path $f.DirectoryName) -Leaf
    if (-not $byDay.Contains($dk)) { continue }; if (-not $byDay[$dk].Contains($run)) { $byDay[$dk][$run] = [ordered]@{ run = $run; items = 0; pass = 0; fail = 0; nt = 0; oos = 0 } }
    $r = $byDay[$dk][$run]; $r.items++
    foreach ($c in @($res.checks | Where-Object { $_ })) { switch ("$($c.result)") { { $_ -like 'PASS*' } { $r.pass++ } 'FAIL' { $r.fail++ } 'OUT_OF_SCOPE' { $r.oos++ }
        'NOT_TESTED' { $r.nt++; $causes[$(if ("$($c.cause)" -in $script:KitQaCauses) { "$($c.cause)" } else { 'other' })]++ } } } }
  $sum = { param($rs, [string]$k) [int](@($rs | ForEach-Object { $_[$k] }) + 0 | Measure-Object -Sum).Sum }
  [pscustomobject]@{ days = @($byDay.Keys | ForEach-Object { $rs = @($byDay[$_].Values); [pscustomobject]@{ day = $_; pass = (& $sum $rs pass); fail = (& $sum $rs fail); nt = (& $sum $rs nt); oos = (& $sum $rs oos); runs = @($rs | ForEach-Object { [pscustomobject]$_ }) } }); causes = [pscustomobject]$causes }
}

# ---- cpu: CPU % of the machine per lane process (hook Get-KitCpuGroups*: @{ name; pid }, its process tree) and the top other
# processes, from the CPU seconds of one process snapshot per sweep (Get-KitSweepProcs) against the last one; 24 h of samples
# a sample = @{ at; s = seconds since the last; all = machine %; g = @{ <name> = % }; top = @(@{ n; pid; p; o = owner; c = command }) }
function Update-KitCpuStats($Prior, [datetime]$Now = (Get-Date), $Shells = @(), $Resources = @()) {
  $all0 = @(Get-KitSweepProcs | Where-Object { $null -ne $_.Cpu }); $idle = @($all0 | Where-Object { $_.Id -eq 0 -or $_.Name -match '^(System )?Idle' })[0]
  $procs = @($all0 | Where-Object { $_.Id -gt 0 -and $_.Name -notmatch '^(System )?Idle' })
  if (-not $procs.Count) { return $Prior }   # no CPU seconds on this platform
  $key = { param($p) "$($p.Id)|$(if ($p.Created) { try { ([datetime]$p.Created).Ticks } catch { '' } })" }
  $acc = [ordered]@{}; foreach ($p in $procs) { if ([double]$p.Cpu -ge 1) { $acc[(& $key $p)] = [math]::Round([double]$p.Cpu, 1) } }; if ($idle) { $acc.idle = [double]$idle.Cpu }
  $samples = @($Prior.samples | Where-Object { $_ -and [datetime]$_.at -ge $Now.AddDays(-1) -and [datetime]$_.at -lt $Now })
  $prevAt = try { [datetime]$Prior.at } catch { $null }; $dt = if ($prevAt) { ($Now - $prevAt).TotalSeconds } else { 0 }
  $groups = @(if (Get-Command Invoke-KitHooks -ErrorAction SilentlyContinue) { Invoke-KitHooks Get-KitCpuGroups })   # pid 0: configured, not running
  $svcNames = @($groups | Where-Object name | ForEach-Object { "$($_.name)" })
  # owner 2026-11-18: every resource with a process (browser, phone, build) gets CPU and RAM from the same tree sampling as a lane service
  $groups += @($Resources | Where-Object { $_ -and $_.name -and [int]$_.pid -gt 0 -and "$($_.name)" -notin $svcNames } | ForEach-Object { [pscustomobject]@{ name = "$($_.name)"; pid = [int]$_.pid } })
  if ($dt -ge 60 -and $dt -le 7200) {   # an older snapshot gives a long average: no sample
    $cores = [math]::Max(1, [Environment]::ProcessorCount); $pa = $Prior.acc; $pct = @{}; $byId = @{}; $kids = @{}
    foreach ($p in $procs) { $byId[$p.Id] = $p; if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[int]]::new() }; $kids[$p.ParentId].Add($p.Id)
      $was = if ($pa) { (Get-KitMember $pa "$(& $key $p)") }; $base = if ($null -ne $was) { [double]$was } elseif ($p.Created -and [datetime]$p.Created -gt $prevAt) { 0 } else { $null }
      if ($null -ne $base) { $v = 100 * ([double]$p.Cpu - $base) / $dt / $cores; if ($v -gt 0.05) { $pct[$p.Id] = $v } } }
    $tree = { param([int]$id) $seen = @{}; $todo = [Collections.Generic.Queue[int]]::new(); $todo.Enqueue($id); while ($todo.Count) { $i = $todo.Dequeue(); if ($seen.ContainsKey($i) -or -not $byId.ContainsKey($i)) { continue }; $seen[$i] = 1; foreach ($c in @($kids[$i])) { if ($c -ne $i) { $todo.Enqueue($c) } } }; @($seen.Keys) }
    $inG = @{}; $g = [ordered]@{}; $m = [ordered]@{}   # m: RAM GB of each group's tree (working set), sampled each sweep like its CPU
    foreach ($gr in @($groups | Where-Object { $_.name -and $_.pid })) { $ids = & $tree ([int]$gr.pid); foreach ($i in $ids) { $inG[$i] = 1 }; $g["$($gr.name)"] = [math]::Round([double](@($ids | ForEach-Object { $pct[$_] }) + 0 | Measure-Object -Sum).Sum, 1)
      $m["$($gr.name)"] = [math]::Round([double](@($ids | ForEach-Object { [double]$byId[$_].WorkingSet }) + 0 | Measure-Object -Sum).Sum / 1GB, 2) }
    $sh = @{}; foreach ($s in @($Shells | Where-Object { $_.pid })) { $sh[[int]$s.pid] = "$($s.owner)" }
    $owner = { param([int]$id) for ($n = 0; $n -lt 12 -and $byId.ContainsKey($id); $n++) { if ($sh.ContainsKey($id) -and $sh[$id]) { return $sh[$id] }; $id = $byId[$id].ParentId }; '' }
    $top = @($pct.Keys | Where-Object { -not $inG.ContainsKey($_) -and $pct[$_] -ge 10 } | Sort-Object { - $pct[$_] } | Select-Object -First 5 | ForEach-Object { $p = $byId[$_]   # TODO-PARAM (fixed default: 10% of the machine)
        [ordered]@{ n = "$($p.Name)"; pid = $p.Id; p = [math]::Round($pct[$_], 1); o = (& $owner $p.Id); c = $(if ($p.CommandLine) { $one = Protect-KitText ("$($p.CommandLine)" -replace '\s+', ' '); $one.Substring(0, [math]::Min(160, $one.Length)) } else { '' }) } })
    # the machine from idle time (a build that came and went between sweeps counts too); no idle process: the sum
    $all = if ($idle -and $null -ne $pa.idle) { [math]::Max(0.0, [math]::Min(100.0, 100 - 100 * ([double]$idle.Cpu - [double]$pa.idle) / $dt / $cores)) } else { [double](@($pct.Values) + 0 | Measure-Object -Sum).Sum }
    $samples += [ordered]@{ at = $Now.ToString('o'); s = [int]$dt; all = [math]::Round($all, 1); g = $g; m = $m; top = $top }
  }
  [ordered]@{ at = $Now.ToString('o'); acc = $acc; samples = $samples; svc = @($svcNames | Select-Object -Unique) }   # svc: every configured service, up or not (its row stays)
}

# ---- writes (owner 2026-11-18: no work that writes huge data): bytes written per process (Windows I/O counters) since the last
# beat, summed per owner over the last hour; owner = the nearest ancestor that is a held resource, an agent's shell or a lane service
# (kit-owned), else the tree's root under the OS, named by its heaviest writer (wrappers fold: timeout -> mysqld). A pid seen before
# counts its growth, one started since the last beat all of it, an older unseen one nothing (no history spike); an exited one drops out.
# writes.softGBPerHour -> WATCH, writes.hardGBPerHour -> ACT; closed clock hours -> state disk-writes (the card's 7 and 30 days)
function Get-KitWriteProcs {   # the sweep's processes + Write (bytes); none off Windows
  if (-not $KitIsWindows) { return @() }
  $wb = @{}; foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, WriteTransferCount -ErrorAction SilentlyContinue)) { $wb[[int]$c.ProcessId] = [double]$c.WriteTransferCount }
  @(Get-KitSweepProcs | Where-Object { $wb.ContainsKey($_.Id) } | ForEach-Object { $_ | Add-Member -Force -NotePropertyName Write -NotePropertyValue $wb[$_.Id] -PassThru })
}
# a process's short label (the full command stays in the tooltip): a browser with its CDP port, a DB server with its data folder,
# a runtime with its script, jar, main class or npx package, else the name without .exe
function Get-KitWriteLabel([string]$Name, [string]$Cmd) {
  $b = if ($Cmd -match '^(?:"(?:[^"]*[\\/])?(?<x>[^"\\/]+?)(?:\.exe)?"|(?:\S*[\\/])?(?<x>[^\s\\/]+?)(?:\.exe)?(?:\s|$))') { $Matches.x } else { $Name -replace '(?i)\.exe$' }   # a wrapper's row carries its child's command
  $leaf = { param([string]$p) @("$p".Trim('"', "'") -split '[\\/]' | Where-Object { $_ }) }
  $nice = @{ msedge = 'Edge'; chrome = 'Chrome'; brave = 'Brave'; firefox = 'Firefox'; slack = 'Slack'; code = 'VS Code'; 'ms-teams' = 'Teams'; onedrive = 'OneDrive' }
  $nm = if ($nice[$b.ToLower()]) { $nice[$b.ToLower()] } else { $b }
  if ($Cmd -match '--remote-debugging-port=(\d+)') { return "$nm (CDP $($Matches[1]))" }
  if ($Cmd -match '--datadir[= ](?:"(?<d>[^"]+)"|(?<d>\S+))') { $ps = & $leaf $Matches.d; $lf = if ($ps.Count -gt 1 -and $ps[-1] -match '^(data|datadir|db|my|mysql|pg|pgdata)$') { $ps[-2] } else { $ps[-1] }; return "$nm · $lf" }
  if ($Cmd -match 'np[mx]-cli\.js"?\s+(?:-\S+\s+)*(?:run\s+)?(?<p>[^\s"-]\S*)') { return "$(if ($Cmd.Contains('npx-cli')) { 'npx' } else { 'npm' }) · $($Matches.p)" }
  if ($b -notmatch '^(node|python\d*|pythonw|py|pwsh|powershell|bash|sh|cmd|java|javaw|dotnet|ruby|php)$') { return $nm }
  if ($Cmd -match '-jar\s+(?:"(?<j>[^"]+)"|(?<j>\S+))') { return "$nm · $((& $leaf $Matches.j)[-1] -replace '\.jar$')" }
  if ($Cmd -match '(?<s>[^\s"\\/]+\.(?:m?js|cjs|ts|py|ps1|sh|rb|php|dll))\b') { return "$nm · $($Matches.s)" }
  if ($Cmd -match '\s-m\s+(?<m>[\w.]+)') { return "$nm · $($Matches.m)" }
  if ($Cmd -cmatch '\s(?:[a-z_]\w*\.)+(?<c>[A-Z]\w*)(\s|$)') { return "$nm · $($Matches.c)" }
  $nm
}
# $Procs: @{ Id; ParentId; Name; CommandLine; Created; Write }; $Owners: @{ pid; label; tag } roots; -> @{ at; acc; samples; hour; flags }
# a sample = @{ at; s = seconds; m = machine GB; w = @(@{ n = label; a = tag (agent); g = GB; c = top command; k = 1: kit-owned }) }
function Update-KitWriteStats($Prior, [datetime]$Now, $Procs, $Owners = @()) {
  $key = { param($p) "$($p.Id)|$(if ($p.Created) { ([datetime]$p.Created).ToUniversalTime().Ticks })" }
  $osRoot = '^(System|Idle|smss|csrss|wininit|winlogon|services|svchost|explorer|userinit|init|systemd|launchd)(\.exe)?$'
  $byId = @{}; $acc = [ordered]@{}; foreach ($p in @($Procs | Where-Object { $_ -and $null -ne $_.Write })) { $byId[[int]$p.Id] = $p; $acc[(& $key $p)] = [double]$p.Write }
  $own = @{}; foreach ($o in @($Owners | Where-Object { $_ -and [int]$_.pid -gt 0 -and $_.label })) { if (-not $own.ContainsKey([int]$o.pid)) { $own[[int]$o.pid] = $o } }
  $ownerOf = { param($p) $q = $p
    for ($n = 0; $n -lt 16; $n++) { if ($own.ContainsKey([int]$q.Id)) { return $own[[int]$q.Id] }
      $up = $byId[[int]$q.ParentId]; if (-not $up -or $up.Id -eq $q.Id -or "$($up.Name)" -match $osRoot -or ($up.Created -and $q.Created -and [datetime]$up.Created -gt [datetime]$q.Created)) { break }; $q = $up }
    "pid $($q.Id)" }   # a reused parent id starts after its child: the tree stops there
  $samples = @($Prior.samples | Where-Object { $_ -and [datetime]$_.at -ge $Now.AddDays(-1) -and [datetime]$_.at -lt $Now })
  $prevAt = try { [datetime]$Prior.at } catch { $null }; $dt = if ($prevAt) { ($Now - $prevAt).TotalSeconds } else { 0 }
  if ($dt -gt 0 -and $dt -le 7200) {   # an older snapshot: no sample (its deltas span hours)
    $gb = @{}; $top = @{}; $mach = 0.0
    foreach ($p in $byId.Values) { if ([int]$p.Id -le 4) { continue }   # Idle / System: the cache flush of every process again
      $was = Get-KitMember $Prior.acc (& $key $p)
      $d = if ($null -ne $was) { [double]$p.Write - [double]$was } elseif ($p.Created -and [datetime]$p.Created -gt $prevAt) { [double]$p.Write } else { 0 }
      if ($d -le 0) { continue }
      $mach += $d / 1GB; $ow = & $ownerOf $p; $ok = if ($ow -is [string]) { $ow } else { "kit $($ow.pid)" }; $gb[$ok] = [double]$gb[$ok] + $d / 1GB
      if (-not $top[$ok] -or $d -gt $top[$ok].b) { $top[$ok] = @{ b = $d; p = $p; o = $ow } } }
    # one row per label: two shells of one agent, or a wrapper's tree and its server's, are one owner
    $rw = [ordered]@{}
    foreach ($ok in $gb.Keys) { $t = $top[$ok]; $cl = Protect-KitText ("$(if ($t.p.CommandLine) { $t.p.CommandLine } else { $t.p.Name })" -replace '\s+', ' ')
      $kit = $t.o -isnot [string]; $lb = if ($kit) { "$($t.o.label)" } else { Get-KitWriteLabel "$($t.p.Name)" $cl }
      if (-not $rw.Contains($lb)) { $rw[$lb] = @{ a = $(if ($kit) { "$($t.o.tag)" } else { '' }); g = 0.0; b = 0.0; c = ''; k = [int]$kit } }
      $r = $rw[$lb]; $r.g += $gb[$ok]; if ($t.b -gt $r.b) { $r.b = $t.b; $r.c = $cl.Substring(0, [math]::Min(120, $cl.Length)) } }
    $samples += [ordered]@{ at = $Now.ToString('o'); s = [int]$dt; m = [math]::Round($mach, 3); w = @($rw.Keys | Where-Object { $rw[$_].g -ge 0.001 } | ForEach-Object { [ordered]@{ n = "$_"; a = $rw[$_].a; g = [math]::Round($rw[$_].g, 3); c = $rw[$_].c; k = $rw[$_].k } }) }
  }
  $hr = @{}; $last = @{}
  foreach ($s in @($samples | Where-Object { [datetime]$_.at -gt $Now.AddHours(-1) })) { foreach ($r in @(Get-KitWriteRows $s)) { $hr["$($r.n)"] = [double]$hr["$($r.n)"] + [double]$r.g; $last["$($r.n)"] = $r } }
  $hour = @($hr.Keys | Sort-Object { - $hr[$_] } | ForEach-Object { [ordered]@{ label = $_; tag = "$($last[$_].a)"; gb = [math]::Round($hr[$_], 2); cmd = "$($last[$_].c)" } })
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  # a burst that is over (no write in the last 2 samples: exited or stopped) leaves the flags, the card keeps its hour
  $nowS = @($samples | Where-Object { "$($_.at)" -eq $Now.ToString('o') })[0]; $cur = @($samples | Select-Object -Last 2 | ForEach-Object { Get-KitWriteRows $_ } | ForEach-Object { "$($_.n)" })
  $flags = @(foreach ($h in @($hour | Where-Object { $_.gb -ge $soft -and (-not $nowS -or $_.label -in $cur) })) { $lv = if ($h.gb -ge $hard) { 'ACT' } else { 'WATCH' }; $who = "$($h.label)$(if ($h.tag) { " ($($h.tag))" })"
      [pscustomobject]@{ level = $lv; kind = 'WRITES'; who = $who; what = "WRITES ${who}: $($h.gb) GB written in the last hour (soft $soft / hard $hard GB); top: $(Get-KitWriteLabel '' $h.cmd)" -replace "; top: $([regex]::Escape($h.label))$"
        action = "$(if ($lv -eq 'ACT') { 'Check whether it is a one-off (a burst already over, a false positive) before acting; still writing: stop it, then ' })tell its owner: no bulk data, dumps, tree copies, reinstalls or big captures (AGENTS.md); links / moves, small fixtures, read-only checks." } })
  [ordered]@{ at = $Now.ToString('o'); acc = $acc; samples = $samples; hour = $hour; flags = $flags }
}
# supervise hook: the owners from this sweep (resources, shells, lane services); <runtime>/cache/supervise-writes.json between beats
function Get-KitSuperviseFlagsWrites([switch]$AutoFix) {
  $cf = Join-Path (Get-KitPath cache -Create) 'supervise-writes.json'
  if (-not $KitIsWindows) { if (-not (Test-Path -LiteralPath $cf)) { Set-Content -LiteralPath $cf '{}'; [pscustomobject]@{ info = 'disk writes per agent: no per-process I/O counters on this OS (Windows only)' } }; return }
  $prior = try { Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json } catch { $null }
  # label = the resource, tag = its holder agent (no branch); a shell: the agent, tag shell
  # Get-Variable -ValueOnly writes the array as one object: unrolled, or every resource was one owner with all their names and holders
  $owners = @(Get-Variable res -ValueOnly -ErrorAction SilentlyContinue | ForEach-Object { $_ } | Where-Object { $_ -and $_.pid } | ForEach-Object { $r = $_; foreach ($p in @($r.pid)) { @{ pid = [int]$p; label = "$($r.name)"; tag = $(if ("$($r.by)" -notmatch '^(no lease|free|parked)') { ("$($r.by)" -replace '\s*\(.*$').Trim() }) } } }) +
    @(@($script:KitShellRows) | Where-Object { $_ -and $_.pid } | ForEach-Object { $r = $_; foreach ($p in @($r.pid)) { @{ pid = [int]$p; label = "$(if ($r.owner) { $r.owner } else { 'unknown agent' })"; tag = 'shell' } } }) +
    @(@(Invoke-KitHooks Get-KitCpuGroups) | Where-Object { $_ -and $_.pid } | ForEach-Object { $r = $_; foreach ($p in @($r.pid)) { @{ pid = [int]$p; label = "lane $($r.name)"; tag = '' } } })
  $now = Get-Date; $w = Update-KitWriteStats $prior $now @(Get-KitWriteProcs) $owners
  Write-KitAtomic $cf ([ordered]@{ at = $w.at; acc = $w.acc; samples = $w.samples; hour = $w.hour } | ConvertTo-Json -Depth 6 -Compress)
  try { Update-KitWriteHistory (Get-KitPath disk-writes) $w.samples $now } catch { }   # the card's 7 / 30 days; a failed append costs one hour
  $w.flags
}
# a sample's owner rows; a row from before 2026-11-19 (no k): "<proc> pid N" -> its short label, "<agent> shell", "<holder> (<resource>)" -> kit-owned
function Get-KitWriteRows($S) {
  @($S.w | Where-Object { $_ } | ForEach-Object { $n0 = "$($_.n)"; $a0 = "$($_.a)"; $k0 = [int]$_.k
      if ($null -eq $_.k) { $k0 = 1; if ($n0 -match '^(?<p>\S+) pid \d+$') { $n0 = Get-KitWriteLabel $Matches.p "$($_.c)"; $k0 = 0 } elseif ($n0 -match '^(?<a>.+) shell$') { $n0 = $Matches.a; $a0 = 'shell' }
        elseif ($n0 -match '^(?<a>[^()]*?)\s*\((?<r>[^()]+)\)$') { $n0 = $Matches.r; $a0 = (($Matches.a -split ',')[0]).Trim() } else { $n0 = 'kit resources' } }   # several holders in one label: the old join bug
      [pscustomobject]@{ n = $n0; a = $a0; g = [double]$_.g; c = "$($_.c)"; k = $k0 } })
}
# a sample's GB spread over the clock hours it spans ([at - s, at], by overlap) -> $Into[yyyyMMddHH] = @{ m; k; o = @{ label = GB }; t = @{ label = tag } }
function Add-KitWriteHours($Samples, [hashtable]$Into) {
  foreach ($s in @($Samples | Where-Object { $_ -and $_.at })) { $e1 = [datetime]$s.at; $s1 = $e1.AddSeconds(-[math]::Max(1.0, [double]$s.s)); $span = ($e1 - $s1).TotalSeconds
    $ws = @(Get-KitWriteRows $s); $m = if ($null -ne $s.m) { [double]$s.m } else { [double](@($ws | ForEach-Object { [double]$_.g }) + 0 | Measure-Object -Sum).Sum }
    $kg = [double](@($ws | Where-Object { [int]$_.k } | ForEach-Object { [double]$_.g }) + 0 | Measure-Object -Sum).Sum
    for ($h = $s1.Date.AddHours($s1.Hour); $h -lt $e1; $h = $h.AddHours(1)) { $f = ([datetime]::new([math]::Min($e1.Ticks, $h.AddHours(1).Ticks)) - [datetime]::new([math]::Max($s1.Ticks, $h.Ticks))).TotalSeconds / $span
      if ($f -le 0) { continue }; $hk = $h.ToString('yyyyMMddHH'); if (-not $Into.ContainsKey($hk)) { $Into[$hk] = @{ m = 0.0; k = 0.0; o = @{}; t = @{} } }
      $bk = $Into[$hk]; $bk.m += $m * $f; $bk.k += $kg * $f; foreach ($r in $ws) { $bk.o["$($r.n)"] = [double]$bk.o["$($r.n)"] + [double]$r.g * $f; if ("$($r.a)") { $bk.t["$($r.n)"] = "$($r.a)" } } } }
}
# { label: GB } of a parsed row (an object) or a new one (a dictionary) -> @{ Name; Value }
function Get-KitWritePairs($O) { if ($O -is [Collections.IDictionary]) { @($O.Keys | ForEach-Object { [pscustomobject]@{ Name = "$_"; Value = $O[$_] } }) } else { @(Get-KitProps $O) } }
# a history row: at, m = machine GB, k = kit-owned GB, o = its top owners ({ label: GB }, 10 MB+); d = 1: a whole day
function ConvertTo-KitWriteRow([datetime]$At, $Bucket, [int]$Top = 6, [switch]$Day) {
  $o = [ordered]@{}; foreach ($nm in @($Bucket.o.Keys | Where-Object { [double]$Bucket.o[$_] -ge 0.01 } | Sort-Object { - [double]$Bucket.o[$_] } | Select-Object -First $Top)) { $o[$nm] = [math]::Round([double]$Bucket.o[$nm], 2) }
  $r = [ordered]@{ at = ([datetimeoffset]$At).ToString('o') }; if ($Day) { $r.d = 1 }; $r.m = [math]::Round([double]$Bucket.m, 3); $r.k = [math]::Round([double]$Bucket.k, 3); $r.o = $o; $r
}
# history rows -> hour rows of the last 7 days kept, older ones one day row per date (top 8), days over 35 dropped (a few KB)
function Compress-KitWriteRows($Rows, [datetime]$Now) {
  $cut = $Now.Date.AddDays(-7); $drop = $Now.Date.AddDays(-35); $days = [ordered]@{}; $keep = [Collections.Generic.List[object]]::new()
  foreach ($r in @($Rows | Where-Object { $_ -and $_.at } | Sort-Object { [datetime]$_.at })) { $t = [datetime]$r.at; if ($t -lt $drop) { continue }
    if (-not $r.d -and $t -ge $cut) { $keep.Add($r); continue }
    $dk = $t.Date; if (-not $days.Contains($dk)) { $days[$dk] = @{ m = 0.0; k = 0.0; o = @{} } }; $bk = $days[$dk]; $bk.m += [double]$r.m; $bk.k += [double]$r.k
    foreach ($p in @(Get-KitWritePairs $r.o)) { $bk.o[$p.Name] = [double]$bk.o[$p.Name] + [double]$p.Value } }
  @($days.Keys | ForEach-Object { ConvertTo-KitWriteRow $_ $days[$_] 8 -Day }) + @($keep)
}
# closed clock hours since the file's last row -> one line each; the first append of a new day also compacts the file
function Update-KitWriteHistory([string]$File, $Samples, [datetime]$Now) {
  $last = if (Test-Path -LiteralPath $File) { try { Get-Content -LiteralPath $File -Tail 1 | ConvertFrom-Json } catch { $null } }
  $lastAt = if ($last.at) { [datetime]$last.at } else { [datetime]::MinValue }; $cur = $Now.Date.AddHours($Now.Hour); $hs = @{}; Add-KitWriteHours $Samples $hs
  $new = @($hs.Keys | Sort-Object | ForEach-Object { $h = [datetime]::ParseExact($_, 'yyyyMMddHH', [cultureinfo]::InvariantCulture); if ($h -lt $cur -and $h -gt $lastAt) { ConvertTo-KitWriteRow $h $hs[$_] } })
  if (-not $new.Count) { return }
  $line = { param($r) $r | ConvertTo-Json -Depth 4 -Compress }
  if ($last -and $lastAt.Date -ne $Now.Date) { $all = @(Get-Content -LiteralPath $File | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) + $new
    Write-KitAtomic $File ((@(Compress-KitWriteRows $all $Now | ForEach-Object { & $line $_ }) -join "`n") + "`n") }
  else { $null = New-Item -ItemType Directory -Force (Split-Path $File); Add-Content -LiteralPath $File -Value @($new | ForEach-Object { & $line $_ }) }
}
# the card's numbers: 24 clock hours per owner (the top $Top by 7-day total, the rest one "others" row) under the whole machine and its
# kit-owned share; 7 days x 24 h of the machine (kit share apart); a row's now (last 60 min) / peak / avg GB an hour, today, 7 and 30 days
function Get-KitWriteView($Samples, $Hist, [datetime]$Now, [int]$Top = 8) {
  $live = @{}; Add-KitWriteHours $Samples $live; $hm = @{}; $dm = @{}
  $add = { param($tbl, $k0, $bk) if (-not $tbl.ContainsKey($k0)) { $tbl[$k0] = @{ m = 0.0; k = 0.0; o = @{} } }; $x = $tbl[$k0]; $x.m += [double]$bk.m; $x.k += [double]$bk.k; foreach ($nm in @($bk.o.Keys)) { $x.o[$nm] = [double]$x.o[$nm] + [double]$bk.o[$nm] } }
  foreach ($r in @($Hist | Where-Object { $_ -and $_.at })) { $t = [datetime]$r.at; $o = @{}; foreach ($p in @(Get-KitWritePairs $r.o)) { $o[$p.Name] = [double]$p.Value }; $bk = @{ m = [double]$r.m; k = [double]$r.k; o = $o }
    if ($r.d) { & $add $dm $t.ToString('yyyy-MM-dd') $bk } else { $hm[$t.ToString('yyyyMMddHH')] = $bk } }
  foreach ($hk in $live.Keys) { if (-not $hm.ContainsKey($hk)) { $hm[$hk] = $live[$hk] } }   # history wins for the hours it closed
  foreach ($hk in $hm.Keys) { & $add $dm "$($hk.Substring(0, 4))-$($hk.Substring(4, 2))-$($hk.Substring(6, 2))" $hm[$hk] }
  $tags = @{}; foreach ($hk in @($live.Keys | Sort-Object)) { foreach ($nm in $live[$hk].t.Keys) { $tags[$nm] = $live[$hk].t[$nm] } }
  $cmds = @{}; $now60 = @{ '*m' = 0.0; '*k' = 0.0 }
  foreach ($s in @($Samples | Where-Object { $_ -and $_.at })) { $ws = @(Get-KitWriteRows $s); foreach ($r in $ws) { $cmds["$($r.n)"] = "$($r.c)" }
    if ([datetime]$s.at -gt $Now.AddHours(-1)) { $now60['*m'] += $(if ($null -ne $s.m) { [double]$s.m } else { [double](@($ws | ForEach-Object { [double]$_.g }) + 0 | Measure-Object -Sum).Sum })
      foreach ($r in $ws) { $now60["$($r.n)"] = [double]$now60["$($r.n)"] + [double]$r.g; if ([int]$r.k) { $now60['*k'] += [double]$r.g } } } }
  $val = { param($bk, [string]$nm) if (-not $bk) { 0.0 } elseif ($nm -eq '*m') { [double]$bk.m } elseif ($nm -eq '*k') { [double]$bk.k } else { [double]$bk.o[$nm] } }
  $sumD = { param([string]$nm, [int]$n) $v = 0.0; for ($i = 0; $i -lt $n; $i++) { $v += & $val $dm[$Now.Date.AddDays(-$i).ToString('yyyy-MM-dd')] $nm }; $v }
  $names = @($dm.Keys | Where-Object { [datetime]$_ -gt $Now.Date.AddDays(-7) } | ForEach-Object { $dm[$_].o.Keys } | Select-Object -Unique)
  $tops = @($names | Sort-Object { - (& $sumD $_ 7) }, { "$_" } | Select-Object -First $Top)
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $hk24 = @(0..23 | ForEach-Object { $h0.AddHours($_).ToString('yyyyMMddHH') })
  $mk = { param([string]$label, [string]$nm, [string]$tag, $hours, $now, $d1, $d7, $d30) $hs0 = @($hours | ForEach-Object { [math]::Round([math]::Max(0.0, [double]$_), 3) })
    [ordered]@{ n = $label; a = $tag; c = "$($cmds[$nm])"; h = $hs0; now = [math]::Round([math]::Max(0.0, [double]$now), 3); peak = [double]($hs0 + 0 | Measure-Object -Maximum).Maximum
      avg = [math]::Round([double]($hs0 | Measure-Object -Sum).Sum / 24, 3); day = [math]::Round([math]::Max(0.0, $d1), 2); d7 = [math]::Round([math]::Max(0.0, $d7), 2); d30 = [math]::Round([math]::Max(0.0, $d30), 2) } }
  $line = { param([string]$nm) , @($hk24 | ForEach-Object { & $val $hm[$_] $nm }) }
  $rows = @((& $mk 'whole machine' '*m' '' (& $line '*m') $now60['*m'] (& $sumD '*m' 1) (& $sumD '*m' 7) (& $sumD '*m' 30)),
    (& $mk 'kit-owned' '*k' 'resources · shells · lanes' (& $line '*k') $now60['*k'] (& $sumD '*k' 1) (& $sumD '*k' 7) (& $sumD '*k' 30)))
  $rows += @($tops | ForEach-Object { & $mk $_ $_ "$($tags[$_])" (& $line $_) $now60[$_] (& $sumD $_ 1) (& $sumD $_ 7) (& $sumD $_ 30) })
  # others = the machine minus the shown owners, per hour and per total
  $rest = { param($tot, [scriptblock]$part) $tot - [double](@($tops | ForEach-Object { & $part $_ }) + 0 | Measure-Object -Sum).Sum }
  $oh = @(for ($i = 0; $i -lt 24; $i++) { $bk = $hm[$hk24[$i]]; & $rest (& $val $bk '*m') { param($nm) & $val $bk $nm } })
  if ($tops.Count) { $rows += & $mk 'others' '' '' $oh (& $rest $now60['*m'] { param($nm) [double]$now60[$nm] }) (& $rest (& $sumD '*m' 1) { param($nm) & $sumD $nm 1 }) (& $rest (& $sumD '*m' 7) { param($nm) & $sumD $nm 7 }) (& $rest (& $sumD '*m' 30) { param($nm) & $sumD $nm 30 }) }
  $days = @(for ($i = 0; $i -lt 7; $i++) { $d0 = $Now.Date.AddDays(-$i); $hp = @(0..23 | ForEach-Object { $bk = $hm[$d0.AddHours($_).ToString('yyyyMMddHH')]; , @([math]::Round((& $val $bk '*m'), 3), [math]::Round((& $val $bk '*k'), 3)) })
      [ordered]@{ d = $d0.ToString('yyyy-MM-dd'); h = $hp; m = [math]::Round((& $val $dm[$d0.ToString('yyyy-MM-dd')] '*m'), 2); k = [math]::Round((& $val $dm[$d0.ToString('yyyy-MM-dd')] '*k'), 2) } })
  $byName = @($names | Where-Object { $_ -notin $tops } | ForEach-Object { & $mk $_ $_ "$($tags[$_])" (& $line $_) $now60[$_] (& $sumD $_ 1) (& $sumD $_ 7) (& $sumD $_ 30) })   # the Writes metric of Resources · 24 h: every owner, not only the top
  [ordered]@{ at = $Now.ToString('o'); h0 = $h0.ToString('o'); rows = $rows; more = $byName; days = $days }
}

# ---- cards: render inside Format-KitSuperviseHtml and use its helpers ($e, $n1, $fmt, $icv, $spark, $dots, $nowCard, $at, $st, $nw, $j, $l24, $fold)
# every heatmap: Format-KitHourHead over a row of Format-KitHeatCells each, rows through Format-KitHeatRows (idle rows folded), the card
# through $fold (chevron + count, open state kept; busy open, idle closed)
# the 24 hour labels over a heatmap: every 6th clock hour, "now" over the last cell; -Clock: a calendar day (00-23), no "now"
function Format-KitHourHead([datetime]$H0, [switch]$Clock) { @(for ($hi = 0; $hi -lt $(if ($Clock) { 23 } else { 21 }); $hi++) { if ($H0.AddHours($hi).Hour % 6 -eq 0) { "<b style='grid-column:$($hi + 1)/span 2'>$($H0.AddHours($hi).ToString('HH'))</b>" } }) + $(if (-not $Clock) { "<b class=nw style='grid-column:23/span 2'>now</b>" }) -join '' }
# Disk writes · 7 days (owner 2026-11-19; Get-KitWriteView days): 7 days x 24 clock hours, the whole machine (top half) over its
# kit-owned share (bottom half); per day: GB, kit GB, the busiest hour. The 24 h per owner is the Writes metric of Resources · 24 h
function Format-KitWritesCard($W) {
  $ds = @($W.days | Where-Object { $_ }); if (-not $ds.Count) { return '' }
  $hard = [double](Get-KitParam 'writes.hardGBPerHour'); $ic = [cultureinfo]::InvariantCulture
  $gv = { param($v) $d = [double]$v; if ($d -le 0) { '0' } elseif ($d -lt 0.095) { $d.ToString('0.00', $ic) } else { & $n1 $d } }
  $gbT = { param($v) $d = [double]$v; if ($d -lt 1) { "$([math]::Round($d * 1024)) MB" } else { "$(& $n1 $d) GB" } }
  $scD = [math]::Max($hard, [double](@($ds | ForEach-Object { @($_.h) | ForEach-Object { [double]@($_)[0] } }) + 0 | Measure-Object -Maximum).Maximum)
  $dHead = "<div class='gk gh'><span class=gn>day · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead ([datetime]$ds[0].d) -Clock)</span><span class=gc title='GB the machine wrote that day'><small>day</small></span><span class=gc title='GB kit-owned processes wrote that day'><small>kit</small></span><span class=gc title='most GB in one hour that day'><small>peak</small></span></div>"
  $dRows = @(for ($di = 0; $di -lt $ds.Count; $di++) { $dy = $ds[$di]; $d0 = [datetime]$dy.d; $dl = if ($di) { $d0.ToString('ddd dd', $ic) } else { 'today' }; $pk = [double](@($dy.h | ForEach-Object { [double]@($_)[0] }) + 0 | Measure-Object -Maximum).Maximum
      $dv = @((& $gv $dy.m), (& $gv $dy.k), (& $gv $pk))
      "<div class=gk><span class=gn title='$(& $e "${dl}: $(& $gbT $dy.m) written, $(& $gbT $dy.k) kit-owned, peak $(& $gbT $pk) an hour")'>$(& $e $dl)</span>" +
      (Format-KitHeatCells @($dy.h) $d0 "$dl, GB written per hour: machine over kit-owned" { param($hv) "machine $(& $gbT $hv[0]) · kit-owned $(& $gbT $hv[1])" } { param($hv) @((Get-KitHeatShade ([double]$hv[0] / $scD)), (Format-KitHeatNum $hv[0]), (Get-KitHeatShade ([double]$hv[1] / $scD)), (Format-KitHeatNum $hv[1])) } 'sp ws' -NowAt $(if ($di) { -1 } else { ([datetime]$W.at).Hour })) +
      (@(for ($ci = 0; $ci -lt 3; $ci++) { "<span class='gc$(if ($dv[$ci] -eq '0') { ' z' })'>$($dv[$ci])</span>" }) -join '') + '</div>' })
  $tot = [double](@($ds | ForEach-Object { [double]$_.m }) + 0 | Measure-Object -Sum).Sum
  & $fold 'writes' 'Disk writes · 7 days' "$(& $gbT $tot)" "<div class='gks w3'>$dHead$($dRows -join '')</div><div class=hk><i class='lgk c'></i>top half = the whole machine <i class='lgk r'></i>bottom half = kit-owned · GB per clock hour · outlined = now · per owner: Resources · 24 h, Writes GB</div>" -tag h4 -cls 'sub st wr'
}
# a share 0..1 -> cell shade % (square root: a small value still shows; 0 = blank)
function Get-KitHeatShade([double]$F) { if ($F -gt 0) { [int][math]::Round(25 + 75 * [math]::Sqrt([math]::Min(1.0, $F))) } else { 0 } }
# a heatmap cell's number (owner, 2026-11-17: a number in every non-empty cell): 0 / none blank, under 10 one decimal, else whole
function Format-KitHeatNum($V) { $d = [double]$V; if ($null -eq $V -or $d -le 0) { '' } elseif ($d -lt 9.95) { [math]::Max(0.1, [math]::Round($d, 1)).ToString('0.#', [cultureinfo]::InvariantCulture) } else { "$([int][math]::Round($d))" } }
# THE cell renderer of every heatmap: shade % (--a), its number, a dark-shade class (hi: contrast text); $B -ge 0: a split cell, top
# half = $A / $Text, bottom = $B / $BText
function Format-KitHeatCell([int]$A, [string]$Text, [string]$Tip, [bool]$Now, [int]$B = -1, [string]$BText = '') {
  $hc = { param([int]$s) if ($s -ge 55) { ' hi' } else { '' } }
  if ($B -lt 0) { $cl = "$(if ($Now) { 'nw' })$(& $hc $A)".Trim(); return "<i$(if ($cl -match ' ') { " class='$cl'" } elseif ($cl) { " class=$cl" }) style='--a:$A%' title='$(& $e $Tip)'>$(& $e $Text)</i>" }
  "<i$(if ($Now) { ' class=nw' }) style='--a:$A%;--b:$B%' title='$(& $e $Tip)'><span class='t$(& $hc $A)'>$(& $e $Text)</span><span class='u$(& $hc $B)'>$(& $e $BText)</span></i>" }
# 24 cells, the last one outlined = now; default: shade and number = minutes in that hour (60 min = full); $Cell: @(shade, text[, shade
# B, text B]) of one cell for another scale (a count, CPU over RAM); $Cls: the map's class (its colours); $NowAt: the outlined cell (-1: none)
function Format-KitHeatCells($Hours, [datetime]$H0, [string]$Aria, [scriptblock]$Tip, [scriptblock]$Cell = $null, [string]$Cls = '', [int]$NowAt = 23) {
  $hs = @($Hours); "<span class='gs hm$(if ($Cls) { " $Cls" })' role=img aria-label='$(& $e $Aria)'>$(@(for ($hi = 0; $hi -lt 24; $hi++) { $hv = if ($hi -lt $hs.Count) { @($hs[$hi]) } else { @(0, 0, 0, '') }
    $cv = if ($Cell) { @(& $Cell $hv) } else { @((Get-KitHeatShade ([double]$hv[1] / 60)), (Format-KitHeatNum $hv[1])) }
    $tp = "$($H0.AddHours($hi).ToString('HH:00'))$(if ($hi -eq $NowAt) { ' (now)' }) · $(& $Tip $hv)"
    if ($cv.Count -ge 4) { Format-KitHeatCell $cv[0] "$($cv[1])" $tp ($hi -eq $NowAt) $cv[2] "$($cv[3])" } else { Format-KitHeatCell $cv[0] "$($cv[1])" $tp ($hi -eq $NowAt) } }) -join '')</span>" }
# a row is busy when one of its last 12 cells has data ($Busy: of one cell; default its first value)
function Test-KitHeatBusy($Hours, [scriptblock]$Busy = { param($c) [double]@($c)[0] -gt 0 }) {
  $hs = @($Hours); if (-not $hs.Count) { return $false }; foreach ($hi in ([math]::Max(0, $hs.Count - 12))..($hs.Count - 1)) { if (& $Busy @($hs[$hi])) { return $true } }; $false }
# rows with data in the last 12 h show; the rest fold into one "N idle rows" line (a tap shows them); $Rows: @{ html; busy }
function Format-KitHeatRows($Rows, [string]$What = 'rows') {
  $rs = @($Rows | Where-Object { $_ }); $on = @($rs | Where-Object busy); $off = @($rs | Where-Object { -not $_.busy })
  (@($on | ForEach-Object html) -join '') + $(if ($off.Count) { "<button type=button class=gkx aria-expanded=false>$($off.Count) idle $(& $e $What) · no data in 12 h</button><div class=gki>$(@($off | ForEach-Object html) -join '')</div>" }) }
# the fold count of a heatmap card: busy rows of all
function Get-KitHeatCount($Rows) { $rs = @($Rows | Where-Object { $_ }); "$(@($rs | Where-Object busy).Count) of $($rs.Count) busy" }
# builds today per agent (owner): count, build minutes, failed; bar = share of the busiest owner's count
function Format-KitBuildOwners($Owners) {
  $os = @($Owners | Where-Object { $_ -and $_.n }); if (-not $os.Count) { return '' }; $top = [double]$os[0].n
  "<div style='text-align:left'><div class=s>builds today per agent · build-min · failed</div>" + (@($os | Select-Object -First 8 | ForEach-Object {
      $t = "$($_.name): $($_.n) builds, $($_.min) build-min, $($_.failed) failed"
      "<div class=s title='$(& $e $t)'><span aria-hidden=true style='display:inline-block;width:60px;margin-right:6px'><span style='display:inline-block;height:6px;width:$([int](60 * $_.n / $top))px;background:currentColor;opacity:.45'></span></span>$(& $e $_.name) $($_.n) · $($_.min) min$(if ($_.failed) { " · $($_.failed) failed" })</div>" }) -join '') +
    $(if ($os.Count -gt 8) { "<div class=s>+$($os.Count - 8) more agents</div>" }) + '</div>'
}
# build gate: one line per kind (24 h heatmap of busy minutes, running, queued, today, waits, RAM); RAM, QA seats, phones, browsers aside
function Format-KitGateCard($gs) {
  if (-not $gs) { return (& $nowCard 'Build gate · QA seats' "$(& $icv run 'running builds' (& $fmt $nw.gr))$(& $icv queue 'queued builds' (& $fmt $nw.gq))<small> · seats </small>$(& $fmt $nw.seats)<small> / $(& $fmt $nw.seatsMax)</small>" "longest wait $(& $fmt $nw.gw) min" '' $(if ($nw.gw -ge 30) { 'hot' } elseif ($nw.gq -ge 6) { 'warn' }) "$(& $dots $nw.seats $nw.seatsMax)$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queue, 24 h' 'peak' 0)") }
  $fl = [math]::Max(0.0, [double]$j.mem.AvailGB - [double]$st.keepFree); $gb = [math]::Min(24, [int][math]::Ceiling([double]$gs.ram + $fl))   # 1 dot = 1 GB: promised to running builds, then free above the floor
  $ramDots = if ($gb -gt 0) { "<div class=dots role=img aria-label='RAM for builds: $(& $n1 $gs.ram) GB promised, $(& $n1 $fl) GB free above the floor'>$(@(1..$gb | ForEach-Object { "<i$(if ($_ -le [math]::Round([double]$gs.ram)) { ' class=on' })></i>" }) -join '')</div><div class=s>RAM: $(& $n1 $gs.ram) GB promised · $(& $n1 $fl) GB free above the $(& $n1 $st.keepFree) GB floor</div>" }
  # under one header row (hour labels, icons); zeros dimmed; each cell carries its icon too: shown only under 700 px
  $gCols = @(@('run', 'running builds', ''), @('queue', 'queued builds', ''), @('today', 'builds today', ''), @('wait', 'wait avg, min', 'avg'), @('wait', 'wait peak, min', 'peak'), @('ram', 'RAM GB: now, or up to (24 h peak)', 'GB'))
  $h0 = try { [datetime]$gs.h0 } catch { $at.Date.AddHours($at.Hour - 23) }
  $gHead = "<div class='gk gh'><span class=gn>kind · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@($gCols | ForEach-Object { "<span class=gc>$(Format-KitIcon $_[0] $_[1])$(if ($_[2]) { "<small>$($_[2])</small>" })</span>" }) -join '')</div>"
  $kRows = @($gs.rows | Where-Object { $_ } | ForEach-Object { $kr = $_; $nm = "$($kr.name)"
      $ram = if ([double]$kr.ram) { @((& $n1 $kr.ram), "$(& $n1 $kr.ram) GB now", ' nw') } elseif ([double]$kr.peakGB) { @("≤$(& $n1 $kr.peakGB)", "up to $(& $n1 $kr.peakGB) GB", '') } else { @('—', 'no RAM sample', ' z') }
      $vals = @("$([int]$kr.running)", "$([int]$kr.queued)", "$([int]$kr.done)", (& $n1 $kr.waitAvg), (& $n1 $kr.waitMax))
      $w = "$($vals[0]) running · $($vals[1]) queued · $($vals[2]) today · wait avg $($vals[3]) / peak $($vals[4]) min · $($ram[1])"
      $cells = @(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($vals[$ci] -eq '0') { ' z' })' title='$(& $e "${nm}: $($vals[$ci]) $($gCols[$ci][1])")'>$(Format-KitIcon $gCols[$ci][0] $gCols[$ci][1])$($vals[$ci])</span>" }) + "<span class='gc$($ram[2])' title='$(& $e "${nm}: $($ram[1])")'>$(Format-KitIcon ram 'RAM GB')$(& $e $ram[0])</span>"
      [pscustomobject]@{ busy = [int]$kr.running + [int]$kr.queued -gt 0 -or (Test-KitHeatBusy $kr.hours { param($c) [double]@($c)[1] -gt 0 }); html = "<div class=gk><span class=gn title='$(& $e "${nm}: $w")'>$(& $e $nm)</span>$(Format-KitHeatCells $kr.hours $h0 "$nm, builds per hour, last 24 h" { param($hv) "$nm · $([int]$hv[0]) builds · $(& $n1 $hv[1]) build-min · max wait $(& $n1 $hv[2]) min" })$($cells -join '')</div>" } })
  $inner = "<div class=v>$(& $icv run 'running builds' (& $fmt $gs.running))$(& $icv queue 'queued builds' (& $fmt $gs.queued))$(& $icv today 'builds today' (& $fmt $gs.today))$(& $icv wait 'longest wait today' (& $n1 $gs.waitMax) ' min')</div>" +
  "<div class=gl><div>$(if ($kRows.Count) { "<div class=gks>$gHead$(Format-KitHeatRows $kRows 'kinds')</div><div class=hk>shade = busy minutes in that hour · outlined = now · tap a cell for builds and waits</div>" } else { '<div class=s>no gated build in 24 h</div>' })</div>" +
  "<div class=gp>$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queued builds, 24 h' 'peak' 0)$ramDots$(& $dots $nw.seats $nw.seatsMax)<div class=s>QA seats $(& $fmt $nw.seats) / $(& $fmt $nw.seatsMax)</div>$(if ($gs.lanes) { "<div class=s>phone lanes $($gs.leased) / $($gs.lanes) leased · emulators $($gs.emulators) running</div>" })$(if ($gs.browsers) { "<div class=s>test browsers $($gs.browsers) ($(& $n1 $gs.browserGB) GB, leased)</div>" })$(Format-KitBuildOwners $gs.owners)</div></div>"
  & $fold 'gate' 'Build gate · QA seats' $(if ($kRows.Count) { Get-KitHeatCount $kRows } else { '' }) $inner -Open:([bool]@($kRows | Where-Object busy).Count -or $gs.running -or $gs.queued) -tag h4 -cls "sub st gt $(if ($gs.waitMax -ge 30) { 'hot' } elseif ($gs.queued -ge 6) { 'warn' })"
}
# Resources · 24 h (owner, 2026-11-17: CPU and RAM per resource in one heatmap): a row per resource, every name of 24 h plus each
# configured lane service (Update-KitCpuStats svc: a stopped one keeps its row); a cell's top half = avg CPU % of the machine (slate),
# the bottom = avg RAM GB (sage; full = the biggest peak, the machine: its total); lease / slot RAM first, else the service's process
# tree; columns CPU now / peak / avg %, RAM now / peak GB; red: over 80% between sweeps 5+ min apart, amber: a peak over 80% in 24 h
# owner 2026-11-19 (one resources view): metric switch CPU · RAM | Writes GB (Get-KitWriteView: kit-owned rows by resource name, agent
# shells, lanes; machine, kit-owned and other processes) | Waits min (Get-KitLeaseWaits); rows in groups (machine open, the rest
# folded; count + the worst state on the group row), holder + branch / task on the row
function Format-KitResHeat($Cpu, $Resources, $Live, [double]$TotalGB, $MemNowGB = $null, $Writes = $null, $Waits = $null) {
  $h0 = $at.Date.AddHours($at.Hour - 23); $hrOf = { param($x) try { [int][math]::Floor(([datetime]$x - $h0).TotalHours) } catch { -1 } }
  $hot = { param($v, $s) [double]$v -gt 80 -and [int]$s -ge 300 }   # TODO-PARAM (fixed default: 80% for 5+ min)
  $names = { param($o) if ($o -is [Collections.IDictionary]) { @($o.Keys) } elseif ($o) { @((Get-KitProps $o).Name) } else { @() } }   # this sweep's: a dictionary; older ones: from JSON
  $ss = @($Cpu.samples | Where-Object { $_ -and (& $hrOf $_.at) -in 0..23 }); $last = if ($ss.Count) { $ss[-1] }
  $ls = @($Live | Where-Object { $_ -and $_.at -and (& $hrOf $_.at) -in 0..23 -and [datetime]$_.at -lt $at })
  $resRows = [ordered]@{}; $lst = { , @(0..23 | ForEach-Object { , [Collections.Generic.List[object]]::new() }) }
  $row = { param([string]$n) if (-not $resRows.Contains($n)) { $resRows[$n] = [pscustomobject]@{ n = $n; c = (& $lst); r = (& $lst); t = (& $lst); by = (& $lst); cv = [Collections.Generic.List[double]]::new() } }; $resRows[$n] }
  $mach = & $row 'whole machine'
  foreach ($s in $ss) { $hi = & $hrOf $s.at; $mach.c[$hi].Add([double]$s.all); $mach.cv.Add([double]$s.all)
    foreach ($nm in (& $names $s.g)) { $w = & $row "$nm"; $v = [double](Get-KitMember $s.g $nm); $w.c[$hi].Add($v); $w.cv.Add($v) }
    foreach ($nm in (& $names $s.m)) { (& $row "$nm").t[$hi].Add([double](Get-KitMember $s.m $nm)) } }
  foreach ($x in $ls) { $hi = & $hrOf $x.at; if ($null -ne $x.mem -and $TotalGB) { $mach.r[$hi].Add($TotalGB * [double]$x.mem / 100) }
    foreach ($nm in (& $names $x.res)) { $v = Get-KitMember $x.res $nm; $w = & $row "$nm"; $w.r[$hi].Add([double]$v.gb); if ("$($v.by)".Trim()) { $w.by[$hi].Add("$($v.by)".Trim()) } } }
  foreach ($nm in @($Cpu.svc | Where-Object { $_ })) { $null = & $row "$nm" }
  $cur = @{}; foreach ($r0 in @($Resources | Where-Object { $_.name })) { $cur["$($r0.name)"] = $r0; $w = & $row "$($r0.name)"; $w.r[23].Add([double]$r0.gb); if ("$($r0.by)".Trim()) { $w.by[23].Add("$($r0.by)".Trim()) } }
  if ($null -ne $MemNowGB) { $mach.r[23].Add([double]$MemNowGB) }
  $wv = @{}; foreach ($x in @(@($Writes.rows) + @($Writes.more) | Where-Object { $_ -and $_.n })) { $wv["$($x.n)"] = $x }
  $wm = $wv['whole machine']; $wk = $wv['kit-owned']
  if ($wm -and $wk) { $oh = @(for ($i = 0; $i -lt 24; $i++) { [math]::Max(0.0, [double]@($wm.h)[$i] - [double]@($wk.h)[$i]) }); $dif = { param([string]$f) [math]::Max(0.0, [double](Get-KitMember $wm $f) - [double](Get-KitMember $wk $f)) }
    $otop = @(@($Writes.rows) + @($Writes.more) | Where-Object { $_ -and "$($_.n)" -notin 'whole machine', 'kit-owned', 'others' -and -not $_.a -and -not $resRows.Contains("$($_.n)") -and "$($_.n)" -notmatch '^lane ' } | Sort-Object { - [double]$_.d7 } | Select-Object -First 3 | ForEach-Object { "$($_.n) $(& $n1 $_.d7) GB" })
    $wv['other processes'] = [pscustomobject]@{ n = 'other processes'; a = ''; c = "7 days: $($otop -join ', ')"; h = $oh; now = (& $dif now); peak = [double]($oh + 0 | Measure-Object -Maximum).Maximum; avg = [double]($oh | Measure-Object -Sum).Sum / 24; day = (& $dif day); d7 = (& $dif d7) }
    $null = & $row 'kit-owned'; $null = & $row 'other processes' }
  foreach ($k0 in @($wv.Keys)) { if ("$($wv[$k0].a)" -eq 'shell' -or $k0 -match '^lane ') { $null = & $row $k0 } }   # agent shells and lanes: their own rows
  $qv = @{}; foreach ($x in @($Waits.rows | Where-Object { $_ -and $_.name })) { $qv["$($x.name)"] = $x; $null = & $row "$($x.name)" }
  $gv = { param($v) $d = [double]$v; if ($d -le 0) { '0' } elseif ($d -lt 0.095) { $d.ToString('0.00', [cultureinfo]::InvariantCulture) } else { & $n1 $d } }
  $avg ={ param($l) if ($l.Count) { [double](@($l) | Measure-Object -Average).Average } else { $null } }; $max = { param($l) [double](@($l) + 0 | Measure-Object -Maximum).Maximum }   # $null kept: a tuple slot, never dropped
  $ramOf = { param($w, $hi) if ($w.r[$hi].Count) { $w.r[$hi] } else { $w.t[$hi] } }   # a lease's own GB first, else the process tree's
  $ramTop = [math]::Max(0.1, [double](@($resRows.Values | Where-Object { $_ -ne $mach } | ForEach-Object { $w = $_; 0..23 | ForEach-Object { & $max (& $ramOf $w $_) } }) + 0 | Measure-Object -Maximum).Maximum)
  $topIn = @{}; foreach ($s in $ss) { $hi = & $hrOf $s.at; foreach ($t in @($s.top | Where-Object { $_ })) { $k0 = "$hi|$($t.n)"; if (-not $topIn[$k0] -or [double]$t.p -gt $topIn[$k0].p) { $topIn[$k0] = [pscustomobject]@{ h = $hi; n = "$($t.n)"; p = [double]$t.p } } } }
  $rows = @(foreach ($w in @(@($mach) + @($resRows.Values | Where-Object { $_ -ne $mach } | Sort-Object n))) { $nm = $w.n; $isM = $w -eq $mach; $scale = if ($isM -and $TotalGB) { $TotalGB } else { $ramTop }
      $hours = @(for ($hi = 0; $hi -lt 24; $hi++) { $rv = & $ramOf $w $hi; $tops = if ($isM) { @($topIn.Values | Where-Object h -eq $hi | Sort-Object { - $_.p } | Select-Object -First 3 | ForEach-Object { "$($_.n) $(& $n1 $_.p)%" }) -join ', ' }
          , @(($w.c[$hi].Count + $rv.Count), (& $avg $w.c[$hi]), (& $max $w.c[$hi]), (& $avg $rv), (@($w.by[$hi] | Select-Object -Unique) -join ', '), "$tops", $scale) })
      $hasC = $w.cv.Count -gt 0; $cNow = if ($hasC -and $last) { if ($isM) { [double]$last.all } else { [double](Get-KitMember $last.g $nm) } }
      $cPk = & $max $w.cv; $cAvg = if ($hasC -and $ss.Count) { [double](@($w.cv) | Measure-Object -Sum).Sum / $ss.Count }
      $rNow = if ($isM) { $MemNowGB } elseif ($cur.ContainsKey($nm)) { [double]$cur[$nm].gb } elseif ($last -and $null -ne (Get-KitMember $last.m $nm)) { [double](Get-KitMember $last.m $nm) }
      $rAll = @(0..23 | ForEach-Object { & $ramOf $w $_ } | ForEach-Object { $_ }); $rPk = [math]::Max([double]$rNow, (& $max $rAll)); $hasR = $rAll.Count -gt 0 -or $null -ne $rNow
      $r0 = $cur[$nm]; $by = "$($r0.by)".Trim(); $hp = Split-KitHolder $by
      $sub = if (-not $r0) { '' } elseif ($r0.shared) { 'shared · always on' } elseif ($hp.h -notin '', 'no lease') { "$($hp.h)$($hp.g)" } else { "no live holder$($hp.g)" }
      $bt = if ($r0 -and -not $r0.shared) { @($hp.b, (Get-KitHolderTask $hp.h) | Where-Object { $_ }) -join ' · ' } else { '' }   # owner 2026-11-19: the held list's branch / task column, now on the row
      $vals = @($(if ($hasC) { & $n1 $cNow } else { '—' }), $(if ($hasC) { & $n1 $cPk } else { '—' }), $(if ($hasC) { & $n1 $cAvg } else { '—' }), $(if ($null -ne $rNow) { & $n1 $rNow } else { '—' }), $(if ($hasR) { & $n1 $rPk } else { '—' }))
      $tone = if ($hasC -and $last -and (& $hot $cNow $last.s)) { 'hot' } elseif ($cPk -gt 80) { 'warn' } else { '' }
      $wr = $wv[$nm]; $qr = $qv[$nm]; if (-not $sub -and "$($wr.a)") { $sub = "$($wr.a)" }
      $wh = @(if ($wr) { $wr.h | ForEach-Object { , @([double]$_) } }); $wvals = if ($wr) { @($wr.now, $wr.peak, $wr.avg, $wr.day, $wr.d7 | ForEach-Object { & $gv $_ }) } else { @('—') * 5 }
      $qvals = if ($qr) { @("$([int]$qr.n)", (& $n1 $qr.min), (& $n1 $qr.max), '', '') } else { @('—', '—', '—', '', '') }
      $gk = if ($nm -in 'whole machine', 'kit-owned', 'other processes') { 'machine' } elseif ($r0.shared) { 'shared' } elseif ("$($wr.a)" -eq 'shell') { 'shell' } elseif ($nm -match '^(build|slot|phone|browser|lock|lane)\b') { $Matches[1] -replace '^lane$', 'env' } elseif ($nm -match '·') { 'env' } else { 'other' }
      [pscustomobject]@{ nm = $nm; grp = $gk; busy = $isM -or [bool]$r0 -or (Test-KitHeatBusy $hours { param($c) [double]@($c)[1] -ge 0.1 -or [double]@($c)[3] -gt 0 }) -or ($wr -and [double]$wr.day -gt 0) -or ($qr -and [int]$qr.n)
        tone = $tone; orphan = $r0 -and -not $r0.shared -and $by -match '^$|\(grace|^no lease$'; sub = $sub; bt = $bt; vals = $vals; hours = $hours; wh = $wh; wvals = $wvals; wc = "$($wr.c)"; qh = @(if ($qr) { $qr.hours }); qvals = $qvals } })
  $cols = @('now %', 'peak %', 'avg %', 'now GB', 'peak GB')
  $mc = @(@('c', $cols), @('w', @('now', 'peak', 'avg', 'today', '7 d')), @('q', @('waits', 'min', 'longest', '', '')))
  $head = "<div class='gk gh'><span class=gn>resource · holder · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@(foreach ($m in $mc) { foreach ($cn in $m[1]) { "<span class=gc data-mv=$($m[0])><small>$cn</small></span>" } }) -join '')</div>"
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  $wmx = { param($rs) [math]::Max($hard, [double](@($rs | ForEach-Object { $_.wh } | ForEach-Object { [double]@($_)[0] }) + 0 | Measure-Object -Maximum).Maximum) }
  $wscM = & $wmx @($rows | Where-Object grp -eq 'machine'); $wscO = & $wmx @($rows | Where-Object grp -ne 'machine')
  $lane = ''; $items = @(foreach ($r in $rows) { $ln = ("$($r.nm)" -split ' · ')[0]; $first = $r.nm -ne 'whole machine' -and $ln -ne $lane; $lane = $ln; $nm = $r.nm; $wsc = if ($r.grp -eq 'machine') { $wscM } else { $wscO }
      $wn = if ($r.grp -eq 'machine') { 0 } else { [double]($r.wvals[0] -replace '—', '0') }; [pscustomobject]@{ busy = $r.busy; grp = $r.grp; tone = $r.tone; orphan = $r.orphan; wl = $(if ($wn -ge $hard) { 2 } elseif ($wn -ge $soft) { 1 } else { 0 }); ql = [double]($r.qvals[2] -replace '—', '0') -ge 30; html = "<div class='gk$(if ($first) { ' gl0' })$(if ($r.tone) { " $($r.tone)" })$(if ($r.orphan) { ' orphan' })'><span class=gn title='$(& $e "${nm}$(if ($r.sub) { " · $($r.sub)" }): $(if ($r.vals[0] -ne '—') { "CPU now $($r.vals[0])% · 24 h peak $($r.vals[1])% · avg $($r.vals[2])% · " } else { 'CPU not sampled: not running, or no process tree of its own (lease, slot, lock, external) · ' })$(if ($r.vals[3] -ne '—') { "RAM now $($r.vals[3]) GB · 24 h peak $($r.vals[4]) GB" } else { 'RAM: not running now' })")'>$(& $e $nm)$(if ($r.sub) { "<small>$(& $e $r.sub)</small>" })$(if ($r.bt) { "<small class=bt>$(& $e $r.bt)</small>" })</span>" +
        ((Format-KitHeatCells $r.hours $h0 "$nm, CPU % and RAM GB per hour, last 24 h" { param($hv) if (-not $hv[0]) { "$nm · no sample" } else { "$nm · $(@(@($(if ($null -ne $hv[1]) { "CPU avg $(& $n1 $hv[1])% · peak $(& $n1 $hv[2])%" }), "RAM $(if ($null -ne $hv[3]) { "$(& $n1 $hv[3]) GB" } else { '—' })") | Where-Object { $_ }) -join ' · ')$(if ("$($hv[4])") { " · $($hv[4])" })$(if ("$($hv[5])") { " · top: $($hv[5])" })" } } { param($hv) @((Get-KitHeatShade ([double]$hv[1] / 100)), (Format-KitHeatNum $hv[1]), (Get-KitHeatShade ([double]$hv[3] / [double]$hv[6])), (Format-KitHeatNum $hv[3])) } 'sp') -replace '^<span ', '<span data-mv=c ') +
        ((Format-KitHeatCells $r.wh $h0 "$nm, GB written per hour, last 24 h" { param($hv) "$nm · $(& $gv $hv[0]) GB written$(if ($r.wc) { " · $($r.wc)" })" } { param($hv) @((Get-KitHeatShade ([double]$hv[0] / $wsc)), (Format-KitHeatNum $hv[0])) } 'ws') -replace '^<span ', '<span data-mv=w ') +
        ((Format-KitHeatCells $r.qh $h0 "$nm, minutes waited per hour, last 24 h" { param($hv) "$([int]$hv[0]) waits · $(& $n1 $hv[1]) min · longest $(& $n1 $hv[2]) min$(if ("$(@($hv)[3])") { " · $($hv[3])" })" }) -replace '^<span ', '<span data-mv=q ') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.vals[$ci] -in '0', '—') { ' z' })' data-mv=c title='$(& $e "${nm}: $($cols[$ci] -replace ' (%|GB)$') $(if ($ci -lt 3) { 'CPU' } else { 'RAM' }) $($r.vals[$ci]) $(if ($ci -lt 3) { '%' } else { 'GB' })")'>$($r.vals[$ci])</span>" }) -join '') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.wvals[$ci] -in '0', '—') { ' z' })$(if ($ci -eq 0 -and $r.grp -ne 'machine' -and [double]($r.wvals[0] -replace '—', '0') -ge $hard) { ' hot' } elseif ($ci -eq 0 -and $r.grp -ne 'machine' -and [double]($r.wvals[0] -replace '—', '0') -ge $soft) { ' warn' })' data-mv=w title='$(& $e "${nm}: $($mc[1][1][$ci]) $($r.wvals[$ci]) GB")'>$($r.wvals[$ci])</span>" }) -join '') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.qvals[$ci] -in '0', '—', '') { ' z' })' data-mv=q>$($r.qvals[$ci])</span>" }) -join '') + '</div>' } })
  $tops = @($ss | ForEach-Object { $s0 = $_; @($_.top | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ k = "$($_.pid)|$($_.n)"; n = $_.n; pid = $_.pid; p = [double]$_.p; o = "$($_.o)"; c = "$($_.c)"; at = $s0.at; s = $s0.s; nowS = [bool]($s0 -eq $last) } } } | Group-Object k | ForEach-Object { $gp = @($_.Group | Sort-Object { [datetime]$_.at }); $pk = ($gp | Measure-Object p -Maximum).Maximum
      [pscustomobject]@{ n = $gp[-1].n; pid = $gp[-1].pid; o = @($gp.o | Where-Object { $_ })[-1]; c = $gp[-1].c; now = $(if ($gp[-1].nowS) { $gp[-1].p }); pk = $pk; hot = [bool]@($gp | Where-Object { & $hot $_.p $_.s }).Count } } | Sort-Object { - $_.pk } | Select-Object -First 8)
  $topHtml = if ($tops.Count) { & $fold 'cpu-top' 'Top other processes' $tops.Count ("<div class=cpt><div class=s>10%+ of the machine between two sweeps</div>" + (@($tops | ForEach-Object { "<div class='cpo f$(if ($_.hot) { ' hot' })' title='$(& $e $(if ($_.c) { $_.c } else { $_.n }))'><span class=cn0>$(& $e $_.n) <small>pid $($_.pid)$(if ($_.o) { " · $($_.o)" })</small></span><span class=gc>now $(if ($null -ne $_.now) { "$(& $n1 $_.now)%" } else { '—' })</span><span class=gc>24 h peak $(& $n1 $_.pk)%</span></div>" }) -join '') + '</div>') -Open:([bool]@($tops | Where-Object { $null -ne $_.now }).Count) -tag h4 -cls sub } else { '<div class=s>no other process over 10% of the machine in 24 h</div>' }
  $legend = "<div class=hk><i class='lgk c'></i>top half = avg CPU % of the machine ($([Environment]::ProcessorCount) cores) <i class='lgk r'></i>bottom half = avg RAM (full = the biggest peak, $(& $n1 $ramTop) GB; the machine: its $(& $n1 $TotalGB) GB) · outlined = now · tap a cell for both values, holders and (machine row) the top other processes · dashed = no live holder (released after idle.graceMinutes)</div>"
  $gl = [ordered]@{ machine = 'machine'; env = 'env services'; build = 'builds'; slot = 'worktree slots'; phone = 'phones · emulators'; browser = 'browser tabs'; shell = 'agent shells'; lock = 'locks'; shared = 'shared'; other = 'other' }
  $groups = @(foreach ($gk0 in $gl.Keys) { $gi = @($items | Where-Object grp -eq $gk0); if (-not $gi.Count) { continue }; $op = $gk0 -eq 'machine'
      $wst = if (@($gi | Where-Object tone -eq 'hot').Count) { @('s-stuck', 'CPU over 80%') } elseif (@($gi | Where-Object wl -ge 2).Count) { @('s-stuck', "writes over $(& $n1 $hard) GB/h") } elseif (@($gi | Where-Object wl -ge 1).Count) { @('s-oth', "writes over $(& $n1 $soft) GB/h") } elseif (@($gi | Where-Object ql).Count) { @('s-oth', 'waits of 30+ min') } elseif (@($gi | Where-Object orphan).Count) { @('s-oth', "$(@($gi | Where-Object orphan).Count) no live holder") } elseif (@($gi | Where-Object tone -eq 'warn').Count) { @('s-oth', 'CPU peak over 80%') }
      "<div class='rgg$(if (-not $op) { ' cl' })' data-g='rg-$gk0'><div class='gk rgh'><button type=button class=rgb aria-expanded=$(if ($op) { 'true' } else { 'false' })><span class=gn0>$($gl[$gk0])</span><span class=gcn>$($gi.Count)</span>$(if ($wst) { "<span class='chip $($wst[0])'>$($wst[1])</span>" })</button></div>$(@($gi | Sort-Object -Stable { -not $_.busy } | ForEach-Object html) -join '')</div>" })
  $tabs = "<div class=rgt role=group aria-label='metric'>$(@(@(@('c', 'CPU · RAM'), @('w', 'Writes GB'), @('q', 'Waits min')) | ForEach-Object { "<button type=button data-m=$($_[0]) aria-pressed=$(if ($_[0] -eq 'c') { 'true' } else { 'false' })>$($_[1])</button>" }) -join '')</div>"
  $legW = "<div class=hk data-mv=w>a cell = GB written in that clock hour (kit-owned processes by the resource, shell or lane that started them) · now = the last 60 min: amber over $(& $n1 $soft), red over $(& $n1 $hard) GB (WATCH / ACT) · other processes: its top 3 in the tooltip</div>"
  $legQ = '<div class=hk data-mv=q>a cell = minutes agents waited for that resource in the hour · tap a cell for waits and who</div>'
  & $fold 'res24' 'Resources · 24 h' (Get-KitHeatCount $items) "<div class=rgx data-m=c>$tabs<div class='gks w5 cpg rsh'>$head$($groups -join '')</div>$($legend -replace '^<div class=hk>', '<div class=hk data-mv=c>')$legW$legQ</div>$topHtml" -Open -tag h4 -cls "sub st cpu$(if ($last -and (& $hot $last.all $last.s)) { ' hot' })"
}
# names minus the suffix all of them share ("-code"): narrow grid columns and chips; one name keeps its full form
function Get-KitShortNames([string[]]$Names) {
  $ns = @($Names | Where-Object { $_ } | Select-Object -Unique); $map = @{}; $sx = ''
  if ($ns.Count -ge 2 -and "$($ns[0])" -match '([-_.][^-_.]+)$') { $c0 = $Matches[1]; if (-not @($ns | Where-Object { -not $_.EndsWith($c0) -or $_.Length -le $c0.Length }).Count) { $sx = $c0 } }
  foreach ($x in $ns) { $map[$x] = if ($sx) { $x.Substring(0, $x.Length - $sx.Length) } else { $x } }; $map
}
# lanes (envy.ps1 lanes -Sync, wt-slots/lanes/lanes.json; owner 2026-11-17, K74): a grid, a row per lane, a column per repo; a cell = commits
# behind the target (amber when > 0) and +N test merges (sage); base, head and kept in its tooltip; no slot for that repo: an empty cell
function Format-KitLaneGrid($Lanes) {
  $ls = @($Lanes | Where-Object { $_ -and $_.lane -and $_.repo }); if (-not $ls.Count) { return '' }
  $rps = @($ls.repo | Sort-Object -Unique); $sn = Get-KitShortNames $rps; $byLR = @{}; foreach ($x in $ls) { $byLR["$($x.lane)|$($x.repo)"] = $x }
  $s8 = { param($v) $v = "$v"; $v.Substring(0, [math]::Min(8, $v.Length)) }
  $hd = "<span></span>$(@($rps | ForEach-Object { "<span class=lnh title='$(& $e $_)'>$(& $e $sn[$_])</span>" }) -join '')"
  $rows = @($ls.lane | Sort-Object -Unique | ForEach-Object { $ln = $_; $lbl = try { Get-KitPoolLabel env $ln } catch { $ln }   # lane 1 too: <env>·<Bird>
      "<span class=lnn title='$(& $e $ln)'>$(& $e $lbl)</span>" + (@($rps | ForEach-Object { $x = $byLR["$ln|$_"]; if (-not $x) { return '<span class=lnc></span>' }
          $bh = [int]$x.behind; $mg = [int]$x.merges
          "<span class='lnc on$(if ($bh) { ' bh' })$(if ($x.kept) { ' kp' })' tabindex=0 title='$(& $e "$lbl · $($x.repo): base @ $(& $s8 $(if ($x.base) { $x.base } else { $x.head })) · head $(& $s8 $x.head) · behind $bh · test merges $mg$(if ($x.kept) { " · kept: $($x.kept)" })$(if ($x.at) { " · $($x.at)" })")'>$bh$(if ($mg) { "<small>+$mg</small>" })</span>" }) -join '') })
  "<div class=lng style='--n:$($rps.Count)' role=group aria-label='lanes by repo: commits behind the target, +N test merges'>$hd$($rows -join '')</div>" +
  "<div class=lnk><i class='lgk lb'></i>behind target <i class='lgk lm'></i>+N test merges · outlined = in use · tap a cell: base sha</div>"
}
# the task a lease belongs to, from its holder ids (comma list): a QA code (test:T5, T5) -> its newest run's task "QA T5 · <task>"; an agent id or
# pid-N -> its live board entry's items (else run); none found: ''
function Get-KitHolderTask([string]$Holder) {
  if (-not $script:KitHolderCache) { $script:KitHolderCache = @{} }; $c = $script:KitHolderCache; $out = [Collections.Generic.List[string]]::new()
  if (-not $c.qa) { $c.qa = @(Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'index.json') -Raw | ConvertFrom-Json).items } catch { $null } } | Where-Object { $_ }) }
  if (-not $c.board) { $c.board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -notin 'left', 'crashed' }) }
  foreach ($id in @("$Holder" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notin 'parked', 'no lease' })) {
    $t = ''; if ($id -match '^(?:test:)?(?<q>T\d+)$') { $q = $Matches.q; $it = @($c.qa | ForEach-Object { Get-KitMember $_ $q } | Where-Object { $_ } | Select-Object -First 1)[0]; if ($it) { $t = "QA $q · $(if ($it.pubKey) { $it.pubKey } else { @($it.tasks)[0] })" } }
    if (-not $t) { $pn = if ($id -match '^pid-(?<n>\d+)$') { [int]$Matches.n } else { 0 }; $b = @($c.board | Where-Object { $_.agent -eq $id -or ($pn -and ($_.pid -eq $pn -or $_.holderPid -eq $pn)) } | Select-Object -First 1)[0]; if ($b) { $t = if ("$($b.items)".Trim()) { "$($b.items)".Trim() } else { "$($b.run)" } } }
    if ($t -and $t -notin $out) { $out.Add($t) } }
  $out -join '; '
}
# a lease holder text -> @{ h = holder(s); b = branch; g = " (grace ..)" }: supervise appends the grace after "(branch)"; "parked: <branch>"
function Split-KitHolder([string]$By) {
  $by0 = "$By".Trim(); $br = ''; $gr = ''; if ($by0 -match '^(?<r>.*?)\s*(?<g>\(grace [^()]*\))$') { $by0 = $Matches.r; $gr = " $($Matches.g)" }
  if ($by0 -match '^(?<h>.*?)\s*\((?<b>[^()\s]+)\)$') { $by0 = $Matches.h; $br = $Matches.b } elseif ($by0 -match '^parked: (?<b>\S+)$') { $by0 = 'parked'; $br = $Matches.b }
  @{ h = $by0; b = $br; g = $gr }
}
# ---- flags: distinct ACT / WATCH / FIXED flags per clock hour, 24 h (history keeps 12 sweeps only): @(@{ h = yyyyMMddHH; f = @(@{ l; k = kind; y = key; t = text }) })
function Get-KitFlagHour($H) { try { [datetime]::ParseExact("$H", 'yyyyMMddHH', [cultureinfo]::InvariantCulture) } catch { [datetime]::MinValue } }
function Update-KitFlagHours($Prior, [datetime]$Now, $Flags) {
  $hk = $Now.ToString('yyyyMMddHH'); $h0 = $Now.Date.AddHours($Now.Hour - 23)
  $old = @($Prior | Where-Object { $_ -and "$($_.h)" -ne $hk -and (Get-KitFlagHour $_.h) -ge $h0 }); $cur = @($Prior | Where-Object { $_ -and "$($_.h)" -eq $hk })[0]
  $seen = @{}; $fs = [Collections.Generic.List[object]]::new(); foreach ($x in @($cur.f | Where-Object { $_ })) { $seen["$($x.l)|$($x.y)"] = 1; $fs.Add($x) }
  foreach ($x in @($Flags | Where-Object { $_ })) { $w = "$($x.what)"; $lv = "$($x.level)"
    if ($lv -eq 'INFO') { if ($w -notlike 'auto-fixed:*') { continue }; $lv = 'FIXED'; $w = $w -replace '^auto-fixed:\s*' } elseif ($lv -notin 'ACT', 'WATCH') { continue }
    $y = Get-KitFlagKey $w; if ($seen["$lv|$y"] -or $fs.Count -ge 120) { continue }; $seen["$lv|$y"] = 1   # 120 a hour: the json stays small
    $kd = "$((Get-KitFlagCells ([pscustomobject]@{ what = $w; kind = $x.kind })).kind)".Trim()
    $fs.Add([ordered]@{ l = $lv; k = $(if ($kd) { $kd } else { 'other' }); y = $y; t = $w.Substring(0, [math]::Min(200, $w.Length)) }) }
  @($old) + [ordered]@{ h = $hk; f = @($fs) }
}
# flags (owner, 2026-11-17: a heatmap like CPU): ACT / WATCH / FIXED rows, a sub-row per kind under each (the leading CAPS words of the flag, re-read for old 'other' entries; 'other' = no kind word); a cell = distinct flags that
# hour (count shown, shade by count, colour by level), its tooltip their texts; column: distinct flags in 24 h
function Format-KitFlagHeat($FH) {
  $h0 = $at.Date.AddHours($at.Hour - 23)
  $xs = @(foreach ($b in @($FH | Where-Object { $_ })) { $hi = [int][math]::Floor(((Get-KitFlagHour $b.h) - $h0).TotalHours); if ($hi -lt 0 -or $hi -gt 23) { continue }
      foreach ($x in @($b.f | Where-Object { $_ })) { [pscustomobject]@{ hi = $hi; l = "$($x.l)"; k = $(if ("$($x.k)" -in '', 'other') { $kd = "$((Get-KitFlagCells ([pscustomobject]@{ what = $x.t })).kind)".Trim(); if ($kd) { $kd } else { 'other' } } else { "$($x.k)" }); y = "$($x.y)"; t = "$($x.t)" } } })
  if (-not $xs.Count) { return (& $fold 'flagmap' 'Flags · 24 h' 0 '' -tag h4 -cls 'sub st fhm') }
  $mx = [math]::Max(1, [int](@($xs | Group-Object { "$($_.l)|$($_.hi)" } | ForEach-Object Count) + 0 | Measure-Object -Maximum).Maximum)
  $mk = { param([string]$label, $set, [string]$lvl, [bool]$sub) $lc = $lvl.ToLower()
    $hours = @(for ($hi = 0; $hi -lt 24; $hi++) { $in = @($set | Where-Object hi -eq $hi); , @($in.Count, @($in | ForEach-Object t | Select-Object -Unique)) }); $tot = @($set | ForEach-Object y | Select-Object -Unique).Count
    [pscustomobject]@{ busy = (Test-KitHeatBusy $hours); html = "<div class='gk l-$lc$(if ($sub) { ' fk' } else { ' gl0' })'><span class=gn title='$(& $e "${label}: $tot distinct flag(s) in 24 h")'>$(& $e $label)</span>" +
      (Format-KitHeatCells $hours $h0 "$label, flags per hour, last 24 h" { param($hv) $tx = @($hv[1] | Where-Object { $_ }); "$([int]$hv[0]) $label$(if ($tx.Count) { ": $(@($tx | Select-Object -First 6) -join ' | ')$(if ($tx.Count -gt 6) { " +$($tx.Count - 6) more" })" })" } { param($hv) $n0 = [int]$hv[0]; @((Get-KitHeatShade ($n0 / $mx)), $(if ($n0) { "$n0" } else { '' })) } "fh l-$lc") +
      "<span class='gc$(if (-not $tot) { ' z' })'>$tot</span></div>" } }
  $rows = @(foreach ($lvl in 'ACT', 'WATCH', 'FIXED') { $ls = @($xs | Where-Object l -eq $lvl); & $mk $lvl $ls $lvl $false
      foreach ($g in @($ls | Group-Object k | Sort-Object { - @($_.Group | ForEach-Object y | Select-Object -Unique).Count }, Name)) { & $mk "$($g.Name)" @($g.Group) $lvl $true } })
  $head = "<div class='gk gh'><span class=gn>level · kind · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span><span class=gc><small>24 h</small></span></div>"
  & $fold 'flagmap' 'Flags · 24 h' "$(@($xs | ForEach-Object { "$($_.l)|$($_.y)" } | Select-Object -Unique).Count) flags" "<div class='gks w1'>$head$(Format-KitHeatRows $rows 'rows')</div><div class=hk>a cell = distinct flags raised that hour (shade by count; ACT red, WATCH amber, FIXED green) · outlined = now · tap a cell for the texts</div>" -Open:([bool]@($rows | Where-Object busy).Count) -tag h4 -cls 'sub st fhm'
}
# test runs (owner, 2026-11-14: one Activity tile): checks and pass % over 7 days, a stacked bar per day, NOT_TESTED causes in one line
function Format-KitQaTile($qa, [datetime]$At = (Get-Date)) {
  $ds = @($qa.days | Where-Object { $_ }); $tot = { param($d) [int]$d.pass + [int]$d.fail + [int]$d.nt + [int]$d.oos }
  $kinds = @(@('pass', 'PASS', 'q-p'), @('fail', 'FAIL', 'q-f'), @('nt', 'NOT_TESTED', 'q-n'), @('oos', 'OUT_OF_SCOPE', 'q-o'))
  $sm = @{}; foreach ($kd in $kinds) { $kn = $kd[0]; $sm[$kn] = [int](@($ds | ForEach-Object { [int](Get-KitMember $_ $kn) }) + 0 | Measure-Object -Sum).Sum }
  $n = $sm.pass + $sm.fail + $sm.nt + $sm.oos; if (-not $n) { return }
  $inScope = $sm.pass + $sm.fail + $sm.nt; $pct = if ($inScope) { "$([math]::Round(100 * $sm.pass / $inScope))<small>% pass</small>" } else { '—<small> pass</small>' }   # OUT_OF_SCOPE never counts against the pass rate
  $mx = [math]::Max(1, (@($ds | ForEach-Object { & $tot $_ }) + 0 | Measure-Object -Maximum).Maximum); $ic = [cultureinfo]::InvariantCulture; $today = $At.ToString('yyyy-MM-dd')
  $cols = @(foreach ($d in $ds) { $t = & $tot $d; $dl = try { ([datetime]$d.day).ToString('ddd dd', $ic) } catch { $d.day }
      "<span class='dbc$(if (-not $t) { ' z' })' title='$(& $e "$dl · $(@($d.runs).Count) runs · $(@($kinds | ForEach-Object { "$([int](Get-KitMember $d ($_[0]))) $($_[1])" }) -join ' · ')")'><b>$(if ($t) { $t } else { '—' })</b><i class=qs style='height:calc((100% - 12px) * $(& $n1 (100 * $t / $mx)) / 100)'>$(@($kinds | Where-Object { [int](Get-KitMember $d ($_[0])) } | ForEach-Object { "<i class=$($_[2]) style='flex:$([int](Get-KitMember $d ($_[0])))'></i>" }) -join '')</i></span>" })
  $axis = @($ds | ForEach-Object { if ($_.day -eq $today) { '<span class=x>today</span>' } else { "<span>$(try { ([datetime]$_.day).ToString('ddd', $ic) } catch { $_.day })</span>" } }) -join ''
  $legend = @($kinds | Where-Object { $sm[$_[0]] } | ForEach-Object { "<span class=ql><i class=$($_[2])></i>$($_[1]) $($sm[$_[0]])</span>" }) -join ''
  $cz = @((Get-KitProps $qa.causes) | Where-Object { [int]$_.Value } | Sort-Object { - [int]$_.Value } | ForEach-Object { "$(& $e $_.Name) $([int]$_.Value)" })
  "<div class=st data-fit><div class=k>Test runs, 7 days</div><div class=v>$n<small> checks · </small>$pct</div>$(if ($cz.Count) { "<div class=s>NOT_TESTED: $($cz -join ' · ')</div>" })" +
  "<figure class='dbr qbr'><div class=dbw role=img aria-label='checks per day, 7 days'>$($cols -join '')</div><div class=dbx>$axis</div><figcaption>$legend</figcaption></figure></div>"
}
# page JS of these cards: the idle-rows fold; links into the kit's own pages (a[data-dw]: run steps, reports) open in an in-page
# drawer (an iframe: file:// pages too; Esc, the close button or a backdrop click closes it), never navigating away (kitbag.py ui-check: LINK)
function Get-KitStatsJs {
  "(function(){var d=document;d.addEventListener('click',function(x){var b=x.target.closest('.gkx');if(!b)return;b.setAttribute('aria-expanded',b.parentNode.classList.toggle('gio'))});" +
  "var dw=d.createElement('dialog');dw.className='drw';dw.setAttribute('aria-label','Linked page');dw.innerHTML='<div class=dwh><b></b><button type=button class=ib aria-label=`"Close (Esc)`" title=`"Close (Esc)`">&#10005;</button></div><iframe title=`"Linked page`"></iframe>';d.body.appendChild(dw);var fr=dw.querySelector('iframe');" +
  "d.addEventListener('click',function(x){var a=x.target.closest('a[data-dw]');if(!a)return;x.preventDefault();dw.querySelector('b').textContent=a.dataset.dw||a.textContent;fr.src=a.getAttribute('href');dw.showModal()});" +
  "dw.querySelector('button').onclick=function(){dw.close()};dw.addEventListener('click',function(x){if(x.target==dw)dw.close()});dw.addEventListener('close',function(){fr.src='about:blank'});" +
  # Resources · 24 h: group fold and metric switch, both kept in localStorage
  "function rp(r,m){r.dataset.m=m;r.querySelectorAll('.rgt button').forEach(function(z){z.setAttribute('aria-pressed',z.dataset.m==m)})}function rf(g,c){g.classList.toggle('cl',c);var b=g.querySelector('.rgb');if(b)b.setAttribute('aria-expanded',!c)}" +
  "d.addEventListener('click',function(x){var b=x.target.closest('.rgb'),t=x.target.closest('.rgt button'),g,c;if(b){g=b.closest('.rgg');c=!g.classList.contains('cl');rf(g,c);try{localStorage.setItem('kc-'+g.dataset.g,c?'1':'0')}catch(e){}}else if(t){rp(t.closest('.rgx'),t.dataset.m);try{localStorage.setItem('kc-rm',t.dataset.m)}catch(e){}}});" +
  "try{d.querySelectorAll('.rgg[data-g]').forEach(function(g){var v=localStorage.getItem('kc-'+g.dataset.g);if(v!==null)rf(g,v=='1')});var m=localStorage.getItem('kc-rm');if(m)d.querySelectorAll('.rgx').forEach(function(r){rp(r,m)})}catch(e){}})()"
}
# CSS of these cards (appended to the page's)
function Get-KitStatsCss {
  '@media(min-width:700px){.gks.w1{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) max-content}.gks.w3{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(3,max-content)}.gks.w5{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(5,max-content)}}:is(.gks.w1,.gks.w3,.gks.w5) .gn{white-space:normal;overflow-wrap:anywhere;max-width:260px}' +
  '@media(max-width:699px){.gks.w1 .gk{grid-template-columns:minmax(0,1fr)}.gks.w3 .gk{grid-template-columns:repeat(3,minmax(0,1fr))}.gks.w5 .gk{grid-template-columns:repeat(5,minmax(0,1fr))}}' +
  '.gks .gn small{color:var(--mt);font-weight:500;font-size:11px;margin-left:6px}.rsh .gk.orphan>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.rsh .gk.orphan>.gs{outline:1px dashed color-mix(in srgb,var(--watch) 60%,var(--ln));outline-offset:1px}' +
  # disk writes: muted sage cells; the 7-day block slate over sage
  '.hm.ws:not(.sp) i{background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}.rsh .gk.gl0>.hm{height:19px}' +
  '.cpg{margin-top:6px}:is(.cpg,.fhm) .gk.gl0>*{border-top:1px solid var(--ln);padding-top:2px}.gks .gc small{color:var(--mt);font-weight:500}.cpg .gk.hot>.gn,.cpg .gk.hot>.gc:nth-last-child(15){color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}.cpg .gk.warn>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}' +
  # heatmap kinds: split CPU (top, slate) over RAM (bottom, sage); flag counts coloured by level; the idle-rows fold
  # a cell's number: dark text on a dark shade (hi, --hmt); split cells: CPU number over RAM number
  '.hm i.hi,.hm i>.hi{color:var(--hmt,var(--fg))}.hm.sp{height:26px}.hm.sp i{display:grid;grid-template-rows:1fr 1fr;font-size:9.5px;line-height:13px;background:linear-gradient(color-mix(in srgb,var(--slate) var(--a),var(--sf2)) 0 50%,color-mix(in srgb,var(--sage2) var(--b),var(--sf2)) 50% 100%)}.hm.sp i>span{overflow:hidden}' +
  '.hm.fh{height:17px}.hm.fh i{line-height:17px}.hm.fh.l-act i{background:color-mix(in srgb,var(--act) var(--a),var(--sf2))}.hm.fh.l-watch i{background:color-mix(in srgb,var(--watch) var(--a),var(--sf2))}.hm.fh.l-fixed i{background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}.hm.fh.l-mr i{background:color-mix(in srgb,var(--sage) var(--a),var(--sf2))}' +
  '.fhm .gk.gl0>.hm.fh{height:20px}.fhm .gk.fk>.gn{padding-left:12px;font-weight:500;color:var(--mt)}.fhm .gk.l-act:not(.fk)>.gn{color:color-mix(in srgb,var(--act) 60%,var(--fg))}.fhm .gk.l-watch:not(.fk)>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.fhm .gk.l-fixed:not(.fk)>.gn{color:var(--sage2)}' +
  '.gkx{grid-column:1/-1;justify-self:start;background:none;border:0;padding:2px 0;color:var(--mt);font:inherit;cursor:pointer}.gkx::before{content:"\25B8  "}.gkx[aria-expanded=true]::before{content:"\25BE  "}.gkx small{font-size:inherit}.gki{display:none}.gks.gio>.gki{display:contents}' +
  '.lgk{display:inline-block;width:8px;height:8px;border-radius:2px;margin:0 3px 0 6px;vertical-align:-1px}.lgk:first-child{margin-left:0}.lgk.c{background:var(--slate)}.lgk.r{background:var(--sage2)}' +
  '.rsh .gn small.bt{display:block;margin-left:0}' +
  # one resources view: metric switch (only the chosen strip and columns show), folding groups with a count and the worst state
  '.rgx[data-m=c] [data-mv=w],.rgx[data-m=c] [data-mv=q],.rgx[data-m=w] [data-mv=c],.rgx[data-m=w] [data-mv=q],.rgx[data-m=q] [data-mv=c],.rgx[data-m=q] [data-mv=w]{display:none}.rgg{display:contents}.rgg.cl>.gk:not(.rgh){display:none}' +
  '.rgh>.rgb{grid-column:1/-1}.rgb{all:unset;box-sizing:border-box;cursor:pointer;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px;border-top:1px solid var(--ln);padding-top:4px}.rgb::before{content:"\25B8";color:var(--mt)}.rgg:not(.cl) .rgb::before{content:"\25BE"}.rgb .gn0{font-weight:650}.rgb .gcn{color:var(--mt)}.rgb:focus-visible{outline:2px solid var(--sage);outline-offset:2px}' +
  '.rgt{display:flex;flex-wrap:wrap;gap:4px;margin:2px 0 4px}.rgt button{all:unset;cursor:pointer;padding:1px 9px;border:1px solid var(--ln);border-radius:10px;font-size:11.5px;color:var(--mt)}.rgt button[aria-pressed=true]{background:var(--sf2);color:var(--fg);border-color:var(--sage2)}.rgt button:focus-visible{outline:2px solid var(--sage)}' +
  '.rsh .gc.hot{color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}.rsh .gc.warn{color:color-mix(in srgb,var(--watch) 55%,var(--fg));font-weight:650}' +
  # lane grid (K74): muted cells, amber = behind, sage +N = test merges, outline = in use
  '.lng{display:grid;grid-template-columns:minmax(0,max-content) repeat(var(--n),minmax(30px,1fr));gap:2px;margin-top:6px;font-size:11.5px;font-variant-numeric:tabular-nums}.lnh{font-size:10.5px;color:var(--mt);text-align:center;overflow-wrap:anywhere}.lnn{padding-right:6px;line-height:20px;overflow-wrap:anywhere}' +
  '.lnc{min-height:20px;line-height:20px;text-align:center;border-radius:3px;color:var(--mt)}.lnc.on{background:var(--sf2)}.lnc.bh{background:color-mix(in srgb,var(--watch) 22%,var(--sf2));color:color-mix(in srgb,var(--watch) 55%,var(--fg));font-weight:600}.lnc small{margin-left:3px;font-size:10px;font-weight:600;color:var(--sage2)}.lnc.kp{box-shadow:inset 0 0 0 1px color-mix(in srgb,var(--fg) 22%,transparent)}' +
  '.lnk{font-size:10.5px;color:var(--mt);margin-top:3px}.lgk.lb{background:color-mix(in srgb,var(--watch) 40%,var(--sf2))}.lgk.lm{background:var(--sage2)}.lcp>.ya{z-index:1}.sch{margin-top:6px;align-items:center}.sch .lnk{margin:0 0 0 4px}.sch .chip{font-weight:500;letter-spacing:0}' +
  'dialog.drw{position:fixed;inset:0 0 0 auto;margin:0;height:100dvh;max-height:none;width:min(1100px,94vw);max-width:none;padding:0;border:0;border-left:1px solid var(--ln);background:var(--bg);color:var(--fg)}dialog.drw[open]{display:flex;flex-direction:column}dialog.drw::backdrop{background:rgba(0,0,0,.35)}.dwh{display:flex;align-items:center;gap:8px;padding:6px 12px;border-bottom:1px solid var(--ln)}.dwh b{flex:1;font-size:13px;overflow-wrap:anywhere}.drw iframe{flex:1;border:0;width:100%;background:var(--bg)}' +
  '.nod{font-size:10.5px;color:var(--mt);padding:10px 0;text-align:center}' +
  '.cpt{margin-top:6px}.cpo{display:grid;grid-template-columns:minmax(0,1fr) max-content max-content;gap:2px 12px;font-size:12px;padding:2px 0;border-top:1px solid var(--ln)}.cpo .cn0{overflow-wrap:anywhere}.cpo small{color:var(--mt)}.cpo.hot .gc{color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}' +
  '.dbc .qs{display:flex;flex-direction:column-reverse;overflow:hidden;background:none}.qs>i{display:block;min-height:2px;border-radius:0}.qs>.q-p,.ql>.q-p{background:var(--sage)}.qs>.q-f,.ql>.q-f{background:var(--act)}.qs>.q-n,.ql>.q-n{background:var(--watch)}.qs>.q-o,.ql>.q-o{background:color-mix(in srgb,var(--mt) 35%,var(--sf2))}' +
  '.qbr figcaption{display:flex;flex-wrap:wrap;gap:0 8px;margin-top:2px}.ql{white-space:nowrap}.ql i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:3px;vertical-align:-1px}'
}
# ---- shells: progress of agents' background shells without a service or new files (owner 2026-11-18): output file tail, CPU + IO samples; the sweep: supervise_resources.ps1 shells
# the last $Bytes of a file another process may be writing ('' when unreadable)
function Read-KitFileTail([string]$Path, [int]$Bytes) {
  try { $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete'); try { $n = [int][math]::Min($fs.Length, $Bytes); $null = $fs.Seek(-$n, 'End'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n); [Text.Encoding]::UTF8.GetString($b, 0, $got) } finally { $fs.Dispose() } } catch { '' }
}
# a background shell's output file: "Output is being written to: <path>" in the tool_result of its tool_use id ('' until written)
function Find-KitShellOutputPath([string]$Text, [string]$ToolUseId) {
  if (-not $ToolUseId -or -not $Text) { return '' }
  $i = $Text.IndexOf("`"tool_use_id`":`"$ToolUseId`"", [StringComparison]::Ordinal); if ($i -lt 0) { return '' }
  $s0 = $Text.LastIndexOf("`n", $i) + 1; $e = $Text.IndexOf("`n", $i); if ($e -lt 0) { $e = $Text.Length }
  if ($Text.Substring($s0, $e - $s0) -match 'Output is being written to: ((?:[^"\\]|\\\\)+?\.output)') { return ($Matches[1] -replace '\\\\', '\') }; ''
}
# a shell's progress without reading its output whole: size, last write, last non-empty line (4 KB tail, ANSI stripped, masked, 160 chars)
function Get-KitShellOutput([string]$Path) {
  if (-not $Path) { return $null }; $fi = [IO.FileInfo]::new($Path); if (-not $fi.Exists) { return $null }
  $tail = (Read-KitFileTail $Path 4KB) -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
  $last = "$(@($tail -split '\r?\n|\r' | Where-Object { $_.Trim() })[-1])".Trim(); $last = Protect-KitText $last
  if ($last.Length -gt 160) { $last = $last.Substring(0, 159) + '…' }
  [pscustomobject]@{ bytes = $fi.Length; ticks = $fi.LastWriteTimeUtc.Ticks; at = $fi.LastWriteTime; last = $last }
}
# CPU seconds + IO bytes of these pids now: one OS query (Linux IO from /proc; none elsewhere)
# -PsLines: canned `ps -o pid= -o time=` output (tests); Io = all bytes read + written, pipes included (Windows TransferCount, Linux rchar + wchar)
function Get-KitProcSample([int[]]$Ids, [string[]]$PsLines) {
  $ids1 = @($Ids | Select-Object -Unique); if (-not $ids1.Count) { return }
  if ($KitIsWindows -and $null -eq $PsLines) {
    for ($i = 0; $i -lt $ids1.Count; $i += 40) {   # a short WQL filter per 40 pids (one long OR list can fail, and SilentlyContinue would hide it)
      $flt = @($ids1[$i..([math]::Min($i + 39, $ids1.Count - 1))] | ForEach-Object { "ProcessId=$_" }) -join ' OR '
      foreach ($p in @(Get-CimInstance Win32_Process -Filter $flt -Property ProcessId, KernelModeTime, UserModeTime, ReadTransferCount, WriteTransferCount -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{ Id = [int]$p.ProcessId; Cpu = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7; Io = [double]$p.ReadTransferCount + [double]$p.WriteTransferCount } } }
    return
  }
  if ($null -eq $PsLines) { $PsLines = @(ps -o pid= -o time= -p ($ids1 -join ',') 2>$null) }
  foreach ($l in $PsLines) {
    if ($l -notmatch '^\s*(\d+)\s+(?:(\d+)-)?([\d:.]+)') { continue }
    $id = [int]$Matches[1]; $days = [int]$Matches[2]; $sec = 0.0; foreach ($part in $Matches[3] -split ':') { $sec = 60 * $sec + [double]$part }; $sec += 86400.0 * $days   # [dd-][hh:]mm:ss
    $io = $null; try { if ([IO.File]::ReadAllText("/proc/$id/io") -match '(?m)^rchar:\s*(\d+)[\s\S]*?^wchar:\s*(\d+)') { $io = [double]$Matches[1] + [double]$Matches[2] } } catch { }
    [pscustomobject]@{ Id = $id; Cpu = $sec; Io = $io }
  }
}
# progress now: CPU + IO growth of each tree between two samples $GapSeconds apart in this sweep (key -> cpu, io, pct of one core)
function Measure-KitTreeDelta([hashtable]$Trees, [scriptblock]$Sampler, [double]$GapSeconds) {
  $res = @{}; $ids = @($Trees.Values | ForEach-Object { @($_) } | ForEach-Object { [int]$_ }); if (-not $ids.Count) { return $res }
  $sa = @{}; foreach ($x in @(& $Sampler $ids)) { if ($x) { $sa[[int]$x.Id] = $x } }
  if ($GapSeconds -gt 0) { Start-Sleep -Milliseconds ([int](1000 * $GapSeconds)) }
  $sb = @{}; foreach ($x in @(& $Sampler $ids)) { if ($x) { $sb[[int]$x.Id] = $x } }
  foreach ($k in @($Trees.Keys)) {
    $dc = 0.0; $di = 0.0; $tot = $null; $hit = $false
    foreach ($id in @($Trees[$k])) { $x0 = $sa[[int]$id]; $x1 = $sb[[int]$id]; if (-not $x0 -or -not $x1) { continue }; $hit = $true; $dc += [math]::Max(0.0, [double]$x1.Cpu - [double]$x0.Cpu); if ($null -ne $x0.Io -and $null -ne $x1.Io) { $di += [math]::Max(0.0, [double]$x1.Io - [double]$x0.Io); $tot = [double]$tot + [double]$x1.Io } }
    if ($hit) { $res[$k] = [pscustomobject]@{ cpu = $dc; io = $di; ioTotal = $tot; pct = $(if ($GapSeconds -gt 0) { [int][math]::Round(100 * $dc / $GapSeconds) } else { 0 }) } }
  }
  $res
}
# bossy.ps1 shells [-Json]: the live agent shells with progress (one sample pair now + the last sweep's quiet clock), then the ones
# ended within supervise.finishedMinutes; read-only (no kill, nothing written)
function Invoke-Shells {
  param([switch]$Json, [double]$GapSeconds = 2)
  $sst = try { Read-KitText (Get-KitPath supervise-state) | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $sst) { $sst = @{} }
  $now0 = Get-Date; $sw = Get-KitShellSweep $sst $now0 -GapSeconds $GapSeconds -ReadOnly -SampleAll
  $ended = @($sst.shells.Values | Where-Object { $_ -is [Collections.IDictionary] -and $_.ended } | Sort-Object { -[long]$_.ended } | ForEach-Object {
    [pscustomobject]@{ owner = "$($_.owner)"; short = "$($_.short)"; endedMin = [math]::Round(($now0.Ticks - [long]$_.ended) / [double][TimeSpan]::TicksPerMinute); killed = [bool]$_.killed; last = "$($_.last)" } })
  if ($Json) { [pscustomobject]@{ at = $now0.ToString('o'); live = @($sw.rows); ended = $ended; flags = @($sw.flags) } | ConvertTo-Json -Depth 4; return }
  if (-not @($sw.rows).Count -and -not $ended.Count) { 'shells: none running'; return }
  $c = { param($t, [int]$m) $t1 = ("$t" -replace '\s+', ' ').Trim(); if ($t1.Length -gt $m) { $t1.Substring(0, $m - 1) + '…' } else { $t1 } }
  if (@($sw.rows).Count) {
    Format-KitMdTable @('PID', 'Owner', 'Age min', 'State', 'CPU now', 'CPU s', 'IO MB', 'Quiet min', 'Output', 'Command', 'Last line') @($sw.rows | Sort-Object { $_.state -eq 'running' }, { -$_.age } | ForEach-Object {
      , @($_.pid, (& $c $_.owner 30), $_.age, $_.state, $(if ($null -ne $_.cpuNow) { "$($_.cpuNow)%" } else { '—' }), $_.cpu, $(if ($null -ne $_.ioMB) { $_.ioMB } else { '—' }), $_.quiet, $(if ($null -ne $_.outKB) { "$($_.outKB) KB, $($_.outAge) min ago" } else { '—' }), (& $c $_.short 60), (& $c $_.last 80)) })
  }
  if ($ended.Count) { ''; "ended (last $(Get-KitSetting 'supervise.finishedMinutes' 30) min):"; Format-KitMdTable @('Owner', 'Ended min ago', 'Command', 'Last line') @($ended | ForEach-Object { , @((& $c $_.owner 30), "$($_.endedMin)$(if ($_.killed) { ' (killed)' })", (& $c $_.short 60), (& $c $_.last 80)) }) }
  foreach ($fl in @($sw.flags)) { "$($fl.level) · $($fl.what) -> $($fl.action)" }
}
