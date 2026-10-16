<#
qa.ps1: qa-kit commands (SKILL.md tester steps 1-6, lead L1-L3). pwsh 7: & <kit>/skills/qa-kit/qa.ps1 <verb> [args]
  seat acquire|release|status ...                  memory seat + item claim
  deployed -Mrs <repo>!<iid>,... [-Detail] [-Json]  live on a test env?
  api -Target <t> -As <user> -Method <M> -Path '/...' [-Body <json>] [-Save <name> -OutDir <abs dir>]
  finalize -RunDir <run> -Code <code> [-Check -FixNames] [-NoTracker] [-ExpectChecks <n>] [-Results <file>]   publish
  annotate -In <image> -Rect 'x,y,w,h,label' [-Copy]
  retest -RunDir <run> -Task <id> -Code <code> -Mrs <refs>
  ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo ...   ($env:ANDROID_SERIAL | KIT_DEVICE)
In: targets.local.json (logins), kit.local.json, the run folder. Out: text / JSON (-Json), evidence files.
Exit codes: 0 ok · 1 problem (evidence check, not deployed, publish refused, api HTTP >= 400 / no answer) · 2 usage ·
  3 seat ALREADY (item taken) · 4 seat still waiting (run it again).
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | select -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# ---- report builder: HTML for Google Docs import (inline styles, tables for layout); Build-QaReportMd = Markdown
function TaskLink($id) { if (Get-Command Get-TrackerUrl -ea 0) { Get-TrackerUrl $id } else { "$id" } }

function Esc($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }

$script:Palette = @{
  PASS           = @{ fg = '#166534'; bg = '#dcfce7'; label = 'PASS' }
  PASS_WITH_NOTE = @{ fg = '#92400e'; bg = '#fef3c7'; label = 'PASS (note)' }
  FAIL           = @{ fg = '#991b1b'; bg = '#fee2e2'; label = 'FAIL' }
  NOT_TESTED     = @{ fg = '#374151'; bg = '#f3f4f6'; label = 'NOT TESTED' }
  PENDING        = @{ fg = '#1e40af'; bg = '#dbeafe'; label = 'PENDING' }
  OUT_OF_SCOPE   = @{ fg = '#6b7280'; bg = '#f9fafb'; label = 'OUT OF SCOPE' }   # never-tested channel
}
$script:Font = "font-family:Arial,Helvetica,sans-serif"
$script:Cell = "border:1px solid #d1d5db;padding:6px 8px;vertical-align:top;font-size:10pt"
# evidence names (evidence-standard.md 2); sync with browser.mjs EVIDENCE_NAME, $script:EvidenceExt, -FixNames
$script:EvidenceName = '^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2}m?)?|_\d{2}m?)_[a-z0-9]+([-._][a-z0-9]+)*|[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?|jsonl|ndjson)$'
# types finalize publishes
$script:EvidenceExt = '^\.(jpe?g|png|json|jsonl|ndjson|log|csv|txt|pdf|mp4|html|xlsx?)$'

# "F2-T4_02_after-edit.jpeg" -> "After edit"
function Caption($file) {
  if ($file -match '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify)?(_\d{2}m?)?_(.+)\.\w+$') {
    $c = ($Matches[3] -replace '[-_]', ' ').Trim(); $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }
    if (-not $c) { return $file }   # one odd name never crashes the publish
    return ($c.Substring(0, 1).ToUpper() + $c.Substring(1)) + $v
  }
  return $file
}
# unknown result renders plain
function Pal($r) { $p = $script:Palette[[string]$r]; if ($p) { $p } else { @{ fg = '#111827'; bg = '#ffffff'; label = $(if ($r) { [string]$r } else { '(no result)' }) } } }
function Chip($k, $n) { $p = $script:Palette[$k]; "<td style='background:$($p.bg);color:$($p.fg);padding:8px 14px;text-align:center;$script:Font;border:1px solid #ffffff'><span style='font-size:18pt;font-weight:bold'>$n</span><br><span style='font-size:8pt;font-weight:bold'>$($p.label)</span></td>" }
function Img($map, $f, $w) {
  $src = if ($map.files[$f].id) { "https://drive.google.com/uc?export=view&amp;id=$($map.files[$f].id)" } else { $map.files[$f].link }
  "<p style='margin:4px 0 12px 0'><img src='$src' width='$w'><br><span style='font-size:9pt;color:#6b7280'>$(Esc (Caption $f)) · <a href='$($map.files[$f].link)'>$(Esc $f)</a></span></p>"
}
# phone shots render narrow
function ImgWidth($f) { if ($f -match '\.png$' -or $f -match '(?i)(^|[_-])(app|phone|mobile|emulator)([_.-])|-L\d+_') { 260 } else { 600 } }

function Build-QaReport($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl, $DocNote) {
  $checks = @($Res.checks)
  $n = @{}; foreach ($k in $script:Palette.Keys) { $n[$k] = @($checks | Where-Object result -eq $k).Count }
  $fails = @($checks | Where-Object result -eq 'FAIL')
  $passAll = $n.PASS + $n.PASS_WITH_NOTE
  $verdict = if ($fails.Count) { @('#991b1b', 'Failures found') } elseif ($n.NOT_TESTED) { @('#374151', 'Partly tested') } elseif ($n.PENDING) { @('#1e40af', 'Passed so far — app checks pending') } else { @('#166534', 'All checks passed') }
  $h = New-Object System.Text.StringBuilder
  function A($s) { [void]$h.Append($s) }

  A "<html><head><meta charset='utf-8'></head><body style='$script:Font;color:#111827;font-size:10.5pt'>"
  # Title block
  A "<p style='font-size:9pt;color:#6b7280;margin:0'>TEST RESULTS · $(Esc $Date)</p>"
  A "<h1 style='font-size:20pt;margin:2px 0 4px 0;color:#111827'>$(Esc $Title) — $(Esc $Code)</h1>"
  A "<p style='font-size:12pt;margin:0 0 10px 0;color:$($verdict[0])'><b>$($verdict[1])</b></p>"
  # Count chips
  A "<table style='border-collapse:collapse;margin:6px 0 12px 0'><tr>"
  foreach ($k in 'PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'PENDING', 'OUT_OF_SCOPE') { if ($n[$k] -or $k -in 'PASS', 'FAIL') { A (Chip $k $n[$k]) } }
  A "</tr></table>"
  # At a glance
  $glance = "$passAll of $($checks.Count - $n.OUT_OF_SCOPE) checks pass"
  if ($n.PASS_WITH_NOTE) { $glance += " ($($n.PASS_WITH_NOTE) with a note)" }
  if ($fails.Count) { $glance += ". $($fails.Count) failed: " + (($fails | ForEach-Object { "$($_.id) ($($_.screen))" }) -join ', ') + $(if (@($fails | Where-Object verify -eq 'confirmed').Count) { ' — confirmed by an independent re-test' } else { '' }) }
  if ($n.NOT_TESTED) { $glance += ". $($n.NOT_TESTED) not tested (reasons below)" }
  if ($n.PENDING) { $glance += ". $($n.PENDING) app/other-lane checks are tested separately" }
  if ($n.OUT_OF_SCOPE) { $glance += ". $($n.OUT_OF_SCOPE) out of scope (channels never tested by agent QA)" }
  A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:14px'>At a glance</h2><p>$(Esc $glance).</p>"
  if ($DocNote) { A "<p style='background:#f3f4f6;padding:6px 8px'>$DocNote</p>" }

  # Facts table
  A "<table style='border-collapse:collapse;width:100%;margin:8px 0'>"
  function Fact($k, $v) { "<tr><td style='$script:Cell;background:#f8fafc;width:22%'><b>$k</b></td><td style='$script:Cell'>$v</td></tr>" }
  A (Fact 'Scope' $(if ($GuideUrl) { "<a href='$GuideUrl'>$(Esc $Item.title)</a> (tester guide)" } else { Esc $Item.title }))
  if (@($Item.subtasks).Count) { A (Fact 'Tasks' ((@($Item.subtasks) | ForEach-Object { "<a href='$(TaskLink $_.id)'>$(Esc $_.name)</a>$(if ($_.mrs) { " <span style='color:#6b7280'>· MRs $(Esc $_.mrs)</span>" })" }) -join '<br>')) }
  if (@($Run.envLines).Count) { A (Fact 'Environment' ((@($Run.envLines) | ForEach-Object { Esc $_ }) -join '<br>')) }
  A (Fact 'Tested by' "$(Esc $Tester) with Claude Code · $(Esc $Date)")
  A (Fact 'Evidence' "<a href='$($Map.folderLink)'>$(if ($Map.local) { 'Run folder' } else { 'Drive folder' })</a> · $(@($Map.files.Keys).Count) files")
  A "</table>"

  # Results table
  A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Results</h2>"
  A "<table style='border-collapse:collapse;width:100%'><tr>"
  foreach ($c in @(@('Check', '7%'), @('Screen / area', '16%'), @('Result', '12%'), @('What was done', '30%'), @('What we saw', '35%'))) { A "<td style='$script:Cell;background:#1f3a68;color:#ffffff;width:$($c[1])'><b>$($c[0])</b></td>" }
  A "</tr>"
  $i = 0
  foreach ($c in $checks) {
    $p = (Pal $c.result); $zebra = if ($i++ % 2) { '#f8fafc' } else { '#ffffff' }
    $v = if ($c.verify) { "<br><span style='font-size:8pt;color:#374151'>re-test: $(Esc $c.verify)</span>" } else { '' }
    A "<tr style='background:$zebra'><td style='$script:Cell'><b>$(Esc $c.id)</b></td><td style='$script:Cell'>$(Esc $c.screen)</td><td style='$script:Cell;background:$($p.bg);color:$($p.fg)'><b>$($p.label)</b>$v</td><td style='$script:Cell'>$(Esc $c.what_was_done)</td><td style='$script:Cell'>$(Esc $c.observed)</td></tr>"
  }
  A "</table>"

  # Failure details
  if ($fails.Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #991b1b;padding-bottom:3px;margin-top:16px;color:#991b1b'>Failures in detail</h2>"
    foreach ($c in $fails) {
      A "<h3 style='font-size:11.5pt;margin:12px 0 4px 0'>$(Esc $c.id) — $(Esc $c.screen)</h3><table style='border-collapse:collapse;width:100%'>"
      A (Fact 'Steps' (Esc $c.what_was_done)); A (Fact 'What we saw' (Esc $c.observed))
      if ($c.verify) { A (Fact 'Independent re-test' (Esc $c.verify)) }
      $data = @($c.evidence | Where-Object { $_ -notmatch '\.(png|jpe?g)$' -and $Map.files[$_] })
      if ($data.Count) { A (Fact 'Data evidence' (($data | ForEach-Object { "<a href='$($Map.files[$_].link)'>$(Esc $_)</a>" }) -join '<br>')) }
      A "</table>"
      foreach ($f in @($c.evidence | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] })) { A (Img $Map $f (ImgWidth $f)) }
    }
  }

  # Notes, not tested, findings, setup
  $notes = @($checks | Where-Object { $_.result -in 'PASS_WITH_NOTE', 'NOT_TESTED', 'OUT_OF_SCOPE' })
  if ($notes.Count -or @($Res.findings).Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Notes</h2><ul>"
    foreach ($c in $notes) { A "<li><b>$(Esc $c.id)</b> ($((Pal $c.result).label)): $(Esc $c.observed)</li>" }
    foreach ($f in @($Res.findings)) { A "<li>$(Esc $f)</li>" }
    A "</ul>"
  }
  $setup = @($Res.setup_changes) + @($Res.data_created) | Where-Object { $_ }
  if ($setup.Count) { A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Setup changes and test data</h2><ul>$((($setup | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''))</ul>" }

  # Screenshots of the passing checks
  $gallery = @($checks | Where-Object { $_.result -ne 'FAIL' -and @($_.evidence | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] }).Count })
  if ($gallery.Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Screenshots</h2>"
    foreach ($c in $gallery) {
      A "<h3 style='font-size:11pt;margin:12px 0 2px 0'>$(Esc $c.id) — $(Esc $c.screen) <span style='color:$((Pal $c.result).fg);font-size:9pt'>$((Pal $c.result).label)</span></h3>"
      foreach ($f in @($c.evidence | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] })) { A (Img $Map $f (ImgWidth $f)) }
    }
  }

  # Evidence index
  $all = @($Map.files.Keys | Sort-Object)
  if ($all.Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Evidence index</h2><table style='border-collapse:collapse;width:100%'><tr>"
    foreach ($c in 'File', 'Check', 'Type', 'Shows') { A "<td style='$script:Cell;background:#1f3a68;color:#ffffff'><b>$c</b></td>" }
    A "</tr>"
    foreach ($f in $all) {
      $chk = if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+)') { $Matches[1] } else { '' }
      $type = switch -Regex ($f) { '\.(png|jpe?g)$' { 'Screenshot' } '\.json$' { 'API / data' } '\.(jsonl|ndjson)$' { 'Data (JSON lines)' } '\.(log|txt)$' { 'Log' } '\.csv$' { 'Export (CSV)' } '\.pdf$' { 'Document (PDF)' } '\.mp4$' { 'Recording' } default { 'File' } }
      A "<tr><td style='$script:Cell'><a href='$($Map.files[$f].link)'>$(Esc $f)</a></td><td style='$script:Cell'>$(Esc $chk)</td><td style='$script:Cell'>$type</td><td style='$script:Cell'>$(Esc (Caption $f))</td></tr>"
    }
    A "</table>"
  }
  A "<p style='font-size:8pt;color:#9ca3af;margin-top:18px'>Generated by the Claude Code QA kit. Verdict rules and evidence standard: defects are always FAIL; every FAIL is re-tested independently before a bug task is raised.</p>"
  A '</body></html>'
  $h.ToString()
}

