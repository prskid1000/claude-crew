<#
pokey.ps1: pokey commands (SKILL.md tester steps 1-6, lead L1-L3). pwsh 7: & <kit>/skills/pokey/pokey.ps1 <verb> [args]
  seat acquire|release|status ...                  memory seat + item claim
  deployed -Mrs <repo>!<iid>,... [-Detail] [-Json] [-TimeoutSec 100]  live on a test env? (goody deploys)
  api -Target <t> -As <user> -Method <M> -Path '/...' [-Body <json>] [-ContentType <type>] [-Save <name> -OutDir <abs dir>]
  finalize -RunDir <run> -Code <code> [-Check -FixNames] [-NoTracker] [-ExpectChecks <n>] [-Results <file>]   publish
  annotate -In <image> -Rect 'x,y,w,h,label' [-Copy]   (goody android-swarm)
  evidence fetch|index|read-chunk|frames|write-vision|label|verify|tune|feedback|bench|status <link | key> ...   videos -> text index (goody media-evidence)
  retest -RunDir <run> -Task <id> -Code <code> -Mrs <refs>
  ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo|mic ...   ($env:ANDROID_SERIAL; goody android-swarm)
In: targets.local.json (logins), kit.local.json, the run folder. Out: text / JSON (-Json), evidence files.
Exit codes: 0 ok · 1 problem (evidence check, not deployed, publish refused, api HTTP >= 400 / no answer, ui NOT FOUND / TIMEOUT) · 2 usage
  or a missing goody · 3 seat ALREADY (item taken) · 4 seat still waiting (run it again).
Goodies (kitbag.py goody add <name>, loaded from adapters/): android-swarm (ui, annotate, deploys[] laneApk), deploys (deployed),
  api-auth, report-gdocs (the styled HTML report), ios-simulator, media-evidence (evidence).
Sections: L23 report · L120 seat · L188 api · L311 finalize · L704 retest
#>
#Requires -Version 7
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'crafty/lib.ps1')
foreach ($__adapter in Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue) { . $__adapter.FullName }
# ---- report: Markdown (tracker comments, the report file; reports.type gdocs converts it to a Google Doc)
function TaskLink($id) { if (Get-Command Get-TrackerUrl -ErrorAction SilentlyContinue) { Get-TrackerUrl $id } else { "$id" } }

# evidence names (SKILL.md "Evidence"); browser.mjs EVIDENCE_NAME is the same literal, -FixNames writes them
$script:EvidenceName = '^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2}m?)?|_\d{2}m?)_[a-z0-9]+([-._][a-z0-9]+)*|[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?|jsonl|ndjson)$'
$script:EvidenceExt = '^\.(jpe?g|png|json|jsonl|ndjson|log|csv|txt|pdf|mp4|html|xlsx?)$'   # types finalize publishes

# "F2-T4_02_after-edit.jpeg" -> "After edit"
function Caption($file) {
  if ($file -match '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify)?(_\d{2}m?)?_(.+)\.\w+$') {
    $c = ($Matches[3] -replace '[-_]', ' ').Trim(); $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }
    if (-not $c) { return $file }   # one odd name never crashes the publish
    return $c.Substring(0, 1).ToUpper() + $c.Substring(1) + $v   # $c is non-empty here
  }
  return $file
}
# phone shots render narrow
function ImgWidth($f) { if ($f -match '\.png$' -or $f -match '(?i)(^|[_-])(app|phone|mobile|emulator)([_.-])|-L\d+_') { 260 } else { 600 } }
# verify = '<status> | <re-test text> | <note audit text>' (testy.js vJoin): the Results cell shows the status only
function VerifyStatus($v) { $s = ([string]$v -split ' \| ', 2)[0].Trim(); if ($s -match '^Note audit' -or @($s -split '\s+').Count -gt 6) { '' } else { $s } }
# a verify over 20 words (the report's sentence cap is 25) is published as its own evidence file, linked from the report
function VerifyFile($Code, $c) { if (@(([string]$c.verify) -split '\s+' | Where-Object { $_ }).Count -gt 20) { "$Code-$(([string]$c.id) -replace '[^A-Za-z0-9-]', '')_verify_retest.txt" } }

