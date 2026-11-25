#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/ (moved out of lib.ps1 for its token cap). Exit codes: none here.
# supervise report: bossy.ps1 supervise -Brief tables, flags, acks, anomalies and the report file; the board's Doing · next;
# the supervise sweep (sections by learned cost, background calls).
# Sections: L6 supervise report · L162 transcript tails · L194 supervise sweep · L274 status rows
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
# lane ids as shown names first (K55: an ack copied from the shown flag, shop·Kestrel, matches a flag stored with shop2)
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
  foreach ($d in [regex]::Matches("$Reason", '\b(?:(?:dec|envfix)-[a-z0-9]+(?:-[a-z0-9]+)*|d-\d{8,}-[\w-]+)\b')) { if (Test-Path -LiteralPath (Join-Path (Get-KitPath decisions) "$($d.Value).json")) { return $true } }
  $named = @([regex]::Matches("$Reason", '(?<r>[\w.-]+)(?:!|/-/merge_requests/|/pulls?/)(?<n>\d+)') | ForEach-Object { "$($_.Groups['r'].Value)!$($_.Groups['n'].Value)" })
  if (-not $named.Count) { return $false }
  [bool]@((Read-KitTracking).tasks.Values | ForEach-Object { @($_.mrs) } | Where-Object { $_ -and ("$_" -split '/')[-1] -in $named }).Count
}
# an acknowledged one (answered / proven false) hides 24 h
function Select-KitFlags($Flags, $Acks, [datetime]$Now) {
  $seen = @{}; $hid = 0; $ackHours = Get-KitParam 'supervise.ackHideHours'; $ackRefHours = Get-KitParam 'supervise.ackRefHours'
  $live = @($Acks.Keys | Where-Object { ($Now - [datetime]$Acks[$_].at).TotalHours -lt $ackHours })
  $keep = @(foreach ($f in @($Flags)) { $k = Get-KitFlagKey $f.what; if ($seen[$k]) { continue }; $seen[$k] = 1
      $fk = if ($f.ackNeeds) { @($live | Where-Object { (Test-KitAckRef $Acks[$_].reason) -and ($Now - [datetime]$Acks[$_].at).TotalHours -lt $ackRefHours }) } else { $live }
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
function Send-BoardMsg([string]$From, [string]$To, [string]$Text, [string]$Kind = 'note', [string]$Ref = '') {
  $f = Get-InboxFile $To; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $line = [ordered]@{ at = (Get-KitStamp); from = $From; to = $To; kind = $Kind; text = $Text; ref = $Ref; read = $false } | ConvertTo-Json -Compress
  Invoke-KitLocked $f { Add-Content -LiteralPath $f $line -Encoding utf8 }
}
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
# ---- status rows: one row per board agent, workflow run and uncovered running step (supervise, board show)
# rows: board entries, workflow runs (2 h after last write, 48 h unfinished), running steps no entry covers (windows inline)
function Get-KitStatusRows([datetime]$Now = (Get-Date), [string]$Session) {
  $stuck = [double](Get-KitParam 'supervise.stuckMinutes'); $rows = [Collections.Generic.List[object]]::new(); $script:KitTxVersions = @{}
  $last = { param($tool, $file) $t = if ($file) { Get-KitTailCached (Get-KitTranscriptKind $tool) $file }; if ($t.version) { $script:KitTxVersions[($t.version -split ' ')[0]] = $t.version }; $t }
  $max = { param([object[]]$T) @($T | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1] }
  $doing = { param($t, [string]$stepNow) Format-KitDoing $t $stepNow }; $nextPh = { param([string]$scr, [string]$ph) Get-KitNextPhase $scr $ph }   # Doing · next: adapters/supervise-report.ps1
  $outcome = { param($st) if ("$($st.result.summary)") { "$($st.result.summary)" } else { 'done' } }
  $tok = { param($n) if ($n -ge 1e6) { '{0:0.#}M' -f ($n / 1e6) } else { '{0:0}k' -f ($n / 1e3) } }
  # waits: "<run>/<agent>" or "/<agent>" -> why, since, next
  $waits = @{}; $put = { param($k, $why, $at, $nx) if (-not $waits[$k]) { $waits[$k] = [pscustomobject]@{ why = $why; at = $at; next = $nx } } }
  foreach ($d in @(Read-KitJsonFiles (Get-KitPath decisions) | Where-Object status -eq 'pending')) {
    $e = $d.kind -eq 'envfix'; & $put "$($d.run)/$($d.agent)" "$(if ($e) { 'env fix' } else { 'decision' }) $($d.id)" $d.at "$(if ($e) { 'coordinator fixes the env' } else { 'owner answers' }), then decide answer -Id $($d.id)"
  }
  foreach ($g in @((Get-KitGpuState).waiting)) { & $put "/$($g.holder)" "GPU, held by $($g.heldBy)" $g.at 'the GPU frees' }
  foreach ($h in @(Get-Command 'Get-KitStatusWait*' -CommandType Function -ErrorAction SilentlyContinue)) { foreach ($w in @(& $h)) { & $put "/$($w.agent)" $w.why $w.at $w.next } }   # adapters: build gate, phone lanes
  $pauses = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object state -eq 'paused')
  $waitOf = { param([string]$Run, [string[]]$Names)
    foreach ($n in $Names) { foreach ($k in "$Run/$n", "/$n") { if ($waits[$k]) { return $waits[$k] } } }
    $p = @($pauses | Where-Object { $Run -and (Test-KitPauseCovers $_ $Run) })[0]
    if ($p) { [pscustomobject]@{ why = "owner pause: $($p.reason)"; at = $p.at; next = "bossy.ps1 resume -Run $Run" } } }
  # a board transcript in a workflow folder maps its folder id to the run
  $recent = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { -not $_.takenOverBy -and ($Now - [datetime]$_.beat).TotalHours -lt $(if ($_.status -eq 'left') { 2 } else { 6 }) })   # supervise's window
  $runOf = @{}; foreach ($e in $recent) { if ("$($e.transcript)" -match '[\\/]workflows[\\/]([^\\/]+)[\\/]agent-' -and $e.run) { $runOf[$Matches[1]] = $e.run } }
  $launch = @(Read-KitJsonFiles (Get-KitPath launches)); $steps = @{}; $anyRun = @{}; $runSteps = [Collections.Generic.List[object]]::new()
  $wfIdleMin = Get-KitParam 'supervise.workflowIdleMinutes'; $wfNoStepMin = Get-KitParam 'supervise.workflowNoStepMinutes'
  foreach ($w in @(Get-KitRecentWorkflowDirs $Session)) {   # oldest first: a relaunch's steps win
    $j = Join-Path $w.FullName 'journal.jsonl'; if (-not (Test-Path $j)) { continue }
    $ev = @(Get-Content $j | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 30 } catch {} }); $jt = (Get-Item $j).LastWriteTime
    $rec = @(Get-KitWorkflowRecords $w $ev $launch); $lr = @($rec | Where-Object { $_.runId -or $_.wfDir })
    $started = @($ev | Where-Object type -eq 'started'); $res = @{}; foreach ($x in $ev | Where-Object type -eq 'result') { $res[$x.agentId] = $x }
    $running = @(Get-JournalRunning $started @($res.Keys)); $seen = [Collections.Generic.List[object]]::new(); $seen.Add($jt)
    # no end marker: no running step for workflowIdleMinutes (none ever: workflowNoStepMinutes) = ended, unless paused
    $paused = [bool]@($rec | Where-Object { $_.paused -and -not $_.completed }).Count
    $fin = -not $paused -and ([bool]@($ev | Where-Object { $_.type -in 'finished', 'completed', 'done' }).Count -or [bool]@($rec | Where-Object completed).Count -or ($started.Count -and -not $running.Count -and ($Now - $jt).TotalMinutes -ge $wfIdleMin) -or (-not $started.Count -and ($Now - $jt).TotalMinutes -ge $wfNoStepMin))
    $gone = if (-not $fin) { Get-KitWorkflowStop $w $rec }; $live = -not $fin -and -not $gone   # ended runs have no running steps
    if (($Now - $jt).TotalHours -ge $(if ($live) { 48 } else { 2 })) { continue }
    $run = @(@($lr | ForEach-Object run) + $runOf[$w.Name] + $w.Name | Where-Object { $_ })[0]
    if (-not @($lr).Count) { $lr = @(@($rec) + @($launch | Where-Object { $_.run -eq $run -and $_.cap }) | Where-Object { $_ }) }   # its self record: script, tokens spent, cap
    foreach ($s in $started) {
      $st = [pscustomobject]@{ label = [string]$s.label; run = $run; result = $res[$s.agentId].result; tf = Join-Path $w.FullName "agent-$($s.agentId).jsonl"; tx = $null; covered = $false; jt = $jt
        phase = [string]$s.phase; script = "$(@($lr.script | Where-Object { $_ })[0])" }
      if ($live -and $s -in $running) { $st.tx = & $last 'claude' $st.tf; $seen.Add($st.tx.at); $runSteps.Add($st)
        $st | Add-Member -Force NoteProperty created (Get-Item -LiteralPath $st.tf -ErrorAction SilentlyContinue).CreationTime
        $st | Add-Member -Force NoteProperty type $(try { (Read-KitText ($st.tf -replace '\.jsonl$', '.meta.json') | ConvertFrom-Json).agentType } catch { '' })
        foreach ($n in @(LabelNames $st.label)) { $anyRun[$n] = if ($anyRun.ContainsKey($n) -and $anyRun[$n] -ne $st) { $false } else { $st } } }   # one running step of a name: its agent, whatever run it joined the board under
      foreach ($k in @(LabelNames $st.label | ForEach-Object { "$run/$_"; if ($run -like 'wf_*') { "?/$_" } })) { if (-not ($steps[$k].tx -and -not $st.tx)) { $steps[$k] = $st } }   # latest step wins, running first; ?/ = run name unknown
    }
    $errs = @($res.Values | Where-Object { $_.result.error }).Count; $spent = @($lr.spent | Where-Object { $_ })[0]; $cap = @($lr.cap | Where-Object { $_ })[0]
    $cw = @(foreach ($x in @($runSteps | Where-Object { $_.tf.StartsWith($w.FullName) })) { & $waitOf $run @(LabelNames $x.label) })   # every running step waits = the run waits
    $rsNow = @($runSteps | Where-Object { $_.tf.StartsWith($w.FullName) }); $phNow = @($rsNow.phase | Where-Object { $_ } | Select-Object -Unique)   # Doing: phase · running steps; next: the phase after
    $wp = if ($paused) { [pscustomobject]@{ why = 'owner pause'; at = (Get-KitPauseAt $lr.paused); next = "bossy.ps1 resume -Run $run" } } elseif (-not $running.Count) { & $waitOf $run @() } elseif ($cw.Count -eq $running.Count) { [pscustomobject]@{ why = "$($cw[0].why)$(if ($cw.Count -gt 1) { ", $($cw.Count) steps" })"; at = @($cw.at | Sort-Object)[0]; next = $cw[0].next } }
    # one row per run: a resumed run's newer folder replaces the older; never a live one by an ended one
    $prevW = @($rows | Where-Object { $_.name -eq "$run (workflow)" })[0]; if ($prevW) { if ([int]$prevW.left -and -not $live) { continue }; [void]$rows.Remove($prevW) }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$run (workflow)"; run = $run; left = $(if ($live) { $running.Count } else { 0 })
          task = "$(@($lr.script | Where-Object { $_ } | ForEach-Object { Split-Path "$_" -Leaf })[0]) $($w.Name) · steps $($res.Count)/$($started.Count)$(if ($spent) { " · $(& $tok $spent) tokens$(if ($cap) { " of $(& $tok $cap)" })" })"
          stopped = $gone; done = $(if ($fin) { "$($res.Count)/$($started.Count) steps$(if ($errs) { ", $errs error(s)" })" })
          wait = $wp.why; waitAt = $wp.at; waitNext = $wp.next; last = & $max $seen; started = $w.CreationTime; ended = $jt
          doing = $(if ($live -and $rsNow.Count) { (@(($phNow -join ', '), (@($rsNow.label) -join ', ')) | Where-Object { $_ }) -join ' · ' })
          next = $(if ($live -and $phNow.Count) { $scr0 = "$(@($rsNow.script | Where-Object { $_ })[0])"; $np = & $nextPh $scr0 "$($phNow[-1])"; if ($np) { "next: $np" } }) }) $Now $stuck))
  }
  # a running step of the same name is that agent now
  $trk = (Read-KitTracking).tasks; $txCache = @{}; $byTx = @{}
  # Agent-tool subagent: transcript = the one with its join line "(pass -Session <id> to beat" (a bare id is also quoted), kept; a left one: one scan
  $txLeftMin = Get-KitParam 'supervise.transcriptLeftMinutes'; $txRetryMin = Get-KitParam 'supervise.transcriptRetryMinutes'
  $txOf = { param($e) if ($e.transcript -or -not $e.session -or ($e.status -eq 'left' -and (($e.txTry -and [datetime]$e.txTry -ge [datetime]$e.beat) -or ($Now - [datetime]$(if ($e.beat) { $e.beat } else { $e.joined })).TotalMinutes -gt $txLeftMin)) -or ($e.txTry -and ($Now - [datetime]$e.txTry).TotalMinutes -lt $txRetryMin)) { return "$($e.transcript)" }
    $k = Get-KitTranscriptKind $e.tool; if (-not $txCache.ContainsKey($k)) { $txCache[$k] = @(Get-KitLiveTranscripts $Now 360 $k) }
    $hit = @($txCache[$k] | Where-Object { $_.LastWriteTime -ge [datetime]$e.joined -and (Test-KitTranscriptMarker $_.FullName "(pass -Session $($e.session) to beat") })[0]
    # a workflow agent that joined by hand (revy-18 under review:<area>): its step transcript
    if (-not $hit -and $k -eq 'claude') { if (-not $txCache.ContainsKey('wf')) { $txCache.wf = @(Get-KitRecentWorkflowDirs | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue }) }
      $hit = @($txCache.wf | Where-Object { $_.LastWriteTime -ge [datetime]$e.joined -and (Test-KitTranscriptMarker $_.FullName "(pass -Session $($e.session) to beat") })[0] }
    try { Invoke-KitLocked $e.file { $x = Read-KitState $e.file; if ($x) { if ($hit) { $x.transcript = $hit.FullName } else { $x.txTry = (Get-KitStamp stored $Now) }; Write-KitState $e.file $x } } } catch { }   # a miss: 10 min until the next scan
    if ($hit) { $hit.FullName } }
  foreach ($e in @($recent | Group-Object { "$($_.run)/$($_.agent)" } | ForEach-Object { $_.Group | Sort-Object { [datetime]$_.joined } | Select-Object -Last 1 } | Sort-Object -Stable { -not $_.type })) {   # a re-join replaces its older entry; typed first
    $sq = $steps["?/$($e.agent)"]; $st = @($steps["$($e.run)/$($e.agent)"], $(if ($sq.tx -or $sq.jt -ge [datetime]$e.joined) { $sq }) | Where-Object { $_ })[0]   # an unnamed run's ended step never matches a newer entry
    $sa = $anyRun["$($e.agent)"]; if (-not $st -and $sa -and $e.status -ne 'left' -and -not $e.crashed -and $sa.type -and $sa.type -eq $e.type -and $sa.created -and [datetime]$e.joined -ge $sa.created.AddMinutes(-1)) { $st = $sa   # testy testers join under the run folder, the launch is select-<target>
      if (-not $e.transcript -and $e.file) { try { Invoke-KitLocked $e.file { $x = Read-KitState $e.file; if ($x) { $x.transcript = $sa.tf; Write-KitState $e.file $x } } } catch { } } }   # lease grace and shell owners read it too
    # an older attempt whose name runs as a newer step (a retest): superseded
    $sup = if (-not $st -and $sa -and $e.status -ne 'left' -and $sa.type -and $sa.type -eq $e.type -and $sa.created -and [datetime]$e.joined -lt $sa.created.AddMinutes(-1) -and [datetime]$e.beat -le $sa.created.AddMinutes(1)) { $sa }
    # N3: the run's running step (<phase>:<area>) is the area's progress, any agent id
    $ar = "$(if ($e.area) { $e.area } elseif ("$($e.agent)" -match '^(?<b>.+)-\d+$') { $Matches.b } else { $e.agent })" -replace '^area-'; $sr = if (-not ($st -or $sup) -and $e.status -ne 'left' -and $ar) { @($steps["$($e.run)/$ar"], $steps["$($e.run)/area-$ar"] | Where-Object { $_ })[0] }
    if ($sr.tx -and $sr.created) { if ([datetime]$e.joined -lt $sr.created.AddMinutes(-1) -and [datetime]$e.beat -le $sr.created.AddMinutes(1)) { $sup = $sr } else { $st = $sr } }
    # a quiet "<agent>-<n>" row whose run's base agent beats: a stale pre-pause copy, never STUCK
    $dupOf = if (-not $st -and $e.status -ne 'left' -and "$($e.agent)" -match '^(?<b>.+)-\d+$' -and ($Now - [datetime]$e.beat).TotalMinutes -ge $stuck) { $bn = $Matches.b; if (@($recent | Where-Object { $_.agent -eq $bn -and $_.run -eq $e.run -and $_.status -ne 'left' -and ($Now - [datetime]$_.beat).TotalMinutes -lt $stuck }).Count) { $bn } }
    if ($st) { $st.covered = $true }; $on = [bool]$st.tx
    $t = if ($on) { $st.tx } else { $tx = & $txOf $e; & $last $e.tool $(if ($tx) { $tx } elseif ($st) { $st.tf }) }
    $w = if ($e.paused -and -not $on) { [pscustomobject]@{ why = 'owner pause'; at = $e.paused; next = "bossy.ps1 resume -Run $($e.run)" } } else { & $waitOf $e.run @($e.agent) }
    if (-not $w -and "$($e.status)" -match '^(?i)wait' -and ($Now - [datetime]$e.beat).TotalMinutes -lt $stuck) { $w = [pscustomobject]@{ why = "$($e.status)"; at = $e.beat; next = '' } }   # its own words (e.g. waiting for area X1) while it beats
    $tn = foreach ($i in "$($e.items)" -split '[,\s]+') { $o = if ($i -and $trk) { $trk[$i] }; if ($o -and -not $o.done) { "track $i`: $(@($o.mrs).Count) MR(s) until promoted$(if ($o.holdPromotion) { " (held: $($o.holdPromotion))" })"; break } }
    $ck = if ($e.status -ne 'left') { Get-KitCheckpointNow "$($e.agent)" "$($e.run)" }; $ph = if ($on) { $st.phase }; $npOn = if ($on) { & $nextPh $st.script $st.phase }
    $dupKey = "$($e.agent)|$($t.file)"; $twin = if ($t.file) { $byTx[$dupKey] }
    if ($twin) { if ($twin.state -notmatch '^(FIN|STOP)' -or $e.status -eq 'left') { continue }; [void]$rows.Remove($twin) }   # joined twice: one row, live wins
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$($e.agent) ($($e.type))"; area = $e.area; run = $e.run; session = $e.session; tx = $t.file; task = (@($(if ($on) { $st.label }), $e.items, $e.run) | Where-Object { $_ }) -join ' · '
          stopped = $(if ($e.crashed -and -not $on) { 'crashed' } elseif ($sup -or $dupOf) { $null } elseif ($e.status -ne 'left' -and (Test-KitHolder $e) -eq $false) { 'session gone' } elseif ($st.result.error) { "error: $($st.result.error)" } elseif ($t.killed) { 'killed' })
          done = $(if ($on) { '' } elseif ($sup) { "superseded by $($sup.label)" } elseif ($dupOf) { "stale duplicate of $dupOf (it beats)" } elseif ($e.handoffBrief) { 'handoff' } elseif (($e.status -eq 'left' -and -not $e.paused) -or ($st.result -and [datetime]$e.joined -le $st.jt)) { & $outcome $st } elseif ($t.ended) { 'turn complete' })
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = & $max @($e.beat, $t.at, (Get-KitAgentProgressAt $e $st)); doing = & $doing $t ((@($ph, $ck.step) | Where-Object { $_ }) -join ' · '); started = $e.joined; ended = $(if ($e.crashed) { $e.crashed } else { $e.beat })
          budget = $(if ($e.handoff) { "handoff at $(& $tok $e.handoff)$(if ($e.capBy) { " ($($e.capBy))" })$(if ($e.ctxCheck) { " · context check $($e.ctxCheck.decision) at $(& $tok $e.ctxCheck.ctx)" })" })
          next = $(if ($e.handoffBrief) { "a fresh $($e.type) from $(Split-Path "$($e.handoffBrief)" -Leaf)" } elseif ($tn) { $tn } elseif ("$($e.status)" -notin 'working', 'left') { "$($e.status)" } elseif ($ck.next -and $ck.next -ne 'none') { "next: $($ck.next)" } elseif ($npOn) { "next: $npOn" }) }) $Now $stuck))
    $byTx[$dupKey] = $rows[$rows.Count - 1]
  }
  foreach ($st in @($runSteps | Where-Object { -not $_.covered })) {
    $w = & $waitOf $st.run @(LabelNames $st.label); $ty = try { (Read-KitText ($st.tf -replace '\.jsonl$', '.meta.json') | ConvertFrom-Json).agentType } catch { '' }
    $rows.Add((Set-KitStatusState ([pscustomobject]@{ name = "$((($st.label -split ':', 2)[-1] -split '@')[0]) ($(if ($ty) { $ty } else { 'step' }))"; run = $st.run; task = "$($st.label) · $($st.run)"
          wait = $w.why; waitAt = $w.at; waitNext = $w.next; last = $(if ($st.tx) { $st.tx.at } else { $st.jt }); doing = & $doing $st.tx $st.phase; started = (Get-Item -LiteralPath $st.tf -ErrorAction SilentlyContinue).CreationTime
          next = $(if ($np = & $nextPh $st.script $st.phase) { "next: $np" } else { '' }) }) $Now $stuck))
  }
  Save-KitTailCache
  @($rows)
}
