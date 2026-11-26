<#
usage.ps1 (core): tokens, cost and time per run, step, role and model for the supervise page (Statistics "Usage") and bossy.ps1
budget -Usage; budget handoffs and their successors; dot-sourced by bossy.ps1 (skills/bossy/adapters/).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L10 usage · L385 context · L733 waste (owner 2026-11-23 · L803 split · L877 budget · L945 handoffs · L957 limits ·
  L976 workflow config · L986 dead runs
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
    $ts = [regex]::Match($l, '"timestamp":"([^"]+)"'); if (-not $ts.Success -and $l.StartsWith('{"step_index"')) { $ts = [regex]::Match($l, '"created_at":"([^"]+)"') }; if ($ts.Success) { if (-not $Rec.t0) { $Rec.t0 = $ts.Groups[1].Value }; $Rec.t1 = $ts.Groups[1].Value; Step-KitUsageTime $Rec $l $ts.Groups[1].Value }   # created_at: Antigravity
    $was = @([long]$Rec.in, [long]$Rec.out, [long]$Rec.cr, [long]$Rec.cw, [long]$Rec.cw1)
    $mdl = Get-KitTranscriptModel $l; if ($mdl) { $Rec.model = $mdl }
    if ($l.Contains('"total_token_usage"')) {   # codex rollout: cumulative
      $m = [regex]::Match($l, '"total_token_usage":\{([^}]*)\}'); if (-not $m.Success) { continue }; $u = $m.Groups[1].Value; $Rec.cr = & $num $u 'cached_input_tokens'; $Rec.in = (& $num $u 'input_tokens') - $Rec.cr; $Rec.out = & $num $u 'output_tokens'; $Rec.n++ }
    elseif ($l.Contains('"type":"PLANNER_RESPONSE"')) {   # antigravity: one model call per line, input without the cache read
      if (-not $l.Contains('"input_tokens"')) { continue }; $Rec.in += & $num $l 'input_tokens'; $Rec.cr += & $num $l 'cache_read_tokens'; $Rec.out += & $num $l 'output_tokens'; $Rec.n++; $Rec.tools += ([regex]::Matches($l, '\{"name":"')).Count }
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
  # the 3 CLIs: Claude assistant / user lines, Codex response items (function_call -> *_call_output), Antigravity steps (PLANNER_RESPONSE -> its tool's step)
  if ($L.Contains('"type":"api-request')) { return }   # Claude's request copies: no turn
  $ag = $L.StartsWith('{"step_index"'); $isA = $L.Contains('"role":"assistant"') -or $L.Contains('"type":"PLANNER_RESPONSE"') -or $L.Contains('"type":"function_call"') -or $L.Contains('"type":"custom_tool_call"')
  $isR = $L.Contains('"tool_result"') -or $L.Contains('_call_output"') -or ($ag -and $L.Contains('"source":"MODEL"'))
  $isU = -not $isA -and ($isR -or $L.Contains('"type":"user"') -or $L.Contains('"type":"USER_INPUT"') -or ($L.Contains('"response_item"') -and $L.Contains('"role":"user"'))); if (-not $isA -and -not $isU) { return }
  $t = [datetimeoffset]$Ts; $gap = if ($Rec.tL) { [math]::Max(0.0, ($t - [datetimeoffset]$Rec.tL).TotalSeconds) } else { 0.0 }; $tm = @($Rec.tm | ForEach-Object { [double]$_ })
  if ($isA) { if ($Rec.tK -and $gap -le 1800) { $tm[0] += $gap }; if ($L.Contains('"type":"tool_use"') -or $L.Contains('"tool_calls"') -or $L.Contains('_call"')) { $Rec.tK = 'a'; $Rec.tC = Get-KitToolTimeKind $L } else { $Rec.tK = 'e' } }
  elseif ($isR) { if ($Rec.tK -in 'a', 'r') { $q = [math]::Min($gap, [double](@([regex]::Matches($L, '\[gate\] starting:[^\\"]*?queued (\d+) s') | ForEach-Object { [double]$_.Groups[1].Value }) + 0 | Measure-Object -Sum).Sum); $tm[[int]$Rec.tC] += $gap - $q; $tm[5] += $q }; $Rec.tK = 'r' }
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
  "usage: today $($d0.tok) tokens (output $($d0.out), fresh in $($d0.in), cache write $($d0.cw), cache read $($d0.cr))$(if ($null -ne $d0.cost) { ", est. `$$($d0.cost)$(if ($d0.cs) { " (output `$$([math]::Round(@($d0.cs)[1], 2)), fresh in `$$([math]::Round(@($d0.cs)[0], 2)), cache write `$$([math]::Round(@($d0.cs)[3], 2)), cache read `$$([math]::Round(@($d0.cs)[2], 2)))" })" }); 7 days $(($u.days | Measure-Object tok -Sum).Sum) tokens, $(@($u.runs).Count) run(s), $((@($u.bg) | Measure-Object n -Sum).Sum) agent(s) outside workflows, $(@($u.coord).Count) coordinator session(s)$(if (@($u.unpriced | Where-Object { -not $_.only }).Count) { "; not priced (add to budget.prices): $(@($u.unpriced | Where-Object { -not $_.only } | ForEach-Object { "$($_.model) $($_.tok) tokens" }) -join ', ')" })$(if (@($u.unpriced | Where-Object only).Count) { "; tokens only (no list price kept): $(@($u.unpriced | Where-Object only | ForEach-Object { "$($_.model) $($_.tok) tokens" }) -join ', ')" })$(if ($u.partial) { '; transcripts still being read (run again)' })"
}
# the git host's merged MRs of this machine's login since $Since (deploy MRs left out); cached 2 beats in the usage cache; $null = no login or no repos
# days as yyyy-MM-dd: ConvertFrom-Json turns ISO date-times into DateTime
function Get-KitUsageHostMrs([datetime]$Since, [datetime]$Now, $Prev) {
  if ($Prev -and "$($Prev.since)" -eq $Since.ToString('yyyy-MM-dd') -and ($Now - [datetime]$Prev.at).TotalMinutes -lt 2 * (Get-KitBeatMinutes)) { return $Prev }
  $repos = @(@(if ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()).name }) | Where-Object { $_ }); if (-not $repos.Count) { return $null }
  $hu = try { Get-KitHostUser } catch { '' }; if (-not $hu) { return $null }; $cut = $Since.ToUniversalTime(); $hostErr = $false
  $mrs = @(foreach ($rp in $repos) { foreach ($m in @(try { Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $rp -Raw); state = 'merged'; author_username = $hu; updated_after = (Get-KitStamp stored $cut); per_page = 100 } } catch { $hostErr = $true }) | Where-Object { $_.iid -and $_.merged_at }) {
        $au = if ($m.author.username) { $m.author.username } else { "$($m.author)" }
        if ((-not $au -or $au -eq $hu) -and ([datetimeoffset]$m.merged_at).UtcDateTime -ge $cut -and -not (Test-KitDeployMr $rp "$($m.source_branch)" "$($m.target_branch)")) { @{ ref = "$rp!$($m.iid)"; day = ([datetimeoffset]$m.merged_at).LocalDateTime.ToString('yyyy-MM-dd'); lead = $(if ($m.created_at) { [math]::Round((([datetimeoffset]$m.merged_at) - ([datetimeoffset]$m.created_at)).TotalHours, 1) }) } } } })   # lead: open -> merged, hours
  if ($hostErr) { return $Prev }   # a failed list is no 0 merged: the last list (or workflow MRs), retried next beat
  @{ at = (Get-KitStamp stored $Now); since = $Since.ToString('yyyy-MM-dd'); user = $hu; mrs = @($mrs | Sort-Object { $_.ref } -Unique) }
}
function Get-KitPct($Vals, [double]$P) { $s = @($Vals | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object); if (-not $s.Count) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($P * $s.Count))] }
# runs, steps, background agents of the last $Days days; parses for at most $Seconds (the cache keeps offsets: the rest next call); stored with the result
# one window for every number: the $Days calendar days ending today (tokens cut by the day they were spent)
# a run's shown name (owner 2026-11-25 reference: 'devy-only-prompt · ask catalogue create-only prompt'): '<role>-<topic> · <plain words>'
# by the one normaliser (Get-KitShownName); the topic: args.label (wave-brief render) or <runDir>/run.json label, else the QA name ·
# target, the brief's file name, the mandate, the first agent's area; task codes, waves, dates never shown (the row tooltip: the run id)
function Get-KitRunTopic($A, [string]$RunDir = '') {
  $lb = "$($A.label)".Trim(); $rd = if ($RunDir) { $RunDir } else { "$($A.runDir)" }
  if ($rd -and -not $lb) { $lb = try { "$((Read-KitText (Join-Path $rd 'run.json') | ConvertFrom-Json).label)".Trim() } catch { '' } }
  if ($lb) { return $lb }
  @(@(if ($A.name) { "$($A.name)$(if ($A.target) { " · $($A.target)" })" }) + @(if ($A.brief) { [IO.Path]::GetFileNameWithoutExtension("$($A.brief)") }) + @($A.mandate) + @(@($A.agents)[0].area) | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() } | Where-Object { $_ -and $_ -notmatch '^<' })[0]
}
function Get-KitRunLabelRow($A, [string]$Run = '', [string]$RunDir = '', [string]$Role = '') {
  $rd = if ($RunDir) { $RunDir } else { "$($A.runDir)" }; if (-not $Run -and $rd) { $Run = Split-Path $rd -Leaf }
  $tp = "$(Get-KitRunTopic $A $rd)"; if ($Run) { , @('run', $Run, $tp, $Role) } else { , @('desc', $tp, '', '') }
}
function Get-KitRunLabel($A, [string]$Run = '', [string]$RunDir = '', [string]$Role = '') { $rw = Get-KitRunLabelRow $A $Run $RunDir $Role; Get-KitShownName @rw }
# a run's normaliser row @(run, id, topic, role) from its newest launch record; no record: -Subject (board join -Subject). A page
# registers every row once (Register-KitShownNames: one call, live names compared for ties), then Get-KitRunTitle reads the memo
function Get-KitRunShownRow([string]$Run, [string]$Subject = '') { if ($script:KitLaunchRecs -isnot [array] -or ((Get-Date) - $script:KitLaunchRecsAt).TotalSeconds -gt 30) { $script:KitLaunchRecsAt = Get-Date; $script:KitLaunchRecs = @(Read-KitJsonFiles (Get-KitPath launches) 'self-*.json' | Sort-Object { try { [datetime]$_.at } catch { [datetime]0 } }) }
  $r = @($script:KitLaunchRecs | Where-Object { "$($_.run)" -eq $Run -or ($_.runDir -and (Split-Path "$($_.runDir)" -Leaf) -eq $Run) })[-1]
  if ($r.args) { , @('run', $Run, "$(Get-KitRunTopic $r.args "$($r.runDir)")", [IO.Path]::GetFileNameWithoutExtension("$($r.script)")) } else { , @('run', $Run, $Subject, '') } }
# a board run's topic: its -Subject, else its first agent's area (fix-ask-012 + "cancel SO reason" -> cancel-reason)
function Get-KitBoardRunTopic($Rows) { @(@($Rows | ForEach-Object { "$($_.subject)" }) + @($Rows | ForEach-Object { "$($_.area)" -replace '^(?i)area-' }) | Where-Object { $_.Trim() })[0] }
function Get-KitRunTitle([string]$Run, [string]$Subject = '') { $rw = Get-KitRunShownRow $Run $Subject; Get-KitShownName @rw }
function Get-KitRunMandate($A) { $m = ((@($A.mandate) | Where-Object { $_ }) -join ' · ' -replace '\s+', ' ').Trim(); if ($m.Length -gt 400) { $m.Substring(0, 399) + '…' } else { $m } }
function Get-KitUsage([datetime]$Now = (Get-Date), [int]$Days = 7, [double]$Seconds = 60) {
  $cf = Get-KitPath usage-cache -Create; $all = try { Read-KitText $cf | ConvertFrom-Json -AsHashtable } catch { $null }; $cache = $all.files; if ($cache -isnot [hashtable]) { $cache = @{} }
  $cfCold = $cf -replace '\.json$', '.cold.json'; $coldAll = try { Read-KitText $cfCold | ConvertFrom-Json -AsHashtable } catch { $null }
  if ($coldAll.files -is [hashtable]) { foreach ($ck in $coldAll.files.Keys) { if (-not $cache.ContainsKey($ck)) { $cache[$ck] = $coldAll.files[$ck] } } }   # the hot file wins
  $root = (Invoke-KitAdapter transcript claude root).dir; $since = $Now.Date.AddDays(1 - $Days); $stop = (Get-Date).AddSeconds($Seconds); $left = [ref][long]2GB; $seen = @{}
  $dayKeys = @(foreach ($i in ($Days - 1)..0) { $Now.AddDays(-$i).ToString('yyyy-MM-dd') }); $unp = @{}; $mcost = @{}; $ctxDay = @{}
  $read = { param([string]$f) $seen[$f] = 1; try { if ((Get-Date) -lt $stop -and $left.Value -gt 0) { $cache[$f] = Update-KitContextFile $f (Update-KitUsageFile $f $cache[$f] $left) $left }; if ([IO.FileInfo]::new($f).Length -gt [long]$cache[$f].off + 64KB) { $script:KitUsagePartial = $true } } catch { }; $cache[$f] }   # a vanished file: its last totals; a half-written line is no backlog
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
    $o = [ordered]@{ run = ''; wid = ''; label = ''; type = ''; role = ''; model = $model; in = $v[0]; out = $v[1]; cr = $v[2]; cw = $v[3]; cw1 = $v[4]; tok = $tk; cost = $cs; cs = $c4; tm = $tmv; act = $(if ($tmv) { [math]::Round(($tmv | Measure-Object -Sum).Sum, 1) }); hrs = $hr; min = (& $mins $u); tools = [int]$u.tools; result = 'pass'; round = 1; retry = 0; dayc = $dc; at = ''; t0 = "$($u.t0)"; mrs = @(); cx = (Get-KitContextSummary $u.cx) }
    foreach ($kv in $x.GetEnumerator()) { $o[$kv.Key] = $kv.Value }
    if ($u.cx.days) { foreach ($kv in $u.cx.days.GetEnumerator()) { $dk = "$($kv.Key)"; if ($dk -notin $dayKeys) { continue }; $dv = @($kv.Value); if (-not $ctxDay[$dk]) { $ctxDay[$dk] = @{ v = @(0.0) * 17; role = @{} } }; $cd = $ctxDay[$dk]   # Trends: the day's mix and peak per role
        for ($i = 0; $i -lt 16; $i++) { $cd.v[$i] += [double]$dv[$i] }; if ([double]$dv[16] -gt $cd.v[16]) { $cd.v[16] = [double]$dv[16] }; $rk = if ($o.role) { "$($o.role)" } else { 'agent' }; if ([double]$dv[16] -gt [double]$cd.role[$rk]) { $cd.role[$rk] = [double]$dv[16] } } }
    [pscustomobject]$o }
  # steps' split sums (runs, roles, sessions): tokens by type, cs, tm over the tmN steps that have one (agent minutes: parallel steps add up);
  # hours stay on the steps (the runs band sums them)
  $split = { param($ss) $ss = @($ss | Where-Object { $_ }); $c4 = $null; $t6 = $null; $tn = 0
    foreach ($s in $ss) { if ($null -ne $s.cs) { $c4 = & $add $c4 $s.cs 4 }; if ($null -ne $s.tm) { $t6 = & $add $t6 $s.tm 6; $tn++ } }
    [ordered]@{ in = [long]($ss | Measure-Object in -Sum).Sum; out = [long]($ss | Measure-Object out -Sum).Sum; cr = [long]($ss | Measure-Object cr -Sum).Sum; cw = [long]($ss | Measure-Object cw -Sum).Sum
      cs = $(if ($null -ne $c4) { @($c4 | ForEach-Object { [math]::Round($_, 4) }) }); tm = $(if ($tn) { @($t6 | ForEach-Object { [math]::Round($_, 1) }) }); tmN = $tn; tmAll = $ss.Count; cx = (Join-KitContext @($ss | ForEach-Object { $_.cx })) } }
  $withSplit = { param($o, $ss) foreach ($kv in (& $split $ss).GetEnumerator()) { $o | Add-Member -Force NoteProperty $kv.Key $kv.Value }; $o }
  $atOf = { param($u, [string]$f) Get-KitStamp stored $(if ($u.t1) { ([datetimeoffset]$u.t1).UtcDateTime } else { [IO.File]::GetLastWriteTime($f) }) }
  $isEmpty = { param($r) Test-KitStepEmpty $r }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $stuck = [double](Get-KitParam 'supervise.stuckMinutes')
  $runs = [Collections.Generic.List[object]]::new(); $steps = [Collections.Generic.List[object]]::new(); $bg = @{}; $coord = [Collections.Generic.List[object]]::new()
  $toBg = { param([string]$k, $st, [string]$rl) if (-not $bg[$k]) { $bg[$k] = [ordered]@{ session = $k; n = 0; tok = 0L; cost = $null; roles = @{}; at = ''; ss = [Collections.Generic.List[object]]::new() } }   # agents outside workflows, by session (or tool)
    $g = $bg[$k]; $g.n++; $g.ss.Add($st); $g.tok += $st.tok; if ($null -ne $st.cost) { $g.cost = [double]$g.cost + $st.cost }; $g.roles[$rl] = 1 + [int]$g.roles[$rl]; if ($st.at -gt $g.at) { $g.at = $st.at }; $steps.Add($st) }
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
      $runs.Add((& $withSplit ([pscustomobject]@{ run = $name; id = $w.Name; label = (Get-KitRunLabelRow $a0 $(if ($name -ne $w.Name) { $name }) "$(@($rec.runDir | Where-Object { $_ })[-1])" ([IO.Path]::GetFileNameWithoutExtension($scr))); mandate = (Get-KitRunMandate $a0); qaName = "$($a0.name)"; tasks = $rTasks; mrAll = @($rs | ForEach-Object { $_.mrAll } | Where-Object { $_ } | Select-Object -Unique); kind = $(if ($scr -match 'testy') { 'test' } elseif ($scr -match 'buildy') { 'build' } elseif ($scr -match 'tidy|retro') { 'kit' } else { '' }); started = (Get-KitStamp stored $w.CreationTime); status = $(if ($live) { 'running' } elseif ($rst -eq 'paused') { 'paused' } else { 'ended' }); state = $rst; lastAt = (Get-KitStamp stored $lastW); cap = [long]$cap; spent = [long]$spent; tok = [long]($rs | Measure-Object tok -Sum).Sum; cost = $(if (@($rs | Where-Object { $null -ne $_.cost }).Count) { [math]::Round(($rs | Measure-Object cost -Sum).Sum, 2) })
          wall = [math]::Round(($wEnd - $w.CreationTime).TotalMinutes); roles = (@($rs | Group-Object role | Sort-Object Count -Descending | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'step' }) $($_.Count)" }) -join ' · ')
          done = @($rs | Where-Object { $_.result -in 'pass', 'empty', 'fail' }).Count; total = $rs.Count; merged = @($rs.mrs | Where-Object { $_ } | Select-Object -Unique).Count; items = $items
          loop = [long](@($rs | Where-Object { $_.type -in 'review', 'fix' }) | Measure-Object tok -Sum).Sum; at = (Get-KitStamp stored $wEnd); steps = @($rs) }) $rs)) }
    foreach ($f in @(Get-ChildItem -LiteralPath $sub -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # Agent-tool spawns, by coordinator session
      $u = & $read $f.FullName; $m = & $meta $f.FullName; $k = $sd.Name; $model = if ($u.model) { $u.model } else { "$($m.model)" }; $rl = if ($m.agentType) { "$($m.agentType)" } else { 'agent' }
      $st = & $mkStep $u $model @{ label = "$($m.description)"; type = 'agent'; role = $rl; tool = 'claude'; at = (Get-KitStamp stored $f.LastWriteTime); tf = $f.FullName }; if (-not $st) { continue }
      & $toBg $k $st $rl }
  }
  # Codex rollouts and Antigravity transcripts (owner 2026-11-22: every CLI): an agent step each, grouped by its tool; tests read only KIT_TRANSCRIPTS_<TOOL>
  foreach ($tl in 'codex', 'antigravity') { if ($env:KIT_TRANSCRIPTS -and -not [Environment]::GetEnvironmentVariable("KIT_TRANSCRIPTS_$($tl.ToUpper())")) { continue }
    $tr = Invoke-KitAdapter transcript $tl root; if (-not $tr.dir -or -not (Test-Path -LiteralPath $tr.dir)) { continue }
    foreach ($f in @(Get-Item -Force -Path (Join-Path ([WildcardPattern]::Escape($tr.dir)) "$($tr.sub)/$($tr.filter)") -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -gt $since })) {
      $u = & $read $f.FullName; $id = if ($tl -eq 'antigravity') { Split-Path (Split-Path (Split-Path $f.DirectoryName)) -Leaf } else { $f.BaseName -replace '^rollout-' }
      $st = & $mkStep $u $(if ($u.model) { "$($u.model)" } else { $tl }) @{ label = "$tl $id"; type = 'agent'; role = $tl; tool = $tl; at = (& $atOf $u $f.FullName); tf = $f.FullName }; if (-not $st -or -not $st.tok) { continue }
      & $toBg $tl $st $tl } }
  foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)) {   # main sessions: the coordinator's own turns
    $u = & $read $f.FullName; $st = & $mkStep $u "$($u.model)" @{ label = "session $($f.BaseName)"; type = 'coordinator'; role = 'coordinator'; at = (& $atOf $u $f.FullName) }; if (-not $st -or -not $st.tok) { continue }
    $steps.Add($st); $coord.Add((& $withSplit ([pscustomobject]@{ session = $f.BaseName; model = $st.model; tok = $st.tok; cost = $(if ($null -ne $st.cost) { [math]::Round($st.cost, 2) }); min = $st.min; at = $st.at }) @($st))) }
  foreach ($k in @($cache.Keys)) { if (-not $seen[$k]) { $cache.Remove($k) } }   # older than $Days: dropped
  # one run = one row: a resumed run's folders merge (the newest folder's id and status, sums, MRs unique, items the max; resumed = older folders)
  Register-KitShownNames @($runs | ForEach-Object { , @($_.label) }); foreach ($r in $runs) { $lr = @($r.label); $r.label = Get-KitShownName @lr; $r | Add-Member -Force NoteProperty topic "$(if ($lr[0] -eq 'run') { $lr[2] })" }   # label rows -> shown names: one normaliser call; topic: the Runs list's one name
  $byRun = [ordered]@{}; foreach ($r in @($runs | Sort-Object { "$($_.started)" })) { $rk = "$($r.run)"; if (-not $byRun.Contains($rk)) { $byRun[$rk] = [Collections.Generic.List[object]]::new() }; $byRun[$rk].Add($r) }
  $runs = @(foreach ($grpRun in $byRun.Values) { if ($grpRun.Count -eq 1) { $grpRun[0]; continue }
      $nw = $grpRun[-1]; $ss = @($grpRun | ForEach-Object { $_.steps }); $sumOf = { param([string]$p) [long](@($grpRun | ForEach-Object { [double](Get-KitMember $_ $p) }) | Measure-Object -Sum).Sum }
      $mx = { param([string]$p) @($grpRun | ForEach-Object { "$(Get-KitMember $_ $p)" } | Sort-Object)[-1] }; $cs0 = @($grpRun | Where-Object { $null -ne $_.cost })
      & $withSplit ([pscustomobject]@{ run = $nw.run; id = $nw.id; ids = @($grpRun.id); resumed = $grpRun.Count - 1; label = $nw.label; topic = $nw.topic; mandate = $nw.mandate; qaName = $nw.qaName; tasks = @($grpRun.tasks | Where-Object { $_ } | Select-Object -Unique)
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
      [pscustomobject]@{ day = $dk; cx = $(if ($ctxDay[$dk]) { [ordered]@{ add = @($ctxDay[$dk].v[0..7]); car = @($ctxDay[$dk].v[8..15]); pk = $ctxDay[$dk].v[16]; role = $ctxDay[$dk].role } }); tok = $tk; cost = $(if ($dc.Count) { [math]::Round(($dc | Measure-Object -Sum).Sum, 2) }); in = [long]$t8[0]; out = [long]$t8[1]; cr = [long]$t8[2]; cw = [long]$t8[3]; cs = $(if ($dc.Count) { @($t8[4..7] | ForEach-Object { [math]::Round($_, 4) }) }); runs = @($ds | Where-Object wid | ForEach-Object run | Select-Object -Unique).Count
        merged = $(if ($hostMrs) { @($hostMrs.mrs | Where-Object { "$($_.day)" -eq $dk }).Count } else { @(@($steps | Where-Object { "$($_.at)".StartsWith($dk) }).mrs | Where-Object { $_ } | Select-Object -Unique).Count }) } })
  $usageOut = [pscustomobject]@{ at = (Get-KitStamp stored $Now); since = (Get-KitStamp stored $since); partial = $script:KitUsagePartial; runs = @($runs | Sort-Object at -Descending); bg = @($bg.Values | ForEach-Object { & $withSplit ([pscustomobject]@{ session = $_.session; n = $_.n; tok = $_.tok; cost = $(if ($null -ne $_.cost) { [math]::Round($_.cost, 2) }); roles = (@($_.roles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ') }) $_.ss } | Sort-Object { -$_.tok })
    coord = @($coord | Sort-Object { -$_.tok }); modelCost = @($mcost.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = [math]::Round($_.Value, 2) } }); unpriced = @($unp.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ model = $_.Key; tok = $_.Value; only = "$($_.Key)" -match '^(gpt|gemini|o\d|codex|antigravity)' } })   # only: Codex / Antigravity models, no list price kept
    mrList = @(@(if ($hostMrs) { $hostMrs.mrs } else { foreach ($sx in $wf) { foreach ($mr in @($sx.mrs | Where-Object { $_ })) { @{ ref = "$mr"; day = $(try { ([datetimeoffset]"$($sx.at)").LocalDateTime.ToString('yyyy-MM-dd') } catch { '' }); lead = $null } } } }) | Sort-Object { "$($_.ref)" } -Unique)   # the Delivery repo x day map, lead times
    merged = $(if ($hostMrs) { [pscustomobject]@{ source = 'host'; user = $hostMrs.user; n = @($hostMrs.mrs).Count } } else { [pscustomobject]@{ source = 'workflows'; user = ''; n = @($wf.mrs | Where-Object { $_ } | Select-Object -Unique).Count } })
    byType = (& $grp type); byModel = (& $grp model)
    byRole = @(& $grp role | ForEach-Object { $rss = @($steps | Where-Object role -eq $_.k)   # the Spend view: a role row, its model mix and step types under it
        $_ | Add-Member -PassThru models @(& $grp model $rss | ForEach-Object { [pscustomobject]@{ k = $_.k; sum = $_.sum; cost = $_.cost } }) | Add-Member -PassThru types @(& $grp type $rss) })
    rates = [pscustomobject]@{ n = $ended.Count; empty = @($ended | Where-Object result -eq 'empty').Count; fail = @($ended | Where-Object result -eq 'fail').Count; stopped = @($ended | Where-Object result -eq 'stopped').Count; stuck = @($wf | Where-Object result -eq 'stuck').Count; running = @($wf | Where-Object result -eq 'running').Count }
    days = $dayRows
    agentSteps = @($steps | Where-Object { $_.type -eq 'agent' -and $_.tf } | Select-Object tf, label, role, model, tool, tok, cost, in, out, cr, cw, cs, tm, act, min, hrs, at, cx) }   # board-only rows: tokens by transcript
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
  $allTok = [double](& $sum 'tok'); $hm = $U.merged; $onHost = $hm.source -eq 'host'; $unp = @($U.unpriced | Where-Object { $_ -and -not $_.only }); $tko = @($U.unpriced | Where-Object { $_ -and $_.only })
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
  $wBy = Get-KitWasteRoleCells @(Get-KitWasteItems @(Get-KitContextSteps $U))   # the role map's Waste group (role -> cells)
  $spRows = @($roles | ForEach-Object { $r0 = $_; $mt = [double](@($_.models | Where-Object { $_ }) | Measure-Object sum -Sum).Sum; $msh = @($mdl | ForEach-Object { $mk = "$($_.k)"; $ms = [double](@($r0.models | Where-Object { "$($_.k)" -eq $mk }) | Measure-Object sum -Sum).Sum; if ($mt) { [math]::Round(100 * $ms / $mt) } else { 0 } })
      # merged (owner 2026-11-20): tokens + est. cost = one split cell; avg time split by model / tools / waiting over the steps that have it
      $tok0 = [pscustomobject]@{ tok = $_.sum; cost = $_.cost; in = $_.in; out = $_.out; cr = $_.cr; cw = $_.cw; cs = $_.cs }
      # the cell: tiles + total over the steps with a split (the total = their sum); none: the avg wall clock
      $tim0 = [pscustomobject]@{ min = $(if (-not [int]$_.tmN) { $_.avgMin }); tm = $(if ([int]$_.tmN) { @(@($_.tm) | ForEach-Object { [double]$_ / [int]$r0.tmN }) }); tmN = 1 }
      # one role map (owner 2026-11-24): Spend | Model mix | Context (Get-KitContextRoleCells) | Waste (Get-KitWasteRoleCells), a column group each
      $cxc = Get-KitContextRoleCells $_ $tk; $wsc = $wBy["$($_.k)"]; if (-not $wsc) { $wsc = @{ v = @(0, 0, 0); tx = @('', '', ''); tips = @('none', 'none', 'none'); ignored = '' } }
      $wTone = @('', '', ''); if (@($wsc.v)[0]) { $wTone[0] = 'warn' }; if (@($wsc.v)[1]) { $wTone[1] = 'act' }   # amber fixable, red open
      @{ n = "$($_.k)"; sub = $(if ($cxc.ag) { "$($cxc.ag) agent$(if ($cxc.ag -ne 1) { 's' })" }); title = "$($_.k): $(@($_.types | Where-Object { $_ } | ForEach-Object { "$($_.k) $($_.n) steps, avg $(& $tk $_.avg)" }) -join ' · ')$(if ($_.cx -and [int]$_.cx.n) { "`n$(Get-KitContextTip $_.cx)" })$(if ($wsc.ignored) { "`nwaste ignored:`n$($wsc.ignored)" })"
        v = @([double]$_.n, [double]$_.sum, $(if ($rAll) { 100 * [double]$_.sum / $rAll } else { 0 }), [double]$_.avgMin, [double]$_.p90Min) + @($msh | ForEach-Object { [double]$_ }) + $cxc.v + $wsc.v
        sk = @('', 'tc', '', 'time', ''); so = @($null, $tok0, $null, $tim0, $null); tone = @(@($null) * (5 + $mdl.Count + 11)) + $wTone
        tips = @('', '', '', "$(& $mn $_.avgMin), avg of $($_.n) steps: active time$(if ([int]$_.wallN) { ", wall clock for the $($_.wallN) without a split" })$(if ([int]$_.tmN) { "; the cell: the $($_.tmN) with one`n$(Get-KitSplitTip ([pscustomobject]@{ tm = $tim0.tm }))" })", "$(& $mn $_.p90Min), p90 of $($_.n) steps (active time$(if ([int]$_.wallN) { "; wall clock for $($_.wallN)" }))") + @($mdl | ForEach-Object { '' }) + $cxc.tips + $wsc.tips
        tx = @("$($_.n)", (& $tk $_.sum), "$(& $pct $_.sum $rAll)%", (& $mn $_.avgMin), (& $mn $_.p90Min)) + @($msh | ForEach-Object { if ($_) { "$_%" } else { '' } }) + $cxc.tx + $wsc.tx } })
  $top = $roles | Select-Object -First 1   # folded (owner 2026-11-19): the top role in its header (the 7-day cost is a Trends tile)
  $spend = & $fold 'u-spend' 'Per role' $roles.Count -tag h4 -cls 'sub st uc ur' -extra "$(if ($top) { "<span class=fsm>top: $(& $e $top.k), $(& $pct $top.sum $rAll)% of the tokens</span>" })" -inner "$(Format-KitMetricHeat $spRows (@('steps', 'tokens · est. cost', 'share', 'avg time', 'P90 time') + @($mdl | ForEach-Object { & $mShort $_.k }) + @('avg start', 'avg peak', 'start / peak') + @($script:KitCtxCats | ForEach-Object { $_[1] }) + @('fixable', 'open', 'fixed')) 'role · metric' 'spend-role' @(@(@('Spend', 5), @('Model mix', $mdl.Count), @('Context', 11), @('Waste', 3)) | Where-Object { [int]$_[1] }))$(Format-KitLegend "shade = column peak · amber fixable · red open · $(Format-KitContextLegend)$(if ($unp.Count) { ' · some not priced' })" "a column shaded by its peak (a split cell: each tile by its type's peak, named in the column head) · Spend: time = active (model + tools + waiting), wall clock where no split is recorded · Model mix: each model's share of the role's tokens · Context: start = the first model call's context (the instruction load), peak = the largest call, the source columns: each source's share of the tokens re-sent with every call (bossy.ps1 usage -Context -Type <role>) · Waste: $(Format-KitWasteLegend) · hover a role for its step types and context$(if ($unp.Count) { " · not priced: $(@($unp | ForEach-Object { "$($_.model) $(& $tk $_.tok)" }) -join ', ')" })$(if ($tko.Count) { " · tokens only (Codex / Antigravity, no list price kept): $(@($tko | ForEach-Object { "$($_.model) $(& $tk $_.tok)" }) -join ', ')" })")"
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
    "<span class=gn0 title='$(& $e "$($r.run) · $($r.id)$(if ($r.mandate) { "`n$($r.mandate)" })")'>$(& $e (& $lbOf $r))</span><span class='chip k-$(& $e (& $kindOf $r))'>$(& $e (& $kindOf $r))</span>$(if ($resumed["$($r.id)"]) { "<span class='chip s-oth'>resumed</span>" })$(if ($r.status -eq 'running') { "<span class='chip s-act'>running</span>" })$(& $segBar $r)" +
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
  $uRows = @(@{ n = 'Est. cost'; mk = 'cost-day'; title = "est. cost per day (budget.prices); 7 d: sum$(if ($null -ne $cAvg) { " · avg of the 6 days before today $(& $usd $cAvg)" })"; v = @($dy | ForEach-Object { if ($null -eq $_.cost) { $null } else { [double]$_.cost } }); fmt = { param($v) '$' + [math]::Round([double]$v) }; t = (& $usd (& $sum 'cost')); cls = 'ws'; keep = $true; sk = 'cost'; so = $dy; tips = @($dy | ForEach-Object { "`n$(Get-KitSplitTip $_)" }) },
    @{ n = 'tokens'; mk = 'tokens-day'; title = "tokens per day, all agents; 7 d: sum$(if ($null -ne $tAvg) { " · avg of the 6 days before today $(& $tk $tAvg)" })"; v = @($dy | ForEach-Object { if ($null -eq $_.tok) { $null } else { [double]$_.tok } }); fmt = $tk; t = (& $tk (& $sum 'tok')); keep = $true; sk = 'tokens'; so = $dy; tips = @($dy | ForEach-Object { "`n$(Get-KitSplitTip $_)" }) })
  # context (owner 2026-11-22): the day's carried mix (tokens re-sent, a stacked bar per day) and the day's peak context, by role in the tooltip
  $cxT = { param($d) if (-not $d.cx) { return 'no context record' }; $c8 = @($d.cx.car); $a8 = @($d.cx.add); $ct = [math]::Max(1.0, [double](@($c8 | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum)
    "`ncarried $(& $tk $ct) · added $(& $tk ([double](@($a8 | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum))`n$(@(for ($i = 0; $i -lt 8; $i++) { "$($script:KitCtxCats[$i][1]) $(& $tk $c8[$i]) ($([math]::Round(100 * [double]$c8[$i] / $ct))%)" }) -join "`n")" }
  $cxR = { param($d) $rp = $d.cx.role; if (-not $rp) { return '' }   # a dictionary in this pass, an object from the result file
    $kv = if ($rp -is [Collections.IDictionary]) { @($rp.GetEnumerator() | ForEach-Object { , @("$($_.Key)", [double]$_.Value) }) } else { @((Get-KitProps $rp) | ForEach-Object { , @("$($_.Name)", [double]$_.Value) }) }
    "`n$(@($kv | Sort-Object { -$_[1] } | ForEach-Object { "$($_[0]) $(& $tk $_[1])" }) -join ' · ')" }
  $uRows += @(@{ n = 'Context mix'; mk = 'context-mix-day'; gl = $true; title = 'tokens re-sent in context per day (each call carries what is in context), the bar: its sources (hover a day; bossy.ps1 usage -Context)'; v = @($dy | ForEach-Object { if ($_.cx) { [double](@($_.cx.car | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum } else { $null } }); fmt = $tk; t = (& $tk ([double](@($dy | Where-Object cx | ForEach-Object { @($_.cx.car) } | ForEach-Object { [double]$_ }) + 0 | Measure-Object -Sum).Sum)); sb = @($dy | ForEach-Object { if ($_.cx) { Get-KitContextGradient @($_.cx.car) } else { '' } }); tips = @($dy | ForEach-Object { & $cxT $_ }) },
    @{ n = 'Peak context'; mk = 'context-peak-day'; title = 'the largest context of one model call that day; 7 d: the highest'; v = @($dy | ForEach-Object { if ($_.cx) { [double]$_.cx.pk } else { $null } }); fmt = $tk; t = (& $tk ([double](@($dy | Where-Object cx | ForEach-Object { [double]$_.cx.pk }) + 0 | Measure-Object -Maximum).Maximum)); tips = @($dy | ForEach-Object { if ($_.cx) { "$(& $tk $_.cx.pk)$(& $cxR $_)" } else { 'no context record' } }) })
  foreach ($dr in $uRows) { $dr.d = $ud }   # Trends aligns the rows by date
  # its group line (owner 2026-11-25): output tokens (the total is the right column: each number once) and the top role
  $uOut = [double](@($dy | ForEach-Object { $sp = Get-KitSplitParts $_ 'tokens'; if ($sp.ok) { @($sp.p4 | Where-Object k -eq 'out' | ForEach-Object { [double]$_.v }) } }) + 0 | Measure-Object -Sum).Sum
  $uEx = @($(if ($uOut) { "output tokens $(& $tk $uOut) in 7 d" }), $(if ($top -and $rAll) { "top: $($top.k) $(& $pct $top.sum $rAll)%" }) | Where-Object { $_ }) -join ' · '
  $uRows = @(@{ hd = 'Usage'; g = 'usage'; ex = (& $e $uEx) }) + $uRows   # its group in the Per day map (the 7-day sums: the right column, once)
  $nRunning = @($devRuns | Where-Object status -eq 'running').Count
  [pscustomobject]@{ runsN = $(if ($shown.Count) { "$($devRuns.Count - $nRunning) ended in 7 days" } else { 0 }); nRunning = $nRunning; tpm = $tpm
    dayRuns = $byDay; days = $dy; mrs = @($U.mrList | Where-Object { $_ })
    tiles = $uTiles; dayRows = $uRows; spend = $spend
    pages = $pages
    usageN = "$(& $tk $td.tok) tokens today" }
}
# empty step = a result with no field but ok, or only null / blank-text fields; an array (even []), a number or a bool is an answer
# (219 of 219 "empty" steps were clean reviews / audits ({findings: []}) or verdict lists: object arrays stringify blank, 2026-11-25)
function Test-KitStepEmpty($R) { -not @((Get-KitProps $R) | Where-Object { $_.Name -ne 'ok' -and $null -ne $_.Value -and ($_.Value -isnot [string] -or $_.Value.Trim()) }).Count }
# ---- context: what fills each agent's context (owner 2026-11-22), per model call, from Claude, Codex and Antigravity transcripts
# tokens = UTF-8 bytes / 4 (kitbag budget); call 1's measured size minus its prompt = kit instructions (system prompt, tools, CLAUDE.md /
# AGENTS.md, rules); at each call the categories in context are scaled to the call's size (input + cache read + cache write) and added to
# carried (re-sent); a compaction (marker, or a drop under usage.context.compactDrop) keeps the start load and the summary
$script:KitCtxCats = @(@('ki', 'kit instructions'), @('ti', 'task input'), @('cd', 'code reads'), @('kd', 'kit data'), @('bt', 'build + test output'), @('ot', 'other tool output'), @('wd', 'web + docs'), @('mo', 'model output'))
# a model id from a Codex turn_context or an Antigravity model switch line; '' = none on this line
function Get-KitTranscriptModel([string]$L) {
  if ($L.Contains('"turn_context"')) { $m = [regex]::Match($L, '"model":"([^"]+)"'); if ($m.Success) { return $m.Groups[1].Value } }
  if ($L.Contains('"type":"USER_INPUT"')) { $m = [regex]::Match($L, 'Model Selection` from [^`]*? to ([A-Za-z][\w .-]*?)(?: \(|\.\s|\.\\|\."|\\|"|$)'); if ($m.Success) { return ($m.Groups[1].Value.Trim().ToLower() -replace '\s+', '-') } }
  ''
}
# the parser's params, read once per process (a line read them 5 times: half the pass)
function Get-KitContextParam([string]$Key) { if ($null -eq $script:KitCtxP) { $script:KitCtxP = @{} }; if (-not $script:KitCtxP.ContainsKey($Key)) { $script:KitCtxP[$Key] = [double](Get-KitParam "usage.context.$Key") }; $script:KitCtxP[$Key] }
function New-KitContextRec { [ordered]@{ off = 0L; n = 0; s0 = 0L; pk = 0L; sum = 0L; last = 0L; cmp = 0; ho = 0; cut = 0; kpk = 0L; lastId = ''; lastOut = 0L; add = @(0L) * 8; car = @(0L) * 8; live = @(0.0) * 8; pend = @{}; q = @(); rd = @{}; rmax = @(0, ''); w = @(0L) * 6; top = @(); days = @{} } }
# a tool's category: 0 kit instructions · 1 task input · 2 code reads · 3 kit data · 4 build + test output · 5 other tool output · 6 web + docs
# (7 = model output: output tokens); tool names of the 3 CLIs; $Key = its path or command
function Get-KitContextCat([string]$Name, [string]$Key) {
  switch -Regex ($Name) {
    '^(Skill|skill)$' { return 0 }
    '^(WebFetch|WebSearch|web_search|search_web|read_url_content)$|^mcp__.*(doc|drive|gws|google)' { return 6 }
    '^(Read|NotebookRead|view_file\w*|read_file|Grep|Glob|LSP|grep_search|list_dir\w*|find_by_name|codebase_search|view_code_item)$' { return (Get-KitContextPathCat $Key 2) }
    '^(Bash|PowerShell|run_command|command_status|shell|shell_command|exec_command|local_shell\w*)$' { return (Get-KitContextCmdCat $Key) }
  }
  5
}
# a path's category: the kit = a .claude folder or a kit worktree (<name>-.claude): .md = instructions, .state / .runtime = kit data (briefs,
# resume briefs, contracts = task input)
function Get-KitContextPathCat([string]$P, [int]$Else) {
  $P = $P -replace '\\', '/'; $task = $P -match 'resume-[\w.-]+\.md$|/briefs?/|/contracts?[\w-]*\.(md|json)$|/lead-notes[\w.-]*\.md$|/mandate[\w.-]*\.(md|json)$'   # anchored: MandateService.java is code
  if ($P -match '[/-]\.claude(/|$)') { if ($task) { return 1 }; if ($P -match '/\.(runtime|state)/|\.(jsonl?|log)$') { return 3 }; if ($P -match '\.md$') { return 0 } }
  elseif ($task) { return 1 }
  $Else
}
function Get-KitContextCmdCat([string]$C) {
  # a leading cd, VAR=value or sh -c wrapper off; a pure read (no chain) first: its operands may name a test tool (cat jest.config.js)
  $c1 = $C -replace '^\s*cd\s+\S+\s*(&&|;)\s*', '' -replace '^\s*((\w+=\S*)\s+)+', '' -replace '^\s*(ba|z)?sh\s+-\w*c\s+', '' -replace '^["'']', ''
  if ($c1 -match '^(cat|head|tail|sed\s+-n|grep|rg|wc|nl|less|Get-Content|Select-String|git\s+(grep|show|blame))\b' -and $c1 -notmatch '&&|;|\|\|') { return (Get-KitContextPathCat $c1 2) }
  if ($c1 -match '^(git|glab|gh)\s' -and $c1 -notmatch '&&|;|\|') { return 5 }   # git commit -m "fix tsc errors" is no build
  # build = a chain step that runs the tool, not a read or git step naming it (git diff -- tests/kit-tests.ps1, sed -n cypress/x.cy.ts)
  $run = @($C -split '&&|\|\||;|\r?\n' | Where-Object { ($_ -replace '^\s*["''(]*\s*', '' -replace '^(do|then|else)\s+', '' -replace '^((\w+=\S*|export\s+\S+)\s+)+', '') -notmatch '^(cd|cat|head|tail|sed|awk|grep|rg|wc|nl|less|ls|echo|printf|find|git|glab|gh|Get-Content|Select-String)\b|^$' }) -join ' ; '
  if ($run -match 'crafty\.ps1\S*\s+check\b|kit-tests\.ps1|\b(mvnw?|gradlew?|cypress|pytest|jest|vitest|tsc|py_compile)\b|\b(yarn|npm|pnpm)\s+(run\s+)?(test|build|lint|e2e)|\bdotnet\s+(test|build)|\bng\s+(build|test|lint)\b|node\s+--check|kitbag\.py\S*\s+(lint|ui-check|port)\b') { return 4 }
  if ($C -match 'learn\s+-Read|\b(SKILL|LESSONS|kit-admin|templates|AGENTS|CLAUDE)\.md') { return 0 }
  if ($C -match 'resume-[\w.-]+\.md|[\\/]briefs?[\\/]|contracts?[\w-]*\.(md|json)|lead-notes') { return 1 }
  if ($C -match '\bgws\b|devtools\.py\S*\s+doc\b') { return 6 }
  if ($C -match 'bossy\.ps1\S*\s+(board|supervise|audit|status|track|decide|launch|report|learn|health|budget|usage|param|shells|storage|recover)\b|crafty\.ps1\S*\s+(checkpoint|dir|gate)\b|kitbag\.py\S*\s+(audit|budget|state|cost|sections)\b|[\\/]\.(state|runtime)[\\/]') { return 3 }
  if ($C -match '^\s*(cd\s+\S+\s*(&&|;)\s*)?(cat|head|tail|sed\s+-n|grep|rg|wc|nl|Get-Content|Select-String|git\s+(grep|show|blame))\b') { return 2 }
  5
}
# a content's tokens: text bytes / 4, an image usage.context.imageTokens
function Measure-KitContextTok($C) {
  if ($null -eq $C) { return 0.0 }; if ($C -is [string]) { return [Text.Encoding]::UTF8.GetByteCount($C) / 4.0 }
  if ($C -is [Collections.IDictionary]) { if ("$($C.type)" -eq 'image') { return (Get-KitContextParam imageTokens) }; return (Measure-KitContextTok $(if ($null -ne $C.text) { $C.text } elseif ($null -ne $C.content) { $C.content } elseif ($null -ne $C.output) { $C.output } else { '' })) }
  $s = 0.0; foreach ($x in @($C)) { $s += Measure-KitContextTok $x }; $s
}
function Add-KitContextTok($Cx, [int]$Cat, [double]$Tok, [string]$Day) {
  if ($Tok -le 0 -or $Cat -lt 0) { return }; $Cx.live[$Cat] = [double]$Cx.live[$Cat] + $Tok; $Cx.add[$Cat] = [long]$Cx.add[$Cat] + [long]$Tok
  if ($Day) { if ($null -eq $Cx.days[$Day]) { $Cx.days[$Day] = @(0L) * 17 }; $dv = $Cx.days[$Day]; $dv[$Cat] = [long]$dv[$Cat] + [long]$Tok }
}
# one model call of measured size $Ctx: call 1 sets the start load, a big drop = a compaction, then the mix is scaled to $Ctx and carried
function Add-KitContextCall($Cx, [double]$Ctx, [string]$Day) {
  if ($Ctx -le 0) { return }; $lv = $Cx.live; $rest = 0.0; for ($i = 1; $i -lt 8; $i++) { $rest += [double]$lv[$i] }
  $pre0 = -1L; if (-not [int]$Cx.n) { $pre0 = [long]$Cx.add[0]; $lv[0] = [math]::Max(0.0, $Ctx - $rest); $Cx.add[0] = [long]$lv[0]; $Cx.s0 = [long]$Ctx }
  elseif (-not [int]$Cx.cut -and [double]$Cx.last -gt (Get-KitContextParam compactMinTokens) -and $Ctx -lt (Get-KitContextParam compactDrop) * [double]$Cx.last) { $Cx.cmp = [int]$Cx.cmp + 1; $lv[0] = [math]::Min([double]$lv[0], [double]$Cx.s0) }   # kit docs read go too
  $lv[0] = [math]::Min([double]$lv[0], $Ctx); $rest = 0.0; for ($i = 1; $i -lt 8; $i++) { $rest += [double]$lv[$i] }
  if ($rest -gt 0) { $f = ($Ctx - [double]$lv[0]) / $rest; for ($i = 1; $i -lt 8; $i++) { $lv[$i] = [double]$lv[$i] * $f } } else { $lv[0] = $Ctx }   # nothing added yet: all start load
  if ($Day -and $null -eq $Cx.days[$Day]) { $Cx.days[$Day] = @(0L) * 17 }; $dv = $null; if ($Day) { $dv = $Cx.days[$Day] }   # the array itself (an if-expression would copy it)
  if ($pre0 -ge 0 -and $dv) { $dv[0] = [long]$dv[0] + [long]$Cx.add[0] - $pre0 }   # the start load counts as added on its day
  for ($i = 0; $i -lt 8; $i++) { $Cx.car[$i] = [long]$Cx.car[$i] + [long]$lv[$i]; if ($dv) { $dv[8 + $i] = [long]$dv[8 + $i] + [long]$lv[$i] } }
  if ($dv -and $Ctx -gt [double]$dv[16]) { $dv[16] = [long]$Ctx }
  if ([double]$lv[0] -gt [double]$Cx.kpk) { $Cx.kpk = [long]$lv[0] }
  $Cx.n = [int]$Cx.n + 1; $Cx.sum = [long]$Cx.sum + [long]$Ctx; $Cx.last = [long]$Ctx; $Cx.cut = 0; if ($Ctx -gt [double]$Cx.pk) { $Cx.pk = [long]$Ctx }
}
# a compaction marker: the start load stays, the rest is gone (the summary comes next as model output)
function Reset-KitContextLive($Cx) { if (-not [int]$Cx.n -or [int]$Cx.cut) { return }; $Cx.cmp = [int]$Cx.cmp + 1; $Cx.cut = 1; for ($i = 1; $i -lt 8; $i++) { $Cx.live[$i] = 0.0 }; $Cx.live[0] = [math]::Min([double]$Cx.live[0], [double]$Cx.s0) }   # kit docs read mid-run go too
# a tool result: its tokens + the waste signals: w = [rereads, their tokens, results over usage.context.bigResultTokens, their tokens,
# build / test results over usage.context.logTokens, their tokens]; rmax = the most re-read file; top = the 3 largest results "tok|cat|label"
function Add-KitContextResult($Cx, [string]$Pend, [double]$Tok, [string]$Day) {
  $p = "$Pend" -split '\|', 3; $cat = if ($p[0] -match '^\d$') { [int]$p[0] } else { 5 }; $tool = "$($p[1])"; $rk = "$($p[2])"; $isRead = $tool -match '^(Read|NotebookRead|view_file\w*|read_file)$'; $key = if ($isRead) { $rk -replace '#L[^#]*$', '' } else { $rk }
  Add-KitContextTok $Cx $cat $Tok $Day; $w = $Cx.w
  if ($key -and $isRead) { $k = $rk.ToLowerInvariant() -replace '\\', '/'
    if ($Cx.rd.Contains($k) -or $Cx.rd.Count -lt 1000) { $c = 1 + [int]$Cx.rd[$k]; $Cx.rd[$k] = $c; if ($c -ge 2) { $w[0] = [long]$w[0] + 1; $w[1] = [long]$w[1] + [long]$Tok }; if ($c -gt [int]@($Cx.rmax)[0]) { $Cx.rmax = @($c, ($key -replace '\\', '/')) } } }
  if ($Tok -gt (Get-KitContextParam bigResultTokens)) { $w[2] = [long]$w[2] + 1; $w[3] = [long]$w[3] + [long]$Tok }
  if ($cat -eq 4 -and $Tok -gt (Get-KitContextParam logTokens)) { $w[4] = [long]$w[4] + 1; $w[5] = [long]$w[5] + [long]$Tok }
  # a command is masked whole before the cut (a cut token escapes the mask): flag values of password / user / token flags too
  $cm = (($key -replace '\s+', ' ').Trim() -replace '^((\w+=\S*)\s+)+', '') -replace '(?i)(\s-{1,2}(?:p|pw|pwd|passw\w*|password|u|user|token|secret|api-?key|auth)\s+)\S+', '$1[redacted]' -replace '(?i)(\s-u\s*[^\s:]+:)\S+', '$1[redacted]'
  $lb = "$tool $(if ($tool -match '^(Bash|PowerShell|run_command|shell\w*|exec_command)$') { Protect-KitText $cm } else { [IO.Path]::GetFileName(($key -replace '\\', '/').TrimEnd('/')) })"; if ($lb.Length -gt 160) { $sp = $lb.LastIndexOf(' ', 159); $lb = $lb.Substring(0, $(if ($sp -gt 100) { $sp } else { 159 })) + ' …' }   # cut between words; the popover wraps it
  $Cx.top = @(@(@($Cx.top) + "$([long]$Tok)|$cat|$(Protect-KitText $lb.Trim())") | Sort-Object { -[double](("$_" -split '\|')[0]) } | Select-Object -First 3)
}
# a tool call's pending entry "cat|tool|key" (its result comes later, maybe in a later read); $In = its input (a dictionary or JSON text)
function Get-KitContextPend([string]$Name, $In) {
  if ($In -is [string]) { $In = try { $In | ConvertFrom-Json -AsHashtable -Depth 20 } catch { @{ command = $In } } }
  if ($In -is [Collections.IDictionary]) { $In = [hashtable]::new($In, [StringComparer]::OrdinalIgnoreCase) }   # JSON keys are case-sensitive: Path / path
  $v = { param($k) $x = $In[$k]; if ($x -is [string] -and $x.StartsWith('"')) { $x = try { $x | ConvertFrom-Json } catch { $x } }; if ($x -is [array]) { $x = $x -join ' ' }; "$x".Trim('"').Trim() }   # Antigravity args are JSON strings
  $key = @(@(foreach ($k in 'file_path', 'path', 'notebook_path', 'AbsolutePath', 'SearchPath', 'SearchDirectory', 'DirectoryPath', 'command', 'CommandLine', 'cmd', 'Url', 'url', 'skill') { if ($In -is [Collections.IDictionary] -and $In.Contains($k)) { & $v $k } }) | Where-Object { $_ })[0]
  # a read's range joins its key: the next range of a file is no re-read (AGENTS.md "File inspection" asks for ranges)
  $rg = if ($In -is [Collections.IDictionary] -and $Name -match '^(Read|NotebookRead|view_file\w*|read_file)$') { (@('offset', 'limit', 'StartLine', 'EndLine', 'pages') | ForEach-Object { & $v $_ }) -join ',' }
  "$(Get-KitContextCat $Name "$key")|$Name|$("$key" -replace '[\r\n|]+', ' ')$(if ($rg -match '[^,]') { "#L$rg" })"
}
# a fast estimate for a big line: its tool results between tool ids (Claude: up to toolUseResult, its copy)
function Get-KitContextSegments([string]$L, [string]$IdKey) {
  $stop = $L.IndexOf('"toolUseResult"'); if ($stop -lt 0) { $stop = $L.Length }; $ms = @([regex]::Matches($L, """$IdKey"":""([^""]+)""") | Where-Object { $_.Index -lt $stop })
  $img = @(if ($L.Contains('"base64"')) { [regex]::Matches($L, '"type":"base64"[^}]*?"data":"[^"]*"') | Where-Object { $_.Index -lt $stop } })   # an image costs usage.context.imageTokens, not its base64 size
  for ($i = 0; $i -lt $ms.Count; $i++) { $s0 = $ms[$i].Index; $e = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $stop }; $im = @($img | Where-Object { $_.Index -gt $s0 -and $_.Index -lt $e })
    [pscustomobject]@{ id = $ms[$i].Groups[1].Value; tok = [math]::Max(0.0, ($e - $s0 - 60 - [double](@($im | ForEach-Object { $_.Length }) + 0 | Measure-Object -Sum).Sum) / 4.0) + $im.Count * (Get-KitContextParam imageTokens) } }
}
# one transcript line; the 3 formats: Antigravity steps ({"step_index"), Codex rollout items ({"timestamp", payload), Claude Code lines
function Step-KitContextLine($Cx, [string]$L) {
  if ($L.Length -lt 20 -or $L.Contains('"type":"api-request')) { return }
  $ti = $L.IndexOf('"timestamp":"', [StringComparison]::Ordinal); $tk = 13; if ($ti -lt 0) { $ti = $L.IndexOf('"created_at":"', [StringComparison]::Ordinal); $tk = 14 }   # ordinal: a regex scanned MB lines
  $day = if ($ti -ge 0) { $te = $L.IndexOf('"', $ti + $tk); try { ([datetimeoffset]$L.Substring($ti + $tk, $te - $ti - $tk)).LocalDateTime.ToString('yyyy-MM-dd') } catch { '' } } else { '' }
  $parse = { try { $L | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $null } }
  if ($L.StartsWith('{"step_index"')) {
    $ty = [regex]::Match($L, '"type":"([A-Z_]+)"').Groups[1].Value
    switch ($ty) {
      'PLANNER_RESPONSE' { $o = & $parse; if (-not $o) { return }
        if ($null -ne $o.input_tokens) { Add-KitContextCall $Cx ([double]$o.input_tokens + [double]$o.cache_read_tokens) $day; Add-KitContextTok $Cx 7 ([double]$o.output_tokens) $day }
        $Cx.q = @(@($Cx.q) + @(@($o.tool_calls) | Where-Object { $_.name } | ForEach-Object { Get-KitContextPend "$($_.name)" $_.args })); return }
      'USER_INPUT' { if (-not [int]$Cx.n -and $L -match 'resume-[\w.-]+\.md') { $Cx.ho = 1 }; Add-KitContextTok $Cx 1 (($L.Length - 150) / 4.0) $day; return }
      'SYSTEM_MESSAGE' { Add-KitContextTok $Cx 0 (($L.Length - 150) / 4.0) $day; return }
      'CHECKPOINT' { Reset-KitContextLive $Cx; Add-KitContextTok $Cx 7 (($L.Length - 150) / 4.0) $day; return }
      'CONVERSATION_HISTORY' { return }
    }
    if (-not $L.Contains('"source":"MODEL"')) { return }   # a tool's step: the next queued call's
    $pd = @($Cx.q)[0]; $Cx.q = @(@($Cx.q) | Select-Object -Skip 1)
    if (-not $pd) { $pd = "$(switch ($ty) { 'VIEW_FILE' { Get-KitContextPathCat ([regex]::Match($L, 'File Path: `file:///([^`]+)`').Groups[1].Value) 2 } { $_ -in 'GREP_SEARCH', 'LIST_DIRECTORY' } { 2 } default { 5 } })|$ty|" }
    Add-KitContextResult $Cx $pd (($L.Length - 150) / 4.0) $day; return }
  if ($L -match '^\{"timestamp":"[^"]*",("ordinal":\d+,)?"type":"(response_item|event_msg|turn_context|session_meta|compacted)"') {
    $kd = $Matches[2]
    if ($kd -eq 'compacted' -or $L.Contains('"type":"context_compacted"')) { Reset-KitContextLive $Cx; return }
    if ($kd -eq 'event_msg') { if (-not $L.Contains('"last_token_usage"')) { return }; $o = & $parse; $u = $o.payload.info.last_token_usage; $tt = [long]$o.payload.info.total_token_usage.total_tokens
      if (-not $u -or $tt -eq [long]$Cx.lastOut) { return }; $Cx.lastOut = $tt   # a repeated count: no new call
      Add-KitContextCall $Cx ([double]$u.input_tokens) $day; Add-KitContextTok $Cx 7 ([double]$u.output_tokens) $day; return }
    if ($kd -ne 'response_item') { return }
    $pt = [regex]::Match($L, '"payload":\{"type":"(\w+)"').Groups[1].Value
    if ($pt -match '_output$') { $id = [regex]::Match($L, '"call_id":"([^"]+)"').Groups[1].Value; $pd = $Cx.pend[$id]; if ($id) { $Cx.pend.Remove($id) }; Add-KitContextResult $Cx "$pd" (($L.Length - 200) / 4.0) $day; return }
    if ($pt -in 'function_call', 'custom_tool_call', 'local_shell_call') { $o = & $parse; $p = $o.payload; $Cx.pend["$($p.call_id)"] = Get-KitContextPend "$(if ($p.name) { $p.name } else { 'local_shell' })" $(if ($null -ne $p.arguments) { $p.arguments } elseif ($null -ne $p.action) { $p.action } else { @{ command = "$($p.input)" } }); return }
    if ($pt -eq 'message' -and $L -match '"role":"(developer|user|system)"') { $tok = ($L.Length - 200) / 4.0; $kit = $Matches[1] -ne 'user' -or $L -match '"text":"\s*(<user_instructions>|<environment_context>|<skills_instructions>|# AGENTS\.md)'
      if (-not $kit -and -not [int]$Cx.n -and $L -match 'resume-[\w.-]+\.md') { $Cx.ho = 1 }; Add-KitContextTok $Cx $(if ($kit) { 0 } else { 1 }) $tok $day }
    return }
  # Claude Code
  if ($L.Contains('"compact_boundary"') -and $L.Contains('"type":"system"')) { Reset-KitContextLive $Cx; return }
  if ($L.Contains('"type":"assistant"') -and $L.Contains('"message"')) { $o = & $parse; $m = $o.message; if (-not $m -or "$($o.type)" -ne 'assistant') { return }
    $u = $m.usage; $id = "$($m.id)"
    if ($u -and $id -and $id -ne "$($Cx.lastId)") { Add-KitContextCall $Cx ([double]$u.input_tokens + [double]$u.cache_read_input_tokens + [double]$u.cache_creation_input_tokens) $day; $Cx.lastId = $id; $Cx.lastOut = 0L }
    if ($u) { $d = [long]$u.output_tokens - [long]$Cx.lastOut; if ($d -gt 0) { Add-KitContextTok $Cx 7 $d $day; $Cx.lastOut = [long]$u.output_tokens } }
    foreach ($b in @($m.content | Where-Object { $_ -is [Collections.IDictionary] -and $_.type -eq 'tool_use' })) { $Cx.pend["$($b.id)"] = Get-KitContextPend "$($b.name)" $b.input }
    return }
  if ($L.Contains('"type":"user"') -and $L.Contains('"tool_use_id"')) {   # tool results: sized between their ids (a line can hold MBs)
    foreach ($sg in @(Get-KitContextSegments $L 'tool_use_id')) { $pd = $Cx.pend[$sg.id]; $Cx.pend.Remove($sg.id); Add-KitContextResult $Cx "$pd" $sg.tok $day }; return }
  if ($L.Contains('"type":"user"')) { $o = & $parse; if ("$($o.type)" -ne 'user') { return }; $c = $o.message.content
    if ($o.isCompactSummary) { Reset-KitContextLive $Cx; Add-KitContextTok $Cx 7 (Measure-KitContextTok $c) $day; return }
    $tx = "$(if ($c -is [string]) { $c } else { @($c | Where-Object { $_ -is [Collections.IDictionary] -and $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' })"
    $cat = if ($tx -match '^\s*Base directory for this skill') { 0 } elseif ($o.isMeta) { 5 } else { 1 }; if ($cat -eq 1 -and -not [int]$Cx.n -and $tx -match 'resume-[\w.-]+\.md') { $Cx.ho = 1 }
    Add-KitContextTok $Cx $cat (Measure-KitContextTok $c) $day; return }
  if ($L.Contains('"type":"attachment"') -and [int]$Cx.n) { $o = & $parse; $a = $o.attachment; if (-not $a) { return }   # before call 1: inside the start load
    $cat = switch -Regex ("$($a.type)") { '^(instructions|nested_memory|skill_listing|agent_listing_delta|mcp_instructions_delta|deferred_tools_\w+|hook_additional_context|total_tokens_reminder|todo_reminder)$' { 0 } '^queued_command$' { 1 } '^edited_text_file$' { Get-KitContextPathCat "$($a.filename)" 2 } '^structured_output$' { 7 } default { -1 } }
    if ($cat -ge 0) { Add-KitContextTok $Cx $cat (Measure-KitContextTok $(if ($null -ne $a.content) { $a.content } elseif ($null -ne $a.prompt) { $a.prompt } elseif ($null -ne $a.snippet) { $a.snippet } else { 'x' * [math]::Max(0, $L.Length - 300) })) $day } }   # no text field: the line's size
}
# the context pass of one usage record: its own offset, up to the token pass's (whole lines); an older record is read from 0 once
function Update-KitContextFile([string]$Path, $Rec, [ref]$Left) {
  if (-not $Rec -or $null -eq $Rec.off) { return $Rec }
  if ($null -eq $Rec.cx -or [long]$Rec.cx.off -gt [long]$Rec.off) { $Rec['cx'] = New-KitContextRec }; $cx = $Rec.cx
  $n = [int][math]::Min([math]::Min([long]$Rec.off - [long]$cx.off, [math]::Max([long]0, [long]$Left.Value)), [long]256MB); if ($n -le 0) { return $Rec }
  $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
  try { $null = $fs.Seek([long]$cx.off, 'Begin'); $b = [byte[]]::new($n); $got = $fs.Read($b, 0, $n) } finally { $fs.Dispose() }
  if ($got -le 0) { return $Rec }; $end = [Array]::LastIndexOf($b, [byte]10, $got - 1); if ($end -lt 0) { return $Rec }
  $Left.Value -= $end + 1; $cx.off = [long]$cx.off + $end + 1
  foreach ($l in [Text.Encoding]::UTF8.GetString($b, 0, $end).Split([char]10)) { Step-KitContextLine $cx $l.TrimEnd("`r") }
  if ($cx.days.Count) { $cut = (Get-Date).AddDays(-(Get-KitParam 'usage.keepDays')).ToString('yyyy-MM-dd'); foreach ($dk in @($cx.days.Keys | Where-Object { "$_" -lt $cut })) { $cx.days.Remove($dk) } }
  $Rec
}
# kit-instruction tokens in an agent's context now: the kit start (budget.instructions.start, lint-enforced; the harness prompt is not
# the kit's) + kit docs read since call 1 and still held (a compaction drops them); cached next to the board row ($Cache): a beat reads new bytes only
function Get-KitInstrLive([string]$File, [string]$Cache) {
  if (-not $File -or -not (Test-Path -LiteralPath $File)) { return 0 }
  $rec = $null; if ($Cache -and (Test-Path -LiteralPath $Cache)) { $rec = try { Get-Content -LiteralPath $Cache -Raw | ConvertFrom-Json -AsHashtable -Depth 10 } catch { $null } }
  if (-not $rec -or "$($rec.file)" -ne $File) { $rec = @{ file = $File; cx = (New-KitContextRec) } }
  $rec.off = (Get-Item -LiteralPath $File).Length; $left = [long]$rec.off
  $rec.cx.live = @($rec.cx.live | ForEach-Object { [double]$_ }); $null = Update-KitContextFile $File $rec ([ref]$left)
  if ($Cache) { try { $rec | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $Cache -Encoding utf8 } catch {} }
  [long]([math]::Max(0.0, [double]@($rec.cx.live)[0] - [double]$rec.cx.s0) + (Get-KitInstrCap 0).start)
}
# context self-check (owner 2026-11-23, every role and the coordinator): at budget.reviewAt x the design window, then every budget.reviewEvery
# tokens, the agent decides continue or a fresh agent; one record per transcript (cache/ctx-checks/<transcript name>.json), shared with
# skills/bossy/ctx_hook.mjs (Claude Code PostToolUse; same thresholds and line); board beat asks it on every CLI
function Get-KitCtxCheckFile([string]$Key) { Join-Path (Get-KitPath cache -Create) "ctx-checks/$($Key -replace '[^\w.-]', '_').json" }
function Get-KitCtxCheckLine([string]$Transcript, [double]$Ctx, [double]$Design) {
  if (-not $Transcript -or $Ctx -le 0) { return }; $key = [IO.Path]::GetFileNameWithoutExtension($Transcript); $cf = Get-KitCtxCheckFile $key
  $at = [math]::Round([double](Get-KitParam 'budget.reviewAt') * $Design); $ev = [double](Get-KitParam 'budget.reviewEvery'); if ($at -le 0 -or $ev -le 0 -or $Ctx -lt $at) { return }
  $th = $at + $ev * [math]::Floor(($Ctx - $at) / $ev); $rec = try { Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if ($rec -isnot [hashtable]) { $rec = @{} }
  if ([double]$rec.asked -ge $th) { return }
  $rec.transcript = $Transcript; $rec.asked = $th; $rec.askedAt = (Get-KitStamp); $null = New-Item -ItemType Directory -Force (Split-Path $cf); $rec | ConvertTo-Json -Compress | Set-Content -LiteralPath $cf -Encoding utf8
  "CONTEXT-CHECK: context $([math]::Round($Ctx / 1000))k (self-check at $([math]::Round($th / 1000))k, next at $([math]::Round(($th + $ev) / 1000))k): decide now: continue when the rest of this phase fits (reads in ranges, no new phase), else hand off at the phase end (crafty.ps1 checkpoint -Brief, board leave -Handoff, a fresh agent); record it: & '$($KitCmd.orch -replace '\\', '/')' board check -Decision continue|handoff -Reason '<why>' -Ctx $key"
}
# the agent's answer: the record (supervise shows it), the board row (-Session) and a calls log line
function Set-KitCtxCheck([string]$Key, [string]$Decision, [string]$Reason, [string]$BoardFile) {
  $cf = Get-KitCtxCheckFile $Key; $rec = try { Get-Content -LiteralPath $cf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }; if ($rec -isnot [hashtable]) { return "board check: no CONTEXT-CHECK asked for '$Key' (-Ctx: the key its line prints)" }
  $ck = [ordered]@{ decision = $Decision; reason = $Reason; at = (Get-KitStamp); ctx = [long]$rec.asked }; $rec.check = $ck; $rec | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $cf -Encoding utf8
  if ($BoardFile -and (Test-Path -LiteralPath $BoardFile)) { Update-BoardEntry $BoardFile { param($x) $x | Add-Member -Force NoteProperty ctxCheck ([pscustomobject]$ck); $x } }
  Write-KitLog calls context-check ([ordered]@{ key = $Key; decision = $Decision; reason = $Reason; ctx = [long]$rec.asked }); "context check recorded: $Decision at $([math]::Round([double]$rec.asked / 1000))k ($Reason)"
}
# transcript (lower case) -> its record: supervise skips the design-window WATCH an answered check covers
function Read-KitCtxChecks { $m = @{}; foreach ($f in @(Get-ChildItem (Join-Path (Get-KitPath cache) 'ctx-checks') -Filter *.json -File -ErrorAction SilentlyContinue)) { $r = try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { $null }; if ($r.transcript) { $m["$($r.transcript)".ToLower()] = $r } }; $m }
# a step's context numbers from its record: calls, start, peak, sum, compactions, handoff, added / carried per category, waste, rereads, largest
function Get-KitContextSummary($Cx) {
  if (-not $Cx -or -not [int]$Cx.n) { return $null }
  [ordered]@{ n = [int]$Cx.n; s0 = [long]$Cx.s0; pk = [long]$Cx.pk; sum = [long]$Cx.sum; last = [long]$Cx.last; cmp = [int]$Cx.cmp; ho = [int]$Cx.ho; agents = 1; pks = [long]$Cx.pk; kl = [long][math]::Max(0.0, [double]@($Cx.live)[0] - [double]$Cx.s0); kpk = [long]$Cx.kpk
    add = @($Cx.add | ForEach-Object { [long]$_ }); car = @($Cx.car | ForEach-Object { [long]$_ }); w = @($Cx.w | ForEach-Object { [long]$_ })
    rr = @([int]@($Cx.rmax)[0], "$(@($Cx.rmax)[1])"); top = @($Cx.top) }
}
# summaries added up (a run, a role, a day's agents): sums, the highest peak and reread, the 3 largest results; s0 / pks over agents
function Join-KitContext($List) {
  $ls = @($List | Where-Object { $_ -and [int]$_.n }); if (-not $ls.Count) { return $null }
  $sum = { param([string]$k) [long](@($ls | ForEach-Object { [double](Get-KitMember $_ $k) }) | Measure-Object -Sum).Sum }
  $vec = { param([string]$k, [int]$n) @(for ($i = 0; $i -lt $n; $i++) { [long](@($ls | ForEach-Object { [double]@((Get-KitMember $_ $k))[$i] }) | Measure-Object -Sum).Sum }) }
  $ag = & $sum agents; $rr = @($ls | Sort-Object { -[int]@($_.rr)[0] })[0].rr
  [ordered]@{ n = (& $sum n); s0 = [long]((& $sum s0) * 1.0 / [math]::Max(1, $ls.Count)); pk = [long](@($ls | ForEach-Object { [double]$_.pk }) | Measure-Object -Maximum).Maximum; sum = (& $sum sum); last = [long]@($ls)[-1].last
    cmp = (& $sum cmp); ho = (& $sum ho); agents = $ag; pks = (& $sum pks); add = (& $vec add 8); car = (& $vec car 8); w = (& $vec w 6); rr = @($rr)
    top = @(@($ls | ForEach-Object { @($_.top) }) | Where-Object { $_ } | Sort-Object { -[double](("$_" -split '\|')[0]) } | Select-Object -First 3) }
}
# a summary's top 3 waste signals, worst first: re-read files, oversized results, pasted build logs, start load share of the peak
function Get-KitContextWaste($Cx) {
  if (-not $Cx) { return @() }; $w = @($Cx.w); $rr = @($Cx.rr); $f = { param($v) if ([double]$v -le 0) { '0' } else { Format-KitCompactNum ([double]$v) } }; $o = [Collections.Generic.List[object]]::new()
  if ([int]$rr[0] -ge 2) { $o.Add(@([double]$w[1], "read $([IO.Path]::GetFileName("$($rr[1])")) $($rr[0])x ($(& $f $w[1]) tokens re-read)")) }
  if ([long]$w[2]) { $o.Add(@([double]$w[3], "$($w[2]) result(s) over $(& $f (Get-KitContextParam bigResultTokens)) tokens ($(& $f $w[3]))")) }
  if ([long]$w[4]) { $o.Add(@([double]$w[5], "$($w[4]) full build / test log(s) pasted ($(& $f $w[5]))")) }
  $sh = if ([double]$Cx.pks) { [double]$Cx.s0 * [double]$Cx.agents / [double]$Cx.pks } else { 0 }; if ($sh -ge 0.3) { $o.Add(@(([double]$Cx.s0 * [double]$Cx.agents), "start load $([math]::Round(100 * $sh))% of the peak (avg start $(& $f $Cx.s0))")) }
  @($o | Sort-Object { -$_[0] } | Select-Object -First 3 | ForEach-Object { $_[1] })
}
# the tooltip: sizes, carried and added per category, the top 3 waste signals, the largest results
function Get-KitContextTip($Cx, [string]$Head = '') {
  if (-not $Cx) { return "$(if ($Head) { "$Head`n" })context not recorded" }; $f = { param($v) if ([double]$v -le 0) { '0' } else { Format-KitCompactNum ([double]$v) } }; $car = @($Cx.car); $add = @($Cx.add); $ct = [math]::Max(1.0, [double](@($car | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum)
  $ls = [Collections.Generic.List[string]]::new(); if ($Head) { $ls.Add($Head) }
  $ls.Add("context peak $(& $f $Cx.pk) · start $(& $f $Cx.s0)$(if ([int]$Cx.agents -gt 1) { ' (avg)' }) · avg $(& $f ([double]$Cx.sum / [math]::Max(1, [int]$Cx.n))) · $($Cx.n) call(s)$(if ([int]$Cx.agents -gt 1) { " · $($Cx.agents) agents" })$(if ([int]$Cx.cmp) { " · $($Cx.cmp) compaction(s)" })$(if ([int]$Cx.ho) { " · $($Cx.ho) resumed from a handoff" })")
  # one line per category with tokens (an empty one adds no fact, only page weight); the largest results one per line (a command may hold " · ")
  $ls.Add('carried (re-sent each call) · added:'); for ($i = 0; $i -lt 8; $i++) { if ([double]$car[$i] -gt 0 -or [double]$add[$i] -gt 0) { $ls.Add("$($script:KitCtxCats[$i][1]) $(& $f $car[$i]) ($([math]::Round(100 * [double]$car[$i] / $ct))%) · $(& $f $add[$i])") } }
  $ws = @(Get-KitContextWaste $Cx); if ($ws.Count) { $ls.Add("waste: $($ws -join ' · ')") }
  $tp = @($Cx.top | Where-Object { $_ } | ForEach-Object { $p = "$_" -split '\|', 3; "$($p[2]) $(& $f $p[0])" }); if ($tp.Count) { $ls.Add('largest results:'); $ls.AddRange([string[]]$tp) }
  $ls -join "`n"
}
# a category vector as one stacked bar (CSS gradient stops, the x-<key> colours)
function Get-KitContextGradient($V) { $t = [double](@($V | ForEach-Object { [double]$_ }) + 0 | Measure-Object -Sum).Sum; if ($t -le 0) { return '' }; $acc = 0.0
  "linear-gradient(90deg,$(@(for ($i = 0; $i -lt 8; $i++) { $a1 = $acc; $acc += 100 * [math]::Max(0.0, [double]@($V)[$i]) / $t; "var(--x-$($script:KitCtxCats[$i][0])) $([math]::Round($a1, 2))% $([math]::Round($acc, 2))%" }) -join ','))" }
# the Runs band cell: the peak over a slim stacked bar of the carried mix; the tooltip every category and the waste
function Format-KitContextCell($Cx, [string]$Head = '') {
  $enc = { param($s) [Net.WebUtility]::HtmlEncode("$s") }
  if (-not $Cx -or -not [int]$Cx.n) { return "<span class='gc cxc z' title='context not recorded (no model call read yet)'>—</span>" }
  $car = @($Cx.car); $t = [math]::Max(1.0, [double](@($car | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum)
  "<span class='gc cxc' title='$(& $enc (Get-KitContextTip $Cx $Head))'><b>$(& $enc (Format-KitCompactNum $Cx.pk))</b><span class=cxb aria-hidden=true>$(@(for ($i = 0; $i -lt 8; $i++) { if ([double]$car[$i] -gt 0) { "<i class=x-$($script:KitCtxCats[$i][0]) style='flex-grow:$([math]::Max(1, [math]::Round(1000 * [double]$car[$i] / $t)))'></i>" } }) -join '')</span></span>"
}
# the context rows of the last usage pass: workflow steps, agents outside workflows (all CLIs), coordinator sessions; each with cx
function Get-KitContextSteps($U) {
  @(@(@($U.runs) | ForEach-Object { @($_.steps) }) + @($U.agentSteps) + @(@($U.coord) | ForEach-Object { [pscustomobject]@{ label = "session $($_.session)"; role = 'coordinator'; run = ''; model = $_.model; at = $_.at; cx = $_.cx; tf = '' } }) | Where-Object { $_ -and $_.cx -and [int]$_.cx.n })
}
# usage -Context (owner 2026-11-22): the dashboard's context numbers as text or JSON, to act on (-Refresh: a usage pass first, up to 180 s)
function Invoke-KitContextUsage {
  param([switch]$Context, [string]$Agent = '', [string]$Run = '', [string]$Type = '', [string]$Since = '7d', [switch]$Json, [switch]$Refresh)
  if (-not $Context) { Stop-KitVerb 'usage: bossy.ps1 usage -Context [-Agent <id> | -Run <run> | -Type <role>] [-Since 24h|7d] [-Json] [-Refresh]' 2 }
  if ($Since -match '^\d+$') { $Since = "${Since}d" }   # from pwsh, 7d is the decimal literal 7
  if ($Since -notmatch '^(\d+)([mhd])$') { Stop-KitVerb "usage -Context: -Since '$Since': <n>m, <n>h or <n>d" 2 }
  $cut = (Get-Date).AddMinutes(-[double]$Matches[1] * @{ m = 1; h = 60; d = 1440 }[$Matches[2]])
  $u = if ($Refresh) { Get-KitUsage -Seconds (Get-KitParam 'usage.passSeconds') } else { Read-KitUsageResult }; if (-not $u) { 'usage -Context: no usage pass yet (bossy.ps1 budget -Usage, or -Refresh)'; exit 1 }
  $ss = @(Get-KitContextSteps $u | Where-Object { $at = try { [datetime]"$($_.at)" } catch { $null }; (-not $at -or $at -ge $cut) -and (-not $Type -or "$($_.role)" -eq $Type) -and (-not $Run -or "$($_.run)" -eq $Run -or "$($_.wid)" -eq $Run) -and (-not $Agent -or "$($_.label)" -like "*$Agent*" -or [IO.Path]::GetFileNameWithoutExtension("$($_.tf)") -like "*$Agent*") } | Sort-Object { -[double]$_.cx.pk })
  $f = { param($v) if ([double]$v -le 0) { '0' } else { Format-KitCompactNum ([double]$v) } }
  $mix = { param($c) $car = @($c.car); $ct = [math]::Max(1.0, [double](@($car | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum); @(0..7 | Sort-Object { -[double]$car[$_] } | Select-Object -First 3 | ForEach-Object { "$($script:KitCtxCats[$_][1]) $([math]::Round(100 * [double]$car[$_] / $ct))%" }) -join ', ' }
  $obj = { param($s) $c = $s.cx; [ordered]@{ label = "$($s.label)"; role = "$($s.role)"; run = "$($s.run)"; model = "$($s.model)"; calls = [int]$c.n; start = [long]$c.s0; peak = [long]$c.pk; avg = [long]([double]$c.sum / [math]::Max(1, [int]$c.n)); compactions = [int]$c.cmp; handoff = [int]$c.ho
      carried = [ordered]@{}; added = [ordered]@{}; waste = @(Get-KitContextWaste $c); largest = @($c.top | Where-Object { $_ } | ForEach-Object { $p = "$_" -split '\|', 3; [ordered]@{ tokens = [long]$p[0]; source = $script:KitCtxCats[[int]$p[1]][1]; what = $p[2] } }) } }
  if ($Json) { @($ss | ForEach-Object { $o = & $obj $_; for ($i = 0; $i -lt 8; $i++) { $o.carried[$script:KitCtxCats[$i][1]] = [long]@($_.cx.car)[$i]; $o.added[$script:KitCtxCats[$i][1]] = [long]@($_.cx.add)[$i] }; [pscustomobject]$o }) | ConvertTo-Json -Depth 5 -Compress -AsArray; exit 0 }
  if (-not $ss.Count) { "usage -Context: no agent with a context record$(if ($Agent -or $Run -or $Type) { ' matches' }) since $($cut.ToString('MM-dd HH:mm'))"; exit 1 }
  $all = Join-KitContext @($ss | ForEach-Object { $_.cx })
  "context since $($cut.ToString('MM-dd HH:mm')): $($ss.Count) agent(s) · avg start $(& $f $all.s0) · avg peak $(& $f ([double]$all.pks / [math]::Max(1, [int]$all.agents))) · highest $(& $f $all.pk) · carried: $(& $mix $all)"
  foreach ($w in @(Get-KitContextWaste $all)) { "  waste: $w" }
  if (-not $Type -and -not $Agent) { 'by type:'; foreach ($g in @($ss | Group-Object { "$($_.role)" } | Sort-Object Count -Descending)) { $jc = Join-KitContext @($g.Group | ForEach-Object { $_.cx }); "  $($g.Name) $($g.Count): avg start $(& $f $jc.s0) · avg peak $(& $f ([double]$jc.pks / [math]::Max(1, [int]$jc.agents))) · $(& $mix $jc)$(if ($wz = @(Get-KitContextWaste $jc)[0]) { " · $wz" })" } }
  'agents (largest peak first):'
  foreach ($s in @($ss | Select-Object -First 25)) { $c = $s.cx; "  $($s.role) $($s.label)$(if ($s.run) { " [$($s.run)]" }): start $(& $f $c.s0) · peak $(& $f $c.pk) · avg $(& $f ([double]$c.sum / [math]::Max(1, [int]$c.n))) · $($c.n) calls$(if ([int]$c.cmp) { " · $($c.cmp) compaction(s)" }) · $(& $mix $c)$(if (@(Get-KitContextWaste $c).Count) { " · waste: $(@(Get-KitContextWaste $c) -join '; ')" })" }
  if ($ss.Count -gt 25) { "  ... $($ss.Count - 25) more (-Json for all)" }; exit 0
}
# supervise (owner 2026-11-22: "obvious things or serious issues in context: optimise them yourself like other ACTs"): a WATCH per live agent
# (near its budget, a file re-read, one oversized result, pasted build logs, a start over its type's learned norm); an ACT when a signal repeats
# in usage.context.actRuns+ agents, with the fix as a kitty task line; ended agents' starts teach usage.context.startNorm per type (once each)
function Get-KitSuperviseFlagsContext([switch]$AutoFix) {
  if (-not (Within 'context')) { return }; $u = Read-KitUsageResult; if (-not $u) { return }
  Get-KitContextFlags @(Get-KitContextSteps $u) (Get-Date) -Observe:$AutoFix
}
function Get-KitContextFlags($Steps, [datetime]$Now, [switch]$Observe) {
  $f = { param($v) if ([double]$v -le 0) { '0' } else { Format-KitCompactNum ([double]$v) } }; $fl = [Collections.Generic.List[object]]::new()
  $big = [double](Get-KitParam 'usage.context.bigResultTokens'); $rrW = [int](Get-KitParam 'usage.context.rereadWatch'); $fac = [double](Get-KitParam 'usage.context.startFactor'); $nAct = [int](Get-KitParam 'usage.context.actRuns')
  $beat = [double](Get-KitBeatMinutes); $ss = @($Steps | Where-Object { $_.cx -and "$($_.role)" -ne 'coordinator' })
  # live = running and its transcript written in the last 2 beats (a finished agent kept 'running' and its WATCHes, 2026-11-23)
  $isLive = { param($s) $tw = if ("$($s.tf)" -and (Test-Path -LiteralPath "$($s.tf)")) { (Get-Item -LiteralPath "$($s.tf)").LastWriteTime }
    if ($tw -and ($Now - $tw).TotalMinutes -ge 2 * $beat) { return $false }
    if ($s.result) { "$($s.result)" -in 'running', 'stuck' } else { $at = try { [datetime]"$($s.at)" } catch { $null }; $at -and ($Now - $at).TotalMinutes -lt 2 * $beat } }
  $norm = { param([string]$r) $rv = try { Resolve-KitParam 'usage.context.startNorm' $null $r (Get-KitParamState) } catch { @($null, 'default') }; if ("$($rv[1])" -notlike 'default*') { [double]$rv[0] } }   # only a learned (or pinned) norm: the 30k default would flag every main-session start
  $who = { param($s) "$($s.role) $(if ("$($s.label)".Trim()) { $s.label } else { [IO.Path]::GetFileNameWithoutExtension("$($s.tf)") })".Trim() }
  $wl = [Collections.Generic.List[object]]::new(); $cks = Read-KitCtxChecks
  foreach ($s in @($ss | Where-Object { & $isLive $_ })) { $c = $s.cx; $w = @($c.w); $nm = & $who $s
    $bo = Get-KitBudget -Tool $(if ("$($s.tool)" -in 'codex', 'antigravity', 'local') { "$($s.tool)" } else { '' }) -Model "$($s.model)"; $b = $bo.budget
    # its self-check answered at the last threshold: shown (INFO), no WATCH; asked, no answer: the WATCH says so
    $ck = $cks["$($s.tf)".ToLower()]; $dn = $ck.check -and [double]$ck.check.ctx -ge [double]$ck.asked
    if ($dn) { $fl.Add([pscustomobject]@{ level = 'INFO'; what = "context: $nm self-check $($ck.check.decision) at $(& $f $ck.check.ctx)"; action = "$($ck.check.reason)" }) }
    elseif ($bo.design -lt $b -and [double]$c.last -gt $bo.design) { $wl.Add(@(3, "context: $nm past the $(& $f $bo.design) design window", "at $(& $f $c.last) (the model holds $(& $f $b)), $(if ($ck.asked) { "self-check asked at $(& $f $ck.asked), no answer" } else { 'no self-check' }): board msg it to answer its CONTEXT-CHECK (continue or hand off)")) }
    # what = stable per agent (the flag key: Get-KitFlagKey keeps 412k as is), the moving numbers in the action
    $pw = [double](Get-KitParam 'usage.context.peakWatch'); if (-not $dn -and $b -and [double]$c.last -gt $pw * $b) { $wl.Add(@(3, "context: $nm over $([math]::Round(100 * $pw))% of its budget", "at $(& $f $c.last) of $(& $f $b): hand it off now (crafty.ps1 checkpoint -Brief, a fresh agent: README Budget); bossy.ps1 usage -Context -Agent <its label>")) }
    $ic = Get-KitInstrCap $b; $kl = [long]$c.kl + $ic.start   # kit docs held + the kit start
    if ($kl -gt $ic.cap) { $fl.Add([pscustomobject]@{ level = 'ACT'; what = "context: $nm holds kit instructions over the cap"; action = "$(& $f $kl) of cap $(& $f $ic.cap): its next board beat prints HANDOFF itself (checkpoint, fresh agent with its phase's instructions); no beat within 2 heartbeats: board msg it to hand off now" }) }
    elseif ($kl -gt $ic.watch) { $wl.Add(@(2, "context: $nm kit instructions near the cap", "$(& $f $kl) of cap $(& $f $ic.cap): reads whole skills or references; tell it to read only the section its step names")) }
    if ([int]@($c.rr)[0] -ge $rrW) { $wl.Add(@(2, "context: $nm re-reads $([IO.Path]::GetFileName("$(@($c.rr)[1])"))", "$(@($c.rr)[0])x, $(& $f $w[1]) tokens re-read: tell it to note what it needs from that file once, or read a range (offset / limit)")) }
    $t0 = "$(@($c.top)[0])" -split '\|', 3; if ([double]$t0[0] -gt $big) { $wl.Add(@(1, "context: $nm took an oversized result ($($t0[2]))", "$(& $f $t0[0]) tokens in one result: narrow that call (a range, a filter, the failure lines only)")) }
    if ([long]$w[4]) { $wl.Add(@(1, "context: $nm pasted full build / test logs", "$($w[4]) log(s), $(& $f $w[5]) tokens: read only the failing tests and errors (crafty.ps1 check prints them; the full log stays in its file)")) }
    $nr = & $norm "$($s.role)"; if ($nr -and [double]$c.s0 -gt $fac * $nr) { $wl.Add(@(0, "context: $nm start load over its type's norm", "started at $(& $f $c.s0) vs the $($s.role) norm $(& $f $nr): bossy.ps1 usage -Context -Type $($s.role), see what its start loads")) } }
  foreach ($x in @($wl | Sort-Object { -$_[0] } | Select-Object -First 8)) { $fl.Add([pscustomobject]@{ level = 'WATCH'; what = $x[1]; action = $x[2] }) }
  # ACT: a signal in actRuns+ agents of the window; the fix by source (owner: a param or setting -> -AutoFix; code / skill -> a kitty task line)
  # counts only agents started after the signal's last fix (Get-KitWasteFixes) and the last fix / perf(context) commit: a fixed signal stops (7-day window kept them)
  $wfx = Get-KitWasteFixes; $cAt = try { [datetimeoffset]"$(git -C $KitConf.Kit log -1 -E '--grep=^(fix|perf)\(context\)' --format=%cI 2>$null)".Trim() } catch { $null }
  $post = { param($s, [string]$k) $fa = @(@($cAt, $wfx["waste:$($s.role):$k"].at) | Where-Object { $_ } | Sort-Object)[-1]; -not $fa -or (($sa = try { [datetimeoffset]"$(if ($s.t0) { $s.t0 } else { $s.at })" } catch { $null }) -and $sa -gt $fa) }   # t0: its first call (at: its last)
  $fix = @{ 4 = 'trim build / test output to the failure lines at the source (crafty.ps1 check prints the full log path)'; 2 = 'read big code files in ranges, keep their facts in notes'; 3 = 'kit data commands print a summary, not the whole file'; 5 = 'make that command print only what the agent asks (a field filter, a line cap)'; 6 = 'fetch only the needed section of web pages and docs'; 0 = 'move detail behind a pointer'; 1 = 'shorter briefs and prompts'; 7 = 'shorter agent reports' }
  $grpBy = @{}; foreach ($s in @($ss | Where-Object { & $post $_ bigresult })) { foreach ($tp in @($s.cx.top | Where-Object { $_ })) { $p = "$tp" -split '\|', 3; if ([double]$p[0] -le $big) { continue }; $hd = (("$($p[2])" -replace '^(\S+)\s+(?:cd\s+\S+\s*(?:&&|;)\s*)?(?:\w+=\S*\s+)*', '$1 ') -split '\s+' | Select-Object -First 2) -join ' '; $gk = "$($p[1])|$hd"; if (-not $grpBy[$gk]) { $grpBy[$gk] = @{} }; $grpBy[$gk][(& $who $s)] = "$($s.role)" } }
  # one ACT per source class (owner 2026-11-22: 15 per-file lines a beat), its top sources by agents in the action
  foreach ($cg in @($grpBy.Keys | Where-Object { $grpBy[$_].Count -ge $nAct } | Group-Object { [int]("$_" -split '\|', 2)[0] } | Sort-Object Name)) {
    $hs = @($cg.Group | Sort-Object { -$grpBy[$_].Count }, { "$_" }); $who2 = @{}; foreach ($gk in $hs) { foreach ($a in $grpBy[$gk].Keys) { $who2[$a] = $grpBy[$gk][$a] } }
    $top = @($hs | Select-Object -First 5 | ForEach-Object { "$(("$_" -split '\|', 2)[1]) $($grpBy[$_].Count)" }) -join ', '; if ($hs.Count -gt 5) { $top += ", +$($hs.Count - 5) more" }
    $fl.Add([pscustomobject]@{ level = 'ACT'; what = "context: $($script:KitCtxCats[[int]$cg.Name][1]) results over $([long]$big) tokens in $($who2.Count) agents"; action = "Spawn kitty (kind fix): $($fix[[int]$cg.Name]) (top: $top; roles $(@($who2.Values | Sort-Object -Unique) -join ', '); bossy.ps1 usage -Context)" }) }   # roles in the action: a new role keeps the key
  $lg = @($ss | Where-Object { [long]@($_.cx.w)[4] -and (& $post $_ buildlog) }); if ($lg.Count -ge $nAct) { $fl.Add([pscustomobject]@{ level = 'ACT'; what = "context: full build / test logs pasted by $($lg.Count) agents"; action = "Spawn kitty (kind fix): $($fix[4]) (roles $(@($lg.role | Sort-Object -Unique) -join ', '))" }) }
  $rr = @($ss | Where-Object { [int]@($_.cx.rr)[0] -ge $rrW -and (& $post $_ reread) }); if ($rr.Count -ge $nAct) { $fl.Add([pscustomobject]@{ level = 'ACT'; what = "context: $($rr.Count) agents re-read one file $rrW+ times"; action = "Spawn kitty (kind fix): a step-0 rule in those skills: note a file's facts once, read ranges after (roles $(@($rr.role | Sort-Object -Unique) -join ', '))" }) }
  foreach ($g in @($ss | Where-Object { -not (& $isLive $_) -and (& $post $_ startload) } | Group-Object { "$($_.role)" })) { $nr = & $norm $g.Name; if (-not $nr) { continue }; $hi = @($g.Group | Where-Object { [double]$_.cx.s0 -gt $fac * $nr })
    if ($hi.Count -ge $nAct) { $fl.Add([pscustomobject]@{ level = 'ACT'; what = "context: $($g.Name) start load over $fac x its norm in $($hi.Count) agents"; action = "Spawn kitty (kind fix): cut $($g.Name)'s start load (avg $(& $f ((@($hi | ForEach-Object { [double]$_.cx.s0 }) | Measure-Object -Average).Average)) vs norm $(& $f $nr); kitbag.py cost, its agent file and skill)" }) } }
  if ($Observe) { Add-KitContextNormObs @($ss | Where-Object { -not (& $isLive $_) })
    $null = Add-KitWasteSignals (Get-KitWasteItems $ss) }   # W2: retro signals, /tidy applies them (Waste panel: open)
  $fl
}
# ended agents' start sizes -> the learned norm per type (usage.context.startNorm), each transcript once (cache/context-norm-seen.json)
function Add-KitContextNormObs($Ended) {
  $sf = Join-Path (Get-KitPath cache -Create) 'context-norm-seen.json'; $seen = try { Read-KitText $sf | ConvertFrom-Json -AsHashtable } catch { $null }; if ($seen -isnot [hashtable]) { $seen = @{} }
  $cut = (Get-KitStamp stored (Get-Date).AddDays(-(Get-KitParam 'usage.keepDays'))); $new = 0
  foreach ($s in @($Ended | Where-Object { $_.role -and [long]$_.cx.s0 })) { $k = "$(if ($s.tf) { $s.tf } else { "$($s.run)|$($s.label)" })"; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = (Get-KitStamp); $new++; Add-KitParamObs 'usage.context.startNorm' ([double]$s.cx.s0) "$($s.role)" }
  if ($new) { foreach ($k in @($seen.Keys | Where-Object { "$($seen[$_])" -lt $cut })) { $seen.Remove($k) }; try { Write-KitAtomic $sf ($seen | ConvertTo-Json -Compress) } catch { } }
}
# the role map's Context group (owner 2026-11-22: "cut devy's start context", "trim build output"; 2026-11-24: one role map): avg start (the
# instruction load), avg peak, start / peak, then each source's share of what its calls re-sent; no record: blank cells
function Get-KitContextRoleCells($Role, $Tk) {
  $c = $Role.cx; if (-not $c -or -not [int]$c.n) { return @{ v = @(1..11 | ForEach-Object { $null }); tx = @(1..11 | ForEach-Object { '' }); tips = @(1..11 | ForEach-Object { 'context not recorded' }); ag = 0 } }
  $ag = [math]::Max(1, [int]$c.agents); $car = @($c.car); $ct = [math]::Max(1.0, [double](@($car | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum); $pa = [double]$c.pks / $ag; $sh = if ($pa) { 100 * [double]$c.s0 / $pa } else { 0 }
  $pc = @(for ($i = 0; $i -lt 8; $i++) { 100 * [double]$car[$i] / $ct })
  @{ ag = $ag; v = @([double]$c.s0, $pa, $sh) + $pc; tx = @((& $Tk $c.s0), (& $Tk $pa), "$([math]::Round($sh))%") + @($pc | ForEach-Object { if ($_ -ge 0.5) { "$([math]::Round($_))%" } else { '' } })
    tips = @("avg start $(& $Tk $c.s0): the first call's context (system prompt, tools, instructions, prompt)", "avg peak $(& $Tk $pa) (highest $(& $Tk $c.pk))", "the start load is $([math]::Round($sh))% of the avg peak") + @(for ($i = 0; $i -lt 8; $i++) { "$($script:KitCtxCats[$i][1]): $(& $Tk $car[$i]) re-sent, $([math]::Round($pc[$i]))%" }) }
}
function Format-KitContextLegend { "<span class=kleg>$(@($script:KitCtxCats | ForEach-Object { "<i class='lgk x-$($_[0])'></i>$($_[1])" }) -join ' ')</span>" }

# ---- waste (owner 2026-11-23: every item shown, never hidden, each tagged): fixed (a win signal "fixed in <commit>", ref waste:<role>:<kind>)
# · open (its signal raised, not fixed) · fixable (over usage.context.wasteMinTokens, or in actRuns+ runs: supervise raises it) · ignored (under, one-off)
$script:KitWasteFix = [ordered]@{ startload = 'slim the role''s start files (kitbag.py budget)'; reread = 'a note-once / read-range lesson, or a reader agent'; bigresult = 'a narrower command (a filter, a range)'; buildlog = 'the failure lines only (crafty.ps1 check)' }
# fixed waste keys -> @{ sha; at }: a win signal "fixed in <sha>" or a kit commit trailer "Waste-Fix: waste:<role>:<kind>" (owner 2026-11-24), dated by its commit
function Get-KitWasteFixes($Signals = $null) {
  if ($null -eq $Signals) { $Signals = @(Get-Content -LiteralPath (Get-KitPath signals) -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { "$($_.ref)" -like 'waste:*' }) }
  $tOf = { param($v) try { [datetimeoffset]"$v" } catch { $null } }; $fixed = @{}
  if (-not $script:KitShaAt) { $script:KitShaAt = @{} }   # a commit's time: one git call per sha a process
  foreach ($g in @($Signals | Where-Object { $_ -and "$($_.kind)" -eq 'win' })) { $gk = "$($g.ref)"
    $sha = if ("$($g.text)" -match 'fixed in (\w+)') { $Matches[1] } else { 'kit' }; if ($sha -ne 'kit' -and -not $script:KitShaAt.ContainsKey($sha)) { $script:KitShaAt[$sha] = & $tOf "$(git -C $KitConf.Kit log -1 --format=%cI $sha 2>$null)" }; $ct = $script:KitShaAt[$sha]; $fixed[$gk] = @{ sha = $sha; at = $(if ($ct) { $ct } else { & $tOf $g.at }) } }
  foreach ($cl in @(git -C $KitConf.Kit log --since=30.days --grep=Waste-Fix: '--format=%h%x09%cI%x09%(trailers:key=Waste-Fix,valueonly,separator=%x2C)' 2>$null)) { $cp = "$cl" -split "`t"; if ($cp.Count -lt 3) { continue }
    foreach ($ck in @($cp[2] -split '\s*,\s*' | Where-Object { $_ -like 'waste:*' })) { $cat = & $tOf $cp[1]; if (-not $fixed[$ck] -or ($cat -and $cat -gt $fixed[$ck].at)) { $fixed[$ck] = @{ sha = $cp[0]; at = $cat } } } }
  $fixed
}
function Get-KitWasteItems($Steps, $Signals = $null) {
  $min = [double](Get-KitParam 'usage.context.wasteMinTokens'); $nAct = [int](Get-KitParam 'usage.context.actRuns'); $aim = [double](Get-KitParam 'usage.context.startAim'); $f = { param($v) Format-KitCompactNum ([double]$v) }
  if ($null -eq $Signals) { $Signals = @(Get-Content -LiteralPath (Get-KitPath signals) -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { "$($_.ref)" -like 'waste:*' }) }
  # fixed: a win signal "fixed in <sha>" or a kit commit trailer "Waste-Fix: waste:<role>:<kind>" (owner 2026-11-24), dated by its commit;
  # closed: /tidy's false-positive signal (its reason); an item after its fix = seen again (open), before = fixed
  $tOf = { param($v) try { [datetimeoffset]"$v" } catch { $null } }; $raised = @{}; $closed = @{}; $fixed = Get-KitWasteFixes $Signals
  foreach ($g in @($Signals | Where-Object { $_ -and "$($_.kind)" -ne 'win' })) { $gk = "$($g.ref)"; if ("$($g.kind)" -eq 'false-positive') { $closed[$gk] = "$($g.text)" } else { $raised[$gk] = "$($g.at)" } }
  $its = @(foreach ($s in @($Steps | Where-Object { $_ -and $_.cx -and [int]$_.cx.n })) { $c = $s.cx; $w = @($c.w); $rr = @($c.rr); $who = "$(if ("$($s.label)".Trim()) { $s.label } else { [IO.Path]::GetFileNameWithoutExtension("$($s.tf)") })"
      $mk = { param($k, $t, $what) [pscustomobject]@{ role = "$($s.role)"; who = $who; run = "$(if ($s.run) { $s.run } else { $who })"; kind = $k; tokens = [long]$t; what = $what; key = "waste:$($s.role):$k"; at = "$($s.at)" } }
      if ([int]$rr[0] -ge 2) { & $mk reread $w[1] "re-read $([IO.Path]::GetFileName("$($rr[1])")) $($rr[0])x" }
      if ([long]$w[2]) { & $mk bigresult $w[3] "$($w[2]) result(s) over $(& $f (Get-KitParam 'usage.context.bigResultTokens'))" }
      if ([long]$w[4]) { & $mk buildlog $w[5] "$($w[4]) build / test log(s) pasted" } })
  $runsOf = @{}; foreach ($g in @($its | Group-Object key)) { $runsOf[$g.Name] = @($g.Group.run | Sort-Object -Unique).Count }
  # W3 start load: one item per role (every agent of it would bury the rest: 2,350 of 2,734 items), its avg start vs usage.context.startAim
  foreach ($g in @($Steps | Where-Object { $_ -and $_.cx -and [int]$_.cx.n -and [double]$_.cx.s0 } | Group-Object { "$($_.role)" })) { $k = "waste:$($g.Name):startload"; $fx = $fixed[$k]
    $post = @(if ($fx -and $fx.at) { $g.Group | Where-Object { ($pa = & $tOf $_.at) -and $pa -gt $fx.at } }); $use = if ($post.Count) { $post } else { @($g.Group) }   # re-measured on the runs after its fix
    $avg = [double](@($use | ForEach-Object { [double]$_.cx.s0 }) | Measure-Object -Average).Average
    if (-not $aim -or ($avg -le $aim -and -not $fx)) { continue }; $runsOf[$k] = @($use | ForEach-Object { if ($_.run) { "$($_.run)" } else { "$($_.label)" } } | Sort-Object -Unique).Count
    $its += [pscustomobject]@{ role = $g.Name; who = "$($use.Count) agent(s)"; run = ''; kind = 'startload'; tokens = [long][math]::Max(0, $avg - $aim); what = "avg start $(& $f $avg) vs the $(& $f $aim) aim"; key = $k; at = $(if ($post.Count -and $avg -gt $aim) { "$(@($post | Sort-Object { "$($_.at)" })[-1].at)" }) } }
  $rank = @{ fixable = 0; open = 1; fixed = 2; ignored = 3 }
  @(foreach ($i in $its) { $n = $runsOf[$i.key]; $fx = $fixed[$i.key]; $after = $fx -and $fx.at -and ($ia = & $tOf $i.at) -and $ia -gt $fx.at
      $tag, $why = if ($fx -and -not $after) { 'fixed', "fixed in $($fx.sha)" } elseif ($after) { 'open', "seen again after the fix $($fx.sha): $($script:KitWasteFix[$i.kind])" } elseif ($closed[$i.key]) { 'ignored', "closed by /tidy: $($closed[$i.key])" }
        elseif ($raised[$i.key]) { 'open', "retro signal raised $("$($raised[$i.key])".Substring(0, [math]::Min(10, "$($raised[$i.key])".Length))), not fixed: $($script:KitWasteFix[$i.kind])" }
        elseif ($i.tokens -ge $min -or $n -ge $nAct) { 'fixable', "$(& $f $i.tokens) tokens$(if ($i.tokens -ge $min) { ", over $(& $f $min)" })$(if ($n -ge $nAct) { ", in $n runs: a retro signal" }) -> $($script:KitWasteFix[$i.kind])" }
        else { 'ignored', "$(& $f $i.tokens) tokens, under $(& $f $min), one-off" }
      $i | Add-Member -Force NoteProperty tag $tag -PassThru | Add-Member -Force NoteProperty why $why -PassThru | Add-Member -Force NoteProperty runs $n -PassThru }) | Sort-Object { $rank[$_.tag] }, { -$_.tokens }
}
# W2: a pattern (role + kind) in actRuns+ runs, neither raised nor fixed -> ONE counted retro signal with its fix kind; /tidy applies it,
# then records `bossy.ps1 learn -Skill <role> -Kind win -Text "fixed in <commit>" -Ref waste:<role>:<kind>`
function Add-KitWasteSignals($Items) {
  $nAct = [int](Get-KitParam 'usage.context.actRuns'); $n = 0
  foreach ($g in @($Items | Where-Object { $_.tag -eq 'fixable' -and $_.runs -ge $nAct } | Group-Object key)) { $i = $g.Group[0]; $tk = [long](@($g.Group.tokens) | Measure-Object -Sum).Sum
    Write-KitLog signals '' ([ordered]@{ skill = $i.role; kind = 'friction'; text = "waste: $($i.role) $($i.kind) in $($i.runs) runs, $(Format-KitCompactNum $tk) tokens; fix: $($script:KitWasteFix[$i.kind])"; ref = $g.Name; source = 'supervise' }); $n++ }
  $n
}
# waste per role (owner 2026-11-24: no panel of its own, a column group of the role heat map): one item per role + kind (its most urgent
# tag, its runs, tokens summed); per role the fixable / open / fixed counts, each cell's tooltip its items and reasons, the ignored ones apart
$script:KitWasteDays = 7   # the usage pass's window
function Group-KitWasteItems($Items) {
  $rk = @{ fixable = 0; open = 1; fixed = 2; ignored = 3 }
  @(@($Items | Where-Object { $_ }) | Group-Object { "$($_.role)|$($_.kind)" } | ForEach-Object { $gi = @($_.Group | Sort-Object { $rk["$($_.tag)"] }, { -[double]$_.tokens }); $g0 = $gi[0]
      $gr = @($gi | ForEach-Object { if ("$($_.run)") { "$($_.run)" } else { "$($_.who)" } } | Sort-Object -Unique).Count
      [pscustomobject]@{ tag = $g0.tag; why = $g0.why; role = $g0.role; kind = $g0.kind; run = $g0.run; tokens = [long](@($gi.tokens) | Measure-Object -Sum).Sum; what = $(if ($gi.Count -gt 1) { "$($g0.what) · $($gi.Count) items" } else { $g0.what }); who = $(if ($gr -gt 1) { "$gr runs" } else { $g0.who }) } } | Sort-Object { $rk["$($_.tag)"] }, { -$_.tokens })
}
# role -> @{ v = 3 counts; tx; tips = the items of each tag ("<kind>: <what> · <who> · <tokens>: <why>"); ignored = their lines }
function Get-KitWasteRoleCells($Items) {
  $by = @{}; foreach ($g in @(Group-KitWasteItems $Items | Group-Object role)) { $gi = @($g.Group)
    $ln = { param($t) @($gi | Where-Object tag -eq $t | ForEach-Object { "$($_.kind): $($_.what) · $($_.who) · $(Format-KitCompactNum ([double]$_.tokens)): $($_.why)" }) }
    $c = @(foreach ($t in 'fixable', 'open', 'fixed') { , @(& $ln $t) })
    $by[$g.Name] = @{ v = @($c | ForEach-Object { [double]$_.Count }); tx = @($c | ForEach-Object { if ($_.Count) { "$($_.Count)" } else { '' } }); tips = @($c | ForEach-Object { if ($_.Count) { $_ -join "`n" } else { 'none' } }); ignored = (@(& $ln ignored) -join "`n") } }
  $by
}
function Format-KitWasteLegend([int]$Days = $script:KitWasteDays) {
  "waste, last $Days days, one item per role + kind: fixable = over $(Format-KitCompactNum ([double](Get-KitParam 'usage.context.wasteMinTokens'))) tokens or in $(Get-KitParam 'usage.context.actRuns')+ runs (supervise raises a retro signal) · open = signal raised, not fixed, or seen again after its fix · fixed = a win signal or a kit commit's Waste-Fix: trailer, no run after it shows the pattern · ignored (the role's tooltip) = under the threshold, one-off, or closed by /tidy with its reason · hover a cell for its items"
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
  "<span class=kleg>Tokens: $(& $sw out output) $(& $sw in fresh) $(& $sw cw 'cache write') $(& $sw cr 'cache read') $(& $sw tot total) · Time: $(& $sw mo model) $(& $sw to tools) $(& $sw wa waiting)</span>"   # each group named (was one run-on line: "total · model")
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
# the kit-instruction cap of a budget window: min(cap, capPct x window); watch = watchAt x it (a 32k local model: 12k, 9.6k)
function Get-KitInstrCap([double]$Window) {
  $ei = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget.instructions
  $cap = [double](Get-KitSetting 'budget.instructions.cap' $ei.cap); $pct = [double](Get-KitSetting 'budget.instructions.capPct' $ei.capPct)
  if ($Window -gt 0 -and $pct -gt 0) { $cap = [math]::Min($cap, $pct * $Window) }
  $st = [double](Get-KitSetting 'budget.instructions.start' $ei.start); $cap = [math]::Max($cap, $st + [double](Get-KitSetting 'budget.instructions.skillAlways' $ei.skillAlways))   # a small window still holds the kit start + one skill
  [pscustomobject]@{ start = [int]$st; cap = [int]$cap; watch = [int]($cap * [double](Get-KitSetting 'budget.instructions.watchAt' $ei.watchAt)) }
}
# the agent tool this runs under: a model id's prefix, KIT_TOOL, then the tool's own env vars
function Get-KitTool([string]$Model = '') {
  $envs = @(Get-ChildItem env: | ForEach-Object Name)
  if ($Model -match '^local/') { 'local' } elseif ($Model -match '^(claude|opus|sonnet|haiku)') { 'claude' } elseif ($Model -match '^gpt') { 'codex' }
  elseif ($Model -match '^gemini') { 'antigravity' } elseif ($v = $env:KIT_TOOL) { $v } elseif ($env:CLAUDECODE) { 'claude' }
  elseif ($envs -like 'CODEX_*') { 'codex' } elseif ($envs -match 'ANTIGRAVITY') { 'antigravity' } else { 'unknown' }
}
# workflow model tiers of a tool: models.tiers.<tool> (kit.local.json per key over the example); a missing tier = the next stronger, then '' (inherit)
function Get-KitTiers([string]$Tool = '') {
  if (-not $Tool) { $Tool = Get-KitTool }
  $ex = Get-KitMember (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).models.tiers $Tool
  $t = [ordered]@{}; $up = ''
  $lo = Get-KitSetting "models.tiers.$Tool" $null   # a local key set to '' = unset: the next stronger tier, not the sample's
  foreach ($k in 'strong', 'balanced', 'fast') { $v = "$(if ($lo -and (Get-KitProps $lo).Name -contains $k) { Get-KitMember $lo $k } else { Get-KitMember $ex $k })"; if ($v) { $up = $v }; $t[$k] = $up }
  $t['inherit'] = ''; $t
}
function Get-KitBudget([string]$Tool = '', [string]$Model = '', [int]$Window = 0, [string]$Role = '') {
  $ex = (Get-Content (Join-Path $KitConf.Kit 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).budget
  $row = { param($n) $o = Get-KitSetting "budget.defaults.$n" $null; if ($o) { $o } else { (Get-KitMember $ex.defaults $n) } }
  if (-not $Tool) { $Tool = Get-KitTool $Model }
  $n = 'unknown'; $tok = 0; $src = ''
  if ($Tool -eq 'claude') {
    if (-not $Model) { $Model = "$env:ANTHROPIC_MODEL" }
    # budget.models [{match, row}]: first match picks the row (kit.local.json list wins over the example's)
    $m = $Model.ToLower(); $mr = @(@(Get-KitSetting 'budget.models' $ex.models) | Where-Object { $_.match -and $m -match $_.match })[0]
    $big = $mr.row -eq 'claude-1m'
    if ($mr -or $m -match 'claude|opus|sonnet|haiku') {
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
  } elseif ($Tool -eq 'antigravity') { $n = 'antigravity'; $tok = if ($Window) { [int]($Window * [double](& $row $n).fraction) } else { [int](& $row $n).tokens } }   # no window known (board join): the row's tokens
  elseif ($Tool -eq 'local') { $n = 'local'; $tok = [int](& $row $n).tokens   # the server's context: llama.cpp LLAMA_ARG_CTX_SIZE (-c), Ollama OLLAMA_CONTEXT_LENGTH
    if ($Window) { $tok = $Window; $src = 'window given' } elseif ($v = $env:LLAMA_ARG_CTX_SIZE) { $tok = [int]$v; $src = 'llama n_ctx (LLAMA_ARG_CTX_SIZE)' } elseif ($v = $env:OLLAMA_CONTEXT_LENGTH) { $tok = [int]$v; $src = 'ollama OLLAMA_CONTEXT_LENGTH' } }
  if (-not $tok) { $n = 'unknown'; $tok = [int](& $row $n).tokens }
  if (-not $src) { $src = (& $row $n).source }
  # handoff = whichever comes first (owner 2026-11-23): handoffAt x the tool's own cap, or the kit's budget for the role (budget.agentCap.<role>,
  # else .default; 0 = none); design window = min(budget.window, the tool's cap): instruction cap and the WATCH past it (optimise for 200k)
  $win = [int](Get-KitSetting 'budget.window' $ex.window); if ($win -le 0) { $win = [int]$ex.window }; $dw = [int][math]::Min($win, $tok)
  $h = [double](Get-KitSetting 'budget.handoffAt' $ex.handoffAt); $ho = [int]($tok * $h); $by = "$n $h x ($src)"
  $rv = if ($Role) { Get-KitSetting "budget.agentCap.$Role" (Get-KitMember $ex.agentCap $Role) }   # a role's 0 = none, even over a default
  $kc = if ($null -ne $rv) { [int]$rv } else { [int](Get-KitSetting 'budget.agentCap.default' $ex.agentCap.default) }
  if ($kc -gt 0 -and $kc -lt $ho) { $ho = $kc; $by = "kit budget $(if ($null -ne $rv) { $Role } else { 'default' })" }
  $ic = Get-KitInstrCap $dw
  [pscustomobject]@{ tool = $Tool; model = $Model; row = $n; budget = $tok; handoff = $ho; capBy = $by; handoffAt = $h; design = $dw; instrCap = $ic.cap; instrWatch = $ic.watch; runStopAt = [double](Get-KitSetting 'budget.runStopAt' $ex.runStopAt); source = $src }
}
# ---- handoffs: a budget handoff and its successor (board join CONTINUE, supervise HANDOFF)
# open = no successor: none marked, no later row of that agent (not $Except) in its run, or any run for a one-per-machine agent
# named after its type (kitty ran as kit-build); area ids (D1) repeat across runs
# a handoff's successor: same run, or same type + area on the next letter suffix (kit-x-1520c -> kit-x-1520d)
function Test-KitRunLineage($Ho, $Row) { "$($Row.run)" -eq "$($Ho.run)" -or ($Ho.run -and $Ho.type -and $Row.type -eq $Ho.type -and "$($Row.area)" -eq "$($Ho.area)" -and ("$($Row.run)" -replace '(?<=\d)[a-z]$') -eq ("$($Ho.run)" -replace '(?<=\d)[a-z]$')) }
# same run, another agent of its type on its area or worktree (devy-40 continued devy-39's area)
function Test-KitAreaHeir($Ho, $Row) { "$($Row.run)" -eq "$($Ho.run)" -and $Row.agent -ne $Ho.agent -and (-not $Ho.type -or -not $Row.type -or $Row.type -eq $Ho.type) -and (("$($Ho.area)" -and "$($Row.area)" -eq "$($Ho.area)") -or @(@($Ho.worktrees) | Where-Object { $_ -and $_ -in @($Row.worktrees) }).Count) }
function Get-KitHandoffs([double]$Hours = 48, [string]$Except = '') {
  $boardRows = @(Read-KitJsonFiles (Get-KitPath board))
  @($boardRows | Where-Object { $ho = $_; $ho.handoffBrief -and -not $ho.continuedBy -and ((Get-Date) - [datetime]$ho.beat).TotalHours -lt $Hours -and
      -not @($boardRows | Where-Object { (($_.agent -eq $ho.agent -and ("$($_.run)" -eq "$($ho.run)" -or $ho.agent -eq $ho.type)) -or ($_.agent -ne $ho.agent -and (Test-KitRunLineage $ho $_) -and "$($_.run)" -ne "$($ho.run)") -or (Test-KitAreaHeir $ho $_)) -and $_.session -ne $Except -and $_.session -ne $ho.session -and $_.joined -and [datetime]$_.joined -gt [datetime]$ho.beat }).Count })
}
# ---- limits: a model's usage limit (owner 2026-11-26): one ACT per limit with its reset time; workflows fall back one tier (@up)
# the tail of each agent transcript written in $Hours (a limit ends the agent: its last lines); Claude Code's "You've hit your ... limit" text
function Get-KitUsageLimits([double]$Hours = 3, [int]$TailBytes = 65536) {
  $cut = (Get-Date).AddHours(-$Hours); $got = [ordered]@{}
  foreach ($wd in @(Get-KitRecentWorkflowDirs -Hours $Hours)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $wd.FullName -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $cut)) {
      $tx = try { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); try { $n = [int][math]::Min($TailBytes, $fs.Length); $null = $fs.Seek(-$n, 'End'); $b = [byte[]]::new($n); $null = $fs.Read($b, 0, $n); [Text.Encoding]::UTF8.GetString($b) } finally { $fs.Dispose() } } catch { '' }
      if ($tx -notmatch 'usage_limit_reached') { continue }
      $msg = if ($tx -match '"text":"(You[^"]{0,40}hit your [^"]{0,160})"') { $Matches[1] -replace '\\u00b7', '·' } else { 'usage limit reached' }
      $mdl = @([regex]::Matches($tx, '"model":"(claude-[^"]+)"') | ForEach-Object { $_.Groups[1].Value })[-1]; if (-not $mdl) { $mdl = 'a model' }
      if (-not $got.Contains($msg)) { $got[$msg] = [pscustomobject]@{ text = $msg; models = [Collections.Generic.List[string]]::new(); runs = [Collections.Generic.List[string]]::new(); at = $f.LastWriteTime } }
      $l = $got[$msg]; if (-not $l.models.Contains($mdl)) { $l.models.Add($mdl) }; if (-not $l.runs.Contains($wd.Name)) { $l.runs.Add($wd.Name) }; if ($f.LastWriteTime -gt $l.at) { $l.at = $f.LastWriteTime } } }
  @($got.Values)
}
function Get-KitSuperviseFlagsUsageLimit([switch]$AutoFix, [double]$Hours = 3) {
  foreach ($l in @(Get-KitUsageLimits $Hours)) {
    [pscustomobject]@{ level = 'ACT'; what = "USAGE LIMIT: $($l.text)"; kind = 'USAGE LIMIT'; who = "$(@($l.models) -join ', ') in run(s) $(@($l.runs) -join ', ')"; age = "$([int]((Get-Date) - $l.at).TotalMinutes) min"
      problem = "$($l.text) (agents on $(@($l.models) -join ', ')); they stop"; action = "buildy / testy steps retry once on the next tier (<label>@up); until the reset: point that tier at an available model (kit.local.json models.tiers), then resume the stopped run (bossy.ps1 resume -All)" } }
}
# ---- workflow config: the CONFIG line of launch -Self (from bossy.ps1: its cap)
# a workflow's config (CONFIG line of launch -Self): models.<phase>, repos[].role by name + alias, qa.lanes
function Get-KitWorkflowConfig {
  $roles = [ordered]@{}; $local = [ordered]@{}
  foreach ($r in @(Get-KitSetting 'repos' @())) { $nm = @(@($r.name) + @($r.aliases) | Where-Object { $_ } | ForEach-Object { "$_".ToLower() }); if ($r.role) { foreach ($n in $nm) { $roles[$n] = "$($r.role)".ToLower() } }
    # repos[].localTest optional / none: its localFallback; ci needs MR pipelines, else unit
    if ("$($r.localTest)" -in 'optional', 'none') { foreach ($n in $nm) { $local[$n] = $(if ("$($r.localFallback)" -eq 'unit' -or ($r.ci -and $r.ci.mrPipelines -eq $false)) { 'unit' } else { 'ci' }) } } }
  $plain = { param($o) if ($o) { $h = [ordered]@{}; foreach ($p in (Get-KitProps $o)) { if ($p.Name -notlike '_*') { $h[$p.Name] = $p.Value } }; if ($h.Count) { $h } } }
  [ordered]@{ models = (& $plain (Get-KitSetting 'models' $null)); tiers = Get-KitTiers; roles = $roles; local = $local; humanDoc = [bool]@(Get-KitProcessDocs | Where-Object key -eq 'testing-doc').Count; qaLanes = (& $plain (Get-KitSetting 'qa.lanes' $null)); intermittentRx = "$(Get-KitSetting 'qa.intermittentRx' '')" }
}
# ---- dead runs: a wave record (waves/<run>.json) whose open steps and findings hold no promotion (owner 2026-11-26; bossy.ps1
# track): its run marked done (launch -Done), or its workflow folder quiet 3x supervise.stuckMinutes (a step died: usage limit, crash)
function Test-KitWaveDead($W) { if ("$($W.run)" -in @(Get-KitFinishedRuns)) { return $true }
  $wd = @(Get-KitWorkflowDirs | Where-Object Name -eq "$($W.run)")[0]
  [bool]($wd -and ((Get-Date) - (Get-KitWorkflowLastWrite $wd)).TotalMinutes -ge 3 * [double](Get-KitParam 'supervise.stuckMinutes')) }
