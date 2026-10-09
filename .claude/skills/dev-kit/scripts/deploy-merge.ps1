#Requires -Version 7
<#
Merges a source branch (usually main) into a deploy branch (e.g. staging/<product>) so merged fixes reach the test environment.
Automates the one conflict rule that is always safe: a deploy-branch file that is byte-identical to SOME earlier version of the
same file on the source branch (it came in through an earlier squashed/cherry-picked merge) takes the source's current version.
Any other conflict stops the script with the list, for a human or agent to resolve.

  & <kit>/skills/dev-kit/scripts/deploy-merge.ps1 -Repo <main checkout> -To staging/<product> [-From main] [-Push] [-Check <dir to compile>]

Steps: fresh worktree from origin/<To> (wt.ps1 new), merge --no-ff origin/<From>, auto-resolve as above, commit with hooks
(wt.ps1 commit), optional compile (check.ps1 -Dir <worktree>/<Check>), then with -Push a plain (fast-forward) push to <To>.
Without -Push it stops after the commit so you can look first. Prints the worktree; remove it afterwards with wt.ps1 remove.
#>
param(
  [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$To, [string]$From = 'main',
  [string]$Check, [switch]$Push, [int]$History = 300
)
$ErrorActionPreference = 'Stop'
$K = $PSScriptRoot
$name = 'deploymerge-' + ($To -replace '[^\w]+', '-')
$br = "deploy/$($To -replace '[^\w]+', '-')-$(Get-Date -Format yyyyMMddHHmm)"
$out = & (Join-Path $K 'wt.ps1') new -Repo $Repo -Branch $br -Target $To -Name $name
$wt = ($out | Where-Object { $_ -match '^worktree:\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() }) | Select-Object -First 1
if (-not $wt) { throw "wt.ps1 new failed: $out" }
"worktree: $wt"
git -C $wt fetch -q origin $From $To
$ahead = git -C $wt rev-list --count "origin/$To..origin/$From"
if ([int]$ahead -eq 0) { & (Join-Path $K 'wt.ps1') remove -Dir $wt -Force | Out-Null; git -C $Repo branch -D $br 2>$null | Out-Null; "nothing to merge: origin/$From has no commits that origin/$To lacks (worktree removed)"; exit 0 }
git -C $wt merge --no-ff "origin/$From" -m "chore(deploy): merge $From into $To" 2>&1 | Select-Object -Last 3
$conf = @(git -C $wt diff --name-only --diff-filter=U)
$left = @()
foreach ($f in $conf) {
  $theirs = git -C $wt rev-parse "origin/${To}:$f" 2>$null   # the deploy branch's blob before the merge
  $known = $false
  if ($theirs) { foreach ($c in @(git -C $wt rev-list -n $History "origin/$From" -- $f)) { if ((git -C $wt rev-parse "${c}:$f" 2>$null) -eq $theirs) { $known = $true; break } } }
  if ($known) { git -C $wt checkout --theirs -- $f; git -C $wt add -- $f; "auto: $f (deploy copy = an older $From version -> took $From)" }
  else { $left += $f }
}
if ($left.Count) { "UNRESOLVED (deploy branch has its own changes): "; $left | ForEach-Object { "  $_" }; "Resolve in $wt, git add, then wt.ps1 commit -Dir $wt -NoStage and push yourself."; exit 2 }
if ($conf.Count) {
  & (Join-Path $K 'wt.ps1') commit -Dir $wt -NoStage -Message "chore(deploy): merge $From into $To`n`nAdd/add conflicts from an earlier squashed merge: the $To copies equalled older $From versions, so $From's current version was taken."
  if ($LASTEXITCODE) { "commit FAILED (hooks?) in $wt"; exit 1 }
}
if ($Check) { & (Join-Path $K 'check.ps1') -Dir (Join-Path $wt $Check); if ($LASTEXITCODE) { "compile FAILED - not pushing"; exit 1 } }
if (-not $Push) { "ready: review $wt, then push with: git -C $wt push origin HEAD:$To"; exit 0 }
git -C $wt fetch -q origin $To
git -C $wt merge-base --is-ancestor "origin/$To" HEAD
if ($LASTEXITCODE) { "origin/$To moved while merging - re-run"; exit 1 }
git -C $wt push origin "HEAD:$To"
"pushed $(git -C $wt rev-parse --short HEAD) to $To ($ahead commits from $From)"
