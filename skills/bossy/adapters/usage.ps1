<#
usage.ps1 (core): tokens, cost and time per run, step, role and model for the supervise page (Statistics "Usage") and bossy.ps1
budget -Usage, dot-sourced by bossy.ps1 (skills/bossy/adapters/).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L9 usage · L327 split · L401 budget
#>
#Requires -Version 7
# ---- usage: tokens, cost, time per run, step, role, model (Statistics "Usage"); transcripts parsed incrementally, cached
# one transcript's totals since its last read offset (append-only files); Claude: per message id (a message repeats per content block), Codex: last cumulative count
# token vector [in, out, cache read, cache write, of it 1-hour cache write]; days = that vector per local day (the 7-day window cuts by day)
function Update-KitUsageFile([string]$Path, $Rec, [ref]$Left) {
  $fi = [IO.FileInfo]::new($Path); if (-not $fi.Exists) { return $Rec }
  if (-not $Rec -or $null -eq $Rec.days -or [int]$Rec.v -lt 3 -or [long]$Rec.off -gt $fi.Length) { $Rec = [ordered]@{ v = 3; off = 0L; in = 0L; out = 0L; cr = 0L; cw = 0L; cw1 = 0L; n = 0; tools = 0; model = ''; t0 = ''; t1 = ''; lastId = ''; lastU = @(0, 0, 0, 0, 0); days = @{} } }   # older cache: no per-day + model vectors, reread
  # time split + hourly tokens (owner 2026-11-20): whole only when read from offset 0; an older record counts on, flagged partial (never reread for it)
  if ($null -eq $Rec.tm) { $Rec['tm'] = @(0.0, 0.0, 0.0, 0.0, 0.0, 0.0); $Rec['tOk'] = [long]$Rec.off -eq 0; $Rec['tL'] = ''; $Rec['tK'] = ''; $Rec['tC'] = 4; $Rec['hrs'] = @{}; $Rec['tOff'] = [long]$Rec.off }
  if ($null -eq $Rec.tmd -and [long]$Rec.off -eq 0) { $Rec['tmd'] = @{} }   # the split per day: only a read from offset 0 (an older record keeps its whole-file split)
  if ($Rec.tOk -and [long]$Rec.tOff -ne [long]$Rec.off) { $Rec.tOk = $false }   # an older reader moved the offset past the split: partial from here
  $Rec['tOff'] = [long]$Rec.off
  $n = [int][math]::Min([math]::Min($fi.Length - [long]$Rec.off, [math]::Max([long]0, [long]$Left.Value)), [long]256MB); if ($n -le 0) { return $Rec }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
  try { $null = $fs.Seek([long]$Rec.off, 'Begin'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  if ($got -le 0) { return $Rec }; $end = [Array]::LastIndexOf($b, [byte]10, $got - 1); if ($end -lt 0) { return $Rec }   # no whole line yet; shrunk meanwhile
  $Left.Value -= $end + 1; $Rec.off = [long]$Rec.off + $end + 1; $Rec.tOff = $Rec.off
  $num = { param($l, [string]$k) $m = [regex]::Match($l, """$k"":(\d+)"); if ($m.Success) { [long]$m.Groups[1].Value } else { 0L } }
  foreach ($l in [Text.Encoding]::UTF8.GetString($b, 0, $end).Split([char]10)) {
    $ts = [regex]::Match($l, '"timestamp":"([^"]+)"'); if ($ts.Success) { if (-not $Rec.t0) { $Rec.t0 = $ts.Groups[1].Value }; $Rec.t1 = $ts.Groups[1].Value; Step-KitUsageTime $Rec $l $ts.Groups[1].Value }
    $was = @([long]$Rec.in, [long]$Rec.out, [long]$Rec.cr, [long]$Rec.cw, [long]$Rec.cw1)
    if ($l.Contains('"total_token_usage"')) {   # codex rollout: cumulative
      $m = [regex]::Match($l, '"total_token_usage":\{([^}]*)\}'); if (-not $m.Success) { continue }; $u = $m.Groups[1].Value; $Rec.cr = & $num $u 'cached_input_tokens'; $Rec.in = (& $num $u 'input_tokens') - $Rec.cr; $Rec.out = & $num $u 'output_tokens'; $Rec.n++ }
    elseif (-not $l.Contains('"usage"') -or -not $l.Contains('"assistant"')) { continue }
    else {
      $Rec.tools += ([regex]::Matches($l, '"type":"tool_use"')).Count
      $md = [regex]::Match($l, '"model":"([^"]+)"'); if ($md.Success -and $md.Groups[1].Value -ne '<synthetic>') { $Rec.model = $md.Groups[1].Value }
      $uu = @((& $num $l 'input_tokens'), (& $num $l 'output_tokens'), (& $num $l 'cache_read_input_tokens'), (& $num $l 'cache_creation_input_tokens'), (& $num $l 'ephemeral_1h_input_tokens'))   # no breakdown: all 5-minute writes
      $id = [regex]::Match($l, '"id":"(msg_[^"]+)"').Groups[1].Value
      if ($id -and $id -eq $Rec.lastId) { $p = @($Rec.lastU) } else { $p = @(0, 0, 0, 0, 0); $Rec.n++ }
      $Rec.in += $uu[0] - $p[0]; $Rec.out += $uu[1] - $p[1]; $Rec.cr += $uu[2] - $p[2]; $Rec.cw += $uu[3] - $p[3]; $Rec.cw1 += $uu[4] - $p[4]; $Rec.lastId = $id; $Rec.lastU = $uu }
    if ($ts.Success) { if ($null -eq $Rec.days) { $Rec.days = @{} }; $dk = "$(([datetimeoffset]$ts.Groups[1].Value).LocalDateTime.ToString('yyyy-MM-dd'))|$($Rec.model)"   # tokens by day and model (a /model switch mid-session)
      $dv = @(if ($Rec.days[$dk]) { $Rec.days[$dk] } else { 0, 0, 0, 0, 0 }); $now5 = @([long]$Rec.in, [long]$Rec.out, [long]$Rec.cr, [long]$Rec.cw, [long]$Rec.cw1)
      $Rec.days[$dk] = @(for ($i = 0; $i -lt 5; $i++) { [long]$dv[$i] + $now5[$i] - $was[$i] })
      if ($Rec.tOk) { $hk = "$(([datetimeoffset]$ts.Groups[1].Value).LocalDateTime.ToString('yyyy-MM-dd HH'))|$($Rec.model)"; $hv = @(if ($Rec.hrs[$hk]) { $Rec.hrs[$hk] } else { 0, 0, 0, 0, 0 })   # the runs band's hour cells
        if (@(for ($i = 0; $i -lt 5; $i++) { $now5[$i] - $was[$i] }) -ne 0) { $Rec.hrs[$hk] = @(for ($i = 0; $i -lt 5; $i++) { [long]$hv[$i] + $now5[$i] - $was[$i] }) } } }
  }
  if ($Rec.hrs -and $Rec.hrs.Count) { $cut = (Get-Date).AddDays(-(Get-KitParam 'usage.keepDays')).ToString('yyyy-MM-dd'); foreach ($hk in @($Rec.hrs.Keys | Where-Object { "$_" -lt $cut })) { $Rec.hrs.Remove($hk) } }
  if ($Rec.tmd -and $Rec.tmd.Count) { $cut = (Get-Date).AddDays(-(Get-KitParam 'usage.keepDays')).ToString('yyyy-MM-dd'); foreach ($dk in @($Rec.tmd.Keys | Where-Object { "$_" -lt $cut })) { $Rec.tmd.Remove($dk) } }
  $Rec
}
# a transcript line's time (owner 2026-11-20): prompt or tool result -> assistant = model (a gap over 30 min = idle); tool_use -> its results = that
# tool's kind, the gate's printed queue time = waiting; an answer with no tool -> the next prompt = idle; tm = seconds [model, build, ci, browser, other tool, waiting]
function Step-KitUsageTime($Rec, [string]$L, [string]$Ts) {
  $isA = $L.Contains('"role":"assistant"'); $isU = -not $isA -and $L.Contains('"type":"user"'); if (-not $isA -and -not $isU) { return }
  $t = [datetimeoffset]$Ts; $gap = if ($Rec.tL) { [math]::Max(0.0, ($t - [datetimeoffset]$Rec.tL).TotalSeconds) } else { 0.0 }; $tm = @($Rec.tm | ForEach-Object { [double]$_ })
  if ($isA) { if ($Rec.tK -and $gap -le 1800) { $tm[0] += $gap }; if ($L.Contains('"type":"tool_use"')) { $Rec.tK = 'a'; $Rec.tC = Get-KitToolTimeKind $L } else { $Rec.tK = 'e' } }
  elseif ($L.Contains('"tool_result"')) { if ($Rec.tK -in 'a', 'r') { $q = [math]::Min($gap, [double](@([regex]::Matches($L, '\[gate\] starting:[^\\"]*?queued (\d+) s') | ForEach-Object { [double]$_.Groups[1].Value }) + 0 | Measure-Object -Sum).Sum); $tm[[int]$Rec.tC] += $gap - $q; $tm[5] += $q }; $Rec.tK = 'r' }
  else { $Rec.tK = 'u' }
  if ($null -ne $Rec.tmd) { $dk = $t.LocalDateTime.ToString('yyyy-MM-dd'); $d6 = @(if ($Rec.tmd[$dk]) { $Rec.tmd[$dk] } else { 0, 0, 0, 0, 0, 0 }); $was6 = @($Rec.tm)   # per day: the 7-day window counts its own days only
    $Rec.tmd[$dk] = @(for ($i = 0; $i -lt 6; $i++) { [double]$d6[$i] + $tm[$i] - [double]$was6[$i] }) }
  $Rec.tm = $tm; $Rec.tL = $Ts
}
# a tool_use line's time kind: 5 waiting (monitors, questions, decisions, leases, sleeps) · 1 builds + tests (gated) · 2 CI / pipelines · 3 browser / QA / phones · 4 other
function Get-KitToolTimeKind([string]$L) {
  if ($L -match '"name":"(Monitor|ScheduleWakeup|AskUserQuestion)"|decide ask|phoney\.ps1\S*\s+acquire|\blease\b|wt train|merge-wait|Start-Sleep|\bsleep \d') { 5 }
  elseif ($L -match 'crafty\.ps1\S*\s+(check|gate)\b|kit-tests\.ps1') { 1 }
  elseif ($L -match '\b(glab|gh)\s+(ci|run|pr checks|pipeline)|pipelines|mr-pipeline|devtools\.py\S*\s+(ci|merge)\b') { 2 }
  elseif ($L -match 'browser\.mjs|pokey\.ps1|phoney\.ps1|"name":"mcp__[\w-]*(chrome|playwright|puppeteer|browser)') { 3 } else { 4 }
}
# a file record's token vectors of the given days (keys yyyy-MM-dd|model): [{ day; model; v }]
function Get-KitUsageParts($Rec, [string[]]$DayKeys) {
  if (-not $Rec -or -not $Rec.days) { return }
  foreach ($kv in $Rec.days.GetEnumerator()) { $dk, $md = "$($kv.Key)" -split '[|]', 2; if ($dk -in $DayKeys) { [pscustomobject]@{ day = $dk; model = $md; v = [long[]]@($kv.Value | ForEach-Object { [long]$_ }) } } }
}
# USD per million tokens (budget.prices, list prices 2026-11-03; derived, not listed: 5-min writes 1.25x in, 1-h 2x in, haiku cache read 0.1x in; key = model id without claude-, also its dated / [1m] variant and alias: sonnet = sonnet-*); [in, out, cache read, 5-min write, 1-h write (else 2x in)]
# $Tok = token vector [in, out, cache read, cache write, of it 1 h]; unknown model: $null (the page lists it as not priced)
function Get-KitUsageCost($Tok, [string]$Model) { $cs = Get-KitUsageCostSplit $Tok $Model; if ($null -ne $cs) { ($cs | Measure-Object -Sum).Sum } }
# the same cost per token type: [in, out, cache read, cache write (5-min + 1-h)] USD; $null = not priced
function Get-KitUsageCostSplit($Tok, [string]$Model) {
  $pr = Get-KitSetting 'budget.prices' $null; if (-not $pr) { if ($null -eq $script:KitPrices) { $script:KitPrices = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget.prices }; $pr = $script:KitPrices }; if (-not $pr -or -not $Model) { return $null }
  $id = $Model.ToLower() -replace '\[[^\]]*\]$' -replace '^claude-'; $pv = $null
  foreach ($p in @((Get-KitProps $pr) | Where-Object { $_.Name -notlike '_*' })) { if ($id -eq $p.Name -or $id.StartsWith("$($p.Name)-") -or ($id -notmatch '-' -and $p.Name -like "$id-*")) { $pv = $p.Value; break } }
  if ($null -eq $pv -or @($pv).Count -lt 4) { return $null }   # pwsh names ignore case: never $v next to $V
  $pv = @($pv | ForEach-Object { [double]$_ }); $w1 = if ($pv.Count -gt 4) { $pv[4] } else { 2 * $pv[0] }   # 4 values: 1-hour writes at 2x input
  @(([double]$Tok[0] * $pv[0] / 1e6), ([double]$Tok[1] * $pv[1] / 1e6), ([double]$Tok[2] * $pv[2] / 1e6), ((([double]$Tok[3] - [double]$Tok[4]) * $pv[3] + [double]$Tok[4] * $w1) / 1e6))
}
# budget -Usage: supervise runs it in the background each sweep; the page reads its cache
function Show-KitUsage([double]$Seconds, [bool]$Json) {
  $u = Get-KitUsage -Seconds $Seconds; $d0 = @($u.days)[-1]
  if ($Json) { $u | ConvertTo-Json -Depth 8 -Compress; return }
  "usage: today $($d0.tok) tokens (output $($d0.out), fresh in $($d0.in), cache write $($d0.cw), cache read $($d0.cr))$(if ($null -ne $d0.cost) { ", est. `$$($d0.cost)$(if ($d0.cs) { " (output `$$([math]::Round(@($d0.cs)[1], 2)), fresh in `$$([math]::Round(@($d0.cs)[0], 2)), cache write `$$([math]::Round(@($d0.cs)[3], 2)), cache read `$$([math]::Round(@($d0.cs)[2], 2)))" })" }); 7 days $(($u.days | Measure-Object tok -Sum).Sum) tokens, $(@($u.runs).Count) run(s), $((@($u.bg) | Measure-Object n -Sum).Sum) agent(s) outside workflows, $(@($u.coord).Count) coordinator session(s)$(if (@($u.unpriced).Count) { "; not priced (add to budget.prices): $(@($u.unpriced | ForEach-Object { "$($_.model) $($_.tok) tokens" }) -join ', ')" })$(if ($u.partial) { '; transcripts still being read (run again)' })"
}
# the git host's merged MRs of this machine's login since $Since (deploy MRs left out); cached 2 beats in the usage cache; $null = no login or no repos
# days as yyyy-MM-dd: ConvertFrom-Json turns ISO date-times into DateTime
function Get-KitUsageHostMrs([datetime]$Since, [datetime]$Now, $Prev) {
  if ($Prev -and "$($Prev.since)" -eq $Since.ToString('yyyy-MM-dd') -and ($Now - [datetime]$Prev.at).TotalMinutes -lt 2 * (Get-KitBeatMinutes)) { return $Prev }
  $repos = @(@(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ }); if (-not $repos.Count) { return $null }
  $hu = try { Get-KitHostUser } catch { '' }; if (-not $hu) { return $null }; $cut = $Since.ToUniversalTime(); $hostErr = $false
  $mrs = @(foreach ($rp in $repos) { foreach ($m in @(try { Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = $cut.ToString('o'); per_page = 100 } } catch { $hostErr = $true }) | Where-Object { $_.iid -and $_.merged_at }) {
        $au = if ($m.author.username) { $m.author.username } else { "$($m.author)" }
        if ((-not $au -or $au -eq $hu) -and ([datetimeoffset]$m.merged_at).UtcDateTime -ge $cut -and -not (Test-KitDeployMr $rp "$($m.source_branch)" "$($m.target_branch)")) { @{ ref = "$rp!$($m.iid)"; day = ([datetimeoffset]$m.merged_at).LocalDateTime.ToString('yyyy-MM-dd'); lead = $(if ($m.created_at) { [math]::Round((([datetimeoffset]$m.merged_at) - ([datetimeoffset]$m.created_at)).TotalHours, 1) }) } } } })   # lead: open -> merged, hours
  if ($hostErr) { return $Prev }   # a failed list is no 0 merged: the last list (or workflow MRs), retried next beat
  @{ at = $Now.ToString('o'); since = $Since.ToString('yyyy-MM-dd'); user = $hu; mrs = @($mrs | Sort-Object { $_.ref } -Unique) }
}
function Get-KitPct($Vals, [double]$P) { $s = @($Vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($P * $s.Count))] }
# runs, steps, background agents of the last $Days days; parses for at most $Seconds (the cache keeps offsets: the rest next call); stored with the result
# one window for every number: the $Days calendar days ending today (tokens cut by the day they were spent)
# a run's human label: its mandate's first words, else the first agent's area or items, else a test run's name and target, else the brief's file name (the run id: the tooltip)
function Get-KitRunLabel($A) {
  $s = @(@($A.mandate) + @(@($A.agents)[0].area) + @(@($A.agents)[0].items) + @(if ($A.name) { "$($A.name)$(if ($A.target) { " · $($A.target)" })" }) + @(if ($A.brief) { [IO.Path]::GetFileNameWithoutExtension("$($A.brief)") }) | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() } | Where-Object { $_ -and $_ -notmatch '^<' })[0]
  if ("$s".Length -gt 48) { $s = ($s.Substring(0, 47) -replace '\s+\S*$', '') + '…' }; "$s"
}
function Get-KitUsage([datetime]$Now = (Get-Date), [int]$Days = 7, [double]$Seconds = 60) {
  $cf = Get-KitPath usage-cache -Create; $all = try { Read-KitText $cf | ConvertFrom-Json -AsHashtable } catch { $null }; $cache = $all.files; if ($cache -isnot [hashtable]) { $cache = @{} }
  $cfCold = $cf -replace '\.json$', '.cold.json'; $coldAll = try { Read-KitText $cfCold | ConvertFrom-Json -AsHashtable } catch { $null }
  if ($coldAll.files -is [hashtable]) { foreach ($ck in $coldAll.files.Keys) { if (-not $cache.ContainsKey($ck)) { $cache[$ck] = $coldAll.files[$ck] } } }   # the hot file wins
  $root = (Invoke-KitAdapter transcript claude root).dir; $since = $Now.Date.AddDays(1 - $Days); $stop = (Get-Date).AddSeconds($Seconds); $left = [ref][long]2GB; $seen = @{}
  $dayKeys = @(foreach ($i in ($Days - 1)..0) { $Now.AddDays(-$i).ToString('yyyy-MM-dd') }); $unp = @{}; $mcost = @{}
  $read = { param([string]$f) $seen[$f] = 1; try { if ((Get-Date) -lt $stop -and $left.Value -gt 0) { $cache[$f] = Update-KitUsageFile $f $cache[$f] $left }; if ([IO.FileInfo]::new($f).Length -gt [long]$cache[$f].off + 64KB) { $script:KitUsagePartial = $true } } catch { }; $cache[$f] }   # a vanished file: its last totals; a half-written line is no backlog
  $script:KitUsagePartial = $false
  $lk = "$cf.lock"; if ((Test-Path -LiteralPath $lk) -and ((Get-Date) - [IO.File]::GetLastWriteTime($lk)).TotalMinutes -gt (Get-KitParam 'usage.lockStaleMinutes')) { Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }   # a killed run's
  try { $lkh = [IO.File]::Open($lk, 'CreateNew', 'Write', 'None') } catch { return (Read-KitUsageResult) }   # another run reads: its last result
  try {
  $meta = { param([string]$f) try { Read-KitText ($f -replace '\.jsonl$', '.meta.json') | ConvertFrom-Json } catch { $null } }
  # elapsed inside the window: a main session open for 15 days read 22184 min in a 7-day window (2026-11-20)
  $mins = { param($r) if ($r.t0 -and $r.t1) { $a0 = [datetimeoffset]$r.t0; if ($a0 -lt [datetimeoffset]$since) { $a0 = [datetimeoffset]$since }; [math]::Round([math]::Max(0.0, ([datetimeoffset]$r.t1 - $a0).TotalMinutes), 1) } }
  $tok4 = { param($v) [long]$v[0] + [long]$v[1] + [long]$v[2] + [long]$v[3] }
  $price = { param($v, [string]$model) $c = Get-KitUsageCostSplit $v $model; $tk = & $tok4 $v; if ($null -eq $c -and $tk) { $mk = if ($model) { $model } else { '(no model)' }; $unp[$mk] = [long]$unp[$mk] + $tk }; $c }   # [in, out, cache read, cache write] USD
  # a step from a file record: its in-window tokens; $x = the step's own fields; $null = no tokens in the window (spent before it)
  # each day + model part priced at its own model; dayc = day -> [tokens, cost, in, out, cache read, cache write, then the 4 costs]; cs = the step's
  # 4 costs; hrs = 'yyyy-MM-dd HH' -> [4 tokens, 4 costs] (whole records only); tm = minutes [model, build, ci, browser, other tool, waiting] or
  # $null (split not recorded); an older cache record (no parts yet) waits for its reread
  $add = { param($a, $b, [int]$n) @(for ($i = 0; $i -lt $n; $i++) { [double]@($a)[$i] + [double]@($b)[$i] }) }
  $mkStep = { param($u, [string]$model, [hashtable]$x) if ($u.days -and $u.days.Count -and [int]$u.v -lt 3) { return }
    $v = [long[]]::new(5); $cs = $null; $c4 = $null; $dc = @{}; foreach ($pt in @(Get-KitUsageParts $u $dayKeys)) { for ($i = 0; $i -lt 5; $i++) { $v[$i] += $pt.v[$i] }; $pm = if ($pt.model) { $pt.model } else { $model }; $s4 = & $price $pt.v $pm; $c = if ($null -ne $s4) { [double]($s4 | Measure-Object -Sum).Sum }
      if ($null -ne $c) { $cs = [double]$cs + $c; $mcost[$pm] = [double]$mcost[$pm] + $c; $c4 = & $add $c4 $s4 4 }; $d0 = @($dc[$pt.day])
      $dc[$pt.day] = @(([long]$d0[0] + (& $tok4 $pt.v)), $(if ($null -ne $c -or $null -ne $d0[1]) { [double]$d0[1] + [double]$c })) + @(& $add @($d0 | Select-Object -Skip 2 -First 4) $pt.v 4) + @(& $add @($d0 | Select-Object -Skip 6) $s4 4) }
    $tk = & $tok4 $v; if (-not $tk -and $u.days -and $u.days.Count) { return }
    $hr = @{}; if ($u.tOk -and $u.hrs) { foreach ($kv in $u.hrs.GetEnumerator()) { $hd, $hm = "$($kv.Key)" -split '[|]', 2; if ($hd.Substring(0, 10) -notin $dayKeys) { continue }; $hv = @($kv.Value | ForEach-Object { [long]$_ })
        $hc = Get-KitUsageCostSplit $hv $(if ($hm) { $hm } else { $model }); $hr[$hd] = & $add $hr[$hd] (@($hv[0..3]) + @(if ($hc) { $hc } else { 0, 0, 0, 0 })) 8 } }
    $tmS = if ($u.tmd) { $s6 = @(0.0) * 6; foreach ($kv in $u.tmd.GetEnumerator()) { if ("$($kv.Key)" -in $dayKeys) { for ($i = 0; $i -lt 6; $i++) { $s6[$i] += [double]@($kv.Value)[$i] } } }; $s6 } elseif ($u.t0 -and [datetimeoffset]$u.t0 -ge [datetimeoffset]$since) { $u.tm }   # the window's days only; no per-day split and begun before the window: unsplit (wall clock)
    $tmv = if ($u.tOk -and $null -ne $tmS) { @($tmS | ForEach-Object { [math]::Round([double]$_ / 60, 1) }) }
    $o = [ordered]@{ run = ''; wid = ''; label = ''; type = ''; role = ''; model = $model; in = $v[0]; out = $v[1]; cr = $v[2]; cw = $v[3]; cw1 = $v[4]; tok = $tk; cost = $cs; cs = $c4; tm = $tmv; act = $(if ($tmv) { [math]::Round(($tmv | Measure-Object -Sum).Sum, 1) }); hrs = $hr; min = (& $mins $u); tools = [int]$u.tools; result = 'pass'; round = 1; retry = 0; dayc = $dc; at = ''; mrs = @() }
    foreach ($kv in $x.GetEnumerator()) { $o[$kv.Key] = $kv.Value }; [pscustomobject]$o }
  # steps' split sums (runs, roles, sessions): tokens by type, cs, tm over the tmN steps that have one (agent minutes: parallel steps add up);
  # hours stay on the steps (the runs band sums them)
  $split = { param($ss) $ss = @($ss | Where-Object { $_ }); $c4 = $null; $t6 = $null; $tn = 0
    foreach ($s in $ss) { if ($null -ne $s.cs) { $c4 = & $add $c4 $s.cs 4 }; if ($null -ne $s.tm) { $t6 = & $add $t6 $s.tm 6; $tn++ } }
    [ordered]@{ in = [long]($ss | Measure-Object in -Sum).Sum; out = [long]($ss | Measure-Object out -Sum).Sum; cr = [long]($ss | Measure-Object cr -Sum).Sum; cw = [long]($ss | Measure-Object cw -Sum).Sum
      cs = $(if ($null -ne $c4) { @($c4 | ForEach-Object { [math]::Round($_, 4) }) }); tm = $(if ($tn) { @($t6 | ForEach-Object { [math]::Round($_, 1) }) }); tmN = $tn; tmAll = $ss.Count } }
  $withSplit = { param($o, $ss) foreach ($kv in (& $split $ss).GetEnumerator()) { $o | Add-Member -Force NoteProperty $kv.Key $kv.Value }; $o }
  $atOf = { param($u, [string]$f) if ($u.t1) { ([datetimeoffset]$u.t1).LocalDateTime.ToString('o') } else { [IO.File]::GetLastWriteTime($f).ToString('o') } }
  # empty = a result whose every field but ok is empty (a missing mrs is no MR)
  $isEmpty = { param($r) -not @((Get-KitProps $r) | Where-Object { $_.Name -ne 'ok' -and $_.Value -and "$($_.Value)".Trim() }).Count }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $stuck = [double](Get-KitParam 'supervise.stuckMinutes')
  $runs = [Collections.Generic.List[object]]::new(); $steps = [Collections.Generic.List[object]]::new(); $bg = @{}; $coord = [Collections.Generic.List[object]]::new()
  foreach ($sd in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {   # no age filter: a session folder keeps its creation time while its runs go on for days
    $sub = Join-Path $sd.FullName 'subagents'; if (-not (Test-Path -LiteralPath $sub)) { continue }
    foreach ($w in @(Get-ChildItem -LiteralPath (Join-Path $sub 'workflows') -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {
      $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path -LiteralPath $j)) { continue }
      $ev = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x.result }
      $failed = @{}; foreach ($x in $ev | Where-Object type -eq 'failed') { $failed["$($x.agentId)"] = 1 }   # the engine's own failure: no result line
      $rec = @(Get-KitWorkflowRecords $w $ev $launch); $name = @(@($rec | ForEach-Object run) + $w.Name | Where-Object { $_ })[0]; $cap = @($rec.cap | Where-Object { $_ })[0]; $spent = @($rec.spent | Where-Object { $_ })[0]
      $rst = Get-KitRunState $w $rec $ev $Now; $live = $rst -in 'running', 'stuck'; $lastW = Get-KitWorkflowLastWrite $w
      $labels = @{}; $noRes = @{}; $rs = [Collections.Generic.List[object]]::new()
      foreach ($s in @($ev | Where-Object type -eq 'started')) {
        $f = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; if (-not (Test-Path -LiteralPath $f)) { continue }
        $u = & $read $f; $m = & $meta $f; $lb = [string]$s.label; $labels[$lb] = 1 + [int]$labels[$lb]
        $r = $res[$s.agentId]; $age = ($Now - [IO.File]::GetLastWriteTime($f)).TotalMinutes
        $out = if ($r) { if ($r.error -or $r.ok -eq $false) { 'fail' } elseif (& $isEmpty $r) { 'empty' } else { 'pass' } } elseif ($failed["$($s.agentId)"]) { 'fail' } elseif ($live -and $age -lt $stuck) { 'running' } elseif ($live) { 'stuck' } else { 'stopped' }
        $model = if ($u.model) { $u.model } else { "$($m.model)" }
        $st = & $mkStep $u $model @{ run = $name; wid = $w.Name; label = $lb; type = (($lb -split ':')[0] -creplace '-[A-Z][\w-]*$'); role = "$($m.agentType)"; result = $out; round = $labels[$lb]; retry = [int]$noRes[$lb]; at = (& $atOf $u $f)
          mrs = @($r.mrs | Where-Object merged | ForEach-Object { "$(if ($_.url) { $_.url } else { $_.ref })" }); mrAll = @($r.mrs | ForEach-Object { "$(if ($_.url) { $_.url } elseif ($_.ref) { $_.ref } else { $_ })" } | Where-Object { $_ -match '[!#]\d+$|^https?://' }) }
        if (-not $r) { $noRes[$lb] = 1 + [int]$noRes[$lb] }; if ($st) { $rs.Add($st); $steps.Add($st) } }   # retry: earlier starts of the label with no result
      if (-not $rs.Count) { continue }
      # a run's end = its newest step (transcript time) or journal write; the folder's time moves only when a file is added (201 vs 211 min, 2026-11-20)
      $wEnd = @(@($rs | ForEach-Object { try { ([datetimeoffset]"$($_.at)").LocalDateTime } catch { } }) + [IO.File]::GetLastWriteTime($j) | Sort-Object)[-1]
      $items = @(@($rec | ForEach-Object { $_.args.agents }) | ForEach-Object { "$($_.items)" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique).Count
      $a0 = @($rec | ForEach-Object args | Where-Object { $_ })[0]; $scr = [IO.Path]::GetFileName("$(@($rec.script | Where-Object { $_ })[0])")
      if (-not $rec.Count -and ($rm = @($ev | Where-Object type -eq 'result' | ForEach-Object { [regex]::Match("$($_.result.output)", 'RECORDED (\S+) (\S+) \(fnv') } | Where-Object Success)[0])) {   # launch record gone or relaunched: name, kind and args from the record-args line (label only, never the live state)
        $name = $rm.Groups[2].Value; $scr = $rm.Groups[1].Value
        $a0 = @($launch | Where-Object { $_.run -eq $name -and $_.args -and (Split-Path "$($_.script)" -Leaf) -eq $scr } | Sort-Object { [math]::Abs(([datetime]$_.at - $w.CreationTime).TotalMinutes) } | ForEach-Object args)[0] }
      $rTasks = @(@(@($a0.agents) | ForEach-Object { $_.task }) + @($a0.select.tasks) + @($a0.tasks) + @($a0.task) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^(?=[\w-]*\d)[\w-]{4,}$' } | Select-Object -Unique)   # a page link each
      $runs.Add((& $withSplit ([pscustomobject]@{ run = $name; id = $w.Name; label = (Get-KitRunLabel $a0); qaName = "$($a0.name)"; tasks = $rTasks; mrAll = @($rs | ForEach-Object { $_.mrAll } | Where-Object { $_ } | Select-Object -Unique); kind = $(if ($scr -match 'testy') { 'test' } elseif ($scr -match 'buildy') { 'build' } elseif ($scr -match 'tidy|retro') { 'kit' } else { '' }); started = $w.CreationTime.ToString('o'); status = $(if ($live) { 'running' } elseif ($rst -eq 'paused') { 'paused' } else { 'ended' }); state = $rst; lastAt = $lastW.ToString('o'); cap = [long]$cap; spent = [long]$spent; tok = [long]($rs | Measure-Object tok -Sum).Sum; cost = $(if (@($rs | Where-Object { $null -ne $_.cost }).Count) { [math]::Round(($rs | Measure-Object cost -Sum).Sum, 2) })
          wall = [math]::Round(($wEnd - $w.CreationTime).TotalMinutes); roles = (@($rs | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = @($rs | Where-Object { $_.result -in 'pass', 'empty', 'fail' }).Count; total = $rs.Count; merged = @($rs.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = $items
          loop = [long](@($rs | Where-Object { $_.type -in 'review', 'fix' }) | Measure-Object tok -Sum).Sum; at = $wEnd.ToString('o'); steps = @($rs) }) $rs)) }
    foreach ($f in @(Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # Agent-tool spawns, by coordinator session
      $u = & $read $f.FullName; $m = & $meta $f.FullName; $k = $sd.Name; $model = if ($u.model) { $u.model } else { "$($m.model)" }; $rl = if ($m.agentType) { "$($m.agentType)" } else { 'agent' }
      $st = & $mkStep $u $model @{ label = "$($m.description)"; type = 'agent'; role = $rl; at = $f.LastWriteTime.ToString('o'); tf = $f.FullName }; if (-not $st) { continue }
      if (-not $bg[$k]) { $bg[$k] = [ordered]@{ session = $k; n = 0; tok = 0L; cost = $null; roles = @{}; at = ''; ss = [Collections.Generic.List[object]]::new() } }; $g = $bg[$k]; $g.n++; $g.ss.Add($st); $g.tok += $st.tok; if ($null -ne $st.cost) { $g.cost = [double]$g.cost + $st.cost }
      $g.roles[$rl] = 1 + [int]$g.roles[$rl]; if ($st.at -gt $g.at) { $g.at = $st.at }; $steps.Add($st) }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # main sessions: the coordinator's own turns
    $u = & $read $f.FullName; $st = & $mkStep $u "$($u.model)" @{ label = "session $($f.BaseName)"; type = 'coordinator'; role = 'coordinator'; at = (& $atOf $u $f.FullName) }; if (-not $st -or -not $st.tok) { continue }
    $steps.Add($st); $coord.Add((& $withSplit ([pscustomobject]@{ session = $f.BaseName; model = $st.model; tok = $st.tok; cost = $(if ($null -ne $st.cost) { [math]::Round($st.cost, 2) }); min = $st.min; at = $st.at }) @($st))) }
  foreach ($k in @($cache.Keys)) { if (-not $seen[$k]) { $cache.Remove($k) } }   # older than $Days: dropped
  # one run = one row: a resumed run's folders merge (the newest folder's id and status, sums, MRs unique, items the max; resumed = older folders)
  $byRun = [ordered]@{}; foreach ($r in @($runs | Sort-Object { "$($_.started)" })) { $rk = "$($r.run)"; if (-not $byRun.Contains($rk)) { $byRun[$rk] = [Collections.Generic.List[object]]::new() }; $byRun[$rk].Add($r) }
  $runs = @(foreach ($grpRun in $byRun.Values) { if ($grpRun.Count -eq 1) { $grpRun[0]; continue }
      $nw = $grpRun[-1]; $ss = @($grpRun | ForEach-Object { $_.steps }); $sumOf = { param([string]$p) [long](@($grpRun | ForEach-Object { [double](Get-KitMember $_ $p) }) | Measure-Object -Sum).Sum }
      $mx = { param([string]$p) @($grpRun | ForEach-Object { "$(Get-KitMember $_ $p)" } | Sort-Object)[-1] }; $cs0 = @($grpRun | Where-Object { $null -ne $_.cost })
      & $withSplit ([pscustomobject]@{ run = $nw.run; id = $nw.id; ids = @($grpRun.id); resumed = $grpRun.Count - 1; label = $nw.label; qaName = $nw.qaName; tasks = @($grpRun.tasks | Where-Object { $_ } | Select-Object -Unique)
          mrAll = @($grpRun.mrAll | Where-Object { $_ } | Select-Object -Unique); kind = $nw.kind; started = $grpRun[0].started; status = $nw.status; state = $nw.state; lastAt = (& $mx lastAt)
          cap = [long](@($grpRun.cap) | Measure-Object -Maximum).Maximum; spent = [long](@($grpRun.spent) | Measure-Object -Maximum).Maximum; tok = (& $sumOf tok); cost = $(if ($cs0.Count) { [math]::Round(($cs0 | Measure-Object cost -Sum).Sum, 2) })
          wall = (& $sumOf wall); roles = (@($ss | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = (& $sumOf done); total = (& $sumOf total); merged = @($ss.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = [int](@($grpRun.items) | Measure-Object -Maximum).Maximum
          loop = (& $sumOf loop); at = (& $mx at); steps = $ss }) $ss })
  # avgMin / p90Min: a step's active time (model + tools + waiting) when its split is recorded, else its elapsed (wall clock: wallN steps)
  $grp = { param([string]$by, $ss = $steps) @($ss | Where-Object { (Get-KitMember $_ $by) -and $_.tok } | Group-Object $by | ForEach-Object { $g = @($_.Group); $tv = @($g | ForEach-Object { if ($null -ne $_.act) { $_.act } else { $_.min } } | Where-Object { $null -ne $_ }); [pscustomobject]@{ k = $_.Name; n = $g.Count; sum = [long]($g | Measure-Object tok -Sum).Sum; cost = $(if (@($g | Where-Object { $null -ne $_.cost }).Count) { [math]::Round((@($g | Where-Object { $null -ne $_.cost }) | Measure-Object cost -Sum).Sum, 2) }); avg = [long]($g | Measure-Object tok -Average).Average; p50 = (Get-KitPct $g.tok 0.5); p90 = (Get-KitPct $g.tok 0.9); avgMin = $(if ($tv.Count) { [math]::Round(($tv | Measure-Object -Average).Average, 1) }); p90Min = (Get-KitPct $tv 0.9); wallN = @($g | Where-Object { $null -eq $_.act -and $null -ne $_.min }).Count } | ForEach-Object { & $withSplit $_ $g } } | Sort-Object { -$_.avg * $_.n }) }
  $wf = @($steps | Where-Object run); $ended = @($wf | Where-Object result -in 'pass', 'empty', 'fail', 'stopped')   # stopped: ended with no result
  $hostMrs = Get-KitUsageHostMrs $since $Now $all.host
  $dayRows = @(foreach ($dk in $dayKeys) { $ds = @($steps | Where-Object { $_.dayc[$dk] }); $tk = 0L; $dc = [Collections.Generic.List[double]]::new(); $t8 = @(0) * 8
      foreach ($x in $ds) { $dv = @($x.dayc[$dk]); $tk += [long]$dv[0]; if ($null -ne $dv[1]) { $dc.Add([double]$dv[1]) }; $t8 = & $add $t8 @($dv | Select-Object -Skip 2) 8 }   # 4 tokens, 4 costs
      [pscustomobject]@{ day = $dk; tok = $tk; cost = $(if ($dc.Count) { [math]::Round(($dc | Measure-Object -Sum).Sum, 2) }); in = [long]$t8[0]; out = [long]$t8[1]; cr = [long]$t8[2]; cw = [long]$t8[3]; cs = $(if ($dc.Count) { @($t8[4..7] | ForEach-Object { [math]::Round($_, 4) }) }); runs = @($ds | Where-Object wid | ForEach-Object run | Select-Object -Unique).Count
        merged = $(if ($hostMrs) { @($hostMrs.mrs | Where-Object { "$($_.day)" -eq $dk }).Count } else { @(@($steps | Where-Object { "$($_.at)".StartsWith($dk) }).mrs | Where-Object { $_ } | Select-Object -Unique).Count }) } })
  $usageOut = [pscustomobject]@{ at = $Now.ToString('o'); since = $since.ToString('o'); partial = $script:KitUsagePartial; runs = @($runs | Sort-Object at -Descending); bg = @($bg.Values | ForEach-Object { & $withSplit ([pscustomobject]@{ session = $_.session; n = $_.n; tok = $_.tok; cost = $(if ($null -ne $_.cost) { [math]::Round($_.cost, 2) }); roles = (@($_.roles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ') }) $_.ss } | Sort-Object { -$_.tok })
    coord = @($coord | Sort-Object { -$_.tok }); modelCost = @($mcost.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = [math]::Round($_.Value, 2) } }); unpriced = @($unp.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ model = $_.Key; tok = $_.Value } })
    mrList = @(@(if ($hostMrs) { $hostMrs.mrs } else { foreach ($sx in $wf) { foreach ($mr in @($sx.mrs | Where-Object { $_ })) { @{ ref = "$mr"; day = $(try { ([datetimeoffset]"$($sx.at)").LocalDateTime.ToString('yyyy-MM-dd') } catch { '' }); lead = $null } } } }) | Sort-Object { "$($_.ref)" } -Unique)   # the Delivery repo x day map, lead times
    merged = $(if ($hostMrs) { [pscustomobject]@{ source = 'host'; user = $hostMrs.user; n = @($hostMrs.mrs).Count } } else { [pscustomobject]@{ source = 'workflows'; user = ''; n = @($wf.mrs | Where-Object { $_ } | Select-Object -Unique).Count } })
    byType = (& $grp type); byModel = (& $grp model)
    byRole = @(& $grp role | ForEach-Object { $rss = @($steps | Where-Object role -eq $_.k)   # the Spend view: a role row, its model mix and step types under it
        $_ | Add-Member -PassThru models @(& $grp model $rss | ForEach-Object { [pscustomobject]@{ k = $_.k; sum = $_.sum; cost = $_.cost } }) | Add-Member -PassThru types @(& $grp type $rss) })
    rates = [pscustomobject]@{ n = $ended.Count; empty = @($ended | Where-Object result -eq 'empty').Count; fail = @($ended | Where-Object result -eq 'fail').Count; stopped = @($ended | Where-Object result -eq 'stopped').Count; stuck = @($wf | Where-Object result -eq 'stuck').Count; running = @($wf | Where-Object result -eq 'running').Count }
    days = $dayRows
    agentSteps = @($steps | Where-Object { $_.type -eq 'agent' -and $_.tf } | Select-Object tf, label, role, model, tok, cost, in, out, cr, cw, cs, tm, act, min, hrs, at) }   # board-only rows: tokens by transcript
  # transcripts last written before today -> usage.cold.json, rewritten about once a day: one file rewrote 1 MB each sweep for a few live records
  $hot = [ordered]@{}; $cold = [ordered]@{}; foreach ($ck in @($cache.Keys | Sort-Object)) { if ([IO.File]::GetLastWriteTime($ck) -lt $Now.Date) { $cold[$ck] = $cache[$ck] } else { $hot[$ck] = $cache[$ck] } }
  try { Write-KitAtomic $cf (@{ files = $hot; host = $hostMrs } | ConvertTo-Json -Depth 7 -Compress); Write-KitAtomic $cfCold (@{ files = $cold } | ConvertTo-Json -Depth 7 -Compress); Write-KitAtomic ($cf -replace '\.json$', '.result.json') ($usageOut | ConvertTo-Json -Depth 10 -Compress) -Volatile '^\{"at":"[^"]*","since":"[^"]*"' } catch {}
  $usageOut
  } finally { $lkh.Dispose(); Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }
}
# the last budget -Usage result (the page, a run that finds the lock taken)
function Read-KitUsageResult { try { Read-KitText ((Get-KitPath usage-cache) -replace '\.json$', '.result.json') | ConvertFrom-Json -Depth 12 } catch { $null } }
# the page's usage parts (budget -Usage result) for Trends: tiles (review share, step outcomes, tokens per MR), the day rows (cost,
# tokens), the spend heatmap; pages (run id -> its step table, linked from the Runs band)
# called by Format-KitSuperviseHtml: its helpers ($e $n1 $grid $table $bar $trend $at) by dynamic scope
function Format-KitUsageHtml($U) {
  if (-not $U -or -not @($U.days).Count) { return [pscustomobject]@{ runsN = $null; tiles = ''; dayRows = @(); spend = '<p class=empty>No usage yet: bossy.ps1 budget -Usage runs each sweep.</p>'; pages = @{} } }
  $tk = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 1e9) { "$(& $n1 ([math]::Round([double]$v / 1e9, 2)))B" } elseif ([double]$v -ge 1e6) { "$(& $n1 ([double]$v / 1e6))M" } elseif ([double]$v -ge 1e3) { "$([math]::Round([double]$v / 1e3))k" } else { "$([long]$v)" } }
  $usd = { param($v) if ($null -eq $v) { '—' } else { '$' + ([double]$v).ToString($(if ([double]$v -ge 1000) { '#,0' } else { '0.00' }), [cultureinfo]::InvariantCulture) } }
  $mn = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 90) { "$(& $n1 ([double]$v / 60)) h" } else { "$(& $n1 $v) min" } }
  $dy = @($U.days | Where-Object { $_ }); $td = $dy[-1]; $prev = @($dy | Select-Object -SkipLast 1)
  $avg = { param([string]$k) $vs = @($prev | ForEach-Object { (Get-KitMember $_ $k) } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Average).Average } }
  $sum = { param([string]$k) $vs = @($dy | ForEach-Object { (Get-KitMember $_ $k) } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Sum).Sum } }
  $runs = @($U.runs | Where-Object { $_ }); $wfTok = [double](($runs | Measure-Object tok -Sum).Sum); $loop = [double](($runs | Measure-Object loop -Sum).Sum)
  $merged = [int](($runs | Measure-Object merged -Sum).Sum); $items = [int](($runs | Measure-Object items -Sum).Sum); $rt = $U.rates;
  $allTok = [double](& $sum 'tok'); $hm = $U.merged; $onHost = $hm.source -eq 'host'; $unp = @($U.unpriced | Where-Object { $_ })
  $card = { param([string]$label, [string]$v, [string]$sub, [string]$w, [string]$cls = '') "<div class='st $cls' data-fit><div class=k>$(& $e $label)</div><div class=v>$v</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })$(if ($w) { "<div class=w>$(& $e $w)</div>" })</div>" }
  $pct = { param($a, $b) if ([double]$b) { [math]::Round(100 * [double]$a / [double]$b) } }
  # step outcomes (pass, empty, failed, stopped, running, stuck): a tile each, the zero ones left out
  $oc = @(@(@('pass', ([double]$rt.n - $rt.empty - $rt.fail - $rt.stopped), 'sage', 'pass'), @('empty', $rt.empty, 'watch', 'empty'), @('failed', $rt.fail, 'act', 'fail'), @('stopped', $rt.stopped, 'slate', 'stopped'), @('running', $rt.running, 'mt', 'running'), @('stuck', $rt.stuck, 'plum', 'stuck')) | Where-Object { [double]$_[1] -gt 0 })
  # one tile row (owner 2026-11-19: tiles, not cards): the review + fix share, then a tile per step outcome; an outcome tile is a button: it
  # shows only the runs with a step in that outcome (page JS + .ocf CSS), a second click shows all
  $shareP = if ($wfTok) { & $pct $loop $wfTok }; $shareW = $wfTok -and $loop / $wfTok -gt 0.5
  $uTiles = "<div class='tl$(if ($shareW) { ' watch' })' data-mk=review-share title='review + fix share: the review and fix steps' share of the workflow tokens (warn over 50%)'><b>$(if ($null -ne $shareP) { "$(& $n1 $shareP)<small>%</small>" } else { '—' })</b><span>review + fix share</span></div>" +
    "$(@($oc | ForEach-Object { "<button type=button class='tl ocb' data-oc=$($_[3]) aria-pressed=false title='$($_[0]) steps: show the runs with one'><b>$([int]$_[1])</b><span><i style='background:var(--$($_[2]))'></i>$($_[0]) steps</span></button>" }) -join '')"
  # tokens per merged MR: a Delivery tile, the value and its base (no sparkline: the day values are the Per day heatmap's tokens row)
  # split (owner 2026-11-20): the value = output tokens per MR, the tooltip every type and its cost per MR
  $perMr = { param($base, [double]$n) if (-not $n) { return $null }; $c4 = @($base.cs); [pscustomobject]@{ tok = [double]$base.tok / $n; in = [double]$base.in / $n; out = [double]$base.out / $n; cr = [double]$base.cr / $n; cw = [double]$base.cw / $n; cs = $(if ($null -ne $base.cs) { @($c4 | ForEach-Object { [double]$_ / $n }) }) } }
  $s7 = { param($xs) $c = $null; foreach ($x in @($xs | Where-Object { $null -ne $_.cs })) { $c = @(for ($i = 0; $i -lt 4; $i++) { [double]@($c)[$i] + [double]@($x.cs)[$i] }) }
    [pscustomobject]@{ tok = [double](($xs | Measure-Object tok -Sum).Sum); in = [double](($xs | Measure-Object in -Sum).Sum); out = [double](($xs | Measure-Object out -Sum).Sum); cr = [double](($xs | Measure-Object cr -Sum).Sum); cw = [double](($xs | Measure-Object cw -Sum).Sum); cs = $c } }
  $tpmT = { param([string]$l, $o, [string]$tip) "<div class=tl data-mk=tokens-per-mr title='$(& $e "${l}: $tip$(if ($o) { "`n$(Get-KitSplitTip $o 'per MR:')" })")'><b>$(if ($o) { "$(& $tk $o.out)<small>out</small>" } else { '—' })</b><span>$(& $e $l)</span></div>" }
  $tpm = if ($onHost) { $hn = [int]$hm.n; & $tpmT 'tokens per merged MR' (& $perMr (& $s7 $dy) $hn) "$hn MR(s) merged on the git host by $($hm.user) · $merged by workflows · $items item(s), 7 days" }
    else { & $tpmT 'tokens per workflow MR' (& $perMr (& $s7 $runs) $merged) "$merged MR(s) merged by workflows (no git-host login) · $items item(s), 7 days" }
  # Spend (owner 2026-11-19, D2): a heatmap, roles x metrics (each column shaded by its peak), the 3 biggest models' share of a role's
  # tokens as 3 cells; its step types in the role's tooltip
  $roles = @($U.byRole | Where-Object { $_ } | Sort-Object { -[double]$_.sum }); $rAll = [double](($roles | Measure-Object sum -Sum).Sum)
  $mdl = @($U.byModel | Where-Object { $_ } | Sort-Object { -[double]$_.sum } | Select-Object -First 3); $mShort = { param($k) "$k" -replace '^claude-' }
  $spRows = @($roles | ForEach-Object { $r0 = $_; $mt = [double](@($_.models | Where-Object { $_ }) | Measure-Object sum -Sum).Sum; $msh = @($mdl | ForEach-Object { $mk = "$($_.k)"; $ms = [double](@($r0.models | Where-Object { "$($_.k)" -eq $mk }) | Measure-Object sum -Sum).Sum; if ($mt) { [math]::Round(100 * $ms / $mt) } else { 0 } })
      # merged (owner 2026-11-20): tokens + est. cost = one split cell; avg time split by model / tools / waiting over the steps that have it
      $tok0 = [pscustomobject]@{ tok = $_.sum; cost = $_.cost; in = $_.in; out = $_.out; cr = $_.cr; cw = $_.cw; cs = $_.cs }
      # the cell: tiles + total over the steps with a split (the total = their sum); none: the avg wall clock
      $tim0 = [pscustomobject]@{ min = $(if (-not [int]$_.tmN) { $_.avgMin }); tm = $(if ([int]$_.tmN) { @(@($_.tm) | ForEach-Object { [double]$_ / [int]$r0.tmN }) }); tmN = 1 }
      @{ n = "$($_.k)"; title = "$($_.k): $(@($_.types | Where-Object { $_ } | ForEach-Object { "$($_.k) $($_.n) steps, avg $(& $tk $_.avg)" }) -join ' · ')"; v = @([double]$_.n, [double]$_.sum, $(if ($rAll) { 100 * [double]$_.sum / $rAll } else { 0 }), [double]$_.avgMin, [double]$_.p90Min) + @($msh | ForEach-Object { [double]$_ })
        sk = @('', 'tc', '', 'time', ''); so = @($null, $tok0, $null, $tim0, $null); tips = @('', '', '', "$(& $mn $_.avgMin), avg of $($_.n) steps: active time$(if ([int]$_.wallN) { ", wall clock for the $($_.wallN) without a split" })$(if ([int]$_.tmN) { "; the cell: the $($_.tmN) with one`n$(Get-KitSplitTip ([pscustomobject]@{ tm = $tim0.tm }))" })", "$(& $mn $_.p90Min), p90 of $($_.n) steps (active time$(if ([int]$_.wallN) { "; wall clock for $($_.wallN)" }))")
        tx = @("$($_.n)", (& $tk $_.sum), "$(& $pct $_.sum $rAll)%", (& $mn $_.avgMin), (& $mn $_.p90Min)) + @($msh | ForEach-Object { if ($_) { "$_%" } else { '' } }) } })
  $top = $roles | Select-Object -First 1   # folded (owner 2026-11-19): the top role in its header (the 7-day cost is a Trends tile)
  $spend = & $fold 'u-spend' 'Spend per role' $roles.Count -tag h4 -cls 'sub st uc ur' -extra "$(if ($top) { "<span class=fsm>top: $(& $e $top.k), $(& $pct $top.sum $rAll)% of the tokens</span>" })" -inner "$(Format-KitMetricHeat $spRows (@('steps', 'tokens · est. cost', 'share', 'avg time', 'P90 time') + @($mdl | ForEach-Object { & $mShort $_.k })) 'role · metric' 'spend-role')$(Format-KitLegend "shade = column peak · last $($mdl.Count) = model share$(if ($unp.Count) { ' · some not priced' })" "a column shaded by its peak (a split cell: each tile by its type's peak, named in the column head) · time = active (model + tools + waiting), wall clock where no split is recorded · the last $($mdl.Count) = each model's share of the role's tokens · hover a role for its step types$(if ($unp.Count) { " · not priced: $(@($unp | ForEach-Object { "$($_.model) $(& $tk $_.tok)" }) -join ', ')" })")"
  $stepRows = { param($ss) @($ss | ForEach-Object { $tip = Get-KitSplitTip $_ "$($_.label)"; , @($_.label, $_.role, ("$($_.model)" -replace '^claude-'), @{ h = Format-KitSplitCell $_ 'tc' $tip }, @{ h = Format-KitSplitCell $_ 'time' (Get-KitSplitTip ($_ | Select-Object tm, tmN, min)) }, $_.tools, @{ h = "<span class='chip $(switch ($_.result) { 'pass' { 's-act' } 'running' { 's-fin' } 'stuck' { 's-stuck' } 'fail' { 's-stuck' } default { 's-oth' } })'>$(& $e $_.result)</span>" }, "$($_.round)$(if ($_.retry) { " · retry $($_.retry)" })") }) }
  # a run: its human label (mandate / area, the run id in the tooltip), kind chip, resumed, outcome-split step bar; budget bar while running or over 80%
  $kindOf = { param($r) if ($r.kind) { "$($r.kind)" } elseif ("$($r.roles)" -match '^(kitty \d+( · )?)+$') { 'kit' } elseif ("$($r.roles)" -match 'checky') { 'test' } else { 'build' } }
  $resumed = @{}; foreach ($r in $runs) { if ([int]$r.resumed) { $resumed["$($r.id)"] = 1 } }   # Get-KitUsage merged its folders
  # steps by outcome in one bar (pass, empty, failed, running, stuck, stopped), each part titled with its count
  $segBar = { param($r) $tot = [math]::Max(1, [int]$r.total); $ps = @(foreach ($o in @(@('pass', 'sage'), @('empty', 'watch'), @('fail', 'act'), @('running', 'slate'), @('stuck', 'plum'), @('stopped', 'mt'))) { $n = @($r.steps | Where-Object result -eq $o[0]).Count; if ($n) { [pscustomobject]@{ k = $o[0]; c = $o[1]; n = $n } } })
    "<span class='bar sb3' title='$(& $e (@($ps | ForEach-Object { "$($_.k) $($_.n)" }) -join ' · '))'>$(@($ps | ForEach-Object { "<i class=$($_.c) style='width:$(& $n1 (100 * $_.n / $tot))%'></i>" }) -join '')</span><span class=bl>$($r.done)/$($r.total) steps</span>" }
  $lbOf = { param($r) if ("$($r.label)".Trim()) { $r.label } else { $r.run } }
  $pageOf = { param($r) "supervise-runs/$([Uri]::EscapeDataString("$($r.id)")).html" }   # Write-KitSuperviseHtml writes $Pages next to the page
  $head = { param($r) $bp = if ($r.cap) { [double]$r.spent / [double]$r.cap } else { 0 }
    "<span class=gn0 title='$(& $e "$($r.run) · $($r.id)")'>$(& $e (& $lbOf $r))</span><span class='chip k-$(& $e (& $kindOf $r))'>$(& $e (& $kindOf $r))</span>$(if ($resumed["$($r.id)"]) { "<span class='chip s-oth'>resumed</span>" })$(if ($r.status -eq 'running') { "<span class='chip s-act'>running</span>" })$(& $segBar $r)" +
    "$(Format-KitSplitCell $r 'tc' (Get-KitSplitTip $r))$(Format-KitSplitCell $r 'time' (Get-KitSplitTip ($r | Select-Object tm, tmN, tmAll, wall)))$(if ([int]$r.merged) { "<span class='chip s-act'>$($r.merged) merged</span>" })$(if ($r.cap -and ($r.status -eq 'running' -or $bp -ge 0.8)) { & $bar ([double]$r.spent) ([double]$r.cap) "budget $(& $tk $r.spent) of $(& $tk $r.cap)" $(if ($bp -ge 0.8) { 'watch' }) })" }   # budget = context spend (budget -Run), not billed tokens
  # what an ended run did, never a bare "failed" (owner, 2026-11-16): a test run's QA checks (task index), MRs merged, then the workflow's own
  # steps that errored (failed, empty, stopped, stuck: named in the tooltip)
  $ix = @(Read-KitJsonFiles (Get-KitPath tasks) | Where-Object { $_.envRuns })
  $resOf = { param($r) $out = [Collections.Generic.List[string]]::new()
    if ((& $kindOf $r) -eq 'test') { $q = if (Get-Command Get-KitRunQa -ErrorAction SilentlyContinue) { Get-KitRunQa $r $ix }   # adapters/outcomes.ps1
      if ($q) { $out.Add("<span class='chip $(if ($q.fail) { 's-stuck' } elseif ($q.nt) { 's-oth' } else { 's-act' })' data-tip='$(& $e "tasks: $($q.closed.Count) closed · $($q.failed.Count) failed testing · $($q.untested.Count) untested")'>checks: $($q.pass) pass · $($q.fail) fail$(if ($q.nt) { " · $($q.nt) not tested" })</span>") }
      else { $out.Add("<span class='chip s-oth'>no QA result recorded</span>") } }
    if ([int]$r.merged) { $out.Add("<span class='chip s-act'>$($r.merged) MR(s) merged</span>") }
    $bad = @($r.steps | Where-Object { $_.result -in 'fail', 'empty', 'stopped', 'stuck' })
    if ($bad.Count) { $out.Add("<span class='chip s-oth' data-tip='$(& $e (@($bad | ForEach-Object { "$($_.label): $($_.result)" }) -join "`n"))'>$($bad.Count) step(s) errored</span>") }
    $out -join '' }
  # a run's tasks and MRs, linked through the tracker and git host adapters (text: the id / repo!n)
  $linksOf = { param($r) $ts = @($r.tasks | Where-Object { $_ }); $ms = @(@($r.mrAll) + @($r.steps.mrs) | Where-Object { $_ } | ForEach-Object { $l = Get-KitMrLink $_; if ($l.url) { $l.url } else { $l.text } } | Select-Object -Unique)
    if (-not ($ts.Count + $ms.Count)) { return '' }; "<span class=lks>$(@(@($ts | ForEach-Object { & $taskA $_ }) + @($ms | ForEach-Object { & $mrA $_ })) -join ' ')</span>" }
  # dev and QA runs: a steps page per running run and the newest 25 ended ones (the Runs band links them)
  $devRuns = @($runs | Where-Object { (& $kindOf $_) -ne 'kit' })
  $dayOf = { param($r) try { ([datetimeoffset]"$(if ($r.started) { $r.started } else { $r.at })").LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } }
  $shown = @($devRuns | Where-Object status -ne 'running' | Sort-Object { "$($_.at)" } -Descending | Select-Object -First 25)   # newest 25 ended: the page stays light
  # a run page per shown run: its tasks and MRs, the QA / merge / error chips, its step table (Write-KitSuperviseHtml writes them)
  $pages = [ordered]@{}; foreach ($r in @(@($devRuns | Where-Object status -eq 'running') + $shown)) { $pages["$($r.id)"] = "<div class='ru'><div class=rh>$(& $head $r)$(if ($r.status -ne 'running') { & $resOf $r })</div></div>" +
      "$(if ($lk = & $linksOf $r) { "<p class=rpl>Tasks and MRs: $lk</p>" })<div class='sy rst'>$((& $table 'Step', 'Role', '~Model', 'Tokens · cost', 'Time', '~Tools', 'Result', '~Round' (& $stepRows @($r.steps | Sort-Object { -$_.tok }))) -replace "<tr class='f more'>", '<tr class=f>' -replace '<button type=button class=sa[^>]*>[^<]*</button>')</div>$(Format-KitLegend (Format-KitSplitLegend) 'tokens · cost: a tile per type (its cost below) and the total · time: model, tools, waiting (active) and the total = elapsed (wall clock) · hover a cell for every type')" +
      "<p class=m>Review findings and QA detail: <code>bossy.ps1 report -Run $(& $e $r.run) -Detail</code></p>" }
  # Per day (owner 2026-11-19: a time series = the day heatmap): est. cost and tokens per day, the 7-day sum on the right, the average in
  # the row tooltip; runs and MRs per day: the Delivery heatmap
  $byDay = @{}; foreach ($r in $devRuns) { $dk = & $dayOf $r; if ($dk) { $byDay[$dk] = @(@($byDay[$dk] | Where-Object { $_ }) + $r) } }
  $cAvg = & $avg 'cost'; $tAvg = & $avg 'tok'; $ud = @($dy | ForEach-Object { "$($_.day)" })
  # at the bottom of Trends, a rule above (owner 2026-11-21)
  $uRows = @(@{ n = 'Est. cost'; mk = 'cost-day'; gl = $true; title = "est. cost per day (budget.prices); 7 d: sum$(if ($null -ne $cAvg) { " · avg of the 6 days before today $(& $usd $cAvg)" })"; v = @($dy | ForEach-Object { if ($null -eq $_.cost) { $null } else { [double]$_.cost } }); fmt = { param($v) '$' + [math]::Round([double]$v) }; t = (& $usd (& $sum 'cost')); cls = 'ws'; keep = $true; sk = 'cost'; so = $dy; tips = @($dy | ForEach-Object { "`n$(Get-KitSplitTip $_)" }) },
    @{ n = 'tokens'; mk = 'tokens-day'; title = "tokens per day, all agents; 7 d: sum$(if ($null -ne $tAvg) { " · avg of the 6 days before today $(& $tk $tAvg)" })"; v = @($dy | ForEach-Object { if ($null -eq $_.tok) { $null } else { [double]$_.tok } }); fmt = $tk; t = (& $tk (& $sum 'tok')); keep = $true; sk = 'tokens'; so = $dy; tips = @($dy | ForEach-Object { "`n$(Get-KitSplitTip $_)" }) })
  foreach ($dr in $uRows) { $dr.d = $ud }   # Trends aligns the rows by date
  $nRunning = @($devRuns | Where-Object status -eq 'running').Count
  [pscustomobject]@{ runsN = $(if ($shown.Count) { "$($devRuns.Count - $nRunning) ended in 7 days" } else { 0 }); nRunning = $nRunning; tpm = $tpm
    dayRuns = $byDay; days = $dy; mrs = @($U.mrList | Where-Object { $_ })
    tiles = $uTiles; dayRows = $uRows; spend = $spend
    pages = $pages
    usageN = "$(& $tk $td.tok) tokens today" }
}
# ---- split: tokens, cost and time by type in one stacked form (owner 2026-11-20: a single "tokens" number misleads, 96% are cache reads)
# parts of $O (a step, run, role or day: in, out, cr, cw, cs = [in, out, cache read, cache write] USD, tm = minutes [model, build, ci, browser,
# other tool, waiting], min = elapsed): p4 = the wide parts, p2 = the narrow ones (work / cache, model / tools + waiting); ok = data recorded
function Get-KitSplitParts($O, [string]$Kind) {
  $p = { param($k, $l, $v) [pscustomobject]@{ k = $k; l = $l; v = $(if ($null -ne $v) { [double]$v }); c = $null } }
  if ($Kind -eq 'tc') { $t0 = Get-KitSplitParts $O 'tokens'; $c0 = Get-KitSplitParts $O 'cost'   # tokens + cost merged: a part = its tokens and its $
    if ($c0.ok -and $t0.ok) { for ($i = 0; $i -lt 4; $i++) { $t0.p4[$i].c = $c0.p4[$i].v }; for ($i = 0; $i -lt 2; $i++) { $t0.p2[$i].c = $c0.p2[$i].v } }; return $t0 }
  if ($Kind -eq 'time') { $t = @($O.tm); if ($null -eq $O.tm -or $t.Count -lt 6) { return [pscustomobject]@{ ok = $false; p4 = @(); p2 = @() } }
    $tl = [double]$t[1] + [double]$t[2] + [double]$t[3] + [double]$t[4]
    return [pscustomobject]@{ ok = $true; p4 = @((& $p mo model $t[0]), (& $p to tools $tl), (& $p wa waiting $t[5])); p2 = @((& $p mo model $t[0]), (& $p tw 'tools + waiting' ($tl + [double]$t[5]))) } }
  $v = if ($Kind -eq 'cost') { $c = @($O.cs); if ($null -eq $O.cs -or $c.Count -lt 4) { return [pscustomobject]@{ ok = $false; p4 = @(); p2 = @() } }; @($c[1], $c[0], $c[3], $c[2]) } elseif ($null -eq $O.out -and $null -eq $O.cr) { return [pscustomobject]@{ ok = $false; p4 = @(); p2 = @() } } else { @($O.out, $O.in, $O.cw, $O.cr) }
  [pscustomobject]@{ ok = $true; p4 = @((& $p out output $v[0]), (& $p in 'fresh in' $v[1]), (& $p cw 'cache write' $v[2]), (& $p cr 'cache read' $v[3]))
    p2 = @((& $p wk 'work (output + fresh in)' ([double]$v[0] + [double]$v[1])), (& $p ca 'cache (write + read)' ([double]$v[2] + [double]$v[3]))) }
}
function Format-KitSplitNum($V, [string]$Kind) {
  if ($null -eq $V) { return '—' }; $d = [double]$V
  switch ($Kind) { 'cost' { if ($d -gt 0 -and $d -lt 0.005) { '<$0.01' } else { '$' + $d.ToString($(if ($d -ge 1000) { '#,0' } else { '0.00' }), [cultureinfo]::InvariantCulture) } }
    'time' { if ($d -ge 90) { "$(([math]::Round($d / 60, 1)).ToString('0.#', [cultureinfo]::InvariantCulture)) h" } else { "$([math]::Round($d)) min" } }
    default { if ($d -le 0) { '0' } else { Format-KitCompactNum $d } } }
}
# the shared tooltip: tokens + cost per type and their totals, then the time split (minutes per part, the tools' kinds) or "split not recorded"
function Get-KitSplitTip($O, [string]$Head = '') {
  $tk = Get-KitSplitParts $O 'tokens'; $cs = Get-KitSplitParts $O 'cost'; $cn = { param($i) if ($cs.ok) { " · $(Format-KitSplitNum $cs.p4[$i].v cost)" } }
  $ls = [Collections.Generic.List[string]]::new(); if ($Head) { $ls.Add($Head) }
  if ($null -ne $O.tok -or $null -ne $O.out) { if ($tk.ok) { for ($i = 0; $i -lt 4; $i++) { $ls.Add("$($tk.p4[$i].l) $(Format-KitSplitNum $tk.p4[$i].v tokens)$(& $cn $i)") } } else { $ls.Add('token split not recorded') }
    $ls.Add("total $(Format-KitSplitNum $(if ($tk.ok) { ($tk.p4 | Measure-Object v -Sum).Sum } else { $O.tok }) tokens) tokens$(if ($cs.ok) { " · $(Format-KitSplitNum (($cs.p4 | Measure-Object v -Sum).Sum) cost)" } elseif ($null -ne $O.cost) { " · $(Format-KitSplitNum $O.cost cost)" } else { ' · not priced' })") }
  $tm = Get-KitSplitParts $O 'time'; $t = @($O.tm); $el = if ($null -ne $O.wall) { $O.wall } else { $O.min }
  if ($tm.ok) { $ls.Add("model $(Format-KitSplitNum $t[0] time) · tools $(Format-KitSplitNum $tm.p4[1].v time) (builds + tests $(Format-KitSplitNum $t[1] time), CI $(Format-KitSplitNum $t[2] time), browser / QA $(Format-KitSplitNum $t[3] time), other $(Format-KitSplitNum $t[4] time)) · waiting $(Format-KitSplitNum $t[5] time) (gate queue, leases, questions, monitors)")
    if ($null -ne $el) { $ls.Add("elapsed $(Format-KitSplitNum $el time)$(if ([int]$O.tmN -gt 1) { "; the split adds up the agent minutes of $($O.tmN) steps (parallel)" } else { '; the rest: idle between turns' })") } }
  elseif ($null -ne $el) { $ls.Add("elapsed $(Format-KitSplitNum $el time) · time split not recorded$(if ([int]$O.tmAll -gt 0 -and [int]$O.tmN -lt [int]$O.tmAll) { ": $([int]$O.tmN) of $($O.tmAll) steps have one (a transcript read before the split was recorded stays without; new steps get it)" })") }
  $ls -join "`n"
}
# the total part of a split (key tot): the parts' sum (and their cost); time: the elapsed minutes when known
function Get-KitSplitTotal($O, [string]$Kind, $Sp) {
  $sum = [double](@($Sp.p4 | ForEach-Object { [double]$_.v }) + 0 | Measure-Object -Sum).Sum; $el = if ($null -ne $O.wall) { $O.wall } else { $O.min }
  $cs = @($Sp.p4 | Where-Object { $null -ne $_.c }); $c = if ($cs.Count) { [double]($cs | Measure-Object c -Sum).Sum }
  if ($Kind -eq 'time' -and $null -ne $el) { [pscustomobject]@{ k = 'tot'; l = 'elapsed'; v = [double]$el; c = $null } } else { [pscustomobject]@{ k = 'tot'; l = 'total'; v = $sum; c = $c } }
}
# one split cell = a row of small tiles, one per part (tinted by type, the value on top, its cost below) + the total; the cell's own width
# picks the form (CSS container query): wide p4 + total, medium p2 + total, narrow the total over a 4-part bar; -Heat: a heatmap cell
# (each tile shaded by $Peaks[<part key>], the row's or column's peak); no split data = the total and "split not recorded"
function Format-KitSplitCell($O, [string]$Kind, [string]$Tip, $Peaks = $null, [switch]$Heat, [bool]$Now = $false) {
  $enc = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; $sp = Get-KitSplitParts $O $Kind
  $nk = if ($Kind -eq 'tc') { 'tokens' } else { $Kind }
  if (-not $sp.ok) { $tot = switch ($Kind) { 'cost' { $O.cost } 'time' { if ($null -ne $O.wall) { $O.wall } else { $O.min } } default { $O.tok } }
    $tx = if ($null -eq $tot) { '—' } else { "$(Format-KitSplitNum $tot $nk)$(if ($Kind -eq 'tc' -and $null -ne $O.cost) { " $(Format-KitSplitNum $O.cost cost)" })" }; $nr = if ($null -ne $tot) { "<small class=knr>$(if ($Kind -eq 'cost') { 'not split' } elseif ($Kind -eq 'time' -and [int]$O.tmN -gt 0 -and [int]$O.tmN -lt [int]$O.tmAll) { "split: $([int]$O.tmN) of $($O.tmAll) steps" } elseif ($Kind -eq 'time') { 'wall clock' } else { 'split not recorded' })</small>" }
    if ($Heat) { return "<i class='kst k0$(if ($Now) { ' nw' })' title='$(& $enc $Tip)'><b>$(& $enc $tx)</b>$nr</i>" }; return "<span class='gc ks kd-$Kind k0' title='$(& $enc $Tip)'><b>$(& $enc $tx)</b>$nr</span>" }
  $tt = Get-KitSplitTotal $O $Kind $sp
  $tile = { param($pt, [string]$cl) $sh = if ($Heat) { if ($Peaks -and [double]$Peaks[$pt.k] -gt 0 -and [double]$pt.v -gt 0) { Get-KitHeatShade ([double]$pt.v / [double]$Peaks[$pt.k]) } else { 0 } }
    $vx = if ([double]$pt.v -le 0) { '0' } else { Format-KitSplitNum $pt.v $nk }
    "<b class='kq k-$($pt.k) $cl'$(if ($Heat) { " style='--a:$sh%'" })>$(& $enc $vx)$(if ($null -ne $pt.c) { "<small>$(& $enc (Format-KitSplitNum $pt.c cost))</small>" })</b>" }
  $vs = [double](@($sp.p4 | ForEach-Object { [double]$_.v }) + 0 | Measure-Object -Sum).Sum
  $bar = "<span class=kb aria-hidden=true>$(@($sp.p4 | Where-Object { [double]$_.v -gt 0 } | ForEach-Object { "<i class='k-$($_.k)' style='flex-grow:$([math]::Round(1000 * [double]$_.v / [math]::Max(1e-9, $vs)))'></i>" }) -join '')</span>"
  $body = "<span class=kr4>$(@($sp.p4 | ForEach-Object { & $tile $_ k4 }) -join '')$(@($sp.p2 | ForEach-Object { & $tile $_ k2 }) -join '')$(& $tile $tt kt)</span>$bar"
  if ($Heat) { "<i class='kst kd-$Kind$(if ($Now) { ' nw' })' title='$(& $enc $Tip)'>$body</i>" } else { "<span class='gc ks kd-$Kind' title='$(& $enc $Tip)'>$body</span>" }
}
# per part key (and tot), the peak over $Objs (a heat row's or column's shading)
function Get-KitSplitPeaks($Objs, [string]$Kind) { $pk = @{}; foreach ($o in @($Objs | Where-Object { $_ })) { $sp = Get-KitSplitParts $o $Kind; if (-not $sp.ok) { continue }; foreach ($pt in @($sp.p4) + @($sp.p2) + @(Get-KitSplitTotal $o $Kind $sp)) { if ([double]$pt.v -gt [double]$pk[$pt.k]) { $pk[$pt.k] = [double]$pt.v } } }; $pk }
# the legend line of every split (one colour per type)
function Format-KitSplitLegend {
  $sw = { param($k, $l) "<i class='lgk k-$k'></i>$l" }
  "<span class=kleg>$(& $sw out output) $(& $sw in fresh) $(& $sw cw 'cache write') $(& $sw cr 'cache read') $(& $sw tot total) · $(& $sw mo model) $(& $sw to tools) $(& $sw wa waiting)</span>"
}
# a split column's sub-header (owner 2026-11-20: tiles need names): the cell's tile row with names, same widths and container query as the cells
function Format-KitSplitHead([string]$Kind) {
  $nm = if ($Kind -eq 'time') { @(@('mo', 'Model', 'k4'), @('to', 'Tools', 'k4'), @('wa', 'Wait', 'k4'), @('mo', 'Model', 'k2'), @('tw', 'Tools+wait', 'k2')) } else { @(@('out', 'Out', 'k4'), @('in', 'Fresh', 'k4'), @('cw', 'C-write', 'k4'), @('cr', 'C-read', 'k4'), @('wk', 'Work', 'k2'), @('ca', 'Cache', 'k2')) }
  "<span class='kst kh kd-$Kind'><span class=kr4>$(@($nm | ForEach-Object { "<b class='kq k-$($_[0]) $($_[2])'>$($_[1])</b>" }) -join '')<b class='kq k-tot kt'>Total</b></span></span>"
}
# every legend (owner 2026-11-20): one short line of swatches and 1-2 word keys; the explanation only in an (i) tooltip
function Format-KitLegend([string]$Keys, [string]$Info = '') {
  $enc = [Net.WebUtility]::HtmlEncode($Info)
  "<div class=hk>$Keys$(if ($Info) { " <span class=hki tabindex=0 role=note title='$enc' aria-label='$enc'>&#9432;</span>" })</div>"
}

# ---- budget: a tool + model's token budget (compaction point), its handoff and run-stop fractions (README "Configuration")
function Get-KitBudget([string]$Tool = '', [string]$Model = '', [int]$Window = 0) {
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget
  $row = { param($n) $o = Get-KitSetting "budget.defaults.$n" $null; if ($o) { $o } else { (Get-KitMember $ex.defaults $n) } }
  $envs = @(Get-ChildItem env: | ForEach-Object Name)
  if (-not $Tool) {
    $Tool = if ($Model -match '^(claude|opus|sonnet|haiku)') { 'claude' }
    elseif ($Model -match '^gpt') { 'codex' }
    elseif ($Model -match '^gemini') { 'antigravity' }
    elseif ($v = $env:KIT_TOOL) { $v }
    elseif ($env:CLAUDECODE) { 'claude' }
    elseif ($envs -like 'CODEX_*') { 'codex' }
    elseif ($envs -match 'ANTIGRAVITY') { 'antigravity' }
    else { 'unknown' }
  }
  $n = 'unknown'; $tok = 0; $src = ''
  if ($Tool -eq 'claude') {
    if (-not $Model) { $Model = "$env:ANTHROPIC_MODEL" }
    $m = $Model.ToLower(); $big = $m -match '\[1m\]|fable|^(opus|sonnet|haiku|inherit|default)?$'
    if ($m -match '(opus|sonnet|haiku)-(\d+)(?:-(\d)(?!\d))?') { $big = $big -or ([double]$Matches[2] + [double]"0$($Matches[3])" / 10) -ge @{ opus = 4.7; sonnet = 5; haiku = 5.5 }[$Matches[1]] }
    if ($big -or $m -match 'claude|opus|sonnet|haiku') {
      if ($env:CLAUDE_CODE_DISABLE_1M_CONTEXT -eq '1') { $big = $false }
      $n = if ($big) { 'claude-1m' } else { 'claude-200k' }; $tok = [int](& $row $n).tokens
      if ($v = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $tok = [int]$v; $src = 'env CLAUDE_CODE_AUTO_COMPACT_WINDOW' }
      if ($v = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE) { $tok = [math]::Min($tok, [int]($(if ($big) { 1e6 } else { 2e5 }) * [double]$v / 100)); $src = 'env CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' }
    }
  } elseif ($Tool -eq 'codex') {
    $ch = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $tt = "$(Get-Content (Join-Path $ch 'config.toml') -Raw -ErrorAction SilentlyContinue)"
    if (-not $Model -and $tt -match '(?m)^\s*model\s*=\s*"([^"]+)"') { $Model = $Matches[1] }
    $mc = try { @((Get-Content (Join-Path $ch 'models_cache.json') -Raw | ConvertFrom-Json).models | Where-Object slug -eq $Model)[0] } catch { $null }
    $n = 'codex'
    if ($tt -match '(?m)^\s*model_auto_compact_token_limit\s*=\s*(\d+)') { $tok = [int]$Matches[1]; $src = 'config.toml model_auto_compact_token_limit' }
    elseif ($v = $mc.auto_compact_token_limit) { $tok = [int]$v; $src = 'models_cache.json auto_compact_token_limit' }
    else {
      $w = if ($v = $mc.context_window) { [double]$v * $(if ($q = $mc.effective_context_window_percent) { [double]$q } else { 100 }) / 100 } else { $Window }
      $tok = [int]($w * [double](& $row $n).fraction)
    }
  } elseif ($Tool -eq 'antigravity' -and $Window) { $n = 'antigravity'; $tok = [int]($Window * [double](& $row $n).fraction) }
  if (-not $tok) { $n = 'unknown'; $tok = [int](& $row $n).tokens }
  $h = [double](Get-KitSetting 'budget.handoffAt' $ex.handoffAt)
  [pscustomobject]@{ tool = $Tool; model = $Model; row = $n; budget = $tok; handoff = [int]($tok * $h); handoffAt = $h; runStopAt = [double](Get-KitSetting 'budget.runStopAt' $ex.runStopAt); source = $(if ($src) { $src } else { (& $row $n).source }) }
}
