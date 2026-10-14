<#
Git worktrees for parallel agents, for any repo and stack.

  $K = '<workspace>/.claude/skills/dev-kit/scripts'
  & $K/wt.ps1 new    -Repo <main checkout> -Branch <branch> -Target <target branch> -Name <agent prefix> [-LinkFrom <checkout>]
  & $K/wt.ps1 sync   -Dir <worktree>                 # fetch + rebase onto the target (do it before editing, before push, before merge)
  & $K/wt.ps1 commit -Dir <worktree> -Message "<msg>" # commit with the repo's hooks really running (fixes .husky in worktrees)
  & $K/wt.ps1 status -Dir <worktree>                 # branch, target, ahead/behind, dirty files, linked deps
  & $K/wt.ps1 remove -Dir <worktree> [-Force]        # unlink deps safely, then remove the worktree
  & $K/wt.ps1 list   -Repo <main checkout>

new:
- creates <Root>/<Name>-<repo folder name> (Root = $env:CLAUDE_WT_ROOT, else kit.local.json worktreeRoots[0], else "<repo's parent>-wt") on a new branch from origin/<Target>;
- links installed dependencies from -LinkFrom (default: the main checkout) as junctions (Windows) or symlinks (Linux/macOS),
  so nothing is reinstalled:
  every node_modules next to a tracked package.json, and every .venv next to pyproject.toml/requirements.txt;
  it warns when the worktree's package.json dependencies differ from the source's (wrong versions = confusing tsc/build errors);