function Build-QaReportMd($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl, [hashtable]$Cells) {
  function MdEsc($t) { ([string]$t -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
  # an image: the host's embeddable src (gdocs) or its link; the quoted title = width in px (md_to_html)
  function MdImg($f) { $u = if ($Map.files[$f].src) { $Map.files[$f].src } else { $Map.files[$f].link }; "![$(if ($f -match '^[A-Za-z0-9]+-([A-Za-z]*\d+[a-z]?)_') { "$($Matches[1]): " })$(Caption $f)]($(([string]$u) -replace ' ', '%20') `"$(ImgWidth $f)`")" }
  # JSON / log evidence previewed in its row: up to 8 "path: value" fields or the last 3 log lines, as code (the run folder copy)
  function Peek($f) {
    $p = @("$D/shots/$f", "$D/evidence/$f") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $p -or $f -notmatch '\.(json|log|txt)$') { return '' }
    $ln = [Collections.Generic.List[string]]::new()
    if ($f -match '\.json$') {
      function Walk($v, $at) {
        if ($ln.Count -ge 8) { return }
        if ($v -is [Collections.IDictionary]) { foreach ($key in $v.Keys) { Walk $v[$key] "$at$(if ($at) { '.' })$key" } }
        elseif ($v -is [Collections.IList]) { $n = 0; foreach ($x in $v) { if ($n -ge 3) { break }; Walk $x "$at[$n]"; $n++ } }
        else { $s = "$v"; $ln.Add("$at`: $($s.Substring(0, [math]::Min(60, $s.Length)))") }
      }
      $jv = try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
      Walk $jv ''
    } else { @(Get-Content -LiteralPath $p | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { $ln.Add($_.Substring(0, [math]::Min(120, $_.Length))) } }
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
  if (@($Item.subtasks).Count) { $o.Add("| Tasks | $((@($Item.subtasks) | ForEach-Object { "[$(MdEsc $_.name)]($(TaskLink $_.id))$(if ($_.mrs) { " · MRs $(MdEsc $_.mrs)" })" }) -join '<br>') |") }
  if (@($Run.envLines).Count) { $o.Add("| Environment | $((@($Run.envLines) | ForEach-Object { MdEsc $_ }) -join '<br>') |") }
  $o.Add("| Tested by | $(MdEsc $Tester) with Claude Code · $Date |")
  $o.Add("| Evidence | $(MdEsc $Map.folderLink) · $(@($Map.files.Keys).Count) files |"); $o.Add('')
  $o.Add('## Tasks'); $o.Add(''); $o.Add('Result per task:'); $o.Add(''); $o.Add('| Task | Pass | Fail | Not tested | Status |'); $o.Add('|---|---|---|---|---|')
  foreach ($st in @(if (@($Item.subtasks).Count) { @($Item.subtasks) } else { [pscustomobject]@{ id = ''; name = $Item.title } })) {
    $tc = @($checks | Where-Object { -not $st.id -or $_.subtask_id -eq $st.id -or @($Item.subtasks).Count -eq 1 }); $tn = @{}; foreach ($k in $label.Keys) { $tn[$k] = @($tc | Where-Object result -eq $k).Count }
    $o.Add("| $(MdEsc $st.name) | $($tn.PASS + $tn.PASS_WITH_NOTE) | $($tn.FAIL) | $($tn.NOT_TESTED) | $(if ($tn.FAIL) { 'failed' } elseif ($tn.NOT_TESTED) { 'partly tested' } elseif ($tn.PENDING) { 'pending' } else { 'passed' }) |")
  }
  $o.Add(''); $o.Add('## Results'); $o.Add(''); $o.Add('Each check, its evidence inline:'); $o.Add(''); $o.Add('| Check | Result | Observed | Evidence |'); $o.Add('|---|---|---|---|')
  foreach ($c in $checks) {   # a FAIL's steps and saw live once, in "Failures in detail"
    $saw = if ($c.result -eq 'FAIL') { '[details](#' + ("$($c.id) — $($c.screen)".ToLower() -replace '[^\w\- ]', '' -replace ' ', '-') + ')' } else { MdEsc $c.observed }
    $evc = (@($c.evidence | Where-Object { $_ }) | ForEach-Object { if ($_ -match '\.(png|jpe?g)$' -and $Map.files[$_]) { MdImg $_ } elseif ($pk = Peek $_) { "$pk<br>[full file]($(([string]$Map.files[$_].link) -replace ' ', '%20'))" } else { "file: $(Lnk $_)" } }) -join '<br>'
    $vt = @(([string]$c.verify -replace ' \| ', ' · ') -split '\s+' | Where-Object { $_ }); $rt = if ($vt.Count) { " (re-test: $(MdEsc (($vt | Select-Object -First 20) -join ' '))$(if ($vt.Count -gt 20) { ' …' }))" }
    $o.Add("| **$(MdEsc $c.id)** $(MdEsc $c.screen) | $($label[[string]$c.result])$rt | $saw | $evc |")
    if ($null -ne $Cells) { $Cells[[string]$c.id] = @{ result = ([string]$c.result -replace '_', ' '); evidence = $evc } }   # the human doc's row
  }
  if ($fails.Count) {
    $o.Add(''); $o.Add('## Failures in detail')
    foreach ($c in $fails) {
      $o.Add(''); $o.Add("### $($c.id) — $($c.screen)"); $o.Add("**Steps:** $($c.what_was_done)"); $o.Add(''); $o.Add("**Saw:** $($c.observed)")
      if ($c.verify) { $o.Add(''); $o.Add("**Independent re-test:** $(VerifyMd $c)") }
    }
  }
  $vNotes = @($checks | Where-Object { $_.result -ne 'FAIL' -and $_.verify -and [string]$_.verify -ne (VerifyStatus $_.verify) })   # a FAIL's verify is in its detail
  if (@($Res.findings).Count -or $vNotes.Count) {   # a note's observed is in the Results table already
    $o.Add(''); $o.Add('## Notes'); $o.Add('')
    foreach ($c in $vNotes) { $o.Add("- **$(MdEsc $c.id)** re-test / note audit: $(VerifyMd $c)") }
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

# ---- seat: item claim (first claimer owns <run>/<code>) + a memory turn in the gate's queue; the seat file names its holder
function Invoke-Seat {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'release', 'status')][string]$Action,
  [string]$Agent, [ValidateSet('web', 'api', 'app')][string]$Kind = 'web',
  [string]$RunDir, [string]$Code, [string]$Owner = 'w1',
  [int]$WaitMinutes = 8, [double]$KeepFreeGB = 0   # 0 = the gate's floor (gate.keepFreeGB)
)
$ErrorActionPreference = 'Stop'
$dir = Get-KitPath qa-seats; $seats = Join-Path $dir 'seats'; $claims = Join-Path $dir 'claims'
New-Item -ItemType Directory -Force $seats, $claims | Out-Null
$need = [double](Get-KitSetting "qa.seatGB.$Kind" @{ web = 1.5; api = 0.4; app = 0.4 }[$Kind])
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-qa-seats')
function Locked([scriptblock]$b) {
  $got = $false
  try { $got = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed holder hands it over
  try { & $b } finally { if ($got) { $mutex.ReleaseMutex() } }
}
function Safe($s) { $s -replace '[^\w.-]', '_' }
# README "Leases": dead = no live holder for idle.graceMinutes from first seen; a record without holder fields: 6 h
function LeaseLive($o, [string]$file) {
  if ($null -eq $o.PSObject.Properties['holderPid']) { return ((Get-Date) - [datetime]$o.since).TotalHours -lt 6 }
  $v = [pscustomobject]@{ agent = "$($o.lease)"; holderPid = $o.holderPid; holderStart = $o.holderStart; seen = $o.seen }
  $live = Update-KitLease $v; $o | Add-Member -Force seen $v.seen; Write-KitAtomic $file ($o | ConvertTo-Json); $live
}
function Read-Seat($p) { try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null } }   # half-written: skipped
function Seats { @(Get-ChildItem $seats -Filter *.json | ForEach-Object { $o = Read-Seat $_.FullName; if (-not $o) { return }; if (LeaseLive $o $_.FullName) { $o } else { Remove-Item $_.FullName -Force } }) }
$lease = (($Agent -split ':', 2)[-1] -split '@')[0]   # item code: Test-KitLive matches step labels, board

switch ($Action) {
  'status' {
    $s = Locked { Seats }
    "free RAM $(Get-FreeGB) GB; $($s.Count) seat(s): $(($s | ForEach-Object { "$($_.agent) ($($_.kind))" }) -join ', ')"
    Get-ChildItem $claims -Filter *.json | ForEach-Object { $c = Read-Seat $_.FullName; if ($c) { "claim: $($c.run)/$($c.code) by $($c.owner) since $($c.since)" } }
  }
  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    Remove-Item (Join-Path $seats "$(Safe $Agent).json") -Force -ErrorAction SilentlyContinue
    "seat released: $Agent"
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
        ([ordered]@{ run = $run; code = $Code; owner = $Owner; since = (Get-Date).ToString('o'); lease = $Agent } + (Get-KitHolder)) | ConvertTo-Json | ForEach-Object { Write-KitAtomic $cf $_ }
        $null
      }
      if ($verdict) { $verdict; exit 3 }
    }
    $sf = Join-Path $seats "$(Safe $Agent).json"
    if (Test-Path $sf) { "seat already held: $Agent"; exit 0 }
    # the gate's fair memory queue (builds, phones, seats); a 0-second command = just the turn, so seats < 3 min old
    # (their browser still starting) are added to what this one needs
    $fresh = [double](@(Locked { Seats }) | Where-Object { ((Get-Date) - [datetime]$_.since).TotalMinutes -lt 3 } | Measure-Object need -Sum).Sum
    $ga = @('-Dir', $dir, '-Cmd', 'exit 0 #qa-seat', '-NeedGB', ($need + $fresh), '-WaitMinutes', $WaitMinutes); if ($KeepFreeGB) { $ga += '-KeepFreeGB', $KeepFreeGB }
    $said = @(& $KitCmd.dev gate @ga *>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE) { "STILL WAITING (no memory turn within $WaitMinutes min$(@($said | Where-Object { $_ -match 'waiting|queued' } | ForEach-Object { ": $_" })[-1])): run the same command again"; exit 4 }
    ([ordered]@{ agent = $Agent; lease = $lease; kind = $Kind; need = $need; since = (Get-Date).ToString('o') } + (Get-KitHolder)) | ConvertTo-Json | ForEach-Object { Write-KitAtomic $sf $_ }
    "seat taken: $Agent ($Kind, ~$need GB); free RAM $(Get-FreeGB) GB"
  }
}
}
# ---- api: call a target's API as a test user (targets.local.json); -Save = redacted request/response evidence
function Invoke-Api {
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory, Position = 0)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = 'admin',
  [string]$Tenant = $null,
  [string]$Save = $null,            # without .json
  [string]$OutDir = $null,          # default: <runtime>/work/evidence
  [hashtable]$Headers = @{},
  [string]$ContentType = 'application/json',
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
# absolute only: a bound hashtable became a relative folder
if ($OutDir -and -not [IO.Path]::IsPathRooted($OutDir)) { throw "-OutDir must be an absolute folder path, got '$OutDir' (a variable holding an object? PowerShell names are case-insensitive: `$o is `$O)" }
# Git Bash rewrites '/api/x' into a Git path: undo
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $p0 = $Path; $Path = '/' + ($Matches.rest -replace '\\', '/'); Write-KitLog calls msys-path @{ from = $p0; to = $Path } }   # the calls log has the raw arg
$here = $PSScriptRoot
$cfgFile = Join-Path $here 'targets.local.json'
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - run bossy.ps1 setup -WriteLocal, then fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
# a QA run pins its targets (KIT_QA_TARGETS)
$pin = @("$env:KIT_QA_TARGETS" -split '[,\s]+' | Where-Object { $_ })
if ($pin.Count -and $Target -notin $pin) { throw "target '$Target' is not this QA run's target ($($pin -join ', ')): a run tests only its own env (run.json target / alsoTargets)" }
$t = $cfg.targets.$Target
if (-not $t) { throw "Unknown target '$Target'. Known: $($cfg.targets.PSObject.Properties.Name -join ', ')" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$u = @($t.users.$As)
if (-not $t.users.$As -and $t.auth.type -ne 'none') { throw "No user '$As' in target $Target. Known: $($t.users.PSObject.Properties.Name -join ', ')" }   # not @(...).Count: @($null).Count is 1
if (-not $t.api -and $Path -notmatch '^https?://') { throw "target '$Target' has no api URL (web-only: use browser.mjs)" }
$base = ([string]$t.api).Replace('{tenant}', $Tenant).TrimEnd('/')
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }
$a = $t.auth
if ("$($a.type)" -notin '', 'login', 'none' -or $a.cert -or $a.refreshField) {   # other auth kinds: goody api-auth
  if ($ext = Get-Command Invoke-ApiExtra -ErrorAction SilentlyContinue) { return & $ext @PSBoundParameters }
  throw "auth type '$($a.type)'$(if ($a.cert) { ' + client cert' })$(if ($a.refreshField) { ' + refresh token' }) of target $Target is a goody: run kitbag.py goody add api-auth"
}

