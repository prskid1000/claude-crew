<#
Publishes one tested package of a QA run: the report, one comment per tracker subtask with the report, closes each subtask,
and opens a "[Bug] ... failed checks" task for confirmed failures. Safe to re-run: never comments/closes a subtask twice.

Report output (kit.local.json "reports": { "type": ... }, or -Report):
  gdocs     Drive folder with all evidence + a Google Doc report (anyone with the link can view), via the gws CLI;
            reuses the folder and uploads only new files on a re-run. Default when gws is installed.
  markdown  <code>/report.md (+ report.html) next to the evidence in the run folder; the tracker comment carries the
            report (GitHub/GitLab: its text; ClickUp/Jira: the file attached; none: logged). Default without gws.
Tracker: skills/dev-kit/scripts/tracker.ps1 (kit.local.json "tracker": { "type": clickup|github|gitlab|jira|none }).

  & <workspace>/.claude/skills/qa-kit/scripts/finalize.ps1 -RunDir <run dir> -Code <package code> [-NoTracker] [-Force] [-Report gdocs|markdown] [-AllowMissing]
  & <workspace>/.claude/skills/qa-kit/scripts/finalize.ps1 -RunDir <run dir> -Code <package code> -Check [-FixNames]

Evidence check (runs first, before any upload or tracker call; reference/evidence-standard.md): every file listed in results.json
must exist (in shots\, evidence\ or findable in the run dir), else it throws and nothing is published. -AllowMissing publishes
anyway, dropping the missing names and noting them in the check's "observed". On publish, off-standard names are only a warning.
-Check runs only this check (no copies, uploads or tracker calls) and exits 1 with the list when evidence is missing, a file in
shots\/evidence\ has an off-standard name (a suggested standard name is printed for each), a listed file has a type that is
never published ("listed but unsupported type") or a check id appears twice in results.json; else exit 0. -Check -FixNames first renames each off-standard file to its suggested name and rewrites the
references in results.json (each rename is printed); duplicate check ids are never fixed automatically.

