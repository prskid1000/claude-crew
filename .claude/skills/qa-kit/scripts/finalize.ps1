<#
Publishes one tested package of a QA run: the report, one comment per tracker subtask with the report, closes each subtask,
and opens a "[Bug] ... failed checks" task for confirmed failures. Safe to re-run: never comments/closes a subtask twice.

Report output (kit.local.json "reports": { "type": ... }, or -Report):
  gdocs     Drive folder with all evidence + a Google Doc report (anyone with the link can view), via the gws CLI;
            reuses the folder and uploads only new files on a re-run. Default when gws is installed.
  markdown  <code>\report.md (+ report.html) next to the evidence in the run folder; the tracker comment carries the
            report (GitHub/GitLab: its text; ClickUp/Jira: the file attached; none: logged). Default without gws.
Tracker: skills\dev-kit\scripts\tracker.ps1 (kit.local.json "tracker": { "type": clickup|github|gitlab|jira|none }).

  & <workspace>\.claude\skills\qa-kit\scripts\finalize.ps1 -RunDir <run dir> -Code <package code> [-NoTracker] [-Force] [-Report gdocs|markdown]

Run dir layout (see the qa-kit SKILL.md):
  run.json                       { title, target, tester, envLines[], tracker{list,parent,owner,closeStatus, closeWithNotTested?}, driveParent, items[] }
  <code>\results.json            { code, checks[], findings[], setup_changes[], data_created[] }
  <code>\shots\*.jpeg|png  <code>\evidence\*.json
Writes <code>\report.html (+ report.md for markdown) and <code>\finalize.json. tracker.closeStatus may be a logical status (closed).
Subtasks that still have PENDING checks (tested later in another lane) get a comment but stay open.
#>
param(
  [Parameter(Mandatory)][string]$RunDir,
  [Parameter(Mandatory)][string]$Code,
  [switch]$NoTracker,
  [switch]$Force,
  [ValidateSet('', 'gdocs', 'markdown')][string]$Report = '',
  [string]$Date = (Get-Date -Format 'd MMM yyyy')
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\tracker.ps1')   # $KitConf + Get-TrackerUrl, Set-TrackerStatus, ...
$rtype = if ($Report) { $Report } else { $KitConf.ReportType }
if ($rtype -eq 'gdocs' -and -not (Get-Command gws -ErrorAction SilentlyContinue)) { throw 'reports.type is gdocs but the gws CLI is not on PATH - install/auth gws or use -Report markdown' }
$RunDir = (Resolve-Path $RunDir).Path
$run = Get-Content "$RunDir\run.json" -Raw | ConvertFrom-Json
$item = @($run.items) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
if (-not $item) { throw "no item $Code in $RunDir\run.json" }
$D = "$RunDir\$Code"
$res = Get-Content "$D\results.json" -Raw | ConvertFrom-Json
# Evidence entries may be absolute paths or files saved outside shots\/evidence\ (verify dirs, the item root): copy them into evidence\
# so they upload; helper scripts, source files and code notes testers list (.mjs/.ts/.tsx/.java, or text with spaces) are not evidence and are dropped.
New-Item -ItemType Directory -Force "$D\evidence" | Out-Null
foreach ($c in @($res.checks)) {
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -and [string]$_ -notmatch '\.(mjs|cjs|js|jsx|ts|tsx|java|kt|ps1|py|sh)$|\s' } | ForEach-Object {
      $e = [string]$_; $leaf = Split-Path $e -Leaf
      if (-not (Test-Path "$D\shots\$leaf") -and -not (Test-Path "$D\evidence\$leaf")) {
        $src = if ([IO.Path]::IsPathRooted($e) -and (Test-Path $e)) { $e } elseif (Test-Path (Join-Path $D $e)) { Join-Path $D $e } else { (Get-ChildItem $RunDir -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
        if ($src) { Copy-Item $src "$D\evidence\$leaf" -Force }
      }
      $leaf } | Select-Object -Unique)
}
$fin = "$D\finalize.json"
$prev = if ((Test-Path $fin) -and -not $Force) { Get-Content $fin -Raw | ConvertFrom-Json } else { $null }
$title = if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }
$tester = if ($run.tester) { $run.tester } else { $env:USERNAME }
$tr = $run.tracker
Set-Location $RunDir   # gws reads/writes only inside the current directory
function Invoke-Gws($a) { $out = & gws @a 2>$null; (($out | Where-Object { $_ -notmatch '^Using keyring' }) -join "`n") | ConvertFrom-Json }
function Share($id) { $null = & gws drive permissions create --params (@{ fileId = $id; supportsAllDrives = $true } | ConvertTo-Json -Compress) --json '{"role":"reader","type":"anyone"}' 2>$null }
function TaskUrl($id) { Get-TrackerUrl $id }
function TrySay([scriptblock]$b, [string]$what) { try { & $b } catch { Write-Warning "tracker ($($KitConf.TrackerType)): $what failed: $_"; $null } }
$P = '{"fields":"id,webViewLink","supportsAllDrives":true}'

