<#
pokey.ps1: pokey commands (SKILL.md tester steps 1-6, lead L1-L3). pwsh 7: & <kit>/skills/pokey/pokey.ps1 <verb> [args]
  seat acquire|release|status ...                  memory seat + item claim; acquire -Target <t> [-Role <r>]: + an own login (SEAT_USER)
  seat capacity -Kind <lane> · seat cleanup [-Run <run> | -RunDir <run>] [-DryRun]   parallel seats free RAM allows · seat logins deactivated (a run's, else idle)
  deployed -Mrs <repo>!<iid>,... [-Target <t>,..] [-Detail] [-Json] [-TimeoutSec <deploy.deployedTimeoutSec>]  live on a test env?
  api -Target <t> -As <user> -Method <M> -Path '/...' (or api <M> '/...') [-Body <json>] [-ContentType <type>] [-Save <name | full path> -OutDir <abs dir>]
  finalize -RunDir <run> -Code <code> [-Check] [-FixNames: + notes over their cap fitted] [-NoTracker] [-ExpectChecks <n>] [-Results <file>]   publish; ends EXIT=<n> (a crash too)
  annotate -In <image> -Rect 'x,y,w,h,label' [-Copy]   red boxes on a screenshot
  evidence fetch|index|read-chunk|frames|write-vision|label|verify|tune|feedback|bench|status <link | key> ...   videos -> text index
  retest -RunDir <run> -Task <id> -Code <code> -Mrs <refs>
  prepare -Job <job JSON | file> | -RunDir <run>   L1 selection: run.json, lead-notes.md, Left out; last line RUN <run JSON>
  lead-notes add -RunDir <run> -Code <code> -Text '<question or answer>'   one line under "## Answers (newest last)"
  results patch|hold -RunDir <run> -Code <code> [-Patch '<{set, add, top} JSON>'] [-Results results-retry.json] [-Why <w> -Summary <s> -EnvFix <json>]   the workflow's deltas / held.json
  ui dump|tap|tapid|tapxy|type|clear|key|swipe|openurl|shot|shotmark|wait|log|photo|mic ...   ($env:ANDROID_SERIAL)
  ui login -Target <t> -As <login> [-Serial <phone>] [-Tenant <t>]   types a stored login into the app (qa.userRecipes app.steps)
  user create -Target <t> -Name <login> -Role <role> [-Kind web|api|app] [-As <admin>] [-Tenant <t>] [-Run <run>] [-Seat] · user list -Target <t> · user deactivate -Target <t> -Name <login>
  user auth -Target <t> -Name <login> [-Path <api login path>] [-WebLogin <JSON>] [-Tenant <t>]   that login's own endpoints (userAuth)
In: targets.local.json (logins; user create writes users.<login> + created.<login>, never prints a password), kit.local.json, the run folder. Out: text / JSON (-Json), evidence files.
Exit codes: 0 ok · 1 problem (evidence check, not deployed, publish refused, api HTTP >= 400 / no answer, ui NOT FOUND / TIMEOUT) · 2 usage,
  api NO-USER · 3 seat ALREADY (item taken) · 4 seat still waiting (run it again).
Adapters (adapters/): ui-android (ui, deploys[] laneApk), annotate, deployed-checks (deployed), api-auth, report-html (the styled
  HTML report), ui-ios, media evidence (evidence).
Sections: L31 lanes · L45 report · L165 seat · L314 api · L589 users · L742 login surfaces (parity.json login) · L775 finalize ·
  L1329 results · L1364 retest · L1421 prepare
#>
#Requires -Version 7
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'crafty/lib.ps1')
foreach ($__adapter in Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue) { . $__adapter.FullName }
# ---- lanes: qa.lanes { <lane>: { kind, parallel, followUp, devices } }; unset = one lane web (kind web)
function Get-QaLanes {
  $cfg = Get-KitSetting 'qa.lanes' $null; $o = [ordered]@{}
  if ($cfg) { foreach ($p in (Get-KitProps $cfg)) { $o[$p.Name] = [pscustomobject]@{ name = $p.Name; kind = [string]$(if ($p.Value.kind) { $p.Value.kind } else { $p.Name }) } } }
  if (-not $o.Count) { $o['web'] = [pscustomobject]@{ name = 'web'; kind = 'web' } }
  $o
}
# a lane name (or a configured lane's kind) -> its lane; unknown -> a throw naming the configured lanes
function Resolve-QaLane([string]$Name) {
  $ls = Get-QaLanes
  if ($ls.Contains($Name)) { return $ls[$Name] }
  $byKind = @($ls.Values | Where-Object { $_.kind -eq $Name })[0]; if ($byKind) { return $byKind }
  throw "unknown lane '$Name': configured lanes (kit.local.json qa.lanes) are $(@($ls.Keys) -join ', ')"
}
# ---- report: Markdown (tracker comments, report file)
function TaskLink($id) { if (Get-Command Get-TrackerUrl -ErrorAction SilentlyContinue) { Get-TrackerUrl $id } else { "$id" } }

# SKILL.md "Evidence"; same literal as browser.mjs EVIDENCE_NAME
$script:EvidenceName = '^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2}m?)?|_\d{2}m?)_[a-z0-9]+([-._][a-z0-9]+)*|[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?|jsonl|ndjson)$'
$script:EvidenceExt = '^\.(jpe?g|png|json|jsonl|ndjson|log|csv|txt|pdf|mp4|html|xlsx?)$'   # types finalize publishes

# "F2-T4_02_after-edit.jpeg" -> "After edit"
function Caption($file) {
  if ($file -match '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify)?(_\d{2}m?)?_(.+)\.\w+$') {
    $c = ($Matches[3] -replace '[-_]', ' ').Trim(); $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }
    if (-not $c) { return $file }   # an odd name never crashes
    return $c.Substring(0, 1).ToUpper() + $c.Substring(1) + $v  }
  return $file
}
# phone shots render narrow
function ImgWidth($f) { if ($f -match '\.png$' -or $f -match '(?i)(^|[_-])(app|phone|mobile|emulator)([_.-])|-L\d+_') { 260 } else { 600 } }
# verify = '<status> | <re-test> | <note audit>' (testy.js vJoin)
function VerifyStatus($v) { $s = ([string]$v -split ' \| ', 2)[0].Trim(); if ($s -match '^Note audit' -or @($s -split '\s+').Count -gt 6) { '' } else { $s } }
# verify > 20 words (sentence cap 25): own evidence file
# a fitted note (kitbag.py notes_fit) ends '(full text: <file>)': the content guards read that file, never the cut field
function NoteFull([string]$Dir, $c, [string]$Field) { $t = [string](Get-KitMember $c $Field); $nf = if ($t -match '\(full text: (?<f>[^)\\/]+\.txt)\)$') { "$Dir/evidence/$($Matches.f)" }
  if ($nf -and (Test-Path -LiteralPath $nf)) { [IO.File]::ReadAllText($nf) } else { $t } }
function VerifyFile($Code, $c) { if (@(([string]$c.verify) -split '\s+' | Where-Object { $_ }).Count -gt 20) { "$Code-$(([string]$c.id) -replace '[^A-Za-z0-9-]', '')_verify_retest.txt" } }

function Build-QaReportMd($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl, [hashtable]$Cells) {
  if ($null -eq $Map.files) { $Map = @{ files = @{}; folderLink = $Map.folderLink } }   # no upload map yet (-Check): plain file names, no crash
  function MdEsc($t) { ([string]$t -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
  # gdocs src or link; title = width px (md_to_html)
  function MdImg($f) { $u = if ($Map.files[$f].src) { $Map.files[$f].src } else { $Map.files[$f].link }; "![$(if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+[a-z]?)_') { "$($Matches[1]): " })$(Caption $f)]($(([string]$u) -replace ' ', '%20') `"$(ImgWidth $f)`")" }
  # preview: an api call "<METHOD> <path> -> <status>" first, then the fields whose value the check's notes name, then the first
  # ones (meta, headers skipped) / 3 log lines; -Line: one span (the human doc's row); newlines split the row
  function Peek($f, $c, [switch]$Line) {
    $p = @("$D/shots/$f", "$D/evidence/$f") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $p -or $f -notmatch '\.(json|log|txt)$') { return '' }
    $ln = [Collections.Generic.List[string]]::new(); $max = if ($Line) { 2 } else { 8 }
    if ($f -match '\.json$') {
      $hits = [Collections.Generic.List[string]]::new(); $first = [Collections.Generic.List[string]]::new(); $seen = @{ n = 0 }
      $notes = "$($c.observed) $($c.what_was_done)"
      function Walk($v, $at) {
        if ($seen.n++ -gt 3000 -or ($first.Count -ge $max -and $hits.Count -ge 3)) { return }
        if ($v -is [Collections.IDictionary]) { foreach ($key in $v.Keys) { if ($key -notin 'meta', 'headers') { Walk $v[$key] "$at$(if ($at) { '.' })$key" } } }
        elseif ($v -is [Collections.IList]) { $n = 0; foreach ($x in $v) { if ($n -ge 3) { break }; Walk $x "$at[$n]"; $n++ } }
        else {
          $s = "$v" -replace '\s+', ' '; $one = "$at`: $($s.Substring(0, [math]::Min(60, $s.Length)))"
          if ($first.Count -lt $max) { $first.Add($one) }
          if ($v -isnot [bool] -and $s.Length -ge 3 -and $hits.Count -lt 3 -and $notes.Contains($s)) { $hits.Add($one) }
        }
      }
      $jv = try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
      if ($jv -is [Collections.IDictionary] -and $jv.request -is [Collections.IDictionary] -and $jv.response -is [Collections.IDictionary]) {   # pokey.ps1 api
        # a relative url or only request.path: PathAndQuery is $null (finalize crashed on .Substring)
        $u = [string]$(if ($jv.request.url) { $jv.request.url } else { $jv.request.path }); $path = "$(try { ([uri]$u).PathAndQuery } catch { })"; if (-not $path) { $path = $u }
        $ln.Add("$($jv.request.method) $($path.Substring(0, [math]::Min(80, $path.Length))) -> $($jv.response.status)"); Walk $jv.response.body 'body'
      } else { Walk $jv '' }
      foreach ($x in @(@($hits) + @($first | Where-Object { $_ -notin $hits }) | Select-Object -First $(if ($Line -and $hits.Count) { $hits.Count } else { $max }))) { $ln.Add($x) }
    } else { @(Get-Content -LiteralPath $p | Where-Object { $_.Trim() } | Select-Object -Last $(if ($Line) { 1 } else { 3 })) | ForEach-Object { $ln.Add($_.Substring(0, [math]::Min(120, $_.Length))) } }
    if ($Line) { return '`' + ((@($ln) -join ' · ') -replace '[`|]', "'") + '`' }
    (@($ln) | ForEach-Object { '`' + ($_ -replace '[`|]', "'") + '`' }) -join '<br>'
  }
  function Lnk($f) { if ($Map.files[$f]) { "[$f]($(([string]$Map.files[$f].link) -replace ' ', '%20'))" } else { $f } }
  function VerifyMd($c) { $vf = VerifyFile $Code $c; if ($vf -and $Map.files[$vf]) { "$(if ($s = VerifyStatus $c.verify) { "$s · " })full text: $(Lnk $vf)" } else { MdEsc ([string]$c.verify -replace ' \| ', ' · ') } }
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
  # name + MR list broke the prose limit
  if (@($Item.subtasks).Count) { $o.Add("| Tasks | $((@($Item.subtasks) | ForEach-Object { $mrN = @(@($_.mrs) | ForEach-Object { "$_" -split ',' } | Where-Object { $_.Trim() }).Count; "[$(MdEsc $_.id)]($(TaskLink $_.id))$(if ($mrN) { " · $mrN MR$(if ($mrN -ne 1) { 's' })" })" }) -join '<br>') |") }
  if (@($Run.envLines).Count) { $o.Add("| Environment | $((@($Run.envLines) | ForEach-Object { MdEsc $_ }) -join '<br>') |") }
  $o.Add("| Tested by | $(MdEsc $Tester) with Claude Code · $Date |")
  $o.Add("| Evidence | $(MdEsc $Map.folderLink) · $(@($Map.files.Keys).Count) files |"); $o.Add('')
  $o.Add('## Tasks'); $o.Add(''); $o.Add('Result per task:'); $o.Add(''); $o.Add('| Task | Pass | Fail | Not tested | Status |'); $o.Add('|---|---|---|---|---|')
  foreach ($st in @(if (@($Item.subtasks).Count) { @($Item.subtasks) } else { [pscustomobject]@{ id = ''; name = $Item.title } })) {
    $tc = @($checks | Where-Object { -not $st.id -or $_.subtask_id -eq $st.id -or @($Item.subtasks).Count -eq 1 }); $tn = @{}; foreach ($k in $label.Keys) { $tn[$k] = @($tc | Where-Object result -eq $k).Count }
    $tk = @($tc | Where-Object { $_.result -eq 'FAIL' -and "$($_.knownBug)".Trim() }).Count   # known defects: FAIL, not the task's own
    $o.Add("| $(MdEsc $st.name) | $($tn.PASS + $tn.PASS_WITH_NOTE) | $($tn.FAIL) | $($tn.NOT_TESTED) | $(if ($tn.FAIL -gt $tk) { 'failed' } elseif ($tk -and -not $tn.NOT_TESTED -and -not $tn.PENDING) { "passed ($tk known defect$(if ($tk -ne 1) { 's' }))" } elseif ($tn.NOT_TESTED) { 'partly tested' } elseif ($tn.PENDING) { 'pending' } else { 'passed' }) |")
  }
  $o.Add(''); $o.Add('## Results'); $o.Add(''); $o.Add('Each check, its evidence inline:'); $o.Add(''); $o.Add('| Check | Result | Observed | Evidence |'); $o.Add('|---|---|---|---|')
  foreach ($c in $checks) {    $saw = if ($c.result -eq 'FAIL') { '[details](#' + ("$($c.id) — $($c.screen)".ToLower() -replace '[^\w\- ]', '' -replace ' ', '-') + ')' } else { MdEsc $c.observed }
    $evc = (@($c.evidence | Where-Object { $_ }) | ForEach-Object { if ($_ -match '\.(png|jpe?g)$' -and $Map.files[$_]) { MdImg $_ } elseif ($pk = Peek $_ $c) { "$pk<br>[full $(([IO.Path]::GetExtension($_)).TrimStart('.').ToLower() -replace '^$', 'file')]($(([string]$Map.files[$_].link) -replace ' ', '%20'))" } else { "file: $(Lnk $_)" } }) -join '<br>'
    $vt = @(([string]$c.verify -replace ' \| ', ' · ') -split '\s+' | Where-Object { $_ }); $rt = if ($vt.Count) { " (re-test: $(MdEsc (($vt | Select-Object -First 20) -join ' '))$(if ($vt.Count -gt 20) { ' …' }))" }
    $kb = "$($c.knownBug)".Trim(); $kn = if ($kb -and $c.result -eq 'FAIL') { " (known: [$(MdEsc $kb)]($(TaskLink $kb)))" } else { '' }   # FAIL (known: <task id>)
    $o.Add("| **$(MdEsc $c.id)** $(MdEsc $c.screen) | $($label[[string]$c.result])$kn$rt | $saw | $evc |")
    if ($null -ne $Cells) {   # the human doc's row (devtools.py _row_cells: by id, case or screen); one line per file
      $hev = (@($c.evidence | Where-Object { $_ }) | ForEach-Object { if ($_ -match '\.(png|jpe?g)$' -and $Map.files[$_]) { MdImg $_ } elseif (($pk = Peek $_ $c -Line) -and $Map.files[$_]) { "$pk [$(Caption $_)]($(([string]$Map.files[$_].link) -replace ' ', '%20'))" } else { "file: $(Lnk $_)" } }) -join '<br>'
      $Cells[[string]$c.id] = @{ result = ([string]$c.result -replace '_', ' ') + $(if ($kn) { " (known: $kb)" }); evidence = $hev; case = "$($c.case)"; screen = "$($c.screen)"
        why = if ([string]$c.result -notin 'PASS', 'PASS_WITH_NOTE', 'FAIL') { (("$($c.observed)" -split ' vs ', 2)[0]).Trim() } else { '' } } }   # a later run's NOT TESTED row names why
  }
  $o.Add(''); $o.Add('## Failures in detail')   # every report section always (templates.md qa-report): n/a — <why> when empty
  if (-not $fails.Count) { $o.Add(''); $o.Add('n/a — no check failed') }
  if ($fails.Count) {
    foreach ($c in $fails) {
      $o.Add(''); $o.Add("### $($c.id) — $($c.screen)"); $o.Add("**Steps:** $($c.what_was_done)"); $o.Add(''); $o.Add("**Saw:** $($c.observed)")
      if (($kb = "$($c.knownBug)".Trim())) { $o.Add(''); $o.Add("**Known defect:** tracked in [$kb]($(TaskLink $kb)); no new [Bug]") }
      if ($c.verify) { $o.Add(''); $o.Add("**Independent re-test:** $(VerifyMd $c)") }
    }
  }
  $vNotes = @($checks | Where-Object { $_.result -ne 'FAIL' -and $_.verify -and [string]$_.verify -ne (VerifyStatus $_.verify) })   # a FAIL's verify is in its detail
  $fnd = @($Res.findings | Where-Object { $_ })   # @($null).Count is 1: an absent list printed a bare '- '
  $o.Add(''); $o.Add('## Notes'); $o.Add(''); if (-not ($fnd.Count -or $vNotes.Count)) { $o.Add('n/a — no re-test note or finding') }
  foreach ($c in $vNotes) { $o.Add("- **$(MdEsc $c.id)** re-test / note audit: $(VerifyMd $c)") }   # observed is in Results already
  foreach ($f in $fnd) { $o.Add("- $(MdEsc $f)") }
  $setup = @($Res.setup_changes) + @($Res.data_created) | Where-Object { $_ }
  $o.Add(''); $o.Add('## Setup changes and test data'); $o.Add(''); if ($setup.Count) { foreach ($s in $setup) { $o.Add("- $(MdEsc $s)") } } else { $o.Add('n/a — no setup change, no test data created') }
  $all = @($Map.files.Keys | Sort-Object)
  $o.Add(''); $o.Add('## Evidence index'); $o.Add(''); if (-not $all.Count) { $o.Add('n/a — no evidence file hosted') }
  if ($all.Count) {
    $o.Add('| File | Check | Shows |'); $o.Add('|---|---|---|')
    foreach ($f in $all) { $chk = if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+)') { $Matches[1] } else { '' }; $o.Add("| $(Lnk $f) | $chk | $(MdEsc (Caption $f)) |") }
  }
  $o.Add(''); $o.Add('_Generated by the Claude Code QA kit. Defects are always FAIL; every FAIL is re-tested independently before a bug task is raised._')
  $o -join "`n"
}

