<#
Publishes one tested package of a QA run: the report, one comment per tracker subtask with the report and its failed / untested
checks, then the result rule: all pass -> closed; an own check FAILED or checks not tested -> failedTesting (back to the dev flow,
no new task); a new / unexpected defect -> one "[Bug] <ask> — new defects (n)" task per original ask. Safe to re-run: never
comments, files or closes a subtask twice.

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
never published ("listed but unsupported type"), a cited file is empty (0 bytes; -FixNames never renames it) or a check id appears twice in results.json; else exit 0. -Check -FixNames first renames each off-standard file to its suggested name and rewrites the
references in results.json (each rename is printed); duplicate check ids are never fixed automatically.

Run dir layout (see the qa-kit SKILL.md):
  run.json                       { title, target, tester, envLines[], tracker{list,parent,owner,closeStatus}, driveParent, items[] }
  <code>/results.json            { code, checks[], findings[], setup_changes[], data_created[] }
  <code>/shots/*.jpeg|png  <code>/evidence/*.json|jsonl|ndjson|log (types: $script:EvidenceExt in lib/report.ps1)
Writes <code>/report.html (+ report.md for markdown) and <code>/finalize.json. tracker.closeStatus may be a logical status (closed).
Subtasks that still have PENDING checks (tested later in another lane) get a comment but stay open. A FAIL is the task's own
(results.json check "defect": "own", the default for guide checks) or new ("defect": "new", the default for X checks): new
defects go to <run>/bugs.json + the ask's [Bug] task, appended to an open one the ask already has (never a task this run tests).
failedTesting falls back to inProgress + a comment when the board has no such status. OUT_OF_SCOPE checks never count.
The summary line says what happened per subtask (closed / failed testing / open: why).
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
  # a cited file of 0 bytes is a failed capture, not evidence: reported below and never renamed (a standard name would make it look valid)
  $cited = @{}; foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e) { $cited[[string]$e] = [string]$c.id } } }
  $emptyFiles = @($files | Where-Object { $_.Length -eq 0 -and $cited.ContainsKey($_.Name) })
  $emptyNames = @($emptyFiles | ForEach-Object Name)
  $suggest = [ordered]@{}
  foreach ($b in $badNames) { $suggest[$b] = if ($emptyNames -contains $b) { $null } else { Get-StandardName $b } }
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
    $badNames | ForEach-Object { "  $_ -> $(if ($suggest[$_]) { $suggest[$_] } elseif ($emptyNames -contains $_) { '(empty file: not renamed, see below)' } else { '(no suggestion: rename by hand)' })" }
  }
  if ($emptyFiles.Count) {
    $fail = $true; "$Code evidence check: $($emptyFiles.Count) empty file(s) cited (0 bytes: the capture failed; re-capture or drop them from results.json; -FixNames leaves them):"
    $emptyFiles | ForEach-Object { "  $($cited[$_.Name]): $($_.Directory.Name)\$($_.Name)" }
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
  foreach ($pf in $prev.files.PSObject.Properties) { $map.files[$pf.Name] = $pf.Value }   # not $p: that IS $P (the --params JSON used below)
} else {
  $meta = @{ name = "$title $Code - test evidence ($Date)"; mimeType = 'application/vnd.google-apps.folder' }
  $dp = if ($run.driveParent) { [string]$run.driveParent } else { [string](Get-KitSetting 'driveParent' '') }   # run.json wins, else kit.local.json (as documented)
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

# 4. Tracker, per subtask. Result rule (qa-kit SKILL.md step 5, reference/human-testing-doc.md):
#   all checks pass (PASS / PASS_WITH_NOTE / OUT_OF_SCOPE)      -> closed
#   a FAIL of the task's own expected behaviour (defect 'own')   -> failedTesting: the task goes back to the dev flow, no new task
#   checks not tested completely (NOT_TESTED)                    -> failedTesting too, the untested checks and why in the comment
#   a new / unexpected defect (defect 'new': regression, found on the way, X checks) -> ONE [Bug] task per original ask (the tested
#     task's tracker parent, else run.json tracker.parent), appended to an open one this ask already has; the task itself closes
#     when its own checks pass
#   PENDING (tested next in another lane) or a sibling item not finalized yet -> stays open for now
$out = [ordered]@{ report = $rtype; folderId = $map.folderId; folderLink = $map.folderLink; files = $map.files; doc = $docUrl; subtasks = @() }
$closeStatus = if ($tr.closeStatus) { $tr.closeStatus } else { 'closed' }   # logical name, mapped by tracker.statuses
$bugList = if ($tr.list) { $tr.list } else { [string](Get-KitSetting 'tracker.list' '') }
$canCreate = [bool]$bugList -or $KitConf.TrackerType -in 'github', 'gitlab', 'none'   # github/gitlab use tracker.repo; clickup/jira need a list/project
# own vs new: the tester's 'defect' field wins; without it an X check (off-script) is new, a guide check is the task's own
function Test-NewDefect($c) { if ("$($c.defect)" -in 'new', 'own') { return "$($c.defect)" -eq 'new' }; [string]$c.id -match '^X\d' }
# the markdown both the bug task and the failedTesting comment use: bug-brief.ps1 parses "### <id> — <screen>" + "**Saw:**"
function Format-Checks($list, [string]$heading) {
  if (-not @($list).Count) { return '' }
  "## $heading`n`n" + ((@($list) | ForEach-Object {
        $ev = (@($_.evidence) | Where-Object { $_ } | ForEach-Object { if ($map.files[$_]) { "[$_]($($map.files[$_].link))" } else { $_ } }) -join ', '
        "### $($_.id) — $($_.screen)`n**Steps:** $($_.what_was_done)`n`n**Saw:** $($_.observed)$(if ($_.cause) { " (cause: $($_.cause))" })`n`n**Independent re-test:** $(if ($_.verify) { $_.verify } else { 'not re-tested' })`n`n**Evidence:** $(if ($ev) { $ev } else { 'none' })`n" }) -join "`n") + "`n"
}
# the last item on a shared task decides: sibling items' failed / untested checks count too
function SiblingHold($id) {
  $own = 0; $nt = 0; $err = $null
  foreach ($c in @(@($run.items) | Where-Object { $_.code -ne $Code } | ForEach-Object code)) {
    $f = "$RunDir\$c\finalize.json"; if (-not (Test-Path $f)) { continue }
    $r = @((Get-Content $f -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.id -eq $id -and -not $_.noTracker }) | Select-Object -First 1
    if ($r) { $own += [int]$r.fail; $nt += [int]$r.notTested; if ($r.bugError) { $err = "$c`: $($r.bugError)" } }
  }
  [pscustomobject]@{ fail = $own; notTested = $nt; bugError = $err }
}
# the original ask of a tested task = its tracker parent; else run.json tracker.parent; else none (top level)
$script:askCache = @{}
function Get-Ask($st) {
  if ($script:askCache.ContainsKey($st.id)) { return $script:askCache[$st.id] }
  $pid_ = try { [string](Get-TrackerTask $st.id).parent } catch { '' }
  if (-not $pid_) { $pid_ = [string]$tr.parent }
  $pname = if ($pid_) { try { [string](Get-TrackerTask $pid_).name } catch { '' } } else { '' }
  $script:askCache[$st.id] = [pscustomobject]@{ id = $pid_; name = $pname }
  $script:askCache[$st.id]
}
# one [Bug] task per original ask: <run>/bugs.json holds one group per ask (task id + its items' new defects); an open
# "[Bug] ..." subtask the ask already has (an earlier run; never a task this run tests) is appended to; a mutex keeps parallel
# finalize runs to one task per ask
function Add-NewDefects($st, [object[]]$defects) {
  $ask = Get-Ask $st; $key = if ($ask.id) { $ask.id } else { '-' }
  $h = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($RunDir.ToLower()))).Substring(0, 16)
  $mx = [Threading.Mutex]::new($false, "Global\kit-bugs-$h")
  $own = $true; try { $own = $mx.WaitOne(120000) } catch [Threading.AbandonedMutexException] { $own = $true }   # abandoned = ours now
  try {
    $f = "$RunDir\bugs.json"
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
    $name = "[Bug] $(if ($ask.name) { $ask.name } else { $title }) — new defects ($n)"
    $body = "QA run **$title** on $($run.target) ($Date) found these defects outside what the tested tasks changed. Results report: $docUrl`n$(if ($guideUrl) { "Tester guide (check ids refer to it): $guideUrl`n" })`n" + (($entries | ForEach-Object md) -join "`n")
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
# failedTesting: the logical status (tracker.statuses); a board without it -> inProgress + the comment says "failed testing"
function Set-FailedTesting($rec, $st) {
  $ok = TrySay { Set-TrackerStatus $st.id 'failedTesting'; $true } "set $($st.id) failedTesting"
  if ($null -eq $ok) {
    $ok = TrySay { Set-TrackerStatus $st.id 'inProgress'; $true } "set $($st.id) inProgress (fallback: no failedTesting status)"
    if ($null -ne $ok) { $rec.statusFallback = 'inProgress'; $null = TrySay { Add-TrackerComment $st.id "Failed testing (this board has no 'failedTesting' status: set tracker.statuses.failedTesting in kit.local.json): moved back to in progress." } "comment on $($st.id)" }
  }
  if ($null -ne $ok) { $rec.failedTesting = $true } else { $rec.keptOpen = 'the tracker refused the failedTesting status (see warning)' }
}
function Resolve-Outcome($rec, $st, [int]$pend) {
  $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir\$($_.code)\finalize.json") } | ForEach-Object code)
  if ($others.Count) { $rec.waitingFor = $others; return }
  if ($pend) { $rec.keptOpen = "$pend check(s) pending in another lane"; return }
  if (-not $rec.total) { $rec.keptOpen = 'no check carries this task id (subtask_id)'; return }   # 0 of 0 is not a pass
  $sib = SiblingHold $st.id
  if ($rec.fail + $sib.fail + $rec.notTested + $sib.notTested) { Set-FailedTesting $rec $st; return }
  if ($rec.bugError -or $sib.bugError) { $rec.keptOpen = "new defects have no [Bug] task ($(if ($rec.bugError) { $rec.bugError } else { $sib.bugError }))"; return }   # never close while a defect is tracked nowhere
  if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } else { $rec.keptOpen = 'the tracker refused the close (see warning)' }
}
foreach ($st in @($item.subtasks)) {
  $mine = @($checks | Where-Object { $_.subtask_id -eq $st.id })
  if (-not $mine.Count -and @($item.subtasks).Count -eq 1) { $mine = $checks }
  $dupOf = if ($item.dups) { [string]$item.dups.($st.id) } else { '' }   # run.json dups: {duplicateId: primaryId} share the primary's checks
  if (-not $mine.Count -and $dupOf) { $mine = @($checks | Where-Object { $_.subtask_id -eq $dupOf }) }
  $allFails = @($mine | Where-Object { $_.result -eq 'FAIL' })
  $newDefects = @($allFails | Where-Object { Test-NewDefect $_ }); $ownFails = @($allFails | Where-Object { -not (Test-NewDefect $_) })
  $ntChecks = @($mine | Where-Object { $_.result -eq 'NOT_TESTED' }); $nt = $ntChecks.Count; $pend = Cnt $mine 'PENDING'
  $pass = (Cnt $mine 'PASS') + (Cnt $mine 'PASS_WITH_NOTE'); $oos = Cnt $mine 'OUT_OF_SCOPE'   # OUT_OF_SCOPE: a channel the org never tests (qa.outOfScope)
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $ownFails.Count; newDefects = $newDefects.Count; notTested = $nt; outOfScope = $oos; pending = $pend; bug = $null; closed = $false; failedTesting = $false }
  $prevRec = if ($prev) { @($prev.subtasks | Where-Object { $_.id -eq $st.id }) | Select-Object -First 1 }
  if ($NoTracker) {
    # a dry run must not overwrite a posted record (the next real run would post again); its own records are marked
    if ($prevRec -and -not $prevRec.noTracker) { $out.subtasks += $prevRec; continue }
    $rec.noTracker = $true
  } else {
    if ($prevRec.noTracker) { $prevRec = $null }
    if ($prevRec.closed -or $prevRec.failedTesting) { $out.subtasks += $prevRec; continue }   # keep the first run's record
    # re-run of a task waiting for a sibling item / a lane: never a second bug task or results comment, only re-resolve
    if ($prevRec) {
      $rec.bug = $prevRec.bug
      $rec.bugError = if ($prevRec.bugError) { $prevRec.bugError } elseif ($newDefects.Count -and -not $rec.bug) { 'new defects have no [Bug] task' }
      Resolve-Outcome $rec $st $pend
      $out.subtasks += $rec; continue
    }
    $icon = if ($allFails.Count) { '❌' } elseif ($nt -or $pend) { '⚠️' } else { '✅' }
    $msg = "$icon " + $(if ($item.retest) { "Retest of the fix ($Date): $pass of $($mine.Count - $oos) checks pass" } else { "Test results ($($run.target), $Date): $pass of $($mine.Count - $oos) checks pass" })
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
    # own failures and untested checks stay on this task (failedTesting): the comment carries them in the bug-brief format
    $detail = (Format-Checks $ownFails 'Failed checks') + (Format-Checks $ntChecks 'Untested checks')
    $text = if ($detail) { "$msg`n`n$detail" } else { $msg }
    if ($reportFile) { $null = TrySay { Add-TrackerAttachment $st.id $reportFile $text } "post the report on $($st.id)" }
    else { $null = TrySay { Add-TrackerComment $st.id $text } "comment on $($st.id)" }
    Resolve-Outcome $rec $st $pend
  }
  $out.subtasks += $rec
}
$out | ConvertTo-Json -Depth 6 | Out-File $fin -Encoding utf8
"$Code report ($rtype): $docUrl"
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, failed $($_.fail), new defects $([int]$_.newDefects), not tested $($_.notTested), out of scope $([int]$_.outOfScope), pending $($_.pending), bug $($_.bug), $(if ($_.closed) { 'closed' } elseif ($_.failedTesting) { "failed testing$(if ($_.statusFallback) { " (set $($_.statusFallback))" })" } elseif ($_.waitingFor) { "open (waiting for $(@($_.waitingFor) -join ', '))" } else { "open ($($_.keptOpen))" })" }
