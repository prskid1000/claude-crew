<#
qa.ps1: qa-kit commands (SKILL.md tester steps 1-6, lead L1-L3). pwsh 7: & <kit>/skills/qa-kit/qa.ps1 <verb> [args]
  seat acquire|release|status ...                  memory seat + item claim
  deployed -Mrs <repo>!<iid>,... [-Detail] [-Json]  live on a test env?
  api -Target <t> -As <user> -Method <M> -Path '/...' [-Body <json>] [-ContentType <type>] [-Save <name> -OutDir <abs dir>]
  finalize -RunDir <run> -Code <code> [-Check -FixNames] [-NoTracker] [-ExpectChecks <n>] [-Results <file>]   publish
  annotate -In <image> -Rect 'x,y,w,h,label' [-Copy]
  retest -RunDir <run> -Task <id> -Code <code> -Mrs <refs>
  ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo ...   ($env:ANDROID_SERIAL; extra android-swarm)
In: targets.local.json (logins), kit.local.json, the run folder. Out: text / JSON (-Json), evidence files.
Exit codes: 0 ok · 1 problem (evidence check, not deployed, publish refused, api HTTP >= 400 / no answer, ui NOT FOUND / TIMEOUT) · 2 usage
  or a missing extra · 3 seat ALREADY (item taken) · 4 seat still waiting (run it again).
Extras (kittool.py extra add <name>, loaded from adapters/): android-swarm (ui, deploys[] laneApk), deployed-checks, api-auth,
  qa-html-report, ios-simulator.
Sections: L21 report · L92 seat · L160 deployed · L252 api · L371 finalize · L711 annotate · L745 retest
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
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