# ---- seat: item claim (first claimer owns <run>/<code>) + a gate memory turn
function Invoke-Seat {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'release', 'status', 'capacity', 'cleanup')][string]$Action,
  [string]$Agent, [string]$Kind = '',   # a qa.lanes lane name or kind; '' = the first lane
  [string]$RunDir, [Alias('Item')][string]$Code, [string]$Owner = 'w1',
  [int]$WaitMinutes = 8, [double]$KeepFreeGB = 0,   # 0 = the gate's floor (gate.keepFreeGB)
  [string]$Target, [string]$Role,       # acquire: an own login on that target (qa.userRecipes seats), role over seats.roles.<lane kind>
  [string]$Run, [switch]$DryRun          # cleanup: that run's seat logins (else the idle ones)
)
$ErrorActionPreference = 'Stop'
$dir = Get-KitPath qa-seats; $seats = Join-Path $dir 'seats'; $claims = Join-Path $dir 'claims'
New-Item -ItemType Directory -Force $seats, $claims | Out-Null
$ln = if ($Kind) { Resolve-QaLane $Kind } else { @((Get-QaLanes).Values)[0] }; $Kind = $ln.name
# seatGB by lane name, then lane kind; browser kinds (web, desktop) the learned web seat, no-browser kinds 0.4
$need = [double](Get-KitSetting "qa.seatGB.$($ln.name)" (Get-KitSetting "qa.seatGB.$($ln.kind)" $(if ($ln.kind -in 'web', 'desktop') { Get-KitParam 'qa.seatGB' -Context web } else { 0.4 })))
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-qa-seats')
function Locked([scriptblock]$b) {
  $got = $false
  try { $got = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed holder hands it over
  try { & $b } finally { if ($got) { $mutex.ReleaseMutex() } }
}
function Safe($s) { $s -replace '[^\w.-]', '_' }
# README "Leases"; no holder fields: 6 h
function LeaseLive($o, [string]$file) {
  if ($null -eq $o.PSObject.Members['holderPid']) { return ((Get-Date) - [datetime]$o.since).TotalHours -lt 6 }
  $v = [pscustomobject]@{ agent = "$($o.lease)"; holderPid = $o.holderPid; holderStart = $o.holderStart; seen = $o.seen }
  $live = Update-KitLease $v; $o | Add-Member -Force seen $v.seen; Write-KitAtomic $file ($o | ConvertTo-Json); $live
}
function Read-Seat($p) { try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null } }   # half-written: skipped
function Seats { @(Get-ChildItem $seats -Filter *.json | ForEach-Object { $o = Read-Seat $_.FullName; if (-not $o) { return }; if (LeaseLive $o $_.FullName) { $o } else { Remove-Item $_.FullName -Force } }) }
$lease = (($Agent -split ':', 2)[-1] -split '@')[0]   # item code: Test-KitLive matches step labels, board
# seat logins (qa.userRecipes.<r>.seats): an own login per parallel tester, made and removed only through user create / deactivate
$runName = if ($Run) { $Run } elseif ($RunDir) { Split-Path $RunDir -Leaf } elseif ($env:KIT_RUN) { $env:KIT_RUN } else { 'adhoc' }
$marks = Join-Path $dir 'logins'   # <target>__<login>: its last release (idle clock)
function Get-SeatRecipe([string]$Tg) { $rc = try { Get-UserRecipe $Tg } catch { $null }; if ($rc -and $rc.seats -is [Collections.IDictionary]) { $rc } }
function Invoke-SeatPokey { try { $global:LASTEXITCODE = 0; $o = @(& $KitCmd.qa @args *>&1 | ForEach-Object { "$_" }); [pscustomobject]@{ code = $LASTEXITCODE; out = $o } } catch { [pscustomobject]@{ code = 1; out = @("$($_.Exception.Message)") } } }
# under Locked, no API call: this run's free login of the role, else a new name to create (held by the caller's seat file) up to seats.max, else @{ why }
function Get-SeatLogin {
  $rc = Get-SeatRecipe $Target; if (-not $rc) { return @{ why = 'no qa.userRecipes seats for this target' } }
  $sc = $rc.seats; $tt = (Get-PokeyTargets).data.targets[$Target]
  if (-not $tt) { return @{ why = "unknown target $Target" } }
  if (Test-ProductionTarget $Target $tt) { return @{ why = 'production target: never seat logins' } }
  if ($sc.targets -and $Target -notmatch [string]$sc.targets) { return @{ why = 'target not in seats.targets' } }
  $ro = if ($Role) { $Role } elseif ($sc.roles -and $sc.roles[$ln.name]) { [string]$sc.roles[$ln.name] } elseif ($sc.roles -and $sc.roles[$ln.kind]) { [string]$sc.roles[$ln.kind] } else { 'admin' }
  if (-not $rc.roles -or -not $rc.roles.Contains($ro)) { return @{ why = "role $ro is not in recipe $($rc.name) roles" } }
  $made = if ($tt.created -is [Collections.IDictionary]) { $tt.created } else { @{} }
  $held = @(Seats | Where-Object { $_.target -eq $Target -and $_.user } | ForEach-Object { "$($_.user)" })
  $open = @($made.Keys | Where-Object { $made[$_].seat -and -not $made[$_].deactivated })
  $free = @($open | Where-Object { $made[$_].run -eq $runName -and $made[$_].role -eq $ro -and -not $made[$_].broken -and $_ -notin $held -and $tt.users -is [Collections.IDictionary] -and $tt.users.Contains($_) })
  if ($free) { return @{ user = $free[0]; role = $ro; state = 'reused' } }
  $max = if ($null -ne $sc.max) { [int]$sc.max } else { 4 }
  $pending = @($held | Where-Object { -not $made.Contains($_) })   # names another acquire is creating now
  if ($open.Count + $pending.Count -ge $max) { return @{ why = "seats.max $max reached on $Target" } }
  $tag = $runName.ToLower() -replace '[^a-z0-9]', ''; if ($tag.Length -gt 16) { $tag = $tag.Substring($tag.Length - 16) }
  for ($n = 1; ; $n++) { $nm = Expand-UserTemplate $(if ($sc.name) { [string]$sc.name } else { 'qa-{run}-s{n}' }) @{ run = $tag; n = $n; role = $ro }; if (-not $made.Contains($nm) -and $nm -notin $pending -and -not ($tt.users -is [Collections.IDictionary] -and $tt.users.Contains($nm))) { break } }
  @{ user = $nm; role = $ro; state = 'created'; create = $true; as = [string]$sc.as }
}
# outside the lock (API calls): user create; a failure -> @{ why } (a login that cannot sign in is deactivated)
function New-SeatLogin($s) {
  $adm = if ($s.as) { @('-As', $s.as) } else { @() }   # the admin login that makes and removes seats ('' = the target's default)
  $r = Invoke-SeatPokey user create -Target $Target -Name $s.user -Role $s.role -Kind $ln.kind -Run $runName -Seat @adm
  if (-not $r.code) { return $s }
  if ("$($r.out)" -match 'LOGIN-FAIL') { $null = Invoke-SeatPokey user deactivate -Target $Target -Name $s.user @adm }
  @{ why = "user create $($s.user) failed: $(@($r.out | Where-Object { $_ })[-1])" }
}
function Format-SeatLogin($s) { if ($s.user) { "SEAT_USER $($s.user) (role $($s.role), $($s.state)) on ${Target}: your own login: api -As $($s.user) · session({ as: '$($s.user)' }) · ui login -As $($s.user); never deactivate it" } else { "SEAT_USER shared ($($s.why)): use the target's default login" } }

switch ($Action) {
  'status' {
    $s = Locked { Seats }
    "free RAM $(Get-FreeGB) GB; $($s.Count) seat(s): $(($s | ForEach-Object { "$($_.agent) ($($_.kind)$(if ($_.user) { ", login $($_.user)" }))" }) -join ', ')"
    Get-ChildItem $claims -Filter *.json | ForEach-Object { $c = Read-Seat $_.FullName; if ($c) { "claim: $($c.run)/$($c.code) by $($c.owner) since $($c.since)" } }
  }
  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    $rf = Join-Path $seats "$(Safe $Agent).json"; $held = if (Test-Path -LiteralPath $rf) { Read-Seat $rf }
    if ($held.since -and $held.kind) { Add-KitParamObs 'qa.packageMinutes' ((Get-Date) - [datetime]$held.since).TotalMinutes "$($held.kind)" }   # a package's time per lane: supervise QA SLOW
    if ($held.user) { New-Item -ItemType Directory -Force $marks | Out-Null; (Get-KitStamp) | Set-Content -LiteralPath (Join-Path $marks "$(Safe $held.target)__$(Safe $held.user)") }
    Remove-Item $rf -Force -ErrorAction SilentlyContinue
    "seat released: $Agent$(if ($held.user) { " (login $($held.user) free for this run; seat cleanup deactivates it)" })"
  }
  'capacity' {
    $fg = Get-FreeGB; $kf = if ($KeepFreeGB) { $KeepFreeGB } else { Get-KitKeepFreeGB }
    "CAPACITY $Kind $([math]::Max(1, [math]::Floor(($fg - $kf) / [math]::Max(0.1, $need)))) (free RAM $fg GB, keep $kf GB, ~$need GB a seat)"
  }
  'cleanup' {
    $byRun = [bool]($Run -or $RunDir)
    # pick under the lock and hold each pick with a seat file (no acquire reuses it), deactivate outside it (API calls)
    $picks = Locked {
      $tf = Get-PokeyTargets
      foreach ($tn in @($tf.data.targets.Keys)) {
        $tt = $tf.data.targets[$tn]; $rc = Get-SeatRecipe $tn; if (-not $rc -or $tt.created -isnot [Collections.IDictionary]) { continue }
        $held = @(Seats | Where-Object { $_.target -eq $tn -and $_.user } | ForEach-Object { "$($_.user)" })
        $idle = if ($null -ne $rc.seats.idleMinutes) { [double]$rc.seats.idleMinutes } else { 60 }
        foreach ($nm in @($tt.created.Keys)) {
          $m = $tt.created[$nm]; if (-not $m.seat -or $m.deactivated -or $nm -in $held) { continue }
          $mk = Join-Path $marks "$(Safe $tn)__$(Safe $nm)"
          if ($byRun) { if ($m.run -ne $runName) { continue } }
          else { $last = if (Test-Path -LiteralPath $mk) { (Get-Item -LiteralPath $mk).LastWriteTime } else { [datetime]$m.at }; if (((Get-Date) - $last).TotalMinutes -lt $idle) { continue } }
          $hf = Join-Path $seats "cleanup__$(Safe $tn)__$(Safe $nm).json"
          if (-not $DryRun) { ([ordered]@{ agent = "cleanup:$nm"; lease = 'cleanup'; kind = 'cleanup'; need = 0; since = (Get-KitStamp); target = $tn; user = $nm } + (Get-KitHolder)) | ConvertTo-Json | ForEach-Object { Write-KitAtomic $hf $_ } }
          [pscustomobject]@{ target = $tn; user = $nm; run = $m.run; mark = $mk; hold = $hf; as = [string]$rc.seats.as }
        }
      }
    }
    $did = foreach ($p in @($picks)) {
      if ($DryRun) { "would deactivate seat login $($p.user) on $($p.target) (run $($p.run))"; continue }
      $adm = if ($p.as) { @('-As', $p.as) } else { @() }
      $r = Invoke-SeatPokey user deactivate -Target $p.target -Name $p.user @adm
      if ($r.code) { "FAILED to deactivate seat login $($p.user) on $($p.target): $(@($r.out | Where-Object { $_ })[-1]) (kept; the next cleanup retries)" } else { "deactivated seat login $($p.user) on $($p.target) (run $($p.run))"; Remove-Item -LiteralPath $p.mark -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $p.hold -ErrorAction SilentlyContinue
    }
    if ($did) { $did } else { "seat cleanup: no seat login to deactivate$(if ($byRun) { " for run $runName" })" }
  }
  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    if ($RunDir -and $Code) {
      $run = Split-Path $RunDir -Leaf
      $cf = Join-Path $claims "$(Safe $run)__$(Safe $Code).json"
      $verdict = Locked {
        if (Test-Path (Join-Path $RunDir "$Code/finalize.json")) { return "ALREADY: $Code was finished and published" }
        if (Test-Path (Join-Path $RunDir "$Code/held.json")) { return "ALREADY: $Code was tested; results held for the lead to publish" }
        $c = if (Test-Path $cf) { Read-Seat $cf }
        if ($c -and $c.owner -ne $Owner -and (LeaseLive $c $cf)) { return "ALREADY: $Code is being tested by worker $($c.owner)" }
        ([ordered]@{ run = $run; code = $Code; owner = $Owner; since = (Get-KitStamp); lease = $Agent } + (Get-KitHolder)) | ConvertTo-Json | ForEach-Object { Write-KitAtomic $cf $_ }
        $null
      }
      if ($verdict) { $verdict; exit 3 }
    }
    $sf = Join-Path $seats "$(Safe $Agent).json"
    if (Test-Path $sf) { $old = Read-Seat $sf; "seat already held: $Agent"; if ($old.target) { $Target = $old.target; Format-SeatLogin @{ user = $old.user; role = $old.role; state = 'held'; why = $old.why } }; exit 0 }
    # seats < 3 min old (browser starting) count too
    $fresh = [double](@(Locked { Seats }) | Where-Object { ((Get-Date) - [datetime]$_.since).TotalMinutes -lt 3 } | Measure-Object need -Sum).Sum
    $ga = @('-Dir', $dir, '-Cmd', 'exit 0 #qa-seat', '-NeedGB', ($need + $fresh), '-WaitMinutes', $WaitMinutes); if ($KeepFreeGB) { $ga += '-KeepFreeGB', $KeepFreeGB }
    # first queue time across exit-4 retries (a retry comes within minutes; an older marker is a dropped wait)
    $wq = "$sf.since"; if (-not (Test-Path -LiteralPath $wq) -or ((Get-Date) - (Get-Item -LiteralPath $wq).LastWriteTime).TotalMinutes -gt $WaitMinutes + 10) { (Get-KitStamp) | Set-Content -LiteralPath $wq }
    $env:KIT_GATE_SINCE = "$(Get-Content -LiteralPath $wq -TotalCount 1)"; try { $said = @(& $KitCmd.dev gate @ga *>&1 | ForEach-Object { "$_" }) } finally { Remove-Item Env:KIT_GATE_SINCE -ErrorAction SilentlyContinue }
    if (-not $LASTEXITCODE) { Remove-Item -LiteralPath $wq -ErrorAction SilentlyContinue } else { (Get-Item -LiteralPath $wq).LastWriteTime = Get-Date }
    if ($LASTEXITCODE) { "STILL WAITING (no memory turn within $WaitMinutes min$(@($said | Where-Object { $_ -match 'waiting|queued' } | ForEach-Object { ": $_" })[-1])): run the same command again"; exit 4 }
    $rec = [ordered]@{ agent = $Agent; lease = $lease; kind = $Kind; need = $need; since = (Get-KitStamp) } + (Get-KitHolder)
    # the login is picked and the seat file written under one lock: two testers never get the same login
    $su = Locked { $s = if ($Target) { Get-SeatLogin }; if ($s) { $rec.target = $Target; $rec.user = $s.user; $rec.role = $s.role; $rec.why = $s.why }; $rec | ConvertTo-Json | ForEach-Object { Write-KitAtomic $sf $_ }; $s }
    if ($su.create) { $su = New-SeatLogin $su; if (-not $su.user) { $rec.user = $null; $rec.why = $su.why; Locked { $rec | ConvertTo-Json | ForEach-Object { Write-KitAtomic $sf $_ } } } }
    "seat taken: $Agent ($Kind, ~$need GB); free RAM $(Get-FreeGB) GB"
    if ($su) { Format-SeatLogin $su }
  }
}
}
# ---- api: a target's API as a test user
# '<target>-<bird>' = that lane of a local env (envy.ps1 envs -Json; -falcon = the base target; old <target><k> still accepted): the base target, its lane-1 URL ports moved to lane k's
# envy.ps1 envs -Json (env, group, lane, ports): cached by kit.local.json + envy.ps1 times (a pwsh start per api call was 72/h, K48)
function Get-KitEnvyLanes {
  $envy = Join-Path $KitConf.Kit 'skills/envy/envy.ps1'; if (-not (Test-Path -LiteralPath $envy)) { return @() }
  $cf = Join-Path (Get-KitPath cache -Create) 'envy-envs.json'; $ck = "$((Get-Item -LiteralPath $KitConf.ConfigFile -ErrorAction SilentlyContinue).LastWriteTimeUtc.Ticks)|$((Get-Item -LiteralPath $envy).LastWriteTimeUtc.Ticks)"
  $c0 = try { Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json } catch { $null }
  if ($c0 -and $c0.key -eq $ck) { return @($c0.lanes) }
  $r = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $envy, 'envs', '-Json') 60; $l0 = try { @($r.out | ConvertFrom-Json) } catch { @() }
  if ($l0.Count) { Write-KitAtomic $cf (@{ key = $ck; lanes = $l0 } | ConvertTo-Json -Depth 10) }; $l0
}
# the local env a target runs on: its web / api URL ports are a lane-1 env's ports ('' = a deployed env)
function Get-TargetLocalEnv([string]$Name) {
  $tc = try { (Get-Content (Get-TargetsFile) -Raw | ConvertFrom-Json).targets } catch { $null }; $t = Get-KitMember $tc $Name
  $urls = "$((Get-KitMember $t 'web')) $((Get-KitMember $t 'api'))"; if (-not $urls.Trim()) { return '' }
  "$(@(Get-KitEnvyLanes | Where-Object { $_.lane -eq 1 -and @((Get-KitProps $_.ports) | Where-Object { $urls -match ":$($_.Value)(?!\d)" }).Count })[0].env)"
}
# '<target>-<bird>' / '<target><k>' -> @{ base; k } when that base target exists, else $null
function Get-LaneBase($targets, [string]$name) {
  $bk = 0; if ($name -match '^(?<b>.+)-(?<bd>[a-z]+)$') { $bk = @(1..40 | Where-Object { "$(Get-KitBirdName $_)" -ieq $Matches.bd })[0] }
  if ($bk) { $tb = $Matches.b; $k = [int]$bk } elseif ($name -match '^(?<b>.+?)(?<k>\d+)$') { $tb = $Matches.b; $k = [int]$Matches.k } else { return $null }
  if (Get-KitMember $targets $tb) { @{ base = $tb; k = $k } }
}
# an env, group or lane name (envy.ps1 envs: rm-osprey, rm / rm-local, lane-<n> when one group has it) -> the target whose URLs hit that group's lane-1 ports, else $null
function Get-EnvTarget($targets, [string]$Name) {
  $lanes = @(Get-KitEnvyLanes); $n = $Name.ToLower()
  $grp = @($lanes | Where-Object { "$($_.env)" -eq $n -or "$($_.group)" -eq $n -or "$($_.group)-local" -eq $n } | ForEach-Object { "$($_.group)" } | Select-Object -Unique)
  if (-not $grp.Count -and $n -match '^lane-0*(\d+)$') { $ln0 = [int]$Matches[1]; $grp = @($lanes | Where-Object { $_.lane -eq $ln0 } | ForEach-Object { "$($_.group)" } | Select-Object -Unique) }
  if ($grp.Count -ne 1) { return $null }
  $one = @($lanes | Where-Object { "$($_.group)" -eq $grp[0] -and $_.lane -eq 1 })[0]; if (-not $one) { return $null }
  foreach ($tn in @($targets.Keys)) { $urls = "$(Get-KitMember $targets[$tn] 'web') $(Get-KitMember $targets[$tn] 'api')"; if (@((Get-KitProps $one.ports) | Where-Object { $urls -match ":$($_.Value)(?!\d)" }).Count) { return $tn } }
  $null
}
function Get-LaneTarget($cfg, [string]$name) {
  $envy = Join-Path $KitConf.Kit 'skills/envy/envy.ps1'
  $lb = Get-LaneBase $cfg.targets $name; if (-not $lb -or -not (Test-Path -LiteralPath $envy)) { return $null }; $tb = $lb.base; $k = $lb.k
  $base = (Get-KitMember $cfg.targets $tb); if ($k -eq 1) { return $base }; $urls = [string](@($base.web, $base.api) -join ' ')
  $lanes = Get-KitEnvyLanes
  foreach ($g in @($lanes | Where-Object { $_.lane -eq 1 })) {
    $one = @((Get-KitProps $g.ports) | Where-Object { $urls -match ":$($_.Value)(?!\d)" }); $lk = @($lanes | Where-Object { $_.group -eq $g.group -and $_.lane -eq $k })[0]
    if (-not $one.Count -or -not $lk) { continue }
    $kd = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { @{ DateKind = 'String' } } else { @{} }; $t = $base | ConvertTo-Json -Depth 10 | ConvertFrom-Json @kd
    foreach ($f in 'web', 'api') { if ((Get-KitMember $t $f)) { foreach ($p in $one) { Set-KitMember $t $f ([regex]::Replace([string](Get-KitMember $t $f), ":$($p.Value)(?!\d)", ":$((Get-KitMember $lk.ports ($p.Name)))")) } } }
    return $t
  }
  $null
}
# a target by name (api, ui login, user): an entry with its own URLs as is; a lane name (<target>-<bird> / <target><k>) = the base
# target on that lane's ports with the base's logins plus a logins-only lane entry's own (envfix-phone, envfix-local)
function Resolve-PokeyTarget($targets, [string]$Name) {
  $own = Get-KitMember $targets $Name; if ($own -and ((Get-KitMember $own 'api') -or (Get-KitMember $own 'web'))) { return $own }
  $lt = Get-LaneTarget ([pscustomobject]@{ targets = $targets }) $Name; if (-not $lt) { return $own }
  $kd = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { @{ DateKind = 'String' } } else { @{} }
  $lt = $lt | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable @kd; if ($own) { foreach ($lk in 'defaultUser', 'defaultTenant') { if ($null -ne (Get-KitMember $own $lk)) { $lt[$lk] = Get-KitMember $own $lk } } }
  # users / created: the base's (a lane DB is a copy of the same seed) + the lane entry's own, which win on a clash
  foreach ($lk in 'users', 'created') { $mg = [ordered]@{}; foreach ($src in @($lt[$lk], $(if ($own) { Get-KitMember $own $lk }))) { if ($src -is [Collections.IDictionary]) { foreach ($sk in @($src.Keys)) { $mg[$sk] = $src[$sk] } } elseif ($null -ne $src) { foreach ($p in @(Get-KitProps $src)) { $mg[$p.Name] = $p.Value } } }; $lt[$lk] = $mg }
  # user / ui login read .Keys (hashtable targets); api reads members
  if ($targets -is [Collections.IDictionary]) { $lt } else { $lt | ConvertTo-Json -Depth 20 | ConvertFrom-Json @kd }
}
# the user when -As is not given: target defaultUser, kit api.defaultUser, the target's only user; several and none chosen = $null
function Resolve-ApiUser($t) {
  $names = @((Get-KitProps $t.users).Name | Where-Object { $cm = Get-KitMember $t.created $_; -not ($cm -and $cm.seat) })   # a seat login never becomes the default
  foreach ($d in @([string]$t.defaultUser, [string](Get-KitSetting 'api.defaultUser' ''))) { if ($d) { return $d } }
  if ($names.Count -eq 1) { return $names[0] }
  if (-not $names.Count) { return '' }
  $null
}
# auth.preset (built-in field sets) under the target's own auth fields
$script:ApiAuthPresets = @{
  oauth2 = @{ type = 'login'; contentType = 'form'; tokenField = 'access_token'; refreshField = 'refresh_token' }
  oidc   = @{ type = 'login'; tokenField = 'id_token' }
}
function Resolve-ApiAuth($a) {
  $o = [ordered]@{}
  $pn = [string]$a.preset
  if ($pn) { $p = $script:ApiAuthPresets[$pn]; if (-not $p) { throw "auth.preset '$pn' unknown (built in: $(@($script:ApiAuthPresets.Keys | Sort-Object) -join ', '))" }; foreach ($k in $p.Keys) { $o[$k] = $p[$k] } }
  if ($a) { foreach ($p in (Get-KitProps $a)) { if ($null -ne $p.Value -and "$($p.Value)" -ne '') { $o[$p.Name] = $p.Value } } }
  [pscustomobject]$o
}
# the token in a login answer: auth.tokenField, else kit api.tokenFields in order ([] = none); a bare string answer is the token
function Get-ApiLoginToken($a, [string]$Content) {
  $j = try { $Content | ConvertFrom-Json -ErrorAction Stop } catch { $null }
  if ($j -is [string]) { return $j }
  if ($null -eq $j) { $s = "$Content".Trim(); if ($s -and $s -notmatch '[\s<{]') { return $s }; return $null }
  $fields = @(if ($a.tokenField) { [string]$a.tokenField } else { @(Get-KitSetting 'api.tokenFields' @()) | Where-Object { $_ } })
  if (-not $fields.Count) { throw "the login answer is JSON but no token field is set: targets.local.json auth.tokenField or auth.preset ($(@($script:ApiAuthPresets.Keys | Sort-Object) -join ', ')), or kit.local.json api.tokenFields (answer fields: $(@((Get-KitProps $j).Name | Select-Object -First 12) -join ', '))" }
  foreach ($f in $fields) { $v = $j; foreach ($k in $f.Split('.')) { $v = (Get-KitMember $v $k) }; if ($v) { return [string]$v } }
  $null
}
function Invoke-Api {
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory, Position = 0)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = '',                 # '' = Resolve-ApiUser
  [string]$Tenant = $null,
  [string]$Save = $null,            # without .json
  [string]$OutDir = $null,          # default: <runtime>/work/evidence
  [hashtable]$Headers = @{},
  [string]$ContentType = 'application/json',
  [Alias('TimeoutSeconds')][int]$TimeoutSec = 180,
  [Parameter(Position = 1)][string]$PathAfterMethod,   # api GET /x: the habit of curl
  [switch]$Anonymous                # no login, no auth header: a public endpoint as a visitor sees it
)
$ErrorActionPreference = 'Stop'
if ($PathAfterMethod -and $Path -match '^(GET|POST|PUT|PATCH|DELETE|HEAD)$') { $Method, $Path = $Path, $PathAfterMethod; $PSBoundParameters.Method = $Method; $PSBoundParameters.Path = $Path; $null = $PSBoundParameters.Remove('PathAfterMethod') }
elseif ($PathAfterMethod) { throw "a second positional '$PathAfterMethod': use -Method <M> -Path '/...'" }
# Git Bash /d/x -> D:/x (else \d\x on the current drive)
$OutDir = $OutDir -replace '^/([A-Za-z])/', '$1:/'; $Save = $Save -replace '^/([A-Za-z])/', '$1:/'
# a '\b' or '\a' in the caller's string arrives as a control character
if ($Save -match '[\x00-\x1f]') { throw "-Save '$($Save -replace '[\x00-\x1f]', '?')' holds a control character (shown as ?): an escape like \b or \a in the caller's string; pass a plain name such as CODE-T1_01_post" }
# a full file path (drive or UNC): its folder is -OutDir, its name -Save
$saveIn = $Save
if ($Save -match '^([A-Za-z]:[\\/]|\\\\).*[^\\/]$') {
  if ($OutDir) { throw "-Save '$Save' is a full path and -OutDir is set too: give the folder once" }
  $OutDir = Split-Path $Save -Parent; $Save = Split-Path $Save -Leaf
}
$Save = $Save -replace '(?i)\.json$', ''
if ($saveIn -and $Save -notmatch '^[^\\/:*?"<>|]+$') { throw "-Save '$saveIn' is not a file name (none of \ / : * ? `" < > |, not empty): a name, or a full file path; the folder goes in -OutDir" }
# a local auth-kind hook gets the cleaned values
if ($saveIn) { $PSBoundParameters['Save'] = $Save }; if ($OutDir) { $PSBoundParameters['OutDir'] = $OutDir }
# a bound hashtable became a relative folder
if ($OutDir -and -not [IO.Path]::IsPathRooted($OutDir)) { throw "-OutDir must be an absolute folder path, got '$OutDir' (a variable holding an object? PowerShell names are case-insensitive: `$o is `$O)" }
# undo Git Bash's '/api/x' -> Git path rewrite
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $p0 = $Path; $Path = '/' + ($Matches.rest -replace '\\', '/'); Write-KitLog calls msys-path @{ from = $p0; to = $Path } }   # the calls log has the raw arg
$cfgFile = Get-TargetsFile
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - run bossy.ps1 setup -WriteLocal, then fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
# a QA run pins its targets (KIT_QA_TARGETS)
$pin = @("$env:KIT_QA_TARGETS" -split '[,\s]+' | Where-Object { $_ })
if ($pin.Count -and $Target -notin $pin) { throw "target '$Target' is not this QA run's target ($($pin -join ', ')): a run tests only its own env (run.json target / alsoTargets)" }
$t = Resolve-PokeyTarget $cfg.targets $Target
if (-not $t -and $Target -match '^(?<b>.+?)(?<k>\d+)$' -and (Get-KitMember $cfg.targets "$($Matches.b)-$("$(Get-KitBirdName ([int]$Matches.k))".ToLower())")) { $nk = "$($Matches.b)-$("$(Get-KitBirdName ([int]$Matches.k))".ToLower())"; Write-Warning "old lane target '$Target': use $nk"; $Target = $nk; $t = Resolve-PokeyTarget $cfg.targets $Target }
if (-not $t) { $t = Get-LaneTarget $cfg $Target }
if (-not $t) { throw "Unknown target '$Target'. Known: $((Get-KitProps $cfg.targets).Name -join ', ')$(if ($Target -match '\d$|-[a-z]+$') { ' (a local env lane <target>-<bird>: its base target must point at lane 1 ports; envy.ps1 envs)' })" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$a = Resolve-ApiAuth $t.auth
$kind = "$($a.type)"; if (-not $kind) { $kind = 'login' }
if ($Anonymous) { if ($As) { throw '-Anonymous sends no login: drop -As' }; $kind = 'none' }   # without it a default login is sent (retro tidy-20261123-01)
if (-not $As -and $kind -ne 'none') {
  $who0 = Resolve-ApiUser $t   # [string]$As would turn $null into ''
  if ($null -eq $who0) { $nu = "NO-USER target $Target has several users and none is chosen (not retried): pass -As <user>, or set targets.local.json targets.$Target.defaultUser or kit.local.json api.defaultUser. Known: $((Get-KitProps $t.users).Name -join ', ')"; if ($script:ApiNoExit) { throw $nu }; $nu; exit 2 }
  $As = $who0
}
$lp = Get-KitLoginPair $t $As; $u = $lp.u
# a profile's auth (over auth) and fields (opaque {field} placeholders; tenant = the -Tenant default)
$pfFields = @{}; if (($pf = $lp.pf)) {
  if ($pf.auth) { $t | Add-Member -Force NoteProperty userAuth ([pscustomobject]@{ $As = $pf.auth }) }
  foreach ($fp in @(Get-KitProps $pf.fields)) { if ($fp.Name -ne 'tenant') { $pfFields[$fp.Name] = "$($fp.Value)" } elseif (-not $PSBoundParameters['Tenant']) { $Tenant = "$($fp.Value)" } }
}
if (-not (Get-KitMember $t.users $As) -and -not $pf -and $kind -ne 'none') {   # not @(...).Count: @($null).Count is 1
  $holders = @((Get-KitProps $cfg.targets) | Where-Object { $_.Name -ne $Target -and (Get-KitMember $_.Value.users $As) } | ForEach-Object Name)   # names only, never values
  # exit 2, not a throw: a missing user never appears on retry (163x loop)
  $nu = "NO-USER '$As' in target $Target (not retried: add it to targets.local.json or use another -As). Known: $((Get-KitProps $t.users).Name -join ', ')$(if ($holders) { ". '$As' is in target(s) $($holders -join ', '): -Target $($holders[0]) -As $As" })"
  if ($script:ApiNoExit) { throw $nu }; $nu; exit 2 }   # user create: in-process, an exit would drop the text
if (-not $PSBoundParameters['Tenant'] -and ($ut = [string](Get-KitMember (Get-KitMember $t.created $As) 'tenant'))) { $Tenant = $ut }   # pokey.ps1 user create kept the login's tenant
# userAuth.<user>: that login's own auth fields over auth (a super admin's endpoint); its tenant unless -Tenant; webLogin: browser.mjs
if (($ua = Get-KitMember $t.userAuth $As)) {
  $ao = [ordered]@{}; foreach ($p in (Get-KitProps $a)) { $ao[$p.Name] = $p.Value }; foreach ($p in (Get-KitProps $ua)) { if ($p.Name -notin 'tenant', 'webLogin' -and $null -ne $p.Value) { $ao[$p.Name] = $p.Value } }
  $a = Resolve-ApiAuth ([pscustomobject]$ao); $kind = "$($a.type)"; if (-not $kind) { $kind = 'login' }
  if (-not $PSBoundParameters['Tenant'] -and "$($ua.tenant)") { $Tenant = [string]$ua.tenant }
}
$ext = Get-Command 'Get-ApiAuthHeaders' -ErrorAction SilentlyContinue   # adapters/api-auth.ps1: basic, cookie, command
$core = 'login', 'none', 'token', 'query'
if ($kind -notin $core -and -not ($ext -and $kind -in 'basic', 'cookie', 'command')) {
  # a local auth kind: Register-KitAdapter api-auth <type> @{ invoke = { param($a) ... } } in adapters/*.local.ps1; $a = the bound params
  if ($KitAdapters['api-auth'] -and $KitAdapters['api-auth'][$kind]) { $bp = @{}; foreach ($kv in $PSBoundParameters.GetEnumerator()) { $bp[$kv.Key] = $kv.Value }; $bp.As = $As; $bp.Target = $Target; return Invoke-KitAdapter 'api-auth' $kind 'invoke' $bp }
  throw "target '$Target' auth.type '$kind' unknown: $($core -join ', ')$(if ($ext) { ', basic, cookie, command' } else { ' (basic, cookie, command: adapters/api-auth.ps1)' })" }
if (-not $t.api -and $Path -notmatch '^https?://') { throw "target '$Target' has no api URL (web-only: use browser.mjs)" }
$base = ([string]$t.api).Replace('{tenant}', $Tenant).TrimEnd('/'); foreach ($fk in $pfFields.Keys) { $base = $base.Replace("{$fk}", $pfFields[$fk]) }
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }
if ($kind -eq 'query') { $uri += "$(if ($uri -match '\?') { '&' } else { '?' })$($a.param)=$([uri]::EscapeDataString([string]$u[1]))" }
$tls = if (-not $a.cert) { @{} } elseif ("$($a.certPass)") { @{ Certificate = Get-PfxCertificate -LiteralPath ([string]$a.cert) -Password (ConvertTo-SecureString ([string]$a.certPass) -AsPlainText -Force) } } else { @{ Certificate = Get-PfxCertificate -LiteralPath ([string]$a.cert) -NoPromptForPassword } }