# Markdown: GitHub/GitLab comments and a file
function Build-QaReportMd($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl) {
  function MdEsc($t) { ([string]$t -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
  function Lnk($f) { if ($Map.files[$f]) { "[$f]($(([string]$Map.files[$f].link) -replace ' ', '%20'))" } else { $f } }
  $label = @{ PASS = 'PASS'; PASS_WITH_NOTE = 'PASS (note)'; FAIL = '**FAIL**'; NOT_TESTED = 'NOT TESTED'; PENDING = 'PENDING'; OUT_OF_SCOPE = 'OUT OF SCOPE' }
  $checks = @($Res.checks)
  $n = @{}; foreach ($k in $label.Keys) { $n[$k] = @($checks | Where-Object result -eq $k).Count }
  $fails = @($checks | Where-Object result -eq 'FAIL')
  $verdict = if ($fails.Count) { 'Failures found' } elseif ($n.NOT_TESTED) { 'Partly tested' } elseif ($n.PENDING) { 'Passed so far — other-lane checks pending' } else { 'All checks passed' }
  $o = New-Object System.Collections.Generic.List[string]
  $o.Add("# $Title — $Code"); $o.Add(''); $o.Add("Test results · $Date · **$verdict**"); $o.Add('')
  $o.Add("PASS $($n.PASS + $n.PASS_WITH_NOTE) (with note $($n.PASS_WITH_NOTE)) · FAIL $($n.FAIL) · NOT TESTED $($n.NOT_TESTED) · PENDING $($n.PENDING) · OUT OF SCOPE $($n.OUT_OF_SCOPE) · total $($checks.Count)"); $o.Add('')
  $o.Add('| | |'); $o.Add('|---|---|')
  $o.Add("| Scope | $(if ($GuideUrl) { "[$(MdEsc $Item.title)]($GuideUrl) (tester guide)" } else { MdEsc $Item.title }) |")
  if (@($Item.subtasks).Count) { $o.Add("| Tasks | $((@($Item.subtasks) | ForEach-Object { "[$(MdEsc $_.name)]($(TaskLink $_.id))$(if ($_.mrs) { " · MRs $(MdEsc $_.mrs)" })" }) -join '<br>') |") }
  if (@($Run.envLines).Count) { $o.Add("| Environment | $((@($Run.envLines) | ForEach-Object { MdEsc $_ }) -join '<br>') |") }
  $o.Add("| Tested by | $(MdEsc $Tester) with Claude Code · $Date |")
  $o.Add("| Evidence | $(MdEsc $Map.folderLink) · $(@($Map.files.Keys).Count) files |"); $o.Add('')
  $o.Add('## Results'); $o.Add(''); $o.Add('| Check | Screen / area | Result | What was done | What we saw |'); $o.Add('|---|---|---|---|---|')
  foreach ($c in $checks) { $o.Add("| **$(MdEsc $c.id)** | $(MdEsc $c.screen) | $($label[[string]$c.result])$(if ($c.verify) { " (re-test: $(MdEsc $c.verify))" }) | $(MdEsc $c.what_was_done) | $(MdEsc $c.observed) |") }
  if ($fails.Count) {
    $o.Add(''); $o.Add('## Failures in detail')
    foreach ($c in $fails) {
      $o.Add(''); $o.Add("### $($c.id) — $($c.screen)"); $o.Add("**Steps:** $($c.what_was_done)"); $o.Add(''); $o.Add("**Saw:** $($c.observed)")
      if ($c.verify) { $o.Add(''); $o.Add("**Independent re-test:** $($c.verify)") }
      $ev = @($c.evidence | Where-Object { $_ }); if ($ev.Count) { $o.Add(''); $o.Add("**Evidence:** $(($ev | ForEach-Object { Lnk $_ }) -join ', ')") }
      foreach ($f in @($ev | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] })) { $o.Add(''); $o.Add("![$(Caption $f)]($(([string]$Map.files[$f].link) -replace ' ', '%20'))") }
    }
  }
  $notes = @($checks | Where-Object { $_.result -in 'PASS_WITH_NOTE', 'NOT_TESTED', 'OUT_OF_SCOPE' })
  if ($notes.Count -or @($Res.findings).Count) {
    $o.Add(''); $o.Add('## Notes'); $o.Add('')
    foreach ($c in $notes) { $o.Add("- **$($c.id)** ($($label[[string]$c.result])): $(MdEsc $c.observed)") }
    foreach ($f in @($Res.findings)) { $o.Add("- $(MdEsc $f)") }
  }
  $setup = @($Res.setup_changes) + @($Res.data_created) | Where-Object { $_ }
  if ($setup.Count) { $o.Add(''); $o.Add('## Setup changes and test data'); $o.Add(''); foreach ($s in $setup) { $o.Add("- $(MdEsc $s)") } }
  $all = @($Map.files.Keys | Sort-Object)
  if ($all.Count) {
    $o.Add(''); $o.Add('## Evidence index'); $o.Add(''); $o.Add('| File | Check | Shows |'); $o.Add('|---|---|---|')
    foreach ($f in $all) { $chk = if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+)') { $Matches[1] } else { '' }; $o.Add("| $(Lnk $f) | $chk | $(MdEsc (Caption $f)) |") }
  }
  $o.Add(''); $o.Add('_Generated by the Claude Code QA kit. Defects are always FAIL; every FAIL is re-tested independently before a bug task is raised._')
  $o -join "`n"
}

# ---- seat: memory seat (fair FIFO, keepFreeGB floor) + item claim (first claimer owns <run>/<code>)
function Invoke-Seat {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'release', 'status')][string]$Action,
  [string]$Agent, [ValidateSet('web', 'api', 'app')][string]$Kind = 'web',
  [string]$RunDir, [string]$Code, [string]$Owner = 'w1',
  [int]$WaitMinutes = 8, [double]$KeepFreeGB = 0
)
$ErrorActionPreference = 'Stop'
$dir = Get-KitPath qa-seats; $seats = Join-Path $dir 'seats'; $wait = Join-Path $dir 'wait'; $claims = Join-Path $dir 'claims'
New-Item -ItemType Directory -Force $seats, $wait, $claims | Out-Null
# floor = gate keepFreeGB (else 15% RAM, min 6 GB)
if (-not $KeepFreeGB) {
  $KeepFreeGB = if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
}
# gate-promised GB: running builds/phones + queued builds
$gateLedger = Join-Path (Get-KitTemp) 'claude-build-gate'
function Get-GatePromisedGB([string]$Ledger = $gateLedger) {
  $rd = { param($d) @(Get-ChildItem $d -Filter '*.json' -ea 0 | ? Name -ne 'history.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | ? { $_.pid }) }
  $run = & $rd $Ledger; $queued = & $rd (Join-Path $Ledger 'queue')
  if (-not ($run.Count + $queued.Count)) { return 0 }
  $ws = @{}; $kids = @{}
  foreach ($p in Get-SysProcs -NoCommandLine) { $ws[$p.Id] = $p.WorkingSet; if (-not $kids.ContainsKey($p.ParentId)) { $kids[$p.ParentId] = [Collections.ArrayList]::new() }; [void]$kids[$p.ParentId].Add($p.Id) }
  $sum = 0.0
  foreach ($e in $run) {
    if (-not $ws.ContainsKey([int]$e.pid)) { continue }
    $used = 0; $st = [Collections.Stack]::new(); $st.Push([int]$e.pid)
    while ($st.Count) { $n = $st.Pop(); if ($ws.ContainsKey($n)) { $used += $ws[$n] }; if ($kids.ContainsKey($n)) { foreach ($k in $kids[$n]) { $st.Push($k) } } }
    $sum += [math]::Max(0, [double]$e.need - $used / 1GB)
  }
  foreach ($t in $queued) { if ($ws.ContainsKey([int]$t.pid)) { $sum += [double]$t.need } }
  [math]::Round($sum, 1)
}
$need = @{ web = 1.5; api = 0.4; app = 0.4 }[$Kind]
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-qa-seats')
function Locked([scriptblock]$b) {
  $got = $false
  try { $got = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed holder hands it over
  try { & $b } finally { if ($got) { $mutex.ReleaseMutex() } }
}
function FreeGB { Get-FreeGB }
function Safe($s) { $s -replace '[^\w.-]', '_' }
# a seat whose holder is gone or > 3 h old is released
function Seats { @(Get-ChildItem $seats -Filter *.json | ForEach-Object { $o = Get-Content $_.FullName -Raw | ConvertFrom-Json; if (((Get-Date) - [datetime]$o.since).TotalHours -gt 3 -or (Test-KitHolder $o) -eq $false) { Remove-Item $_.FullName -Force } else { $o } }) }
$holder = Get-KitHolder

switch ($Action) {
  'status' {
    $s = Seats
    "free RAM $(FreeGB) GB, $(Get-GatePromisedGB) GB promised by the memory gate, keep $KeepFreeGB GB free (gate.keepFreeGB); $($s.Count) seat(s): $(($s | ForEach-Object { "$($_.agent) ($($_.kind))" }) -join ', ')"
    Get-ChildItem $wait -Filter *.json | Sort-Object LastWriteTime | ForEach-Object { $w = Get-Content $_.FullName -Raw | ConvertFrom-Json; "waiting: $($w.agent) ($($w.kind)) since $($w.since)" }
    Get-ChildItem $claims -Filter *.json | ForEach-Object { $c = Get-Content $_.FullName -Raw | ConvertFrom-Json; "claim: $($c.run)/$($c.code) by $($c.owner) since $($c.since)" }
  }

  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    Remove-Item (Join-Path $seats "$(Safe $Agent).json"), (Join-Path $wait "$(Safe $Agent).json") -Force -ea 0
    "seat released: $Agent"
  }

  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    # 1. item claim
    if ($RunDir -and $Code) {
      $run = Split-Path $RunDir -Leaf
      $cf = Join-Path $claims "$(Safe $run)__$(Safe $Code).json"
      $verdict = Locked {
        if (Test-Path (Join-Path $RunDir "$Code/finalize.json")) { return "ALREADY: $Code was finished and published" }
        if (Test-Path (Join-Path $RunDir "$Code/held.json")) { return "ALREADY: $Code was tested; results held for the lead to publish" }
        if (Test-Path $cf) {
          $c = Get-Content $cf -Raw | ConvertFrom-Json
          $alive = Test-KitHolder $c   # $null unknown: only that expires after 6 h
          if ($c.owner -ne $Owner -and ($alive -eq $true -or ($null -eq $alive -and ((Get-Date) - [datetime]$c.since).TotalHours -lt 6))) { return "ALREADY: $Code is being tested by worker $($c.owner)" }   # a dead holder's claim is free
        }
        ([ordered]@{ run = $run; code = $Code; owner = $Owner; since = (Get-Date).ToString('s') } + $holder) | ConvertTo-Json | Set-Content $cf
        $null
      }
      if ($verdict) { $verdict; exit 3 }
    }
    # 2. memory seat (fair FIFO)
    $me = Safe $Agent; $wf = Join-Path $wait "$me.json"
    if (Test-Path (Join-Path $seats "$me.json")) { "seat already held: $Agent"; exit 0 }
    $rec = { ([ordered]@{ agent = $Agent; kind = $Kind; need = $need; since = (Get-Date).ToString('s') } + $holder) | ConvertTo-Json }
    if (-not (Test-Path $wf)) { & $rec | Set-Content $wf }
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $told = $false
    while ($true) {
      $ok = Locked {
        $mine = Get-Content $wf -Raw | ConvertFrom-Json
        $mine | Add-Member -Force beat (Get-Date).ToString('s'); $mine | ConvertTo-Json | Set-Content $wf    # heartbeat: dead waiters never block
        $ahead = @(Get-ChildItem $wait -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            ? { $_.agent -ne $Agent -and [datetime]$_.since -lt [datetime]$mine.since -and ((Get-Date) - [datetime]$(if ($_.beat) { $_.beat } else { $_.since })).TotalMinutes -lt 3 })
        # promised = seats < 3 min old + gate's builds and phones
        $promised = [double](@(Seats | ? { ((Get-Date) - [datetime]$_.since).TotalMinutes -lt 3 }) | Measure-Object need -Sum).Sum + 0
        $promised = [math]::Round($promised + (Get-GatePromisedGB), 1)
        $left = (FreeGB) - [double]$promised - $need
        if ($ahead.Count -eq 0 -and $left -ge $KeepFreeGB) {
          & $rec | Set-Content (Join-Path $seats "$me.json")
          Remove-Item $wf -Force
          return "seat taken: $Agent ($Kind, ~$need GB); free RAM after it ~$([math]::Round($left, 1)) GB"
        }
        $script:why = if ($ahead.Count) { "$($ahead.Count) agent(s) ahead in the queue" } else { "free RAM $(FreeGB) GB - promised $promised GB - need $need GB < keep $KeepFreeGB GB" }
        $null
      }
      if ($ok) { $ok; exit 0 }
      if (-not $told) { "waiting for a seat: $script:why"; $told = $true }
      if ((Get-Date) -gt $deadline) { "STILL WAITING ($script:why): run the same command again"; exit 4 }
      Start-Sleep 15
    }
  }
}
}