function Fill($s) { ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant) }
function Get-Field($o, $path) { foreach ($k in $path.Split('.')) { $o = $o.$k }; $o }

$tokDir = Get-KitPath tokens -Create
$cache = Join-Path $tokDir ("$Target-$Tenant-$As.txt" -replace '[^\w.\-]', '_')
function Login {
  $b = [ordered]@{}; foreach ($p in $a.body.PSObject.Properties) { $b[$p.Name] = if ($p.Value -is [string]) { Fill $p.Value } else { $p.Value } }
  $lu = Fill $(if ($a.path -match '^https?://') { $a.path } else { $base + $a.path })
  $form = $a.contentType -eq 'form'
  $r = Invoke-WebRequest -Method Post $lu -ContentType $(if ($form) { 'application/x-www-form-urlencoded' } else { 'application/json' }) -Body $(if ($form) { $b } else { $b | ConvertTo-Json -Depth 5 }) -ConnectionTimeoutSeconds 60
  $tok = Get-Field ($r.Content | ConvertFrom-Json) $(if ($a.tokenField) { $a.tokenField } else { 'access_token' })
  if (-not $tok) { throw "login to $Target as $As returned no token" }
  $tok | Set-Content $cache -NoNewline
  $tok
}
# login: the header template (default a bearer token); none: no auth header
function AuthHeaders($tok) {
  if ($a.type -ne 'login') { return @{} }
  $n, $v = "$(if ($a.header) { $a.header } else { 'Authorization: Bearer {token}' })".Split(':', 2)
  @{ $n.Trim() = $v.Trim().Replace('{token}', $tok) }
}
$tok = $null; $login = $a.type -eq 'login'
if ($login) { $tok = if (Test-Path $cache) { "$(Get-Content $cache -Raw)".Trim() }; if (-not $tok) { $tok = Login } }   # empty cache file: log in again