function Fill($s) { $fs = ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant); foreach ($fk in $pfFields.Keys) { $fs = $fs.Replace("{$fk}", $pfFields[$fk]) }; $fs }

$tokDir = Get-KitPath tokens -Create
$cache = Join-Path $tokDir ("$Target-$Tenant-$As.txt" -replace '[^\w.\-]', '_')
$failMark = "$cache.refused"   # a refused login holds its user until targets.local.json changes: no lockout storm (6x Bad credentials)
$who = "LOGIN-FAIL target=$Target tenant='$Tenant' user=$As"
$script:rt = $null
# cache: token (cookie kind: the Cookie header) + refresh token
function Login([switch]$Refresh) {
  $fm = Get-Item -LiteralPath $failMark -ErrorAction SilentlyContinue
  if (-not $Refresh -and $fm -and $fm.LastWriteTime -gt (Get-Item -LiteralPath $cfgFile).LastWriteTime -and ((Get-Date) - $fm.LastWriteTime).TotalMinutes -lt [double](Get-KitParam 'api.loginHoldMinutes')) {
    throw "$who`: not retried, refused at $($fm.LastWriteTime.ToString('HH:mm')) ($(Get-Content -LiteralPath $failMark -Raw)); fix targets.local.json targets.$Target.users.$As, then retry (api.loginHoldMinutes)" }
  $b = [ordered]@{}; foreach ($p in (Get-KitProps $a.body)) { $b[$p.Name] = if ($p.Value -is [string]) { Fill $p.Value } else { $p.Value } }
  if ($Refresh) { $cid = $b.client_id; $b = [ordered]@{ grant_type = 'refresh_token'; refresh_token = $script:rt }; if ($cid) { $b.client_id = $cid } }
  $lu = Fill $(if ($a.path -match '^https?://') { $a.path } else { $base + $a.path })
  $form = $a.contentType -eq 'form' -or $Refresh
  $r = try { Invoke-WebRequest -Method Post $lu -ContentType $(if ($form) { 'application/x-www-form-urlencoded' } else { 'application/json' }) -Body $(if ($form) { $b } else { $b | ConvertTo-Json -Depth 5 }) -ConnectionTimeoutSeconds 60 -SessionVariable ws @tls } catch {
    $lc = [int]$_.Exception.Response.StatusCode; if ($Refresh -or $lc -notin 401, 403) { throw }   # a bad login names where to look (23x a bare 401 body)
    if ($lc -eq 401) { Set-Content -LiteralPath $failMark "HTTP $lc" -NoNewline }   # 403 may be a WAF or rate limit: no hold
    throw "$who`: login refused (HTTP $lc): check targets.local.json targets.$Target.users.$As (password; the user's tenant: -Tenant) and auth.path. $(-join ("$($_.ErrorDetails.Message)" -replace '\s+', ' ' -replace $(if ($u[1]) { [regex]::Escape([string]$u[1]) } else { '(?!)' }), '[redacted]')[0..199])" }
  if ($kind -eq 'cookie') { $tok = (@($ws.Cookies.GetAllCookies()) | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ' }
  else {
    $tok = Get-ApiLoginToken $a ([string]$r.Content)
    if ($a.refreshField) { $j = $r.Content | ConvertFrom-Json; $nrt = $j; foreach ($k in ([string]$a.refreshField).Split('.')) { $nrt = (Get-KitMember $nrt $k) }; if ($nrt) { $script:rt = $nrt } }   # a refresh answer may omit it: keep the old one
  }
  if (-not $tok) { throw "login to $Target as $As returned no token$(if ($a.tokenField) { " (auth.tokenField $($a.tokenField))" })" }
  Remove-Item -LiteralPath $failMark -ErrorAction SilentlyContinue
  "$tok`n$script:rt" | Set-Content $cache -NoNewline
  $tok
}
function AuthHeaders($tok) {
  if ($kind -in 'basic', 'cookie', 'command') { return Get-ApiAuthHeaders -Auth $a -User $u -Token $tok -Method $Method -Uri $uri -Body $Body -Fill ${function:Fill} }
  if ($kind -in 'none', 'query') { return @{} }
  $n, $v = "$(if ($a.header) { $a.header } else { 'Authorization: Bearer {token}' })".Split(':', 2)
  @{ $n.Trim() = $v.Trim().Replace('{token}', $tok) }
}
$tok = $null; $login = $kind -in 'login', 'cookie'
if ($login) { $tok, $script:rt = if (Test-Path $cache) { @(Get-Content $cache) + '' }; if (-not "$tok".Trim()) { $tok = Login } }   # empty cache file: log in again
elseif ($kind -eq 'token') { $tok = if ($a.token) { $a.token } else { [string]$u[1] } }

function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = $ContentType } + $tls
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match $KitLogMap.secretKey -or $kv.Key -match '(?i)cookie') { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
  try { $r = Invoke-WebRequest @p; $hm = HeaderMap $r.Headers.GetEnumerator(); return @([int]$r.StatusCode, $r.Content, [string]$hm['content-type'], $hm) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { $hm = HeaderMap (@($resp.Headers) + @($resp.Content.Headers)); return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType, $hm) } else { return @(0, "ERR $($_.Exception.Message)", '', [ordered]@{}) }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $login) { $tok = if ($script:rt) { try { Login -Refresh } catch { Login } } else { Login }; $sw.Restart(); $res = Call $tok }   # token expired: once more
$sw.Stop()
$status, $content, $ctype, $rhead = $res
if ($content -is [byte[]]) {
  $bytes = $content; $content = "[binary $($bytes.Length) bytes, $ctype]"
  if ($Save -and -not $bytes.Length) { $content += ' (empty: no file saved)' }
  elseif ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Get-KitPath evidence }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = if ([string]$rhead['content-disposition'] -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)') { [IO.Path]::GetExtension($Matches[1]) } else { '' }
    if (-not $ext) { $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '' } } }
    if (-not $ext) {   # octet-stream: magic bytes, then strict UTF-8
      $hex = -join @($bytes | Select-Object -First 4 | ForEach-Object { $_.ToString('X2') })
      $ext = switch -Regex ($hex) { '^25504446' { '.pdf' } '^89504E47' { '.png' } '^FFD8FF' { '.jpg' } '^504B0304' { '.zip' } default { try { if ($ctype -and $ctype -notmatch 'octet-stream') { throw }; $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes); '.txt' } catch { '.bin' } } }
    }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}

if ($Save) {
  if (-not $OutDir) { $OutDir = Get-KitPath evidence }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  # redact secrets at any depth (_paths.log.secretKey)
  function Redact($o) {
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $o[$k] = if ("$k" -match $KitLogMap.secretKey) { '[redacted]' } else { Redact $o[$k] } }; return , $o }
    if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in (Get-KitProps $o)) { $p.Value = if ($p.Name -match $KitLogMap.secretKey) { '[redacted]' } else { Redact $p.Value } }; return $o }
    if ($o -is [array]) { return , @($o | ForEach-Object { Redact $_ }) }
    # a string: the login's password and form / query secret fields (retro: a saved request body held a test password)
    if ($o -is [string]) { $o = $o -replace '(?i)((?:^|[?&])[^=&\s]*(?:passw|pwd|token|secret|api[-_]?key|authoriz|cookie|credential|private[-_]?key|signature)[^=&\s]*=)[^&\s]*', '$1[redacted]'; if ("$($u[1])".Length -ge 8) { $o = $o.Replace([string]$u[1], '[redacted]') } }
    $o
  }
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = (Redact $s.Substring(0, 200KB)) } }; try { Redact (ConvertFrom-Json $s -NoEnumerate) } catch { Redact $s } }
  $red = [ordered]@{}; foreach ($k in $script:sentHeaders.Keys) { $red[$k] = if ($k -match $KitLogMap.secretKey) { '[redacted]' } else { $script:sentHeaders[$k] } }
  $code, $check = if ($Save -match '^([A-Za-z0-9]+)-([A-Za-z]*\d+)') { $Matches[1], $Matches[2] } else { '', '' }
  [ordered]@{
    meta     = [ordered]@{ code = $code; check = $check; target = $Target; tenant = $Tenant; user = [string]$u[0]; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); durationMs = $sw.ElapsedMilliseconds; tool = 'pokey.ps1 api' }
    request  = [ordered]@{ method = $Method.ToUpper(); url = ($uri -replace '(?i)([?&][^=&]*(key|token|secret|sig|pass)[^=&]*=)[^&]*', '$1[redacted]'); headers = $red; body = (Parse $Body) }
    response = [ordered]@{ status = $status; headers = $(if ($rhead) { $rhead } else { [ordered]@{ 'content-type' = [string]$ctype } }); body = (Parse $content) }
  } | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutDir "$Save.json") -Encoding utf8
}
"HTTP $status"
$content
if (-not $status -or [int]$status -ge 400) { if ($script:ApiNoExit) { return }; exit 1 }   # else a 500 looked like success; user create reads the status itself
}