# ---- deployed: is a merged MR live on a test env (CI deploy job, squash, ssh, aws, manual, laneApk)
function Invoke-Deployed {
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json, [switch]$Detail, [string]$Exclude)   # -Exclude <regex>: skip those targets
$ErrorActionPreference = 'SilentlyContinue'
$group = $KitConf.GitlabGroup
$repos = @(Get-KitValue 'repos' @())
function Row($d, $s, $x) { [pscustomobject]@{ mr = $ref; target = $d.target; state = $s; detail = $x } }
function Repo($name) { $repos | ? { $_.name -eq $name -or @($_.aliases) -contains $name } | select -First 1 }
# memoised: supervise asks per round
$memo = @{}
function Api($path) { if (-not $memo.ContainsKey($path)) { $memo[$path] = Invoke-HostApi $path }; $memo[$path] }
function IsAncestor($p, $sha, $ref) { if ($sha -eq $ref) { return $true }; (Api "projects/$p/repository/merge_base?refs[]=$sha&refs[]=$([uri]::EscapeDataString($ref))").id -eq $sha }
# squash / cherry-pick: live if no file differs from $ref
function ContentOn($p, $mr, $sha, $ref) {
  # cheap guard: a ref older than the merge
  $head = Api "projects/$p/repository/commits/$([uri]::EscapeDataString($ref))"
  if (-not $head -or ($mr.merged_at -and [datetimeoffset]$head.committed_date -lt [datetimeoffset]$mr.merged_at)) { return $false }
  if (-not (IsAncestor $p $sha $mr.target_branch)) { return $false }
  $files = @((Api "projects/$p/merge_requests/$($mr.iid)/changes?access_raw_diffs=true").changes | ForEach-Object { $_.new_path; $_.old_path } | Sort-Object -Unique)
  if (-not $files.Count) { return $false }
  $cmp = Api "projects/$p/repository/compare?from=$([uri]::EscapeDataString($ref))&to=$([uri]::EscapeDataString($mr.target_branch))&straight=true"
  if (-not $cmp) { return $false }
  -not @($cmp.diffs | ? { $files -contains $_.new_path -or $files -contains $_.old_path }).Count
}
# squash-merged deploy MR: live if one merged into $branch after a source head held the commit
function ViaDeployMr($p, $mr, $sha, $ref, $branch) {
  if (-not $branch -or -not $mr.merged_at) { return $false }
  $after = ([datetimeoffset]$mr.merged_at).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
  foreach ($dm in @(Api "projects/$p/merge_requests?state=merged&target_branch=$([uri]::EscapeDataString($branch))&updated_after=$after&per_page=50") | ? { $_ -and $_.iid -ne $mr.iid }) {
    $land = @($dm.merge_commit_sha, $dm.squash_commit_sha) | ? { $_ } | select -First 1
    if ($land -and $dm.sha -and (IsAncestor $p $sha $dm.sha) -and (IsAncestor $p $land $ref)) { return $true }
  }
  $false
}
# NOT-DEPLOYED only if the host answers, else UNKNOWN
function NotLiveRow($p, $ref, $d, [string]$detail) { if ($null -eq (Api "projects/$p/repository/commits/$([uri]::EscapeDataString($d.branch))")) { Row $d 'UNKNOWN' "the git host did not answer for $($d.branch): try again" } else { Row $d 'NOT-DEPLOYED' $detail } }
function OnRef($p, $mr, $sha, $ref, $branch = $ref) { (IsAncestor $p $sha $ref) -or (ViaDeployMr $p $mr $sha $ref $branch) -or (ContentOn $p $mr $sha $ref) }
# laneApk: true -> <outDir>/apk/app.json; a string = its path
function LaneApk($d) {
  $f = if ($d.laneApk -is [string]) { $d.laneApk } else {
    $sc = Join-Path (Split-Path $PSScriptRoot) 'android-swarm/swarm.config.json'
    $o = if (Test-Path $sc) { (Get-Content $sc -Raw | ConvertFrom-Json).outDir }
    Join-Path $(if ($o) { [string]$o } else { Get-KitPath android-swarm }) 'apk/app.json'
  }
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}
# $null if checkout or commit missing
function LocalAncestor($dir, $sha, $commit) {
  if (-not $dir -or -not (Test-Path $dir)) { return $null }
  git -C $dir cat-file -e "$commit^{commit}" 2>$null; if ($LASTEXITCODE) { return $null }
  git -C $dir merge-base --is-ancestor $sha $commit 2>$null
  $LASTEXITCODE -eq 0
}
# probeField: JSON path in the answer
function Probe($d, $r) {
  if ($d.tag) { git -C $r.checkout fetch -q --tags 2>$null; return @(git -C $r.checkout tag --sort=-creatordate 2>$null | ? { $_ -match $d.tag })[0] }
  $o = if ($d.probe -match '^https?://') { try { (Invoke-WebRequest $d.probe -TimeoutSec 30).Content } catch { '' } } else { (Invoke-Sh $d.probe) -join "`n" }
  if ($d.probeField) { try { $j = $o | ConvertFrom-Json; foreach ($k in $d.probeField.Split('.')) { $j = $j.$k }; $o = "$j" } catch { $o = '' } }
  [regex]::Match("$o", '\b[0-9a-f]{7,40}\b').Value
}
# one memoised ssh call (script as base64); rc 0 match, 1 DIFF, 2 failed
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
function SshState($s, $sha) {
  $sub = ([string]$s.subdir).Trim('/')
  $k = "$($s.host)|$($s.repoDir)|$sub|$($s.appDir)|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $xs = (@($s.exclude | ? { $_ }) | ForEach-Object { Sq $_ }) -join ' '
  $awk = 'NR == FNR { if (length($0) > 66) a[substr($0, 67)] = substr($0, 1, 64); next } length($0) > 66 { p = substr($0, 67); if (!(p in a)) print "not installed: " p; else if (a[p] != substr($0, 1, 64)) print "differs: " p }'
  $sh = @(
    '{'
    "R=$(Sq ([string]$s.repoDir).TrimEnd('/')); SUB=$(Sq $sub); A=$(Sq ([string]$s.appDir).TrimEnd('/')); X=($xs); SU=$(if ($s.sudo -ne $false) { "'sudo -n'" })"
    'H=sha256sum; command -v sha256sum >/dev/null || H="shasum -a 256"'
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service) { "echo `"SVC=`$(systemctl show -p ActiveEnterTimestamp --value $(Sq $s.service) 2>/dev/null)`"" })
    'skip() { local c pat cs; IFS=/ read -ra cs <<< "$1"; for c in "${cs[@]}"; do for pat in "${X[@]}"; do [[ $c == $pat ]] && return 0; done; done; return 1; }'
    'cd "$R" 2>/dev/null || { echo RC=2; echo "DIFF=cannot cd to $R"; exit 0; }'
    '$SU test -d "$A" 2>/dev/null || { echo RC=2; echo "DIFF=$SU test -d $A failed (no app dir / passwordless sudo: ssh.sudo false)"; exit 0; }'
    'L=$(mktemp) || { echo RC=2; echo "DIFF=mktemp failed"; exit 0; }; trap ''rm -f "$L"'' EXIT'
    'git ls-files -z -- ${SUB:+"$SUB"} | while IFS= read -r -d "" f; do r="${f#"$SUB"/}"; skip "$r" || printf "%s\0" "$r"; done > "$L"'
    'N=$(tr -cd "\0" < "$L" | wc -c); echo "FILES=$N"'
    '[ "$N" -gt 0 ] || { echo RC=2; echo "DIFF=git ls-files lists no tracked files under ${SUB:-the repo}"; exit 0; }'
    'src=$(cd "$R/$SUB" && xargs -0 $H -- < "$L" 2>/dev/null)'
    'app=$($SU sh -c ''cd "$1" && shift && xargs -0 "$@" -- 2>/dev/null'' _ "$A" $H < "$L")'
    "out=`$(awk $(Sq $awk) <(printf '%s\n' `"`$app`") <(printf '%s\n' `"`$src`"))"
    'if [ -n "$out" ]; then echo RC=1; printf "%s\n" "$out" | sed "s/^/DIFF=/"; else echo RC=0; fi'
    '}'
  ) -join "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
  $key = [string]$s.key -replace '^~', $HOME
  $lines = @(ssh -i $key -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $s.host "echo $b64 | base64 -d | bash" 2>$null)
  $r = if (-not ($lines -match '^RC=')) { $null } else {
    @{ head = (($lines -match '^HEAD=') -replace '^HEAD=', '' | select -First 1).Trim()
       anc = [bool]($lines -match '^ANC=yes'); rc = [int](($lines -match '^RC=') -replace '^RC=', '' | select -First 1)
       diff = @($lines -match '^DIFF=' -replace '^DIFF=', ''); svc = (($lines -match '^SVC=') -replace '^SVC=', '' | select -First 1)
       files = [int](($lines -match '^FILES=') -replace '^FILES=', '' | select -First 1) }
  }
  $memo[$k] = $r; $r
}

