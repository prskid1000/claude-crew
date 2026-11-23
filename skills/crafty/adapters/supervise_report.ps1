#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/ (moved out of lib.ps1 for its token cap). Exit codes: none here.
# supervise report: bossy.ps1 supervise -Brief tables, flags, acks, anomalies and the report file; the board's Doing · next;
# the supervise sweep (sections by learned cost, background calls).
# Sections: L6 supervise report · L156 transcript tails · L188 supervise sweep
# ---- supervise report: -Brief, no LLM step; pure on $d, so fixtures test it
# a FINISHED row shows for supervise.finishedMinutes after it ended
function Select-KitBriefRows($Rows, [datetime]$Now) {
  $fm = [double](Get-KitParam 'supervise.finishedMinutes')
  @($Rows | Where-Object { $_.state -ne 'FINISHED' -or -not $_.ended -or ($Now - [datetime]$_.ended).TotalMinutes -le $fm })
}
function Format-KitReport($d) {
  $g1 = { param($x) [math]::Round([double]$x, 1) }
  $reportLines = [Collections.Generic.List[string]]::new()
  foreach ($l in @(Format-KitStatusTable $d.rows $d.at $null -Cap 80) + '') { $reportLines.Add($l) }
  # flags: ACT, WATCH, then INFO (deploy-ready envs)
  $fl = @(@($d.flags | Where-Object { $_.level -ne 'INFO' } | Sort-Object { @{ ACT = 0; WATCH = 1 }[$_.level] }) + @($d.info | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = $_; action = '' } }))
  if ($fl.Count) { $reportLines.Add('| Level | Flag | Who / item | Age | Problem | Next step |'); $reportLines.Add('|---|---|---|---|---|---|') }
  foreach ($f in $fl) {
    $c = Get-KitFlagCells $f -Fill:($f.level -ne 'INFO')
    $reportLines.Add("| $($f.level) | $(@($c.kind, $c.who, $c.age, $c.problem, $c.action | ForEach-Object { if ("$_".Trim()) { Format-KitCell (Limit-KitCell $_ 80) -Exact } else { '—' } }) -join ' | ') |")
  }
  if ($fl.Count) { $reportLines.Add('') }   # GFM: a plain line right after a table becomes a row
  # RAM below the flags: the owner reads flags first
  $m = $d.mem
  $reportLines.Add("**RAM** $(& $g1 ($m.TotalGB - $m.AvailGB)) / $(& $g1 $m.TotalGB) GB used, $(& $g1 $m.AvailGB) GB free$(if ($m.AvailGB -lt $d.keepFree) { " (below the floor $($d.keepFree) GB)" })")
  $rs = @($d.resources | Sort-Object { -[double]$_.gb })
  if ($rs.Count) {
    # up to 3 column groups side by side: 9 columns fit only short cells (words at 9, cells at 24)
    $gs = if ($rs.Count -le 4) { 1 } elseif ($rs.Count -le 8) { 2 } else { 3 }
    $reportLines.Add(''); $reportLines.Add('|' + ' Resource | Used by | RAM |' * $gs); $reportLines.Add('|' + '---|' * (3 * $gs))
    $rc = @(foreach ($r in $rs) { "$(Limit-KitCell (Format-KitCell $r.name 9) 24) | $(if ($r.by) { Limit-KitCell (Format-KitCell $r.by 9) 24 }) | $(if ($r.gb) { & $g1 $r.gb })" })
    for ($i = 0; $i -lt $rc.Count; $i += $gs) { $row = @($rc[$i..([math]::Min($i + $gs, $rc.Count) - 1)]); while ($row.Count -lt $gs) { $row += ' |  | ' }; $reportLines.Add('| ' + ($row -join ' | ') + ' |') }
  }
  $reportLines.Add('')
  foreach ($l in @(Format-KitShellTable $d.shells)) { $reportLines.Add($l) }
  @($reportLines)
}
# Get-KitShellSweep rows: problems first, then oldest
function Format-KitShellTable($Shells) {
  if (-not @($Shells | Where-Object { $_ }).Count) { return }
  $cut = { param($t, [int]$m) if ("$t".Trim()) { Limit-KitCell (Format-KitCell $t -Exact) $m } else { '—' } }
  '| Shell | Owner | Age | State | Next |'; '|---|---|---|---|---|'
  foreach ($s in @($Shells | Sort-Object { $_.state -eq 'running' }, { -$_.age })) {
    "| $(& $cut $s.short 60) | $(& $cut $s.owner 40) | $(if ($s.age -ge 120) { '{0:0.#} h' -f ($s.age / 60) } else { "$($s.age) min" }) | $($s.state) | $(& $cut $s.next 80) |"
  }
  ''
}
# no producer kind: an upper-case lead ("RESTART LOOP: ...") is the kind, an id-like "<subject>:" (a digit in it) the who ("ATTENTION
# <task>: ..."; "DISK C: ..." keeps its text); -Fill (the flag tables, owner 2026-11-19: every row has a kind, who and age): no kind =
# the first word, no who = coordinator
function Get-KitFlagCells($f, [switch]$Fill) {
  $kind = $f.kind; $problem = $f.problem; $who = $f.who
  if (-not $kind -and "$($f.what)" -cmatch '^([A-Z]{3,}(?:[ -](?:[A-Z]{3,}|MR|PR))*):?\s+(.+)$') { $kind = $Matches[1]; if (-not $problem) { $problem = $Matches[2]; if (-not $who -and $problem -match '^([^\s:]*\d[^\s:]*):\s+(.+)$') { $who = $Matches[1]; $problem = $Matches[2] } } }
  if ($Fill -and -not $kind -and "$($f.what)" -match '[A-Za-z][\w-]*') { $kind = $Matches[0].ToUpper() }
  if ($Fill -and -not "$who".Trim() -and $f.level -in 'ACT', 'WATCH') { $who = 'coordinator' }
  [pscustomobject]@{ kind = $kind; who = $who; age = $f.age; problem = $(if ($problem) { $problem } else { $f.what }); action = $(if ($f.next) { $f.next } else { $f.action }) }
}
# a flag's identity across rounds: counts, times and sizes vary; an id list in another order is the same flag (an ack holds)
function Get-KitSortedLists([string]$T) { [regex]::Replace($T, '(?<![\w.-])[\w.-]*\w(?:\s*,\s*[\w.-]*\w)+', { param($m) (@($m.Value -split '\s*,\s*') | Sort-Object) -join ', ' }) }
function Get-KitFlagKey([string]$What) { $k = ((Get-KitSortedLists $What.ToLower()) -replace '\b\d+\b', '#' -replace '\s+', ' ').Trim(); $k.Substring(0, [math]::Min(160, $k.Length)) }
# -Ack text pasted from the -Brief table: cells add spaces after - / (word wrap), escape |, end in …, join with ·; counts vary
# lane ids as shown names first (K55: an ack copied from the shown flag, rm·Kestrel, matches a flag stored with rm2)
function ConvertTo-KitAckText([string]$Text, [switch]$NoSort) { $t = (ConvertTo-KitLaneText $Text).ToLower(); if (-not $NoSort) { $t = Get-KitSortedLists $t }; ($t -replace '\b\d+\b', '#') -replace '[\s\\|…·''"`]', '' }
# an ack matches the flag's whole line or any one cell; a short one only a whole flag or its kind + who start ("BUILDS · HQA")
function Get-KitAckWholes($Flag, [switch]$NoSort) { $c = Get-KitFlagCells $Flag; @((ConvertTo-KitAckText "$($Flag.what)" -NoSort:$NoSort), (ConvertTo-KitAckText "$($c.kind) $($c.who) $($c.problem)" -NoSort:$NoSort), $(if ($c.kind -and $c.who) { ConvertTo-KitAckText "$($c.kind) $($c.who)" -NoSort:$NoSort })) | Where-Object { $_ } }
# sorted (ids reordered) or as typed (a cut list "a, b…" is a prefix only unsorted)
function Test-KitAcked($Flag, [string[]]$Keys) { foreach ($ns in $false, $true) {
  $c = Get-KitFlagCells $Flag; $w = ConvertTo-KitAckText "$($Flag.what)" -NoSort:$ns; $cells = ConvertTo-KitAckText "$($c.kind) $($c.who) $($c.problem)" -NoSort:$ns; $wh = @(Get-KitAckWholes $Flag -NoSort:$ns)
  if (@($Keys | ForEach-Object { ConvertTo-KitAckText $_ -NoSort:$ns } | Where-Object { $_ -and ($_ -in $wh -or ($_.Length -ge 12 -and ($w.Contains($_) -or $cells.Contains($_)))) }).Count) { return $true } }
  $false
}
# -Ack under 20 characters: allowed when it is a last-round flag's whole text or its kind + who (a short flag has no longer start)
function Test-KitAckWhole([string]$Ack) {
  $s0 = try { Get-Content (Get-KitPath supervise-state) -Raw | ConvertFrom-Json } catch { $null }; $a = ConvertTo-KitAckText $Ack
  [bool]($a -and @($s0.lastFlags | Where-Object { $_ -and $a -in @(Get-KitAckWholes $_) }).Count)
}
# an ack of a flag with ackNeeds (no fix MR linked) names a decision id or an MR in its reason and hides it 2 h
# (a recorded decision, or an MR some task tracks: a made-up ref hides nothing)
function Test-KitAckRef([string]$Reason) {
  foreach ($d in [regex]::Matches("$Reason", '\bd-\d{8,}-[\w-]+')) { if (Test-Path -LiteralPath (Join-Path (Get-KitPath decisions) "$($d.Value).json")) { return $true } }
  $named = @([regex]::Matches("$Reason", '(?<r>[\w.-]+)(?:!|/-/merge_requests/|/pulls?/)(?<n>\d+)') | ForEach-Object { "$($_.Groups['r'].Value)!$($_.Groups['n'].Value)" })
  if (-not $named.Count) { return $false }
  [bool]@((Read-KitTracking).tasks.Values | ForEach-Object { @($_.mrs) } | Where-Object { $_ -and ("$_" -split '/')[-1] -in $named }).Count
}
# an acknowledged one (answered / proven false) hides 24 h
function Select-KitFlags($Flags, $Acks, [datetime]$Now) {
  $seen = @{}; $hid = 0; $live = @($Acks.Keys | Where-Object { ($Now - [datetime]$Acks[$_].at).TotalHours -lt 24 })
  $keep = @(foreach ($f in @($Flags)) { $k = Get-KitFlagKey $f.what; if ($seen[$k]) { continue }; $seen[$k] = 1
      $fk = if ($f.ackNeeds) { @($live | Where-Object { (Test-KitAckRef $Acks[$_].reason) -and ($Now - [datetime]$Acks[$_].at).TotalHours -lt 2 }) } else { $live }
      if ($f.level -ne 'INFO' -and $fk.Count -and (Test-KitAcked $f $fk)) { $hid++; continue }; $f })
  if ($hid) { $keep += [pscustomobject]@{ level = 'INFO'; what = "$hid acknowledged flag(s) hidden (supervise -Ack, 24 h)"; action = 'Nothing to do.' } }
  $keep
}
# flags with refs (UNTRACKED MR, ERROR SPIKE) store the refs, so a new ref flags again
function Add-KitFlagAck([string]$Ack, [string]$Reason) {
  $sf0 = Get-KitPath supervise-state -Create; $k0 = Get-KitFlagKey $Ack; $script:ackOut = ''
  Invoke-KitLocked $sf0 { $s0 = try { Get-Content $sf0 -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $s0) { $s0 = @{} }; if (-not $s0.acks) { $s0.acks = @{} }
    $hit = @($s0.lastFlags | Where-Object { $_ -and (Test-KitAcked ([pscustomobject]$_) @($k0)) }); $refs = @($hit | ForEach-Object { @($_.refs) } | Where-Object { $_ })
    $need = @($hit | Where-Object { $_.ackNeeds }); if ($need.Count -and -not (Test-KitAckRef $Reason)) { $script:ackOut = "REFUSED: no fix MR linked ($(@($need | ForEach-Object { "$($_.what)".Substring(0, [math]::Min(90, "$($_.what)".Length)) }) -join ' · ')): link it (the flag's track route / track add), or -Reason naming a decision id (d-...) or the fix MR (repo!n): hides 2 h"; return }
    if ($refs.Count) { if (-not $s0.known) { $s0.known = @{} }; foreach ($r in $refs) { $s0.known[$r] = (Get-KitStamp) } }
    if (-not $hit.Count -or @($hit | Where-Object { -not @(@($_.refs) | Where-Object { $_ }).Count }).Count) { $s0.acks[$k0] = @{ at = (Get-KitStamp); reason = $Reason } }
    Write-KitAtomic $sf0 ($s0 | ConvertTo-Json -Depth 5)
    $script:ackOut = "$(if ($refs.Count) { "known from now on (they no longer flag; a new one does): $(@($refs | Select-Object -First 5) -join ' · ')$(if ($refs.Count -gt 5) { " +$($refs.Count - 5)" })" } else { "acknowledged for $(if ($need.Count) { '2 h (no fix MR linked)' } else { '24 h' }): $k0" })$(if ($Reason) { " ($Reason)" })`n$(if ($hit.Count) { "hides $($hit.Count) flag(s) of the last round: $(@($hit | ForEach-Object { "$($_.what)".Substring(0, [math]::Min(90, "$($_.what)".Length)) }) -join ' · ')" } else { 'matches no flag of the last round: check the text (any later flag containing it hides)' })" }
  $script:ackOut
}
# supervise anomalies: pure -> WATCH flags + next state
function Get-KitAnomalies($c, $p) {
  $f = [Collections.Generic.List[object]]::new(); $AddF = { param($w, $a) $f.Add([pscustomobject]@{ level = 'WATCH'; what = $w; action = $a }) }; if (-not $p) { $p = @{} }
  if ($null -ne $p.outbox -and $c.outbox -gt [int]$p.outbox) { & $AddF "SILENT FAILURE: tracker outbox grew to $($c.outbox) write(s)" 'evidence .state/outbox.jsonl: tracker auth / network' }
  if ($null -ne $p.toolErrors -and $c.toolErrors -gt [int]$p.toolErrors) { & $AddF "SILENT FAILURE: $($c.toolErrors - [int]$p.toolErrors) new agent result error(s)" "evidence $($c.errorRun) journal" }
  [pscustomobject]@{ flags = @($f); state = @{ outbox = $c.outbox; toolErrors = $c.toolErrors } }
}
# supervise -Brief's report file: whole cells, one table per section
function Write-KitSuperviseReport($d, [string[]]$Md, [string[]]$Sweep, [string]$Next) {
  $ag = { param($st) Format-KitMdTable 'Agent', 'Task', 'State', 'Doing', 'Next' @($d.rows | Where-Object { ($_.state -eq 'FINISHED') -eq $st } | ForEach-Object { , @($_.name, $_.task, "$($_.state) $($_.wait)$($_.done)$($_.stopped)", $_.doing, $_.next) }) }
  $n = { param($l) @($d.flags | Where-Object level -eq $l).Count }
  @("# Supervise report $($d.at.ToString('yyyy-MM-dd HH:mm'))", "**Result:** $(& $n ACT) ACT · $(& $n WATCH) WATCH · $(@($d.rows | Where-Object state -ne 'FINISHED').Count) live · $Next$(if ($d.versions.Count) { " · transcripts: $(@($d.versions.Values | Sort-Object) -join ', ')" })", '') + $Md +
    @('', '## Agents (whole cells)', '') + @(& $ag $false) + @('', '## Finished today', '') + @(& $ag $true) + @('', '## All flags', '') +
    @(Format-KitMdTable 'Level', 'Flag', 'Action' @(@($d.flags | ForEach-Object { , @($_.level, $_.what, $_.action) }) + @($d.info | Where-Object { $_ } | ForEach-Object { , @('INFO', $_, '') }))) +
    @('', '## Resources', '') + @(Format-KitMdTable 'Resource', 'Holder', 'GB' @($d.resources | ForEach-Object { , @($_.name, $_.by, $_.gb) })) +
    @('', '## Shells (whole commands)', '') + @(Format-KitMdTable 'PID', 'Owner', 'Age min', 'State', 'Quiet min', 'Dir', 'Command', 'Last line', 'Next' @($d.shells | ForEach-Object { , @($_.pid, $_.owner, $_.age, $_.state, $_.quiet, $_.dir, ($_.cmd -replace '\r?\n', ' \n '), $_.last, $_.next) })) +
    @('', '## Sweep', '', '```text') + $Sweep + '```' | ForEach-Object { ConvertTo-KitLaneText "$_" } |   # one lane name (K55)
    Set-Content (Get-KitPath supervise-report -Create) -Encoding utf8
}
# board messages (bossy.ps1 board msg | inbox): one jsonl per agent; the unread ones as lines, then marked read (inbox, board beat and
# every gated build print them: a workflow step between beats still gets the coordinator's rule); -All: the read ones too
function Get-InboxFile([string]$Agent) { Join-Path (Get-KitPath board -Create) "inbox/$($Agent.ToLower() -replace '[^\w.-]', '_').jsonl" }
function Read-KitInboxNew([string]$Agent, [switch]$All) {
  if (-not $Agent) { return }; $f = Get-InboxFile $Agent; if (-not (Test-Path -LiteralPath $f)) { return }
  Invoke-KitLocked $f { $m = @(Get-Content -LiteralPath $f | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }); $new = @($m | Where-Object { $All -or -not $_.read })
    foreach ($x in $new) { "$(([datetime]$x.at).ToString('HH:mm')) from $($x.from)$(if ($x.kind -and $x.kind -ne 'note') { " [$($x.kind)]" }): $($x.text)$(if ($x.ref) { " (ref $($x.ref))" })" }
    $cut = (Get-Date).AddDays(-1)   # a read message is kept a day (the hourly rule dedupe), then dropped
    if (@($new | Where-Object { -not $_.read }).Count) { Write-KitAtomic $f ((@($m | Where-Object { -not $_.read -or $(try { [datetime]$_.at -gt $cut } catch { $false }) } | ForEach-Object { $_ | Add-Member -Force NoteProperty read $true; $_ | ConvertTo-Json -Compress }) -join "`n") + "`n") } }
}
# crafty.ps1 gate: the build owner's unread messages first (a workflow step beats only between steps; it builds all the time); only a
# named agent (CLAUDE_AGENT) or one live on the board: a worktree-name owner never drains another agent's inbox
function Test-KitBoardAgent([string]$Agent) { [bool]@(Get-ChildItem (Get-KitPath board) -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt (Get-Date).AddDays(-1) | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } } | Where-Object { "$($_.agent)" -eq $Agent -and $_.status -ne 'left' }).Count }
function Show-KitGateInbox([string]$Owner) { if (-not $env:CLAUDE_AGENT -and -not (Test-KitBoardAgent $Owner)) { return }; foreach ($m in @(try { Read-KitInboxNew $Owner } catch { })) { Write-Host "[gate] MESSAGE for $Owner (follow it for this and every later build): $m" } }
# -Brief stdout (supervise.output): html = link, ACT / WATCH / fix lines, counts; chat = tables; both
function Format-KitSuperviseOut($d, $Shown, [string]$Path) {
  $o = if ($Path) { ([string](Get-KitSetting 'supervise.output' 'html')).Trim().ToLower() } else { 'chat' }; if ($o -notin 'chat', 'both') { $o = 'html' }
  if ($o -ne 'html') { Format-KitReport $Shown }; if ($o -eq 'chat') { return }
  "report: $(([Uri]$Path).AbsoluteUri) (updated $($d.at.ToString('HH:mm'))) · detail: $(([Uri][IO.Path]::ChangeExtension($Path, '.json')).AbsoluteUri)"
  # T8 (coordinator context): at most supervise.briefLines lines: every ACT, then WATCH; past it one WATCH line per kind (+N more: who)
  $ln = { param($f) $c = Get-KitFlagCells $f; "$($f.level) · $(@($c.kind, $c.who, $c.problem | Where-Object { "$_".Trim() } | ForEach-Object { ("$_" -replace '\s+', ' ').Trim() }) -join ' · ')$(if ("$($c.action)".Trim()) { " -> $(("$($c.action)" -replace '\s+', ' ').Trim())" })" }
  $acts = @($d.flags | Where-Object level -eq 'ACT'); $ws = @($d.flags | Where-Object level -eq 'WATCH'); $fx = @($d.flags | Where-Object { $_.level -eq 'INFO' -and "$($_.what)" -like 'auto-fixed:*' } | ForEach-Object { "$($_.what)" -replace '^auto-fixed:\s*' })
  $acts | ForEach-Object { & $ln $_ }; $room = [int](Get-KitParam 'supervise.briefLines') - 2 - [int][bool]$fx.Count - $acts.Count
  if ($ws.Count -le $room) { $ws | ForEach-Object { & $ln $_ } }
  else { $gs = @($ws | Group-Object { "$((Get-KitFlagCells $_).kind)" }); $n = 0
    foreach ($g in $gs) { if ($n -ge [math]::Max(1, $room) - 1 -and $n -lt $gs.Count - 1) { "WATCH · $(@($gs | Select-Object -Skip $n | ForEach-Object Group).Count) more in $($gs.Count - $n) kind(s): the report"; break }
      $n++; "$(& $ln $g.Group[0])$(if ($g.Count -gt 1) { " (+$($g.Count - 1) more$(if ($wh = @($g.Group | Select-Object -Skip 1 | ForEach-Object { (Get-KitFlagCells $_).who } | Where-Object { $_ } | Select-Object -Unique)) { ": $($wh -join ', ')" }))" })" } }
  if ($fx.Count) { "FIXED · $($fx -join ' · ')" }
  "$(@($d.rows | Where-Object state -ne 'FINISHED').Count) agent(s) active · $(@($d.flags | Where-Object level -eq 'ACT').Count) ACT · $(@($d.flags | Where-Object level -eq 'WATCH').Count) WATCH"
}
# ---- transcript tails: the board's Doing detail, cached per transcript (lib.ps1 Get-KitStatusRows)
# what a tool call works on (board "Doing"): its description, else a file name + its folder tail, a workflow / skill name, a search pattern, the command
function Get-KitToolWhat($U) { $i = $U.input; $pt = { param($p) $ps = @("$p" -split '[\\/]' | Where-Object { $_ }); if ($ps.Count -gt 1) { "$($ps[-1]) · $(@($ps | Select-Object -SkipLast 1 | Select-Object -Last 2) -join '/')" } else { "$p" } }
  $w = if ("$($i.description)".Trim()) { "$($i.description)" } elseif ($i.file_path -or $i.notebook_path) { "$($U.name) $(& $pt "$($i.file_path)$($i.notebook_path)")" } elseif ($i.scriptPath) { "$($U.name) $([IO.Path]::GetFileNameWithoutExtension("$($i.scriptPath)"))" }
    elseif ($i.skill) { "$($U.name) $($i.skill)" } elseif ($i.pattern) { "$($U.name) $($i.pattern)$(if ($i.path) { " in $(& $pt $i.path)" })" } elseif ($i.command) { "$($i.command)" } else { '' }
  $w = Protect-KitText ("$w" -replace '\s+', ' ').Trim(); if ($w.Length -gt 160) { $w.Substring(0, 159) + '…' } else { $w } }   # masked before the cut: a command can hold a secret