# ---- users: test logins agents create through the admin API (kit.local.json qa.userRecipes); passwords stay in targets.local.json, never printed
# this kit's targets.local.json, else the one next to kit.local.json (a kit worktree has neither: lib.ps1 reads the main clone's config)
function Get-TargetsFile {
  $f = Join-Path $PSScriptRoot 'targets.local.json'; if (Test-Path -LiteralPath $f) { return $f }
  $alt = Join-Path (Split-Path (Split-Path (Split-Path $KitConf.ConfigFile))) 'skills/pokey/targets.local.json'; if (Test-Path -LiteralPath $alt) { $alt } else { $f }
}
# ISO times stay text on a read-modify-write (pwsh 7.5+; older: DateTime, printed in the local culture)
$script:JsonKeepDates = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { @{ DateKind = 'String' } } else { @{} }
function Get-PokeyTargets {
  $f = Get-TargetsFile; if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f - run bossy.ps1 setup -WriteLocal, then fill it in" }
  [pscustomobject]@{ file = $f; data = (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable @JsonKeepDates) }
}
# the recipe whose targets regex matches the target
function Get-UserRecipe([string]$Target) {
  foreach ($p in (Get-KitProps (Get-KitSetting 'qa.userRecipes' $null))) { if ($p.Value.targets -and $Target -match [string]$p.Value.targets) { $h = $p.Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable; $h.name = $p.Name; return $h } }
  throw "no kit.local.json qa.userRecipes entry matches target '$Target' (each: targets regex, find, create, deactivate, roles, app; README Configuration)"
}
# roles.<r>.find / create / deactivate replace the recipe's (a driver's vehicle step); the role's other keys are template values
$script:UserStepKeys = 'find', 'create', 'deactivate', 'kinds'
function Get-UserSteps($Rc, [string]$Role, [string]$Step) { $rr = if ($Role -and $Rc.roles) { $Rc.roles[$Role] }; if ($rr -is [Collections.IDictionary] -and $rr.Contains($Step)) { $rr[$Step] } else { $Rc[$Step] } }
# never on production: targets.<t>.production, else deploy.productionPattern on the name
function Test-ProductionTarget([string]$Target, $T) { if ($null -ne $T.production) { return [bool]$T.production }; $rx = [string](Get-KitSetting 'deploy.productionPattern' ''); [bool]($rx -and $Target -match $rx) }
# '{x}' alone -> the value of x (arrays and objects too); '{x}' inside text -> its text; unknown names stay
function Expand-UserTemplate($Value, [hashtable]$Vars) {
  if ($Value -is [Collections.IDictionary]) { $o = [ordered]@{}; foreach ($key in $Value.Keys) { $o[$key] = Expand-UserTemplate $Value[$key] $Vars }; return $o }
  if ($Value -is [Collections.IList]) { return , @(foreach ($x in $Value) { Expand-UserTemplate $x $Vars }) }
  if ($Value -isnot [string]) { return $Value }
  if ($Value -match '^\{(\w+)\}$' -and $Vars.ContainsKey($Matches[1])) { $whole = $Vars[$Matches[1]]; if ($whole -is [Collections.IList]) { return , $whole }; return $whole }
  [regex]::Replace($Value, '\{(\w+)\}', { param($m) if ($Vars.ContainsKey($m.Groups[1].Value)) { [string]$Vars[$m.Groups[1].Value] } else { $m.Value } })
}
function Get-DottedValue($Obj, [string]$Path) { foreach ($key in ($Path -split '\.')) { $Obj = if ($Obj -is [Collections.IDictionary]) { $Obj[$key] } else { $null } }; $Obj }
# 20+ characters, each class once: upper, lower, digit, one of - _ . (safe for adb input text and JSON)
function New-TestPassword([int]$Length = 20) {
  # random bytes from v4 GUIDs (OS random source; version / variant bytes skipped): the crypto class name would make pwsh log this script (lint ARCH-SBLOG)
  $rnd = [Collections.Generic.Queue[int]]::new(); while ($rnd.Count -lt 2 * $Length + 8) { $g = [guid]::NewGuid().ToByteArray(); foreach ($bt in @($g[0..6] + $g[9..15])) { $rnd.Enqueue([int]$bt) } }
  $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.'; $pool = -join $sets
  $chars = @(foreach ($set in $sets) { $set[$rnd.Dequeue() % $set.Length] }) + @(for ($i = $sets.Count; $i -lt $Length; $i++) { $pool[$rnd.Dequeue() % $pool.Length] })
  $mixed = -join ($chars | Sort-Object { $rnd.Dequeue() }); $first = $mixed.IndexOfAny([char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz')
  "$($mixed[$first])$($mixed.Remove($first, 1))"   # a letter first: '-x' would read as an option to adb input text
}
# one recipe step as the admin: { method, path, body | from + set, match, name, save { var: dotted path } }; returns the answer (match: the element whose match path = login, or $null)
function Invoke-UserStep($Step, [hashtable]$Vars, [string]$Target, [string]$As, [string]$Tenant) {
  $body = if ($Step.from) { $src0 = $Vars["@$($Step.from)"]; if ($null -eq $src0) { throw "step from '$($Step.from)': no earlier step named so" }; $b0 = $src0 | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable; $set0 = Expand-UserTemplate $Step.set $Vars; foreach ($key in @($set0.Keys)) { $b0[$key] = $set0[$key] }; $b0 } elseif ($null -ne $Step.body) { Expand-UserTemplate $Step.body $Vars }
  $json = if ($null -ne $body) { $body | ConvertTo-Json -Depth 30 -Compress }
  $method = if ($Step.method) { ([string]$Step.method).ToUpper() } else { 'GET' }
  $script:ApiNoExit = $true
  try { $out = @(Invoke-Api -Method $method -Path (Expand-UserTemplate ([string]$Step.path) $Vars) -Body $json -Target $Target -As $As -Tenant $Tenant) } finally { $script:ApiNoExit = $false }
  $status = if ("$($out[0])" -match '^HTTP (\d+)') { [int]$Matches[1] } else { 0 }; $text = (@($out | Select-Object -Skip 1) -join "`n")
  $ans = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate @JsonKeepDates } catch { $null }
  if ($Step.match) { if ($status -eq 404) { return $null }; $ans = @(@($ans) + @(Get-DottedValue $ans 'content') | Where-Object { $_ -is [Collections.IDictionary] -and "$(Get-DottedValue $_ $Step.match)" -ieq "$($Vars.login)" })[0] }
  if ($status -lt 200 -or $status -ge 300) { $pw = [string]$Vars.password; throw "$method $($Step.path) -> HTTP $status $(-join ("$text" -replace $(if ($pw) { [regex]::Escape($pw) } else { '(?!)' }), '[redacted]' -replace '\s+', ' ')[0..299])" }
  if ($null -ne $ans) { if ($Step.name) { $Vars["@$($Step.name)"] = $ans }; if ($Step.save) { foreach ($key in $Step.save.Keys) { $Vars[$key] = Get-DottedValue $ans $Step.save[$key] } } }
  $ans
}
function Invoke-User {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('create', 'list', 'deactivate', 'auth')][string]$Action,
  [Parameter(Mandatory)][string]$Target,
  [string]$Name,                     # the login (and its users key)
  [string]$Role,                     # a key of the recipe's roles
  [string]$As = '',                  # the admin user ('' = the target's default user)
  [string]$Tenant,                   # '' = targets.<t>.defaultTenant
  [string]$Run = $env:KIT_RUN,       # kept with the login: cleanup finds a run's logins
  [string]$Kind,                     # web | api | app: refused when the role's kinds lack it
  [switch]$Seat,                     # a run's own parallel login (seat acquire): seat cleanup deactivates it
  [string]$Path,                     # auth: userAuth.<login>.path (its API login endpoint)
  [string]$WebLogin                  # auth: userAuth.<login>.webLogin JSON over webLogin (its web login page: path, fields, submit)
)
$ErrorActionPreference = 'Stop'
$tf = Get-PokeyTargets; $t = Resolve-PokeyTarget $tf.data.targets $Target
# list on a lane (<target>-<bird>): its logins are the base target's (create / deactivate keep the exact target)
if (-not $t -and $Action -eq 'list' -and ($lb = Get-LaneBase $tf.data.targets $Target)) { $Target = $lb.base; $t = $tf.data.targets[$Target] }
# list on an env or lane name (rm-osprey, rm-local, lane-03): the target on that group's lane-1 ports
if (-not $t -and $Action -eq 'list' -and ($et = Get-EnvTarget $tf.data.targets $Target)) { $Target = $et; $t = $tf.data.targets[$Target] }
if (-not $t) { throw "Unknown target '$Target'. Known: $(@($tf.data.targets.Keys) -join ', ') (a lane/env name: use its target; envy.ps1 envs lists lanes)" }
$made = if ($t.created -is [Collections.IDictionary]) { $t.created } else { [ordered]@{} }
if ($Action -eq 'list') {
  foreach ($n in @($t.users.Keys)) { $c = $made[$n]; "$n$(if ($c) { " · created $($c.at) · tenant $($c.tenant) · role $($c.role)$(if ($c.run) { " · run $($c.run)" })$(if ($c.deactivated) { " · deactivated $($c.deactivated)" })" })" }
  foreach ($n in @($made.Keys | Where-Object { $_ -notin @($t.users.Keys) })) { "$n · deactivated $($made[$n].deactivated) · tenant $($made[$n].tenant)" }
  return
}
if ($Name -notmatch '^[_.@A-Za-z0-9-]{1,50}$') { "usage: pokey.ps1 user $Action -Target <t> -Name <login: 1-50 of A-Z a-z 0-9 _ . @ -> ..."; exit 2 }
# auth: a stored login's own login endpoints (a super admin's), written under the lock; prints field names only
if ($Action -eq 'auth') {
  if (-not $t.users[$Name]) { "NO-USER '$Name' in target $Target (user list -Target $Target)"; exit 2 }
  # Git Bash turns /api/x into C:/Program Files/Git/api/x (the login then hit 'No such host')
  if ($Path -and $Path -notmatch '^(/|https?://)') { "REFUSED: -Path '$Path' is not /... or http(s)://... (from Git Bash: MSYS_NO_PATHCONV=1, or pwsh)"; exit 2 }
  if (-not ($Path -or $WebLogin -or $Tenant)) { "usage: pokey.ps1 user auth -Target <t> -Name <login> [-Path <api login path>] [-WebLogin <JSON: path, fields, submit>] [-Tenant <t>]"; exit 2 }
  Invoke-KitLocked $tf.file {
    $d = Get-Content -LiteralPath $tf.file -Raw | ConvertFrom-Json -AsHashtable @JsonKeepDates; $tt = $d.targets[$Target]
    if ($tt.userAuth -isnot [Collections.IDictionary]) { $tt.userAuth = [ordered]@{} }
    if ($tt.userAuth[$Name] -isnot [Collections.IDictionary]) { $tt.userAuth[$Name] = [ordered]@{} }
    $ua0 = $tt.userAuth[$Name]
    if ($Path) { $ua0.path = $Path }
    if ($Tenant) { $ua0.tenant = $Tenant }
    if ($WebLogin) { $ua0.webLogin = $WebLogin | ConvertFrom-Json -AsHashtable }
    Write-KitAtomic $tf.file ($d | ConvertTo-Json -Depth 30); $script:UserAuthKeys = @($ua0.Keys)
  }
  "AUTH $Target userAuth.$Name set: $(@($(if ($Path) { 'path' }), $(if ($WebLogin) { 'webLogin' }), $(if ($Tenant) { 'tenant' }) | Where-Object { $_ }) -join ', ') (fields now: $($script:UserAuthKeys -join ', '))"
  return
}
$rc = Get-UserRecipe $Target
if (-not $Tenant) { $Tenant = if ($made[$Name].tenant) { [string]$made[$Name].tenant } else { [string]$t.defaultTenant } }
$local = $t.users[$Name]
$vars = @{ login = $Name; tenant = $Tenant; run = $Run; role = $Role; password = $(if ($local) { [string]@($local)[1] } else { New-TestPassword }) }
if ($made[$Name].ids -is [Collections.IDictionary]) { foreach ($key in @($made[$Name].ids.Keys)) { $vars[$key] = $made[$Name].ids[$key] } }
$vars.email = Expand-UserTemplate $(if ($rc.email) { $rc.email } else { '{login}@example.invalid' }) $vars
$save = {   # one writer, under the file lock; never prints a value
  param([scriptblock]$Change)
  Invoke-KitLocked $tf.file { $d = Get-Content -LiteralPath $tf.file -Raw | ConvertFrom-Json -AsHashtable @JsonKeepDates; $tt = $d.targets[$Target]; if ($null -eq $tt) { $tt = $d.targets[$Target] = [ordered]@{} }; if ($tt.created -isnot [Collections.IDictionary]) { $tt.created = [ordered]@{} }; if ($tt.users -isnot [Collections.IDictionary]) { $tt.users = [ordered]@{} }; & $Change $tt; Write-KitAtomic $tf.file ($d | ConvertTo-Json -Depth 30) }
}
$ro = if ($Role) { $Role } else { [string]$made[$Name].role }   # deactivate: the role it was made with
$steps = @{}; foreach ($sn in 'find', 'create', 'deactivate') { $steps[$sn] = Get-UserSteps $rc $ro $sn }
# ids = what the recipe's steps save (find, create): deactivate reuses them
$ids = { $o = [ordered]@{}; foreach ($st in @(@($steps.find) + @($steps.create) | Where-Object { $_.save })) { foreach ($key in $st.save.Keys) { if ($null -ne $vars[$key]) { $o[$key] = $vars[$key] } } }; $o }
if ($Action -eq 'deactivate') {
  if (-not $made[$Name] -or $made[$Name].deactivated) { "REFUSED: '$Name' on $Target was not made by user create or is deactivated already (shared logins are never deactivated)"; exit 2 }
  if (-not $steps.deactivate) { throw "recipe $($rc.name) has no deactivate steps" }
  # a create killed before it saved ids: find it; not on the server -> nothing to deactivate
  $gone = $made[$Name].broken -and -not @($made[$Name].ids.Keys | Where-Object { $_ }).Count -and $steps.find -and -not (Invoke-UserStep $steps.find $vars $Target $As $Tenant)
  if (-not $gone) { foreach ($st in @($steps.deactivate)) { $null = Invoke-UserStep $st $vars $Target $As $Tenant } }
  & $save { param($tt) $tt.users.Remove($Name); if (-not $tt.created[$Name]) { $tt.created[$Name] = [ordered]@{ tenant = $Tenant } }; $tt.created[$Name].deactivated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
  "DEACTIVATED $Name on $Target tenant '$Tenant'"; return
}
if (-not $Role -or -not $rc.roles -or -not $rc.roles.Contains($Role)) { "usage: -Role <$(@($rc.roles.Keys) -join ' | ')> (recipe $($rc.name) roles)"; exit 2 }
if ($Kind -and $rc.roles[$Role].kinds -and $Kind -notin @($rc.roles[$Role].kinds)) { "usage: role $Role logs in on $(@($rc.roles[$Role].kinds) -join ', '), not -Kind $Kind (recipe $($rc.name) roles.$Role.kinds)"; exit 2 }
if (Test-ProductionTarget $Target $t) { "REFUSED: $Target is a production target (targets.$Target.production / deploy.productionPattern): test logins are never created there"; exit 2 }
foreach ($key in $rc.roles[$Role].Keys | Where-Object { $_ -notin $script:UserStepKeys }) { $vars[$key] = $rc.roles[$Role][$key] }
if (-not $steps.create) { throw "recipe $($rc.name) role $Role has no create steps" }
$found = if ($steps.find) { Invoke-UserStep $steps.find $vars $Target $As $Tenant }
if ($found -and -not $local) { throw "'$Name' exists on $Target tenant '$Tenant' with no password in targets.local.json: pick another -Name" }
$state = if ($found) { 'EXISTS' } else { 'CREATED' }
$rec = [ordered]@{ tenant = $Tenant; role = $Role; recipe = $rc.name; at = $(if ($made[$Name].at) { $made[$Name].at } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }); run = $(if ($made[$Name].run) { $made[$Name].run } else { $Run }); ids = (& $ids) }
if ($Kind) { $rec.kind = $Kind }; if ($Seat -or $made[$Name].seat) { $rec.seat = $true }
if (-not $found) { $rec.broken = $true }   # until every create step passed (a killed create is never handed out as a seat)
# the password is stored before the create call: a crash after it never leaves a server login nobody can use
$pwRef = [string]$vars.password; if ((Get-KitSecretStore) -ne 'file') { $pwRef = "secret:targets/$Target/$Name/password"; $null = Set-KitSecret $pwRef.Substring(7) $vars.password }
& $save { param($tt) $tt.users[$Name] = @($Name, $pwRef); $tt.created[$Name] = $rec }
if (-not $found) {
  try { foreach ($st in @($steps.create)) { $null = Invoke-UserStep $st $vars $Target $As $Tenant } }
  catch { $failed = $_; $there = try { if ($steps.find) { Invoke-UserStep $steps.find $vars $Target $As $Tenant } } catch { $null }; if (-not $there) { & $save { param($tt) $tt.users.Remove($Name); $tt.created.Remove($Name) }; if ($pwRef -like 'secret:*') { Remove-KitSecret $pwRef.Substring(7) } }
    else { $rec.ids = (& $ids); & $save { param($tt) $tt.created[$Name] = $rec } }   # a later step failed: stays broken, deactivate finds its ids
    throw $failed }
  $rec.ids = (& $ids); $rec.Remove('broken'); & $save { param($tt) $tt.created[$Name] = $rec }
}
$check = ''
if ($rc.check) {
  $script:ApiNoExit = $true; try { $co = @(Invoke-Api -Method GET -Path ([string]$rc.check) -Target $Target -As $Name -Tenant $Tenant) } catch { $co = @("HTTP 0 $($_.Exception.Message)") } finally { $script:ApiNoExit = $false }
  $check = " · login check $(-join "$($co[0])"[0..119])"; if ("$($co[0])" -notmatch '^HTTP 2') { $state = "$state-LOGIN-FAIL" } }
"$state $Name (role $Role) on $Target tenant '$Tenant'$check · password in targets.local.json (not shown): pokey.ps1 api -Target $Target -As $Name · ui login -Target $Target -As $Name"
"SETUP_CHANGE: test login $Name ($Role) $(if ($state -like 'EXISTS*') { 'reused' } else { 'created' }) on $Target/$Tenant; remove: pokey.ps1 user deactivate -Target $Target -Name $Name"
if ($state -like '*LOGIN-FAIL') { exit 1 }
}
# ---- login surfaces (parity.json login): api and app read a target user the same way (Get-KitLoginPair); web: browser.mjs
# a target user -> @{ u = login, password; pf = its profile }: profiles.<As> (login, secret = a secrets.store name) over users.<As>
# (secret:<name> refs resolved through the store); README "Adapters" login profiles
function Get-KitLoginPair($T, [string]$As) {
  $pf = Get-KitMember $T.profiles $As
  if ($pf) { return @{ u = @($(if ($pf.login) { "$($pf.login)" } else { $As }), $(if ($pf.secret) { Get-KitSecret "$($pf.secret)" })); pf = $pf } }
  @{ u = @((Get-KitMember $T.users $As) | ForEach-Object { Resolve-KitSecretRef $_ }); pf = $null }
}
Register-KitAdapter login api @{ users = $true; secretRefs = $true; profiles = $true }
Register-KitAdapter login app @{ users = $true; secretRefs = $true; profiles = $true }
# type a stored login into the app's login screen (qa.userRecipes.<r>.app.steps); the password never reaches stdout
function Invoke-UiLogin {
param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$As, [string]$Serial, [string]$Tenant)
if ($Serial) { $env:ANDROID_SERIAL = $Serial }
$tf = Get-PokeyTargets; $t = Resolve-PokeyTarget $tf.data.targets $Target; if (-not $t) { throw "Unknown target '$Target'. Known: $(@($tf.data.targets.Keys) -join ', ')" }
$lp = Get-KitLoginPair $t $As; $u = $lp.u; if (-not $u[0]) { "NO-USER '$As' in target ${Target}: pokey.ps1 user list -Target $Target, or user create"; exit 2 }
if (-not $Tenant -and "$($lp.pf.fields.tenant)") { $Tenant = "$($lp.pf.fields.tenant)" }
if (-not $Tenant) { $Tenant = if ($t.created -is [Collections.IDictionary] -and $t.created[$As].tenant) { [string]$t.created[$As].tenant } else { [string]$t.defaultTenant } }
$app = (Get-UserRecipe $Target).app; if (-not $app.steps) { throw "kit.local.json qa.userRecipes entry for '$Target' has no app.steps ([{ into: <resource-id>, text: '{user}' | '{pass}' | '{tenant}', optional }, { key: <keycode> }, { tap: <resource-id> }, { wait: <text> }])" }
$vars = @{ user = [string]$u[0]; pass = [string]$u[1]; tenant = $Tenant }; $android = (Get-KitSetting 'devices.type' 'none') -ne 'ios'
foreach ($s in @($app.steps)) {
  if ($s.into) {
    if ($s.optional -and -not (@(Invoke-Ui dump) -match "#\S*$([regex]::Escape([string]$s.into))$")) { "skipped #$($s.into) (not on screen)"; continue }
    Invoke-Ui tapid ([string]$s.into); if ($android) { $null = Invoke-Ui clear }
    $null = Invoke-Ui type (Expand-UserTemplate ([string]$s.text) $vars); "typed #$($s.into)$(if ("$($s.text)" -match '\{pass\}') { ' (hidden)' })"
  }
  elseif ($s.key) { Invoke-Ui key ([string]$s.key) }
  elseif ($s.tap) { Invoke-Ui tapid ([string]$s.tap) }
  elseif ($s.wait) { Invoke-Ui wait ([string]$s.wait) $(if ($s.seconds) { [string]$s.seconds } else { '30' }) }
}
"LOGIN typed for $As on $Target tenant '$Tenant'$(if ($env:ANDROID_SERIAL) { " ($env:ANDROID_SERIAL)" })"
}

