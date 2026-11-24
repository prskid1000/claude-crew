#Requires -Version 7
# Usage: dot-sourced by bossy.ps1 from adapters/. Exit codes: none here (its verbs exit through bossy.ps1).
# deploys: bossy.ps1 deploy merge, dot-sourced by bossy.ps1.
# Merges the main line into a deploy branch through a deploy MR (-Mr: deploy/<env>-<nnnn> pushed, MR per deploy.mergeMethod, merged on green),
# or tags it (deploys[].tag, {n} = the deploy counter; -Push pushes the tag). A deploy branch itself is never pushed to. NO-DATE: the time is in
# the tag message and the commit, never in a ref name; old dated deploy branches still resume.
# Sections: L8 merge · L101 mr
# ---- merge: tag or trunk, the merge in a worktree
function Invoke-DeployMerge {
param(
  [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$To, [string]$From,
  [string]$Check, [switch]$Push, [switch]$Mr, [string[]]$Mrs = @(), [string]$Decision, [int]$WaitMinutes = 8, [int]$History = 300
)
$ErrorActionPreference = 'Stop'
$rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
$rc = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1
# -To: a deploys[] target or branch; tag: tags origin/<From>; trunk (branch = From): no merge
$hit = { param($x) @($x.deploys) | Where-Object { $_.target -eq $To -or $_.branch -eq $To } }
if (-not $rc) {   # -Repo a worktree or another clone: the one repo whose deploys name -To
  $cand = @(@(Get-KitValue 'repos' @()) | Where-Object { & $hit $_ })
  if ($cand.Count -gt 1) { "deploy merge: -To $To names deploys of $(@($cand.name) -join ', '): pass -Repo <that repo's checkout>; nothing merged"; exit 2 }
  $rc = $cand | Select-Object -First 1
}
$dep = & $hit $rc | Select-Object -First 1
if ($dep.target -eq $To -and -not $dep.branch -and -not $dep.tag) { "deploy merge: deploys[] target $To has no branch (kit.local.json repos[].deploys[].branch = the branch its CI deploys from): add it or pass -To <branch>; nothing merged"; exit 2 }
if (-not $From) {
  $From = @($dep.from)[0] ?? $rc.target   # deploys[].from: one repo, two products on different main lines
  if (-not $From) { $h = (git -C $Repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null); if ($h) { $From = ($h -replace '^origin/', '').Trim() } }
  if (-not $From) { "deploy merge: no source branch: pass -From <branch> or set repos[].target (origin/HEAD unknown); nothing merged"; exit 2 }   # no vendor default
  "source branch: $From"
}
if ($dep.tag) {
  git -C $Repo fetch -q origin $From
  if ($LASTEXITCODE) { "fetch origin $From FAILED (exit ${LASTEXITCODE}: offline or wrong -From): no tag"; exit 1 }   # a stale origin/<From> would ship old code
  if ("$($dep.tag)".Contains('{date}')) { Write-Warning "deploys[].tag $($dep.tag): {date} is retired (no date in a ref name): use {n}; it gives the counter now" }
  for ($tn = 0; $tn -lt 20; $tn++) { $dn = if ("$($dep.tag)" -match '\{(n|date)\}') { New-KitId deploy -Number }; $tag = ([string]$dep.tag).Replace('{n}', $dn).Replace('{date}', $dn)
    if (-not $dn) { break }; git -C $Repo rev-parse -q --verify "refs/tags/$tag" 2>$null | Out-Null   # a reset counter skips a taken tag, here or on origin
    if ($LASTEXITCODE -and -not "$(git -C $Repo ls-remote --tags origin "refs/tags/$tag" 2>$null)".Trim()) { break } }
  git -C $Repo tag -a $tag "origin/$From" -m "deploy $To $(Get-KitStamp)"; if ($LASTEXITCODE) { "tag $tag FAILED"; exit 1 }
  if (-not $Push) { "tagged ${tag}: git -C $Repo push origin $tag"; exit 0 }
  git -C $Repo push origin $tag; if ($LASTEXITCODE) { "push of $tag FAILED"; exit 1 }; "pushed $tag"; exit 0
}
$envName = if ($dep.target) { $dep.target } else { $To }
if ($dep.branch) { $To = $dep.branch }
if ($To -eq $From) { "trunk: $To deploys from itself, nothing to merge (deploy record, pokey.ps1 deployed)"; exit 0 }
# deploys[].branchPrefix (deploy.branchPrefix, default deploy/): the pushed source of the deploy MR; mergeMethod (default merge: a merge commit)
$bp = [string]$(if ($dep.branchPrefix) { $dep.branchPrefix } else { Get-KitSetting 'deploy.branchPrefix' 'deploy/' })
$dmm = [string]$(if ($dep.mergeMethod) { $dep.mergeMethod } else { Get-KitSetting 'deploy.mergeMethod' 'merge' })
$dmmText = if ($dmm -eq 'merge') { 'a merge commit, squash off' } else { "merge method $dmm" }   # the MR texts follow deploy.mergeMethod
if ($Push) { "REFUSED: deploy merge -Push would push straight to $To (a deploy branch). It changes only through a deploy MR: re-run with -Mr (pushes $bp$envName-<nnnn>, opens the MR ($dmmText), merges on a green pipeline)."; exit 2 }
$envSlug = $envName -replace '[^\w]+', '-'
if ($Mr) {   # host project + adapter from the origin URL (else repos[].name and gitHostType)
  $hostRepo = Get-HostProject "$($rc.name)" -Raw; $hostType = $script:HostType
  if ("$(git -C $Repo remote get-url origin 2>$null)".Trim() -match '^(?:https?://(?:[^@/]+@)?(?<host>[^/]+)/|[^@]+@(?<host>[^:]+):)(?<path>.+?)(?:\.git)?/?$') {
    $hostRepo = $Matches.path -replace '/_git/', '/' -replace '^v3/', ''; if ($Matches.host -ne $KitConf.GitHost) { $hostType = Get-HostKind $Matches.host }
    if ($hostType -eq 'gitlab') { $env:GITLAB_HOST = $Matches.host }
  }
  $ha = @{ repo = $hostRepo; type = $hostType }
  # a re-run after a cut wait (opsy's shell timeout, 2026-11-23 !651): the open deploy MR of this env resumes, no second branch or MR
  $listed = try { @(Invoke-HostVerb 'mr.list' ($ha + @{ state = 'opened'; target_branch = $To; per_page = 50 }) -NoMemo) } catch { "deploy merge: open deploy MRs unreadable ($($_.Exception.Message)): nothing done, run it again"; exit 1 }
  $open = @($listed | Where-Object { $_ -and "$($_.source_branch)" -match "^$([regex]::Escape("$bp$envSlug"))-(?:\d{8}-\d{6}|\d{4,})$" -and "$($_.target_branch)" -eq $To } | Sort-Object { [long]"$($_.iid)" } -Descending)[0]   # a dated branch (old) too
}
if ($open) {
  $iid = "$($open.iid)"; $br = "$($open.source_branch)"; $made = $null
  git -C $Repo fetch -q origin $From $br 2>$null; git -C $Repo merge-base --is-ancestor "origin/$From" "origin/$br" 2>$null
  if ($LASTEXITCODE) { "deploy MR !$iid ($br) is open but lacks origin/$From (stale): close it, then run this again; nothing merged"; exit 1 }
  $url = if ($open.web_url) { $open.web_url } else { Invoke-HostVerb 'mr.url' ($ha + @{ n = $iid }) }
  "deploy MR: $url ($br -> $To; resumed: open from an earlier run)"
} else {
$name = 'deploymerge-' + ($To -replace '[^\w]+', '-')
for ($bn = 0; $bn -lt 20; $bn++) { $br = "$bp$envSlug-$(New-KitId deploy -Number)"; if (-not "$(git -C $Repo ls-remote --heads origin $br 2>$null)".Trim()) { break } }   # a reset counter skips a taken branch
$out = & $KitCmd.dev wt new -Repo $Repo -Branch $br -Target $To -Name $name -Override 'deploy merge: a dedicated worktree'
$wt = ($out | Where-Object { $_ -match '^worktree:\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
if (-not $wt) { throw "crafty.ps1 wt new failed: $out" }
"worktree: $wt"
git -C $wt fetch -q origin $From $To
if ($LASTEXITCODE) { "fetch origin $From $To FAILED (exit ${LASTEXITCODE}: wrong -From/-To or offline); worktree kept: $wt"; exit 1 }
$ahead = "$(git -C $wt rev-list --count "origin/$To..origin/$From")".Trim()
if ($LASTEXITCODE -or $ahead -notmatch '^\d+$') { "rev-list origin/$To..origin/$From FAILED: '$ahead'; worktree left at $wt"; exit 1 }  # [int]'' is 0
if ([int]$ahead -eq 0) { & $KitCmd.dev wt remove -Dir $wt -Force | Out-Null; git -C $Repo branch -D $br 2>$null | Out-Null; "nothing to merge: origin/$To has all of origin/$From (worktree removed)"; exit 0 }
$mo = git -C $wt merge --no-ff --no-commit "origin/$From" 2>&1; $mrc = $LASTEXITCODE
$mo | Select-Object -Last 3
$conf = @(git -C $wt diff --name-only --diff-filter=U)
if ($mrc -and -not $conf.Count) { "merge FAILED (not a conflict) in $wt"; exit 1 }
$left = @()
foreach ($f in $conf) {
  $theirs = git -C $wt rev-parse "origin/${To}:$f" 2>$null
  $known = $false
  $fromHas = $null -ne (git -C $wt rev-parse -q --verify "origin/${From}:$f" 2>$null)  # modify/delete: no --theirs
  if ($theirs -and $fromHas) { foreach ($c in @(git -C $wt rev-list -n $History "origin/$From" -- $f)) { if ((git -C $wt rev-parse "${c}:$f" 2>$null) -eq $theirs) { $known = $true; break } } }
  if ($known) { git -C $wt checkout --theirs -- $f; git -C $wt add -- $f; "auto: $f (deploy copy = an older $From version -> took $From)" }
  else { $left += $f }
}
if ($left.Count) { "UNRESOLVED (deploy branch has its own changes): "; $left | ForEach-Object { "  $_" }; "Resolve in $wt, git add, crafty.ps1 wt commit -Dir $wt -NoStage, git -C $wt push origin HEAD:refs/heads/$br, then open the deploy MR $br -> $To (squash off) and merge it on green; never push to $To."; exit 2 }
# deploys[].commitTemplate (deploy.commitTemplate): {from} {to} {env}; default the Conventional Commits line below
$ct = [string]$(if ($dep.commitTemplate) { $dep.commitTemplate } else { Get-KitSetting 'deploy.commitTemplate' 'chore(deploy): merge {from} into {to}' })
$msg = $ct.Replace('{from}', $From).Replace('{to}', $To).Replace('{env}', $envName) + $(if ($conf.Count) { "`n`nAdd/add conflicts (old squash merge): $To held older $From versions; took $From's." })
& $KitCmd.dev wt commit -Dir $wt -NoStage -Message $msg
if ($LASTEXITCODE) { "commit FAILED (hooks?) in $wt"; exit 1 }
if ($Check) { & $KitCmd.dev check -Dir (Join-Path $wt $Check); if ($LASTEXITCODE) { "compile FAILED - not pushing"; exit 1 } }
# ---- mr: deploy/<env>-<nnnn> pushed, the deploy MR opened (deploy.mergeMethod), merged on green
if (-not $Mr) { "ready (nothing pushed): review $wt; the deploy MR: crafty.ps1 wt remove -Dir $wt, then the same command with -Mr"; exit 0 }
git -C $wt fetch -q origin $To
git -C $wt merge-base --is-ancestor "origin/$To" HEAD
if ($LASTEXITCODE) { "origin/$To moved while merging - re-run"; exit 1 }
git -C $wt push -q origin "HEAD:refs/heads/$br"
if ($LASTEXITCODE) { "push of $br FAILED (exit $LASTEXITCODE): no deploy MR; worktree kept: $wt"; exit 1 }
$refs = @(Split-KitList $Mrs | ForEach-Object { ConvertTo-MrRef $_ })
$trk = Read-KitTracking; $taskIds = @($trk.tasks.Keys | Where-Object { @(@($trk.tasks[$_].mrs) | Where-Object { $_ -in $refs }).Count } | Sort-Object)
$mrw = [string]$(if ("$(Get-KitMember $script:KitVocab.mrWord $script:HostType)") { Get-KitMember $script:KitVocab.mrWord $script:HostType } else { 'MR' })   # vocab.json mrWord: PR off GitLab
$body = "Deploy ${mrw}: $From into $To (bossy.ps1 deploy merge; $dmmText).`n`n- Env: $envName`n- ${mrw}s: $(if ($refs.Count) { $refs -join ', ' } else { 'none given' })`n- Tasks: $(if ($taskIds.Count) { $taskIds -join ', ' } else { 'none tracked' })`n- Deploy decision: $(if ($Decision) { $Decision } else { 'none given (deploy.trigger rule)' })`n- Commits from ${From}: $ahead"
$made = Invoke-HostVerb 'mr.create' ($ha + @{ source = $br; target = $To; title = ($ct.Replace('{from}', $From).Replace('{to}', $To).Replace('{env}', $envName) -replace '\bmerge (?=\S+ into)', '') + " ($envName)"; body = $body; method = $dmm })
$iid = "$($made.iid)"; if (-not $iid) { "deploy MR create FAILED for $br -> $To (host $hostType, repo $hostRepo): open it by hand ($dmmText); worktree kept: $wt"; exit 1 }
$url = if ($made.web_url) { $made.web_url } else { Invoke-HostVerb 'mr.url' ($ha + @{ n = $iid }) }
"deploy MR: $url ($br -> $To)"
}
# squash is a GitLab MR field; the other hosts take it per merge call (method merge)
if ($made.squash -eq $true -and $dmm -ne 'squash') { "deploy MR $url has squash ON (the project forces it?): turn it off, then merge it by hand on green; not merged"; exit 1 }
$noCi = $rc.ci.mrPipelines -eq $false; $end = (Get-Date).AddMinutes($WaitMinutes); $bk = @{}
do {   # wait for its pipeline: success merges, any other end state stops; an unchanged status backs off
  $cur = Invoke-HostVerb 'mr.get' ($ha + @{ n = $iid }) -NoMemo; $st = "$($cur.head_pipeline.status)"; $cs = if ($cur.head_pipeline) { ConvertTo-KitCiState $st } else { 'none' }
  if ($noCi -or ($cur -and $cur.state -ne 'opened') -or $cs -in 'success', 'failed', 'canceled' -or (__CiWord $st) -in 'skipped', 'manual' -or (Get-Date) -gt $end) { break }
  Wait-KitBackoff $bk $st (Get-KitParam 'deploy.mergePollSec') $end
} while ($true)
if ($cur.state -eq 'merged') { "deploy MR $url already merged"; exit 0 }
if ($cur.state -ne 'opened') { "deploy MR $url is $(if ($cur) { $cur.state } else { 'unreadable' }): not merged"; exit 1 }
if (-not $noCi -and $cs -ne 'success') { "deploy MR $url pipeline $(if ($st) { $st } else { 'none' })$(if ((Get-Date) -gt $end) { " after $WaitMinutes min" }): not merged$(if ($cs -notin 'failed', 'canceled') { '; re-run the same command: it resumes this MR' } else { " (crafty.ps1 pipes -Mrs $url; merge it on green)" })"; exit 1 }
$done = Invoke-HostVerb 'mr.merge' ($ha + @{ n = $iid; method = $dmm; sha = $cur.sha })
# the host merges asynchronously: 'opened' for some seconds after an accepted merge call
for ($i = 0; $i -lt 30 -and "$($done.state)" -ne 'merged'; $i++) { if ($i) { Start-Sleep (Get-KitParam 'deploy.mergeSettleSec') }; $done = Invoke-HostVerb 'mr.get' ($ha + @{ n = $iid }) -NoMemo; if ($done -and $done.state -notin 'opened', 'locked') { break } }
if ($done.state -ne 'merged') { "deploy MR $url merge FAILED (state $($done.state)): merge it by hand ($dmmText)"; exit 1 }
"merged deploy MR $url into $To (merge commit$(if ($ahead) { ", $ahead commits from $From" }))"
}