# pwsh -File keeps the quotes: strip, split
$out = foreach ($m in @(Split-KitList $Mrs)) {
  if ($m -notmatch '^(?<repo>[\w.-]+)!(?<iid>\d+)$') { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'expected <repo>!<iid>' }; continue }
  $r = Repo $Matches.repo; $iid = $Matches.iid
  if (-not $r) { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'repo not in kit.local.json' }; continue }
  $p = [uri]::EscapeDataString($(if ($group) { "$group/$($r.name)" } else { $r.name })); $ref = "$($r.name)!$iid"
  $mr = Api "projects/$p/merge_requests/$iid"
  if (-not $mr -or -not $mr.iid) { [pscustomobject]@{ mr = $ref; target = ''; state = 'UNKNOWN'; detail = 'git host did not answer (glab/gh auth status?)' }; continue }   # a failed call is not 'not merged'
  if ($mr.state -ne 'merged') { [pscustomobject]@{ mr = $ref; target = ''; state = 'NOT-MERGED'; detail = "$($mr.state)" }; continue }
  # fast-forward: the MR head sha landed
  $sha = @($mr.squash_commit_sha, $mr.merge_commit_sha, $mr.sha) | ? { $_ } | select -First 1
  if (-not $sha) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'UNKNOWN'; detail = 'merged MR has no commit sha (glab auth status?)' }; continue }
  $s8 = $sha.Substring(0, [math]::Min(8, $sha.Length))
  $deps = @($r.deploys | ? { (-not $Target -or $_.target -eq $Target) -and (-not $Exclude -or $_.target -notmatch $Exclude) })
  if (-not $deps.Count) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'NO-TARGET'; detail = 'no deploys configured for this repo' }; continue }
  foreach ($d in $deps) {
    if ($d.laneApk) {   # app repo: lane APK commit
      $ai = LaneApk $d
      if (-not $ai -or -not $ai.commit) { Row $d 'UNKNOWN' 'no lane APK stamp (android-swarm apk/app.json): build the APK with swarm.ps1 build'; continue }
      $apk = "APK $($ai.commit) ($($ai.branch), built $($ai.built))"
      $on = LocalAncestor $ai.appDir $sha $ai.commit
      if (-not $on) { $on = OnRef $p $mr $sha $ai.commit $ai.branch }   # else ask the git host
      if ($on) { Row $d 'DEPLOYED' "in the lane $apk (phones get it on their next swarm.ps1 acquire)" }
      else { Row $d 'NOT-DEPLOYED' "$s8 is not in the lane ${apk}: rebuild it (swarm.ps1 build) from a branch holding the merge" }
      continue
    }
    if ($d.ssh) {   # host HEAD holds the merge AND files match
      $s = $d.ssh; $st = SshState $s $sha
      if (-not $st) { Row $d 'UNKNOWN' "no answer from $($s.host) over ssh (key $($s.key); the host needs bash, git, base64)"; continue }
      $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
      if ($st.rc -gt 1 -and -not $st.head) { Row $d 'UNKNOWN' "host checkout unreadable: $(($st.diff | select -First 2) -join '; ')"; continue }   # a wrong repoDir is not 'not deployed'
      if (-not $st.anc) { Row $d 'NOT-DEPLOYED' "$s8 is not in the host checkout ($where)"; continue }
      if ($st.rc -gt 1) { Row $d 'UNKNOWN' "in the host checkout, but the compare failed: $(($st.diff | select -First 2) -join '; ')"; continue }
      if ($st.diff.Count) { Row $d 'NOT-DEPLOYED' "in the host checkout ($where), but $($st.diff.Count) of $($st.files) tracked file(s) differ from the installed app: $(($st.diff | select -First 3) -join '; ')"; continue }
      Row $d 'DEPLOYED' "in the host checkout and installed ($($st.files) tracked files match, $where)"
      continue
    }
    if ($d.probe -or $d.tag) {   # live commit: probe (URL / command) or newest matching tag
      $c = Probe $d $r; $w = if ($d.tag) { "tag $c" } else { "probe commit $c" }
      if (-not $c) { Row $d 'UNKNOWN' "no commit from $(if ($d.tag) { "tags matching $($d.tag)" } else { "probe $($d.probe)" })"; continue }
      $on = LocalAncestor $r.checkout $sha $c; if ($null -eq $on) { $on = OnRef $p $mr $sha $c }
      Row $d $(if ($on) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }) "$w $(if ($on) { 'holds' } else { 'lacks' }) $s8"; continue
    }
    if ($d.manual) { Row $d 'MANUAL' 'deployed by hand: confirm with the owner or an ssh check'; continue }
    if ($d.awsStack) {   # no CI job: stack updated after the merge
      $ra = if ($d.region) { @('--region', $d.region) } else { @() }   # else AWS CLI default region
      $upd = aws cloudformation describe-stacks @ra --stack-name $d.awsStack --query 'Stacks[0].[LastUpdatedTime,StackStatus,CreationTime]' --output text 2>$null
      if (-not $upd) { Row $d 'UNKNOWN' "cannot read stack $($d.awsStack) (aws sts get-caller-identity?)"; continue }
      $at, $st, $created = "$upd" -split '\s+'
      if ($at -eq 'None') { $at = $created }   # a stack never updated since creation
      try {
        if ([datetimeoffset]$at -gt [datetimeoffset]$mr.merged_at -and $st -match 'COMPLETE$' -and $st -notmatch 'ROLLBACK') { Row $d 'DEPLOYED' "stack $($d.awsStack) updated $at after the merge (by hand: confirm the build was from the merged branch)" }
        else { Row $d 'NOT-DEPLOYED' "stack $($d.awsStack) last updated $at ($st), merged $($mr.merged_at)" }
      } catch { Row $d 'UNKNOWN' "stack $($d.awsStack): cannot read its update time ($upd)" }
      continue
    }
    if (-not (OnRef $p $mr $sha $d.branch)) { NotLiveRow $p $ref $d "not on $($d.branch) yet"; continue }
    $hit = $null
    # a pipeline older than the merge cannot hold it
    foreach ($pl in @(Api "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10") | ? { -not $mr.merged_at -or [datetimeoffset]$_.created_at -ge [datetimeoffset]$mr.merged_at }) {
      $job = @(Api "projects/$p/pipelines/$($pl.id)/jobs?per_page=100") | ? { $_.name -eq $d.job } | select -First 1
      if ($job.status -eq 'success' -and ($pl.sha -eq $sha -or (OnRef $p $mr $sha $pl.sha $d.branch))) { $hit = $job; break }
    }
    if ($hit) { Row $d 'DEPLOYED' "$($d.job) finished $($hit.finished_at)" }
    else { NotLiveRow $p $ref $d "on $($d.branch), but no successful $($d.job) includes it yet" }
  }
}
$row = { "{0,-13} {1,-18} {2,-12} {3}" -f $_.state, $_.mr, $_.target, $_.detail }
if ($Json) { $out | ConvertTo-Json -Depth 3 }
elseif ($Detail) { $out | ForEach-Object $row }
else {
  $live = @($out | ? state -eq 'DEPLOYED')
  "deployed: $($live.Count)/$(@($out).Count) MR x target$(if ($live.Count) { ' (' + (($live | ForEach-Object { "$($_.mr)@$($_.target)" }) -join ', ') + ')' })"
  $out | ? state -ne 'DEPLOYED' | ForEach-Object $row
}
exit $(if (@($out | ? { $_.state -ne 'DEPLOYED' }).Count) { 1 } else { 0 })
}

# ---- api: call a target's API as a test user (targets.local.json); -Save = redacted request/response evidence
function Invoke-Api {
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = 'admin',
  [string]$Tenant = $null,
  [string]$Save = $null,            # without .json
  [string]$OutDir = $null,          # default: <runtime>/work/evidence
  [hashtable]$Headers = @{},
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
# absolute only: a bound hashtable became a relative folder
if ($OutDir -and -not [IO.Path]::IsPathRooted($OutDir)) { throw "-OutDir must be an absolute folder path, got '$OutDir' (a variable holding an object? PowerShell names are case-insensitive: `$o is `$O)" }
# Git Bash rewrites '/api/x' into a Git path: undo
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $Path = '/' + ($Matches.rest -replace '\\', '/') }
$here = $PSScriptRoot
$cfgFile = Join-Path $here 'targets.local.json'
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - run orch.ps1 setup -WriteLocal, then fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
# a QA run pins its targets (KIT_QA_TARGETS)
$pin = @("$env:KIT_QA_TARGETS" -split '[,\s]+' | ? { $_ })
if ($pin.Count -and $Target -notin $pin) { throw "target '$Target' is not this QA run's target ($($pin -join ', ')): a run tests only its own env (run.json target / alsoTargets)" }
$t = $cfg.targets.$Target
if (-not $t) { throw "Unknown target '$Target'. Known: $($cfg.targets.PSObject.Properties.Name -join ', ')" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$u = @($t.users.$As)
if (-not $t.users.$As -and $t.auth.type -ne 'none') { throw "No user '$As' in target $Target. Known: $($t.users.PSObject.Properties.Name -join ', ')" }   # not @(...).Count: @($null).Count is 1
$base = $t.api.Replace('{tenant}', $Tenant).TrimEnd('/')
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }
$a = $t.auth
if ($a.type -eq 'query') { $uri += "$(if ($uri -match '\?') { '&' } else { '?' })$($a.param)=$([uri]::EscapeDataString([string]$u[1]))" }
$tls = if ($a.cert) { @{ Certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([string]$a.cert, [string]$a.certPass) } } else { @{} }

function Fill($s) { ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant) }
function Get-Field($o, $path) { foreach ($k in $path.Split('.')) { $o = $o.$k }; $o }

$tokDir = Get-KitPath tokens -Create
$cache = Join-Path $tokDir ("$Target-$Tenant-$As.txt" -replace '[^\w.\-]', '_')
# cache: token (cookie type: Cookie header) + refresh token
function Login([switch]$Refresh) {
  $b = [ordered]@{}; foreach ($p in $a.body.PSObject.Properties) { $b[$p.Name] = if ($p.Value -is [string]) { Fill $p.Value } else { $p.Value } }
  if ($Refresh) { $b = [ordered]@{ grant_type = 'refresh_token'; refresh_token = $script:rt } + $(if ($b.client_id) { @{ client_id = $b.client_id } } else { @{} }) }
  $lu = Fill $(if ($a.path -match '^https?://') { $a.path } else { $base + $a.path })
  $form = $a.contentType -eq 'form' -or $Refresh
  $r = Invoke-WebRequest -Method Post $lu -ContentType $(if ($form) { 'application/x-www-form-urlencoded' } else { 'application/json' }) -Body $(if ($form) { $b } else { $b | ConvertTo-Json -Depth 5 }) -TimeoutSec 60 -SessionVariable ws @tls
  if ($a.type -eq 'cookie') { $tok = (@($ws.Cookies.GetAllCookies()) | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ' }
  else { $j = $r.Content | ConvertFrom-Json; $tok = Get-Field $j $(if ($a.tokenField) { $a.tokenField } else { 'access_token' }); if ($a.refreshField) { $script:rt = Get-Field $j $a.refreshField } }
  if (-not $tok) { throw "login to $Target as $As returned no token" }
  "$tok`n$script:rt" | Set-Content $cache -NoNewline
  $tok
}
function AuthHeaders($tok) {
  $h = @{}
  switch ($a.type) {
    'basic' { $h.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($u[0]):$($u[1])")) }
    { $_ -in 'none', 'query' } { }
    'cookie' { $h.Cookie = $tok; if ($a.csrfCookie -and $tok -match "(?:^|; )$([regex]::Escape($a.csrfCookie))=([^;]+)") { $h[$(if ($a.csrfHeader) { $a.csrfHeader } else { 'X-XSRF-TOKEN' })] = [uri]::UnescapeDataString($Matches[1]) } }
    'command' { $env:KIT_API_BODY = $Body; foreach ($l in @(Invoke-Sh ((Fill $a.cmd).Replace('{method}', $Method.ToUpper()).Replace('{url}', $uri)))) { if ($l -match '^\s*([\w-]+)\s*:\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } } }   # HMAC / SigV4 signer
    default { $n, $v = "$(if ($a.header) { $a.header } else { 'Authorization: Bearer {token}' })".Split(':', 2); $h[$n.Trim()] = $v.Trim().Replace('{token}', $tok) }
  }
  $h
}
$tok = $null; $login = $a.type -in 'login', 'cookie'
if ($login) { $tok, $script:rt = if (Test-Path $cache) { @(Get-Content $cache) + '' }; if (-not "$tok".Trim()) { $tok = Login } }   # empty cache file: log in again
elseif ($a.type -eq 'token') { $tok = if ($a.token) { $a.token } else { [string]$u[1] } }

function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = 'application/json' } + $tls
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  # cookies redacted
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match '(?i)cookie|authorization|token|key|secret|password') { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
  try { $r = Invoke-WebRequest @p; $hm = HeaderMap $r.Headers.GetEnumerator(); return @([int]$r.StatusCode, $r.Content, [string]$hm['content-type'], $hm) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { $hm = HeaderMap (@($resp.Headers) + @($resp.Content.Headers)); return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType, $hm) } else { return @(0, "ERR $($_.Exception.Message)", '', [ordered]@{}) }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $login) { $tok = if ($script:rt) { try { Login -Refresh } catch { Login } } else { Login }; $sw.Restart(); $res = Call $tok }
$sw.Stop()
$status, $content, $ctype, $rhead = $res
# binary response: saved as a file
if ($content -is [byte[]]) {
  $bytes = $content; $content = "[binary $($bytes.Length) bytes, $ctype]"
  if ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Get-KitPath evidence }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = if ([string]$rhead['content-disposition'] -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)') { [IO.Path]::GetExtension($Matches[1]) } else { '' }
    if (-not $ext) { $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '.bin' } } }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}

if ($Save) {
  # evidence-standard.md envelope
  if (-not $OutDir) { $OutDir = Get-KitPath evidence }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  # secrets redacted at any depth
  function Redact($o) {
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $o[$k] = if ("$k" -match $script:secretKey) { '[redacted]' } else { Redact $o[$k] } }; return , $o }
    if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $p.Value = if ($p.Name -match $script:secretKey) { '[redacted]' } else { Redact $p.Value } }; return $o }
    if ($o -is [array]) { return , @($o | ForEach-Object { Redact $_ }) }
    $o
  }
  $script:secretKey = '(?i)passw|^pass$|^pwd$|secret|token|api_?key|authorization|cookie'
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = $s.Substring(0, 200KB) } }; try { Redact (ConvertFrom-Json $s -NoEnumerate) } catch { $s } }
  $red = [ordered]@{}; foreach ($k in $script:sentHeaders.Keys) { $red[$k] = if ($k -match '(?i)authorization|cookie|token|key|secret|password') { '[redacted]' } else { $script:sentHeaders[$k] } }
  $code, $check = if ($Save -match '^([A-Za-z0-9]+)-([A-Za-z]*\d+)') { $Matches[1], $Matches[2] } else { '', '' }
  [ordered]@{
    meta     = [ordered]@{ code = $code; check = $check; target = $Target; tenant = $Tenant; user = [string]$u[0]; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); durationMs = $sw.ElapsedMilliseconds; tool = 'qa.ps1 api' }
    request  = [ordered]@{ method = $Method.ToUpper(); url = ($uri -replace '(?i)([?&][^=&]*(key|token|secret|sig|pass)[^=&]*=)[^&]*', '$1[redacted]'); headers = $red; body = (Parse $Body) }
    response = [ordered]@{ status = $status; headers = $(if ($rhead) { $rhead } else { [ordered]@{ 'content-type' = [string]$ctype } }); body = (Parse $content) }
  } | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutDir "$Save.json") -Encoding utf8
}
"HTTP $status"
$content
if (-not $status -or [int]$status -ge 400) { exit 1 }   # else a 500 looked like success
}

