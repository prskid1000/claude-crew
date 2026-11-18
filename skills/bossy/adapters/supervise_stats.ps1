<#
supervise_stats.ps1 (core): the supervise page's history graphs from the logs the kit already writes, dot-sourced by bossy.ps1
(skills/bossy/adapters/): the build gate per kind (builds log), lease waits per resource (leases log, builds log, local-env
lease-wait events, live queues), test-run results per day (qa-runs results.json), CPU + RAM per lane process and the top other
processes (one process snapshot per sweep), flags per hour; their heatmap cards (shared cells, idle-row fold, card fold) and the
page drawer render inside Format-KitSuperviseHtml.
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L12 gate · L64 waits · L90 qa · L106 cpu · L141 writes (owner 2026-11-18 · L194 cards · L379 flags
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
# beat, summed per owner over the last hour; owner = the nearest ancestor that is a held resource, an agent's shell or a lane service,
# else the tree's root under the OS (its own name + pid). A pid seen before counts its growth, one started since the last beat all of
# it, an older unseen one nothing (no history spike); an exited one drops out. writes.softGBPerHour -> WATCH, writes.hardGBPerHour -> ACT
function Get-KitWriteProcs {   # the sweep's processes + Write (bytes); none off Windows
  if (-not $KitIsWindows) { return @() }
  $wb = @{}; foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, WriteTransferCount -ErrorAction SilentlyContinue)) { $wb[[int]$c.ProcessId] = [double]$c.WriteTransferCount }
  @(Get-KitSweepProcs | Where-Object { $wb.ContainsKey($_.Id) } | ForEach-Object { $_ | Add-Member -Force -NotePropertyName Write -NotePropertyValue $wb[$_.Id] -PassThru })
}
# $Procs: @{ Id; ParentId; Name; CommandLine; Created; Write }; $Owners: @{ pid; label } roots; -> @{ at; acc; samples; hour; flags }
function Update-KitWriteStats($Prior, [datetime]$Now, $Procs, $Owners = @()) {
  $key = { param($p) "$($p.Id)|$(if ($p.Created) { ([datetime]$p.Created).ToUniversalTime().Ticks })" }
  $osRoot = '^(System|Idle|smss|csrss|wininit|winlogon|services|svchost|explorer|userinit|init|systemd|launchd)(\.exe)?$'
  $byId = @{}; $acc = [ordered]@{}; foreach ($p in @($Procs | Where-Object { $_ -and $null -ne $_.Write })) { $byId[[int]$p.Id] = $p; $acc[(& $key $p)] = [double]$p.Write }
  $own = @{}; foreach ($o in @($Owners | Where-Object { $_ -and [int]$_.pid -gt 0 -and $_.label })) { if (-not $own.ContainsKey([int]$o.pid)) { $own[[int]$o.pid] = "$($o.label)" } }
  $ownerOf = { param($p) $q = $p
    for ($n = 0; $n -lt 16; $n++) { if ($own.ContainsKey([int]$q.Id)) { return $own[[int]$q.Id] }
      $up = $byId[[int]$q.ParentId]; if (-not $up -or $up.Id -eq $q.Id -or "$($up.Name)" -match $osRoot -or ($up.Created -and $q.Created -and [datetime]$up.Created -gt [datetime]$q.Created)) { break }; $q = $up }
    "$($q.Name) pid $($q.Id)" }   # a reused parent id starts after its child: the tree stops there
  $samples = @($Prior.samples | Where-Object { $_ -and [datetime]$_.at -ge $Now.AddDays(-1) -and [datetime]$_.at -lt $Now })
  $prevAt = try { [datetime]$Prior.at } catch { $null }; $dt = if ($prevAt) { ($Now - $prevAt).TotalSeconds } else { 0 }
  if ($dt -gt 0 -and $dt -le 7200) {   # an older snapshot: no sample (its deltas span hours)
    $gb = @{}; $top = @{}
    foreach ($p in $byId.Values) { if ([int]$p.Id -le 4) { continue }   # Idle / System: the cache flush of every process again
      $was = Get-KitMember $Prior.acc (& $key $p)
      $d = if ($null -ne $was) { [double]$p.Write - [double]$was } elseif ($p.Created -and [datetime]$p.Created -gt $prevAt) { [double]$p.Write } else { 0 }
      if ($d -le 0) { continue }
      $ow = & $ownerOf $p; $gb[$ow] = [double]$gb[$ow] + $d / 1GB
      if (-not $top[$ow] -or $d -gt $top[$ow].b) { $cl = Protect-KitText ("$(if ($p.CommandLine) { $p.CommandLine } else { $p.Name })" -replace '\s+', ' '); $top[$ow] = @{ b = $d; c = $cl.Substring(0, [math]::Min(120, $cl.Length)) } } }
    $samples += [ordered]@{ at = $Now.ToString('o'); s = [int]$dt; w = @($gb.Keys | Where-Object { $gb[$_] -ge 0.001 } | ForEach-Object { [ordered]@{ n = "$_"; g = [math]::Round($gb[$_], 3); c = $top[$_].c } }) }   # w: one row per owner
  }
  $hr = @{}; $cmd = @{}
  foreach ($s in @($samples | Where-Object { [datetime]$_.at -gt $Now.AddHours(-1) })) { foreach ($r in @($s.w | Where-Object { $_ })) { $hr["$($r.n)"] = [double]$hr["$($r.n)"] + [double]$r.g; $cmd["$($r.n)"] = "$($r.c)" } }
  $hour = @($hr.Keys | Sort-Object { - $hr[$_] } | ForEach-Object { [ordered]@{ label = $_; gb = [math]::Round($hr[$_], 2); cmd = $cmd[$_] } })
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  $flags = @(foreach ($h in @($hour | Where-Object { $_.gb -ge $soft })) { $lv = if ($h.gb -ge $hard) { 'ACT' } else { 'WATCH' }
      [pscustomobject]@{ level = $lv; kind = 'WRITES'; who = $h.label; what = "WRITES $($h.label): $($h.gb) GB written in the last hour (soft $soft / hard $hard GB); top: $($h.cmd)"
        action = "$(if ($lv -eq 'ACT') { 'Stop it now, then ' })tell its owner: no bulk data, dumps, tree copies, reinstalls or big captures (AGENTS.md); links / moves, small fixtures, read-only checks." } })
  [ordered]@{ at = $Now.ToString('o'); acc = $acc; samples = $samples; hour = $hour; flags = $flags }
}
# supervise hook: the owners from this sweep (resources, shells, lane services); <runtime>/cache/supervise-writes.json between beats
function Get-KitSuperviseFlagsWrites([switch]$AutoFix) {
  $cf = Join-Path (Get-KitPath cache -Create) 'supervise-writes.json'
  if (-not $KitIsWindows) { if (-not (Test-Path -LiteralPath $cf)) { Set-Content -LiteralPath $cf '{}'; [pscustomobject]@{ info = 'disk writes per agent: no per-process I/O counters on this OS (Windows only)' } }; return }
  $prior = try { Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json } catch { $null }
  $owners = @(@(Get-Variable res -ValueOnly -ErrorAction SilentlyContinue) | Where-Object { $_ -and $_.pid } | ForEach-Object { @{ pid = [int]$_.pid; label = $(if ("$($_.by)" -and "$($_.by)" -notmatch '^(no lease|free|parked)') { "$($_.by) ($($_.name))" } else { "$($_.name)" }) } }) +
    @(@($script:KitShellRows) | Where-Object { $_ -and $_.pid } | ForEach-Object { @{ pid = [int]$_.pid; label = "$(if ($_.owner) { $_.owner } else { 'unknown agent' }) shell" } }) +
    @(@(Invoke-KitHooks Get-KitCpuGroups) | Where-Object { $_ -and $_.pid } | ForEach-Object { @{ pid = [int]$_.pid; label = "lane $($_.name)" } })
  $w = Update-KitWriteStats $prior (Get-Date) @(Get-KitWriteProcs) $owners
  Write-KitAtomic $cf ([ordered]@{ at = $w.at; acc = $w.acc; samples = $w.samples; hour = $w.hour } | ConvertTo-Json -Depth 6 -Compress)
  $w.flags
}

