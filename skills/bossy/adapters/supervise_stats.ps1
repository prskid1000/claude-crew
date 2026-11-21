<#
supervise_stats.ps1 (core): the supervise page's history graphs from the logs the kit already writes, dot-sourced by bossy.ps1
(skills/bossy/adapters/): the build gate per kind (builds log), lease waits per resource (leases log, builds log, local-env
lease-wait events, live queues), test-run results per day (qa-runs results.json), CPU + RAM per lane process and the top other
processes (one process snapshot per sweep), flags per hour, agents shell progress (bossy.ps1 shells), the statistics reset (bossy.ps1 stats); their heatmap cards (shared cells, idle-row fold, card fold) and the
page drawer render inside Format-KitSuperviseHtml; the page's icons and sentence-case labels (Format-KitLabel).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L13 gate · L65 waits · L91 qa · L108 cpu · L144 writes (owner 2026-11-18 · L428 cards · L715 flags · L855 bands ·
  L1000 shells · L1071 reset
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
function Get-KitGateStats([datetime]$Now = (Get-Date), $Resources = @(), [datetime]$StatsFrom = [datetime]::MinValue) {   # StatsFrom: Get-KitStatsCutoff
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $from = $h0; $led = Get-KitGateLedger; $rd = { param($f) try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
  $at = { param($v) $t = if ($v -is [datetime]) { $v } else { try { [datetime]"$v" } catch { $null } }; if ($t -and $t -ge $StatsFrom) { $t } }   # before the stats reset: no time, the line drops
  $run = @(Get-ChildItem $led -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ -and $_.pid -and (Test-KitPid $_.pid $_.start) })
  $que = @(Get-ChildItem (Join-Path $led 'queue') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { & $rd $_.FullName } | Where-Object { $_ })
  $ends = @(Read-KitLog builds $from | Where-Object { $_.event -eq 'end' -and (& $at $_.at) })
  $g = [ordered]@{}; $row = { param($n) if (-not $g.Contains($n)) { $g[$n] = [ordered]@{ name = $n; running = 0; queued = 0; done = 0; waits = [Collections.Generic.List[double]]::new(); ram = 0.0; peakGB = 0.0; minToday = 0.0; failed = 0; who = [Collections.Generic.List[string]]::new(); hours = @(0..23 | ForEach-Object { , @(0, 0.0, 0.0) }) } }; $g[$n] }
  # busy minutes spread over the clock hours a build overlapped; its count and wait go to the hour it ended in
  $busy = { param($r, [datetime]$s1, [datetime]$e1) Split-KitHours $h0 $s1 $e1 { param($hi, $ov) $r.hours[$hi][1] += $ov } }
  foreach ($x in $ends) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $e1 = & $at $x.at; $s1 = $e1.AddSeconds(-[double]$x.sec); $wm = [double]$x.waitSec / 60
    if ($e1 -ge $Now.Date) { $r.done++; $r.waits.Add($wm); $r.minToday += [double]$x.sec / 60; if ([int]$x.code) { $r.failed++ } }; if ($e1 -ge $Now.Date -and "$($x.owner)" -and "$($x.owner)" -notin $r.who -and "$($x.project)" -notmatch '(^|[\\/])qa-seats$') { $r.who.Add("$($x.owner)") }; & $busy $r $s1 $e1; $hi = [int][math]::Floor(($e1 - $h0).TotalHours); if ($hi -ge 0 -and $hi -le 23) { $r.hours[$hi][0]++; $r.hours[$hi][2] = [math]::Max($r.hours[$hi][2], $wm) } }
  foreach ($x in @(Read-KitLog builds $Now.Date | Where-Object { $_.event -eq 'start' -and (& $at $_.at) })) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.project)"); $r.peakGB = [math]::Max($r.peakGB, [double]$x.needGB) }
  foreach ($x in $run) { $r = & $row (Get-KitGateGroup "$($x.kind)" "$($x.owner) $($x.dir)"); $r.running++; $r.ram += [double]$x.need; if ("$($x.owner)" -and "$($x.owner)" -notin $r.who) { $r.who.Add("$($x.owner)") }; $s1 = if ($x.started) { try { [datetime]$x.started } catch { $null } }; if ($s1 -and $s1 -lt $StatsFrom) { $s1 = $StatsFrom }; if ($s1) { & $busy $r $s1 $Now } }   # a build running since before the reset: busy from the reset on
  foreach ($x in $que) { (& $row (Get-KitGateGroup "$($x.kind)" "$($x.owner)")).queued++ }
  $rows = @($g.Values | ForEach-Object { [pscustomobject]@{ name = $_.name; running = $_.running; queued = $_.queued; done = $_.done; ram = [math]::Round($_.ram, 1); peakGB = [math]::Round($_.peakGB, 1); min = [math]::Round($_.minToday); failed = $_.failed; owners = @($_.who)
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
function Get-KitLeaseWaits([datetime]$Now = (Get-Date), [datetime]$StatsFrom = [datetime]::MinValue) {   # StatsFrom: Get-KitStatsCutoff
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $rows = [ordered]@{}
  $add = { param([string]$res, $s, $e, [string]$who) if ($null -eq $s -or $null -eq $e) { return }; $s = [datetime]$s; $e = [datetime]$e; if ($s -lt $StatsFrom) { $s = $StatsFrom }; if (($e - $s).TotalMinutes -lt 0.5 -or $e -lt $h0) { return }
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
  foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath phones) 'wait') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ($Now - $_.LastWriteTime).TotalMinutes -lt (Get-KitParam 'phone.waitFreshMinutes') })) { $w = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }; & $add "phone $(if ($w.lane) { $w.lane } else { 'any lane' })" $w.since $Now "$($w.agent)" }
  [pscustomobject]@{ h0 = $h0.ToString('o'); rows = @($rows.Values | Sort-Object { - $_.min } | ForEach-Object { [pscustomobject]@{ name = $_.name; n = $_.n; min = [math]::Round($_.min, 1); max = [math]::Round($_.max, 1); hours = @($_.hours | ForEach-Object { , @([int]$_[0], [math]::Round($_[1], 1), [math]::Round($_[2], 1), "$($_[3])") }) } }) }
}