# ---- finalize: publish one tested package (report, tracker comments, result rule); re-run safe
function Invoke-Finalize {
param(
  [Parameter(Mandatory)][string]$RunDir,
  [Parameter(Mandatory)][string]$Code,
  [switch]$NoTracker,
  [switch]$Force,
  [switch]$Check,
  [switch]$FixNames,
  [switch]$AllowMissing,
  [int]$ExpectChecks = -1,              # truncated results.json refused
  [string]$Results = 'results.json',    # -Check: a retry renames only its own
  [ValidateSet('', 'gdocs', 'markdown')][string]$Report = '',
  [string]$Date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
)
$ErrorActionPreference = 'Stop'
if ($FixNames -and -not $Check) { throw '-FixNames works only together with -Check' }
$rtype = if ($Report) { $Report } else { $KitConf.ReportType }
if (-not $Check -and $rtype -eq 'gdocs' -and -not (Get-Command gws -ea 0)) { throw 'reports.type is gdocs but the gws CLI is not on PATH - install/auth gws or use -Report markdown' }
$RunDir = (Resolve-Path $RunDir).Path
$run = Get-Content "$RunDir/run.json" -Raw | ConvertFrom-Json
$item = @($run.items) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
if (-not $item) { throw "no item $Code in $RunDir/run.json" }
$D = "$RunDir/$Code"
if ($Results -ne 'results.json' -and -not $Check) { throw '-Results works only with -Check (publishing reads results.json)' }
$res = Get-Content (Join-Path $D $Results) -Raw | ConvertFrom-Json
if ($ExpectChecks -ge 0 -and @($res.checks).Count -ne $ExpectChecks) {
  $m = "$Code`: $Results has $(@($res.checks).Count) check(s), the workflow sent $ExpectChecks - a truncated copy; nothing published. Write the JSON again, complete."
  if ($Check) { $m; exit 1 } else { throw $m }
}
# copy evidence outside shots/evidence into evidence to upload
if (-not $Check) { New-Item -ItemType Directory -Force "$D/evidence" | Out-Null }
$lost = [Collections.Generic.List[object]]::new()   # listed but found nowhere
foreach ($c in @($res.checks)) {
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -and [string]$_ -notmatch '\.(mjs|cjs|js|jsx|ts|tsx|java|kt|ps1|py|sh)$|\s' } | ForEach-Object {
      $e = [string]$_; $leaf = Split-Path $e -Leaf
      if (-not (Test-Path "$D/shots\$leaf") -and -not (Test-Path "$D/evidence\$leaf")) {
        $src = if ([IO.Path]::IsPathRooted($e) -and (Test-Path $e)) { $e } elseif (Test-Path (Join-Path $D $e)) { Join-Path $D $e } else { (Get-ChildItem $RunDir -Recurse -File -Filter $leaf -ea 0 | Select-Object -First 1).FullName }
        if (-not $src) { $lost.Add([pscustomobject]@{ check = $c; name = $leaf }) }
        elseif (-not $Check) { Copy-Item $src "$D/evidence\$leaf" -Force }
      }
      $leaf } | Select-Object -Unique)
}

# 0. Evidence check first
$files = @(Get-ChildItem "$D/shots", "$D/evidence" -File -ea 0 | Where-Object { $_.Name -notlike 'tmp*' -and $_.Extension -match $script:EvidenceExt })
$badNames = @($files | Where-Object { $_.Name -notmatch $script:EvidenceName } | ForEach-Object Name)
if ($badNames.Count -and -not $Check) { Write-Warning "evidence names not following the standard (published anyway): $($badNames -join ', ')" }
# a listed unsupported type would stay on disk
$badTypes = @(@(foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e -and [IO.Path]::GetExtension([string]$e) -notmatch $script:EvidenceExt) { "$($c.id): $e" } } }) | Select-Object -Unique)
if ($badTypes.Count -and -not $Check) { Write-Warning "evidence listed but of an unsupported type (not published): $($badTypes -join '; ')" }
$lostList = @($lost | ForEach-Object { "$($_.check.id): $($_.name)" })
if ($Check) {
  # standard name, else setup form; nn from the name, else a free one
  $ids = @(@($res.checks) | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Select-Object -Unique | Sort-Object Length -Descending)
  $refBy = @{}; foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e -and -not $refBy.ContainsKey([string]$e)) { $refBy[[string]$e] = [string]$c.id } } }
  $taken = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($x in $files) { $null = $taken.Add($x.Name) }
  function Get-StandardName([string]$name) {
    $ext = [IO.Path]::GetExtension($name).ToLower(); $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $stem = $stem -replace "(?i)^$([regex]::Escape($Code))(?=$|[^A-Za-z0-9])[-_. ]*", ''
    $id = $null
    foreach ($i in $ids) { if ($stem -match "(?i)^$([regex]::Escape($i))(?=$|[^A-Za-z0-9])") { $id = $i; $stem = $stem.Substring($i.Length); break } }
    if (-not $id -and $refBy[$name]) { $id = $refBy[$name] }
    $verify = $stem -match '(?i)(^|[^a-z])verify([^a-z]|$)'
    $stem = $stem -replace '(?i)(^|[^a-z])verify(?=[^a-z]|$)', '$1'
    $nn = -1
    $num = [regex]::Match($stem, '(?<![A-Za-z0-9])(\d{1,2})m?(?![A-Za-z0-9])')
    if ($num.Success) { $nn = [int]$num.Groups[1].Value; $stem = $stem.Remove($num.Index, $num.Length) }
    $what = ($stem.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $what) { $what = if ($ext -match '^\.(jpe?g|png)$') { 'screen' } else { 'evidence' } }
    $make = {
      param($n)
      $c1 = if ($id) { '{0}-{1}{2}_{3:D2}_{4}{5}' -f $Code, $id, $(if ($verify) { '_verify' } else { '' }), $n, $what, $ext } else { $null }
      if ($c1 -and $c1 -match $script:EvidenceName) { return $c1 }
      '{0}-{1:D2}-{2}{3}' -f $Code, $n, $what, $ext   # setup form
    }
    if ($nn -lt 0) {   # no number: next free one
      $pre = if ($id) { "$Code-$id$(if ($verify) { '_verify' })_" } else { "$Code-" }
      $used = @($taken | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { if ($_.Substring($pre.Length) -match '^(\d{2})m?[_-]') { [int]$Matches[1] } })
      $nn = if ($used.Count) { ($used | Measure-Object -Maximum).Maximum + 1 } elseif ($id) { 1 } else { 0 }
    }
    $n = [int]$nn
    $cand = & $make $n
    while (($taken.Contains($cand) -or $cand -notmatch $script:EvidenceName) -and $n -lt 99) { $n++; $cand = & $make $n }
    if ($cand -notmatch $script:EvidenceName -or $taken.Contains($cand)) { return $null }
    $null = $taken.Add($cand); $cand
  }
  # 0-byte file = failed capture: reported, never renamed
  $cited = @{}; foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e) { $cited[[string]$e] = [string]$c.id } } }
  $emptyFiles = @($files | Where-Object { $_.Length -eq 0 -and $cited.ContainsKey($_.Name) })
  $emptyNames = @($emptyFiles | ForEach-Object Name)
  if ($Results -ne 'results.json') { $badNames = @($badNames | Where-Object { $cited.ContainsKey($_) }) }   # a retry renames only its own
  $suggest = [ordered]@{}
  foreach ($b in $badNames) { $suggest[$b] = if ($emptyNames -contains $b) { $null } else { Get-StandardName $b } }
  if ($FixNames -and $suggest.Count) {
    $resFile = Join-Path $D $Results; $raw = [IO.File]::ReadAllText($resFile)
    foreach ($b in @($suggest.Keys)) {
      $new = $suggest[$b]; if (-not $new) { continue }
      $f = $files | Where-Object Name -eq $b | Select-Object -First 1
      Rename-Item -LiteralPath $f.FullName -NewName $new
      # references end in the file name
      $raw = [regex]::Replace($raw, '(?<=["/\\])' + [regex]::Escape($b) + '(?=")', $new.Replace('$', '$$'))
      "  renamed $($f.Directory.Name)/$b -> $new"
      $suggest.Remove($b)
    }
    [IO.File]::WriteAllText($resFile, $raw)
    $badNames = @($suggest.Keys)
  }
  $dups = @(@($res.checks) | Where-Object { $_.id } | Group-Object { [string]$_.id } | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) (x$($_.Count))" })
  $fail = $false
  if ($lostList.Count) { $fail = $true; "$Code evidence check: $($lostList.Count) file(s) listed in results.json but missing:"; $lostList | ForEach-Object { "  $_" } }
  if ($badNames.Count) {
    $fail = $true; "$Code evidence check: $($badNames.Count) off-standard name(s) (reference/evidence-standard.md; -Check -FixNames renames them):"
    $badNames | ForEach-Object { "  $_ -> $(if ($suggest[$_]) { $suggest[$_] } elseif ($emptyNames -contains $_) { '(empty file: not renamed, see below)' } else { '(no suggestion: rename by hand)' })" }
  }
  if ($emptyFiles.Count) {
    $fail = $true; "$Code evidence check: $($emptyFiles.Count) empty file(s) cited (0 bytes: the capture failed; re-capture or drop them from results.json; -FixNames leaves them):"
    $emptyFiles | ForEach-Object { "  $($cited[$_.Name]): $($_.Directory.Name)/$($_.Name)" }
  }
  if ($dups.Count) { $fail = $true; "$Code evidence check: duplicate check id(s) in results.json (merge or renumber them): $($dups -join ', ')" }
  if ($badTypes.Count) {
    $fail = $true; "$Code evidence check: $($badTypes.Count) file(s) listed but unsupported type (never published; supported: $($script:EvidenceExt -replace '^\^\\\.\(|\)\$$', '' -replace '\|', ' ')):"
    $badTypes | ForEach-Object { "  $_" }
  }
  if ($fail) { exit 1 }
  "$Code evidence check: OK ($($files.Count) files, standard names, supported types, none empty, unique check ids)"; exit 0
}
if ($lostList.Count -and -not $AllowMissing) {
  throw "$Code`: $($lostList.Count) evidence file(s) listed in results.json are missing - nothing was published: $($lostList -join '; '). Save them or fix results.json, then re-run (or pass -AllowMissing to publish without them)."
}
foreach ($g in @($lost | Group-Object { $_.check.id })) {   # -AllowMissing: drop the names, say so
  $c = $g.Group[0].check; $gone = @($g.Group | ForEach-Object name)
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -notin $gone })
  $c | Add-Member -NotePropertyName observed -NotePropertyValue "$($c.observed) [Evidence missing at publish: $($gone -join ', ')]".Trim() -Force
}
if ($lostList.Count) { Write-Warning "published without missing evidence (-AllowMissing): $($lostList -join '; ')" }
$fin = "$D/finalize.json"
$prev = if ((Test-Path $fin) -and -not $Force) { Get-Content $fin -Raw | ConvertFrom-Json } else { $null }
$title = if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }
$tester = if ($run.tester) { $run.tester } else { [Environment]::UserName }
$tr = $run.tracker
Push-Location $RunDir; $script:qaFinPushed = $true   # gws works only inside the current directory
trap { if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }; break }
function Invoke-Gws($a) { $out = & gws @a 2>$null; (($out | Where-Object { $_ -notmatch '^Using keyring' }) -join "`n") | ConvertFrom-Json }
function Share($id) { $o = & gws drive permissions create --params (@{ fileId = $id; supportsAllDrives = $true } | ConvertTo-Json -Compress) --json '{"role":"reader","type":"anyone"}' 2>&1; if ($LASTEXITCODE -or -not $o) { Write-Warning "sharing $id with anyone-with-the-link failed (testers may not open the link): $(("$o" -replace '\s+', ' ').Trim())" } }
function TaskUrl($id) { Get-TrackerUrl $id }
function TrySay([scriptblock]$b, [string]$what) { try { & $b } catch { Write-Warning "tracker ($($KitConf.TrackerType)): $what failed: $_"; $null } }
$P = '{"fields":"id,webViewLink","supportsAllDrives":true}'