# ---- cards: render inside Format-KitSuperviseHtml and use its helpers ($e, $n1, $fmt, $icv, $spark, $dots, $nowCard, $at, $st, $nw, $j, $l24, $fold)
# every heatmap: Format-KitHourHead over a row of Format-KitHeatCells each, rows through Format-KitHeatRows (idle rows folded), the card
# through $fold (chevron + count, open state kept; busy open, idle closed)
# the 24 hour labels over a heatmap: every 6th clock hour, "now" over the last cell
function Format-KitHourHead([datetime]$H0) { @(for ($hi = 0; $hi -lt 21; $hi++) { if ($H0.AddHours($hi).Hour % 6 -eq 0) { "<b style='grid-column:$($hi + 1)/span 2'>$($H0.AddHours($hi).ToString('HH'))</b>" } }) + "<b class=nw style='grid-column:23/span 2'>now</b>" -join '' }
# disk writes per owner, the last hour (Update-KitWriteStats hour): a labelled bar each against the hard limit; none: nothing
function Format-KitWritesCard($W) {
  $rows = @($W.hour | Where-Object { $_ -and [double]$_.gb -ge 0.01 } | Select-Object -First 8); if (-not $W) { return '' }
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  $body = if ($rows.Count) { @($rows | ForEach-Object { $g = [double]$_.gb; "<div class=s>$(& $e "$($_.label)$(if ($_.cmd) { ": $($_.cmd)" })")</div>" + (& $meter $g $hard "$(& $n1 $g) GB/h" $(if ($g -ge $hard) { 'act' } elseif ($g -ge $soft) { 'watch' } else { 'slate' })) }) -join '' } else { '<div class=s>no owner wrote 10 MB in the last hour</div>' }
  $tone = if (@($rows | Where-Object { [double]$_.gb -ge $hard }).Count) { ' hot' } elseif (@($rows | Where-Object { [double]$_.gb -ge $soft }).Count) { ' warn' } else { '' }
  "<div class='st$tone' data-fit><div class=k>Disk writes per agent<small> · last hour · soft $(& $n1 $soft) / hard $(& $n1 $hard) GB</small></div>$body</div>"
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
# B, text B]) of one cell for another scale (a count, CPU over RAM); $Cls: the map's class (its colours)
function Format-KitHeatCells($Hours, [datetime]$H0, [string]$Aria, [scriptblock]$Tip, [scriptblock]$Cell = $null, [string]$Cls = '') {
  $hs = @($Hours); "<span class='gs hm$(if ($Cls) { " $Cls" })' role=img aria-label='$(& $e $Aria)'>$(@(for ($hi = 0; $hi -lt 24; $hi++) { $hv = if ($hi -lt $hs.Count) { @($hs[$hi]) } else { @(0, 0, 0, '') }
    $cv = if ($Cell) { @(& $Cell $hv) } else { @((Get-KitHeatShade ([double]$hv[1] / 60)), (Format-KitHeatNum $hv[1])) }
    $tp = "$($H0.AddHours($hi).ToString('HH:00'))$(if ($hi -eq 23) { ' (now)' }) · $(& $Tip $hv)"
    if ($cv.Count -ge 4) { Format-KitHeatCell $cv[0] "$($cv[1])" $tp ($hi -eq 23) $cv[2] "$($cv[3])" } else { Format-KitHeatCell $cv[0] "$($cv[1])" $tp ($hi -eq 23) } }) -join '')</span>" }
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
# lease waits: one line per resource (24 h heatmap of minutes waited · waits · minutes · longest), the gate card's style
function Format-KitWaitCard($w) {
  $rs = @($w.rows | Where-Object { $_ }); $h0 = try { [datetime]$w.h0 } catch { $at.Date.AddHours($at.Hour - 23) }
  # owner 2026-11-18: one lease waits on all of a lane's services at once: "<lane> · <service>" rows with identical hours and totals collapse to "<lane>"
  $rs = @($rs | Group-Object { $nm0 = "$($_.name)"; $ix = $nm0.LastIndexOf(' · '); if ($ix -gt 0) { "$($nm0.Substring(0, $ix))|$(ConvertTo-Json @($_.hours) -Depth 6 -Compress)|$($_.n)|$($_.min)|$($_.max)" } else { [guid]::NewGuid().ToString() } } | ForEach-Object {
      $g = @($_.Group); if ($g.Count -lt 2) { $g[0]; return }; $nm0 = "$($g[0].name)"; $c = $g[0].PSObject.Copy(); $c.name = $nm0.Substring(0, $nm0.LastIndexOf(' · ')); $c })
  if (-not $rs.Count) { return (& $fold 'waits' 'Lease waits · 24 h' 0 '' -tag h4 -cls 'sub st wt') }   # (0): no agent waited for a lease in 24 h
  $cols = @(@('queue', 'waits, 24 h', ''), @('wait', 'minutes waited, 24 h', 'min'), @('wait', 'longest wait, min', 'max'))
  $head = "<div class='gk gh'><span class=gn>resource · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@($cols | ForEach-Object { "<span class=gc>$(Format-KitIcon $_[0] $_[1])$(if ($_[2]) { "<small>$($_[2])</small>" })</span>" }) -join '')</div>"
  $lines = @(foreach ($r in $rs) { $nm = "$($r.name)"; $vals = @("$([int]$r.n)", (& $n1 $r.min), (& $n1 $r.max))
      [pscustomobject]@{ busy = (Test-KitHeatBusy $r.hours { param($c) [double]@($c)[1] -gt 0 }); html = "<div class=gk><span class=gn title='$(& $e "${nm}: $($vals[0]) waits · $($vals[1]) min · longest $($vals[2]) min")'>$(& $e $nm)</span>$(Format-KitHeatCells $r.hours $h0 "$nm, minutes waited per hour, last 24 h" { param($hv) "$([int]$hv[0]) waits · $(& $n1 $hv[1]) min · longest $(& $n1 $hv[2]) min$(if ("$($hv[3])") { " · $($hv[3])" })" })" +
      (@(for ($ci = 0; $ci -lt 3; $ci++) { "<span class='gc$(if ($vals[$ci] -eq '0') { ' z' })' title='$(& $e "${nm}: $($vals[$ci]) $($cols[$ci][1])")'>$(Format-KitIcon $cols[$ci][0] $cols[$ci][1])$($vals[$ci])</span>" }) -join '') + '</div>' } })
  & $fold 'waits' 'Lease waits · 24 h' (Get-KitHeatCount $lines) "<div class='gks w3'>$head$(Format-KitHeatRows $lines 'resources')</div><div class=hk>shade = minutes agents waited for that resource in the hour · outlined = now · tap a cell for waits and who</div>" -Open:([bool]@($lines | Where-Object busy).Count) -tag h4 -cls 'sub st wt'
}
# Resources · 24 h (owner, 2026-11-17: CPU and RAM per resource in one heatmap): a row per resource, every name of 24 h plus each
# configured lane service (Update-KitCpuStats svc: a stopped one keeps its row); a cell's top half = avg CPU % of the machine (slate),
# the bottom = avg RAM GB (sage; full = the biggest peak, the machine: its total); lease / slot RAM first, else the service's process
# tree; columns CPU now / peak / avg %, RAM now / peak GB; red: over 80% between sweeps 5+ min apart, amber: a peak over 80% in 24 h
function Format-KitResHeat($Cpu, $Resources, $Live, [double]$TotalGB, $MemNowGB = $null) {
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
  $avg = { param($l) if ($l.Count) { [double](@($l) | Measure-Object -Average).Average } else { $null } }; $max = { param($l) [double](@($l) + 0 | Measure-Object -Maximum).Maximum }   # $null kept: a tuple slot, never dropped
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
      $r0 = $cur[$nm]; $by = "$($r0.by)".Trim(); $sub = if (-not $r0) { '' } elseif ($r0.shared) { 'shared · always on' } elseif ($by) { $by } else { 'no live holder' }
      $vals = @($(if ($hasC) { & $n1 $cNow } else { '—' }), $(if ($hasC) { & $n1 $cPk } else { '—' }), $(if ($hasC) { & $n1 $cAvg } else { '—' }), $(if ($null -ne $rNow) { & $n1 $rNow } else { '—' }), $(if ($hasR) { & $n1 $rPk } else { '—' }))
      $tone = if ($hasC -and $last -and (& $hot $cNow $last.s)) { 'hot' } elseif ($cPk -gt 80) { 'warn' } else { '' }
      [pscustomobject]@{ nm = $nm; busy = $isM -or [bool]$r0 -or (Test-KitHeatBusy $hours { param($c) [double]@($c)[1] -ge 0.1 -or [double]@($c)[3] -gt 0 })
        tone = $tone; orphan = $r0 -and -not $r0.shared -and $by -match '^$|\(grace|^no lease$'; sub = $sub; vals = $vals; hours = $hours } })
  $cols = @('now %', 'peak %', 'avg %', 'now GB', 'peak GB')
  $head = "<div class='gk gh'><span class=gn>resource · holder · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@($cols | ForEach-Object { "<span class=gc><small>$_</small></span>" }) -join '')</div>"
  $lane = ''; $items = @(foreach ($r in $rows) { $ln = ("$($r.nm)" -split ' · ')[0]; $first = $r.nm -ne 'whole machine' -and $ln -ne $lane; $lane = $ln; $nm = $r.nm
      [pscustomobject]@{ busy = $r.busy; html = "<div class='gk$(if ($first) { ' gl0' })$(if ($r.tone) { " $($r.tone)" })$(if ($r.orphan) { ' orphan' })'><span class=gn title='$(& $e "${nm}$(if ($r.sub) { " · $($r.sub)" }): $(if ($r.vals[0] -ne '—') { "CPU now $($r.vals[0])% · 24 h peak $($r.vals[1])% · avg $($r.vals[2])% · " } else { 'CPU not sampled: not running, or no process tree of its own (lease, slot, lock, external) · ' })$(if ($r.vals[3] -ne '—') { "RAM now $($r.vals[3]) GB · 24 h peak $($r.vals[4]) GB" } else { 'RAM: not running now' })")'>$(& $e $nm)$(if ($r.sub) { "<small>$(& $e $r.sub)</small>" })</span>" +
        (Format-KitHeatCells $r.hours $h0 "$nm, CPU % and RAM GB per hour, last 24 h" { param($hv) if (-not $hv[0]) { "$nm · no sample" } else { "$nm · $(@(@($(if ($null -ne $hv[1]) { "CPU avg $(& $n1 $hv[1])% · peak $(& $n1 $hv[2])%" }), "RAM $(if ($null -ne $hv[3]) { "$(& $n1 $hv[3]) GB" } else { '—' })") | Where-Object { $_ }) -join ' · ')$(if ("$($hv[4])") { " · $($hv[4])" })$(if ("$($hv[5])") { " · top: $($hv[5])" })" } } { param($hv) @((Get-KitHeatShade ([double]$hv[1] / 100)), (Format-KitHeatNum $hv[1]), (Get-KitHeatShade ([double]$hv[3] / [double]$hv[6])), (Format-KitHeatNum $hv[3])) } 'sp') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.vals[$ci] -in '0', '—') { ' z' })' title='$(& $e "${nm}: $($cols[$ci] -replace ' (%|GB)$') $(if ($ci -lt 3) { 'CPU' } else { 'RAM' }) $($r.vals[$ci]) $(if ($ci -lt 3) { '%' } else { 'GB' })")'>$($r.vals[$ci])</span>" }) -join '') + '</div>' } })
  $tops = @($ss | ForEach-Object { $s0 = $_; @($_.top | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ k = "$($_.pid)|$($_.n)"; n = $_.n; pid = $_.pid; p = [double]$_.p; o = "$($_.o)"; c = "$($_.c)"; at = $s0.at; s = $s0.s; nowS = [bool]($s0 -eq $last) } } } | Group-Object k | ForEach-Object { $gp = @($_.Group | Sort-Object { [datetime]$_.at }); $pk = ($gp | Measure-Object p -Maximum).Maximum
      [pscustomobject]@{ n = $gp[-1].n; pid = $gp[-1].pid; o = @($gp.o | Where-Object { $_ })[-1]; c = $gp[-1].c; now = $(if ($gp[-1].nowS) { $gp[-1].p }); pk = $pk; hot = [bool]@($gp | Where-Object { & $hot $_.p $_.s }).Count } } | Sort-Object { - $_.pk } | Select-Object -First 8)
  $topHtml = if ($tops.Count) { & $fold 'cpu-top' 'Top other processes' $tops.Count ("<div class=cpt><div class=s>10%+ of the machine between two sweeps</div>" + (@($tops | ForEach-Object { "<div class='cpo f$(if ($_.hot) { ' hot' })' title='$(& $e $(if ($_.c) { $_.c } else { $_.n }))'><span class=cn0>$(& $e $_.n) <small>pid $($_.pid)$(if ($_.o) { " · $($_.o)" })</small></span><span class=gc>now $(if ($null -ne $_.now) { "$(& $n1 $_.now)%" } else { '—' })</span><span class=gc>24 h peak $(& $n1 $_.pk)%</span></div>" }) -join '') + '</div>') -Open:([bool]@($tops | Where-Object { $null -ne $_.now }).Count) -tag h4 -cls sub } else { '<div class=s>no other process over 10% of the machine in 24 h</div>' }
  $legend = "<div class=hk><i class='lgk c'></i>top half = avg CPU % of the machine ($([Environment]::ProcessorCount) cores) <i class='lgk r'></i>bottom half = avg RAM (full = the biggest peak, $(& $n1 $ramTop) GB; the machine: its $(& $n1 $TotalGB) GB) · outlined = now · tap a cell for both values, holders and (machine row) the top other processes · dashed = no live holder (released after idle.graceMinutes)</div>"
  & $fold 'res24' 'Resources · 24 h' (Get-KitHeatCount $items) "<div class='gks w5 cpg rsh'>$head$(Format-KitHeatRows $items 'resources')</div>$legend$topHtml" -Open -tag h4 -cls "sub st cpu$(if ($last -and (& $hot $last.all $last.s)) { ' hot' })"
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
# resources held now (Resources and leases): name and holder; none: the live agents' count or "No resource held."
function Format-KitHeldList($Resources, [int]$Active = 0) {   # $Active: live agents (none held while agents run is a count, not idle)
  $rs = @($Resources | Where-Object { $_ } | Sort-Object { -[double]$_.gb }); if (-not $rs.Count) { return "<p class=empty>$(if ($Active) { "$Active agent$(if ($Active -ne 1) { 's' }) active · none holds a lease" } else { 'No resource held.' })</p>" }
  # owner 2026-11-18: one table, a folding group per kind (kind, else the name's first word) with its count; no live holder first,
  # amber, its group open; holder "(branch)" -> its own column, cut with the full text in the tooltip
  $lbl = @{ env = 'env services'; slot = 'worktree slots' }; $ord = @('env', 'browser', 'build', 'slot')
  $its = @($rs | ForEach-Object { $by = "$($_.by)".Trim(); $nm = "$($_.name)"; $kd = "$($_.kind)"
      if ($_.shared) { $kd = 'shared' } elseif (-not $kd -and $nm -match '^(?<k>[a-z]+) (?<r>.+)$') { $kd = $Matches.k; $nm = $Matches.r } elseif (-not $kd) { $kd = 'other' }
      $br = ''; $gr = ''; if ($by -match '^(?<r>.*?)\s*(?<g>\(grace [^()]*\))$') { $by = $Matches.r; $gr = " $($Matches.g)" }   # supervise appends the grace after the branch
      if ($by -match '^(?<h>.*?)\s*\((?<b>[^()\s]+)\)$') { $by = $Matches.h; $br = $Matches.b } elseif ($by -match '^parked: (?<b>\S+)$') { $by = 'parked'; $br = $Matches.b }
      [pscustomobject]@{ k = $kd; n = $nm; o = -not $_.shared -and $by -in '', 'no lease'; h = $(if ($_.shared) { 'shared · always on' } elseif ($by -in '', 'no lease') { "no live holder$gr" } else { "$by$gr" }); b = $br; t = $(if ($_.shared) { '' } else { Get-KitHolderTask $by }) } })
  # a lane's services ("rm·Falcon api", "rm·Falcon web") with the same holder and branch are one lease: one row "rm·Falcon (api, web)"
  $its = @($its | Group-Object { $ix = "$($_.n)".LastIndexOf(' '); if ($_.k -ne 'shared' -and $ix -gt 0) { "$($_.k)|$("$($_.n)".Substring(0, $ix))|$($_.o)|$($_.h)|$($_.b)" } else { [guid]::NewGuid().ToString() } } | ForEach-Object {
      $g = @($_.Group); if ($g.Count -lt 2) { $g[0]; return }; $c = $g[0].PSObject.Copy(); $c.n = "$("$($g[0].n)".Substring(0, "$($g[0].n)".LastIndexOf(' '))) ($(@($g | ForEach-Object { "$($_.n)".Substring("$($_.n)".LastIndexOf(' ') + 1) }) -join ', '))"; $c })
  $gs = @($its | Group-Object k | Sort-Object { $i = [array]::IndexOf($ord, $_.Name); if ($_.Name -eq 'shared') { 99 } elseif ($i -ge 0) { $i } else { 50 } }, Name)
  $hasB = [bool]@($its | Where-Object { $_.b -or $_.t }).Count   # no branch or task on any row: no column
  "<table class=hlt><thead><tr><th>Resource</th><th>Holder(s)</th>$(if ($hasB) { "<th>Branch / task</th>" })</tr></thead>" + (@($gs | ForEach-Object {
        $no = @($_.Group | Where-Object o).Count; $nmG = if ($lbl[$_.Name]) { $lbl[$_.Name] } elseif ($_.Name -in 'shared', 'other') { $_.Name } else { "$($_.Name)s" }
        "<tbody class='grp$(if (-not $no) { ' cl' })' data-g='res-$(& $e $_.Name)'><tr class=gh><th colspan=$(if ($hasB) { 3 } else { 2 })><button type=button class=gtg aria-expanded=$(if ($no) { 'true' } else { 'false' })><span class=gn0>$(& $e $nmG)</span><span class=gcn>$($_.Count)$(if ($no) { " · $no no live holder" })</span></button></th></tr>" +
        (@($_.Group | Sort-Object { -not $_.o }, n | ForEach-Object {
            $bt = @($_.b, $_.t | Where-Object { $_ }) -join ' · '; if ($bt.Length -gt 40) { $bs = $bt.Substring(0, 39) + '…' } else { $bs = $bt }
            "<tr class='f$(if ($_.o) { ' nh' })'><td>$(& $e $_.n)</td><td>$(& $e $_.h)</td>$(if ($hasB) { "<td$(if ($bt) { " title='$(& $e $bt)'" })>$(if ($bt) { & $e $bs } else { & $e '—' })</td>" })</tr>" }) -join '') + '</tbody>' }) -join '') + '</table>'
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
  "dw.querySelector('button').onclick=function(){dw.close()};dw.addEventListener('click',function(x){if(x.target==dw)dw.close()});dw.addEventListener('close',function(){fr.src='about:blank'})})()"
}
# CSS of these cards (appended to the page's)
function Get-KitStatsCss {
  '@media(min-width:700px){.gks.w1{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) max-content}.gks.w3{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(3,max-content)}.gks.w5{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(5,max-content)}}:is(.gks.w1,.gks.w3,.gks.w5) .gn{white-space:normal;overflow-wrap:anywhere;max-width:260px}' +
  '@media(max-width:699px){.gks.w1 .gk{grid-template-columns:minmax(0,1fr)}.gks.w3 .gk{grid-template-columns:repeat(3,minmax(0,1fr))}.gks.w5 .gk{grid-template-columns:repeat(5,minmax(0,1fr))}}' +
  '.gks .gn small{color:var(--mt);font-weight:500;font-size:11px;margin-left:6px}.rsh .gk.orphan>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.rsh .gk.orphan>.gs{outline:1px dashed color-mix(in srgb,var(--watch) 60%,var(--ln));outline-offset:1px}' +
  '.cpg{margin-top:6px}:is(.cpg,.fhm) .gk.gl0>*{border-top:1px solid var(--ln);padding-top:2px}.gks .gc small{color:var(--mt);font-weight:500}.cpg .gk.hot>.gn,.cpg .gk.hot>.gc:nth-last-child(5){color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}.cpg .gk.warn>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}' +
  # heatmap kinds: split CPU (top, slate) over RAM (bottom, sage); flag counts coloured by level; the idle-rows fold; held list
  # a cell's number: dark text on a dark shade (hi, --hmt); split cells: CPU number over RAM number
  '.hm i.hi,.hm i>.hi{color:var(--hmt,var(--fg))}.hm.sp{height:26px}.hm.sp i{display:grid;grid-template-rows:1fr 1fr;font-size:9.5px;line-height:13px;background:linear-gradient(color-mix(in srgb,var(--slate) var(--a),var(--sf2)) 0 50%,color-mix(in srgb,var(--sage2) var(--b),var(--sf2)) 50% 100%)}.hm.sp i>span{overflow:hidden}' +
  '.hm.fh{height:17px}.hm.fh i{line-height:17px}.hm.fh.l-act i{background:color-mix(in srgb,var(--act) var(--a),var(--sf2))}.hm.fh.l-watch i{background:color-mix(in srgb,var(--watch) var(--a),var(--sf2))}.hm.fh.l-fixed i{background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}.hm.fh.l-mr i{background:color-mix(in srgb,var(--sage) var(--a),var(--sf2))}' +
  '.fhm .gk.gl0>.hm.fh{height:20px}.fhm .gk.fk>.gn{padding-left:12px;font-weight:500;color:var(--mt)}.fhm .gk.l-act:not(.fk)>.gn{color:color-mix(in srgb,var(--act) 60%,var(--fg))}.fhm .gk.l-watch:not(.fk)>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.fhm .gk.l-fixed:not(.fk)>.gn{color:var(--sage2)}' +
  '.gkx{grid-column:1/-1;justify-self:start;background:none;border:0;padding:2px 0;color:var(--mt);font:inherit;cursor:pointer}.gkx::before{content:"\25B8  "}.gkx[aria-expanded=true]::before{content:"\25BE  "}.gkx small{font-size:inherit}.gki{display:none}.gks.gio>.gki{display:contents}' +
  '.lgk{display:inline-block;width:8px;height:8px;border-radius:2px;margin:0 3px 0 6px;vertical-align:-1px}.lgk:first-child{margin-left:0}.lgk.c{background:var(--slate)}.lgk.r{background:var(--sage2)}' +
  '.hlt{margin-top:6px;font-size:12px}.hlt td{padding:2px 6px;border-bottom:1px solid var(--ln);overflow-wrap:anywhere;vertical-align:top}.hlt td+td{color:var(--mt)}.hlt td:first-child{font-weight:600}' +
  '.hlt tr.nh td{background:color-mix(in srgb,var(--watch) 10%,transparent);color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.hlt tr.gh th{font-size:12px;padding:3px 6px}' +
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
