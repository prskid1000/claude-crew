<#
crafty.ps1: crafty commands (SKILL.md steps 1-8). pwsh 7: & <kit>/skills/crafty/crafty.ps1 <verb> [args]
 wt lease|release|pool|new|sync|commit|remove|status|list ...  worktrees (lease -Repo -Branch -Agent: a pool slot, release: back, pool [-Sync] [-Migrate]; deps linked, hooks run; commit -Spec <json> (devtools.py render commit) | -Message [-ProseOk '<why>'] [-AllowEmpty] [-Paths <p,..> (stages only them)]: over prose limits = refused; sync [-Mrs <iid>]: repos[].regenerate;
   new -Scope '<glob>,..' (brief agents[].paths): commit refuses files outside, -ScopeOk <decision id> = the owner's scope word;
   new / lease -Task <id> without -Branch: a keyed task's branch, kitbag.py naming make branch)
 scope [-Mrs <refs> [-Json]] [-Days 7]  -Mrs: each MR's source / test files + OUT-OF-AREA vs its logged area; none: one WATCH line for MRs merged outside it
 stack -Dir <module> [-Json]  build/test/run commands (auto-detected; .claude-stack.json overrides)
 check -Dir <module> [-Step quick|test|e2e|build|migrations] [-Tests <names>] [-Touched] [-Force]  gated checks (e2e: the diff's specs only; -AllTests = whole suite;
   a pass on the same sources + command is not rerun, -Force reruns)
 gate -Dir <dir> -Cmd "<command>"  a heavy command through the machine-wide memory gate
 tracker <verb> <id> ...  tracker adapter (view, roles <scope>, status [-Back <why>: a step back], comment -Kind [-ProseOk] [-Spec <json> (rendered)], uncomment <id> <comment id>, create -Spec <json> [-DryRun] ("task spec" below; free text -File only with -Key: a QA / watch defect), update <id> -Spec <json> (merged by key; -ReplaceItems [-Force]: its items are the whole list), describe <id> <text | file> | -Text | -File (a missing file refused, old text kept in desc-backups), render -Spec <json>, bug -Parent -Key -Name -File [-Signature], scope -Task -Add, move <id> [-Parent] [-List] [-NoParent], group -Parent <p> | -Spec <json> -Tasks <ids> (another list: an Items link), list, ...)
 prior -Task <id> [-Repo <r>] [-Query '<words>'] [-Symbol <s>] [-Json]  prior work (duplicate tasks, MRs, branches, commits, docs, QA runs): the gate of wt lease / new, devtools.py mr / finish / doc
 pipes [-Mrs <repo!iid | url>,...] [-Run <run>] [-MaxMinutes 8] [-UntilMerged] | -Repo <repo> -Branch <branch> [-Sha <commit>]  wait for MR pipelines, or a branch's newest one (of that commit) (JSON; no -Mrs: a wt worktree's branch's open MRs, else tracked open MRs [of -Run]); -UntilMerged: for the merges
 host <verb> '<args JSON>' | <iid | [group/]repo!iid | MR URL | repo iid>  git-host / ci adapter verb (README "Adapters")
 guard [-SelfTest]  PreToolUse hook (tool call JSON on stdin)
 dir -Agent <id> [-Item <task>] [-Name <file>] | -Kind evidence -Item <task> [-Agent]  an agent's own folder (created) or file path
 checkpoint -Agent <id> [-Run <run>] -Step <step> [-Evidence] [-Dir <wt>] [-Next] | -Read  resume point (bossy.ps1 pause / resume)
 runtime use|release|status -Name <runtime> [-Agent]  leases on Docker, WSL, VMs
In: kit.local.json + verb parameters. Out: text, or JSON with -Json.
Exit codes: 0 ok · 1 problem (failed check, conflict, blocked) · 2 usage · gate/check: the command's code
Sections: L25 init · L34 wt · L327 stack · L426 gate · L760 check · L1078 pipes · L1140 guard · L2057 dir · L2067 checkpoint ·
  L2099 prior · L2137 tracker · L2159 task spec · L2357 scope · L2405 host
#>
#Requires -Version 7
# ---- init: args, gate mutex, lib.ps1
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
# an abandoned gate mutex is ours
function Lock-Gate($m) { try { $m.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $true } }
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:TscNoOutput = [string]$script:KitVocab.tscNoOutput   # unset: no typecheck command
# e2e test runners: kit.local.json tests.runners, else vocab.json testRunners [{ name, deps, files, cmd, wholeSuiteRx, specGlobs, ignore }]
function Get-KitTestRunners { $r = Get-KitSetting 'tests.runners' $null; @($(if ($r) { $r } else { $script:KitVocab.testRunners }) | Where-Object { $_ }) }
# ---- wt: a worktree per agent; deps linked, never installed
# a lock file newer than the install: packages added since are missing (fails at runtime, not at link time)
function Get-StaleDepsNote([string]$nmDir) {
  $at = @(@('.yarn-integrity', '.package-lock.json', '.modules.yaml') | ForEach-Object { Get-Item -LiteralPath (Join-Path $nmDir $_) -Force -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime)[-1]
  if (-not $at) { $at = Get-Item -LiteralPath $nmDir -Force -ErrorAction SilentlyContinue }; if (-not $at) { return }
  $new = @(@('yarn.lock', 'package-lock.json', 'pnpm-lock.yaml', 'package.json') | ForEach-Object { Get-Item -LiteralPath (Join-Path (Split-Path $nmDir) $_) -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt $at.LastWriteTime.AddMinutes(1) })
  if ($new.Count) { "$nmDir was installed $($at.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), before $($new[0].Name) changed ($($new[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))): packages added since are missing; reinstall that source (frozen lockfile), then link" }
}
function Invoke-Wt {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('new', 'sync', 'commit', 'status', 'remove', 'list', 'sweep', 'lease', 'release', 'pool')][string]$Action,
  [string]$Repo, [string]$Branch, [string]$Target, [string]$Name, [string]$LinkFrom, [string]$Root,
  [string]$Dir, [string]$Message, [string]$MessageFile, [string]$Spec, [switch]$Force, [switch]$NoStage, [string[]]$Paths, [switch]$AllowEmpty, [string]$ProseOk, [Alias('Mr')][string]$Mrs, [string]$Task, [string]$Override,
  [string]$Scope, [string]$ScopeOk, [double]$IdleHours = 2, [switch]$DryRun, [switch]$Json,
  [string]$Agent, [string]$Session, [int]$WaitMinutes = 60, [string]$Reason, [switch]$Migrate, [switch]$Sync
)
$ErrorActionPreference = 'Stop'
function G { $o = & git @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' '): $o" }; $o }
# else git -C hits an outer repo
function Resolve-Wt($d) {
  if (-not $d) { $d = (Get-Location).Path }
  if (-not (Test-Path -LiteralPath $d -PathType Container)) { throw "no such folder: $d" }
  $d = (Resolve-Path -LiteralPath $d).Path.TrimEnd('\', '/')
  $pre = git -C $d rev-parse --show-prefix 2>$null   # '' only at a worktree top
  if ($LASTEXITCODE -or "$pre".Trim()) {
    # a worktrees root resolves to the superproject
    $kids = @(Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Leaf } | Select-Object -First 5 -ExpandProperty FullName)
    if ($kids.Count) { throw "$d holds worktrees, it is not one: pass -Dir <worktree>, e.g. $($kids -join ', ')" }
    throw "$d is not the top of a git worktree (top: $(git -C $d rev-parse --show-toplevel 2>$null)); pass the worktree folder as -Dir"
  }
  $d
}
function GitDir($d) { $g = (git -C $d rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $d $g }; $g }
# repos[].regenerate: generated-only rebase conflict -> target's copy + run commands, rebase done, last commit amended + pushed;
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
function Meta($d, $k, $v) { $f = Join-Path (GitDir $d) "claude-$k"; if ($PSBoundParameters.ContainsKey('v')) { Write-KitAtomic $f "$v`n" } elseif (Test-Path $f) { Get-Content $f } }
function DepHash($pkgJson) {
  try { $p = Get-Content $pkgJson -Raw | ConvertFrom-Json } catch { return '' }
  (@('dependencies', 'devDependencies') | ForEach-Object { if ((Get-KitMember $p $_)) { (Get-KitProps (Get-KitMember $p $_)) | Sort-Object Name | ForEach-Object { "$($_.Name)@$($_.Value)" } } }) -join ';'
}
function Copy-HookDirs($path, $sources) {
  foreach ($hs in @($sources | Where-Object { $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique)) {
    foreach ($h in (Get-ChildItem $hs -Directory -Recurse -Depth 3 -Filter '_' -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Name -eq '.husky' -and $_.FullName -notmatch 'node_modules' })) {
      $to = Join-Path $path $h.FullName.Substring($hs.Length).TrimStart('\', '/')
      if (-not (Test-Path $to)) { Copy-Item $h.FullName $to -Recurse }
    }
  }
}
# add -A would commit a symlink
function Exclude-Links($path, $links) {
  if (-not $links -or $KitIsWindows) { return }
  $ex = Join-Path (git -C $path rev-parse --path-format=absolute --git-common-dir).Trim() 'info/exclude'
  New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
  $have = @(if (Test-Path $ex) { Get-Content $ex })
  $add = @($links | ForEach-Object { '/' + [IO.Path]::GetRelativePath($path, $_).Replace('\', '/') } | Where-Object { $_ -notin $have })
  if ($add) { Add-Content $ex $add }
}
# deps from the target's source (repos[].linkFromByTarget / linkFrom, else the checkout), linkPaths, hooks; another source relinks
function Set-WtDeps($path, $rp, $tg, $from) {
  $rc = Get-WtRepoConf $rp; $from = @($from | Where-Object { $_ })
  if (-not $from.Count -and ($from = @(Get-WtDepSource $rp $tg)).Count) { "linking dependencies from $($from -join ', ') (kit.local.json, target $tg)" }
  $srcs = @(if ($from.Count) { $from | ForEach-Object { (Resolve-Path $_).Path } } else { $rp }); $src = $srcs[0]   # a list: the first is the source of record
  $was = "$(Meta $path 'linksrc')".Trim(); $kept = @()
  $srcKey = $srcs -join ";"
  if ($was -and $was -ne $srcKey) {   # a slot moved to another target's install
    foreach ($l in @(Meta $path 'links' | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) { if ((Split-Path $l -Leaf) -eq 'node_modules' -or -not (Get-Item -LiteralPath $l -Force).LinkType) { Remove-NodeModules $l } else { Remove-DirLink $l } }
    "relinked dependencies: $was -> $srcKey"
  } elseif ($was) { $kept = @(Meta $path 'links' | Where-Object { $_ }) }
  $links = @(Add-DepLinks $path $srcs $tg)
  foreach ($lp in @($rc.linkPaths) | Where-Object { $_ }) {   # git-ignored files
    $lf = @(@($srcs) + $rp | ForEach-Object { Join-Path $_ $lp }) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $to = Join-Path $path $lp
    if (-not $lf) { Write-Warning "linkPaths: no $lp in $src or $rp, skipped"; continue }
    if (Test-Path $to) { continue }
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    if ((Get-Item $lf).PSIsContainer) { New-DirLink $to $lf; $links += $to } else { Copy-Item $lf $to }
  }
  Copy-HookDirs $path @(@($srcs) + $rp)   # a --ignore-scripts checkout has no .husky/_
  Meta $path 'links' (@(@($kept) + $links | Select-Object -Unique) -join "`n"); Meta $path 'linksrc' $srcKey
  Exclude-Links $path $links
  if ($links) { 'linked:   ' + (($links | ForEach-Object { $_.Substring($path.Length + 1) }) -join ', ') + "  (from $($srcs -join ', '))" }
}

switch ($Action) {
  'new' {
    if (-not $Branch -and $Task) { $Branch = Get-KitTaskBranch $Task } elseif ($Task) { Test-KitTaskBranch $Task $Branch }   # naming make branch
    if (-not ($Repo -and $Branch -and $Target -and $Name)) { throw 'new needs -Repo -Branch (or -Task: a keyed task names it) -Target -Name' }
    $Repo = Resolve-WtRepo $Repo
    if (($tx = Get-KitTaskTagRx) -and $Branch -match $tx -and (Get-KitPoolSize $Repo) -gt 0 -and -not $Override) { throw "wt new refused: $(Get-KitCheckoutName $Repo) has a worktree pool and $Branch is a task branch: & $($KitCmd.dev) wt lease -Repo $Repo -Branch $Branch -Agent <your id> (a free slot, kept warm); a dedicated worktree on purpose: -Override '<why>'" }
    if (-not $Root) { $Root = @($KitConf.WorktreeRoots)[0] }
    $path = Join-Path $Root "$Name-$(Split-Path $Repo -Leaf)"
    if (Test-Path $path) {   # name the blocker
      $bh = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and "$($_.worktrees)" -match [regex]::Escape($path) } | ForEach-Object agent)
      throw "$path exists (branch $(git -C $path branch --show-current 2>$null), last commit $(git -C $path log -1 --format=%cr 2>$null), holder: $(if ($bh) { $bh -join ', ' } else { 'none on the board' })): resume there (wt status -Dir $path), pick another -Name, or with no holder: wt remove -Dir $path"
    }
    $tk = if ($Task) { $Task } elseif (($rx = Get-KitTaskTagRx) -and $Branch -match $rx) { $Matches.id }   # check before create (crafty.ps1 prior)
    try { Assert-KitPrior $tk $Repo "wt new $Branch" $Override $Branch } catch {
      $priorWhy = "$($_.Exception.Message)"; $wtCmd = "crafty.ps1 wt new -Repo '$Repo' -Target $Target -Name $Name$(if ($Task) { " -Task $Task" })"
      $reuseBr = @(if ($priorWhy -match 'already exists') { (Read-KitState (Get-KitTaskFile $tk)).prior.found | Where-Object { $_.kind -eq 'branch' -and ($_.repo -split '[\\/]')[-1] -eq ($Repo -split '[\\/]')[-1] } | ForEach-Object { "$($_.ref)" -replace '^origin/' } | Select-Object -Unique })
      throw (@($priorWhy) + @($reuseBr | ForEach-Object { "  reuse: $wtCmd -Branch $_" }) + @(if ($priorWhy -match 'already exists') { "  new work on purpose: $wtCmd -Branch $Branch -Override '<why>'" }) -join "`n")
    }
    if ($tk) { Update-KitTaskIndex $tk { param($x) if ($x.prior) { $x.prior.claimed = @(@($x.prior.claimed) + $Branch | Where-Object { $_ } | Select-Object -Unique) } } }
    $depFrom = @($LinkFrom | Where-Object { $_ })   # before the checkout: a missing source fails first
    if (-not $depFrom.Count -and ($depFrom = @(Get-WtDepSource $Repo $Target)).Count) { "linking dependencies from $($depFrom -join ', ') (kit.local.json, target $Target)" }
    Add-WtRoot $Root
    G -C $Repo fetch -q origin $Target | Out-Null
    $remoteBranch = git -C $Repo ls-remote --heads origin "refs/heads/$Branch"   # bare name would suffix-match
    git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"
    # -B would lose unpushed commits
    if ($LASTEXITCODE -eq 0) { G -C $Repo worktree add $path $Branch | Out-Null; "local branch $Branch exists: checked out as is$(if ($remoteBranch) { " (also on origin: compare before pushing)" })" }
    elseif ($remoteBranch) { G -C $Repo fetch -q origin $Branch | Out-Null; G -C $Repo worktree add -b $Branch $path "origin/$Branch" | Out-Null; "branch $Branch on origin: checked out" }
    else { G -C $Repo worktree add -b $Branch $path "origin/$Target" | Out-Null }
    Meta $path 'target' $Target
    if ($Scope) { Meta $path 'scope' (@(Split-KitList $Scope -Sep '\s*,\s*') -join "`n"); "area:     $Scope (wt commit, devtools.py mr / merge refuse files outside)" }   # brief agents[].paths
    $depOut = @(Set-WtDeps $path $Repo $Target $depFrom)
    "worktree: $path"
    "branch:   $Branch (from origin/$Target)"
    $depOut
  }
  'sync' {
    $Dir = Resolve-Wt $Dir
    $t = Meta $Dir 'target'; if (-not $t) { throw "no target for ${Dir}: git -C $Dir rebase origin/<target>" }
    if (git -C $Dir status --porcelain --untracked-files=no) { throw "uncommitted changes in ${Dir}: crafty.ps1 wt commit -Dir $Dir -Message 'wip: <what>' (WIP is fine; never git stash), then wt sync again" }
    G -C $Dir fetch -q origin $t | Out-Null
    $head0 = (G -C $Dir rev-parse HEAD).Trim()
    git -C $Dir rebase "origin/$t"
    $why = if ($LASTEXITCODE) { Sync-Generated $Dir $t $head0 } else { '' }
    if ($why -match '^regenerated ') { $why } elseif ($why) { $why; "REBASE CONFLICT. Append-only files (changelog masters, nav/i18n lists): $(Split-Path (Get-Python) -Leaf) $($KitCmd.devtools) keepboth <file>; real code: resolve by hand. Then git add + git -C $Dir rebase --continue, and re-run crafty.ps1 check."; exit 1 }
    "rebased onto origin/$t"
  }
  'commit' {
    $Dir = Resolve-Wt $Dir
    if ($MessageFile) { if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { throw "no such message file: $MessageFile" }; $Message = Get-Content -LiteralPath $MessageFile -Raw -Encoding utf8 }
    if ($Spec) {   # commitFormat subject + change bullets; python prints UTF-8, stdout only
      if ($Message) { throw 'commit: -Spec or -Message / -MessageFile, not both' }
      $out = @(& (Get-Python) -X utf8 $KitCmd.devtools render commit $Spec 2>$null); $code = $LASTEXITCODE; $why = if ($code) { @(& (Get-Python) -X utf8 $KitCmd.devtools render commit $Spec 2>&1) -join ' ' }
      if ($code) { throw "commit spec: $why" }; $Message = ($out -join "`n").TrimEnd()
    }
    if (-not $Message -or -not $Message.Trim()) { throw "commit needs -Message '<subject>' or -MessageFile <file> (multi-line: write it to `$(crafty.ps1 dir -Agent <id> -Name commit-msg.txt) with the Write tool, then -MessageFile <that path>)" }
    # a hand-made worktree lacks .husky/_ and hook deps
    $common = (git -C $Dir rev-parse --path-format=absolute --git-common-dir).Trim()
    $cw = git --git-dir="$common" config core.worktree
    $main = if ($cw) { if ([IO.Path]::IsPathRooted($cw)) { $cw } else { Join-Path $common $cw } } else { Split-Path $common }
    if ($main -and (Test-Path (Join-Path $main '.git')) -and (Resolve-Path $main).Path -ne (Resolve-Path $Dir).Path) {
      $main = (Resolve-Path $main).Path
      $added = @(Add-DepLinks $Dir $main $null)
      Copy-HookDirs $Dir @($main)
      Exclude-Links $Dir $added
      if ($added) { "linked from ${main}: $(($added | ForEach-Object { [IO.Path]::GetRelativePath($Dir, $_) }) -join ', ')" }
    }
    $hp = (git -C $Dir config core.hooksPath)
    $c = @()
    $hpFull = if ($hp -and [IO.Path]::IsPathRooted($hp)) { $hp } elseif ($hp) { Join-Path $Dir $hp }
    if ($hp -and -not (Test-Path (Join-Path $hpFull 'pre-commit')) -and -not (Test-Path (Join-Path $hpFull 'prepare-commit-msg'))) {
      if (Test-Path (Join-Path $Dir '.husky')) { $c = @('-c', 'core.hooksPath=.husky') }
      else { Write-Warning "core.hooksPath=$hp missing here: hooks would be skipped" }
    }
    $stagePaths = @(Split-KitList $Paths)   # -Paths: a split commit stages only its group, the next group stays out
    if ($stagePaths.Count -and $NoStage) { throw 'commit: -Paths or -NoStage, not both' }
    # test-run output (reports, screenshots, videos) never blocks a commit or lands in an MR
    $skipGlobs = @(@(Get-KitSetting 'commit.ignore' @(Get-KitTestRunners | ForEach-Object { $_.ignore })) | Where-Object { $_ } | ForEach-Object { ":(exclude,glob)$_" })
    if ($stagePaths.Count) { git -C $Dir add -A -- @($stagePaths) @($skipGlobs); if ($LASTEXITCODE) { throw "commit -Paths: git add failed for $($stagePaths -join ', ')" } } elseif (-not $NoStage) { git -C $Dir add -A -- . @($skipGlobs) }
    if (($area = @(Meta $Dir 'scope' | Where-Object { $_ })).Count) {   # the branch's diff and this commit stay in the brief area
      $at = Meta $Dir 'target'; $br = (git -C $Dir rev-parse --abbrev-ref HEAD).Trim()
      $out = @(Get-KitScopeOutside @(@(if ($at) { git -C $Dir -c core.quotepath=false diff --name-only "origin/$at...HEAD" }) + @(git -C $Dir -c core.quotepath=false diff --cached --name-only) | Select-Object -Unique) $area)
      if ($out.Count -and -not ($ScopeOk -and "$(pwsh -NoProfile -File $KitCmd.orch decide check -Id $ScopeOk -Gate scope -Item $br -MaxHours 720)" -match '^WORD ')) {
        [Console]::Error.WriteLine("commit refused: $($out.Count) file(s) outside the area ($($area -join ', ')): $(($out | Select-Object -First 12) -join ', '). Revert them (a product bug in a test-only area: pin today's behaviour, decide ask); an owner-approved exception: bossy.ps1 decide record -Gate scope -Item $br ..., then -ScopeOk <id>"); exit 1
      }
    }
    # merge subjects name branches
    $isMerge = [bool](git -C $Dir rev-parse -q --verify MERGE_HEAD 2>$null)
    $pf = @(Test-KitProse -Kind $(if ($isMerge) { 'merge-commit' } else { 'commit' }) -Text $Message)
    $pf = @($pf | Where-Object { $_ -notmatch 'missing: conv' })   # subject style is commitlint's; WIP commits pass
    if ($pf.Count -and -not $ProseOk -and $Message -notmatch '^(wip|chore\(wip\))[:(]') { [Console]::Error.WriteLine("commit refused: $($pf.Count) prose finding(s): rewrite the message (same facts), or -ProseOk '<why>' for a format the brief fixes: $($pf -join '; ')"); exit 1 }   # stderr: a chained call shows it
    git -C $Dir @c commit -m $Message @(if ($AllowEmpty) { '--allow-empty' })   # a deploy MR on a branch equal to its target
    exit $LASTEXITCODE
  }
  'status' {
    $Dir = Resolve-Wt $Dir
    $t = Meta $Dir 'target'
    "branch: $((git -C $Dir rev-parse --abbrev-ref HEAD).Trim())   target: $t"
    if ($t) { git -C $Dir fetch -q origin $t 2>$null; "ahead/behind origin/${t}: $((git -C $Dir rev-list --left-right --count "HEAD...origin/$t") -replace '\s+', ' / ')" }
    git -C $Dir log --oneline -3
    git -C $Dir status --short | Select-Object -First 30
    $l = Meta $Dir 'links'; if ($l) { "linked: $($l -join ', ')" }
  }
  'remove' {
    # never cwd: may be a main tree or the live kit
    if ($Name -and -not $Dir) {
      $roots = if ($Root) { @($Root) } else { $KitConf.WorktreeRoots }
      $hits = @(foreach ($rt in $roots) { Get-ChildItem -LiteralPath $rt -Directory -ErrorAction SilentlyContinue | Where-Object { $(if ($Repo) { $_.Name -eq "$Name-$(Split-Path $Repo -Leaf)" } else { $_.Name -eq $Name -or $_.Name.StartsWith("$Name-", [StringComparison]::OrdinalIgnoreCase) }) } })
      if ($hits.Count -ne 1) { throw "wt remove -Name ${Name}: $($hits.Count) worktrees match in $($roots -join ', ')$(if ($hits) { ": $($hits.FullName -join ', ')" }); pass -Repo or -Dir" }
      $Dir = $hits[0].FullName
    }
    if (-not $Dir) { throw 'remove needs -Dir <worktree> or -Name <name from wt new>' }
    if ($Dir -match '\$\{?\w') { throw "wt remove -Dir '$Dir' holds an unexpanded variable ($($Matches[0])): expand it in the caller (double-quoted path, no single quotes or escaped `$)" }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir).TrimEnd('\', '/'); $want = $full -replace '\\', '/'   # relative: from the PowerShell location, as Resolve-Wt
    $repoDirs = @(@(if ($Repo -and (Test-Path -LiteralPath $Repo)) { (Resolve-Path -LiteralPath $Repo).Path }) + @(Get-KitRepoDirs))
    $reg = @(foreach ($rp in $repoDirs) { foreach ($w in @(Get-KitWorktrees $rp)) { if ($w.path -eq $want) { [pscustomobject]@{ repo = $rp; wt = $w } } } })[0]
    $inRoot = @(@($KitConf.WorktreeRoots) + @($Root) | Where-Object { $_ -and ([IO.Path]::GetFullPath("$_").TrimEnd('\', '/') -replace '\\', '/') -eq ((Split-Path $full) -replace '\\', '/') }).Count   # a root's direct child, never a folder inside a worktree
    # prune, then the branch when nothing is lost: lib.ps1 "sweep"
    $finish = { param($rp, $br) git -C $rp worktree prune 2>$null
      if ($br) { try { $bv = Get-KitBranchVerdict $rp $br @{} -IdleHours 0; if ($bv.delete) { git -C $rp branch -D $br 2>$null | Out-Null; "deleted branch $br ($($bv.why))" } else { "kept branch ${br}: $($bv.why)" } } catch { "kept branch ${br}: verdict failed ($($_.Exception.Message))" } } }
    if (-not (Test-Path -LiteralPath $Dir)) {   # removed already: prune + branch; unknown and outside the roots = typo
      if ($reg) { & $finish $reg.repo $reg.wt.branch; "already gone: $Dir (record pruned in $($reg.repo))"; exit 0 }
      if ($inRoot) { "already gone: $Dir (no folder, no repo lists it)"; exit 0 }
      throw "no such folder: $Dir (and no repo lists it as a worktree)"
    }
    if (-not $reg -and $inRoot -and "$(git -C $full rev-parse --path-format=absolute --show-toplevel 2>$null)".Trim() -ne $want) {   # a half-done remove: junctions + files git has
      $lv = Get-KitLeftoverVerdict $full $repoDirs
      if (-not $lv.delete) { throw "wt remove: $Dir is no worktree (no repo lists it) and holds $($lv.why): keep what you need, then delete it by hand" }
      Remove-KitLeftover $full; "removed leftover $Dir ($($lv.why))"; exit 0
    }
    $Dir = Resolve-Wt $Dir
    if (Test-KitSlotDir $Dir) { throw "$Dir is a pool slot: never deleted (its build caches stay warm); free it with wt release -Dir $Dir" }
    $br = "$(git -C $Dir rev-parse --abbrev-ref HEAD 2>$null)".Trim(); if ($br -eq 'HEAD') { $br = '' }
    $gd = (git -C $Dir rev-parse --path-format=absolute --git-dir).Trim()
    if ($gd -eq (git -C $Dir rev-parse --path-format=absolute --git-common-dir).Trim() -or $Dir -eq (Resolve-Path -LiteralPath $KitConf.Kit).Path.TrimEnd('\', '/')) { throw "$Dir is a main working tree or the running kit: wt remove only removes linked worktrees" }
    $links = @(@(@(Meta $Dir 'links') | Where-Object { $_ -and (Test-Path $_) }) + @(Get-DirLinks $Dir 4 | ForEach-Object { $_.FullName }) | Sort-Object -Unique)
    # corrupt index (bad signature 0x00000000) fails status and remove
    if ("$(git -C $Dir status --porcelain 2>&1)" -match 'index file corrupt') {
      $ix = Join-Path $gd 'index'; Move-Item -LiteralPath $ix "$ix.corrupt" -Force; git -C $Dir reset -q 2>&1 | Out-Null
      if ($LASTEXITCODE) { Move-Item -LiteralPath "$ix.corrupt" $ix -Force; throw "wt remove: $Dir has a corrupt index and git reset could not rebuild it: fix it by hand" }
      Remove-Item -LiteralPath "$ix.corrupt" -Force
      "rebuilt the corrupt index of $Dir from HEAD"
    }
    $farms = @($links | Where-Object { (Split-Path $_ -Leaf) -eq 'node_modules' -and -not (Get-Item -LiteralPath $_ -Force).LinkType })
    $links = @($links | Where-Object { $l = $_; -not @($farms | Where-Object { $l.StartsWith($_ + [IO.Path]::DirectorySeparatorChar) }).Count })
    if (-not $Force) {
      # dirty test before links go; ours don't count
      $mine = @($links | ForEach-Object { [IO.Path]::GetRelativePath($Dir, $_).Replace('\', '/') })
      $dirty = @(git -C $Dir status --porcelain | Where-Object { $_ -and ($_.Substring(3).Trim('"').TrimEnd('/') -notin $mine) })
      if ($dirty) { throw "uncommitted or untracked files in $Dir - commit/push or delete them, or pass -Force:`n$($dirty | Select-Object -First 10 | Out-String)" }
    }
    $undo = @(foreach ($l in $links) { if ($l -notin $farms) { , @($l, [string]@((Get-Item $l -Force).Target)[0]) } })
    $farmUndo = @(foreach ($f in $farms) { $m = Join-Path $f '.kit-farm.json'; if (Test-Path $m) { , @($f, ((Get-Content $m -Raw).Trim() -split '\|')) } })
    foreach ($l in $links) { if (Test-Path $l) { if ((Split-Path $l -Leaf) -eq 'node_modules' -or -not (Get-Item -LiteralPath $l -Force).LinkType) { Remove-NodeModules $l } else { Remove-DirLink $l } } }
    $main = ((git -C $Dir worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', '')
    $gitSaid = @(git -C $main worktree remove $(if ($Force) { '--force' }) $Dir 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -and @(git -C $main worktree list --porcelain 2>$null) -contains "worktree $want") {
      foreach ($u in $undo) { if ($u[1] -and -not (Test-Path $u[0])) { New-DirLink $u[0] $u[1] } }
      foreach ($u in $farmUndo) { $src = $u[1][0]; $wtr = $u[1][1]; $null = Set-NodeModules $u[0] $src (git -C $Dir rev-parse --path-format=absolute --git-common-dir | Split-Path) $wtr }
      throw "git worktree remove failed for $Dir (links restored): $(($gitSaid | Where-Object { $_.Trim() }) -join ' ' -replace '\s+', ' '); fix that, or -Force"
    }
    # record gone, folder kept by a locked file: no links back into it
    if (Test-Path -LiteralPath $full) { $lv = Get-KitLeftoverVerdict $full $repoDirs; if (-not $lv.delete) { "left $Dir in place: $($lv.why)" } else { try { Remove-KitLeftover $full } catch { "left $Dir in place: $($_.Exception.Message)" } } }
    & $finish $main $br
    "removed $Dir"
  }
  'list' { git -C $(if ($Repo) { $Repo } else { (Get-Location).Path }) worktree list }
  'sweep' { $r = Invoke-KitSweep @(if ($Root) { Split-KitList $Root } else { $KitConf.WorktreeRoots }) $IdleHours -DryRun:$DryRun
    if ($Json) { $r | ConvertTo-Json -Depth 4 -Compress } else { $r.actions | ForEach-Object { "$(if ($DryRun) { 'would go' } else { 'gone' }): $($_.path)" }; $r.kept | ForEach-Object { "kept: $_" }; $r.notes } }
  'lease' { Invoke-WtLease }   # adapters/wt_pool.ps1
  'release' { Invoke-WtRelease }
  'pool' { Invoke-WtPool }
}
}

# ---- stack: nearest marker file up to the git root; .claude-stack.json overrides
function Invoke-Stack {
param([string]$Dir = (Get-Location).Path, [switch]$Json)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
if (Test-Path -LiteralPath $Dir -PathType Leaf) { $Dir = Split-Path $Dir }
function Wrapper($d, $name, $winExt, $fallback) {
  if ($KitIsWindows) { if (Test-Path (Join-Path $d "$name.$winExt")) { return ".\$name.$winExt" } }
  elseif (Test-Path (Join-Path $d $name)) { return "./$name" }
  $fallback
}

function Has($d, [string[]]$pattern) { foreach ($p in $pattern) { if (Get-ChildItem -LiteralPath $d -Filter $p -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true } }; $false }
function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
function ReadText($f) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue } else { '' } }
function Get-NodePm($d) {
  $top = (git -C $d rev-parse --show-toplevel 2>$null); if ($top) { $top = (Resolve-Path $top).Path }
  $x = $d
  while ($x) {
    if (Test-Path (Join-Path $x 'pnpm-lock.yaml')) { return 'pnpm' }
    if (Test-Path (Join-Path $x 'yarn.lock')) { return 'yarn' }
    if ((Test-Path (Join-Path $x 'bun.lockb')) -or (Test-Path (Join-Path $x 'bun.lock'))) { return 'bun' }
    if ((Test-Path (Join-Path $x 'package-lock.json')) -or -not $top -or $x -eq $top) { break }
    $p = Split-Path $x; if (-not $p -or $p -eq $x) { break }; $x = $p
  }
  'npm'
}
function NodeRun($pm, $script, $argText) {
  $a = if ($argText) { " $argText" } else { '' }
  switch ($pm) { 'npm' { "npm $(if ($script -ne 'test') { 'run ' })$script$(if ($a) { ' --' + $a })" } 'yarn' { "yarn $script$a" } default { "$pm run $script$a" } }
}
# a references-only tsconfig.json type-checks nothing
function TsProject($d) {
  $t = ReadText (Join-Path $d 'tsconfig.json')
  if ((Test-Path (Join-Path $d 'tsconfig.app.json')) -and $t -match '"references"\s*:\s*\[\s*\{' -and $t -match '"files"\s*:\s*\[\s*\]') { return 'tsconfig.app.json' }
  $null
}

# tests.fallbackRunner: a TS project with no test runner; unset / 'none' = no test step, 'spec' = the kit's spec.mjs (opt-in), else a command with {tests}
function NodeSpecCmd { $f = "$(Get-KitSetting 'tests.fallbackRunner' '')".Trim(); if (-not $f -or $f -eq 'none') { $null } elseif ($f -eq 'spec') { "node `"$($KitCmd.spec)`" {tests}" } else { $f } }

function Get-NodeTools($d) {
  $pkg = ReadJson (Join-Path $d 'package.json')
  $deps = @()
  foreach ($k in 'dependencies', 'devDependencies') { if ((Get-KitMember $pkg $k)) { $deps += (Get-KitProps (Get-KitMember $pkg $k)).Name } }
  $scripts = if ($pkg.scripts) { (Get-KitProps $pkg.scripts).Name } else { @() }
  $jestCfg = @('jest-unit.config.json', 'jest.config.js', 'jest.config.ts', 'jest.config.json', 'jest.config.cjs', 'jest.config.mjs') | Where-Object { Test-Path (Join-Path $d $_) } | Select-Object -First 1
  [pscustomobject]@{
    Deps = $deps; Scripts = $scripts
    Ts = Test-Path (Join-Path $d 'tsconfig.json')
    Jest = ($deps -contains 'jest') -or [bool]$jestCfg
    JestCfg = $jestCfg
    Vitest = $deps -contains 'vitest'
    Eslint = ($deps -contains 'eslint') -or (Has $d 'eslint.config.*', '.eslintrc*')
    # check -Step e2e fills {specs}
    E2e = (@(Get-KitTestRunners | Where-Object { @(@($_.deps) | Where-Object { $_ -and $deps -contains $_ }).Count -or (@($_.files).Count -and (Has $d @($_.files))) })[0]).cmd
  }
}

function Get-Stack($d) {
  $c = [ordered]@{ compile = $null; typecheck = $null; lint = $null; test = $null; e2e = $null; build = $null; format = $null; run = $null }
  $s = $null; $deps = @()

  # adapters/stack_presets.ps1: core always first, then the others stack.presets names (unset = all)
  $on = Get-KitSetting 'stack.presets' $null; $raw = $__cfg.stack -and (Get-KitProps $__cfg.stack).Name -contains 'presets'
  $det = @{ dir = $d; commands = $c; deps = @() }
  $order = @(@($KitAdapters.stack.core) + @(@(if ($KitAdapters.stack) { $KitAdapters.stack.GetEnumerator() }) | Where-Object { $_.Key -ne 'core' -and $_.Value -and (-not $raw -or @($on) -contains $_.Key) } | ForEach-Object Value)) | Where-Object { $_ }
  foreach ($plugin in $order) { if (-not $s) { $s = & $plugin.detect $det } }
  $deps = @($det.deps)
  $ovr = ReadJson (Join-Path $d '.claude-stack.json')
  if (-not $s -and -not $ovr.stack -and ((Has $d 'build.gradle', 'build.gradle.kts', 'settings.gradle*') -or (Has $d '*.sln', '*.csproj', '*.fsproj', 'go.mod', 'Cargo.toml', 'CMakeLists.txt', 'Makefile'))) { throw "stack: no preset detects $d (a .claude-stack.json sets one; README ""Adapters"")" }
  if (-not $s -and -not $ovr.stack) { return $null }   # an override's stack alone counts

  if ($ovr) {
    if ($ovr.stack) { $s = $ovr.stack }
    if ($ovr.commands) { foreach ($p in (Get-KitProps $ovr.commands)) { $c[$p.Name] = $p.Value } }
    if ($ovr.deps) { $deps = @($ovr.deps) }
  }
  [pscustomobject]@{ stack = $s; dir = $d; deps = $deps; commands = [pscustomobject]$c }
}

$top = (git -C $Dir rev-parse --show-toplevel 2>$null)
if ($top) { $top = (Resolve-Path $top).Path }
$d = $Dir; $hit = $null
while ($d) {
  $hit = Get-Stack $d
  if ($hit -or -not $top -or $d -eq $top) { break }
  $parent = Split-Path $d
  if (-not $parent -or $parent -eq $d) { break }
  $d = $parent
}
if (-not $hit) { throw "No known stack under $Dir (up to the git root): add a .claude-stack.json" }
if ($Json) { $hit | ConvertTo-Json -Depth 4 }
else {
  "stack: $($hit.stack)   dir: $($hit.dir)"
  (Get-KitProps $hit.commands) | Where-Object Value | ForEach-Object { '  {0,-9} {1}' -f $_.Name, $_.Value }
}
}

# ---- gate: machine-wide memory gate; exit = command's code, 3 = no start in time or a PAUSE
# the open pause of a live board agent (by name or worktree holding $Dir) in a paused or listed run
function Get-KitPauseFor([string]$Agent, [string]$Dir) {
  $ps = @(Read-KitJsonFiles (Get-KitPath pauses) | Where-Object { $_.state -ne 'resumed' }); if (-not $ps.Count) { return }
  $full = try { [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/') } catch { '' }
  $me = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and ($_.agent -eq $Agent -or ($full -and @($_.worktrees | Where-Object { "$_" -match '[\\/]' -and $full.StartsWith("$_".TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) }).Count)) })[0]
  if (-not $me) { return }
  @($ps | Where-Object { ($me.run -and ($_.run -eq $me.run -or ($_.run -eq '*' -and $me.run -notin @($_.released)))) -or $me.agent -in @($_.agents.agent) })[0]
}
# kind: command regex; its starting GB until 2 runs are learned: params.registry.json gate.kindGB.<kind> (other: gate.kindGB.other)
$script:GateKinds = [ordered]@{
  'emulator' = '^exit 0 #emulator'
  'android-build' = 'gradlew.*\b(assemble|bundle)'
  'android-test' = 'gradlew.*\btest|connectedAndroidTest|lintDebug'
  'gradle' = 'gradle(w|w\.bat)?\b'
  'rn-bundle' = 'export:embed|react-native bundle|expo export'
  'typecheck' = "^\s*((npx|yarn|pnpm)\s+(exec\s+)?)?(vue-)?tsc\b[^&|;]*$([regex]::Escape($script:TscNoOutput))"   # before e2e: tsc -p cypress/tsconfig.json is no e2e run
  'cypress' = 'cypress'   # 3.5 GB runner + its browser
  'e2e' = 'playwright|\b(npm|yarn|pnpm|bun)\s+(run\s+)?e2e\b'
  'docker' = '\bdocker(\.exe)?"?\s+(compose\s+(-\S+(\s+(?!-)\S+)?\s+)*)?(build|run|up|buildx\s+build)\b|\bdocker-compose(\.exe)?\s+(-\S+(\s+(?!-)\S+)?\s+)*(build|run|up)\b'
  'ng-test' = '\bng test\b|\bkarma\b'
  'web-build' = 'ng build|next build|vite build|webpack|npm run build|yarn build|pnpm (run )?build|bun run build'
  'maven-test' = '^(?!.*-D(skipTests|maven\.test\.skip)\b).*\b(mvn|mvnd|mvnw(\.cmd)?)\b.*\b(test|verify|package|install)\b'
  'maven' = '\b(mvn|mvnd|mvnw(\.cmd)?)\b'
  'dotnet' = 'msbuild|dotnet (build|test|publish)'
  'rust' = 'cargo (build|test|clippy|check)'
  'native' = 'cmake --build|\bmake\b'
  'js-test' = 'jest|vitest'
  'tsc-lint' = '\btsc\b|eslint'
  'local-ai' = 'video\.py"? transcribe\b'   # pokey.ps1 evidence: -NeedGB = the STT server's RAM
  'python' = 'pytest|mypy|ruff|compileall|-m unittest\b|\btest_\w*\.py\b'
  'go' = 'go (build|test|vet)'
}
function Get-GateKind([string]$c, [string]$Dir = '') {
  # a package script is its body
  $sb = if ($Dir -and $c -match '^\s*(npm|yarn|pnpm|bun)\s+(run\s+)?([\w:.-]+)') { try { "$((Read-KitText (Join-Path $Dir 'package.json') | ConvertFrom-Json -AsHashtable).scripts[$Matches[3]])" } catch { '' } }
  if ($sb -match 'cypress\s+run') { return 'cypress' }
  foreach ($t in @($c, $sb) | Where-Object { $_ }) { foreach ($k in $script:GateKinds.Keys) { if ($t -match $script:GateKinds[$k]) { return $k } } }; 'other'
}
# testcontainers in the module's build files: the run starts containers whose RAM sits outside its process tree
function Test-GateContainers([string]$Dir) {
  $fs = @(@(@('build.gradle', 'build.gradle.kts', 'gradle/libs.versions.toml', 'pyproject.toml', 'requirements.txt', 'requirements-dev.txt', 'package.json') | ForEach-Object { Join-Path $Dir $_ } | Where-Object { Test-Path -LiteralPath $_ }) +
    @(Get-ChildItem -LiteralPath $Dir -Filter pom.xml -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | ForEach-Object FullName))   # a parent pom: its modules' poms
  $fs.Count -gt 0 -and @(Select-String -LiteralPath $fs -SimpleMatch 'testcontainers' -List -ErrorAction SilentlyContinue).Count -gt 0
}
# RAM of running containers (docker stats); $null when the engine is down
function Get-GateContainerGB {
  $r = Invoke-KitExe 'docker' @('stats', '--no-stream', '--format', '{{.MemUsage}}') 15
  if ($r.code -ne 0) { return $null }
  $u = @{ B = 1; KIB = 1KB; MIB = 1MB; GIB = 1GB; KB = 1e3; MB = 1e6; GB = 1e9 }
  $sum = 0.0; foreach ($l in @("$($r.out)" -split '\r?\n')) { if ($l -match '^\s*([\d.]+)\s*([KMG]i?B|B)\b') { $sum += [double]$Matches[1] * $u[$Matches[2].ToUpper()] } }
  $sum / 1GB
}
# relative: worktree paths differ per agent
function Get-GateHistCmd([string]$Cmd, [string]$Dir) {
  $c = $Cmd; foreach ($d in @([IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')) | ForEach-Object { $_; $_.Replace('\', '/') } | Select-Object -Unique) { $c = [regex]::Replace($c, [regex]::Escape($d) + '(?=[\\/\s"'']|$)', '.', 'IgnoreCase') }
  if ($c.Length -gt 120) { $c.Substring(0, 120) } else { $c }
}
function Get-KitKeepFreeGB {
  if ($env:CLAUDE_GATE_KEEP_FREE_GB) { return [double]$env:CLAUDE_GATE_KEEP_FREE_GB }
  [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15))))
}
function Add-KitMemSample([double]$Free) { try { $f = Get-KitPath mem-samples -Create; if (-not (Test-Path $f) -or ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -ge 60) { Add-Content $f "$((Get-Date).ToString('s'))`t$([math]::Round($Free, 1))" } } catch {} }
function Invoke-Gate {
param(
  [Parameter(Mandatory)][string]$Cmd,
  [string]$Dir = (Get-Location).Path,
  [int]$WaitMinutes = -1,   # -1 = learned gate.waitMinutes (90); 0 = no wait
  [double]$KeepFreeGB = -1,   # -1 = Get-KitKeepFreeGB
  [double]$NeedGB = 0,
  [int]$MaxParallel = 0,
  [string]$Log   # the command's output goes there; the gate prints its digest (Write-KitRunDigest), not the whole log
)
$waitLearned = $WaitMinutes -lt 0; if ($waitLearned) { $WaitMinutes = Get-KitParam 'gate.waitMinutes' }
$keepFromConfig = $KeepFreeGB -lt 0   # re-read each round for queued builds
if ($keepFromConfig) { $KeepFreeGB = Get-KitKeepFreeGB }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# cmd.exe has no ';'
function ConvertTo-CmdSeparators([string]$c) {
  $sb = [Text.StringBuilder]::new(); $inQ = $false
  for ($i = 0; $i -lt $c.Length; $i++) {
    $ch = $c[$i]
    if ($ch -eq [char]34) { $inQ = -not $inQ; [void]$sb.Append($ch); continue }
    if (-not $inQ -and $ch -eq [char]59 -and ($i + 1 -ge $c.Length -or [char]::IsWhiteSpace($c[$i + 1]))) {
      while ($i + 1 -lt $c.Length -and [char]::IsWhiteSpace($c[$i + 1])) { $i++ }
      $head = $sb.ToString().TrimEnd(); [void]$sb.Clear().Append($head)
      if ($i + 1 -lt $c.Length -and $head) { [void]$sb.Append(' & ') }
      continue
    }
    [void]$sb.Append($ch)
  }
  $sb.ToString()
}
# whole e2e suite only with -AllTests (KIT_E2E_ALL)
if (@(Get-KitTestRunners | Where-Object { $_.wholeSuiteRx -and $Cmd -match $_.wholeSuiteRx }).Count -and $env:KIT_E2E_ALL -ne '1') { Write-Host "[gate] refused: $Cmd runs the whole e2e suite: use crafty.ps1 check -Dir <module> -Step e2e (the diff's specs; whole suite: -AllTests on the owner's word)"; exit 2 }
if ($KitIsWindows) { $semi = ConvertTo-CmdSeparators $Cmd; if ($semi -ne $Cmd) { Write-Host "[gate] cmd.exe has no ';': running $semi"; $Cmd = $semi } }

# NoDefaultCurrentDirectoryInExePath hides bare names in cwd
$Cmd = [regex]::Replace($Cmd, '(^|&&\s*|&\s*|\|\|\s*)(?<!\.[\\/])(gradlew(\.bat)?|mvnw(\.cmd)?)(?=\s|$)', $(if ($KitIsWindows) { '$1.\$2' } else { '$1./$2' }))
# mvnd on PATH: a warm JVM
if ($Cmd -match '^(\.[\\/]mvnw(\.cmd)?|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $Cmd = $Cmd -replace '^(\.[\\/]mvnw(\.cmd)?|mvn)\s', 'mvnd ' }
# runners fork a worker per core; the flag right after the runner (at the end a compound command's next tool gets it)
$wk = { param($rx) if ($Cmd -match $rx) { ([regex]$rx).Replace($Cmd, '$0 --maxWorkers=2', 1) } else { "$Cmd --maxWorkers=2" } }   # no runner word (yarn test): the end
if ($Cmd -match '\bjest\b' -and $Cmd -notmatch 'maxWorkers|runInBand|\s-i(\s|$)') { $Cmd = & $wk '(?<![\w./-])jest(?=\s|$)' }
if ($Cmd -match '\bvitest\b' -and $Cmd -notmatch 'maxWorkers|maxThreads') { $Cmd = & $wk '(?<![\w./-])vitest(\s+(run|watch))?(?=\s|$)' }
if ($Cmd -match '\bpytest\b' -and $Cmd -match '\s-n\s+auto') { $Cmd = $Cmd -replace '\s-n\s+auto', ' -n 2' }

$ledger = Get-KitGateLedger
New-Item -ItemType Directory -Force $ledger | Out-Null
$histFile = Join-Path $ledger 'history.json'
function Read-History { $h = try { Read-KitText $histFile | ConvertFrom-Json -AsHashtable } catch {}; if ($h) { $h } else { @{} } }

$kind = Get-GateKind $Cmd $Dir
$default = [double](Get-KitParam "gate.kindGB.$(if ($script:GateKinds.Contains($kind)) { $kind } else { 'other' })")
# containers: learned peaks (docker stats growth) hold RAM; until then +2 GB (a DB + a search engine)
$ctr = $kind -eq 'docker' -or (($kind -match 'test|cypress|e2e|dotnet|^go$' -or ($kind -eq 'python' -and $Cmd -match 'pytest|unittest|\btest_')) -and (Test-GateContainers $Dir))
if ($ctr -and $kind -ne 'docker') { $default += 2 }
$project = Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf
$top = (git -C $Dir rev-parse --show-toplevel 2>$null)
if ($top) {
  $main = ((git -C $Dir worktree list --porcelain 2>$null | Select-Object -First 1) -replace '^worktree\s+', '')
  $repoName = if ($main) { Split-Path $main -Leaf } else { Split-Path $top -Leaf }
  $rel = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($top), [IO.Path]::GetFullPath($Dir)).Replace([char]92, [char]47)
  $project = if ($rel -eq '.') { $repoName } else { "$repoName/$rel" }
}

$histKey = "$kind|$project"
$hist = Read-History
$samples = @($hist[$histKey] | Where-Object { $_ })
if ($kind -eq 'cypress' -and $samples.Count -lt 2) { $samples = @($samples) + @($hist["e2e|$project"] | Where-Object { $_ -and "$($_.cmd)" -match 'cypress' }) }   # learned before the cypress kind split from e2e
$peaks = @($samples | ForEach-Object { [double]$_.gb })
$secs = @($samples | ForEach-Object { [double]$_.sec } | Sort-Object)
# small builds may backfill past a starving head
function Get-MedianSec([double[]]$Secs) { $s = @($Secs | Sort-Object); if ($s.Count -lt 2) { return -1 }; $s[[int][math]::Floor($s.Count / 2)] }
function Test-SmallBuild([double]$Need, [double]$MedianSec) { $MedianSec -ge 0 -and $MedianSec -le 120 -and $Need -le 2 }
$kindSecs = if ($secs.Count -ge 2) { $secs } else { @($hist.Keys | Where-Object { $_ -like "$kind|*" } | ForEach-Object { @($hist[$_]) | Where-Object { $_ -and $null -ne $_.sec } | ForEach-Object { [double]$_.sec } }) }
$medianSec = Get-MedianSec $kindSecs
function Get-NeedEstimate([double]$Default, [double[]]$Peaks, [double]$TotalGB) {
  if (@($Peaks).Count -lt 2) { return $Default }
  $recentMax = (@($Peaks) | Select-Object -Last 5 | Measure-Object -Maximum).Maximum
  [math]::Round([math]::Min($TotalGB * 0.6, [math]::Max(0.75, $recentMax * 1.15)), 1)
}
$estimate = Get-NeedEstimate $default $peaks (Get-SysMem).TotalGB   # default of learned gate.needGB per kind|project
$need = if ($NeedGB -gt 0) { $NeedGB } else { [math]::Min((Get-SysMem).TotalGB * 0.6, [double](Get-KitParam 'gate.needGB' $estimate $histKey)) }

# adapters/build_heap.ps1: heap cap from learned peak, floor under pressure
$heap = 0; $heapFloor = 0; $heapTool = $null
if (($hp = Get-Command Get-GateHeap -ErrorAction SilentlyContinue) -and ($h = & $hp $kind $peaks $NeedGB $need)) { $heap = $h.heap; $heapFloor = $h.floor; $need = $h.need; $heapTool = $h.tool }

$ownerRoot = if ($top) { Split-Path $top -Leaf } else { Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf }
$owner = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { Get-KitBuildOwner $ownerRoot $(if ($top) { $repoName } else { '' }) $top }
Show-KitGateInbox $owner
$heapBase = $heap
$queueDir = Join-Path $ledger 'queue'; New-Item -ItemType Directory -Force $queueDir | Out-Null
$myTicket = Join-Path $queueDir "$PID.json"
$gtk = Get-GateTicket $kind $Cmd $medianSec
$myStart = Get-KitPidStart $PID
function Write-Ticket { Write-KitAtomic $myTicket (@{ pid = $PID; start = $myStart; owner = $owner; kind = $kind; need = $need; dir = $Dir } + $gtk | ConvertTo-Json -Compress) }
function Get-Queue {
  $q = foreach ($f in Get-ChildItem $queueDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $t = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not (Test-KitPid $t.pid $t.start)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }   # gone, or a pid reused after a reboot
    $t
  }
  $cut = (Get-Date).AddMinutes(-30); $recent = @{}
  foreach ($x in @(Read-KitLog builds $cut | Where-Object event -eq 'start')) { $recent[$x.owner] = 1 + [int]$recent[$x.owner] }
  Get-GateOrder @($q) $recent (Get-Date)
}

function Get-State {
  $Snap = Get-KitProcSnap

  $promised = 0; $running = 0; $backfills = 0
  foreach ($f in Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json') {
    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $Snap.procs.ContainsKey([int]$e.pid) -or -not (Test-KitPid $e.pid $e.start)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $running++
    if ($e.backfill) { $backfills++ }
    $promised += [math]::Max(0.0, [double]$e.need - (Get-KitTreeGB ([int]$e.pid) $Snap))
  }
  $mem = Get-SysMem
  [pscustomobject]@{ Avail = (Get-GateAvailGB $mem); Total = $mem.TotalGB; Promised = [math]::Round($promised, 1); Running = $running; Backfills = $backfills; Snap = $Snap }
}
# head waited 20+ min: one small build at a time
function Get-BackfillMode([double]$HeadNeed, [double]$HeadWaitedMin, [double]$Need, [double]$Room, [bool]$Small, [int]$SmallRunning) {
  if ($HeadNeed -le $Room -or $Need -gt $Room) { return '' }
  if ($HeadWaitedMin -lt 20) { return 'backfill' }
  if ($Small -and $SmallRunning -eq 0) { return 'small' }
  ''
}
function Top-Users($Snap) {
  ($Snap.names.GetEnumerator() | Group-Object Value | ForEach-Object { [pscustomobject]@{ n = $_.Name; gb = (($_.Group | ForEach-Object { $Snap.procs[$_.Key] }) | Measure-Object -Sum).Sum / 1GB } } |
    Sort-Object gb -Descending | Select-Object -First 5 | ForEach-Object { '{0} {1:N1} GB' -f $_.n, $_.gb }) -join ', '
}

$gate = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate')
$deadline = (Get-Date).AddMinutes($WaitMinutes); $queuedAt = Get-Date
$learned = if ($NeedGB -le 0 -and $peaks.Count -ge 2) { " (learned from $($peaks.Count) runs)" } else { '' }
$usual = if ($secs.Count -ge 2) { " usually ~$([math]::Ceiling((Get-MedianSec $secs) / 60)) min," } else { '' }
Write-Host "[gate] $kind needs ~$need GB$learned,$usual keep $KeepFreeGB GB free: $Cmd"
$proc = $null; $entry = $null; $waits = 0
Write-Ticket
try {
while ((Get-Date) -lt $deadline) {
  if (($pz = Get-KitPauseFor $owner $Dir)) { Write-Host "[gate] PAUSE ($($pz.reason)): not started; this step is not done: checkpoint -Next 'redo: <this step>' and leave (board beat says how)"; exit 3 }
  $got = Lock-Gate $gate
  if (-not $got) { continue }
  try {
    $s = Get-State
    if ($keepFromConfig) { $KeepFreeGB = Get-KitKeepFreeGB }
    $queue = Get-Queue
    if ($heapBase -gt 0 -and $NeedGB -le 0 -and $queue.Count -ge 2) {
      $share = [math]::Floor(($s.Avail - $s.Promised - $KeepFreeGB) / $queue.Count - 0.5)
      $h2 = [math]::Min($heapBase, [math]::Max($heapFloor, $share))
      if ($h2 -ne $heap) {
        Write-Host "[gate] $($queue.Count) builds queued, ~$share GB each: heap $heap GB -> $h2 GB (floor $heapFloor, ceiling $heapBase)"
        if ($peaks.Count -lt 2) { $need = $h2 + 0.5 }; $heap = $h2; Write-Ticket
      }
    }
    $left = $s.Avail - $s.Promised - $need
    $pos = [array]::IndexOf(@($queue | ForEach-Object { [int]$_.pid }), [int]$PID)
    $head = if ($queue.Count) { $queue[0] } else { $null }
    $myTurn = ($pos -le 0); $smallFill = $false
    if (-not $myTurn -and $head) {
      $room = $s.Avail - $s.Promised - $KeepFreeGB
      $headWaited = ((Get-Date) - [datetime]$head.since).TotalMinutes
      $mode = Get-BackfillMode ([double]$head.need) $headWaited $need $room (Test-SmallBuild $need $medianSec) $s.Backfills
      if ($mode -eq 'backfill') { $myTurn = $true; Write-Host "[gate] backfilling ahead of $($head.owner) (its $($head.need) GB doesn't fit yet)" }
      elseif ($mode -eq 'small') { $myTurn = $true; $smallFill = $true; Write-Host "[gate] small build (~$([int]$medianSec) s, $need GB) backfilling ahead of $($head.owner) (waited $([int]$headWaited) min, needs $($head.need) GB)" }
    }
    if (-not $myTurn) {
      $waits++; Add-KitMemSample $s.Avail
      if ($waits % 3 -eq 1) { Write-Host "[gate] queued #$($pos + 1) of $($queue.Count) (owner $owner); next: $($head.owner) $($head.kind); ~$(Get-GateAhead $queue $pos) min ahead" }
    }
    else {
    if ($heap -gt 0 -and $left -lt $KeepFreeGB -and $NeedGB -le 0) {
      $room = [math]::Floor($s.Avail - $s.Promised - $KeepFreeGB - 0.5)
      if ($room -ge $heapFloor -and $room -lt $heap) {
        Write-Host "[gate] memory tight: heap $heap GB -> $room GB"
        $need = [math]::Max($heapFloor + 0.5, [math]::Min($need, $room + 0.5)); $heap = $room
        $left = $s.Avail - $s.Promised - $need
      }
    }
    $dh = Get-KitDiskHold
    if (-not $dh -and (Test-GateStart $left $KeepFreeGB ((Get-Date) - [datetime]$gtk.since).TotalMinutes $s.Total) -and (($MaxParallel -le 0) -or ($s.Running -lt $MaxParallel))) {
      if ($heap -gt 0) { $Cmd = & (Get-Command Set-GateHeap) $heapTool $heap $Cmd }
      $reserved = $need   # an OOM near this = failure
      Write-Host "[gate] starting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> ~$([math]::Round($left,1)) GB left$(if ($heap -gt 0) { "; heap cap $heap GB" }); queued $([int]((Get-Date) - [datetime]$gtk.since).TotalSeconds) s"   # usage.ps1 Step-KitUsageTime: the queue = waiting
      if ($gt = Get-Command Set-GateTemp -ErrorAction SilentlyContinue) { & $gt $Cmd $Dir }
      # /s + outer quotes: a leading quoted path survives; -Log wraps only what runs (history and ledger keep the command)
      $runCmd = if ($Log) { "($Cmd) > `"$Log`" 2>&1" } else { $Cmd }
      if ($KitIsWindows) { $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/s', '/c', "`"$runCmd`"" -WorkingDirectory $Dir -NoNewWindow -PassThru }
      else {
        $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($runCmd)
        $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
      }
      Remove-Item $myTicket -ErrorAction SilentlyContinue; $waitSec = [int]((Get-Date) - $queuedAt).TotalSeconds
      Write-KitLog builds start ([ordered]@{ owner = $owner; kind = $kind; project = $project; needGB = $need; waitSec = $waitSec; availGB = $s.Avail; running = $s.Running })
      $entry = Join-Path $ledger "$($proc.Id).json"
      Write-KitAtomic $entry (@{ pid = $proc.Id; start = (Get-KitPidStart $proc.Id); gate = $PID; owner = $owner; need = $need; kind = $kind; cmd = $Cmd; dir = $Dir; started = (Get-Date).ToString('o'); backfill = $smallFill } | ConvertTo-Json)
      $buildLease = @{ agent = $owner; at = (Get-Date).ToString('o') }; Write-KitLeaseLog acquire build "$kind $(Split-Path $Dir -Leaf)" $buildLease
      break
    }
    $waits++; Add-KitMemSample $s.Avail
    $msg = "[gate] waiting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> would leave $([math]::Round($left,1)) GB (< $KeepFreeGB)"
    if ($dh) { $msg = "[gate] waiting: disk hold since $(([datetime]$dh.at).ToString('HH:mm')) ($($dh.reason)); bossy.ps1 storage -Drive $($dh.drive)" }
    if ($waits % 15 -eq 1) { $msg += ". Biggest users: $(Top-Users $s.Snap)" }
    Write-Host $msg
    }
  } finally { $gate.ReleaseMutex() }
  Start-Sleep -Seconds 20
}
} finally { Remove-Item $myTicket -ErrorAction SilentlyContinue }
if (-not $proc) { if ($waitLearned) { Add-KitParamObs 'gate.waitMinutes' $WaitMinutes '' 'timeout' 90 }; Write-Host "[gate] could not start within $WaitMinutes min"; exit 3 }
$sw = [Diagnostics.Stopwatch]::StartNew(); $peak = 0.0   # double: Max(int, double) would truncate
$c0 = if ($ctr) { Get-GateContainerGB }; $ctrPeak = 0.0; $tick = 0
try {
  $null = $proc.Handle   # keeps ExitCode readable
  $gateMaxHours = [double](Get-KitParam 'gate.maxHours')
  while (-not $proc.HasExited -and $sw.Elapsed.TotalHours -lt $gateMaxHours) {
    $peak = [math]::Max($peak, (Get-KitTreeGB $proc.Id))
    if ($null -ne $c0 -and ($tick++ % 3) -eq 2 -and $null -ne ($cn = Get-GateContainerGB)) { $ctrPeak = [math]::Max($ctrPeak, $cn - $c0) }
    Start-Sleep -Seconds 5
  }
  $proc.WaitForExit(); $code = $proc.ExitCode
  if ($null -ne $c0 -and $null -ne ($cn = Get-GateContainerGB)) { $ctrPeak = [math]::Max($ctrPeak, $cn - $c0) }   # compose up -d: its containers outlive the command
  $peak += $ctrPeak
} finally {
  $why = try { "$((Get-Content $entry -Raw | ConvertFrom-Json).reclaimed)" } catch { '' }   # supervise -AutoFix marks the build it stops
  Remove-Item $entry -ErrorAction SilentlyContinue; Write-KitLeaseLog release build "$kind $(Split-Path $Dir -Leaf)" $buildLease $(if ($why) { $why } else { "ended, exit $code" })
}
if ($why) { Write-Host "[gate] stopped by the kit: $why (exit $code)" }   # a killed build teaches neither time nor peak
if ($kind -ne 'emulator' -and -not $why) { Add-KitParamObs 'gate.waitMinutes' $sw.Elapsed.TotalMinutes -Default 90 }   # learns build time, not wait time
Write-KitLog builds end ([ordered]@{ owner = $owner; kind = $kind; project = $project; code = $code; sec = [int]$sw.Elapsed.TotalSeconds; peakGB = [math]::Round($peak, 2); ctrGB = [math]::Round($ctrPeak, 2); waitSec = $waitSec })
if ($peak -gt 0.2 -and $kind -ne 'emulator' -and -not $why) {
  # oom: exit 137 / 134 near its reservation
  if ($NeedGB -le 0) { Add-KitParamObs 'gate.needGB' $peak $histKey $(if ($code -eq 0) { 'ok' } elseif ($code -in 134, 137 -and $peak -ge 0.9 * $reserved) { 'oom' } else { 'fail' }) $estimate }
  # concurrent ends; never reset an unreadable file
  $got = $false
  try {
    $got = Lock-Gate $gate
    if ($got) {
      $txt = if (Test-Path $histFile) { Read-KitText $histFile } else { '' }
      $h = if ("$txt".Trim()) { $txt | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { @{} }
      if ($h -is [hashtable]) {
        $h[$histKey] = @(@($h[$histKey] | Where-Object { $_ }) + @{ gb = [math]::Round($peak, 2); sec = [int]$sw.Elapsed.TotalSeconds; ok = ($code -eq 0); at = (Get-Date).ToString('o'); code = $code; wait = $waitSec; ctr = [math]::Round($ctrPeak, 2); cmd = (Get-GateHistCmd $Cmd $Dir) } | Select-Object -Last 10)
        $h | ConvertTo-Json -Depth 3 | Set-Content "$histFile.tmp" -ErrorAction Stop
        Move-Item "$histFile.tmp" $histFile -Force -ErrorAction Stop
      }
    }
  } catch {} finally { if ($got) { $gate.ReleaseMutex() } }
}
if ($Log) { Write-KitRunDigest $Log $code }
exit $code
}
# a gated run's log -> what an agent reads (owner 2026-11-22: 60 agents pasted whole build / test logs): a short log whole; else the
# failure lines (+ the next 2 lines each) up to check.printLines, the last 10 lines (the summary), the log path
function Write-KitRunDigest([string]$Path, [int]$Code) {
  $ls = @(try { Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop } catch { })
  $cap = [int](Get-KitParam 'check.printLines')
  if ($ls.Count -le $cap) { foreach ($l in $ls) { Write-Host $l }; return }
  $tail = 10; $keep = [Collections.Generic.SortedSet[int]]::new()
  if ($Code) {
    $rx = '(?i)\b(error|errors|fail(ed|ure|ures|ing)?|exception|assert\w*|traceback|panic|fatal|expected|not ok)\b|^\s*[✗×✖]|(?-i:^E\s)'
    for ($i = 0; $i -lt $ls.Count - $tail -and $keep.Count -lt $cap - $tail; $i++) { if ($ls[$i] -match $rx) { for ($j = $i; $j -le [math]::Min($i + 2, $ls.Count - $tail - 1); $j++) { $null = $keep.Add($j) } } }
  }
  $prev = -1; foreach ($i in $keep) { if ($prev -ge 0 -and $i -gt $prev + 1) { Write-Host '  ...' }; Write-Host $ls[$i]; $prev = $i }
  if ($keep.Count) { Write-Host '  ...' }
  foreach ($l in @($ls | Select-Object -Last $tail)) { Write-Host $l }
  Write-Host "[gate] $($ls.Count) lines, $(if ($Code) { "$($keep.Count) failure line(s) and " })the last $tail shown; the full log: $Path (read a range: never the whole file)"
}

# ---- check: gated stack steps; exit = failing step's code (3 gate / test lock, 4 no container engine, 5 UNRUN)
# failed python test: top-level packages its "No module named" lines (no output: the test files' imports) name that find_spec
# misses (never imported; the repo and src/ count) -> names; check.importProbeSec cap
function Get-PyStaleModules([string]$Dir, [string]$Py, [string]$RunText, [string[]]$TestFiles) {
  $mode, $items = if ("$RunText".Trim()) { 'names', @([regex]::Matches($RunText, "(?:ModuleNotFoundError|ImportError): No module named '([\w.]+)'") | ForEach-Object { $_.Groups[1].Value }) } else { 'files', @($TestFiles | ForEach-Object { Join-Path $Dir ($_ -split '::')[0] } | Where-Object { $_ -match '\.py$' -and (Test-Path -LiteralPath $_) }) }
  $Py = ($Py -replace '^\s*"([^"]+)".*', '$1' -split '\s+-')[0].Trim('"', ' ')   # "python -X utf8", a quoted path
  $pyExe = if (Test-Path -LiteralPath (Join-Path $Dir $Py)) { Join-Path $Dir $Py } else { Resolve-Tool $Py }
  if (-not $items.Count -or -not $pyExe) { return @() }
  $probe = @'
import ast, importlib.util as u, os, sys
m, t, c = sys.argv[1], set(), os.getcwd(); sys.path[:0] = [c, c + '/src']
for a in sys.argv[2:]:
    if m == 'names': t.add(a.split('.')[0]); continue
    sys.path.insert(0, os.path.dirname(os.path.abspath(a)))
    try: t |= {x.split('.')[0] for n in ast.parse(open(a, encoding='utf-8').read()).body for x in ([y.name for y in n.names] if isinstance(n, ast.Import) else [n.module] if isinstance(n, ast.ImportFrom) and not n.level and n.module else [])}
    except Exception: pass
def gone(x):
    try: return u.find_spec(x) is None
    except Exception: return False
print(' '.join(x for x in sorted(t) if gone(x)))
'@
  $psi = [Diagnostics.ProcessStartInfo]::new($pyExe); foreach ($x in @('-X', 'utf8', '-', $mode) + $items) { $psi.ArgumentList.Add($x) }   # stdin: a .bat shim (pyenv) mangles a multi-line -c
  $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true
  $pr = try { [Diagnostics.Process]::Start($psi) } catch { return @() }; $pr.StandardInput.Write($probe); $pr.StandardInput.Close(); $outTask = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEndAsync()
  if (-not $pr.WaitForExit(1000 * [int](Get-KitParam 'check.importProbeSec'))) { Stop-KitProcessTree $pr; return @() }
  @("$($outTask.Result)".Trim() -split '\s+' | Where-Object { $_ })
}
# stale-env hint: each module's requirements.txt pins as constraints (a full -r rebuilt other pins)
function Write-PyStaleEnv([string]$Dir, [string]$Py, [string[]]$Stale) {
  $venv = Get-Item -LiteralPath (Join-Path $Dir '.venv') -Force -ErrorAction SilentlyContinue; $venvDir = if ($venv.LinkTarget) { [IO.Path]::GetFullPath($venv.LinkTarget, $Dir) } else { $venv.FullName }
  $venvPy = if ($venvDir) { Join-Path $venvDir $(if ($KitIsWindows) { 'Scripts\python.exe' } else { 'bin/python' }) } else { $Py }
  $reqFile = Join-Path $Dir 'requirements.txt'; $norm = { "$args".ToLower() -replace '[-_.]+', '_' }; $hits = @{}
  $reqLines = @(if (Test-Path -LiteralPath $reqFile) { Get-Content -LiteralPath $reqFile | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ -match '^\w[\w.-]*(\[[^\]]*\])?\s*([=<>~!;]|$)' } })
  $pins = @($reqLines | Where-Object { $_ -match '[=<>~!]' })
  foreach ($m in $Stale) { $hits[$m] = @($reqLines | Where-Object { (& $norm ($_ -split '[\[<>=!~;\s]')[0]) -eq (& $norm $m) })[0] }
  Write-Host "[check] stale-env: $($Stale -join ', ') (the venv lacks them: not a test failure)"
  foreach ($m in @($Stale | Where-Object { -not $hits[$_] })) { Write-Host "[check] stale-env: no requirements.txt line for $m`: add its package (the import name may differ), then install" }
  $quoted = @($hits.Values | Where-Object { $_ } | ForEach-Object { '"' + $_ + '"' }) -join ' '; if (-not $quoted) { return }
  $cons = Join-Path (Get-KitPath logs -Create) "constraints-$((Get-KitHash ($Dir.ToLower()) MD5).Substring(0, 12)).txt"; $pins -replace '\[[^\]]*\]' | Set-Content -LiteralPath $cons -Encoding utf8
  Write-Host "[check] ENV-FIX to kitty (shared venv, when no build uses it; never run it from a worktree): `"$venvPy`" -m pip install -c `"$cons`" $quoted"
}
# check builds and stamps: adapters/check_stamps.ps1
# a step's log: per dir, step and run (parallel checks of one dir); cleanup drops it after keep.check-logs hours
function Get-CheckLog([string]$Dir, [string]$Step) { Join-Path (Get-KitPath check-logs -Create) "$((Get-KitHash $Dir.ToLower() MD5).Substring(0, 12))-$Step-$PID.log" }
function Invoke-Check {
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'e2e', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),
  [switch]$Show,
  [switch]$Touched,
  [switch]$RealAngular,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$script:anyUnrun = $false; $script:CheckSrcKey = $null
$k = $PSScriptRoot
$st = & $KitCmd.dev stack -Dir $Dir -Json | ConvertFrom-Json
function Hash12([string]$s) { (Get-KitHash $s MD5).Substring(0, 12) }
Write-Host "[check] $($st.stack) in $($st.dir)"

# @{upstream} alone = the pushed branch: misses commits
function Get-ChangedFiles {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $tgt = if ($t = Get-WtTarget) { "origin/$t" }
  $refs = @($tgt, ((git -C $st.dir symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null) | Select-Object -First 1), '@{upstream}') | Where-Object { $_ }
  $base = $null; foreach ($r in $refs) { $base = (git -C $st.dir merge-base HEAD $r 2>$null); if ($LASTEXITCODE -eq 0 -and $base) { break }; $base = $null }
  $list = @(git -C $st.dir diff --name-only --diff-filter=ACMR $(if ($base) { $base } else { 'HEAD' }) -- . 2>$null) +
          @(git -C $st.dir ls-files --others --exclude-standard --full-name -- . 2>$null)
  @($list | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

function Get-WtTarget {
  $gd = git -C $st.dir rev-parse --git-dir 2>$null; if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
  if ($gd -and (Test-Path (Join-Path $gd 'claude-target'))) { (Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim() }
}
# repos[] entry via main checkout / submodule core.worktree
function Get-CheckRepo {
  $top = "$(git -C $st.dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top) { return }
  $common = "$(git -C $top rev-parse --path-format=absolute --git-common-dir)".Trim(); $cw = git --git-dir="$common" config core.worktree
  $main = if ($cw) { if ([IO.Path]::IsPathRooted($cw)) { $cw } else { Join-Path $common $cw } } else { Split-Path $common }
  $full = { param($p) "$((Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path)".TrimEnd('\', '/') }
  $roots = @((& $full $main), (& $full $top) | Where-Object { $_ })
  [pscustomobject]@{ top = $top; conf = (@(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and ($c = & $full $_.checkout) -and $c -in $roots } | Select-Object -First 1) }
}
# repos[].exclusiveTests: matching tests hold their lock machine-wide
function Get-TestLock([string[]]$Names) {
  $r = Get-CheckRepo; if (-not $r.conf.exclusiveTests) { return }
  $rel = [IO.Path]::GetRelativePath($r.top, $st.dir).Replace('\', '/'); $files = $null
  foreach ($x in @($r.conf.exclusiveTests)) {
    $d = "$($x.dir)".Replace('\', '/').Trim('/')
    if ($d -and $rel -ne $d -and -not $rel.StartsWith("$d/", [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not $Names.Count) { return $x }
    foreach ($n in $Names) {
      if ($n -match $x.match) { return $x }
      $src = Join-Path $st.dir $n
      if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        if ($null -eq $files) { $files = @(git -C $st.dir ls-files 2>$null) }
        $cls = (($n -split '#')[0] -split '\.')[-1]
        $src = @($files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -eq $cls } | ForEach-Object { Join-Path $st.dir $_ })[0]
      }
      if (-not $src -or (Select-String -LiteralPath $src -Pattern $x.match -Quiet)) { return $x }   # no source found (a pattern, a package): locked
    }
  }
}
# repos[].migrations.check, else the migration adapter of repos[].migrations.tool / migrations.tool (default none: no check);
# a tool without a check verb = UNRUN (exit 5)
if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $mc = (Get-CheckRepo).conf.migrations; $chk = $mc.check
  if ($chk) { if ($Show) { "migrations : $chk"; exit 0 }; Write-Host "[check] migrations: $chk"; & $KitCmd.dev gate -Dir $top -Cmd $chk; exit $LASTEXITCODE }
  $mt = "$(if ($mc.tool) { $mc.tool } else { Get-KitSetting 'migrations.tool' 'none' })".ToLower()
  if ($mt -eq 'none') { Write-Host '[check] migrations: no migration tool configured (kit.local.json migrations.tool, repos[].migrations.tool or .check) - not checked'; exit 0 }
  $mad = if ($KitAdapters['migration']) { $KitAdapters['migration'][$mt] }
  if (-not $mad -or -not ($mad.check -is [scriptblock])) { Write-Host "[check] migrations UNRUN: migration tool $mt has no kit check: set kit.local.json repos[].migrations.check (its validate / dry run); say 'migrations unrun' in the MR."; exit 5 }
  $rc = & $mad.check @{ top = $top; dir = $st.dir; since = $Since; show = [bool]$Show } 'check'
  if ($Show) { exit 0 }; exit ([int]$rc)
}

# e2e: diff's specs only; none: NOT_TESTED (exit 5)
function ConvertTo-GlobRx([string]$g) {
  $x = [regex]::Escape($g.Replace('\', '/').TrimStart('/')) -replace '\\\*\\\*/', '(.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]'
  "(?i)^$([regex]::Replace($x, '\\\{([^}]*)}', { '(' + ($args[0].Groups[1].Value -replace ',', '|') + ')' }))$"
}
$script:GlobRx = @{}   # compiled once: a map scans every tracked file
function Test-Glob([string]$p, $globs) { foreach ($g in @($globs | Where-Object { $_ })) { if (-not $script:GlobRx.ContainsKey($g)) { $script:GlobRx[$g] = [regex]::new((ConvertTo-GlobRx $g)) }; if ($script:GlobRx[$g].IsMatch($p)) { return $g } } }
if ($Step -eq 'e2e') {
  $cfg = Get-KitSetting 'tests.e2e' $null
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $mod = [IO.Path]::GetRelativePath($top, $st.dir).Replace('\', '/'); if ($mod -eq '.') { $mod = '' }
  # tests.e2e.run[]: a module's e2e recipe from kit config
  $recipe = @($cfg.run | Where-Object { $_ -and "$($_.dir)".Replace('\', '/').Trim('/') -eq $mod })[0]
  $cmd = if ($recipe.cmd) { "$($recipe.cmd)" } else { $st.commands.e2e }
  if (-not $cmd) { Write-Host "[check] $($st.stack) has no 'e2e' step (no Cypress / Playwright here: set .claude-stack.json commands.e2e with {specs})"; exit 2 }
  $rel = { param($f) [IO.Path]::GetRelativePath($st.dir, $f).Replace('\', '/') }
  $all = @(@(git -C $st.dir ls-files 2>$null) + @(git -C $st.dir ls-files --others --exclude-standard 2>$null) | Where-Object { $_ } | Select-Object -Unique)
  $sg = if ($cfg.specs) { @($cfg.specs) } else { $rns = @(Get-KitTestRunners); $own = @($rns | Where-Object { $cmd -match "\b$([regex]::Escape($_.name))\b" }); @(@($(if ($own.Count) { $own } else { $rns[0] }) | ForEach-Object { $_.specGlobs }) + 'e2e/**/*.spec.*', '**/*.e2e.*') }
  $specs = @($all | Where-Object { $_ -match '\.([cm]?[jt]sx?|feature)$' -and (Test-Glob $_ $sg) })
  $map = @($cfg.map | Where-Object { $_ -and (-not $_.dir -or "$($_.dir)".Replace('\', '/').Trim('/') -eq $mod) })
  $mapSpecs = @($map | ForEach-Object { $ms = $_.specs; , @($all | Where-Object { Test-Glob $_ $ms }) })
  $chg = @(Get-ChangedFiles | ForEach-Object { & $rel $_ } | Where-Object { $_ -notmatch '^\.\./' })
  $why = [ordered]@{}; $add = { param($s, $r) if (-not $why.Contains($s)) { $why[$s] = [Collections.Generic.List[string]]::new() }; if (-not $why[$s].Contains($r)) { $why[$s].Add($r) } }
  $generic = 'src', 'app', 'apps', 'lib', 'libs', 'components', 'component', 'shared', 'common', 'core', 'pages', 'page', 'views', 'view', 'features', 'feature', 'modules', 'module', 'services', 'service', 'utils', 'util', 'helpers', 'models', 'assets', 'styles', 'public', 'static', 'environments', 'ui', 'web', 'client', 'index', 'main', 'private', 'cypress', 'e2e', 'e2e-tests', 'integration', 'tests', 'test', 'specs', 'spec', 'support', 'fixtures'
  # key -> specs: words, imports, routes
  $byWord = @{}; $byImp = @{}; $byRoute = @{}; $isSpec = @{}
  $put = { param($h, $key, $s, $r) if (-not $key) { return }; if (-not $h.Contains($key)) { $h[$key] = [ordered]@{} }; $h[$key][$s] = $r }
  foreach ($s in $specs) {
    $isSpec[$s] = 1; $p = @($s -split '/')
    $ws = @(@($p | Select-Object -SkipLast 1) + (($p[-1] -replace '^(\d+[-._])+', '') -split '\.')[0]) | ForEach-Object { $_ -replace '^(\d+[-._])+', '' }
    foreach ($w in $ws) {
      $parts = $w -split '(?=[-_.])'; for ($i = 1; $i -le $parts.Count; $i++) { & $put $byWord ($parts[0..($i - 1)] -join '') $s 1 }
    }
    $body = "$(Get-Content -LiteralPath (Join-Path $st.dir $s) -Raw -ErrorAction SilentlyContinue)"; $sd = [IO.Path]::GetDirectoryName($s)
    foreach ($m in [regex]::Matches($body, '(?:from\s+|require\(\s*|import\(\s*|import\s+)[''"](\.[^''"]+)[''"]')) {
      & $put $byImp ([IO.Path]::GetRelativePath($st.dir, [IO.Path]::GetFullPath([IO.Path]::Combine($st.dir, $sd, $m.Groups[1].Value))).Replace('\', '/') -replace '\.[cm]?[jt]sx?$', '') $s 1 }
    foreach ($m in [regex]::Matches($body, '(?:\bvisit|\bgoto)\(\s*[''"`]([^''"`]+)')) { foreach ($g in @($m.Groups[1].Value -split '[/?#]')) { & $put $byRoute $g $s $m.Groups[1].Value } }
  }
  foreach ($f in $chg) {
    if ($isSpec[$f]) { & $add $f 'changed'; continue }
    $hit = $false
    for ($mi = 0; $mi -lt $map.Count; $mi++) { if ($g = Test-Glob $f $map[$mi].paths) { $hit = $true; foreach ($s in $mapSpecs[$mi]) { & $add $s "map $g" } } }
    if ($hit) { continue }
    $stem = ([IO.Path]::GetFileName($f) -split '\.')[0]; if ($stem -in $generic) { $stem = '' }
    # name, then nearest folders; first hit wins
    $dirs = @(([IO.Path]::GetDirectoryName($f) -replace '\\', '/') -split '/' | Where-Object { $_ -and $_ -notin $generic }); [array]::Reverse($dirs)
    $noExt = $f -replace '\.[^./]+$', ''
    foreach ($n in @(@($stem) + $dirs | Where-Object { $_ } | Select-Object -Unique)) {
      $tag = if ($n -eq $stem) { 'name' } else { 'folder' }; $got = $false
      if ($byWord[$n]) { foreach ($s in $byWord[$n].Keys) { & $add $s "$tag $n"; $got = $true } }
      if ($byRoute[$n]) { foreach ($s in $byRoute[$n].Keys) { & $add $s "visits $($byRoute[$n][$s])"; $got = $true } }
      if ($got) { break }
    }
    foreach ($key in $f, $noExt, ($noExt -replace '/index$', '')) { if ($byImp[$key]) { foreach ($s in $byImp[$key].Keys) { & $add $s "imports $f" } } }
  }
  foreach ($t in @($Tests -split '[,\s]+' | Where-Object { $_ })) { & $add $t.Replace('\', '/') 'named (-Tests)' }
  # split = folder: one run per spec folder (one long run crashed Cypress)
  $split = "$($recipe.split)" -eq 'folder'; $groups = [ordered]@{}
  $fold = { param($s) $fd = [IO.Path]::GetDirectoryName($s).Replace('\', '/'); if (-not $groups.Contains($fd)) { $groups[$fd] = [Collections.Generic.List[string]]::new() }; $fd }
  if ($AllTests) {
    Write-Host "[check] e2e: the WHOLE suite (-AllTests: only on the owner's word), logged to the builds stream"
    if ($split) { $globbed = @{}; foreach ($s in $specs) { $fd = & $fold $s; if ($s -notmatch '\.cy\.') { $groups[$fd].Add($s) } elseif (-not $globbed[$fd]) { $globbed[$fd] = 1; $groups[$fd].Add($(if ($fd) { "$fd/*.cy.*" } else { '*.cy.*' })) } } }
    else { $cmd = $cmd -replace '\s*--spec[=\s]+"?\{specs\}"?', '' -replace '\s*\{specs\}', ''; $groups[''] = @() }
    if (-not $Show) { Write-KitLog builds e2e-all ([ordered]@{ dir = $st.dir; branch = "$(git -C $st.dir branch --show-current)"; cmd = $cmd }) }
  } else {
    if (-not $why.Count) {
      Write-Host "[check] e2e NOT_TESTED: no spec relates to the $($chg.Count) changed file(s)$(if ($chg.Count) { ' (' + (($chg | Select-Object -First 5) -join ', ') + $(if ($chg.Count -gt 5) { ', ...' }) + ')' }) of $($specs.Count) spec(s): add a tests.e2e.map entry or a spec, or name specs with -Tests; never the whole suite"
      exit 5
    }
    Write-Host "[check] e2e: $($why.Count) spec(s) for $($chg.Count) changed file(s) (of $($specs.Count)):"
    foreach ($s in $why.Keys) { $r = $why[$s]; Write-Host "  $s <- $(($r | Select-Object -First 3) -join '; ')$(if ($r.Count -gt 3) { " (+$($r.Count - 3) more)" })" }
    foreach ($s in $why.Keys) { $fd = if ($split) { & $fold $s } else { if (-not $groups.Contains('')) { $groups[''] = [Collections.Generic.List[string]]::new() }; '' }; $groups[$fd].Add($s) }
  }
  $envs = [ordered]@{}; if ($recipe.env) { foreach ($p in (Get-KitProps $recipe.env)) { $envs[$p.Name] = "$($p.Value)" } }
  $runs = @(foreach ($fd in $groups.Keys) { $ss = @($groups[$fd]); $(if (-not $ss.Count) { $cmd } else { $cmd.Replace('{specs}', $(if ($cmd -match '--spec[=\s]+"?\{specs\}') { $ss -join ',' } else { $ss -join ' ' })) }) })
  if (-not $runs.Count) { Write-Host "[check] e2e NOT_TESTED: no spec file found (tests.e2e.specs)"; exit 5 }
  if ($Show) { if ($envs.Count) { "e2e env: $(@($envs.Keys | ForEach-Object { "$_=$($envs[$_])" }) -join ' ')" }; foreach ($r in $runs) { "e2e : $r" }; exit 0 }
  foreach ($ek in $envs.Keys) { [Environment]::SetEnvironmentVariable($ek, $envs[$ek]) }
  $env:KIT_E2E_ALL = if ($AllTests) { '1' } else { '' }
  $rc = 0; $n = 0
  foreach ($r in $runs) {
    $n++; if ($runs.Count -gt 1) { Write-Host "[check] e2e run $n/$($runs.Count): $r" }
    & $KitCmd.dev gate -Dir $st.dir -Cmd $r -Log (Get-CheckLog $st.dir "e2e-$n"); if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
  }
  Write-Host "[check] e2e $(if ($rc) { "FAILED (exit $rc)" } else { 'ok' })"; exit $rc
}

$steps = if ($Step -eq 'quick') { 'compile', 'typecheck', 'lint' } else { @($Step) }
$ran = 0
foreach ($s in $steps) {
  $cmd = (Get-KitMember $st.commands $s)
  if (-not $cmd -and $s -eq 'test' -and (Test-Path -LiteralPath (Join-Path $st.dir 'package.json'))) { $cmd = "node `"$($KitCmd.spec)`" {tests}" }
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs' -and -not $Show) {
    if ($RealAngular) { $cmd += ' --real-angular' }
  }
  if ($Touched -and $s -eq 'test') {
    # CI may skip tests
    $chg = @(Get-ChangedFiles)
    $lay = Get-KitSetting "tests.$($st.stack)" $null
    $pat = if ($lay -and $lay.testFor) { @($lay.testFor) } else { switch -Regex ($st.stack) { 'maven|gradle|android|kotlin|java' { '{name}Test', '{name}Tests', '{name}IT' } 'dotnet|msbuild' { '{name}Tests', '{name}Test' } 'python' { 'test_{name}', '{name}_test' } 'go' { '{name}_test' } default { '{name}.spec', '{name}.test' } } }
    $tracked = @(git -C $st.dir ls-files 2>$null)
    $found = foreach ($cf in $chg) {
      $n = [IO.Path]::GetFileNameWithoutExtension($cf) -replace '\.(spec|test)$', ''
      if ($cf -match '\.(spec|test)\.\w+$' -or $n -cmatch '(Test|Tests|IT|_test)$' -or $n -match '^test_') { $cf; continue }
      foreach ($p in $pat) { $w = $p.Replace('{name}', $n); @($tracked | Where-Object { $b = [IO.Path]::GetFileName($_); $b -like "$w.*" }) | ForEach-Object { Join-Path $st.dir $_ } }
    }
    $byName = $st.stack -match 'maven|gradle|android|kotlin|java|dotnet|msbuild'
    $sel = @($found | Where-Object { $_ } | ForEach-Object { if ($byName) { [IO.Path]::GetFileNameWithoutExtension($_) } else { [IO.Path]::GetRelativePath($st.dir, $_) -replace '\\', '/' } } | Select-Object -Unique)
    Write-Host "[check] -Touched: $($sel.Count) test(s) for $($chg.Count) changed file(s)$(if ($sel.Count) { ': ' + ($sel -join ', ') })"
    if ($sel.Count) { $Tests = (@(@($Tests -split '[,\s]+' | Where-Object { $_ }) + $sel) | Select-Object -Unique) -join ',' }
    elseif (-not $Tests) { Write-Host '[check] -Touched: no test file matches the changes: add tests (skills/crafty/testing.md) or pass -Tests'; exit 1 }
  }
  if ($cmd -match '\{tests\}') {
    if (-not $Tests -and -not $AllTests) { throw "-Step test needs -Tests '<names or paths>' (or -AllTests)" }
    # commas reached runners as one name, spaces broke -Dtest
    $tl = @($Tests -split '[,\s]+' | Where-Object { $_ })
    $pyRun = if ($st.stack -eq 'python' -and $cmd -match '^(?<py>.+?)\s+-m\s+(pytest|unittest)\b') { $Matches.py } else { $null }
    # unittest/pytest exit 5 on files without test cases
    $scripts = if ($pyRun -and $tl.Count) { @($tl | Where-Object { $_ -match '\.py$' -and (Test-Path -LiteralPath (Join-Path $st.dir $_) -PathType Leaf) -and -not (Select-String -LiteralPath (Join-Path $st.dir $_) -Pattern '^\s*(def test_|class \w+\(.*TestCase\)|import (unittest|pytest)|from (unittest|pytest)\b)' -Quiet) }) } else { @() }
    if ($scripts.Count -and $scripts.Count -eq $tl.Count) {
      $cmd = ($scripts | ForEach-Object { "$pyRun `"$_`"" }) -join ' && '
      Write-Host "[check] $($scripts.Count) file(s) without test cases: running each with python (exit = the script's)"
    } else {
      $joined = if ($cmd -match '-Dtest=\{tests\}') { $tl -join ',' } elseif ($cmd -match '--tests \{tests\}') { $tl -join ' --tests ' } elseif ($cmd -match '--include \{tests\}') { $tl -join ' --include ' } elseif ($cmd -match '(-run|-R) "\{tests\}"') { $tl -join '|' } else { $tl -join ' ' }
      $cmd = $cmd.Replace('{tests}', $joined)
    }
    if ($AllTests -and -not $Tests) { $cmd = $cmd -replace ' --tests\s*(?=\s|$)', '' -replace ' -Dtest=\s', ' ' -replace ' --include\s*(?=\s|$)', '' -replace ' -run ""', '' -replace ' --filter ""', '' }
  }
  $ct = if ($s -eq 'test' -and $st.stack -match 'maven|gradle|java|kotlin') { Get-Command Test-DockerForContainerTests -ErrorAction SilentlyContinue }   # adapters/container_tests.ps1
  if ($ct) {
    $rc = & $ct
    if ($rc -and -not $Show) { exit $rc }
  }
  if ($cmd -match '\{files\}') {
    if (-not $Files -and $Step -eq 'quick' -and ($s -eq 'lint' -or ($s -eq 'compile' -and $st.stack -eq 'python'))) {
      $ext = if ($st.stack -eq 'python') { '\.(py|pyi)$' } else { '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$' }
      # absolute paths overflow cmd.exe's 8191 chars
      Push-Location $st.dir
      $changed = @(Get-ChangedFiles | Where-Object { $_ -match $ext } | ForEach-Object { Resolve-Path -Relative $_ })
      Pop-Location
      if (-not $changed.Count) { Write-Host "[check] ${s}: no changed files"; continue }
      $Files = ($changed | ForEach-Object { '"' + $_ + '"' }) -join ' '
    }
  }
  $batches = @($cmd)
  if ($cmd -match '\{files\}') {
    $batches = @()
    $list = if ($Files) { @([regex]::Matches($Files, '"[^"]*"|[^\s,]+') | ForEach-Object Value) } else { @('.') }
    $room = 7000 - $cmd.Length; $cur = @()
    foreach ($f in $list) {
      if ($cur.Count -and (($cur -join ' ').Length + $f.Length + 1) -gt $room) { $batches += $cmd -replace '\{files\}', ($cur -join ' '); $cur = @() }
      $cur += $f
    }
    if ($cur.Count) { $batches += $cmd -replace '\{files\}', ($cur -join ' ') }
  }
  for ($bi = 0; $bi -lt $batches.Count; $bi++) {
  $cmd = $batches[$bi]
  if ($batches.Count -gt 1) { Write-Host "[check] $s batch $($bi + 1)/$($batches.Count)" }
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {
    $hash = Hash12 $st.dir.ToLower()
    $tsb = Get-KitPath tsbuild -Create
    $cmd += " --incremental --tsBuildInfoFile `"$(Join-Path $tsb "$hash.tsbuildinfo")`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }
  if ($Show) { "$s : $cmd"; continue }
  $unrun = $false; $slot = if ($s -in 'compile', 'typecheck', 'test') { "$s|$(Hash12 $cmd)" }   # build: its output may be gone
  if ($slot -and (Test-CheckStamp $st.dir $slot -Force:$Force)) { $ran++; continue }
  $runLog = $runText = $null   # adapters/ts_typecheck.ps1: a huge tsc baseline = unrun (exit 5)
  $tc = if ($s -eq 'typecheck' -and $cmd -match '\btsc\b') { Get-Command Invoke-Typecheck -ErrorAction SilentlyContinue }
  if ($tc) { $r = @(& $tc $cmd)[-1]; if ($r -eq 'unrun') { $unrun = $true; $script:anyUnrun = $true; $rc = 0 } else { $rc = [int]$r } }
  else {
    $lk = if ($s -eq 'test') { Get-TestLock @($Tests -split '[,\s]+' | Where-Object { $_ }) }
    if ($lk -and -not (Use-KitLock "$($lk.lock)" $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { Split-Path (Get-CheckRepo).top -Leaf }) $st.dir)) { Write-Host "[check] test not started: lock $($lk.lock) still held by $($script:KitLockRefused.holder) (repos[].exclusiveTests); retry when it ends"; exit 3 }
    # "No module named" = a stale venv, not a failed test
    $runLog = Get-CheckLog $st.dir $s   # every step: the gate prints its digest (failure lines + summary), the log keeps the rest
    Write-Host "[check] $s output goes to $runLog; its digest prints when the run ends"; if ($pyRun) { $env:PYTHONUTF8 = '1' }
    $bt0 = (Get-Date).AddSeconds(-2)
    try { & $KitCmd.dev gate -Dir $st.dir -Cmd $cmd -Log $runLog; $rc = $LASTEXITCODE } finally {
      if ($lk) { Remove-KitLock "$($lk.lock)" }
      if ($pyRun -and $s -eq 'test') { $runText = Get-Content -LiteralPath $runLog -Raw -Encoding utf8 -ErrorAction SilentlyContinue } }
  }
  $ran++
  $stale = if ($rc -and $pyRun -and $s -eq 'test') { @(Get-PyStaleModules $st.dir $pyRun $runText $tl) } else { @() }   # 24 of 39 python builds failed on the env, not the code
  if ($stale.Count) { Write-PyStaleEnv $st.dir $pyRun $stale; Write-Host "[check] exit 5: $s UNRUN (stale-env, test exit $rc)"; exit 5 }
  if ($rc) { Write-Host "[check] $s FAILED (exit $rc)"; exit $rc }
  if ($s -eq 'build' -and -not $unrun) { Save-CheckBuild $st.dir $cmd $bt0 }
  if ($slot -and -not $unrun) { Save-CheckStamp $st.dir $slot }
  }
  if (-not $Show) { Write-Host "[check] $s $(if ($unrun) { 'UNRUN (not a pass: see above)' } else { 'ok' })" }
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
if ($script:anyUnrun) { Write-Host '[check] exit 5: typecheck UNRUN (not a pass)'; exit 5 }
exit 0
}

# ---- pipes: wait for MR/PR pipelines (JSON)
function Invoke-Pipes {
param([Alias('Mr')][string[]]$Mrs, [int]$MaxMinutes = 8, [switch]$UntilMerged, [string]$Run, [string]$Repo, [string]$Branch, [string]$Sha)   # -UntilMerged: a consumer waits for producers; -Sha: the branch run of that commit
if ($Branch) { if (-not $Repo) { Stop-KitVerb 'pipes: -Branch needs -Repo <repo> (a deploy branch: its newest pipeline)' }; $Mrs = @("branch:$Repo@$Branch") }   # retro 1508: opsy waits on a deploy branch
if (-not $Mrs) {   # a wt worktree: its branch's open MRs; else the tracked tasks' (-Run: its)
  $wtTop = "$(git rev-parse --show-toplevel 2>$null)".Trim(); $wtGit = if ($wtTop) { "$(git -C $wtTop rev-parse --absolute-git-dir 2>$null)".Trim() }
  $wtTarget = if ($wtGit -and (Test-Path -LiteralPath (Join-Path $wtGit 'claude-target'))) { (Get-Content -LiteralPath (Join-Path $wtGit 'claude-target') -TotalCount 1).Trim() }
  $script:KitRc = 2
  if (-not $wtTarget) {
    $trRefs = @((Read-KitTracking).tasks.Values | Where-Object { -not $_.done -and (-not $Run -or "$($_.wave)" -eq $Run) } | ForEach-Object { @($_.mrs) } | Where-Object { "$_" -match '^[\w./-]+!\d+$' } | Select-Object -Unique)
    $Mrs = @(foreach ($tr in $trRefs) { $trRepo, $trN = "$tr" -split '!', 2; $trA = @{ repo = (Get-HostProject $trRepo -Raw); n = $trN }
        if ("$((Invoke-HostVerb 'mr.get' $trA).state)" -eq 'opened') { Invoke-HostVerb 'mr.url' $trA } }) | Where-Object { $_ }
    if (-not $Mrs.Count) { Stop-KitVerb "pipes: missing -Mrs (not in a crafty.ps1 wt worktree, no open MR in tracking$(if ($Run) { " for run $Run" })). Usage: pipes -Mrs <repo!iid>,... (or MR urls) [-Run <run>] [-MaxMinutes 8] [-UntilMerged]" }
    $script:KitRc = 'exit'; [Console]::Error.WriteLine("pipes: -Mrs $($Mrs -join ',') (open tracked MRs$(if ($Run) { " of run $Run" }))")
  } else {
    $wtBranch = "$(git -C $wtTop branch --show-current)".Trim()
    if (-not $wtBranch) { Stop-KitVerb 'pipes: the worktree has a detached HEAD: pass -Mrs <repo!iid>,...' }
    $Mrs = @(Get-MergedMrs $wtTop $wtBranch $wtTarget 'opened' | Where-Object source_branch -eq $wtBranch | ForEach-Object web_url | Where-Object { $_ })
    if (-not $Mrs.Count) { Stop-KitVerb "pipes: no open MR for $wtBranch -> $wtTarget (open it, or pass -Mrs <repo!iid>,...)" }
    $script:KitRc = 'exit'; [Console]::Error.WriteLine("pipes: -Mrs $($Mrs -join ',') (open MRs of $wtBranch)")
  }
}
$ErrorActionPreference = 'SilentlyContinue'
$list = @($Mrs -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { if ("$_" -match '^([\w./-]+)!(\d+)$') { $pmUrl = Invoke-HostVerb 'mr.url' @{ repo = (Get-HostProject $Matches[1] -Raw); n = $Matches[2] }; if ($pmUrl) { $pmUrl } else { $_ } } else { $_ } })   # repo!iid -> its url (retro 2026-11-20)
$noMrCi = @(Get-KitValue 'repos' @() | Where-Object { $_.ci.mrPipelines -eq $false } | ForEach-Object { @($_.name) + @($_.aliases) } | Where-Object { $_ } | ForEach-Object { "$_".ToLower() })
# no head pipeline: no-ci (no CI config) or no-pipeline (may start); a branch with -Sha: no-pipeline until a run of that commit exists
function State($url) {
  if ("$url" -match '^branch:(.+)@([^@]+)$') { $rq = @{ repo = (Get-HostProject $Matches[1] -Raw) }; $bp = @(Invoke-HostVerb 'ci.runs' ($rq + @{ ref = $Matches[2]; per_page = $(if ($Sha) { 10 } else { 1 }) }) -NoMemo | ForEach-Object { $_ } | Where-Object { $_ -and (-not $Sha -or "$($_.sha)".StartsWith($Sha)) })[0]
    if (-not $bp) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }; return (Get-PipeFailure ([ordered]@{ mr = $url; status = "$($bp.state)" }) $rq $bp.id) }   # state: the host's word normalised
  $u = ConvertFrom-MrUrl $url; if (-not $u) { return [ordered]@{ mr = $url; status = 'bad-url' } }
  if ($u.type -eq 'gitlab' -and $url -match '^https?://([^/]+)/') { $env:GITLAB_HOST = $Matches[1] }   # else glab asks gitlab.com
  $m = Invoke-HostVerb 'mr.get' $u -NoMemo
  if (-not $m) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($m.state -eq 'merged') { return [ordered]@{ mr = $url; status = 'merged' } }
  if ($UntilMerged -and $m.state -eq 'closed') { return [ordered]@{ mr = $url; status = 'closed' } }
  $p = $m.head_pipeline
  if (-not $p) { return [ordered]@{ mr = $url; status = $(if (@($noMrCi | Where-Object { "/$($u.repo)".ToLower().EndsWith("/$_") }).Count -or (Invoke-HostVerb 'ci.config' @{ repo = $u.repo; ref = $m.target_branch; type = $u.type }) -eq $false) { 'no-ci' } else { 'no-pipeline' }) } }
  Get-PipeFailure ([ordered]@{ mr = $url; status = $p.status }) @{ repo = $u.repo; type = $u.type } $p.id
}
# a failed pipeline: its failed job and the error lines of its log
function Get-PipeFailure($o, [hashtable]$Rq, $Id) {
  if ($o.status -eq 'failed' -and $Id) {
    $job = @(Invoke-HostVerb 'ci.jobs' ($Rq + @{ id = $Id }) | Where-Object { "$($_.status)" -eq 'failed' -or "$($_.state)" -eq 'failed' })[0]
    if ($job) {
      $o.job = $job.name
      $trace = ([string](Invoke-HostVerb 'ci.log' ($Rq + @{ id = $job.id }))) -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' -replace '^\S+Z \d+O ', '' }
      $o.error = (@($trace | Where-Object { $_ -match '(?i)error|fail|invalid|exception|\[ERROR\]' } | Select-Object -Last 8) -join "`n")
    }
  }
  $o
}
$end = (Get-Date).AddMinutes($MaxMinutes); $bk = @{}; $states = $list.ForEach({ State $_ })
do {
  # a pipeline may still start
  $busy = @($states | Where-Object { $_.status -in 'created', 'pending', 'running', 'waiting_for_resource', 'preparing', 'scheduled', 'no-pipeline', 'unknown' -or ($UntilMerged -and $_.status -notin 'merged', 'failed', 'canceled', 'closed', 'bad-url') })
  if (-not $busy -or (Get-Date) -gt $end -or ($UntilMerged -and @($states | Where-Object { $_.status -in 'failed', 'canceled', 'closed', 'bad-url' }).Count)) { break }   # one will never merge: stop now
  Wait-KitBackoff $bk "$($states.status)" 30 $end
  $states = $states.ForEach({ if ($_.status -notin 'merged', 'closed', 'bad-url') { State $_.mr } else { $_ } })
} while ($true)
[ordered]@{ done = (-not $busy); mrs = $states } | ConvertTo-Json -Depth 4 -Compress
}

# ---- guard: PreToolUse hook: a deny or nothing
function Invoke-Guard {
param([switch]$SelfTest, [string]$Json)   # -Json: hook input without stdin (in-process self-test)
$ErrorActionPreference = 'SilentlyContinue'; $script:layoutNote = $null   # guard_server.ps1 keeps this runspace: no note carries over
$gbn = 'KIT_GUARD_BY' + 'PASS'   # client crash switch; split: SBLOG
if ($SelfTest) {
  $da = 'default desktop app'; $mg = 'the memory gate';$sx = 'Run it through its interpreter'; $wb = "open the owner's browser"; $rp = 'holds runs in progress'; $hk = 'Hooks must run'; $pb = 'a protected kit branch'; $lk = 'the live kit runs'; $gb = 'Git Bash path'; $rt = 'use the Read tool'; $dr = 'searches a whole drive'
  $cases = @(
  @('P', 'git stash', $true),
  @('P', '& "C:\Program Files\Git\bin\git.exe" stash list', $false),
  @('P', 'git stash push -m x', $true),
  @('P', '$s = $(git stash list); $s', $false),
  @('P', 'pwsh -NoProfile -Command "git stash"', $true),
  @('B', 'cd repo && git -C x stash pop', $true),
  @('B', 'FOO=1 git --no-pager stash show', $false),
  @('B', 'git -C x stash push -m x', $true),
  @('B', "bash -c 'git stash'", $true),
  @('P', 'git commit -m "fix: never git stash here"', $false),
  @('P', "`$m = @'`nnever run git stash`n'@`ngit commit -m `$m", $false),
  @('B', "git commit -m `"`$(cat <<'EOF'`nfix: never git stash in worktrees`nEOF`n)`"", $false),
  @('B', 'git checkout fix/stash-list', $false),
  @('B', 'echo done # not git stash', $false),
  @('B', 'aws elasticbeanstalk update-environment --environment-name e1 --option-settings Namespace=aws:elasticbeanstalk:application:environment,OptionName=A,Value=true', $true, 'changes a deployed env'),
  @('B', 'aws --region eu-west-1 elasticbeanstalk restart-app-server --environment-name e1', $true, 'changes a deployed env'),
  @('P', 'aws ecs update-service --cluster c --service s --force-new-deployment', $true, 'changes a deployed env'),
  @('B', 'cd x && kubectl -n qa rollout restart deploy/api', $true, 'changes a deployed env'),
  @('B', 'KIT_DECISION=d-none aws lambda update-function-configuration --function-name f', $true, 'changes a deployed env'),
  @('B', 'aws elasticbeanstalk describe-configuration-settings --environment-name e1', $false),
  @('B', 'git commit -m "test: never aws elasticbeanstalk update-environment"', $false),
  @('B', 'kubectl get pods -n qa | grep edit', $false),
  @('B', 'kubectl get deploy && npm run scale', $false),
  @('B', "git commit -m `"x`naws ecs update-service --cluster c`"", $false),
  @('B', 'echo "after web restart"', $false),
  @('P', '& "C:\Program Files\Amazon\AWSCLIV2\aws.exe" elasticbeanstalk restart-app-server --environment-name e1', $true, 'changes a deployed env'),
  @('B', 'sudo aws ecs update-service --cluster c --service s', $true, 'changes a deployed env'),
  @('B', 'bash -c "aws elasticbeanstalk update-environment --environment-name e1"', $true, 'changes a deployed env'),
  @('P', 'pwsh -Command "aws ssm put-parameter --name x --value y"', $true, 'changes a deployed env'),
  @('P', '& D:\kit\skills\crafty\LESSONS.md', $true, $da),
  @('P', 'Invoke-Item .\report.html', $true, $da),
  @('P', 'Start-Process https://example.com', $true, $da),
  @('B', 'xdg-open out/report.html', $true, $da),
  @('B', 'cmd /c start "" report.pdf', $true, $da),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden', $false, ''),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -PassThru -RedirectStandardOutput o.txt', $false, $da),
  @('P', 'Start-Process -FilePath .\r.html', $true, $da),
  @('P', 'Start-Process -Wait .\r.html', $true, $da),
  @('P', 'cd x; ii "out.pdf"', $true, $da),
  @('P', '& D:/kit/learn.ps1 -Skill crafty -Text "resumed agent; . templates.md "Resume brief" was read (see notes.md); & LESSONS.md"', $false, $da),
  @('P', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, $da),
  @('P', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, $da),
  @('P', '& D:/kit/learn.ps1 -Skill crafty -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, $da),
  @('P', "& D:/kit/learn.ps1 -Skill crafty -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/crafty/LESSONS.md | Out-Null", $true, $da),
  @('P', '& D:\kit\skills\crafty\devtools.py merge 12', $true, $sx),
  @('P', "& 'D:\kit\skills\crafty\devtools.py' merge", $true, $sx),
  @('P', '& "$k/skills/pokey/browser.mjs" shot', $true, $sx),
  @('P', '.\x.py --flag', $true, $sx),
  @('P', 'tool.ts run', $true, $sx),
  @('P', 'Start-Process x.py', $true, $sx),
  @('P', 'cmd /c x.js', $true, $sx),
  @('B', './skills/crafty/devtools.py merge 12', $true, $sx),
  @('B', 'cd x && FOO=1 tool.mjs a', $true, $sx),
  @('B', 'start x.py', $true, $sx),
  @('P', 'python -X utf8 skills/crafty/devtools.py merge 12', $false, ''),
  @('P', 'node skills/pokey/browser.mjs shot; npx tsx a.ts', $false, ''),
  @('P', 'pwsh -File x.ps1; & D:/kit/x.ps1 -A b.py', $false, ''),
  @('P', 'Get-Content x.json; Select-String foo x.md', $false, ''),
  @('B', 'python -X utf8 skills/crafty/devtools.py merge 12; node a.mjs', $false, ''),
  @('B', 'cat devtools.py; grep -n foo x.md; ls *.json > out.txt', $false, ''),
  @('B', 'cd ../MR3/scripts; E=../evidence; ls ../ev/MR3-T2A_0*; cp ../ev/MR3-T2A_02_vin-photo.jpg $E/MR3-T2_00_vin-input.jpg; for i in 1 2 3; do node t2a/run-app-vin.cjs $E/MR3-T2_00_vin-input.jpg $E/MR3-T2_0${i}_run$i.json 1; done', $false, $da),
  @('B', 'E=../evidence; cat ../ev/MR3-T2A_02_vin-photo.jpg > $E/MR3-T2_00_vin-input.jpg; for i in 1 2 3; do node t2a/run-app-vin.cjs $E/in.jpg $E/MR3-T2_0${i}_run$i.json 1; done', $false, $da),
  @('B', 'LN=D:/x/{RT}/work/lead-notes.md; for i in $(seq 1 30); do m=$(curl -s https://x/ | grep -o ''"mode":"[a-z]*"''); a=$(grep -E "^- .*MR4:" $LN | grep -v "REQUEST"); echo "$m ${a:0:200}"; done', $false, $da),
  @('B', 'E=D:/x/{RT}/work/MR4/evidence; F=$E/MR4-T2_retry_03_history.log; { echo "== NRQL"; echo x; } > $F', $false, $da),
  @('P', '$x = ''notes.md''; Get-Content $x', $false, $da),
  @('B', 'x=$(cat a.md); a=(x.md y.md)', $false, $da),
  @('B', 'x.md', $true, $da),
  @('B', 'cd x; for f in a; do r.pdf; done', $true, $da),
  @('B', 'X=1 r.html', $true, $da),
  @('B', 'start x.html', $true, $da),
  @('P', 'ii x.pdf', $true, $da),
  @('P', '& x.py', $true, $sx),
  @('P', '& .\notes.md', $true, $da),
  @('P', 'ii .', $true, $da),
  @('P', 'explorer.exe D:\x', $true, $da),
  @('P', 'code skills/crafty/devtools.py', $true, $da),
  @('P', 'notepad a.txt', $true, $da),
  @('P', 'mmc; control', $true, $da),
  @('P', 'rundll32 url.dll,FileProtocolHandler https://x', $true, $da),
  @('P', 'Start-Process report.docx', $true, $da),
  @('P', 'cmd /c start https://x', $true, $da),
  @('B', 'start https://example.com', $true, $da),
  @('B', 'explorer .', $true, $da),
  @('B', 'cmd //c start "" a.xlsx', $true, $da),
  @('B', 'code .', $true, $da),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden; Start-Process -FilePath node.exe -WindowStyle Hidden', $false, ''),
  @('B', 'cd D:/x/src/code-review; echo code', $false, ''),
  @('P', 'glab mr view 12 --web', $true, $wb),
  @('B', 'gh pr view 3 -w', $true, $wb),
  @('B', 'gh browse', $true, $wb),
  @('P', 'glab mr view 12 -R g/web; gh pr view 3 --json title', $false, ''),
  @('B', 'gh run list -w ci.yml; gh workflow run -w x; gh browse -n 12', $false, ''),
  @('P', 'code --version; code --list-extensions', $false, ''),
  @('B', 'code --version', $false, ''),
  @('P', 'Start-Process -FilePath notepad.exe -WindowStyle Hidden', $false, ''),
  @('P', 'powershell -c "ii ."', $true, $da),
  @('B', 'pwsh -c ". a.py"', $true, $sx),
  @('P', 'cmd.exe /k a.js', $true, $sx),
  @('B', 'mshta x.hta', $true, $da),
  @('B', "cd {KRT} && mkdir -p work/agents/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/agents/g5/body.md; cat >> work/agents/g5/body.md <<'EOF'`n## Review follow-up`n- Plain check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/agents/g5/body.md)`"", $false, $rp),
  @('P', '& D:/kit/learn.ps1 -Skill crafty -Text "never rm the {RT}/work folder" -Source workflow', $false, $rp),
  @('B', 'rm -rf {KRTB}/work', $true, $rp),
  @('P', 'Remove-Item -Recurse -Force "{KRT}\work"', $true, $rp),
  @('B', "python -c `"import shutil; shutil.rmtree('{KRT}/work')`"", $true, $rp),
  @('B', 'cd {KRTB} && rm -rf work', $true, $rp), @('B', 'cd {KIT}; rm -rf {RT}/work', $true, $rp), @('B', 'rm -rf $K/{RT}/work', $true, $rp),
  @('B', 'rm -rf /d/x/{RT}/work', $false, $rp), @('P', 'Remove-Item -Recurse "D:\x\{RT}\work"', $false, $rp), @('B', 'cd /d/x/{RT} && rm -rf work', $false, $rp),
  @('B', 'cd {WS}; rmdir {RT}/work/agents/a {RT}/work {RT}', $false, $rp), @('B', 'cd {WS}; mkdir -p {RT}/work/agents/a', $true, 'outside the kit'),
  @('E', '{WS}/{RT}/work/a.md', $true, 'outside the kit'), @('B', 'mkdir -p {KRT}/work/agents/a; echo x > {KRTB}/../x/y/{RT}/a.txt', $false, 'outside the kit'),
  @('B', 'rm -rf {KRTU}/work', $true, $rp), @('B', 'cd {WS}; mkdir -p {RTU}/w', $true, 'outside the kit'), @('B', 'mv {WS}/{RT}/work/x {KRT}/work/agents/x; cat {WS}/{RT}/a.md > {KRT}/work/agents/x/b.md', $false, 'outside the kit'),
  @('B', 'cd {WS}; echo "{RT}/" >> .gitignore; ls {RT} 2>&1', $false, 'outside the kit'), @('B', 'cd {WS}; mkdir -p a/b/c/{RT}', $false, 'outside the kit'),
  @('P', 'Remove-Item D:\x\.claude\tracking.local.json', $true, 'durable local kit state'),
  @('P', 'Remove-Item -Force "{KRT}\work\a.json"', $false, $rp), @('B', 'rm -r {KRTB}/work/a.d', $true, $rp),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`ns=open(p).read()  # never git stash here`nE`nnode x.mjs", $false),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`nE`ngit stash list >/dev/null; cp a.ts /tmp/a.bak", $false),
  @('B', 'glab mr update 5 --description "$(cat /tmp/mr-body.md)"', $true, 'shared temp root'),
  @('P', 'Set-Content $env:TEMP\desc-8543.md $d', $true, 'shared temp root'),
  @('B', 'cp body.md /tmp/w1-run/body.md; cat /tmp/out.log', $false, 'shared temp root'),
  @('B', 'git push origin +HEAD:main', $true, 'force-push'),
  @('P', 'git -C x push origin +f/CU-1-x', $true, 'force-push'),
  @('B', 'git push origin HEAD:main', $true, 'refused: a protected branch'),
  @('B', 'git push -u origin HEAD; git push origin HEAD:f/CU-1-x --force-with-lease', $false, 'force-push'),
  @('B', 'git push -fu origin main', $true, 'force-push'),
  @('P', 'git -C "{KIT}" push origin ":main"', $true, $pb),
  @('B', 'cd "{KIT}" && git push origin --delete "main"', $true, $pb),
  @('P', 'Set-Location -Path "{KIT}"; git push -d origin main', $true, $pb),
  @('P', 'Push-Location "{KIT}"; git push --mirror origin', $true, $pb),
  @('B', 'git -C "{KIT}" branch -D main', $true, $pb),
  @('B', 'git -C "{KIT}" branch -f main HEAD~1', $true, $pb),
  @('P', 'git -C "{KIT}" branch -dr origin/main', $true, $pb),
  @('P', 'git -C "{KIT}" update-ref -d refs/remotes/origin/main', $true, $pb),
  @('B', 'git -C "{KIT}" push -u origin HEAD:main; git -C "{KIT}" branch --show-current', $false, $pb),
  @('B', 'git -C "{KIT}" push origin --delete kit/build-x; git -C "{KIT}" branch -D kit/main-x', $false, $pb),
  @('B', 'git -C /nowhere/repo push origin --delete f/x; git -C /nowhere/repo branch -D develop', $false, $pb),
  @('B', 'git -C /nowhere/repo push origin --delete main; git push origin main --tags', $true, 'refused: a protected branch'),
  @('B', 'git push --all origin', $true, 'refused: a protected branch'),
  @('B', 'git -C /nowhere/repo push origin --force-with-lease HEAD:release', $false, $pb),
  @('P', 'git commit -m "never git push origin --delete main"', $false, $pb),
  @('B', 'git commit -n -m "x"', $true, $hk),
  @('B', 'git -c core.hooksPath=/dev/null commit -m x', $true, $hk),
  @('B', 'git commit --no-edit --amend', $false, $hk),
  @('P', 'git commit -m "use -n for a dry run"', $false, $hk),
  @('B', 'git log -n 3; git commit -m x', $false, $hk),
  @('E', '{LIVE}/skills/crafty/crafty.ps1', $true, $lk),
  @('E', '{LIVE}/{RT}/work/agents/x/x.md', $false, $lk),
  @('E', '{LIVE}/.git/info/exclude', $false, $lk),
  @('E', '{LIVE}/../wt/skills/crafty/crafty.ps1', $false, $lk),
  @('A', "*** Begin Patch`n*** Update File: {LIVE}/AGENTS.md", $true, $lk),
  @('P', 'Set-Content {LIVE}/AGENTS.md x', $true, $lk),
  @('B', 'sed -i s/a/b/ {LIVE}/README.md', $true, $lk),
  @('B', 'git -C "{LIVE}" commit -m x', $true, $lk),
  @('P', 'cd {LIVE}; git pull; git log -1; Get-Content AGENTS.md > {RT}/work/agents/x/a.txt; cp AGENTS.md ../a.md', $false, $lk),
  @('B', 'cd {LIVE}; grep -c ">" README.md; git clean -n', $false, $lk),
  @('B', 'KIT_LIVE_EDIT=1 git -C "{LIVE}" commit -m x', $false, $lk),
  @('B', 'node shot.mjs --out /d/x/{RT}/work/evidence/t1/a.png', $true, 'Use D:/x/'),
  @('B', "python -c `"open('/d/x/a.txt', 'w')`"", $true, $gb),
  @('B', "cd /d/x; python3 - <<'E'`nopen('/c/Users/x/a.json')`nE", $true, 'Use C:/Users/x/a.json'),
  @('B', 'OUT=/d/x/a.png node shot.mjs', $true, $gb),
  @('B', 'cd /d/x && node shot.mjs ''{"out":"/d/x/a.png"}''', $true, $gb),
  @('B', 'bash -c "java -jar a.jar /d/x/in.txt"', $true, $gb),
  @('B', 'curl -s -o /d/x/a.json https://h.io/api; x=$(npx tsx a.ts --dir=/e/y)', $true, $gb),
  @('P', 'node shot.mjs /d/x/a.png; adb.exe pull /sdcard/a.png /d/x/', $true, $gb),
  @('B', 'command node a.mjs /d/x; { sudo python a.py /d/y; }', $true, $gb),
  @('B', 'curl -sSo /d/x/a.json https://h.io/api', $true, 'Use D:/x/a.json'),
  @('B', 'curl -d @/d/x/body.json https://h.io/api', $true, $gb),
  @('B', 'curl --output=/d/x/a.zip https://h.io/a; curl -T /d/x/a.zip https://h.io/u', $true, $gb),
  @('B', 'curl -K /d/x/c.txt; curl -F file=@/d/x/a.png https://h.io', $true, $gb),
  @('B', 'curl -s -d ''{"route":"/c/orders"}'' https://h.io/api; curl --json ''{"p":"/d/x"}'' "https://h.io/api?path=/d/x"', $false, $gb),
  @('B', 'curl --data-raw /c/orders -H "X-Path: /v/1" https://h.io; curl -X POST --data /d/x https://h.io', $false, $gb),
  @('B', 'node a.mjs D:/x > {KRTB}/work/agents/a/out.log 2>{KRTB}/work/agents/a/err.log; python a.py < /d/x/in.txt', $false, $gb),
  @('B', 'curl -s https://h.io/d/files/a.json -o D:/x/a.json; node a.mjs abc/c/def x/d/y ${R}/c/z', $false, $gb),
  @('B', "python a.py D:/x # was /d/x`n# node b.mjs /d/y", $false, $gb),
  @('B', 'python a.py x#y /d/z', $true, $gb),
  @('B', 'ls /d/x; cat /d/x/a.md; grep -rn foo /d/x; git -C /d/x status; cd /d/x && node shot.mjs D:/x/a.png', $false, $gb),
  @('B', "git commit -m `"fix: node got /d/x paths`"; cat <<'EOF' > /d/x/a.md`npython /d/x/a.py`nEOF", $false, $gb),
  @('P', 'python -X utf8 D:\x\a.py --out D:/x/a.png; adb shell ls /sdcard/DCIM', $false, $gb),
  @('B', 'cd web && npx cypress run', $true, 'e2e runs go through'), @('P', 'yarn e2e:ci; npx playwright test x.spec.ts', $true, 'e2e runs go through'),
  @('P', '& D:/k/skills/crafty/crafty.ps1 check -Dir web -Step e2e', $false, 'e2e runs go through'), @('B', 'crafty.ps1 check -Dir w -Step test; npx cypress run', $true, 'e2e runs go through'),
  @('B', 'cat cypress/tsconfig.json; git log --grep "cypress run"; yarn playwright install; npm run cypress:open', $false, 'e2e runs go through'),
  # a file path as the command (G = Antigravity run_command)
  @('B', '"{KIT}/skills/bossy/SKILL.md"', $true, $rt), @('B', '{CR}/NOTICE', $true, $rt), @('B', 'cd "{CR}" && ./NOTICE', $true, $rt),
  @('B', 'start {CR}/NOTICE', $true, $rt), @('B', '& "{CR}\NOTICE"', $true, $rt), @('B', 'cd x; "./tool.ps1" -A', $true, $rt),
  @('B', 'cd "{CR}" && ./run; bash .githooks/pre-push; cat "{KIT}/README.md"; echo "a; ./x.md"; ls {KIT}', $false, $rt),
  @('P', '& "{CR}/NOTICE"', $true, $rt), @('P', '& "{KIT}"', $true, $rt), @('P', 'Set-Location "{CR}"; .\NOTICE', $true, $rt),
  @('P', '$g = Join-Path "{KIT}" ''skills/bossy/SKILL.md''; & $g', $true, $rt), @('P', '$f = "{KIT}/README.md"; Start-Process -FilePath $f', $true, $rt),
  @('P', 'Start-Process "{CR}/NOTICE"', $true, $rt), @('G', '{CR}\NOTICE', $true, $rt), @('P', 'Start-Process (Join-Path "{KIT}" ''README.md'')', $true, $rt),
  @('B', "git log \`n  -- docs/readme.md; git diff \`n  skills/crafty/crafty.ps1", $false, $rt),
  @('P', '$py = ''C:/x/python.exe''; & $py a.py; Get-Content "{CR}/NOTICE"; "{KIT}/README.md" | Out-Null; cd "{KIT}"; .\.githooks\pre-commit.ps1', $false, $rt),
  # pytest / docker runs go through the gate
  @('B', 'cd api && pytest tests/test_a.py -q', $true, $mg), @('P', '& "C:\v\python.exe" -X utf8 -m pytest t', $true, $mg), @('B', 'uv run pytest', $true, $mg),
  @('B', 'docker compose -f a.yml -f b.yml up -d --wait', $true, $mg), @('P', 'docker build -t x .', $true, $mg), @('B', 'docker-compose up', $true, $mg),
  @('P', '& "C:\Program Files\Py\python.exe" -m pytest t', $true, $mg), @('B', 'FOO=1 timeout 300 pytest -x', $true, $mg), @('B', 'nohup pytest &', $true, $mg),
  @('B', 'sudo docker run x', $true, $mg), @('B', 'docker --context ci image build .', $true, $mg), @('B', 'docker container run x', $true, $mg),
  @('B', 'grep -rn pytest requirements.txt; pytest --version; pytest -h; docker ps; docker compose logs api', $false, $mg),
  @('B', 'rg "foo|pytest" src; grep -E "(pytest|docker run)" a; git commit -m "fix; pytest runs"; echo x | grep -n "; docker build" f', $false, $mg),
  @('P', '& {KIT}/skills/crafty/crafty.ps1 gate -Dir x -Cmd ''docker compose up -d''', $false, $mg),
  # whole-drive searches denied; scoped paths pass
  @('B', 'find / -ipath "*backend-test-reconciler*" 2>/dev/null', $true, $dr), @('B', 'find /c -name SKILL.md', $true, $dr), @('B', 'sudo find -L /d/ -type f | head', $true, $dr),
  @('B', 'find C:\ -name x', $true, $dr), @('B', 'grep -rn reconciler /', $true, $dr), @('B', 'rg -l -g "*.md" reconciler C:/', $true, $dr), @('B', 'ls -R /c | grep x', $true, $dr),
  @('B', 'bash -c "find / -name x"', $true, $dr), @('P', 'cmd /c dir /s C:\*.md', $true, $dr), @('P', 'Get-ChildItem -Recurse C:\ -Filter SKILL.md', $true, $dr),
  @('P', 'gci D:\ -r -Include *.md', $true, $dr), @('P', 'where.exe /r C:\ claude.exe', $true, $dr), @('P', 'rg --files D:\', $true, $dr), @('B', 'find //c/.. -name x', $true, $dr), @('B', 'rg --max-columns 5 x / src', $true, $dr), @('B', 'rg --max-columns 5 / src', $false, $dr),
  @('B', 'find . -name x; find ~/.claude/skills -name SKILL.md; find /d/work/repos -maxdepth 2 -name pom.xml; ls /; ls -la /c', $false, $dr),
  @('B', "grep -rn / src; rg -n `"/`" skills; grep -e x /etc/hosts; git commit -m `"never find / -name x`"; cat > n.md <<'EOF'`nfind / -name x`nEOF", $false, $dr),
  @('P', 'Get-ChildItem -Recurse D:\work\.claude\skills -Filter SKILL.md; Get-ChildItem C:\; where.exe git; rg -l x C:\Users\x\.claude', $false, $dr),
  @('B', 'cd / && find . -name x', $true, $dr), @('B', 'cd /c; grep -rn x', $true, $dr), @('P', 'Set-Location C:\; gci -Recurse -Filter x', $true, $dr), @('B', 'find . -name "*.md" -exec grep -rl x / \;', $true, $dr),
  @('B', 'cd / && ls; cd ~/src && find . -name x; find . -exec grep -l x {} +; cd /d/repo && rg x', $false, $dr), @('P', 'Set-Location C:\; where.exe git; Get-ChildItem', $false, $dr)
  )
  $gh = 'browser on Windows'   # Git for Windows help is HTML; elsewhere a man page
  if ($IsWindows) { $cases += @(@('B', 'git cherry-pick --help', $true, $gh), @('P', 'git -C x help rebase', $true, $gh), @('B', 'git cherry-pick -h; git help -a; git commit -m "see --help"', $false, $gh)) }
  $cr = Join-Path (Get-KitPath agents -Create) 'guard-selftest/crlf'; New-Item -ItemType Directory -Force "$cr/skills/crafty" | Out-Null; git init -q $cr   # tracked CRLF, tracked LF, untracked CRLF
  foreach ($cf in 'skills/crafty/crafty.ps1', 'n.ps1') { [IO.File]::WriteAllText("$cr/$cf", "a`r`n") }; [IO.File]::WriteAllText("$cr/lf.md", "a`n"); git -C $cr -c core.autocrlf=false add skills lf.md
  [IO.File]::WriteAllText("$cr/NOTICE", "text`n"); [IO.File]::WriteAllText("$cr/run", "#!/bin/sh`necho ok`n")   # an extensionless file a desktop app would open; a #! script
  $cases += @(@('B', 'git fetch -q origin merge-requests/12/head:mr12', $true, 'local branch from an MR'), @('P', 'gh pr checkout 7', $true, 'local branch from an MR'),
    @('B', 'git fetch origin merge-requests/12/head && git diff origin/main...FETCH_HEAD; git fetch origin pull/3/head:refs/remotes/origin/pr3', $false, 'local branch from an MR'),
    @('B', 'git -C x worktree remove --force y', $true, 'wt remove -Dir'), @('B', 'git worktree list; git worktree prune', $false, 'wt remove -Dir'))
  if ($mc = @(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.checkout)" } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })[0]) {   # a configured main checkout
    $ef = @(Get-ChildItem -LiteralPath $mc -File | Select-Object -First 1).Name
    $cases += @(@('B', "echo x > $mc/kit-scratch-$PID.txt", $true, 'shared main checkout'), @('B', "cd $mc && git status > kit-scratch-$PID.txt", $true, 'shared main checkout'), @('E', "$mc/kit-scratch-$PID.md", $true, 'shared main checkout'),
      @('B', "git -C $mc status > $cr/s.txt; echo x >> $mc/$ef; echo x > $mc/sub/new.txt", $false, 'shared main checkout')) }
  $cases += @(@('B', "sed -Ei.b s/a/b/ $cr/skills/crafty/crafty.ps1", $true, 'use the Edit tool'), @('B', "sed -i s/a/b/ $cr/lf.md $cr/n.ps1; sed -n 1p $cr/skills/crafty/crafty.ps1; sed 's/ -i / /' $cr/skills/crafty/crafty.ps1", $false, 'use the Edit tool'))
  $bp = 'owner only'
  $cases += @(@('B', "setx $gbn 1", $true, $bp), @('B', "echo '{""env"":{""$gbn"":""1""}}' > $cr/settings.local.json", $true, $bp), @('B', "$gbn=1 node x.mjs; grep $gbn $cr/settings.json; git commit -m 'setx $gbn > settings.json'", $false, $bp), @('P', "Set-ItemProperty -Path x -Name $gbn -Value 1", $true, $bp), @('B', "grep x y; pwsh -c ""setx $gbn 1""", $true, $bp), @('B', "sed -i 's/}/,""$gbn"":1}/;s/a/b/' settings.json", $true, $bp), @('B', "git commit -m ""`$(setx $gbn 1)""", $true, $bp))
  $nr = Join-Path (Get-KitPath agents) 'guard-selftest/neutral'; if (-not (Test-Path "$nr/.git")) { git init -q -b selftest $nr }   # cwd: a repo of its own on an unprotected branch, never the kit (K63s)
  $env:KIT_GUARD_SELFTEST_ACTIVE = '1'; $env:KIT_LIVE_EDIT = $null
  $live = Split-Path (git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)
  $krt = [IO.Path]::GetFullPath((Get-KitRuntime)).Replace('\', '/'); $fail = 0
  foreach ($c in $cases) {
    $tool = @{ P = 'PowerShell'; B = 'Bash'; E = 'Edit'; A = 'apply_patch'; G = 'run_command' }[$c[0]]
    $v = $c[1].Replace('{KRTU}', ($krt -replace '[^/]+$', { $_.Value.ToUpper() })).Replace('{RTU}', '.RUNTIME').Replace('{KRTB}', ($krt -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() })).Replace('{KRT}', $krt).Replace('{WS}', (Split-Path $live)).Replace('{RT}', '.runtime').Replace('{KIT}', (Split-Path (Split-Path $PSScriptRoot))).Replace('{LIVE}', $live).Replace('{CR}', $cr)
    # cwd-independent results
    $hookIn = @{ tool_name = $tool; cwd = $nr; tool_input = $(if ($tool -eq 'Edit') { @{ file_path = $v } } else { @{ command = $v } }) }
    if ($tool -eq 'run_command') { $hookIn = @{ conversationId = 'selftest'; toolCall = @{ args = @{ CommandLine = $v } }; cwd = $hookIn.cwd } }
    $json = $hookIn | ConvertTo-Json -Compress -Depth 4
    $out = (& $PSCommandPath guard -Json $json) -join ''
    $denied = $out -match '"(permissionDecision|decision)":"deny"' -and $out -match $(if ($c.Count -gt 3) { [regex]::Escape($c[3]) } else { 'git stash is shared' })
    $ok = if ($c[2]) { $denied } else { $out -notmatch '"(permissionDecision|decision)":"deny"' }   # strict allow (K63s): a deny for any reason fails it
    if (-not $ok) { $fail++ }
    '{0} {1,-10} {2,-6} {3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $tool, $(if ($c[2]) { 'deny' } else { 'allow' }), (($c[1] -replace "`n", ' \n ') + $(if (-not $ok -and $out -match '(?:Reason|reason)":"([^"]{1,160})') { " <- $($Matches[1])" }))
  }
  "$($cases.Count - $fail)/$($cases.Count) passed"
  exit [int]($fail -gt 0)
}
$stdin = if ($Json) { $Json } elseif ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
if (-not "$stdin".Trim()) { exit 0 }
try { $in = $stdin | ConvertFrom-Json -ErrorAction Stop } catch {
  $one = "$stdin" -replace "[\r\n\t]+", ' '; $one = $one.Substring(0, [math]::Min(300, $one.Length))
  Write-KitLog guard deny @{ why = 'malformed hook input'; cmd = $one }
  if ($stdin -match '"toolCall"|"conversationId"') {
    @{ decision = 'deny'; reason = 'kit guard: hook input not JSON (logged: bossy.ps1 audit); retry' } | ConvertTo-Json -Compress
  } else {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = 'kit guard: hook input not JSON (logged: bossy.ps1 audit); retry' } } | ConvertTo-Json -Compress -Depth 4
  }
  exit 0
}
$isGravity = [bool]($in.toolCall -or $in.conversationId)
$cmd = if ($in.tool_input.command) { [string]$in.tool_input.command }
       elseif ($in.toolCall.args.CommandLine) { [string]$in.toolCall.args.CommandLine }
       elseif ($in.toolCall.args.command) { [string]$in.toolCall.args.command }
       elseif ($in.CommandLine) { [string]$in.CommandLine }
       else { '' }
$K = $PSScriptRoot
try { $kc = Read-KitText (Join-Path $K 'kit.local.json') | ConvertFrom-Json } catch {}
$protectedRx = Get-KitProtectedBranches -Rx -Any '\S+'

function Deny($why) {
  if ($in.session_id) {   # test runs must not raise a guard WATCH
    $one = $raw -replace "[\r\n\t]+", " // "
    if ($one.Length -gt 2000) { $one = $one.Substring(0, 1000) + ' /*...*/ ' + $one.Substring($one.Length - 1000) }
    Write-KitLog guard deny @{ session = "$($in.session_id)"; agentId = "$($in.agent_id)"; tool = "$($in.tool_name)"; why = $why; cmd = $one }
  }
  if ($isGravity) {
    @{ decision = 'deny'; reason = $why } | ConvertTo-Json -Compress
  } else {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  }
  exit 0
}
function GitCommon([string]$d) {
  $ceil = @("$env:GIT_CEILING_DIRECTORIES" -split [IO.Path]::PathSeparator | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') })
  for (; $d; $d = Split-Path $d) {
    if (($d -replace '\\', '/') -in $ceil) { return }
    $g = Join-Path $d '.git'
    if (Test-Path -LiteralPath $g -PathType Container) { return [IO.Path]::GetFullPath($g) }
    if ((Test-Path -LiteralPath $g -PathType Leaf) -and (Get-Content -LiteralPath $g -Raw) -match 'gitdir:\s*(.+?)\s*$') { return [IO.Path]::GetFullPath(($Matches[1] -replace '[\\/]worktrees[\\/][^\\/]+[\\/]?$', '')) }
  }
}
# the live kit clone runs every agent: edit via a kit worktree
$live = if (($lg = GitCommon (Split-Path (Split-Path $K)))) { Split-Path $lg }
$here = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
$liveOk = $env:KIT_LIVE_EDIT -eq '1' -or $cmd -match '(^|[\s;])(\$env:)?KIT_LIVE_EDIT\s*=\s*[''"]?1'
function InLive([string]$p, [string]$base) {
  if (-not $live -or -not $p -or $p -match '[$*?<>|`]') { return $null }
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return $null }; $p = Join-Path $base $p }
  $p = $p -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'   # Git Bash /d/x
  $rel = [IO.Path]::GetRelativePath($live, [IO.Path]::GetFullPath($p))
  if ($rel -notmatch '^\.\.([\\/]|$)|^\.git([\\/]|$)' -and -not [IO.Path]::IsPathRooted($rel)) { $rel }
}
# git-ignored own worktree; git in .runtime hits the live clone
function LiveIgnored([string]$rel) {
  $abs = Join-Path $live $rel; if (-not (Test-Path -LiteralPath $abs -PathType Container)) { return $false }
  $top = "$(git -C $abs rev-parse --show-toplevel 2>$null)".Trim()
  if (-not $top -or [IO.Path]::GetFullPath($top).TrimEnd('\', '/') -eq [IO.Path]::GetFullPath($live).TrimEnd('\', '/')) { return $false }
  git -C $live check-ignore -q -- $rel 2>$null; $LASTEXITCODE -eq 0
}
function LiveFile([string]$p, [string]$base) {
  $own = '^(' + [regex]::Escape((Split-Path (Get-KitRuntime) -Leaf)) + '|' + [regex]::Escape($script:KitPathMap.stateDir.Trim('/\')) + ')([\\/]|$)'
  if (($rel = InLive $p $base) -and $rel -ne '.' -and $rel -notmatch $own) { git -C $live check-ignore -q -- $rel 2>$null; $LASTEXITCODE -eq 1 }
}
# Git Bash sed -i rewrites tracked CRLF kit files LF
function CrlfKitFile([string]$p, [string]$base) {
  if (-not $p -or $p -match '[$*?<>|`]') { return }
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return }; $p = Join-Path $base $p }
  $p = [IO.Path]::GetFullPath(($p -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'))
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return }
  $top = "$(git -C (Split-Path $p) rev-parse --show-toplevel 2>$null)".Trim()
  if (-not $top -or -not (Test-Path -LiteralPath (Join-Path $top 'skills/crafty/crafty.ps1'))) { return }
  git -C $top ls-files --error-unmatch -- $p 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { return }
  if ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p)).Contains("`r`n")) { $p }
}
$liveWhy = 'the live kit runs every agent: edit your kit worktree (crafty.ps1 wt) and push; the coordinator pulls'
# .runtime path kind: kit (<kit>'s, $var, ~), stray (<= 2 folders into the workspace, no kit: lint RUNTIME-STRAY), other
$rtFull = [IO.Path]::GetFullPath((Get-KitRuntime)).TrimEnd('\', '/'); $rtLeaf = Split-Path $rtFull -Leaf
$wsRoot = Split-Path $(if ($live) { $live } else { $script:KitRoot })
function FullOf([string]$p, [string]$base) {
  if (-not $p -or $p -match '[$%~*?<>|`]') { return }
  $p = $p -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return }; $p = Join-Path $base $p }
  [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}
function Under([string]$p, [string]$root) { $r = [IO.Path]::GetRelativePath($root, $p); $r -eq '.' -or ($r -notmatch '^\.\.([\\/]|$)' -and -not [IO.Path]::IsPathRooted($r)) }
function RuntimeKind([string]$tok, [string]$base) {
  if (-not ($f = FullOf $tok $base) -or (Under $f $rtFull)) { return 'kit' }
  $up = Split-Path $f
  if ((Under $up $wsRoot) -and @([IO.Path]::GetRelativePath($wsRoot, $up) -split '[\\/]' | Where-Object { $_ -ne '.' }).Count -le 2 -and -not (Test-Path -LiteralPath (Join-Path $up 'skills/crafty/crafty.ps1'))) { 'stray' } else { 'other' }
}
function RuntimeKinds([string]$seg, [string]$base) {
  $n = ($seg -replace '\\', '/') -replace '(?<![\w:])/([A-Za-z])/', '$1:/'
  if ($n -match ([regex]::Escape($rtFull.Replace('\', '/')) + '(?=[/''"\s;|)]|$)')) { 'kit' }   # a kit path with spaces
  [regex]::Matches($seg, "(?i)(?<![\w.-])[^\s'""=]*(?<![\w.-])$([regex]::Escape($rtLeaf))(?=[\\/'""\s;|)]|$)") | ForEach-Object { RuntimeKind $_.Value $base }
}
$segBase = $here
$edits = @($in.tool_input.file_path, $in.tool_input.notebook_path) + @([regex]::Matches("$(if ($in.tool_name -eq 'apply_patch') { $cmd })", '(?m)^\*\*\* (?:Add|Update|Delete) File: (.+?)\s*$|^\*\*\* Move to: (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value })
foreach ($e in $edits) { if (-not $liveOk -and (LiveFile $e $here)) { $raw = "$($in.tool_name) $e"; Deny $liveWhy } }
# the crash switch: the owner's (K67); a commit or search is no write
$bpw = '(?i)\bsetx\b|SetEnvironmentVariable|\breg(\.exe)?\s+add\b|(New|Set)-ItemProperty|(>|\btee\b|\bsed\s+-i|Set-Content|Add-Content|Out-File).*(settings[\w.-]*\.json|\.bashrc|\$PROFILE)'
if ("$cmd $($in.tool_input.content) $($in.tool_input.new_string) $($in.tool_input.edits.new_string)" -match $gbn -and (($edits -match 'settings[\w.-]*\.json$') -or @([regex]::Matches(($cmd -replace '\\\r?\n|`\r?\n', ' '), '(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[^;&|\r\n])+').Value | Where-Object { $_ -match $bpw -and -not ($_ -match '^\s*(git\b.*\b(commit|tag)\b|grep|rg|Select-String)\b' -and $_ -notmatch '\$\(|`|<\(') }).Count)) {
  $raw = "$($in.tool_name) $($edits -join ' ') $cmd"; Deny "kit guard: $gbn (lets guard crashes through) is set by the owner only" }
$strayWhy = "a $rtLeaf outside the kit (a relative path from the wrong folder): agent files go under & $($KitCmd.dev) dir -Agent <id> (<kit>/$rtLeaf/work/agents/<id>/)"
foreach ($e in $edits) { if ((RuntimeKinds " $e" $here) -contains 'stray') { $raw = "$($in.tool_name) $e"; Deny "kit guard: $e is $strayWhy" } }
# scratch at a shared main checkout's top (repos[].checkout) outlives its agent
$mainRoots = @(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.checkout)" } | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') })
$scratchWhy = "is a new file at the top of a shared main checkout: write scratch under & $($KitCmd.dev) dir -Agent <id> -Name <file>"
function MainScratch([string]$p, [string]$base) {
  if (-not $p -or -not $mainRoots.Count -or $p -match '[$*?<>|`]') { return $false }
  $p = $p -replace '^/([A-Za-z])/', '$1:/'
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return $false }; $p = Join-Path $base $p }
  $full = [IO.Path]::GetFullPath($p); (Split-Path $full) -in $mainRoots -and -not (Test-Path -LiteralPath $full)
}
foreach ($e in $edits) { if (MainScratch $e $here) { $raw = "$($in.tool_name) $e"; Deny "kit guard: $e $scratchWhy" } }
# shared temp body / desc files got swapped between agents
$tmpRoots = @('/tmp', $env:TEMP, $env:TMP, [IO.Path]::GetTempPath()) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') } | Select-Object -Unique   # arch-ok: guard deny list
$tmpRx = '(?i)(?:^|[\s''"=<>(,@])(?:' + ((@($tmpRoots | ForEach-Object { [regex]::Escape($_) }) + '\$env:(?:TEMP|TMP)', '%(?:TEMP|TMP)%', '\$\{?TMPDIR\}?') -join '|') + ')[\\/](?<f>[^\s''"\\/;|&)]*(?:body|desc|comment|summary|message|msg)[^\s''"\\/;|&)]*)(?=$|[\s''";|&)])'
$tmpHit = @(@($edits | Where-Object { $_ } | ForEach-Object { " $_" }) + $(if ($cmd) { $cmd }) | ForEach-Object { if ($_ -match $tmpRx) { $Matches.f } })
if ($tmpHit) { $raw = "$($in.tool_name) $($tmpHit[0])"; Deny "kit guard: $($tmpHit[0]) is in the shared temp root (other agents use the same names): write it under & $($KitCmd.dev) dir -Agent <id> -Name $($tmpHit[0])" }
# files at a drive root or outside every root outlive their agent
$uh = [Environment]::GetFolderPath('UserProfile')
$writeRoots = @(@($wsRoot, $script:KitRoot, (Get-KitRuntime), (Split-Path (Get-KitPath tracking)), $KitConf.ReposRoot) + @($KitConf.WorktreeRoots) + $mainRoots + @($tmpRoots) +
  @(@(Get-KitSetting 'guard.writeRoots' @()) | ForEach-Object { "$_" -replace '^~(?=[\\/]|$)', $uh }) + "$uh/.claude" + "$uh/Downloads" |
  Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/') } | Where-Object { $_ } | Select-Object -Unique)
function StrayWrite([string]$p, [string]$base) {
  if (-not $p -or $p -match '[$%*?<>|`]|^[A-Za-z]:(?![\\/]|$)|^(nul|-)$|^[\\/]dev[\\/](null|stderr|stdout|tty)$') { return }
  # Windows "/x" outside Git Bash = the cwd drive's root (2026-11-22: a test's "$empty/one.txt" wrote D:\one.txt); in Git Bash, the Git install dir
  $driveRel = $IsWindows -and $p -match '^[\\/](?![\\/]|[A-Za-z]([\\/]|$))'
  if ($driveRel -and ($in.tool_name -eq 'Bash' -or -not $base)) { return }
  $p = ($p -replace '^~(?=[\\/]|$)', $uh) -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'
  if ($driveRel) { $p = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($base)).TrimEnd('\', '/') + $p }
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return }; $p = Join-Path $base $p }
  $f = [IO.Path]::GetFullPath($p); $r0 = [IO.Path]::GetPathRoot($f); if ($f.Length -gt $r0.Length) { $f = $f.TrimEnd('\', '/') }; $par = [IO.Path]::GetDirectoryName($f)
  if (@($writeRoots | Where-Object { Under $f $_ }).Count) { return }
  if (-not $par -or $par -eq $r0) { return 'writes at a drive root' }
  if (-not (Test-Path -LiteralPath $f) -and -not (GitCommon $par)) { 'is a new file outside the workspace and every repo' }
}
$rootWhy = "agent files go under & $($KitCmd.dev) dir -Agent <id> -Name <file>; an owner-asked place: guard.writeRoots"
foreach ($e in $edits) { if (($sk = StrayWrite $e $here)) { $raw = "$($in.tool_name) $e"; Deny "kit guard: $e $sk ($rootWhy)" } }
# tester evidence written from a kit folder (2026-11-21: skills/shots/) belongs to the run
$shotsWhy = "is tester evidence inside the kit's skills/: write it under the run's output folder (<outDir>/shots|evidence) or & $($KitCmd.dev) dir -Kind evidence -Item <task>"
function KitEvidenceWrite([string]$p, [string]$base) {
  if (-not ($f = FullOf $p $base)) { return $false }
  foreach ($kr in @($script:KitRoot, $live) | Where-Object { $_ }) {
    $sk = Join-Path $kr 'skills'; if (-not (Under $f $sk)) { continue }
    if (@([IO.Path]::GetRelativePath($sk, $f) -split '[\\/]' | Select-Object -SkipLast 1) -match '^(shots|screenshots|evidence)$') { return $true }
  }
  $false
}
foreach ($e in $edits) { if (KitEvidenceWrite $e $here) { $raw = "$($in.tool_name) $e"; Deny "kit guard: $e $shotsWhy" } }
# runtime / state writes need a _paths name (guard.layout)
$layout = @(@((Get-KitRuntime), 'runtime'), @((Split-Path (Get-KitPath tracking)), 'durable'))
function OffLayout([string]$p, [string]$base) {
  if (-not $p -or $p -match '[$*?<>|`]') { return }
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return }; $p = Join-Path $base $p }
  $p = [IO.Path]::GetFullPath(($p -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'))
  foreach ($r in $layout) {
    $rel = [IO.Path]::GetRelativePath($r[0], $p).Replace('\', '/'); if ($rel -match '^\.\.(/|$)|^\.$' -or [IO.Path]::IsPathRooted($rel)) { continue }
    if (-not @((Get-KitProps (Get-KitMember $script:KitPathMap ($r[1]))).Value | ForEach-Object { ([string]$_).TrimEnd('/') } | Where-Object { $rel -eq $_ -or ($_ -notin 'work', 'cache', 'logs' -and $rel.StartsWith("$_/")) }).Count) { "$($r[1])/$rel" }
  }
}
# Deny here, outside captured output
function LayoutCheck {
  if (-not $off) { return }
  $lw = "kit layout: $(@($off | Select-Object -Unique) -join ', ') is no kit place: agent files go under & $($KitCmd.dev) dir -Agent <id> [-Item <task>] (work/agents/<id>/) or dir -Kind evidence -Item <task> (work/evidence/<task>/)"
  if ($kc.guard.layout -eq 'block') { $raw = "$($in.tool_name) $($off -join ' ')"; Deny $lw }
  if ($in.session_id) { Write-KitLog guard warn @{ session = "$($in.session_id)"; tool = "$($in.tool_name)"; why = $lw } }; $script:layoutNote = $lw
}
$off = @(foreach ($e in $edits) { OffLayout $e $here })
if (-not $cmd) {
  LayoutCheck
  if ($isGravity) { @{ decision = 'allow' } | ConvertTo-Json -Compress } elseif ($script:layoutNote) { @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $script:layoutNote } } | ConvertTo-Json -Compress -Depth 4 }
  exit 0
}

# quoted text and heredocs are data
$raw = $cmd
function StripDocs([string]$t) {
  $t = [regex]::Replace($t, '(?ms)^([^\n]*?)<<-?\s*([''"]?)(\w+)\2[^\n]*\n.*?^\s*\3\s*$', {
      param($m) if ($m.Groups[1].Value -match '\b(ba|z|da)?sh\b|pwsh|powershell') { $m.Value } else { $m.Groups[1].Value + '<<heredoc' } })
  [regex]::Replace($t, '(?s)@''\r?\n.*?\r?\n''@|@"\r?\n.*?\r?\n"@', '""')
}
function StripData([string]$t) { [regex]::Replace((StripDocs $t), '"(?:[^"\\]|\\.)*"|''[^'']*''', '""') }
# PowerShell command ASTs; $null = parse error
function CmdAsts([string]$t) {
  $tk = $null; $er = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$tk, [ref]$er)
  if (@($er).Count) { return $null }
  , @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
}
$cmd = StripData $cmd
function StashArgs($words) {
  for ($i = 0; $i -lt $words.Count; $i++) {
    $w = [string]$words[$i]
    if ($w -in '-C', '-c', '--git-dir', '--work-tree', '--namespace') { $i++; continue }
    if ($w -like '-*') { continue }
    return $w -eq 'stash' -and [string]$words[$i + 1] -notin 'list', 'show'   # read-only verbs
  }
  $false
}
function Test-GitStash([string]$text, [string]$tool, [int]$depth = 0) {
  if ($depth -gt 3) { return $false }
  if ($tool -ne 'Bash') {
    $cas = CmdAsts $text
    if ($null -ne $cas) {
      foreach ($ca in $cas) {
        $words = @($ca.CommandElements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value } else { $_.Extent.Text } })
        if (-not $words.Count) { continue }
        $rest = @($words | Select-Object -Skip 1)
        if ($words[0] -match '(^|[\\/])git(\.exe)?$') { if (StashArgs $rest) { return $true }; continue }
        if ($words[0] -match '(^|[\\/])(pwsh|powershell|(ba|z|da)?sh|cmd)(\.exe)?$') {
          $flag = [array]::FindIndex([string[]]$rest, [Predicate[string]] { param($x) $x -match '^(-c|-Command|/c)$' })
          if ($flag -ge 0 -and $flag + 1 -lt $rest.Count) {
            $inner = (@($rest | Select-Object -Skip ($flag + 1)) -join ' ')
            if (Test-GitStash $inner $(if ($words[0] -match 'pwsh|powershell') { 'PowerShell' } else { 'Bash' }) ($depth + 1)) { return $true }
          }
        }
      }
      return $false
    }
  }
  foreach ($m in [regex]::Matches($text, '\b(?:(?:ba|z|da)?sh|pwsh|powershell)(?:\.exe)?\s+(?:-\S+\s+)*?-(?:c|Command)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')')) {
    $inner = $m.Groups[1].Value + $m.Groups[2].Value
    if (Test-GitStash $inner $(if ($m.Value -match '^(pwsh|powershell)') { 'PowerShell' } else { 'Bash' }) ($depth + 1)) { return $true }
  }
  $t = [regex]::Replace((StripData $text), '(?m)(^|\s)#.*$', '$1')
  $t -match '(?m)(^|[;&|({`\n]|\$\()\s*(\w+=\S*\s+)*(\S*[\\/])?git(\.exe)?\s+((-C|-c|--git-dir|--work-tree|--namespace)\s+\S+\s+|-\S+\s+)*stash\b(?!\s+(list|show)\b)'
}
# work/ holds in-flight runs
function ActiveWork {
  if ($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1') { return 'work/selftest' }
  foreach ($n in 'board', 'phones', 'waves', 'qa-runs', 'qa-seats') {
    $d = Get-KitPath $n
    if ((Test-Path $d) -and @(Get-ChildItem $d -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-3) } | Select-Object -First 1).Count) { "work/$n" }
  }
}
function DeleteSegments([string]$t) {
  $t = [regex]::Replace((StripDocs $t),'"((?:[^"\\]|\\.)*)"|''([^'']*)''', {
      param($m) $v = $m.Groups[1].Value + $m.Groups[2].Value
      if ($v -match '^\s*([A-Za-z]:[\\/]|[\\/~$]|\.{1,2}[\\/])' -or $v -match '\brmtree\b|Directory\]::Delete|Remove-Item|rimraf') { ' ' + ($v -replace '[;|&\r\n]', ' ') + ' ' } else { '""' } })
  @($t -split '\r?\n|;|&&|\|\||\|' | Where-Object { $_.Trim() })
}
$end = '[''"]?(\s|;|\||\)|$)'
$delWord = '(Remove-Item|(^|[\s;|&(`])(rm|rmdir|rd|del)(\s|$)|rimraf|shutil\.rmtree|Directory\]::Delete)'   # a command word only
if ($env:KIT_ALLOW_RUNTIME_DELETE -ne '1') {
  $inRuntime = $false; $rt = '(' + [regex]::Escape($rtLeaf) + ')'; $sd = [regex]::Escape($script:KitPathMap.stateDir.Trim('/\'))
  foreach ($seg in DeleteSegments $raw) {
    if ($seg -match '^\s*(cd|Set-Location|sl|pushd|Push-Location)\s+(?<to>.*?)\s*$') {
      $to = $Matches.to.Trim('''"'); $inRuntime = $seg -match "$rt([\\/]+work)?[\\/]*\s*`$" -and (RuntimeKinds $seg $segBase) -contains 'kit'
      $segBase = if (($nb = FullOf $to $segBase)) { $nb } else { $null }; continue }
    if ($seg -notmatch $delWord) { continue }
    if ($seg -match ("($sd([\\/][\w.-]+)*|tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)" + $end)) {
      Deny 'That is durable local kit state (task tracking, learning signals): never delete it; the lead (coordinator) may.' }
    # cleanup, or one named file (not recursive): no wipe of work/
    if ($seg -match 'cleanup\.ps1|bossy\.ps1["'']?\s+cleanup' -or ($seg -cnotmatch '\s-[fvidR]*[rR][fvidR]*(\s|$)' -and $seg -notmatch '(?i)-Recurse|rmtree|(^|\s)(rmdir|rd)\s|\*' -and $seg -match ("work[\\/]+[\w-]+\.\w{1,8}" + $end))) { continue }
    if (($seg -match ("$rt([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*" + $end) -and (RuntimeKinds $seg $segBase) -contains 'kit') -or
        ($inRuntime -and $seg -match '\s[''"]?(\.[\\/])?(work([\\/]+[\w.-]+)?|\*|\.)[\\/]*[''"]?(\s|$)')) {
      $act = @(ActiveWork)
      if ($act.Count) { Deny "The runtime's work/ holds runs in progress ($($act -join ', ') written < 3 h ago): do not delete it. cache/ and logs/ may go; bossy.ps1 cleanup prunes old work; a wipe is for the lead (coordinator)." }
    }
  }
}
$segBase = $here
foreach ($seg in DeleteSegments $raw) {
  if ($seg -match '^\s*(cd|Set-Location|sl|pushd|Push-Location)\s+(?<to>.*?)\s*$') { $segBase = FullOf $Matches.to.Trim('''"') $segBase; continue }
  # only written paths; reads pass
  $wrote = @([regex]::Matches($seg, '(?<![\d&>])>{1,2}(?!&)\s*(?<t>\S+)') | ForEach-Object { $_.Groups['t'].Value })
  if ($seg -match '(^|[\s(`])(cp|mv|Copy-Item|Move-Item)\s') { $wrote += ($seg.TrimEnd() -split '\s+')[-1] }
  if ($seg -match '(^|[\s(`])(?<v>mkdir|md|New-Item|ni|touch|tee|Out-File|Set-Content|Add-Content)\s+(?<a>.*)$') { $wrote += @($Matches.a -split '\s+' | Where-Object { $_ -and $_ -notmatch '^-' }) }
  $wrote += @([regex]::Matches($seg, '(?i)::(Write|Append)All\w*\(\s*(?<t>[^,\s)]+)') | ForEach-Object { $_.Groups['t'].Value })
  # git init <dir> / git clone <url> <dir> make a repo there (no -C: a relative dir is the cwd's)
  $gitDest = @(); if ($seg -match '(^|[\s(`])git(\.exe)?\s+(-c\s+\S+\s+)*(?<v>init|clone)\s+(?<a>.*)$' -and $seg -cnotmatch '\s-C\s') {
    $gitVerb = $Matches.v; $gitPos = @(); $gitSkip = $false; foreach ($gt in @($Matches.a -split '\s+' | Where-Object { $_ })) { if ($gitSkip) { $gitSkip = $false } elseif ($gt -match '^(-[bocju]|--(branch|origin|depth|reference|template|config|separate-git-dir|jobs|filter|upload-pack|object-format|shallow-since)|\d*>{1,2}|&>)$') { $gitSkip = $true } elseif ($gt -notmatch '^-|^\d*>|^&>') { $gitPos += $gt } }
    if ($gitPos.Count -and ($gitVerb -eq 'init' -or $gitPos.Count -ge 2) -and $gitPos[-1] -notmatch '://|^[\w.-]+@[\w.-]+:') { $gitDest = @($gitPos[-1]); $wrote += $gitDest } }
  if (@($wrote | ForEach-Object { RuntimeKinds " $($_.Trim('''"'))" $segBase }) -contains 'stray') { Deny "kit guard: that writes $strayWhy" }
  foreach ($x in $wrote) { if (MainScratch $x.Trim('''"') $segBase) { Deny "kit guard: $x $scratchWhy" } }
  foreach ($x in @(@($wrote -match '[\\/.]') + $gitDest | Select-Object -Unique)) { if (($sk = StrayWrite $x.Trim('''"') $segBase)) { Deny "kit guard: $x $sk ($rootWhy)" } }
  foreach ($x in $wrote -match '[\\/]') { if (KitEvidenceWrite $x.Trim('''"') $segBase) { Deny "kit guard: $x $shotsWhy" } }
}
# a bare remove leaves junction skeletons no repo lists, and the branch
if ($raw -match '(?m)(^|[;&|(\n])\s*(\S*[\\/])?git(\.exe)?\s+((-C|-c)\s+("[^"]*"|\S+)\s+)*worktree\s+remove\b') { Deny "kit guard: use & $($KitCmd.dev) wt remove -Dir <worktree>: it unlinks shared folders first, prunes and deletes the branch once nothing is lost (a bare git worktree remove leaves junctions behind)" }
# host CLIs from the git-host adapters (lib.ps1 Get-KitHostCli: exe, MR noun, option names), not literals
$hostClis = @(Get-KitHostCli); $hcExe = (@($hostClis.exe | Select-Object -Unique | ForEach-Object { [regex]::Escape($_) }) -join '|'); $hcNoun = (@($hostClis.noun | Select-Object -Unique | ForEach-Object { [regex]::Escape($_) }) -join '|')
# an MR fetched into a local branch (mr8520) outlives its reader
if ($raw -match '(?m)(^|[;&|(\n])\s*(\S*[\\/])?git(\.exe)?\s+((-C|-c)\s+\S+\s+)*fetch\b[^;&|\n]*\b(merge-requests|pull)/\d+/head:(?!refs/remotes/)\S' -or ($hcExe -and $raw -match "(?m)(^|[;&|(\n])\s*(\S*[\\/])?($hcExe)(\.exe)?\s+($hcNoun)\s+checkout\b")) {
  Deny 'kit guard: that makes a local branch from an MR, which outlives you: git fetch origin merge-requests/<n>/head (GitHub: pull/<n>/head), then read FETCH_HEAD (git diff origin/<target>...FETCH_HEAD); to change it: crafty.ps1 wt new' }
$tn = if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' }
if (Test-GitStash $raw $tn) { Deny 'git stash is shared across worktrees (another agent can pop it): make a WIP commit (crafty.ps1 wt commit -Message "wip: ...")' }
# hand-made task branches skip the prior-work gate of wt lease / new
if (($trx = Get-KitTaskTagRx) -and $raw -match '(?m)(^|[;&|(\n])\s*(\S*[\\/])?git(\.exe)?\s+((-C|-c)\s+\S+\s+)*(checkout\s+(-\S+\s+)*-[bB]|switch\s+(-\S+\s+)*-[cC]|worktree\s+add\s+(\S+\s+)*?-[bB]|branch(\s+-[fct]\S*)*)\s+(?<br>[^\s;|&]+)') {
  $br = $Matches.br; if ($br -match $trx) { try { Assert-KitPrior $Matches.id '' "git branch $br" '' } catch { Deny "kit guard: $($_.Exception.Message -replace '-Override', 'crafty.ps1 wt lease -Override')" } }
}
# Git Bash /d/x reaches Windows programs as \d\x; MSYS skips strings, JSON, env, code
function Find-MsysPath([string]$text, [string]$tool, [int]$depth = 0) {
  if ($depth -gt 3) { return }
  $drive = '(?<![\w.:/~\\})\]])/(?<d>[a-zA-Z])/(?<r>[\w.$-][^\s''"`;|&<>(){}\[\],]*)'
  # a heredoc body is its opener's data
  if ($tool -eq 'Bash') { $text = [regex]::Replace($text, '(?ms)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n(.*?)^\s*\2\s*$', { param($hd) "<<doc '" + ($hd.Groups[4].Value -replace "['\r\n]", ' ') + "'" + $hd.Groups[3].Value }) }
  foreach ($seg in (Split-CommandSegments $text $tool)) {
    if (-not ($seg -match $segRx)) { continue }
    $pre = $Matches[1]; $rest = $Matches[3]; $leaf = $Matches[2].Trim('''"') -replace '^.*[\\/]', ''
    if ($leaf -match '^((ba|z|da)?sh|pwsh|powershell|cmd)(\.exe)?$') {
      $inTool = if ($leaf -match '^(pwsh|powershell)') { 'PowerShell' } else { 'Bash' }
      foreach ($im in [regex]::Matches($rest, '(?:^|\s)(?:-c|-Command|/c)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')')) { if (($hit = Find-MsysPath ($im.Groups[1].Value + $im.Groups[2].Value) $inTool ($depth + 1))) { return $hit } }
      continue
    }
    $chk = "$pre $rest" -replace '(?<![\w"''])\d*(?:>>?|<)\s*[^\s;|&]+', ' '
    # curl: only file options and @file are paths
    if ($leaf -match '^curl(\.exe)?$') { $chk = ' ' + (@([regex]::Matches($chk, '(?:(?<=\s)(?:-[a-zA-Z]*[oTK]|--output|--upload-file|--config)(?:\s+|=)?|@)[''"]?(?<f>/[^\s''"]+)') | ForEach-Object { $_.Groups['f'].Value }) -join ' ') }
    if ($leaf -match '^(node|python[\d.]*|py|java|mvn|mvnw|mvnd|npx|adb|ffmpeg|curl)(\.exe|\.cmd)?$' -and $chk -match $drive) { return @(($leaf -replace '\.(exe|cmd)$', ''), $Matches[0], "$($Matches.d.ToUpper()):/$($Matches.r)") }
  }
}
# shell text -> command segments (quote- and comment-aware); $segRx: 1 = prefix words, 2 = command word, 3 = rest
$segRx = '(?s)^\s*((?:(?:\w+=(?:"[^"]*"|''[^'']*''|[^\s"''])*|do|then|else|elif|time|exec|nohup|env|xargs|timeout|command|sudo|\{|!|\d+[smh]?|-\S+)\s+)*)("[^"]+"|''[^'']+''|[^\s"'']+)(.*)$'
function Split-CommandSegments([string]$text, [string]$tool) {
  $segs = [System.Collections.Generic.List[string]]::new(); $sb = [Text.StringBuilder]::new(); $quote = ''
  for ($i = 0; $i -lt $text.Length; $i++) {
    $ch = [string]$text[$i]
    if ($quote) {
      if ($ch -eq '\' -and $quote -eq '"' -and $tool -eq 'Bash' -and $i + 1 -lt $text.Length) { [void]$sb.Append($ch); $i++; $ch = [string]$text[$i] } elseif ($ch -eq $quote) { $quote = '' }
      [void]$sb.Append($ch); continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; [void]$sb.Append($ch); continue }
    if ($ch -eq '#' -and $tool -eq 'Bash' -and ($sb.Length -eq 0 -or [char]::IsWhiteSpace($sb[$sb.Length - 1]))) { $nl = $text.IndexOf("`n", $i); $i = if ($nl -lt 0) { $text.Length } else { $nl - 1 }; continue }   # a shell comment runs nothing
    if ($ch -in ';', '|', '&', "`n", '(', ')' -or ($tool -eq 'Bash' -and $ch -eq '`')) { $segs.Add($sb.ToString()); [void]$sb.Clear(); continue }
    [void]$sb.Append($ch)
  }
  $segs.Add($sb.ToString())
  , $segs
}
if (($mp = Find-MsysPath $raw $tn)) { Deny "kit guard: $($mp[0]) gets the Git Bash path $($mp[1]), which a Windows program reads as $($mp[1] -replace '/', '\') on the current drive (a stray tree). Use $($mp[2]): Windows paths (D:/... or D:\..., or the crafty.ps1 dir output) in arguments, JSON, env vars and code." }
# Git for Windows opens help in the owner's browser
if ($IsWindows -and $cmd -match '(?m)(^|[;&|({\n]|\$\()\s*(\S*[\\/])?git(\.exe)?\s+((-C|-c)\s+\S+\s+)*(help\s+(?!-[ag]\b)\S|[\w-]+\s+([^|;&\r\n]*\s)?--help\b)') { Deny "git help <cmd> / git <cmd> --help opens the manual in the owner's browser on Windows: use git <cmd> -h (usage in the terminal)" }
if ($cmd -match '\badb(\.exe)?\b[^|;&]*\bkill-server\b') { Deny 'Never adb kill-server: it drops every lane other agents test on. Reconnect your phone only (adb -s <serial> ...) or ask the lead (phoney.ps1 avd reset).' }
# a whole-drive search outlives its agent at full CPU (an orphaned find / starved every local-env start)
function Find-DriveRootSearch([string]$text, [string]$tool, [int]$depth = 0) {
  if ($depth -gt 3) { return }
  $rootRx = '^(/+(\.\.?/*)*\*?|/+(mnt/|cygdrive/)?[a-zA-Z]/*(\.\.?/*)*\*?|[a-zA-Z]:[\\/]*|[a-zA-Z]:[\\/]+[^\\/]*[*?][^\\/]*|\\+)$'
  if ($tool -eq 'Bash') { $text = [regex]::Replace($text, '(?ms)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n(.*?)^\s*\2\s*$', { param($hd) '<<doc' + $hd.Groups[3].Value }) }
  $atRoot = $false   # cd / then find . = the drive
  foreach ($seg in (Split-CommandSegments $text $tool)) {
    if (-not ($seg -match $segRx)) { continue }
    $rest = $Matches[3]; $leaf = ($Matches[2].Trim('''"') -replace '^.*[\\/]', '' -replace '\.(exe|cmd)$', '').ToLower()
    if ($leaf -match '^(cd|pushd|chdir|sl|set-location)$') { $atRoot = "$(@([regex]::Matches($rest, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value.Trim('''"') } | Where-Object { $_ -notmatch '^-' -and -not ($tool -eq 'cmd' -and $_ -match '^/\w$') })[0])" -match $rootRx; continue }
    if ($leaf -match '^((ba|z|da)?sh|pwsh|powershell)$') {
      $inTool = if ($leaf -match '^(pwsh|powershell)') { 'PowerShell' } else { 'Bash' }
      foreach ($im in [regex]::Matches($rest, '(?:^|\s)(?:-c|-Command)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')')) { if (($hit = Find-DriveRootSearch ($im.Groups[1].Value + $im.Groups[2].Value) $inTool ($depth + 1))) { return $hit } }
      continue
    }
    $words = @([regex]::Matches($rest, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value.Trim('''"') })
    if ($leaf -eq 'cmd') { $ci = [array]::FindIndex([string[]]$words, [Predicate[string]] { param($w) $w -match '^/+[ck]$' }); if ($ci -ge 0 -and ($hit = Find-DriveRootSearch ($words[($ci + 1)..($words.Count)] -join ' ') 'cmd' ($depth + 1))) { return $hit }; continue }
    $paths = @(); $scan = $true
    if ($leaf -eq 'find') {   # paths come before the first expression word
      $i = 0; while ($i -lt $words.Count -and $words[$i] -cmatch '^-([HLP]|O\d|D)$') { $i += 1 + [int]($words[$i] -eq '-D') }
      while ($i -lt $words.Count -and $words[$i] -notmatch '^(-|\\?\(|!)') { $paths += $words[$i]; $i++ }
      for (; $i -lt $words.Count; $i++) {   # -exec grep -r x / runs a search of its own
        if ($words[$i] -notmatch '^-(exec|execdir|ok|okdir)$') { continue }
        $sub = @(); for ($i++; $i -lt $words.Count -and $words[$i] -notmatch '^(\\?;|\+|\\)$'; $i++) { $sub += $words[$i] }
        if (($hit = Find-DriveRootSearch ($sub -join ' ') 'Bash' ($depth + 1))) { return $hit }
      }
    } elseif ($leaf -match '^([ef]?grep|rg|ag|ack|fd)$') {   # pattern first unless -e / -f / --files
      if ($leaf -match 'grep' -and -not ($words -cmatch '^(-[a-zA-Z]*[rR][a-zA-Z]*|--(dereference-)?recursive|--directories=recurse)$')) { continue }
      $pos = @(); $given = $false
      for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w -cmatch '^(-[ef]|--regexp|--file|--files)$') { $given = $true }
        if ($w -cmatch '^(-[efgtTmABCMjd]|--(regexp|file|glob|iglob|type|type-not|max-count|max-depth|context|before-context|after-context|include|exclude|exclude-dir|include-dir|max-columns|max-filesize|threads|sort|sortr|colors|engine|replace))$') { $i++; continue }
        if ($w -notmatch '^-') { $pos += $w }
      }
      $paths = if ($given) { $pos } else { @($pos | Select-Object -Skip 1) }
    } elseif ($leaf -match '^(ls|dir|gci|get-childitem)$') {
      $rec = @($words | Where-Object { $_ -cmatch '^(-[a-zA-Z]*R[a-zA-Z]*|--recursive)$' -or $_ -match '^(/s|-rec\w*)$' -or ($tool -ne 'Bash' -and $_ -match '^-r$') }).Count
      $scan = $rec -gt 0; if ($rec) { $paths = @(for ($i = 0; $i -lt $words.Count; $i++) { if ($words[$i] -match '^-(filter|include|exclude|depth|attributes)$') { $i++ } elseif ($words[$i] -notmatch '^-') { $words[$i] } }) }
    } elseif ($leaf -eq 'where') {
      $ri = [array]::FindIndex([string[]]$words, [Predicate[string]] { param($w) $w -match '^/r$' }); $scan = $ri -ge 0; if ($scan -and $ri + 1 -lt $words.Count) { $paths = @($words[$ri + 1]) }
    } else { $scan = $false }
    if ($atRoot -and $scan -and ($rel = @(@($paths | Where-Object { $_ -match '^(\.[\\/]*|\*)$' }) + @(if (-not $paths.Count) { '.' }))[0])) { return @($leaf, "$rel after cd to a drive root") }
    if (($root = @($paths | Where-Object { $_ -match $rootRx })[0])) { return @($leaf, $root) }
  }
}
if (($ds = Find-DriveRootSearch $raw $tn)) { Deny "kit guard: that $($ds[0]) searches a whole drive ($($ds[1])): it runs for hours at full CPU and outlives you (an orphaned find / starved every local-env start). Search a scoped path: the Glob / Grep tools on the repo, the kit or ~/.claude (e.g. Glob **/SKILL.md in ~/.claude/skills), or name the folder (find <repo> -name x)." }
$hl = "GUI windows on the owner's screen are not allowed (headless rule)."
if ($hcExe -and $cmd -match "(?m)(^|[;&|({\n]|\`$\()\s*(\S*[\\/])?($hcExe)(\.exe)?\s+" + '(browse\b(?![^|;&\r\n]*\s(-n|--no-browser)\b)|(?!(run|workflow)\s)[^|;&\r\n]*\s(--web|-w)(?=[\s=;|&)]|$))') { Deny "the git-host CLI's --web, -w and browse open the owner's browser: read it in the terminal (its view verb, --json). $hl" }
# raw MR create / merge skips track add (KIT_NO_TASK=<reason>)
$mrRx = '(?m)(?:^|[;&|({\n]|\$\()\s*(?:&\s*)?(?:\w+=(?:"[^"]*"|''[^'']*''|\S*)\s+)*(?:\S*[\\/])?(?<tool>' + $hcExe + ')(?:\.exe)?\s+(?:' + $hcNoun + ')\s+(?<verb>create|new|merge)\b'
if ($KitConf.TrackerType -ne 'none' -and $hcExe -and $cmd -match $mrRx) {
  # same-length copies: $mrJ joins continuations, $mrM blanks data
  $blank = { param($m) [regex]::Replace($m.Value, '[^\r\n]', ' ') }
  $mrJ = [regex]::Replace($raw, '[\\`](?=\r?\n)\r?\n', { param($m) ' ' * $m.Length })
  $mrM = [regex]::Replace([regex]::Replace([regex]::Replace($mrJ, '(?ms)<<-?\s*([''"]?)(\w+)\1[^\n]*\n.*?^\s*\2\s*$', $blank), '(?s)@''\r?\n.*?\r?\n''@|@"\r?\n.*?\r?\n"@', $blank), '"(?:[^"\\]|\\.)*"|''[^'']*''', { param($m) $m.Value[0] + (' ' * ($m.Length - 2)) + $m.Value[0] })
  $noTask = if ($env:KIT_NO_TASK) { $env:KIT_NO_TASK } elseif (($em = [regex]::Match($mrM, '(?:^|[\s;(])(?:\$env:)?KIT_NO_TASK\s*=\s*')).Success -and $mrJ.Substring($em.Index + $em.Length) -match '^(?:"([^"]+)"|''([^'']+)''|([^\s;''"]+))') { $Matches[1] + $Matches[2] + $Matches[3] }
  if ($noTask) { Write-KitLog guard no-task @{ session = "$($in.session_id)"; reason = $noTask; cmd = $raw.Substring(0, [math]::Min(300, $raw.Length)) } }
  else {
    # words from $i to an unquoted ; | & ) or line end
    function CliWords([string]$t, [int]$i) {
      $ws = [Collections.Generic.List[string]]::new(); $sb = [Text.StringBuilder]::new(); $q = ''; $has = $false
      for (; $i -lt $t.Length; $i++) {
        $ch = [string]$t[$i]
        if ($q) { if ($ch -eq $q) { $q = '' } else { [void]$sb.Append($ch) }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $q = $ch; $has = $true; continue }
        if ($ch -in ';', '|', '&', ')', "`n", "`r") { break }
        if ($ch -match '\s') { if ($sb.Length -or $has) { $ws.Add($sb.ToString()); [void]$sb.Clear(); $has = $false }; continue }
        [void]$sb.Append($ch)
      }
      if ($sb.Length -or $has) { $ws.Add($sb.ToString()) }
      , $ws.ToArray()
    }
    function OptVal([string[]]$ws, [string[]]$names) { for ($j = 0; $j -lt $ws.Count; $j++) { foreach ($n in $names) { if ($ws[$j] -ceq $n -and $j + 1 -lt $ws.Count) { return $ws[$j + 1] }; if ($ws[$j].StartsWith("$n=")) { return $ws[$j].Substring($n.Length + 1) } } } }
    $tagRx = Get-KitTaskTagRx; $tag = if ($KitConf.TrackerTag) { "$($KitConf.TrackerTag)<id>" } else { "a task id ($tagRx)" }; $esc = 'no task at all: KIT_NO_TASK=<reason> <command> (logged)'
    foreach ($mm in [regex]::Matches($mrM, $mrRx)) {
      $ws = CliWords $mrJ ($mm.Index + $mm.Length); $tool = $mm.Groups['tool'].Value
      # last cd before it, else the hook's cwd
      $gd = $here; foreach ($cm in [regex]::Matches($raw.Substring(0, $mm.Index), '\b(?:cd|chdir|sl|Set-Location|pushd|Push-Location)\s+(?:-(?:Literal)?Path\s+)?(?:"([^"]+)"|''([^'']+)''|([^\s;|&]+))')) {
        $cx = ($cm.Groups[1].Value + $cm.Groups[2].Value + $cm.Groups[3].Value) -replace '^/([A-Za-z])(?=/|$)', '$1:'; $gd = if ([IO.Path]::IsPathRooted($cx)) { $cx } elseif ($gd) { Join-Path $gd $cx } }
      if ($mm.Groups['verb'].Value -ne 'merge') {
        if (-not $tagRx) { continue }
        $src = OptVal $ws @($hostClis.source | Select-Object -Unique); if (-not $src -and $gd) { $src = "$(git -C $gd branch --show-current 2>$null)".Trim() }
        if (Test-KitDeployMr $(if ($gd) { "$(git -C $gd remote get-url origin 2>$null)" -replace '\.git$' -replace '.*[/:]' }) $src (OptVal $ws @($hostClis.target | Select-Object -Unique))) { continue }   # a deploy MR: no task
        if ("$(OptVal $ws @($hostClis.title | Select-Object -Unique)) $src" -notmatch $tagRx) { Deny "kit guard: this MR names no tracker task ($tag in neither its title nor its source branch '$src'): the owner never sees it on the task. Open it with python -X utf8 $($KitCmd.devtools) mr <wt> '<title>' <body.md> from a branch with $tag, or put $tag in the title; $esc." }
        continue
      }
      $hc = @($hostClis | Where-Object { $_.exe -eq $tool })[0]
      if ($hc.noAuto -and $ws -contains $hc.noAuto) { continue }
      $valued = @($hc.valued)
      $target = $null; for ($j = 0; $j -lt $ws.Count; $j++) { if ($ws[$j] -cin $valued) { $j++; continue }; if ($ws[$j] -like '-*') { continue }; $target = $ws[$j]; break }
      $repo = OptVal $ws '-R', '--repo'; $n = $null
      if (($u = ConvertFrom-MrUrl "$target")) { $repo = $u.repo; $n = $u.n } elseif ("$target" -match '^!?(\d+)$') { $n = $Matches[1] }
      if (-not $n) { Deny "kit guard: $tool $($hc.noun) merge needs the MR number (merge <iid>), so the guard can check that a task tracks it; $esc." }
      if (-not $repo -and $gd -and "$(git -C $gd remote get-url origin 2>$null)".Trim() -match '^(?:\w+://(?:[^@/]+@)?[^/]+/|[^@]+@[^:]+:)(?<p>.+?)(?:\.git)?/?$') { $repo = $Matches.p -replace '/_git/', '/' }
      if (-not (Test-KitMrTracked "$repo" $n)) {
        $h = if ($repo) { try { Invoke-HostVerb 'mr.get' @{ repo = "$repo"; n = $n } } catch { $null } }
        if ($h -and (Test-KitDeployMr "$repo" "$($h.source_branch)" "$($h.target_branch)")) { continue }   # a deploy MR: no task
        $leaf = if ($repo) { ($repo -split '/')[-1] } else { '<repo>' }
        Deny "kit guard: $leaf!$n is in no task's tracking: the owner never sees it on the task and it is never promoted. First & $($KitCmd.orch) track add -Task <id> -Mrs '$leaf!$n' (the task its fix belongs to, or a new one), then merge; $esc."
      }
    }
  }
}
# a script / doc run directly opens its associated app
function Test-OpenDoc([string]$text, [string]$tool) {
  $de = 'md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|gif|svg|pdf|docx?|xlsx?|pptx?'; $se = 'pyw?|[cm]?js|ts'
  $doc = "\.($de)$"; $scr = "\.($se)$"
  $gui = '^(explorer|xdg-open|open|code|code-insiders|notepad|notepad\+\+|wordpad|mspaint|mmc|control|rundll32|mshta|wscript|Invoke-Item|ii)(\.exe)?$'; $info = '(^|\s)(--version|-v|--list-extensions|--help|-h|--status)(\s|$)'
  # kit .ps1 call: the rest is arguments
  $text = [regex]::Replace($text, '(?m)(^|[;{]|&&)\s*&\s+(''[^'']+\.ps1''|"[^"]+\.ps1"|[^\s;''"]+\.ps1)(\s.*)?$', '$1')
  if ($tool -ne 'Bash') {
    $cas = CmdAsts $text
    if ($null -ne $cas) {
      foreach ($ca in $cas) {
        $el = @($ca.CommandElements); if (-not $el.Count) { continue }
        $val = { param($e) if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $e.Value } else { $e.Extent.Text.Trim('''"') } }
        $w0 = & $val $el[0]; $leaf = $w0 -replace '^.*[\\/]', ''
        if ($el[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $el[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
          if ($w0 -match $scr) { return 'script' }
          if ($w0 -match $doc) { return 'doc' }
        }
        $rest = (@($el | Select-Object -Skip 1 | ForEach-Object { & $val $_ }) -join ' ')
        if ($leaf -match $gui -and -not ($leaf -match '^code' -and $rest -match $info)) { return 'doc' }
        if ($leaf -match '^(pwsh|powershell)(\.exe)?$' -and $rest -match '(?is)(^|\s)-(c|Command)\s+(.+)$' -and ($inner = Test-OpenDoc $Matches[3] 'PowerShell')) { return $inner }
        if ($leaf -match '^cmd(\.exe)?$' -and $rest -match "(?i)[/-][ck]\s+(start\s+(""""\s+)?)?\S+\.($se)(\s|$)") { return 'script' }
        if ($leaf -match '^cmd(\.exe)?$' -and $rest -match '(?i)[/-][ck]\s+start\b') { return 'doc' }
        # only the opened target counts
        $fp = [array]::FindIndex([object[]]$el, [Predicate[object]] { param($x) $x -is [System.Management.Automation.Language.CommandParameterAst] -and $x.ParameterName -match '^(FilePath|Path|LiteralPath)$' })
        $tg = if ($fp -gt 0 -and $fp + 1 -lt $el.Count) { $el[$fp + 1] } else { $el | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | Select-Object -First 1 }
        if ($w0 -match '^(Start-Process|start|saps)$' -and $tg) {
          $tv = & $val $tg
          if ($tv -match $scr) { return 'script' }
          if ($tv -match "$doc|^https?://|^\.{1,2}[\\/]?$" -or (($tv -replace '^.*[\\/]', '') -match $gui -and $rest -notmatch '(?i)-WindowStyle\s+Hidden')) { return 'doc' }
        }
      }
      return $null
    }
  }
  foreach ($nm in [regex]::Matches($text, '\b(?:(?:ba|z|da)?sh|pwsh|powershell)(?:\.exe)?\s+(?:-\S+\s+)*?-(?:c|Command)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')')) {
    if (($inner = Test-OpenDoc ($nm.Groups[1].Value + $nm.Groups[2].Value) $(if ($nm.Value -match '^(pwsh|powershell)') { 'PowerShell' } else { 'Bash' }))) { return $inner }
  }
  # command position only; ${v}, a=(...), X=path, > path are data
  $t = [regex]::Replace(((StripData $text) -replace '\$\{[^}\s]*\}', '$$v'), '(?m)\bcode(-insiders)?(\.exe)?(?=\s+(--version|-v|--list-extensions|--help|-h|--status)(\s|$))', 'codeinfo')
  $sep = '(?m)(^|[;|{\r\n]|(?<!=)\(|&&)\s*((do|then|else|elif)\s+)?(\w+=(?:\$\([^)]*\)|\([^)]*\)|[^\s(])*\s+)*'; $fe = '(\s|;|\||\)|$)'
  if ($t -match "$sep((&|\.)\s+)?[^\s;|&<>=]+\.($se)$fe" -or $t -match "$sep(start|Start-Process|saps|cmd(\.exe)?\s+[/-]+[ck](\s+start(\s+"""")?)?)\s+[^\s;|&<>]+\.($se)$fe") { return 'script' }
  if ($t -match "$sep((&|\.)\s+)?[^\s;|&<>=]+\.($de)$fe" -or $t -match "$sep(\S*[\\/])?(explorer|xdg-open|open|code|code-insiders|notepad|notepad\+\+|wordpad|mspaint|mmc|control|rundll32|mshta|wscript|Invoke-Item|ii)(\.exe)?$fe" -or
      $t -match "$sep(\S*[\\/])?cmd(\.exe)?\s+[/-]+[ck]\s+start$fe" -or ($tool -eq 'Bash' -and $t -match "$sep(start)$fe") -or
      $t -match "$sep(Start-Process|start|saps)\s+(-\w+\s+)*([^\s;|&<>]+\.($de)|https?://\S+|\.{1,2}[\\/]?)$fe") { return 'doc' }
  $null
}
function Get-KitScriptRewrite([string]$text) {   # the first script in command position, via its interpreter
  if ($text -notmatch '(?m)(?:^|[;&|(]\s*)(?:[&.]\s+)?([''"]?)(?<s>[^\s''";|&<>]+\.(?<x>ps1|py|m?js))\1(?<r>(?:''[^'']*''|"(?:[^"\\]|\\.)*"|\d?>&\d|[^\r\n;|&''"]|[''"])*)') { return '' }   # 2>&1 stays: a cut "2>" rewrite fails again
  $hit = $Matches; $pre = $text.Substring(0, [Math]::Max(0, $text.IndexOf($hit.s)))
  # Bash: an env var set before it (export X=v, $env:X='v') carries over as a prefix
  $envSet = @(@(if ($tn -eq 'Bash') { [regex]::Matches($pre, '(?:\bexport\s+|\$env:)(?<n>\w+)\s*=\s*(?<v>''[^'']*''|"[^"]*"|[^\s;]+)') }) | ForEach-Object { "$($_.Groups['n'].Value)=$($_.Groups['v'].Value) " }) -join ''
  " Rewrite: $envSet$(@{ ps1 = 'pwsh -NoProfile -File'; py = 'python -X utf8' }[$hit.x] ?? 'node') $($hit.s)$($hit.r.TrimEnd())"
}
# a heredoc fed to pwsh -Command - is PowerShell, where & x.ps1 runs in place (2026-11-17..21: 50+ false blocks of & pokey.ps1)
$script:psBodies = @(); $bashText = $raw
if ($tn -eq 'Bash') { foreach ($hd in @([regex]::Matches($raw, '(?ms)^(?<open>[^\r\n]*(?<!<)<<(?!<)-?\s*(?<q>[''"]?)(?<tag>\w+)\k<q>[^\r\n]*)\r?\n(?<body>.*?)\r?\n[ \t]*\k<tag>[ \t]*(?=\r?\n|$)'))) {
  if ($hd.Groups['open'].Value -match '\b(pwsh|powershell)(\.exe)?\s.*-(c|Command)\s+-(\s|$)') { $script:psBodies += $hd.Groups['body'].Value; $bashText = $bashText.Replace($hd.Value, $hd.Groups['open'].Value) } } }
$od = Test-OpenDoc $bashText $tn; foreach ($pb in $script:psBodies) { if (-not $od) { $od = Test-OpenDoc $pb 'PowerShell' } }
if ($od -eq 'script') {
  $fix = Get-KitScriptRewrite $raw
  Deny "$(if ($fix) { "$($fix.Trim()) -> " })That runs a script file directly: Windows opens it in an editor. Run it through its interpreter (python -X utf8, node, pwsh -File). $hl" }
$readIt = "use the Read tool (offset / limit; Get-Content or cat in a script); run a script through its interpreter (python -X utf8, node, pwsh -File). $hl"
if ($od) { Deny "That opens the file in its default desktop app instead of reading it: $readIt" }
# a file path in command position (quoted, any extension, an existing file or folder) opens its associated app
$docRx = '\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|ini|toml|cfg|conf|sql|pdf|docx?|xlsx?|pptx?|png|jpe?g|gif|svg)$'
function Get-GuardPath([string]$word, [string]$base) {
  if (-not $word -or $word -match '[$*?<>|`]') { return $null }
  $p = $word -replace '^~(?=[\\/]|$)', $HOME -replace '^[\\/]([A-Za-z])(?=[\\/]|$)', '$1:'
  if (-not [IO.Path]::IsPathRooted($p)) { if (-not $base) { return $null }; $p = Join-Path $base $p }
  try { [IO.Path]::GetFullPath($p) } catch { $null }
}
function Test-RunsFile([string]$word, [string]$base, [string]$tool) {
  if ($word -notmatch '[\\/]|^[A-Za-z]:' -or $word -match '^\w+=') { return $null }   # a bare name is a command lookup; X=path is data
  if ($word -match $docRx -or ($tool -eq 'Bash' -and $word -match '\.(pyw?|ps[dm]?1|[cm]?js|ts)$')) { return $word }
  if (-not ($p = Get-GuardPath $word $base)) { return $null }
  if (Test-Path -LiteralPath $p -PathType Container) { return $(if ($tool -ne 'Bash') { $word }) }   # Bash: "Is a directory"
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  $ext = [IO.Path]::GetExtension($p).TrimStart('.').ToLower()
  if ($ext -in 'exe', 'com', 'bat', 'cmd') { return $null }
  if ($tool -eq 'Bash') {
    if ($ext -in 'sh', 'bash') { return $null }
    $head = [byte[]]::new(4); try { $fs = [IO.File]::OpenRead($p); $n = $fs.Read($head, 0, 4); $fs.Dispose() } catch { $n = 0 }
    $magic = [Text.Encoding]::Latin1.GetString($head, 0, [math]::Max(0, $n))
    if ($magic -match "^(#!|MZ|`u{7f}ELF)") { return $null }   # #! script (gradlew, .bin/tsc) or a native binary
  } elseif ($ext -eq 'ps1' -or (-not $ext -and (Get-ChildItem -LiteralPath (Split-Path $p) -Filter "$(Split-Path $p -Leaf).*" -File | Where-Object Extension -in '.ps1', '.cmd', '.bat', '.exe'))) { return $null }   # PowerShell picks the runnable sibling
  $word
}
function Find-RunsFile([string]$text, [string]$tool, [string]$base) {
  $cdRx = '^(cd|pushd|Set-Location|Push-Location|sl|chdir)$'
  $asts = if ($tool -ne 'Bash') { $tk = $null; $er = $null; $root = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tk, [ref]$er); if (-not @($er).Count) { $root } }
  if (-not $asts) {
    foreach ($seg in (Split-CommandSegments ((StripDocs $text) -replace '\\\r?\n', ' ') $tool)) {   # a \-continued line is one command
      if (-not ($seg -match $segRx)) { continue }
      $w0 = $Matches[2].Trim('''"'); $rest = $Matches[3].Trim()
      $arg = if ($rest -match '^(?:-\S+\s+)*("[^"]+"|''[^'']+''|[^\s"'']+)') { $Matches[1].Trim('''"') }
      if ($w0 -match $cdRx) { if (($to = Get-GuardPath $arg $base)) { $base = $to }; continue }
      if (($hit = Test-RunsFile $w0 $base $tool)) { return $hit }
      if ($w0 -match '^(start|Start-Process|saps)$' -and $arg -and ($hit = Test-RunsFile $arg $base 'PowerShell')) { return $hit }
    }
    return $null
  }
  # PowerShell: the AST knows what runs
  $sets = @($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
  # an element -> the file it names; a variable: its last assigned string
  $runsVia = { param($e)
    if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $e -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return Test-RunsFile $e.Value $base $tool }
    $from = if ($e -is [System.Management.Automation.Language.ParenExpressionAst]) { $e }   # (Join-Path $k 'a.md')
            elseif ($e -is [System.Management.Automation.Language.VariableExpressionAst]) { $sets | Where-Object { $_.Left.VariablePath.UserPath -eq $e.VariablePath.UserPath -and $_.Extent.StartOffset -lt $e.Extent.StartOffset } | Select-Object -Last 1 | ForEach-Object Right }
    $strs = if ($from) { @($from.FindAll({ param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord') -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) }
    if ($strs -and $strs[-1].Value -match $docRx) { "$($e.Extent.Text) ($($strs[-1].Value))" } }
  foreach ($ca in @($asts.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
    $el = @($ca.CommandElements); if (-not $el.Count) { continue }
    $w0 = if ($el[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $el[0].Value }
    $args1 = @($el | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
    if ($w0 -match $cdRx -and $args1 -and $args1[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { if (($to = Get-GuardPath $args1[0].Value $base)) { $base = $to }; continue }
    if (($hit = & $runsVia $el[0])) { return $hit }
    if ($w0 -match '^(start|Start-Process|saps)$' -and $args1) {
      $fp = [array]::FindIndex([object[]]$el, [Predicate[object]] { param($x) $x -is [System.Management.Automation.Language.CommandParameterAst] -and $x.ParameterName -match '^(FilePath|Path|LiteralPath)$' })
      if (($hit = & $runsVia $(if ($fp -gt 0 -and $fp + 1 -lt $el.Count) { $el[$fp + 1] } else { $args1[0] }))) { return $hit }
    }
  }
  $null
}
$rf = Find-RunsFile $bashText $tn $here; foreach ($pb in $script:psBodies) { if (-not $rf) { $rf = Find-RunsFile $pb 'PowerShell' $here } }
if ($rf) { $rw = if ($rf -match '\.(ps1|py|mjs|cjs|js)$') { Get-KitScriptRewrite $raw }   # the ready command first (agents missed it at the end)
  Deny "kit guard:$(if ($rw) { "$rw ->" }) $rf in command position opens it in its default desktop app (a window on the owner's screen), not your terminal: $readIt" }
if ($cmd -match '--no-verify|core\.hooksPath=(/dev/null|nul\b|\s|$)|HUSKY=0|SKIP_HOOKS' -or
    $cmd -match '\bgit\b[^|;&\r\n]*\bcommit\b[^|;&\r\n]*\s-[a-zA-Z]*n[a-zA-Z]*(?=\s|$)') { Deny "Hooks must run: commit with $($KitCmd.dev) wt commit; fix what the hook reports." }
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  $p = $push.Value
  if ($p -match '(--force(?![-\w])|\s-[a-zA-Z]*f[a-zA-Z]*(?=\s|$)|\s\+[^\s+])' -or ($p -match '--force' -and $protectedRx -and $p -match ('\b(origin\s+)?(' + $protectedRx + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch; on yours: --force-with-lease after crafty.ps1 wt sync.'
  }
}
# deploy branches (repos[].deploys) change only via a deploy MR; protected ones of a product repo via a merged MR (kit: "kit main")
$deployBr = @(@($kc.repos) | ForEach-Object { $repoTarget = $_.target; @($_.deploys).branch | Where-Object { $_ -and $_ -ne $repoTarget } } | Sort-Object -Unique)
if ($cmd -match '\bgit\b[^|;&]*\bpush\b') {
  $pushText = StripData ([regex]::Replace((StripDocs $raw), '"([^"\s;|&]*)"|''([^''\s;|&]*)''', '$1$2'))   # one-word quotes are refs or dirs; other quoted text is data
  $kitGit = GitCommon (Split-Path (Split-Path $K))
  foreach ($push in [regex]::Matches($pushText, '\bgit\b[^|;&\r\n]*?\spush(?=\s|$)[^|;&\r\n]*')) {   # push as a word, not a path part
    $pushTk = @(-split (($push.Value -replace '^.*?\spush(?=\s|$)', '') -replace '\s(-o|--push-option|--repo)\s+\S+', ' ') | Where-Object { $_ -notmatch '^-' } | ForEach-Object { $_ -replace '[''"]' })
    $dst = @($pushTk | Select-Object -Skip 1 | ForEach-Object { ($_ -split ':')[-1] -replace '^\+' -replace '^refs/heads/' })
    $wide = $push.Value -match '\s--(all|mirror)(?=\s|$)'; if (-not $dst.Count -and $push.Value -match '\s--tags(?=\s|$)') { continue }
    $cdTo = @([regex]::Matches($pushText.Substring(0, $push.Index), '\b(?:cd|chdir|sl|Set-Location|pushd|Push-Location)\s+(?:-(?:Literal)?Path\s+)?([^\s;|&]+)'))
    $pushDir = if ($push.Value -match '\s-C\s+("[^"]+"|''[^'']+''|\S+)') { $Matches[1].Trim('"', "'") } elseif ($cdTo.Count) { $cdTo[-1].Groups[1].Value } else { $here }
    if (-not [IO.Path]::IsPathRooted($pushDir)) { $pushDir = Join-Path $here $pushDir }
    if (-not $wide -and (-not $dst.Count -or $dst -contains 'HEAD')) { $dst += "$(git -C $pushDir branch --show-current 2>$null)".Trim() }   # no refspec or HEAD: the checked-out branch
    if (($deployHit = @($dst | Where-Object { $_ -in $deployBr })[0])) { Deny "$deployHit is a deploy branch (kit.local.json repos[].deploys): it changes only through a deploy MR, never a push: bossy.ps1 deploy merge -Repo <checkout> -To <env> -Mr." }
    if ($protectedRx -and -not ($kitGit -and (GitCommon $pushDir) -eq $kitGit) -and ($protHit = $(if ($wide) { '--all / --mirror' } else { @($dst | Where-Object { $_ -match "^($protectedRx)$" })[0] }))) {
      Deny "push to $protHit refused: a protected branch (protectedBranchesBase): merged MRs only; push your branch, open an MR."
    }
  }
}
# shell writes into the live clone or off the layout
if ($cmd) {
  $cur = $here
  foreach ($seg in (StripData ([regex]::Replace((StripDocs $raw), '"([^"\s;|&>]*)"|''([^''\s;|&>]*)''', '$1$2'))) -split '\r?\n|;|&&|\|\||\|') {
    $tk = @(-split $seg); if (-not $tk.Count) { continue }
    $w = $tk[0] -replace '^&$', '' ; if (-not $w -and $tk.Count -gt 1) { $tk = @($tk | Select-Object -Skip 1); $w = $tk[0] }
    $pa = @($tk | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' })
    if ($w -match '^(cd|chdir|sl|Set-Location|pushd|Push-Location)$') { $cur = if ($pa) { $(if ([IO.Path]::IsPathRooted($pa[0])) { $pa[0] } elseif ($cur -and $pa[0] -notmatch '\$') { Join-Path $cur $pa[0] }) } ; continue }
    $hits = @([regex]::Matches($seg, '(?<![\d&*=-])>>?\s*([^\s>&]+)') | ForEach-Object { $_.Groups[1].Value })
    if ($w -match '(^|[\\/])git(\.exe)?$') {
      $gd = $cur
      for ($i = 1; $i -lt $tk.Count; $i++) {
        if ($tk[$i] -eq '-C') { $i++; $gd = if ([IO.Path]::IsPathRooted($tk[$i])) { $tk[$i] } elseif ($gd) { Join-Path $gd $tk[$i] }; continue }
        if ($tk[$i] -match '^-') { if ($tk[$i] -eq '-c') { $i++ }; continue }
        if (-not $liveOk -and $tk[$i] -match '^(checkout|switch|apply|am|commit|reset|restore|merge|rebase|cherry-pick|revert|rm|mv|clean)$' -and $seg -notmatch '\s(-n|--dry-run|--check|-h|--help)(\s|$)' -and ($gr = InLive $gd '') -and ($gr -eq '.' -or -not (LiveIgnored $gr))) { Deny $liveWhy }
        break
      }
    }
    elseif ($w -match '^(Copy-Item|cpi|cp|copy)$') { $hits += @($pa | Select-Object -Last 1) }
    elseif ($w -match '^(Set-Content|sc|Add-Content|ac|Out-File|Clear-Content|clc|Remove-Item|ri|rm|del|erase|rmdir|rd|Move-Item|mi|mv|move|Rename-Item|rni|ren|New-Item|ni|tee|Tee-Object|touch)$' -or ($w -eq 'sed' -and $seg -match '\s(-i|--in-place)')) { $hits += @($pa | Select-Object -Skip ([int]($w -eq 'sed'))) }
    foreach ($h in $hits) { if ($h -match '[\\/]|\.\w{1,8}$') { if (-not $liveOk -and (LiveFile $h $cur)) { Deny $liveWhy }; if ($w -notmatch '^(Remove-Item|ri|rm|del|erase|rmdir|rd)$') { $off += @(OffLayout $h $cur) } } }
    if ($w -match '(^|[\\/])sed(\.exe)?$' -and @($tk | Where-Object { $_ -match '^(-[a-zA-Z]*i\S*|--in-place\S*)$' }).Count) { foreach ($h in $pa) { if (($cf = CrlfKitFile $h $cur)) { Deny "sed -i rewrites $cf (a tracked CRLF kit file) to LF: use the Edit tool" } } }
  }
}
# kit main: never forced, deleted or moved
if ($cmd -match '\bgit\b[^|;&]*\b(push|branch|update-ref)\b' -and ($kg = GitCommon (Split-Path (Split-Path $K)))) {
  $dirs = @([regex]::Matches($raw, '(?:\s-C|\b(?:cd|chdir|sl|Set-Location|pushd|Push-Location))\s+(?:-(?:Literal)?Path\s+)?(?:"([^"]+)"|''([^'']+)''|([^\s;|&]+))') | ForEach-Object { $x = $_.Groups[1].Value + $_.Groups[2].Value + $_.Groups[3].Value; if ([IO.Path]::IsPathRooted($x)) { $x } else { Join-Path $here $x } })
  if (@(@($(if ($dirs) { $dirs } else { $here })) | Where-Object { (GitCommon $_) -eq $kg }).Count) {
    $u = StripData ([regex]::Replace((StripDocs $raw), '"([^"\s;|&]*)"|''([^''\s;|&]*)''', '$1$2'))   # one-word quotes are refs
    $pr = '^\+?(?:[^:\s]*:)?(?:refs/(?:heads|remotes/[^/\s]+)/|origin/)?(' + [regex]::Escape($(if ($kc.kitBranch) { "$($kc.kitBranch)" } else { 'main' })) + ')$'
    foreach ($m in [regex]::Matches($u, '\bgit\b[^|;&]*\b(push\b|branch\b|update-ref\b)[^|;&]*')) {
      $p = $m.Value; $tk = -split $p; $hit = @($tk | ForEach-Object { if ($_ -match $pr) { $Matches[1] } })[0]
      $bad = switch ($m.Groups[1].Value) {
        'push' { $p -match '--mirror|--prune' -or ($hit -and ($p -match '--force|--delete|\s-[a-zA-Z]*[fd][a-zA-Z]*(?=\s|$)' -or @($tk | Where-Object { $_ -match '^[+:]' -and $_ -match $pr }).Count)) }
        'branch' { $hit -and $p -match '\s(-[a-zA-Z]*[dDfMm][a-zA-Z]*|--delete|--force|--move)(?=\s|$)' }
        default { [bool]$hit } }
      if ($bad) { Deny "$(if ($hit) { $hit } else { 'main' }): a protected kit branch: fast-forward pushes only (rebase on origin first); never force-push, delete or move it." }
    }
  }
}
$gated = $cmd -match 'crafty\.ps1["'']?\s+(gate|check)\b|phoney\.ps1["'']?\s+build\b|gate\.ps1|check\.ps1|app-build\.ps1'
# pytest / docker at a command's start (a grep or a message is no run): quoted tool paths unwrapped, other quotes emptied, wrappers skipped
$hv = [regex]::Replace([regex]::Replace((StripDocs $raw), '"[^"]*[\\/]((?:python[\d.]*|py|pytest|docker(?:-compose)?)(?:\.exe)?)"', '$1'), '"(?:[^"\\]|\\.)*"|''[^'']*''', '""')
$hvAt = '(^|[;&|(\n]|\bthen\b|\bdo\b)\s*(&\s*)?((\w+=\S*|sudo|env|time|nohup|exec|setsid|timeout\s+\S+)\s+)*(\S*[\\/])?'
$heavy =$cmd -match '(^|[\s;&|(''"])(\.[\\/])?(mvn|mvnd|mvnw(\.cmd)?)(\s[^|;&]*)?\s(compile|test|package|install|verify)\b' -or
        $cmd -match 'gradlew(\.bat)?(\s[^|;&]*)?\s(assemble\w*|build|test\w*|bundle\w*|lint\w*)\b' -or
        $cmd -match '(^|[\s;&|(''"])msbuild(\.exe)?(\s|$)' -or
        $cmd -match '\b(ng\s+(build|test)|dotnet\s+(build|test|publish)|cargo\s+(build|test)|npx\s+(jest|vitest|tsc)\b|npm\s+(run\s+)?(build|test)\b|yarn\s+(build|test)\b|(pnpm|bun)\s+(run\s+)?(build|test)\b)' -or
        ($hv -match ($hvAt + '((uv|poetry|pipenv|hatch|pdm)\s+run\s+)?(pytest|py\.test|(py|python[\d.]*)(\.exe)?(\s+-\S+(\s+(?!-)[^\s;&|]+)?)*?\s+-m\s+pytest)(\.exe)?(?=\s|$|[;&|)])') -and $hv -notmatch 'pytest[^|;&\n]*\s(--version|--help|-h|--collect-only|--co)\b') -or
        ($hv -match ($hvAt + '(docker(\.exe)?\s+(--?\w[\w-]*(\s+(?!-)[^\s;&|]+)?\s+)*(compose\s+(-\S+(\s+(?!-)[^\s;&|]+)?\s+)*(build|run|up)|build|run|(buildx|image|container)\s+(build|run))|docker-compose(\.exe)?\s+(-\S+(\s+(?!-)[^\s;&|]+)?\s+)*(build|run|up))\b') -and $hv -notmatch 'docker[^|;&\n]*\s(--help|-h)\b') -or
        @(@(Get-KitSetting 'guard.heavyPatterns' @()) | Where-Object { $_ -and $cmd -match $_ }).Count   # a stack's own heavy commands (bazel build, sbt test, ...)
# e2e only via check -Step e2e (else the whole suite); guard.e2ePatterns: more e2e runners
$e2eRx = '\b(cypress\s+run|playwright\s+test)\b|\b(npm|yarn|pnpm|bun)\s+(run\s+)?(e2e|cypress|playwright)\b(?![:-](open|verify|install|lint)\b)(?!\s+(install|verify|info|cache|open|codegen|show-report)\b)' + (@(@(Get-KitSetting 'guard.e2ePatterns' @()) | Where-Object { $_ } | ForEach-Object { "|(?:$_)" }) -join '')
if (@($cmd -split '\r?\n|;|&&|\|\||\|' | Where-Object { $_ -match $e2eRx -and $_ -notmatch 'crafty\.ps1["'']?\s+check\b' }).Count) {
  Deny "e2e runs go through & $($KitCmd.dev) check -Dir <module> -Step e2e: only the specs related to the change (the whole suite: -AllTests, on the owner's word)."
}
if ($heavy -and -not $gated) {
  Deny "Heavy builds/tests go through the memory gate: & $($KitCmd.dev) check -Dir <module> [-Step test -Tests X | -Step build], else crafty.ps1 gate -Dir <dir> -Cmd '<cmd>' -Log <crafty.ps1 dir file> (prints a digest, not the whole log)."
}
# background shells: endless waits / stdin reads hang for hours
$bgNote = $null; if ($in.tool_input.run_in_background -eq $true) {
  $bgWhy = @($(if ($raw -match '(?s)\b(until|while)\b[^;{\n]*(;\s*do\b(?:(?!\bdone\b).)*?\bsleep\b|\{[^}]*?\bStart-Sleep\b)' -and $Matches[0] -notmatch '\$SECONDS|\s-(lt|le|gt|ge)\s|\(\(.*[<>].*\)\)' -and $raw -notmatch '\btimeout\s+\d+\s+(ba|z)?sh\s+-c') { 'a sleep loop with no max count or timeout' }),
    $(if ($raw -match '(?m)(^\s*|[;&(]\s*)cat\s*(>\s*\S+\s*)?($|[;&|)])') { 'cat with no file reads stdin' }),
    $(if ($raw -match '\bpython\d*(\.exe)?\s+-(\s|$)' -and $raw -notmatch '\bpython\d*(\.exe)?\s+-\s*<|\|\s*python') { 'python - reads its script from stdin' }) | Where-Object { $_ })
  if ($bgWhy) { $bgNote = @("kit guard: this background shell may never end ($($bgWhy -join '; ')): bound it (timeout <s> <cmd>, a loop counter), no stdin reads; supervise flags hung shells (Shells table)") } }
# adapter rules (Register-KitAdapter 'guard') last: notes only follow commands that run
$notes = foreach ($rule in @($KitAdapters.guard.Values | Where-Object { $_ })) { $why = & $rule.check @{ cmd = $cmd; raw = $raw; config = $kc; hook = $in }; if ($why.note) { $why.note } elseif ($why) { Deny $why } }   # not @(): Deny's output would die with it
LayoutCheck; $notes = @(@($notes) + $script:layoutNote + $bgNote | Where-Object { $_ })
if ($isGravity) { @{ decision = 'allow' } | ConvertTo-Json -Compress }
elseif ($notes) { @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = (@($notes) -join "`n") } } | ConvertTo-Json -Compress -Depth 4 }
exit 0
}

# ---- dir: agents' runtime write places: agents/<agent>/[<item>/], evidence/<item>/
function Invoke-Dir {
param([string]$Agent, [string]$Item, [ValidateSet('scratch', 'evidence')][string]$Kind = 'scratch', [string]$Name)
$slug = { param($s) ConvertTo-KitSlug $s }
if (-not $(if ($Kind -eq 'evidence') { $Item } else { $Agent })) { 'usage: crafty.ps1 dir -Agent <id> [-Item <task>] [-Name <file>] | -Kind evidence -Item <task> [-Agent <id>] [-Name <file>]'; exit 2 }
$d = if ($Kind -eq 'evidence') { Join-Path (Get-KitPath evidence) (& $slug $Item) } else { Join-Path (Get-KitPath agents) (& $slug $Agent) | Join-Path -ChildPath $(if ($Item) { & $slug $Item } else { '' }) }
New-Item -ItemType Directory -Force $d | Out-Null
if ($Name) { Join-Path $d "$(if ($Kind -eq 'evidence' -and $Agent) { "$(& $slug $Agent)-" })$(& $slug $Name)" } else { $d.TrimEnd('\', '/') }
}

# ---- checkpoint: resume point per step: resume-<run>.json + .md, atomic; -Brief: a hand-written brief keeps its text
$script:KitSteps = 'worktree', 'commit', 'goals', 'loop', 'mr', 'review', 'ci', 'doc', 'tracker', 'merge', 'done'
function Invoke-Checkpoint {
param([string]$Agent, [string]$Run = '', [string]$Step, [string]$Evidence = '', [string]$Item = '', [string]$Next = '', [string]$Dir = '', [string[]]$Leases, [switch]$Read, [string]$Notes = '', [string]$Brief = '')
if (-not $Agent -or -not ($Step -or $Read)) { "usage: crafty.ps1 checkpoint -Agent <id> [-Run <run>] -Step <$($script:KitSteps -join '|')|<check id>> [-Evidence <sha|iid|url|result>] [-Item <task>] [-Next <step>] [-Dir <wt>] [-Leases <a,b>] [-Notes '<one line>'] [-Brief <handoff path>] | -Agent <id> -Read"; exit 2 }
if (-not $Run -and -not $Read) { $Run = "adhoc-$(ConvertTo-KitSlug $Agent)" }
$null = Invoke-Dir -Agent $Agent; $jf = Get-KitCheckpointFile $Agent $Run -Write:(-not $Read); $mf = $jf -replace '\.json$', '.md'   # per run: same-named agents never overwrite
if ($Read) { if (Test-Path -LiteralPath $mf) { Get-Content -LiteralPath $mf } else { "no checkpoint for $Agent$(if ($Run) { " run $Run" })" }; return }
$c = try { Read-KitText $jf | ConvertFrom-Json -AsHashtable } catch { $null }
foreach ($ckObj in @($c) + @($c.steps)) { foreach ($ckKey in 'at', 'updated') { if ($ckObj -is [Collections.IDictionary] -and $ckObj[$ckKey] -is [datetime]) { $ckObj[$ckKey] = $ckObj[$ckKey].ToString('o') } } }   # times stay ISO text (-DateKind needs pwsh 7.5)
if (-not $c -or ($Run -and "$($c.run)" -ne $Run)) { $c = @{ agent = $Agent; run = $Run; steps = @(); worktrees = @(); leases = @() } }   # another run's: start over
$s = [ordered]@{ step = $Step; evidence = $Evidence; item = $Item; at = (Get-Date).ToString('o') }
if ($Dir) { $Dir = (Resolve-Path -LiteralPath $Dir).Path; $s.dir = $Dir; $s.head = "$(git -C $Dir rev-parse --short HEAD 2>$null)".Trim(); $c.worktrees = @(@($c.worktrees) + $Dir | Where-Object { $_ } | Select-Object -Unique) }
$i = [array]::IndexOf($script:KitSteps, $Step.ToLower())
$c.steps = @(@($c.steps) + $s); $c.done = $false; $c.updated = $s.at
$c.next = if ($Next) { $Next } elseif ($Step -eq 'done') { 'none' } elseif ($i -ge 0) { $script:KitSteps[$i + 1] } else { 'the next check' }
if ($PSBoundParameters.ContainsKey('Leases')) { $c.leases = @(Split-KitList $Leases) }
if ($Notes) { $c.notes = @(@($c.notes) + "$($s.at.Substring(0, 16)) $($Notes -replace '\s+', ' ')" | Where-Object { $_ }) }   # the agent's only free text: one line each
$c.decisions = @(Get-ChildItem (Get-KitPath decisions) -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.agent -eq $Agent -and $_.status -eq 'pending' } | ForEach-Object id)
Write-KitState $jf $c
$md = @("# Checkpoint: $Agent (run ``$($c.run)``)", "**Result:** Next: $($c.next) (start here; the steps below are done: verify, never redo) · $($c.updated)", '', '## Done', '') +
  @(Format-KitMdTable 'At', 'Step', 'Item', 'Evidence', 'Worktree @ head' @($c.steps | ForEach-Object { , @($_.at, $_.step, $_.item, $_.evidence, "$(if ($_.head) { "``$($_.dir)`` @ $($_.head)" })") })) +
  @('', '## Open', '', "**Worktrees:** $(@($c.worktrees) -join ', ')", "**Leases:** $(@($c.leases) -join ', ')", "**Decisions pending:** $(@($c.decisions) -join ', ')") +
  @(if ($c.notes) { '', '## Notes', ''; @($c.notes | ForEach-Object { "- $_" }) })
# a hand-written resume-<run>.md keeps its text above the generated part (the checkpoint overwrote it, 2026-11-23)
$own0 = if (Test-Path -LiteralPath $mf) { ([IO.File]::ReadAllText($mf) -split '<!-- checkpoint -->')[0] -replace '(?s)^# (Resume brief|Checkpoint): .*' }
Write-KitAtomic $mf ("$(if ("$own0".Trim()) { "$("$own0".TrimEnd())`n`n<!-- checkpoint -->`n" })" + ($md -join "`n") + "`n")
if ($Brief) { $own = "$(if (Test-Path $Brief) { ([IO.File]::ReadAllText($Brief) -split '<!-- checkpoint -->')[0] })" -replace '(?s)^# Resume brief: .*'
  Write-KitAtomic $Brief ("$(if ($own.Trim()) { "$($own.TrimEnd())`n`n<!-- checkpoint -->`n" })# Resume brief: $Agent (run ``$($c.run)``)`n" + ($md[1..($md.Count - 1)] -join "`n") + "`n"); "resume brief: $Brief (board leave -Handoff $Brief)" }
"checkpoint $Agent`: $Step done -> next $($c.next) ($mf)"
}

# ---- prior: a task's work of the last 30 days (lib.ps1 Assert-KitPrior)
function Invoke-Prior {
param([string]$Task, [string]$Repo, [string]$Query, [string]$Symbol, [switch]$Json)
  if (-not $Task) { 'usage: crafty.ps1 prior -Task <id> [-Repo <r>] [-Query <words>] [-Symbol <s>] [-Json]'; exit 2 }
  $tag = "$($KitConf.TrackerTag)$Task"; $since = (Get-Date).AddDays(-30); $priorHits = [Collections.Generic.List[object]]::new()
  $claimed = @((Read-KitState (Get-KitTaskFile $Task)).prior.claimed)   # branches wt lease / new made for this task
  $add = { param($k, $r, $ref, $ti, [bool]$tg, $br) $priorHits.Add([ordered]@{ kind = $k; repo = $r; ref = $ref; title = "$ti"; tagged = $tg; proj = $(if ($r) { ((Get-HostProject $r -Raw) -split '/')[-1] }); branches = @($br | Where-Object { $_ }) }) }   # branches: MR source / commit's (wt new reusing one passes)
  $idRx = "(?i)$([regex]::Escape($tag))(?![A-Za-z0-9])"   # CU-12 is no hit for CU-123
  $tt = Get-TrackerTask $Task; $words = if ($Query) { $Query } else { $tt.name }
  foreach ($d in @(Find-KitSimilarTasks $words $tt.list $tt.parent @() @($Task))) { & $add task '' $d.id "$($d.name) (score $($d.score))" }
  foreach ($r in @(if ($Repo) { $Repo } elseif ($KitConf.TrackerRepos.Count) { $KitConf.TrackerRepos } else { @(Get-KitValue 'repos' @()) | ForEach-Object name })) {
    $n = ($r -split '[\\/]')[-1]; $tgtBr = Get-RepoConf $n target 'main'; $mergedSrc = @()   # merged into the target: a fix round, not a duplicate
    foreach ($q in @($tag) + @($Query | Where-Object { $_ })) {
      foreach ($m in @(Invoke-HostVerb 'mr.list' @{ repo = (Get-HostProject $n -Raw); state = 'all'; search = $q; updated_after = $since.ToString('o') })) {
        if ($m.state -eq 'merged' -and "$($m.target_branch)" -eq $tgtBr) { $mergedSrc += "$($m.source_branch)"; continue }
        if ($m.iid -and $m.state -ne 'closed' -and "$($m.source_branch)" -notin $claimed -and ($q -ne $tag -or "$($m.title) $($m.source_branch)" -match $idRx)) { & $add mr $n "$n!$($m.iid) ($($m.state))" $m.title ("$($m.title) $($m.source_branch)" -match $idRx) $m.source_branch } } }
    $dir = @($r, (Get-RepoConf $n checkout $null), (Join-Path $KitConf.ReposRoot $n)) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ '.git')) } | Select-Object -First 1
    if (-not $dir) { continue }
    foreach ($b in @(git -C $dir for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>$null)) { if ($b -match $idRx -and ($b -replace '^origin/') -notin @($claimed) + $mergedSrc) { & $add branch $n $b '' $true } }
    $nc = 0; foreach ($c in @(git -C $dir log --all -i "--grep=$tag" "--since=$($since.ToString('yyyy-MM-dd'))" --format='%h %s' -n 50 2>$null)) {   # a commit on a claimed branch is this task's own
      if ($nc -ge 5) { break }; if ($c -notmatch $idRx) { continue }; git -C $dir merge-base --is-ancestor ($c -split ' ')[0] "origin/$tgtBr" 2>$null; if ($LASTEXITCODE -eq 0) { continue }
      $on = @(git -C $dir branch -a --format='%(refname:short)' --contains ($c -split ' ')[0] 2>$null | ForEach-Object { $_ -replace '^origin/' })
      if (-not @($on | Where-Object { $_ -in @($claimed) + $mergedSrc + $tgtBr }).Count) { $nc++; & $add commit $n ($c -split ' ')[0] ($c -split ' ', 2)[1] $true $on } }
    if ($Symbol) { foreach ($g in @(git -C $dir grep -n -F $Symbol "origin/$(Get-RepoConf $n target 'main')" -- 2>$null | Select-Object -First 3)) { & $add code $n (($g -split ':', 4)[1..2] -join ':') '' } }
  }
  $st = Read-KitState (Get-KitTaskFile $Task)
  foreach ($k in @(if ($st.docs) { $st.docs.Keys })) { & $add doc '' $k $st.docs[$k].url }
  foreach ($e in @($st.envRuns | Where-Object { $_ })) { & $add qa '' "$($e.env) $($e.at)" $e.result }
  $priorHits = @($priorHits | Group-Object { "$($_.kind) $($_.ref)" } | ForEach-Object { $_.Group[0] })
  $own = { param($h) $h.kind -in 'doc', 'qa' -or (@($claimed | Where-Object { $_ }).Count -and $h.kind -eq 'branch' -and $h.ref -match $idRx) }   # gate passed once: tagged branches are the same wave's
  $gate = @($priorHits | Where-Object { -not (& $own $_) })   # own docs, QA runs, tagged work: shown, never a stop
  Update-KitTaskIndex $Task { param($x) $x.prior = [ordered]@{ at = (Get-Date).ToString('o'); validUntil = (Get-Date).AddHours([double](Get-KitParam 'prior.validHours')).ToString('o'); found = $gate; claimed = $claimed } }
  $paired = { param($h) -not $Repo -and $h.tagged -and $h.repo -and $h.kind -ne 'task' }   # no -Repo: the task's own work across repos
  $stop = @($gate | Where-Object { -not (& $paired $_) })
  if ($Json) { [pscustomobject]@{ task = $Task; found = $priorHits } | ConvertTo-Json -Depth 5 } else { if ($priorHits.Count) { $priorHits | ForEach-Object { "$(if ((& $own $_) -or (& $paired $_)) { 'INFO' } else { 'FOUND' }) $($_.kind) $(if ($_.repo) { "$($_.repo) " })$($_.ref) $($_.title)" } }; if (-not $stop.Count) { "NONE: no prior work for $Task (valid $(Get-KitParam 'prior.validHours') h)" } }
  exit $(if ($stop.Count) { 1 } else { 0 })
}

# ---- tracker: lib.ps1 adapters
# lib.ps1 leases: a named lock (check exclusiveTests)
# -WaitMinutes -1: gate.waitMinutes learned per lock:<name>
function Use-KitLock([string]$Name, [string]$Holder, [string]$Dir = '', [double]$WaitMinutes = -1, [int]$ProcessId = $PID) {
  $ctx = "lock:$Name"; $learned = $WaitMinutes -lt 0; if ($learned) { $WaitMinutes = [double](Get-KitParam 'gate.waitMinutes' $null $ctx) }
  $me = @{ lock = $Name; holder = $Holder; pid = $ProcessId; pidStart = (Get-KitPidStart $ProcessId); at = (Get-Date).ToString('o'); dir = $Dir }
  $f = Get-KitLockFile; $end = (Get-Date).AddMinutes($WaitMinutes); $n = 0; $script:KitLockRefused = $null
  while ($true) {
    $o = Invoke-KitLocked $f {
      $st = Get-KitLockState; $h = $st.held[$Name]
      $ahead = @($st.waiting | Where-Object { $_.lock -eq $Name -and $_.pid -ne $ProcessId -and [datetime]$_.at -lt [datetime]$me.at } | Sort-Object { [datetime]$_.at })
      $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $ProcessId })
      $by = if ($h -and $h.pid -ne $ProcessId) { $h } elseif ($ahead.Count) { $ahead[0] + @{ queued = $true } } else { $null }
      if ($by) { $st.waiting += $me } else { $g = $me.Clone(); $g.at = (Get-Date).ToString('o'); $st.held[$Name] = $g }   # held since = taken, not queued
      Save-KitLockState $st; $by
    }
    if (-not $o) { Write-KitLeaseLog acquire lock $Name @{ agent = $Holder; at = $me.at }; if ($n) { Write-Host "[lock] $Name taken after $([int]((Get-Date) - [datetime]$me.at).TotalMinutes) min" }; return $true }
    if ($n++ % 20 -eq 0) { Write-Host "[lock] waiting for lock $Name $(if ($o.queued) { 'behind' } else { 'held by' }) $($o.holder) since $(([datetime]$o.at).ToString('HH:mm')) (wait cap $WaitMinutes min)" }
    if ((Get-Date) -ge $end) { Remove-KitLock $Name $ProcessId; if ($learned) { Add-KitParamObs 'gate.waitMinutes' $WaitMinutes $ctx 'timeout' 90 }; $script:KitLockRefused = $o; return $false }
    Wait-KitPoll 15
  }
}
# ---- task spec: agents pass facts (JSON), never task markdown; tracker create|update <id>|render -Spec <json> renders the
# description (doc lines, tracker.taskTemplate sections), the items checklist `<code> · <desc> · <MR URLs>`, Decisions
# (lib.ps1 Format-KitDecisionItems), parent items (adapters/task_items.ps1), any tracker. Spec: { kind: Feature|Bug|Chore, title, code (its item code on the parent), parent, list,
# assignee, priority, newTask, problem, goal, items: [{ code, desc, mrs: [full MR URLs], done }], acceptance: [..], links: [url |
# { text, url }], docs: { <process.docs key>: url } (older: human, ai), decisions: [{ id, question, answer, by, at }], subtasks: [{ code, desc }], proseOk }.
# what a spec lacks (bug: name + problem), a link or MR no full URL
function Test-KitTaskSpec($Spec) {
  $bug = "$($Spec.kind)" -match '(?i)^bug$' -or (Test-KitBugName "$($Spec.title)")
  @(if (-not "$($Spec.title)".Trim()) { 'title' }; if (-not "$($Spec.problem)".Trim()) { 'problem' }
    if (-not $bug) { if (-not "$($Spec.goal)".Trim()) { 'goal' }; if (-not (@($Spec.items) + @($Spec.subtasks) | Where-Object { $_.code }).Count) { 'items[{code, desc}] (or subtasks)' }; if (-not @($Spec.acceptance | Where-Object { $_ }).Count) { 'acceptance' } }
    foreach ($ln in @($Spec.links) + @(if ($Spec.docs -is [Collections.IDictionary]) { @($Spec.docs.Values) } else { @(Get-KitProps $Spec.docs | ForEach-Object Value) }) +@($Spec.items | ForEach-Object { @($_.mrs) })) { $u = if ($ln -is [Collections.IDictionary]) { $ln.url } else { "$ln" }; if ($u -and $u -notmatch '^https?://\S+$') { "a full URL instead of '$u'" } })
}
# tracker.nameFormat ({prefix} {title} {kind} {code}); prefix = tracker.kindPrefixes[kind]; a typed known kind prefix ([Bug]) is swapped, another "[...]" stays
function Get-KitSpecName($Spec) {
  if ($Spec.key) { $nk = [hashtable]::new($Spec); $nk.Remove('key'); return (Format-KitKeyedName (Get-KitSpecName $nk) "$($Spec.key)") }   # naming: <KEY> [Type] <Area>: <outcome>
  $t = (Remove-KitNameKey "$($Spec.title)").Trim(); if (-not $Spec.kind) { return $t }
  $nk = Get-KitNameKind $t
  if ($nk.rest -ne $t -and $nk.kind -ieq "$($Spec.kind)") { $t = $nk.rest } elseif ($t -match '^\[') { return $t }   # another kind typed: kept as written
  $v = @{ prefix = (Get-KitKindPrefix "$($Spec.kind)"); title = $t; kind = "$($Spec.kind)"; code = "$($Spec.code)" }
  ([regex]::Replace([string](Get-KitSetting 'tracker.nameFormat' '{prefix} {title}'), '\{(\w+)\}', { param($m) [string]$v[$m.Groups[1].Value] }) -replace '\s{2,}', ' ').Trim()
}
# a spec doc's link: docs.<doc key>, or the legacy docs.human / docs.ai: testing-doc / testing-ai by key (a one-doc set), other keys by place
function Get-KitSpecDocUrl($Spec, $Doc, [int]$At) { $u = (Get-KitMember $Spec.docs "$($Doc.key)"); $o = if ("$($Doc.key)" -like 'testing-*') { @{ 'testing-doc' = 'human'; 'testing-ai' = 'ai' }["$($Doc.key)"] } else { @('human', 'ai')[$At] }
  if (-not $u -and $o) { $u = (Get-KitMember $Spec.docs $o) }; "$u" }
# the description: doc links (process.docs, once they exist), then the tracker.taskTemplate sections
function Format-KitTaskText($Spec) {
  $ln = @(); $dk = @(Get-KitProcessDocs); for ($i = 0; $i -lt $dk.Count; $i++) { if ($u = Get-KitSpecDocUrl $Spec $dk[$i] $i) { $ln += "**$($dk[$i].label):** [open]($u)", '' } }
  $lb = @{}; foreach ($s in Get-KitTaskTemplate) { $lb["$($s.key)"] = "$($s.label)" }; $L = { param($k, $d) if ($lb.ContainsKey($k)) { $lb[$k] } else { $d } }
  $ln += "**$(& $L problem Problem):** $("$($Spec.problem)".Trim())", ''; if ($Spec.goal) { $ln += "**$(& $L goal Goal):** $("$($Spec.goal)".Trim())", '' }
  $its = @(@($Spec.items) + @($Spec.subtasks) | Where-Object { $_.code } | ForEach-Object { "- $(Format-KitItemText "$($_.code)" "$($_.desc)" @())" })
  if ($its.Count) { $ln += @("**$(& $L items Items):**") + $its + '' }
  $ac = @($Spec.acceptance | Where-Object { $_ } | ForEach-Object { "- $_" }); if ($ac.Count) { $ln += @("**$(& $L acceptance Acceptance):**") + $ac + '' }
  $lk = @($Spec.links | Where-Object { $_ } | ForEach-Object { if ($_ -is [Collections.IDictionary]) { "[$(if ($_.text) { $_.text } else { $_.url })]($($_.url))" } else { "$_" } })
  if ($lk.Count) { $ln += "**$(& $L links Links):** $($lk -join ' · ')" }
  ($ln -join "`n").TrimEnd()
}
# the rendered task: name, description, checklists (Items: items with MR URLs; Decisions: templates.md decisions)
function ConvertTo-KitTaskRender($Spec, [string]$Task) {
  $dec = @($Spec.decisions | Where-Object { $_.id } | ForEach-Object { [ordered]@{ id = "$($_.id)"; question = "$($_.question)"; answer = "$($_.answer)"; by = "$($_.by)"; at = "$($_.at)"; status = $(if ($_.answer) { 'answered' } else { 'pending' }) } })
  [pscustomobject]@{ name = (Get-KitSpecName $Spec); description = (Format-KitTaskText $Spec)
    items = @(ConvertTo-KitSpecItems $Spec $Task)
    decisions = @(if ($dec.Count) { Format-KitDecisionItems $dec '' $Task }) }
}
# create (no -Task) or update by key (-Task: merged into its stored spec); refused on gaps or prose findings (a local path is one);
# -ReplaceItems: items not in this spec leave the spec and the Items checklist (kept out of rollups like track forget-item), a done one stays unless -Force
function Publish-KitTaskSpec($Spec, [string]$Task, [switch]$DryRun, [switch]$ReplaceItems, [switch]$Force) {
  $old = if ($Task) { (Read-KitState (Get-KitTaskFile $Task)).spec }; $sp = if ($old -is [Collections.IDictionary]) { Merge-KitTaskSpec $old $Spec } else { $Spec }
  $drop = @(); if ($ReplaceItems) {
    if (-not $Task -or -not @($Spec.items | Where-Object { $_.code }).Count) { throw 'tracker update -ReplaceItems: needs <id> and a spec with items[{code, desc}] (the full new list)' }
    $tx = Read-KitState (Get-KitTaskFile $Task)   # done = spec done, named by a merged MR (itemsMrs), or ticked in the description's Items section
    $dn = @(@($sp.items | Where-Object done | ForEach-Object { "$($_.code)" }) + @(if ($tx.itemsMrs -is [Collections.IDictionary]) { @($tx.itemsMrs.Values | ForEach-Object { $_ }) }) + @([regex]::Matches("$((Get-TrackerTask $Task).description)", '(?m)^- \[x\] (\S+) · ') | ForEach-Object { $_.Groups[1].Value }))
    $nk = @($Spec.items | ForEach-Object { "$($_.code)" }); $keep = @($sp.items | Where-Object { $_.code -and ("$($_.code)" -in $nk -or (-not $Force -and "$($_.code)" -in $dn)) }); foreach ($e in $keep) { if ("$($e.code)" -notin $nk) { $e.done = $true } }
    $drop = @($sp.items | Where-Object { $_.code -and $keep -notcontains $_ } | ForEach-Object { "$($_.code)" }); $sp.items = $keep }
  Set-KitSpecKey $sp $Task   # a new task: <P>-<A>-000 until it passes the gates
  $gap = @(Test-KitTaskSpec $sp); if ($gap.Count) { throw "tracker spec refused: missing or wrong: $($gap -join '; ') (crafty.ps1 ""task spec"")" }
  $r = ConvertTo-KitTaskRender $sp $Task
  $dt = "`n`n$(@($r.decisions.text) -join "`n")"; $pf = @(if (-not $Spec.proseOk) { Test-KitProse -Kind task-description -Text "$($r.name)`n`n$($r.description)$dt" })
  if (@($pf | Where-Object { $_ -match '^\(all\): \d+ words' }).Count) {   # Items come from the brief: the word cap counts the rest
    $pq = $sp | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable; $pq.items = @(); $pq.subtasks = @()
    $pf = @(@($pf | Where-Object { $_ -notmatch '^\(all\): \d+ words' }) + @(Test-KitProse -Kind task-description -Text "$($r.name)`n`n$(Format-KitTaskText $pq)$dt" | Where-Object { $_ -match '^\(all\): \d+ words' }))
  }
  if ($pf.Count) { throw "tracker spec refused: $($pf.Count) prose finding(s): $($pf -join '; ')" }
  if ($DryRun) { return $r }
  if ("$($sp.key)" -like '*-000') { $sp.key = ''; Set-KitSpecKey $sp '' -Allocate; $r.name = Get-KitSpecName $sp }
  if ($Task) {   # kept from the live text: doc links the spec lacks, rollup sections
    Clear-TrackerMemo $Task; $cur = "$((Get-TrackerTask $Task).description)" -replace "`r`n", "`n"; $nd = $r.description
    $lbs = @(Get-KitProcessDocs | ForEach-Object label)
    $docs = @($cur -split "`n" | Where-Object { $l = $_; @($lbs | Where-Object { $l.StartsWith("**$($_):**") -and -not $nd.Contains("$($_):") }).Count }); if ($docs.Count) { $nd = (($docs -join "`n`n") + "`n`n" + $nd) }
    $ms = @([regex]::Matches($cur, '(?s)<!-- kit:([\w-]+) -->\n(.*?)\n<!-- /kit:\1 -->')); [array]::Reverse($ms)   # each lands on top: last first keeps their order
    foreach ($m in $ms) { $nd = Set-KitDescSection $nd $m.Groups[1].Value $m.Groups[2].Value '' }
    $null = Set-TrackerName $Task $r.name; $null = Set-TrackerDescription $Task $nd -Resolved; $bkp = $script:KitDescBackup; $id = $Task
  }
  else { $nt = New-TrackerTask -List "$($sp.list)" -Name $r.name -Description $r.description -Parent "$($sp.parent)" -Assignee "$($sp.assignee)" -Priority "$($sp.priority)" -NewTask "$($sp.newTask)" -Related @($sp.related); $id = "$($nt.id)"; if (-not $id) { throw "tracker create returned no id: $nt" } }
  $cl = if ($r.items.Count) { Set-KitTaskChecklist $id (Get-KitItemsLabel) $r.items -Prune:$ReplaceItems -KeepDone:($ReplaceItems -and -not $Force) }
  if ($r.decisions.Count) { $null = Set-KitTaskChecklist $id 'Decisions' $r.decisions }
  $nkx = @($sp.items | ForEach-Object { "$($_.code)" })
  $sp.Remove('proseOk'); Update-KitTaskIndex $id { param($x) $x.spec = $sp; $x.parentItemsSig = ''; if ($r.items.Count) { $x.itemsSig = '' }   # Items just rewritten: the rollup / parent items write theirs again
    if ($ReplaceItems) { $x.itemsDropped = @(@($x.itemsDropped) + $drop | Where-Object { $_ -and $nkx -notcontains $_ } | Select-Object -Unique); if ($x.itemIds) { $x.itemIds = @($x.itemIds | Where-Object { $drop -notcontains $_ }) }
      if ($x.itemDesc -is [Collections.IDictionary]) { foreach ($c in $drop) { $x.itemDesc.Remove($c) } } } }
  $po = @(if ($sp.parent) { Update-KitParentItems "$($sp.parent)" }; if ($Task -or $sp.subtasks) { Update-KitParentItems $id }) -join ' · '
  if (-not $Task -and -not $sp.parent -and $env:KIT_SESSION) {   # K54: 2+ related tasks of one session go under one parent ask
    $flat = @(Get-ChildItem (Get-KitPath tasks) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $id -and $_.LastWriteTime -gt (Get-Date).AddHours(-2) } | ForEach-Object { $x = Read-KitState $_.FullName
        if ($x.spec -and -not $x.spec.parent -and -not $x.spec.subtasks -and "$($x.holder.session)" -eq $env:KIT_SESSION) { $_.BaseName } })
    if ($flat.Count) { [Console]::Error.WriteLine("WARNING: tracker create: this session made $($flat.Count + 1) top-level tasks ($(@(@($flat) + $id) -join ', ')): related tasks go under one parent ask (create it from a spec, then -Parent), or tracker group -Parent <p> -Tasks $(@(@($flat) + $id) -join ',')") } }
  $o = [pscustomobject]@{ id = $id; url = (Get-TrackerUrl $id); name = $r.name; items = $r.items.Count; decisions = $r.decisions.Count; parent = "$po" }
  if ($ReplaceItems) { $o | Add-Member dropped $drop; $o | Add-Member checklist "$cl" }; if ($bkp) { $o | Add-Member backup $bkp }; $o
}
# a hand-written decision record ("Decision(s) (owner ...): ..." / "Decisions:"), a stale copy nobody updates; "Decision needed for X" passes
function Test-KitDecisionText([string]$Text) { "$Text".Trim() -match '^\W{0,3}decisions?\W*(\(|:|\r?\n|$)' }
# one-per-task comment kinds: edited in place (Set-TrackerKitComment)
function Test-KitKeyedComment([string]$Kind) { $Kind -in 'comment-solution', 'qa-result', 'comment-intest' -or $Kind -like 'mrs-*' -or $Kind -like 'watch-*' }
# appends a dated scope section; the old text (doc links on top) stays
function Add-TrackerScope([string]$Id, [string]$Item) {
  $d = "$((Get-TrackerTask $Id).description)".TrimEnd(); if (-not (Get-TrackerTask $Id).name) { throw "tracker scope: task $Id not found (UNKNOWN)" }
  $null = Set-TrackerDescription $Id "$d`n`n**Scope (extended $(Get-Date -Format yyyy-MM-dd)):**`n$Item"; Write-KitLog calls task-scope @{ task = $Id; item = $Item }
  "scope of $Id extended: work and open MRs under it"
}
function Remove-TrackerComment([string]$Id, [string]$Comment) {
  if (-not (__TrCan commentDelete)) { throw "tracker ($__trType): the adapter has no comment-delete verb: remove comment $Comment by hand" }
  Clear-TrackerMemo $Id; __TrA 'comment-delete' @{ id = $Id; comment = $Comment }
}
function Invoke-Tracker {
  $__trA = @($args); $__trPos = New-Object System.Collections.ArrayList; $__trOpt = @{}
  for ($__i = 0; $__i -lt $__trA.Count; $__i++) {
    $__a = [string]$__trA[$__i]
    if ($__a -match '^-(DryRun|Json|NoParent|ReplaceItems|Force)$') { $__trOpt[$Matches[1]] = $true }
    elseif ($__a -match '^-(Type|List|Name|Description|Parent|Assignee|Priority|Text|File|Kind|ProseOk|Key|NewTask|Related|Task|Tasks|Add|Signature|Spec|Back|Area|Product)$' -and $__i + 1 -lt $__trA.Count) { $__trOpt[$Matches[1]] = [string]$__trA[++$__i] }
    elseif ($__a -match '^-[A-Za-z]+$') { "tracker: unknown option $__a (options: -Spec -Key -Text -File -Name -Description -List -Parent -Assignee -Priority -Type -Kind -ProseOk -NewTask -Related -Task -Tasks -Add -Signature -Back -NoParent -ReplaceItems -Force -DryRun -Json)"; exit 2 }
    else { [void]$__trPos.Add($__a) }
  }
  $__sp = if ($__trOpt.Spec) {   # `skills/crafty/crafty.ps1` "task spec": a file or inline JSON
    $__sj = if ("$($__trOpt.Spec)".TrimStart().StartsWith('{')) { $__trOpt.Spec } elseif (Test-Path -LiteralPath $__trOpt.Spec -PathType Leaf) { Get-Content -LiteralPath $__trOpt.Spec -Raw -Encoding utf8 } else { "tracker: no such spec file $($__trOpt.Spec) (pass a file path or inline JSON '{...}')"; exit 2 }
    try { $__sj | ConvertFrom-Json -AsHashtable } catch { "tracker: -Spec is not valid JSON: $($_.Exception.Message)"; exit 2 } }
  if ($__trOpt.File) { if (-not (Test-Path -LiteralPath $__trOpt.File -PathType Leaf)) { "tracker: no such file $($__trOpt.File)"; exit 2 }; $__trOpt.Text = Get-Content -LiteralPath $__trOpt.File -Raw -Encoding utf8; if (-not $__trOpt.Description) { $__trOpt.Description = $__trOpt.Text } }
  Initialize-KitTracker -Type $__trOpt.Type -DryRun:([bool]$__trOpt.DryRun)
  $ErrorActionPreference = 'Stop'
  $__v = if ($__trPos.Count) { $__trPos[0] } else { '' }
  $__id = if ($__trPos.Count -gt 1) { $__trPos[1] } else { '' }
  $__x = if ($__trPos.Count -gt 2) { ($__trPos[2..($__trPos.Count - 1)]) -join ' ' } else { '' }
  function __TrOut($o) { if ($null -ne $o) { ConvertTo-Json -InputObject $o -Depth 6 } }
  switch ($__v) {
    'view' { __TrOut (Get-TrackerTask $__id) }
    'statuses' { $__bad = 0; foreach ($__s in @(Split-KitList $__id)) { $__st = try { "$((Get-TrackerTask $__s).status)" } catch { '' }; if ($__st) { "$__s $((Get-Date).ToString('o')) $__st" } else { $__bad++ } }; if ($__bad) { [Console]::Error.WriteLine("tracker statuses: $__bad view(s) failed") } }   # supervise: <id> <at> <status>
    'roles' { Show-KitScopeRoles $__id }
    'status' { if (-not $__id -or -not $__x) { 'tracker: usage: tracker status <id> <status> [-Back <why>] (read it: tracker view <id>)'; exit 2 }; $__sr = Set-TrackerStatus $__id $__x $__trOpt.Back; $__sr; if ("$__sr" -like 'SKIPPED*') { exit 1 } }   # an empty status set Open
    'comment' {   # -Kind required; over prose limits = refused
      $__ct = __TrText $(if ($__x) { $__x } else { $__trOpt.Text }); $__k = "$($__trOpt.Kind)"
      if ($__sp -and -not "$__ct".Trim()) {   # -Spec: rendered as -Kind (templates.md "Comment spec")
        if (-not $__k) { $__k = 'comment-status' }
        $__sf = Join-Path (Get-KitTemp) "tracker-spec-$PID.json"; Write-KitAtomic $__sf ($__sp | ConvertTo-Json -Depth 10)   # a file: inline JSON loses its quotes on the way to python
        try { $__ct = (@(& (Get-Python) -X utf8 $KitCmd.devtools render $__k $__sf "$__sf.md" 2>&1) | ForEach-Object { "$_" }) -join "`n"; $__rc = $LASTEXITCODE; if (-not $__rc) { $__ct = (Get-Content -LiteralPath "$__sf.md" -Raw -Encoding utf8).TrimEnd() } }   # the out file keeps UTF-8 (stdout: console code page)
        finally { Remove-Item -LiteralPath $__sf, "$__sf.md" -ErrorAction SilentlyContinue }
        if ($__rc) { "tracker comment refused: -Spec does not render as ${__k}: $__ct"; exit 2 } }
      if (-not "$__ct".Trim()) { "tracker comment refused: no text: pass <text>, -Text, -File or -Spec <file | '{...}'>"; exit 2 }
      if ($__k -like 'mrs-*' -or (Test-KitHeadText $__ct $script:KitMrsHeading)) { "tracker comment refused: no MRs comment: MR links live in the task's Items checklist (bossy.ps1 track add -Task $__id -Mrs <repo>!<n>[,...] writes them)"; exit 1 }
      if ($__k -eq 'comment-decisions' -or (Test-KitDecisionText $__ct)) { "tracker comment refused: decisions live in the task's Decisions checklist, rendered from the decision records: bossy.ps1 decide ask|record|answer (it republishes), or decide publish -Task $__id [-Link <plan url>]"; exit 1 }
      if (-not $__k) { "tracker comment refused: -Kind required (templates.md ""Writing standards""): comment-solution | qa-result | comment-intest | watch-<env> edit their one comment in place; comment-status and the rest append"; exit 2 }
      $__pf = @(if (-not $__trOpt.ProseOk) { Test-KitProse -Kind $__k -Text $__ct })
      if ($__pf.Count) { "tracker comment refused: $($__pf.Count) prose finding(s) above ($__k): rewrite it (same facts), or -ProseOk '<why>' for a format the brief fixes"; exit 1 }
      # one-per-task kinds edit in place, others append
      if (Test-KitKeyedComment $__trOpt.Kind) { Set-TrackerKitComment $__id $__trOpt.Kind $__ct } else { Add-TrackerComment $__id $__ct }; exit 0   # a failure throws
    }
    'comments' { __TrOut @(Get-TrackerComments $__id) }
    'uncomment' {   # one comment by id (tracker comments <id>): a stale hand-written kit comment
      if (-not ($__id -and $__x)) { 'usage: tracker uncomment <task> <comment id> (ids: tracker comments <task>)'; exit 2 }
      $__c = @(Get-TrackerComments $__id | Where-Object { "$($_.id)" -eq $__x })
      if (-not $__c.Count) { "tracker uncomment: no comment $__x on $__id (tracker comments $__id lists the ids)"; exit 1 }
      if ($__trOpt.DryRun) { "DRYRUN: would delete comment $__x on $__id`: $((("$($__c[0].text)" -split "`r?`n")[0]))"; return }
      $null = Remove-TrackerComment $__id $__x; Write-KitLog calls comment-deleted @{ task = $__id; comment = $__x; head = (("$($__c[0].text)" -split "`r?`n")[0]) }
      "deleted comment $__x on $__id`: $((("$($__c[0].text)" -split "`r?`n")[0]))"
    }
    'render' { if (-not $__sp) { 'usage: tracker render -Spec <json>'; exit 2 }; __TrOut (Publish-KitTaskSpec $__sp -DryRun) }
    'update' { if (-not ($__id -and $__sp)) { 'usage: tracker update <id> -Spec <json> [-ReplaceItems [-Force]] (merged by key into the stored spec; -ReplaceItems: its items are the whole list)'; exit 2 }; __TrOut (Publish-KitTaskSpec $__sp -Task $__id -ReplaceItems:([bool]$__trOpt.ReplaceItems) -Force:([bool]$__trOpt.Force)) }
    'create' {   # -Spec: rendered ("task spec"); free text only for a keyed QA / watch defect
      if ($__sp) { foreach ($__f in @(@('List', 'list'), @('Parent', 'parent'), @('Area', 'area'), @('Product', 'product'))) { if ($__trOpt[$__f[0]] -and -not $__sp[$__f[1]]) { $__sp[$__f[1]] = "$($__trOpt[$__f[0]])" } }   # command-line values fill the spec
        __TrOut (Publish-KitTaskSpec $__sp -DryRun:([bool]$__trOpt.DryRun)); return }
      $__specHint = 'tracker create -Spec <json> (crafty.ps1 "task spec": kind, title, problem, goal, items, acceptance, links)'
      if ("$($__trOpt.Key)" -notmatch '^(qa|watch)-') { "tracker create refused: every task the kit creates is rendered from a spec: $__specHint; free text only for a keyed QA / watch defect (-Key qa-<run> or watch-<env>-<signature>$(if ($__trOpt.Key) { "; '$($__trOpt.Key)' is neither" }))"; exit 1 }   # owner, 2026-11-15: a free-text [Bug] for merged MRs; 2026-11-16: a made-up key skipped the spec
      if ("$($__trOpt.Name)".Trim() -and -not (Test-KitKindName $__trOpt.Name)) { $__trOpt.Name = Format-KitBugName $__trOpt.Name }   # a keyed defect: the kit adds the configured bug prefix
      if ((($__trOpt.Parent -and $__trOpt.Parent -ne '-') -or (Test-KitKindName $__trOpt.Name)) -and @(Get-KitTaskTextGaps $__trOpt.Name 'x').Count) { "tracker create refused: a kit task's text (a subtask or a [Kind] name) is rendered from a spec: $__specHint; free text only for a keyed [Bug]"; exit 1 }
      $kf = if ($__trOpt.Key) { Join-Path (Get-KitPath published -Create) "$($__trOpt.Key -replace '[^\w.-]+', '_')_task.json" }
      $old = if ($kf -and (Test-Path -LiteralPath $kf)) { Get-Content -LiteralPath $kf -Raw | ConvertFrom-Json }
      $ot = if ($old.id) { Get-TrackerTask $old.id }
      if ($ot.name -and -not (Test-TrackerStatus $ot.status 'closed')) {
        $null = Set-TrackerName $old.id $__trOpt.Name; $null = Set-TrackerDescription $old.id $__trOpt.Description
        __TrOut ([pscustomobject]@{ id = $old.id; url = (Get-TrackerUrl $old.id); reused = $true }); return
      }
      $nt = New-TrackerTask -List $__trOpt.List -Name $__trOpt.Name -Description $__trOpt.Description -Parent $__trOpt.Parent -Assignee $__trOpt.Assignee -Priority $__trOpt.Priority -NewTask $__trOpt.NewTask -Related @(Split-KitList $__trOpt.Related) -Area ((@($__trOpt.Product, $__trOpt.Area) | Where-Object { $_ }) -join '-')
      if ($kf -and $nt.id) { Write-KitState $kf ([ordered]@{ key = $__trOpt.Key; id = $nt.id }) }
      __TrOut $nt
    }
    'bug' {   # ONE open QA collector [Bug] per ask (lib.ps1 Add-KitAskBug)
      if (-not ($__trOpt.Key -and $__trOpt.Name -and $__trOpt.Text)) { "usage: tracker bug -Parent <ask> -Key <qa-<run> | watch-<env>-<signature>> -Name '<title: the kit adds tracker.kindPrefixes.bug>' -File <md> [-Signature 'a|b'] [-List] [-Assignee] [-Priority]"; exit 2 }
      if ($__trOpt.Key -notmatch '^(qa|watch)-') { "tracker bug refused: -Key '$($__trOpt.Key)' is no QA / watch defect key (qa-<run>, watch-<env>-<signature>); any other task: tracker create -Spec <json> (crafty.ps1 ""task spec"")"; exit 1 }
      __TrOut (Add-KitAskBug -Ask $__trOpt.Parent -Key $__trOpt.Key -Name $__trOpt.Name -List $__trOpt.List -Assignee $__trOpt.Assignee -Priority $(if ($__trOpt.Priority) { $__trOpt.Priority } else { '2' }) -Defects @([pscustomobject]@{ label = $__trOpt.Key; sig = @("$($__trOpt.Signature)" -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); md = $__trOpt.Text; group = '' }))
    }
    'scope' { $__s = if ($__trOpt.Task) { $__trOpt.Task } else { $__id }; if (-not ($__s -and $__trOpt.Add)) { "usage: tracker scope -Task <id> -Add '<item>'"; exit 2 }; Add-TrackerScope $__s $__trOpt.Add }
    'url' { Get-TrackerUrl $__id }
    'owner' { Get-TrackerOwner }
    'describe' { if ((Read-KitState (Get-KitTaskFile $__id)).spec) { "tracker describe refused: $__id is rendered from its spec: tracker update $__id -Spec <json with the changed keys>"; exit 1 }
      $__nd = __TrText $(if ($__x) { $__x } elseif ($__trOpt.Description) { $__trOpt.Description } else { $__trOpt.Text }); if (-not "$__nd".Trim()) { 'usage: tracker describe <id> <text | existing file> | -Text <text> | -File <file> (empty text refused)'; exit 2 }; $__ot = Get-TrackerTask $__id; $__sub = [bool]"$($__ot.parent)"   # text or a file path; spec-less free text keeps every template section
      $__oldG = @(Get-KitTaskTextGaps 'x' "$($__ot.description)" -Subtask:$__sub); if ($__oldG -contains 'a description') { $__oldG = @(Get-KitTaskTemplate | ForEach-Object { "$($_.label)" }) }   # empty today: nothing to lose
      $__lost = @(Get-KitTaskTextGaps 'x' $__nd -Subtask:$__sub | Where-Object { $_ -notin $__oldG })
      if ($__lost.Count) { "tracker describe refused: the text lacks $($__lost -join ', ') (templates.md task-description): render it from a spec: tracker update $__id -Spec <json> (crafty.ps1 ""task spec""; doc links and kit sections stay)"; exit 1 }
      Set-TrackerDescription $__id $__nd -Resolved; if ($script:KitDescBackup) { "old description kept: $script:KitDescBackup" } }
    'rename' { Set-TrackerName $__id $(if ($__x) { $__x } else { $__trOpt.Name }) }
    'move' {   # K54: re-parent, list or top-level; state and both parents' Items follow
      if (-not ($__id -and ($__trOpt.Parent -or $__trOpt.List -or $__trOpt.NoParent))) { 'usage: tracker move <id> [-Parent <p>] [-List <l>] [-NoParent] [-DryRun]'; exit 2 }
      Move-KitTask $__id -Parent "$($__trOpt.Parent)" -List "$($__trOpt.List)" -Top:([bool]$__trOpt.NoParent) -DryRun:([bool]$__trOpt.DryRun) }
    'group' {   # K54: tasks under one parent (made from -Spec if missing)
      if (-not ($__trOpt.Tasks -and ($__trOpt.Parent -or $__trOpt.Spec))) { 'usage: tracker group -Parent <p> | -Spec <parent spec json> -Tasks <id,id,...> [-DryRun]'; exit 2 }
      Invoke-KitTaskGroup -Parent "$($__trOpt.Parent)" -Tasks @(Split-KitList $__trOpt.Tasks) -Spec $(if ($__trOpt.Spec) { $__sp }) -DryRun:([bool]$__trOpt.DryRun) }
    'attach' { Add-TrackerAttachment $__id $__trPos[2] $__trOpt.Text }
    'list' { __TrOut @(Get-TrackerTasks $__id $__x) }
    default { 'usage: crafty.ps1 tracker view|statuses|status|comment|comments|uncomment|create|update|render|bug|scope|owner|url|describe|rename|move|group|attach|list <id> ... [-Type <backend>] [-DryRun]'; exit 2 }
  }
}

# ---- scope: brief area globs (agents[].paths) vs a diff (wt commit, deploy plan, supervise); devtools.py glob_rx alike
function ConvertTo-KitGlobRx([string]$Glob) {   # ** any folders, * ? in one name, {a,b}, a trailing / all below
  $g = ($Glob.Trim() -replace '\\', '/') -replace '^\./'; if ($g.EndsWith('/')) { $g += '**' }
  $part = { param($s) @([regex]::Split($s, '(\*\*/?|\*|\?)') | ForEach-Object { switch -CaseSensitive ($_) { '**/' { '(?:.*/)?' } '**' { '.*' } '*' { '[^/]*' } '?' { '[^/]' } default { [regex]::Escape($_) } } }) -join '' }
  '^' + (@([regex]::Split($g, '(\{[^{}]*\})') | ForEach-Object { if ($_ -match '^\{(.*)\}$') { '(?:' + (@($Matches[1] -split ',' | ForEach-Object { & $part $_ }) -join '|') + ')' } else { & $part $_ } }) -join '') + '\z'
}
function Get-KitScopeOutside([string[]]$Files, [string[]]$Globs) {   # no globs: no area, nothing outside
  $rx = @($Globs | Where-Object { "$_".Trim() } | ForEach-Object { ConvertTo-KitGlobRx $_ }); if (-not $rx.Count) { return @() }
  @($Files | Where-Object { $f = $_; $_ -and -not @($rx | Where-Object { $f -cmatch $_ }).Count })
}
$script:KitTestPathRx = '(?i)(^|/)(tests?|__tests__|specs?|cypress|e2e|fixtures?)/|[._-](test|spec|cy)\.\w+$|Tests?\.\w+$|(^|/)test_[^/]+\.py$'
function Invoke-Scope([Alias('Mr')][string]$Mrs, [int]$Days = 7, [switch]$Json) {
  $now = Get-Date; $log = @(Read-KitLog scope-log $now.AddDays(-30)); $areas = [ordered]@{}; $seen = @{}
  foreach ($x in $log) { if ($x.event -eq 'area' -and $x.mr) { $areas["$($x.mr)"] = $x } elseif ($x.event -eq 'checked') { $seen["$($x.mr)"] = $x } }
  $crew = @('coordinator') + @(Get-ChildItem (Join-Path $KitConf.Kit 'agents') -Filter '*.md' -ErrorAction SilentlyContinue).BaseName
  $words = @(Read-KitJsonFiles (Get-KitPath decisions) | Where-Object { $_.gate -eq 'scope' -and $_.status -eq 'answered' -and ("$($_.by)" -split '[-_ :]')[0] -notin $crew })
  $lifted = { param($c) @($words | Where-Object { ($_.item -and $_.item -in "$($c.branch)", "$($c.mr)") -or "$($c.mr)" -in @($_.mrs) }).Count -gt 0 }   # a person's scope word
  $filesOf = { param($m) $rn, $iid = $m -split '!', 2; $ch = try { Invoke-HostVerb 'mr.changes' @{ repo = (Get-HostProject $rn -Raw); n = $iid } } catch { $null }; @($ch.changes | ForEach-Object { $_.new_path; $_.old_path } | Where-Object { $_ } | Select-Object -Unique) }
  if ($Mrs) {   # each MR's source / test files and area (the deploy plan shows them)
    $rows = foreach ($m in @(Split-KitList $Mrs)) {
      $k = if ($m -match '([^/]+)/(?:-/)?(?:merge_requests|pulls?|pull-requests|pullrequest)/(\d+)') { "$($Matches[1])!$($Matches[2])" } else { $m -replace '^.*/' }
      $f = @(& $filesOf $k); $a = $areas[$k]
      [pscustomobject]@{ mr = $k; files = $f.Count; source = @($f | Where-Object { $_ -notmatch $script:KitTestPathRx }); test = @($f | Where-Object { $_ -match $script:KitTestPathRx }).Count; globs = @(if ($a) { $a.globs })
        outside = @(if ($a -and -not (& $lifted ([pscustomobject]@{ mr = $k; branch = $a.branch }))) { Get-KitScopeOutside $f @($a.globs) }) }
    }
    if ($Json) { ConvertTo-Json @($rows) -Depth 4; return }
    foreach ($r in $rows) { "$($r.mr): $(if ($r.files) { "$($r.files) file(s), $(@($r.source).Count) source, $($r.test) test" } else { 'files unknown (no change list)' })$(if (@($r.outside).Count) { " · OUT-OF-AREA: $(@($r.outside).Count) outside $($r.globs -join ', '): $(@($r.outside) -join ', ')" })" }
    return
  }
  # post-hoc: MRs merged within -Days with a logged area, each checked once
  # an open MR re-asked after 30 min, host calls cut at 20 s
  $pf = Join-Path (Get-KitPath cache -Create) 'scope-probes.json'; $probed = try { Read-KitText $pf | ConvertFrom-Json -AsHashtable } catch { @{} }; if ($probed -isnot [hashtable]) { $probed = @{} }; $stopAt = $now.AddSeconds(20)
  $hits = foreach ($a in @($areas.Values | Where-Object { [datetime]$_.at -ge $now.AddDays(-$Days) } | Sort-Object { if ($probed["$($_.mr)"]) { [datetime]$probed["$($_.mr)"] } else { [datetime]::MinValue } })) {   # least recently asked first: the 20 s cut never starves one
    if (-not ($c = $seen["$($a.mr)"])) {
      if ((Get-Date) -gt $stopAt -or ($probed["$($a.mr)"] -and ($now - [datetime]$probed["$($a.mr)"]).TotalMinutes -lt 30)) { continue }
      $rn, $iid = "$($a.mr)" -split '!', 2; $m = try { Invoke-HostVerb 'mr.get' @{ repo = (Get-HostProject $rn -Raw); n = $iid } } catch { $null }
      if ($m.state -and $m.state -ne 'merged') { $probed["$($a.mr)"] = $now.ToString('o') }   # open or closed; unknown: next round
      if ($m.state -ne 'merged' -or -not ($f = @(& $filesOf "$($a.mr)")).Count) { continue }   # open: devtools.py merge checks it; unknown: next round
      $c = [ordered]@{ mr ="$($a.mr)"; branch = "$($a.branch)"; globs = @($a.globs); outside = @(Get-KitScopeOutside $f @($a.globs)); mergedAt = "$($m.merged_at)" }
      Write-KitLog scope-log checked $c
    }
    if (-not @($c.outside).Count -or ($c.mergedAt -and ($now - [datetime]$c.mergedAt).TotalDays -gt $Days) -or (& $lifted $c)) { continue }
    "$($c.mr) ($(@($c.outside).Count) file(s) outside $(@($c.globs) -join ', '): $((@($c.outside) | Select-Object -First 4) -join ', '))"
  }
  foreach ($pk in @($probed.Keys | Where-Object { ($now - [datetime]$probed[$_]).TotalDays -gt 1 })) { $probed.Remove($pk) }; Write-KitAtomic $pf ($probed | ConvertTo-Json -Compress)
  if (@($hits).Count) { "WATCH OUT-OF-AREA merged: $(@($hits) -join '; ') | Tell the owner before any deploy of it: a revert MR, or their yes: decide record -Gate scope -Item <branch> (then supervise -Ack)." } else { 'scope: no merged MR outside its area' }
}

# ---- host: git-host / ci adapters for devtools.py
# a bare MR ref (MR URL, [group/]repo!iid, "repo iid", iid = the current folder's origin) -> @{ repo; n [; type] }, else $null
function ConvertFrom-MrRef([string[]]$Ref) {
  $s = (@($Ref | Where-Object { $_ }) -join ' ').Trim()
  if ($u = ConvertFrom-MrUrl $s) { return $u }
  if ($s -match '^(?<r>[A-Za-z][\w./-]*)(?:!|\s+)(?<n>\d+)$') { return @{ repo = $Matches.r; n = $Matches.n } }
  if ($s -notmatch '^!?(?<n>\d+)$') { return $null }
  $n = $Matches.n
  if ("$(git remote get-url origin 2>$null)".Trim() -match '^(?:\w+://(?:[^@/]+@)?(?<h>[^/]+)/|[^@]+@(?<h>[^:]+):)(?<p>.+?)(?:\.git)?/?$') {
    $originHost = $Matches.h -replace ':\d+$'; @{ repo = $Matches.p -replace '/_git/', '/' -replace '^v3/'; n = $n; type = $(if ($originHost -eq $KitConf.GitHost) { $script:HostType } else { Get-HostKind $originHost }) } }
  else { Stop-KitVerb "host: iid $n needs a git folder with an origin: use repo!iid or the MR URL" }
}
function Invoke-Host([Parameter(Mandatory)][string]$Verb, [string]$ArgJson = '{}', [Parameter(ValueFromRemainingArguments)][string[]]$MrRef) {
  if ($ArgJson -match '^\s*[{@]' -and @($MrRef | Where-Object { $_ }).Count) { Stop-KitVerb "host: extra argument(s) after the JSON: $($MrRef -join ' ')" }
  $a = if ($ArgJson -match '^\s*[{@]') { $(if ($ArgJson -like '@*') { Get-Content -LiteralPath $ArgJson.Substring(1) -Raw -Encoding utf8 } else { $ArgJson }) | ConvertFrom-Json -AsHashtable }
  else { ConvertFrom-MrRef (@($ArgJson) + @($MrRef)) }   # a bare MR ref: 17 usage errors in one retro
  if ($null -eq $a) { Stop-KitVerb "host: '$((@($ArgJson) + @($MrRef) | Where-Object { $_ }) -join ' ')' is no JSON and no MR ref. Usage: host <verb> '<args JSON>' | host <verb> <iid | [group/]repo!iid | MR URL | repo iid>" }
  $global:KitHostFailed = $false; $r = @(Invoke-HostVerb $Verb $a -NoMemo | Where-Object { $null -ne $_ })   # a failed call = null (unknown)
  if (-not $r.Count -and $global:KitHostFailed) { 'null' } elseif ($Verb -in 'mr.list', 'ci.runs', 'ci.jobs') { ConvertTo-Json -InputObject $r -Depth 8 -Compress }
  elseif ($r.Count -eq 1 -and $r[0] -is [string]) { $r[0] } else { ConvertTo-Json -InputObject $(if ($r.Count) { $r[0] } else { $null }) -Depth 8 -Compress }
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced: functions only
  switch ($__verb) {
    'wt' { Invoke-KitVerb Invoke-Wt $__rest }
    'dir' { Invoke-KitVerb Invoke-Dir $__rest }
    'checkpoint' { Invoke-KitVerb Invoke-Checkpoint $__rest }
    'stack' { Invoke-KitVerb Invoke-Stack $__rest }
    'gate' { Invoke-KitVerb Invoke-Gate $__rest }
    'check' { Invoke-KitVerb Invoke-Check $__rest }
    'pipes' { Invoke-KitVerb Invoke-Pipes $__rest }
    'guard' { Invoke-KitVerb Invoke-Guard $__rest }
    'prior' { Invoke-KitVerb Invoke-Prior $__rest }
    'tracker' { Invoke-KitVerb Invoke-Tracker $__rest }
    'host' { Invoke-KitVerb Invoke-Host $__rest }
    'scope' { Invoke-KitVerb Invoke-Scope $__rest }
    'runtime' { Invoke-KitVerb Invoke-Runtime $__rest }
    default { Get-Content $PSCommandPath -TotalCount 18 | Select-Object -Skip 1; exit $(if ($__verb -in '-h', '--help', 'help', '-?') { 0 } else { 2 }) }
  }
}