# ---- finalize: publish one package; re-run safe
function Invoke-Finalize {
param(
  [Parameter(Mandatory)][string]$RunDir,
  [Alias('Item')][Parameter(Mandatory)][string]$Code,
  [switch]$NoTracker,
  [switch]$Force,
  [switch]$Check,
  [switch]$FixNames,
  [int]$ExpectChecks = -1,              # truncated results.json refused
  [string]$Results = 'results.json',    # -Check: a retry renames only its own
  [string]$Report = '',                 # a reports.type name
  [string]$Date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
)
$ErrorActionPreference = 'Stop'
if ($Results -ne 'results.json' -and -not $Check) { throw '-Results works only with -Check (publishing reads results.json)' }
$publishAfter = $FixNames -and -not $Check   # -FixNames alone: publish after a clean rename
if ($FixNames) { $Check = [switch]$true }$rtype = if ($Report) { $Report } else { $KitConf.ReportType }
$RunDir = (Resolve-Path $RunDir).Path
$run = Get-Content "$RunDir/run.json" -Raw | ConvertFrom-Json
$item = @($run.items) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
if (-not $item) { throw "no item $Code in $RunDir/run.json" }
$D = "$RunDir/$Code"
# one report per task (else per run item); a human testing doc of the task gets this run's Result / Evidence per row
$pubKey = if (@($item.subtasks).Count -eq 1) { [string]@($item.subtasks)[0].id } else { "$(Split-Path $RunDir -Leaf)-$Code" }
$hDoc = Test-Path -LiteralPath (Join-Path (Get-KitPath published) "$($pubKey -replace '[^\w.-]+', '_')_testing-doc.json")
# -FixNames fits notes too (owner 2026-11-26: 365 prose-check stops in 6 days): an observed / what_was_done over the result-note cap keeps
# its first words, the full text becomes an evidence file its row cites (kitbag.py notes_fit): nothing cut, no rewrite round
if ($FixNames) { @(& (Get-Python) -X utf8 $KitCmd.kitbag prose --kind result-note (Join-Path $D $Results) --fit "$D/evidence" --code $Code 2>$null) -match '^FIT ' | ForEach-Object { "  $_" } }
$res = Get-Content (Join-Path $D $Results) -Raw | ConvertFrom-Json
if ($ExpectChecks -ge 0 -and @($res.checks).Count -ne $ExpectChecks) {
  $m = "$Code`: $Results has $(@($res.checks).Count) check(s), the workflow sent $ExpectChecks - a truncated copy; nothing published. Write the JSON again, complete."
  if ($Check) { $m; 'EXIT=1'; exit 1 } else { throw $m }
}
# copy outside evidence in for upload
if (-not $Check) { New-Item -ItemType Directory -Force "$D/evidence" | Out-Null }
# long verify -> own evidence file (-Check: counted only)
$vText = [ordered]@{}
foreach ($c in @($res.checks)) { $vf = VerifyFile $Code $c; if ($vf) { $vText[$vf] = "$($c.id) — $($c.screen): independent re-test and note audit`n`n" + (([string]$c.verify -split ' \| ') -join "`n`n") + "`n" } }
$vChanged = @(if (-not $Check) { foreach ($vf in $vText.Keys) {   # re-uploaded in step 1
  if ((Test-Path "$D/evidence/$vf") -and [IO.File]::ReadAllText("$D/evidence/$vf") -ne $vText[$vf]) { $vf }
  [IO.File]::WriteAllText("$D/evidence/$vf", $vText[$vf]) } })
$lost = [Collections.Generic.List[object]]::new()   # listed but found nowhere
# -FixNames log: rewritten results may name old files
$renLog = "$D/evidence-renames.json"; $renamed = @{}; $remap = [ordered]@{}
if (Test-Path -LiteralPath $renLog) { (Get-KitProps (Get-Content -LiteralPath $renLog -Raw | ConvertFrom-Json)) | ForEach-Object { $renamed[$_.Name] = [string]$_.Value } }
foreach ($c in @($res.checks)) {
  if ($null -eq $c.PSObject.Members['evidence']) { $c | Add-Member NoteProperty evidence @() }
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -and [string]$_ -notmatch '\.(mjs|cjs|js|jsx|ts|tsx|java|kt|ps1|py|sh)$|\s' } | ForEach-Object {
      $e = [string]$_; $leaf = Split-Path $e -Leaf
      $nw = $renamed[$leaf]
      if ($nw -and -not (Test-Path "$D/shots/$leaf") -and -not (Test-Path "$D/evidence/$leaf") -and ((Test-Path "$D/shots/$nw") -or (Test-Path "$D/evidence/$nw"))) { $remap[$leaf] = $nw; $leaf = $nw }
      if (-not (Test-Path "$D/shots/$leaf") -and -not (Test-Path "$D/evidence/$leaf")) {
        $src = if ([IO.Path]::IsPathRooted($e) -and (Test-Path $e)) { $e } elseif (Test-Path (Join-Path $D $e)) { Join-Path $D $e } else { (Get-ChildItem $RunDir -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
        if (-not $src) { $lost.Add([pscustomobject]@{ check = $c; name = $leaf }) }
        elseif (-not $Check) { Copy-Item $src "$D/evidence/$leaf" -Force }
      }
      $leaf } | Select-Object -Unique)
}

# 0. Evidence check first
$files = @(Get-ChildItem "$D/shots", "$D/evidence" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'tmp*' -and $_.Extension -match $script:EvidenceExt })
$badNames = @($files | Where-Object { $_.Name -notmatch $script:EvidenceName -and -not $vText.Contains($_.Name) } | ForEach-Object Name)
if ($badNames.Count -and -not $Check) { Write-Warning "evidence names not following the standard (published anyway): $($badNames -join ', ')" }
# a listed unsupported type would stay on disk
$badTypes = @(@(foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e -and [IO.Path]::GetExtension([string]$e) -notmatch $script:EvidenceExt) { "$($c.id): $e" } } }) | Select-Object -Unique)
if ($badTypes.Count -and -not $Check) { Write-Warning "evidence listed but of an unsupported type (not published): $($badTypes -join '; ')" }
$lostList = @($lost | ForEach-Object { "$($_.check.id): $($_.name)" })
# prose limits: -Check exits 1, publish refuses
$prose = {
  $lm = @{ folderLink = $D; files = @{} }; foreach ($x in @(@($files.Name) + @($vText.Keys) | Where-Object { $_ })) { $lm.files[$x] = @{ link = $x } }
  $md = Build-QaReportMd -Title $(if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }) -Code $Code -Item $item -Res $res -Map $lm -Run $run -Tester '-' -Date $Date
  # each finding names its file + field (kitbag result_notes): this package's results and report only
  # link lists are not prose; the H1 = the lead's run title (capped at prepare): a tester cannot fix it
  $mdProse = (($md -split "`n## Evidence index")[0] + "`n## Evidence index`nn/a — a file list, not prose") -replace '(?m)^\*\*Evidence:\*\* .*$', '' -replace '\A# [^\n]*', ''
  foreach ($trName in @(@($item.subtasks) | ForEach-Object { "$($_.name)" -replace '\|', '\|' -replace "`r?`n", ' ' } | ForEach-Object Trim | Where-Object { $_ })) { $mdProse = $mdProse.Replace("| $trName |", '| |') }   # tracker task names: quoted, not ours to rewrite
  @(@(Test-KitProse -Kind result-note -Path (Join-Path $D $Results) 3>$null) + @(Test-KitProse -Kind qa-report -Text $mdProse 3>$null))
}
# the run's shared run.json / bugs.json: WARN only (one package's note there never holds another package's close)
$proseRun = { @(foreach ($pf in "$RunDir/run.json", "$RunDir/bugs.json") { if (Test-Path -LiteralPath $pf) { Test-KitProse -Kind result-note -Path $pf 3>$null } }) }
$prWhy = "$Code prose check: shorten the named field (file, path) (crafty/templates.md ""Writing standards"")"
# knownBug: a FAIL already tracked by another OPEN task (an untracked defect must never close a task); -in compares any case
$knownBad = { $tested = @(@($item.subtasks) | ForEach-Object { ([string]$_.id).Trim().TrimStart('#') })
  @(foreach ($c in @(@($res.checks) | Where-Object { "$($_.knownBug)".Trim() })) { $kb = "$($c.knownBug)".Trim(); $kt = try { Get-TrackerTask $kb } catch { $null }
  if ($c.result -ne 'FAIL') { "$($c.id): knownBug $kb on a $($c.result) check (FAIL only)" }
  elseif ("$($c.defect)" -eq 'own') { "$($c.id): knownBug $kb with defect own (pick one)" }
  elseif ($kb.TrimStart('#') -in $tested) { "$($c.id): knownBug $kb is a tested task (its own failure: defect own)" }
  elseif (-not "$($kt.name)".Trim()) { "$($c.id): knownBug $kb not found in the tracker" }
  elseif ((Test-TrackerStatus "$($kt.status)" 'closed') -or "$($kt.status)" -ieq 'closed') { "$($c.id): knownBug $kb is closed (reopen it, or defect new)" } }) }
# human doc rows neither this run nor an earlier published run covers (devtools.py docgaps: id, case or a screen starting with the row id); a sibling item on the task: WARN
$runKey = "$(Split-Path $RunDir -Leaf)-$Code"
$stIds = @(@($item.subtasks) | ForEach-Object { [string]$_.id })
$docSib = [bool]@(@($run.items) | Where-Object { $_.code -ne $Code -and @(@($_.subtasks) | Where-Object { [string]$_.id -in $stIds }).Count }).Count
$docGaps = { if (-not $hDoc) { return }
  # a scoped retry (-Results <file>): the item's results.json covers the rows the retry does not touch
  $gcAll = @(@($res.checks) + @(if ($Results -ne 'results.json' -and (Test-Path -LiteralPath (Join-Path $D 'results.json'))) { try { @((Get-Content -LiteralPath (Join-Path $D 'results.json') -Raw | ConvertFrom-Json).checks) } catch { } }))
  $gc = @{}; foreach ($c in $gcAll) { if ($c -and -not $gc.ContainsKey([string]$c.id)) { $gc[[string]$c.id] = @{ result = [string]$c.result; case = "$($c.case)"; screen = "$($c.screen)" } } }
  $gf = New-KitTempFile '.json'; [IO.File]::WriteAllText($gf, (ConvertTo-Json $gc -Depth 3), [Text.UTF8Encoding]::new($false))
  $gapAll = @(& (Get-Python) -X utf8 $KitCmd.devtools docgaps --key "${pubKey}:testing-doc" --run $gf --run-id $runKey 2>&1); $gapRc = $LASTEXITCODE; Remove-Item -LiteralPath $gf -ErrorAction SilentlyContinue
  if ($gapRc) { throw "devtools.py docgaps failed (exit $gapRc): $((@($gapAll) | Select-Object -Last 3) -join ' | ')" }   # never read as "every row covered"
  @($gapAll | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] -and "$_".Trim() } | ForEach-Object { "$_".Trim() }) }