# a transcript's parsed tail, cached per file by size + write time (a sweep re-reads only grown transcripts; task outputs still rechecked); claude only
function Get-KitTailCached([string]$Kind, [string]$File) {
  if ($Kind -ne 'claude' -or -not $File) { return $(if ($File) { Invoke-KitAdapter transcript $Kind last @{ file = $File } }) }
  if ($null -eq $script:KitTailCache) { $script:KitTailCache = try { Read-KitText (Get-KitPath transcript-tails) | ConvertFrom-Json -AsHashtable } catch { $null }; if ($script:KitTailCache -isnot [hashtable]) { $script:KitTailCache = @{} } }
  $fi = Get-Item -LiteralPath $File -ErrorAction SilentlyContinue; if (-not $fi) { return }
  $sig = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"; $c = $script:KitTailCache[$fi.FullName]
  if ($c -and "$($c.sig)" -eq $sig) { $s = [pscustomobject]@{ file = $fi.FullName; at = $fi.LastWriteTime; tool = "$($c.tool)"; what = "$($c.what)"; say = "$($c.say)"; ended = [bool]$c.ended; killed = $false; version = "$($c.version)"; outs = @($c.outs) }
    foreach ($o in $s.outs) { $f = Get-Item -LiteralPath $o -ErrorAction SilentlyContinue; if ($f -and $f.LastWriteTime -gt $s.at) { $s.at = $f.LastWriteTime } }; return $s }
  $s = Invoke-KitAdapter transcript claude last @{ file = $File }; if (-not $s) { return }
  $script:KitTailCache[$fi.FullName] = @{ sig = $sig; tool = $s.tool; what = $s.what; say = $s.say; ended = [bool]$s.ended; version = $s.version; outs = @($s.outs); seen = (Get-KitStamp) }; $script:KitTailDirty = $true; $s
}
function Save-KitTailCache { if (-not $script:KitTailDirty) { return }; $old = (Get-Date).AddDays(-1)
  foreach ($k in @($script:KitTailCache.Keys)) { if ([datetime]"$($script:KitTailCache[$k].seen)" -lt $old -or -not (Test-Path -LiteralPath $k)) { $script:KitTailCache.Remove($k) } }   # a day unseen or gone: dropped
  try { Write-KitAtomic (Get-KitPath transcript-tails -Create) ($script:KitTailCache | ConvertTo-Json -Depth 4 -Compress); $script:KitTailDirty = $false } catch { } }