function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = $ContentType }
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match $KitLogMap.secretKey) { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
  try { $r = Invoke-WebRequest @p; $hm = HeaderMap $r.Headers.GetEnumerator(); return @([int]$r.StatusCode, $r.Content, [string]$hm['content-type'], $hm) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { $hm = HeaderMap (@($resp.Headers) + @($resp.Content.Headers)); return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType, $hm) } else { return @(0, "ERR $($_.Exception.Message)", '', [ordered]@{}) }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $login) { $tok = Login; $sw.Restart(); $res = Call $tok }   # token expired: once more
$sw.Stop()
$status, $content, $ctype, $rhead = $res
if ($content -is [byte[]]) {
  $bytes = $content; $content = "[binary $($bytes.Length) bytes, $ctype]"
  if ($Save -and -not $bytes.Length) { $content += ' (empty: no file saved)' }
  elseif ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Get-KitPath evidence }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = if ([string]$rhead['content-disposition'] -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)') { [IO.Path]::GetExtension($Matches[1]) } else { '' }
    if (-not $ext) { $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '' } } }
    if (-not $ext) {   # octet-stream: the magic bytes, then strict UTF-8 text
      $hex = -join @($bytes | Select-Object -First 4 | ForEach-Object { $_.ToString('X2') })
      $ext = switch -Regex ($hex) { '^25504446' { '.pdf' } '^89504E47' { '.png' } '^FFD8FF' { '.jpg' } '^504B0304' { '.zip' } default { try { if ($ctype -and $ctype -notmatch 'octet-stream') { throw }; $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes); '.txt' } catch { '.bin' } } }
    }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}

if ($Save) {
  if (-not $OutDir) { $OutDir = Get-KitPath evidence }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  # secrets redacted at any depth (keys: kit.example.json _paths.log.secretKey)
  function Redact($o) {
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $o[$k] = if ("$k" -match $KitLogMap.secretKey) { '[redacted]' } else { Redact $o[$k] } }; return , $o }
    if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $p.Value = if ($p.Name -match $KitLogMap.secretKey) { '[redacted]' } else { Redact $p.Value } }; return $o }
    if ($o -is [array]) { return , @($o | ForEach-Object { Redact $_ }) }
    $o
  }
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = $s.Substring(0, 200KB) } }; try { Redact (ConvertFrom-Json $s -NoEnumerate) } catch { $s } }
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
  [int]$ExpectChecks = -1,              # truncated results.json refused
  [string]$Results = 'results.json',    # -Check: a retry renames only its own
  [string]$Report = '',                 # a reports.type name
  [string]$Date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
)
$ErrorActionPreference = 'Stop'
if ($FixNames -and -not $Check) { throw '-FixNames works only together with -Check' }
$rtype = if ($Report) { $Report } else { $KitConf.ReportType }
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
# a long verify (re-test + note audit text) -> its own evidence file; -Check only counts it as present
$vText = [ordered]@{}
foreach ($c in @($res.checks)) { $vf = VerifyFile $Code $c; if ($vf) { $vText[$vf] = "$($c.id) — $($c.screen): independent re-test and note audit`n`n" + (([string]$c.verify -split ' \| ') -join "`n`n") + "`n" } }
$vChanged = @(if (-not $Check) { foreach ($vf in $vText.Keys) {   # changed text: uploaded again on a re-run (step 1)
  if ((Test-Path "$D/evidence/$vf") -and [IO.File]::ReadAllText("$D/evidence/$vf") -ne $vText[$vf]) { $vf }
  [IO.File]::WriteAllText("$D/evidence/$vf", $vText[$vf]) } })
