# Builds the QA results report: Build-QaReport = styled HTML (tuned for Google Docs import: inline styles only, tables for layout),
# Build-QaReportMd = the same content as Markdown (reports.type "markdown"; evidence links relative to <code>\report.md).
# Dot-sourced by finalize.ps1:  . "$S\lib\report.ps1";  $html = Build-QaReport -Title ... -Code ... -Item ... -Res ... -Map ... -Run ...
# $Map.files[<name>] = { id (Drive file id, gdocs only), link }; $Map.local = evidence stays in the run folder.
# Task links use Get-TrackerUrl (dev-kit\scripts\tracker.ps1) when the caller dot-sourced it.
function TaskLink($id) { if (Get-Command Get-TrackerUrl -ErrorAction SilentlyContinue) { Get-TrackerUrl $id } else { "$id" } }

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
$script:EvidenceName = '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2})?|_\d{2})_[a-z0-9]+([-._][a-z0-9]+)*\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?)$'

# "F2-T4_02_after-edit.jpeg" -> "After edit"; legacy names fall back to the file name
function Caption($file) {
  if ($file -match '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify)?(_\d{2})?_(.+)\.\w+$') {
    $c = ($Matches[3] -replace '[-_]', ' ').Trim(); $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }
    if (-not $c) { return $file }   # never let one odd name crash the whole publish
    return ($c.Substring(0, 1).ToUpper() + $c.Substring(1)) + $v
  }
  return $file
}
function Chip($k, $n) { $p = $script:Palette[$k]; "<td style='background:$($p.bg);color:$($p.fg);padding:8px 14px;text-align:center;$script:Font;border:1px solid #ffffff'><span style='font-size:18pt;font-weight:bold'>$n</span><br><span style='font-size:8pt;font-weight:bold'>$($p.label)</span></td>" }
function Img($map, $f, $w) {
  $src = if ($map.files[$f].id) { "https://drive.google.com/uc?export=view&amp;id=$($map.files[$f].id)" } else { $map.files[$f].link }
  "<p style='margin:4px 0 12px 0'><img src='$src' width='$w'><br><span style='font-size:9pt;color:#6b7280'>$(Esc (Caption $f)) · <a href='$($map.files[$f].link)'>$(Esc $f)</a></span></p>"
}
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

# Markdown version of the same report (reports.type "markdown"): GitHub/GitLab render it in a comment, and it reads fine as a file
function Build-QaReportMd($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl) {
  function MdEsc($t) { ([string]$t -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
  function Lnk($f) { if ($Map.files[$f]) { "[$f]($(([string]$Map.files[$f].link) -replace ' ', '%20'))" } else { $f } }
  $label = @{ PASS = 'PASS'; PASS_WITH_NOTE = 'PASS (note)'; FAIL = '**FAIL**'; NOT_TESTED = 'NOT TESTED'; PENDING = 'PENDING' }
  $checks = @($Res.checks)
  $n = @{}; foreach ($k in $label.Keys) { $n[$k] = @($checks | Where-Object result -eq $k).Count }
  $fails = @($checks | Where-Object result -eq 'FAIL')
  $verdict = if ($fails.Count) { 'Failures found' } elseif ($n.NOT_TESTED) { 'Partly tested' } elseif ($n.PENDING) { 'Passed so far — other-lane checks pending' } else { 'All checks passed' }
  $o = New-Object System.Collections.Generic.List[string]
  $o.Add("# $Title — $Code"); $o.Add(''); $o.Add("Test results · $Date · **$verdict**"); $o.Add('')
  $o.Add("PASS $($n.PASS + $n.PASS_WITH_NOTE) (with note $($n.PASS_WITH_NOTE)) · FAIL $($n.FAIL) · NOT TESTED $($n.NOT_TESTED) · PENDING $($n.PENDING) · total $($checks.Count)"); $o.Add('')
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
  $notes = @($checks | Where-Object { $_.result -in 'PASS_WITH_NOTE', 'NOT_TESTED' })
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