# 1. Evidence: Drive (gdocs) or run folder
$map = [ordered]@{ folderId = $null; folderLink = $null; files = [ordered]@{}; local = ($rtype -ne 'gdocs') }
if ($map.local) {
  $map.folderLink = $D
  foreach ($x in $files) { $map.files[$x.Name] = @{ id = $null; link = "$($x.Directory.Name)/$($x.Name)"; path = $x.FullName } }
}
elseif ($prev -and $prev.folderId) {
  $map.folderId = $prev.folderId; $map.folderLink = $prev.folderLink
  foreach ($pf in $prev.files.PSObject.Properties) { $map.files[$pf.Name] = $pf.Value }   # not $p: that IS $P (--params JSON)
} else {
  $meta = @{ name = "$title $Code - test evidence ($Date)"; mimeType = 'application/vnd.google-apps.folder' }
  $dp = if ($run.driveParent) { [string]$run.driveParent } else { [string](Get-KitSetting 'driveParent' '') }   # run.json wins, else kit.local.json
  if ($dp) { $meta.parents = @($dp) }
  $f = Invoke-Gws @('drive', 'files', 'create', '--json', ($meta | ConvertTo-Json -Compress), '--params', $P)
  Share $f.id
  $map.folderId = $f.id; $map.folderLink = $f.webViewLink
}
foreach ($x in $files) {
  if ($map.local -or $map.files[$x.Name]) { continue }
  $rel = "$Code/$($x.Directory.Name)/$($x.Name)"
  $r = Invoke-Gws @('drive', 'files', 'create', '--json', (@{ name = $x.Name; parents = @($map.folderId) } | ConvertTo-Json -Compress), '--upload', $rel, '--params', $P)
  if ($r.id) { $map.files[$x.Name] = @{ id = $r.id; link = $r.webViewLink } }
}

# 2. Styled report
$checks = @($res.checks)
function Cnt($arr, $k) { @($arr | Where-Object { $_.result -eq $k }).Count }
$guideUrl = if ($item.guideUrl) { $item.guideUrl } elseif ($item.guideId) { "https://docs.google.com/document/d/$($item.guideId)/edit" } elseif ($item.guideFile) { $item.guideFile } else { $null }
$missing = @($checks | ForEach-Object { $c = $_; @($c.evidence) | Where-Object { $_ -and -not $map.files[$_] } | ForEach-Object { "$($c.id): $_" } })
if ($missing.Count) { Write-Warning "evidence found but not uploaded: $($missing -join '; ')" }
Build-QaReport -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File "$D/report.html" -Encoding utf8

# 3. Report
$null = Test-KitProse -Kind result-note -Path "$D/results.json"
$null = Test-KitProse -Kind qa-report -Text (Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-String)
$reportFile = $null
if ($map.local) {
  $reportFile = "$D/report.md"
  Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File $reportFile -Encoding utf8
  $docUrl = $reportFile
} elseif ($prev.doc -and $prev.doc -notmatch '/d//') { $docUrl = $prev.doc   # a re-run keeps the posted report
} else {
  $doc = Invoke-Gws @('drive', 'files', 'create', '--json', (@{ name = "$title $Code - Test Results ($Date)"; mimeType = 'application/vnd.google-apps.document'; parents = @($map.folderId) } | ConvertTo-Json -Compress), '--upload', "$Code/report.html", '--upload-content-type', 'text/html', '--params', $P)
  if ($doc.id) { Share $doc.id; $docUrl = "https://docs.google.com/document/d/$($doc.id)/edit" }
  elseif ($prev.doc -and $prev.doc -notmatch '/d//') { Write-Warning "Google Doc create failed - keeping the previous report $($prev.doc)"; $docUrl = $prev.doc }
  else { throw "Google Doc create failed and there is no previous report - fix gws auth and re-run (nothing was posted to the tracker)" }
}