function Build-QaReportMd($Title, $Code, $Item, $Res, $Map, $Run, $Tester, $Date, $GuideUrl) {
  function MdEsc($t) { ([string]$t -replace '\|', '\|' -replace "`r?`n", ' ').Trim() }
  # an image: the host's embeddable src (gdocs) or its link; the quoted title = width in px (md_to_html)
  function MdImg($f) { $u = if ($Map.files[$f].src) { $Map.files[$f].src } else { $Map.files[$f].link }; "![$(Caption $f)]($(([string]$u) -replace ' ', '%20') `"$(ImgWidth $f)`")" }
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
      foreach ($f in @($ev | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] })) { $o.Add(''); $o.Add((MdImg $f)) }
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
  $gallery = @($checks | Where-Object { $_.result -ne 'FAIL' -and @($_.evidence | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] }).Count })
  if ($gallery.Count) {
    $o.Add(''); $o.Add('## Screenshots')
    foreach ($c in $gallery) { $o.Add(''); $o.Add("### $($c.id) — $($c.screen) ($($label[[string]$c.result]))"); foreach ($f in @($c.evidence | Where-Object { $_ -match '\.(png|jpe?g)$' -and $Map.files[$_] })) { $o.Add(''); $o.Add((MdImg $f)) } }
  }
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
  $live = Update-KitLease $v; $o | Add-Member -Force seen $v.seen; $o | ConvertTo-Json | Set-Content $file; $live
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
        ([ordered]@{ run = $run; code = $Code; owner = $Owner; since = (Get-Date).ToString('s'); lease = $Agent } + (Get-KitHolder)) | ConvertTo-Json | Set-Content $cf
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
    ([ordered]@{ agent = $Agent; lease = $lease; kind = $Kind; need = $need; since = (Get-Date).ToString('s') } + (Get-KitHolder)) | ConvertTo-Json | Set-Content $sf
    "seat taken: $Agent ($Kind, ~$need GB); free RAM $(Get-FreeGB) GB"
  }
}
}
# ---- deployed: is a merged MR live on a test env (CI deploy job, squash, laneApk; ssh / awsStack / probe / tag / manual: extra deployed-checks)
function Invoke-Deployed {
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json, [switch]$Detail, [string]$Exclude)   # -Exclude <regex>: skip those targets
$ErrorActionPreference = 'SilentlyContinue'
$group = $KitConf.GitlabGroup
$repos = @(Get-KitValue 'repos' @())
function Row($d, $s, $x) { [pscustomobject]@{ mr = $ref; target = $d.target; state = $s; detail = $x } }
function Repo($name) { $repos | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1 }
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
  -not @($cmp.diffs | Where-Object { $files -contains $_.new_path -or $files -contains $_.old_path }).Count
}
# squash-merged deploy MR: live if one merged into $branch after a source head held the commit
function ViaDeployMr($p, $mr, $sha, $ref, $branch) {
  if (-not $branch -or -not $mr.merged_at) { return $false }
  $after = ([datetimeoffset]$mr.merged_at).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
  foreach ($dm in @(Api "projects/$p/merge_requests?state=merged&target_branch=$([uri]::EscapeDataString($branch))&updated_after=$after&per_page=50") | Where-Object { $_ -and $_.iid -ne $mr.iid }) {
    $land = @($dm.merge_commit_sha, $dm.squash_commit_sha) | Where-Object { $_ } | Select-Object -First 1
    if ($land -and $dm.sha -and (IsAncestor $p $sha $dm.sha) -and (IsAncestor $p $land $ref)) { return $true }
  }
  $false
}
# NOT-DEPLOYED only if the host answers, else UNKNOWN
function NotLiveRow($p, $ref, $d, [string]$detail) { if ($null -eq (Api "projects/$p/repository/commits/$([uri]::EscapeDataString($d.branch))")) { Row $d 'UNKNOWN' "the git host did not answer for $($d.branch): try again" } else { Row $d 'NOT-DEPLOYED' $detail } }
function OnRef($p, $mr, $sha, $ref, $branch = $ref) { (IsAncestor $p $sha $ref) -or (ViaDeployMr $p $mr $sha $ref $branch) -or (ContentOn $p $mr $sha $ref) }
# $null if checkout or commit missing
function LocalAncestor($dir, $sha, $commit) {
  if (-not $dir -or -not (Test-Path $dir)) { return $null }
  git -C $dir cat-file -e "$commit^{commit}" 2>$null; if ($LASTEXITCODE) { return $null }
  git -C $dir merge-base --is-ancestor $sha $commit 2>$null
  $LASTEXITCODE -eq 0
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
  $sha = @($mr.squash_commit_sha, $mr.merge_commit_sha, $mr.sha) | Where-Object { $_ } | Select-Object -First 1
  if (-not $sha) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'UNKNOWN'; detail = 'merged MR has no commit sha (glab auth status?)' }; continue }
  $s8 = $sha.Substring(0, [math]::Min(8, $sha.Length))
  $deps = @($r.deploys | Where-Object { (-not $Target -or $_.target -eq $Target) -and (-not $Exclude -or $_.target -notmatch $Exclude) })
  if (-not $deps.Count) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'NO-TARGET'; detail = 'no deploys configured for this repo' }; continue }
  foreach ($d in $deps) {
    if ($d.laneApk) {   # app repo: the lane APK's commit
      if ($ext = Get-Command Test-LaneApkDeployed -ErrorAction SilentlyContinue) { & $ext $d }
      else { Row $d 'UNKNOWN' 'deploys[] laneApk is an extra: run kittool.py extra add android-swarm' }
      continue
    }
    if ($d.ssh -or $d.awsStack -or $d.probe -or $d.tag -or $d.manual) {
      if ($ext = Get-Command Test-DeployedExtra -ErrorAction SilentlyContinue) { & $ext $d }
      else { Row $d 'UNKNOWN' "deploys[] $(@('ssh', 'awsStack', 'probe', 'tag', 'manual' | Where-Object { $d.$_ })[0]) is an extra: run kittool.py extra add deployed-checks" }
      continue
    }
    if (-not (OnRef $p $mr $sha $d.branch)) { NotLiveRow $p $ref $d "not on $($d.branch) yet"; continue }
    $hit = $null
    # a pipeline older than the merge cannot hold it
    foreach ($pl in @(Api "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10") | Where-Object { -not $mr.merged_at -or [datetimeoffset]$_.created_at -ge [datetimeoffset]$mr.merged_at }) {
      $job = @(Api "projects/$p/pipelines/$($pl.id)/jobs?per_page=100") | Where-Object { $_.name -like $d.job } | Select-Object -First 1   # matrix names
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
  $live = @($out | Where-Object state -eq 'DEPLOYED')
  "deployed: $($live.Count)/$(@($out).Count) MR x target$(if ($live.Count) { ' (' + (($live | ForEach-Object { "$($_.mr)@$($_.target)" }) -join ', ') + ')' })"
  $out | Where-Object state -ne 'DEPLOYED' | ForEach-Object $row
}
exit $(if (@($out | Where-Object { $_.state -ne 'DEPLOYED' }).Count) { 1 } else { 0 })
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
  [string]$ContentType = 'application/json',
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
if ("$($a.type)" -notin '', 'login', 'none' -or $a.cert -or $a.refreshField) {   # other auth kinds: extra api-auth
  if ($ext = Get-Command Invoke-ApiExtra -ErrorAction SilentlyContinue) { return & $ext @PSBoundParameters }
  throw "auth type '$($a.type)'$(if ($a.cert) { ' + client cert' })$(if ($a.refreshField) { ' + refresh token' }) of target $Target is an extra: run kittool.py extra add api-auth"
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
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match '(?i)cookie|authorization|token|key|secret|password') { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
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
  if ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Get-KitPath evidence }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = if ([string]$rhead['content-disposition'] -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)') { [IO.Path]::GetExtension($Matches[1]) } else { '' }
    if (-not $ext) { $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '.bin' } } }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}

if ($Save) {
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
$lost = [Collections.Generic.List[object]]::new()   # listed but found nowhere
foreach ($c in @($res.checks)) {
  if ($null -eq $c.PSObject.Properties['evidence']) { $c | Add-Member NoteProperty evidence @() }
  $c.evidence = @(@($c.evidence) | Where-Object { $_ -and [string]$_ -notmatch '\.(mjs|cjs|js|jsx|ts|tsx|java|kt|ps1|py|sh)$|\s' } | ForEach-Object {
      $e = [string]$_; $leaf = Split-Path $e -Leaf
      if (-not (Test-Path "$D/shots/$leaf") -and -not (Test-Path "$D/evidence/$leaf")) {
        $src = if ([IO.Path]::IsPathRooted($e) -and (Test-Path $e)) { $e } elseif (Test-Path (Join-Path $D $e)) { Join-Path $D $e } else { (Get-ChildItem $RunDir -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
        if (-not $src) { $lost.Add([pscustomobject]@{ check = $c; name = $leaf }) }
        elseif (-not $Check) { Copy-Item $src "$D/evidence/$leaf" -Force }
      }
      $leaf } | Select-Object -Unique)
}

# 0. Evidence check first
$files = @(Get-ChildItem "$D/shots", "$D/evidence" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'tmp*' -and $_.Extension -match $script:EvidenceExt })
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
    $fail = $true; "$Code evidence check: $($badNames.Count) off-standard name(s) (qa-kit SKILL.md Evidence; -Check -FixNames renames them):"
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
if ($lostList.Count) {
  throw "$Code`: $($lostList.Count) evidence file(s) listed in results.json are missing - nothing was published: $($lostList -join '; '). Save them or fix results.json, then re-run."
}
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
if ($prev.folderId) { foreach ($pf in $prev.files.PSObject.Properties) { $map.files[$pf.Name] = $pf.Value } }
$ea = @('evidence', "$title $Code - test evidence ($Date)", '--type', $rtype)
if ($run.driveParent) { $ea += '--parent', [string]$run.driveParent }   # run.json wins, else kit.local.json
if ($prev.folderId) { $ea += '--folder', [string]$prev.folderId }
$lf = [IO.Path]::GetTempFileName()   # a list file: 80+ long paths broke the command-line limit
[IO.File]::WriteAllLines($lf, [string[]]@($files | Where-Object { -not $map.files[$_.Name] } | ForEach-Object FullName))
$ev = & (Get-Python) -X utf8 $KitCmd.devtools @ea --files-from $lf; $evRc = $LASTEXITCODE; Remove-Item -LiteralPath $lf -ErrorAction SilentlyContinue
if ($evRc) { throw "evidence upload ($rtype) failed (above) - nothing was published" }
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
$missing = @($checks | ForEach-Object { $c = $_; @($c.evidence) | Where-Object { $_ -and -not $map.files[$_] } | ForEach-Object { "$($c.id): $_" } })
if ($missing.Count) { Write-Warning "evidence found but not uploaded: $($missing -join '; ')" }
$html = Get-Command Build-QaReport -ErrorAction SilentlyContinue   # extra qa-html-report: the styled HTML goes to gdocs
if ($html) { & $html -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl | Out-File "$D/report.html" -Encoding utf8 }

$null = Test-KitProse -Kind result-note -Path "$D/results.json"
$md = Build-QaReportMd -Title $title -Code $Code -Item $item -Res $res -Map $map -Run $run -Tester $tester -Date $Date -GuideUrl $guideUrl
$null = Test-KitProse -Kind qa-report -Text $md
$md | Out-File "$D/report.md" -Encoding utf8
$kept = $prev.doc -match '^https?://' -and $prev.doc -notmatch '/d//' -and "$($prev.report)" -in '', $rtype
if ($kept) { $docUrl = $prev.doc }   # a re-run keeps the posted report
else {   # devtools doc (reports.type); kept-file types keep it in $D
  $o = & (Get-Python) -X utf8 $KitCmd.devtools doc "$title $Code - Test Results ($Date)" "$D/report.$(if ($html -and $rtype -eq 'gdocs') { 'html' } else { 'md' })" $(if ($map.folderId) { $map.folderId } else { $D }) --type $rtype 2>&1 | ForEach-Object { "$_" }
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

# ---- annotate: -Rect 'x,y,w,h[,label]' boxes on a PNG/JPEG (Windows only); image px (web: CSS px x DPR)
function Invoke-Annotate {
param([Parameter(Mandatory)][string]$In, [string]$Out, [string[]]$Rect = @(), [switch]$Copy)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'annotate needs Windows (System.Drawing): elsewhere mark() before shot(), or name the element in the check note' }
$Rect = @(Split-KitList $Rect ';')   # one box each, its commas stay
Add-Type -AssemblyName System.Drawing
$src = (Resolve-Path $In).Path
if (-not $Out -and $Copy) { $Out = Join-Path (Split-Path $src) ("{0}-marked{1}" -f [IO.Path]::GetFileNameWithoutExtension($src), [IO.Path]::GetExtension($src)) }
if (-not $Out) { $Out = $src }
$ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($src))   # read fully: the file may be overwritten
$img0 = [Drawing.Image]::FromStream($ms)
$bmp = New-Object Drawing.Bitmap $img0.Width, $img0.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
$g.DrawImage($img0, 0, 0, $img0.Width, $img0.Height)
$k = [math]::Max(1, $img0.Width / 1300)   # sizes grow with the image
$red = [Drawing.Color]::FromArgb(230, 220, 38, 38)
$pen = New-Object Drawing.Pen $red, (4 * $k)
$font = New-Object Drawing.Font ([Drawing.FontFamily]::GenericSansSerif), ([float](15 * $k)), ([Drawing.FontStyle]::Bold)
foreach ($r in $Rect) {
  $p = $r -split ',', 5; $x = [float]$p[0]; $y = [float]$p[1]; $w = [float]$p[2]; $h = [float]$p[3]
  $g.DrawRectangle($pen, $x, $y, $w, $h)
  if ($p.Count -ge 5 -and $p[4]) {   # label above the box, else below; kept inside the image
    $sz = $g.MeasureString($p[4], $font)
    $lx = [math]::Max(0, [math]::Min($x, $bmp.Width - $sz.Width - 2)); $ly = if ($y - 30 * $k -ge 0) { $y - 30 * $k } else { [math]::Min($y + $h + 4 * $k, $bmp.Height - $sz.Height - 2) }
    $g.FillRectangle((New-Object Drawing.SolidBrush $red), $lx, $ly, $sz.Width + 8 * $k, $sz.Height + 2 * $k)
    $g.DrawString($p[4], $font, [Drawing.Brushes]::White, $lx + 4 * $k, $ly + $k)
  }
}
$g.Dispose(); $img0.Dispose(); $ms.Dispose()
$bmp.Save($Out, $(if ($Out -match '\.jpe?g$') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png })); $bmp.Dispose()
"annotated $Out ($(@($Rect).Count) rect)"
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
  "Check the fix is deployed first (qa.ps1 deployed -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.description)`n`n## Comments (oldest first)`n"
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
$r | ConvertTo-Json -Depth 8 | Set-Content "$RunDir/run.json" -Encoding utf8
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir/run.json - launch: Workflow testy { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'seat' { Invoke-KitVerb Invoke-Seat $__rest }
    'deployed' { Invoke-KitVerb Invoke-Deployed $__rest }
    'api' { Invoke-KitVerb Invoke-Api $__rest }
    'finalize' { Invoke-KitVerb Invoke-Finalize $__rest }   # a crash exits 1: Invoke-KitVerb
    'annotate' { Invoke-KitVerb Invoke-Annotate $__rest }
    'retest' { Invoke-KitVerb Invoke-Retest $__rest }
    'ui' {   # phone lanes: extra android-swarm (adapters/ui_android.ps1)
      if (Get-Command Invoke-Ui -ErrorAction SilentlyContinue) { Invoke-KitVerb Invoke-Ui $__rest }
      elseif ((Get-KitSetting 'devices.type' 'android') -eq 'none') { 'no devices (devices.type none): app checks are NOT_TESTED'; exit 1 }
      else { [Console]::Error.WriteLine('qa.ps1 ui (phone lanes) is an extra: run kittool.py extra add android-swarm'); exit 2 }
    }
    { $_ -in '-h', '--help', 'help', '-?' } { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 0 }
    default { (Get-Content $PSCommandPath -Raw) -replace '(?s)^\s*<#\s*(.*?)#>.*$', '$1'; exit 2 }   # the header only
  }
}
