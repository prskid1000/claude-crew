#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/ (moved out of lib.ps1 for its token cap). Exit codes: none here.
# supervise report: bossy.ps1 supervise -Brief tables, flags, acks, anomalies and the report file; the board's Doing · next.
# Sections: L5 supervise report · L101 transcript tails
# ---- supervise report: -Brief, no LLM step; pure on $d, so fixtures test it
# a FINISHED row shows for supervise.finishedMinutes after it ended
function Select-KitBriefRows($Rows, [datetime]$Now) {
  $fm = [double](Get-KitSetting 'supervise.finishedMinutes' 30)
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
    $c = Get-KitFlagCells $f
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
# no producer kind: an upper-case lead ("RESTART LOOP: ...") is the kind
function Get-KitFlagCells($f) {
  $kind = $f.kind; $problem = $f.problem
  if (-not $kind -and "$($f.what)" -cmatch '^([A-Z]{3,}(?:[ -][A-Z]{3,})*):?\s+(.+)$') { $kind = $Matches[1]; if (-not $problem) { $problem = $Matches[2] } }
  [pscustomobject]@{ kind = $kind; who = $f.who; age = $f.age; problem = $(if ($problem) { $problem } else { $f.what }); action = $(if ($f.next) { $f.next } else { $f.action }) }
}
# a flag's identity across rounds: counts, times and sizes vary
function Get-KitFlagKey([string]$What) { $k = (($What.ToLower() -replace '\b\d+\b', '#') -replace '\s+', ' ').Trim(); $k.Substring(0, [math]::Min(160, $k.Length)) }
# -Ack text pasted from the -Brief table: cells add spaces after - / (word wrap), escape |, end in …, join with ·; counts vary
function ConvertTo-KitAckText([string]$Text) { ($Text.ToLower() -replace '\b\d+\b', '#') -replace '[\s\\|…·''"`]', '' }
# an ack matches the flag's whole line or any one cell
function Test-KitAcked($Flag, [string[]]$Keys) {
  $c = Get-KitFlagCells $Flag; $w = ConvertTo-KitAckText "$($Flag.what)"; $cells = ConvertTo-KitAckText "$($c.kind) $($c.who) $($c.problem)"
  [bool]@($Keys | ForEach-Object { ConvertTo-KitAckText $_ } | Where-Object { $_.Length -ge 12 -and ($w.Contains($_) -or $cells.Contains($_)) }).Count
}
# an acknowledged one (answered / proven false) hides 24 h
function Select-KitFlags($Flags, $Acks, [datetime]$Now) {
  $seen = @{}; $hid = 0; $live = @($Acks.Keys | Where-Object { ($Now - [datetime]$Acks[$_].at).TotalHours -lt 24 })
  $keep = @(foreach ($f in @($Flags)) { $k = Get-KitFlagKey $f.what; if ($seen[$k]) { continue }; $seen[$k] = 1
      if ($f.level -ne 'INFO' -and $live.Count -and (Test-KitAcked $f $live)) { $hid++; continue }; $f })
  if ($hid) { $keep += [pscustomobject]@{ level = 'INFO'; what = "$hid acknowledged flag(s) hidden (supervise -Ack, 24 h)"; action = 'Nothing to do.' } }
  $keep
}
# flags with refs (UNTRACKED MR, ERROR SPIKE) store the refs, so a new ref flags again
function Add-KitFlagAck([string]$Ack, [string]$Reason) {
  $sf0 = Get-KitPath supervise-state -Create; $k0 = Get-KitFlagKey $Ack; $script:ackOut = ''
  Invoke-KitLocked $sf0 { $s0 = try { Get-Content $sf0 -Raw | ConvertFrom-Json -AsHashtable } catch { $null }; if (-not $s0) { $s0 = @{} }; if (-not $s0.acks) { $s0.acks = @{} }
    $hit = @($s0.lastFlags | Where-Object { $_ -and (Test-KitAcked ([pscustomobject]$_) @($k0)) }); $refs = @($hit | ForEach-Object { @($_.refs) } | Where-Object { $_ })
    if ($refs.Count) { if (-not $s0.known) { $s0.known = @{} }; foreach ($r in $refs) { $s0.known[$r] = (Get-Date).ToString('o') } }
    if (-not $hit.Count -or @($hit | Where-Object { -not @(@($_.refs) | Where-Object { $_ }).Count }).Count) { $s0.acks[$k0] = @{ at = (Get-Date).ToString('o'); reason = $Reason } }
    Write-KitAtomic $sf0 ($s0 | ConvertTo-Json -Depth 5)
    $script:ackOut = "$(if ($refs.Count) { "known from now on (they no longer flag; a new one does): $(@($refs | Select-Object -First 5) -join ' · ')$(if ($refs.Count -gt 5) { " +$($refs.Count - 5)" })" } else { "acknowledged for 24 h: $k0" })$(if ($Reason) { " ($Reason)" })`n$(if ($hit.Count) { "hides $($hit.Count) flag(s) of the last round: $(@($hit | ForEach-Object { "$($_.what)".Substring(0, [math]::Min(90, "$($_.what)".Length)) }) -join ' · ')" } else { 'matches no flag of the last round: check the text (any later flag containing it hides)' })" }
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
    @('', '## Shells (whole commands)', '') + @(Format-KitMdTable 'PID', 'Owner', 'Age min', 'State', 'Dir', 'Command', 'Next' @($d.shells | ForEach-Object { , @($_.pid, $_.owner, $_.age, $_.state, $_.dir, ($_.cmd -replace '\r?\n', ' \n '), $_.next) })) +
    @('', '## Sweep', '', '```text') + $Sweep + '```' |
    Set-Content (Get-KitPath supervise-report -Create) -Encoding utf8
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
  $script:KitTailCache[$fi.FullName] = @{ sig = $sig; tool = $s.tool; what = $s.what; say = $s.say; ended = [bool]$s.ended; version = $s.version; outs = @($s.outs); seen = (Get-Date).ToString('o') }; $script:KitTailDirty = $true; $s
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
