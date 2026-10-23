#Requires -Version 7
# Extra deploys (kittool.py extra add deploys): orch.ps1 deploy merge, dot-sourced by orch.ps1.
# Merges the main line into a deploy branch, or tags it (deploys[].tag), in a worktree; pushes only with -Push after a clean merge.
function Invoke-DeployMerge {
param(
  [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$To, [string]$From,
  [string]$Check, [switch]$Push, [int]$History = 300
)
$ErrorActionPreference = 'Stop'
$rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
$rc = @(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1
if (-not $From) {
  $From = $rc.target
  if (-not $From) { $h = (git -C $Repo symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null); if ($h) { $From = ($h -replace '^origin/', '').Trim() } }
  if (-not $From) { $From = 'main' }
  "source branch: $From"
}
# -To: a deploys[] target or branch; tag: tags origin/<From>; trunk (branch = From): no merge
$dep = @($rc.deploys) | Where-Object { $_.target -eq $To -or $_.branch -eq $To } | Select-Object -First 1
if ($dep.tag) {
  $tag = ([string]$dep.tag).Replace('{date}', [datetime]::UtcNow.ToString('yyyyMMddHHmm')); git -C $Repo fetch -q origin $From
  if ($LASTEXITCODE) { "fetch origin $From FAILED (exit ${LASTEXITCODE}: offline or wrong -From): no tag"; exit 1 }   # a stale origin/<From> would ship old code
  git -C $Repo tag -a $tag "origin/$From" -m "deploy $To"; if ($LASTEXITCODE) { "tag $tag FAILED"; exit 1 }
  if (-not $Push) { "tagged ${tag}: git -C $Repo push origin $tag"; exit 0 }
  git -C $Repo push origin $tag; if ($LASTEXITCODE) { "push of $tag FAILED"; exit 1 }; "pushed $tag"; exit 0
}
if ($dep.branch) { $To = $dep.branch }
if ($To -eq $From) { "trunk: $To deploys from itself, nothing to merge (deploy record, qa.ps1 deployed)"; exit 0 }
$name = 'deploymerge-' + ($To -replace '[^\w]+', '-')
$br = "deploy/$($To -replace '[^\w]+', '-')-$(Get-Date -Format yyyyMMddHHmm)"
$out = & $KitCmd.dev wt new -Repo $Repo -Branch $br -Target $To -Name $name
$wt = ($out | Where-Object { $_ -match '^worktree:\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
if (-not $wt) { throw "dev.ps1 wt new failed: $out" }
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
if ($left.Count) { "UNRESOLVED (deploy branch has its own changes): "; $left | ForEach-Object { "  $_" }; "Resolve in $wt, git add, dev.ps1 wt commit -Dir $wt -NoStage, push."; exit 2 }
$msg = "chore(deploy): merge $From into $To" + $(if ($conf.Count) { "`n`nAdd/add conflicts (old squash merge): $To held older $From versions; took $From's." })
& $KitCmd.dev wt commit -Dir $wt -NoStage -Message $msg
if ($LASTEXITCODE) { "commit FAILED (hooks?) in $wt"; exit 1 }
if ($Check) { & $KitCmd.dev check -Dir (Join-Path $wt $Check); if ($LASTEXITCODE) { "compile FAILED - not pushing"; exit 1 } }
if (-not $Push) { "ready: review $wt, then git -C $wt push origin HEAD:$To"; exit 0 }
git -C $wt fetch -q origin $To
git -C $wt merge-base --is-ancestor "origin/$To" HEAD
if ($LASTEXITCODE) { "origin/$To moved while merging - re-run"; exit 1 }
git -C $wt push origin "HEAD:$To"
if ($LASTEXITCODE) { "push FAILED (exit $LASTEXITCODE): nothing reached $To; worktree kept: $wt"; exit 1 }
"pushed $(git -C $wt rev-parse --short HEAD) to $To ($ahead commits from $From)"
}