- copies generated hook folders that worktrees miss (.husky/_).
commit: first adds whatever of those a worktree lacks (one not made by `new`) from the main checkout, so its hooks really run.
Never run npm/yarn/pip install inside a linked folder: it writes into the source checkout.
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('new', 'sync', 'commit', 'status', 'remove', 'list')][string]$Action,
  [string]$Repo, [string]$Branch, [string]$Target, [string]$Name, [string]$LinkFrom, [string]$Root,
  [string]$Dir, [string]$Message, [switch]$Force, [switch]$NoStage
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sysinfo.ps1')
function G { $o = & git @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' '): $o" }; $o }
function GitDir($d) { $g = (git -C $d rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $d $g }; $g }
function Meta($d, $k, $v) { $f = Join-Path (GitDir $d) "claude-$k"; if ($PSBoundParameters.ContainsKey('v')) { $v | Set-Content $f } elseif (Test-Path $f) { Get-Content $f } }
function DepHash($pkgJson) {
  try { $p = Get-Content $pkgJson -Raw | ConvertFrom-Json } catch { return '' }
  (@('dependencies', 'devDependencies') | ForEach-Object { if ($p.$_) { $p.$_.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)@$($_.Value)" } } }) -join ';'
}
# Links node_modules next to every tracked package.json and .venv next to Python projects from $src, only where missing.
# Returns the links it made.
function Add-DepLinks($path, $src, $target) {
  $made = @()
  foreach ($pj in (git -C $path ls-files -- 'package.json' '*/package.json' | Where-Object { $_ -notmatch 'node_modules/' })) {
    $rel = Split-Path $pj; if (-not $rel) { $rel = "." }; $from = Join-Path $src (Join-Path $rel 'node_modules'); $to = Join-Path $path (Join-Path $rel 'node_modules')
    if ((Test-Path $from) -and -not (Test-Path $to)) {
      New-DirLink $to $from; $made += $to
      $a = DepHash (Join-Path $path $pj); $b = DepHash (Join-Path $src $pj)
      if ($a -ne $b) { Write-Warning "$pj dependencies differ from $src - linked node_modules may be the wrong versions.$(if ($target) { " Use -LinkFrom <a checkout of $target with matching installs>." })" }
    }
  }
  foreach ($py in (git -C $path ls-files -- 'pyproject.toml' '*/pyproject.toml' 'requirements.txt' '*/requirements.txt')) {
    $rel = Split-Path $py; if (-not $rel) { $rel = "." }; $from = Join-Path $src (Join-Path $rel '.venv'); $to = Join-Path $path (Join-Path $rel '.venv')
    if ((Test-Path $from) -and -not (Test-Path $to)) { New-DirLink $to $from; $made += $to }
  }
  $made
}
# Copies generated hook folders worktrees miss (.husky/_) from the first source that has each one.
function Copy-HookDirs($path, $sources) {
  foreach ($hs in @($sources | Where-Object { $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique)) {
    foreach ($h in (Get-ChildItem $hs -Directory -Recurse -Depth 3 -Filter '_' -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Name -eq '.husky' -and $_.FullName -notmatch 'node_modules' })) {
      $to = Join-Path $path $h.FullName.Substring($hs.Length).TrimStart('\', '/')
      if (-not (Test-Path $to)) { Copy-Item $h.FullName $to -Recurse }
    }
  }
}
# git sees a symlink as a file, so a dir-only ignore rule (node_modules/) misses it and `wt.ps1 commit` (git add -A) would
# commit the link: exclude each linked path (a junction on Windows is a directory and stays ignored as before)
function Exclude-Links($path, $links) {
  if (-not $links -or $KitIsWindows) { return }
  $ex = Join-Path (git -C $path rev-parse --path-format=absolute --git-common-dir).Trim() 'info/exclude'
  New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
  $have = @(if (Test-Path $ex) { Get-Content $ex })
  $add = @($links | ForEach-Object { '/' + [IO.Path]::GetRelativePath($path, $_).Replace('\', '/') } | Where-Object { $_ -notin $have })
  if ($add) { Add-Content $ex $add }
}

switch ($Action) {
  'new' {
    if (-not ($Repo -and $Branch -and $Target -and $Name)) { throw 'new needs -Repo -Branch -Target -Name' }
    $Repo = (Resolve-Path $Repo).Path
    # Root: -Root, else $env:CLAUDE_WT_ROOT, else kit.local.json "worktreeRoots"[0] (the same list cleanup/status scan), else
    # <repo's parent>-wt. An org can keep worktrees inside its repos folder this way (e.g. "<reposRoot>/.worktrees").
    if (-not $Root) {
      $kcRoot = $null
      try { . (Join-Path $PSScriptRoot 'kitconfig.ps1'); if ($env:CLAUDE_WT_ROOT -or (Get-KitValue 'worktreeRoots' $null)) { $kcRoot = @($KitConf.WorktreeRoots)[0] } } catch { }
      $Root = if ($kcRoot) { $kcRoot } else { (Split-Path $Repo) + '-wt' }
    }
    $path = Join-Path $Root "$Name-$(Split-Path $Repo -Leaf)"
    if (Test-Path $path) { throw "$path already exists - resume there (wt.ps1 status -Dir $path) or pick another -Name" }
    # no -LinkFrom: use kit.local.json repos[].linkFromByTarget[<target>] (or linkFrom when <target> is the repo's default target).
    # One repo can ship several products from different branches; linking the main checkout's installs (another branch) gave
    # agents silently wrong dependency versions. Resolved BEFORE the worktree exists: a configured source that is missing is an
    # error (it used to fall back to the main checkout silently and every typecheck failed on version drift).
    $r = $null
    $kc = Join-Path (Split-Path $PSScriptRoot) 'kit.local.json'
    if (Test-Path $kc) {
      $rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
      $r = @((Get-Content $kc -Raw | ConvertFrom-Json).repos) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1
    }
    if (-not $LinkFrom) {
      if ($r) {
        $cand = if ($r.linkFromByTarget -and $r.linkFromByTarget.$Target) { $r.linkFromByTarget.$Target } elseif ($r.linkFrom -and $Target -eq $r.target) { $r.linkFrom } else { $null }
        if ($cand -and -not (Test-Path $cand)) { throw "kit.local.json names $cand as the dependency source for $(Split-Path $Repo -Leaf) target $Target, but it does not exist. Create it (git worktree add --detach <path> origin/$Target + a frozen-lockfile install) or fix kit.local.json." }
        if ($cand) { $LinkFrom = $cand; "linking dependencies from $cand (kit.local.json, target $Target)" }
      }
    }
    New-Item -ItemType Directory -Force $Root | Out-Null
    # a root inside another git repo (e.g. a superproject that holds the checkouts) must not show up there as untracked files
    $outer = git -C $Root rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $outer) {
      $outer = (Resolve-Path $outer.Trim()).Path; $rootFull = (Resolve-Path $Root).Path
      if ($rootFull.StartsWith($outer, [StringComparison]::OrdinalIgnoreCase) -and $rootFull.Length -gt $outer.Length) {
        $rel = '/' + $rootFull.Substring($outer.Length).TrimStart('\', '/').Replace('\', '/') + '/'
        $ex = Join-Path (git -C $outer rev-parse --path-format=absolute --git-common-dir).Trim() 'info/exclude'
        New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
        if (-not ((Test-Path $ex) -and (Select-String -Path $ex -SimpleMatch -Pattern $rel -Quiet))) { Add-Content $ex $rel }
      }
    }
    G -C $Repo fetch -q origin $Target | Out-Null
    $remoteBranch = git -C $Repo ls-remote --heads origin $Branch
    git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"
    # the local branch outlives `wt.ps1 remove`: check it out again as it is (-B would reset it and lose unpushed commits)
    if ($LASTEXITCODE -eq 0) { G -C $Repo worktree add $path $Branch | Out-Null; "local branch $Branch already exists - checked it out as it is$(if ($remoteBranch) { " (also on origin: compare with origin/$Branch before pushing)" })" }
    elseif ($remoteBranch) { G -C $Repo fetch -q origin $Branch | Out-Null; G -C $Repo worktree add -b $Branch $path "origin/$Branch" | Out-Null; "branch $Branch already on origin - checked it out" }
    else { G -C $Repo worktree add -b $Branch $path "origin/$Target" | Out-Null }
    Meta $path 'target' $Target
    $src = if ($LinkFrom) { (Resolve-Path $LinkFrom).Path } else { $Repo }
    $links = @(Add-DepLinks $path $src $Target)
    # kit.local.json repos[].linkPaths: git-ignored local files/folders every worktree needs (credentials, local.properties,
    # .env ...), taken from the dependency source (else the main checkout). Folders are linked, files are copied.
    foreach ($lp in @($r.linkPaths) | Where-Object { $_ }) {
      $from = @((Join-Path $src $lp), (Join-Path $Repo $lp)) | Where-Object { Test-Path $_ } | Select-Object -First 1
      $to = Join-Path $path $lp
      if (-not $from) { Write-Warning "linkPaths: $lp not found in $src or $Repo - skipped"; continue }
      if (Test-Path $to) { continue }
      New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
      if ((Get-Item $from).PSIsContainer) { New-DirLink $to $from; $links += $to } else { Copy-Item $from $to }
    }
    # A dependency checkout installed with --ignore-scripts has no .husky/_ (husky's prepare script never ran), so fall back to
    # the main checkout for any hook folder the link source lacks.
    Copy-HookDirs $path @($src, $Repo)
    Meta $path 'links' ($links -join "`n")
    Exclude-Links $path $links
    "worktree: $path"
    "branch:   $Branch (from origin/$Target)"
    if ($links) { 'linked:   ' + (($links | ForEach-Object { $_.Substring($path.Length + 1) }) -join ', ') + "  (from $src)" }
  }
  'sync' {
    $t = Meta $Dir 'target'; if (-not $t) { throw "no target recorded for $Dir - run: git -C $Dir rebase origin/<target>" }
    if (git -C $Dir status --porcelain --untracked-files=no) { throw 'uncommitted changes - commit them first (a WIP commit is fine; never git stash, it is shared across worktrees)' }
    G -C $Dir fetch -q origin $t | Out-Null
    git -C $Dir rebase "origin/$t"
    if ($LASTEXITCODE) { "REBASE CONFLICT. Append-only files (master.xml, nav/i18n lists): $(Split-Path (Get-Python) -Leaf) $(Join-Path $PSScriptRoot 'keepboth.py') <file>; real code: resolve by hand. Then git add + git -C $Dir rebase --continue, and re-run check.ps1."; exit 1 }
    "rebased onto origin/$t"
  }
  'commit' {
    if (-not $Message) { throw 'commit needs -Message' }
    # A worktree not made by `new` (a hand-made release-merge worktree, say) lacks .husky/_ and the node_modules its hooks run
    # (husky.sh not found, then 'prettier' not recognized): add whatever is missing from the main checkout first.
    # main checkout = the common git dir's core.worktree (a submodule: .git/modules/<name>, which `git worktree list` reports as
    # the main worktree itself), else the common dir's parent (<main>/.git)
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
    # A hooksPath folder without hook scripts (e.g. a husky v8 repo whose `.husky/_` holds only husky.sh) skips hooks too.
    if ($hp -and -not (Test-Path (Join-Path (Join-Path $Dir $hp) 'pre-commit')) -and -not (Test-Path (Join-Path (Join-Path $Dir $hp) 'prepare-commit-msg'))) {
      if (Test-Path (Join-Path $Dir '.husky')) { $c = @('-c', 'core.hooksPath=.husky') }
      else { Write-Warning "core.hooksPath=$hp does not exist in this worktree - hooks would be skipped" }
    }
    if (-not $NoStage) { git -C $Dir add -A }   # stage everything in the worktree (agents expect commit to include their changes)
    git -C $Dir @c commit -m $Message
    exit $LASTEXITCODE
  }
  'status' {
    $t = Meta $Dir 'target'
    "branch: $((git -C $Dir rev-parse --abbrev-ref HEAD).Trim())   target: $t"
    if ($t) { git -C $Dir fetch -q origin $t 2>$null; "ahead/behind origin/${t}: $((git -C $Dir rev-list --left-right --count "HEAD...origin/$t") -replace '\s+', ' / ')" }
    git -C $Dir log --oneline -3
    git -C $Dir status --short | Select-Object -First 30
    $l = Meta $Dir 'links'; if ($l) { "linked: $($l -join ', ')" }
  }
  'remove' {
    $Dir = (Resolve-Path $Dir).Path
    $links = @(@(@(Meta $Dir 'links') | Where-Object { $_ -and (Test-Path $_) }) + @(Get-DirLinks $Dir 4 | ForEach-Object { $_.FullName }) | Sort-Object -Unique)
    if (-not $Force) {
      # the same test `git worktree remove` makes (untracked files count), run BEFORE any link goes; our own links don't count
      $mine = @($links | ForEach-Object { [IO.Path]::GetRelativePath($Dir, $_).Replace('\', '/') })
      $dirty = @(git -C $Dir status --porcelain | Where-Object { $_ -and ($_.Substring(3).Trim('"').TrimEnd('/') -notin $mine) })
      if ($dirty) { throw "uncommitted or untracked files in $Dir - commit/push or delete them, or pass -Force:`n$($dirty | Select-Object -First 10 | Out-String)" }
    }
    $undo = @(foreach ($l in $links) { , @($l, [string]@((Get-Item $l -Force).Target)[0]) })
    foreach ($l in $links) { if (Test-Path $l) { Remove-DirLink $l } }   # removes only the link (junction/symlink), never the linked folder
    $main = ((git -C $Dir worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', '')
    git -C $main worktree remove $(if ($Force) { '--force' }) $Dir
    if ($LASTEXITCODE) {
      foreach ($u in $undo) { if ($u[1] -and -not (Test-Path $u[0])) { New-DirLink $u[0] $u[1] } }
      throw "git worktree remove failed for $Dir (dependency links restored); fix what git reports, or pass -Force"
    }
    "removed $Dir"
  }
  'list' { git -C $Repo worktree list }
}
