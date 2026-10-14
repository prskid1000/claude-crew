#Requires -Version 7
<#
Is a merged MR live on a test environment? Answers from the CI, not from memory: the MR's merge commit must be on
the deploy branch AND on a pipeline on that branch whose deploy job succeeded. "On" = an ancestor, or (squashed "merge main
into staging" / cherry-picks) the MR is on its target branch and none of its files differ between that branch and the deploy ref.

  $D = '<kit>/skills/qa-kit/scripts/deployed.ps1'
  & $D -Mrs backend!812,web!415                     # compact: one summary line + a line per MR/target NOT live; exit 0 when every MR is live
  & $D -Mrs backend!812,web!415 -Detail             # one line per MR per deploy target, live ones too
  & $D -Mrs backend!812 -Target staging -Json       # machine-readable

Deploy targets come from dev-kit/kit.local.json: repos[].deploys = [{ "target": "staging", "branch": "staging",
"job": "deploy-staging" }]. A repo deployed by hand (no CI job) uses { "target": ..., "awsStack": "<CloudFormation stack>", "region": ... }:
live when the stack was updated after the merge. A repo without deploys reports NO-TARGET.
A repo deployed by hand onto a host: { "target": ..., "ssh": { "host": "user@host", "key": "<key file>", "repoDir": "<repo checkout on
the host>", "appDir": "<installed app dir>", "subdir": "<optional: part of repoDir that is installed>", "exclude": ["<optional
extra glob per path part>"], "service": "<optional systemd unit, for its start time>" } }: live when the MR's commit is an ancestor
of the host checkout's HEAD AND every file git tracks under repoDir/subdir (`git ls-files`) has the same sha256 under appDir (read
with `sudo -n`; one ssh call per host+commit, BatchMode). Untracked or ignored runtime files in appDir (logs, node_modules,
generated assets) never count, so `exclude` is only needed for tracked files the install leaves out on purpose. Without a way to
check, { "target": ..., "manual": true } reports MANUAL (confirm with the owner or an ssh check), never NOT-DEPLOYED.
An app repo tested on the emulator lanes: { "target": ..., "laneApk": true } (or the path of an app.json): live when the MR's merge
commit is an ancestor of the commit the lane APK was built from (android-swarm apk/app.json, written by app-build.ps1).
Use it before holding a QA item as "not deployed yet", and supervise.ps1 -AutoFix uses it to flag promoted tasks that went live.
#>
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json, [switch]$Detail)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\kitconfig.ps1')
if (-not $env:GITLAB_HOST -and $KitConf.GitHost -ne 'gitlab.com') { $env:GITLAB_HOST = $KitConf.GitHost }   # self-hosted GitLab for glab
$group = $KitConf.GitlabGroup
$repos = @(Get-KitValue 'repos' @())
function Repo($name) { $repos | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1 }
# memoised: supervise checks many MRs on the same branches/pipelines each round (unmemoised: 100+ sequential API calls, > 2 min)
$memo = @{}
function Api($path) { if (-not $memo.ContainsKey($path)) { $memo[$path] = glab api $path 2>$null | ConvertFrom-Json }; $memo[$path] }
function IsAncestor($p, $sha, $ref) { if ($sha -eq $ref) { return $true }; (Api "projects/$p/repository/merge_base?refs[]=$sha&refs[]=$([uri]::EscapeDataString($ref))").id -eq $sha }
# A squashed "merge main into staging" (or a cherry-pick) carries the MR's content without its commit: ancestry says no.
# Fallback: the MR is on its target branch (e.g. main) and none of its files differ between that branch and $ref.
function ContentOn($p, $mr, $sha, $ref) {
  # cheap guard first (supervise runs this for many MRs): a ref last committed before the merge cannot hold it
  $head = Api "projects/$p/repository/commits/$([uri]::EscapeDataString($ref))"
  if (-not $head -or ($mr.merged_at -and [datetimeoffset]$head.committed_date -lt [datetimeoffset]$mr.merged_at)) { return $false }
  if (-not (IsAncestor $p $sha $mr.target_branch)) { return $false }
  $files = @((Api "projects/$p/merge_requests/$($mr.iid)/changes?access_raw_diffs=true").changes | ForEach-Object { $_.new_path; $_.old_path } | Sort-Object -Unique)
  if (-not $files.Count) { return $false }
  $cmp = Api "projects/$p/repository/compare?from=$([uri]::EscapeDataString($ref))&to=$([uri]::EscapeDataString($mr.target_branch))&straight=true"
  if (-not $cmp) { return $false }
  -not @($cmp.diffs | Where-Object { $files -contains $_.new_path -or $files -contains $_.old_path }).Count
}
function OnRef($p, $mr, $sha, $ref) { (IsAncestor $p $sha $ref) -or (ContentOn $p $mr $sha $ref) }
# App repos (laneApk): the stamp android-swarm app-build.ps1 writes next to the lane APK (apk/app.json: branch, commit, appDir, built).
# laneApk = true -> <swarm.config.json outDir, else Get-KitPath android-swarm>/apk/app.json; a string = the path of that app.json.
function LaneApk($d) {
  $f = if ($d.laneApk -is [string]) { $d.laneApk } else {
    $sc = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'android-swarm/swarm.config.json'
    $o = if (Test-Path $sc) { (Get-Content $sc -Raw | ConvertFrom-Json).outDir }
    Join-Path $(if ($o) { [string]$o } else { Get-KitPath android-swarm }) 'apk/app.json'
  }
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}
# Local ancestry in the checkout the APK was built from: $true / $false, $null when that checkout or the APK commit is not there.
# A sha unknown to the checkout (exit 128) cannot be an ancestor of a commit the checkout holds: $false.
function LocalAncestor($dir, $sha, $commit) {
  if (-not $dir -or -not (Test-Path $dir)) { return $null }
  git -C $dir cat-file -e "$commit^{commit}" 2>$null; if ($LASTEXITCODE) { return $null }
  git -C $dir merge-base --is-ancestor $sha $commit 2>$null
  $LASTEXITCODE -eq 0
}
# Hand-deployed host: one ssh call per (host, dirs, commit), memoised. The script goes over base64 so no quoting or CRLF survives
# Windows argument passing. Returns @{ head; anc; rc; diff; svc; files } or $null when the host cannot be reached.
# Compared: only the files git tracks under repoDir/subdir (minus the optional `exclude` globs, matched against each path part),
# sha256 in the checkout vs the same relative path under appDir (sudo -n). rc 0 = all match, 1 = DIFF lines, 2 = could not compare.
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
function SshState($s, $sha) {
  $sub = ([string]$s.subdir).Trim('/')
  $k = "$($s.host)|$($s.repoDir)|$sub|$($s.appDir)|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $xs = (@($s.exclude | Where-Object { $_ }) | ForEach-Object { Sq $_ }) -join ' '
  $awk = 'NR == FNR { if (length($0) > 66) a[substr($0, 67)] = substr($0, 1, 64); next } length($0) > 66 { p = substr($0, 67); if (!(p in a)) print "not installed: " p; else if (a[p] != substr($0, 1, 64)) print "differs: " p }'
  $sh = @(
    '{'
    "R=$(Sq ([string]$s.repoDir).TrimEnd('/')); SUB=$(Sq $sub); A=$(Sq ([string]$s.appDir).TrimEnd('/')); X=($xs)"
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service) { "echo `"SVC=`$(systemctl show -p ActiveEnterTimestamp --value $(Sq $s.service) 2>/dev/null)`"" })
    'skip() { local c pat cs; IFS=/ read -ra cs <<< "$1"; for c in "${cs[@]}"; do for pat in "${X[@]}"; do [[ $c == $pat ]] && return 0; done; done; return 1; }'
    'cd "$R" 2>/dev/null || { echo RC=2; echo "DIFF=cannot cd to $R"; exit 0; }'
    'sudo -n test -d "$A" 2>/dev/null || { echo RC=2; echo "DIFF=sudo -n test -d $A failed (no passwordless sudo, or no app dir)"; exit 0; }'
    'L=$(mktemp) || { echo RC=2; echo "DIFF=mktemp failed"; exit 0; }; trap ''rm -f "$L"'' EXIT'
    'git ls-files -z -- ${SUB:+"$SUB"} | while IFS= read -r -d "" f; do r="${f#"$SUB"/}"; skip "$r" || printf "%s\0" "$r"; done > "$L"'
    'N=$(tr -cd "\0" < "$L" | wc -c); echo "FILES=$N"'
    '[ "$N" -gt 0 ] || { echo RC=2; echo "DIFF=git ls-files lists no tracked files under ${SUB:-the repo}"; exit 0; }'
    'src=$(cd "$R/$SUB" && xargs -0 sha256sum -- < "$L" 2>/dev/null)'
    'app=$(sudo -n sh -c ''cd "$1" && xargs -0 sha256sum -- 2>/dev/null'' _ "$A" < "$L")'
    "out=`$(awk $(Sq $awk) <(printf '%s\n' `"`$app`") <(printf '%s\n' `"`$src`"))"
    'if [ -n "$out" ]; then echo RC=1; printf "%s\n" "$out" | sed "s/^/DIFF=/"; else echo RC=0; fi'
    '}'
  ) -join "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
  $key = [string]$s.key -replace '^~', $HOME
  $lines = @(ssh -i $key -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $s.host "echo $b64 | base64 -d | bash" 2>$null)
  $r = if (-not ($lines -match '^RC=')) { $null } else {
    @{ head = (($lines -match '^HEAD=') -replace '^HEAD=', '' | Select-Object -First 1).Trim()
       anc = [bool]($lines -match '^ANC=yes'); rc = [int](($lines -match '^RC=') -replace '^RC=', '' | Select-Object -First 1)
       diff = @($lines -match '^DIFF=' -replace '^DIFF=', ''); svc = (($lines -match '^SVC=') -replace '^SVC=', '' | Select-Object -First 1)
       files = [int](($lines -match '^FILES=') -replace '^FILES=', '' | Select-Object -First 1) }
  }
  $memo[$k] = $r; $r
}