# ---- qa: checks per day from the QA runs' results.json (7 days): PASS / FAIL / NOT_TESTED / OUT_OF_SCOPE, NOT_TESTED causes, runs per day
$script:KitQaCauses = 'env-data', 'phone-only', 'tool-down', 'no-mail-sandbox', 'undeployed'   # testy.js CHECKS_SCHEMA cause; anything else: other
function Get-KitQaDays([datetime]$Now = (Get-Date), [int]$Days = 7, [datetime]$StatsFrom = [datetime]::MinValue) {   # StatsFrom: Get-KitStatsCutoff
  $from = $Now.Date.AddDays(1 - $Days); if ($StatsFrom -gt $from) { $from = $StatsFrom } $byDay = [ordered]@{}; foreach ($i in ($Days - 1)..0) { $byDay[$Now.Date.AddDays(-$i).ToString('yyyy-MM-dd')] = [ordered]@{} }
  $causes = [ordered]@{}; foreach ($c in @($script:KitQaCauses) + 'other') { $causes[$c] = 0 }
  # <qa-runs>/<run>/<item>/results.json, dated by its own at (a retest rewrites it), else its last write (a copy or touch moves the mtime)
  foreach ($f in @(Get-ChildItem (Get-KitPath qa-runs) -Filter 'results.json' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $from)) {
    $res = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }; $rt = $f.LastWriteTime; if ($res.at) { try { $rt = ([datetimeoffset]"$($res.at)").LocalDateTime } catch { } }
    if ($rt -lt $from) { continue }; $dk = $rt.ToString('yyyy-MM-dd'); $run = Split-Path (Split-Path $f.DirectoryName) -Leaf
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
  $groups += @($Resources | Where-Object { $_ -and $_.name -and @($_.pid | Where-Object { [int]$_ -gt 0 }).Count -and "$($_.name)" -notin $svcNames } | ForEach-Object { [pscustomobject]@{ name = "$($_.name)"; pid = @($_.pid | Where-Object { [int]$_ -gt 0 } | ForEach-Object { [int]$_ }) } })
  if ($dt -ge 60 -and $dt -le 7200) {   # an older snapshot gives a long average: no sample
    $cores = [math]::Max(1, [Environment]::ProcessorCount); $pa = $Prior.acc; $pct = @{}; $byId = @{}; $kids = @{}
    foreach ($p in $procs) { $byId[$p.Id] = $p; if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[int]]::new() }; $kids[$p.ParentId].Add($p.Id)
      $was = if ($pa) { (Get-KitMember $pa "$(& $key $p)") }; $base = if ($null -ne $was) { [double]$was } elseif ($p.Created -and [datetime]$p.Created -gt $prevAt) { 0 } else { $null }
      if ($null -ne $base) { $v = 100 * ([double]$p.Cpu - $base) / $dt / $cores; if ($v -gt 0.05) { $pct[$p.Id] = $v } } }
    $tree = { param([int]$id) $seen = @{}; $todo = [Collections.Generic.Queue[int]]::new(); $todo.Enqueue($id); while ($todo.Count) { $i = $todo.Dequeue(); if ($seen.ContainsKey($i) -or -not $byId.ContainsKey($i)) { continue }; $seen[$i] = 1; foreach ($c in @($kids[$i])) { if ($c -ne $i) { $todo.Enqueue($c) } } }; @($seen.Keys) }
    $inG = @{}; $g = [ordered]@{}; $m = [ordered]@{}   # m: RAM GB of each group's tree (working set), sampled each sweep like its CPU
    foreach ($gr in @($groups | Where-Object { $_.name -and $_.pid })) { $ids = @(foreach ($gp in @($gr.pid)) { & $tree ([int]$gp) }) | Select-Object -Unique; foreach ($i in $ids) { $inG[$i] = 1 }; $g["$($gr.name)"] = [math]::Round([double](@($ids | ForEach-Object { $pct[$_] }) + 0 | Measure-Object -Sum).Sum, 1)
      $m["$($gr.name)"] = [math]::Round([double](@($ids | ForEach-Object { [double]$byId[$_].WorkingSet }) + 0 | Measure-Object -Sum).Sum / 1GB, 2) }
    $sh = @{}; foreach ($s in @($Shells | Where-Object { $_.pid })) { $sh[[int]$s.pid] = "$($s.owner)" }
    $topPct = [double](Get-KitParam 'supervise.topProcPct')
    $owner = { param([int]$id) for ($n = 0; $n -lt 12 -and $byId.ContainsKey($id); $n++) { if ($sh.ContainsKey($id) -and $sh[$id]) { return $sh[$id] }; $id = $byId[$id].ParentId }; '' }
    $top = @($pct.Keys | Where-Object { -not $inG.ContainsKey($_) -and $pct[$_] -ge $topPct } | Sort-Object { - $pct[$_] } | Select-Object -First 5 | ForEach-Object { $p = $byId[$_]
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
# K94 (owner 2026-11-19): the I/O counter also counts pipes, sockets and console, so a GB is "est." = the process's share of all process
# I/O x the physical disks' real writes over the same beat (never above them); no disk counter -> no flag; a tracer (writes.tracer) replaces
# every estimate with disk MB; not kit-owned -> never ACT, WATCH only on the tracer's MB
function Get-KitWriteProcs {   # the sweep's processes + Write (bytes); none off Windows
  if (-not $KitIsWindows) { return @() }
  $wb = @{}; foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, WriteTransferCount -ErrorAction SilentlyContinue)) { $wb[[int]$c.ProcessId] = [double]$c.WriteTransferCount }
  @(Get-KitSweepProcs | Where-Object { $wb.ContainsKey($_.Id) } | ForEach-Object { $_ | Add-Member -Force -NotePropertyName Write -NotePropertyValue $wb[$_.Id] -PassThru })
}
# bytes written to all physical disks since boot (cumulative raw counter); $null off Windows or without perf counters
function Get-KitDiskWritten {
  if (-not $KitIsWindows) { return $null }
  # the property is matched, not named: its full name is a pwsh script-block-logging trigger (lint ARCH-SBLOG)
  try { $pd = @(Get-KitProps @(Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop)[0] | Where-Object Name -like 'DiskWriteB*'); if ($pd.Count) { [double]$pd[0].Value } } catch { $null }
}
# kit.local.json writes.tracer { csv, time, kind, process, folder, mb, disk }: the tracer CSV and its column names (today's by default);
# writes.tracerCsv: the older key for csv
function Get-KitWriteTracerConf {
  $c = Get-KitSetting 'writes.tracer' $null; $v = { param($k, $d) $x = if ($c) { "$(Get-KitMember $c $k)" }; if ($x) { $x } else { $d } }
  @{ csv = (& $v 'csv' ([string](Get-KitSetting 'writes.tracerCsv' ''))); time = (& $v 'time' 'Time'); kind = (& $v 'kind' 'Kind'); process = (& $v 'process' 'Process'); folder = (& $v 'folder' 'Folder'); mb = (& $v 'mb' 'WriteMB'); disk = (& $v 'disk' 'disk') }
}
# the tracer's physical disk writes in ($Since, $Now] -> @{ oldest; newest; rows = @(@{ t; p = process; f = folder; mb }) }; columns by header name
# (any order, case-insensitive); no kind column = every row is disk, another kind value is skipped; $null = no tracer: unset, missing,
# no time / process / MB column, or stale (no row in the 20 min before $Now)
function Read-KitWriteTracer($Conf, [datetime]$Now, [datetime]$Since = $Now.AddHours(-1)) {
  if ($Conf -is [string]) { $cf = Get-KitWriteTracerConf; $cf.csv = $Conf; $Conf = $cf }
  if (-not $Conf.csv -or -not (Test-Path -LiteralPath $Conf.csv)) { return $null }
  $fs = [IO.FileStream]::new($Conf.csv, 'Open', 'Read', 'ReadWrite'); try { $all = [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }   # the tracer appends meanwhile
  $ln = @($all -split "`r?`n" | Where-Object { $_ }); if ($ln.Count -lt 2) { return $null }
  $crx = [regex]::new('(?:^|,)(?:"((?:[^"]|"")*)"|([^,]*))', 'Compiled')
  $cell = { param([string]$l) $o = [Collections.Generic.List[string]]::new(); foreach ($m in $crx.Matches($l)) { $o.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value.Replace('""', '"') } else { $m.Groups[2].Value })) }; , $o.ToArray() }
  $hd = @((& $cell $ln[0]).ForEach({ "$_".Trim() })); $ix = @{}
  foreach ($k in 'time', 'kind', 'process', 'folder', 'mb') { $ix[$k] = -1; for ($i = 0; $i -lt $hd.Count; $i++) { if ($hd[$i] -ieq $Conf[$k]) { $ix[$k] = $i; break } } }
  if ($ix.time -lt 0 -or $ix.process -lt 0 -or $ix.mb -lt 0) { return $null }
  $ic = [cultureinfo]::InvariantCulture; $newest = [datetime]::MinValue; $oldest = [datetime]::MaxValue; $rows = [Collections.Generic.List[object]]::new()
  # appended in time order: parsed from the end in chunks until one starts at or before $Since (a beat parses ~1 chunk, not the file)
  for ($end = $ln.Count - 1; $end -ge 1; $end -= 250) { $lo = 1e18
    foreach ($l in $ln[[math]::Max(1, $end - 249)..$end]) { $t = [datetime]::MinValue   # the cells inline: a script block call per line doubled the beat's parse
      $v = [Collections.Generic.List[string]]::new(); foreach ($m in $crx.Matches($l)) { $v.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value.Replace('""', '"') } else { $m.Groups[2].Value })) }
      if ($v.Count -le $ix.time -or -not [datetime]::TryParse($v[$ix.time], $ic, [Globalization.DateTimeStyles]::None, [ref]$t)) { continue }
      if ($t -gt $newest) { $newest = $t }; if ($t -lt $oldest) { $oldest = $t }; $lo = [math]::Min($lo, $t.Ticks)
      if ($t -le $Since -or $t -gt $Now -or ($ix.kind -ge 0 -and "$($v[$ix.kind])" -ine $Conf.disk)) { continue }
      $mb = 0.0; if (-not [double]::TryParse("$($v[$ix.mb])", [Globalization.NumberStyles]::Float, $ic, [ref]$mb)) { continue }   # a half-written last line
      $rows.Add(@{ t = $t; p = ("$($v[$ix.process])" -replace '(?i)\.exe$'); f = $(if ($ix.folder -ge 0) { "$($v[$ix.folder])" -replace '[\\/]+\.\.\.$' -replace '/', '\' } else { '' }); mb = $mb }) }
    if ($lo -le $Since.Ticks) { break } }
  if ($newest -lt $Now.AddMinutes(-(Get-KitParam 'writes.tracerFreshMinutes'))) { return $null }
  @{ oldest = $oldest; newest = $newest; rows = $rows }
}
# a command's executable without folder and .exe (the tracer's process name)
function Get-KitWriteExe([string]$Name, [string]$Cmd) { if ($Cmd -match '^(?:"(?:[^"]*[\\/])?(?<x>[^"\\/]+?)(?:\.exe)?"|(?:\S*[\\/])?(?<x>[^\s\\/]+?)(?:\.exe)?(?:\s|$))') { $Matches.x } else { $Name -replace '(?i)\.exe$' } }
# a process's short label (the full command stays in the tooltip): a browser with its CDP port, a DB server with its data folder,
# a runtime with its script, jar, main class or npx package, else the name without .exe
function Get-KitWriteLabel([string]$Name, [string]$Cmd) {
  $b = Get-KitWriteExe $Name $Cmd   # a wrapper's row carries its child's command
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
# $Disk: Get-KitDiskWritten; $Tracer: Read-KitWriteTracer
# a sample = @{ at; s = seconds; m = machine GB (the disks' when e); e = 1: GBs scaled to the disks; t = 1: GBs from the tracer; w = @(@{ n = label; a = tag (agent); g = GB; c = top command; k = 1: kit-owned }) }
# the folders a command names (absolute paths after the executable; a file: its folder), at most 3
function Get-KitWriteDirs([string]$Cmd) {
  # a DB server writes to its data folder only: --datadir, else its --defaults-file's datadir line, else that file's folder
  # (lane inis sit side by side in one folder: its folder made one lane's row take every lane's writes, 2026-11-20)
  foreach ($o in 'datadir', 'defaults-file') { if ($Cmd -match "--$o[= ](?:`"(?<d>[^`"]+)`"|(?<d>\S+))") { $p = $Matches.d -replace '/', '\'
      $dd = $null; if ($o -ne 'datadir' -and (Test-Path -LiteralPath $p -PathType Leaf)) { foreach ($il in @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)) { $im = [regex]::Match("$il", '^\s*datadir\s*=\s*"?([^"]+?)"?\s*$'); if ($im.Success) { $dd = $im.Groups[1].Value -replace '/', '\' } } }
      return @(@($(if ($o -eq 'datadir') { $p.TrimEnd('\') } elseif ($dd) { $dd.TrimEnd('\') } else { Split-Path $p })) | Where-Object { @($_ -split '\\').Count -ge 3 }) } }   # never a drive root
  $ps =@([regex]::Matches(($Cmd -replace '^\s*("[^"]*"|\S+)'), '(?<![\w])[A-Za-z]:[\\/][^"\s]*') | ForEach-Object { $p = $_.Value -replace '/', '\' -replace '[\\,;]+$'; if ($p -match '\.\w{1,5}$') { Split-Path $p } else { $p } })
  @($ps | Where-Object { @($_ -split '\\').Count -ge 3 } | Select-Object -Unique -First 3)
}
# a tracer folder belongs to a dir: under it, or a cut tracer folder (4+ parts) above it
function Test-KitWriteFolderIn([string]$Folder, [string[]]$Dirs) {
  $fb = $Folder.TrimEnd('\') + '\'   # a path boundary: D:\a\app2 is not under D:\a\app
  foreach ($d in $Dirs) { $db = $d.TrimEnd('\') + '\'; if ($fb.StartsWith($db, 'OrdinalIgnoreCase') -or (@($Folder -split '\\').Count -ge 4 -and $db.StartsWith($fb, 'OrdinalIgnoreCase'))) { return $true } }; $false
}
# a sample's rows ($Rows: @{ n; g = est. GB; c; k; f }) -> @{ label = disk GB } from the tracer rows in ($S1, $E1]: a write under a kit row's
# folders goes to that row whatever the process (System flushes cached writes); any other write to the rows of its process (split by
# their est. share); System's other writes and processes no row names: none (the machine total keeps them)
# a DB server row (--datadir / --defaults-file) gets only the writes under its data folder: all mysqld writes split by share put a
# lane's and the machine's MySQL into kit-tests (5.55 GB vs 1.70 GB traced there, 2026-11-19)
function Get-KitTracerShare($Tracer, [datetime]$S1, [datetime]$E1, $Rows) {
  $dbRx = '--(?:datadir|defaults-file)[= ]'
  $out = @{}; foreach ($r in $Rows) { $out["$($r.n)"] = 0.0 }; $kd = @($Rows | Where-Object { ([int]$_.k -or "$($_.c)" -match $dbRx) -and @($_.f).Count })
  $byExe = @{}; foreach ($r in @($Rows | Where-Object { "$($_.c)" -notmatch $dbRx })) { $x = (Get-KitWriteExe '' "$($r.c)").ToLower(); if (-not $byExe.ContainsKey($x)) { $byExe[$x] = [Collections.Generic.List[object]]::new() }; $byExe[$x].Add($r) }
  foreach ($w in @($Tracer.rows | Where-Object { $_.t -gt $S1 -and $_.t -le $E1 })) { $gb = [double]$w.mb / 1024
    $hit = if ($w.f) { @($kd | Where-Object { Test-KitWriteFolderIn $w.f @($_.f) })[0] }; if ($hit) { $out["$($hit.n)"] += $gb; continue }
    $rs = $byExe["$($w.p)".ToLower()]; if ("$($w.p)" -match '^(System|Idle|Registry)$' -or -not $rs) { continue }
    $tot = [double](@($rs | ForEach-Object { [double]$_.g }) + 0 | Measure-Object -Sum).Sum
    foreach ($r in $rs) { $out["$($r.n)"] += $gb * $(if ($tot -gt 0) { [double]$r.g / $tot } else { 1.0 / $rs.Count }) } }
  $out
}
# $Tracer: Read-KitWriteTracer from the oldest sample still est. (24 h): its rows replace every row's GB (sample t = 1), samples
# before it too ("re-render"); $Redo (out) = the sample windows it re-attributed
function Update-KitWriteStats($Prior, [datetime]$Now, $Procs, $Owners = @(), $Disk = $null, $Tracer = $null, [string[]]$KitDirs = @()) {
  $key = { param($p) "$($p.Id)|$(if ($p.Created) { ([datetime]$p.Created).ToUniversalTime().Ticks })" }
  $osRoot = '^(System|Idle|smss|csrss|wininit|winlogon|services|svchost|explorer|userinit|init|systemd|launchd)(\.exe)?$'
  $byId = @{}; $acc = [ordered]@{}; foreach ($p in @($Procs | Where-Object { $_ -and $null -ne $_.Write })) { $byId[[int]$p.Id] = $p; $acc[(& $key $p)] = [double]$p.Write }
  if ($null -ne $Disk) { $acc['disk'] = [double]$Disk }
  $own = @{}; foreach ($o in @($Owners | Where-Object { $_ -and [int]$_.pid -gt 0 -and $_.label })) { if (-not $own.ContainsKey([int]$o.pid)) { $own[[int]$o.pid] = $o } }
  # an unowned tree with a process that names a kit folder (the kit-tests mysqld's data dir, a detached kit script) is the kit's: the
  # nearest such process on the way up (its root changes when a parent exits: the label and kit-ownership stay)
  $kitOf = { param($pp) $qc = "$($pp.CommandLine)" -replace '/', '\'; foreach ($kd in @($KitDirs | Where-Object { $_ })) { if ($qc.IndexOf(("$kd" -replace '/', '\').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return @{ pid = [int]$pp.Id; label = (Get-KitWriteLabel "$($pp.Name)" $qc); tag = 'kit' } } } }
  $ownerOf = { param($p) $q = $p; $km = $null
    for ($n = 0; $n -lt 16; $n++) { if ($own.ContainsKey([int]$q.Id)) { return $own[[int]$q.Id] }; if (-not $km) { $km = & $kitOf $q }
      $up = $byId[[int]$q.ParentId]; if (-not $up -or $up.Id -eq $q.Id -or "$($up.Name)" -match $osRoot -or ($up.Created -and $q.Created -and [datetime]$up.Created -gt [datetime]$q.Created)) { break }; $q = $up }
    if ($km) { return $km }; "pid $($q.Id)" }   # a reused parent id starts after its child: the tree stops there
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
      if (-not $rw.Contains($lb)) { $rw[$lb] = @{ a = $(if ($kit) { "$($t.o.tag)" } else { '' }); g = 0.0; b = 0.0; c = ''; k = [int]$kit; f = @() } }
      $r = $rw[$lb]; $r.g += $gb[$ok]; if ($t.b -gt $r.b) { $r.b = $t.b; $r.c = $cl.Substring(0, [math]::Min(120, $cl.Length)); $r.f = @(Get-KitWriteDirs $cl) } }
    # the disks' growth this beat (a reboot resets the counter: no scale); each GB = its share of all process I/O x that
    $wasD = Get-KitMember $Prior.acc 'disk'; $dg = if ($null -ne $Disk -and $null -ne $wasD -and [double]$Disk -ge [double]$wasD) { ([double]$Disk - [double]$wasD) / 1GB }
    $f = if ($null -eq $dg) { 1.0 } elseif ($mach -gt 0) { [math]::Min(1.0, $dg / $mach) } else { 0.0 }
    $smp = [ordered]@{ at = $Now.ToString('o'); s = [int]$dt; m = [math]::Round($(if ($null -ne $dg) { $dg } else { $mach }), 3) }; if ($null -ne $dg) { $smp.e = 1 }
    $smp.w = @($rw.Keys | Where-Object { $rw[$_].g * $f -ge 0.001 } | ForEach-Object { $o1 = [ordered]@{ n = "$_"; a = $rw[$_].a; g = [math]::Round($rw[$_].g * $f, 3); c = $rw[$_].c; k = $rw[$_].k }; if (($rw[$_].k -or $rw[$_].c -match '--(datadir|defaults-file)[= ]') -and $rw[$_].f.Count) { $o1.f = $rw[$_].f }; $o1 }); $samples += $smp
  }
  # owner 2026-11-19 ("it should record pure disk writes"): with a tracer every row's GB is its physical disk MB (a cached write, e.g. qemu
  # disk images or browser profiles, is flushed by System: credited to the kit row whose folder it is); the I/O counter is the fallback, est.
  $redo = [Collections.Generic.List[object]]::new()
  if ($Tracer) { $samples = @(foreach ($s in $samples) { $e1 = [datetime]$s.at; $s1 = $e1.AddSeconds(-[math]::Max(1.0, [double]$s.s))
        if ($s.t -or $s.x -or $e1 -gt $Tracer.newest.AddMinutes((Get-KitParam 'writes.tracerFreshMinutes'))) { $s; continue }
        if ($s1 -lt $Tracer.oldest) { if ($s -is [Collections.IDictionary]) { $s.x = 1 } else { $s | Add-Member -Force -NotePropertyName x -NotePropertyValue 1 }; $s; continue }   # before the tracer's first row: est. for good (x), never read for again
        $ws = @(Get-KitWriteRows $s); $sh = Get-KitTracerShare $Tracer $s1 $e1 $ws
        $s2 = [ordered]@{}; foreach ($p in @(Get-KitWritePairs $s)) { if ($p.Name -ne 'w') { $s2[$p.Name] = $p.Value } }; $s2.t = 1
        $s2.w = @($ws | Where-Object { $sh["$($_.n)"] -ge 0.001 } | ForEach-Object { $o1 = [ordered]@{ n = $_.n; a = $_.a; g = [math]::Round($sh["$($_.n)"], 3); c = $_.c; k = $_.k }; if (@($_.f).Count) { $o1.f = @($_.f) }; $o1 })
        if ("$($s.at)" -ne $Now.ToString('o')) { $redo.Add($s2) }; $s2 }) }
  $hr = @{}; $last = @{}; $hd = 0.0; $he = $false; $est = @{}; $kk = @{}
  # only disk-scaled or tracer samples count (one from before the disk counter, a reboot or a lost prior is raw I/O); the card keeps them all;
  # each sample by the part of its window inside the hour not counted yet (two sweeps' overlapping windows, a 2 h window: counted once)
  $cov = $Now.AddHours(-1)
  foreach ($s in @($samples | Where-Object { [datetime]$_.at -gt $Now.AddHours(-1) -and ($_.e -or $_.t) } | Sort-Object { [datetime]$_.at })) { $e1 = [datetime]$s.at; $sec = [math]::Max(1.0, [double]$s.s)
    $fr = [math]::Max(0.0, ($e1 - [datetime]::new([math]::Max($e1.AddSeconds(-$sec).Ticks, $cov.Ticks))).TotalSeconds / $sec); if ($e1 -gt $cov) { $cov = $e1 }; if ($fr -le 0) { continue }
    $he = $true; $hd += $fr * [double]$s.m
    foreach ($r in @(Get-KitWriteRows $s)) { $rn = "$($r.n)"; $hr[$rn] = [double]$hr[$rn] + $fr * [double]$r.g; $last[$rn] = $r; if ([int]$r.k) { $kk[$rn] = "$($r.a)" }; if (-not $s.t) { $est[$rn] = 1 } } }
  # kit-owned when any sample of the hour saw it so (a tree's root changes between sweeps); never above all disks
  $hour = @($hr.Keys | ForEach-Object { [ordered]@{ label = $_; tag = $(if ($kk.ContainsKey($_)) { $kk[$_] } else { "$($last[$_].a)" }); gb = [math]::Round($(if ($hd -gt 0) { [math]::Min($hr[$_], $hd) } else { $hr[$_] }), 2); cmd = "$($last[$_].c)"; k = [int]$kk.ContainsKey($_); est = [int]$est.ContainsKey($_) } } | Sort-Object { - $_.gb })
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  # a burst that is over (no write in the last 2 samples: exited or stopped) leaves the flags, the card keeps its hour; not kit-owned:
  # only the tracer's own disk MB flags it (never ACT), an estimate never (2026-11-19: Edge est. 1.12 GB, ~0 MB on disk)
  $nowS = @($samples | Where-Object { "$($_.at)" -eq $Now.ToString('o') })[0]; $cur = @($samples | Select-Object -Last 2 | ForEach-Object { Get-KitWriteRows $_ } | ForEach-Object { "$($_.n)" })
  $flags = @(foreach ($h in @($hour | Where-Object { $he -and $_.gb -ge $soft -and (-not $nowS -or $_.label -in $cur) -and ($_.k -or -not $_.est) })) { $lv = if ($h.k -and $h.gb -ge $hard) { 'ACT' } else { 'WATCH' }; $who = "$($h.label)$(if ($h.tag) { " ($($h.tag))" })"
      [pscustomobject]@{ level = $lv; kind = 'WRITES'; who = $who; what = "WRITES ${who}: $(if ($h.est) { 'est. ' })$($h.gb) GB to disk in the last hour (all disks $([math]::Round($hd, 2)) GB; soft $soft / hard $hard GB$(if (-not $h.k) { '; not kit-owned' })); top: $(Get-KitWriteLabel '' $h.cmd)" -replace "; top: $([regex]::Escape($h.label))$"
        action = "$(if ($lv -eq 'ACT') { 'Check whether it is a one-off (a burst already over, a false positive) before acting; still writing: stop it, then ' })tell its owner: no bulk data, dumps, tree copies, reinstalls or big captures (AGENTS.md); links / moves, small fixtures, read-only checks." } })
  [ordered]@{ at = $Now.ToString('o'); acc = $acc; samples = $samples; hour = $hour; flags = $flags; redo = @($redo) }
}
# the owners from this sweep (resources, shells, lane services): label = the resource, tag = its holder agent (no branch); a shell: the
# agent, tag shell; an env service with no pid (an external one, e.g. the shared database): the pid listening on its port (one netstat)
function Get-KitWriteOwners($Res) {
  $rs = @($Res | Where-Object { $_ }); $lsn = @{}
  if (@($rs | Where-Object { -not $_.pid -and $_.port }).Count) { foreach ($c in @(Get-KitTcpRows | Where-Object { [int]$_.RemotePort -eq 0 -and $_.OwningProcess })) { $lsn["$($c.LocalPort)"] = [int]$c.OwningProcess } }
  @($rs | ForEach-Object { $r = $_; foreach ($p in @(if ($r.pid) { $r.pid } else { @($r.port) | ForEach-Object { $lsn["$_"] } })) { if ($p) { @{ pid = [int]$p; label = "$($r.name)"; tag = $(if ("$($r.by)" -notmatch '^(no lease|free|parked)') { ("$($r.by)" -replace '\s*\(.*$').Trim() }) } } } }) +
    @(@($script:KitShellRows) | Where-Object { $_ -and $_.pid } | ForEach-Object { $r = $_; foreach ($p in @($r.pid)) { @{ pid = [int]$p; label = "$(if ($r.owner) { $r.owner } else { 'unknown agent' })"; tag = 'shell' } } }) +
    @(@(Invoke-KitHooks Get-KitCpuGroups) | Where-Object { $_ -and $_.pid } | ForEach-Object { $r = $_; foreach ($p in @($r.pid)) { @{ pid = [int]$p; label = "lane $($r.name)"; tag = '' } } })
}
# supervise hook: <runtime>/cache/supervise-writes.json between beats
function Get-KitSuperviseFlagsWrites([switch]$AutoFix) {
  $cf = Join-Path (Get-KitPath cache -Create) 'supervise-writes.json'
  if (-not $KitIsWindows) { if (-not (Test-Path -LiteralPath $cf)) { Set-Content -LiteralPath $cf '{}'; [pscustomobject]@{ info = 'disk writes per agent: no per-process I/O counters on this OS (Windows only)' } }; return }
  $prior = try { Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json } catch { $null }
  # Get-Variable -ValueOnly writes the array as one object: unrolled, or every resource was one owner with all their names and holders
  $owners = Get-KitWriteOwners @(Get-Variable res -ValueOnly -ErrorAction SilentlyContinue | ForEach-Object { $_ })
  # the tracer from the oldest sample still est. (24 h), else since the last beat; a locked or odd file: no tracer this beat
  $now = Get-Date; $since = @(@($prior.samples | Where-Object { $_.at -and -not $_.t -and -not $_.x } | ForEach-Object { ([datetime]$_.at).AddSeconds(-[double]$_.s) }) + $(if ($prior.at) { [datetime]$prior.at } else { $now.AddHours(-1) }) | Sort-Object)[0]
  $trc = try { Read-KitWriteTracer (Get-KitWriteTracerConf) $now ([datetime]::new([math]::Max($since.Ticks, $now.AddDays(-1).Ticks))) } catch { $null }
  $w = Update-KitWriteStats $prior $now @(Get-KitWriteProcs) $owners (Get-KitDiskWritten) $trc @(@($KitConf.Kit) + @($KitConf.WorktreeRoots))
  Write-KitAtomic $cf ([ordered]@{ at = $w.at; acc = $w.acc; samples = $w.samples; hour = $w.hour } | ConvertTo-Json -Depth 6 -Compress)
  try { Update-KitWriteHistory (Get-KitPath disk-writes) $w.samples $now $w.redo } catch { }   # the card's 7 / 30 days; a failed append costs one hour
  $w.flags
}
# a sample's owner rows; a row from before 2026-11-19 (no k): "<proc> pid N" -> its short label, "<agent> shell", "<holder> (<resource>)" -> kit-owned
function Get-KitWriteRows($S) {
  @($S.w | Where-Object { $_ } | ForEach-Object { $n0 = "$($_.n)"; $a0 = "$($_.a)"; $k0 = [int]$_.k
      if ($null -eq $_.k) { $k0 = 1; if ($n0 -match '^(?<p>\S+) pid \d+$') { $n0 = Get-KitWriteLabel $Matches.p "$($_.c)"; $k0 = 0 } elseif ($n0 -match '^(?<a>.+) shell$') { $n0 = $Matches.a; $a0 = 'shell' }
        elseif ($n0 -match '^(?<a>[^()]*?)\s*\((?<r>[^()]+)\)$') { $n0 = $Matches.r; $a0 = (($Matches.a -split ',')[0]).Trim() } else { $n0 = 'kit resources' } }   # several holders in one label: the old join bug
      [pscustomobject]@{ n = $n0; a = $a0; g = [double]$_.g; c = "$($_.c)"; k = $k0; f = @($_.f | Where-Object { $_ }) } })
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
  $cut = $Now.Date.AddDays(-(Get-KitParam 'supervise.statsDays')); $drop = $Now.Date.AddDays(-(Get-KitParam 'writes.keepDays')); $days = [ordered]@{}; $keep = [Collections.Generic.List[object]]::new()
  foreach ($r in @($Rows | Where-Object { $_ -and $_.at } | Sort-Object { [datetime]$_.at })) { $t = [datetime]$r.at; if ($t -lt $drop) { continue }
    if (-not $r.d -and $t -ge $cut) { $keep.Add($r); continue }
    $dk = $t.Date; if (-not $days.Contains($dk)) { $days[$dk] = @{ m = 0.0; k = 0.0; o = @{} } }; $bk = $days[$dk]; $bk.m += [double]$r.m; $bk.k += [double]$r.k
    foreach ($p in @(Get-KitWritePairs $r.o)) { $bk.o[$p.Name] = [double]$bk.o[$p.Name] + [double]$p.Value } }
  @($days.Keys | ForEach-Object { ConvertTo-KitWriteRow $_ $days[$_] 8 -Day }) + @($keep)
}
# closed clock hours since the file's last row -> one line each; the first append of a new day also compacts the file; $Redo (samples the
# tracer re-attributed): the closed hours they touch that the samples fully cover are written again
function Update-KitWriteHistory([string]$File, $Samples, [datetime]$Now, $Redo = @()) {
  $last = if (Test-Path -LiteralPath $File) { try { Get-Content -LiteralPath $File -Tail 1 | ConvertFrom-Json } catch { $null } }
  $lastAt = if ($last.at) { [datetime]$last.at } else { [datetime]::MinValue }; $cur = $Now.Date.AddHours($Now.Hour); $hs = @{}; Add-KitWriteHours $Samples $hs
  $hAt = { param($k) [datetime]::ParseExact($k, 'yyyyMMddHH', [cultureinfo]::InvariantCulture) }
  $new = @($hs.Keys | Sort-Object | ForEach-Object { $h = & $hAt $_; if ($h -lt $cur -and $h -gt $lastAt) { ConvertTo-KitWriteRow $h $hs[$_] } })
  $first = @($Samples | Where-Object { $_ -and $_.at } | ForEach-Object { ([datetime]$_.at).AddSeconds(-[double]$_.s) } | Sort-Object)[0]; $again = @{}
  foreach ($s in @($Redo | Where-Object { $_ -and $_.at })) { $e1 = [datetime]$s.at; $s1 = $e1.AddSeconds(-[double]$s.s)
    for ($h = $s1.Date.AddHours($s1.Hour); $h -lt $e1; $h = $h.AddHours(1)) { $hk = $h.ToString('yyyyMMddHH'); if ($first -and $h -ge $first -and $h -lt $cur -and $h -le $lastAt -and $hs.ContainsKey($hk)) { $again[$hk] = 1 } } }
  if (-not $new.Count -and -not $again.Count) { return }
  $line = { param($r) $r | ConvertTo-Json -Depth 4 -Compress }
  if ($again.Count -or ($last -and $lastAt.Date -ne $Now.Date)) { $all = @(Get-Content -LiteralPath $File | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.d -or -not $again.ContainsKey(([datetime]$_.at).ToString('yyyyMMddHH')) }) +
      @($again.Keys | Sort-Object | ForEach-Object { ConvertTo-KitWriteRow (& $hAt $_) $hs[$_] }) + $new
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
  # a row not kit-owned under 50 MB in 7 days is no row of its own (in "others"); kit-owned: a row in the live samples with k
  $kitN = @{}; foreach ($s in @($Samples | Where-Object { $_ })) { foreach ($r in @(Get-KitWriteRows $s | Where-Object { [int]$_.k })) { $kitN["$($r.n)"] = 1 } }
  $names = @($dm.Keys | Where-Object { [datetime]$_ -gt $Now.Date.AddDays(-(Get-KitParam 'supervise.statsDays')) } | ForEach-Object { $dm[$_].o.Keys } | Select-Object -Unique | Where-Object { $kitN.ContainsKey("$_") -or (& $sumD $_ 7) -ge 0.05 })
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
  # an hour: @(machine GB, kit GB, top writer, sampled 1/0): an hour no sample covered is "no samples", never 0 written
  $days = @(for ($i = 0; $i -lt 7; $i++) { $d0 = $Now.Date.AddDays(-$i); $hp = @(0..23 | ForEach-Object { $bk = $hm[$d0.AddHours($_).ToString('yyyyMMddHH')]; $tw = if ($bk -and $bk.o.Count) { @($bk.o.GetEnumerator() | Sort-Object Value -Descending)[0].Key } else { '' }
        , @([math]::Round((& $val $bk '*m'), 3), [math]::Round((& $val $bk '*k'), 3), $tw, [int][bool]$bk) })
      [ordered]@{ d = $d0.ToString('yyyy-MM-dd'); h = $hp; m = [math]::Round((& $val $dm[$d0.ToString('yyyy-MM-dd')] '*m'), 2); k = [math]::Round((& $val $dm[$d0.ToString('yyyy-MM-dd')] '*k'), 2) } })
  $byName = @($names | Where-Object { $_ -notin $tops } | ForEach-Object { & $mk $_ $_ "$($tags[$_])" (& $line $_) $now60[$_] (& $sumD $_ 1) (& $sumD $_ 7) (& $sumD $_ 30) })   # the Writes metric of Resources · 24 h: every owner, not only the top
  [ordered]@{ at = $Now.ToString('o'); last = $(@($Samples | Where-Object { $_ -and $_.at } | ForEach-Object { ([datetime]$_.at).ToString('o') } | Sort-Object)[-1]); h0 = $h0.ToString('o'); src =$(if (@($Samples | Where-Object { $_ })[-1].t) { 'tracer' } else { 'est' }); rows = $rows; more = $byName; days = $days }   # src tracer: disk MB, no "est." label
}

# ---- cards: render inside Format-KitSuperviseHtml and use its helpers ($e, $n1, $fmt, $icv, $at, $st, $nw, $j, $l24, $fold)
# every heatmap: Format-KitHourHead over a row of Format-KitHeatCells each, rows through Format-KitHeatRows (idle rows folded), the card
# through $fold (chevron + count, open state kept; busy open, idle closed)
# the 24 hour labels over a heatmap: every 6th clock hour, "now" over the last cell; -Clock: a calendar day (00-23), no "now"
function Format-KitHourHead([datetime]$H0, [switch]$Clock) { @(for ($hi = 0; $hi -lt $(if ($Clock) { 23 } else { 21 }); $hi++) { if ($H0.AddHours($hi).Hour % 6 -eq 0) { "<b style='grid-column:$($hi + 1)/span 2'>$($H0.AddHours($hi).ToString('HH'))</b>" } }) + $(if (-not $Clock) { "<b class=nw style='grid-column:23/span 2'>now</b>" }) -join '' }
# Disk · 7 days (owner 2026-11-21: one disk section): a row per day (today on top), 24 clock hours, then GB written, kit GB (share) and
# each drive's free GB at day end with its change; it answers how much is written, by whom (kit or not) and whether a drive fills up.
# An hour: shade = machine GB (one scale for the week), bottom stripe = kit share, the number only from writes.cellMinGB; no sample
# covered it: hatched (never 0); $Drives: Resources disk rows (free = GB per day of $DDays, oldest first)
function Format-KitWritesCard($W, $Drives = @(), $DDays = @()) {
  $drv = @($Drives | Where-Object { $_ -and @($_.free | Where-Object { $null -ne $_ }).Count })
  # no write samples yet: the days still carry the drives' free space (hours hatched)
  $ds = @($W.days | Where-Object { $_ }); if (-not $ds.Count) { if (-not $drv.Count) { return '' }; $ds = @(@($DDays)[(@($DDays).Count - 1)..0] | ForEach-Object { [pscustomobject]@{ d = "$_"; m = 0; k = 0; h = @() } }) }
  $hard = [double](Get-KitParam 'writes.hardGBPerHour'); $minGB = [double](Get-KitParam 'writes.cellMinGB'); $dropGB = [double](Get-KitParam 'writes.freeDropWarnGB'); $ic = [cultureinfo]::InvariantCulture
  $gv = { param($v) $d = [double]$v; if ($d -le 0) { '0' } elseif ($d -lt 0.095) { $d.ToString('0.00', $ic) } else { & $n1 $d } }
  $gbT = { param($v) $d = [double]$v; if ($d -lt 1) { "$([math]::Round($d * 1024)) MB" } else { "$(& $n1 $d) GB" } }
  $fGB = { param($v) $d = [double]$v; if ($d -ge 100) { "$([math]::Round($d))" } else { & $n1 $d } }
  $at = if ($W.at) { [datetime]$W.at } else { $at }; $last = if ($W.last) { [datetime]$W.last } else { $null }
  $scD = [math]::Max($hard, [double](@($ds | ForEach-Object { @($_.h) | ForEach-Object { [double]@($_)[0] } }) + 0 | Measure-Object -Maximum).Maximum)
  $lowD = @{}; foreach ($dv in $drv) { $lowD[$dv.n] = [double](@($dv.free | Where-Object { $null -ne $_ }) | Measure-Object -Minimum).Minimum }
  $cell = { param($hv, [datetime]$t, [bool]$isNow) $m = [double]@($hv)[0]; $k = [double]@($hv)[1]; $tw = "$(@($hv)[2])"; $hh = $t.ToString('HH:00'); $nw = if ($isNow) { ' nw' } else { '' }
    if ($t -gt $at) { return '<i class=fu></i>' }
    if (-not [int]@($hv)[3] -and $m -le 0) { return "<i class='ns$nw' title='$hh · no samples'></i>" }
    if ($m -le 0) { return "<i$(if ($nw) { ' class=nw' }) title='$hh · 0 written'></i>" }
    $a = Get-KitHeatShade ($m / $scD); $kp = [int][math]::Round(100 * [math]::Min(1.0, $k / $m))
    "<i class='$("$(if ($a -ge 55) { 'hi' })$nw".Trim())' style='--a:$a%;--k:$kp%' title='$(& $e "$hh · $(& $gbT $m) machine · $(& $gbT $k) kit ($kp%)$(if ($tw) { " · top writer: $tw" })")'>$(if ($m -ge $minGB) { Format-KitHeatNum $m })</i>" }
  $dHead = "<div class='gk gh'><span class=gn>day · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead ([datetime]$ds[0].d) -Clock)</span><span class=gc title='GB the machine wrote that day'><small>written</small></span><span class=gc title='GB kit-owned processes wrote that day (share of the day)'><small>kit</small></span>$(@($drv | ForEach-Object { "<span class=gc title='$(& $e "$($_.n): free GB at the day's last sample, change vs the day before")'><small>$(& $e ($_.n -replace '^disk ')) free</small></span>" }) -join '')</div>"
  $dRows = @(for ($di = 0; $di -lt $ds.Count; $di++) { $dy = $ds[$di]; $d0 = [datetime]$dy.d; $dl = if ($di) { $d0.ToString('ddd dd', $ic) } else { "today · as of $(if ($last) { $last.ToString('HH:mm') } else { $at.ToString('HH:mm') })" }
      $kp = if ([double]$dy.m -gt 0) { [int][math]::Round(100 * [math]::Min(1.0, [double]$dy.k / [double]$dy.m)) } else { 0 }
      $hrs = "<span class='gs hm dw' role=img aria-label='$(& $e "$dl, GB written per hour")'>$(@(for ($hi = 0; $hi -lt 24; $hi++) { & $cell @($dy.h)[$hi] $d0.AddHours($hi) ((-not $di) -and $hi -eq $at.Hour) }) -join '')</span>"
      $ix = [array]::IndexOf(@($DDays), $d0.ToString('yyyy-MM-dd'))
      $fc = @(foreach ($dv in $drv) { $fv = if ($ix -ge 0) { @($dv.free)[$ix] } else { $null }; $pv = if ($ix -gt 0) { @($dv.free)[$ix - 1] } else { $null }
          if ($null -eq $fv) { "<span class='gc z' title='no free-space sample that day'>—</span>"; continue }
          $dd = if ($null -ne $pv) { [double]$fv - [double]$pv } else { $null }; $wn = $null -ne $dd -and -$dd -ge $dropGB
          "<span class='gc fr$(if ($wn) { ' warn' })$(if ([double]$fv -le $lowD[$dv.n]) { ' lo' })' title='$(& $e "$($dv.n) $dl`: $(& $n1 $fv) GB free$(if ($null -ne $dd) { ", $(if ($dd -lt 0) { 'down' } else { 'up' }) $(& $n1 ([math]::Abs($dd))) GB vs the day before" })")'>$(& $fGB $fv)$(if ($null -ne $dd -and [math]::Abs($dd) -ge 0.05) { "<small>$(if ($dd -lt 0) { '▼' } else { '▲' })$(& $n1 ([math]::Abs($dd)))</small>" })</span>" })
      $cov = [bool]@(@($dy.h) | Where-Object { [int]@($_)[3] -or [double]@($_)[0] -gt 0 }).Count   # a day no sample covered: "—", not 0
      $wc = if ($cov) { "<span class='gc$(if ((& $gv $dy.m) -eq '0') { ' z' })'>$(& $gv $dy.m)</span><span class='gc$(if ((& $gv $dy.k) -eq '0') { ' z' })'>$(& $gv $dy.k)$(if ($kp) { "<small>$kp%</small>" })</span>" } else { "<span class='gc z' title='no samples that day'>—</span><span class='gc z'>—</span>" }
      "<div class=gk><span class=gn title='$(& $e "${dl}: $(if ($cov) { "$(& $gbT $dy.m) written, $(& $gbT $dy.k) kit-owned ($kp%)" } else { 'no samples' })")'>$(& $e $dl)</span>$hrs$wc$($fc -join '')</div>" })
  $tot = [double](@($ds | ForEach-Object { [double]$_.m }) + 0 | Measure-Object -Sum).Sum; $totK = [double](@($ds | ForEach-Object { [double]$_.k }) + 0 | Measure-Object -Sum).Sum
  $stale = $last -and ($at - $last).TotalMinutes -gt 2 * [double](Get-KitParam 'supervise.heartbeatMinutes')
  $sum = "$(& $gbT $tot) written in 7 days (kit $(& $gbT $totK), $(if ($tot -gt 0) { [int][math]::Round(100 * $totK / $tot) } else { 0 })%)$(if ($drv.Count) { " · free now $(@($drv | ForEach-Object { "$($_.n -replace '^disk ') $(& $fGB $_.fnow) GB" }) -join ' · ')" })$(if ($stale) { " · no samples since $($last.ToString('HH:mm'))" })"
  & $fold 'writes' 'Disk · 7 days' '' "<div class='gks wdk' style='--rc:$(2 + $drv.Count)' data-mk=writes-day-hour>$dHead$($dRows -join '')</div>$(Format-KitLegend "<i class='lgk r'></i>shade = GB / hour <i class='lgk kst'></i>stripe = kit share <i class='lgk nsx'></i>hatch = no samples · ▼ = free-space drop" "an hour: shade = GB the machine wrote (one scale for the week; a number from $(& $n1 $minGB) GB), the bottom stripe's width = the kit-owned share (est. = share of process I/O x disk writes) · outlined = now · free = GB at the day's last sample, amber = a drop of $(& $n1 $dropGB) GB or more, bold = the week's lowest · per owner: Resources · 24 h, Writes GB")" -tag h4 -cls 'sub st wr' -extra "<span class=fsm>$(& $e $sum)</span>"
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
function Test-KitHeatBusy($Hours, [scriptblock]$Busy = { param($c) [double]@($c)[0] -gt 0 }, [int]$Last = 12) {
  $hs = @($Hours); if (-not $hs.Count) { return $false }; foreach ($hi in ([math]::Max(0, $hs.Count - $Last))..($hs.Count - 1)) { if (& $Busy @($hs[$hi])) { return $true } }; $false }
# rows with data in the last 12 h show; the rest fold into one "N idle rows" line (a tap shows them); $Rows: @{ html; busy }
function Format-KitHeatRows($Rows, [string]$What = 'rows', [string]$Span = '12 h') {
  $rs = @($Rows | Where-Object { $_ }); $on = @($rs | Where-Object busy); $off = @($rs | Where-Object { -not $_.busy })
  (@($on | ForEach-Object html) -join '') + $(if ($off.Count) { "<button type=button class=gkx aria-expanded=false>$($off.Count) idle $(& $e $What) · no data in $Span</button><div class=gki>$(@($off | ForEach-Object html) -join '')</div>" }) }
# the fold count of a heatmap card: busy rows of all
function Get-KitHeatCount($Rows) { $rs = @($Rows | Where-Object { $_ }); "$(@($rs | Where-Object busy).Count) of $($rs.Count) busy" }
# THE day heatmap (owner 2026-11-19: a time series = the shared heatmap): rows = series, columns = $Dates (yyyy-MM-dd, the last = today,
# outlined), the row total on the right; each row shaded by its own peak; a row: @{ n = label; sub; title; v = a value per day ($null: no
# data); t = total text; tips = a tooltip per day; fmt = { param($v) cell number }; cls = colours (slate; ws sage; fh l-act red ..);
# zero: a 0 shows (else blank); tx = a text per day (else the number); dd = a direction per day; sh = a shade % per day (else by the row's peak); ft + fv = a filter value per day: a cell click filters [data-fk] rows (page JS); keep: shown when idle; gl: a rule above }; idle rows fold
# a day cell's or total's number: 10k+ compact (12k, 3.4M, 1.2B), else Format-KitHeatNum
function Format-KitCompactNum($V) { if ($null -eq $V) { return '' }; $d = [double]$V; $iv = [cultureinfo]::InvariantCulture
  if ($d -ge 999.95e6) { ($d / 1e9).ToString('0.#', $iv) + 'B' } elseif ($d -ge 999.5e3) { ($d / 1e6).ToString('0.#', $iv) + 'M' } elseif ($d -ge 1e4) { "$([math]::Round($d / 1e3))k" } elseif ($d -ge 999.5) { ($d / 1e3).ToString('0.#', $iv) + 'k' } else { Format-KitHeatNum $d } }   # 4916 -> 4.9k (owner 2026-11-20)
function Format-KitDayHeat($Rows, [string[]]$Dates, [string]$What, [string]$TotLabel = '7 d') {
  $nd = @($Dates).Count; if (-not $nd) { return '' }; $ic = [cultureinfo]::InvariantCulture; $cn = "style='--n:$nd'"
  $dl = { param($i) if ($i -eq $nd - 1) { 'today' } else { try { ([datetime]$Dates[$i]).ToString('ddd dd', $ic) } catch { "$($Dates[$i])" } } }
  $head = "<div class='gk gh'><span class=gn>$(& $e $What)</span><span class='gs0 hrs dy' $cn aria-hidden=true>$(@(for ($i = 0; $i -lt $nd; $i++) { "<b$(if ($i -eq $nd - 1) { ' class=nw' })>$(& $dl $i)</b>" }) -join '')</span><span class=gc><small>$(& $e $TotLabel)</small></span></div>"
  $rs = @(foreach ($r in @($Rows | Where-Object { $_ })) { $vs = @(for ($i = 0; $i -lt $nd; $i++) { @($r.v)[$i] })
      $mx = [math]::Max(1e-9, [double](@($vs | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ }) + 0 | Measure-Object -Maximum).Maximum)
      $pk = if ($r.sk) { Get-KitSplitPeaks $r.so $r.sk }   # sk + so: a split row (usage.ps1 split), each type shaded by its own peak
      # the parts as one bar: gradient stops at their running share, each in its tile colour (out slate, fresh k2, cache write k3, cache read k4)
      $sbG = { param($p4, [double]$tot) $acc = 0.0; $cv = @{ out = '--slate'; in = '--k2'; cw = '--k3'; cr = '--k4' }; "linear-gradient(90deg,$(@($p4 | ForEach-Object { $a1 = $acc; $acc += $(if ($tot -gt 0) { 100 * [math]::Max(0.0, [double]$_.v) / $tot } else { 0 }); "var($($cv[$_.k])) $([math]::Round($a1, 2))% $([math]::Round($acc, 2))%" }) -join ','))" }
      $cells = @(for ($i = 0; $i -lt $nd; $i++) { $v = $vs[$i]; $tx = if ($r.tx) { "$(@($r.tx)[$i])" } elseif ($null -eq $v -or ([double]$v -eq 0 -and -not $r.zero)) { '' } elseif ($r.fmt) { "$(& $r.fmt $v)" } else { Format-KitCompactNum $v }
          $tp = "$($Dates[$i])$(if ($i -eq $nd - 1) { ' (today)' }) · $($r.n): $(if ($r.tips) { "$(@($r.tips)[$i])" } elseif ($null -eq $v) { 'no data' } elseif ($tx) { $tx } else { '0' })"
          # a split row (tokens, est. cost; owner 2026-11-21): one number = the sum of the 4 parts, the parts a stacked bar under it, each in the tooltip
          if ($r.sk -and $null -ne $v) { $sp4 = Get-KitSplitParts @($r.so)[$i] $r.sk; if ($sp4.ok) { $vt = [double](@($sp4.p4 | ForEach-Object { [double]$_.v }) + 0 | Measure-Object -Sum).Sum; $a0 = Get-KitHeatShade ($vt / $mx)
              "<i class='sdc$(if ($a0 -ge 55) { ' hi' })$(if ($i -eq $nd - 1) { ' nw' })' style='--a:$a0%;--sb:$(& $sbG $sp4.p4 $vt)' title='$(& $e $tp)'>$(& $e $(if ($vt -gt 0) { if ($r.fmt) { & $r.fmt $vt } else { Format-KitCompactNum $vt } }))</i>"; continue } }
          $c = Format-KitHeatCell $(if ($r.sh) { [int]@($r.sh)[$i] } elseif ($null -eq $v) { 0 } else { Get-KitHeatShade ([double]$v / $mx) }) $tx $tp ($i -eq $nd - 1)
          # dd: a direction per day (up / dn / rs = reset / ch = changed, not a number): the cell's colour (CSS .hm.pd)
          if ($r.dd -and "$(@($r.dd)[$i])") { $c = $c -replace '^<i', "<i data-d=$(@($r.dd)[$i])" }
          if ($r.fv -and $tx) { $c -replace '^<i', "<i tabindex=0 role=button data-ft='$(& $e $r.ft)' data-fv='$(& $e "$(@($r.fv)[$i])")'" } else { $c } })
      $busy = [bool]$r.keep -or [bool]@($vs | Where-Object { $null -ne $_ -and [double]$_ -gt 0 }).Count
      [pscustomobject]@{ busy = $busy; html = "<div class=$(if ($r.gl) { "'gk gl0'" } else { 'gk' })$(if ($r.mk) { " data-mk='$($r.mk -replace '[^\w.:-]', '-')'" })><span class=gn$(if ($r.title) { " title='$(& $e $r.title)'" })$(if ($r.id) { ' translate=no' })>$(& $e $r.n)$(if ($r.sub) { "<small>$(& $e $r.sub)</small>" })</span><span class='gs hm dy$(if ($r.cls) { " $($r.cls)" })$(if ($r.sk) { ' sbr' })' $cn role=img aria-label='$(& $e "$($r.n) per day, $nd days")'>$($cells -join '')</span><span class='gc$(if ("$($r.t)" -in '', '0', '—') { ' z' })'>$(& $e "$($r.t)")</span></div>" } })
  "<div class='gks w1 dyh'>$head$(Format-KitHeatRows $rs 'rows' "$nd days")</div>"
}
# shared card parts (owner 2026-11-19: value + label tiles, one labelled stacked bar, an aligned table; never dot-joined text lines)
# stat tiles: @{ v = value; u = unit; l = label; t = tone (act | watch); tip }
function Format-KitTiles($Tiles) {
  "<div class=tls>$(@($Tiles | Where-Object { $_ } | ForEach-Object { "<div class='tl$(if ($_.t) { " $($_.t)" })'$(if ($_.mk) { " data-mk=$($_.mk)" }) title='$(& $e (Format-KitLabel $(if ($_.tip) { $_.tip } else { "$($_.l): $($_.v)$($_.u)" })))'><b>$(& $e "$($_.v)")$(if ($_.u) { "<small>$(& $e $_.u)</small>" })</b><span>$(& $e (Format-KitLabel $_.l))</span></div>" }) -join '')</div>" }   # sentence case: the caption and its tooltip agree (ui-check)
# one stacked bar of $Max: parts @{ v; l = label; c = colour class (sk-u used, sk-p promised, sk-f free, sk-r reserve) }; the values in a legend
function Format-KitStackBar($Parts, [double]$Max, [string]$Aria, [string]$Unit = 'GB') {
  $ps = @($Parts | Where-Object { $_ -and [double]$_.v -gt 0 }); if ($Max -le 0 -or -not $ps.Count) { return '' }
  "<div class=skb><span class=skw role=img aria-label='$(& $e $Aria)'>$(@($ps | ForEach-Object { "<i class=$($_.c) style='width:$(& $n1 (100 * [math]::Min($Max, [double]$_.v) / $Max))%' title='$(& $e "$($_.l): $(& $n1 $_.v) $Unit")'></i>" }) -join '')</span>" +
  "<span class=skl>$(@($ps | ForEach-Object { "<span><i class=$($_.c)></i>$(& $e $_.l) <b>$(& $n1 $_.v)</b> $Unit</span>" }) -join '')</span></div>" }
# an aligned table: the first column left, the rest right; a cell = text or @{ h = html }
function Format-KitMiniTable([string[]]$Cols, $Rows) {
  "<table class=mtb><thead><tr>$(@($Cols | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '')</tr></thead><tbody>$(@($Rows | ForEach-Object { "<tr>$(@($_ | ForEach-Object { if ($_ -is [hashtable]) { "<td>$($_.h)</td>" } else { "<td>$(& $e "$_")</td>" } }) -join '')</tr>" }) -join '')</tbody></table>" }
# on top of Resources · 24 h (owner 2026-11-19: one resources view): RAM, the build gate, QA seats, lanes and browsers as tiles, one RAM
# bar (used / promised to builds / free above the floor / floor); RAM over 24 h = the machine row; builds per kind and owner = the builds group
function Format-KitMachineTop($Gs, $Nw, $MemPct, $MemFree, $TotalGB, [double]$Floor) {
  $fr0 = [math]::Min([double]$TotalGB, [double]$MemFree); $fa = [math]::Max(0.0, $fr0 - $Floor); $pr = [math]::Min($fa, [double]$Gs.ram); $fm = { param($v) if ($null -eq $v) { '—' } else { & $n1 $v } }
  $ramBar = if ($TotalGB -and $null -ne $MemFree) { Format-KitStackBar @(@{ v = $TotalGB - $fr0; l = 'used'; c = 'sk-u' }, @{ v = $pr; l = 'promised to builds'; c = 'sk-p' }, @{ v = $fa - $pr; l = 'free above the floor'; c = 'sk-f' }, @{ v = [math]::Min($fr0, $Floor); l = 'floor (kept free)'; c = 'sk-r' }) $TotalGB "RAM of $(& $n1 $TotalGB) GB" }
  $gq = if ($Gs) { [int]$Gs.queued } else { [int]$Nw.gq }; $gw = if ($Gs) { [double]$Gs.waitMax } else { [double]$Nw.gw }
  $tiles = @(@{ v = (& $fm $MemPct); u = '%'; l = 'RAM used'; t = $(if ($MemPct -ge 90) { 'act' } elseif ($MemPct -ge 75) { 'watch' }) },
    @{ v = $(if ($Gs) { [int]$Gs.running } else { & $fm $Nw.gr }); l = 'builds running' }, @{ v = $gq; l = 'builds queued'; t = $(if ($gq -ge 6) { 'watch' }) },
    $(if ($Gs) { @{ v = [int]$Gs.today; l = 'builds today' } }), @{ v = (& $n1 $gw); u = ' min'; l = 'longest gate wait'; t = $(if ($gw -ge 30) { 'act' }) },
    $(if ($null -ne $Nw.seatsMax) { @{ v = "$(& $fm $Nw.seats) / $(& $fm $Nw.seatsMax)"; l = 'QA seats' } }), $(if ($Gs.lanes) { @{ v = "$($Gs.leased) / $($Gs.lanes)"; l = 'phone lanes leased' } }),
    $(if ($Gs.emulators) { @{ v = $Gs.emulators; l = 'emulators running' } }), $(if ($Gs.browsers) { @{ v = $Gs.browsers; l = "test browsers · $(& $n1 $Gs.browserGB) GB" } }))
  "$(Format-KitTiles $tiles)$ramBar"
}
# Resources · 24 h (owner, 2026-11-17: CPU and RAM per resource in one heatmap): a row per resource, every name of 24 h plus each
# configured lane service (Update-KitCpuStats svc: a stopped one keeps its row); a cell's top half = avg CPU % of the machine (slate),
# the bottom = avg RAM GB (sage; full = the biggest peak, the machine: its total); lease / slot RAM first, else the service's process
# tree; columns CPU now / peak / avg %, RAM now / peak GB; red: over 80% between sweeps 5+ min apart, amber: a peak over 80% in 24 h
# owner 2026-11-19 (one resources view): metric switch CPU · RAM | Writes GB (Get-KitWriteView: kit-owned rows by resource name, agent
# shells, lanes; machine, kit-owned and other processes) | Waits min (Get-KitLeaseWaits); rows in groups (machine open, the rest
# folded; count + the worst state on the group row), holder + branch / task on the row
function Format-KitResHeat($Cpu, $Resources, $Live, [double]$TotalGB, $MemNowGB = $null, $Writes = $null, $Waits = $null, $Gate = $null, [string]$HeadHtml = '') {
  $h0 = $at.Date.AddHours($at.Hour - 23); $hrOf = { param($x) try { [int][math]::Floor(([datetime]$x - $h0).TotalHours) } catch { -1 } }
  $hotPct = [double](Get-KitParam 'supervise.hotCpuPct'); $hotSec = [double](Get-KitParam 'supervise.hotCpuSec'); $hot = { param($v, $s) [double]$v -gt $hotPct -and [int]$s -ge $hotSec }
  $names = { param($o) if ($o -is [Collections.IDictionary]) { @($o.Keys) } elseif ($o) { @((Get-KitProps $o).Name) } else { @() } }   # this sweep's: a dictionary; older ones: from JSON
  $ss = @($Cpu.samples | Where-Object { $_ -and (& $hrOf $_.at) -in 0..23 }); $last = if ($ss.Count) { $ss[-1] }; $synC = @{}; $synR = @{}
  $ls = @($Live | Where-Object { $_ -and $_.at -and (& $hrOf $_.at) -in 0..23 -and [datetime]$_.at -lt $at })
  $resRows = [ordered]@{}; $lst = { , @(0..23 | ForEach-Object { , [Collections.Generic.List[object]]::new() }) }
  # an old lane id in older samples (rm · api) joins its bird id's row (rm-falcon · api)
  $row = { param([string]$n) $n = ConvertTo-KitLaneId $n; if (-not $resRows.Contains($n)) { $resRows[$n] = [pscustomobject]@{ n = $n; c = (& $lst); r = (& $lst); t = (& $lst); by = (& $lst); cv = [Collections.Generic.List[double]]::new() } }; $resRows[$n] }
  $mach = & $row 'whole machine'
  foreach ($s in $ss) { $hi = & $hrOf $s.at; $mach.c[$hi].Add([double]$s.all); $mach.cv.Add([double]$s.all)
    foreach ($nm in (& $names $s.g)) { $w = & $row "$nm"; $v = [double](Get-KitMember $s.g $nm); $w.c[$hi].Add($v); $w.cv.Add($v) }
    foreach ($nm in (& $names $s.m)) { (& $row "$nm").t[$hi].Add([double](Get-KitMember $s.m $nm)) }
    # D1: kit-owned = the kit's process trees summed, other processes = the machine minus them (CPU now; RAM below, by hour)
    $kc = [double](@(& $names $s.g | ForEach-Object { [double](Get-KitMember $s.g $_) }) + 0 | Measure-Object -Sum).Sum; $km = [double](@(& $names $s.m | ForEach-Object { [double](Get-KitMember $s.m $_) }) + 0 | Measure-Object -Sum).Sum
    $kr = & $row 'kit-owned'; $kr.c[$hi].Add($kc); $kr.cv.Add($kc); $kr.t[$hi].Add($km); $orw = & $row 'other processes'; $oc = [math]::Max(0.0, [double]$s.all - $kc); $orw.c[$hi].Add($oc); $orw.cv.Add($oc)
    if ($s -eq $last) { $synC = @{ 'kit-owned' = $kc; 'other processes' = $oc }; $synR = @{ 'kit-owned' = $km } } }
  foreach ($x in $ls) { $hi = & $hrOf $x.at; if ($null -ne $x.mem -and $TotalGB) { $mach.r[$hi].Add($TotalGB * [double]$x.mem / 100) }
    foreach ($nm in (& $names $x.res)) { $v = Get-KitMember $x.res $nm; $w = & $row "$nm"; $w.r[$hi].Add([double]$v.gb); if ("$($v.by)".Trim()) { $w.by[$hi].Add("$($v.by)".Trim()) } } }
  if ($resRows.Contains('kit-owned')) { $kr = $resRows['kit-owned']; $orw = $resRows['other processes']; for ($hi = 0; $hi -lt 24; $hi++) { if ($mach.r[$hi].Count -and $kr.t[$hi].Count) { $orw.t[$hi].Add([math]::Max(0.0, [double](@($mach.r[$hi]) | Measure-Object -Average).Average - [double](@($kr.t[$hi]) | Measure-Object -Average).Average)) } }
    if ($null -ne $MemNowGB -and $synR) { $synR['other processes'] = [math]::Max(0.0, [double]$MemNowGB - $synR['kit-owned']) } }
  foreach ($nm in @($Cpu.svc | Where-Object { $_ })) { $null = & $row "$nm" }
  $cur = @{}; foreach ($r0 in @($Resources | Where-Object { $_.name })) { $cur[(ConvertTo-KitLaneId "$($r0.name)")] = $r0; $w = & $row "$($r0.name)"; $w.r[23].Add([double]$r0.gb); if ("$($r0.by)".Trim()) { $w.by[23].Add("$($r0.by)".Trim()) } }
  if ($null -ne $MemNowGB) { $mach.r[23].Add([double]$MemNowGB) }
  # an old and a bird lane id on one row: written GB summed (per hour, now, avg, today, 7 d), peak of the sum
  $wv = @{}; foreach ($x in @(@($Writes.rows) + @($Writes.more) | Where-Object { $_ -and $_.n })) { $wk0 = ConvertTo-KitLaneId "$($x.n)"; $w0 = $wv[$wk0]
    $wv[$wk0] = if (-not $w0) { $x } else { $wh0 = @(for ($i = 0; $i -lt 24; $i++) { [double]@($w0.h)[$i] + [double]@($x.h)[$i] })
      [pscustomobject]@{ n = $wk0; a = "$($w0.a)"; c = "$($w0.c)"; h = $wh0; now = [double]$w0.now + [double]$x.now; peak = [double]($wh0 + 0 | Measure-Object -Maximum).Maximum; avg = [double]$w0.avg + [double]$x.avg; day = [double]$w0.day + [double]$x.day; d7 = [double]$w0.d7 + [double]$x.d7 } } }
  $wm = $wv['whole machine']; $wk = $wv['kit-owned']
  if ($wm -and $wk) { $oh = @(for ($i = 0; $i -lt 24; $i++) { [math]::Max(0.0, [double]@($wm.h)[$i] - [double]@($wk.h)[$i]) }); $dif = { param([string]$f) [math]::Max(0.0, [double](Get-KitMember $wm $f) - [double](Get-KitMember $wk $f)) }
    $otop = @(@($Writes.rows) + @($Writes.more) | Where-Object { $_ -and "$($_.n)" -notin 'whole machine', 'kit-owned', 'others' -and -not $_.a -and -not $resRows.Contains((ConvertTo-KitLaneId "$($_.n)")) -and "$($_.n)" -notmatch '^lane ' } | Sort-Object { - [double]$_.d7 } | Select-Object -First 3 | ForEach-Object { "$($_.n) $(& $n1 $_.d7) GB" })
    $wv['other processes'] = [pscustomobject]@{ n = 'other processes'; a = ''; c = "7 days: $($otop -join ', ')"; h = $oh; now = (& $dif now); peak = [double]($oh + 0 | Measure-Object -Maximum).Maximum; avg = [double]($oh | Measure-Object -Sum).Sum / 24; day = (& $dif day); d7 = (& $dif d7) }
    $null = & $row 'kit-owned'; $null = & $row 'other processes' }
  foreach ($k0 in @($wv.Keys)) { if ("$($wv[$k0].a)" -eq 'shell' -or $k0 -match '^(lane|disk) ') { $null = & $row $k0 } }   # agent shells and lanes: their own rows
  $qv = @{}; foreach ($x in @($Waits.rows | Where-Object { $_ -and $_.name })) { $qk0 = ConvertTo-KitLaneId "$($x.name)"; $q0 = $qv[$qk0]   # two ids: waits and minutes summed, the longest kept
    $qv[$qk0] = if (-not $q0) { $x } else { [pscustomobject]@{ name = $qk0; n = [int]$q0.n + [int]$x.n; min = [double]$q0.min + [double]$x.min; max = [math]::Max([double]$q0.max, [double]$x.max); hours = @(if ([int]$x.n -gt [int]$q0.n) { $x.hours } else { $q0.hours }) } }; $null = & $row "$($x.name)" }
  $gv = { param($v) $d = [double]$v; if ($d -le 0) { '0' } elseif ($d -lt 0.095) { $d.ToString('0.00', [cultureinfo]::InvariantCulture) } else { & $n1 $d } }
  $avg ={ param($l) if ($l.Count) { [double](@($l) | Measure-Object -Average).Average } else { $null } }; $max = { param($l) [double](@($l) + 0 | Measure-Object -Maximum).Maximum }   # $null kept: a tuple slot, never dropped
  $ramOf = { param($w, $hi) if ($w.r[$hi].Count) { $w.r[$hi] } else { $w.t[$hi] } }   # a lease's own GB first, else the process tree's
  $ramTop = [math]::Max(0.1, [double](@($resRows.Values | Where-Object { $_ -ne $mach } | ForEach-Object { $w = $_; 0..23 | ForEach-Object { & $max (& $ramOf $w $_) } }) + 0 | Measure-Object -Maximum).Maximum)
  $topIn = @{}; foreach ($s in $ss) { $hi = & $hrOf $s.at; foreach ($t in @($s.top | Where-Object { $_ })) { $k0 = "$hi|$($t.n)"; if (-not $topIn[$k0] -or [double]$t.p -gt $topIn[$k0].p) { $topIn[$k0] = [pscustomobject]@{ h = $hi; n = "$($t.n)"; p = [double]$t.p } } } }
  $rows = @(foreach ($w in @(@($mach) + @($resRows.Values | Where-Object { $_ -ne $mach } | Sort-Object n))) { $nm = $w.n; $isM = $w -eq $mach; $scale = if ($isM -and $TotalGB) { $TotalGB } else { $ramTop }
      $hours = @(for ($hi = 0; $hi -lt 24; $hi++) { $rv = & $ramOf $w $hi; $tops = if ($isM) { @($topIn.Values | Where-Object h -eq $hi | Sort-Object { - $_.p } | Select-Object -First 3 | ForEach-Object { "$($_.n) $(& $n1 $_.p)%" }) -join ', ' }
          , @(($w.c[$hi].Count + $rv.Count), (& $avg $w.c[$hi]), (& $max $w.c[$hi]), (& $avg $rv), (@($w.by[$hi] | Select-Object -Unique) -join ', '), "$tops", $scale) })
      $hasC = $w.cv.Count -gt 0; $cNow = if ($hasC -and $last) { if ($isM) { [double]$last.all } elseif ($synC.ContainsKey($nm)) { $synC[$nm] } else { [double](Get-KitMember $last.g $nm) } }
      $cPk = & $max $w.cv; $cAvg = if ($hasC -and $ss.Count) { [double](@($w.cv) | Measure-Object -Sum).Sum / $ss.Count }
      $rNow = if ($isM) { $MemNowGB } elseif ($synR.ContainsKey($nm)) { $synR[$nm] } elseif ($cur.ContainsKey($nm)) { [double]$cur[$nm].gb } elseif ($last -and $null -ne (Get-KitMember $last.m $nm)) { [double](Get-KitMember $last.m $nm) }
      $rAll = @(0..23 | ForEach-Object { & $ramOf $w $_ } | ForEach-Object { $_ }); $rPk = [math]::Max([double]$rNow, (& $max $rAll)); $hasR = $rAll.Count -gt 0 -or $null -ne $rNow
      $r0 = $cur[$nm]; $by = "$($r0.by)".Trim(); $hp = Split-KitHolder $by
      $sub = if (-not $r0) { '' } elseif ($r0.shared) { 'shared · always on' } elseif ($hp.h -notin '', 'no lease') { "$($hp.h)$($hp.g)" } else { "no live holder$($hp.g)" }
      $bt = if ($r0 -and -not $r0.shared) { @($hp.b, (Get-KitHolderTask $hp.h) | Where-Object { $_ }) -join ' · ' } else { '' }   # owner 2026-11-19: the held list's branch / task column, now on the row
      $vals = @($(if ($hasC) { & $n1 $cNow } else { '—' }), $(if ($hasC) { & $n1 $cPk } else { '—' }), $(if ($hasC) { & $n1 $cAvg } else { '—' }), $(if ($null -ne $rNow) { & $n1 $rNow } else { '—' }), $(if ($hasR) { & $n1 $rPk } else { '—' }))
      $tone = if ($hasC -and $last -and (& $hot $cNow $last.s)) { 'hot' } elseif ($cPk -gt 80) { 'warn' } else { '' }
      $wr = $wv[$nm]; $qr = $qv[$nm]; if (-not $sub -and "$($wr.a)") { $sub = "$($wr.a)" }
      $wh = @(if ($wr) { $wr.h | ForEach-Object { , @([double]$_) } }); $wvals = if ($wr) { @($wr.now, $wr.peak, $wr.avg, $wr.day, $wr.d7 | ForEach-Object { & $gv $_ }) } else { @('—') * 5 }
      $qvals = if ($qr) { @("$([int]$qr.n)", (& $n1 $qr.min), (& $n1 $qr.max), '', '') } else { @('—', '—', '—', '', '') }
      $gk = if ($nm -in 'whole machine', 'kit-owned', 'other processes' -or ($wr -and $nm -match '^disk ')) { 'machine' } elseif ($r0.shared) { 'shared' } elseif ("$($wr.a)" -eq 'shell') { 'shell' } elseif ($nm -match '^(build|slot|phone|browser|lock|lane)\b') { $Matches[1] -replace '^lane$', 'env' } elseif ($nm -match '·') { 'env' } else { 'other' }
      $has = $isM -or $nm -match '^disk ' -or @($hours | Where-Object { [int]@($_)[0] }).Count -or @($wh | Where-Object { [double]@($_)[0] -gt 0 }).Count -or ($qr -and [int]$qr.n)
      [pscustomobject]@{ nm = $nm; grp = $gk; has = $has; busy = $isM -or [bool]$r0 -or (Test-KitHeatBusy $hours { param($c) [double]@($c)[1] -ge 0.1 -or [double]@($c)[3] -gt 0 } -Last 24) -or ($wr -and [double]$wr.day -gt 0) -or ($qr -and [int]$qr.n)
        dk = $(if ($nm -match '^disk ') { "$($wr.tone)" }); tone = $tone; orphan = $r0 -and -not $r0.shared -and $by -match '^$|\(grace|^no lease$'; sub = $sub; bt = $bt; vals = $vals; hours = $hours; wh = $wh; wvals = $wvals; wc = "$($wr.c)"; qh = @(if ($qr) { $qr.hours }); qvals = $qvals } })
  $cols = @('now %', 'peak %', 'avg %', 'now GB', 'peak GB')
  $mc = @(@('c', $cols), @('w', @('now', 'peak', 'avg', 'today', '7 d')), @('q', @('waits', 'min', 'longest', '', '')), @('b', @('today', 'build-min', 'failed', 'wait avg', 'wait peak')))
  $head = "<div class='gk gh'><span class=gn>resource · holder · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@(foreach ($m in $mc) { foreach ($cn in $m[1]) { "<span class=gc data-mv=$($m[0])><small>$cn</small></span>" } }) -join '')</div>"
  $soft = [double](Get-KitParam 'writes.softGBPerHour'); $hard = [double](Get-KitParam 'writes.hardGBPerHour')
  $wmx = { param($rs) [math]::Max($hard, [double](@($rs | ForEach-Object { $_.wh } | ForEach-Object { [double]@($_)[0] }) + 0 | Measure-Object -Maximum).Maximum) }
  $wscM = & $wmx @($rows | Where-Object grp -eq 'machine'); $wscO = & $wmx @($rows | Where-Object grp -ne 'machine')
  $lane = ''; $items = @(foreach ($r in $rows) { $ln = ("$($r.nm)" -split ' · ')[0]; $first = $r.nm -ne 'whole machine' -and $ln -ne $lane; $lane = $ln; $nm = $r.nm; $wsc = if ($r.grp -eq 'machine') { $wscM } else { $wscO }
      $wn = if ($r.grp -eq 'machine') { 0 } else { [double]($r.wvals[0] -replace '—', '0') }; [pscustomobject]@{ dk = $r.dk; busy = $r.busy -and $r.has; has = $r.has; grp = $r.grp; tone = $r.tone; orphan = $r.orphan; wl = $(if ($wn -ge $hard) { 2 } elseif ($wn -ge $soft) { 1 } else { 0 }); ql = [double]($r.qvals[2] -replace '—', '0') -ge 30; html = "<div$(if ($nm -match '^disk ') { ' data-mv=w' }) class='gk$(if ($first) { ' gl0' })$(if ($r.tone) { " $($r.tone)" })$(if ($r.orphan) { ' orphan' })$(if ($r.dk) { " $($r.dk)" })'><span class=gn title='$(& $e "${nm}$(if ($r.sub) { " · $($r.sub)" }): $(if ($r.grp -eq 'machine' -and $nm -match '^disk ') { "$($r.wc) · Writes GB: what it filled per hour" } elseif ($r.vals[0] -ne '—') { "CPU now $($r.vals[0])% · 24 h peak $($r.vals[1])% · avg $($r.vals[2])% · " } else { 'CPU not sampled: not running, or no process tree of its own (lease, slot, lock, external) · ' })$(if ($r.vals[3] -ne '—') { "RAM now $($r.vals[3]) GB · 24 h peak $($r.vals[4]) GB" } elseif ($nm -notmatch '^disk ') { 'RAM: not running now' })")'>$(& $e $nm)$(if ($r.sub) { "<small>$(& $e $r.sub)</small>" })$(if ($r.bt) { "<small class=bt>$(& $e $r.bt)</small>" })</span>" +
        ((Format-KitHeatCells $r.hours $h0 "$nm, CPU % and RAM GB per hour, last 24 h" { param($hv) if (-not $hv[0]) { "$nm · no sample" } else { "$nm · $(@(@($(if ($null -ne $hv[1]) { "CPU avg $(& $n1 $hv[1])% · peak $(& $n1 $hv[2])%" }), "RAM $(if ($null -ne $hv[3]) { "$(& $n1 $hv[3]) GB" } else { '—' })") | Where-Object { $_ }) -join ' · ')$(if ("$($hv[4])") { " · $($hv[4])" })$(if ("$($hv[5])") { " · top: $($hv[5])" })" } } { param($hv) @((Get-KitHeatShade ([double]$hv[1] / 100)), (Format-KitHeatNum $hv[1]), (Get-KitHeatShade ([double]$hv[3] / [double]$hv[6])), (Format-KitHeatNum $hv[3])) } 'sp') -replace '^<span ', '<span data-mv=c ') +
        ((Format-KitHeatCells $r.wh $h0 "$nm, GB written per hour, last 24 h" { param($hv) "$nm · $(& $gv $hv[0]) GB $(if ($nm -match '^disk ') { 'filled (free space dropped)' } else { 'written' })$(if ($r.wc) { " · $($r.wc)" })" } { param($hv) @((Get-KitHeatShade ([double]$hv[0] / $wsc)), (Format-KitHeatNum $hv[0])) } 'ws') -replace '^<span ', '<span data-mv=w ') +
        ((Format-KitHeatCells $r.qh $h0 "$nm, minutes waited per hour, last 24 h" { param($hv) "$([int]$hv[0]) waits · $(& $n1 $hv[1]) min · longest $(& $n1 $hv[2]) min$(if ("$(@($hv)[3])") { " · $($hv[3])" })" }) -replace '^<span ', '<span data-mv=q ') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.vals[$ci] -in '0', '—') { ' z' })' data-mv=c title='$(& $e "${nm}: $($cols[$ci] -replace ' (%|GB)$') $(if ($ci -lt 3) { 'CPU' } else { 'RAM' }) $($r.vals[$ci]) $(if ($ci -lt 3) { '%' } else { 'GB' })")'>$($r.vals[$ci])</span>" }) -join '') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.wvals[$ci] -in '0', '—') { ' z' })$(if ($ci -eq 0 -and $r.grp -ne 'machine' -and [double]($r.wvals[0] -replace '—', '0') -ge $hard) { ' hot' } elseif ($ci -eq 0 -and $r.grp -ne 'machine' -and [double]($r.wvals[0] -replace '—', '0') -ge $soft) { ' warn' })' data-mv=w title='$(& $e "${nm}: $($mc[1][1][$ci]) $($r.wvals[$ci]) GB")'>$($r.wvals[$ci])</span>" }) -join '') +
        (@(for ($ci = 0; $ci -lt 5; $ci++) { "<span class='gc$(if ($r.qvals[$ci] -in '0', '—', '') { ' z' })' data-mv=q>$($r.qvals[$ci])</span>" }) -join '') + '</div>' } })
  $tops = @($ss | ForEach-Object { $s0 = $_; @($_.top | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ k = "$($_.pid)|$($_.n)"; n = $_.n; pid = $_.pid; p = [double]$_.p; o = "$($_.o)"; c = "$($_.c)"; at = $s0.at; s = $s0.s; nowS = [bool]($s0 -eq $last) } } } | Group-Object k | ForEach-Object { $gp = @($_.Group | Sort-Object { [datetime]$_.at }); $pk = ($gp | Measure-Object p -Maximum).Maximum
      [pscustomobject]@{ n = $gp[-1].n; pid = $gp[-1].pid; o = @($gp.o | Where-Object { $_ })[-1]; c = $gp[-1].c; now = $(if ($gp[-1].nowS) { $gp[-1].p }); pk = $pk; hot = [bool]@($gp | Where-Object { & $hot $_.p $_.s }).Count } } | Sort-Object { - $_.pk } | Select-Object -First 8)
  $topHtml = if ($tops.Count) { & $fold 'cpu-top' 'Top other processes' $tops.Count ("<div class=cpt><div class=s>10%+ of the machine between two sweeps</div>" + (@($tops | ForEach-Object { "<div class='cpo f$(if ($_.hot) { ' hot' })' title='$(& $e $(if ($_.c) { $_.c } else { $_.n }))'><span class=cn0>$(& $e $_.n) <small>pid $($_.pid)$(if ($_.o) { " · $($_.o)" })</small></span><span class=gc>now $(if ($null -ne $_.now) { "$(& $n1 $_.now)%" } else { '—' })</span><span class=gc>24 h peak $(& $n1 $_.pk)%</span></div>" }) -join '') + '</div>') -Open:([bool]@($tops | Where-Object { $null -ne $_.now }).Count) -tag h4 -cls sub } else { "<div class=s>No other process over $(Get-KitParam 'supervise.topProcPct')% of the machine in 24 h</div>" }
  $legend = Format-KitLegend "<i class='lgk c'></i>CPU % <i class='lgk r'></i>RAM · dashed = no holder" "top half = avg CPU % of the machine ($([Environment]::ProcessorCount) cores), bottom half = avg RAM (full = the biggest peak, $(& $n1 $ramTop) GB; the machine: its $(& $n1 $TotalGB) GB) · outlined = now · tap a cell for both values, holders and (machine row) the top other processes · dashed = no live holder (released after idle.graceMinutes)"
  $gl = [ordered]@{ machine = 'machine'; env = 'env services'; build = 'builds'; slot = 'worktree slots'; phone = 'phones · emulators'; browser = 'browser tabs'; shell = 'agent shells'; lock = 'locks'; shared = 'shared'; other = 'other' }
  # Builds metric (owner 2026-11-19, the gate card folded in): a row per gate kind of 24 h (busy min per hour; running, queued, today, waits)
  $gh0 = try { [datetime]$Gate.h0 } catch { $h0 }   # the gate's own 24 h window (its log)
  $kinds = @(@($Gate.rows | Where-Object { $_ }) | ForEach-Object { $kr = $_; $kn = "$($kr.name)"; $kv = @("$([int]$kr.done)", "$([int]$kr.min)", "$([int]$kr.failed)", (& $n1 $kr.waitAvg), (& $n1 $kr.waitMax)); $who = @($kr.owners | Where-Object { $_ } | Select-Object -Unique)
      $kIdle = -not (@($kr.hours | ForEach-Object { [int]@($_)[0] + [double]@($_)[1] }) | Where-Object { $_ -gt 0 }).Count -and -not ([int]$kr.running + [int]$kr.queued)
      $kh = "<div class='gk mb'><span class=gn title='$(& $e "${kn}: $([int]$kr.running) running · $([int]$kr.queued) queued · $($kv[0]) today · $($kv[1]) build-min · $($kv[2]) failed · wait avg $($kv[3]) / peak $($kv[4]) min$(if ([double]$kr.ram) { " · $(& $n1 $kr.ram) GB RAM now" } elseif ([double]$kr.peakGB) { " · up to $(& $n1 $kr.peakGB) GB RAM" })")'>$(& $e $kn)$(if ($who.Count) { "<span class=och>$(@($who | ForEach-Object { "<span class=chip>$(& $e $_)</span>" }) -join '')</span>" })</span>" + ((Format-KitHeatCells $kr.hours $gh0 "$kn, builds per hour, last 24 h" { param($hv) "$kn · $([int]$hv[0]) builds · $(& $n1 $hv[1]) build-min · max wait $(& $n1 $hv[2]) min" }) -replace '^<span ', '<span data-mv=b ') + (@(for ($ci = 0; $ci -lt 5; $ci++) { if ($ci -eq 2 -and $kv[2] -ne '0') { "<span class=gc data-mv=b><span class='chip s-stuck'>$($kv[2])</span></span>" } else { "<span class='gc$(if ($kv[$ci] -eq '0') { ' z' })' data-mv=b>$($kv[$ci])</span>" } }) -join '') + '</div>'
      [pscustomobject]@{ busy = -not $kIdle; html = $kh } })
  $groups = @(foreach ($gk0 in $gl.Keys) { $gi = @($items | Where-Object grp -eq $gk0); $kb = @(if ($gk0 -eq 'build') { $kinds }); if (-not ($gi.Count + $kb.Count)) { continue }; $op = $gk0 -eq 'machine'
      $wst = if (@($gi | Where-Object tone -eq 'hot').Count) { @('s-stuck', 'CPU over 80%') } elseif (@($gi | Where-Object dk -eq 'hot').Count) { @('s-stuck', 'disk filling') } elseif (@($gi | Where-Object dk -eq 'warn').Count) { @('s-oth', 'disk low') } elseif (@($gi | Where-Object wl -ge 2).Count) { @('s-stuck', "writes over $(& $n1 $hard) GB/h") } elseif (@($gi | Where-Object wl -ge 1).Count) { @('s-oth', "writes over $(& $n1 $soft) GB/h") } elseif (@($gi | Where-Object ql).Count) { @('s-oth', 'waits of 30+ min') } elseif (@($gi | Where-Object orphan).Count) { @('s-oth', "$(@($gi | Where-Object orphan).Count) no live holder") } elseif (@($gi | Where-Object tone -eq 'warn').Count) { @('s-oth', 'CPU peak over 80%') }
      "<div class='rgg$(if (-not $op) { ' cl' })$(if ($kb.Count) { ' hb' })$(if (-not $gi.Count) { ' ob' })' data-g='rg-$gk0'><div class='gk rgh'><button type=button class=rgb aria-expanded=$(if ($op) { 'true' } else { 'false' })><span class=gn0>$($gl[$gk0])</span><span class=gcn>$(if ($gi.Count) { $gi.Count } else { "$($kb.Count) kinds" })</span>$(if ($wst) { "<span class='chip $($wst[0])'>$($wst[1])</span>" })</button></div>$(Format-KitHeatRows @($gi | ForEach-Object { [pscustomobject]@{ busy = ($_.busy -or $_.grp -eq 'machine') -and $_.has; html = $_.html } }) 'rows' '24 h')$((Format-KitHeatRows $kb 'kinds' '24 h') -replace 'class=gkx ', "class='gkx mb' ")</div>" })
  $wEst = if ("$($Writes.src)" -ne 'tracer') { ' est.' } else { '' }   # the tracer's disk MB: no "est." (owner 2026-11-19)
  $tabs = "<div class=rgt role=group aria-label='metric'>$(@(@(@('c', 'CPU · RAM'), @('w', "Writes GB$wEst"), @('q', 'Waits min'), @('b', 'Builds min')) | ForEach-Object { "<button type=button data-m=$($_[0]) aria-pressed=$(if ($_[0] -eq 'c') { 'true' } else { 'false' })>$($_[1])</button>" }) -join '')</div>"
  $legW = (Format-KitLegend "cell = GB$wEst / hour · amber > $(& $n1 $soft) · red > $(& $n1 $hard)" "a cell =$wEst GB written to disk in that clock hour (kit-owned processes by the resource, shell or lane that started them) · now = the last 60 min: amber over $(& $n1 $soft), red over $(& $n1 $hard) GB (WATCH / ACT) · other processes: its top 3 in the tooltip · a disk row: GB its free space dropped") -replace '^<div class=hk>', '<div class=hk data-mv=w>'
  $legQ = (Format-KitLegend 'cell = wait min / hour' 'a cell = minutes agents waited for that resource in the hour · tap a cell for waits and who') -replace '^<div class=hk>', '<div class=hk data-mv=q>'
  & $fold 'res24' 'Resources · 24 h' (Get-KitHeatCount $items) "<div class=rgx data-m=c>$HeadHtml$tabs<div class='gks w5 cpg rsh' data-mk=res-hour>$head$($groups -join '')</div>$($legend -replace '^<div class=hk>', '<div class=hk data-mv=c>')$legW$legQ$(if (@($kinds).Count) { (Format-KitLegend 'cell = build min / hour' 'a cell = busy build minutes in that hour (the build gate per kind) · tap a cell for builds and waits') -replace '^<div class=hk>', '<div class=hk data-mv=b>' } else { '<div class=hk data-mv=b>no gated build in 24 h</div>' })</div>$topHtml" -Open -tag h4 -cls "sub st cpu$(if ($last -and (& $hot $last.all $last.s)) { ' hot' })"
}
# the task a lease belongs to, from its holder ids (comma list): a QA code (test:T5, T5) -> its newest run's task "QA T5 · <task>"; an agent id or
# pid-N -> its live board entry's items (else run); none found: ''
function Get-KitHolderTask([string]$Holder) {
  if (-not $script:KitHolderCache) { $script:KitHolderCache = @{} }; $c = $script:KitHolderCache; $out = [Collections.Generic.List[string]]::new()
  if (-not $c.qa) { $c.qa = @(Get-ChildItem (Get-KitPath qa-runs) -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object { try { (Get-Content (Join-Path $_.FullName 'index.json') -Raw | ConvertFrom-Json).items } catch { $null } } | Where-Object { $_ }) }
  if (-not $c.board) { $c.board = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -notin 'left', 'crashed' }) }
  foreach ($id in @("$Holder" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notin 'parked', 'no lease' })) {
    $t = ''; if ($id -match '^(?:(?:test|verify):)?(?<q>T\d+)(?:@\S+)?$') { $q = $Matches.q; $it = @($c.qa | ForEach-Object { Get-KitMember $_ $q } | Where-Object { $_ } | Select-Object -First 1)[0]; if ($it) { $t = "QA $q · $(if ($it.pubKey) { $it.pubKey } else { @($it.tasks)[0] })" } }
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
# learned keys (owner 2026-11-20, K100: one row per key + scope): from params-changes, every key changed in $Days days, the latest change
# first; per day $null (no change) or @{ f = the value before the day's first change; t = after its last; c = changes }; cur = the value now
# ($null = the default); last = its newest change (ISO); why = that change's reason
function Get-KitParamDays([datetime]$Now, [int]$Days = 7, [int]$Top = 16) {
  $from = $Now.Date.AddDays(1 - $Days)
  $rs = @(Get-Content -LiteralPath (Get-KitPath params-changes) -Tail 5000 -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { } } | Where-Object { $_.key -and $(try { [datetime]$_.at -ge $from -and [datetime]$_.at -le $Now } catch { $false }) })
  @($rs | Group-Object { "$($_.key)|$(if ("$($_.ctx)" -ne '_') { $_.ctx })" } | ForEach-Object { $g = @($_.Group | Sort-Object { [datetime]$_.at }); $k0, $c0 = $_.Name -split '\|', 2
      [pscustomobject]@{ key = $k0; ctx = $c0; n = $g.Count; cur = $g[-1].to; lf = $g[-1].from; last = ([datetime]$g[-1].at).ToString('o'); why = "$($g[-1].why)"
        days = @(for ($i = 0; $i -lt $Days; $i++) { $in = @($g | Where-Object { ([datetime]$_.at).Date -eq $from.AddDays($i) }); if ($in.Count) { [pscustomobject]@{ f = $in[0].from; t = $in[-1].to; c = $in.Count } } else { $null } }) } } |
    Sort-Object { [datetime]$_.last } -Descending | Select-Object -First $Top)
}
# one icon set for the words the page repeats (running, queued, today, wait, RAM, stuck): inline SVG, currentColor, <title> = tooltip
function Format-KitIcon([string]$Name, [string]$Label = $Name) {
  $p = switch ($Name) { 'run' { "<path fill=currentColor stroke=none d='M5 3.2v9.6L12.8 8z'/>" } 'queue' { "<path fill=none d='M4.5 2h7M4.5 14h7M5.5 2v1.8c0 2 5 2.4 5 4.2s-5 2.2-5 4.2V14M10.5 2v1.8c0 2-5 2.4-5 4.2s5 2.2 5 4.2V14'/>" }
    'today' { "<path fill=none d='M3 8.6l3.2 3.1L13 4.6'/>" } 'wait' { "<circle fill=none cx=8 cy=8 r=6 /><path fill=none d='M8 4.6V8l2.3 1.6'/>" } 'stuck' { "<path fill=none d='M8 2.2l6.3 11.3H1.7zM8 6.6v3.2M8 11.6v.1'/>" }
    'ram' { "<rect fill=none x=4 y=4 width=8 height=8 rx=1.2 /><path fill=none d='M6 1.6V4M10 1.6V4M6 12v2.4M10 12v2.4M1.6 6H4M1.6 10H4M12 6h2.4M12 10h2.4'/>" } default { throw "Format-KitIcon: unknown icon '$Name'" } }
  $l = [Net.WebUtility]::HtmlEncode($Label); "<svg class='ic i-$Name hit' viewBox='0 0 16 16' role=img aria-label='$l'><title>$l</title>$p</svg>" }
# sentence case (owner 2026-11-21): a label's first word capitalised unless it is an id (a - . _ / | : @ # · \ or digit, camelCase, a crew
# agent type or workflow from _manifest, a unit); known acronyms upper-case; -Humanize: a camelCase key group reads as words (localEnv -> Local env)
function Format-KitLabel([string]$Text, [switch]$Humanize) {
  if (-not $script:KitLabelIds) { $mf = try { (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json)._manifest } catch { $null }
    $script:KitLabelIds = [Collections.Generic.HashSet[string]]::new([string[]](@((Get-KitProps $mf.agents).Name) + @((Get-KitProps $mf.workflows).Name) + @('coordinator', 'fork', 'general-purpose', 'workflow', 'min', 'h', 's', 'd', 'ms', 'gb', 'mb', 'kb', 'k', 'x', 'tok') | Where-Object { $_ }), [StringComparer]::OrdinalIgnoreCase) }
  $m = [regex]::Match($Text, '^(\s*)([^\s,;:()]+)(.*)$', 'Singleline'); if (-not $m.Success) { return $Text }; $w = $m.Groups[2].Value; $rest = $m.Groups[3].Value
  $acr = @{ api = 'API'; qa = 'QA'; ui = 'UI'; cpu = 'CPU'; ram = 'RAM'; ci = 'CI'; mr = 'MR'; mrs = 'MRs'; tsv = 'TSV'; js = 'JS' }
  if ($Humanize -and $w -cmatch '^[a-z]+(?:[A-Z][a-z0-9]*)+$') {
    $wp = @(($w -creplace '(?<=[a-z0-9])(?=[A-Z])', ' ').ToLowerInvariant() -split ' ' | ForEach-Object { if ($acr.ContainsKey($_)) { $acr[$_] } else { $_ } })
    $w = $wp[0]; $rest = ' ' + (@($wp | Select-Object -Skip 1) -join ' ') + $rest }
  elseif ($w -cnotmatch '^[a-z]' -or $w -match '[-._/|:@#\\·\d]|&#' -or $w -cmatch '[a-z][A-Z]' -or $script:KitLabelIds.Contains($w)) { return $Text }
  $up = if ($acr.ContainsKey($w.ToLowerInvariant())) { $acr[$w.ToLowerInvariant()] } elseif ($w -cmatch '^[a-z]') { $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1) } else { $w }
  "$($m.Groups[1].Value)$up$rest"
}
# the page's label elements (headings, column heads, row names, chips, tile names, legends, buttons): their first text node in sentence
# case; a tile's caption = a bare <span> after its </b> value; a <small> right after text is a unit or note (6<small> checks</small>) and
# stays; an id row (translate=no: repo names), values, cells (td), tooltips and code never change
function ConvertTo-KitLabelCase([string]$Html) {
  $lc = "\bclass=(?:'[^']*\b(?:gn0?|chip|hk|hc|k|tgn|bl|gcn|fsm|kleg|bdg|rk|knr)\b|(?:gn0?|chip|hk|hc|k|tgn|bl|gcn|fsm|kleg|bdg|rk|knr)\b)"
  [regex]::Replace($Html, '<(?<tag>th|button|summary|h[1-4]|li|small|b|span|div|p|a)(?<at>(?:\s[^>]*)?)>(?<t>\s*[a-z][^<>]*)', {
      param($m) $tg = $m.Groups['tag'].Value; $at = $m.Groups['at'].Value; if ($at -match '\btranslate=no\b') { return $m.Value }; $pre = if ($m.Index -ge 4) { $Html.Substring($m.Index - 4, 4) } else { '' }
      if ($tg -in 'span', 'div', 'p', 'a', 'li' -and $at -notmatch $lc -and -not ($tg -eq 'span' -and -not $at -and $pre -eq '</b>')) { return $m.Value }
      # a <b> is a label only as a column head (inside a .gs0 head row); else a value (a tile's number, a hold's task)
      if ($tg -eq 'b') { $back = $Html.Substring([math]::Max(0, $m.Index - 800), [math]::Min(800, $m.Index)); if ($back.LastIndexOf("class='gs0") -le $back.LastIndexOf('</span>')) { return $m.Value } }
      if ($tg -eq 'small' -and $pre -notmatch '>$') { return $m.Value }   # a unit after its value, a note after a name (Sweep time (s)<small>now 29 s)
      $old = $m.Groups['t'].Value; $new = Format-KitLabel $old -Humanize:($at -match '\bclass=tgn\b'); if ($new -ceq $old) { return $m.Value }
      "<$tg$($at.Replace("title='$($old.Trim())'", "title='$($new.Trim())'"))>$new" }) -replace '(?<=<i\b[^>]*></i>)(\s*[a-z][^<>]*)', { Format-KitLabel $_.Value }   # a key after its swatch (legends, tile captions)
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
  & $fold 'flagmap' 'Flags · 24 h' "$(@($xs | ForEach-Object { "$($_.l)|$($_.y)" } | Select-Object -Unique).Count) flags" "<div class='gks w1' data-mk=flags-hour>$head$(Format-KitHeatRows $rows 'rows')</div>$(Format-KitLegend 'cell = flags / hour · red ACT · amber WATCH · green FIXED' 'a cell = distinct flags raised that hour, shaded by count · outlined = now · tap a cell for the texts')" -Open:([bool]@($rows | Where-Object busy).Count) -tag h4 -cls 'sub st fhm'
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
  "<div class=st data-fit data-mk=qa-day><div class=k>Test runs, 7 days</div><div class=v>$n<small> checks · </small>$pct</div>$(if ($cz.Count) { "<div class=s>NOT_TESTED: $($cz -join ' · ')</div>" })" +
  "<figure class='dbr qbr'><div class=dbw role=img aria-label='checks per day, 7 days'>$($cols -join '')</div><div class=dbx>$axis</div><figcaption>$legend</figcaption></figure></div>"
}
# page JS of these cards: the idle-rows fold; links into the kit's own pages (a[data-dw]: run steps, reports) open in an in-page
# drawer (an iframe: file:// pages too; Esc, the close button or a backdrop click closes it), never navigating away (kitbag.py ui-check: LINK)
function Get-KitStatsJs {
  "(function(){var d=document;d.addEventListener('click',function(x){var b=x.target.closest('.gkx');if(!b)return;b.setAttribute('aria-expanded',b.parentNode.classList.toggle('gio'))});" +
  # Spend table: a role's button shows its step-type rows (same columns)
  "d.addEventListener('click',function(x){var b=x.target.closest('.spx');if(!b)return;b.setAttribute('aria-expanded',b.closest('tbody').classList.toggle('op'))});" +
  "var dw=d.createElement('dialog');dw.className='drw';dw.setAttribute('aria-label','Linked page');dw.innerHTML='<div class=dwh><b></b><button type=button class=ib aria-label=`"Close (Esc)`" title=`"Close (Esc)`">&#10005;</button></div><iframe title=`"Linked page`"></iframe>';d.body.appendChild(dw);var fr=dw.querySelector('iframe');" +
  "d.addEventListener('click',function(x){var a=x.target.closest('a[data-dw]');if(!a)return;x.preventDefault();dw.querySelector('b').textContent=a.dataset.dw||a.textContent;fr.src=a.getAttribute('href');dw.showModal()});" +
  "dw.querySelector('button').onclick=function(){dw.close()};dw.addEventListener('click',function(x){if(x.target==dw)dw.close()});dw.addEventListener('close',function(){fr.src='about:blank'});" +
  # Resources · 24 h: group fold and metric switch, both kept in localStorage
  "function rp(r,m){r.dataset.m=m;r.querySelectorAll('.rgt button').forEach(function(z){z.setAttribute('aria-pressed',z.dataset.m==m)})}function rf(g,c){g.classList.toggle('cl',c);var b=g.querySelector('.rgb');if(b)b.setAttribute('aria-expanded',!c)}" +
  "d.addEventListener('click',function(x){var b=x.target.closest('.rgb'),t=x.target.closest('.rgt button'),g,c;if(b){g=b.closest('.rgg');c=!g.classList.contains('cl');rf(g,c);try{localStorage.setItem('kc-'+g.dataset.g,c?'1':'0')}catch(e){}}else if(t){rp(t.closest('.rgx'),t.dataset.m);try{localStorage.setItem('kc-rm',t.dataset.m)}catch(e){}}});" +
  # [data-tg]: a button shows / hides the element of that id (kept); .rtg: a run row shows its agents
  "d.addEventListener('click',function(x){var b=x.target.closest('[data-tg]');if(!b)return;x.preventDefault();var t=d.getElementById(b.dataset.tg);if(!t)return;t.hidden=!t.hidden;b.setAttribute('aria-expanded',!t.hidden);try{localStorage.setItem('kc-tg-'+t.id,t.hidden?'0':'1')}catch(e){}});" +
  "d.querySelectorAll('[data-tg]').forEach(function(b){var t=d.getElementById(b.dataset.tg),v=null;try{v=localStorage.getItem('kc-tg-'+b.dataset.tg)}catch(e){}if(t&&v!==null){t.hidden=v!='1';b.setAttribute('aria-expanded',v=='1')}});" +
  "d.addEventListener('click',function(x){var b=x.target.closest('.rtg');if(!b)return;var g=b.closest('.rgg'),c=!g.classList.contains('cl');g.classList.toggle('cl',c);b.setAttribute('aria-expanded',!c);try{localStorage.setItem('kc-'+g.dataset.g,c?'1':'0')}catch(e){}});" +
  "try{d.querySelectorAll('.rgg[data-g]').forEach(function(g){var v=localStorage.getItem('kc-'+g.dataset.g);if(v!==null)rf(g,v=='1')});var m=localStorage.getItem('kc-rm');if(m)d.querySelectorAll('.rgx').forEach(function(r){rp(r,m)})}catch(e){}d.querySelectorAll('.rtg').forEach(function(b){b.setAttribute('aria-expanded',!b.closest('.rgg').classList.contains('cl'))})})()"
}
# CSS of these cards (appended to the page's)
function Get-KitStatsCss {
  '@media(min-width:700px){.gks.w1{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) max-content}.gks.w3{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(3,max-content)}.gks.w5{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(5,max-content)}}:is(.gks.w1,.gks.w3,.gks.w5) .gn{white-space:normal;overflow-wrap:anywhere;max-width:260px}' +
  '@media(max-width:699px){.gks.w1 .gk{grid-template-columns:minmax(0,1fr)}.gks.w3 .gk{grid-template-columns:repeat(3,minmax(0,1fr))}.gks.w5 .gk{grid-template-columns:repeat(5,minmax(0,1fr))}}' +
  '.gks .gn small{color:var(--mt);font-weight:500;font-size:11px;margin-left:6px}.rsh .gk.orphan>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.rsh .gk.orphan>.gs{outline:1px dashed color-mix(in srgb,var(--watch) 60%,var(--ln));outline-offset:1px}' +
  # disk writes: muted sage cells; the 7-day block slate over sage
  '.hm.ws:not(.sp) i{background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}' +
  '.hm.sbr i.sdc{background:var(--sb) left bottom/100% 3px no-repeat,color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}' +
  # Disk · 7 days: right columns at their width, the hour grid flexes; shade = machine GB, bottom stripe = kit share, hatch = no samples
  '@media(min-width:700px){.gks.wdk{grid-template-columns:minmax(0,max-content) minmax(264px,1fr) repeat(var(--rc),minmax(48px,max-content))}}.hm.dw i{background:linear-gradient(var(--slate),var(--slate)) left bottom/var(--k,0%) 3px no-repeat,color-mix(in srgb,var(--sage2) var(--a,0%),var(--sf2))}' +
  '.hm.dw i.ns,.lgk.nsx{background:repeating-linear-gradient(135deg,var(--sf2) 0 3px,color-mix(in srgb,var(--mt) 35%,var(--sf2)) 3px 5px)}.hm.dw i.fu{background:transparent;outline:1px dashed var(--ln);outline-offset:-1px}.lgk.kst{background:linear-gradient(var(--slate),var(--slate)) left bottom/100% 3px no-repeat,var(--sf2)}' +
  '.wdk .gc small{margin-left:3px;color:var(--mt);font-size:10px}.wdk .gc.fr.warn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.wdk .gc.fr.warn small{color:inherit}.wdk .gc.lo{font-weight:700}@media(max-width:699px){.gks.wdk .gk{grid-template-columns:repeat(var(--rc),minmax(0,1fr))}}' +
  # day heatmaps: a column per day (--n), taller cells for the wider numbers
  '.hm.dy,.hrs.dy{grid-template-columns:repeat(var(--n),minmax(0,1fr))}.dyh .hm.dy{height:20px}.dyh .hm.dy i{line-height:20px;font-size:10.5px}.hm.dy i[data-ft]{cursor:pointer}.hrs.dy b{text-align:center}.dyh .gk.gl0>*{border-top:1px solid var(--ln);padding-top:2px}.dyh .gk.gl0>.hm.dy{height:23px}' +   # 23 = 20 + the rule above
  '.cpg{margin-top:6px}:is(.cpg,.fhm) .gk.gl0>*{border-top:1px solid var(--ln);padding-top:2px}.gks .gc small{color:var(--mt);font-weight:500}.cpg .gk.hot>.gn,.cpg .gk.hot>.gc:nth-last-child(15){color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}.cpg .gk.warn>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}' +
  # heatmap kinds: split CPU (top, slate) over RAM (bottom, sage); flag counts coloured by level; the idle-rows fold
  # a cell's number: dark text on a dark shade (hi, --hmt); split cells: CPU number over RAM number
  '.hm i.hi,.hm i>.hi{color:var(--hmt,var(--fg))}.hm.sp{height:26px}.hm.sp i{display:grid;grid-template-rows:1fr 1fr;font-size:9.5px;line-height:13px;background:linear-gradient(color-mix(in srgb,var(--slate) var(--a),var(--sf2)) 0 50%,color-mix(in srgb,var(--sage2) var(--b),var(--sf2)) 50% 100%)}.hm.sp i>span{overflow:hidden}' +
  '.hm.fh{height:17px}.hm.fh i{line-height:17px}.hm.fh.l-act i{background:color-mix(in srgb,var(--act) var(--a),var(--sf2))}.hm.fh.l-watch i{background:color-mix(in srgb,var(--watch) var(--a),var(--sf2))}.hm.fh.l-fixed i{background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}.hm.fh.l-mr i{background:color-mix(in srgb,var(--sage) var(--a),var(--sf2))}' +
  # learned keys (K100): a change cell wraps its "old→new" (never cut); up slate, down plum, a reset or text change outlined plain
  '.dyh .hm.dy.pd{height:auto;min-height:20px}.dyh .hm.pd i{display:flex;align-items:center;justify-content:center;line-height:12px;padding:2px 1px;white-space:normal;overflow-wrap:break-word;font-size:10px}:is(.hm.pd i[data-d=up],.lgk.pu){background:color-mix(in srgb,var(--slate) 45%,var(--sf2))}:is(.hm.pd i[data-d=dn],.lgk.pw){background:color-mix(in srgb,var(--plum) 45%,var(--sf2))}.hm.pd i:is([data-d=rs],[data-d=ch]){background:var(--sf2);outline:1px dashed var(--mt);outline-offset:-1px}.hm.pd i[data-d=rs]{color:var(--mt)}.pdk .gc{white-space:nowrap}' +
  '.fhm .gk.gl0>.hm.fh{height:20px}.fhm .gk.fk>.gn{padding-left:12px;font-weight:500;color:var(--mt)}.fhm .gk.l-act:not(.fk)>.gn{color:color-mix(in srgb,var(--act) 60%,var(--fg))}.fhm .gk.l-watch:not(.fk)>.gn{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.fhm .gk.l-fixed:not(.fk)>.gn{color:var(--sage2)}' +
  '.gkx{grid-column:1/-1;justify-self:start;background:none;border:0;padding:2px 0;color:var(--mt);font:inherit;cursor:pointer}.gkx::before{content:"\25B8  "}.gkx[aria-expanded=true]::before{content:"\25BE  "}.gkx small{font-size:inherit}.gki{display:none}.gks.gio>.gki{display:contents}' +
  '.lgk{display:inline-block;width:8px;height:8px;border-radius:2px;margin:0 3px 0 6px;vertical-align:-1px}.lgk:first-child{margin-left:0}.lgk.c{background:var(--slate)}.lgk.r{background:var(--sage2)}' +
  '.rsh .gn small.bt{display:block;margin-left:0}.rgg.gio>.gki{display:contents}.rgg.cl>:is(.gkx,.gki){display:none}.rgx[data-m=b] .gkx:not(.mb),.rgx:not([data-m=b]) .gkx.mb{display:none}.och{display:inline-flex;flex-wrap:wrap;gap:3px;margin-left:6px;vertical-align:1px}.och .chip{font-size:10.5px;padding:0 6px;font-weight:500}' +
  # one resources view: metric switch (only the chosen strip and columns show), folding groups with a count and the worst state
  '.rgx:not([data-m=b]) [data-mv=b],.rgx:not([data-m=b]) .gk.mb,.rgx:not([data-m=b]) .rgg.ob,.rgx[data-m=b] [data-mv=c],.rgx[data-m=b] [data-mv=w],.rgx[data-m=b] [data-mv=q],.rgx[data-m=b] .rgg:not(.hb),.rgx[data-m=b] .rgg .gk:not(.rgh):not(.mb){display:none}.rgx[data-m=b] .rgg.hb.cl>.gk.mb{display:contents}' +
  'button.tl{display:block;border:0;font:inherit;color:inherit;text-align:left;cursor:pointer}.tl.ocb b{margin-left:0}button.tl[aria-pressed=true]{box-shadow:inset 0 0 0 1.5px var(--sage2)}.tl span i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px}.tls{display:flex;flex-wrap:wrap;gap:6px;margin:2px 0 6px}.tl{background:var(--sf2);border-radius:6px;padding:4px 10px;min-width:76px}.tl b{display:block;font-size:16px;font-weight:650;font-variant-numeric:tabular-nums}.tl b small{font-size:11px;color:var(--mt);font-weight:500;margin-left:2px}.tl span{font-size:11px;color:var(--mt)}.tl.act b{color:color-mix(in srgb,var(--act) 60%,var(--fg))}.tl.watch b{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}' +
  '.skb{margin:2px 0 6px}.skw{display:flex;height:14px;border-radius:4px;overflow:hidden;background:var(--sf2)}.skw i{display:block}.sk-u{background:var(--slate)}.sk-p{background:color-mix(in srgb,var(--watch) 55%,var(--sf2))}.sk-f{background:var(--sage2)}.sk-r{background:color-mix(in srgb,var(--mt) 35%,var(--sf2))}' +
  '.skl{display:flex;flex-wrap:wrap;gap:2px 14px;font-size:11px;color:var(--mt);margin-top:3px}.skl i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px}.skl b{color:var(--fg);font-weight:600}' +
  '.mtw{margin:4px 0 6px}.mtb{font-size:12px;border-collapse:collapse}.mtb th{color:var(--mt);font-weight:500;padding:2px 10px;text-align:right}.mtb td{padding:2px 10px;border-top:1px solid var(--ln);text-align:right;font-variant-numeric:tabular-nums}.mtb th:first-child,.mtb td:first-child{text-align:left;overflow-wrap:anywhere}' +
  '.rgx[data-m=c] [data-mv=w],.rgx[data-m=c] [data-mv=q],.rgx[data-m=w] [data-mv=c],.rgx[data-m=w] [data-mv=q],.rgx[data-m=q] [data-mv=c],.rgx[data-m=q] [data-mv=w]{display:none}.rgg{display:contents}.rgg.cl>.gk:not(.rgh){display:none}' +
  '.rgh>.rgb{grid-column:1/-1}.rgb{all:unset;box-sizing:border-box;cursor:pointer;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px;border-top:1px solid var(--ln);padding-top:4px}.rgb::before{content:"\25B8";color:var(--mt)}.rgg:not(.cl) .rgb::before{content:"\25BE"}.rgb .gn0{font-weight:650}.rgb .gcn{color:var(--mt)}.rgb:focus-visible{outline:2px solid var(--sage);outline-offset:2px}' +
  '.rgt{display:flex;flex-wrap:wrap;gap:4px;margin:2px 0 4px}.rgt button{all:unset;cursor:pointer;padding:1px 9px;border:1px solid var(--ln);border-radius:10px;font-size:11.5px;color:var(--mt)}.rgt button[aria-pressed=true]{background:var(--sf2);color:var(--fg);border-color:var(--sage2)}.rgt button:focus-visible{outline:2px solid var(--sage)}' +
  '.rsh .gc.hot{color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}.rsh .gc.warn{color:color-mix(in srgb,var(--watch) 55%,var(--fg));font-weight:650}' +
  '.lcp>.ya{z-index:1}' +
  # Settings (owner 2026-11-21): equal tiles in a dense grid (an open group's panel spans the row under its tile), a badge, a source bar
  '.tgc{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin:0 0 6px}.tgc input{flex:0 1 220px;min-width:140px;font:inherit;font-size:12px;padding:3px 8px;border:1px solid var(--ln);border-radius:6px;background:var(--sf2);color:var(--fg)}.tgk{all:unset;cursor:pointer;padding:2px 10px;border:1px solid var(--ln);border-radius:10px;font-size:11.5px;color:var(--mt)}.tgk:hover{color:var(--fg)}.tgk:focus-visible{outline:2px solid var(--sage)}.tgk[aria-pressed=true]{border-color:var(--sage2);background:color-mix(in srgb,var(--sage2) 22%,var(--sf2))}' +
  '.tgs{display:grid;grid-template-columns:repeat(auto-fill,minmax(136px,1fr));grid-auto-flow:row dense;gap:4px}.tgb{all:unset;box-sizing:border-box;display:flex;flex-direction:column;gap:2px;min-width:0;padding:4px 8px 6px;border:1px solid var(--ln);border-radius:6px;background:var(--sf2);cursor:pointer}.tgb:hover{border-color:var(--mt)}.tgb:focus-visible{outline:2px solid var(--sage);outline-offset:1px}.tgb[aria-expanded=true]{border-color:var(--sage2);background:color-mix(in srgb,var(--sage2) 18%,var(--sf2))}' +
  '.tgh{display:flex;align-items:baseline;gap:6px;min-width:0}.tgh::before{content:"\25B8";color:var(--mt);font-size:10px}.tgb[aria-expanded=true] .tgh::before{content:"\25BE";color:var(--fg)}.tgn{flex:1 1 auto;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600;font-size:12px}.tgh small{color:var(--mt);font-size:11px;font-variant-numeric:tabular-nums}' +
  '.tgm{min-height:16px;line-height:16px}.bdg{display:inline-block;padding:0 6px;border-radius:8px;font-size:10.5px;line-height:15px;font-weight:600;background:color-mix(in srgb,var(--sage2) 32%,var(--sf2));color:var(--fg)}' +
  '.tgx{display:flex;gap:1px;height:5px;border-radius:2px;overflow:hidden}.tgx i{display:block;flex:0 1 0;min-width:2px}.tgx .pl,.lgk.pl{background:var(--sage2)}.tgx .ps,.lgk.ps{background:var(--plum)}.tgx .pc,.lgk.pc{background:var(--slate)}.tgx .pd,.lgk.pd{background:color-mix(in srgb,var(--mt) 40%,transparent)}' +
  '.tgp{display:none;grid-column:1/-1;border:1px solid var(--sage2);border-radius:6px;background:var(--sf);padding:4px 8px 6px}.tgp.on,.tgs.all .tgp,.flq .tgs .tgp{display:block}.tgs.all .tgb,.flq .tgs .tgb{display:none}.tgs .tgp[hidden],.tgs .tgp.sx,.tgs.ch .tgb:not(.c7g),.tgs.ch .tgp:not(.c7g),.tgs.ch tbody tr:not(.c7),.tkt tr.sx{display:none}' +
  '.tph{display:flex;align-items:center;gap:8px;margin-bottom:2px}.tph b{font-size:12.5px}.tph small{color:var(--mt)}.tpx{all:unset;margin-left:auto;cursor:pointer;padding:0 8px;border-radius:4px;font-size:15px;line-height:20px;color:var(--mt)}.tpx:hover{color:var(--fg);background:var(--sf2)}.tpx:focus-visible{outline:2px solid var(--sage)}.tgs.all .tpx,.flq .tpx{display:none}' +
  '.tkt{width:100%;table-layout:fixed;font-size:11.5px}.tkt th{padding:0}.tks{all:unset;cursor:pointer;display:block;padding:2px 6px;font-weight:600}.tks:focus-visible{outline:2px solid var(--sage)}.tkt th[aria-sort=ascending] .tks::after{content:" \25B4"}.tkt th[aria-sort=descending] .tks::after{content:" \25BE"}' +
  '.tkt td{padding:2px 6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tkt td.tv{font-variant-numeric:tabular-nums;font-weight:600}.tkt td.tk.rep{color:transparent}.tkt tr.c7>td:first-child{box-shadow:inset 2px 0 0 var(--sage2)}.cmk{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--sage2);margin-right:5px;vertical-align:1px}.tkt td .lgk{margin:0 5px 0 0}' +
  '.tsv{margin-left:auto;border:1px solid var(--ln);cursor:pointer;font:inherit;font-size:11px;font-weight:600}summary:has(>.tsv)::after{margin-left:0}@media(pointer:fine){summary>.tsv{min-height:24px;padding:1px 10px}}.tat>summary{cursor:pointer;color:var(--mt);font-size:12px;margin-top:8px}.tat .mtb{min-width:720px}' +
  # a phone: nested folds keep their width for the maps (thin side padding), day labels wrap, the repo table packs its columns
  '@media(max-width:699px){details.sub details.sub>.bd,details.sub .st>.bd{padding-left:4px;padding-right:4px}.hrs.dy b{white-space:normal;overflow-wrap:anywhere;font-size:9.5px}.mtb{font-size:11px;width:100%}.mtb th{font-size:9.5px;text-transform:none;letter-spacing:0;overflow-wrap:anywhere}.mtb :is(th,td){padding:2px 3px}}' +
  'dialog.drw{position:fixed;inset:0 0 0 auto;margin:0;height:100dvh;max-height:none;width:min(1100px,94vw);max-width:none;padding:0;border:0;border-left:1px solid var(--ln);background:var(--bg);color:var(--fg)}dialog.drw[open]{display:flex;flex-direction:column}dialog.drw::backdrop{background:rgba(0,0,0,.35)}.dwh{display:flex;align-items:center;gap:8px;padding:6px 12px;border-bottom:1px solid var(--ln)}.dwh b{flex:1;font-size:13px;overflow-wrap:anywhere}.drw iframe{flex:1;border:0;width:100%;background:var(--bg)}' +
  '.nod{font-size:10.5px;color:var(--mt);padding:10px 0;text-align:center}' +
  '.cpt{margin-top:6px}.cpo{display:grid;grid-template-columns:minmax(0,1fr) max-content max-content;gap:2px 12px;font-size:12px;padding:2px 0;border-top:1px solid var(--ln)}.cpo .cn0{overflow-wrap:anywhere}.cpo small{color:var(--mt)}.cpo.hot .gc{color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}' +
  '.dbc .qs{display:flex;flex-direction:column-reverse;overflow:hidden;background:none}.qs>i{display:block;min-height:2px;border-radius:0}.qs>.q-p,.ql>.q-p{background:var(--sage)}.qs>.q-f,.ql>.q-f{background:var(--act)}.qs>.q-n,.ql>.q-n{background:var(--watch)}.qs>.q-o,.ql>.q-o{background:color-mix(in srgb,var(--mt) 35%,var(--sf2))}' +
  '.qbr figcaption{display:flex;flex-wrap:wrap;gap:0 8px;margin-top:2px}.ql{white-space:nowrap}.ql i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:3px;vertical-align:-1px}' +
  # bands (owner 2026-11-19): flags table, runs timeline, metric heatmaps; D8: every tile one size, a one-line label (ellipsis, its title holds it)
  '.flt{width:100%;table-layout:fixed}.flt col.c-lv{width:84px}.flt col.c-k{width:12%}.flt col.c-w{width:13%}.flt col.c-n{width:30%}.flt col.c-a{width:84px}.flt td{vertical-align:top;overflow-wrap:anywhere}.flt tr.ACT>td:first-child{box-shadow:inset 3px 0 var(--act)}.flt tr.WATCH>td:first-child{box-shadow:inset 3px 0 var(--watch)}.fxn{margin-left:4px;font-size:11px;color:var(--mt)}.chip.fxd{color:color-mix(in srgb,var(--sage2) 70%,var(--fg))}.fxb{all:unset;cursor:pointer;color:var(--mt);font-size:12px}.fxb::before{content:"\25B8  "}.fxb[aria-expanded=true]::before{content:"\25BE  "}.fxr>td{color:var(--mt);font-size:12px}#fl-hist{margin-top:8px}' +
  '@media(max-width:699px){.flt thead,.flt colgroup{display:none}.tw>table.flt tr{display:flex!important;flex-wrap:wrap;gap:2px 8px;padding:6px 0;border-top:1px solid var(--ln)}.tw>table.flt td{border:0;padding:0;flex:0 1 auto}.tw>table.flt td:nth-child(n+4),.tw>table.flt td[colspan]{flex-basis:100%}.tw>table.flt td::before{display:none}.mhw .gks.w0{grid-template-columns:minmax(0,1fr)}.gks.w0 .gk{grid-template-columns:minmax(0,1fr)}}' +
  '.rtl .gn{max-width:380px}.rtl .rr>.gn{display:flex;flex-wrap:wrap;gap:2px 6px;align-items:baseline}.rtg{all:unset;cursor:pointer;font-weight:600;overflow-wrap:anywhere}.rtg::before{content:"\25B8 ";color:var(--mt)}.rgg:not(.cl)>.rr .rtg::before{content:"\25BE "}.rtl .gk.ag>.gn{padding-left:16px}.rtl .gk.ag .chip{margin-left:6px}:is(.rdg,.rkg).cl>.rgg{display:none}.rkh .gn small{font-weight:500}.rtl .rkg>.rgg>.rr>.gn{padding-left:16px}.rtl .rkg .gk.ag>.gn{padding-left:32px}.hm.rn i{--a:0%;background:color-mix(in srgb,var(--sage2) var(--a),var(--sf2))}.rtl .rk{font-size:11px}' +
  '.gks.w0{grid-template-columns:minmax(0,max-content) minmax(160px,1fr)}.mhw .gks.w0{min-width:calc(var(--n) * 52px + 110px + var(--xw,0px))}.mhw .hm.dy,.mhw .hrs.dy{grid-template-columns:var(--gt,repeat(var(--n),minmax(48px,1fr)))}.hm.mh i[data-t=warn]{background:color-mix(in srgb,var(--watch) 60%,var(--sf2))}.hm.mh i[data-t=act]{background:color-mix(in srgb,var(--act) 60%,var(--sf2))}' +
  '.tls{align-items:stretch}.tl{height:46px;width:136px;display:flex;flex-direction:column;justify-content:space-between;overflow:hidden}.tl b{line-height:20px;white-space:nowrap}.tl span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:15px}' +
  '.fsm{margin-left:8px;font-size:12px;font-weight:400;color:var(--mt);overflow-wrap:anywhere}' +   # a folded block's one-line summary in its header
  # split cells (usage.ps1 split, owner 2026-11-20): a row of small muted tiles (tint = type, fill capped by --kcap so text keeps 4.5:1,
  # a 2px accent at the left; output strongest, cache read faintest, the total strongest of all); the cell's own width picks the form
  # (container query): wide p4 + total, medium p2 + total, narrow the total over a 4-part bar; never stacked bands; .kh = the tile names
  '.k-out,.k-wk,.k-to,.k-tw{--kc:var(--slate)}.k-to,.k-in{--kx:.85}.k-in,.k-mo{--kc:var(--k2)}.k-cw{--kc:var(--k3);--kx:.75}:is(.k-cr,.k-ca,.k-wa){--kc:var(--k4);--kx:.55}.k-tot{--kc:var(--sage)}.lgk[class*=k-]{background:var(--kc)}.kleg{white-space:normal}.hki{cursor:help;color:var(--mt);font-size:13px;line-height:1;margin-left:2px}.hki:focus-visible{outline:2px solid var(--sage);border-radius:50%}' +
  '@media(min-width:700px){.gks.w2{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(2,max-content)}.gks.w2 .gk{column-gap:12px}}@media(max-width:699px){.gks.w2 .gk{grid-template-columns:repeat(2,minmax(0,1fr))}}' +
  '.ks,.kst{container-type:inline-size}.ks{display:block;width:290px;max-width:100%}.ks.kd-time{width:200px}td>.ks{margin-left:auto}.kr4{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:2px}' +
  '.kq{--a:50%;display:flex;flex-direction:column;align-items:flex-end;justify-content:center;min-width:0;padding:1px 4px 1px 5px;border-radius:3px;background:color-mix(in srgb,var(--kc) calc(var(--a) * var(--kx,1) * var(--kcap)),var(--sf2));box-shadow:inset 2px 0 var(--kc);color:var(--fg);font-size:10.5px;font-weight:500;line-height:13px;white-space:nowrap}.kq small{font-size:9px;font-weight:400;line-height:11px}.kq.kt{--kx:1;font-weight:650}.ks .kq.kt{--a:75%}' +
  '.kr4>.kq.k2,.kb{display:none}.kb{height:4px;margin-top:2px;gap:1px;border-radius:2px;overflow:hidden}.kb i{display:block;flex:0 1 0;min-width:2px;background:var(--kc)}' +
  '@container (max-width:259.98px){:not(.kd-time)>.kr4>.kq.k4{display:none}:not(.kd-time)>.kr4>.kq.k2{display:flex}}@container (max-width:189.98px){.kd-time>.kr4>.kq.k4{display:none}.kd-time>.kr4>.kq.k2{display:flex}}' +
  '@container (max-width:189.98px){:not(.kd-time)>.kr4>.kq:not(.kt){display:none}:not(.kd-time)>.kb{display:flex}}@container (max-width:129.98px){.kd-time>.kr4>.kq:not(.kt){display:none}.kd-time>.kb{display:flex}}' +
  '.ks.k0,.kst.k0{container-type:normal}.ks.k0{display:inline-flex;width:auto;flex-direction:column;align-items:flex-end;text-align:right}:is(.ks,.kst).k0 b{display:block;font-weight:500;font-size:11px;line-height:13px;white-space:nowrap}.knr{display:block;font-size:9.5px;color:var(--mt);white-space:nowrap}' +
  ':is(.gks .gk,.gks .gk.gl0)>.hm.kr{height:auto;align-items:stretch}@media(max-width:1599px){.hm.rs i>.t{font-size:0}}.hm.kr i.kst{display:block;background:var(--sf2);padding:1px 0;line-height:normal;overflow:hidden;text-align:right}.hm.kr i.kst.k0{display:grid;align-content:center;text-align:center}.kst .knr{white-space:normal;line-height:11px}' +
  '.hm.rs i{--a:0%;--b:0%}.ru>.rh .ks{margin-left:6px}.kh{display:block;margin-top:2px}.hrs.dy .kh .kq,.kh .kq.kt{--a:0%;color:var(--mt);font-size:9px;font-weight:500;align-items:center;white-space:nowrap;overflow:hidden}'
}
# ---- bands: the page's flags table, runs timeline and metric heatmaps (owner 2026-11-19 redesign); helpers by dynamic scope
# flags (D4/D7): one table, ACT first (level, kind, who, problem, next, age); a repeat (same level, kind and problem) one row with
# its count; auto-fixes and notes one folded row under them
function Format-KitFlagTable($Flags, $Fixed, $Notes) {
  $rk = @{ ACT = 0; WATCH = 1 }; $dash = '<span class=m>—</span>'
  $grp = @(@($Flags | Where-Object { $_.level -in 'ACT', 'WATCH' } | ForEach-Object { $fc = Get-KitFlagCells $_ -Fill; [pscustomobject]@{ f = $_; c = $fc; k = "$($_.level)|$($fc.kind)|$(Get-KitFlagKey "$($fc.problem)")" } }) | Group-Object k | Sort-Object { $rk["$($_.Group[0].f.level)"] })
  $txt = { param($t) if ("$t".Trim()) { & $long "$t" } else { $dash } }
  $rows = @(foreach ($g in $grp) { $f0 = $g.Group[0]; $lv = "$($f0.f.level)"; $who = @($g.Group | ForEach-Object { "$($_.c.who)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
      "<tr class='f fr $lv'><td><span class='chip lv $lv'>$lv</span>$(if ($g.Count -gt 1) { "<span class=fxn title='seen $($g.Count) times this sweep'>x$($g.Count)</span>" })</td><td>$(& $txt $f0.c.kind)</td><td>$(& $txt ($who -join ', '))</td><td>$(& $txt $f0.c.problem)</td><td>$(& $txt $f0.c.action)</td><td>$(if ("$($f0.c.age)".Trim()) { & $minAgo $f0.c.age } else { $dash })</td></tr>" })
  $fx = @(@($Fixed | ForEach-Object { "<tr class='f fxr'><td><span class='chip fxd'>FIXED</span></td><td colspan=5>$(& $e ("$($_.what)" -replace '^auto-fixed:\s*'))</td></tr>" }) + @($Notes | ForEach-Object { "<tr class='f fxr'><td><span class='chip fnt'>NOTE</span></td><td colspan=5>$(& $e $_)</td></tr>" }))
  $sum = @($(if (@($Fixed).Count) { "$(@($Fixed).Count) auto-fixed this sweep" }), $(if (@($Notes).Count) { "$(@($Notes).Count) note(s)" }) | Where-Object { $_ }) -join ' · '
  "<div class=tw><table class=flt><colgroup><col class=c-lv><col class=c-k><col class=c-w><col><col class=c-n><col class=c-a></colgroup><thead><tr><th>Level</th><th>Kind</th><th>Who</th><th>Problem</th><th>Next step</th><th>Age</th></tr></thead>" +
  "<tbody>$(if ($rows.Count) { $rows -join '' } else { "<tr><td colspan=6 class=m>All clear: no ACT or WATCH flag.</td></tr>" })</tbody>$(if ($fx.Count) { "<tbody><tr><td colspan=6><button type=button class=fxb data-tg=fx-rows aria-expanded=false>$(& $e $sum)</button></td></tr></tbody><tbody id=fx-rows hidden>$($fx -join '')</tbody>" })</table></div>"
}
# runs (D9): one runs x hour heatmap; a row per run (workflow runs from usage; board agents outside one by their run), a cell = its
# minutes in that clock hour; agents (its steps by agent code, live board rows) under a run on expand; tokens, cost and time on the run row;
# live runs on top over the last 24 h, ended ones by day (today open, older days folded); $Pages: run ids with a steps page
function Format-KitRunsTimeline($Runs, $Agents, $Pages, $UsageAt = $null, $UsageAgents = @()) {
  $tOf = { param($x) if ($x) { try { ([datetimeoffset]"$x").LocalDateTime } catch { $null } } }
  $tk = { param($v) if ($null -eq $v -or [double]$v -le 0) { '—' } else { Format-KitCompactNum $v } }
  $usd = { param($v) if ($null -eq $v) { '—' } else { '$' + ([double]$v).ToString('0.00', [cultureinfo]::InvariantCulture) } }
  # @(sample count, minutes, that hour's [4 tokens, 4 costs] or $null) per clock hour from $H0 inside the spans (@(start, end)); $Hm = usage hrs
  $hrs = { param($spans, [datetime]$H0, $Hm = $null) @(for ($hi = 0; $hi -lt 24; $hi++) { $a0 = $H0.AddHours($hi); $a1 = $a0.AddHours(1); $m = 0.0
      foreach ($sp in @($spans | Where-Object { $_ })) { $s0 = if ($sp[0] -gt $a0) { $sp[0] } else { $a0 }; $s1 = if ($sp[1] -lt $a1) { $sp[1] } else { $a1 }; if ($s1 -gt $s0) { $m += ($s1 - $s0).TotalMinutes } }
      , @([int]($m -gt 0), [math]::Min(60.0, $m), $(if ($Hm) { Get-KitMember $Hm $a0.ToString('yyyy-MM-dd HH') })) }) }
  # split sums of steps (an agent row) or a run's own (usage.ps1 split); tm only when every step has one
  $spOf = { param($ss, $base = $null) $ss = @($ss | Where-Object { $_ }); $c4 = $null; $t6 = $null; $hsum = @{}
    foreach ($s in $ss) { if ($null -ne $s.cs) { $c4 = @(for ($i = 0; $i -lt 4; $i++) { [double]@($c4)[$i] + [double]@($s.cs)[$i] }) }; if ($null -ne $s.tm) { $t6 = @(for ($i = 0; $i -lt 6; $i++) { [double]@($t6)[$i] + [double]@($s.tm)[$i] }) }
      if ($s.hrs) { foreach ($p in @(if ($s.hrs -is [Collections.IDictionary]) { $s.hrs.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = "$($_.Key)"; Value = $_.Value } } } else { (Get-KitProps $s.hrs) | Where-Object MemberType -eq NoteProperty })) { $hsum[$p.Name] = @(for ($i = 0; $i -lt 8; $i++) { [double]@($hsum[$p.Name])[$i] + [double]@($p.Value)[$i] }) } } }
    $tmH = @($ss | Where-Object { $null -ne $_.tm }).Count; $all = $ss.Count -and $tmH -eq $ss.Count
    if ($base) { return [pscustomobject]@{ tok = $base.tok; cost = $base.cost; in = $base.in; out = $base.out; cr = $base.cr; cw = $base.cw; cs = $base.cs; tm = $(if ($all) { $base.tm }); tmN = $tmH; tmAll = $ss.Count; wall = $base.wall; hrs = $(if ($hsum.Count) { [pscustomobject]$hsum }) } }
    [pscustomobject]@{ tok = [double]($ss | Measure-Object tok -Sum).Sum; cost = $(if (@($ss | Where-Object { $null -ne $_.cost }).Count) { [double]($ss | Measure-Object cost -Sum).Sum }); in = [double]($ss | Measure-Object in -Sum).Sum; out = [double]($ss | Measure-Object out -Sum).Sum; cr = [double]($ss | Measure-Object cr -Sum).Sum; cw = [double]($ss | Measure-Object cw -Sum).Sum
      cs = $c4; tm = $(if ($all) { $t6 }); tmN = $tmH; tmAll = $ss.Count; min = [double]($ss | Measure-Object min -Sum).Sum; hrs = $(if ($hsum.Count) { [pscustomobject]$hsum }) } }
  $code = { param($n) (("$n" -split ' ')[0] -split '@')[0] }
  $byRun = @{}; foreach ($a in @($Agents | Where-Object { $_ })) { $rn = if ("$($a.run)" -in '', 'solo') { '' } else { "$($a.run)" }; if (-not $byRun.ContainsKey($rn)) { $byRun[$rn] = [Collections.Generic.List[object]]::new() }; $byRun[$rn].Add($a) }
  # its span: joined (started) -> ended / last beat; since = the current state's start (a finished agent's since is its end: 0 min, empty cells)
  $agSub = { param($a) $s1 = & $tOf $(if ($a.started) { $a.started } elseif ($a.since) { $a.since } else { $a.last }); $fin = & $isFin $a; if (-not $s1 -and -not $fin) { $s1 = $at }
    $e1 = if (-not $fin) { $at } else { @(@($a.ended, $a.last, $a.since) | ForEach-Object { & $tOf $_ } | Where-Object { $_ } | Sort-Object)[-1] }; if ($s1 -and $e1 -and $e1 -lt $s1) { $e1 = $s1 }
    [pscustomobject]@{ tf = "$($a.tx)"; n = & $code $a.name; sub = $(if ("$($a.name)" -match '\(([\w-]+)\)') { $Matches[1] }); st = $(if ($fin) { 'finished' } else { "$($a.state)" -replace '\s.*' }); live = -not $fin; since = $(if (-not $fin) { $a.since }); spans = @(if ($s1 -and $e1) { , @($s1, $e1) }); tip = "$($a.name): $($a.state)$(if ("$($a.doing)".Trim()) { " · $($a.doing)" })$(if ("$($a.next)".Trim()) { " · next: $($a.next)" })"; tok = $null; sp = $null } }
  $items = [Collections.Generic.List[object]]::new(); $seen = @{}
  # live = running by its own writes (usage Get-KitRunState) or a live board agent of the run's newest folder (a resumed run's older folder ended)
  $newId = @{}; foreach ($r in @($Runs | Where-Object { $_ })) { $k0 = "$($r.run)"; if (-not $newId[$k0] -or "$($r.started)" -gt $newId[$k0][1]) { $newId[$k0] = @("$($r.id)", "$($r.started)") } }
  $bLive = { param($rn) [bool]@($byRun[$rn] | Where-Object { $_ -and -not (& $isFin $_) -and "$($_.name)" -notmatch '\(workflow\)$' }).Count }
  # a run's hours: the union of its steps' spans (activity), never start-to-now
  $mergeSp = { param($sp) $o = [Collections.Generic.List[object]]::new(); foreach ($p in @($sp | Where-Object { $_ } | Sort-Object { $_[0] })) { if ($o.Count -and $p[0] -le $o[-1][1]) { if ($p[1] -gt $o[-1][1]) { $o[$o.Count - 1] = @($o[-1][0], $p[1]) } } else { $o.Add(@($p[0], $p[1])) } }; , @($o) }
  foreach ($r in @($Runs | Where-Object { $_ })) {
    # this sweep's ended workflow row beats an older usage pass's running
    $wfEnd = [bool]@($byRun["$($r.run)"] | Where-Object { $_ -and "$($_.name)" -match '\(workflow\)$' -and (& $isFin $_) }).Count; $live = ("$($r.status)" -eq 'running' -and -not $wfEnd) -or ((& $bLive "$($r.run)") -and $newId["$($r.run)"][0] -eq "$($r.id)"); $e0 = if ($live) { $at } else { & $tOf $r.at }; $s0 = & $tOf $r.started; if (-not $s0) { $s0 = $e0 }; if (-not $s0 -or -not $e0) { continue }; $seen["$($r.run)"] = 1; $seen["$($r.id)"] = 1
    $subs = [Collections.Generic.List[object]]::new()
    foreach ($g in @($r.steps | Where-Object { $_ -and $_.at } | Group-Object { if ("$($_.label)" -match ':') { & $code ("$($_.label)" -split ':', 2)[1] } else { "$($_.label)" } })) {
      $res = @($g.Group | ForEach-Object { "$($_.result)" } | Select-Object -Unique)
      $subs.Add([pscustomobject]@{ n = $g.Name; sub = (@($g.Group | ForEach-Object { "$($_.role)" } | Where-Object { $_ } | Select-Object -Unique) -join ', '); st = $(if ('running' -in $res) { 'running' } elseif ('fail' -in $res -or 'stuck' -in $res) { 'failed' } else { '' }); live = 'running' -in $res
          spans = @($g.Group | ForEach-Object { $t1 = & $tOf $_.at; if ($t1) { , @($t1.AddMinutes(-[double]$_.min), $t1) } }); tip = "$($g.Name): $(@($g.Group | ForEach-Object { "$($_.label) $($_.result) $([math]::Round([double]$_.min)) min" }) -join ' · ')"; tok = [double]($g.Group | Measure-Object tok -Sum).Sum; sp = (& $spOf $g.Group) }) }
    if ($live) { foreach ($a in @($byRun["$($r.run)"] | Where-Object { $_ -and -not (& $isFin $_) -and "$($_.name)" -notmatch '\(workflow\)$' })) { $as = & $agSub $a; $hit = @($subs | Where-Object n -eq $as.n)[0]; if ($hit) { $hit.st = $as.st; $hit.live = $true; $hit.tip = "$($hit.tip) · $($as.tip)" } else { $subs.Add($as) } } }
    $items.Add([pscustomobject]@{ id = "$($r.id)"; run = "$($r.run)"; label = $(if ("$($r.label)".Trim()) { "$($r.label)" } else { "$($r.run)" }); mandate = "$($r.mandate)"; kind = $(if ($r.kind) { "$($r.kind)" } elseif ("$($r.roles)" -match 'checky') { 'test' } elseif ("$($r.roles)" -match '^kitty') { 'kit' } else { 'build' })
        live = $live; state = "$($r.state)"; lastAt = $r.lastAt; act = (& $mergeSp @($subs | ForEach-Object { @($_.spans) })); s = $s0; e = $e0; tok = $r.tok; cost = $r.cost; wall = $r.wall; sp = (& $spOf $r.steps $r); oc = (@($r.steps | ForEach-Object { "$($_.result)" } | Where-Object { $_ } | Select-Object -Unique) -join ' '); subs = @($subs) }) }
  # board-only agents: tokens from their own transcript (usage agentSteps: Agent-tool spawns), matched by path, else by file name (agent-<agentId>.jsonl)
  $txKey = { param($p) "$p".ToLowerInvariant() -replace '\\', '/' }; $axPath = @{}; $axLeaf = @{}
  foreach ($x in @($UsageAgents | Where-Object { $_ -and $_.tf })) { $axPath[(& $txKey $x.tf)] = $x; $axLeaf[[IO.Path]::GetFileName((& $txKey $x.tf))] = $x }
  # proof only (owner 2026-11-21): a board agent belongs to a workflow run by the run it joined with or its transcript in workflows/<run id>;
  # a name or time overlap never attaches it (a standalone revy audit during a wave keeps its own row)
  $wfIds = @{}; foreach ($r in @($Runs | Where-Object { $_ })) { foreach ($i in @(@($r.ids) + $r.id | Where-Object { $_ })) { $wfIds["$i"] = 1 } }
  $inRun = { param($sb) "$($sb.tf)" -match '[\\/]workflows[\\/]([^\\/]+)[\\/]' -and $wfIds.ContainsKey($Matches[1]) }
  foreach ($rn in @($byRun.Keys | Where-Object { -not $seen.ContainsKey($_) })) { $all = @($byRun[$rn] | ForEach-Object { & $agSub $_ } | Where-Object { $_.spans.Count -and -not (& $inRun $_) }); if (-not $all.Count) { continue }
   # a named run: one row; no run name: a row per agent (its type + board name, its own tokens) in the agents kind
   foreach ($subs in @(if ($rn) { , $all } else { $all | ForEach-Object { , @($_) } })) {
    $own = @(foreach ($sb in $subs) { if (-not $sb.tf) { continue }; $kx = & $txKey $sb.tf; $x = if ($axPath[$kx]) { $axPath[$kx] } else { $axLeaf[[IO.Path]::GetFileName($kx)] }; if ($x) { $sb.sp = & $spOf @($x); $sb.tok = [double]$x.tok; $xt = & $tOf $x.at; if ($xt -and $null -ne $x.min -and $sb.spans.Count) { $x0 = $xt.AddMinutes(-[double]$x.min); $sp0 = $sb.spans[0]; $sb.spans = @(, @($(if ($x0 -lt $sp0[0]) { $x0 } else { $sp0[0] }), $(if (-not $sb.live -and $xt -gt $sp0[1]) { $xt } else { $sp0[1] }))) }; $x } })
    $lv = [bool]@($subs | Where-Object live).Count; $s0 = @($subs | ForEach-Object { $_.spans[0][0] } | Sort-Object)[0]; $e0 = if ($lv) { $at } else { @($subs | ForEach-Object { $_.spans[0][1] } | Sort-Object)[-1] }
    $rsp = if ($own.Count) { & $spOf $own }
    $sb0 = $subs[0]; $items.Add([pscustomobject]@{ id = $(if ($rn) { "board-$rn" } else { "board-solo-$($sb0.n)-$(if ($sb0.tf) { [IO.Path]::GetFileNameWithoutExtension($sb0.tf) } else { $s0.ToString('MMddHHmmss') })" }); run = $rn; label = $(if ($rn) { $rn } else { "$(if ($sb0.sub) { "$($sb0.sub) · " })$($sb0.n)" }); grp = $(if (-not $rn) { 'agents' })
        kind = $(if (@($subs.sub | Select-Object -Unique).Count -eq 1) { "$(@($subs.sub)[0])" } else { 'agents' }); live = $lv; s = $s0; e = $e0; tok = $rsp.tok; cost = $rsp.cost; wall = [math]::Round(($e0 - $s0).TotalMinutes); sp = $rsp; oc = ''; subs = $subs }) } }
  # tokens · cost and time (owner 2026-11-20): one split cell each (usage.ps1 split); no transcript: its elapsed time, no tokens
  $vcol = { param($o, [string]$tip, $wall, $s1 = $null) if (-not $o) { $cnt = $UsageAt -and $s1 -and ([datetime]$UsageAt) -lt $s1; return "<span class='gc z' title='$(if ($cnt) { 'tokens are counted when the usage pass reaches this run' } else { 'no usage record: the agent started outside a workflow and no transcript of it was found (another tool, or not read yet)' })'>$(if ($cnt) { "Counting… (usage as of $(([datetime]$UsageAt).ToString('HH:mm')))" } else { 'No usage record' })</span><span class=gc>$(if ($null -ne $wall) { "$([int]$wall) min" } else { '—' })</span>" }
    "$(Format-KitSplitCell $o 'tc' $tip)$(Format-KitSplitCell $o 'time' (Get-KitSplitTip ($o | Select-Object tm, tmN, tmAll, min, wall)))" }   # the time cell: its own lines only (page weight)
  # an hour cell: minutes active (sage, lower) under that hour's output tokens (slate, upper; the row's peak), the hour's split in the tooltip
  $runRow = { param($it, [datetime]$H0, [int]$NowAt, $kids = $null) $cl = { param($nm, $hv0, $hasT) $pk = [math]::Max(1.0, [double](@($hv0 | ForEach-Object { [double]@($_[2])[1] }) + 0 | Measure-Object -Maximum).Maximum)
      if (-not $hasT) { return (Format-KitHeatCells $hv0 $H0 "$nm, minutes active per hour" { param($hv) "$nm · $([int]$hv[1]) min active" } $null 'rn' $NowAt) -replace "<i style='--a:0%' title='[^']*'></i>", '<i></i>' }   # an idle hour: a bare cell (the page stays light)
      (Format-KitHeatCells $hv0 $H0 "$nm, output tokens over minutes active per hour" { param($hv) $t8 = @($hv[2]); "$nm · $([int]$hv[1]) min active$(if ($null -ne $hv[2]) { ' · ' + ((Get-KitSplitTip ([pscustomobject]@{ in = $t8[0]; out = $t8[1]; cr = $t8[2]; cw = $t8[3]; cs = @($t8[4..7]); tok = 1 })) -replace "`n", ' · ') })" } { param($hv) $o1 = [double]@($hv[2])[1]
          @($(if ($o1 -gt 0) { Get-KitHeatShade ($o1 / $pk) } else { 0 }), $(if ($o1 -gt 0) { Format-KitCompactNum $o1 } else { '' }), (Get-KitHeatShade ([double]$hv[1] / 60)), (Format-KitHeatNum $hv[1])) } 'sp rs' $NowAt) -replace "<i style='--a:0%;--b:0%' title='[^']*'><span class='t'></span><span class='u'></span></i>", '<i></i>' }
    $rsp = @($it.act | Where-Object { $_ }); if (-not $rsp.Count) { $rsp = @(, @($it.s, $it.e)) }   # a subexpression would unroll one pair into two dates
    # a kind group (owner 2026-11-21): its header row = the group's sums, its runs ($kids) under it
    if ($null -ne $kids) { $hvG = & $hrs $rsp $H0 $it.sp.hrs; $mSum = @(0.0) * 24   # minutes: each run's minutes in the hour, added up
      foreach ($ka in @($it.kAct)) { $hk = & $hrs $ka $H0; for ($hi = 0; $hi -lt 24; $hi++) { $mSum[$hi] += [double]$hk[$hi][1] } }
      for ($hi = 0; $hi -lt 24; $hi++) { $hvG[$hi][0] = [int]($mSum[$hi] -gt 0); $hvG[$hi][1] = $mSum[$hi] }
      return "<div class='rgg rkg$(if (-not $it.open) { ' cl' })' data-g='rk-$(& $e $it.id)' data-oc='$(& $e $it.oc)' data-fk='$(& $e $it.fk)'><div class='gk rgh rr rkh f'><span class=gn title='$(& $e $it.tip)'><button type=button class=rtg aria-expanded=$(if ($it.open) { 'true' } else { 'false' })>$(& $e $it.label)</button><small>$($it.n) ended</small></span>" +
        "$(& $cl $it.label $hvG ([bool]$it.sp.hrs))$(if ($it.sp) { & $vcol $it.sp (Get-KitSplitTip $it.sp $it.label) $it.wall } else { "<span class='gc z' title='no usage record for these runs'>—</span><span class=gc>$([int]$it.wall) min</span>" })</div>$kids</div>" }
    $pg = "$($it.id)" -in @($Pages); $subH = @($it.subs | Sort-Object { $_.spans[0][0] } | ForEach-Object { $sb = $_; $sbH = & $hrs $sb.spans $H0 $sb.sp.hrs
        "<div class='gk ag f'><span class=gn title='$(& $e $sb.tip)'>$(& $e $sb.n)$(if ($sb.sub) { "<small>$(& $e $sb.sub)</small>" })$(if ($sb.since) { "<small>$(& $when $sb.since)</small>" })$(if ($sb.st) { "<span class='chip $(& $stCls $(if ($sb.st -match 'run|act') { 'ACTIVE' } elseif ($sb.st -match 'fail|stuck') { 'STUCK' } else { $sb.st }))'>$(& $e $sb.st)</span>" })</span>$(& $cl $sb.n $sbH ([bool]$sb.sp.hrs))$(& $vcol $sb.sp (Get-KitSplitTip $sb.sp $sb.n) $null)</div>" })
    "<div class='rgg cl' data-g='rr-$(& $e $it.id)' data-oc='$(& $e $it.oc)' data-fk='d$($it.s.ToString('yyyy-MM-dd'))'><div class='gk rgh rr f'><span class=gn title='$(& $e "$($it.label) · $($it.run) · $($it.id)$(if ($it.mandate) { "`n$($it.mandate)" })")'><button type=button class=rtg aria-expanded=false>$(& $e $it.label)</button><span class='chip k-$(& $e $it.kind)'>$(& $e $it.kind)</span>$(if ($it.live) { "<span class='chip s-act'>running</span>" } elseif ($it.state -in 'paused', 'stale') { "<span class='chip s-oth' title='$(& $e "last write $(try { ([datetime]$it.lastAt).ToString('MM-dd HH:mm') } catch { '?' })")'>$(if ($it.state -eq 'paused') { 'paused' } else { 'stale · no end record' })</span>" })$(if ($pg) { "<a class=rk href='supervise-runs/$([Uri]::EscapeDataString($it.id)).html' data-dw='$(& $e "Run $($it.label)")'>steps</a>" })</span>" +
    "$(& $cl $it.label (& $hrs $rsp $H0 $it.sp.hrs) ([bool]$it.sp.hrs))$(& $vcol $it.sp (Get-KitSplitTip $it.sp $it.label) $it.wall $it.s)</div>$($subH -join '')</div>" }
  $head = { param([datetime]$H0, [switch]$Clock) "<div class='gk gh'><span class=gn>run · agent · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $H0 -Clock:$Clock)</span><span class=gc><small>tokens · cost</small></span><span class=gc><small>time</small></span></div>" }
  # an ended run's row: rendered once per hour (76 rows cost 3.4 s a sweep), kept in cache/runs-rows.json while shown
  $rcf = Join-Path (Get-KitPath cache -Create) 'runs-rows.json'; $rcOld = if ([IO.File]::Exists($rcf)) { try { [IO.File]::ReadAllText($rcf) | ConvertFrom-Json -AsHashtable } catch { $null } }; if (-not $rcOld) { $rcOld = @{} }
  $rcNew = @{}; $rcVer = "$runRow|$vcol|$spOf|$tOf|$when|$hrs|$stCls|" + (@('Format-KitHeatCells', 'Format-KitHourHead', 'Format-KitSplitCell', 'Get-KitSplitTotal', 'Get-KitSplitTip', 'Get-KitSplitParts', 'Format-KitSplitNum', 'Get-KitHeatShade', 'Format-KitCompactNum', 'Format-KitHeatNum') | ForEach-Object { (Get-Command $_).Definition }) -join '|'
  $rowOf = { param($it, [datetime]$H0, [int]$NowAt) $rk = Get-KitHash "$rcVer|$($H0.ToString('o'))|$NowAt|$("$($it.id)" -in @($Pages))|$(if (-not $it.sp) { $UsageAt })|$($it | ConvertTo-Json -Depth 6 -Compress)"
    $rcNew[$rk] = if ($rcOld.ContainsKey($rk)) { $rcOld[$rk] } else { & $runRow $it $H0 $NowAt }; $rcNew[$rk] }
  $liveR = @($items | Where-Object live | Sort-Object s -Descending); $hL = $at.Date.AddHours($at.Hour - 23)
  # kind groups (owner 2026-11-21): a day's ended runs by kind, each a folding row with the group's sums, the newest group open
  $kindKey = { param($k) switch -Regex ("$k") { '^(kit|kitty)$' { 'kit' } '^(test|checky)$' { 'test' } '^(deploy|opsy)$' { 'deploy' } '^(build|devy|briefy)$' { 'build' } default { 'agents' } } }
  $kOrd = @('build', 'test', 'kit', 'deploy', 'agents')
  $dayG = @(@($items | Where-Object { -not $_.live }) | Group-Object { $_.e.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending | ForEach-Object { $d0 = [datetime]$_.Name; $td = $d0 -eq $at.Date; $rs = @($_.Group | Sort-Object e -Descending)
      $hD = if ($td) { $hL } else { $d0 }; $nD = if ($td) { 23 } else { -1 }   # today: the running block's axis (last 24 h, now at the right), so the columns line up
      $kg = @($rs | Group-Object { if ($_.grp) { $_.grp } else { & $kindKey $_.kind } } | Sort-Object { [array]::IndexOf($kOrd, $_.Name) }); $newK = @($kg | Sort-Object { @($_.Group | Sort-Object e)[-1].e } -Descending)[0].Name
      $kH = @($kg | ForEach-Object { $ks = @($_.Group); $kp = @($ks | ForEach-Object { $_.sp } | Where-Object { $_ }); $kw = [double]($ks | Measure-Object wall -Sum).Sum
          $gsp = if ($kp.Count) { & $spOf $kp }; if ($gsp) { $gsp | Add-Member -NotePropertyName wall -NotePropertyValue $kw -Force }
          $gi = [pscustomobject]@{ id = "$($_.Name)-$($d0.ToString('yyyy-MM-dd'))"; label = $_.Name; n = $ks.Count; open = $_.Name -eq $newK; sp = $gsp; wall = $kw
            tip = "$($_.Name): $($ks.Count) ended · a cell = their minutes active in that hour (added up) under their output tokens · tokens, cost and time: their sums"
            kAct = @($ks | ForEach-Object { $a1 = @($_.act | Where-Object { $_ }); if ($a1.Count) { , $a1 } else { , @(, @($_.s, $_.e)) } })
            act = (& $mergeSp @($ks | ForEach-Object { $a1 = @($_.act | Where-Object { $_ }); if ($a1.Count) { $a1 } else { , @($_.s, $_.e) } }))
            oc = (@($ks | ForEach-Object { $_.oc -split ' ' } | Where-Object { $_ } | Select-Object -Unique) -join ' '); fk = (@($ks | ForEach-Object { "d$($_.s.ToString('yyyy-MM-dd'))" } | Select-Object -Unique) -join ' ') }
          & $runRow $gi $hD $nD (@($ks | ForEach-Object { & $rowOf $_ $hD $nD }) -join '') })
      $sg = & $spOf @($rs | ForEach-Object { $_.sp } | Where-Object { $_ })   # the day's ended runs: tokens by type and cost (all their days; the tooltip: every type)
      "<div class='rgg rdg$(if (-not $td) { ' cl' })' data-g='rd-$($_.Name)' data-oc='$(& $e (@($rs | ForEach-Object { $_.oc -split ' ' } | Where-Object { $_ } | Select-Object -Unique) -join ' '))' data-fk='$(@($rs | ForEach-Object { "d$($_.s.ToString('yyyy-MM-dd'))" } | Select-Object -Unique) -join ' ')'><div class='gk rgh'><button type=button class=rgb aria-expanded=$(if ($td) { 'true' } else { 'false' })><span class=gn0>$(if ($td) { 'ended today' } else { $d0.ToString('ddd dd MMM', [cultureinfo]::InvariantCulture) })</span><span class=gcn title='$(& $e (Get-KitSplitTip $sg))'>$($rs.Count) ended$(if ($td -and $liveR.Count) { " (+ $($liveR.Count) running)" })$(if ($sg.tok -gt 0) { " · $(& $tk $sg.tok) tok · $(& $usd $sg.cost)" })</span></button></div>$(& $head $hD -Clock:(-not $td))$($kH -join '')</div>" })
  if (@($rcNew.Keys | Where-Object { -not $rcOld.ContainsKey($_) }).Count -or $rcNew.Count -ne $rcOld.Count) { try { Write-KitAtomic $rcf ($rcNew | ConvertTo-Json -Compress) } catch { } }
  if (-not $items.Count) { return '<p class=empty>No run in 7 days.</p>' }
  $uOld = if ($UsageAt) { try { $ua = [datetime]$UsageAt; if (($at - $ua).TotalMinutes -gt 2 * [double](Get-KitParam 'supervise.heartbeatMinutes')) { "<p class=m>Tokens and steps: usage as of $($ua.ToString('MM-dd HH:mm')) (bossy.ps1 budget -Usage refreshes it); running state from this sweep.</p>" } } catch { } }
  "$uOld<div class='gks w2 rtl' data-mk=runs-hour>$(if ($liveR.Count) { "$(& $head $hL)$(@($liveR | ForEach-Object { & $runRow $_ $hL 23 }) -join '')" })$($dayG -join '')</div>$(Format-KitLegend "cell: output / minutes · $(Format-KitSplitLegend)" "a cell = minutes the run (or agent) was active in that clock hour (sage, lower part) under its output tokens in that hour (slate, upper part, shaded by the row's peak; hover: the hour's tokens and cost by type) · tokens · cost and time: a tile per type and the total (time: elapsed, wall clock); a narrower cell shows work / cache, then the total over a bar · tap a run for its agents · running and ended today: the last 24 h (now at the right), older days: their clock day · ended runs by kind: tap a kind for its runs")"
}
# a metric heatmap (D2, D3): rows x named metric columns, each column shaded by its own peak; a row @{ n; title; v = values; tx = texts;
# tips; tone = a class per cell ('' | warn | act) }; idle rows (no value) fold
function Format-KitMetricHeat($Rows, [string[]]$Cols, [string]$What, [string]$Mk) {
  $nc = $Cols.Count; $rs = @($Rows | Where-Object { $_ })
  # a split column gets the width of its tile row (wide form): tokens · cost 5 tiles, time 4; the rest share what is left
  $ck = @(for ($ci = 0; $ci -lt $nc; $ci++) { "$(@($rs | ForEach-Object { "$(@($_.sk)[$ci])" } | Where-Object { $_ })[0])" })
  $cn = if (@($ck | Where-Object { $_ }).Count) { "style='--n:$nc;--gt:$(@($ck | ForEach-Object { switch ($_) { '' { 'minmax(48px,1fr)' } 'time' { 'minmax(190px,2.2fr)' } default { 'minmax(260px,3fr)' } } }) -join ' ');--xw:$(@($ck | ForEach-Object { switch ($_) { '' { 0 } 'time' { 140 } default { 210 } } }) | Measure-Object -Sum | ForEach-Object Sum)px'" } else { "style='--n:$nc'" }
  $mx = @(for ($ci = 0; $ci -lt $nc; $ci++) { [math]::Max(1e-9, [double](@($rs | ForEach-Object { [double]@($_.v)[$ci] }) + 0 | Measure-Object -Maximum).Maximum) })
  # sk + so (a kind and an object per column): a split column (usage.ps1 split), each type shaded by its column peak
  $pkc = @(for ($ci = 0; $ci -lt $nc; $ci++) { $k0 = @($rs | ForEach-Object { "$(@($_.sk)[$ci])" } | Where-Object { $_ })[0]; if ($k0) { Get-KitSplitPeaks @($rs | ForEach-Object { @($_.so)[$ci] }) $k0 } else { $null } })
  $out = @(foreach ($r in $rs) { $cells = @(for ($ci = 0; $ci -lt $nc; $ci++) { $v = @($r.v)[$ci]; $tn = "$(@($r.tone)[$ci])"
        if ("$(@($r.sk)[$ci])" -and @($r.so)[$ci]) { Format-KitSplitCell @($r.so)[$ci] "$(@($r.sk)[$ci])" "$($r.n) · $($Cols[$ci])`n$(if (@($r.tips)[$ci]) { @($r.tips)[$ci] } else { Get-KitSplitTip @($r.so)[$ci] })" $pkc[$ci] -Heat; continue }
        $c = Format-KitHeatCell $(if ($null -eq $v) { 0 } else { Get-KitHeatShade ([double]$v / $mx[$ci]) }) "$(@($r.tx)[$ci])" "$($r.n) · $($Cols[$ci]): $(if (@($r.tips)[$ci]) { @($r.tips)[$ci] } else { @($r.tx)[$ci] })" $false
        if ($tn) { $c -replace '^<i', "<i data-t=$tn" } else { $c } })
      [pscustomobject]@{ busy = [bool]@($r.v | Where-Object { [double]$_ -gt 0 }).Count; html = "<div class=gk><span class=gn$(if ($r.title) { " title='$(& $e $r.title)'" })$(if ($r.id) { ' translate=no' })>$(& $e $r.n)</span><span class='gs hm dy mh$(if (@($r.sk | Where-Object { $_ }).Count) { ' kr' })' $cn role=img aria-label='$(& $e "$($r.n): $($Cols -join ', ')")'>$($cells -join '')</span></div>" } })
  "<div class='tw mhw'><div class='gks w0 dyh' $cn data-mk=$($Mk -replace '[^\w.:-]', '-')><div class='gk gh'><span class=gn>$(& $e $What)</span><span class='gs0 hrs dy' $cn aria-hidden=true>$(@(for ($ci = 0; $ci -lt $nc; $ci++) { "<b>$(& $e (Format-KitLabel $Cols[$ci]))$(if ($ck[$ci]) { Format-KitSplitHead $ck[$ci] })</b>" }) -join '')</span></div>$(Format-KitHeatRows $out 'rows' '7 days')</div></div>"
}
# repos now (D3): repo x branches, worktrees, kept, dirty, diverged; dirty amber, diverged red, the branches in the tooltip
function Format-KitRepoGrid($Repos, $Sync) {
  $syOf = @{}; foreach ($s in @($Sync | Where-Object { $_.repo })) { $syOf["$($s.repo)"] = $s }
  $rr = @($Repos.repos | Where-Object { $_.repo -and [int]$_.branches + [int]$_.worktrees } | Sort-Object { -[int]$_.branches }, { -[int]$_.worktrees }); if (-not $rr.Count) { return '' }
  $rows = @($rr | ForEach-Object { $s = $syOf["$($_.repo)"]; $dl = @($s.dirty | Where-Object { $_ }); $vl = @($s.diverged | Where-Object { $_ })
      @{ n = "$($_.repo)"; id = $true; v = @([int]$_.branches, [int]$_.worktrees, [int]$_.kept, $dl.Count, $vl.Count); tx = @("$([int]$_.branches)", "$([int]$_.worktrees)", "$([int]$_.kept)", "$($dl.Count)", "$($vl.Count)")
        tips = @('', '', 'unpushed, open or dirty: cleanup keeps it', ($dl -join '; '), ($vl -join '; ')); tone = @('', '', '', $(if ($dl.Count) { 'warn' }), $(if ($vl.Count) { 'act' })) } })
  $sm = @(0..4 | ForEach-Object { $ci = $_; [int](@($rows | ForEach-Object { @($_.v)[$ci] }) | Measure-Object -Sum).Sum })   # folded (owner 2026-11-19): the totals in its header
  & $fold 'repos-now' 'Repos now' $rr.Count "$(Format-KitMetricHeat $rows @('branches', 'worktrees', 'kept', 'dirty', 'diverged') 'repo' 'repo-now')$(Format-KitLegend 'amber dirty · red diverged' 'from the last repo sync · tap a cell for the branches')" -tag h4 -cls 'sub st' -extra "<span class=fsm>$($sm[0]) branches · $($sm[1]) worktrees$(if ($sm[3]) { " · $($sm[3]) dirty" })$(if ($sm[4]) { " · $($sm[4]) diverged" })$(if ($ra = try { [datetime]$Repos.at } catch { $null }) { " · as of $($ra.ToString($(if ($ra.Date -eq $at.Date) { 'HH:mm' } else { 'MM-dd HH:mm' })))" })</span>"
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
  if ($ended.Count) { ''; "ended (last $(Get-KitParam 'supervise.finishedMinutes') min):"; Format-KitMdTable @('Owner', 'Ended min ago', 'Command', 'Last line') @($ended | ForEach-Object { , @((& $c $_.owner 30), "$($_.endedMin)$(if ($_.killed) { ' (killed)' })", (& $c $_.short 60), (& $c $_.last 80)) }) }
  foreach ($fl in @($sw.flags)) { "$($fl.level) · $($fl.what) -> $($fl.action)" }
}

# ---- reset: bossy.ps1 stats [-Reset] (owner 2026-11-20): the files only this page's charts read; -Reset moves them to
# <state>/forgotten/stats-reset-<yyyyMMdd>/ (relative paths kept), the next sweep starts empty charts. Functional state stays: params,
# params-changes (the settings audit log), outcomes, storage (disk verdicts), pool-usage, runtimes, localenv-history, leases, audit logs, run records, supervise-state.
function Get-KitStatsFiles {
  $rt = Get-KitRuntime; $sd = Split-Path (Get-KitPath disk-writes); $cache = Get-KitPath cache
  foreach ($p in @((Get-KitPath disk-writes), (Get-KitPath mem-samples), [IO.Path]::ChangeExtension((Get-KitPath supervise-report), '.json'), (Join-Path $cache 'supervise-writes.json'), (Join-Path $cache 'runs-rows.json'))) {
    $inState = $p.StartsWith($sd, [StringComparison]::OrdinalIgnoreCase)
    [pscustomobject]@{ path = $p; rel = Join-Path $(if ($inState) { $script:KitPathMap.stateDir } else { $script:KitPathMap.runtimeDir }) ([IO.Path]::GetRelativePath($(if ($inState) { $sd } else { $rt }), $p)) } }
}
function Invoke-Stats {
  param([switch]$Reset)
  $dst = Join-Path (Get-KitPath forgotten) "stats-reset-$((Get-Date).ToString('yyyyMMdd'))"
  if (Test-Path -LiteralPath $dst) { $dst += "-$((Get-Date).ToString('HHmmss'))" }   # a second reset the same day never overwrites the first
  $moved = 0
  foreach ($f in @(Get-KitStatsFiles)) {
    if (-not [IO.File]::Exists($f.path)) { "absent  $($f.rel)"; continue }
    $kb = [math]::Round([IO.FileInfo]::new($f.path).Length / 1KB, 1)
    if (-not $Reset) { "stats  $($f.rel) ($kb KB)"; continue }
    $to = Join-Path $dst $f.rel; $null = New-Item -ItemType Directory -Force (Split-Path $to)
    try { [IO.File]::Move($f.path, $to); $moved++; "moved  $($f.rel) ($kb KB)" } catch { "busy  $($f.rel): $($_.Exception.Message)" }
  }
  if ($moved) { "-> $dst"; Write-KitLog calls stats-reset @{ to = $dst; files = $moved } }
}
# the newest reset's time (owner 2026-11-20; its folder's creation, not its day's midnight): charts still built from kept logs (runs,
# gate, waits, QA, Trends) read nothing before it; the Tuning heatmap and Disk free do; no reset = MinValue
function Get-KitStatsCutoff {
  $rd = @(Get-ChildItem -LiteralPath (Get-KitPath forgotten) -Directory -Filter 'stats-reset-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^stats-reset-\d{8}' } | ForEach-Object { $_.CreationTime } | Sort-Object)
  if ($rd.Count) { $rd[-1] } else { [datetime]::MinValue }
}
# a budget -Usage result without what came before $StatsFrom: ended runs started before it (the day they are listed under), its days' values, its MRs; step outcomes recounted
# from the kept runs (Spend per role stays: the result has no per-day split of it)
function Select-KitUsageSince($U, [datetime]$StatsFrom) {
  if (-not $U -or $StatsFrom -eq [datetime]::MinValue) { return $U }
  $cutDay = $StatsFrom.ToString('yyyy-MM-dd'); $uo = $U.PSObject.Copy()
  $uo | Add-Member -Force NoteProperty runs @($U.runs | Where-Object { $_ -and ("$($_.status)" -eq 'running' -or $(try { ([datetimeoffset]"$(if ($_.started) { $_.started } else { $_.at })").LocalDateTime -ge $StatsFrom } catch { $false })) })
  $uo | Add-Member -Force NoteProperty days @($U.days | Where-Object { $_ } | ForEach-Object { if ("$($_.day)" -ge $cutDay) { $_ } else { [pscustomobject]@{ day = "$($_.day)"; tok = $null; cost = $null; runs = $null; merged = $null } } })
  if ($null -ne $U.mrList) { $uo.mrList = @($U.mrList | Where-Object { $_ -and "$($_.day)" -ge $cutDay }) }
  if ("$($U.merged.source)" -eq 'host') { $uo.merged = [pscustomobject]@{ source = 'host'; user = $U.merged.user; n = @($uo.mrList).Count } }
  $wfSteps = @($uo.runs | ForEach-Object { @($_.steps) } | Where-Object { $_ }); $endSteps = @($wfSteps | Where-Object result -in 'pass', 'empty', 'fail', 'stopped')
  if ($null -ne $U.rates) { $uo.rates = [pscustomobject]@{ n = $endSteps.Count; empty = @($endSteps | Where-Object result -eq 'empty').Count; fail = @($endSteps | Where-Object result -eq 'fail').Count; stopped = @($endSteps | Where-Object result -eq 'stopped').Count; stuck = @($wfSteps | Where-Object result -eq 'stuck').Count; running = @($wfSteps | Where-Object result -eq 'running').Count } }
  $uo
}
