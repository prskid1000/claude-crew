<#
supervise_stats.ps1 (core): the supervise page's history graphs from the logs the kit already writes, dot-sourced by bossy.ps1
(skills/bossy/adapters/): the build gate per kind (builds log), lease waits per resource (leases log, builds log, local-env
lease-wait events, live queues), test-run results per day (qa-runs results.json), CPU per lane process and the top other
processes (one process snapshot per sweep); their cards render inside Format-KitSuperviseHtml.
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L11 gate · L50 waits · L76 qa · L92 cpu · L123 cards
#>
#Requires -Version 7
# ---- gate: the build gate per kind, 24 h
# the gate's card row of a build: kind (crafty.ps1 GateKinds) to a plain group; a local env's build = env deploy
function Get-KitGateGroup([string]$Kind, [string]$Who) {
  if ($Who -match 'localenv-') { return 'env deploy' }
  switch -regex ($Kind) { '^maven-test$' { 'maven test' } '^maven$' { 'maven build' } '^(web-build|rn-bundle)$' { 'web build' } '^(typecheck|tsc-lint)$' { 'typecheck / lint' }
    '^(js-test|ng-test)$' { 'js tests' } '^python$' { 'python' } '^(e2e|cypress)$' { 'cypress / e2e' } '^docker$' { 'docker' } '^(android-build|android-test|gradle)$' { 'android' } '^emulator$' { 'emulator' } default { 'other' } }
}
# minutes of [$S, $E] spread over the 24 clock hours from $H0 (index 0..23) -> & $Add <hour> <minutes>
function Split-KitHours([datetime]$H0, [datetime]$S, [datetime]$E, [scriptblock]$Add) {
  for ($hi = [math]::Max(0, [int][math]::Floor(($S - $H0).TotalHours)); $hi -le [math]::Min(23, [int][math]::Floor(($E - $H0).TotalHours)); $hi++) {
    $hs = $H0.AddHours($hi); $ov = ([datetime]::new([math]::Min($E.Ticks, $hs.AddHours(1).Ticks)) - [datetime]::new([math]::Max($S.Ticks, $hs.Ticks))).TotalMinutes; if ($ov -gt 0) { & $Add $hi $ov } }
}
# the gate from its builds log (24 h), not a sweep sample (one missed a build between sweeps):
# per group running / queued now, done today, avg / peak wait, RAM promised, an hourly heatmap (24 clock hours, the last = the current one:
# @(builds ended, busy min, max wait min) each, h0 = the first hour); phone lanes and emulators
function Get-KitGateStats([datetime]$Now = (Get-Date), $Resources = @()) {
  $h0 = $Now.Date.AddHours($Now.Hour - 23); $from = $h0; $led = Join-Path (Get-KitTemp) 'claude-build-gate'; $rd = { param($f) try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
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
  $lanes = @(try { (Get-Content (Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json') -Raw -ErrorAction Stop | ConvertFrom-Json).lanes } catch { })
  [pscustomobject]@{ h0 = $h0.ToString('o'); running = $run.Count; queued = $que.Count; today = [int](($rows | Measure-Object done -Sum).Sum); waitMax = [double](@($rows.waitMax) + 0 | Measure-Object -Maximum).Maximum
    ram = [math]::Round([double](($run | Measure-Object need -Sum).Sum), 1); rows = $rows
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
function Update-KitCpuStats($Prior, [datetime]$Now = (Get-Date), $Shells = @()) {
  $all0 = @(Get-KitSweepProcs | Where-Object { $null -ne $_.Cpu }); $idle = @($all0 | Where-Object { $_.Id -eq 0 -or $_.Name -match '^(System )?Idle' })[0]
  $procs = @($all0 | Where-Object { $_.Id -gt 0 -and $_.Name -notmatch '^(System )?Idle' })
  if (-not $procs.Count) { return $Prior }   # no CPU seconds on this platform
  $key = { param($p) "$($p.Id)|$(if ($p.Created) { try { ([datetime]$p.Created).Ticks } catch { '' } })" }
  $acc = [ordered]@{}; foreach ($p in $procs) { if ([double]$p.Cpu -ge 1) { $acc[(& $key $p)] = [math]::Round([double]$p.Cpu, 1) } }; if ($idle) { $acc.idle = [double]$idle.Cpu }
  $samples = @($Prior.samples | Where-Object { $_ -and [datetime]$_.at -ge $Now.AddDays(-1) -and [datetime]$_.at -lt $Now })
  $prevAt = try { [datetime]$Prior.at } catch { $null }; $dt = if ($prevAt) { ($Now - $prevAt).TotalSeconds } else { 0 }
  if ($dt -ge 60 -and $dt -le 7200) {   # an older snapshot gives a long average: no sample
    $cores = [math]::Max(1, [Environment]::ProcessorCount); $pa = $Prior.acc; $pct = @{}; $byId = @{}; $kids = @{}
    foreach ($p in $procs) { $byId[$p.Id] = $p; if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.Generic.List[int]]::new() }; $kids[$p.ParentId].Add($p.Id)
      $was = if ($pa) { $pa."$(& $key $p)" }; $base = if ($null -ne $was) { [double]$was } elseif ($p.Created -and [datetime]$p.Created -gt $prevAt) { 0 } else { $null }
      if ($null -ne $base) { $v = 100 * ([double]$p.Cpu - $base) / $dt / $cores; if ($v -gt 0.05) { $pct[$p.Id] = $v } } }
    $tree = { param([int]$id) $seen = @{}; $todo = [Collections.Generic.Queue[int]]::new(); $todo.Enqueue($id); while ($todo.Count) { $i = $todo.Dequeue(); if ($seen.ContainsKey($i) -or -not $byId.ContainsKey($i)) { continue }; $seen[$i] = 1; foreach ($c in @($kids[$i])) { if ($c -ne $i) { $todo.Enqueue($c) } } }; @($seen.Keys) }
    $inG = @{}; $g = [ordered]@{}
    $groups = @(if (Get-Command Invoke-KitHooks -ErrorAction SilentlyContinue) { Invoke-KitHooks Get-KitCpuGroups })
    foreach ($gr in @($groups | Where-Object { $_.name -and $_.pid })) { $ids = & $tree ([int]$gr.pid); foreach ($i in $ids) { $inG[$i] = 1 }; $g["$($gr.name)"] = [math]::Round([double](@($ids | ForEach-Object { $pct[$_] }) + 0 | Measure-Object -Sum).Sum, 1) }
    $sh = @{}; foreach ($s in @($Shells | Where-Object { $_.pid })) { $sh[[int]$s.pid] = "$($s.owner)" }
    $owner = { param([int]$id) for ($n = 0; $n -lt 12 -and $byId.ContainsKey($id); $n++) { if ($sh.ContainsKey($id) -and $sh[$id]) { return $sh[$id] }; $id = $byId[$id].ParentId }; '' }
    $top = @($pct.Keys | Where-Object { -not $inG.ContainsKey($_) -and $pct[$_] -ge 10 } | Sort-Object { - $pct[$_] } | Select-Object -First 5 | ForEach-Object { $p = $byId[$_]   # TODO-PARAM (fixed default: 10% of the machine)
        [ordered]@{ n = "$($p.Name)"; pid = $p.Id; p = [math]::Round($pct[$_], 1); o = (& $owner $p.Id); c = $(if ($p.CommandLine) { $one = Protect-KitText ("$($p.CommandLine)" -replace '\s+', ' '); $one.Substring(0, [math]::Min(160, $one.Length)) } else { '' }) } })
    # the machine from idle time (a build that came and went between sweeps counts too); no idle process: the sum
    $all = if ($idle -and $null -ne $pa.idle) { [math]::Max(0, [math]::Min(100, 100 - 100 * ([double]$idle.Cpu - [double]$pa.idle) / $dt / $cores)) } else { [double](@($pct.Values) + 0 | Measure-Object -Sum).Sum }
    $samples += [ordered]@{ at = $Now.ToString('o'); s = [int]$dt; all = [math]::Round($all, 1); g = $g; top = $top }
  }
  [ordered]@{ at = $Now.ToString('o'); acc = $acc; samples = $samples }
}

# ---- cards: render inside Format-KitSuperviseHtml and use its helpers ($e, $n1, $fmt, $icv, $spark, $dots, $nowCard, $at, $st, $nw, $j, $l24)
# the 24 hour labels over a heatmap: every 6th clock hour, "now" over the last cell
function Format-KitHourHead([datetime]$H0) { @(for ($hi = 0; $hi -lt 21; $hi++) { if ($H0.AddHours($hi).Hour % 6 -eq 0) { "<b style='grid-column:$($hi + 1)/span 2'>$($H0.AddHours($hi).ToString('HH'))</b>" } }) + "<b class=nw style='grid-column:23/span 2'>now</b>" -join '' }
# 24 cells, shade = minutes in that hour (square root: a short one still shows; 60 min = full), the last one outlined = now
function Format-KitHeatCells($Hours, [datetime]$H0, [string]$Aria, [scriptblock]$Tip) {
  $hs = @($Hours); "<span class='gs hm' role=img aria-label='$(& $e $Aria)'>$(@(for ($hi = 0; $hi -lt 24; $hi++) { $hv = if ($hi -lt $hs.Count) { @($hs[$hi]) } else { @(0, 0, 0, '') }; $m = [double]$hv[1]
    "<i$(if ($hi -eq 23) { ' class=nw' }) style='--a:$(if ($m -gt 0) { & $n1 ([math]::Round(25 + 75 * [math]::Sqrt([math]::Min(1, $m / 60)))) } else { 0 })%' title='$(& $e "$($H0.AddHours($hi).ToString('HH:00'))$(if ($hi -eq 23) { ' (now)' }) · $(& $Tip $hv)")'></i>" }) -join '')</span>" }
# build gate: one line per kind (24 h heatmap of busy minutes, running, queued, today, waits, RAM); RAM, QA seats, phones, browsers aside
function Format-KitGateCard($gs) {
  if (-not $gs) { return (& $nowCard 'Build gate · QA seats' "$(& $icv run 'running builds' (& $fmt $nw.gr))$(& $icv queue 'queued builds' (& $fmt $nw.gq))<small> · seats </small>$(& $fmt $nw.seats)<small> / $(& $fmt $nw.seatsMax)</small>" "longest wait $(& $fmt $nw.gw) min" '' $(if ($nw.gw -ge 30) { 'hot' } elseif ($nw.gq -ge 6) { 'warn' }) "$(& $dots $nw.seats $nw.seatsMax)$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queue, 24 h' 'peak' 0)") }
  $fl = [math]::Max(0, [double]$j.mem.AvailGB - [double]$st.keepFree); $gb = [math]::Min(24, [int][math]::Ceiling([double]$gs.ram + $fl))   # 1 dot = 1 GB: promised to running builds, then free above the floor
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
      "<div class=gk><span class=gn title='$(& $e "${nm}: $w")'>$(& $e $nm)</span>$(Format-KitHeatCells $kr.hours $h0 "$nm, builds per hour, last 24 h" { param($hv) "$nm · $([int]$hv[0]) builds · $(& $n1 $hv[1]) build-min · max wait $(& $n1 $hv[2]) min" })$($cells -join '')</div>" })
  "<div class='st $(if ($gs.waitMax -ge 30) { 'hot' } elseif ($gs.queued -ge 6) { 'warn' })' data-fit><div class=k>Build gate · QA seats</div><div class=v>$(& $icv run 'running builds' (& $fmt $gs.running))$(& $icv queue 'queued builds' (& $fmt $gs.queued))$(& $icv today 'builds today' (& $fmt $gs.today))$(& $icv wait 'longest wait today' (& $n1 $gs.waitMax) ' min')</div>" +
  "<div class=gl><div>$(if ($kRows.Count) { "<div class=gks>$gHead$($kRows -join '')</div><div class=hk>shade = busy minutes in that hour · outlined = now · tap a cell for builds and waits</div>" } else { '<div class=s>no gated build in 24 h</div>' })</div>" +
  "<div class=gp>$(& $spark @($l24 | ForEach-Object gq) 'watch' 'queued builds, 24 h' 'peak' 0)$ramDots$(& $dots $nw.seats $nw.seatsMax)<div class=s>QA seats $(& $fmt $nw.seats) / $(& $fmt $nw.seatsMax)</div>$(if ($gs.lanes) { "<div class=s>phone lanes $($gs.leased) / $($gs.lanes) leased · emulators $($gs.emulators) running</div>" })$(if ($gs.browsers) { "<div class=s>test browsers $($gs.browsers) ($(& $n1 $gs.browserGB) GB, leased)</div>" })</div></div></div>"
}
# lease waits: one line per resource (24 h heatmap of minutes waited · waits · minutes · longest), the gate card's style
function Format-KitWaitCard($w) {
  $rs = @($w.rows | Where-Object { $_ }); $h0 = try { [datetime]$w.h0 } catch { $at.Date.AddHours($at.Hour - 23) }
  if (-not $rs.Count) { return "<div class='st wt' data-fit><div class=k>Lease waits · 24 h</div><div class=s>no agent waited for a lease in 24 h</div></div>" }
  $cols = @(@('queue', 'waits, 24 h', ''), @('wait', 'minutes waited, 24 h', 'min'), @('wait', 'longest wait, min', 'max'))
  $head = "<div class='gk gh'><span class=gn>resource · hour</span><span class='gs0 hrs' aria-hidden=true>$(Format-KitHourHead $h0)</span>$(@($cols | ForEach-Object { "<span class=gc>$(Format-KitIcon $_[0] $_[1])$(if ($_[2]) { "<small>$($_[2])</small>" })</span>" }) -join '')</div>"
  $lines = @(foreach ($r in $rs) { $nm = "$($r.name)"; $vals = @("$([int]$r.n)", (& $n1 $r.min), (& $n1 $r.max))
      "<div class=gk><span class=gn title='$(& $e "${nm}: $($vals[0]) waits · $($vals[1]) min · longest $($vals[2]) min")'>$(& $e $nm)</span>$(Format-KitHeatCells $r.hours $h0 "$nm, minutes waited per hour, last 24 h" { param($hv) "$([int]$hv[0]) waits · $(& $n1 $hv[1]) min · longest $(& $n1 $hv[2]) min$(if ("$($hv[3])") { " · $($hv[3])" })" })" +
      (@(for ($ci = 0; $ci -lt 3; $ci++) { "<span class='gc$(if ($vals[$ci] -eq '0') { ' z' })' title='$(& $e "${nm}: $($vals[$ci]) $($cols[$ci][1])")'>$(Format-KitIcon $cols[$ci][0] $cols[$ci][1])$($vals[$ci])</span>" }) -join '') + '</div>' })
  "<div class='st wt' data-fit><div class=k>Lease waits · 24 h</div><div class='gks w3'>$head$($lines -join '')</div><div class=hk>shade = minutes agents waited for that resource in the hour · outlined = now · tap a cell for waits and who</div></div>"
}
# CPU: a sparkline per lane process (24 h, % of the machine; red: over 80% between sweeps 5+ min apart, amber: a peak over 80% in 24 h), the
# machine total, then the top other processes (10%+ of the machine between two sweeps)
function Format-KitCpuCard($cpu) {
  $ss = @($cpu.samples | Where-Object { $_ }); $last = if ($ss.Count) { $ss[-1] }
  $hot = { param($v, $s) [double]$v -gt 80 -and [int]$s -ge 300 }   # TODO-PARAM (fixed default: 80% for 5+ min)
  if (-not $ss.Count) { return "<div class='st cpu' data-fit><div class=k>CPU · 24 h</div><div class=s>no sample yet: the next sweep compares CPU time with this one</div></div>" }
  $names = @($ss | ForEach-Object { if ($_.g -is [Collections.IDictionary]) { @($_.g.Keys) } elseif ($_.g) { @($_.g.PSObject.Properties.Name) } } | Select-Object -Unique | Sort-Object)   # this sweep's sample: a dictionary; older ones: from JSON
  $one = { param([string]$nm, $vals, [string]$sub) $now = [double]@($vals)[-1]; $pk = [double](@($vals) + 0 | Measure-Object -Maximum).Maximum
    $tn = if (& $hot $now $last.s) { 'hot' } elseif ($pk -gt 80) { 'warn' } else { '' }
    "<div class='cpi f $tn' title='$(& $e "${nm}: now $(& $n1 $now)% · 24 h peak $(& $n1 $pk)%")'><div class=tn>$(& $e $nm)<span class=cv>$(& $n1 $now)<small>%</small></span></div>$(& $spark $vals $(if ($tn -eq 'hot') { 'act' } elseif ($tn) { 'watch' } else { 'slate' }) "$sub, 24 h" 'peak' 0 '%' -NoNow)</div>" }
  $items = @(& $one 'whole machine' @($ss | ForEach-Object { [double]$_.all }) 'CPU %') + @(foreach ($nm in $names) { & $one $nm @($ss | ForEach-Object { if ($_.g -and $null -ne $_.g.$nm) { [double]$_.g.$nm } else { 0 } }) 'CPU %' })
  $tops = @($ss | ForEach-Object { $s0 = $_; @($_.top | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ k = "$($_.pid)|$($_.n)"; n = $_.n; pid = $_.pid; p = [double]$_.p; o = "$($_.o)"; c = "$($_.c)"; at = $s0.at; s = $s0.s; nowS = [bool]($s0 -eq $last) } } } | Group-Object k | ForEach-Object { $gp = @($_.Group | Sort-Object { [datetime]$_.at }); $pk = ($gp | Measure-Object p -Maximum).Maximum
      [pscustomobject]@{ n = $gp[-1].n; pid = $gp[-1].pid; o = @($gp.o | Where-Object { $_ })[-1]; c = $gp[-1].c; now = $(if ($gp[-1].nowS) { $gp[-1].p }); pk = $pk; hot = [bool]@($gp | Where-Object { & $hot $_.p $_.s }).Count; last = $gp[-1].at } } | Sort-Object { - $_.pk } | Select-Object -First 8)
  $topHtml = if ($tops.Count) { "<div class=cpt><div class=sh4>Top other processes (10%+ of the machine between two sweeps)</div>" + (@($tops | ForEach-Object { "<div class='cpo f$(if ($_.hot) { ' hot' })' title='$(& $e $(if ($_.c) { $_.c } else { $_.n }))'><span class=cn0>$(& $e $_.n) <small>pid $($_.pid)$(if ($_.o) { " · $($_.o)" })</small></span><span class=gc>now $(if ($null -ne $_.now) { "$(& $n1 $_.now)%" } else { '—' })</span><span class=gc>24 h peak $(& $n1 $_.pk)%</span></div>" }) -join '') + '</div>' } else { '<div class=s>no other process over 10% of the machine in 24 h</div>' }
  "<div class='st cpu$(if (& $hot $last.all $last.s) { ' hot' })' data-fit><div class=k>CPU · 24 h<small> · % of the machine ($([Environment]::ProcessorCount) cores), sampled each sweep</small></div><div class=cpus>$($items -join '')</div>$topHtml</div>"
}
# test runs: checks per day as stacked bars (PASS, FAIL, NOT_TESTED, OUT_OF_SCOPE muted), NOT_TESTED causes; a day's bar lists its runs
function Format-KitQaBand($qa) {
  $ds = @($qa.days | Where-Object { $_ }); $tot = { param($d) [int]$d.pass + [int]$d.fail + [int]$d.nt + [int]$d.oos }; $mx = [math]::Max(1, (@($ds | ForEach-Object { & $tot $_ }) + 0 | Measure-Object -Maximum).Maximum)
  $kinds = @(@('pass', 'PASS', 'q-p'), @('fail', 'FAIL', 'q-f'), @('nt', 'NOT_TESTED', 'q-n'), @('oos', 'OUT_OF_SCOPE', 'q-o'))
  $sel = @($ds | Where-Object { @($_.runs).Count })[-1].day
  $cols = @(foreach ($d in $ds) { $t = & $tot $d; $dl = try { ([datetime]$d.day).ToString('ddd dd', [cultureinfo]::InvariantCulture) } catch { $d.day }
      $tip = "$dl · $(@($d.runs).Count) runs · $(@($kinds | ForEach-Object { "$([int]$d.($_[0])) $($_[1])" }) -join ' · ')"
      "<button type=button class='qc$(if (-not $t) { ' z' })' data-d='$($d.day)' aria-pressed=$(if ($d.day -eq $sel) { 'true' } else { 'false' }) title='$(& $e $tip)' aria-label='$(& $e $tip)' onclick=`"var d=this.dataset.d,q=this.closest('.qa');q.querySelectorAll('.qdl').forEach(function(l){l.hidden=l.dataset.d!=d});q.querySelectorAll('.qc').forEach(function(b){b.setAttribute('aria-pressed',b.dataset.d==d)})`"><b>$(if ($t) { $t } else { '—' })</b><span class=qs style='height:calc((100% - 14px) * $(& $n1 (100 * $t / $mx)) / 100)'>$(@($kinds | Where-Object { [int]$d.($_[0]) } | ForEach-Object { "<i class=$($_[2]) style='flex:$([int]$d.($_[0]))'></i>" }) -join '')</span></button>" })
  $axis = @($ds | ForEach-Object { $x = $_.day -eq $at.ToString('yyyy-MM-dd'); "<span$(if ($x) { ' class=x' })>$(if ($x) { 'today' } else { try { ([datetime]$_.day).ToString('ddd', [cultureinfo]::InvariantCulture) } catch { $_.day } })</span>" }) -join ''
  $sums = @($kinds | ForEach-Object { $k = $_[0]; [pscustomobject]@{ k = $_; n = [int](@($ds | ForEach-Object { [int]$_.$k }) + 0 | Measure-Object -Sum).Sum } })
  $legend = @($sums | ForEach-Object { "<span class=ql><i class=$($_.k[2])></i>$($_.k[1]) $($_.n)</span>" }) -join ''
  $cz = @($qa.causes.PSObject.Properties | Where-Object { [int]$_.Value }); $cMax = [math]::Max(1, (@($cz.Value) + 0 | Measure-Object -Maximum).Maximum)
  $causes = if ($cz.Count) { "<div class=qcz><div class=sh4>NOT_TESTED causes, 7 days</div>$(@($cz | Sort-Object { - [int]$_.Value } | ForEach-Object { "<div class=qcr><span class=qcn>$(& $e $_.Name)</span><span class=bar><i class=watch style='width:$(& $n1 (100 * [int]$_.Value / $cMax))%'></i></span><span class=gc>$([int]$_.Value)</span></div>" }) -join '')</div>" } else { "<div class=qcz><div class=sh4>NOT_TESTED causes, 7 days</div><div class=s>none</div></div>" }
  $runLi = { param($rn) "<li class=f><span class=qrn>$(& $e $rn.run)</span><span class=qrv>$([int]$rn.items) items$(@(foreach ($kk in $kinds) { "<span class=ql title='$($kk[1])'><i class=$($kk[2])></i>$([int]$rn.($kk[0]))</span>" }) -join '')</span></li>" }
  $lists = @(foreach ($d in @($ds | Where-Object { @($_.runs).Count })) { "<ul class=qdl data-d='$($d.day)'$(if ($d.day -ne $sel) { ' hidden' })><li class=qh>$(try { ([datetime]$d.day).ToString('dddd dd MMM', [cultureinfo]::InvariantCulture) } catch { $d.day })</li>$(@(foreach ($rn in @($d.runs)) { & $runLi $rn }) -join '')</ul>" })
  "<div class=qa><div class=qg><figure class=qch><div class=qw role=group aria-label='checks per day, 7 days: tap a day for its runs'>$($cols -join '')</div><div class=qx>$axis</div><figcaption>$legend</figcaption></figure>$causes</div><div class=qrl>$($lists -join '')</div></div>"
}
# CSS of these cards (appended to the page's)
function Get-KitStatsCss {
  '@media(min-width:700px){.gks.w3{grid-template-columns:minmax(0,max-content) minmax(120px,1fr) repeat(3,max-content)}}.gks.w3 .gn{white-space:normal;overflow-wrap:anywhere;max-width:260px}@media(max-width:699px){.gks.w3 .gk{grid-template-columns:repeat(3,minmax(0,1fr))}}' +
  '.cpus{margin-top:6px;display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px}.cpi{border:1px solid var(--ln);border-radius:6px;padding:4px 8px;min-width:0}.cpi .tn{display:flex;justify-content:space-between;gap:8px;font-size:12px;font-weight:600;overflow-wrap:anywhere}.cpi .cv{font-variant-numeric:tabular-nums;white-space:nowrap}.cpi .cv small{color:var(--mt);font-weight:500}' +
  '.cpi.hot{border-color:color-mix(in srgb,var(--act) 60%,var(--ln))}.cpi.hot .cv{color:color-mix(in srgb,var(--act) 60%,var(--fg))}.cpi.warn .cv{color:color-mix(in srgb,var(--watch) 55%,var(--fg))}.nod{font-size:10.5px;color:var(--mt);padding:10px 0;text-align:center}' +
  '.cpt{margin-top:6px}.cpo{display:grid;grid-template-columns:minmax(0,1fr) max-content max-content;gap:2px 12px;font-size:12px;padding:2px 0;border-top:1px solid var(--ln)}.cpo .cn0{overflow-wrap:anywhere}.cpo small{color:var(--mt)}.cpo.hot .gc{color:color-mix(in srgb,var(--act) 60%,var(--fg));font-weight:650}' +
  '.qa{display:grid;gap:8px}.qg{display:grid;grid-template-columns:minmax(0,1fr) minmax(200px,320px);gap:8px 20px;align-items:start}@media(max-width:700px){.qg{grid-template-columns:minmax(0,1fr)}}.qch{margin:0}' +
  '.qw,.qx{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:4px;text-align:center}.qw{height:110px;align-items:end}.qc{all:unset;box-sizing:border-box;display:flex;flex-direction:column;justify-content:flex-end;height:100%;cursor:pointer;border-radius:3px}.qc:focus-visible{outline:2px solid var(--sage)}' +
  '.qc b{font-size:10.5px;line-height:13px}.qc.z b{color:var(--mt);font-weight:500}.qs{display:flex;flex-direction:column-reverse;min-height:1px;border-radius:2px 2px 0 0;overflow:hidden}.qc[aria-pressed=true] .qs{box-shadow:0 0 0 1.5px var(--fg)}' +
  '.q-p{background:var(--sage)}.q-f{background:var(--act)}.q-n{background:var(--watch)}.q-o{background:color-mix(in srgb,var(--mt) 35%,var(--sf2))}.qs i{display:block;min-height:2px}' +
  '.qx{font-size:10px;color:var(--mt);border-top:1px solid var(--ln)}.qx .x{color:var(--fg);font-weight:650}.qch figcaption{display:flex;flex-wrap:wrap;gap:2px 10px;font-size:11px;color:var(--mt);margin-top:4px}.ql{white-space:nowrap}.ql i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:3px;vertical-align:-1px}' +
  '.qcr{display:grid;grid-template-columns:max-content minmax(40px,1fr) max-content;gap:6px;align-items:center;font-size:12px;margin-top:3px}.qcn{overflow-wrap:anywhere}' +
  '.qdl{list-style:none;margin:0;padding:0;display:grid;gap:2px}.qdl .qh{font-size:11px;color:var(--mt);font-weight:600}.qdl li.f{display:flex;flex-wrap:wrap;justify-content:space-between;gap:2px 12px;font-size:12px;border-top:1px solid var(--ln);padding:2px 0}.qrn{overflow-wrap:anywhere;min-width:0}.qrv{display:flex;flex-wrap:wrap;gap:2px 8px;color:var(--mt)}'
}