# 1. Evidence: Drive folder + uploads (gdocs) or the run folder itself (markdown; links are relative to <code>\report.md)
$map = [ordered]@{ folderId = $null; folderLink = $null; files = [ordered]@{}; local = ($rtype -ne 'gdocs') }
$files = @(Get-ChildItem "$D\shots", "$D\evidence" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'tmp*' -and $_.Extension -match '^\.(jpe?g|png|json|log|csv|txt|pdf|mp4|html|xlsx?)$' })
if ($map.local) {
  $map.folderLink = $D
  foreach ($x in $files) { $map.files[$x.Name] = @{ id = $null; link = "$($x.Directory.Name)/$($x.Name)"; path = $x.FullName } }
}
elseif ($prev -and $prev.folderId) {
  $map.folderId = $prev.folderId; $map.folderLink = $prev.folderLink
  foreach ($p in $prev.files.PSObject.Properties) { $map.files[$p.Name] = $p.Value }
} else {
  $meta = @{ name = "$title $Code - test evidence ($Date)"; mimeType = 'application/vnd.google-apps.folder' }
  if ($run.driveParent) { $meta.parents = @($run.driveParent) }
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

# 2. Styled report (lib\report.ps1) + evidence-name check (reference\evidence-standard.md)
. "$PSScriptRoot\lib\report.ps1"
$checks = @($res.checks)
function Cnt($arr, $k) { @($arr | Where-Object { $_.result -eq $k }).Count }
$guideUrl = if ($item.guideUrl) { $item.guideUrl } elseif ($item.guideId) { "https://docs.google.com/document/d/$($item.guideId)/edit" } elseif ($item.guideFile) { $item.guideFile } else { $null }
$badNames = @($files | Where-Object { $_.Name -notmatch $script:EvidenceName } | ForEach-Object Name)
if ($badNames.Count) { Write-Warning "evidence names not following the standard (published anyway): $($badNames -join ', ')" }
$missing = @($checks | ForEach-Object { $c = $_; @($c.evidence) | Where-Object { $_ -and -not $map.files[$_] } | ForEach-Object { "$($c.id): $_" } })
if ($missing.Count) { Write-Warning "evidence listed in results.json but not found/uploaded: $($missing -join '; ')" }
Build-QaReport -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File "$D\report.html" -Encoding utf8

# 3. The report: Google Doc (gdocs) or report.md in the run folder (markdown)
$reportFile = $null
if ($map.local) {
  $reportFile = "$D\report.md"
  Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File $reportFile -Encoding utf8
  $docUrl = $reportFile
} else {
  $doc = Invoke-Gws @('drive', 'files', 'create', '--json', (@{ name = "$title $Code - Test Results ($Date)"; mimeType = 'application/vnd.google-apps.document'; parents = @($map.folderId) } | ConvertTo-Json -Compress), '--upload', "$Code/report.html", '--upload-content-type', 'text/html', '--params', $P)
  if ($doc.id) { Share $doc.id; $docUrl = "https://docs.google.com/document/d/$($doc.id)/edit" }
  elseif ($prev.doc -and $prev.doc -notmatch '/d//') { Write-Warning "Google Doc create failed - keeping the previous report $($prev.doc)"; $docUrl = $prev.doc }
  else { throw "Google Doc create failed and there is no previous report - fix gws auth and re-run (nothing was posted to the tracker)" }
}

# 4. Tracker, per subtask
$out = [ordered]@{ report = $rtype; folderId = $map.folderId; folderLink = $map.folderLink; files = $map.files; doc = $docUrl; subtasks = @() }
$closeStatus = if ($tr.closeStatus) { $tr.closeStatus } else { 'closed' }   # logical name, mapped by tracker.statuses
$bugList = if ($tr.list) { $tr.list } else { [string](Get-KitSetting 'tracker.list' '') }
$canCreate = [bool]$bugList -or $KitConf.TrackerType -in 'github', 'gitlab', 'none'   # github/gitlab use tracker.repo; clickup/jira need a list/project
foreach ($st in @($item.subtasks)) {
  $mine = @($checks | Where-Object { $_.subtask_id -eq $st.id })
  if (-not $mine.Count -and @($item.subtasks).Count -eq 1) { $mine = $checks }
  $pass = (Cnt $mine 'PASS') + (Cnt $mine 'PASS_WITH_NOTE'); $fails = @($mine | Where-Object { $_.result -eq 'FAIL' }); $nt = Cnt $mine 'NOT_TESTED'; $pend = Cnt $mine 'PENDING'
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $fails.Count; notTested = $nt; pending = $pend; bug = $null; closed = $false }
  if (-not $NoTracker) {
    $prevRec = if ($prev) { @($prev.subtasks | Where-Object { $_.id -eq $st.id }) | Select-Object -First 1 }
    if ($prevRec.closed) { $out.subtasks += $prevRec; continue }   # keep the first run's record (bug id, closed)
    # re-run of a task kept open (NOT_TESTED) or waiting for a sibling item: never a second bug task or results comment,
    # only re-check whether it can close now
    if ($prevRec) {
      $rec.bug = $prevRec.bug
      $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir\$($_.code)\finalize.json") } | ForEach-Object code)
      if ($others.Count) { $rec.waitingFor = $others }
      elseif ($nt -and -not $tr.closeWithNotTested) { $rec.keptOpen = "$nt check(s) not tested" }
      elseif ($rec.bugError) { $rec.keptOpen = 'failed checks have no bug task' }   # never close while failures are tracked nowhere
      elseif (-not $pend) { if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } }
      $out.subtasks += $rec; continue
    }
    $icon = if ($fails.Count) { '❌' } elseif ($nt -or $pend) { '⚠️' } else { '✅' }
    $msg = "$icon " + $(if ($item.retest) { "Retest of the fix ($Date): $pass of $($mine.Count) checks pass" } else { "Test results ($($run.target), $Date): $pass of $($mine.Count) checks pass" })
    if ($fails.Count) { $msg += ", $($fails.Count) failed ($(($fails | ForEach-Object id) -join ', '))" }
    if ($nt) { $msg += ", $nt not tested" }
    if ($pend) { $msg += ". $pend check(s) are tested next in another lane" }
    if ($fails.Count -and $canCreate) {
      $body = "## Failed checks`n`nFound while testing **$($st.name)** on $($run.target) ($Date).`n`n" +
        "- Original task: $(TaskUrl $st.id)`n- Results report (screenshots, request/response JSON): $docUrl$(if ($map.local) { ' (attached to the original task)' })`n" + $(if ($guideUrl) { "- Tester guide (check ids refer to it): $guideUrl`n" } else { '' }) + "`n" +
        (($fails | ForEach-Object { "### $($_.id) — $($_.screen)`n**Steps:** $($_.what_was_done)`n`n**Saw:** $($_.observed)`n`n**Independent re-test:** $(if ($_.verify) { $_.verify } else { 'not re-tested' })`n`n**Evidence:** $((@($_.evidence) | ForEach-Object { if ($map.files[$_]) { "[$_]($($map.files[$_].link))" } else { $_ } }) -join ', ')`n" }) -join "`n") +
        "`n## Expected`nAs described in the tester guide for each check id."
      $base = ($st.name -replace '^\[(Bug|Feature)\]\s*', '' -replace '\s+[-—]\s+failed checks\b.*$', '' -replace '\s*\((API|Web|App)[^)]*\)\s*$', '').Trim()   # a retested bug task keeps one "failed checks" suffix
      if ($base.Length -gt 90) { $base = $base.Substring(0, 87) + '...' }
      $nm = "[Bug] $base — failed checks $(($fails | ForEach-Object id) -join ', ')"
      # tracker.ps1 handles backend quirks (e.g. ClickUp refuses a subtask whose parent is in another list: created in the list + 'Related' comment)
      $bug = TrySay { New-TrackerTask -List $bugList -Name $nm -Description $body -Parent $tr.parent -Assignee $tr.owner -Priority '2' } 'create the bug task'
      if ($bug.id) { $rec.bug = $bug.id; $msg += ". Failed part moved to $(if ($bug.url) { $bug.url } else { TaskUrl $bug.id })" }
      else { $rec.bugError = 'bug task could not be created'; Write-Warning "$($st.id): could not create the bug task for $(($fails | ForEach-Object id) -join ', ') - task kept open" }
    }
    if ($reportFile) {
      $msg += ". Full report with screenshots and API evidence: $docUrl (evidence in $D)"
      $null = TrySay { Add-TrackerAttachment $st.id $reportFile $msg } "post the report on $($st.id)"
      if ($rec.bug) { $null = TrySay { Add-TrackerAttachment $rec.bug $reportFile "QA report for the failed checks" } "post the report on $($rec.bug)" }
    } else {
      $msg += ". Full report with screenshots and API evidence: $docUrl"
      $null = TrySay { Add-TrackerComment $st.id $msg } "comment on $($st.id)"
    }
    # a task shared by several items (e.g. one feature, one guide per dev group) closes only when the last of them has finalized
    $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir\$($_.code)\finalize.json") } | ForEach-Object code)
    if ($others.Count) { $rec.waitingFor = $others }
    # NOT_TESTED checks keep the task open (e.g. a dependency not deployed yet): closing would hide the untested part
    elseif ($nt -and -not $tr.closeWithNotTested) { $rec.keptOpen = "$nt check(s) not tested"; $null = TrySay { Add-TrackerComment $st.id "Not closed: $nt check(s) could not be tested yet (see the report). Retest them once their blocker is resolved." } "comment on $($st.id)" }
    elseif ($rec.bugError) { $rec.keptOpen = 'failed checks have no bug task' }   # never close while failures are tracked nowhere
    elseif (-not $pend) { if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } }
  }
  $out.subtasks += $rec
}
$out | ConvertTo-Json -Depth 6 | Out-File $fin -Encoding utf8
"$Code report ($rtype): $docUrl"
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, fail $($_.fail), not tested $($_.notTested), pending $($_.pending), bug $($_.bug), closed $($_.closed)" }