$lost = [Collections.Generic.List[object]]::new()   # listed but found nowhere
# -FixNames renames (old -> new): a results file written again from the checks of before the rename still names the old files
$renLog = "$D/evidence-renames.json"; $renamed = @{}; $remap = [ordered]@{}
if (Test-Path -LiteralPath $renLog) { (Get-Content -LiteralPath $renLog -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $renamed[$_.Name] = [string]$_.Value } }
foreach ($c in @($res.checks)) {
  if ($null -eq $c.PSObject.Properties['evidence']) { $c | Add-Member NoteProperty evidence @() }
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
# the prose limits: -Check exits 1, a publish refuses (one rule), before anything is published
$prose = {
  $lm = @{ folderLink = $D; files = @{} }; foreach ($x in @(@($files.Name) + @($vText.Keys) | Where-Object { $_ })) { $lm.files[$x] = @{ link = $x } }
  $md = Build-QaReportMd -Title $(if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }) -Code $Code -Item $item -Res $res -Map $lm -Run $run -Tester '-' -Date $Date
  @(@(Test-KitProse -Kind result-note -Path (Join-Path $D $Results) 3>$null) + @(Test-KitProse -Kind qa-report -Text (($md -split "`n## Evidence index")[0] -replace '(?m)^\*\*Evidence:\*\* .*$', '') 3>$null))   # link lists are not prose
}
$prWhy = "$Code prose check: shorten observed / what_was_done in $Results (crafty/templates.md ""Writing standards"")"
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
  if ($FixNames -and ($suggest.Count -or $remap.Count)) {
    $resFile = Join-Path $D $Results; $raw = [IO.File]::ReadAllText($resFile)
    # references end in the file name; any case (Windows found the file under a reference in another case, the rename left it)
    $retag = { param($old, $nn) [regex]::Replace($raw, '(?<=["/\\])' + [regex]::Escape($old) + '(?=")', $nn.Replace('$', '$$'), 'IgnoreCase') }
    foreach ($o in @($remap.Keys)) { $raw = & $retag $o $remap[$o]; "  $Results`: $o -> $($remap[$o]) (renamed by an earlier -FixNames)" }
    foreach ($b in @($suggest.Keys)) {
      $new = $suggest[$b]; if (-not $new) { continue }
      $f = $files | Where-Object Name -eq $b | Select-Object -First 1
      Rename-Item -LiteralPath $f.FullName -NewName $new
      $raw = & $retag $b $new; $renamed[$b] = $new
      "  renamed $($f.Directory.Name)/$b -> $new"
      $suggest.Remove($b)
    }
    [IO.File]::WriteAllText($resFile, $raw)
    [IO.File]::WriteAllText($renLog, ($renamed | ConvertTo-Json -Depth 2))
    $badNames = @($suggest.Keys)
  }
  $dups = @(@($res.checks) | Where-Object { $_.id } | Group-Object { [string]$_.id } | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) (x$($_.Count))" })
  $fail = $false
  if ($lostList.Count) { $fail = $true; "$Code evidence check: $($lostList.Count) file(s) listed in results.json but missing:"; $lostList | ForEach-Object { "  $_" } }
  if ($badNames.Count) {
    $fail = $true; "$Code evidence check: $($badNames.Count) off-standard name(s) (pokey SKILL.md Evidence; -Check -FixNames renames them):"
    $badNames | ForEach-Object { "  $_ -> $(if ($suggest[$_]) { $suggest[$_] } elseif ($emptyNames -contains $_) { '(empty file: not renamed, see below)' } else { '(no suggestion: rename by hand)' })" }
  }
  if ($emptyFiles.Count) {
    $fail = $true; "$Code evidence check: $($emptyFiles.Count) empty file(s) cited (0 bytes: the capture failed; re-capture or drop them from results.json; -FixNames leaves them):"
    $emptyFiles | ForEach-Object { "  $($cited[$_.Name]): $($_.Directory.Name)/$($_.Name)" }
  }
  if ($dups.Count) { $fail = $true; "$Code evidence check: duplicate check id(s) in results.json (merge or renumber them): $($dups -join ', ')" }
  # a note without its class hides defects; a re-test's own note (verify) is exempt, a note audit's is not
  $noClass = @(@($res.checks) | Where-Object { $_.result -eq 'PASS_WITH_NOTE' -and -not ($_.verify -and "$($_.verify)" -notmatch '^Note audit') -and "$($_.observed)" -notmatch '^\s*\([a-d]\)\s' } | ForEach-Object { [string]$_.id })
  if ($noClass.Count) { $fail = $true; "$Code note check: PASS_WITH_NOTE without its class (observed starts with '(a|b|c|d) <why>', pokey SKILL.md step 5; else FAIL): $($noClass -join ', ')" }
  if ($badTypes.Count) {
    $fail = $true; "$Code evidence check: $($badTypes.Count) file(s) listed but unsupported type (never published; supported: $($script:EvidenceExt -replace '^\^\\\.\(|\)\$$', '' -replace '\|', ' ')):"
    $badTypes | ForEach-Object { "  $_" }
  }
  $pr = @(& $prose)
  if ($pr.Count) { $fail = $true; "${prWhy}:"; $pr | ForEach-Object { "  $_" } }
  # one rerun fixes all: the names (-FixNames) and the re-checked text together
  if ($fail) { "next: $(if ($pr.Count -or $noClass.Count -or $dups.Count) { "fix the text above in $Results$(if ($renamed.Count) { ' (renamed files already in it)' }), then " })ONE run: pokey.ps1 finalize -RunDir $RunDir -Code $Code -Check$(if (@($suggest.Values | Where-Object { $_ }).Count) { ' -FixNames' })$(if ($Results -ne 'results.json') { " -Results $Results" })"; exit 1 }
  "$Code evidence check: OK ($($files.Count) files, standard names, supported types, none empty, unique check ids, note classes, prose)"; exit 0
}
if ($lostList.Count) {
  throw "$Code`: $($lostList.Count) evidence file(s) listed in results.json are missing - nothing was published: $($lostList -join '; '). Save them or fix results.json, then re-run."
}
$pr = @(& $prose)
if ($pr.Count) { throw "${prWhy}, then re-run - nothing was published: $($pr -join '; ')" }
$fin = "$D/finalize.json"
$prev = if ((Test-Path $fin) -and -not $Force) { Get-Content $fin -Raw | ConvertFrom-Json } else { $null }
$title = if ($run.title) { $run.title } else { Split-Path $RunDir -Leaf }
$tester = if ($run.tester) { $run.tester } else { [Environment]::UserName }
$tr = $run.tracker
Push-Location $RunDir; $script:qaFinPushed = $true   # tracker CLIs run inside the run folder
trap { if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }; break }
function TrySay([scriptblock]$b, [string]$what) { try { & $b } catch { Write-Warning "tracker ($($KitConf.TrackerType)): $what failed: $_"; $null } }

