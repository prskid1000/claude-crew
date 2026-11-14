<#
usage.ps1 (core): tokens, cost and time per run, step, role and model for the supervise page (Statistics "Usage") and bossy.ps1
budget -Usage, dot-sourced by bossy.ps1 (skills/bossy/adapters/).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L9 usage
#>
#Requires -Version 7
# ---- usage: tokens, cost, time per run, step, role, model (Statistics "Usage"); transcripts parsed incrementally, cached
# one transcript's totals since its last read offset (append-only files); Claude: per message id (a message repeats per content block), Codex: last cumulative count
# token vector [in, out, cache read, cache write, of it 1-hour cache write]; days = that vector per local day (the 7-day window cuts by day)
function Update-KitUsageFile([string]$Path, $Rec, [ref]$Left) {
  $fi = [IO.FileInfo]::new($Path); if (-not $fi.Exists) { return $Rec }
  if (-not $Rec -or $null -eq $Rec.days -or [int]$Rec.v -lt 3 -or [long]$Rec.off -gt $fi.Length) { $Rec = [ordered]@{ v = 3; off = 0L; in = 0L; out = 0L; cr = 0L; cw = 0L; cw1 = 0L; n = 0; tools = 0; model = ''; t0 = ''; t1 = ''; lastId = ''; lastU = @(0, 0, 0, 0, 0); days = @{} } }   # older cache: no per-day + model vectors, reread
  $n = [int][math]::Min([math]::Min($fi.Length - [long]$Rec.off, [math]::Max([long]0, [long]$Left.Value)), [long]256MB); if ($n -le 0) { return $Rec }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
  try { $null = $fs.Seek([long]$Rec.off, 'Begin'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  if ($got -le 0) { return $Rec }; $end = [Array]::LastIndexOf($b, [byte]10, $got - 1); if ($end -lt 0) { return $Rec }   # no whole line yet; shrunk meanwhile
  $Left.Value -= $end + 1; $Rec.off = [long]$Rec.off + $end + 1
  $num = { param($l, [string]$k) $m = [regex]::Match($l, """$k"":(\d+)"); if ($m.Success) { [long]$m.Groups[1].Value } else { 0L } }
  foreach ($l in [Text.Encoding]::UTF8.GetString($b, 0, $end).Split([char]10)) {
    $ts = [regex]::Match($l, '"timestamp":"([^"]+)"'); if ($ts.Success) { if (-not $Rec.t0) { $Rec.t0 = $ts.Groups[1].Value }; $Rec.t1 = $ts.Groups[1].Value }
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
      $Rec.days[$dk] = @(for ($i = 0; $i -lt 5; $i++) { [long]$dv[$i] + $now5[$i] - $was[$i] }) }
  }
  $Rec
}
# a file record's token vectors of the given days (keys yyyy-MM-dd|model): [{ day; model; v }]
function Get-KitUsageParts($Rec, [string[]]$DayKeys) {
  if (-not $Rec -or -not $Rec.days) { return }
  foreach ($kv in $Rec.days.GetEnumerator()) { $dk, $md = "$($kv.Key)" -split '[|]', 2; if ($dk -in $DayKeys) { [pscustomobject]@{ day = $dk; model = $md; v = [long[]]@($kv.Value | ForEach-Object { [long]$_ }) } } }
}
# USD per million tokens (budget.prices, list prices 2026-11-03; derived, not listed: 5-min writes 1.25x in, 1-h 2x in, haiku cache read 0.1x in; key = model id without claude-, also its dated / [1m] variant and alias: sonnet = sonnet-*); [in, out, cache read, 5-min write, 1-h write (else 2x in)]
# $Tok = token vector [in, out, cache read, cache write, of it 1 h]; unknown model: $null (the page lists it as not priced)
function Get-KitUsageCost($Tok, [string]$Model) {
  $pr = Get-KitSetting 'budget.prices' $null; if (-not $pr) { if ($null -eq $script:KitPrices) { $script:KitPrices = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget.prices }; $pr = $script:KitPrices }; if (-not $pr -or -not $Model) { return $null }
  $id = $Model.ToLower() -replace '\[[^\]]*\]$' -replace '^claude-'; $pv = $null
  foreach ($p in @($pr.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) { if ($id -eq $p.Name -or $id.StartsWith("$($p.Name)-") -or ($id -notmatch '-' -and $p.Name -like "$id-*")) { $pv = $p.Value; break } }
  if ($null -eq $pv -or @($pv).Count -lt 4) { return $null }   # pwsh names ignore case: never $v next to $V
  $pv = @($pv | ForEach-Object { [double]$_ }); $w1 = if ($pv.Count -gt 4) { $pv[4] } else { 2 * $pv[0] }   # 4 values: 1-hour writes at 2x input
  ([double]$Tok[0] * $pv[0] + [double]$Tok[1] * $pv[1] + [double]$Tok[2] * $pv[2] + ([double]$Tok[3] - [double]$Tok[4]) * $pv[3] + [double]$Tok[4] * $w1) / 1e6
}
# budget -Usage: supervise runs it in the background each sweep; the page reads its cache
function Show-KitUsage([double]$Seconds, [bool]$Json) {
  $u = Get-KitUsage -Seconds $Seconds; $d0 = @($u.days)[-1]
  if ($Json) { $u | ConvertTo-Json -Depth 8 -Compress; return }
  "usage: today $($d0.tok) tokens$(if ($null -ne $d0.cost) { ", est. `$$($d0.cost)" }); 7 days $(($u.days | Measure-Object tok -Sum).Sum) tokens, $(@($u.runs).Count) run(s), $((@($u.bg) | Measure-Object n -Sum).Sum) agent(s) outside workflows, $(@($u.coord).Count) coordinator session(s)$(if (@($u.unpriced).Count) { "; not priced (add to budget.prices): $(@($u.unpriced | ForEach-Object { "$($_.model) $($_.tok) tokens" }) -join ', ')" })$(if ($u.partial) { '; transcripts still being read (run again)' })"
}
# the git host's merged MRs of this machine's login since $Since (deploy MRs left out); cached 2 beats in the usage cache; $null = no login or no repos
# days as yyyy-MM-dd: ConvertFrom-Json turns ISO date-times into DateTime
function Get-KitUsageHostMrs([datetime]$Since, [datetime]$Now, $Prev) {
  if ($Prev -and "$($Prev.since)" -eq $Since.ToString('yyyy-MM-dd') -and ($Now - [datetime]$Prev.at).TotalMinutes -lt 2 * (Get-KitBeatMinutes)) { return $Prev }
  $repos = @(@(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ }); if (-not $repos.Count) { return $null }
  $hu = try { Get-KitHostUser } catch { '' }; if (-not $hu) { return $null }; $cut = $Since.ToUniversalTime(); $hostErr = $false
  $mrs = @(foreach ($rp in $repos) { foreach ($m in @(try { Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = $cut.ToString('o'); per_page = 100 } } catch { $hostErr = $true }) | Where-Object { $_.iid -and $_.merged_at }) {
        $au = if ($m.author.username) { $m.author.username } else { "$($m.author)" }
        if ((-not $au -or $au -eq $hu) -and ([datetimeoffset]$m.merged_at).UtcDateTime -ge $cut -and -not (Test-KitDeployMr $rp "$($m.source_branch)" "$($m.target_branch)")) { @{ ref = "$rp!$($m.iid)"; day = ([datetimeoffset]$m.merged_at).LocalDateTime.ToString('yyyy-MM-dd') } } } })
  if ($hostErr) { return $Prev }   # a failed list is no 0 merged: the last list (or workflow MRs), retried next beat
  @{ at = $Now.ToString('o'); since = $Since.ToString('yyyy-MM-dd'); user = $hu; mrs = @($mrs | Sort-Object { $_.ref } -Unique) }
}
function Get-KitPct($Vals, [double]$P) { $s = @($Vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($P * $s.Count))] }
# runs, steps, background agents of the last $Days days; parses for at most $Seconds (the cache keeps offsets: the rest next call); stored with the result
# one window for every number: the $Days calendar days ending today (tokens cut by the day they were spent)
# a run's human label: its mandate's first words, else the first agent's area or items, else the brief's file name (the run id: the tooltip)
function Get-KitRunLabel($A) {
  $s = @(@($A.mandate) + @(@($A.agents)[0].area) + @(@($A.agents)[0].items) + @(if ($A.brief) { [IO.Path]::GetFileNameWithoutExtension("$($A.brief)") }) | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() } | Where-Object { $_ -and $_ -notmatch '^<' })[0]
  if ("$s".Length -gt 48) { $s = ($s.Substring(0, 47) -replace '\s+\S*$', '') + '…' }; "$s"
}
function Get-KitUsage([datetime]$Now = (Get-Date), [int]$Days = 7, [double]$Seconds = 60) {
  $cf = Get-KitPath usage-cache -Create; $all = try { Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; $cache = $all.files; if ($cache -isnot [hashtable]) { $cache = @{} }
  $root = (Invoke-KitAdapter transcript claude root).dir; $since = $Now.Date.AddDays(1 - $Days); $stop = (Get-Date).AddSeconds($Seconds); $left = [ref][long]2GB; $seen = @{}
  $dayKeys = @(foreach ($i in ($Days - 1)..0) { $Now.AddDays(-$i).ToString('yyyy-MM-dd') }); $unp = @{}; $mcost = @{}
  $read = { param([string]$f) $seen[$f] = 1; try { if ((Get-Date) -lt $stop -and $left.Value -gt 0) { $cache[$f] = Update-KitUsageFile $f $cache[$f] $left }; if ([IO.FileInfo]::new($f).Length -gt [long]$cache[$f].off + 64KB) { $script:KitUsagePartial = $true } } catch { }; $cache[$f] }   # a vanished file: its last totals; a half-written line is no backlog
  $script:KitUsagePartial = $false
  $lk = "$cf.lock"; if ((Test-Path -LiteralPath $lk) -and ((Get-Date) - [IO.File]::GetLastWriteTime($lk)).TotalMinutes -gt 10) { Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }   # a killed run's
  try { $lkh = [IO.File]::Open($lk, 'CreateNew', 'Write', 'None') } catch { return (Read-KitUsageResult) }   # another run reads: its last result
  try {
  $meta = { param([string]$f) try { Get-Content -LiteralPath ($f -replace '\.jsonl$', '.meta.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
  $mins = { param($r) if ($r.t0 -and $r.t1) { [math]::Round(([datetimeoffset]$r.t1 - [datetimeoffset]$r.t0).TotalMinutes, 1) } }
  $tok4 = { param($v) [long]$v[0] + [long]$v[1] + [long]$v[2] + [long]$v[3] }
  $price = { param($v, [string]$model) $c = Get-KitUsageCost $v $model; $tk = & $tok4 $v; if ($null -eq $c -and $tk) { $mk = if ($model) { $model } else { '(no model)' }; $unp[$mk] = [long]$unp[$mk] + $tk }; $c }
  # a step from a file record: its in-window tokens; $x = the step's own fields; $null = no tokens in the window (spent before it)
  # each day + model part priced at its own model; dayc = day -> [tokens, cost]; an older cache record (no parts yet) waits for its reread
  $mkStep = { param($u, [string]$model, [hashtable]$x) if ($u.days -and $u.days.Count -and [int]$u.v -lt 3) { return }
    $v = [long[]]::new(5); $cs = $null; $dc = @{}; foreach ($pt in @(Get-KitUsageParts $u $dayKeys)) { for ($i = 0; $i -lt 5; $i++) { $v[$i] += $pt.v[$i] }; $pm = if ($pt.model) { $pt.model } else { $model }; $c = & $price $pt.v $pm
      if ($null -ne $c) { $cs = [double]$cs + $c; $mcost[$pm] = [double]$mcost[$pm] + $c }; $d0 = @($dc[$pt.day]); $dc[$pt.day] = @(([long]$d0[0] + (& $tok4 $pt.v)), $(if ($null -ne $c -or $null -ne $d0[1]) { [double]$d0[1] + [double]$c })) }
    $tk = & $tok4 $v; if (-not $tk -and $u.days -and $u.days.Count) { return }
    $o = [ordered]@{ run = ''; wid = ''; label = ''; type = ''; role = ''; model = $model; in = $v[0]; out = $v[1]; cr = $v[2]; cw = $v[3]; cw1 = $v[4]; tok = $tk; cost = $cs; min = (& $mins $u); tools = [int]$u.tools; result = 'pass'; round = 1; retry = 0; dayc = $dc; at = ''; mrs = @() }
    foreach ($kv in $x.GetEnumerator()) { $o[$kv.Key] = $kv.Value }; [pscustomobject]$o }
  $atOf = { param($u, [string]$f) if ($u.t1) { ([datetimeoffset]$u.t1).LocalDateTime.ToString('o') } else { [IO.File]::GetLastWriteTime($f).ToString('o') } }
  # empty = a result whose every field but ok is empty (a missing mrs is no MR)
  $isEmpty = { param($r) -not @($r.PSObject.Properties | Where-Object { $_.Name -ne 'ok' -and $_.Value -and "$($_.Value)".Trim() }).Count }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $stuck = [double](Get-KitParam 'supervise.stuckMinutes')
  $runs = [Collections.Generic.List[object]]::new(); $steps = [Collections.Generic.List[object]]::new(); $bg = @{}; $coord = [Collections.Generic.List[object]]::new()
  foreach ($sd in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {   # no age filter: a session folder keeps its creation time while its runs go on for days
    $sub = Join-Path $sd.FullName 'subagents'; if (-not (Test-Path -LiteralPath $sub)) { continue }
    foreach ($w in @(Get-ChildItem -LiteralPath (Join-Path $sub 'workflows') -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {
      $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path -LiteralPath $j)) { continue }
      $ev = @(Get-Content -LiteralPath $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x.result }
      $failed = @{}; foreach ($x in $ev | Where-Object type -eq 'failed') { $failed["$($x.agentId)"] = 1 }   # the engine's own failure: no result line
      $rec = @(Get-KitWorkflowRecords $w $ev $launch); $name = @(@($rec | ForEach-Object run) + $w.Name | Where-Object { $_ })[0]; $cap = @($rec.cap | Where-Object { $_ })[0]; $spent = @($rec.spent | Where-Object { $_ })[0]
      $live = -not (Get-KitWorkflowStop $w $rec) -and -not @($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count
      $labels = @{}; $noRes = @{}; $rs = [Collections.Generic.List[object]]::new()
      foreach ($s in @($ev | Where-Object type -eq 'started')) {
        $f = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; if (-not (Test-Path -LiteralPath $f)) { continue }
        $u = & $read $f; $m = & $meta $f; $lb = [string]$s.label; $labels[$lb] = 1 + [int]$labels[$lb]
        $r = $res[$s.agentId]; $age = ($Now - [IO.File]::GetLastWriteTime($f)).TotalMinutes
        $out = if ($r) { if ($r.error -or $r.ok -eq $false) { 'fail' } elseif (& $isEmpty $r) { 'empty' } else { 'pass' } } elseif ($failed["$($s.agentId)"]) { 'fail' } elseif ($live -and $age -lt $stuck) { 'running' } elseif ($live) { 'stuck' } else { 'stopped' }
        $model = if ($u.model) { $u.model } else { "$($m.model)" }
        $st = & $mkStep $u $model @{ run = $name; wid = $w.Name; label = $lb; type = (($lb -split ':')[0] -creplace '-[A-Z][\w-]*$'); role = "$($m.agentType)"; result = $out; round = $labels[$lb]; retry = [int]$noRes[$lb]; at = (& $atOf $u $f)
          mrs = @($r.mrs | Where-Object merged | ForEach-Object { "$(if ($_.url) { $_.url } else { $_.ref })" }) }
        if (-not $r) { $noRes[$lb] = 1 + [int]$noRes[$lb] }; if ($st) { $rs.Add($st); $steps.Add($st) } }   # retry: earlier starts of the label with no result
      if (-not $rs.Count) { continue }
      $items = @(@($rec | ForEach-Object { $_.args.agents }) | ForEach-Object { "$($_.items)" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique).Count
      $a0 = @($rec | ForEach-Object args | Where-Object { $_ })[0]; $scr = [IO.Path]::GetFileName("$(@($rec.script | Where-Object { $_ })[0])")
      $runs.Add([pscustomobject]@{ run = $name; id = $w.Name; label = (Get-KitRunLabel $a0); kind = $(if ($scr -match 'testy') { 'test' } elseif ($scr -match 'buildy') { 'build' } elseif ($scr -match 'tidy|retro') { 'kit' } else { '' }); started = $w.CreationTime.ToString('o'); status = $(if ($live) { 'running' } else { 'ended' }); cap = [long]$cap; spent = [long]$spent; tok = [long]($rs | Measure-Object tok -Sum).Sum; cost = $(if (@($rs | Where-Object { $null -ne $_.cost }).Count) { [math]::Round(($rs | Measure-Object cost -Sum).Sum, 2) })
          in = [long]($rs | Measure-Object in -Sum).Sum; out = [long]($rs | Measure-Object out -Sum).Sum; cr = [long]($rs | Measure-Object cr -Sum).Sum; cw = [long]($rs | Measure-Object cw -Sum).Sum
          wall = [math]::Round(($w.LastWriteTime - $w.CreationTime).TotalMinutes); roles = (@($rs | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = @($rs | Where-Object { $_.result -in 'pass', 'empty', 'fail' }).Count; total = $rs.Count; merged = @($rs.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = $items
          loop = [long](@($rs | Where-Object { $_.type -in 'review', 'fix' }) | Measure-Object tok -Sum).Sum; at = $w.LastWriteTime.ToString('o'); steps = @($rs) }) }
    foreach ($f in @(Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # Agent-tool spawns, by coordinator session
      $u = & $read $f.FullName; $m = & $meta $f.FullName; $k = $sd.Name; $model = if ($u.model) { $u.model } else { "$($m.model)" }; $rl = if ($m.agentType) { "$($m.agentType)" } else { 'agent' }
      $st = & $mkStep $u $model @{ label = "$($m.description)"; type = 'agent'; role = $rl; at = $f.LastWriteTime.ToString('o') }; if (-not $st) { continue }
      if (-not $bg[$k]) { $bg[$k] = [ordered]@{ session = $k; n = 0; tok = 0L; cost = $null; roles = @{}; at = '' } }; $g = $bg[$k]; $g.n++; $g.tok += $st.tok; if ($null -ne $st.cost) { $g.cost = [double]$g.cost + $st.cost }
      $g.roles[$rl] = 1 + [int]$g.roles[$rl]; if ($st.at -gt $g.at) { $g.at = $st.at }; $steps.Add($st) }
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # main sessions: the coordinator's own turns
    $u = & $read $f.FullName; $st = & $mkStep $u "$($u.model)" @{ label = "session $($f.BaseName)"; type = 'coordinator'; role = 'coordinator'; at = (& $atOf $u $f.FullName) }; if (-not $st -or -not $st.tok) { continue }
    $steps.Add($st); $coord.Add([pscustomobject]@{ session = $f.BaseName; model = $st.model; tok = $st.tok; cost = $(if ($null -ne $st.cost) { [math]::Round($st.cost, 2) }); min = $st.min; at = $st.at }) }
  foreach ($k in @($cache.Keys)) { if (-not $seen[$k]) { $cache.Remove($k) } }   # older than $Days: dropped
  $grp = { param([string]$by) @($steps | Where-Object { $_.$by -and $_.tok } | Group-Object $by | ForEach-Object { $g = @($_.Group); [pscustomobject]@{ k = $_.Name; n = $g.Count; sum = [long]($g | Measure-Object tok -Sum).Sum; cost = $(if (@($g | Where-Object { $null -ne $_.cost }).Count) { [math]::Round((@($g | Where-Object { $null -ne $_.cost }) | Measure-Object cost -Sum).Sum, 2) }); avg = [long]($g | Measure-Object tok -Average).Average; p50 = (Get-KitPct $g.tok 0.5); p90 = (Get-KitPct $g.tok 0.9); avgMin = $(if (@($g.min | Where-Object { $null -ne $_ }).Count) { [math]::Round(($g.min | Where-Object { $null -ne $_ } | Measure-Object -Average).Average, 1) }); p90Min = (Get-KitPct $g.min 0.9) } } | Sort-Object { -$_.avg * $_.n }) }
  $wf = @($steps | Where-Object run); $ended = @($wf | Where-Object result -in 'pass', 'empty', 'fail', 'stopped')   # stopped: ended with no result
  $hostMrs = Get-KitUsageHostMrs $since $Now $all.host
  $dayRows = @(foreach ($dk in $dayKeys) { $ds = @($steps | Where-Object { $_.dayc[$dk] }); $tk = 0L; $dc = [Collections.Generic.List[double]]::new()
      foreach ($x in $ds) { $dv = @($x.dayc[$dk]); $tk += [long]$dv[0]; if ($null -ne $dv[1]) { $dc.Add([double]$dv[1]) } }
      [pscustomobject]@{ day = $dk; tok = $tk; cost = $(if ($dc.Count) { [math]::Round(($dc | Measure-Object -Sum).Sum, 2) }); runs = @($ds | Where-Object wid | ForEach-Object wid | Select-Object -Unique).Count
        merged = $(if ($hostMrs) { @($hostMrs.mrs | Where-Object { "$($_.day)" -eq $dk }).Count } else { @(@($steps | Where-Object { "$($_.at)".StartsWith($dk) }).mrs | Where-Object { $_ } | Select-Object -Unique).Count }) } })
  $usageOut = [pscustomobject]@{ at = $Now.ToString('o'); since = $since.ToString('o'); partial = $script:KitUsagePartial; runs = @($runs | Sort-Object at -Descending); bg = @($bg.Values | ForEach-Object { [pscustomobject]@{ session = $_.session; n = $_.n; tok = $_.tok; cost = $(if ($null -ne $_.cost) { [math]::Round($_.cost, 2) }); roles = (@($_.roles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ') } } | Sort-Object { -$_.tok })
    coord = @($coord | Sort-Object { -$_.tok }); modelCost = @($mcost.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = [math]::Round($_.Value, 2) } }); unpriced = @($unp.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ model = $_.Key; tok = $_.Value } })
    merged = $(if ($hostMrs) { [pscustomobject]@{ source = 'host'; user = $hostMrs.user; n = @($hostMrs.mrs).Count } } else { [pscustomobject]@{ source = 'workflows'; user = ''; n = @($wf.mrs | Where-Object { $_ } | Select-Object -Unique).Count } })
    byType = (& $grp type); byRole = (& $grp role); byModel = (& $grp model)
    rates = [pscustomobject]@{ n = $ended.Count; empty = @($ended | Where-Object result -eq 'empty').Count; fail = @($ended | Where-Object result -eq 'fail').Count; stopped = @($ended | Where-Object result -eq 'stopped').Count; stuck = @($wf | Where-Object result -eq 'stuck').Count; running = @($wf | Where-Object result -eq 'running').Count }
    days = $dayRows }
  try { Write-KitAtomic $cf (@{ files = $cache; host = $hostMrs } | ConvertTo-Json -Depth 7 -Compress); Write-KitAtomic ($cf -replace '\.json$', '.result.json') ($usageOut | ConvertTo-Json -Depth 10 -Compress) } catch {}
  $usageOut
  } finally { $lkh.Dispose(); Remove-Item -LiteralPath $lk -Force -ErrorAction SilentlyContinue }
}
# the last budget -Usage result (the page, a run that finds the lock taken)
function Read-KitUsageResult { try { Get-Content -LiteralPath ((Get-KitPath usage-cache) -replace '\.json$', '.result.json') -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 } catch { $null } }
# the page's usage parts (budget -Usage result), each number once: runs (one line each, steps folded), usage (today tiles, step
# outcomes bar, 7-day chart, role and model tables with share bars), top 5 steps (7 days, today marked), internals (per step type, sessions when 2+)
# called by Format-KitSuperviseHtml: its helpers ($e $n1 $grid $table $bar $trend $at) by dynamic scope
function Format-KitUsageHtml($U) {
  if (-not $U -or -not @($U.days).Count) { return [pscustomobject]@{ runs = ''; runsN = $null; usage = '<p class=empty>No usage yet: bossy.ps1 budget -Usage runs each sweep.</p>'; internals = '' } }
  $tk = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 1e9) { "$(& $n1 ([math]::Round([double]$v / 1e9, 2)))B" } elseif ([double]$v -ge 1e6) { "$(& $n1 ([double]$v / 1e6))M" } elseif ([double]$v -ge 1e3) { "$([math]::Round([double]$v / 1e3))k" } else { "$([long]$v)" } }
  $usd = { param($v) if ($null -eq $v) { '—' } else { '$' + ([double]$v).ToString($(if ([double]$v -ge 1000) { '#,0' } else { '0.00' }), [cultureinfo]::InvariantCulture) } }
  $mn = { param($v) if ($null -eq $v) { '—' } elseif ([double]$v -ge 90) { "$(& $n1 ([double]$v / 60)) h" } else { "$(& $n1 $v) min" } }
  $dy = @($U.days | Where-Object { $_ }); $td = $dy[-1]; $prev = @($dy | Select-Object -SkipLast 1)
  $avg = { param([string]$k) $vs = @($prev | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Average).Average } }
  $sum = { param([string]$k) $vs = @($dy | ForEach-Object { $_.$k } | Where-Object { $null -ne $_ }); if ($vs.Count) { ($vs | Measure-Object -Sum).Sum } }
  $runs = @($U.runs | Where-Object { $_ }); $wfTok = [double](($runs | Measure-Object tok -Sum).Sum); $loop = [double](($runs | Measure-Object loop -Sum).Sum)
  $merged = [int](($runs | Measure-Object merged -Sum).Sum); $items = [int](($runs | Measure-Object items -Sum).Sum); $rt = $U.rates; $bgs = @($U.bg | Where-Object { $_ }); $cos = @($U.coord | Where-Object { $_ })
  $allTok = [double](& $sum 'tok'); $hm = $U.merged; $onHost = $hm.source -eq 'host'; $unp = @($U.unpriced | Where-Object { $_ })
  $card = { param([string]$label, [string]$v, [string]$sub, [string]$w, [string]$cls = '') "<div class='st $cls' data-fit><div class=k>$(& $e $label)</div><div class=v>$v</div>$(if ($sub) { "<div class=s title='$(& $e $sub)'>$(& $e $sub)</div>" })$(if ($w) { "<div class=w>$(& $e $w)</div>" })</div>" }
  $pct = { param($a, $b) if ([double]$b) { [math]::Round(100 * [double]$a / [double]$b) } }
  # step outcomes: one stacked bar, counts in its legend (a part-of-whole with 4-6 parts reads better as one bar than a donut)
  $oc = @(@(@('pass', ([double]$rt.n - $rt.empty - $rt.fail - $rt.stopped), 'sage'), @('empty', $rt.empty, 'watch'), @('failed', $rt.fail, 'act'), @('stopped', $rt.stopped, 'slate'), @('running', $rt.running, 'mt'), @('stuck', $rt.stuck, 'plum')) | Where-Object { [double]$_[1] -gt 0 })
  $ocAll = [double](($oc | ForEach-Object { [double]$_[1] } | Measure-Object -Sum).Sum)
  $ocHtml = "<div class=sb role=img aria-label='workflow steps by outcome'>$(@($oc | ForEach-Object { "<i style='width:$(& $n1 (100 * [double]$_[1] / $ocAll))%;background:var(--$($_[2]))' title='$($_[0]): $([int]$_[1])'></i>" }) -join '')</div><ul class=ocl>$(@($oc | ForEach-Object { "<li><i style='background:var(--$($_[2]))'></i>$($_[0]) <b>$([int]$_[1])</b></li>" }) -join '')</ul>"
  # today's tokens and cost: the Per day chart's labelled today point (no tile repeats them)
  $kpis = & $grid stats 170px @(
    $(if ($onHost) { $hn = [int]$hm.n; & $card 'Tokens per merged MR' "$(if ($hn) { & $tk ($allTok / $hn) } else { '—' })" "$hn MR(s) merged on the git host by $($hm.user) · $merged reported by workflows · $items item(s)" 'all tokens' }
      else { & $card 'Tokens per MR reported by workflows' "$(if ($merged) { & $tk ($wfTok / $merged) } else { '—' })" "$merged MR(s) reported merged by workflows (no git-host login) · $items item(s): $(if ($items) { & $tk ($wfTok / $items) } else { '—' }) per item" 'workflow runs' }),
    ((& $card 'Review + fix share' "$(if ($wfTok) { & $n1 (& $pct $loop $wfTok) } else { '—' })<small>%</small>" '' '' $(if ($wfTok -and $loop / $wfTok -gt 0.5) { 'warn' })) -replace '</div>$', "$(if ($wfTok) { & $meter $loop $wfTok 'of the workflow tokens · tick = 50% (warn)' $(if ($loop / $wfTok -gt 0.5) { 'watch' } else { 'slate' }) ($wfTok / 2) } else { '<div class=s>of the workflow tokens</div>' })</div>")) 2
  $ocCard = & $fold 'u-outcome' 'Workflow steps by outcome' ([int]$ocAll) $ocHtml -Open -tag h4 -cls "sub st uc $(if ($rt.stuck -or $rt.fail) { 'warn' })"
  # 7 days as lines (owner: no bar charts): est. cost = the solid filled line (left scale), tokens = the dashed line (right scale), a value
  # label per dot, today highlighted, the dotted 7-day average; the 7-day total once, in the title
  $dpts = @(for ($i = 0; $i -lt $dy.Count; $i++) { $d0 = $dy[$i]; $isToday = $i -eq $dy.Count - 1
      @{ label = $(if ($isToday) { 'today' } else { "$($d0.day)".Substring(5) }); x = $isToday; tip = "$($d0.day)$(if ($isToday) { ' (today)' }): $(& $tk $d0.tok) tokens · est. $(& $usd $d0.cost) · $($d0.runs) run(s) · $($d0.merged) MR(s) merged" } })
  $cAvg = & $avg 'cost'; $cMax = [double](@($dy | ForEach-Object { [double]$_.cost }) + 0 | Measure-Object -Maximum).Maximum; $tMax = [double](@($dy | ForEach-Object { [double]$_.tok }) + 0 | Measure-Object -Maximum).Maximum
  $lines = Format-KitLineChart $dpts @(@{ vals = @($dy | ForEach-Object { if ($null -eq $_.cost) { $null } else { [double]$_.cost } }); tone = 'sage'; style = 'solid'; area = $true; fmt = { param($v) if ($null -eq $v) { '—' } else { '$' + [math]::Round([double]$v) } } },
    @{ vals = @($dy | ForEach-Object { [double]$_.tok }); tone = 'slate'; style = 'dash'; fmt = { param($v) & $tk $v } }) "est. cost and tokens per day, $($dy.Count) days" 150 $cAvg -Labels
  $chart = & $fold 'u-days' 'Per day' "$(& $tk (& $sum 'tok')) tokens · $(& $usd (& $sum 'cost')) in 7 days" -Open -tag h4 -cls 'sub st uc' -inner "$lines<div class=ax><span><i class='lk t-sage solid'>est. cost (left, 0-$(& $usd $cMax))</i> <i class='lk t-slate dash'>tokens (right, 0-$(& $tk $tMax))</i></span>$(if ($cAvg) { "<span><i class='lk avg'>7-day avg $(& $usd $cAvg) (budget.prices)</i></span>" })</div>$(if ($unp.Count) { "<p class=m>not priced: $(& $e (@($unp | ForEach-Object { "$($_.model) $(& $tk $_.tok)" }) -join ', '))</p>" })"
  # role and model: one table each, the share as an inline bar (exact values in the cells, the bar for the comparison)
  $roles = @($U.byRole | Where-Object { $_ } | Sort-Object { -[double]$_.sum }); $rAll = [double](($roles | Measure-Object sum -Sum).Sum)
  $roleT = & $fold 'u-roles' 'Per role (coordinator, workflows, agents outside them)' $roles.Count -Open -tag h4 -cls 'sub st uc ur' -inner "$(& $table 'Role', '~Steps', 'Tokens', 'Share', 'Est. cost', '~Avg time', '~p90 time' @($roles | ForEach-Object { , @($_.k, $_.n, (& $tk $_.sum), @{ h = "<span>$(& $bar ([double]$_.sum) $rAll "$(& $pct $_.sum $rAll)%" 'slate')</span>" }, (& $usd $_.cost), (& $mn $_.avgMin), (& $mn $_.p90Min)) }))"
  $mdl = @($U.byModel | Where-Object { $_ } | Sort-Object { -[double]$_.cost }); $cAll = [double](($mdl | Where-Object { $null -ne $_.cost } | Measure-Object cost -Sum).Sum)
  $modelT = & $fold 'u-models' 'Per model' $mdl.Count -Open -tag h4 -cls 'sub st uc um' -inner "$(& $table 'Model', '~Steps', 'Tokens', 'Est. cost', 'Cost share', '~Avg time' @($mdl | ForEach-Object { , @(("$($_.k)" -replace '^claude-'), $_.n, (& $tk $_.sum), (& $usd $_.cost), @{ h = "<span>$(if ($cAll -and $null -ne $_.cost) { & $bar ([double]$_.cost) $cAll "$(& $pct $_.cost $cAll)%" 'plum' } else { '—' })</span>" }, (& $mn $_.avgMin)) }))"
  $stepRows = { param($ss) @($ss | ForEach-Object { , @($_.label, $_.role, ("$($_.model)" -replace '^claude-'), (& $tk $_.tok), "$(& $tk $_.in) / $(& $tk $_.out) / $(& $tk $_.cr) / $(& $tk $_.cw)", (& $mn $_.min), $_.tools, @{ h = "<span class='chip $(switch ($_.result) { 'pass' { 's-act' } 'running' { 's-fin' } 'stuck' { 's-stuck' } 'fail' { 's-stuck' } default { 's-oth' } })'>$(& $e $_.result)</span>" }, "$($_.round)$(if ($_.retry) { " · retry $($_.retry)" })") }) }
  # a run: its human label (mandate / area, the run id in the tooltip), kind chip, resumed, outcome-split step bar; budget bar while running or over 80%
  $kindOf = { param($r) if ($r.kind) { "$($r.kind)" } elseif ("$($r.roles)" -match '^(kitty \d+( · )?)+$') { 'kit' } elseif ("$($r.roles)" -match 'checky') { 'test' } else { 'build' } }
  $resumed = @{}; $firstOf = @{}; foreach ($r in @($runs | Sort-Object { "$(if ($_.started) { $_.started } else { $_.at })" })) { if ($firstOf.ContainsKey("$($r.run)")) { $resumed["$($r.id)"] = 1 } else { $firstOf["$($r.run)"] = 1 } }
  # steps by outcome in one bar (pass, empty, failed, running, stuck, stopped), each part titled with its count
  $segBar = { param($r) $tot = [math]::Max(1, [int]$r.total); $ps = @(foreach ($o in @(@('pass', 'sage'), @('empty', 'watch'), @('fail', 'act'), @('running', 'slate'), @('stuck', 'plum'), @('stopped', 'mt'))) { $n = @($r.steps | Where-Object result -eq $o[0]).Count; if ($n) { [pscustomobject]@{ k = $o[0]; c = $o[1]; n = $n } } })
    "<span class='bar sb3' title='$(& $e (@($ps | ForEach-Object { "$($_.k) $($_.n)" }) -join ' · '))'>$(@($ps | ForEach-Object { "<i class=$($_.c) style='width:$(& $n1 (100 * $_.n / $tot))%'></i>" }) -join '')</span><span class=bl>$($r.done)/$($r.total) steps</span>" }
  $runRow = { param($r) $bp = if ($r.cap) { [double]$r.spent / [double]$r.cap } else { 0 }; $lb = if ("$($r.label)".Trim()) { $r.label } else { $r.run }
      "<details class='ru f'><summary><span class=gn0 title='$(& $e "$($r.run) · $($r.id)")'>$(& $e $lb)</span><span class='chip k-$(& $e (& $kindOf $r))'>$(& $e (& $kindOf $r))</span>$(if ($resumed["$($r.id)"]) { "<span class='chip s-oth'>resumed</span>" })$(if ($r.status -eq 'running') { "<span class='chip s-act'>running</span>" })$(& $segBar $r)" +
      "<span class=m>$(& $tk $r.tok) tokens · $(& $usd $r.cost) · $(& $mn $r.wall)</span>$(if ([int]$r.merged) { "<span class='chip s-act'>$($r.merged) merged</span>" })$(if ($r.cap -and ($r.status -eq 'running' -or $bp -ge 0.8)) { & $bar ([double]$r.spent) ([double]$r.cap) "budget $(& $tk $r.spent) of $(& $tk $r.cap)" $(if ($bp -ge 0.8) { 'watch' }) })</summary>" +   # budget = context spend (budget -Run), not billed tokens
      "<div class=sy>$(& $table 'Step', 'Role', '~Model', 'Tokens', '~In / out / cache r / w', 'Elapsed', '~Tools', 'Result', '~Round' (& $stepRows @($r.steps | Sort-Object { -$_.tok })))</div></details>" }
  # dev and QA runs: running ones on top, then one fold per day (today open) with its one-line sum; kit runs (tidy, retro) not shown
  $devRuns = @($runs | Where-Object { (& $kindOf $_) -ne 'kit' })
  $dayOf = { param($r) try { ([datetimeoffset]"$(if ($r.started) { $r.started } else { $r.at })").LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } }
  $daySum = { param($g) "$($g.Count) runs · $(($g | Measure-Object done -Sum).Sum) steps · $(& $tk ($g | Measure-Object tok -Sum).Sum) tokens · $(& $usd (($g | Where-Object { $null -ne $_.cost } | Measure-Object cost -Sum).Sum)) · $(($g | Measure-Object merged -Sum).Sum) merged" }
  $shown = @($devRuns | Where-Object status -ne 'running' | Sort-Object { "$($_.at)" } -Descending | Select-Object -First 25)   # newest 25 ended with their step tables: the page stays light
  $runHtml = (@($devRuns | Where-Object status -eq 'running' | ForEach-Object { & $runRow $_ }) -join '') + (@(foreach ($g in @($devRuns | Where-Object status -ne 'running' | Group-Object { & $dayOf $_ } | Sort-Object Name -Descending)) {
      $dn = if ($g.Name -eq $at.ToString('yyyy-MM-dd')) { 'Today' } elseif ($g.Name -eq $at.AddDays(-1).ToString('yyyy-MM-dd')) { 'Yesterday' } elseif ($g.Name) { $g.Name.Substring(5) } else { 'Undated' }
      $old = @($g.Group | Where-Object { $shown -notcontains $_ }).Count
      & $fold "runs-$($g.Name)" $dn (& $daySum @($g.Group)) ((@($g.Group | Where-Object { $shown -contains $_ } | ForEach-Object { & $runRow $_ }) -join '') + $(if ($old) { "<p class=m>$old older run(s): supervise-report.json</p>" })) -Open:($dn -eq 'Today') -cls sub }) -join '')
  $aggT = "<div class='uc ua'><h4>tokens avg / p50 / p90 · time = elapsed</h4><div class=sy>$(& $table 'Key', 'N', 'Avg', '~p50', '~p90', 'Avg time', '~p90 time' @($U.byType | Where-Object { $_ } | ForEach-Object { , @($_.k, $_.n, (& $tk $_.avg), (& $tk $_.p50), (& $tk $_.p90), (& $mn $_.avgMin), (& $mn $_.p90Min)) }))</div></div>"
  # one session = its role row already; 2+ = a folded split per session
  $sess = $(if ($cos.Count -ge 2) { "<details class=ru><summary>Coordinator sessions ($($cos.Count))</summary><div class='sy us'>$(& $table 'Session', 'Tokens', 'Est. cost', 'Elapsed', 'Model' @($cos | ForEach-Object { , @($_.session, (& $tk $_.tok), (& $usd $_.cost), (& $mn $_.min), ("$($_.model)" -replace '^claude-')) }))</div></details>" }) +
    $(if ($bgs.Count -ge 2) { "<details class=ru><summary>Agents outside workflows, by session ($($bgs.Count))</summary><div class='sy us'>$(& $table 'Session', 'Agents', 'Tokens', 'Est. cost', 'Roles' @($bgs | ForEach-Object { , @($_.session, $_.n, (& $tk $_.tok), (& $usd $_.cost), $_.roles) }))</div></details>" })
  $nRunning = @($devRuns | Where-Object status -eq 'running').Count
  [pscustomobject]@{ runsN = @{ h = "<span class='iv$(if (-not $nRunning) { ' z' })'>$(Format-KitIcon run 'running runs')$nRunning</span> · $($devRuns.Count) in 7 days" }; runs = $(if ($runHtml) { "<div class='rus sy'>$runHtml</div>" } else { '<p class=empty>None</p>' })
    usage = "$(if ($U.partial) { '<p class=m>Transcripts still being read: numbers grow next sweep.</p>' })$kpis<div class=ug>$chart<div class=ucol>$ocCard$modelT</div>$roleT</div>$(& $fold 'steps' 'Per step type' @($U.byType | Where-Object { $_ }).Count "$aggT$sess" -cls sub)"   # folded: the page fits ~3 screens at 1366
    usageN = "$(& $tk $td.tok) tokens today" }
}
