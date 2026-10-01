# Builds the styled QA results report (HTML tuned for Google Docs import: inline styles only, tables for layout).
# Dot-sourced by finalize.ps1:  . "$S\lib\report.ps1";  $html = Build-QaReport -Title ... -Code ... -Item ... -Res ... -Map ... -Run ...

function Esc($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }

$script:Palette = @{
  PASS           = @{ fg = '#166534'; bg = '#dcfce7'; label = 'PASS' }
  PASS_WITH_NOTE = @{ fg = '#92400e'; bg = '#fef3c7'; label = 'PASS (note)' }
  FAIL           = @{ fg = '#991b1b'; bg = '#fee2e2'; label = 'FAIL' }
  NOT_TESTED     = @{ fg = '#374151'; bg = '#f3f4f6'; label = 'NOT TESTED' }
  PENDING        = @{ fg = '#1e40af'; bg = '#dbeafe'; label = 'PENDING' }
}
$script:Font = "font-family:Arial,Helvetica,sans-serif"
$script:Cell = "border:1px solid #d1d5db;padding:6px 8px;vertical-align:top;font-size:10pt"
$script:EvidenceName = '^[A-Za-z0-9]+-[A-Za-z]*\d+(_verify(_\d{2})?|_\d{2})_[a-z0-9]+([-._][a-z0-9]+)*\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?)$'

# "F2-T4_02_after-edit.jpeg" -> "After edit"; legacy names fall back to the file name
function Caption($file) {
  if ($file -match '^[A-Za-z0-9]+-[A-Za-z]*\d+(_verify)?(_\d{2})?_(.+)\.\w+$') {
    $c = ($Matches[3] -replace '[-_]', ' ').Trim(); $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }
    return ($c.Substring(0, 1).ToUpper() + $c.Substring(1)) + $v
  }
  return $file
}
function Chip($k, $n) { $p = $script:Palette[$k]; "<td style='background:$($p.bg);color:$($p.fg);padding:8px 14px;text-align:center;$script:Font;border:1px solid #ffffff'><span style='font-size:18pt;font-weight:bold'>$n</span><br><span style='font-size:8pt;font-weight:bold'>$($p.label)</span></td>" }
function Img($map, $f, $w) { "<p style='margin:4px 0 12px 0'><img src='https://drive.google.com/uc?export=view&amp;id=$($map.files[$f].id)' width='$w'><br><span style='font-size:9pt;color:#6b7280'>$(Esc (Caption $f)) · <a href='$($map.files[$f].link)'>$(Esc $f)</a></span></p>" }
# phone screenshots (PNG from ui.ps1, or names with an app/phone word or an L<n> lane check) are narrow
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
  foreach ($k in 'PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'PENDING') { if ($n[$k] -or $k -in 'PASS', 'FAIL') { A (Chip $k $n[$k]) } }
  A "</tr></table>"
  # At a glance
  $glance = "$passAll of $($checks.Count) checks pass"
  if ($n.PASS_WITH_NOTE) { $glance += " ($($n.PASS_WITH_NOTE) with a note)" }
  if ($fails.Count) { $glance += ". $($fails.Count) failed: " + (($fails | ForEach-Object { "$($_.id) ($($_.screen))" }) -join ', ') + $(if (@($fails | Where-Object verify -eq 'confirmed').Count) { ' — confirmed by an independent re-test' } else { '' }) }
  if ($n.NOT_TESTED) { $glance += ". $($n.NOT_TESTED) not tested (reasons below)" }
  if ($n.PENDING) { $glance += ". $($n.PENDING) app/other-lane checks are tested separately" }
  A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:14px'>At a glance</h2><p>$(Esc $glance).</p>"
  if ($DocNote) { A "<p style='background:#f3f4f6;padding:6px 8px'>$DocNote</p>" }

  # Facts table
  A "<table style='border-collapse:collapse;width:100%;margin:8px 0'>"
  function Fact($k, $v) { "<tr><td style='$script:Cell;background:#f8fafc;width:22%'><b>$k</b></td><td style='$script:Cell'>$v</td></tr>" }
  A (Fact 'Scope' $(if ($GuideUrl) { "<a href='$GuideUrl'>$(Esc $Item.title)</a> (tester guide)" } else { Esc $Item.title }))
  if (@($Item.subtasks).Count) { A (Fact 'Tasks' ((@($Item.subtasks) | ForEach-Object { "<a href='https://app.clickup.com/t/$($_.id)'>$(Esc $_.name)</a>$(if ($_.mrs) { " <span style='color:#6b7280'>· MRs $(Esc $_.mrs)</span>" })" }) -join '<br>')) }
  if (@($Run.envLines).Count) { A (Fact 'Environment' ((@($Run.envLines) | ForEach-Object { Esc $_ }) -join '<br>')) }
  A (Fact 'Tested by' "$(Esc $Tester) with Claude Code · $(Esc $Date)")
  A (Fact 'Evidence' "<a href='$($Map.folderLink)'>Drive folder</a> · $(@($Map.files.Keys).Count) files")
  A "</table>"

  # Results table
  A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Results</h2>"
  A "<table style='border-collapse:collapse;width:100%'><tr>"
  foreach ($c in @(@('Check', '7%'), @('Screen / area', '16%'), @('Result', '12%'), @('What was done', '30%'), @('What we saw', '35%'))) { A "<td style='$script:Cell;background:#1f3a68;color:#ffffff;width:$($c[1])'><b>$($c[0])</b></td>" }
  A "</tr>"
  $i = 0
  foreach ($c in $checks) {
    $p = $script:Palette[$c.result]; $zebra = if ($i++ % 2) { '#f8fafc' } else { '#ffffff' }
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
  $notes = @($checks | Where-Object { $_.result -in 'PASS_WITH_NOTE', 'NOT_TESTED' })
  if ($notes.Count -or @($Res.findings).Count) {
    A "<h2 style='font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px'>Notes</h2><ul>"
    foreach ($c in $notes) { A "<li><b>$(Esc $c.id)</b> ($($script:Palette[$c.result].label)): $(Esc $c.observed)</li>" }
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
      A "<h3 style='font-size:11pt;margin:12px 0 2px 0'>$(Esc $c.id) — $(Esc $c.screen) <span style='color:$($script:Palette[$c.result].fg);font-size:9pt'>$($script:Palette[$c.result].label)</span></h3>"
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
      $type = switch -Regex ($f) { '\.(png|jpe?g)$' { 'Screenshot' } '\.json$' { 'API / data' } '\.(log|txt)$' { 'Log' } '\.csv$' { 'Export (CSV)' } '\.pdf$' { 'Document (PDF)' } '\.mp4$' { 'Recording' } default { 'File' } }
      A "<tr><td style='$script:Cell'><a href='$($Map.files[$f].link)'>$(Esc $f)</a></td><td style='$script:Cell'>$(Esc $chk)</td><td style='$script:Cell'>$type</td><td style='$script:Cell'>$(Esc (Caption $f))</td></tr>"
    }
    A "</table>"
  }
  A "<p style='font-size:8pt;color:#9ca3af;margin-top:18px'>Generated by the Claude Code QA kit. Verdict rules and evidence standard: defects are always FAIL; every FAIL is re-tested independently before a bug task is raised.</p>"
  A '</body></html>'
  $h.ToString()
}