# 1. Evidence: hosted by the report type (devtools evidence; gdocs: a Drive folder, a re-run adds new files) or the run folder
$map = [ordered]@{ folderId = $prev.folderId; folderLink = $prev.folderLink; files = [ordered]@{}; local = $false; label = $null }
if ($prev.folderId) { foreach ($pf in $prev.files.PSObject.Properties) { if ($pf.Name -notin $vChanged) { $map.files[$pf.Name] = $pf.Value } } }
# one report, one evidence folder per task across runs (devtools.py publish by key); several tasks: per run item
$pubKey = if (@($item.subtasks).Count -eq 1) { [string]@($item.subtasks)[0].id } else { "$(Split-Path $RunDir -Leaf)-$Code" }
$ea = @('evidence', "$title $Code - test evidence ($Date)", '--type', $rtype, '--key', "${pubKey}:evidence")
if ($run.driveParent) { $ea += '--parent', [string]$run.driveParent }   # run.json wins, else kit.local.json
if ($prev.folderId) { $ea += '--folder', [string]$prev.folderId }
$lf = [IO.Path]::GetTempFileName()   # a list file: 80+ long paths broke the command-line limit
[IO.File]::WriteAllLines($lf, [string[]]@($files | Where-Object { -not $map.files[$_.Name] } | ForEach-Object FullName))
$evAll = @(& (Get-Python) -X utf8 $KitCmd.devtools @ea --files-from $lf 2>&1); $evRc = $LASTEXITCODE; Remove-Item -LiteralPath $lf -ErrorAction SilentlyContinue
$ev = @($evAll | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }); $evErr = @($evAll | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
if ($evErr) { $evErr | ForEach-Object { [Console]::Error.WriteLine($_) } }
if ($evRc) { throw "evidence upload ($rtype) failed (exit $evRc): $((@($evErr) + @($ev) | Select-Object -Last 4) -join ' | ') - nothing was published" }
$ev = ($ev | Out-String) | ConvertFrom-Json
if ($ev.folderId) {
  $map.folderId = $ev.folderId; $map.label = $ev.label; if ($ev.folderLink) { $map.folderLink = $ev.folderLink }
  foreach ($pf in $ev.files.PSObject.Properties) { $map.files[$pf.Name] = $pf.Value }
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
$html = Get-Command Build-QaReport -ErrorAction SilentlyContinue   # goody report-gdocs: the styled HTML goes to gdocs
if ($html) { & $html -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File "$D/report.html" -Encoding utf8 }

$cells = @{}
$md = Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl -Cells $cells
$md | Out-File "$D/report.md" -Encoding utf8
$kept = $prev.doc -match '^https?://' -and $prev.doc -notmatch '/d//' -and "$($prev.report)" -in '', $rtype
# the task's human testing doc takes the run: Result / Evidence per row + a dated "<env> run" section (same doc); none: a report by key
$hDoc = Test-Path -LiteralPath (Join-Path (Get-KitPath published) "$($pubKey -replace '[^\w.-]+', '_')_testing-doc.json")
if ($kept) { $docUrl = $prev.doc }   # a re-run keeps the posted report
else {   # devtools doc (reports.type); kept-file types keep it in $D
  $pa = if ($hDoc) { [IO.File]::WriteAllText("$D/cells.json", (ConvertTo-Json $cells -Depth 4), [Text.UTF8Encoding]::new($false)); @("$D/report.md", '--key', "${pubKey}:testing-doc", '--run', "$D/cells.json") }
    else { @("$D/report.$(if ($html -and $rtype -eq 'gdocs') { 'html' } else { 'md' })", '--key', "${pubKey}:qa-report") }
  $o = & (Get-Python) -X utf8 $KitCmd.devtools doc "$title $Code - Test Results ($Date)" $pa[0] $(if ($map.folderId) { $map.folderId } else { $D }) --type $rtype @($pa | Select-Object -Skip 1) --label "$(if ($item.target) { $item.target } else { $run.target })" 2>&1 | ForEach-Object { "$_" }
  $docUrl = if (-not $LASTEXITCODE) { @($o)[-1].Trim() } elseif ("$o" -match '(\S+) was uploaded but not shared') { Write-Warning "$o"; $Matches[1] }
  elseif ($prev.doc -match '^https?://') { Write-Warning "report publish ($rtype) failed - keeping the previous report $($prev.doc): $o"; $prev.doc }
  else { throw "report publish ($rtype) failed and there is no previous report (nothing was posted to the tracker): $o" }
}
$reportFile = if ($docUrl -notmatch '^https?://') { $docUrl }   # a kept file is attached to the task

# 4. Tracker per subtask, result rule (SKILL.md step 5)
$out = [ordered]@{ report = $rtype; folderId = $map.folderId; folderLink = $map.folderLink; files = $map.files; doc = $docUrl; subtasks = @() }
$closeStatus = if ($tr.closeStatus) { $tr.closeStatus } else { 'closed' }   # logical name (tracker.statuses)
$isLocal = [string]$(if ($item.localEnv) { $item.localEnv } else { $run.localEnv })   # local env item (ENV-FIX)
$bugList = if ($tr.list) { $tr.list } else { [string](Get-KitSetting 'tracker.list' '') }
$canCreate = [bool]$bugList -or $KitConf.TrackerType -in 'github', 'gitlab', 'none'   # clickup/jira need a list/project
# own vs new: tester's 'defect' wins, else X = new
function Test-NewDefect($c) { if ("$($c.defect)" -in 'new', 'own') { return "$($c.defect)" -eq 'new' }; [string]$c.id -match '^X\d' }
# bossy.ps1 bugbrief parses "### <id> — <screen>" + "**Saw:**"
$script:NtHold = 'env-data', 'phone-only', 'tool-down', 'no-mail-sandbox'   # NOT_TESTED causes no developer can fix
function Format-Checks($list, [string]$heading) {
  if (-not @($list).Count) { return '' }
  "## $heading`n`n" + ((@($list) | ForEach-Object {
        $ev = (@($_.evidence) | Where-Object { $_ } | ForEach-Object { if ($map.files[$_]) { "[$_]($($map.files[$_].link))" } else { $_ } }) -join ', '
        "### $($_.id) — $($_.screen)$(if ($_.flaky) { ' (flaky)' })`n**Steps:** $($_.what_was_done)`n`n**Saw:** $($_.observed)$(if ($_.cause) { " (cause: $($_.cause))" })`n`n**Independent re-test:** $(if ($_.verify) { $_.verify } else { 'not re-tested' })`n`n**Evidence:** $(if ($ev) { $ev } else { 'none' })`n" }) -join "`n") + "`n"
}
# last item on a shared task decides
function SiblingHold($id) {
  $own = 0; $nt = 0; $ntH = 0; $err = $null; $pend = 0
  foreach ($c in @(@($run.items) | Where-Object { $_.code -ne $Code } | ForEach-Object code)) {
    $f = "$RunDir/$c/finalize.json"; if (-not (Test-Path $f)) { continue }
    $r = @((Get-Content $f -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.id -eq $id -and -not $_.noTracker }) | Select-Object -First 1
    if ($r) { $own += [int]$r.fail; $nt += [int]$r.notTested; $ntH += [int]$r.notTestedHold; $pend += [int]$r.pending; if ($r.bugError) { $err = "$c`: $($r.bugError)" } }
  }
  [pscustomobject]@{ fail = $own; notTested = $nt; notTestedHold = $ntH; bugError = $err; pending = $pend }
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
  $own = $true; try { $own = $mx.WaitOne(1000 * [int](Get-KitParam 'qa.bugsLockSec')) } catch [Threading.AbandonedMutexException] { $own = $true }   # abandoned = ours now
  if (-not $own) { $mx.Dispose(); throw "bugs.json of $RunDir is locked by another finalize for $(Get-KitParam 'qa.bugsLockSec') s (qa.bugsLockSec): re-run finalize -Code $Code" }
  try {
    $f = "$RunDir/bugs.json"
    $all = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
    $groups = [ordered]@{}; if ($all.groups) { foreach ($p in $all.groups.PSObject.Properties) { $groups[$p.Name] = $p.Value } }
    $s = if ($groups.Contains($key)) { $groups[$key] } else { [pscustomobject]@{ id = $null; url = $null; base = ''; baseCount = 0; entries = @() } }
    if (-not $s.id -and $ask.id) {
      $tested = @(@($run.items) | ForEach-Object { @($_.subtasks) | ForEach-Object id })
      $bp = [WildcardPattern]::Escape([string](Get-KitSetting 'tracker.bugPrefix' '[Bug]'))
      $open = try { @((Get-TrackerTask $ask.id).subtasks | Where-Object { "$($_.name)" -like "$bp *" -and $_.id -notin $tested -and -not (Test-TrackerStatus $_.status 'closed') }) | Select-Object -First 1 } catch { $null }
      if ($open) {
        $o = Get-TrackerTask $open.id
        $s.id = $open.id; $s.url = $(if ($open.url) { $open.url } else { TaskLink $open.id }); $s.base = [string]$o.description
        $s.baseCount = if ("$($o.name)" -match '\((\d+)\)\s*$') { [int]$Matches[1] } else { 0 }
      }
    }
    $entries = @(@($s.entries) | Where-Object { $_ -and -not ($_.code -eq $Code -and $_.task -eq $st.id) })
    $entries += [pscustomobject]@{ code = $Code; task = $st.id; taskName = $st.name; md = (Format-Checks $defects "New defects found while testing $($st.name) ($(TaskLink $st.id)), package $Code") }
    $n = [int]$s.baseCount + [int](($entries | ForEach-Object { ([regex]::Matches([string]$_.md, '(?m)^### ')).Count } | Measure-Object -Sum).Sum)
    $name = "$(Get-KitSetting 'tracker.bugPrefix' '[Bug]') $(if ($ask.name) { $ask.name } else { $title }) — new defects ($n)$(if (($entries | ForEach-Object md) -match '\(flaky\)') { ' [flaky]' })"
    $body = "QA run **$title** on $(if ($item.target) { $item.target } else { $run.target }) ($Date) found these defects outside what the tested tasks changed. Results report: $docUrl`n$(if ($guideUrl) { "Tester guide (check ids refer to it): $guideUrl`n" })`n" + (($entries | ForEach-Object md) -join "`n")
    if ($s.base) { $body = "$($s.base.TrimEnd())`n`n$body" }
    if ($s.id) { $null = Set-TrackerName $s.id $name; $null = Set-TrackerDescription $s.id $body }
    else {
      $t = New-TrackerTask -List $bugList -Name $name -Description $body -Parent $ask.id -Assignee $tr.owner -Priority '2'
      if (-not $t.id) { return $null }
      $s.id = $t.id; $s.url = $(if ($t.url) { $t.url } else { TaskLink $t.id })
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
  if ($isLocal -and -not ($rec.fail + $sib.fail) -and ($rec.notTested + $sib.notTested)) { $rec.keptOpen = "local env ${isLocal}: $($rec.notTested + $sib.notTested) check(s) not tested: ENV-FIX + pokey.ps1 retest"; return }
  $hold = [int]$rec.notTestedHold + [int]$sib.notTestedHold   # causes a developer cannot fix: the owner decides (close / retest)
  if ($rec.fail + $sib.fail + $rec.notTested + $sib.notTested - $hold) { Set-FailedTesting $rec $st; return }
  if ($hold) {
    $rec.keptOpen = "$hold check(s) not tested for a cause no developer can fix ($($script:NtHold -join ', ')): status kept, the owner decides"
    $rec.decision = TrySay { "$(& $KitCmd.orch decide ask -Run (Split-Path $RunDir -Leaf) -Agent "qa-$Code" -Item $st.id -Task $st.id -Question "$($st.id): $hold check(s) not tested ($($script:NtHold -join ' / ') causes; report $docUrl). Close it or retest?" -Options 'A: close it', 'B: keep it open for a retest' -Recommend B)" } "ask the owner about $($st.id)"
    return
  }
  if ($rec.bugError -or $sib.bugError) { $rec.keptOpen = "new defects have no [Bug] task ($(if ($rec.bugError) { $rec.bugError } else { $sib.bugError }))"; return }   # never close while a defect is untracked
  if ($null -ne (TrySay { Set-TrackerStatus $st.id $closeStatus; $true } "close $($st.id)")) { $rec.closed = $true } else { $rec.keptOpen = 'the tracker refused the close (see warning)' }
}
# one tracker step per run at a time (siblings deadlocked)
$fh = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($RunDir.ToLower()))).Substring(0, 16)
$fmx = [Threading.Mutex]::new($false, "Global\kit-finalize-$fh")
$fOwn = $true; try { $fOwn = $fmx.WaitOne(1000 * [int](Get-KitParam 'qa.finalizeLockSec')) } catch [Threading.AbandonedMutexException] { $fOwn = $true }
if (-not $fOwn) { $fmx.Dispose(); throw "another finalize of $RunDir held the tracker step for $(Get-KitParam 'qa.finalizeLockSec') s (qa.finalizeLockSec): re-run finalize -Code $Code" }
function Save-Fin { Write-KitAtomic $fin ($out | ConvertTo-Json -Depth 6) }
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
  $rec = [ordered]@{ id = $st.id; pass = $pass; total = $mine.Count; fail = $ownFails.Count; newDefects = $newDefects.Count; notTested = $nt; outOfScope = $oos; pending = $pend; bug = $null; closed = $false; failedTesting = $false
    notTestedHold = @($ntChecks | Where-Object { "$($_.cause)" -in $script:NtHold }).Count }
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
      if ($b.id) { $rec.bug = $b.id; $msg += ". New defects ($(($newDefects | ForEach-Object id) -join ', ')) moved to [Bug] task $($b.id)" }   # the comment carries one link: the report
      else { $rec.bugError = '[Bug] task could not be created'; Write-Warning "$($st.id): could not create the [Bug] task for $(($newDefects | ForEach-Object id) -join ', ')" }
    }
    elseif ($newDefects.Count) { $rec.bugError = 'no bug list configured'; Write-Warning "$($st.id): no tracker list for bug tasks (tracker.list) - task kept open" }
    $msg += if ($hDoc -and (Test-KitTaskDocLink $st.id) -eq $true) { '. Screenshots and evidence: the human testing doc in the description' } else { ". Report with screenshots and evidence: $docUrl" }   # testing doc links live only in the description
    # own failures + untested: failedTesting
    $text = $msg   # one line: counts, failed / untested ids, where the evidence is; the details live in the doc
    $posted = if ($reportFile) { TrySay { $null = Add-TrackerAttachment $st.id $reportFile $text; $true } "post the report on $($st.id)" }
    else { TrySay { $null = Set-TrackerKitComment $st.id 'qa-result' $text; $true } "comment on $($st.id)" }   # a new run edits the last result comment
    $out.subtasks += $rec
    # no results comment: leave the task, post next run
    if (-not $posted) { $rec.commentFailed = $true; $rec.keptOpen = 'the results comment was not posted (see warning): re-run finalize'; Save-Fin; continue }
    Save-Fin; Resolve-Outcome $rec $st $pend; Save-Fin; continue
  }
  $out.subtasks += $rec
}
Save-Fin
# the indexes (STATE.md): the task's env runs; the run's items -> result + report, so nobody re-reads the tracker or the run folder
$envName = [string]$(if ($item.target) { $item.target } else { $run.target }); $runName = Split-Path $RunDir -Leaf
foreach ($s in @($out.subtasks | Where-Object { $_.id })) {
  $er = [ordered]@{ env = $envName; run = $runName; code = $Code; pass = [int]$s.pass; fail = [int]$s.fail; notTested = [int]$s.notTested; doc = $docUrl; at = (Get-Date).ToString('o') }
  try { Update-KitTaskIndex ([string]$s.id) { param($x) $x.envRuns = @(@($x.envRuns) | Where-Object { -not ($_.run -eq $runName -and $_.code -eq $Code) }) + $er } } catch { Write-Warning "task index $($s.id): $_" }
}
$rix = Join-Path $RunDir 'index.json'
try { Invoke-KitLocked $rix { $ri = Read-KitState $rix; if (-not $ri) { $ri = [ordered]@{ run = $runName; env = $envName; items = @{} } }; if ($ri.items -isnot [Collections.IDictionary]) { $ri.items = @{} }
  $ri.items[$Code] = [ordered]@{ tasks = @($out.subtasks.id); doc = $docUrl; pubKey = $pubKey; pass = [int](($out.subtasks | Measure-Object pass -Sum).Sum); fail = [int](($out.subtasks | Measure-Object fail -Sum).Sum); at = (Get-Date).ToString('o') }
  Write-KitState $rix $ri } } catch { Write-Warning "run index ${rix}: $_" }
} finally { $fmx.ReleaseMutex(); $fmx.Dispose() }
"$Code report ($rtype): $docUrl"
if ($script:qaFinPushed) { $script:qaFinPushed = $false; Pop-Location }
$out.subtasks | ForEach-Object { "  $($_.id): $($_.pass)/$($_.total) pass, failed $($_.fail), new defects $([int]$_.newDefects), not tested $($_.notTested), out of scope $([int]$_.outOfScope), pending $($_.pending), bug $($_.bug), $(if ($_.closed) { 'closed' } elseif ($_.failedTesting) { "failed testing$(if ($_.statusFallback) { " (set $($_.statusFallback))" })" } elseif ($_.waitingFor) { "open (waiting for $(@($_.waitingFor) -join ', '))" } else { "open ($($_.keptOpen))" })" }
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
    $ids = @([regex]::Matches($txt, '(?m)^###\s+(\S+)\s+[—-]\s+') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($ids.Count) { $Only = $ids; break }
  }
}
if (-not $Title) { $Title = "RETEST $($t.name -replace "^$([regex]::Escape([string](Get-KitSetting 'tracker.bugPrefix' '[Bug]')))\s*", '')" }
$md = "# $($t.name)`n`nTask: $($t.url)  Status: $($t.status)`n`n" +
  "RETEST of the fix: run the failed checks ($($Only -join ', ')) again on the deployed build, same steps and data where possible. " +
  "Check the fix is deployed first (pokey.ps1 deployed -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.description)`n`n## Comments (oldest first)`n"
foreach ($x in $c) { $md += "`n---`n**$($x.user)** $($x.date)`n`n$($x.text)`n" }
New-Item -ItemType Directory -Force "$RunDir/tasks" | Out-Null
$gf = "$RunDir/tasks/$Task.md"; Set-Content $gf $md -Encoding utf8
$old = @('finalize.json', 'held.json', 'results.json' | ForEach-Object { Join-Path "$RunDir/$Code" $_ } | Where-Object { Test-Path $_ })
if ($old.Count) {   # reused code: archive the earlier round
  $arc = Join-Path "$RunDir/$Code" "archive-$(Get-Date -Format yyyyMMdd-HHmmss)"; New-Item -ItemType Directory -Force $arc | Out-Null
  foreach ($f in $old) { Move-Item -LiteralPath $f -Destination $arc }
  "archived the earlier round of $Code ($(($old | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) to $arc"
}
$r = Get-Content "$RunDir/run.json" -Raw | ConvertFrom-Json
$items = @($r.items | Where-Object { $_.code -ne $Code })
$items += [pscustomobject]@{ code = $Code; lane = $Lane; title = $Title; guideFile = $gf; retest = $true; only = @($Only); subtasks = @([pscustomobject]@{ id = $Task; name = $t.name; mrs = $Mrs }) }
$r.items = $items
Write-KitAtomic "$RunDir/run.json" ($r | ConvertTo-Json -Depth 8)
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir/run.json - launch: Workflow testy { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'seat' { Invoke-KitVerb Invoke-Seat $__rest }
    'api' { Invoke-KitVerb Invoke-Api $__rest }
    'finalize' { Invoke-KitVerb Invoke-Finalize $__rest }   # a crash exits 1: Invoke-KitVerb
    { $_ -in 'deployed', 'annotate', 'evidence' } {   # goodies deploys, android-swarm, media-evidence (adapters/)
      $fn = @{ deployed = 'Invoke-Deployed'; annotate = 'Invoke-Annotate'; evidence = 'Invoke-Evidence' }[$__verb]
      if (Get-Command $fn -ErrorAction SilentlyContinue) { Invoke-KitVerb $fn $__rest }
      else { $xn = @{ deployed = 'deploys'; annotate = 'android-swarm'; evidence = 'media-evidence' }[$__verb]; Resolve-KitExtra $xn; [Console]::Error.WriteLine("pokey.ps1 $__verb is a goody: run kitbag.py goody add $xn"); exit 2 }
    }
    'retest' { Invoke-KitVerb Invoke-Retest $__rest }
    'ui' {   # phone lanes: goody android-swarm (adapters/ui_android.ps1)
      if (Get-Command Invoke-Ui -ErrorAction SilentlyContinue) { Invoke-KitVerb Invoke-Ui $__rest }
      elseif ((Get-KitSetting 'devices.type' 'android') -eq 'none') { 'no devices (devices.type none): app checks are NOT_TESTED'; exit 1 }
      else { [Console]::Error.WriteLine('pokey.ps1 ui (phone lanes) is a goody: run kitbag.py goody add android-swarm'); exit 2 }
    }
    { $_ -in '-h', '--help', 'help', '-?' } { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }   # the header only
  }
}