# Doing (no agent reports it): "<phase / checkpoint step> · <what now>"; what now = the newest tool call's description or file, else its one-line text
function Format-KitDoing($T, [string]$StepNow) { $now0 = if ($T.what) { if ("$($T.what)".StartsWith("$($T.tool) ")) { "$($T.what)" } else { "$($T.tool): $($T.what)" } } elseif ($T.say) { "$($T.tool): $($T.say)" } elseif ($T.tool) { "$($T.tool)" }
  (@($StepNow, $now0) | Where-Object { "$_".Trim() }) -join ' · ' }
# an agent's checkpoint of this run: its last step (round = the step's count, item, a short evidence) and next
function Get-KitCheckpointNow([string]$Agent, [string]$Run) { $c = try { Read-KitState (Get-KitCheckpointFile $Agent $Run) } catch { $null }; if (-not $c -or -not @($c.steps).Count -or ($Run -and "$($c.run)" -ne $Run) -or $c.done) { return }
  $l = @($c.steps)[-1]; $rd = @($c.steps | Where-Object { "$($_.step)" -eq "$($l.step)" }).Count
  [pscustomobject]@{ step = Protect-KitText ((@("$($l.step)$(if ($rd -gt 1) { " round $rd" })", $l.item, $(if ("$($l.evidence)".Length -le 40) { $l.evidence })) | Where-Object { "$_".Trim() }) -join ' · '); next = Protect-KitText "$($c.next)" } }
