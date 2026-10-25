#Requires -Version 7
# deploys (goody): pokey.ps1 deployed and its deploy kinds ssh, awsStack, probe, tag, manual (dot-sourced from adapters/).
# Test-DeployedExtra runs inside Invoke-Deployed and uses its $sha, $s8, $mr, $p, $r, $memo, Row, Api, OnRef, LocalAncestor.
# Sections: L5 shell · L7 probe · L55 kinds · L87 deployed
# ---- shell: one shell line per OS
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# ---- probe: version probe, memoised ssh state
# probeField: JSON path in the answer
function Probe($d, $r) {
  if ($d.tag) { git -C $r.checkout fetch -q --tags 2>$null; return @(git -C $r.checkout tag --sort=-creatordate 2>$null | Where-Object { $_ -match $d.tag })[0] }
  $o = if ($d.probe -match '^https?://') { try { (Invoke-WebRequest $d.probe -ConnectionTimeoutSeconds 30).Content } catch { '' } } else { (Invoke-Sh $d.probe) -join "`n" }
  if ($d.probeField) { try { $j = $o | ConvertFrom-Json; foreach ($k in $d.probeField.Split('.')) { $j = $j.$k }; $o = "$j" } catch { $o = '' } }
  if ($d.probeRegex) { $m = [regex]::Match("$o", [string]$d.probeRegex); return $(if ($m.Success) { $m.Groups[1].Value } else { '' }) }
  [regex]::Match("$o", '\b[0-9a-f]{7,40}\b').Value
}
# one memoised ssh call (script as base64); rc 0 match, 1 DIFF, 2 failed
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
function SshState($s, $sha) {
  $sub = ([string]$s.subdir).Trim('/')
  $k = "$($s.host)|$($s.repoDir)|$sub|$($s.appDir)|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $xs = (@($s.exclude | Where-Object { $_ }) | ForEach-Object { Sq $_ }) -join ' '
  $awk = 'NR == FNR { if (length($0) > 66) a[substr($0, 67)] = substr($0, 1, 64); next } length($0) > 66 { p = substr($0, 67); if (!(p in a)) print "not installed: " p; else if (a[p] != substr($0, 1, 64)) print "differs: " p }'
  $sh = @(
    '{'
    "R=$(Sq ([string]$s.repoDir).TrimEnd('/')); SUB=$(Sq $sub); A=$(Sq ([string]$s.appDir).TrimEnd('/')); X=($xs); SU=$(if ($s.sudo -ne $false) { "'sudo -n'" })"
    'H=sha256sum; command -v sha256sum >/dev/null || H="shasum -a 256"'
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service) { "echo `"SVC=`$(systemctl show -p ActiveEnterTimestamp --value $(Sq $s.service) 2>/dev/null)`"" })
    'skip() { local c pat cs; IFS=/ read -ra cs <<< "$1"; for c in "${cs[@]}"; do for pat in "${X[@]}"; do [[ $c == $pat ]] && return 0; done; done; return 1; }'
    'cd "$R" 2>/dev/null || { echo RC=2; echo "DIFF=cannot cd to $R"; exit 0; }'
    '$SU test -d "$A" 2>/dev/null || { echo RC=2; echo "DIFF=$SU test -d $A failed (no app dir / passwordless sudo: ssh.sudo false)"; exit 0; }'
    'L=$(mktemp) || { echo RC=2; echo "DIFF=mktemp failed"; exit 0; }; trap ''rm -f "$L"'' EXIT'
    'git ls-files -z -- ${SUB:+"$SUB"} | while IFS= read -r -d "" f; do r="${f#"$SUB"/}"; skip "$r" || printf "%s\0" "$r"; done > "$L"'
    'N=$(tr -cd "\0" < "$L" | wc -c); echo "FILES=$N"'
    '[ "$N" -gt 0 ] || { echo RC=2; echo "DIFF=git ls-files lists no tracked files under ${SUB:-the repo}"; exit 0; }'
    'src=$(cd "$R/$SUB" && xargs -0 $H -- < "$L" 2>/dev/null)'
    'app=$($SU sh -c ''cd "$1" && shift && xargs -0 "$@" -- 2>/dev/null'' _ "$A" $H < "$L")'
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
# ---- kinds: ssh, awsStack, probe, tag, manual
function Test-DeployedExtra($d) {
  if ($d.ssh) {   # host HEAD holds the merge AND files match
    $s = $d.ssh; $st = SshState $s $sha
    if (-not $st) { return Row $d 'UNKNOWN' "no answer from $($s.host) over ssh (key $($s.key); the host needs bash, git, base64)" }
    $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
    if ($st.rc -gt 1 -and -not $st.head) { return Row $d 'UNKNOWN' "host checkout unreadable: $(($st.diff | Select-Object -First 2) -join '; ')" }   # a wrong repoDir is not 'not deployed'
    if (-not $st.anc) { return Row $d 'NOT-DEPLOYED' "$s8 is not in the host checkout ($where)" }
    if ($st.rc -gt 1) { return Row $d 'UNKNOWN' "in the host checkout, but the compare failed: $(($st.diff | Select-Object -First 2) -join '; ')" }
    if ($st.diff.Count) { return Row $d 'NOT-DEPLOYED' "in the host checkout ($where), but $($st.diff.Count) of $($st.files) tracked file(s) differ from the installed app: $(($st.diff | Select-Object -First 3) -join '; ')" }
    return Row $d 'DEPLOYED' "in the host checkout and installed ($($st.files) tracked files match, $where)"
  }
  if ($d.probe -or $d.tag) {   # live commit: probe (URL / command) or newest matching tag
    $c = Probe $d $r; $w = if ($d.tag) { "tag $c" } else { "probe commit $c" }
    if (-not $c) { return Row $d 'UNKNOWN' "no commit from $(if ($d.tag) { "tags matching $($d.tag)" } else { "probe $($d.probe)" })" }
    $on = LocalAncestor $r.checkout $sha $c; if ($null -eq $on) { $on = OnRef $p $mr $sha $c }
    return Row $d $(if ($on) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }) "$w $(if ($on) { 'holds' } else { 'lacks' }) $s8"
  }
  if ($d.manual) { return Row $d 'MANUAL' 'deployed by hand: confirm with the owner or an ssh check' }
  if ($d.awsStack) {   # no CI job: stack updated after the merge
    $ra = if ($d.region) { @('--region', $d.region) } else { @() }   # else AWS CLI default region
    $upd = aws cloudformation describe-stacks @ra --stack-name $d.awsStack --query 'Stacks[0].[LastUpdatedTime,StackStatus,CreationTime]' --output text 2>$null
    if (-not $upd) { return Row $d 'UNKNOWN' "cannot read stack $($d.awsStack) (aws sts get-caller-identity?)" }
    $at, $st, $created = "$upd" -split '\s+'
    if ($at -eq 'None') { $at = $created }   # a stack never updated since creation
    try {
      if ([datetimeoffset]$at -gt [datetimeoffset]$mr.merged_at -and $st -match 'COMPLETE$' -and $st -notmatch 'ROLLBACK') { Row $d 'DEPLOYED' "stack $($d.awsStack) updated $at after the merge (by hand: confirm the build was from the merged branch)" }
      else { Row $d 'NOT-DEPLOYED' "stack $($d.awsStack) last updated $at ($st), merged $($mr.merged_at)" }
    } catch { Row $d 'UNKNOWN' "stack $($d.awsStack): cannot read its update time ($upd)" }
  }
}

# ---- deployed: pokey.ps1 deployed, an MR live per test env
# pokey.ps1 deployed: is a merged MR live on a test env (CI deploy job, squash-merged deploy MR, same content; laneApk: goody
# android-swarm; the kinds ssh, awsStack, probe, tag, manual: Test-DeployedExtra below)
function Invoke-Deployed {
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json, [switch]$Detail, [string]$Exclude, [switch]$Lines)   # -Exclude <regex>: skip those targets; -Lines: one JSON row per line as each is known (deploy plan keeps them on a timeout)
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
$out = [Collections.Generic.List[object]]::new()
& { foreach ($m in @(Split-KitList $Mrs)) {
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
      else { Row $d 'UNKNOWN' 'deploys[] laneApk is a goody: run kitbag.py goody add android-swarm' }
      continue
    }
    if ($d.ssh -or $d.awsStack -or $d.probe -or $d.tag -or $d.manual) { Test-DeployedExtra $d; continue }
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
} } | ForEach-Object { $out.Add($_); if ($Lines) { $_ | ConvertTo-Json -Depth 3 -Compress } }
if ($Lines) { exit $(if (@($out | Where-Object { $_.state -ne 'DEPLOYED' }).Count) { 1 } else { 0 }) }
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