# `pwsh -File deployed.ps1 -Mrs 'a!1','b!2'` hands over the quotes literally; strip them and split on commas/spaces.
$out = foreach ($m in @(Split-KitList $Mrs)) {   # kitconfig.ps1
  if ($m -notmatch '^(?<repo>[\w.-]+)!(?<iid>\d+)$') { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'expected <repo>!<iid>' }; continue }
  $r = Repo $Matches.repo; $iid = $Matches.iid
  if (-not $r) { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'repo not in kit.local.json' }; continue }
  $p = [uri]::EscapeDataString($(if ($group) { "$group/$($r.name)" } else { $r.name })); $ref = "$($r.name)!$iid"
  $mr = Api "projects/$p/merge_requests/$iid"
  if ($mr.state -ne 'merged') { [pscustomobject]@{ mr = $ref; target = ''; state = 'NOT-MERGED'; detail = "$($mr.state)" }; continue }
  # fast-forward merges have no merge commit: the MR head (sha) is what landed on the target
  $sha = @($mr.squash_commit_sha, $mr.merge_commit_sha, $mr.sha) | Where-Object { $_ } | Select-Object -First 1
  if (-not $sha) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'UNKNOWN'; detail = 'merged MR has no commit sha (glab auth status?)' }; continue }
  $deps = @($r.deploys | Where-Object { -not $Target -or $_.target -eq $Target })
  if (-not $deps.Count) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'NO-TARGET'; detail = 'no deploys configured for this repo' }; continue }
  foreach ($d in $deps) {
    if ($d.laneApk) {   # app repo, no deploy pipeline: live on the test phones when the lane APK was built from a commit holding the merge
      $ai = LaneApk $d
      if (-not $ai -or -not $ai.commit) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = 'no lane APK stamp (android-swarm apk/app.json): build the APK with app-build.ps1' }; continue }
      $apk = "APK $($ai.commit) ($($ai.branch), built $($ai.built))"
      $on = LocalAncestor $ai.appDir $sha $ai.commit
      if (-not $on) { $on = OnRef $p $mr $sha $ai.commit }   # no local checkout, or squashed / cherry-picked content: ask the git host
      if ($on) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "in the lane $apk (phones get it on their next phone.ps1 acquire)" } }
      else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "$($sha.Substring(0, [math]::Min(8, $sha.Length))) is not in the lane ${apk}: rebuild it (app-build.ps1) from a branch holding the merge" } }
      continue
    }
    if ($d.ssh) {   # deployed by hand onto a host: the host checkout holds the merge AND the installed app matches it
      $s = $d.ssh; $st = SshState $s $sha
      if (-not $st) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "cannot reach $($s.host) over ssh (key $($s.key)); confirm with the owner" }; continue }
      $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
      if (-not $st.anc) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "$($sha.Substring(0, [math]::Min(8, $sha.Length))) is not in the host checkout ($where)" }; continue }
      if ($st.rc -gt 1) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "in the host checkout, but the compare failed: $(($st.diff | Select-Object -First 2) -join '; ')" }; continue }
      if ($st.diff.Count) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "in the host checkout ($where), but $($st.diff.Count) of $($st.files) tracked file(s) differ from the installed app: $(($st.diff | Select-Object -First 3) -join '; ')" }; continue }
      [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "in the host checkout and installed ($($st.files) tracked files match, $where)" }
      continue
    }
    if ($d.manual) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'MANUAL'; detail = 'deployed by hand: confirm with the owner or an ssh check' }; continue }
    if ($d.awsStack) {   # deployed by hand (no CI job): live only if the CloudFormation stack was updated after the merge
      $upd = aws cloudformation describe-stacks --region $(if ($d.region) { $d.region } else { 'eu-west-1' }) --stack-name $d.awsStack --query 'Stacks[0].[LastUpdatedTime,StackStatus,CreationTime]' --output text 2>$null
      if (-not $upd) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "cannot read stack $($d.awsStack) (aws sts get-caller-identity?)" }; continue }
      $at, $st, $created = "$upd" -split '\s+'
      if ($at -eq 'None') { $at = $created }   # a stack never updated since creation
      try {
        if ([datetimeoffset]$at -gt [datetimeoffset]$mr.merged_at -and $st -match 'COMPLETE$' -and $st -notmatch 'ROLLBACK') { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "stack $($d.awsStack) updated $at after the merge (by hand: confirm the build was from the merged branch)" } }
        else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "stack $($d.awsStack) last updated $at ($st), merged $($mr.merged_at)" } }
      } catch { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "stack $($d.awsStack): cannot read its update time ($upd)" } }
      continue
    }
    if (-not (OnRef $p $mr $sha $d.branch)) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "not on $($d.branch) yet" }; continue }
    $hit = $null
    # a pipeline created before the merge cannot contain it: skip those without asking for their jobs
    foreach ($pl in @(Api "projects/$p/pipelines?ref=$([uri]::EscapeDataString($d.branch))&per_page=10") | Where-Object { -not $mr.merged_at -or [datetimeoffset]$_.created_at -ge [datetimeoffset]$mr.merged_at }) {
      $job = @(Api "projects/$p/pipelines/$($pl.id)/jobs?per_page=100") | Where-Object { $_.name -eq $d.job } | Select-Object -First 1
      if ($job.status -eq 'success' -and ($pl.sha -eq $sha -or (OnRef $p $mr $sha $pl.sha))) { $hit = $job; break }
    }
    if ($hit) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "$($d.job) finished $($hit.finished_at)" } }
    else { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "on $($d.branch), but no successful $($d.job) includes it yet" } }
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