# a workflow's phases (meta.phases titles of its script, read once per process): the phase after $Phase
function Get-KitNextPhase([string]$Script, [string]$Phase) { if (-not $Script -or -not $Phase) { return }; if ($null -eq $script:KitPhases) { $script:KitPhases = @{} }
  if (-not $script:KitPhases.ContainsKey($Script)) { $pf = if (Test-Path -LiteralPath $Script) { $Script } else { Join-Path $script:KitRoot "workflows/$(Split-Path $Script -Leaf)" }
    $script:KitPhases[$Script] = @(try { [regex]::Matches(((Get-Content -LiteralPath $pf -TotalCount 40 -ErrorAction Stop) -join "`n"), "(?m)^\s*\{\s*title: '([^']+)'") | ForEach-Object { $_.Groups[1].Value } } catch { }) }
  $ps = @($script:KitPhases[$Script]); $pi = [array]::IndexOf($ps, $Phase); if ($pi -ge 0 -and $pi + 1 -lt $ps.Count) { $ps[$pi + 1] } }
# ---- supervise sweep: sections by learned cost, starved first, promotion always; slow calls in the background
# runs when its cost fits the time left after starved sections; supervise.sectionMinutes caps its cadence
function New-KitSweep([datetime]$Deadline, $State) {
  $sw = if ($State.sweep -is [Collections.IDictionary]) { $State.sweep } else { @{} }; if ($sw.cost -isnot [Collections.IDictionary] -or $sw.v -ne 2) { $sw.cost = @{} }   # v2: costs exclude ungated work
  foreach ($jk in @($sw.cost.Keys | Where-Object { "$_" -match '^\S+\.ps1(\s+\S+){3}' })) { $sw.cost.Remove($jk) }   # old per-job keys
  $every = @{ 'cleanup' = 30; 'deploy checks' = 10; 'stale layers' = 15; 'outcomes' = 30; 'repo sync' = [double](Get-KitParam 'sync.everyMinutes') }   # only one-shot sections: standing flags would vanish off-round
  $cf = Get-KitSetting 'supervise.sectionMinutes' $null; if ($cf) { foreach ($p in @((Get-KitProps $cf) | Where-Object MemberType -eq NoteProperty)) { $v = 0.0; if ([double]::TryParse("$($p.Value)", [ref]$v)) { $every[$p.Name] = $v } } }
  [pscustomobject]@{ deadline = $Deadline; cost = $sw.cost; starved = @($sw.starved | Where-Object { $_ }); last = $(if ($sw.last -is [Collections.IDictionary]) { $sw.last } else { @{} }); every = $every; always = @('tracker checks'); ran = @{}; cur = $null; t = $null; skipped = [Collections.Generic.List[string]]::new(); timedOut = [Collections.Generic.List[string]]::new() }
}
# an ungated phase (~<name>): reported, never charged to the prior section
function Start-KitSweepPhase($Sw, [string]$Name, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds }
  $Sw.cur = "~$Name"; $Sw.t = $Now
}
function Test-KitSweep($Sw, [string]$Name, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds; $Sw.cur = $null }
  if (-not $Sw.ran.ContainsKey($Name) -and $Sw.last[$Name] -and ($Now - [datetime]$Sw.last[$Name]).TotalMinutes -lt [double]$Sw.every[$Name]) { return $false }
  $left = ($Sw.deadline - $Now).TotalSeconds
  $hold = [math]::Min(0.5 * $left, [double](@($Sw.starved | Where-Object { $_ -ne $Name -and -not $Sw.ran.ContainsKey($_) } | ForEach-Object { [double]$Sw.cost[$_] }) | Measure-Object -Sum).Sum)   # starved reserve at most half: none starves the rest
  # starved: up to 10 s past the deadline
  $go = if ($Name -in $Sw.always) { $true } elseif ($Name -in $Sw.starved) { $left + 10 -ge [math]::Min([double]$Sw.cost[$Name], 5) } else { $left -gt 0 -and $left -ge [double]$Sw.cost[$Name] + $hold }
  if ($go) { $Sw.cur = $Name; $Sw.t = $Now } elseif ($Name -notin $Sw.skipped) { $Sw.skipped.Add($Name) }
  $go
}
# sweep end: stores costs (EWMA 0.3) and the starved list
function Complete-KitSweep($Sw, $State, [datetime]$Now = (Get-Date)) {
  if ($Sw.cur) { $Sw.ran[$Sw.cur] = [double]$Sw.ran[$Sw.cur] + ($Now - $Sw.t).TotalSeconds; $Sw.cur = $null }
  foreach ($n in @($Sw.ran.Keys | Where-Object { -not "$_".StartsWith('~') })) { $c = $Sw.cost[$n]; $Sw.cost[$n] = [math]::Round($(if ($null -ne $c) { 0.7 * [double]$c + 0.3 * $Sw.ran[$n] } else { $Sw.ran[$n] }), 2); if ($Sw.every[$n]) { $Sw.last[$n] = (Get-KitStamp stored $Now) } }
  $State.sweep = @{ v = 2; cost = $Sw.cost; last = $Sw.last; starved = @($Sw.skipped | Where-Object { -not $Sw.ran.ContainsKey($_) }) }
  $secs = [ordered]@{}; foreach ($kv in @($Sw.ran.GetEnumerator() | Where-Object { $_.Value -ge 0.5 } | Sort-Object { -$_.Value })) { $secs[$kv.Key] = [math]::Round($kv.Value, 1) }
  Write-KitLog calls sweep @{ secs = $secs; skipped = @($State.sweep.starved); timedOut = @($Sw.timedOut) }   # a budget hit names its slow sections (K8: no per-sweep data before)
  "slowest: $(@($Sw.ran.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 5 | ForEach-Object { '{0} {1:0.0} s' -f $_.Key, $_.Value }) -join ', ')"   # ~ = ungated phase
}
# inline within the time left; -Background over half of it, or -Detached: background, last finished result now
function Invoke-KitSweepCall($Sw, [string]$Name, [string]$Script, [string[]]$A, [switch]$Background, [string]$Job, [switch]$Detached) {
  $left = [math]::Max(5, [int]($Sw.deadline - (Get-Date)).TotalSeconds); $c = $Sw.cost[$Name]
  if (-not $Detached -and (-not $Background -or $null -eq $c -or [double]$c -le $left / 2)) {
    $t0 = Get-Date; $r = Invoke-KitExe 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', $Script) + $A) $left; $s = ((Get-Date) - $t0).TotalSeconds
    $Sw.cost[$Name] = [math]::Round($(if ($r.timedOut) { [math]::Max(2 * $s, [double]$c) } elseif ($null -ne $c) { 0.7 * [double]$c + 0.3 * $s } else { $s }), 2); if ($r.timedOut) { $Sw.timedOut.Add($Name) }   # cut short: at least 2x what it got
    return @($r.out -split "`r?`n" | Where-Object { $_ })
  }
  $sn = $Name   # closure: Invoke-KitBackground's $Name is the job
  @(Invoke-KitBackground $(if ($Job) { $Job } else { $Name }) $Script $A { param($s) $Sw.cost[$sn] = [math]::Round(0.7 * [double]$Sw.cost[$sn] + 0.3 * $s, 2) }.GetNewClosure() ([double]$c))
}
# supervise's kit calls: detached = last result now, a fresh run behind; background = inline under half the time left
function Get-KitSweepMode([string[]]$A) {
  $v = "$($A[0..1])"
  if ($v -in 'deploy plan', 'deployed -Mrs', 'deploy intest', 'budget -Usage', 'report -Run', 'tracker statuses', 'scope', 'wt pool') { 'detached' } elseif ($v -in 'track run', 'budget -Run') { 'background' } else { 'inline' }
}
# past max(10 x cost, 30 min) = hung, stopped; empty result with errors = WATCH
function Invoke-KitBackground([string]$Name, [string]$Script, [string[]]$A, [scriptblock]$OnSeconds, [double]$Cost = 0) {
  $d = Get-KitPath background -Create; $sl = ConvertTo-KitSlug $Name
  if ($sl.Length -gt 100) { $sl = $sl.Substring(0, 80) + '-' + (Get-KitHash $sl SHA1).Substring(0, 12) }   # stay within MAX_PATH
  $base = Join-Path $d $sl; $res = @{ out = @() }
  Invoke-KitLocked "$base.json" {
    $run = try { Read-KitText "$base.json" | ConvertFrom-Json } catch { $null }
    $busy = $run -and (Test-KitPid $run.pid $run.start)
    if ($busy -and ((Get-Date) - [datetime]$run.at).TotalMinutes -gt [math]::Max(30.0, 10 * $Cost / 60)) {
      if ($KitIsWindows) { $null = & taskkill /PID ([int]$run.pid) /T /F 2>$null } else { Stop-Process -Id $run.pid -Force -ErrorAction SilentlyContinue }   # the launcher, its job and the job's children
      $busy = $false; $res.out = @("WATCH background $Name hung $([int]((Get-Date) - [datetime]$run.at).TotalMinutes) min: stopped, started again")
    }
    elseif ($run -and -not $busy -and -not (Test-Path -LiteralPath "$base.out")) { $res.out = @("WATCH background $Name ended without output (launch failed): started again") }
    elseif ($run -and -not $busy) {
      $res.out = @(Get-Content -LiteralPath "$base.out" | Where-Object { $_ }); $er = @(Get-Content -LiteralPath "$base.err" -ErrorAction SilentlyContinue | Where-Object { $_ })
      if (-not $res.out.Count -and $er.Count) { $res.out = @("WATCH background $Name failed: $($er[0])") }
      if (-not $run.read -and $OnSeconds) { & $OnSeconds ((Get-Item -LiteralPath "$base.out").LastWriteTime - [datetime]$run.at).TotalSeconds }
      $run | Add-Member -Force NoteProperty read $true; Write-KitAtomic "$base.json" ($run | ConvertTo-Json -Compress)
    }
    if (-not $busy) {
      Remove-Item -LiteralPath "$base.out", "$base.err" -Force -ErrorAction SilentlyContinue
      $fileArgs = @('-NoProfile', '-NonInteractive', '-File', "`"$Script`"") + @($A | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } })
      # Windows: -Redirect* inherits the caller's stdout (a -Brief hung 120+ s)
      $sq = { param($s) "'$("$s" -replace '([\u2018-\u201B''])', '$1$1')'" }   # PowerShell reads the smart quotes as ' too
      $bc = "(Start-Process pwsh -ArgumentList $(@($fileArgs | ForEach-Object { & $sq $_ }) -join ',') -NoNewWindow -PassThru -RedirectStandardOutput $(& $sq "$base.out") -RedirectStandardError $(& $sq "$base.err")).WaitForExit()"
      $p = if ($KitIsWindows) { Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-ec', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bc))) -WindowStyle Hidden -PassThru } else { Start-Process pwsh -ArgumentList $fileArgs -PassThru -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err" }
      Write-KitAtomic "$base.json" (@{ pid = $p.Id; start = (Get-KitPidStart $p.Id); at = (Get-KitStamp) } | ConvertTo-Json -Compress)
    }
  }
  $res.out
}
