<#
wt-pool.ps1: fixed worktree slots per repo (crafty.ps1 wt lease / release / pool), leased like phone lanes; a slot is never
deleted, so its build caches stay warm, and one naming scheme for every pooled resource (member n = the n-th bird).
  & <kit>/skills/crafty/crafty.ps1 wt lease -Repo <r> -Branch <b> -Agent <id> [-Target] [-Scope] [-Session] [-WaitMinutes 60]
  & <kit>/skills/crafty/crafty.ps1 wt release -Agent <id> [-Repo] | -Dir <slot> [-Reason]   uncommitted work: a WIP commit, else a patch file, else parked
  & <kit>/skills/crafty/crafty.ps1 wt pool [-Repo] [-Json] [-Sync] | -Migrate [-DryRun]   slots + a repo sync preview (-Sync: run it); per-task worktrees go when nothing is lost
  & <kit>/skills/envy/envy.ps1 lanes -Migrate [-LanesOnly] [-DryRun]   old lane names -> new when idle, orphan / merged branches (Invoke-LaneMigrate)
Inputs: kit.local.json pool.size (10), pool.names, repos[].poolSize. State: <runtime>/work/wt-slots/slot-<nn>-<repo>.json (+ wait/).
Dot-sourced by lib.ps1 (adapters/*.ps1); the Invoke-Wt* verbs run inside crafty.ps1 Invoke-Wt (its parameters and helpers).
Also the sweep of worktrees and local branches (crafty.ps1 wt remove, sweep, cleanup; from crafty.ps1: its token cap).
Exit codes: 0 ok · 1 problem (no slot within -WaitMinutes, a branch another agent holds, git failed) · 2 usage.
Sections: L15 worktrees · L191 names · L284 slots · L354 lease · L472 release · L518 lanes · L667 sync · L769 pool · L812 sweep
#>
#Requires -Version 7
# ---- worktrees: helpers of crafty.ps1 wt (Invoke-Wt, sweep); Get-WtDirty runs inside Invoke-Wt (its Meta)
# crafty.ps1 wt sync (its token cap), inside Invoke-Wt: repos[].regenerate: generated-only rebase conflict -> target's copy + run commands, rebase done, last commit amended + pushed;
# returns 'regenerated ...' or the refusal reason (a failing command: back to the plain conflict)
function Sync-Generated($d, $t, $head0) {
  $gen = @(Get-RepoConf ("$(git -C $d remote get-url origin 2>$null)".Trim() -replace '\.git$' -split '[/:\\]')[-1] 'regenerate' @())
  if (-not $gen.Count) { return '' }
  $taken = @(); $gd = GitDir $d; $last = ''
  while ((Test-Path "$gd/rebase-merge") -or (Test-Path "$gd/rebase-apply")) {
    $u = @(git -C $d -c core.quotepath=false diff --name-only --diff-filter=U)
    $other = @($u | Where-Object { $f = $_; -not ($gen | Where-Object { $f -like $_.path }) })
    $sig = "$(git -C $d rev-parse -q --verify REBASE_HEAD)|$($u -join '|')"   # same commit, same files: no progress
    if ($sig -eq $last) { $other = $u }
    if (-not $u.Count -or $other.Count) { return "not only generated files conflict ($($other -join ', '))$(if ($taken) { "; took the target's $($taken -join ', '): after the rebase run repos[].regenerate run" })" }
    $last = $sig
    foreach ($f in $u) {   # rebase: ours = target; none = target deleted it
      git -C $d checkout -q --ours -- $f 2>$null
      if ($LASTEXITCODE) { git -C $d rm -q -- $f 2>$null } else { git -C $d add -- $f }
    }
    $taken = @($taken + $u | Select-Object -Unique)
    git -C $d diff --cached --quiet
    $step = if ($LASTEXITCODE) { 'continue' } else { 'skip' }   # only generated changes
    $null = git -C $d -c core.editor=true rebase "--$step" 2>&1
  }
  if (-not $taken.Count) { return 'the rebase stopped without a conflict' }
  $mr = if ($Mrs) { ($Mrs -split '[!/#]')[-1] } else { try { "$(@(Get-MergedMrs $d (G -C $d rev-parse --abbrev-ref HEAD).Trim() $t 'opened' | ForEach-Object iid)[0])" } catch { '' } }
  $runs = @($gen | Where-Object { $p = $_.path; $taken | Where-Object { $_ -like $p } } | ForEach-Object { @($_.run) } | Select-Object -Unique | Where-Object { $mr -or $_ -notmatch '\{mr\}' })   # {mr}: only once the MR exists
  foreach ($c in $runs) {
    $tok = Split-KitCommand $c @{ mr = $mr; target = $t }
    $r = Invoke-KitExe $tok[0] @($tok | Select-Object -Skip 1) 900 -Cwd $d
    if ($r.code) { git -C $d reset -q --hard $head0; $null = git -C $d rebase "origin/$t" 2>&1; return "regenerate failed (exit $($r.code)): $c`n$("$($r.err)$($r.out)".Trim() -split "`n" | Select-Object -Last 5)" }
  }
  $own = (G -C $d rev-list --count "origin/$t..HEAD").Trim() -ne '0'   # none: every commit only changed generated files
  git -C $d add -A -- @($taken); git -C $d diff --cached --quiet
  if ($LASTEXITCODE) { if ($own) { G -C $d commit -q --amend --no-edit | Out-Null } else { G -C $d commit -q -m "chore: regenerate $($taken -join ', ')" | Out-Null; $own = $true } }
  $br = (G -C $d rev-parse --abbrev-ref HEAD).Trim(); git -C $d rev-parse -q --verify "refs/remotes/origin/$br" *> $null
  $pushed = if (-not $LASTEXITCODE -and $br -ne $t -and $own) { G -C $d push -q --force-with-lease origin "HEAD:refs/heads/$br" | Out-Null; "; pushed ${br}: run devtools.py merge again" } else { '' }
  "regenerated $($taken -join ', ') (target's copy + $($runs.Count) command(s)$(if (-not $mr) { ', no MR yet: {mr} commands skipped' }))$pushed"
}
# { param($path) -> 'a board agent' | 'a running process' | $null }: a live row's claims + the worktrees its agent checkpointed
# since it joined (a kitty's own worktree went after its push), or a process (editor, build, shell) in the folder
function Get-KitWtHeldTest {
  $now = Get-Date
  $script:KitWtClaimed = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and $_.beat -and ($now - [datetime]$_.beat).TotalHours -lt [double](Get-KitParam 'board.rowHours') } | ForEach-Object {
      $liveRow = $_; $liveRow.worktrees
      if ($liveRow.agent -and $liveRow.joined) { @((Read-KitState (Get-KitCheckpointFile $liveRow.agent "$($liveRow.run)")).steps | Where-Object { $_.dir -and $_.at -and [datetime]$_.at -ge [datetime]$liveRow.joined } | ForEach-Object { $_.dir }) }
    } | Where-Object { "$_" -match '^([A-Za-z]:)?[\\/]' } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/').ToLower() })
  $claimedAt = $script:KitWtClaimed; $cmdLines = @(Get-SysProcs | Where-Object { $_.Id -ne $PID -and $_.CommandLine } | ForEach-Object { $_.CommandLine.Replace('/', '\').ToLower() })
  { param($p) $l = $p.ToLower(); if ($l -in $claimedAt) { 'a board agent' } elseif (@($cmdLines | Where-Object { $_.Contains($l) }).Count) { 'a running process' } }.GetNewClosure()
}
# never deleted: protectedBranchesBase (main/master/develop/release/*), configured lanes' lane/* (+ -<target> of a second target) + localenv/*, protectedBranches, target, deploy branches, origin/HEAD
function Get-KitKeepBranchRx([string]$Repo) {
  $name = ("$(git -C $Repo remote get-url origin 2>$null)".Trim() -replace '\.git$' -split '[/:\\]')[-1]
  $all = @(Get-KitProtectedBranches) + @(Get-KitLaneNames | ForEach-Object { "localenv/$_"; Get-KitLaneBranch $_; "$(Get-KitLaneBranch $_)-*" }) + @(Get-RepoConf $name 'target' '') + @(@(Get-RepoConf $name 'deploys' @()) | ForEach-Object { $_.branch }) + @("$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/')
  '^(' + (@($all | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { [regex]::Escape("$_") -replace '\\\*', '.+' }) -join '|') + ')$'
}
# may a local branch go? delete + why; $Ctx caches per repo (keep rx, checkouts, bases, host MR refs)
function Get-KitBranchVerdict([string]$Repo, [string]$Branch, [hashtable]$Ctx, [double]$IdleHours = 2, [switch]$IgnoreCheckout) {
  $v = { param($go, $why) [pscustomobject]@{ branch = $Branch; delete = [bool]$go; why = $why } }
  if (-not $Ctx.keep) { $Ctx.keep = Get-KitKeepBranchRx $Repo }
  if ($null -eq $Ctx.out) { $Ctx.out = @{}; foreach ($w in @(Get-KitWorktrees $Repo)) { if ($w.branch) { $Ctx.out[$w.branch] = $w.path } } }
  if ($null -eq $Ctx.bases) { $tg = Get-RepoConf ((("$(git -C $Repo remote get-url origin 2>$null)".Trim() -replace '\.git$') -split '[/:\\]')[-1]) 'target' ''
    $Ctx.bases = @(@("$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim(), $(if ($tg) { "origin/$tg" })) | Where-Object { $_ -and (git -C $Repo rev-parse -q --verify "refs/remotes/$_" 2>$null) } | Select-Object -Unique) }
  if ($Branch -match $Ctx.keep) { return & $v $false 'protected (default, target or deploy branch)' }
  if (-not $IgnoreCheckout -and $Ctx.out[$Branch]) { return & $v $false "checked out in $($Ctx.out[$Branch])" }
  $tip = "$(git -C $Repo rev-parse -q --verify "refs/heads/$Branch" 2>$null)".Trim(); if (-not $tip) { return & $v $false 'no such branch' }
  $t = if ("$(git -C $Repo reflog show -1 --format=%gd --date=unix "refs/heads/$Branch" 2>$null)" -match '@\{(\d+)\}') { $Matches[1] } else { "$(git -C $Repo log -1 --format=%ct $tip 2>$null)".Trim() }   # last move, not commit time
  if ($t -and $IdleHours -gt 0 -and ($age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeSeconds([long]$t)).TotalHours) -lt $IdleHours) { return & $v $false "moved $([math]::Round($age * 60)) min ago" }
  foreach ($b in $Ctx.bases) { git -C $Repo merge-base --is-ancestor $tip $b 2>$null; if ($LASTEXITCODE -eq 0) { return & $v $true "merged into $b" } }
  $up, $track = "$(git -C $Repo for-each-ref --format='%(upstream:short)|%(upstream:track)' "refs/heads/$Branch" 2>$null)".Trim() -split '\|', 2
  $on = "$(git -C $Repo for-each-ref --contains $tip --count=1 --format='%(refname:short)' refs/remotes/origin 2>$null)".Trim()
  if (-not $on) {   # MR / PR refs keep pushed work after its branch is deleted
    if ($null -eq $Ctx.mrRefs) { $Ctx.mrRefs = @{}; $r = Invoke-KitExe git @('-C', $Repo, 'ls-remote', 'origin', 'refs/merge-requests/*/head', 'refs/pull/*/head') 30
      foreach ($l in @(if (-not $r.code) { "$($r.out)" -split "`n" })) { $s, $ref = $l.Trim() -split '\s+', 2; if ($ref) { $Ctx.mrRefs[$s] = $ref } } }
    $on = $Ctx.mrRefs[$tip]
  }
  $iid = if ($Branch -match '^(?:mr|pr)[-_]?(\d+)$') { $Matches[1] }   # an MR checkout branch
  if (-not $on -and $Branch -match '^(lane|localenv)/') {   # a lane no longer configured (keep rx: configured lanes only): its own commits are test merges
    $own = @(git -C $Repo log --format=%s $tip --not --remotes=origin 2>$null | Where-Object { $_ -notmatch '^localenv (layer|prepare) ' })
    return & $v (-not $own.Count) $(if ($own.Count) { "dead lane, $($own.Count) commit(s) beyond its test merges" } else { 'dead lane: only local test merges' })
  }
  if (-not $on) {   # squash-merged (K38: with or without an upstream): the tip inside a merged MR's head, or a rebased copy of it
    foreach ($m in @(if ($iid) { Get-MergedMrs $Repo '' '' 'merged' $iid } else { Get-MergedMrs $Repo $Branch })) {
      if ($m.sha -and ($m.sha -eq $tip -or $(git -C $Repo cat-file -e "$($m.sha)^{commit}" 2>$null; if ($LASTEXITCODE) { git -C $Repo fetch -q origin $m.sha 2>$null }; git -C $Repo merge-base --is-ancestor $tip $m.sha 2>$null; $LASTEXITCODE -eq 0) -or (Test-KitRebasedCopy $Repo $tip $m.sha))) { return & $v $true "MR merged, tip in its head ($(if ($iid) { "!$iid" } else { $m.sha.Substring(0, 8) }))" } } }
  if (-not $on) { return & $v $false "$("$(git -C $Repo rev-list --count $tip --not --remotes=origin 2>$null)".Trim()) commit(s) on no remote branch or MR$(if ($track -eq '[gone]') { " (upstream $up gone)" })" }
  if ($track -eq '[gone]') { return & $v $true "upstream $up gone, tip on the host ($on)" }
  if (($up -and ($up -replace '^origin/') -eq $Branch) -or (git -C $Repo rev-parse -q --verify "refs/remotes/origin/$Branch" 2>$null)) {
    if ($tip -in @(Get-MergedMrs $Repo $Branch | ForEach-Object sha)) { return & $v $true 'MR merged at its tip' }
    return & $v $false "open: origin/$Branch not merged"
  }
  & $v $true "local copy, its commits are on the host ($on)"
}
# the worktree root, git-excluded in an outer repo (else untracked there)
function Add-WtRoot($rt) {
  New-Item -ItemType Directory -Force $rt | Out-Null
  $outer = git -C $rt rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $outer) {
    $outer = (Resolve-Path $outer.Trim()).Path; $rootFull = (Resolve-Path $rt).Path
    if ($rootFull.StartsWith($outer, [StringComparison]::OrdinalIgnoreCase) -and $rootFull.Length -gt $outer.Length) {
      $rel = '/' + $rootFull.Substring($outer.Length).TrimStart('\', '/').Replace('\', '/') + '/'
      $ex = Join-Path (git -C $outer rev-parse --path-format=absolute --git-common-dir).Trim() 'info/exclude'
      New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
      if (-not ((Test-Path $ex) -and (Select-String -Path $ex -SimpleMatch -Pattern $rel -Quiet))) { Add-Content $ex $rel }
    }
  }
}
# name or alias: repos[].checkout, else <reposRoot>/<name>
function Resolve-WtRepo($rr) {
  if (-not (Test-Path -LiteralPath $rr)) {
    $hit = @((Get-RepoConf $rr checkout $null), (Join-Path $KitConf.ReposRoot $rr)) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $hit) { throw "no repo $rr (not a folder, no kit.local.json repos[] checkout, not under $($KitConf.ReposRoot)): pass the checkout path" }
    $rr = $hit
  }
  (Resolve-Path $rr).Path
}
# wt sync -Mrs (before a merge): the target touched none of this branch's files -> no rebase, no push, no 2nd CI run (rechy-5: 2
# pipelines per MR); repos[].mergeMethod ff needs the rebase. The skip line, else nothing
function Get-WtSyncSkip([string]$Dir, [string]$t) {
  $theirs = @(git -C $Dir diff --name-only "HEAD...origin/$t"); $mine = @(git -C $Dir diff --name-only "origin/$t...HEAD")
  if ($LASTEXITCODE -or -not $theirs.Count -or "$(Get-RepoConf (("$(git -C $Dir remote get-url origin)".Trim() -replace '\.git$' -split '[/:\\]')[-1]) 'mergeMethod' '')" -eq 'ff' -or @($theirs | Where-Object { $_ -in $mine }).Count) { return }
  "rebase skipped: origin/$t changed $($theirs.Count) file(s), none of this branch's: merge as is"
}
function Get-WtRepoConf($rp) {
  $kc = $KitConf.ConfigFile; if (-not ($kc -and (Test-Path $kc))) { return }
  $rpn = $rp.TrimEnd('\', '/'); @((Get-Content $kc -Raw | ConvertFrom-Json).repos) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rpn) } | Select-Object -First 1
}
# repos[].hooksPath: the repo's hook folder (default .husky: husky's generated <dir>/_ is copied into a fresh worktree)
function Get-WtHooksDir($rc) { if ($rc.hooksPath) { "$($rc.hooksPath)" } else { '.husky' } }
function Copy-HookDirs($path, $sources, [string]$hooksDir = '.husky') {
  foreach ($hs in @($sources | Where-Object { $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique)) {
    foreach ($h in (Get-ChildItem $hs -Directory -Recurse -Depth 3 -Filter '_' -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Name -eq (Split-Path $hooksDir -Leaf) -and $_.FullName -notmatch 'node_modules' })) {
      $to = Join-Path $path $h.FullName.Substring($hs.Length).TrimStart('\', '/')
      if (-not (Test-Path $to)) { Copy-Item $h.FullName $to -Recurse }
    }
  }
}
# kit.local.json dep sources of a target (linkFromByTarget.<t>: a path or a list, first with the package's folder wins); a missing one: error
function Get-WtDepSource($rp, $tg) {
  $rc = Get-WtRepoConf $rp; if (-not $rc) { return }
  $cand = @(if ($rc.linkFromByTarget -and (Get-KitMember $rc.linkFromByTarget $tg)) { (Get-KitMember $rc.linkFromByTarget $tg) } elseif ($rc.linkFrom -and $tg -eq $rc.target) { $rc.linkFrom }) | Where-Object { $_ } | ForEach-Object { "$_" }
  if (-not $cand.Count -and $tg -and $tg -notin @(Get-KitMainLines $rc.name)) {   # a feature-branch target: the worktree (lease) on that branch has its deps, the main checkout another branch's
    $cand = @(git -C $rp worktree list --porcelain 2>$null | ForEach-Object { if ($_ -match '^worktree (.+)$') { $wtAt = $Matches[1] } elseif ($_ -eq "branch refs/heads/$tg") { $wtAt } } | Select-Object -First 1)
  }
  foreach ($c in $cand) { if (-not (Test-Path $c)) { throw "kit.local.json dep source $c ($(Split-Path $rp -Leaf), target $tg) is missing: create it (git worktree add --detach <path> origin/$tg + frozen-lockfile install) or fix kit.local.json" } }
  $cand
}
# $srcs: one source or a list (linkFromByTarget); per package folder the first source that has it
function Add-DepLinks($path, $srcs, $target) {
  $made = @(); $ld = @(Get-DepLinkDefaults)
  $pickSrc = { param($sub) foreach ($s in @($srcs)) { if (Test-Path (Join-Path $s $sub)) { return $s } }; @($srcs)[0] }
  foreach ($e in @($ld | Where-Object { $_.dir -ne 'node_modules' })) {
    foreach ($mk in (git -C $path ls-files -- @(@($e.markers) | ForEach-Object { $_; "*/$_" }) | Where-Object { $_ -notmatch 'node_modules/' })) {
      $rel = Split-Path $mk; if (-not $rel) { $rel = "." }; $src = & $pickSrc (Join-Path $rel $e.dir); $from = Join-Path $src (Join-Path $rel $e.dir); $to = Join-Path $path (Join-Path $rel $e.dir)
      if ((Test-Path $from) -and -not (Test-Path $to)) { New-DirLink $to $from; $made += $to }
    }
  }
  if (-not @($ld | Where-Object { $_.dir -eq 'node_modules' }).Count) { return $made }
  foreach ($pj in (git -C $path ls-files -- 'package.json' '*/package.json' | Where-Object { $_ -notmatch 'node_modules/' })) {
    $rel = Split-Path $pj; if (-not $rel) { $rel = "." }; $src = & $pickSrc (Join-Path $rel 'node_modules'); $from = Join-Path $src (Join-Path $rel 'node_modules'); $to = Join-Path $path (Join-Path $rel 'node_modules')
    if ((Test-Path $from) -and -not (Test-Path $to)) {
      $null = Set-NodeModules $to $from $src $path; $made += $to
      $a = DepHash (Join-Path $path $pj); $b = DepHash (Join-Path $src $pj)
      if ($a -ne $b) { Write-Warning "$pj deps differ from ${src}: linked node_modules may be wrong.$(if ($target) { " Use -LinkFrom <a $target checkout with matching installs>." })" }
      if (($old = Get-StaleDepsNote $from)) { Write-Warning $old }
    }
  }
  $made
}
# porcelain status minus the worktree's own dependency links
function Get-WtDirty($d) {
  $mine = @(@(Meta $d 'links') | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetRelativePath($d, $_).Replace('\', '/') })
  # untracked test-run output (commit.ignore, else the runners' ignore globs) is no work: never WIP-committed (retro tidy-20261123-01); tracked files always count
  $outSpec = @(@(Get-KitSetting 'commit.ignore' @(@(Get-KitSetting 'tests.runners' $script:KitVocab.testRunners) | ForEach-Object { $_.ignore })) | Where-Object { $_ } | ForEach-Object { ":(glob)$_" })
  $outU = @(if ($outSpec.Count) { git -C $d ls-files -o --exclude-standard -- @outSpec 2>$null })
  $uAll = @(if ($outU.Count) { '--untracked-files=all' })
  @(git -C $d status --porcelain @uAll 2>$null | Where-Object { $_ -and ($_.Substring(3).Trim('"').TrimEnd('/') -notin $mine) -and -not ($_.StartsWith('??') -and $_.Substring(3).Trim('"') -in $outU) })
}
# ---- names: slots and lanes per localEnv.laneIds; birds by default (owner 2026-11-24), numbered only when an org sets laneIds "nn"
# pool slot n of a repo: folder <bird>-<repo>, shown <repo>·<Bird>; laneIds "nn": slot-<nn>-<repo>, <repo>·slot-<nn> (either kind keeps serving)
function Get-KitSlotLeaf([int]$N, [string]$Rl) { if ("$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'nn') { 'slot-{0:d2}-{1}' -f $N, $Rl } else { "$(Get-KitBirdName $N)-$Rl".ToLower() } }
function Get-KitSlotName([int]$N, [string]$Rl) { if ("$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'nn') { '{1}·slot-{0:d2}' -f $N, $Rl } else { "$Rl·$(Get-KitBirdName $N)" } }
$script:KitBirds = @('Falcon', 'Kestrel', 'Osprey', 'Heron', 'Merlin', 'Harrier', 'Kite', 'Swift', 'Raven', 'Wren', 'Egret', 'Ibis', 'Lark', 'Owl', 'Petrel', 'Robin', 'Shrike', 'Tern', 'Finch', 'Plover')
function Get-KitBirdName([int]$N) { $b = @(Get-KitSetting 'pool.names' $script:KitBirds); if ($N -ge 1 -and $N -le $b.Count) { "$($b[$N - 1])" } else { "Bird$N" } }
# localEnv.laneIds "nn" (N3): lane k of the i-th base env (config order) = lane-<nn>, nn = 10 x i + k (k <= 9 with 2+ envs: adding lanes
# never moves another env's ids; one env: nn = k) -> @{ id; env; k; old (<env>, <env><k>); bird (<env>-<bird>) }; other schemes: none
function Get-KitLaneMap {
  if ("$(Get-KitSetting 'localEnv.laneIds' '')" -ne 'nn' -or -not ($envs = Get-KitSetting 'localEnv.envs' $null)) { return @() }
  if ($script:KitLaneMapC -and [object]::ReferenceEquals($script:KitLaneMapC.cfg, $__cfg)) { return $script:KitLaneMapC.rows }
  $all = @((Get-KitProps $envs).Name); $bn = @(1..40 | ForEach-Object { "$(Get-KitBirdName $_)".ToLower() })
  $base = @($all | Where-Object { -not (($_ -match '^(?<b>.+?)\d+$' -and $Matches.b -in $all) -or ($_ -match '^(?<b>.+)-(?<d>[a-z]+)$' -and $Matches.d -in $bn -and $Matches.b -in $all) -or $_ -match '^lane-\d{2,}$') })
  $rows = @(for ($i = 0; $i -lt $base.Count; $i++) { $e = $base[$i]; for ($k = 1; $k -le [math]::Max(1, [int]"$((Get-KitMember $envs $e).lanes.max)"); $k++) {
        [pscustomobject]@{ id = 'lane-{0:d2}' -f ($(if ($base.Count -gt 1) { 10 * $i } else { 0 }) + $k); env = $e; k = $k; old = $(if ($k -gt 1) { "$e$k" } else { $e }); bird = "$e-$($bn[$k - 1])" } } })
  $script:KitLaneMapC = @{ cfg = $__cfg; rows = $rows }; $rows
}
function Get-KitLaneRow([string]$Lane) { @(Get-KitLaneMap | Where-Object id -eq $Lane)[0] }
# "<pool>·<Bird>": env lane shop2 -> shop·Kestrel (lane 1 = <env>, lane k = <env><k>; envs.<env><k> overrides: the shortest base wins); else the name
function Get-KitPoolLabel([string]$Kind, [string]$Name) {
  if ($Kind -eq 'env' -and ($lr = Get-KitLaneRow $Name)) { return "$($lr.env)·$(Get-KitBirdName $lr.k)" }   # laneIds "nn": lane-02 -> shop·Kestrel
  if ($Kind -eq 'env' -and "$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'bird' -and $Name -match '^(?<p>.+)-(?<b>[a-z]+)$') { foreach ($i in 1..40) { if ((Get-KitBirdName $i) -ieq $Matches.b) { return "$($Matches.p)·$(Get-KitBirdName $i)" } } }   # laneIds "bird": the id is <product>-<bird>
  if ($Kind -eq 'env' -and ($envs = Get-KitSetting 'localEnv.envs' $null)) {
    foreach ($e in @((Get-KitProps $envs).Name | Sort-Object Length)) { if ($Name -match "^$([regex]::Escape($e))(?<k>\d*)$") { return "$e·$(Get-KitBirdName $(if ($Matches.k) { [int]$Matches.k } else { 1 }))" } }
  }
  $Name
}
# a lane's names (README "Worktrees and lanes"): env shop2 -> lane/shop-kestrel, worktree lane-shop-kestrel-<repo>; laneIds "nn": lane-02 ->
# lane/02, lane-02-<repo>; an older scheme's worktree (localenv-<env>-<repo>; nn: lane-<env>-<bird>-<repo>) serves until envy
# Ensure-Worktree moves it (-Old: that path, -New: the new one)
function Get-KitLaneSlug([string]$Lane) { if (Get-KitLaneRow $Lane) { return $Lane.Substring(5) }; ((Get-KitPoolLabel 'env' $Lane) -replace '[·\s]+', '-').ToLower() }
# one display name per lane (owner 2026-11-17, K55; state and logs keep the id): in shown text, <env><k> as a word and a base <env>
# before " · " (a service row) or after "env " / "lane " become the pool label (shop2 · api -> shop·Kestrel · api); kitbag.py ui-check LANE-ID
function ConvertTo-KitLaneText([string]$Text) {
  if (-not $Text) { return $Text }
  $dot = '(?:·|&#0*183;|&middot;|(?i:&#x0*b7;))'   # a middle dot, plain or HTML-encoded: a lane already labelled
  if (-not $script:KitLaneRx -or -not [object]::ReferenceEquals($script:KitLaneRx.cfg, $__cfg)) { $al = Get-KitLaneAlias; $script:KitLaneRx = @{ cfg = $__cfg; map =@(foreach ($l in @(@(Get-KitLaneNames) + @($al.Keys) | Sort-Object Length -Descending)) { $lb = Get-KitPoolLabel env $(if ($al.ContainsKey($l)) { $al[$l] } else { $l }); if ($lb -ne $l) { $q = [regex]::Escape($l)
          , @($(if ($l -match '\d$' -and $l -notmatch '^lane-\d') { "(?<![\w·./\-])$q(?![\w·./\-])" } else { "(?<![\w·./\-])$(if ($l -match '^lane-\d') { '(?<!phone )' })$q(?= $dot )|(?<=\b(?:env|lane) )$q(?![\w·./\-]|$dot)" }), $lb) } }) } }   # lane-<nn> only in an env lane context: a phone lane may share the name
  foreach ($m in $script:KitLaneRx.map) { $Text = [regex]::Replace($Text, $m[0], $m[1]) }; $Text }
# an older scheme's lane ids -> today's (records from before a rename are read through it): laneIds "bird": <env>, <env><k> -> <env>-<bird>;
# "nn": <env>, <env><k> and <env>-<bird> -> lane-<nn>
function Get-KitLaneAlias {
  $al = @{}; foreach ($r in @(Get-KitLaneMap)) { $al[$r.old] = $r.id; $al[$r.bird] = $r.id }; if ("$(Get-KitSetting 'localEnv.laneIds' '')" -ne 'bird') { return $al }
  foreach ($l in @(Get-KitLaneNames)) { if ($l -match '^(?<p>.+)-(?<b>[a-z]+)$') { for ($i = 1; $i -le 40; $i++) { if ((Get-KitBirdName $i) -ieq $Matches.b) { $al[$(if ($i -gt 1) { "$($Matches.p)$i" } else { $Matches.p })] = $l; break } } } }
  $al
}
# a record's resource name (<lane> · <service>, lane <lane>, <lane>) with an old lane id -> the same name with today's id (one row per lane)
function ConvertTo-KitLaneId([string]$Name) {
  if (-not $script:KitLaneAl -or -not [object]::ReferenceEquals($script:KitLaneAl.cfg, $__cfg)) { $script:KitLaneAl = @{ cfg = $__cfg; map = (Get-KitLaneAlias) } }
  if ($script:KitLaneAl.map.Count -and $Name -match '^(?<pre>lane )?(?<id>[^\s·]+)(?<rest> · .*)?$' -and $script:KitLaneAl.map.ContainsKey($Matches.id)) { "$($Matches.pre)$($script:KitLaneAl.map[$Matches.id])$($Matches.rest)" } else { $Name }
}
# a shown lane name (shop·Kestrel, shop-kestrel, case-insensitive) or an older id (nn: shop2, shop-kestrel) -> its id; anything else as given
function ConvertFrom-KitLaneLabel([string]$Name) { foreach ($l in @(Get-KitLaneNames)) { if ($Name -ieq (Get-KitPoolLabel env $l) -or $Name -ieq (Get-KitLaneSlug $l)) { return $l } }; foreach ($r in @(Get-KitLaneMap)) { if ($Name -ieq $r.old -or $Name -ieq $r.bird) { return $r.id } }; $Name }
# a verb's text output with shown lane names; -Json output (read by scripts) keeps the ids
function ConvertTo-KitLaneOut([bool]$Json) { process { if ($Json -or $_ -isnot [string]) { $_ } else { ConvertTo-KitLaneText $_ } } }
function Get-KitLaneBranch([string]$Lane) { "lane/$(Get-KitLaneSlug $Lane)" }
# configured lanes: each localEnv.envs key, lanes 2..lanes.max as <env><k> (envy.ps1 Get-LaneCfg); laneIds "bird" / "nn": their ids
function Get-KitLaneNames { $envs = Get-KitSetting 'localEnv.envs' $null; if (-not $envs) { return @() }; if (($lm = @(Get-KitLaneMap)).Count) { return @($lm.id) }; if ("$(Get-KitSetting 'localEnv.laneIds' '')" -eq 'bird') { $bn = @(1..40 | ForEach-Object { "$(Get-KitBirdName $_)".ToLower() }); return @(foreach ($p in @(Get-KitProps $envs | Where-Object { -not ($_.Name -match '^(?<b>.+?)\d+$' -and (Get-KitMember $envs $Matches.b)) })) { if ($p.Name -match '^.+-(?<b>[a-z]+)$' -and $Matches.b -in $bn) { $p.Name } else { for ($i = 1; $i -le [math]::Max(1, [int]"$($p.Value.lanes.max)"); $i++) { "$($p.Name)-$($bn[$i - 1])" } } }) | Select-Object -Unique }; @(foreach ($p in @(Get-KitProps $envs)) { $p.Name; for ($i = 2; $i -le [int]"$($p.Value.lanes.max)"; $i++) { "$($p.Name)$i" } }) | Select-Object -Unique }
function Get-KitLaneWorktree([string]$Lane, [string]$Checkout, [switch]$Old, [switch]$New) {
  $rt = @($KitConf.WorktreeRoots)[0]; $lf = Split-Path $Checkout -Leaf; $nw = Join-Path $rt "lane-$(Get-KitLaneSlug $Lane)-$lf"
  $ow = Join-Path $rt $(if (($lr = Get-KitLaneRow $Lane)) { "lane-$($lr.bird)-$lf" } else { "localenv-$Lane-$lf" })
  if ($New) { $nw } elseif ($Old -or (-not (Test-Path $nw) -and (Test-Path "$ow/.git"))) { $ow } else { $nw }
}
# the gate's build owner with no CLAUDE_AGENT (crafty.ps1 gate): a pool slot's build is its lease holder's, a lane worktree's "lane <env>·<Bird>" ("builds per agent" read falcon, kestrel:
# slot names, not agents); else the worktree name before -<repo>
function Get-KitBuildOwner([string]$Leaf, [string]$Repo, [string]$Top) {
  $tn = "$Top".Replace('\', '/').TrimEnd('/')
  if ($tn) { $sl = @(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.slot -and $_.agent -and -not $_.parked -and "$($_.path)".Replace('\', '/').TrimEnd('/') -ieq $tn })[0]; if ($sl) { return "$($sl.agent)" } }
  $o = if ($Repo -and $Leaf.Length -gt $Repo.Length + 1 -and $Leaf.EndsWith("-$Repo", [StringComparison]::OrdinalIgnoreCase)) { $Leaf.Substring(0, $Leaf.Length - $Repo.Length - 1) } else { ($Leaf -split '-')[0] }
  if ($o -match '^lane-(?<s>.+)$') { "lane $(Get-KitPoolLabel env (ConvertFrom-KitLaneLabel $Matches.s))" } else { $o }
}
# STUCK progress (owner 2026-11-24: a long phase writes no beat or transcript): the newest write of the agent's own places: its step's
# start, its worktrees (board worktrees + leased slots: changed files, commits), its QA run item dirs (no items: the run root's files),
# its agent work dir; $null = none (lib.ps1 status rows). Read-only and bounded: git without optional locks, a scan stops at a fresh file
function Get-KitAgentProgressAt($Entry, $Step, [datetime]$Now = (Get-Date)) {
  if (-not $Entry -or $Entry.status -eq 'left') { return $Step.created }
  Get-KitLiveCached "prog:$($Entry.run)/$($Entry.agent)" {
    $fresh = $Now.AddMinutes(-[double](Get-KitParam 'supervise.stuckMinutes'))
    $newest = { param($d, [switch]$Top) $best = $null; $n = 0
      if ($d -and [IO.Directory]::Exists($d)) { foreach ($f in [IO.Directory]::EnumerateFiles($d, '*', $(if ($Top) { 'TopDirectoryOnly' } else { 'AllDirectories' }))) {
          $t = [IO.File]::GetLastWriteTime($f); if (-not $best -or $t -gt $best) { $best = $t }; if ($t -gt $fresh -or ++$n -ge 5000) { break } } }
      $best }
    $wts = @(@($Entry.worktrees) + @(Read-KitJsonFiles (Get-KitPath wt-slots) | Where-Object { $_.agent -eq $Entry.agent -and $_.path } | ForEach-Object path) | Where-Object { $_ -and (Test-Path -LiteralPath "$_/.git") } | Select-Object -Unique)
    $at = @($Step.created) + @(foreach ($w in $wts) {
        $skip = $false; foreach ($f in @("$(git --no-optional-locks -C $w status --porcelain -z --untracked-files=all 2>$null)" -split "`0" | Select-Object -First 400)) {
          if ($skip -or $f.Length -lt 4) { $skip = $false; continue }; $skip = $f[0] -in 'R', 'C'   # a rename's next entry is its old path
          $p = Join-Path $w $f.Substring(3); if ([IO.File]::Exists($p)) { [IO.File]::GetLastWriteTime($p) } }
        $hl = "$(git -C $w rev-parse --path-format=absolute --git-path logs/HEAD 2>$null)".Trim(); if ($hl -and [IO.File]::Exists($hl)) { [IO.File]::GetLastWriteTime($hl) } })   # a commit or checkout
    $rd = if ($Entry.run) { Join-Path (Get-KitPath qa-runs) $Entry.run }; $its = @("$($Entry.items)" -split '[,\s]+' | Where-Object { $_ })
    if ($rd -and $its.Count) { foreach ($i in $its) { $at += & $newest (Join-Path $rd $i) } } elseif ($rd) { $at += & $newest $rd -Top }   # a sibling's item never counts
    if ($Entry.agent) { $at += & $newest (Join-Path (Get-KitPath agents) $Entry.agent) }
    @($at | Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object)[-1] }
}
# ---- slots: a repo's pool size and its slots (worktrees marked <git dir>/claude-slot)
# the repos[] entry whose checkout it is, else origin's last path segment, else the folder
function Get-KitCheckoutName([string]$Repo) {
  $rp = (Resolve-Path -LiteralPath $Repo -ErrorAction SilentlyContinue).Path
  foreach ($x in @(Get-KitValue 'repos' @())) { if ($x.name -and $x.checkout -and (Resolve-Path -LiteralPath $x.checkout -ErrorAction SilentlyContinue).Path -eq $rp) { return "$($x.name)" } }
  $u = "$(git -C $Repo remote get-url origin 2>$null)".Trim(); if ($u) { (($u -replace '\.git$') -split '[/:\\]')[-1] } else { Split-Path $Repo -Leaf }
}
# repos[].poolSize, else pool.size (10); the kit's own clone: 0 (kitty keeps wt new)
function Get-KitPoolSize([string]$Repo) {
  if ((Resolve-Path -LiteralPath $Repo -ErrorAction SilentlyContinue).Path -eq (Resolve-Path -LiteralPath $KitConf.Kit).Path) { return 0 }
  $n = Get-RepoConf (Get-KitCheckoutName $Repo) 'poolSize' $null; if ($null -ne $n) { [int]$n } else { [int](Get-KitParam 'pool.size') }
}
# a lock file newer than the install: packages added since are missing (fails at runtime, not at link time)
function Get-StaleDepsNote([string]$nmDir) {
  $at = @(@('.yarn-integrity', '.package-lock.json', '.modules.yaml') | ForEach-Object { Get-Item -LiteralPath (Join-Path $nmDir $_) -Force -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime)[-1]
  if (-not $at) { $at = Get-Item -LiteralPath $nmDir -Force -ErrorAction SilentlyContinue }; if (-not $at) { return }
  $new = @(@('yarn.lock', 'package-lock.json', 'pnpm-lock.yaml', 'package.json') | ForEach-Object { Get-Item -LiteralPath (Join-Path (Split-Path $nmDir) $_) -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt $at.LastWriteTime.AddMinutes(1) })
  if ($new.Count) { "$nmDir was installed $($at.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), before $($new[0].Name) changed ($($new[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))): packages added since are missing; reinstall that source (frozen lockfile), then link" }
}
function Get-KitSlotFile([string]$Leaf) { Join-Path (Get-KitPath wt-slots -Create) "$Leaf.json" }
# a repo's slots: worktrees marked <git dir>/claude-slot (= n, the bird index), by n
function Get-KitSlots([string]$Repo) {
  $rl = Split-Path $Repo -Leaf
  @(foreach ($w in @(Get-KitWorktrees $Repo)) {
      $gf = Join-Path $w.path '.git'; if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { continue }
      $gd = ("$(Get-Content -LiteralPath $gf -TotalCount 1)" -replace '^gitdir:\s*').Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $w.path $gd }
      $sf = Join-Path $gd 'claude-slot'; if (-not (Test-Path -LiteralPath $sf)) { continue }
      $n = [int]"$(Get-Content -LiteralPath $sf -TotalCount 1)".Trim(); $leaf = Split-Path $w.path -Leaf
      [pscustomobject]@{ n = $n; name = (Get-KitSlotName $n $rl); path = $w.path; branch = $w.branch; head = $w.head; gitDir = $gd; file = (Get-KitSlotFile $leaf) }
    }) | Sort-Object n
}
# board leave / handoff: the agent's queued wt lease waits (wt-slots/wait) removed; its wait loop sees that and stops -> the names
function Remove-KitPoolWaits([string]$Agent) {
  $wd = Join-Path (Get-KitPath wt-slots -Create) 'wait'
  @(Get-ChildItem -LiteralPath $wd -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $Agent -and "$((Read-KitSlotLease $_.FullName).agent)" -eq $Agent } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $_.BaseName })
}
# the waiter's agent left the board after its wait began, no live row left (never joined: not gone, a coordinator's own lease)
function Test-KitPoolWaiterGone([string]$Agent, [string]$Since) {
  $rows = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $Agent -and "$($_.agent)" -eq $Agent })
  $sAt = try { [datetimeoffset]$Since } catch { [datetimeoffset]::MinValue }
  -not @($rows | Where-Object { "$($_.status)" -ne 'left' }).Count -and [bool]@($rows | Where-Object { $b = try { [datetimeoffset]"$($_.beat)" } catch { $null }; $b -and $b -ge $sAt }).Count
}
# a slot lease whose holder is gone while a live agent's board row lists the slot (a successor resumed in it without leasing it:
# 2026-11-26: the slot went to a third agent): the lease moves to that agent, saved and logged -> $true (lib Update-KitLease)
function Move-KitSlotLease($l) {
  if (-not ($l.slot -and $l.path) -or $l.parked -or $l.creating) { return $false }
  $mvPath = [IO.Path]::GetFullPath("$($l.path)").TrimEnd('\', '/'); $mvNow = Get-Date; $mvBeat = [double](Get-KitParam 'idle.beatMinutes')
  $mvRow = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.agent -and "$($_.status)" -ne 'left' -and -not ("$($_.agent)" -eq "$($l.agent)" -and "$($_.session)" -eq "$($l.session)") -and @($_.worktrees | Where-Object { $_ -and [IO.Path]::GetFullPath("$_").TrimEnd('\', '/') -ieq $mvPath }).Count } |
    Where-Object { ($_.pid -and (Test-KitPid $_.pid $_.pidStart)) -or (($mvAct = Get-KitLastActivity "$($_.transcript)" $_ "$($_.tool)") -and ($mvNow - $mvAct).TotalMinutes -lt $mvBeat) })[0]
  if (-not $mvRow) { return $false }
  Write-KitLeaseLog reclaim slot "$($l.slot)" $l "reclaim: moved to $($mvRow.agent), whose board row lists the slot ($($l.agent) has no live holder)"
  Set-KitProp $l agent "$($mvRow.agent)"; Set-KitProp $l session "$($mvRow.session)"; Set-KitProp $l run "$($mvRow.run)"
  foreach ($mvKey in 'pid', 'pidStart', 'holderPid', 'holderStart', 'holder') { Set-KitProp $l $mvKey (Get-KitMember $mvRow $mvKey) }
  Set-KitProp $l at (Get-KitStamp); Set-KitProp $l seen (Get-KitStamp stored $mvNow); foreach ($mvKey in 'graceLeft', 'graceMin', 'released') { Set-KitProp $l $mvKey $null }
  $mvFile = Get-KitSlotFile (Split-Path $mvPath -Leaf); if (Test-Path -LiteralPath $mvFile) { Write-KitAtomic $mvFile ($l | ConvertTo-Json -Depth 5) }
  Write-KitLeaseLog acquire slot "$($l.slot)" $l; $true
}
function Read-KitSlotLease([string]$File) { if (Test-Path -LiteralPath $File) { try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json } catch { $null } } }
# a pool slot leased to another agent is theirs (2026-11-26: a round's successor deployed a re-leased slot's branch as its own layer):
# envy deploy, wt commit and wt sync refuse -> the reason; '' = the caller's slot (-Agent, else KIT_AGENT / CLAUDE_AGENT), a free one, no slot or no id
function Get-KitSlotForeign([string]$Dir, [string]$Agent) {
  if (-not $Agent) { $Agent = "$(@($env:KIT_AGENT, $env:CLAUDE_AGENT | Where-Object { "$_".Trim() })[0])" }   # never KitWho: it takes the row that claims $Dir
  if (-not $Dir -or -not $Agent) { return '' }
  $sfTop = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $sfTop -or -not (Test-KitSlotDir $sfTop)) { return '' }
  $sfLease = Read-KitSlotLease (Get-KitSlotFile (Split-Path ([IO.Path]::GetFullPath($sfTop).TrimEnd('\', '/')) -Leaf))
  if (-not $sfLease -or -not "$($sfLease.agent)" -or "$($sfLease.agent)" -eq $Agent) { return '' }
  "$sfTop is pool slot $($sfLease.slot), leased to $($sfLease.agent) ($(if (Test-KitLive $sfLease) { 'live' } else { 'no live holder yet' })) on $($sfLease.branch) since $($sfLease.since); your lease of it ended (wt release, a round's end). Lease your own: crafty.ps1 wt lease -Repo $(Split-Path "$($sfLease.repo)" -Leaf) -Branch <your branch> -Agent $Agent, then work in the worktree it prints"
}
function Assert-KitSlotOwn([string]$Dir, [string]$Agent, [string]$Verb) { if ($sfWhy = Get-KitSlotForeign $Dir $Agent) { [Console]::Error.WriteLine("$Verb refused: $sfWhy"); exit 1 } }
function Test-KitSlotDir([string]$Dir) { $gf = Join-Path $Dir '.git'; if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return $false }; $gd = ("$(Get-Content -LiteralPath $gf -TotalCount 1)" -replace '^gitdir:\s*').Trim(); [bool]($gd -and (Test-Path -LiteralPath (Join-Path $gd 'claude-slot'))) }
# ---- lease: wt lease
function Invoke-WtLease {   # a free slot of the repo's pool on -Branch (fair queue when all are leased); created lazily up to the pool size
  # defaults (retro 2205, 11 usage errors): -Agent = the -Session board row or KIT_AGENT; -Repo / -Branch = the linked worktree at -Dir or cwd
  if (-not $Agent) { $Agent = "$($script:KitWho.agent)" }
  if (-not ($Repo -and $Branch)) { $here = if ($Dir) { $Dir } else { (Get-Location).Path }
    $top = "$(git -C $here rev-parse --show-toplevel 2>$null)".Trim(); $cdir = "$(git -C $here rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
    if ($top -and $cdir -and [IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath((Split-Path $cdir)).TrimEnd('\', '/')) {   # a linked worktree, never the main checkout's branch
      $wtRepo = Split-Path $cdir; if (-not $Repo) { $Repo = $wtRepo }   # another -Repo never takes this worktree's branch
      if (-not $Branch -and [IO.Path]::GetFullPath((Resolve-WtRepo $Repo)).TrimEnd('\', '/') -eq [IO.Path]::GetFullPath($wtRepo).TrimEnd('\', '/')) { $Branch = "$(git -C $here branch --show-current 2>$null)".Trim() } } }
  if (-not $Branch -and $Agent -and $Repo) {   # a re-lease (resume, fix round; 25 'needs -Branch' 11-18..20): this agent's newest branch on this repo
    $rlLast = try { Split-Path (Resolve-WtRepo $Repo) -Leaf } catch { '' }
    if ($rlLast) { $Branch = "$(@(Get-Content -LiteralPath (Get-KitLogFile leases) -ErrorAction SilentlyContinue | Where-Object { $_ -match '"kind":"slot"' -and $_ -match '"event":"acquire"' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.agent -eq $Agent -and $_.branch -and "$($_.name)" -like "$rlLast·*" })[-1].branch)" }
    if ($Branch -and -not "$(git -C (Resolve-WtRepo $Repo) for-each-ref --count=1 "refs/heads/$Branch" "refs/remotes/origin/$Branch" 2>$null)".Trim()) { $Branch = '' }   # merged and deleted: no default
    if ($Branch) { "default:  -Branch $Branch (your last lease on $rlLast; pass -Branch for another)" } }
  if (-not $Branch -and $Task) { $Branch = Get-KitTaskBranch $Task; "branch:   $Branch (kitbag.py naming make branch)" } elseif ($Task) { Test-KitTaskBranch $Task $Branch }
  $miss = @(@{ '-Repo' = $Repo; '-Branch' = $Branch; '-Agent' = $Agent }.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Name | Sort-Object)
  if ($miss.Count) { throw "lease needs $($miss -join ' '): wt lease -Repo <repo> -Branch <branch> -Agent <id> (-Agent: -Session <board session> or KIT_AGENT; -Repo / -Branch: run it in the linked worktree or pass -Dir <it>)" }
  $Repo = Resolve-WtRepo $Repo; $rl = Split-Path $Repo -Leaf; $size = Get-KitPoolSize $Repo
  if ($size -lt 1) { throw "wt lease: $(Get-KitCheckoutName $Repo) has no pool (repos[].poolSize 0, or the kit itself): wt new" }
  if (-not $Target) { $Target = Resolve-KitTarget (Get-KitCheckoutName $Repo) @($Paths); if (-not $Target) { $Target = "$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/' } }
  if (-not $Target) { throw 'wt lease: no target (repos[].target, origin/HEAD): pass -Target' }
  G -C $Repo fetch -q origin $Target | Out-Null
  $remoteBranch = "$(git -C $Repo ls-remote --heads origin "refs/heads/$Branch" 2>$null)".Trim()   # bare name would suffix-match
  git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"; $localBranch = -not $LASTEXITCODE
  if (-not $localBranch -and -not $remoteBranch) {   # a new branch: wt new's prior-work gate
    $tk = if ($Task) { $Task } elseif (($rx = Get-KitTaskTagRx) -and $Branch -match $rx) { $Matches.id }
    Assert-KitPrior $tk $Repo "wt lease $Branch" $Override $Branch
    if ($tk) { Update-KitTaskIndex $tk { param($x) if ($x.prior) { $x.prior.claimed = @(@($x.prior.claimed) + $Branch | Where-Object { $_ } | Select-Object -Unique) } } }
  }
  $sdir = Get-KitPath wt-slots -Create; $wdir = Join-Path $sdir 'wait'; New-Item -ItemType Directory -Force $wdir | Out-Null
  $poolLock = Join-Path $sdir "$rl.pool"; $wf = Join-Path $wdir "$(ConvertTo-KitSlug $Agent)-$rl.json"; $since = (Get-KitStamp)
  $slotRoot = if ($Root) { $Root } else { @($KitConf.WorktreeRoots)[0] }
  $deadline = (Get-Date).AddMinutes($WaitMinutes); $got = $null; $told = $false
  $waitTok = [guid]::NewGuid().ToString('n'); $ownWait = { "$((Read-KitSlotLease $wf).token)" -eq $waitTok }
  Write-KitAtomic $wf (@{ agent = $Agent; repo = $rl; branch = $Branch; since = $since; token = $waitTok; pid = $PID } | ConvertTo-Json -Compress)
  try {
    while (-not $got) {
      $got = Invoke-KitLocked $poolLock {
        if (Test-Path -LiteralPath $wf) { (Get-Item -LiteralPath $wf).LastWriteTime = Get-Date }   # heartbeat: 3 min untouched = a dead waiter
        if (-not (& $ownWait)) { return $null }   # cancelled between polls: never a slot for a left agent (the check below throws)
        $slots = @(Get-KitSlots $Repo); $byN = @{}; $ls = @{}
        foreach ($s in $slots) { $byN[$s.n] = $s; $ls[$s.n] = Read-KitSlotLease $s.file }
        $reserved = @(foreach ($n in 1..$size) { if (-not $byN[$n]) { $rf = Get-KitSlotFile (Get-KitSlotLeaf $n $rl); $ro = Read-KitSlotLease $rf
              if ($ro.creating -and (Test-KitLive $ro)) { $n } elseif ($ro) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue } } })   # a slot being created
        $mine = @($slots | Where-Object { $o = $ls[$_.n]; $o -and -not $o.parked -and $o.agent -eq $Agent -and $o.branch -eq $Branch })[0]
        if ($mine) { return $mine }   # already ours
        $pick = @($slots | Where-Object { $_.branch -eq $Branch })[0]   # a resume, handoff or fix round: the slot that has the branch
        if ($pick -and ($o = $ls[$pick.n]) -and -not $o.parked -and (Update-KitLease $o)) { if ("$($o.agent)" -eq $Agent) { return $pick }   # moved to us just now (Move-KitSlotLease)
          throw "wt lease: $Branch is checked out in $($pick.name) ($($pick.path)), leased by $($o.agent): two agents never share a slot; board msg $($o.agent) or wait for its release" }
        if (-not $pick) {
          foreach ($s in $slots) {   # holder gone past the grace + clean: freed here (dirty: supervise's reaper commits WIP first)
            $o = $ls[$s.n]; if (-not $o -or $o.parked -or $o.creating) { continue }
            $s0 = "$($o.seen)"; if (Update-KitLease $o) { if ("$($o.seen)" -ne $s0) { Write-KitAtomic $s.file ($o | ConvertTo-Json -Depth 5) }; continue }
            if (@(Get-WtDirty $s.path).Count) { continue }
            if ($s.branch) { git -C $s.path switch -q --detach 2>$null | Out-Null; Meta $s.path 'lastbranch' $s.branch; $s.branch = '' }
            Remove-Item -LiteralPath $s.file -Force; $ls[$s.n] = $null; Write-KitLeaseLog reclaim slot $s.name $o "reclaim: no live holder for $($o.graceMin) min"
          }
          $free = @($slots | Where-Object { -not $ls[$_.n] }); $room = [math]::Max(0, $size - $slots.Count - $reserved.Count)
          $ahead = @(Get-ChildItem -LiteralPath $wdir -Filter "*-$rl.json" -File | Where-Object { $_.FullName -ne $wf -and ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt (Get-KitParam 'pool.waitFreshMinutes') } | ForEach-Object { Read-KitSlotLease $_.FullName } | Where-Object { $_.repo -eq $rl -and [datetimeoffset]$_.since -lt [datetimeoffset]$since })
          if ($ahead.Count -ge $free.Count + $room) { return $null }   # fair: older waiters first
          foreach ($s in @(@($free | Where-Object { "$(Meta $_.path 'lastbranch')".Trim() -eq $Branch }) + $free)) { if (-not @(Get-WtDirty $s.path).Count) { $pick = $s; break } }   # warm for this branch first, then the lowest
          if (-not $pick) {
            if (-not $room) { return $null }
            $n = @(1..$size | Where-Object { -not $byN[$_] -and $_ -notin $reserved })[0]; $sleaf = Get-KitSlotLeaf $n $rl
            $pick = [pscustomobject]@{ n = $n; name = (Get-KitSlotName $n $rl); path = (Join-Path $slotRoot $sleaf); branch = ''; head = ''; new = $true; file = (Get-KitSlotFile $sleaf) }
          }
        }
        $lease = [ordered]@{ slot = $pick.name; n = $pick.n; repo = $Repo; path = $pick.path; branch = $Branch; since = (Get-KitStamp) } + (New-KitLease $Agent $Session)
        if ($pick.new) { $lease.creating = $true }
        Write-KitAtomic $pick.file ($lease | ConvertTo-Json -Depth 5)
        $lg = @{}; foreach ($k in $lease.Keys) { $lg[$k] = $lease[$k] }; $lg.at = $since; Write-KitLeaseLog acquire slot $pick.name $lg   # since = when it began to wait
        $pick
      } | Select-Object -Last 1
      if (-not $got) {
        # cancelled (board leave / handoff removed the wait, or a newer lease of this agent took it) or its agent left: an orphan never queues ahead of a successor
        if (-not (& $ownWait)) { throw "wt lease cancelled: the $rl wait of $Agent was removed (board leave / handoff) or replaced by a newer lease" }
        if (Test-KitPoolWaiterGone $Agent $since) { throw "wt lease stopped: $Agent left the board (no live row): its successor leases fresh" }
        if ((Get-Date) -gt $deadline) { throw "no $rl slot free within $WaitMinutes min (all $size leased: wt pool -Repo $rl shows the holders)" }
        if (-not $told) { "all $size $rl slots are leased; waiting for a release (fair queue) ..."; $told = $true }
        Wait-KitPoll 20
      }
    }
  } finally { if (& $ownWait) { Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue } }   # a newer waiter's file stays
  $p = $got.path; $cur = ''; $h0 = ''
  try {
    if ($got.new) {
      if (Test-Path -LiteralPath $p) { throw "wt lease: $p exists but is no slot (a half-made slot or an old worktree): wt remove -Dir $p -Force, then lease again" }
      Add-WtRoot (Split-Path $p)
      G -C $Repo worktree add -q --detach $p "origin/$Target" | Out-Null
      Meta $p 'slot' $got.n
      "new slot $($got.name) (pool $(@(Get-KitSlots $Repo).Count)/$size): $p"
    } else { $cur = "$(git -C $p branch --show-current 2>$null)".Trim(); $h0 = "$(git -C $p rev-parse HEAD 2>$null)".Trim() }
    if ($cur -ne $Branch) {
      if ($cur) { git -C $p switch -q --detach 2>$null | Out-Null }   # an unleased slot left on a branch
      $sw = if ($localBranch) { git -C $p switch -q $Branch 2>&1 } elseif ($remoteBranch) { G -C $Repo fetch -q origin $Branch | Out-Null; git -C $p switch -q -c $Branch --track "origin/$Branch" 2>&1 } else { git -C $p switch -q --no-track -c $Branch "origin/$Target" 2>&1 }
      if ($LASTEXITCODE) { $said = (@($sw) | ForEach-Object { "$_" }) -join ' '; $inRx = "already (?:checked out|used by worktree) at '(?<w>[^']+)'"
        throw "wt lease: git switch $Branch failed in $($got.name): $said$(if ($said -match $inRx) { " -> it is checked out in $($Matches.w) (an older worktree): work there, or wt remove it first" })" }
    }
    Meta $p 'target' $Target
    $scf = Join-Path (GitDir $p) 'claude-scope'
    if ($Scope) { Meta $p 'scope' (@(Split-KitList $Scope -Sep ',(?![^{}]*\})') -join "`n") } elseif (Test-Path -LiteralPath $scf) { Remove-Item -LiteralPath $scf -Force }   # brief agents[].paths; a comma inside {a,b} is no separator (one brace level, as the glob matchers)
    $depOut = @(Set-WtDeps $p $Repo $Target $LinkFrom)
    $o = Read-KitSlotLease $got.file; if ($o) { $o = $o | Select-Object -Property * -ExcludeProperty creating; Set-KitProp $o branch $Branch; Write-KitAtomic $got.file ($o | ConvertTo-Json -Depth 5) }
    foreach ($wp in @(Get-ChildItem -LiteralPath (Get-KitPath wip-patches -Create) -Filter "$($Branch -replace '[^\w.-]', '_')~*.patch" -File)) { "WIP patch of ${Branch}: git -C $p apply --3way $($wp.FullName), then delete it (saved when hooks refused the WIP commit)" }
  } catch {
    $err = $_; Invoke-KitLocked $poolLock { $o = Read-KitSlotLease $got.file; if ($o -and $o.agent -eq $Agent) {   # dirty (a resumed parked slot): parked again, never orphaned
        if ((Test-Path -LiteralPath $got.path) -and @(Get-WtDirty $got.path).Count) { $pw = "lease failed, files kept: $($err.Exception.Message)"; Set-KitProp $o parked $true; Set-KitProp $o parkedAt (Get-KitStamp); Set-KitProp $o parkedWhy $pw.Substring(0, [math]::Min(300, $pw.Length)); Write-KitAtomic $got.file ($o | ConvertTo-Json -Depth 5) }
        else { Remove-Item -LiteralPath $got.file -Force }
        Write-KitLeaseLog release slot $got.name $o "lease failed: $($err.Exception.Message)" } }
    throw $err
  }
  "worktree: $p"
  "slot:     $($got.name) (leased by $Agent; done: wt release -Agent $Agent)"
  "branch:   $Branch$(if ($cur -eq $Branch) { ' (already here)' } elseif ($localBranch) { ' (local branch, as is)' } elseif ($remoteBranch) { ' (from origin)' } else { " (new, from origin/$Target)" })"
  if ($Scope) { "area:     $Scope (wt commit, devtools.py mr / merge refuse files outside)" }
  if ($h0) { $gone = @(git -C $p diff --name-only --diff-filter=D $h0 HEAD 2>$null).Count; "files:    $(@(git -C $p diff --name-only $h0 HEAD 2>$null).Count) changed by the switch, not $(@(git -C $p ls-files).Count) written by a fresh worktree$(if ($gone) { "; $gone deleted: their build outputs may linger in ignored folders" })" }
  $depOut
}
# ---- release: wt release
# hooks refused the WIP commit (no hook skip: the guard forbids it): the staged work -> <wip-patches>/<branch>~<head>~<stamp>.patch,
# checked to reverse-apply, then the tree goes back to HEAD; '' = saved, else the reason the slot stays parked (files kept)
function Save-WtWipPatch([string]$Path, [string]$Branch, [string]$Refused) {
  $hd = "$(git -C $Path rev-parse --short=12 HEAD 2>$null)".Trim()
  $wpBase = Join-Path (Get-KitPath wip-patches -Create) "$($Branch -replace '[^\w.-]', '_')~$hd"; $pf = "$wpBase.patch"; $wpTie = 2   # owner 2026-11-25: branch + commit name it, no date; a tie -2
  while (Test-Path -LiteralPath $pf) { $pf = "$wpBase-$wpTie.patch"; $wpTie++ }
  git -C $Path diff --cached --binary --output="$pf" 2>$null
  if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $pf) -or -not (Get-Item -LiteralPath $pf).Length) { git -C $Path reset -q 2>$null; Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue; return "$Refused; patch not written" }
  git -C $Path apply --check -R --cached "$pf" 2>$null; if ($LASTEXITCODE) { git -C $Path reset -q 2>$null; return "$Refused; patch $pf does not reverse-apply: files kept" }
  git -C $Path reset -q --hard HEAD 2>$null; $script:WtWipPatch = $pf; ''
}
function Invoke-WtRelease {   # -Agent: every slot it holds (-Repo: of one repo) · -Dir: that slot; uncommitted work -> a WIP commit, else parked
  if (-not ($Agent -or $Dir)) { throw 'release needs -Agent <id> or -Dir <slot>' }
  $want = if ($Dir) { [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/').Replace('\', '/').ToLower() }
  $held = @(Get-ChildItem -LiteralPath (Get-KitPath wt-slots -Create) -Filter '*.json' -File | ForEach-Object { $o = Read-KitSlotLease $_.FullName; if ($o -is [pscustomobject] -and $o.slot) { [pscustomobject]@{ f = $_.FullName; o = $o } } } |
    Where-Object { if ($want) { "$($_.o.path)".Replace('\', '/').TrimEnd('/').ToLower() -eq $want } else { $_.o.agent -eq $Agent -and -not $_.o.parked -and (-not $Repo -or (Split-Path "$($_.o.repo)" -Leaf) -eq (Split-Path $Repo -Leaf)) } })
  if (-not $held.Count) { "$(if ($Dir) { "${Dir}: no lease" } else { "no slot held by $Agent" })"; return }
  $why = if ($Reason) { $Reason } else { 'released' }
  foreach ($h in $held) {
    $o = $h.o; $p = $o.path; $lf = $h.f
    if (-not (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $lf -Force; Write-KitLeaseLog release slot $o.slot $o "$why (folder gone)"; "released $($o.slot): its folder is gone"; continue }
    $br = "$(git -C $p branch --show-current 2>$null)".Trim(); $dirty = @(Get-WtDirty $p)
    # pool.wipRestore: tracked files a test run rewrites (fixtures, reports) are restored, never WIP-committed (retro 1709)
    $wipGen = @($dirty | Where-Object { $wf = ($_.Substring(3).Trim('"') -split ' -> ')[-1]; $_.Substring(0, 2) -match 'M' -and @(@(Get-KitSetting 'pool.wipRestore' @()) | Where-Object { $_ -and $wf -like $_ }).Count })
    foreach ($wg in $wipGen) { git -C $p checkout -q HEAD -- (($wg.Substring(3).Trim('"') -split ' -> ')[-1]) 2>$null }; if ($wipGen.Count) { $dirty = @(Get-WtDirty $p) }
    # an untracked key / data file named like a secret (log.secretKey: a credentials json) is never WIP-committed or patched: it stays, named
    $dirty = @($dirty | ForEach-Object { if ($_.StartsWith('??') -and $_.TrimEnd('"').EndsWith('/')) { foreach ($uf in @(git -C $p -c core.quotepath=off ls-files -o --exclude-standard -- ($_.Substring(3).Trim('"')) 2>$null)) { "?? $uf" } } else { $_ } })   # an untracked folder: its files
    $sk = "$($script:KitLogMap.secretKey)"; $secret = @($dirty | Where-Object { $_.StartsWith('??') -and (($lf0 = Split-Path ($_.Substring(3).Trim('"')) -Leaf) -match '\.(pem|key|p12|pfx|jks|keystore)$|^\.env(\.|$)|^id_(rsa|ed25519|ecdsa)$' -or ($sk -and $lf0 -match $sk -and $lf0 -match '\.(json|ya?ml|propert[i]es)$')) })
    if ($secret.Count) { "$($o.slot): kept untracked $(@($secret | ForEach-Object { $_.Substring(3).Trim('"') }) -join ', ') (secret-named, never committed): move it out of $p"; $dirty = @($dirty | Where-Object { $_ -notin $secret }) }
    if ($dirty.Count) {   # never lost: a WIP commit on its branch (hooks run), else a patch file (Save-WtWipPatch), else parked for that branch
      $said = 'uncommitted files on a detached HEAD'; $script:WtWipPatch = ''
      if ($br) { git -C $p add -A -- @($dirty | ForEach-Object { ($_.Substring(3).Trim('"') -split ' -> ')[-1] }) 2>$null; $said = @(git -C $p commit -q -m "wip: $($o.slot) released with uncommitted work ($why)" 2>&1 | ForEach-Object { "$_" }) -join ' '; $wc = $LASTEXITCODE; if ($wc) { $said = Save-WtWipPatch $p $br "WIP commit refused (exit $wc) $said".Trim() } else { $said = '' } }
      if ($said) {
        Set-KitProp $o parked $true; Set-KitProp $o parkedAt (Get-KitStamp); $pw = "uncommitted files: $said"; Set-KitProp $o parkedWhy $pw.Substring(0, [math]::Min(300, $pw.Length)); Write-KitAtomic $lf ($o | ConvertTo-Json -Depth 5)
        Write-KitLeaseLog release slot $o.slot $o "$why (parked)"; "PARKED $($o.slot) ($p): $said; wt lease -Branch $(if ($br) { $br } else { '<branch>' }) -Repo $(Split-Path $o.repo -Leaf) -Agent <id> resumes it, nobody else gets it"; continue
      }
      "$($o.slot): uncommitted work $(if ($script:WtWipPatch) { "saved to $($script:WtWipPatch) (hooks refused the WIP commit; wt lease -Branch $br prints how to apply it)" } else { "committed on $br as a WIP commit" })"
    }
    if ($br) { git -C $p switch -q --detach 2>$null | Out-Null; Meta $p 'lastbranch' $br }   # HEAD stays: no file written
    $scf = Join-Path (GitDir $p) 'claude-scope'; if (Test-Path -LiteralPath $scf) { Remove-Item -LiteralPath $scf -Force }
    $bn = if ($br) { try { $bv = Get-KitBranchVerdict $o.repo $br @{} -IdleHours 0; if ($bv.delete) { git -C $o.repo branch -D $br 2>$null | Out-Null; "; branch $br deleted ($($bv.why))" } else { "; branch $br kept ($($bv.why))" } } catch { "; branch $br kept" } }
    Remove-Item -LiteralPath $lf -Force; Write-KitLeaseLog release slot $o.slot $o $Reason
    "released $($o.slot) ($p)$bn"
  }
}
# ---- lanes: envy.ps1 lanes -Migrate (run inside envy.ps1: its EnvNames, EnvRepos, Read-State, StateFile)
# a lane's old names (worktree localenv-<lane>-<repo>, branch localenv/<lane>) -> lane-<slug>-<repo>, lane/<slug>; $Busy (why the lane
# is in use) keeps them; -> "moved / renamed ..." | "kept ...: <why>" | $null (nothing to move); the state keeps no worktree path
function Move-LaneWorktree([string]$e, [string]$co, [string]$Busy = '') {
  $ow = Get-KitLaneWorktree $e $co -Old; $nw = Get-KitLaneWorktree $e $co -New; $rl = Split-Path $co -Leaf; $ob = if (($lr = Get-KitLaneRow $e)) { "lane/$($lr.bird)" } else { "localenv/$e" }; $nb = Get-KitLaneBranch $e
  $onOld = { param($d) "$(git -C $d branch --show-current 2>$null)".Trim() -eq $ob }
  if (Test-Path "$ow/.git") {
    if (Test-Path -LiteralPath $nw) { return "kept [$e] ${rl}: $ow and $nw both exist" }
    if ($Busy) { return "kept [$e] ${rl}: in use ($Busy), retried next sweep" }
    $mv = @(git -C $co worktree move $ow $nw 2>&1); if ($LASTEXITCODE) { return "kept [$e] ${rl}: $(@($mv)[-1])" }
    if (-not (& $onOld $nw)) { return "moved [$e] ${rl}: $nw" }
    $bm = @(git -C $nw branch -M $ob $nb 2>&1); return "moved [$e] ${rl}: $nw$(if ($LASTEXITCODE) { "; branch kept: $(@($bm)[-1])" } else { " on $nb" })"
  }
  if ((Test-Path "$nw/.git") -and (& $onOld $nw)) {   # moved, the branch not renamed
    if ($Busy) { return "kept [$e] ${rl}: in use ($Busy), retried next sweep" }
    $bm = @(git -C $nw branch -M $ob $nb 2>&1); return $(if ($LASTEXITCODE) { "kept [$e] ${rl}: $(@($bm)[-1])" } else { "renamed [$e] ${rl}: $ob -> $nb" })
  }
  $null
}
# envy.ps1 Get-MergedWhy: a layer = an older copy of the branch the MR merged after a rebase: each of its own non-merge commits has a same-subject commit on
# the MR's side (trailing marker tokens a commit hook adds, e.g. a symbol-led word, ignored); a commit the MR lacks keeps the layer
function Test-KitRebasedCopy([string]$d, [string]$sha, [string]$mrSha) {
  $norm = { param($s) ("$s" -replace '(\s+[^\w\s(\[][^\s]*)+$').Trim() }
  $mine = @(git -C $d log --no-merges --format=%s "$mrSha..$sha" 2>$null | ForEach-Object { & $norm $_ }); if ($LASTEXITCODE -or -not $mine.Count) { return $false }
  $theirs = @(git -C $d log --no-merges --format=%s "$sha..$mrSha" 2>$null | ForEach-Object { & $norm $_ })
  -not @($mine | Where-Object { $_ -notin $theirs }).Count
}
# why a lane is in use ('' = idle): a service up, starting or waiting with a live process, a lease, a hold, a train, a queued request
function Get-LaneBusy([string]$e, $st) {
  $up = @($st.services.Keys | Where-Object { $v = $st.services[$_]; $v.status -in 'up', 'starting', 'waiting' -and (-not $v.pid -or (Test-KitPid $v.pid $v.pstart)) })
  @(if ($up.Count) { "up: $($up -join ', ')" }; if ($st.leases.Count) { "$($st.leases.Count) lease(s)" }; if ($st.holds.Count) { "$($st.holds.Count) hold(s)" }; if ($st.train) { 'a train' }
    if (@($st.requests | Where-Object { $_.status -in 'queued', 'in-train' }).Count) { 'queued requests' }) -join ', '
}
# lanes -Migrate [-LanesOnly] [-DryRun] (supervise: -LanesOnly each sweep while an old name is left): every idle lane x repo to the new
# names (a busy one: next sweep); localenv/* branches no lane worktree holds: a clean worktree removed, commits on no remote kept as
# a backup/ tag (Save-KitBranchBackup), the branch deleted; then (not -LanesOnly, after a fetch) [gone] branches merged into the target and
# backup branches whose every commit is on origin: deleted; the rest listed as kept
function Invoke-LaneMigrate([switch]$LanesOnly, [switch]$DryRun) {
  $repos = [ordered]@{}; $lanes = @(EnvNames)
  foreach ($e in $lanes) {
    foreach ($r in @((EnvRepos $e).Values)) { $co = "$($r.cfg.checkout)"; if (-not (Test-Path -LiteralPath "$co/.git")) { continue }; if (-not $repos.Contains($co)) { $repos[$co] = "$($r.target)" }
      if ($DryRun) { $ow = Get-KitLaneWorktree $e $co -Old; $busy = Get-LaneBusy $e (Read-State $e)
        if (Test-Path "$ow/.git") { "plan [$e] $(Split-Path $co -Leaf): $ow -> $(Get-KitLaneWorktree $e $co -New), $(Get-KitLaneBranch $e)$(if ($busy) { " (in use: $busy)" })" }; continue }
      Invoke-KitLocked (StateFile $e) { $script:stateLocked = $true; try { $busy = Get-LaneBusy $e (Read-State $e) } finally { $script:stateLocked = $false }; Move-LaneWorktree $e $co $busy } } }   # under the state lock: no build starts mid-move
  $held = Get-KitWtHeldTest
  foreach ($co in @($repos.Keys)) { $tg = $repos[$co]; $rl = Split-Path $co -Leaf
    if (-not $LanesOnly) { $null = git -C $co fetch -q --prune origin 2>&1 }
    $wts = @{}; $wp = ''; foreach ($l in @(git -C $co worktree list --porcelain 2>$null)) { if ($l -like 'worktree *') { $wp = $l.Substring(9) } elseif ($l -like 'branch refs/heads/*') { $wts[$l.Substring(18)] = $wp } }
    $offRemote = { param($b) $c = @(git -C $co rev-list --count "refs/heads/$b" --not --remotes 2>$null); if ($LASTEXITCODE -or -not "$($c[0])".Trim()) { -1 } else { [int]"$($c[0])".Trim() } }   # -1: unknown, kept
    foreach ($b in @(git -C $co for-each-ref --format='%(refname:short)' refs/heads/localenv 2>$null)) { $wd = $wts[$b]
      if (("$b" -replace '^localenv/') -in $lanes) { continue }   # a configured lane's own: moved above when idle (no worktree: Sync-KitRepo, tagged first)
      if ($wd) { $ign = @(git -C $wd status --porcelain --ignored 2>$null | Where-Object { $_ -like '!! *' -and $_ -notmatch '(^!! |/)(target|node_modules|build|dist|out|bin|obj|\.gradle|\.angular|\.idea|\.vscode|__pycache__|\.venv)/?$' })   # ignored files beyond build output (.env, local config): kept
        $why = if (@(git -C $wd status --porcelain 2>$null).Count) { 'uncommitted changes' } elseif ($ign.Count) { "ignored files ($(@($ign | Select-Object -First 3 | ForEach-Object { $_.Substring(3) }) -join ', '))" } else { & $held ([IO.Path]::GetFullPath($wd).TrimEnd('\', '/')) }
        if ($why) { "kept $rl ${b}: $wd has $why"; continue } }
      if ($DryRun) { $bk = Save-KitBranchBackup $co $b -DryRun; "plan $rl ${b}: $(if ($wd) { "remove worktree $wd, " })$(if ($bk.n) { "tag $($bk.tag) ($($bk.n) commit(s) on no remote), " })delete"; continue }
      if ($wd) { $o = @(git -C $co worktree remove $wd 2>&1); if ($LASTEXITCODE) { "kept $rl ${b}: $(@($o)[-1])"; continue } }
      $bk = Save-KitBranchBackup $co $b; if ($bk.err) { "kept $rl ${b}: $($bk.err)"; continue }
      $o = @(git -C $co branch -D $b 2>&1); if ($LASTEXITCODE) { "kept $rl ${b}: $(@($o)[-1])" } else { "deleted $rl $b$(if ($wd) { " (worktree $wd removed)" })$(if ($bk.n) { " ($($bk.n) commit(s) kept as tag $($bk.tag))" })" } }
    if ($LanesOnly) { continue }
    foreach ($ln in @(git -C $co for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads 2>$null)) { $b, $tr = "$ln" -split '\|', 2
      if ($wts[$b] -or $b -like 'localenv/*' -or $b -like 'lane/*') { continue }
      $kind = if ($tr -eq '[gone]') { 'upstream gone' } elseif ($b -match '(^|[/_-])backup([/_-]|$)') { 'backup' } else { continue }
      $n = & $offRemote $b; $merged = $false; if ($tg) { git -C $co merge-base --is-ancestor "refs/heads/$b" "origin/$tg" 2>$null; $merged = -not $LASTEXITCODE }
      if ($n -and -not $merged) { "kept $rl ${b}: $kind, $(if ($n -lt 0) { 'commits unknown (rev-list failed)' } else { "$n commit(s) on no remote" })"; continue }
      if ($DryRun) { "plan $rl ${b}: delete ($kind, every commit on origin)"; continue }
      $o = @(git -C $co branch -D $b 2>&1); if ($LASTEXITCODE) { "kept $rl ${b}: $(@($o)[-1])" } else { "deleted $rl $b ($kind, every commit on origin)" } } }
}
# lanes -Sync [-DryRun] (wt pool -Sync, owner 2026-11-17: lane branches always in sync): every idle lane x repo rebuilt as Sync-Repo
# does at a build: origin/<target> + the layers still open in its state (re-merged; merged ones dropped) + the prepare commit; a
# conflict puts the lane back as it was (listed); lane/* never track an upstream (local only: no false ahead / behind); the per
# lane state (base sha, behind, merges) -> wt-slots/lanes/lanes.json for the dashboard (Branches tile)
function Invoke-LaneResync([switch]$DryRun) {
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($e in @(EnvNames)) { $sf = StateFile $e
    foreach ($co in @(@((EnvRepos $e).Values) | ForEach-Object { "$($_.cfg.checkout)" } | Select-Object -Unique)) { if (-not $DryRun -and (Test-Path "$co/.git")) { $null = git -C $co fetch -q origin 2>&1 } }   # the network outside the lock
    $mergedWhy = @{}; $st0 = Read-State $e   # "<repo>|<branch>|<sha>" -> why: ancestry or the host's merged MR by source branch (squash / rebase), outside the lock
    foreach ($r in @(if (-not (Get-LaneBusy $e $st0)) { (EnvRepos $e).Values })) { if (-not (Test-Path "$($r.wt)/.git")) { continue }   # a busy lane is kept anyway: no host calls
      foreach ($l in @($st0.release.repos[$r.name].layers | Where-Object { $_.sha })) {
        if (($mw = Get-MergedWhy $r.wt $l.branch "$($l.sha)" $r.target "origin/$($r.target)")) { $mergedWhy["$($r.name)|$($l.branch)|$($l.sha)"] = $mw } } }
    Invoke-KitLocked $sf { $script:stateLocked = $true   # held for the whole lane: Sync-Repo's Ensure-Worktree reads the state too; no build starts mid-sync
      try { $st = Read-State $e; $busy = Get-LaneBusy $e $st; $was = $st | ConvertTo-Json -Depth 10
        foreach ($r in @((EnvRepos $e).Values)) { $d = $r.wt; $rl = $r.name; if (-not (Test-Path "$d/.git")) { continue }
          $br = "$(git -C $d branch --show-current 2>$null)".Trim(); if ($br -like 'lane/*') { git -C $d config --unset "branch.$br.merge" 2>$null; git -C $d config --unset "branch.$br.remote" 2>$null }
          $rs = $st.release.repos[$rl]; $old = "$(git -C $d rev-parse HEAD 2>$null)".Trim()
          $mk = { param($l) "$rl|$($l.branch)|$($l.sha)" }   # the sha too: a layer re-pushed since the read is judged again by Sync-Repo
          $ly = @($rs.layers | Where-Object { $_ -and -not $mergedWhy[(& $mk $_)] }); $pre = @($rs.layers | Where-Object { $_ -and $mergedWhy[(& $mk $_)] } | ForEach-Object { "$($_.branch) ($($mergedWhy[(& $mk $_)]))" })   # merged: dropped, never re-merged
          $row = [ordered]@{ lane = $e; repo = $rl; head = $old; base = ''; behind = 0; merges = $ly.Count; at = (Get-KitStamp); kept = '' }
          if ($busy) { "kept [$e] ${rl}: in use ($busy)"; $row.kept = $busy }
          elseif (@(git -C $d status --porcelain --untracked-files=no 2>$null).Count) { "kept [$e] ${rl}: uncommitted edits in $d (a sync never discards them)"; $row.kept = 'uncommitted edits' }
          elseif ($DryRun) { "plan [$e] ${rl}: origin/$($r.target) + $($ly.Count) layer(s)$(if ($pre.Count) { "; drop $($pre -join ', ')" })" }
          else { $snap = if ($rs) { $rs.layers | ConvertTo-Json -Depth 6 }   # Sync-Repo writes each kept layer's sha: put back on a conflict
            $res = try { Sync-Repo $e $r $ly -NoFetch -KeepRunning 6>$null } catch { @{ err = "$($_.Exception.Message)" } }
            $bad = @($res.dropped | Where-Object { "$($_.why)" -like 'conflicts*' -or "$($_.why)" -like '*gone*' })
            if ($res.err -or $bad.Count) { git -C $d reset -q --hard $old 2>$null | Out-Null; if ($rs) { $rs.layers = @($(if ($snap) { $snap | ConvertFrom-Json -AsHashtable })) }; $row.kept = 'conflict'
              "kept [$e] ${rl}: $(if ($res.err) { $res.err } else { "layer $(@($bad.layer.branch) -join ', ') $(@($bad.why)[0])" }) (left as it was)" }
            else { if ($rs) { $rs.layers = @($res.kept); $rs.targetSha = $res.targetSha }; $row.base = "$($res.targetSha)"; $row.merges = @($res.kept).Count; $gone = @($pre) + @($res.dropped | ForEach-Object { "$($_.layer.branch) ($($_.why))" })
              Event $e 'lane-resync' @{ repo = $rl; base = $res.targetSha; kept = @($res.kept | ForEach-Object branch); dropped = $gone }
              "synced [$e] ${rl}: origin/$($r.target) @ $("$($res.targetSha)".Substring(0, [math]::Min(8, "$($res.targetSha)".Length)))$(if (@($res.kept).Count) { " + $(@($res.kept).Count) layer(s) re-merged" })$(if ($gone.Count) { "; dropped $($gone -join ', ')" })" } }
          $row.head = "$(git -C $d rev-parse HEAD 2>$null)".Trim(); $row.behind = [int]"$(git -C $d rev-list --count "HEAD..origin/$($r.target)" 2>$null)"; $rows.Add([pscustomobject]$row) }
        if (-not $DryRun -and ($st | ConvertTo-Json -Depth 10) -ne $was) { Write-KitAtomic $sf ($st | ConvertTo-Json -Depth 10) } }   # the layers that stayed, written only when changed
      finally { $script:stateLocked = $false } } }
  if (-not $DryRun) { Write-KitAtomic (Get-KitLaneSyncFile) (ConvertTo-Json @($rows) -Depth 4) }
}
# wt-slots/lanes/lanes.json: its own folder (wt-slots/*.json are slot leases only)
# tests.e2e.run[].portFiles (coordinator 2026-11-25: a suite reading its URLs from a source file, devys hand-edited it): on a lane run
# each file's lane-1 ports and {port:<svc>} are rewritten for the run ($Fix), then put back with git checkout; a file with its own
# edits: refused (never mixed into a commit); a killed run: the next e2e in that tree restores it first (work/e2e-portfiles-<hash>.json)
function Get-KitPortFilesMark([string]$Dir) { Join-Path (Get-KitPath work -Create) "e2e-portfiles-$((Get-KitHash ([IO.Path]::GetFullPath($Dir).ToLower()) MD5).Substring(0, 12)).json" }
function Restore-KitLanePortFiles([string]$Dir) {
  $mf = Get-KitPortFilesMark $Dir; if (-not (Test-Path -LiteralPath $mf)) { return }
  $o = try { Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } catch { $null }
  foreach ($rel in @($o.files | Where-Object { $_ })) { git -C $Dir checkout -q -- $rel 2>$null }; Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue
}
# crafty.ps1 check -Step e2e: each run through the gate (its own log), the lane's portFiles written around them -> the last failing exit
function Invoke-KitE2eRuns([string]$Dir, [string[]]$Runs, [string[]]$PortFiles, [scriptblock]$Fix) {
  $rc = 0; $n = 0
  try { if (@($PortFiles | Where-Object { $_ }).Count -and $Fix) { Use-KitLanePortFiles $Dir $PortFiles $Fix } else { Restore-KitLanePortFiles $Dir }
    foreach ($r in $Runs) { $n++; if ($Runs.Count -gt 1) { Write-Host "[check] e2e run $n/$($Runs.Count): $r" }
      & $KitCmd.dev gate -Dir $Dir -Cmd $r -Log (Get-CheckLog $Dir "e2e-$n") | Out-Host; if ($LASTEXITCODE) { $rc = $LASTEXITCODE } } } finally { Restore-KitLanePortFiles $Dir }
  $rc
}
function Use-KitLanePortFiles([string]$Dir, [string[]]$Files, [scriptblock]$Fix) {
  Restore-KitLanePortFiles $Dir; $done = @(); $use = @()
  foreach ($rel in @($Files | Where-Object { $_ })) {   # every file checked before any is written
    $null = git -C $Dir ls-files --error-unmatch -- $rel 2>$null; if ($LASTEXITCODE -or -not (Test-Path -LiteralPath (Join-Path $Dir $rel) -PathType Leaf)) { Write-Host "[check] e2e: portFiles $rel not a tracked file in $Dir`: skipped"; continue }
    if (@(git -C $Dir status --porcelain -- $rel).Count) { throw "e2e: portFiles $rel has edits of its own: commit or revert them (the lane ports are written for the run and put back with git checkout)" }
    $use += $rel }
  foreach ($rel in $use) { $p = Join-Path $Dir $rel
    $was = [IO.File]::ReadAllText($p); $new = & $Fix $was; if ($new -eq $was) { continue }
    [IO.File]::WriteAllText($p, $new); $done += $rel; Write-KitAtomic (Get-KitPortFilesMark $Dir) (@{ files = $done } | ConvertTo-Json -Compress) }
  if ($done.Count) { Write-Host "[check] e2e: lane ports in $($done -join ', ') for this run (put back after it)" }
}
# crafty.ps1 check -Step e2e: -Lane <id>, else the local-env lane whose release holds the branch (envy state, newest): @{ env; why; ports (svc -> port); map (lane-1 port -> lane port) }
function Get-KitBranchLane([string]$Lane, [string]$Branch) {
  $why = 'named -Lane'
  if (-not $Lane) {
    $ld = Get-KitPath localenv; if (-not $Branch -or -not (Test-Path -LiteralPath $ld)) { return }
    $Lane = @(Get-ChildItem -LiteralPath $ld -Filter *.json -File | Sort-Object LastWriteTimeUtc -Descending | Where-Object {
      $sj = try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
      $sj -and $sj.release -and $sj.release.repos -and @($sj.release.repos.Values | ForEach-Object { @($_.layers) } | Where-Object { $_ -and "$($_.branch)" -eq $Branch }).Count } | ForEach-Object BaseName)[0]
    if (-not $Lane) { return }; $why = "holds $Branch"
  }
  $rows = @(try { (pwsh -NoProfile -File $KitCmd.local envs -Json 2>$null | Out-String) | ConvertFrom-Json } catch { })
  $me = @($rows | Where-Object env -eq $Lane)[0]; if (-not $me) { Write-Host "[check] e2e: no local-env lane $Lane (envy.ps1 envs)"; return }
  $base = @($rows | Where-Object { $_.group -eq $me.group -and [int]$_.lane -eq 1 })[0]; $ports = @{}; $map = @{}
  foreach ($p in (Get-KitProps $me.ports)) { $ports[$p.Name] = "$($p.Value)"; $bp = "$(Get-KitMember $base.ports $p.Name)"; if ($bp -and $bp -ne "$($p.Value)") { $map[$bp] = "$($p.Value)" } }
  @{ env = $Lane; why = $why; ports = $ports; map = $map }
}
function Get-KitLaneSyncFile { Join-Path (New-Item -ItemType Directory -Force (Join-Path (Get-KitPath wt-slots -Create) 'lanes')).FullName 'lanes.json' }
# ---- sync: every pooled repo (wt pool; supervise every sync.everyMinutes): one fetch, fast-forward each local branch strictly
# behind its upstream (checked out: ff-only when clean), prune lane branches no worktree holds and gone-upstream branches merged
# into the target; diverged or dirty: listed only. Free clean slots sit detached at origin/<target>; pool.warm free slots exist.
# a branch about to be deleted: its commits on no remote kept as tag backup/<branch>-<sha> (one per tip; NO-DATE: the sha is the id; old
# backup/<branch>-<yyyyMMdd>-<sha> tags stay) -> @{ n; tag; err }
function Save-KitBranchBackup([string]$Repo, [string]$Branch, [switch]$DryRun) {
  $c = @(git -C $Repo rev-list --count "refs/heads/$Branch" --not --remotes 2>$null); if ($LASTEXITCODE -or -not "$($c[0])".Trim()) { return [pscustomobject]@{ n = 0; tag = ''; err = 'rev-list failed: commits unknown' } }
  $n = [int]"$($c[0])".Trim(); if (-not $n) { return [pscustomobject]@{ n = 0; tag = ''; err = '' } }
  $sha = "$(git -C $Repo rev-parse --short=8 "refs/heads/$Branch" 2>$null)".Trim(); $tag = "backup/$($Branch -replace '/', '-')-$sha"
  $err = ''; if (-not $DryRun) { git -C $Repo rev-parse -q --verify "refs/tags/$tag" 2>$null | Out-Null; if ($LASTEXITCODE) { $o = @(git -C $Repo tag $tag "refs/heads/$Branch" 2>&1); if ($LASTEXITCODE) { $err = "tag $tag failed: $(@($o)[-1])" } } }
  [pscustomobject]@{ n = $n; tag = $tag; err = $err }
}
# adaptive warm slots (K40, owner 2026-11-17; state pool-usage, never config): each sync samples the leased slots; warm = p90 of 7 days
# + 1, capped by the pool size (config poolWarm / pool.warm until a day of samples); grows at once (a lease makes a slot lazily); a
# free clean slot unused 7+ days goes only when 3 days stayed under the target, one a day -> @{ warm; target; drop (candidate slot
# numbers, newest bird first; -Shrunk: the sync removed one, the day starts) }
function Update-KitPoolUsage([string]$Repo, [int]$Size, [int]$Default, $Slots, [datetime]$Now = (Get-Date), [switch]$Shrunk) {
  $rk = Get-KitCheckoutName $Repo; $f = Get-KitPath pool-usage; $res = @{ warm = $Default; target = $Default; drop = @() }
  if ($Shrunk) { Invoke-KitLocked $f { $st = Read-KitState $f; if ($st.repos[$rk]) { $st.repos[$rk].shrunk = (Get-KitStamp stored $Now); Write-KitState $f $st } }; return $res }
  Invoke-KitLocked $f { $st = Read-KitState $f; if (-not $st) { $st = [ordered]@{ repos = [ordered]@{} } }; if (-not $st.repos[$rk]) { $st.repos[$rk] = [ordered]@{ samples = @(); used = [ordered]@{}; shrunk = '' } }
    $u = $st.repos[$rk]; $held = @($Slots | Where-Object { Read-KitSlotLease $_.file }); foreach ($s in $held) { $u.used["$($s.n)"] = (Get-KitStamp stored $Now) }
    foreach ($s in @($Slots | Where-Object { -not $u.used["$($_.n)"] })) { $u.used["$($s.n)"] = (Get-KitStamp stored $Now) }   # first seen: counts as used now
    $sampleCut = $Now.AddDays(-(Get-KitParam 'pool.sampleDays')); $idleCut = $Now.AddDays(-(Get-KitParam 'pool.idleDropDays'))
    $u.samples = @(@($u.samples | Where-Object { $_ -and [datetime]$_[0] -gt $sampleCut }) + , @((Get-KitStamp stored $Now), $held.Count))
    $vals = @($u.samples | ForEach-Object { [int]$_[1] } | Sort-Object)
    if ($vals.Count -and (@($u.samples | ForEach-Object { [datetime]$_[0] }) | Measure-Object -Minimum).Minimum -le $Now.AddDays(-1)) { $res.target = [math]::Min($Size, $vals[[math]::Min($vals.Count - 1, [int][math]::Ceiling(0.9 * $vals.Count) - 1)] + 1); $res.warm = $res.target }
    $recentAt = $Now.AddDays(-(Get-KitParam 'pool.shrinkCalmDays')); $recent = @($u.samples | Where-Object { [datetime]$_[0] -gt $recentAt } | ForEach-Object { [int]$_[1] }); $span = @($u.samples | Where-Object { [datetime]$_[0] -le $recentAt }).Count
    if ($span -and @($Slots).Count -gt $res.target -and -not @($recent | Where-Object { $_ + 1 -gt $res.target }).Count -and -not ($u.shrunk -and [datetime]$u.shrunk -gt $Now.AddDays(-1))) {
      $res.drop = @($Slots | Where-Object { -not (Read-KitSlotLease $_.file) -and [datetime]$u.used["$($_.n)"] -lt $idleCut } | Sort-Object n -Descending | ForEach-Object n) }
    $u.target = $res.target; Write-KitState $f $st }
  $res
}
function Sync-KitRepo([string]$Repo, [switch]$DryRun) {
  $rl = Split-Path $Repo -Leaf; $r = [ordered]@{ repo = $rl; at = (Get-KitStamp); ff = @(); diverged = @(); dirty = @(); pruned = @(); warmed = @(); maint = $false; err = '' }
  # a preview (wt pool) reuses a fetch under 10 min old: no 6-repo fetch per look
  $fh = "$(git -C $Repo rev-parse --path-format=absolute --git-path FETCH_HEAD 2>$null)".Trim(); $fresh = $DryRun -and $fh -and (Test-Path -LiteralPath $fh) -and ((Get-Date) - (Get-Item -LiteralPath $fh).LastWriteTime).TotalMinutes -lt (Get-KitParam 'pool.fetchFreshMinutes')
  $fo = @(if (-not $fresh) { git -C $Repo fetch -q --prune origin 2>&1 }); if (-not $fresh -and $LASTEXITCODE) { $r.err = "fetch failed: $(@($fo)[-1])"; return [pscustomobject]$r }
  $tgt = "$(Get-RepoConf (Get-KitCheckoutName $Repo) 'target' '')"; if (-not $tgt) { $tgt = "$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/' }
  $keepRx = Get-KitKeepBranchRx $Repo; $at = @{}; $busy = @{}   # busy: a leased slot or a rebase in progress (its branch is not in worktree list then)
  $leased = @(Get-KitSlots $Repo | Where-Object { Read-KitSlotLease $_.file } | ForEach-Object { "$($_.path)".Replace('\', '/').ToLower() })
  foreach ($w in @(Get-KitWorktrees $Repo)) { $wb = $w.branch; $hn = "$(git -C $w.path rev-parse --git-path rebase-merge/head-name 2>$null)".Trim()
    if (-not $wb -and $hn -and (Test-Path -LiteralPath $(if ([IO.Path]::IsPathRooted($hn)) { $hn } else { Join-Path $w.path $hn }))) { $wb = "$(Get-Content -LiteralPath $(if ([IO.Path]::IsPathRooted($hn)) { $hn } else { Join-Path $w.path $hn }) -TotalCount 1)".Trim() -replace '^refs/heads/'; $busy[$wb] = 'rebase in progress' }
    if ($wb) { $at[$wb] = $w.path; if ("$($w.path)".Replace('\', '/').ToLower() -in $leased) { $busy[$wb] = 'leased slot' } } }
  foreach ($ln in @(git -C $Repo for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads 2>$null)) {
    $b, $u, $tr = "$ln" -split '\|', 3; $wd = $at[$b]
    if ($b -like 'lane/*' -or $b -like 'localenv/*') {   # a lane's branch = target + test merges, rebuilt at its next build
      if (-not $wd) { $bk = Save-KitBranchBackup $Repo $b -DryRun:$DryRun; if ($bk.err) { $r.diverged += "$b kept: $($bk.err)"; continue }
        if (-not $DryRun) { git -C $Repo branch -D $b 2>$null | Out-Null }; $r.pruned += "$b (lane branch, no worktree$(if ($bk.n) { "; $($bk.n) commit(s) on no remote kept as tag $($bk.tag)" }))" }; continue }
    if (-not $u) { continue }
    if ($tr -eq '[gone]') {
      if (-not $wd -and $b -notmatch $keepRx -and $tgt) { git -C $Repo merge-base --is-ancestor "refs/heads/$b" "origin/$tgt" 2>$null; if (-not $LASTEXITCODE) { if (-not $DryRun) { git -C $Repo branch -D $b 2>$null | Out-Null }; $r.pruned += "$b (upstream gone, merged into $tgt)" } }
      continue }
    $bh = if ($tr -match 'behind (\d+)') { [int]$Matches[1] } else { 0 }; if (-not $bh) { continue }
    if ($tr -match 'ahead') { $r.diverged += "$b $tr"; continue }
    if ($busy[$b]) { $r.dirty += "$b behind $bh ($($busy[$b]))"; continue }   # never under a live agent
    if ($wd) {
      if (@(git -C $wd status --porcelain --untracked-files=no 2>$null).Count) { $r.dirty += "$b behind $bh ($wd)"; continue }
      if (-not $DryRun) { git -C $wd merge -q --ff-only "refs/remotes/$u" 2>$null | Out-Null; if ($LASTEXITCODE) { $r.diverged += "$b ff failed"; continue } }
    } elseif (-not $DryRun) { $old = "$(git -C $Repo rev-parse "refs/heads/$b")".Trim(); git -C $Repo update-ref "refs/heads/$b" "refs/remotes/$u" $old 2>$null | Out-Null; if ($LASTEXITCODE) { $r.diverged += "$b update failed"; continue } }
    $r.ff += "$b +$bh"
  }
  $size = Get-KitPoolSize $Repo; $warm = [math]::Min($size, [int]$(if ($null -ne ($pw = Get-RepoConf (Get-KitCheckoutName $Repo) 'poolWarm' $null)) { $pw } else { Get-KitParam 'pool.warm' }))
  if ($size -gt 0 -and -not $DryRun) {   # K40: the learned warm count; one long-unused free slot may go (wt remove: links first, nothing lost)
    $pu = Update-KitPoolUsage $Repo $size $warm @(Get-KitSlots $Repo); $warm = $pu.warm; $r.warm = "$warm of $(@(Get-KitSlots $Repo).Count) (learned $($pu.target))"
    # the first candidate that is safe: checked and reserved (a removing lease: wt lease skips it) under the pool lock, removed outside it
    $pl0 = Join-Path (Get-KitPath wt-slots -Create) "$rl.pool"
    foreach ($dn in @($pu.drop)) { $ds = @(Get-KitSlots $Repo | Where-Object { $_.n -eq $dn })[0]; if (-not $ds -or -not $tgt) { continue }
      $ok = Invoke-KitLocked $pl0 { if ((Read-KitSlotLease $ds.file) -or "$(git -C $ds.path branch --show-current 2>$null)".Trim() -or @(Get-WtDirty $ds.path).Count) { return $false }
        git -C $ds.path merge-base --is-ancestor HEAD "origin/$tgt" 2>$null; if ($LASTEXITCODE) { return $false }
        Write-KitAtomic $ds.file (([ordered]@{ slot = $ds.name; n = $ds.n; repo = $Repo; creating = $true } + (New-KitLease 'wt-sync')) | ConvertTo-Json -Depth 5); $true } | Select-Object -Last 1
      if (-not $ok) { continue }
      try { Remove-Item -LiteralPath (Join-Path $ds.gitDir 'claude-slot') -Force   # no slot any more: wt remove refuses slots
        $rm = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.dev, 'wt', 'remove', '-Dir', $ds.path) 120
        if ($rm.code -and (Test-Path -LiteralPath $ds.path)) { Meta $ds.path 'slot' $ds.n } } finally { Remove-Item -LiteralPath $ds.file -Force -ErrorAction SilentlyContinue }
      $r.shrunk = @("$($ds.name)$(if ($rm.code) { ' (remove failed)' })"); if (-not $rm.code) { $null = Update-KitPoolUsage $Repo $size $warm @() -Shrunk }; break } }
  if ($size -gt 0 -and $tgt -and -not $DryRun) {
    $pl = Join-Path (Get-KitPath wt-slots -Create) "$rl.pool"
    foreach ($s in @(Get-KitSlots $Repo)) {   # idle: at the target, no stale branch; the lock per slot (a lease never waits on a sweep)
      Invoke-KitLocked $pl { if (-not (Read-KitSlotLease $s.file) -and -not "$(git -C $s.path branch --show-current 2>$null)".Trim() -and -not @(git -C $s.path status --porcelain --untracked-files=no 2>$null).Count) {
          git -C $s.path merge-base --is-ancestor HEAD "origin/$tgt" 2>$null; if ($LASTEXITCODE) { $r.dirty += "$($s.name) holds commits on no branch"; return }   # never strand commits
          git -C $s.path checkout -q --detach "origin/$tgt" 2>$null | Out-Null } }
    }
    for ($wi = 0; $wi -lt $size; $wi++) {   # one warm slot at a time: reserved under the lock (a creating lease), made outside it
      $mk = Invoke-KitLocked $pl { $slots = @(Get-KitSlots $Repo); $byN = @{}; foreach ($s in $slots) { $byN[$s.n] = $s }
        if (@($slots | Where-Object { -not (Read-KitSlotLease $_.file) }).Count -ge $warm) { return $null }
        $n = @(1..$size | Where-Object { -not $byN[$_] -and -not (Test-Path -LiteralPath (Get-KitSlotFile (Get-KitSlotLeaf $_ $rl))) })[0]; if (-not $n) { return $null }
        $lf = Get-KitSlotFile (Get-KitSlotLeaf $n $rl); Write-KitAtomic $lf (([ordered]@{ slot = (Get-KitSlotName $n $rl); n = $n; repo = $Repo; creating = $true } + (New-KitLease 'wt-sync')) | ConvertTo-Json -Depth 5)
        [pscustomobject]@{ n = $n; lf = $lf; p = (Join-Path @($KitConf.WorktreeRoots)[0] (Get-KitSlotLeaf $n $rl)) } } | Select-Object -Last 1
      if (-not $mk) { break }
      try { if (Test-Path -LiteralPath $mk.p) { $r.err = "$($mk.p) exists but is no slot"; break }
        Add-WtRoot (Split-Path $mk.p); git -C $Repo worktree add -q --detach $mk.p "origin/$tgt" 2>$null | Out-Null; if ($LASTEXITCODE) { $r.err = "warm slot $($mk.n) failed"; break }
        Meta $mk.p 'slot' $mk.n; $r.warmed += Get-KitSlotName $mk.n $rl } finally { Remove-Item -LiteralPath $mk.lf -Force -ErrorAction SilentlyContinue }
    }
  }
  # the gc kit git skips (lib.ps1 maintenance.auto): at most once a sync, only with no slot of this repo leased; git's own thresholds
  if (-not $DryRun -and -not $leased.Count) { git -C $Repo maintenance run --auto --quiet --detach 2>$null | Out-Null; $r.maint = $LASTEXITCODE -eq 0 }
  $sf = Join-Path (New-Item -ItemType Directory -Force (Join-Path (Get-KitPath wt-slots -Create) 'sync')).FullName "$rl.json"
  if (-not $DryRun) { Write-KitAtomic $sf ([pscustomobject]$r | ConvertTo-Json -Depth 4) }
  [pscustomobject]$r
}
# the last sync per repo (the dashboard's Branches tile)
function Get-KitRepoSyncState { @(Get-ChildItem -LiteralPath (Join-Path (Get-KitPath wt-slots -Create) 'sync') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } }) }
# ---- pool: wt pool [-Migrate]
function Invoke-WtPool {   # slots per pooled repo; -Migrate [-DryRun]: per-task worktrees of pooled repos go when nothing is lost, the rest listed
  $repos = if ($Repo) { @(Resolve-WtRepo $Repo) } else { @(Get-KitRepoDirs | Where-Object { (Get-KitPoolSize $_) -gt 0 }) }
  if ($Migrate) {
    $heldBy = Get-KitWtHeldTest
    foreach ($rp in $repos) {
      $bctx = @{}; $keepRx = Get-KitKeepBranchRx $rp
      foreach ($w in @(Get-KitWorktrees $rp | Select-Object -Skip 1)) {   # the first is the main checkout
        $d = $w.path; if (-not (Test-Path -LiteralPath $d) -or (Test-KitSlotDir $d)) { continue }
        $label = "$d$(if ($w.branch) { " ($($w.branch))" })"
        $dedicated = if ($w.branch -and $w.branch -match $keepRx) { 'protected or env branch' } elseif ((Split-Path $d -Leaf) -like 'deploymerge-*') { 'deploy merge' } elseif (-not $w.branch -and @(Get-DepLinkDefaults | Where-Object { $i = Get-Item -LiteralPath (Join-Path $d $_.dir) -Force -ErrorAction SilentlyContinue; $i -and -not $i.LinkType }).Count) { 'a dependency store' }
        if ($dedicated) { "dedicated  ${label}: $dedicated"; continue }
        if (($who = & $heldBy $d.Replace('/', '\'))) { "keep  ${label}: held by $who"; continue }
        $dt = @(Get-WtDirty $d); $bv = if ($w.branch) { Get-KitBranchVerdict $rp $w.branch $bctx -IdleHours 0 -IgnoreCheckout }
        if ($dt.Count) {   # a merged branch whose only leftovers are edits of tracked files (regenerated fixtures): saved as a patch, then discarded (K38)
          if (-not $bv.delete -or @($dt | Where-Object { $_ -notmatch '^( M|M |MM) ' }).Count) { "keep  ${label}: uncommitted files"; continue }
          if ($DryRun) { "would go  ${label}: $($bv.why); $($dt.Count) edited file(s) saved as a patch first"; continue }
          $pd = (New-Item -ItemType Directory -Force (Join-Path (Get-KitPath wt-slots -Create) 'patches')).FullName; $pf = Join-Path $pd "$(New-KitName patch (Split-Path $d -Leaf) $pd -Cap 40).patch"   # patch-<slot leaf>, a tie -2
          git -C $d diff HEAD --binary --output="$pf" 2>$null; if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $pf) -or -not (Get-Item -LiteralPath $pf).Length) { "keep  ${label}: uncommitted files (patch failed)"; continue }   # git writes the bytes (CRLF, binary kept)
          git -C $d checkout -q HEAD -- . 2>$null; if ($LASTEXITCODE) { "keep  ${label}: uncommitted files (reset failed; patch $pf)"; continue }; "patched  ${label}: $($dt.Count) edited file(s) saved to $pf" }
        if ($w.branch) { if (-not $bv.delete) { "keep  ${label}: $($bv.why)"; continue }; $gw = $bv.why }
        elseif (-not "$(git -C $d for-each-ref --contains $w.head --count=1 --format='%(refname)' refs/remotes/origin 2>$null)".Trim()) { "keep  ${label}: detached HEAD on no remote branch"; continue }
        else { $gw = 'detached HEAD on the host' }
        if ($DryRun) { "would go  ${label}: $gw"; continue }
        $ro = @(try { Invoke-Wt remove -Dir $d 2>&1 | ForEach-Object { "$_" } } catch { "FAILED: $($_.Exception.Message)" }); "gone  ${label}: $gw; $($ro[-1])"
      }
    }
    return
  }
  # plain pool: what a sync would do; -Sync (supervise): does it
  $synced = @(foreach ($rp in $repos) { $sy = Sync-KitRepo $rp -DryRun:(-not $Sync -or $DryRun); if (-not $Json) { "sync $($sy.repo): $(@($sy.ff).Count) fast-forwarded, $(@($sy.diverged).Count) diverged, $(@($sy.dirty).Count) dirty, $(@($sy.pruned).Count) pruned, $(@($sy.warmed).Count) warm slot(s) made$(if ($sy.err) { "; $($sy.err)" })"; foreach ($x in @($sy.diverged) + @($sy.dirty)) { "  kept: $x" } } })
  if (-not $Json) { $synced }
  if ($Sync -and -not $DryRun -and (Get-KitValue 'localEnv' $null) -and (Test-Path -LiteralPath $KitCmd.local)) {   # idle lanes rebuilt on their target (envy.ps1 lanes -Sync)
    $ls = Invoke-KitExe 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $KitCmd.local, 'lanes', '-Sync') 600; if (-not $Json) { @("$($ls.out)" -split "`r?`n" | Where-Object { $_ -match '^(synced|kept) ' }) } }
  $rows = @(foreach ($rp in $repos) { $size = Get-KitPoolSize $rp; foreach ($s in @(Get-KitSlots $rp)) { $o = Read-KitSlotLease $s.file
        [pscustomobject]@{ slot = $s.name; repo = (Split-Path $rp -Leaf); size = $size; path = $s.path; branch = $(if ($s.branch) { $s.branch } else { "detached $("$($s.head)".Substring(0, [math]::Min(8, "$($s.head)".Length)))" })
          state = $(if (-not $o) { 'free' } elseif ($o.parked) { 'parked' } elseif ($o.creating) { 'creating' } else { 'leased' }); agent = "$($o.agent)"; since = "$($o.since)"; why = "$($o.parkedWhy)" } } })
  $waiting = @(Get-ChildItem -LiteralPath (Join-Path (Get-KitPath wt-slots -Create) 'wait') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt (Get-KitParam 'pool.waitFreshMinutes') } | ForEach-Object { Read-KitSlotLease $_.FullName })
  if ($Json) { return ([ordered]@{ slots = $rows; waiting = $waiting } | ConvertTo-Json -Depth 4 -Compress) }
  foreach ($rp in $repos) { $mine = @($rows | Where-Object repo -eq (Split-Path $rp -Leaf)); "pool $(Split-Path $rp -Leaf): $($mine.Count)/$(Get-KitPoolSize $rp) slots, $(@($mine | Where-Object state -eq 'free').Count) free" }
  foreach ($r in $rows) { '  {0,-22} {1,-8} {2,-40} {3}' -f $r.slot, $r.state, $r.branch, $(if ($r.agent) { "$($r.agent) since $($r.since)$(if ($r.why) { ": $($r.why)" })" }) }
  foreach ($w in $waiting) { "  waiting: $($w.agent) for $($w.repo) ($($w.branch)) since $($w.since)" }
}
# ---- sweep: worktrees and local branches of every repo (wt remove, cleanup); nothing unpushed, dirty or held goes
# one checkout per repo: repos[].checkout, git checkouts under reposRoot, the kit
function Get-KitRepoDirs {
  $seen = @{}
  $cand = @(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.checkout)" }) + @(if ($KitConf.ReposRoot -and (Test-Path -LiteralPath $KitConf.ReposRoot) -and (Test-Path -LiteralPath $KitConf.ConfigFile)) { Get-ChildItem -LiteralPath $KitConf.ReposRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } | ForEach-Object FullName }) + @($KitConf.Kit)
  foreach ($d in @($cand | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })) {
    $gd = "$(git -C $d rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim().ToLower()
    if ($gd -and -not $seen[$gd]) { $seen[$gd] = 1; (Resolve-Path -LiteralPath $d).Path.TrimEnd('\', '/') }
  }
}
function Get-KitWorktrees([string]$Repo) {   # git worktree list as objects; branch '' = detached
  $cur = $null
  foreach ($l in @(git -C $Repo worktree list --porcelain 2>$null) + '') {
    if ($l -like 'worktree *') { $cur = [ordered]@{ path = $l.Substring(9).Replace('\', '/'); branch = ''; head = '' } }
    elseif (-not $l) { if ($cur) { [pscustomobject]$cur }; $cur = $null }
    elseif ($cur -and $l -like 'branch refs/heads/*') { $cur.branch = $l.Substring(18) }
    elseif ($cur -and $l -like 'HEAD *') { $cur.head = $l.Substring(5) }
  }
}
# linkDefaults: [{ markers: [<file>], dir }] a worktree links from its source; unset = node_modules + .venv
function Get-DepLinkDefaults {
  $l = @(Get-KitSetting 'linkDefaults' $null | Where-Object { $_.dir -and @($_.markers).Count })
  if ($l.Count -or ($__cfg -and (Get-KitProps $__cfg).Name -contains 'linkDefaults')) { return $l }   # [] = link nothing
  @([pscustomobject]@{ markers = @('package.json'); dir = 'node_modules' }, [pscustomobject]@{ markers = @('pyproject.toml', 'requirements.txt'); dir = '.venv' })
}
# a worktree-root folder no repo lists (half-done remove): goes if all files are runtime, ignored or in a repo's objects
function Get-KitLeftoverVerdict([string]$Dir, [string[]]$RepoDirs) {
  $RepoDirs += @(git -C $KitConf.Kit rev-parse --path-format=absolute --git-common-dir 2>$null | Split-Path)
  $leaf = Split-Path $Dir -Leaf; $repo = @($RepoDirs | Where-Object { $leaf -like "*-$(Split-Path $_ -Leaf)" -or $leaf -eq (Split-Path $_ -Leaf) } | Select-Object -First 1)[0]
  $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.LinkType })   # links are never followed
  if ($files.Count -gt 500) { return [pscustomobject]@{ delete = $false; why = "$($files.Count) files: check by hand" } }
  # a worktree's own runtime and state folders are its runs' (the live clone keeps the real state; 2026-11-27: a removed kit worktree
  # stayed for its .state/*.local.* files)
  $rtl = "$(Split-Path (Get-KitRuntime) -Leaf)/"; $stl = "$($script:KitPathMap.stateDir.Trim('/\'))/"
  $left = @(foreach ($f in $files) { $rel = [IO.Path]::GetRelativePath($Dir, $f.FullName).Replace('\', '/'); if ($rel.StartsWith($rtl) -or $rel.StartsWith($stl)) { continue }
      if ($repo -and $f.Name -notlike '*.local.*') {
        git -C $repo check-ignore -q --no-index -- $rel 2>$null; if ($LASTEXITCODE -eq 0) { continue }
        $h = "$(git -C $repo hash-object --path=$rel -- $f.FullName 2>$null)".Trim(); if ($h) { git -C $repo cat-file -e "$h^{blob}" 2>$null; if ($LASTEXITCODE -eq 0) { continue } } }
      $rel })
  if ($left.Count) { return [pscustomobject]@{ delete = $false; why = "$($left.Count) file(s) in no git: $(@($left | Select-Object -First 3) -join ', ')" } }
  [pscustomobject]@{ delete = $true; why = $(if ($files.Count) { "$($files.Count) file(s): runtime, ignored or in git" } else { 'empty skeleton (links only)' }) }
}
# links first (never followed), then the folder
function Remove-KitLeftover([string]$Dir) {
  foreach ($l in @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)) { if ($l.PSIsContainer) { [IO.Directory]::Delete($l.FullName) } else { [IO.File]::Delete($l.FullName) } }
  if (@(Get-ChildItem -LiteralPath $Dir -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue).Count) { throw "links left in ${Dir}: not removed" }
  Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop
}
# worktree-root folders, then repo branches; counts -> repo-sweep
function Invoke-KitSweep([string[]]$Roots, [double]$IdleHours = 2, [switch]$DryRun) {
  $ErrorActionPreference = 'SilentlyContinue'; $now = Get-Date; $wtDays = [double](Get-KitParam 'cleanup.worktreeDays')   # gone branch / uncommitted: idle this long
  $actions = [Collections.ArrayList]::new(); $kept = [Collections.ArrayList]::new(); $notes = @()
  $act = { param($b, $why, $path) [void]$actions.Add([pscustomobject]@{ bytes = [long]$b; why = $why; path = $path }) }; $keep = { param($what, $why) [void]$kept.Add("$what`: $why") }
  $size = { param($p) [long](Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
  $cat = { param($w) $w -replace '^(upstream) \S+ (gone).*', '$1 $2, tip on the host' -replace ' \(.*$' -replace '^merged into \S+', 'merged' }   # one action group per reason
  $heldBy = Get-KitWtHeldTest; $claimed = $script:KitWtClaimed
  $ctx = [ordered]@{}; $reg = @{}
  $addRepo = { param($rp) if ($rp -and -not $ctx.Contains($rp)) { $ctx[$rp] = @{}; foreach ($x in @(Get-KitWorktrees $rp)) { $reg[$x.path.ToLower()] = $rp } } }
  foreach ($rp in @(Get-KitRepoDirs)) { & $addRepo $rp }
  # a loose file in a root is an agent's scratch (2026-11-27: 30 dbg / edit scripts in .kit-worktrees): gone once idle
  foreach ($lf in @(foreach ($root in $Roots) { Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue })) {
    $idleF = ($now - $lf.LastWriteTime).TotalHours
    if ($idleF -lt $IdleHours) { & $keep $lf.FullName "loose file in a worktree root, changed $([int]($idleF * 60)) min ago"; continue }
    & $act $lf.Length 'loose file in a worktree root (only worktrees live there)' $lf.FullName
    if (-not $DryRun) { try { Remove-Item -LiteralPath $lf.FullName -Force -ErrorAction Stop } catch { & $act 0 'FAILED loose file' "$($lf.FullName): $($_.Exception.Message)" } } }
  foreach ($w in @(foreach ($root in $Roots) { Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue })) {
    $d = $w.FullName; $key = $d.Replace('\', '/').ToLower()
    if (Test-KitSlotDir $d) { continue }   # pool slots stay (wt release frees them; supervise reaps their leases)
    if (-not $reg[$key] -and "$(git -C $d rev-parse --path-format=absolute --show-toplevel 2>$null)".Trim().ToLower() -eq $key) { & $addRepo ("$(@(git -C $d worktree list --porcelain 2>$null)[0])" -replace '^worktree ') }
    $newest = (Get-ChildItem $d -File -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue | Where-Object FullName -notmatch '[\\/](node_modules|\.git|target|build)[\\/]' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $idleH = ($now - $(if ($newest) { $newest } else { $w.LastWriteTime })).TotalHours; $old = $idleH -ge 24 * $wtDays   # no file (a skeleton): the folder's own time
    if ($who = & $heldBy $d) { & $keep $d "held by $who"; continue }
    if (-not ($rp = $reg[$key])) {   # no repo lists it: a remove git half did (junctions + files)
      if ($idleH -lt $IdleHours) { & $keep $d "no repo lists it, changed $([int]($idleH * 60)) min ago"; continue }
      $lv = Get-KitLeftoverVerdict $d @($ctx.Keys)
      if (-not $lv.delete) { & $keep $d "no repo lists it; $($lv.why)"; $notes += "folder $d`: no worktree or slot, $($lv.why): kept (move what you need, then delete it)"; continue }
      & $act (& $size $d) 'leftover folder no repo lists (links unlinked, never followed)' "$d ($($lv.why))"
      if (-not $DryRun) { try { Remove-KitLeftover $d } catch { & $act 0 'FAILED leftover folder' "$d`: $($_.Exception.Message)" } }
      continue
    }
    $br = "$(git -C $d rev-parse --abbrev-ref HEAD 2>$null)".Trim(); if ($br -eq 'HEAD') { $br = '' }
    if (-not $ctx[$rp].keep) { $ctx[$rp].keep = Get-KitKeepBranchRx $rp }
    if ($br -and $br -match $ctx[$rp].keep) { continue }   # env / default worktrees: their owners'
    if (git -C $d status --porcelain 2>$null) { & $keep "$d$(if ($br) { " ($br)" })" 'uncommitted files'; if ($old) { $notes += "worktree $d ($br): uncommitted files, idle $([int]($idleH / 24)) d: kept (never deleted; commit or remove it by hand)" }; continue }
    # an idle unclaimed deploymerge-* blocks the next merge
    $dm = $w.Name -like 'deploymerge-*' -and $d.ToLower() -notin $claimed -and $newest -and ($now - $newest).TotalMinutes -ge [math]::Max(60.0, [double](Get-KitParam 'idle.graceMinutes'))
    if (-not $dm -and $idleH -lt $IdleHours) { & $keep "$d ($br)" "active, changed $([int]($idleH * 60)) min ago"; continue }
    if (-not (Invoke-GitFetch -Dir $d)) { & $keep $d 'git fetch failed'; continue }
    $why = if ($dm) { 'ownerless deploy merge' } elseif ($br) {
      $bv = Get-KitBranchVerdict $rp $br $ctx[$rp] -IdleHours 0 -IgnoreCheckout
      if ($bv.delete -and ($idleH -ge 24 -or $bv.why -notlike 'local copy*')) { $bv.why } elseif ($old -and $bv.why -match 'upstream \S+ gone') { "upstream gone, idle $wtDays d+ (branch kept: $($bv.why))" } else { & $keep "$d ($br)" $bv.why; $null }
    } else {
      $hd = "$(git -C $d rev-parse HEAD 2>$null)".Trim()
      $dep = @(foreach ($n in @(Get-DepLinkDefaults | ForEach-Object dir)) { $i = Get-Item -LiteralPath (Join-Path $d $n) -Force -ErrorAction SilentlyContinue; if ($i -and -not $i.LinkType -and -not (Test-Path -LiteralPath (Join-Path $i.FullName '.kit-farm.json'))) { $n } })
      if ($dep) { & $keep $d "detached, its own $($dep -join ' + ') install (a dependency store)"; $null }
      elseif ($idleH -ge 24 -and "$(git -C $d for-each-ref --contains $hd --count=1 --format='%(refname)' refs/remotes/origin 2>$null)".Trim()) { 'detached HEAD on the host' }
      else { & $keep $d 'detached: HEAD on no remote branch, or idle < 24 h'; $null }
    }
    if (-not $why) { continue }
    & $act (& $size $d) "worktree: $(& $cat $why) (clean, idle, no holder)" "$d$(if ($br) { " ($br)" }): $why"
    if (-not $DryRun -and (Test-Path -LiteralPath $d)) { try { $null = Invoke-Wt remove -Dir $d 2>&1 } catch {}; if (Test-Path -LiteralPath $d) { & $act 0 'FAILED worktree remove' $d } }
  }
  $counts = [Collections.ArrayList]::new()
  foreach ($rp in @($ctx.Keys)) {
    $leaf = Split-Path $rp -Leaf
    $pr = @(git -C $rp worktree prune -n -v 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
    if ($pr.Count) { & $act 0 'worktree record of a missing folder pruned' "$($pr.Count) in $leaf"; if (-not $DryRun) { git -C $rp worktree prune 2>$null } }
    $ctx[$rp].out = $null; $del = 0; $keptN = 0
    $brs = @(git -C $rp for-each-ref --format='%(refname:short)' refs/heads 2>$null)
    if (-not (Invoke-GitFetch -Dir $rp)) { $notes += "git fetch failed in $rp`: its branches not swept"; $brs = @() }
    foreach ($b in $brs) {
      $bv = Get-KitBranchVerdict $rp $b $ctx[$rp] -IdleHours ([math]::Max(1, $IdleHours))
      if ($bv.delete) { $del++; & $act 0 "local branch: $(& $cat $bv.why)" "$b in $leaf`: $($bv.why)"; if (-not $DryRun) { git -C $rp branch -D $b 2>$null | Out-Null } }
      elseif ($bv.why -notmatch '^(protected|checked out)') { $keptN++; & $keep "$b in $leaf" $bv.why }
    }
    [void]$counts.Add([ordered]@{ repo = $leaf; branches = @(git -C $rp for-each-ref --format='%(refname:short)' refs/heads 2>$null).Count; worktrees = [math]::Max(0, @(Get-KitWorktrees $rp).Count - 1); removable = $(if ($DryRun) { $del } else { 0 }); kept = $keptN })
  }
  Write-KitAtomic (Get-KitPath repo-sweep -Create) ([ordered]@{ at = (Get-KitStamp stored $now); dryRun = [bool]$DryRun; repos = @($counts) } | ConvertTo-Json -Depth 4) -Volatile '"at":\s*"[^"]*"'
  [pscustomobject]@{ actions = @($actions); kept = @($kept); notes = @($notes) }
}