Run dir layout (see the qa-kit SKILL.md):
  run.json                       { title, target, tester, envLines[], tracker{list,parent,owner,closeStatus, closeWithNotTested?}, driveParent, items[] }
  <code>/results.json            { code, checks[], findings[], setup_changes[], data_created[] }
  <code>/shots/*.jpeg|png  <code>/evidence/*.json|jsonl|ndjson|log (types: $script:EvidenceExt in lib/report.ps1)
Writes <code>/report.html (+ report.md for markdown) and <code>/finalize.json. tracker.closeStatus may be a logical status (closed).
Subtasks that still have PENDING checks (tested later in another lane) get a comment but stay open.
#>
param(
  [Parameter(Mandatory)][string]$RunDir,
  [Parameter(Mandatory)][string]$Code,
  [switch]$NoTracker,
  [switch]$Force,
  [switch]$Check,
  [switch]$FixNames,
  [switch]$AllowMissing,
  [ValidateSet('', 'gdocs', 'markdown')][string]$Report = '',
  [string]$Date = (Get-Date -Format 'd MMM yyyy')
)
$ErrorActionPreference = 'Stop'
if ($FixNames -and -not $Check) { throw '-FixNames works only together with -Check' }
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\tracker.ps1')   # $KitConf + Get-TrackerUrl, Set-TrackerStatus, ...
$rtype = if ($Report) { $Report } else { $KitConf.ReportType }
if (-not $Check -and $rtype -eq 'gdocs' -and -not (Get-Command gws -ErrorAction SilentlyContinue)) { throw 'reports.type is gdocs but the gws CLI is not on PATH - install/auth gws or use -Report markdown' }
$RunDir = (Resolve-Path $RunDir).Path
$run = Get-Content "$RunDir\run.json" -Raw | ConvertFrom-Json
$item = @($run.items) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
if (-not $item) { throw "no item $Code in $RunDir\run.json" }
$D = "$RunDir\$Code"
$res = Get-Content "$D\results.json" -Raw | ConvertFrom-Json
# Evidence entries may be absolute paths or files saved outside shots\/evidence\ (verify dirs, the item root): copy them into evidence\
# so they upload; helper scripts, source files and code notes testers list (.mjs/.ts/.tsx/.java, or text with spaces) are not evidence and are dropped.
if (-not $Check) { New-Item -ItemType Directory -Force "$D\evidence" | Out-Null }
$lost = [Collections.Generic.List[object]]::new()   # evidence listed in results.json that exists nowhere
foreach ($c in @($res.checks)) {
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -and [string]$_ -notmatch '\.(mjs|cjs|js|jsx|ts|tsx|java|kt|ps1|py|sh)$|\s' } | ForEach-Object {
      $e = [string]$_; $leaf = Split-Path $e -Leaf
      if (-not (Test-Path "$D\shots\$leaf") -and -not (Test-Path "$D\evidence\$leaf")) {
        $src = if ([IO.Path]::IsPathRooted($e) -and (Test-Path $e)) { $e } elseif (Test-Path (Join-Path $D $e)) { Join-Path $D $e } else { (Get-ChildItem $RunDir -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
        if (-not $src) { $lost.Add([pscustomobject]@{ check = $c; name = $leaf }) }
        elseif (-not $Check) { Copy-Item $src "$D\evidence\$leaf" -Force }
      }
      $leaf } | Select-Object -Unique)
}

# 0. Evidence check before anything is uploaded or posted (reference/evidence-standard.md)
. (Join-Path $PSScriptRoot 'lib/report.ps1')
$files = @(Get-ChildItem "$D\shots", "$D\evidence" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'tmp*' -and $_.Extension -match $script:EvidenceExt })
$badNames = @($files | Where-Object { $_.Name -notmatch $script:EvidenceName } | ForEach-Object Name)
if ($badNames.Count -and -not $Check) { Write-Warning "evidence names not following the standard (published anyway): $($badNames -join ', ')" }
# listed evidence of a type that is never published (it would silently stay on disk): convert it or list a supported file instead
$badTypes = @(@(foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e -and [IO.Path]::GetExtension([string]$e) -notmatch $script:EvidenceExt) { "$($c.id): $e" } } }) | Select-Object -Unique)
if ($badTypes.Count -and -not $Check) { Write-Warning "evidence listed but of an unsupported type (not published): $($badTypes -join '; ')" }
$lostList = @($lost | ForEach-Object { "$($_.check.id): $($_.name)" })
if ($Check) {
  # A standard name for an off-standard file: <CODE>-<check>[_verify]_<nn>_<what>.<ext> when a check id is in the name or a check
  # lists the file, else the setup form <CODE>-<nn>-<what>.<ext>; nn from the name (a free one when absent or taken).
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
      '{0}-{1:D2}-{2}{3}' -f $Code, $n, $what, $ext   # setup form: no check id, or one that does not fit the pattern
    }
    if ($nn -lt 0) {   # no number in the name: the next one after this check's (or the setup files') highest
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
  $suggest = [ordered]@{}
  foreach ($b in $badNames) { $suggest[$b] = Get-StandardName $b }
  if ($FixNames -and $suggest.Count) {
    $resFile = "$D\results.json"; $raw = [IO.File]::ReadAllText($resFile)
    foreach ($b in @($suggest.Keys)) {
      $new = $suggest[$b]; if (-not $new) { continue }
      $f = $files | Where-Object Name -eq $b | Select-Object -First 1
      Rename-Item -LiteralPath $f.FullName -NewName $new
      # references end in the file name: "<name>" or "<dir>/<name>" inside a JSON string
      $raw = [regex]::Replace($raw, '(?<=["/\\])' + [regex]::Escape($b) + '(?=")', $new.Replace('$', '$$'))
      "  renamed $($f.Directory.Name)\$b -> $new"
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
    $badNames | ForEach-Object { "  $_ -> $(if ($suggest[$_]) { $suggest[$_] } else { '(no suggestion: rename by hand)' })" }
  }
  if ($dups.Count) { $fail = $true; "$Code evidence check: duplicate check id(s) in results.json (merge or renumber them): $($dups -join ', ')" }
  if ($badTypes.Count) {
    $fail = $true; "$Code evidence check: $($badTypes.Count) file(s) listed but unsupported type (never published; supported: $($script:EvidenceExt -replace '^\^\\\.\(|\)\$$', '' -replace '\|', ' ')):"
    $badTypes | ForEach-Object { "  $_" }
  }
  if ($fail) { exit 1 }
  "$Code evidence check: OK ($($files.Count) files, standard names, supported types, unique check ids)"; exit 0
}
if ($lostList.Count -and -not $AllowMissing) {
  throw "$Code`: $($lostList.Count) evidence file(s) listed in results.json are missing - nothing was published: $($lostList -join '; '). Save them or fix results.json, then re-run (or pass -AllowMissing to publish without them)."
}
foreach ($g in @($lost | Group-Object { $_.check.id })) {   # -AllowMissing: drop the names, say so in the check
  $c = $g.Group[0].check; $gone = @($g.Group | ForEach-Object name)
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -notin $gone })
  $c | Add-Member -NotePropertyName observed -NotePropertyValue "$($c.observed) [Evidence missing at publish: $($gone -join ', ')]".Trim() -Force
}
if ($lostList.Count) { Write-Warning "published without missing evidence (-AllowMissing): $($lostList -join '; ')" }
$fin = "$D\finalize.json"
$prev = if ((Test-Path $fin) -and -not $Force) { Get-Content $fin -Raw | ConvertFrom-Json } else { $null }
$title = if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }
$tester = if ($run.tester) { $run.tester } else { [Environment]::UserName }
$tr = $run.tracker
Set-Location $RunDir   # gws reads/writes only inside the current directory
function Invoke-Gws($a) { $out = & gws @a 2>$null; (($out | Where-Object { $_ -notmatch '^Using keyring' }) -join "`n") | ConvertFrom-Json }
function Share($id) { $null = & gws drive permissions create --params (@{ fileId = $id; supportsAllDrives = $true } | ConvertTo-Json -Compress) --json '{"role":"reader","type":"anyone"}' 2>$null }
function TaskUrl($id) { Get-TrackerUrl $id }
function TrySay([scriptblock]$b, [string]$what) { try { & $b } catch { Write-Warning "tracker ($($KitConf.TrackerType)): $what failed: $_"; $null } }
$P = '{"fields":"id,webViewLink","supportsAllDrives":true}'

# 1. Evidence: Drive folder + uploads (gdocs) or the run folder itself (markdown; links are relative to <code>/report.md)
$map = [ordered]@{ folderId = $null; folderLink = $null; files = [ordered]@{}; local = ($rtype -ne 'gdocs') }
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

# 2. Styled report (lib/report.ps1, loaded at step 0)
$checks = @($res.checks)
function Cnt($arr, $k) { @($arr | Where-Object { $_.result -eq $k }).Count }
$guideUrl = if ($item.guideUrl) { $item.guideUrl } elseif ($item.guideId) { "https://docs.google.com/document/d/$($item.guideId)/edit" } elseif ($item.guideFile) { $item.guideFile } else { $null }
$missing = @($checks | ForEach-Object { $c = $_; @($c.evidence) | Where-Object { $_ -and -not $map.files[$_] } | ForEach-Object { "$($c.id): $_" } })
if ($missing.Count) { Write-Warning "evidence found but not uploaded: $($missing -join '; ')" }
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
# the last item on a shared task decides the close: sibling items' NOT_TESTED checks and untracked failures keep it open too
function SiblingHold($id) {
  $nt = 0; $err = $null
  foreach ($c in @(@($run.items) | Where-Object { $_.code -ne $Code } | ForEach-Object code)) {
    $f = "$RunDir\$c\finalize.json"; if (-not (Test-Path $f)) { continue }
    $r = @((Get-Content $f -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.id -eq $id -and -not $_.noTracker }) | Select-Object -First 1
    if ($r) { $nt += [int]$r.notTested; if ($r.bugError) { $err = "$c`: $($r.bugError)" } }
  }
  [pscustomobject]@{ notTested = $nt; bugError = $err }
}
foreach ($st in @($item.subtasks)) {
  $mine = @($checks | Where-Object { $_.subtask_id -eq $st.id })
  if (-not $mine.Count -and @($item.subtasks).Count -eq 1) { $mine = $checks }
  $pass = (Cnt $mine 'PASS') + (Cnt $mine 'PASS_WITH_NOTE'); $fails = @($mine | Where-Object { $_.result -eq 'FAIL' }); $nt = Cnt $mine 'NOT_TESTED'; $pend = Cnt $mine 'PENDING'
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $fails.Count; notTested = $nt; pending = $pend; bug = $null; closed = $false }
  $prevRec = if ($prev) { @($prev.subtasks | Where-Object { $_.id -eq $st.id }) | Select-Object -First 1 }
  if ($NoTracker) {
    # a dry run must not overwrite a posted record (the next real run would post again); its own records are marked
    # so a later real run treats the subtask as a first run
    if ($prevRec -and -not $prevRec.noTracker) { $out.subtasks += $prevRec; continue }
    $rec.noTracker = $true
  } else {
    if ($prevRec.noTracker) { $prevRec = $null }
    if ($prevRec.closed) { $out.subtasks += $prevRec; continue }   # keep the first run's record (bug id, closed)
    # re-run of a task kept open (NOT_TESTED) or waiting for a sibling item: never a second bug task or results comment,
    # only re-check whether it can close now
    if ($prevRec) {
      $rec.bug = $prevRec.bug
      $rec.bugError = if ($prevRec.bugError) { $prevRec.bugError } elseif ($fails.Count -and -not $rec.bug) { 'failed checks have no bug task' }
      $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir\$($_.code)\finalize.json") } | ForEach-Object code)
      $sib = if ($others.Count) { $null } else { SiblingHold $st.id }
      if ($others.Count) { $rec.waitingFor = $others }
      elseif (($nt + $sib.notTested) -and -not $tr.closeWithNotTested) { $rec.keptOpen = "$($nt + $sib.notTested) check(s) not tested" }
      elseif ($rec.bugError) { $rec.keptOpen = 'failed checks have no bug task' }   # never close while failures are tracked nowhere
      elseif ($sib.bugError) { $rec.keptOpen = "failed checks have no bug task ($($sib.bugError))" }
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
    elseif ($fails.Count) { $rec.bugError = 'no bug list configured'; Write-Warning "$($st.id): no tracker list for bug tasks (tracker.list) - task kept open" }
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
    $sib = if ($others.Count) { $null } else { SiblingHold $st.id }
    if ($others.Count) { $rec.waitingFor = $others }
    # NOT_TESTED checks (this item's or a sibling's) keep the task open (e.g. a dependency not deployed yet): closing would hide the untested part
    elseif (($nt + $sib.notTested) -and -not $tr.closeWithNotTested) { $ntAll = $nt + $sib.notTested; $rec.keptOpen = "$ntAll check(s) not tested"; $null = TrySay { Add-TrackerComment $st.id "Not closed: $ntAll check(s) could not be tested yet (see the reports). Retest them once their blocker is resolved." } "comment on $($st.id)" }
    elseif ($rec.bugError) { $rec.keptOpen = 'failed checks have no bug task' }   # never close while failures are tracked nowhere
    elseif ($sib.bugError) { $rec.keptOpen = "failed checks have no bug task ($($sib.bugError))" }
    elseif (-not $pend) { if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } }
  }
  $out.subtasks += $rec
}
$out | ConvertTo-Json -Depth 6 | Out-File $fin -Encoding utf8
"$Code report ($rtype): $docUrl"
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, fail $($_.fail), not tested $($_.notTested), pending $($_.pending), bug $($_.bug), closed $($_.closed)" }