# 4. Tracker per subtask, result rule (SKILL.md step 5)
$out = [ordered]@{ report = $rtype; folderId = $map.folderId; folderLink = $map.folderLink; files = $map.files; doc = $docUrl; subtasks = @() }
$closeStatus = if ($tr.closeStatus) { $tr.closeStatus } else { 'closed' }   # logical name (tracker.statuses)
$isLocal = [string]$(if ($item.localEnv) { $item.localEnv } else { $run.localEnv })   # local env item (ENV-FIX)
$bugList = if ($tr.list) { $tr.list } else { [string](Get-KitSetting 'tracker.list' '') }
$canCreate = [bool]$bugList -or $KitConf.TrackerType -in 'github', 'gitlab', 'none'   # clickup/jira need a list/project
# own vs new: tester's 'defect' wins, else X = new
function Test-NewDefect($c) { if ("$($c.defect)" -in 'new', 'own') { return "$($c.defect)" -eq 'new' }; [string]$c.id -match '^X\d' }
# orch.ps1 bugbrief parses "### <id> — <screen>" + "**Saw:**"
function Format-Checks($list, [string]$heading) {
  if (-not @($list).Count) { return '' }
  "## $heading`n`n" + ((@($list) | ForEach-Object {
        $ev = (@($_.evidence) | Where-Object { $_ } | ForEach-Object { if ($map.files[$_]) { "[$_]($($map.files[$_].link))" } else { $_ } }) -join ', '
        "### $($_.id) — $($_.screen)$(if ($_.flaky) { ' (flaky)' })`n**Steps:** $($_.what_was_done)`n`n**Saw:** $($_.observed)$(if ($_.cause) { " (cause: $($_.cause))" })`n`n**Independent re-test:** $(if ($_.verify) { $_.verify } else { 'not re-tested' })`n`n**Evidence:** $(if ($ev) { $ev } else { 'none' })`n" }) -join "`n") + "`n"
}
# last item on a shared task decides
function SiblingHold($id) {
  $own = 0; $nt = 0; $err = $null; $pend = 0
  foreach ($c in @(@($run.items) | Where-Object { $_.code -ne $Code } | ForEach-Object code)) {
    $f = "$RunDir/$c/finalize.json"; if (-not (Test-Path $f)) { continue }
    $r = @((Get-Content $f -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.id -eq $id -and -not $_.noTracker }) | Select-Object -First 1
    if ($r) { $own += [int]$r.fail; $nt += [int]$r.notTested; $pend += [int]$r.pending; if ($r.bugError) { $err = "$c`: $($r.bugError)" } }
  }
  [pscustomobject]@{ fail = $own; notTested = $nt; bugError = $err; pending = $pend }
}
# original ask = tracker parent, else run.json, else top level
$script:askCache = @{}
function Get-Ask($st) {
  if ($script:askCache.ContainsKey($st.id)) { return $script:askCache[$st.id] }
  $pid_ = try { [string](Get-TrackerTask $st.id).parent } catch { '' }
  if (-not $pid_) { $pid_ = [string]$tr.parent }
  $pname = if ($pid_) { try { [string](Get-TrackerTask $pid_).name } catch { '' } } else { '' }
  $script:askCache[$st.id] = [pscustomobject]@{ id = $pid_; name = $pname }
  $script:askCache[$st.id]
}
# one [Bug] per ask (bugs.json, mutex)
function Add-NewDefects($st, [object[]]$defects) {
  $ask = Get-Ask $st; $key = if ($ask.id) { $ask.id } else { '-' }
  $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($RunDir.ToLower()))).Substring(0, 16)
  $mx = [Threading.Mutex]::new($false, "Global\kit-bugs-$h")
  $own = $true; try { $own = $mx.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $own = $true }   # abandoned = ours now
  if (-not $own) { $mx.Dispose(); throw "bugs.json of $RunDir is locked by another finalize for 2 min: re-run finalize -Code $Code" }
  try {
    $f = "$RunDir/bugs.json"
    $all = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
    $groups = [ordered]@{}; if ($all.groups) { foreach ($p in $all.groups.PSObject.Properties) { $groups[$p.Name] = $p.Value } }
    $s = if ($groups.Contains($key)) { $groups[$key] } else { [pscustomobject]@{ id = $null; url = $null; base = ''; baseCount = 0; entries = @() } }
    if (-not $s.id -and $ask.id) {
      $tested = @(@($run.items) | ForEach-Object { @($_.subtasks) | ForEach-Object id })
      $open = try { @((Get-TrackerTask $ask.id).subtasks | Where-Object { "$($_.name)" -like '`[Bug`] *' -and $_.id -notin $tested -and -not (Test-TrackerStatus $_.status 'closed') }) | Select-Object -First 1 } catch { $null }
      if ($open) {
        $o = Get-TrackerTask $open.id
        $s.id = $open.id; $s.url = $(if ($open.url) { $open.url } else { TaskUrl $open.id }); $s.base = [string]$o.description
        $s.baseCount = if ("$($o.name)" -match '\((\d+)\)\s*$') { [int]$Matches[1] } else { 0 }
      }
    }
    $entries = @(@($s.entries) | Where-Object { $_ -and -not ($_.code -eq $Code -and $_.task -eq $st.id) })
    $entries += [pscustomobject]@{ code = $Code; task = $st.id; taskName = $st.name; md = (Format-Checks $defects "New defects found while testing $($st.name) ($(TaskUrl $st.id)), package $Code") }
    $n = [int]$s.baseCount + [int](($entries | ForEach-Object { ([regex]::Matches([string]$_.md, '(?m)^### ')).Count } | Measure-Object -Sum).Sum)
    $name = "$(Get-KitSetting 'tracker.bugPrefix' '[Bug]') $(if ($ask.name) { $ask.name } else { $title }) — new defects ($n)$(if (($entries | ForEach-Object md) -match '\(flaky\)') { ' [flaky]' })"
    $body = "QA run **$title** on $(if ($item.target) { $item.target } else { $run.target }) ($Date) found these defects outside what the tested tasks changed. Results report: $docUrl`n$(if ($guideUrl) { "Tester guide (check ids refer to it): $guideUrl`n" })`n" + (($entries | ForEach-Object md) -join "`n")
    if ($s.base) { $body = "$($s.base.TrimEnd())`n`n$body" }
    if ($s.id) { $null = Set-TrackerName $s.id $name; $null = Set-TrackerDescription $s.id $body }
    else {
      $t = New-TrackerTask -List $bugList -Name $name -Description $body -Parent $ask.id -Assignee $tr.owner -Priority '2'
      if (-not $t.id) { return $null }
      $s.id = $t.id; $s.url = $(if ($t.url) { $t.url } else { TaskUrl $t.id })
    }
    $s.entries = $entries; $groups[$key] = $s
    [pscustomobject]@{ groups = $groups } | ConvertTo-Json -Depth 8 | Out-File $f -Encoding utf8
    [pscustomobject]@{ id = $s.id; url = $s.url }
  } finally { if ($own) { $mx.ReleaseMutex() }; $mx.Dispose() }
}
# no failedTesting status -> inProgress + comment
function Set-FailedTesting($rec, $st) {
  $ok = TrySay { Set-TrackerStatus $st.id 'failedTesting'; $true } "set $($st.id) failedTesting"
  if ($null -eq $ok) {
    $ok = TrySay { Set-TrackerStatus $st.id 'inProgress'; $true } "set $($st.id) inProgress (fallback: no failedTesting status)"
    if ($null -ne $ok) { $rec.statusFallback = 'inProgress'; $null = TrySay { Add-TrackerComment $st.id "Failed testing (this board has no 'failedTesting' status: set tracker.statuses.failedTesting in kit.local.json): moved back to in progress." } "comment on $($st.id)" }
  }
  if ($null -ne $ok) { $rec.failedTesting = $true } else { $rec.keptOpen = 'the tracker refused the failedTesting status (see warning)' }
}
function Resolve-Outcome($rec, $st, [int]$pend) {
  $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir/$($_.code)/finalize.json") } | ForEach-Object code)
  if ($others.Count) { $rec.waitingFor = $others; return }
  if ($pend) { $rec.keptOpen = "$pend check(s) pending in another lane"; return }
  if (-not $rec.total) { $rec.keptOpen = 'no check carries this task id (subtask_id)'; return }   # 0 of 0 is not a pass
  $sib = SiblingHold $st.id
  if ($sib.pending) { $rec.keptOpen = "$($sib.pending) check(s) of a sibling item pending in another lane"; return }
  # local env: untested = ENV-FIX
  if ($isLocal -and -not ($rec.fail + $sib.fail) -and ($rec.notTested + $sib.notTested)) { $rec.keptOpen = "local env ${isLocal}: $($rec.notTested + $sib.notTested) check(s) not tested: ENV-FIX + qa.ps1 retest"; return }
  if ($rec.fail + $sib.fail + $rec.notTested + $sib.notTested) { Set-FailedTesting $rec $st; return }
  if ($rec.bugError -or $sib.bugError) { $rec.keptOpen = "new defects have no [Bug] task ($(if ($rec.bugError) { $rec.bugError } else { $sib.bugError }))"; return }   # never close while a defect is untracked
  if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } else { $rec.keptOpen = 'the tracker refused the close (see warning)' }
}
# one tracker step per run at a time (siblings deadlocked)
$fh = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($RunDir.ToLower()))).Substring(0, 16)
$fmx = [Threading.Mutex]::new($false, "Global\kit-finalize-$fh")
$fOwn = $true; try { $fOwn = $fmx.WaitOne(600000) } catch [Threading.AbandonedMutexException] { $fOwn = $true }
if (-not $fOwn) { $fmx.Dispose(); throw "another finalize of $RunDir held the tracker step for 10 min: re-run finalize -Code $Code" }
function Save-Fin { $out | ConvertTo-Json -Depth 6 | Out-File $fin -Encoding utf8 }
try {
foreach ($st in @($item.subtasks)) {
  $mine = @($checks | Where-Object { $_.subtask_id -eq $st.id })
  if (-not $mine.Count -and @($item.subtasks).Count -eq 1) { $mine = $checks }
  $dupOf = if ($item.dups) { [string]$item.dups.($st.id) } else { '' }   # run.json dups share the primary's checks
  if (-not $mine.Count -and $dupOf) { $mine = @($checks | Where-Object { $_.subtask_id -eq $dupOf }) }
  $allFails = @($mine | Where-Object { $_.result -eq 'FAIL' })
  $newDefects = @($allFails | Where-Object { Test-NewDefect $_ }); $ownFails = @($allFails | Where-Object { -not (Test-NewDefect $_) })
  $ntChecks = @($mine | Where-Object { $_.result -eq 'NOT_TESTED' }); $nt = $ntChecks.Count; $pend = Cnt $mine 'PENDING'
  $pass = (Cnt $mine 'PASS') + (Cnt $mine 'PASS_WITH_NOTE'); $oos = Cnt $mine 'OUT_OF_SCOPE'   # OUT_OF_SCOPE: qa.outOfScope
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $ownFails.Count; newDefects = $newDefects.Count; notTested = $nt; outOfScope = $oos; pending = $pend; bug = $null; closed = $false; failedTesting = $false }
  $prevRec = if ($prev) { @($prev.subtasks | Where-Object { $_.id -eq $st.id }) | Select-Object -First 1 }
  if ($NoTracker) {
    # a dry run never overwrites a posted record (else the real run re-posts)
    if ($prevRec -and -not $prevRec.noTracker) { $out.subtasks += $prevRec; continue }
    $rec.noTracker = $true
  } else {
    if ($prevRec.noTracker -or $prevRec.commentFailed) { $prevRec = $null }   # a failed results comment is posted again
    if ($prevRec.closed -or $prevRec.failedTesting) { $out.subtasks += $prevRec; continue }   # keep the first run's record
    # re-run on a sibling: re-resolve only
    if ($prevRec) {
      $rec.bug = $prevRec.bug
      $rec.bugError = if ($prevRec.bugError) { $prevRec.bugError } elseif ($newDefects.Count -and -not $rec.bug) { 'new defects have no [Bug] task' }
      $out.subtasks += $rec; Resolve-Outcome $rec $st $pend; Save-Fin; continue
    }
    $icon = if ($allFails.Count) { '❌' } elseif ($nt -or $pend) { '⚠️' } else { '✅' }
    $msg = "$icon " + $(if ($item.retest) { "Retest of the fix ($Date): $pass of $($mine.Count - $oos) checks pass" } else { "Test results ($(if ($item.target) { $item.target } else { $run.target }), $Date): $pass of $($mine.Count - $oos) checks pass" })
    if ($ownFails.Count) { $msg += ", $($ownFails.Count) of this task's checks failed ($(($ownFails | ForEach-Object id) -join ', '))" }
    if ($nt) { $msg += ", $nt not tested ($(($ntChecks | ForEach-Object id) -join ', '))" }
    if ($oos) { $msg += ", $oos out of scope" }
    if ($pend) { $msg += ". $pend check(s) are tested next in another lane" }
    if ($newDefects.Count -and $canCreate) {
      $b = TrySay { Add-NewDefects $st $newDefects } 'record the new defects in the [Bug] task'
      if ($b.id) { $rec.bug = $b.id; $msg += ". New defects ($(($newDefects | ForEach-Object id) -join ', ')) moved to $($b.url)" }
      else { $rec.bugError = '[Bug] task could not be created'; Write-Warning "$($st.id): could not create the [Bug] task for $(($newDefects | ForEach-Object id) -join ', ')" }
    }
    elseif ($newDefects.Count) { $rec.bugError = 'no bug list configured'; Write-Warning "$($st.id): no tracker list for bug tasks (tracker.list) - task kept open" }
    $msg += ". Full report with screenshots and API evidence: $docUrl"
    # own failures + untested: failedTesting
    $detail = (Format-Checks $ownFails 'Failed checks') + (Format-Checks $ntChecks 'Untested checks')
    $text = if ($detail) { "$msg`n`n$detail" } else { $msg }
    $posted = if ($reportFile) { TrySay { $null = Add-TrackerAttachment $st.id $reportFile $text; $true } "post the report on $($st.id)" }
    else { TrySay { $null = Add-TrackerComment $st.id $text; $true } "comment on $($st.id)" }
    $out.subtasks += $rec
    # no results comment: leave the task, post next run
    if (-not $posted) { $rec.commentFailed = $true; $rec.keptOpen = 'the results comment was not posted (see warning): re-run finalize'; Save-Fin; continue }
    Save-Fin; Resolve-Outcome $rec $st $pend; Save-Fin; continue
  }
  $out.subtasks += $rec
}
Save-Fin
} finally { $fmx.ReleaseMutex(); $fmx.Dispose() }
"$Code report ($rtype): $docUrl"
if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, failed $($_.fail), new defects $([int]$_.newDefects), not tested $($_.notTested), out of scope $([int]$_.outOfScope), pending $($_.pending), bug $($_.bug), $(if ($_.closed) { 'closed' } elseif ($_.failedTesting) { "failed testing$(if ($_.statusFallback) { " (set $($_.statusFallback))" })" } elseif ($_.waitingFor) { "open (waiting for $(@($_.waitingFor) -join ', '))" } else { "open ($($_.keptOpen))" })" }
}

# ---- annotate: -Rect / -Arrow / -Text on a PNG/JPEG (Windows only); image px (web: CSS px x DPR)
function Invoke-Annotate {
param(
  [Parameter(Mandatory)][string]$In, [string]$Out,
  [string[]]$Rect = @(), [string[]]$Arrow = @(), [string[]]$Text = @(),
  [ValidateSet('red', 'orange', 'green', 'blue')][string]$Color = 'red', [double]$Scale = 0,
  [switch]$Copy
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'annotate needs Windows (System.Drawing): elsewhere mark() before shot(), or name the element in the check note' }
# one item each, its commas stay
$Rect = @(Split-KitList $Rect ';'); $Arrow = @(Split-KitList $Arrow ';'); $Text = @(Split-KitList $Text ';')
Add-Type -AssemblyName System.Drawing
$src = (Resolve-Path $In).Path
if (-not $Out -and $Copy) { $Out = Join-Path (Split-Path $src) ("{0}-marked{1}" -f [IO.Path]::GetFileNameWithoutExtension($src), [IO.Path]::GetExtension($src)) }
if (-not $Out) { $Out = $src }
$bytes = [IO.File]::ReadAllBytes($src)                     # read fully to overwrite
$ms = New-Object IO.MemoryStream(, $bytes)
$img0 = [Drawing.Image]::FromStream($ms)
$bmp = New-Object Drawing.Bitmap $img0.Width, $img0.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
$g.DrawImage($img0, 0, 0, $img0.Width, $img0.Height)
$k = if ($Scale) { $Scale } else { [math]::Max(1, $img0.Width / 1300) }  # sizes grow with the image
$col = @{ red = [Drawing.Color]::FromArgb(230, 220, 38, 38); orange = [Drawing.Color]::FromArgb(230, 245, 140, 0); green = [Drawing.Color]::FromArgb(230, 22, 163, 74); blue = [Drawing.Color]::FromArgb(230, 37, 99, 235) }[$Color]
$pen = New-Object Drawing.Pen $col, (4 * $k)
$font = New-Object Drawing.Font ([Drawing.FontFamily]::GenericSansSerif), ([float](15 * $k)), ([Drawing.FontStyle]::Bold)
$bg = New-Object Drawing.SolidBrush $col
$fg = [Drawing.Brushes]::White
function Label([string]$t, [float]$x, [float]$y) {
  if (-not $t) { return }
  $sz = $g.MeasureString($t, $font)
  $x = [math]::Max(0, [math]::Min($x, $bmp.Width - $sz.Width - 2)); $y = [math]::Max(0, [math]::Min($y, $bmp.Height - $sz.Height - 2))
  $g.FillRectangle($bg, $x, $y, $sz.Width + 8 * $k, $sz.Height + 2 * $k)
  $g.DrawString($t, $font, $fg, $x + 4 * $k, $y + $k)
}
function Parts($s) { $p = $s -split ',', 5; $p }
foreach ($r in $Rect) {
  $p = $r -split ',', 5; $x = [float]$p[0]; $y = [float]$p[1]; $w = [float]$p[2]; $h = [float]$p[3]
  $g.DrawRectangle($pen, $x, $y, $w, $h)
  if ($p.Count -ge 5) { $ly = if ($y - 30 * $k -ge 0) { $y - 30 * $k } else { $y + $h + 4 * $k }; Label $p[4] $x $ly }
}
foreach ($a in $Arrow) {
  $p = $a -split ',', 5; $x1 = [float]$p[0]; $y1 = [float]$p[1]; $x2 = [float]$p[2]; $y2 = [float]$p[3]
  $ap = New-Object Drawing.Pen $col, (4 * $k)
  $ap.CustomEndCap = New-Object Drawing.Drawing2D.AdjustableArrowCap 4, 4, $true
  $g.DrawLine($ap, $x1, $y1, $x2, $y2)
  if ($p.Count -ge 5) { Label $p[4] ($x1 - 10 * $k) ($y1 - 30 * $k) }
}
foreach ($t in $Text) { $p = $t -split ',', 3; Label $p[2] ([float]$p[0]) ([float]$p[1]) }
$g.Dispose(); $img0.Dispose(); $ms.Dispose()
$fmt = if ($Out -match '\.jpe?g$') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png }
$bmp.Save($Out, $fmt); $bmp.Dispose()
"annotated $Out ($(@($Rect).Count) rect, $(@($Arrow).Count) arrow, $(@($Text).Count) text)"
}

# ---- retest: add a RETEST item for a fixed task whose fix went live (same -Code replaces it)
function Invoke-Retest {
param(
  [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][string]$Code,
  [string]$Title, [string]$Mrs = '', [string[]]$Only, [ValidateSet('web', 'api', 'app')][string]$Lane = 'web'
)
$ErrorActionPreference = 'Stop'
# Split-KitList: -Only arrives as one string
$Only = @(Split-KitList $Only)
$t = Get-TrackerTask $Task
if (-not $t.name) { throw "cannot read task $Task (tracker $($KitConf.TrackerType): CLI auth / config?)" }
$c = @(try { Get-TrackerComments $Task } catch { @() })
# rerun ids: ### headings
if (-not $Only) {
  foreach ($txt in @([string]$t.description) + @($c | Sort-Object date -Descending | ForEach-Object { [string]$_.text })) {
    $ids = @([regex]::Matches($txt, '(?m)^###\s+(\S+)\s+[—-]\s+') | ForEach-Object { $_.Groups[1].Value } | select -Unique)
    if ($ids.Count) { $Only = $ids; break }
  }
}
if (-not $Title) { $Title = "RETEST $($t.name -replace '^\[Bug\]\s*', '')" }
$md = "# $($t.name)`n`nTask: $($t.url)  Status: $($t.status)`n`n" +
  "RETEST of the fix: run the failed checks ($($Only -join ', ')) again on the deployed build, same steps and data where possible. " +
  "Check the fix is deployed first (qa.ps1 deployed -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.description)`n`n## Comments (oldest first)`n"
foreach ($x in $c) { $md += "`n---`n**$($x.user)** $($x.date)`n`n$($x.text)`n" }
New-Item -ItemType Directory -Force "$RunDir/tasks" | Out-Null
$gf = "$RunDir/tasks\$Task.md"; Set-Content $gf $md -Encoding utf8
$old = @('finalize.json', 'held.json', 'results.json' | ForEach-Object { Join-Path "$RunDir/$Code" $_ } | ? { Test-Path $_ })
if ($old.Count) {   # reused code: archive the earlier round
  $arc = Join-Path "$RunDir/$Code" "archive-$(Get-Date -Format yyyyMMdd-HHmmss)"; New-Item -ItemType Directory -Force $arc | Out-Null
  foreach ($f in $old) { Move-Item -LiteralPath $f -Destination $arc }
  "archived the earlier round of $Code ($(($old | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) to $arc"
}
$r = Get-Content "$RunDir/run.json" -Raw | ConvertFrom-Json
$items = @($r.items | ? { $_.code -ne $Code })
$items += [pscustomobject]@{ code = $Code; lane = $Lane; title = $Title; guideFile = $gf; retest = $true; only = @($Only); subtasks = @([pscustomobject]@{ id = $Task; name = $t.name; mrs = $Mrs }) }
$r.items = $items
$r | ConvertTo-Json -Depth 8 | Set-Content "$RunDir/run.json" -Encoding utf8
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir/run.json - launch: Workflow testy { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
}

# ---- ui: drive the app on your leased phone (uiautomator + adb; $env:ANDROID_SERIAL)
function Invoke-Ui {
param([Parameter(Position = 0)][string]$Action = 'dump', [Parameter(Position = 1)][string]$Arg = '', [Parameter(Position = 2)][string]$Arg2 = '',
      [Parameter(Position = 3)][string]$Arg3 = '', [Parameter(Position = 4)][string]$Arg4 = '')
$adb = Join-Path (Get-AndroidSdk) (Join-Path 'platform-tools' (Get-ExeName 'adb'))   # ANDROID_HOME / ANDROID_SDK_ROOT / OS default
$dt = Get-KitSetting 'devices.type' 'android'
if ($dt -eq 'none') { 'no devices (devices.type none): app checks are NOT_TESTED'; exit 1 }
$ios = $dt -eq 'ios'   # Simulator: $env:KIT_DEVICE = udid
$tag = if ($ios) { if ($env:KIT_DEVICE) { $env:KIT_DEVICE } else { 'booted' } } elseif ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { 'default' }
if ($ios -and $Action -notin 'shot', 'openurl', 'log') { "ios: no ui $Action (simctl has no UI driver): use shot | openurl | log, prove the rest via the API"; exit 2 }
$xmlLocal = Join-Path (Get-KitPath android-tmp -Create) "ui_$tag.xml"
function Get-Nodes {
  # a failed dump must not return the old screen
  & $adb shell rm -f /sdcard/ui.xml | Out-Null; Remove-Item $xmlLocal -Force -ea 0
  & $adb shell uiautomator dump /sdcard/ui.xml | Out-Null
  & $adb pull /sdcard/ui.xml $xmlLocal 2>$null | Out-Null
  if (-not (Test-Path $xmlLocal)) { throw 'uiautomator dump failed (no fresh ui.xml): screen busy or device offline - retry' }
  [xml]$x = Get-Content $xmlLocal -Raw
  $x.SelectNodes('//node') | ForEach-Object {
    $t = if ($_.text) { $_.text } elseif ($_.'content-desc') { $_.'content-desc' } else { '' }
    if ($_.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $l, $u, $r, $b = 1..4 | ForEach-Object { [int]$Matches[$_] }
      [pscustomobject]@{ text = $t; rid = $_.'resource-id'; cls = $_.class; x = [int](($l + $r) / 2); y = [int](($u + $b) / 2); l = $l; t = $u; w = $r - $l; h = $b - $u }
    }
  }
}
# text (exact, then contains) or #<resource-id suffix>
function Find($all, $w) { if ($w -like '#*') { $all | ? { $_.rid -like "*$($w.TrimStart('#'))" } | select -First 1 } else { ($all | ? { $_.text -eq $w } | select -First 1) ?? ($all | ? { $_.text -like "*$w*" } | select -First 1) } }
function Tap($n, $w) { if ($n) { & $adb shell input tap $n.x $n.y; "tapped $(if ($w -like '#*') { "#$($n.rid)" } else { "'$($n.text)'" }) at $($n.x),$($n.y)" } else { "NOT FOUND: $w" } }
function Shot($name, $dir) {
  if (-not $dir) { $dir = Join-Path (Get-KitPath shots) $tag }; New-Item -ItemType Directory -Force $dir | Out-Null; $f = Join-Path $dir "$name.png"; Remove-Item -LiteralPath $f -Force -ea 0
  if ($ios) { xcrun simctl io $tag screenshot $f | Out-Null } else { & $adb shell screencap -p /sdcard/qa_shot.png | Out-Null; & $adb pull /sdcard/qa_shot.png $f 2>&1 | Out-Null }
  if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) { throw "screenshot failed (device $tag offline?): nothing saved to $f" }; $f
}
switch ($Action) {
  'dump' { Get-Nodes | ? { $_.text -or $_.rid -or $_.cls -match 'EditText' } | ForEach-Object { '{0} @({1},{2}){3}{4}' -f $_.text, $_.x, $_.y, $(if ($_.cls -match 'EditText') { ' [edit]' }), $(if ($_.rid) { " #$($_.rid)" }) } }
  'tap' { Tap (Find (Get-Nodes) $Arg) $Arg }
  'tapid' { Tap (Find (Get-Nodes) "#$Arg") "#$Arg" }
  'tapxy' { & $adb shell input tap $Arg $Arg2; "tapped $Arg,$Arg2" }
  'type' { & $adb shell input text ($Arg -replace ' ', '%s' -replace '([#&;()<>|$''"])', '\$1'); 'typed' }
  'key' { & $adb shell input keyevent $Arg; "key $Arg" }
  'swipe' { & $adb shell input swipe $Arg $Arg2 $Arg3 $Arg4 400; 'swiped' }
  'openurl' { if ($ios) { xcrun simctl openurl $tag $Arg } else { & $adb shell am start -a android.intent.action.VIEW -d $Arg | Out-Null }; "opened $Arg" }
  'shot' { "saved $(Shot $Arg $Arg2)" }
  'shotmark' {
    # Arg name, Arg2 text or #id ('|' between), Arg3 label, Arg4 dir
    $all = Get-Nodes
    $rects = foreach ($want in ($Arg2 -split '\s*\|\s*')) {
      $n = Find $all $want
      if ($n) { "$($n.l - 6),$($n.t - 6),$($n.w + 12),$($n.h + 12),$(if ($Arg3) { $Arg3 } else { $n.text })" } else { Write-Warning "NOT FOUND: $want (screenshot taken without a mark for it)" }
    }
    $f = Shot $Arg $Arg4
    if ($rects -and -not $KitIsWindows) { Write-Warning 'marks need qa.ps1 annotate (Windows only): screenshot saved unmarked - name the element in the check note'; $rects = $null }
    if ($rects) { & $KitCmd.qa annotate -In $f -Rect @($rects) | Out-Null }
    "saved $f$(if ($rects) { " with $(@($rects).Count) mark(s)" })"
  }
  'wait' {
    $end = (Get-Date).AddSeconds($(if ($Arg2) { [int]$Arg2 } else { 30 }))
    # not `if (try ...)`: in ( ) `try` is a command
    while ((Get-Date) -lt $end) { $hit = try { Get-Nodes | ? { $_.text -like "*$Arg*" } } catch { $null }; if ($hit) { "found '$Arg'"; return }; Start-Sleep 2 }
    "TIMEOUT waiting for '$Arg'"
  }
  'photo' {
    # shutter: -Arg id suffix, else common ids; Arg2 = confirm text
    Start-Sleep 3
    $all = Get-Nodes
    $n = @(@($(if ($Arg) { $Arg } else { 'take-image-button', 'shutter', 'capture', 'take_photo', 'camera_button', 'btnCapture' }) | ForEach-Object { Find $all "#$_" }) + @($all | ? { $_.text -match (Get-KitSetting 'qa.shutterText' '^(Take photo|Capture|Shutter|Take picture)$') }))[0]
    if (-not $n) { "NOT FOUND: no shutter (pass its resource-id: qa.ps1 ui photo <id>; qa.ps1 ui dump shows ids)"; return }
    & $adb shell input tap $n.x $n.y; Start-Sleep 4
    $ok = Get-Nodes | ? { $_.text -match $(if ($Arg2) { "^$([regex]::Escape($Arg2))$" } else { (Get-KitSetting 'qa.confirmText' '^(OK|Done|Use photo|Save|Confirm|✓|Use)$') }) } | select -First 1
    if ($ok) { & $adb shell input tap $ok.x $ok.y; Start-Sleep 2; "photo taken and accepted ('$($ok.text)')" } else { "photo taken (no confirm step seen)" }
  }
  'log' { if ($ios) { xcrun simctl spawn $tag log show --last 5m --style compact --predicate $(if ($Arg) { "process == '$Arg'" } else { 'messageType == error' }) } else { & $adb logcat -d -t 300 -s $(if ($Arg) { $Arg } else { '*:E' }) } }
  default { "unknown action $Action (qa.ps1 ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo)"; exit 2 }
}
}
if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'seat' { Invoke-KitVerb Invoke-Seat $__rest }
    'deployed' { Invoke-KitVerb Invoke-Deployed $__rest }
    'api' { Invoke-KitVerb Invoke-Api $__rest }
    'finalize' { Invoke-KitVerb Invoke-Finalize $__rest }
    'annotate' { Invoke-KitVerb Invoke-Annotate $__rest }
    'retest' { Invoke-KitVerb Invoke-Retest $__rest }
    'ui' { Invoke-KitVerb Invoke-Ui $__rest }
    { $_ -in '-h', '--help', 'help', '-?' } { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }   # the header only
  }
}
