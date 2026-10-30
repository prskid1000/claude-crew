#Requires -Version 7
# report-gdocs (goody): the styled HTML QA report (colour chips, zebra tables, gallery) for Google Docs import. pokey.ps1 finalize
# writes report.html with Build-QaReport and publishes it instead of report.md when this file is present (dot-sourced).
# Sections: L5 helpers · L32 build
# ---- helpers: HTML escape, palette, chips, images
function Esc($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }
# escaped text with its `backtick` spans monospace on grey (a span: Docs' import drops <code> styles)
function EscCode($t) { [regex]::Replace((Esc $t), '`([^`]+)`', { "<span style=`"font-family:'Roboto Mono';font-size:9pt;background-color:#f1f3f4`">$($args[0].Groups[1].Value)</span>" }) }

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

# unknown result renders plain
function Pal($r) { $p = $script:Palette[[string]$r]; if ($p) { $p } else { @{ fg = '#111827'; bg = '#ffffff'; label = $(if ($r) { [string]$r } else { '(no result)' }) } } }
function Chip($k, $n) { $p = $script:Palette[$k]; "<td style='background:$($p.bg);color:$($p.fg);padding:8px 14px;text-align:center;$script:Font;border:1px solid #ffffff'><span style='font-size:18pt;font-weight:bold'>$n</span><br><span style='font-size:8pt;font-weight:bold'>$($p.label)</span></td>" }
function Img($map, $f, $w) {
  $src = if ($map.files[$f].src) { Esc $map.files[$f].src } else { $map.files[$f].link }
  $id = if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+[a-z]?)_') { "$($Matches[1]): " }   # caption = check id + what it shows
  "<p style='margin:4px 0 12px 0'><img src='$src' width='$w'><br><span style='font-size:9pt;color:#6b7280'>$(Esc "$id$(Caption $f)") · <a href='$($map.files[$f].link)'>$(Esc $f)</a></span></p>"
}
# phone shots render narrow
function ImgWidth($f) { if ($f -match '\.png$' -or $f -match '(?i)(^|[_-])(app|phone|mobile|emulator)([_.-])|-L\d+_') { 260 } else { 600 } }

# ---- build: Build-QaReport, the report page
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
  # verify = '<status> | <re-test / note audit text>' (core pokey.ps1 VerifyStatus / VerifyFile; an older core: the whole text)
  $vNew = [bool](Get-Command VerifyFile -ErrorAction SilentlyContinue)
  function VStatus($c) { if ($vNew) { VerifyStatus $c.verify } else { [string]$c.verify } }
  function VFull($c) { $vf = if ($vNew) { VerifyFile $Code $c }; if ($vf -and $Map.files[$vf]) { "$(if ($s = VStatus $c) { "$(Esc $s) · " })full text: <a href='$($Map.files[$vf].link)'>$(Esc $vf)</a>" } else { Esc $c.verify } }
  # Count chips
  A "<table style='border-collapse:collapse;margin:6px 0 12px 0'><tr>"
  foreach ($k in 'PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'PENDING', 'OUT_OF_SCOPE') { if ($n[$k] -or $k -in 'PASS', 'FAIL') { A (Chip $k $n[$k]) } }
  A "</tr></table>"
  # At a glance
  $glance = "$passAll of $($checks.Count - $n.OUT_OF_SCOPE) checks pass"
  if ($n.PASS_WITH_NOTE) { $glance += " ($($n.PASS_WITH_NOTE) with a note)" }
  if ($fails.Count) { $glance += ". $($fails.Count) failed: " + (($fails | ForEach-Object { "$($_.id) ($($_.screen))" }) -join ', ') + $(if (@($fails | Where-Object { (VStatus $_) -eq 'confirmed' }).Count) { ' — confirmed by an independent re-test' } else { '' }) }
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
  A (Fact 'Evidence' "<a href='$($Map.folderLink)'>$($Map.label)</a> · $(@($Map.files.Keys).Count) files")
  A "</table>"

  # Results table
  A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Results</h2>"
  A "<table style='border-collapse:collapse;width:100%'><tr>"
  foreach ($c in @(@('Check', '14%'), @('Result', '12%'), @('Observed', '34%'), @('Evidence', '40%'))) { A "<th style='$script:Cell;background:#1f3a68;color:#ffffff;text-align:left;width:$($c[1])'><b>$($c[0])</b></th>" }   # th: Docs repeats the header row on each page
  A "</tr>"
  $i = 0
  foreach ($c in $checks) {   # evidence inline in its row: images, then one line per data file
    $p = (Pal $c.result); $zebra = if ($i++ % 2) { '#f8fafc' } else { '#ffffff' }
    $v = if ($vs = VStatus $c) { "<br><span style='font-size:8pt;color:#374151'>re-test: $(Esc $vs)</span>" } else { '' }
    $ev = (@($c.evidence | Where-Object { $_ -and $Map.files[$_] }) | ForEach-Object { if ($_ -match '\.(png|jpe?g)$') { Img $Map $_ ([math]::Min(260, (ImgWidth $_))) } else { "file: <a href='$($Map.files[$_].link)'>$(Esc $_)</a><br>" } }) -join ''
    A "<tr style='background:$zebra'><td style='$script:Cell'><b>$(Esc $c.id)</b> $(Esc $c.screen)</td><td style='$script:Cell;background:$($p.bg);color:$($p.fg)'><b>$($p.label)</b>$v</td><td style='$script:Cell'>$(EscCode $c.observed)</td><td style='$script:Cell'>$ev</td></tr>"
  }
  A "</table>"

  # Failure details
  if ($fails.Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #991b1b;padding-bottom:3px;margin-top:16px;color:#991b1b'>Failures in detail</h2>"
    foreach ($c in $fails) {
      A "<h3 style='font-size:11.5pt;margin:12px 0 4px 0'>$(Esc $c.id) — $(Esc $c.screen)</h3><table style='border-collapse:collapse;width:100%'>"
      A (Fact 'Steps' (EscCode $c.what_was_done)); A (Fact 'What we saw' (EscCode $c.observed))
      if ($c.verify) { A (Fact 'Independent re-test' (VFull $c)) }
      A "</table>"
    }
  }

  # Notes, not tested, findings, setup
  $notes = @($checks | Where-Object { $_.result -in 'PASS_WITH_NOTE', 'NOT_TESTED', 'OUT_OF_SCOPE' })
  if ($notes.Count -or @($Res.findings).Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Notes</h2><ul>"
    foreach ($c in $notes) { A "<li><b>$(Esc $c.id)</b> ($((Pal $c.result).label)): $(Esc $c.observed)$(if ($c.verify -and [string]$c.verify -ne (VStatus $c)) { "<br>re-test / note audit: $(VFull $c)" })</li>" }
    foreach ($f in @($Res.findings)) { A "<li>$(Esc $f)</li>" }
    A "</ul>"
  }
  $setup = @($Res.setup_changes) + @($Res.data_created) | Where-Object { $_ }
  if ($setup.Count) { A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Setup changes and test data</h2><ul>$((($setup | ForEach-Object { "<li>$(Esc $_)</li>" }) -join ''))</ul>" }

  # Evidence index
  $all = @($Map.files.Keys | Sort-Object)
  if ($all.Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Evidence index</h2><table style='border-collapse:collapse;width:100%'><tr>"
    foreach ($c in 'File', 'Check', 'Type', 'Shows') { A "<th style='$script:Cell;background:#1f3a68;color:#ffffff;text-align:left'><b>$c</b></th>" }
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