# human doc checks run from the UI: a screenshot each (PASS / note / FAIL); a "No UI trigger" row also takes a .log excerpt; JSON alone = API-only
$noShot = { if (-not $hDoc) { return }
  $hRec = try { Get-Content -LiteralPath (Join-Path (Get-KitPath published) "$($pubKey -replace '[^\w.-]+', '_')_testing-doc.json") -Raw | ConvertFrom-Json } catch { $null }
  # the rows of the doc's case tables (a header with # and Result); only checks covering one need a screenshot
  $docRows = [Collections.Generic.List[string]]::new(); $noUiRows = [Collections.Generic.List[string]]::new(); $inCases = $false
  foreach ($hLine in ("$(@($hRec.rounds)[-1].body)" -split "`r?`n")) {
    if ($hLine -notmatch '^\s*\|') { $inCases = $false; continue }
    if ($hLine -match '^\s*\|\s*#\s*\|' -and $hLine -match '\|\s*Result\s*\|') { $inCases = $true; continue }
    if ($inCases -and $hLine -match '^\s*\|\s*([^|\s]+)\s*\|(.*)' -and $Matches[1] -notmatch '^[-:]+$') {
      $rowId = $Matches[1]; $docRows.Add($rowId); if ($Matches[2] -match '^\s*\**No UI trigger') { $noUiRows.Add($rowId) } }
  }
  foreach ($sc in @(@($res.checks) | Where-Object { [string]$_.result -in 'PASS', 'PASS_WITH_NOTE', 'FAIL' })) {
    $scEv = @(@($sc.evidence) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if (@($scEv | Where-Object { $_ -match '\.(png|jpe?g)$' }).Count) { continue }
    $scRows = @(@("$($sc.id)") + @("$($sc.case)" -split '[\s,;]+') + @(if ("$($sc.screen)" -match '^\s*([A-Za-z]*\d+[a-z]?)\b') { $Matches[1] }) | Where-Object { $_ })
    if (-not @($scRows | Where-Object { $_ -in $docRows }).Count) { continue }
    if (@($scRows | Where-Object { $_ -in $noUiRows }).Count -and @($scEv | Where-Object { $_ -match '\.log$' }).Count) { continue }
    "$($sc.id)$(if (@($scEv | Where-Object { $_ -match '\.json$' }).Count) { ' (API-only evidence: run it from the UI, keep the JSON that action caused as extra)' })"
  } }
$gapWhy = "human testing doc row(s) neither this run nor an earlier published run covers (each row's Result / Evidence comes from the checks with its id, ""case"": ""<row id>"" or a screen starting with it): give those checks the row id, or add a NOT_TESTED check per row with why"
if ($Check) {
  # standard name, else setup form
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
    # an uncited file of a check id no longer in results (X9-...): keep its id; the setup form runs out after 99 files
    if (-not $id -and $stem -match '^([A-Za-z]{1,3}\d+[a-z]?)(?=[-_. ]|$)') { $id = $Matches[1]; $stem = $stem.Substring($id.Length) }
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
  # 0 bytes = failed capture: report, never rename
  $cited = @{}; foreach ($c in @($res.checks)) { foreach ($e in @($c.evidence)) { if ($e) { $cited[[string]$e] = [string]$c.id } } }
  $emptyFiles = @($files | Where-Object { $_.Length -eq 0 -and $cited.ContainsKey($_.Name) })
  $emptyNames = @($emptyFiles | ForEach-Object Name)
  if ($Results -ne 'results.json') { $badNames = @($badNames | Where-Object { $cited.ContainsKey($_) }) }
  $suggest = [ordered]@{}
  foreach ($b in $badNames) { $suggest[$b] = if ($emptyNames -contains $b) { $null } else { Get-StandardName $b } }
  if ($FixNames -and ($suggest.Count -or $remap.Count)) {
    $resFile = Join-Path $D $Results; $raw = [IO.File]::ReadAllText($resFile)
    # whole-name refs, any case (a Windows rename left other-case refs)
    $retag = { param($old, $nn) [regex]::Replace($raw, '(?<![\w.-])' + [regex]::Escape($old) + '(?![\w-]|\.\w)', $nn.Replace('$', '$$'), 'IgnoreCase') }
    foreach ($o in @($remap.Keys)) { $raw = & $retag $o $remap[$o]; "  $Results`: $o -> $($remap[$o]) (renamed by an earlier -FixNames)" }
    foreach ($b in @($suggest.Keys)) {
      $new = $suggest[$b]; if (-not $new) { continue }
      $f = $files | Where-Object Name -eq $b | Select-Object -First 1
      Rename-Item -LiteralPath $f.FullName -NewName $new
      $raw = & $retag $b $new; $renamed[$b] = $new
      "  renamed $($f.Directory.Name)/$b -> $($f.Directory.Name)/$new"
      $suggest.Remove($b)
    }
    [IO.File]::WriteAllText($resFile, $raw)
    [IO.File]::WriteAllText($renLog, ($renamed | ConvertTo-Json -Depth 2))
    $badNames = @($suggest.Keys)
  }
  $dups = @(@($res.checks) | Where-Object { $_.id } | Group-Object { [string]$_.id } | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) (x$($_.Count))" })
  $fail = $false
  if ($lostList.Count) { $fail = $true; "$Code evidence check: $($lostList.Count) file(s) listed in results.json but missing:"; $lostList | ForEach-Object { "  $_" } }
  # the exact next command, with this call's -ExpectChecks / -Results
  $canFix = @($suggest.Values | Where-Object { $_ }).Count
  $checkCmd = "& '$($PSCommandPath.Replace("'", "''"))' finalize -RunDir '$($RunDir.Replace("'", "''"))' -Code $Code -Check$(if ($canFix) { ' -FixNames' })$(if ($ExpectChecks -ge 0) { " -ExpectChecks $ExpectChecks" })$(if ($Results -ne 'results.json') { " -Results $Results" })"
  # a name -FixNames renames blocks until renamed; one it cannot rename is a WARN (published as is: a name never holds a close)
  if ($badNames.Count) {
    if ($canFix) { $fail = $true }; "$Code evidence check$(if (-not $canFix) { ' WARN' }): $($badNames.Count) off-standard name(s) (pokey SKILL.md Evidence):"
    $badNames | ForEach-Object { "  $_ -> $(if ($suggest[$_]) { $suggest[$_] } elseif ($emptyNames -contains $_) { '(empty file: not renamed, see below)' } else { '(no suggestion: rename by hand)' })" }
    if ($canFix) { "  rename them all with: $checkCmd" }
  }
  if ($emptyFiles.Count) {
    $fail = $true; "$Code evidence check: $($emptyFiles.Count) empty file(s) cited (0 bytes: the capture failed; re-capture or drop them from results.json; -FixNames leaves them):"
    $emptyFiles | ForEach-Object { "  $($cited[$_.Name]): $($_.Directory.Name)/$($_.Name)" }
  }
  if ($dups.Count) { $fail = $true; "$Code evidence check: duplicate check id(s) in results.json (merge or renumber them): $($dups -join ', ')" }
  # a classless note hides defects (re-tests exempt)
  $noClass = @(@($res.checks) | Where-Object { $_.result -eq 'PASS_WITH_NOTE' -and -not ($_.verify -and "$($_.verify)" -notmatch '^Note audit') -and "$($_.observed)" -notmatch '^\s*\([a-d]\)\s' } | ForEach-Object { [string]$_.id })
  if ($noClass.Count) { $fail = $true; "$Code note check: PASS_WITH_NOTE without its class (observed starts with '(a|b|c|d) <why>', pokey SKILL.md step 5; else FAIL): $($noClass -join ', ')" }
  # devtools.py PRE_EXISTING: doc checks are never waived
  $preEx = @(@($res.checks) | Where-Object { $_.result -match '^PASS' -and "$(NoteFull $D $_ 'observed')" -match '(?i)\b(known|ignored?|waived?|accepted|not (our|my|this)|out of scope)\b.{0,40}pre-?existing|pre-?existing\b.{0,30}\b(bug|defect|issue|failure|error|overlap|problem|broken|behaviou?r)|\b(unrelated to|not caused by) (this|the) (change|task)\b' } | ForEach-Object { [string]$_.id })
  if ($preEx.Count) { $fail = $true; "$Code pre-existing check: a check of the doc is the task's own: a defect in it is FAIL (defect own; outside the change: new), never waived as pre-existing: $($preEx -join ', ')" }
  $kbBad = @(& $knownBad); if ($kbBad.Count) { $fail = $true; "$Code known-bug check: $($kbBad -join '; ')" }
  # OUT_OF_SCOPE only for a qa.outOfScope channel (run.json outOfScope wins), named in the check; an unbuilt app / web part runs on the local env
  $oosCh = @(@(if ($null -ne $run.outOfScope) { $run.outOfScope } else { Get-KitSetting 'qa.outOfScope' @() }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
  $oosBad = @(@($res.checks) | Where-Object { $_.result -eq 'OUT_OF_SCOPE' } | Where-Object { $t = "$($_.screen) $(NoteFull $D $_ 'what_was_done') $(NoteFull $D $_ 'observed')"; -not @($oosCh | Where-Object { $t -match "(?i)\b$([regex]::Escape($_))\b" }).Count } | ForEach-Object { [string]$_.id })
  if ($oosBad.Count) { $fail = $true; "$Code scope check: OUT_OF_SCOPE is only for a qa.outOfScope channel ($(if ($oosCh.Count) { $oosCh -join ', ' } else { 'none set' })), named in the check: $($oosBad -join ', '). A part with no build on the target: test it on the local env (phoney.ps1 build -Local + a lane, a ""local run""); no lane can run it -> NOT_TESTED phone-only (the owner decides)" }
  $shotBad = @(& $noShot); if ($shotBad.Count) { $fail = $true; "$Code screenshot check: human testing doc check(s) without a screenshot of the visible result (pokey SKILL.md Evidence: run each from the UI; JSON is extra, never instead): $($shotBad -join ', ')" }
  $gaps = @(& $docGaps); if ($gaps.Count) { if (-not $docSib) { $fail = $true }; "$Code doc check$(if ($docSib) { ' WARN (a sibling item tests the same task)' }): $($gaps -join ', '): $gapWhy" }
  if ($badTypes.Count) {
    $fail = $true; "$Code evidence check: $($badTypes.Count) file(s) listed but unsupported type (never published; supported: $($script:EvidenceExt -replace '^\^\\\.\(|\)\$$', '' -replace '\|', ' ')):"
    $badTypes | ForEach-Object { "  $_" }
  }
  $pr = @(& $prose)
  if ($pr.Count) { $fail = $true; "${prWhy}:"; $pr | ForEach-Object { "  $_" } }
  $prRun = @(& $proseRun); if ($prRun.Count) { "$Code prose WARN (run.json / bugs.json, shared by every package: fix there; does not hold this close):"; $prRun | ForEach-Object { "  $_" } }
  # the publish's upload launch, dry: a title the launcher or a CLI shim mangles fails here, not after the checks (retro tidy-6)
  $upTitle = "$(if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }) $Code - Test Results ($Date)"
  $upOut = @(& (Get-Python) -X utf8 $KitCmd.devtools doc $upTitle (Join-Path $D $Results) --type $rtype --dry-run 2>&1 | ForEach-Object { "$_" }); $upRc = $LASTEXITCODE
  $upGot = try { ((@($upOut) -match '^\{')[-1] | ConvertFrom-Json).title } catch { $null }
  if ($upRc -or $upGot -cne $upTitle) { $fail = $true; "$Code upload check ($rtype dry run, exit $upRc): $(if (-not $upRc -and $null -ne $upGot) { "title arrived as '$upGot', sent '$upTitle'" } else { (@($upOut) | Select-Object -Last 3) -join ' | ' }) - fix run.json title or the CLI, then re-run" }
  if ($fail) { "next: $(if ($pr.Count -or $noClass.Count -or $preEx.Count -or $dups.Count -or $kbBad.Count -or $oosBad.Count -or ($gaps.Count -and -not $docSib)) { "fix the text above in $Results$(if ($renamed.Count) { ' (renamed files already in it)' }), then " })ONE run: $checkCmd"; 'EXIT=1'; exit 1 }
  "$Code evidence check: OK ($($files.Count) files, standard names, supported types, none empty, unique check ids, note classes, prose$(if ($hDoc) { ', every human doc row covered, each with a screenshot' }))"
  if ($publishAfter) { $pass = @{} + $PSBoundParameters; foreach ($k in 'FixNames', 'Check') { $pass.Remove($k) }; Invoke-Finalize @pass; return }
  'EXIT=0'; exit 0
}
if ($lostList.Count) {
  throw "$Code`: $($lostList.Count) evidence file(s) listed in results.json are missing - nothing was published: $($lostList -join '; '). Save them or fix results.json, then re-run."
}
$pr = @(& $prose)
if ($pr.Count) { throw "${prWhy}, then re-run - nothing was published: $($pr -join '; ')" }
$kbBad = @(& $knownBad)
if ($kbBad.Count) { throw "$Code known-bug check: $($kbBad -join '; ') - nothing was published. Fix knownBug in results.json (or drop it: defect own / new), then re-run." }
$gaps = @(& $docGaps)
if ($gaps.Count -and -not $docSib) { throw "$Code doc check: $($gaps -join ', '): $gapWhy - nothing was published." }
if ($gaps.Count) { Write-Warning "$Code doc check: $($gaps -join ', ') stay empty until a sibling item of the task covers them" }
$fin = "$D/finalize.json"
$prev = if ((Test-Path $fin) -and -not $Force) { Get-Content $fin -Raw | ConvertFrom-Json } else { $null }
$title = if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }
$tester = if ($run.tester) { $run.tester } else { [Environment]::UserName }
$tr = $run.tracker
if ($tr.parent) { try { Add-KitQaParent ([string]$tr.parent) } catch { Write-Warning "QA parents index: $_" } }   # supervise reads it for new [Bug] tasks (30 d)
Push-Location $RunDir; $script:qaFinPushed = $true   # tracker CLIs run inside the run folder
trap { if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }; break }
function TrySay([scriptblock]$b, [string]$what) { try { & $b } catch { Write-Warning "tracker ($($KitConf.TrackerType)): $what failed: $_"; $null } }

# 1. Evidence: report type host (gdocs: Drive) or the run folder
$map = [ordered]@{ folderId = $prev.folderId; folderLink = $prev.folderLink; files = [ordered]@{}; local = $false; label = $null }
if ($prev.folderId) { foreach ($pf in (Get-KitProps $prev.files)) { if ($pf.Name -notin $vChanged) { $map.files[$pf.Name] = $pf.Value } } }
# evidence folder per run item ($runKey): never the task's dev-loop folder (<task>:evidence holds the local test files)
$ea = @('evidence', "$title $Code - test evidence ($Date)", '--type', $rtype, '--key', "${runKey}:evidence")
if ($run.driveParent) { $ea += '--parent', [string]$run.driveParent }   # run.json wins, else kit.local.json
if ($prev.folderId) { $ea += '--folder', [string]$prev.folderId }
$lf = New-KitTempFile '.txt'   # 80+ long paths broke the command-line limit
[IO.File]::WriteAllLines($lf, [string[]]@($files | Where-Object { -not $map.files[$_.Name] } | ForEach-Object FullName))
$evAll = @(& (Get-Python) -X utf8 $KitCmd.devtools @ea --files-from $lf 2>&1); $evRc = $LASTEXITCODE; Remove-Item -LiteralPath $lf -ErrorAction SilentlyContinue
$ev = @($evAll | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }); $evErr = @($evAll | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
if ($evErr) { $evErr | ForEach-Object { [Console]::Error.WriteLine($_) } }
if ($evRc) { throw "evidence upload ($rtype) failed (exit $evRc): $((@($evErr) + @($ev) | Select-Object -Last 4) -join ' | ') - nothing was published" }
$ev = ($ev | Out-String) | ConvertFrom-Json
if ($ev.folderId) {
  $map.folderId = $ev.folderId; $map.label = $ev.label; if ($ev.folderLink) { $map.folderLink = $ev.folderLink }
  foreach ($pf in (Get-KitProps $ev.files)) { $map.files[$pf.Name] = $pf.Value }
} else {
  $map = [ordered]@{ folderId = $null; folderLink = $D; files = [ordered]@{}; local = $true; label = 'Run folder' }
  foreach ($x in $files) { $map.files[$x.Name] = @{ id = $null; link = "$($x.Directory.Name)/$($x.Name)"; path = $x.FullName } }
}

# 2. Report
$checks = @($res.checks)
function Cnt($arr, $k) { @($arr | Where-Object { $_.result -eq $k }).Count }
$guideUrl = if ($item.guideUrl) { $item.guideUrl } elseif ($item.guideId -and $rtype -eq 'gdocs') { "https://docs.google.com/document/d/$($item.guideId)/edit" } elseif ($item.guideFile) { $item.guideFile } else { $null }
$missing = @($checks | ForEach-Object { $c = $_; @($c.evidence) | Where-Object { $_ -and -not $map.files[$_] -and [IO.Path]::GetExtension([string]$_) -match $script:EvidenceExt } | ForEach-Object { "$($c.id): $_" } })
if ($missing.Count) { throw "$Code`: $($missing.Count) evidence file(s) cited but not uploaded - nothing was published: $($missing -join '; '). Check the upload output above, then re-run." }
$html = Get-Command Build-QaReport -ErrorAction SilentlyContinue   # adapters/report-html.ps1
if ($html) { & $html -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File "$D/report.html" -Encoding utf8 }

$cells = @{}
$md = Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl -Cells $cells
$md | Out-File "$D/report.md" -Encoding utf8
$kept = $prev.doc -match '^https?://' -and $prev.doc -notmatch '/d//' -and "$($prev.report)" -in '', $rtype
# human testing doc: per-row results + "<env> run" (a re-publish of this item replaces its own; rows: over every run, devtools.py _runs_cells); else report by key
if ($kept) { $docUrl = $prev.doc }   # a re-run keeps the posted report
else {   # devtools doc; kept-file types stay in $D
  $pa = if ($hDoc) { [IO.File]::WriteAllText("$D/cells.json", (ConvertTo-Json $cells -Depth 4), [Text.UTF8Encoding]::new($false)); @("$D/report.md", '--key', "${pubKey}:testing-doc", '--run', "$D/cells.json", '--run-id', $runKey) }
    else { @("$D/report.$(if ($html -and $rtype -eq 'gdocs') { 'html' } else { 'md' })", '--key', "${pubKey}:qa-report") }
  $o = & (Get-Python) -X utf8 $KitCmd.devtools doc "$title $Code - Test Results ($Date)" $pa[0] $(if ($map.folderId) { $map.folderId } else { $D }) --type $rtype @($pa | Select-Object -Skip 1) --label "$(if ($item.target) { $item.target } else { $run.target })" 2>&1 | ForEach-Object { "$_" }
  $docUrl = if (-not $LASTEXITCODE) { @($o)[-1].Trim() } elseif ("$o" -match '(\S+) was uploaded but not shared') { Write-Warning "$o"; $Matches[1] }
  elseif ($prev.doc -match '^https?://') { Write-Warning "report publish ($rtype) failed - keeping the previous report $($prev.doc): $o"; $prev.doc }
  else { throw "report publish ($rtype) failed and there is no previous report (nothing was posted to the tracker): $o" }
}
$reportFile = if ($docUrl -notmatch '^https?://') { $docUrl }   # a kept file is attached to the task

# 4. Tracker per subtask, result rule (SKILL.md step 5)
$out = [ordered]@{ report = $rtype; folderId = $map.folderId; folderLink = $map.folderLink; files = $map.files; doc = $docUrl; subtasks = @(); watch = @() }
$closeStatus = if ($tr.closeStatus) { $tr.closeStatus } else { 'closed' }   # logical name (tracker.statuses)
$isLocal = [string]$(if ($item.localEnv) { $item.localEnv } else { $run.localEnv })   # local env item (ENV-FIX)
$bugList = if ($tr.list) { $tr.list } else { [string](Get-KitSetting 'tracker.list' '') }
# trackers that file an issue without a list / project: none, and vocab.json trackers.<type>.listless
$canCreate = [bool]$bugList -or $KitConf.TrackerType -eq 'none' -or [bool]$(if ($KitVocab) { (Get-KitMember $KitVocab.trackers ($KitConf.TrackerType)).listless })
# own vs new: tester's 'defect' wins, else a check id matching qa.newDefectIdRx ('' = none) is new; a knownBug FAIL is neither (tracked elsewhere)
$script:NewDefectRx = [string](Get-KitSetting 'qa.newDefectIdRx' '')
function Test-KnownBug($c) { [bool]"$($c.knownBug)".Trim() }
function Test-NewDefect($c) { if (Test-KnownBug $c) { return $false }; if ("$($c.defect)" -in 'new', 'own') { return "$($c.defect)" -eq 'new' }; [bool]$script:NewDefectRx -and [string]$c.id -match $script:NewDefectRx }
# a new defect with an inconclusive verify and no request / endpoint named is unproven: a WATCH note (watchy triage), never a [Bug]
function Test-Unproven($c) { (VerifyStatus $c.verify) -match '^inconclusive\b' -and "$($c.what_was_done) $($c.observed)" -cnotmatch '\b(?:GET|POST|PUT|PATCH|DELETE)\s+(?:https?:|/)|https?://\S|(?:^|[\s(`''"])/[\w.{}:-]+/' }
# bossy.ps1 bugbrief parses "### <id> — <screen>" + "**Saw:**"
$script:NtHold = @(Get-KitSetting 'qa.holdCauses' @() | Where-Object { $_ } | ForEach-Object { "$_" })   # NOT_TESTED causes no developer can fix: status kept, the owner decides
function Format-Check($c) {
  $ev = (@($c.evidence) | Where-Object { $_ } | ForEach-Object { if ($map.files[$_]) { "[$_]($($map.files[$_].link))" } else { $_ } }) -join ', '
  "### $($c.id) — $($c.screen)$(if ($c.flaky) { ' (flaky)' })`n**Steps:** $($c.what_was_done)`n`n**Saw:** $($c.observed)$(if ($c.cause) { " (cause: $($c.cause))" })`n`n**Independent re-test:** $(if ($c.verify) { $c.verify } else { 'not re-tested' })`n`n**Evidence:** $(if ($ev) { $ev } else { 'none' })`n"
}
function Format-Checks($list, [string]$heading) {
  if (-not @($list).Count) { return '' }
  "## $heading`n`n" + ((@($list) | ForEach-Object { Format-Check $_ }) -join "`n") + "`n"
}
# last item on a shared task decides
function SiblingHold($id) {
  $own = 0; $nt = 0; $ntH = 0; $err = $null; $pend = 0
  # a retest supersedes the FAILs its only list names: a sibling's other FAILs still hold (K68r)
  foreach ($c in @(@($run.items) | Where-Object { $_.code -ne $Code } | ForEach-Object code)) {
    $f = "$RunDir/$c/finalize.json"; if (-not (Test-Path $f)) { continue }
    $r = @((Get-Content $f -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.id -eq $id -and -not $_.noTracker }) | Select-Object -First 1
    $sup = $item.retest -and -not @($run.items | Where-Object { $_.code -eq $c }).retest   # an older round this retest redoes
    if ($r) { $own += if (-not $sup) { [int]$r.fail } elseif ($null -ne $r.failIds -and @($item.only | Where-Object { $_ }).Count) { @(@($r.failIds) | Where-Object { $_ -notin @($item.only) }).Count } else { 0 }; if ($sup) { continue }; $nt += [int]$r.notTested; $ntH += [int]$r.notTestedHold; $pend += [int]$r.pending; if ($r.bugError) { $err = "$c`: $($r.bugError)" } }
  }
  [pscustomobject]@{ fail = $own; notTested = $nt; notTestedHold = $ntH; bugError = $err; pending = $pend }
}
# ask = tracker parent, else run.json, else top level
$script:askCache = @{}
function Get-Ask($st) {
  if ($script:askCache.ContainsKey($st.id)) { return $script:askCache[$st.id] }
  $pid_ = try { [string](Get-TrackerTask $st.id).parent } catch { '' }
  if (-not $pid_) { $pid_ = [string]$tr.parent }
  $pname = if ($pid_) { try { [string](Get-TrackerTask $pid_).name } catch { '' } } else { '' }
  $script:askCache[$st.id] = [pscustomobject]@{ id = $pid_; name = $pname }
  $script:askCache[$st.id]
}
# one [Bug] per ask and run (bugs.json, mutex); edits only its own
function Add-NewDefects($st, [object[]]$defects) {
  # process.qaResult.newDefect: collector (default: one [Bug] per ask) | per-defect (one [Bug] each) | none (results report only)
  $ndMode = "$(Get-KitSetting 'process.qaResult.newDefect' 'collector')"
  if ($ndMode -eq 'none') { return [pscustomobject]@{ id = $null; none = $true } }
  $ask = Get-Ask $st; $key = if ($ask.id) { $ask.id } else { '-' }
  if ($ndMode -eq 'per-defect') { return Add-NewDefectEach $st $defects $ask }
  $h = (Get-KitHash ($RunDir.ToLower()) SHA256).Substring(0, 16)
  $mx = [Threading.Mutex]::new($false, "Global\kit-bugs-$h")
  $own = $true; try { $own = $mx.WaitOne(1000 * [int](Get-KitParam 'qa.bugsLockSec')) } catch [Threading.AbandonedMutexException] { $own = $true }   # abandoned = ours now
  if (-not $own) { $mx.Dispose(); throw "bugs.json of $RunDir is locked by another finalize for $(Get-KitParam 'qa.bugsLockSec') s (qa.bugsLockSec): re-run finalize -Code $Code" }
  try {
    $f = "$RunDir/bugs.json"
    $all = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
    $groups = [ordered]@{}; if ($all.groups) { foreach ($p in (Get-KitProps $all.groups)) { $groups[$p.Name] = $p.Value } }
    $s = if ($groups.Contains($key)) { $groups[$key] } else { [pscustomobject]@{ id = $null; url = $null; entries = @() } }
    $entries = @(@($s.entries) | Where-Object { $_ -and -not ($_.code -eq $Code -and $_.task -eq $st.id) })
    $grp = "New defects while testing $(if (($tl = TaskLink $st.id)) { "[$($st.name)]($tl)" } else { "$($st.name) ($($st.id))" }), package ``$Code``"
    $entries += [pscustomobject]@{ code = $Code; task = $st.id; taskName = $st.name; defects = @($defects | ForEach-Object { [pscustomobject]@{ label = "$Code $($_.id)"; sig = @(Get-KitDefectSigs $_); md = (Format-Check $_); group = $grp } }) }
    # an old-format entry (one md) stays one defect
    $ds = @($entries | ForEach-Object { if ($_.defects) { @($_.defects) } elseif ($_.md) { [pscustomobject]@{ label = $_.code; sig = @(); md = $_.md; group = '' } } })
    $mdAll = ($ds | ForEach-Object md) -join "`n"
    $n = ([regex]::Matches($mdAll, '(?m)^### ')).Count
    # "<prefix> <product> — <first defect> (+N more)": product = the part before " — " of a tested task, the ask or the run title
    $pn = @(@($entries | ForEach-Object taskName) + $ask.name + $title | Where-Object { $_ } | ForEach-Object { "$_" -replace '^\s*(?:[\w.-]+:\s*)?\[[^\]]*\]\s*', '' })
    $pAsk = "$(if ($ask.name) { $ask.name } else { $title })" -replace '^\s*\[[^\]]*\]\s*', ''
    $prod = (@(@($pn | Where-Object { $_ -match ' [—-] ' }) + $pAsk)[0] -split ' [—-] ', 2)[0].Trim()
    $first = [regex]::Match($mdAll, '(?m)^### \S+ — (.+?)(?: \(flaky\))?\r?$').Groups[1].Value
    $name = "$(Get-KitKindPrefix 'bug') $prod — $(if ($first) { $first } else { 'new defects' })$(if ($n -gt 1) { " (+$($n - 1) more)" })"   # flaky: each defect's '(flaky)' in the body, never the title (dec-keep-kit)
    $head = "QA run **$title** on ``$(if ($item.target) { $item.target } else { $run.target })`` ($Date) found defects outside the tested tasks' changes.`n`n- **Results report:** $(Format-KitMdLink $docUrl)$(if ($guideUrl) { "`n- **Tester guide** (check ids refer to it): $(Format-KitMdLink $guideUrl)" })"
    $bt = if ($s.id) { Clear-TrackerMemo $s.id; try { Get-TrackerTask $s.id } catch { $null } }; $cur = [string]$bt.name
    # replace an older finalize's own text
    $mine = [bool]($s.id -and -not $s.adopted -and (($s.name -and $cur -eq $s.name) -or "$($bt.description)".StartsWith("QA run **$title**")))
    # the open QA collector [Bug] under the ask gets a section, not a twin; a hand-made [Bug] never
    $r = Add-KitAskBug -Ask $ask.id -Key "qa-$(Split-Path $RunDir -Leaf)" -Name $name -Head $head -Defects $ds -List $bugList -Assignee $tr.owner -Id $s.id -Mine:$mine
    if (-not $r.id) { return $null }
    if ($r.action -ne 'updated') { $s | Add-Member -Force NoteProperty adopted ($r.action -eq 'appended') }   # another source's task: never renamed
    elseif (-not $s.adopted) {   # a hand-changed name stays
      if (-not $s.name -or -not $cur -or $cur -eq $s.name) { $null = Set-TrackerName $r.id $name } else { $name = $cur } }
    $s.id = $r.id; $s.url = $(if ($r.url) { $r.url } else { TaskLink $r.id })
    $s.entries = $entries; $s | Add-Member -Force NoteProperty name $name; $groups[$key] = $s
    [pscustomobject]@{ groups = $groups } | ConvertTo-Json -Depth 8 | Out-File $f -Encoding utf8
    [pscustomobject]@{ id = $s.id; url = $s.url }
  } finally { if ($own) { $mx.ReleaseMutex() }; $mx.Dispose() }
}
# per-defect: one [Bug] per defect under the ask, its own section key (ask + signature: a rerun updates it, a twin elsewhere
# is caught by the create duplicate check); <run>/bugs-each.json maps keys to ids
function Add-NewDefectEach($st, [object[]]$defects, $ask) {
  $f = "$RunDir/bugs-each.json"
  Invoke-KitLocked $f {
    $map = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $ids = @(foreach ($d in @($defects)) {
      $sg = @(Get-KitDefectSigs $d); $md = Format-Check $d; $k = "qa-$((Get-KitHash "$($ask.id)|$(if ($sg.Count) { $sg[0] } else { $md })" SHA256).Substring(0, 12))"
      $t = [regex]::Match($md, '(?m)^### \S+ — (.+?)(?: \(flaky\))?\r?$').Groups[1].Value
      $r = Add-KitAskBug -Ask $ask.id -Key $k -Name "$(Get-KitKindPrefix 'bug') $(if ($t) { $t } else { "$Code $($d.id)" })" -Head "QA run **$title** ($Date): $(Format-KitMdLink $docUrl)" -Defects @([pscustomobject]@{ label = "$Code $($d.id)"; sig = $sg; md = $md; group = '' }) -List $bugList -Assignee $tr.owner -Id $map[$k] -Mine:([bool]$map[$k]) -Single
      if ($r.id) { $map[$k] = $r.id; $r.id } })
    $map | ConvertTo-Json | Out-File $f -Encoding utf8
    if ($ids.Count) { [pscustomobject]@{ id = ($ids | Select-Object -Unique) -join ', ' } } else { $null }
  }
}
# no failedTesting status -> inProgress + comment
# knownBug FAILs: no [Bug]; one edited-in-place "Seen again" line per known task and run item; a failure is retried next run
function Send-KnownSeen($rec, [object[]]$known) {
  $rn = Split-Path $RunDir -Leaf; $lost = $false
  foreach ($kg in @($known | Group-Object { "$($_.knownBug)".Trim() })) {
    $seen = "Seen again in $rn ($Code $(($kg.Group | ForEach-Object id) -join ', ') on $(if ($item.target) { $item.target } else { $run.target }), $Date): $docUrl"
    if ($null -eq (TrySay { $null = Set-TrackerKitComment $kg.Name "qa-seen-$rn-$Code" $seen; $true } "comment on known bug $($kg.Name)")) { $lost = $true } }
  if ($rec -is [Collections.IDictionary]) { $rec.seenFailed = $lost } else { $rec | Add-Member -Force NoteProperty seenFailed $lost }
}
function Set-FailedTesting($rec, $st) {
  # process.qaResult.fail: role (default: the failed-testing status role, else inProgress) | reopen (inProgress) | none (status kept)
  $qf = "$(Get-KitSetting 'process.qaResult.fail' 'role')"
  if ($qf -eq 'none') { $rec.keptOpen = 'process.qaResult.fail none: status kept'; return }
  if ($qf -eq 'reopen') { $ok = TrySay { Set-TrackerStatus $st.id 'inProgress' 'failed testing'; $true } "set $($st.id) inProgress (process.qaResult.fail reopen)"
    if ($null -ne $ok) { $rec.failedTesting = $true; $rec.statusFallback = 'inProgress' } else { $rec.keptOpen = 'the tracker refused inProgress (see warning)' }; return }
  $sr = TrySay { "$(Set-TrackerStatus $st.id 'failedTesting')" } "set $($st.id) failedTesting"
  if ("$sr" -like 'SKIPPED*' -and "$sr" -notmatch 'has no failedTesting status') { $rec.keptOpen = "$sr".Substring(9); return }   # not a role transition from where it is now
  $ok = if ($null -ne $sr -and "$sr" -notmatch 'has no failedTesting status') { $true }   # a scope without it: the inProgress fallback below
  # a parent and its subtasks follow one result (owner, 2026-11-19: a subtask stayed in test while its parent failed testing)
  if ($null -ne $ok) { foreach ($kid in @(try { Clear-TrackerMemo $st.id; (Get-TrackerTask $st.id).subtasks } catch { }) | Where-Object { $_.id -and (Test-TrackerStatus "$($_.status)" 'promoted', 'inTest') }) { $null = TrySay { Set-TrackerStatus $kid.id 'failedTesting'; $true } "set subtask $($kid.id) failedTesting (its parent $($st.id) failed testing)" } }
  if ($null -eq $ok) {
    $ok = TrySay { Set-TrackerStatus $st.id 'inProgress' 'failed testing, no failedTesting status'; $true } "set $($st.id) inProgress (fallback: no failedTesting status)"
    if ($null -ne $ok) { $rec.statusFallback = 'inProgress'; $null = TrySay { Add-TrackerComment $st.id "Failed testing (this board has no 'failedTesting' status: map one in kit.local.json tracker.statusMap.<list>.failedTesting): moved back to in progress." } "comment on $($st.id)" }
  }
  if ($null -ne $ok) { $rec.failedTesting = $true } else { $rec.keptOpen = 'the tracker refused the failedTesting status (see warning)' }
}
# the task's MRs (run item + track) merged after this item started and not deployed to its target before then: a newer fix round it never tested
function Get-LateMerges($st) {
  # N3 run ids carry no time: run.json started; the legacy folder stamp yyyy-MM-dd-HHmmss for one version
  $t0 = if ((Split-Path $RunDir -Leaf) -match '^(\d{4}-\d{2}-\d{2}-\d{6})') { [datetimeoffset][datetime]::ParseExact($Matches[1], 'yyyy-MM-dd-HHmmss', $null) } elseif ($rs = try { (Read-KitText (Join-Path $RunDir 'run.json') | ConvertFrom-Json).started } catch { $null }) { [datetimeoffset]$rs }
  # the item's own start (owner 2026-11-25: a retest added hours later kept a passing task failed): its stamp, else its first evidence file
  $i0 = if ($item.added) { [datetimeoffset]$item.added } else { @(Get-ChildItem -LiteralPath (Join-Path $RunDir "$Code/evidence") -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { [datetimeoffset]$_.LastWriteTime } | Sort-Object)[0] }
  if ($i0 -and (-not $t0 -or $i0 -gt $t0)) { $t0 = $i0 }
  if (-not $t0) { return }
  $qaTgt = [string]$(if ($item.target) { $item.target } else { $run.target })
  $covered = @(Read-KitLog deploy-log ([datetime]::MinValue) | Where-Object { $_.event -eq 'record' -and "$($_.target)" -eq $qaTgt -and [datetimeoffset]$_.at -lt $t0 } | ForEach-Object { @($_.mrs) -split '[,\s]+' } | ForEach-Object { "$_" -replace '^.*/(?=[\w.-]+!\d+$)' })   # deployed there before the item ran: tested (repo!n, any group)
  $refs = @(@("$($st.mrs)" -split '[,\s]+') + @((Read-KitTracking).tasks["$($st.id)"].mrs) | Where-Object { "$_" -match '^[\w./-]+!\d+$' } | Select-Object -Unique)
  foreach ($ref in @($refs | Where-Object { ($_ -replace '^.*/(?=[\w.-]+!\d+$)') -notin $covered })) { $rp, $iid = "$ref" -split '!', 2; if ($rp -notmatch '/' -and $KitConf.GitlabGroup) { $rp = "$($KitConf.GitlabGroup)/$rp" }
    $m = try { Invoke-HostVerb 'mr.get' @{ repo = $rp; n = $iid } } catch { $null }
    $ma = $m.merged_at; if (-not $ma) { continue }
    if ($(if ($ma -is [datetime]) { [datetimeoffset]$ma } else { [datetimeoffset]::Parse("$ma", [Globalization.CultureInfo]::InvariantCulture) }) -gt $t0) { "$ref" } }
}
function Resolve-Outcome($rec, $st, [int]$pend) {
  $others = @(@($run.items) | Where-Object { $_.code -ne $Code -and @($_.subtasks | Where-Object { $_.id -eq $st.id }).Count -and -not (Test-Path "$RunDir/$($_.code)/finalize.json") } | ForEach-Object code)
  if ($others.Count) { $rec.waitingFor = $others; return }
  if (@($rec.late).Count) { $rec.keptOpen = "status unchanged: $(@($rec.late) -join ', ') merged after this run started (a newer fix round): retest after their deploy"; return }   # owner, 2026-11-19
  if ($pend -and -not $rec.fail) { $rec.keptOpen = "$pend check(s) pending in another lane"; return }   # an own FAIL decides now
  if (-not $rec.total) { $rec.keptOpen = 'no check carries this task id (subtask_id)'; return }   # 0 of 0 is not a pass
  $sib = SiblingHold $st.id
  if ($sib.pending -and -not ($rec.fail + $sib.fail)) { $rec.keptOpen = "$($sib.pending) check(s) of a sibling item pending in another lane"; return }
  # local env: untested = ENV-FIX
  if ($isLocal -and -not ($rec.fail + $sib.fail) -and ($rec.notTested + $sib.notTested)) { $rec.keptOpen = "local env ${isLocal}: $($rec.notTested + $sib.notTested) check(s) not tested: ENV-FIX + pokey.ps1 retest"; return }
  # undeployed, but every MR is N/A on this target: another product's change, never failedTesting
  if (-not ($rec.fail + $sib.fail + $sib.notTested) -and $rec.undeployed -and $rec.undeployed -eq $rec.notTested -and (Get-Command 'Invoke-Deployed' -ErrorAction SilentlyContinue)) {
    $qaTgt = [string]$(if ($item.target) { $item.target } else { $run.target }); $stMrs = @("$($st.mrs)" -split '[,\s]+' | Where-Object { $_ -match '^[\w./-]+!\d+$' })
    if ($stMrs.Count -and (Test-QaOtherTarget @(Invoke-Deployed -Mrs $stMrs -Target $qaTgt -Json | ConvertFrom-Json))) { $rec.keptOpen = "other product / target: $($stMrs -join ', ') N/A on $qaTgt (not undeployed): test it on its own target"; return }
  }
  $hold = [int]$rec.notTestedHold + [int]$sib.notTestedHold   # owner decides (close / retest)
  if ($rec.fail + $sib.fail + $rec.notTested + $sib.notTested - $hold) { Set-FailedTesting $rec $st; return }
  if ($hold) {
    $rec.keptOpen = "$hold check(s) not tested for a cause no developer can fix ($($script:NtHold -join ', ')): status kept, the owner decides"
    $rec.decision = TrySay { "$(& $KitCmd.orch decide ask -Run (Split-Path $RunDir -Leaf) -Agent "qa-$Code" -Item $st.id -Task $st.id -Question "$($st.id): $hold check(s) not tested ($($script:NtHold -join ' / ') causes; report $docUrl). Close it or retest?" -Options 'A: close it — testers see it done; the untested checks stay unproven', 'B: keep it open for a retest — it stays in test until a run covers those checks' -Recommend B -Context "the agent run could not test every check of $($st.id); the rest passed")" } "ask the owner about $($st.id)"
    return
  }
  if ($orphans.Count) { $rec.keptOpen = "$($orphans.Count) check(s) name no subtask of this item ($(@($orphans.subtask_id | Select-Object -Unique) -join ', ')): fix their subtask_id, finalize again"; return }   # never dropped
  if ($rec.bugError -or $sib.bugError) { $rec.keptOpen = "new defects have no [Bug] task ($(if ($rec.bugError) { $rec.bugError } else { $sib.bugError }))"; return }   # never close while a defect is untracked
  $cs = TrySay { "$(Set-TrackerStatus $st.id $closeStatus)" } "close $($st.id)"; if ("$cs" -like 'SKIPPED*') { $rec.ownPassed = $true; $rec.keptOpen = "own checks passed; it closes with its last open subtask (rollup): $cs" } elseif ($null -ne $cs) { $rec.closed = $true } else { $rec.keptOpen = 'the tracker refused the close (see warning)' }
}
# one tracker step per run (siblings deadlocked)
$fh = (Get-KitHash ($RunDir.ToLower()) SHA256).Substring(0, 16)
$fmx = [Threading.Mutex]::new($false, "Global\kit-finalize-$fh")
$fOwn = $true; try { $fOwn = $fmx.WaitOne(1000 * [int](Get-KitParam 'qa.finalizeLockSec')) } catch [Threading.AbandonedMutexException] { $fOwn = $true }
if (-not $fOwn) { $fmx.Dispose(); throw "another finalize of $RunDir held the tracker step for $(Get-KitParam 'qa.finalizeLockSec') s (qa.finalizeLockSec): re-run finalize -Code $Code" }
function Save-Fin { Write-KitAtomic $fin ($out | ConvertTo-Json -Depth 6) }
try {
$known = @(@($item.subtasks).id) + @(if ($item.dups) { (Get-KitProps $item.dups).Value })
$orphans = @(if (@($item.subtasks).Count -gt 1) { $checks | Where-Object { $_.subtask_id -and "$($_.subtask_id)" -notin $known -and $_.result -ne 'PASS' } })
foreach ($st in @($item.subtasks)) {
  $mine = @($checks | Where-Object { $_.subtask_id -eq $st.id })
  if (-not $mine.Count -and @($item.subtasks).Count -eq 1) { $mine = $checks }
  $dupOf = if ($item.dups) { [string](Get-KitMember $item.dups ($st.id)) } else { '' }   # run.json dups share the primary's checks
  if (-not $mine.Count -and $dupOf) { $mine = @($checks | Where-Object { $_.subtask_id -eq $dupOf }) }
  $allFails = @($mine | Where-Object { $_.result -eq 'FAIL' })
  $knownFails = @($allFails | Where-Object { Test-KnownBug $_ })
  $newDefects = @($allFails | Where-Object { Test-NewDefect $_ }); $unproven = @($newDefects | Where-Object { Test-Unproven $_ }); $newDefects = @($newDefects | Where-Object { -not (Test-Unproven $_) }); $ownFails = @($allFails | Where-Object { -not (Test-NewDefect $_) -and -not (Test-KnownBug $_) })
  $ntChecks = @($mine | Where-Object { $_.result -eq 'NOT_TESTED' }); $nt = $ntChecks.Count; $pend = Cnt $mine 'PENDING'
  $pass = (Cnt $mine 'PASS') + (Cnt $mine 'PASS_WITH_NOTE'); $oos = Cnt $mine 'OUT_OF_SCOPE'   # OUT_OF_SCOPE: qa.outOfScope
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $ownFails.Count; newDefects = $newDefects.Count; known = @($knownFails | ForEach-Object { "$($_.id) -> $("$($_.knownBug)".Trim())" }); notTested = $nt; outOfScope = $oos; pending = $pend; bug = $null; closed = $false; failedTesting = $false
    notTestedHold = @($ntChecks | Where-Object { "$($_.cause)" -in $script:NtHold }).Count; undeployed = @($ntChecks | Where-Object { "$($_.cause)" -eq 'undeployed' }).Count; unproven = @($unproven | ForEach-Object id); failIds = @($ownFails | ForEach-Object id) }
  # supervise reads watch: one WATCH + a watchy triage per unproven finding
  foreach ($u in $unproven) { $out.watch += [pscustomobject]@{ id = $u.id; task = $st.id; screen = $u.screen; env = [string]$(if ($item.target) { $item.target } else { $run.target }); observed = $u.observed } }
  $prevRec =if ($prev) { @($prev.subtasks | Where-Object { $_.id -eq $st.id }) | Select-Object -First 1 }
  if ($NoTracker) {
    # a dry run never overwrites a posted record
    if ($prevRec -and -not $prevRec.noTracker) { $out.subtasks += $prevRec; continue }
    $rec.noTracker = $true
  } else {
    if ($prevRec.noTracker -or $prevRec.commentFailed) { $prevRec = $null }   # failed comment: post again
    if ($prevRec.seenFailed -and $knownFails.Count) { Send-KnownSeen $prevRec $knownFails }   # a lost "Seen again" line is posted on the next run
    if ($prevRec.closed -or $prevRec.failedTesting) { $out.subtasks += $prevRec; continue }   # keep the first run's record
    $rec.late = @(Get-LateMerges $st)
    # sibling re-run: re-resolve only
    if ($prevRec) {
      $rec.bug = $prevRec.bug; if ($prevRec.seenFailed) { $rec.seenFailed = $true }
      $rec.bugError = if ($prevRec.bugError) { $prevRec.bugError } elseif ($newDefects.Count -and -not $rec.bug) { 'new defects have no [Bug] task' }
      $out.subtasks += $rec; Resolve-Outcome $rec $st $pend; Save-Fin; continue
    }
    $icon = if ($allFails.Count) { '❌' } elseif ($nt -or $pend) { '⚠️' } else { '✅' }
    $msg = "$icon " + $(if ($item.retest) { "Retest of the fix ($Date): $pass of $($mine.Count - $oos) checks pass" } else { "Test results ($(if ($item.target) { $item.target } else { $run.target }), $Date): $pass of $($mine.Count - $oos) checks pass" })
    if ($ownFails.Count) { $msg += ", $($ownFails.Count) of this task's checks failed ($(($ownFails | ForEach-Object id) -join ', '))" }
    if ($nt) { $msg += ", $nt not tested ($(($ntChecks | ForEach-Object id) -join ', '))" }
    if ($oos) { $msg += ", $oos out of scope" }
    if ($unproven.Count) { $msg += ", $($unproven.Count) unproven finding(s) ($(($unproven | ForEach-Object id) -join ', '): verify inconclusive, no request named) left to a monitoring triage, no [Bug]" }
    if ($pend) { $msg += ". $pend check(s) are tested next in another lane" }
    if ($rec.late.Count) { $msg += ". Status unchanged: $($rec.late -join ', ') merged after this run started; retest after their deploy" }
    if ($newDefects.Count -and $canCreate) {
      $b = TrySay { Add-NewDefects $st $newDefects } 'record the new defects in the [Bug] task'
      if ($b.none) { $msg += ". New defects ($(($newDefects | ForEach-Object id) -join ', ')) stay in the results report (process.qaResult.newDefect none)" }
      elseif ($b.id) { $rec.bug = $b.id; $msg += ". New defects ($(($newDefects | ForEach-Object id) -join ', ')) moved to [Bug] task $($b.id)" }   # one link: the report
      else { $rec.bugError = '[Bug] task could not be created'; Write-Warning "$($st.id): could not create the [Bug] task for $(($newDefects | ForEach-Object id) -join ', ')" }
    }
    elseif ($newDefects.Count) { $rec.bugError = 'no bug list configured'; Write-Warning "$($st.id): no tracker list for bug tasks (tracker.list) - task kept open" }
    if ($knownFails.Count) { $msg += ". Known defects seen again: $(($knownFails | ForEach-Object { "$($_.id) ($("$($_.knownBug)".Trim()))" }) -join ', ')"; Send-KnownSeen $rec $knownFails }
    $msg += if ($hDoc -and (Test-KitTaskDocLink $st.id) -eq $true) { '. Screenshots and evidence: the human testing doc in the description' } else { ". Screenshots and evidence: $docUrl" }   # testing doc links live only in the description
    $text = $msg   # one line; details live in the doc
    $posted = if ($reportFile) { TrySay { $null = Add-TrackerAttachment $st.id $reportFile $text; $true } "post the report on $($st.id)" }
    else { TrySay { $null = Set-TrackerKitComment $st.id 'qa-result' $text; $true } "comment on $($st.id)" }   # edits the last result comment
    $out.subtasks += $rec
    # comment failed: post next run
    if (-not $posted) { $rec.commentFailed = $true; $rec.keptOpen = 'the results comment was not posted (see warning): re-run finalize'; Save-Fin; continue }
    Save-Fin; Resolve-Outcome $rec $st $pend; Save-Fin; continue
  }
  $out.subtasks += $rec
}
Save-Fin
# indexes (STATE.md) spare re-reading tracker / run folder
$envName = [string]$(if ($item.target) { $item.target } else { $run.target }); $runName = Split-Path $RunDir -Leaf
foreach ($s in @($out.subtasks | Where-Object { $_.id })) {
  $er = [ordered]@{ env = $envName; run = $runName; code = $Code; pass = [int]$s.pass; fail = [int]$s.fail; notTested = [int]$s.notTested; failIds = @($s.failIds); bug = "$($s.bug)"; doc = $docUrl; at = (Get-KitStamp) }   # failIds, bug: outcome rows' came-back reason, [Bug] links
  try { Update-KitTaskIndex ([string]$s.id) { param($x) $x.envRuns = @(@($x.envRuns) | Where-Object { -not ($_.run -eq $runName -and $_.code -eq $Code) }) + $er } } catch { Write-Warning "task index $($s.id): $_" }
}
$rix = Join-Path $RunDir 'index.json'
try { Invoke-KitLocked $rix { $ri = Read-KitState $rix; if (-not $ri) { $ri = [ordered]@{ run = $runName; env = $envName; items = @{} } }; if ($ri.items -isnot [Collections.IDictionary]) { $ri.items = @{} }
  $ri.items[$Code] = [ordered]@{ tasks = @($out.subtasks.id); doc = $docUrl; pubKey = $pubKey; pass = [int](($out.subtasks | Measure-Object pass -Sum).Sum); fail = [int](($out.subtasks | Measure-Object fail -Sum).Sum); at = (Get-KitStamp) }
  Write-KitState $rix $ri } } catch { Write-Warning "run index ${rix}: $_" }
} finally { $fmx.ReleaseMutex(); $fmx.Dispose() }
"$Code report ($rtype): $docUrl"
if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, failed $($_.fail), new defects $([int]$_.newDefects), known $(@($_.known).Count), not tested $($_.notTested), out of scope $([int]$_.outOfScope), pending $($_.pending), bug $($_.bug), $(if ($_.closed) { 'closed' } elseif ($_.failedTesting) { "failed testing$(if ($_.statusFallback) { " (set $($_.statusFallback))" })" } elseif ($_.waitingFor) { "open (waiting for $(@($_.waitingFor) -join ', '))" } else { "open ($($_.keptOpen))" })" }
'EXIT=0'; $global:LASTEXITCODE = 0   # an in-session & call kept a stale one; no exit: dot-sourced callers go on
}

# ---- results: results.json written once (the tester); the workflow's changes as deltas by check id; held.json by the script
# a row's keys: testy.js CHECKS_SCHEMA + the keys the workflow adds (kitbag lint RESULT-KEYS keeps them in step)
$script:ResultRowKeys = 'id', 'subtask_id', 'case', 'screen', 'result', 'defect', 'knownBug', 'signature', 'cause', 'env_fix', 'what_was_done', 'observed', 'evidence', 'attempts', 'window', 'guideId', 'verify', 'flaky', 'firstAttempt'
function Invoke-Results {
param([Parameter(Mandatory, Position = 0)][ValidateSet('patch', 'hold')][string]$Action, [Parameter(Mandatory)][string]$RunDir, [Alias('Item')][Parameter(Mandatory)][string]$Code,
  [string]$Patch, [string]$Why, [string]$Summary, [string]$EnvFix, [string]$Results = 'results.json')
$dir = Join-Path $RunDir $Code
if ($Action -eq 'hold') {   # supervise + workers read it; the time is the script's
  Write-KitAtomic (Join-Path $dir 'held.json') ([ordered]@{ code = $Code; held = $Why; envFix = $(if ($EnvFix) { $EnvFix | ConvertFrom-Json } else { $null }); summary = $Summary; at = (Get-KitStamp) } | ConvertTo-Json -Depth 6)
  "held $Code`: $Why"; return
}
# -Patch { set: { <id>: { <field>: <value> } }, add: [<rows>], top: { findings, setup_changes, data_created } }
$p = $Patch | ConvertFrom-Json -AsHashtable; $f = Join-Path $dir (Split-Path $Results -Leaf)
$pAdd = @($p['add'] | Where-Object { $null -ne $_ })   # by index: a missing key read as .add is the hashtable's Add method
# only a scoped retry's file there (testy-wave2 T5): name it, never hand-write results.json
if (-not (Test-Path -LiteralPath $f)) { $rf = Join-Path $dir 'results-retry.json'
  throw "results patch: no $f (the tester writes it first)$(if ($f -ne $rf -and (Test-Path -LiteralPath $rf)) { "; only $rf (a scoped retry): patch it with -Results results-retry.json, finalize -Check -Results results-retry.json; never hand-write results.json" })" }
$r = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
$bad = @(foreach ($c in $pAdd + @($p.set.Values)) { if ($c) { $c.Keys | Where-Object { $_ -notin $script:ResultRowKeys } } }) | Select-Object -Unique
if ($bad.Count) { throw "results patch refused: unknown row key(s) $($bad -join ', ') (testy.js CHECKS_SCHEMA); nothing written" }
# an add row without id or a set value that is no object crashed (ContainsKey(null)): say how to change a field
if (@($pAdd | Where-Object { $_ -and -not ($_ -is [Collections.IDictionary] -and "$($_.id)") }).Count -or ($p.set -and -not ($p.set -is [Collections.IDictionary] -and -not @($p.set.Values | Where-Object { $_ -isnot [Collections.IDictionary] }).Count))) {
  throw "results patch refused: add rows need an id; to change fields of a check use set: { <id>: { <field>: <value> } }; nothing written" }
$seen = @{}; foreach ($c in $r.checks) {   # unique ids as the workflow makes them (testy.js run-item): a, b ... suffix, guideId
  $id = "$(if ($c.id) { $c.id } else { 'check' })"; $n = $id; $k = 1; while ($seen.ContainsKey($n)) { $n = "$id$([char](97 + $k++))" }
  if ($n -ne $id) { $c.guideId = $id }; $c.id = $n; $seen[$n] = $c }
$setIds = if ($p.set) { @($p.set.Keys) } else { @() }
$miss = @(foreach ($id in $setIds) { if (-not $seen.ContainsKey($id)) { $id } else { foreach ($kv in $p.set[$id].GetEnumerator()) { $seen[$id][$kv.Key] = $kv.Value } } })
if ($miss.Count) { throw "results patch refused: no check $($miss -join ', ') in $f; nothing written" }
foreach ($c in $pAdd) { if ($c) { if ($seen.ContainsKey($c.id)) { foreach ($kv in $c.GetEnumerator()) { $seen[$c.id][$kv.Key] = $kv.Value } } else { $r.checks += $c; $seen[$c.id] = $c } } }
if ($p.top) { foreach ($kv in $p.top.GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
Write-KitAtomic $f ($r | ConvertTo-Json -Depth 8)
"patched $Code`: $($setIds.Count) changed, $($pAdd.Count) added, $(@($r.checks).Count) checks"
}

# ---- retest: RETEST item for a live fix (same -Code replaces it)
function Invoke-Retest {
param(
  [Parameter(Mandatory)][string]$RunDir, [Alias('Item')][Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][string]$Code,
  [string]$Title, [Alias('Mr')][string]$Mrs = '', [string[]]$Only, [string]$Lane = ''   # a qa.lanes lane; '' = the first lane
)
$ErrorActionPreference = 'Stop'
$Lane = if ($Lane) { (Resolve-QaLane $Lane).name } else { @((Get-QaLanes).Keys)[0] }
# -Only arrives as one string
$Only = @(Split-KitList $Only)
$t = Get-TrackerTask $Task
if (-not $t.name) { throw "cannot read task $Task (tracker $($KitConf.TrackerType): CLI auth / config?)" }
$c = @(try { Get-TrackerComments $Task } catch { @() })
# rerun ids: ### headings
if (-not $Only) {
  foreach ($txt in @([string]$t.description) + @($c | Sort-Object date -Descending | ForEach-Object { [string]$_.text })) {
    $ids = @([regex]::Matches($txt, '(?m)^###\s+(\S+)\s+[—-]\s+') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($ids.Count) { $Only = $ids; break }
  }
}
if (-not $Title) { $Title = "RETEST $($t.name -replace "^$([regex]::Escape((Get-KitKindPrefix 'bug')))\s*", '')" }
$md = "# $($t.name)`n`nTask: $($t.url)  Status: $($t.status)`n`n" +
  "RETEST of the fix: run the failed checks ($($Only -join ', ')) again on the deployed build, same steps and data where possible. " +
  "Check the fix is deployed first (pokey.ps1 deployed -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.description)`n`n## Comments (oldest first)`n"
foreach ($x in $c) { $md += "`n---`n**$($x.user)** $($x.date)`n`n$($x.text)`n" }
New-Item -ItemType Directory -Force "$RunDir/tasks" | Out-Null
$gf = "$RunDir/tasks/$Task.md"; Set-Content $gf $md -Encoding utf8
$old = @('finalize.json', 'held.json', 'results.json' | ForEach-Object { Join-Path "$RunDir/$Code" $_ } | Where-Object { Test-Path $_ })
if ($old.Count) {   # reused code: archive the earlier round
  $arc = Join-Path "$RunDir/$Code" (New-KitName round "" "$RunDir/$Code"); New-Item -ItemType Directory -Force $arc | Out-Null
  foreach ($f in $old) { Move-Item -LiteralPath $f -Destination $arc }
  "archived the earlier round of $Code ($(($old | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) to $arc"
}
$r = Get-Content "$RunDir/run.json" -Raw | ConvertFrom-Json
$items = @($r.items | Where-Object { $_.code -ne $Code })
$items += [pscustomobject]@{ code = $Code; lane = $Lane; title = $Title; guideFile = $gf; retest = $true; added = (Get-KitStamp); only = @($Only); subtasks = @([pscustomobject]@{ id = $Task; name = $t.name; mrs = $Mrs }) }
$r.items = $items
Write-KitAtomic "$RunDir/run.json" ($r | ConvertTo-Json -Depth 8)
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir/run.json - launch: Workflow testy { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
}

# the tester guide doc: the process docs (lib.ps1 Get-KitProcessDocs) entry qa.guideDoc (unset: the first); none = the task text guides
function Get-QaGuideDocSpec {
  $docs = @(Get-KitProcessDocs)
  if (-not $docs.Count) { return $null }
  $want = [string](Get-KitSetting 'qa.guideDoc' '')
  $at = if ($want) { [array]::IndexOf(@($docs.key), $want) } else { 0 }
  if ($at -lt 0) { throw "qa.guideDoc '$want' is not a process docs key ($(@($docs.key) -join ', '))" }
  $d = $docs[$at]; [pscustomobject]@{ key = $d.key; label = $d.label; rx = $d.linkRx; legacy = $(if ("$($d.key)" -like 'testing-*') { @{ 'testing-doc' = 'human'; 'testing-ai' = 'ai' }["$($d.key)"] } else { @('human', 'ai')[[Math]::Min($at, 1)] }) }
}
# the guide doc's URL: a "<label>: [x](url)" line in the task text, else the tracking file's docs.<key> (older records: docs.human / docs.ai)
function Get-QaGuideDocUrl([string]$Description, $Track, $Spec) {
  if (-not $Spec) { return $null }
  if ($Description -match "(?im)(?:$($Spec.rx)):\*{0,2}\s*\[[^\]]*\]\((?<u>https?://[^)\s]+)\)") { return $Matches.u }
  $v = if ($Track.docs) { $x = (Get-KitMember $Track.docs ($Spec.key)); if (-not $x) { $x = (Get-KitMember $Track.docs ($Spec.legacy)) }; $x }; if ($v) { "$v" }
}

# ---- prepare: a test-only run from a job (lead.md L1 Selection): run.json, lead-notes.md skeleton, Left out; -RunDir: print it
# kept testing doc -> the run's guide: its head + the newest "## <env> run <date>" / "## Round <n> — <date>" section without its
# "### Evidence index", older runs only named (owner 2026-11-22: a 1494-line guide filled testers' context; 2026-11-25: one run's
# 76 evidence links + a Round section = 8k tokens per tester read)
function Copy-QaGuide([string]$Kept, [string]$Dest) {
  $gl = @(Get-Content -LiteralPath $Kept -Encoding utf8); $rx = '^## (?!#).*\b(?:run|round \d+\W+)\s*(\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?)'
  $runs = @(for ($i = 0; $i -lt $gl.Count; $i++) { if ($gl[$i] -match $rx) { [pscustomobject]@{ at = $i; key = $Matches[1] } } })
  if (-not $runs.Count) { Copy-Item -LiteralPath $Kept $Dest; return }
  $nw = @($runs | Sort-Object key -Descending)[0]; $end = $gl.Count
  for ($i = $nw.at + 1; $i -lt $gl.Count; $i++) { if ($gl[$i] -match '^## (?!#)') { $end = $i; break } }
  $sec = @($gl[$nw.at..($end - 1)]); $ev = @(for ($i = 0; $i -lt $sec.Count; $i++) { if ($sec[$i] -match '^###\s+Evidence index') { $i } })[0]; $evN = 0
  if ($null -ne $ev) { $evEnd = $sec.Count; for ($i = $ev + 1; $i -lt $sec.Count; $i++) { if ($sec[$i] -match '^#{2,3} ') { $evEnd = $i; break } }; $evN = @($sec[$ev..($evEnd - 1)] | Where-Object { $_ -match '^\|\s*\[' }).Count
    $sec = @(if ($ev) { $sec[0..($ev - 1)] }) + @(if ($evEnd -lt $sec.Count) { $sec[$evEnd..($sec.Count - 1)] }) }
  $older = $runs.Count - 1; $cut = @(if ($older) { "older runs ($older)" }; if ($evN) { "the newest run's evidence index ($evN files)" }) -join ' and '
  $body = @(if ($runs[0].at) { $gl[0..($runs[0].at - 1)] }) + $sec + @(if ($cut) { '', "> Not copied: $cut. In $Kept (read a range when a retest needs one)" })
  Set-Content -LiteralPath $Dest -Encoding utf8 ($body -join "`n")
}
# deploy rows -> not live / local parts: an MR with no build on the target (NO-TARGET) next to a live one runs on the local env
function Split-QaLiveParts($Dep) {
  $notLive = @($Dep | Where-Object { $_.state -notmatch '^(DEPLOYED|N/A|MANUAL)' }); $noTgt = @($notLive | Where-Object { $_.state -eq 'NO-TARGET' })
  if ($noTgt.Count -and $noTgt.Count -eq $notLive.Count -and @($Dep | Where-Object { $_.state -match '^DEPLOYED' }).Count) { return @{ notLive = @(); local = @($noTgt | ForEach-Object { "$($_.mr)" }) } }
  @{ notLive = $notLive; local = @() }
}
# owner 2026-11-26: the tasks this one waits on (tracker waits-on) whose MRs are not live on the target: it stays untested, never failedTesting
function Get-QaWaitsOnNotLive([string]$Tid, $Tk, [string]$Target, $DepFn) {
  foreach ($w in @((Get-KitTaskWaitsOn $Tid $Tk).waitsOn)) { $wm = @(@((Read-KitState (Get-KitTaskFile $w)).track.mrs) | Where-Object { $_ })
    if ($wm.Count -and @((Split-QaLiveParts @(& $DepFn -Mrs $wm -Target $Target -Json | ConvertFrom-Json)).notLive).Count) { $w } }
}
# every row N/A, at least one proven for this target (deployed-checks "n/a for <t>": another branch or no path under it): another product's change
function Test-QaOtherTarget($Dep) { $rows = @($Dep | Where-Object { $_ }); $rows.Count -and -not @($rows | Where-Object { "$($_.state)" -ne 'N/A' }).Count -and @($rows | Where-Object { "$($_.detail)" -like 'n/a for *' }).Count }
function Invoke-Prepare {
param([string]$Job, [string]$RunDir)
$ErrorActionPreference = 'Stop'
$printRun = { param($Run) "RUN $(ConvertTo-Json -InputObject $Run -Depth 8 -Compress)" }   # the workflow reads this one line
if ($RunDir) { $rf = Join-Path $RunDir 'run.json'; if (-not (Test-Path -LiteralPath $rf)) { throw "no run.json in $RunDir" }; return & $printRun (Get-Content -LiteralPath $rf -Raw -Encoding utf8 | ConvertFrom-Json) }
if (-not $Job) { 'usage: pokey.ps1 prepare -Job <job JSON | file> | -RunDir <run>'; exit 2 }
$jb = (& { if (Test-Path -LiteralPath $Job -PathType Leaf) { Get-Content -LiteralPath $Job -Raw -Encoding utf8 } else { $Job } }) | ConvertFrom-Json -AsHashtable
if (-not ($jb.runFolder -and $jb.target)) { throw 'prepare: the job needs runFolder and target' }
# <testy-id> -> testy-<name words> (owner 2026-11-24: testy-retest; a tie -2; never a date or counter)
$newRunId = { param($IdKind) New-KitName $IdKind "$($jb.name)" }
if ("$($jb.runFolder)" -match '<(?<k>[a-z]+)-id>') { $jb.runFolder = "$($jb.runFolder)" -replace '<[a-z]+-id>', (& $newRunId $Matches.k) }
# a date placeholder (<yyyy-MM-dd>, ...) or a leading '-' (a caller's stamp expanded to nothing): the testy run name, never a date
$dir = "$($jb.runFolder)"; if ($dir -match '<[yMdHms][^<>]*>') { $dir = $dir -replace '(?:<[yMdHms][^<>]*>[-_]?)+', "$(& $newRunId testy)-" -replace '-(?=$|[\\/])', '' }
if (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Split-Path $KitConf.Kit) $dir }   # testy's relative runFolder is from the workspace root, never this cwd (the kit: <kit>/.claude/.runtime, retro 1549)
if ((Split-Path $dir -Leaf) -like '-*') { $dir = Join-Path (Split-Path $dir -Parent) "$(& $newRunId testy)$(Split-Path $dir -Leaf)" }
if (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { throw "prepare: $dir exists with files: pass another name, or launch with { runDir }" }   # an empty one is reused
New-Item -ItemType Directory -Force (Join-Path $dir 'guides') | Out-Null; $dir = (Resolve-Path -LiteralPath $dir).Path -replace '\\', '/'
# 1. candidates: lists x statuses, plus tasks, minus exclude; mine = the tracker owner's
$lists = @($jb.lists | Where-Object { $_ }); if (-not $lists.Count) { $lists = @(@(Get-KitValue 'trackerLists' @()) | Where-Object { $_ }) }; if (-not $lists.Count) { $lists = @('') }
# default: deployed work's role, inTest, else the next on-role down (a tracker without inTest / promoted: tracker.statuses.<role> null)
$sts = @($jb.statuses | Where-Object { $_ }); if (-not $sts.Count) { $sts = @(@(@('inTest', 'promoted', 'review', 'inProgress') | Where-Object { -not (Test-TrackerStatusOff $_) })[0]) }
$ids = @($jb.tasks | Where-Object { $_ }); $stPick = @($jb.statuses | Where-Object { $_ })
$cand = [ordered]@{}
if ($ids.Count) {
  # named tasks: exactly those ids plus their subtasks (in statuses when given, else open ones), never a list sweep
  $subIn = { param($Sub) if ($stPick.Count) { [bool]@($stPick | Where-Object { (Test-TrackerStatus "$($Sub.status)" $_) -or "$($Sub.status)" -ieq $_ }).Count } else { -not (Test-TrackerStatus "$($Sub.status)" 'closed') } }
  foreach ($tid in $ids) { $cand["$tid"] = ''; foreach ($sub in @((Get-TrackerTask "$tid").subtasks | Where-Object { $_.id })) { if (& $subIn $sub) { $cand["$($sub.id)"] = '' } } }
} else { foreach ($ls in $lists) { foreach ($st in $sts) { foreach ($row in @(Get-TrackerTasks "$ls" "$st")) { if ($row.id) { $cand["$($row.id)"] = "$ls" } } } } }
# tracked tasks a list sweep misses (a ClickUp list omits subtasks; another list): merged within deploy.doneLookbackDays, live status
# in a selected role (2026-11-25: 18 subtasks in "for test" never selected, not even left out)
$nTracked = 0
if (-not $ids.Count -and -not @($jb.lists | Where-Object { $_ }).Count) { $lbD = [double](Get-KitParam 'deploy.doneLookbackDays')
  foreach ($o in @((Read-KitTracking).tasks.Values | Where-Object { $_.task -and $_.done -and $_.doneAt -and -not $cand.Contains("$($_.task)") -and ((Get-Date) - [datetime]$_.doneAt).TotalDays -le $lbD })) {
    $lt = try { Get-TrackerTask "$($o.task)" } catch { $null }
    if ($lt -and @($sts | Where-Object { (Test-TrackerStatus "$($lt.status)" $_) -or "$($lt.status)" -ieq $_ }).Count) { $cand["$($o.task)"] = ''; $nTracked++ } } }
foreach ($tid in @($jb.exclude | Where-Object { $_ })) { $cand.Remove("$tid") }; $nList = $cand.Count - $nTracked
$owner = if ($jb.mine) { "$(Get-TrackerOwner)" }
$tgtRules = Get-KitSetting "qa.targets.$($jb.target)" $null
$gSpec = Get-QaGuideDocSpec
$items = [Collections.Generic.List[object]]::new(); $left = [Collections.Generic.List[object]]::new(); $byDoc = @{}
foreach ($tid in @($cand.Keys)) {
  $tk = Get-TrackerTask $tid; $nm = "$($tk.name)"
  $out = { param($Why) $left.Add([ordered]@{ id = $tid; name = $nm; reason = $Why }) }
  if (-not $nm) { & $out 'not readable in the tracker'; continue }
  if ($owner -and -not (@($tk.assignees) -contains $owner)) { continue }
  # 2. MRs (tracking, else MR links in the description) and the human testing doc
  $tf = Get-KitTaskFile $tid; $trk = if (Test-Path -LiteralPath $tf) { Get-Content -LiteralPath $tf -Raw | ConvertFrom-Json }
  $mrs = @(@($trk.track.mrs) | Where-Object { $_ }); if (-not $mrs.Count) { $mrs = @([regex]::Matches("$($tk.description)", 'https?://\S+?/(?:-/merge_requests|pulls?|pull-requests)/\d+') | ForEach-Object { $mu = ConvertFrom-MrUrl $_.Value; if ($mu) { "$(($mu.repo -split '/')[-1])!$($mu.n)" } } | Select-Object -Unique) }
  $doc = Get-QaGuideDocUrl "$($tk.description)" $trk $gSpec
  if (-not $mrs.Count) { & $out 'no MRs (tracking or task links)'; continue }
  if ($gSpec -and -not $doc) { & $out "no `"$($gSpec.label):`" link"; continue }
  if (-not $doc) { $doc = "task:$tid" }   # no guide doc configured (process.docs): the task text is the guide
  # 3. target: the job's target names a targets.local.json entry, else the first qa.targets rule that matches
  $it = [ordered]@{ code = ''; title = $nm; guideFile = ''; lane = @((Get-QaLanes).Keys)[0]; subtasks = @([ordered]@{ id = $tid; name = $nm; mrs = ($mrs -join ', ') }) }
  if ($tgtRules) {
    $repoNames = @($mrs | ForEach-Object { ($_ -split '!')[0] })
    # asked once, only by a pathRegex rule; a cut list (host overflow, an unpaged 100-file page) cannot prove a path is absent: that rule is undecided (K68s)
    $mrPaths = { if ($null -eq $script:QaMrPaths) { $script:QaMrCut = @(); $script:QaMrPaths = @(foreach ($m in $mrs) { $r0 = $m -split '!'; $ch = Invoke-HostVerb 'mr.changes' @{ repo = (Get-HostProject $r0[0] -Raw); n = $r0[1] }; if ($ch.overflow -or @($ch.changes).Count -ge 100) { $script:QaMrCut += $m }; @($ch.changes.new_path) }) }; $script:QaMrPaths }
    $script:QaMrPaths = $null; $script:QaMrCut = @(); $cutRule = $null
    $hit = @(foreach ($rule in @($tgtRules)) { if ((-not $rule.lists -or @($rule.lists) -contains $cand[$tid]) -and (-not $rule.repos -or @($repoNames | Where-Object { $_ -in @($rule.repos) }).Count) -and (-not $rule.nameRegex -or $nm -match $rule.nameRegex)) {
        if (-not $rule.pathRegex -or @(& $mrPaths | Where-Object { $_ -match $rule.pathRegex }).Count) { $rule; break }
        if ($script:QaMrCut.Count) { $cutRule = $rule; break } } })[0]
    if ($cutRule) { & $out "qa.targets.$($jb.target) rule -> $($cutRule.target): $($script:QaMrCut -join ', ') changes list cut by the host, pathRegex unprovable (name the task's target in the job)"; continue }
    if (-not $hit) { & $out "no qa.targets.$($jb.target) rule matches"; continue }
    $it.target = "$($hit.target)"; if ($hit.localEnv) { $it.localEnv = "$($hit.localEnv)" }
  } else { $it.target = "$($jb.target)"; if ($null -eq $script:QaJobLocal) { $script:QaJobLocal = Get-TargetLocalEnv $jb.target }; if ($script:QaJobLocal) { $it.localEnv = $script:QaJobLocal } }   # a local target: envy deploys what is missing (lead)
  # 4. live: every MR deployed on the target (N/A, MANUAL count as in; all N/A for this target: left out); a local env: its own check (lead)
  $depFn = Get-Command 'Invoke-Deployed' -ErrorAction SilentlyContinue   # adapters/deployed-checks.ps1
  if (-not $it.localEnv -and $depFn) {
    $dep = @(& $depFn -Mrs $mrs -Target $it.target -Json | ConvertFrom-Json)
    if (Test-QaOtherTarget $dep) { & $out "other product / target: $($mrs -join ', ') N/A on $($it.target) (no change for it)"; continue }
    $lp = Split-QaLiveParts $dep; $notLive = $lp.notLive; if ($lp.local.Count) { $it.localParts = $lp.local }
    if ($notLive.Count) { & $out "not live on $($it.target): $(@($notLive | ForEach-Object { "$($_.mr) $($_.state)" }) -join ', ')"; continue }
    $woOff = @(Get-QaWaitsOnNotLive $tid $tk $it.target $depFn)
    if ($woOff.Count) { & $out "waits on $($woOff -join ', '): not deployed on $($it.target) yet (untested, not failedTesting)"; continue }
  }
  if ($byDoc[$doc]) { $byDoc[$doc].subtasks += $it.subtasks[0]; continue }   # tasks sharing a doc = one item
  $it.code = "T$($items.Count + 1)"; $gf = "$dir/guides/$($it.code).md"; $kept = Join-Path (Get-KitPath docs) "$($tid)_testing-doc.md"
  if (Test-Path -LiteralPath $kept) { Copy-QaGuide $kept $gf }
  elseif ($doc -like 'task:*') { Set-Content -LiteralPath $gf -Encoding utf8 "# Guide: $nm`n`nNo testing doc configured (process.docs): test what the task text below asks.`n`n$($tk.description)" }
  else { Set-Content -LiteralPath $gf -Encoding utf8 "# Guide: $nm`n`n$($gSpec.label): $doc (no kept copy: read the doc itself, fully, before the first check)" }
  $it.guideFile = $gf; if ($doc -notlike 'task:*') { $it.guideUrl = $doc }; $items.Add($it); $byDoc[$doc] = $it
}
# 5. run.json + lead-notes.md (fixed headings; testers and the lead append with lead-notes add)
# the title: 25 words at most (capped here; finalize skips the report H1)
# N3 label '<KEY> <short title>' (+N more tasks): the run's name on the board and dashboard; a task without a key: none (the old label)
$lb = if (($lk = Get-KitTaskKey "$(@(@($items)[0].subtasks)[0].id)") -and (Remove-KitNameKey "$(@($items)[0].title)") -match '^(?:\[[^\]]+\]\s*)?(?:[^:]{1,30}:\s*)?(?<t>.+)$') { "$lk $(Limit-KitWords $Matches.t 7)$(if (@($items).Count -gt 1) { " +$(@($items).Count - 1)" })" }   # dec-60: the key from the kit table
$run = [ordered]@{ name = "$($jb.name)"; label = "$lb"; started = (Get-KitStamp); title = (Limit-KitWords "$($jb.target): $(@($items | ForEach-Object title) -join '; ')" 25 "+$(@($items).Count)-items"); target = "$($jb.target)"; kitDir = "$($jb.kitDir)"; runDir = $dir; mandate = @($jb.runSettings.mandate); tracker = [ordered]@{ list = "$(@($lists)[0])" }; items = @($items); left = @($left) }
foreach ($rk in @(@($jb.runSettings.Keys) | Where-Object { $_ -and $_ -notin $run.Keys })) { $run[$rk] = $jb.runSettings[$rk] }
Write-KitAtomic "$dir/run.json" ($run | ConvertTo-Json -Depth 8)
$cell = { param($Text) "$Text" -replace '\s+', ' ' -replace '\|', '\|' }
$ln = @("# Lead notes: $(Split-Path $dir -Leaf)", "**Result:** $($items.Count) in, $($left.Count) left out of $($cand.Count) $($sts -join ' / ') task(s) on $($jb.target) (lists $nList, tracked off-list $nTracked)", '', '## Prerequisites', '', '| Item | Flags / accounts / data ids | State |', '|---|---|---|') +
  @($items | ForEach-Object { "| $($_.code) $(& $cell $_.title) | from the guide | $(if ($_.localEnv) { "envy.ps1 status -Env $($_.localEnv): every MR commit running?" } else { 'to check' }) |" }) + @('', '## Left out', '', '| Task | Reason |', '|---|---|') +
  @($left | ForEach-Object { "| $($_.id) $(& $cell $_.name) | $(& $cell $_.reason) |" }) + @('', '## Answers (newest last)', '')
Write-KitAtomic "$dir/lead-notes.md" (($ln -join "`n") + "`n")
"prepared $dir`: $($items.Count) item(s), $($left.Count) left out of $($cand.Count) (lists $nList, tracked off-list $nTracked)"
& $printRun $run
}
# testers ask and the lead answers in lead-notes.md: one line each under "## Answers (newest last)"
function Invoke-LeadNotes {
param([Parameter(Position = 0)][ValidateSet('add')][string]$Action, [Parameter(Mandatory)][string]$RunDir, [Alias('Item')][Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Text)
$nf = Join-Path $RunDir 'lead-notes.md'; if (-not (Test-Path -LiteralPath $nf)) { throw "no lead-notes.md in $RunDir (pokey.ps1 prepare writes it)" }
Invoke-KitLocked $nf { Add-Content -LiteralPath $nf -Encoding utf8 "- $(Get-Date -Format 'HH:mm') $Code`: $($Text -replace '\s+', ' ')" }
"noted $Code in $nf"
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'seat' { Invoke-KitVerb Invoke-Seat $__rest }
    'api' { Invoke-KitVerb Invoke-Api $__rest }
    'finalize' { $KitVerbOnError = { 'EXIT=1' }; Invoke-KitVerb Invoke-Finalize $__rest }   # a crash exits 1 (Invoke-KitVerb), EXIT=1 first
    'deployed' { Invoke-KitVerb Invoke-Deployed $__rest }   # adapters/deployed-checks.ps1
    'annotate' { Invoke-KitVerb Invoke-Annotate $__rest }   # adapters/annotate.ps1
    'evidence' { Invoke-KitVerb Invoke-Evidence $__rest }   # skills/crafty/adapters/video.ps1
    'retest' { Invoke-KitVerb Invoke-Retest $__rest }
    'prepare' { Invoke-KitVerb Invoke-Prepare $__rest; exit 0 }   # pwsh -File would exit with a helper's git code (128); a crash exits 1 inside
    'lead-notes' { Invoke-KitVerb Invoke-LeadNotes $__rest }
    'results' { Invoke-KitVerb Invoke-Results $__rest }
    'ui' { if ("$($__rest[0])" -eq 'login') { Invoke-KitVerb Invoke-UiLogin @($__rest | Select-Object -Skip 1) } else { Invoke-KitVerb Invoke-Ui $__rest } }   # adapters/ui-android.ps1
    'user' { Invoke-KitVerb Invoke-User $__rest }
    { $_ -in '-h', '--help', 'help', '-?' } { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }   # the header only
  }
}
