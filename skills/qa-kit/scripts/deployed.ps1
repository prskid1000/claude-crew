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
the host>", "appDir": "<installed app dir>", "subdir": "<optional: part of repoDir that is installed>", "exclude": ["data"],
"service": "<optional systemd unit, for its start time>" } }: live when the MR's commit is an ancestor of the host checkout's HEAD
AND `sudo diff -rq` shows no differing code files between repoDir/subdir and appDir (one ssh call, BatchMode). Without a way to
check, { "target": ..., "manual": true } reports MANUAL (confirm with the owner or an ssh check), never NOT-DEPLOYED.
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
# Hand-deployed host: one ssh call per (host, dirs, commit), memoised. The script goes over base64 so no quoting or CRLF survives
# Windows argument passing. Returns @{ head; anc; rc; diff; svc } or $null when the host cannot be reached.
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
function SshState($s, $sha) {
  $src = if ($s.subdir) { "$($s.repoDir.TrimEnd('/'))/$($s.subdir)" } else { $s.repoDir }
  $k = "$($s.host)|$($s.repoDir)|$src|$($s.appDir)|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $x = (@('.git', '__pycache__', '*.pyc', 'venv', 'current') + @($s.exclude | Where-Object { $_ }) | ForEach-Object { "-x $(Sq $_)" }) -join ' '
  $sh = @(
    "R=$(Sq $s.repoDir); S=$(Sq $src); A=$(Sq $s.appDir.TrimEnd('/'))"
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service) { "echo `"SVC=`$(systemctl show -p ActiveEnterTimestamp --value $(Sq $s.service) 2>/dev/null)`"" })
    "out=`$(sudo -n diff -rq $x `"`$S`" `"`$A`" 2>&1); echo RC=`$?"
    'printf "%s\n" "$out" | grep -v "^Only in $A[/:]" | grep -v "^$" | sed "s/^/DIFF=/"'
  ) -join "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
  $key = [string]$s.key -replace '^~', $HOME
  $lines = @(ssh -i $key -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $s.host "echo $b64 | base64 -d | bash" 2>$null)
  $r = if (-not ($lines -match '^RC=')) { $null } else {
    @{ head = (($lines -match '^HEAD=') -replace '^HEAD=', '' | Select-Object -First 1).Trim()
       anc = [bool]($lines -match '^ANC=yes'); rc = [int](($lines -match '^RC=') -replace '^RC=', '' | Select-Object -First 1)
       diff = @($lines -match '^DIFF=' -replace '^DIFF=', ''); svc = (($lines -match '^SVC=') -replace '^SVC=', '' | Select-Object -First 1) }
  }
  $memo[$k] = $r; $r
}

# `pwsh -File deployed.ps1 -Mrs 'a!1','b!2'` hands over the quotes literally; strip them and split on commas/spaces.
$out = foreach ($m in @($Mrs -split '[\s,]+' | ForEach-Object { $_.Trim("'", '"') } | Where-Object { $_ })) {
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
    if ($d.ssh) {   # deployed by hand onto a host: the host checkout holds the merge AND the installed app matches it
      $s = $d.ssh; $st = SshState $s $sha
      if (-not $st) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "cannot reach $($s.host) over ssh (key $($s.key)); confirm with the owner" }; continue }
      $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
      if (-not $st.anc) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "$($sha.Substring(0, [math]::Min(8, $sha.Length))) is not in the host checkout ($where)" }; continue }
      if ($st.rc -gt 1) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'UNKNOWN'; detail = "in the host checkout, but diff failed: $(($st.diff | Select-Object -First 2) -join '; ') (sudo -n?)" }; continue }
      if ($st.diff.Count) { [pscustomobject]@{ mr = $ref; target = $d.target; state = 'NOT-DEPLOYED'; detail = "in the host checkout ($where), but $($st.diff.Count) file(s) differ from the installed app: $(($st.diff | Select-Object -First 3) -join '; ')" }; continue }
      [pscustomobject]@{ mr = $ref; target = $d.target; state = 'DEPLOYED'; detail = "in the host checkout and installed ($where)" }
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
