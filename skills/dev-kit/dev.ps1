<#
dev.ps1: the dev-kit commands in one file (dev-kit SKILL.md steps 1-8). Run from pwsh 7:
  & <kit>/skills/dev-kit/dev.ps1 <verb> [args]
Verbs:
  wt new|sync|commit|remove|status ...      worktrees (deps linked, hooks really run)
  stack -Dir <module> [-Json]               the module's build/test/run commands (stack auto-detected; .claude-stack.json overrides)
  check -Dir <module> [-Step quick|test|build|migrations] [-Tests <names>] [-Touched]   gated checks (targeted + touched tests)
  gate -Dir <dir> -Cmd "<command>"          run any heavy command through the machine-wide memory gate
  tracker <verb> <id> ...                   the tracker adapter (view, status, comment, comments, create, list, ...)
  pipes -Mrs <url>,... [-MaxMinutes 8]      wait for MR pipelines (JSON)
  guard [-SelfTest]                         PreToolUse hook (reads the tool call JSON on stdin)
Inputs: kit.local.json (lib.ps1), the verb's parameters. Outputs: text, or JSON where -Json is offered.
Exit codes: 0 ok · 1 problem found (failed check, conflict, blocked) · 2 usage error · gate/check pass through the command's code.
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path $PSScriptRoot 'lib.ps1')
# ---------------------------------------------------------------- wt: worktrees (new, sync, commit, remove, status)
# Git worktrees for parallel agents, for any repo and stack.
#
#   $D = '<workspace>/.claude/skills/dev-kit/dev.ps1'
#   & $D wt new    -Repo <main checkout> -Branch <branch> -Target <target branch> -Name <agent prefix> [-LinkFrom <checkout>]
#   & $D wt sync   -Dir <worktree>                 # fetch + rebase onto the target (do it before editing, before push, before merge)
#   & $D wt commit -Dir <worktree> -Message "<msg>" | -MessageFile <file>   # commit with the repo's hooks really running (fixes .husky in worktrees)
#   & $D wt status -Dir <worktree>                 # branch, target, ahead/behind, dirty files, linked deps
#   & $D wt remove -Dir <worktree> [-Force]        # unlink deps safely, then remove the worktree
#   & $D wt list   -Repo <main checkout>
#
# new:
# - creates <Root>/<Name>-<repo folder name> (Root = $env:CLAUDE_WT_ROOT, else kit.local.json worktreeRoots[0], else "<repo's parent>-wt") on a new branch from origin/<Target>;
# - links installed dependencies from -LinkFrom (default: the main checkout) as junctions (Windows) or symlinks (Linux/macOS),
#   so nothing is reinstalled:
#   every node_modules next to a tracked package.json, and every .venv next to pyproject.toml/requirements.txt;
#   it warns when the worktree's package.json dependencies differ from the source's (wrong versions = confusing tsc/build errors);
# - copies generated hook folders that worktrees miss (.husky/_).
# commit: first adds whatever of those a worktree lacks (one not made by `new`) from the main checkout, so its hooks really run.
# Never run npm/yarn/pip install inside a linked folder: it writes into the source checkout.
# sync/commit/status/remove: -Dir defaults to the current folder and must be the top of a git worktree (else they refuse: git -C would
# fall through to an enclosing repo and commit its files). A merge (deploy branch: git merge --no-commit ...) is committed with commit too.
function Invoke-Wt {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('new', 'sync', 'commit', 'status', 'remove', 'list')][string]$Action,
  [string]$Repo, [string]$Branch, [string]$Target, [string]$Name, [string]$LinkFrom, [string]$Root,
  [string]$Dir, [string]$Message, [string]$MessageFile, [switch]$Force, [switch]$NoStage
)
$ErrorActionPreference = 'Stop'
function G { $o = & git @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' '): $o" }; $o }
# -Dir (default: the current folder) must be the top of a git worktree: inside a plain folder git -C walks up to an enclosing
# repo (a superproject), and commit's add -A once swept that repo's unrelated files into a commit
function Resolve-Wt($d) {
  if (-not $d) { $d = (Get-Location).Path }
  if (-not (Test-Path -LiteralPath $d -PathType Container)) { throw "no such folder: $d" }
  $d = (Resolve-Path -LiteralPath $d).Path.TrimEnd('\', '/')
  $pre = git -C $d rev-parse --show-prefix 2>$null   # '' only at the top of a worktree (junction/symlink paths compare right too)
  if ($LASTEXITCODE -or "$pre".Trim()) { throw "$d is not the top of a git worktree (git toplevel: $(git -C $d rev-parse --show-toplevel 2>$null)) - refusing; pass the worktree folder as -Dir" }
  $d
}
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
      $null = Set-NodeModules $to $from $src $path; $made += $to   # one junction, or a farm when it holds workspace packages (lib.ps1)
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
# git sees a symlink as a file, so a dir-only ignore rule (node_modules/) misses it and `dev.ps1 wt commit` (git add -A) would
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
      try { if ($env:CLAUDE_WT_ROOT -or (Get-KitValue 'worktreeRoots' $null)) { $kcRoot = @($KitConf.WorktreeRoots)[0] } } catch { }
      $Root = if ($kcRoot) { $kcRoot } else { (Split-Path $Repo) + '-wt' }
    }
    $path = Join-Path $Root "$Name-$(Split-Path $Repo -Leaf)"
    if (Test-Path $path) { throw "$path already exists - resume there (dev.ps1 wt status -Dir $path) or pick another -Name" }
    # no -LinkFrom: use kit.local.json repos[].linkFromByTarget[<target>] (or linkFrom when <target> is the repo's default target).
    # One repo can ship several products from different branches; linking the main checkout's installs (another branch) gave
    # agents silently wrong dependency versions. Resolved BEFORE the worktree exists: a configured source that is missing is an
    # error (it used to fall back to the main checkout silently and every typecheck failed on version drift).
    $r = $null
    $kc = Join-Path $PSScriptRoot 'kit.local.json'
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
    $remoteBranch = git -C $Repo ls-remote --heads origin "refs/heads/$Branch"   # a bare name matches by suffix (fix also matched f/fix)
    git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"
    # the local branch outlives `dev.ps1 wt remove`: check it out again as it is (-B would reset it and lose unpushed commits)
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
    $Dir = Resolve-Wt $Dir
    $t = Meta $Dir 'target'; if (-not $t) { throw "no target recorded for $Dir - run: git -C $Dir rebase origin/<target>" }
    if (git -C $Dir status --porcelain --untracked-files=no) { throw 'uncommitted changes - commit them first (a WIP commit is fine; never git stash, it is shared across worktrees)' }
    G -C $Dir fetch -q origin $t | Out-Null
    git -C $Dir rebase "origin/$t"
    if ($LASTEXITCODE) { "REBASE CONFLICT. Append-only files (master.xml, nav/i18n lists): $(Split-Path (Get-Python) -Leaf) $($KitCmd.devtools) keepboth <file>; real code: resolve by hand. Then git add + git -C $Dir rebase --continue, and re-run dev.ps1 check."; exit 1 }
    "rebased onto origin/$t"
  }
  'commit' {
    $Dir = Resolve-Wt $Dir
    if ($MessageFile) { if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { throw "no such message file: $MessageFile" }; $Message = Get-Content -LiteralPath $MessageFile -Raw -Encoding utf8 }
    if (-not $Message -or -not $Message.Trim()) { throw 'commit needs -Message or -MessageFile' }
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
    $hpFull = if ($hp -and [IO.Path]::IsPathRooted($hp)) { $hp } elseif ($hp) { Join-Path $Dir $hp }
    if ($hp -and -not (Test-Path (Join-Path $hpFull 'pre-commit')) -and -not (Test-Path (Join-Path $hpFull 'prepare-commit-msg'))) {
      if (Test-Path (Join-Path $Dir '.husky')) { $c = @('-c', 'core.hooksPath=.husky') }
      else { Write-Warning "core.hooksPath=$hp does not exist in this worktree - hooks would be skipped" }
    }
    if (-not $NoStage) { git -C $Dir add -A }   # stage everything in the worktree (agents expect commit to include their changes)
    # a merge in progress (deploy merge, main into a branch) is a merge commit: its subject names branches, not a Conventional type
    $isMerge = [bool](git -C $Dir rev-parse -q --verify MERGE_HEAD 2>$null)
    $null = Test-KitProse -Kind $(if ($isMerge) { 'merge-commit' } else { 'commit' }) -Text $Message
    git -C $Dir @c commit -m $Message
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
    $Dir = Resolve-Wt $Dir
    $links = @(@(@(Meta $Dir 'links') | Where-Object { $_ -and (Test-Path $_) }) + @(Get-DirLinks $Dir 4 | ForEach-Object { $_.FullName }) | Sort-Object -Unique)
    # entries inside a node_modules farm (a real folder of links) belong to the farm: removed and restored with it
    $farms = @($links | Where-Object { (Split-Path $_ -Leaf) -eq 'node_modules' -and -not (Get-Item -LiteralPath $_ -Force).LinkType })
    $links = @($links | Where-Object { $l = $_; -not @($farms | Where-Object { $l.StartsWith($_ + [IO.Path]::DirectorySeparatorChar) }).Count })
    if (-not $Force) {
      # the same test `git worktree remove` makes (untracked files count), run BEFORE any link goes; our own links don't count
      $mine = @($links | ForEach-Object { [IO.Path]::GetRelativePath($Dir, $_).Replace('\', '/') })
      $dirty = @(git -C $Dir status --porcelain | Where-Object { $_ -and ($_.Substring(3).Trim('"').TrimEnd('/') -notin $mine) })
      if ($dirty) { throw "uncommitted or untracked files in $Dir - commit/push or delete them, or pass -Force:`n$($dirty | Select-Object -First 10 | Out-String)" }
    }
    $undo = @(foreach ($l in $links) { if ($l -notin $farms) { , @($l, [string]@((Get-Item $l -Force).Target)[0]) } })
    $farmUndo = @(foreach ($f in $farms) { $m = Join-Path $f '.kit-farm.json'; if (Test-Path $m) { , @($f, ((Get-Content $m -Raw).Trim() -split '\|')) } })
    foreach ($l in $links) { if (Test-Path $l) { if ((Split-Path $l -Leaf) -eq 'node_modules' -or -not (Get-Item -LiteralPath $l -Force).LinkType) { Remove-NodeModules $l } else { Remove-DirLink $l } } }   # links only, never the linked folders (a node_modules farm: its links, then the folder)
    $main = ((git -C $Dir worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', '')
    git -C $main worktree remove $(if ($Force) { '--force' }) $Dir
    if ($LASTEXITCODE) {
      foreach ($u in $undo) { if ($u[1] -and -not (Test-Path $u[0])) { New-DirLink $u[0] $u[1] } }
      foreach ($u in $farmUndo) { $src = $u[1][0]; $wtr = $u[1][1]; $null = Set-NodeModules $u[0] $src (git -C $Dir rev-parse --path-format=absolute --git-common-dir | Split-Path) $wtr }
      throw "git worktree remove failed for $Dir (dependency links restored); fix what git reports, or pass -Force"
    }
    "removed $Dir"
  }
  'list' { git -C $Repo worktree list }
}
}

# ---------------------------------------------------------------- stack: detect build/test commands of a module
# Detects the build stack of a directory from its marker files and returns the commands for it.
# Works for any repo — nothing project-specific lives here.
#
#   & <workspace>/.claude/skills/dev-kit/dev.ps1 stack -Dir <dir>            # table: stack, dir, commands
#   & <workspace>/.claude/skills/dev-kit/dev.ps1 stack -Dir <dir> -Json      # same, as JSON (for agents/scripts)
#
# Looks in -Dir first, then walks up to the git root, and uses the nearest match.
# Commands use placeholders filled by dev.ps1 check: {tests} (test filter), {files} (paths), {sln} (solution file).
# run = the dev server / app start command local-env's localenv.ps1 uses when a service names no start ({port} = its port).
#
# Override for one repo/folder: put `.claude-stack.json` next to the marker file, e.g.
#   { "stack": "custom", "commands": { "compile": "make", "test": "make test T={tests}" } }
# Keys you set replace the detected ones; the rest stay.
function Invoke-Stack {
param([string]$Dir = (Get-Location).Path, [switch]$Json)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
if (Test-Path -LiteralPath $Dir -PathType Leaf) { $Dir = Split-Path $Dir }   # -Dir <file> (a .sln, pom.xml ...) = its folder
# Repo-local wrappers: .\mvnw.cmd / .\gradlew.bat on Windows, ./mvnw / ./gradlew elsewhere
function Wrapper($d, $name, $winExt, $fallback) {
  if ($KitIsWindows) { if (Test-Path (Join-Path $d "$name.$winExt")) { return ".\$name.$winExt" } }
  elseif (Test-Path (Join-Path $d $name)) { return "./$name" }
  $fallback
}

function Has($d, $pattern) { [bool](Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1) }
function First($d, $pattern) { Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
function ReadJson($f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { $null } }
function ReadText($f) { if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue } else { '' } }
# Package manager of a Node project: the lockfile in its folder or above it (monorepo), up to the git root. npm by default.
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
# <pm> run <script> [args] in the form each package manager passes arguments through
function NodeRun($pm, $script, $argText) {
  $a = if ($argText) { " $argText" } else { '' }
  switch ($pm) { 'npm' { "npm $(if ($script -ne 'test') { 'run ' })$script$(if ($a) { ' --' + $a })" } 'yarn' { "yarn $script$a" } default { "$pm run $script$a" } }
}
# tsconfig.json that only holds project references ("files": [] + "references", the Vite/Nx layout) type-checks nothing with
# -p tsconfig.json: use tsconfig.app.json when there is one
function TsProject($d) {
  $t = ReadText (Join-Path $d 'tsconfig.json')
  if ((Test-Path (Join-Path $d 'tsconfig.app.json')) -and $t -match '"references"\s*:\s*\[\s*\{' -and $t -match '"files"\s*:\s*\[\s*\]') { return 'tsconfig.app.json' }
  $null
}

# Web project with no unit-test target (no Karma/Vitest/Jest, no `test` script): spec.mjs bundles the given *.spec.ts files with
# the project's own esbuild and runs them under node with a jasmine/jest-like shim (pure-logic specs; no TestBed or DOM).
function NodeSpecCmd { "node `"$($KitCmd.spec)`" {tests}" }

function Get-NodeTools($d) {
  $pkg = ReadJson (Join-Path $d 'package.json')
  $deps = @()
  foreach ($k in 'dependencies', 'devDependencies') { if ($pkg.$k) { $deps += $pkg.$k.PSObject.Properties.Name } }
  $scripts = if ($pkg.scripts) { $pkg.scripts.PSObject.Properties.Name } else { @() }
  $jestCfg = @('jest-unit.config.json', 'jest.config.js', 'jest.config.ts', 'jest.config.json', 'jest.config.cjs', 'jest.config.mjs') | Where-Object { Test-Path (Join-Path $d $_) } | Select-Object -First 1
  [pscustomobject]@{
    Deps    = $deps; Scripts = $scripts
    Ts      = Test-Path (Join-Path $d 'tsconfig.json')
    Jest    = ($deps -contains 'jest') -or [bool]$jestCfg
    JestCfg = $jestCfg
    Vitest  = $deps -contains 'vitest'
    Eslint  = ($deps -contains 'eslint') -or (Has $d 'eslint.config.*') -or (Has $d '.eslintrc*')
  }
}

function Get-Stack($d) {
  $c = [ordered]@{ compile = $null; typecheck = $null; lint = $null; test = $null; build = $null; format = $null; run = $null }
  $s = $null; $deps = @()

  if (Test-Path (Join-Path $d 'pom.xml')) {
    $s = 'java-maven'
    $mvn = Wrapper $d 'mvnw' 'cmd' 'mvn'
    # offline (-o) = no network round-trips and no remote-repo lock contention between parallel builds; it needs the
    # dependencies in the local repo, so it is used only when ~/.m2/repository exists (kit.local.json build.mavenOffline: false = never)
    $off = if ((Get-KitSetting 'build.mavenOffline' $true) -ne $false -and "$(Get-KitSetting 'build.mavenOffline' $true)" -ne 'false' -and (Test-Path (Join-Path $HOME '.m2/repository'))) { '-o ' } else { '' }
    $c.compile = "$mvn $off-q compile"
    $c.test = "$mvn $off-q test -Dtest={tests} -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
    $c.build = "$mvn $off-q package -DskipTests"
    if ((ReadText (Join-Path $d 'pom.xml')) -match 'spring-boot') { $c.run = "$mvn $($off)spring-boot:run" }
  }
  elseif ((Has $d 'build.gradle') -or (Has $d 'build.gradle.kts') -or (Has $d 'settings.gradle*')) {
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    $android = (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($android) {
      $s = 'android-gradle'
      # Variant: .claude-stack.json "androidVariant" (e.g. "freeDebug"), else Debug, or <first product flavor>Debug when the
      # app module declares productFlavors (then compileDebugSources / testDebugUnitTest do not exist and Gradle fails)
      $var = [string](ReadJson (Join-Path $d '.claude-stack.json')).androidVariant
      if (-not $var) {
        $var = 'Debug'
        foreach ($bf in @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -Include build.gradle, build.gradle.kts -File -ErrorAction SilentlyContinue)) {
          $bt = ReadText $bf.FullName
          if ($bt -match '(?s)productFlavors\s*\{\s*(?:create\(\s*"|register\(\s*"|maybeCreate\(\s*")?([A-Za-z]\w*)') { $var = $Matches[1].Substring(0, 1).ToUpper() + $Matches[1].Substring(1) + 'Debug'; break }
        }
      } else { $var = $var.Substring(0, 1).ToUpper() + $var.Substring(1) }
      $c.compile = "$gw compile${var}Sources -q"
      $c.test = "$gw test${var}UnitTest --tests {tests}"
      $c.lint = "$gw lint$var"
      $c.build = "$gw assemble$var"
    } else {
      $s = 'gradle'
      $c.compile = "$gw classes -q"
      $c.test = "$gw test --tests {tests}"
      $c.build = "$gw assemble"
      $c.run = if ((@(Get-ChildItem -LiteralPath $d -Filter 'build.gradle*' -File -ErrorAction SilentlyContinue | ForEach-Object { ReadText $_.FullName }) -join ' ') -match 'org\.springframework\.boot') { "$gw bootRun" } else { "$gw run" }
    }
  }
  elseif ((Has $d '*.sln') -or (Has $d '*.csproj') -or (Has $d '*.fsproj') -or (Has $d '*.vbproj')) {
    # any old-style (non-SDK) project in the solution -> MSBuild, which also builds SDK-style projects
    $projs = Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Include *.csproj, *.fsproj, *.vbproj -File -ErrorAction SilentlyContinue | Select-Object -First 50
    $legacy = [bool]($projs | Where-Object { -not (Select-String -LiteralPath $_.FullName -Pattern '<Project\s+Sdk=' -Quiet) } | Select-Object -First 1)
    if ($legacy) {
      $s = 'dotnet-msbuild'
      # msbuild / vstest.console are on PATH only in a Developer prompt: otherwise find them with vswhere (Visual Studio / Build Tools)
      $msb = 'msbuild'; $vst = 'vstest.console.exe'
      $vswhere = if ($KitIsWindows -and ${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
      if ($vswhere -and (Test-Path $vswhere)) {
        if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null)[0]; if ($f) { $msb = "`"$f`"" } }
        if (-not (Get-Command vstest.console.exe -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -find '**\TestPlatform\vstest.console.exe' 2>$null)[0]; if ($f) { $vst = "`"$f`"" } }
      }
      $c.compile = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Debug"
      $c.build = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Release"
      $c.test = "$vst {tests}"   # .NET Framework test runner: Windows only
    } else {
      $s = 'dotnet'
      $c.compile = 'dotnet build "{sln}" -nologo -v q -m:2'
      $c.test = 'dotnet test "{sln}" -nologo --filter "{tests}"'
      $c.format = 'dotnet format "{sln}" --verify-no-changes'
      $c.build = 'dotnet build "{sln}" -nologo -v q -c Release'
      if ((Has $d '*.csproj') -or (Has $d '*.fsproj')) { $c.run = 'dotnet run --urls http://localhost:{port}' }   # a project folder (not a solution root)
    }
  }
  elseif (Test-Path (Join-Path $d 'angular.json')) {
    $s = 'angular'; $n = Get-NodeTools $d; $deps = @('node_modules')
    $tsc = if (Test-Path (Join-Path $d 'tsconfig.app.json')) { 'tsconfig.app.json' } else { 'tsconfig.json' }
    $c.typecheck = "npx tsc -p $tsc --noEmit"
    $c.build = 'npx ng build --configuration production'
    # test only when a project has a 'test' target; the flags depend on its builder (Karma takes --browsers, the
    # @angular/build:unit-test / Vitest runner does not). No target -> spec.mjs (pure-logic specs under node).
    # build: --configuration production only when the build target defines a 'production' configuration.
    $ngTest = $null
    try {
      $aj = Get-Content (Join-Path $d 'angular.json') -Raw | ConvertFrom-Json
      $bt = foreach ($p in $aj.projects.PSObject.Properties) { $b = if ($p.Value.architect.build) { $p.Value.architect.build } else { $p.Value.targets.build }; if ($b) { $b; break } }
      if ($bt -and -not ($bt.configurations -and $bt.configurations.PSObject.Properties.Name -contains 'production')) { $c.build = 'npx ng build' }
      foreach ($p in $aj.projects.PSObject.Properties) {
        $t = if ($p.Value.architect.test) { $p.Value.architect.test } elseif ($p.Value.targets.test) { $p.Value.targets.test } else { $null }
        if ($t) { $ngTest = [string]$t.builder; break }
      }
    } catch { $ngTest = 'karma' }
    if ($ngTest -match 'karma') { $c.test = 'npx ng test --watch=false --browsers=ChromeHeadless --include {tests}' }
    elseif ($ngTest) { $c.test = 'npx ng test --watch=false --include {tests}' }
    else { $c.test = NodeSpecCmd }   # no test target: spec.mjs runs pure-logic specs
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    $c.run = 'npx ng serve --port {port}'
  }
  elseif (Test-Path (Join-Path $d 'package.json')) {
    $n = Get-NodeTools $d; $deps = @('node_modules')
    $s = if ($n.Deps -contains 'react-native') { 'react-native' } elseif ($n.Deps -contains 'next') { 'node-next' } elseif ($n.Deps -contains 'react') { 'node-react' } else { 'node' }
    $pm = Get-NodePm $d   # npm / yarn / pnpm / bun, from the lockfile
    if ($n.Ts) { $tp = TsProject $d; $c.typecheck = if ($tp) { "npx tsc -p $tp --noEmit" } else { 'npx tsc --noEmit' } }
    if ($n.Vitest) { $c.test = 'npx vitest run {tests}' }
    elseif ($n.Jest) { $c.test = 'npx jest ' + $(if ($n.JestCfg) { "--config $($n.JestCfg) " } else { '' }) + '{tests} --no-watchman --forceExit' }
    elseif ($n.Scripts -contains 'test') { $c.test = NodeRun $pm 'test' '{tests}' }
    elseif ($n.Ts -and $s -ne 'react-native') { $c.test = NodeSpecCmd }   # TypeScript web project with no test runner
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    if ($s -ne 'react-native' -and $n.Scripts -contains 'build') { $c.build = NodeRun $pm 'build' '' }
    $agw = Wrapper (Join-Path $d 'android') 'gradlew' 'bat' $null
    if ($s -eq 'react-native' -and $agw) { $c.build = "cd android && $agw assembleRelease" }
    # dev server: Metro for React Native (Expo or bare), else the project's own dev / start script
    $c.run = if ($s -eq 'react-native') { if ($n.Deps -contains 'expo') { 'npx expo start --port {port}' } else { 'npx react-native start --port {port}' } }
             elseif ($n.Scripts -contains 'dev') { NodeRun $pm 'dev' '' } elseif ($n.Scripts -contains 'start') { NodeRun $pm 'start' '' } else { $null }
  }
  elseif ((Has $d 'pyproject.toml') -or (Has $d 'requirements*.txt') -or (Has $d 'setup.py') -or (Has $d 'Pipfile')) {
    $s = 'python'; $deps = @('.venv')
    $py = if ($KitIsWindows -and (Test-Path (Join-Path $d '.venv\Scripts\python.exe'))) { '.venv\Scripts\python.exe' }
          elseif (-not $KitIsWindows -and (Test-Path (Join-Path $d '.venv/bin/python'))) { '.venv/bin/python' }
          elseif ($KitIsWindows -or -not (Resolve-Tool python3)) { 'python' } else { 'python3' }
    $c.compile = "$py -m compileall -q -x `"[\\/](\.venv|venv|node_modules|\.git)[\\/]`" {files}"   # never walk a linked .venv
    # lint/test tools the project really has: ruff (else flake8) and pytest (else the standard library's unittest). Asked of
    # the project's interpreter in one call; if it cannot be asked, the config files decide (ruff + pytest as before).
    $cfgText = @('pyproject.toml', 'setup.cfg', 'tox.ini') | ForEach-Object { ReadText (Join-Path $d $_) }
    $have = $null
    $pyExe = if ($py -match '^\.venv') { Join-Path $d $py } else { (Resolve-Tool $py) }
    if ($pyExe -and (Test-Path $pyExe)) {
      $have = @(& $pyExe -c "import importlib.util as u; print(' '.join(m for m in ('ruff','flake8','pytest') if u.find_spec(m)))" 2>$null) -join ' '
      if ($LASTEXITCODE) { $have = $null }
    }
    $ruffCfg = (Has $d 'ruff.toml') -or (Has $d '.ruff.toml') -or ("$cfgText" -match '\[tool\.ruff')
    $flakeCfg = (Has $d '.flake8') -or ("$cfgText" -match '\[flake8\]')
    $pytestCfg = (Has $d 'pytest.ini') -or (Has $d 'conftest.py') -or ("$cfgText" -match '\[tool\.pytest|\[pytest\]|\[tool:pytest\]')
    if ($null -eq $have) { $c.lint = if ($flakeCfg -and -not $ruffCfg) { "$py -m flake8 {files}" } else { "$py -m ruff check {files}" }; $c.test = "$py -m pytest {tests} -q" }
    else {
      $c.lint = if ($have -match 'ruff' -and ($ruffCfg -or -not ($flakeCfg -and $have -match 'flake8'))) { "$py -m ruff check {files}" } elseif ($have -match 'flake8') { "$py -m flake8 {files}" } else { $null }
      $c.test = if ($have -match 'pytest' -or $pytestCfg) { "$py -m pytest {tests} -q" } else { "$py -m unittest {tests}" }
    }
    if (Test-Path (Join-Path $d 'manage.py')) { $c.run = "$py manage.py runserver {port}" }   # Django; other frameworks: .claude-stack.json commands.run
    if ((Has $d 'mypy.ini') -or (Select-String -LiteralPath (Join-Path $d 'pyproject.toml') -Pattern '\[tool\.mypy\]' -Quiet -ErrorAction SilentlyContinue)) { $c.typecheck = "$py -m mypy {files}" }
  }
  elseif (Test-Path (Join-Path $d 'go.mod')) {
    $s = 'go'
    $c.compile = 'go build ./...'; $c.run = 'go run .'; $c.test = 'go test ./... -run "{tests}"'; $c.lint = 'go vet ./...'; $c.format = 'gofmt -l .'
  }
  elseif (Test-Path (Join-Path $d 'Cargo.toml')) {
    $s = 'rust'
    $c.compile = 'cargo check -q'; $c.test = 'cargo test {tests}'; $c.lint = 'cargo clippy -q'; $c.build = 'cargo build --release'; $c.run = 'cargo run'; $c.format = 'cargo fmt --check'
  }
  elseif (Test-Path (Join-Path $d 'CMakeLists.txt')) {
    $s = 'cmake'
    $c.compile = 'cmake -S . -B build && cmake --build build -j 2'; $c.test = 'ctest --test-dir build -R "{tests}"'
  }
  elseif (Test-Path (Join-Path $d 'Makefile')) {
    $s = 'make'
    $c.compile = 'make'
    if ((ReadText (Join-Path $d 'Makefile')) -match '(?m)^test\s*:') { $c.test = 'make test' }   # only when the Makefile has a test target
  }
  if (-not $s) { return $null }

  $ovr = ReadJson (Join-Path $d '.claude-stack.json')
  if ($ovr) {
    if ($ovr.stack) { $s = $ovr.stack }
    if ($ovr.commands) { foreach ($p in $ovr.commands.PSObject.Properties) { $c[$p.Name] = $p.Value } }
    if ($ovr.deps) { $deps = @($ovr.deps) }
  }
  $sln = if ($s -like 'dotnet*') { (First $d '*.sln').Name } else { $null }
  [pscustomobject]@{ stack = $s; dir = $d; solution = $sln; deps = $deps; commands = [pscustomobject]$c }
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
if (-not $hit) { throw "No known stack under $Dir (looked up to the git root). Add a .claude-stack.json there." }
if ($Json) { $hit | ConvertTo-Json -Depth 4 }
else {
  "stack: $($hit.stack)   dir: $($hit.dir)$(if ($hit.solution) { "   solution: $($hit.solution)" })"
  $hit.commands.PSObject.Properties | Where-Object Value | ForEach-Object { '  {0,-9} {1}' -f $_.Name, $_.Value }
}
}

# ---------------------------------------------------------------- gate: machine-wide memory gate for heavy commands
# Machine-wide memory gate for heavy builds and tests, so parallel agents (plus other Claude sessions, IDEs,
# emulators and browsers) never run the machine out of RAM. Stack-agnostic: Maven, Gradle/Android, .NET,
# Angular/Node/React Native, Python, Go, Rust, CMake.
#
#   & <workspace>/.claude/skills/dev-kit/dev.ps1 gate -Dir <dir> -Cmd "<command>"
#
# Usually you call dev.ps1 check, which detects the command and runs it through this gate for you.
# The command runs in -Dir, so relative paths resolve against -Dir. On Windows it runs under cmd.exe: to run somewhere else write
# `cd /d <absolute dir> && <cmd>` (elsewhere `cd <dir> && <cmd>` under /bin/sh). cmd.exe has no ';' separator: on Windows a ';'
# outside quotes and followed by a space is rewritten to ' & ' (cmd's "then run", the same meaning) and the rewritten command is
# printed; a ';' inside a word (a Java classpath a.jar;b.jar) is left alone.
#
# There is no fixed limit on parallel builds. A build starts only when
#     available RAM - (memory still promised to running builds) - (this build's estimate)  >=  KeepFreeGB
# - available RAM = free + reclaimable cache (Windows "Available" as Task Manager shows it, Linux MemAvailable, macOS free +
#   inactive pages), read through lib.ps1 so the gate runs on Windows, Linux and macOS;
# - KeepFreeGB default = 15% of total RAM (min 6 GB); override with -KeepFreeGB, $env:CLAUDE_GATE_KEEP_FREE_GB or kit.local.json gate.keepFreeGB;
# - the estimate is LEARNED per PROJECT: each build's peak working set is recorded per command kind + repo (history.json) and the next
#   estimate is the recent peak (last 5 runs) + 15%, capped at 60% of total RAM; until there are 2 samples, a built-in default per
#   kind is used;
# - "promised" = for each gated build still running, max(0, its estimate - what its process tree uses now);
# - running builds are listed in a shared ledger in <OS temp folder>/claude-build-gate; dead entries are dropped;
# - starts are decided one at a time, under a named mutex, from a FAIR QUEUE: the owner (agent / worktree) with the fewest
#   builds started in the last 30 min goes first, then the longest-waiting; a smaller build may backfill only while the head of
#   the queue doesn't fit and has waited < 20 min; after that only a SMALL build (its kind's median <= 120 s and need <= 2 GB, from
#   history) that fits may, one at a time. Owner = $env:CLAUDE_AGENT, else the worktree folder minus its repo suffix
#   (b-api-backend -> b-api), else its first dash part (x1-backend -> x1).
# - history.json samples: { gb, sec, ok, at, code, cmd (first 60 chars) }; older samples lack at / code / cmd.
# - heap caps follow load INTELLIGENTLY: ceiling = start value or learned peak x 1.25; floor = what this project's build really
#   uses (learned peak x 1.1, min 4 GB). With N builds queued each gets an equal share of the free memory, clamped between floor
#   and ceiling: plenty of room -> full headroom and builds run side by side; crowded -> heaps shrink toward real usage (never below
#   it, so nothing thrashes in GC), and whatever still doesn't fit waits its fair turn.
# - while waiting it prints its queue position and, now and then, the biggest memory users.
# Exit code = the command's exit code, or 3 if it could not start within -WaitMinutes.
# A build killed by someone else is not a code failure: just run it again.
function Invoke-Gate {
param(
  [Parameter(Mandatory)][string]$Cmd,
  [string]$Dir = (Get-Location).Path,
  [int]$WaitMinutes = 90,
  [double]$KeepFreeGB = $(if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { -1 }),   # -1 = 15% of total RAM, min 6 GB
  [double]$NeedGB = 0,         # 0 = learned / default estimate for this kind of command
  [int]$MaxParallel = 0        # 0 = no fixed cap (memory decides)
)
# Heap caps for JVM (Maven) and Node builds are DYNAMIC and always override inherited flags (a user-level
# MAVEN_OPTS=-Xmx16g once made one gated `mvn test` take 6 GB):
#   new project (no history for this kind + repo): start Gradle 12 GB, Maven 8 GB, Node 4 GB;
#   after 2 recorded runs: learned peak x 1.25, never above the start value, never below 4 GB;
#   at start time, if memory is tight the heap is REDUCED toward 4 GB instead of waiting longer.
# All of these numbers can be set in kit.local.json "gate" (machines with less RAM, or JVM builds that need more):
#   { "keepFreeGB": 6, "heapMinGB": 4, "startHeapGB": { "gradle": 12, "maven": 8, "node": 4 } }
$HeapMinGB = [double](Get-KitSetting 'gate.heapMinGB' 4)
if ($KeepFreeGB -lt 0) { $KeepFreeGB = [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
$StartGB = @{ gradle = [double](Get-KitSetting 'gate.startHeapGB.gradle' 12); maven = [double](Get-KitSetting 'gate.startHeapGB.maven' 8); node = [double](Get-KitSetting 'gate.startHeapGB.node' 4) }
$mavenKeep = ([string]$env:MAVEN_OPTS -replace '-Xm[xs]\S+|-XX:\+Use\w+GC|-XX:MaxMetaspaceSize=\S+', '' -replace '\s+', ' ').Trim()
$nodeKeep = ([string]$env:NODE_OPTIONS -replace '--max-old-space-size=\d+', '' -replace '\s+', ' ').Trim()
if (-not $env:GRADLE_OPTS) { $env:GRADLE_OPTS = '-Dorg.gradle.workers.max=4' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# kind of command -> default GB (used until the gate has learned real peaks for that kind)
$Kinds = [ordered]@{
  'emulator'      = @('^exit 0 #emulator', 4.5)
  'android-build' = @('gradlew.*\b(assemble|bundle)', 7)
  'android-test'  = @('gradlew.*\btest|connectedAndroidTest|lintDebug', 6)
  'gradle'        = @('gradle(w|w\.bat)?\b', 3.5)
  'rn-bundle'     = @('export:embed|react-native bundle|expo export', 3)
  'e2e'           = @('cypress|playwright', 3.5)
  'ng-test'       = @('ng test|karma', 3)
  'web-build'     = @('ng build|next build|vite build|webpack|npm run build|yarn build|pnpm (run )?build|bun run build', 8)
  'maven-test'    = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b.*\b(test|verify|package|install)\b', 3)
  'maven'         = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b', 2.5)
  'dotnet'        = @('msbuild|dotnet (build|test|publish)', 3)
  'rust'          = @('cargo (build|test|clippy|check)', 4)
  'native'        = @('cmake --build|\bmake\b', 3)
  'js-test'       = @('jest|vitest', 2)
  'tsc-lint'      = @('\btsc\b|eslint', 2)
  'python'        = @('pytest|mypy|ruff|compileall', 1.5)
  'go'            = @('go (build|test|vet)', 2)
}
function Get-Kind([string]$c) { foreach ($k in $Kinds.Keys) { if ($c -match $Kinds[$k][0]) { return $k } }; 'other' }

# cmd.exe has no ';' separator ('a; b' runs a with the arguments ';' and 'b'). Rewrite a ';' outside double quotes that is followed
# by whitespace (or ends the command) to ' & ' (cmd's "then run"); a ';' inside a word (classpath a.jar;b.jar, -Dx=a;b) stays.
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
if ($KitIsWindows) { $semi = ConvertTo-CmdSeparators $Cmd; if ($semi -ne $Cmd) { Write-Host "[gate] cmd.exe has no ';' separator - running as: $semi"; $Cmd = $semi } }

# Repo-local wrappers must be called as .\gradlew.bat / .\mvnw.cmd: Claude Code sets NoDefaultCurrentDirectoryInExePath=1,
# so cmd.exe no longer finds programs in the current directory by bare name (sh never does: ./gradlew there).
$Cmd = [regex]::Replace($Cmd, '(^|&&\s*|&\s*|\|\|\s*)(?<!\.[\\/])(gradlew(\.bat)?|mvnw(\.cmd)?)(?=\s|$)', $(if ($KitIsWindows) { '$1.\$2' } else { '$1./$2' }))
# Test runners fork one worker per core by default; cap them.
if ($Cmd -match '\bjest\b' -and $Cmd -notmatch 'maxWorkers|runInBand|\s-i(\s|$)') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bvitest\b' -and $Cmd -notmatch 'maxWorkers|maxThreads') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bpytest\b' -and $Cmd -match '\s-n\s+auto') { $Cmd = $Cmd -replace '\s-n\s+auto', ' -n 2' }

$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
New-Item -ItemType Directory -Force $ledger | Out-Null
$histFile = Join-Path $ledger 'history.json'
function Read-History { try { Get-Content $histFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} } }

$kind = Get-Kind $Cmd
$default = if ($Kinds.Contains($kind)) { $Kinds[$kind][1] } else { 2 }
# Project = main repo name + the subproject folder inside it (repos can hold several modules, e.g. backend/services/api).
# Worktrees resolve to their main checkout (first entry of `git worktree list`), so x1-backend learns into backend.
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
$samples = @($hist[$histKey] | Where-Object { $_ })        # [{gb, sec, ok}, ...] newest last
$peaks = @($samples | ForEach-Object { [double]$_.gb })
$secs = @($samples | ForEach-Object { [double]$_.sec } | Sort-Object)
# Small build (may backfill past a starving head, see the queue loop): this kind's median run <= 120 s and need <= 2 GB, from
# history (this project's samples, else every project's samples of the kind; under 2 samples it is never small). Old samples
# without at/code/cmd are fine: only sec is read.
function Get-MedianSec([double[]]$Secs) { $s = @($Secs | Sort-Object); if ($s.Count -lt 2) { return -1 }; $s[[int][math]::Floor($s.Count / 2)] }
function Test-SmallBuild([double]$Need, [double]$MedianSec) { $MedianSec -ge 0 -and $MedianSec -le 120 -and $Need -le 2 }
$kindSecs = if ($secs.Count -ge 2) { $secs } else { @($hist.Keys | Where-Object { $_ -like "$kind|*" } | ForEach-Object { @($hist[$_]) | Where-Object { $_ -and $null -ne $_.sec } | ForEach-Object { [double]$_.sec } }) }
$medianSec = Get-MedianSec $kindSecs
# Estimate: with 2+ recorded peaks, the recent max (last 5) + 15%, never above 60% of total RAM (a cap at default x 1.5 once
# reserved 6 GB for web builds that peaked at 9.5 GB); fewer samples -> the kind's default.
function Get-NeedEstimate([double]$Default, [double[]]$Peaks, [double]$TotalGB) {
  if (@($Peaks).Count -lt 2) { return $Default }
  $recentMax = (@($Peaks) | Select-Object -Last 5 | Measure-Object -Maximum).Maximum
  [math]::Round([math]::Min($TotalGB * 0.6, [math]::Max(0.75, $recentMax * 1.15)), 1)
}
$need = if ($NeedGB -gt 0) { $NeedGB } else { Get-NeedEstimate $default $peaks (Get-SysMem).TotalGB }

# Dynamic heap for JVM / Node build kinds (see top of file)
$jvmKind = $kind -like 'maven*'
$nodeKind = $kind -in @('ng-test', 'web-build', 'js-test', 'tsc-lint', 'rn-bundle', 'e2e')
$gradleKind = $kind -in @('android-build', 'android-test', 'gradle')
$heap = 0
if ($jvmKind -or $nodeKind -or $gradleKind) {
  # Gradle (Android: Gradle + Kotlin + Hermes) starts high and learns down; Maven/Node start at the floor.
  # JVMs run G1 with tight free-ratios + periodic GC, so the heap tracks LIVE data and the recorded peak can fall
  # (without that a JVM fills whatever -Xmx it gets and the learned estimate never drops).
  $startHeap = if ($gradleKind) { $StartGB.gradle } elseif ($jvmKind) { $StartGB.maven } else { $StartGB.node }   # not $startGB: same variable as the $StartGB table
  $maxGB = [math]::Max($startHeap, 8)
  $heap = if ($peaks.Count -ge 2) { [int][math]::Ceiling((($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum) * 1.25) } else { $startHeap }
  $heap = [math]::Min($maxGB, [math]::Max($HeapMinGB, $heap))
  if ($NeedGB -le 0 -and $peaks.Count -lt 2) { $need = [math]::Max($need, $heap + 0.5) }   # no history yet: assume the heap can fill up
}
function Set-HeapEnv([int]$gb) {
  if ($jvmKind) { $env:MAVEN_OPTS = "$mavenKeep -Xmx${gb}g -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000".Trim() }   # G1 returns unused heap to the OS
  if ($nodeKind) { $env:NODE_OPTIONS = "$nodeKeep --max-old-space-size=$($gb * 1024)".Trim() }
  if ($gradleKind -and $script:Cmd -notmatch 'org\.gradle\.jvmargs') {
    # Gradle daemon heap comes from org.gradle.jvmargs (gradle.properties); a -D on the command line overrides it
    $script:Cmd = ([regex]'(gradlew(\.bat)?|\bgradle)(?=\s|$)').Replace($script:Cmd, "`$1 `"-Dorg.gradle.jvmargs=-Xmx${gb}g -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000 -Dfile.encoding=UTF-8`"", 1)
  }
}

# Owner for fair turns: explicit agent id, else the worktree folder minus its repo suffix (b-load-api-backend in repo backend
# -> b-load-java); a folder without that suffix (the main checkout, other names) -> its first dash part (x1-backend -> x1).
function Get-OwnerName([string]$Leaf, [string]$Repo) {
  if ($Repo -and $Leaf.Length -gt $Repo.Length + 1 -and $Leaf.EndsWith("-$Repo", [StringComparison]::OrdinalIgnoreCase)) { return $Leaf.Substring(0, $Leaf.Length - $Repo.Length - 1) }
  ($Leaf -split '-')[0]
}
$ownerRoot = if ($top) { Split-Path $top -Leaf } else { Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf }
$owner = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { Get-OwnerName $ownerRoot $(if ($top) { $repoName } else { '' }) }
$heapBase = $heap
# never shrink below what this project's build has really used (a smaller heap only makes it thrash in GC)
$heapFloor = if ($heap -gt 0 -and $peaks.Count -ge 2) { [math]::Min($heapBase, [math]::Max($HeapMinGB, [int][math]::Ceiling((($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum) * 1.1))) } else { $HeapMinGB }
$queueDir = Join-Path $ledger 'queue'; New-Item -ItemType Directory -Force $queueDir | Out-Null
$startsFile = Join-Path $ledger 'starts.jsonl'
$myTicket = Join-Path $queueDir "$PID.json"
$since = (Get-Date).ToString('o')
function Write-Ticket { @{ pid = $PID; owner = $owner; kind = $kind; need = $need; since = $since; dir = $Dir } | ConvertTo-Json -Compress | Set-Content $myTicket }
function Get-Queue {
  $q = foreach ($f in Get-ChildItem $queueDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $t = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not (Get-Process -Id $t.pid -ErrorAction SilentlyContinue)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $t
  }
  $cut = (Get-Date).AddMinutes(-30); $recent = @{}
  foreach ($l in Get-Content $startsFile -Tail 300 -ErrorAction SilentlyContinue) { try { $x = $l | ConvertFrom-Json; if ([datetime]$x.at -gt $cut) { $recent[$x.owner] = 1 + [int]$recent[$x.owner] } } catch {} }
  @($q | Sort-Object @{ e = { [int]$recent[$_.owner] } }, @{ e = { [datetime]$_.since } })
}

function Get-Procs {
  $procs = @{}; $kids = @{}; $names = @{}
  foreach ($p in Get-SysProcs -NoCommandLine) {
    $procs[$p.Id] = $p.WorkingSet; $names[$p.Id] = $p.Name
    $pp = $p.ParentId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add($p.Id)
  }
  @{ procs = $procs; kids = $kids; names = $names }
}
function Get-TreeGB([int]$rootPid, $Snap) {
  $sum = 0; $stack = New-Object System.Collections.Stack; $stack.Push($rootPid)
  while ($stack.Count) {
    $node = $stack.Pop()
    if ($Snap.procs.ContainsKey($node)) { $sum += $Snap.procs[$node] }
    if ($Snap.kids.ContainsKey($node)) { foreach ($k in $Snap.kids[$node]) { $stack.Push($k) } }
  }
  return $sum / 1GB
}
function Get-AvailGB { (Get-SysMem).AvailGB }
function Get-State {
  $Snap = Get-Procs
  $promised = 0; $running = 0; $backfills = 0
  foreach ($f in Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json') {
    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $Snap.procs.ContainsKey([int]$e.pid)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $running++
    if ($e.backfill) { $backfills++ }
    $promised += [math]::Max(0, [double]$e.need - (Get-TreeGB ([int]$e.pid) $Snap))
  }
  [pscustomobject]@{ Avail = (Get-AvailGB); Promised = [math]::Round($promised, 1); Running = $running; Backfills = $backfills; Snap = $Snap }
}
# May a build that is not the head of the queue start now? Returns '' (no), 'backfill' (the head doesn't fit and has waited < 20 min:
# any build that fits) or 'small' (the head has waited 20+ min: only a small build that fits, and only while no other small backfill
# runs, so the starving head is delayed by at most one short build).
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
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$learned = if ($NeedGB -le 0 -and $peaks.Count -ge 2) { " (learned from $($peaks.Count) runs)" } else { '' }
$usual = if ($secs.Count -ge 2) { " usually ~$([math]::Ceiling($secs[[int][math]::Floor($secs.Count / 2)] / 60)) min," } else { '' }
Write-Host "[gate] $kind needs ~$need GB$learned,$usual keep $KeepFreeGB GB free: $Cmd"
$proc = $null; $entry = $null; $waits = 0
Write-Ticket
try {
while ((Get-Date) -lt $deadline) {
  $got = $false
  try { $got = $gate.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { continue }
  try {
    $s = Get-State
    $queue = Get-Queue
    # Load-aware heap: equal share of free memory per queued build, clamped to [real-usage floor, headroom ceiling]
    if ($heapBase -gt 0 -and $NeedGB -le 0 -and $queue.Count -ge 2) {
      $share = [math]::Floor(($s.Avail - $s.Promised - $KeepFreeGB) / $queue.Count - 0.5)
      $h2 = [math]::Min($heapBase, [math]::Max($heapFloor, $share))
      if ($h2 -ne $heap) {
        Write-Host "[gate] $($queue.Count) builds queued, ~$share GB each: heap $heap GB -> $h2 GB (floor $heapFloor = real usage, ceiling $heapBase)"
        if ($peaks.Count -lt 2) { $need = $h2 + 0.5 }; $heap = $h2; Write-Ticket
      }
    }
    $left = $s.Avail - $s.Promised - $need
    # Fair turns: only the head of the queue may start; others may backfill only while the head doesn't fit (and isn't starving)
    $pos = [array]::IndexOf(@($queue | ForEach-Object { [int]$_.pid }), [int]$PID)
    $head = if ($queue.Count) { $queue[0] } else { $null }
    $myTurn = ($pos -le 0); $smallFill = $false
    if (-not $myTurn -and $head) {
      $room = $s.Avail - $s.Promised - $KeepFreeGB
      $headWaited = ((Get-Date) - [datetime]$head.since).TotalMinutes
      $mode = Get-BackfillMode ([double]$head.need) $headWaited $need $room (Test-SmallBuild $need $medianSec) $s.Backfills
      if ($mode -eq 'backfill') { $myTurn = $true; Write-Host "[gate] backfilling ahead of $($head.owner) (its $($head.need) GB doesn't fit yet)" }
      elseif ($mode -eq 'small') { $myTurn = $true; $smallFill = $true; Write-Host "[gate] small build (~$([int]$medianSec) s, $need GB) backfilling ahead of $($head.owner) (waited $([int]$headWaited) min; its $($head.need) GB doesn't fit yet)" }
    }
    if (-not $myTurn) {
      $waits++
      if ($waits % 3 -eq 1) { Write-Host "[gate] queued #$($pos + 1) of $($queue.Count) (owner $owner); next: $($head.owner) $($head.kind)" }
    }
    else {
    # Tight memory: shrink the heap toward the real-usage floor instead of waiting (never below it)
    if ($heap -gt 0 -and $left -lt $KeepFreeGB -and $NeedGB -le 0) {
      $room = [math]::Floor($s.Avail - $s.Promised - $KeepFreeGB - 0.5)
      if ($room -ge $heapFloor -and $room -lt $heap) {
        Write-Host "[gate] memory tight: heap $heap GB -> $room GB"
        $need = [math]::Max($heapFloor + 0.5, [math]::Min($need, $room + 0.5)); $heap = $room
        $left = $s.Avail - $s.Promised - $need
      }
    }
    if ($left -ge $KeepFreeGB -and (($MaxParallel -le 0) -or ($s.Running -lt $MaxParallel))) {
      if ($heap -gt 0) { Set-HeapEnv $heap }
      Write-Host "[gate] starting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> ~$([math]::Round($left,1)) GB left$(if ($heap -gt 0) { "; heap cap $heap GB" })"
      # /s + outer quotes: cmd strips exactly those, so a command that starts with a quoted path ("C:\Program Files\...\MSBuild.exe" "x.sln") survives
      if ($KitIsWindows) { $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/s', '/c', "`"$Cmd`"" -WorkingDirectory $Dir -NoNewWindow -PassThru }
      else {
        $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($Cmd)
        $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
      }
      Remove-Item $myTicket -ErrorAction SilentlyContinue
      @{ owner = $owner; kind = $kind; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Add-Content $startsFile
      $entry = Join-Path $ledger "$($proc.Id).json"
      @{ pid = $proc.Id; need = $need; kind = $kind; cmd = $Cmd; dir = $Dir; started = (Get-Date).ToString('s'); backfill = $smallFill } | ConvertTo-Json | Set-Content $entry
      break
    }
    $waits++
    $msg = "[gate] waiting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> would leave $([math]::Round($left,1)) GB (< $KeepFreeGB)"
    if ($waits % 15 -eq 1) { $msg += ". Biggest users: $(Top-Users $s.Snap)" }
    Write-Host $msg
    }
  } finally { $gate.ReleaseMutex() }
  Start-Sleep -Seconds 20
}
} finally { Remove-Item $myTicket -ErrorAction SilentlyContinue }
if (-not $proc) { Write-Host "[gate] could not start within $WaitMinutes min"; exit 3 }
# Wait, sampling the process tree's peak memory so the next estimate for this kind is realistic.
$sw = [Diagnostics.Stopwatch]::StartNew(); $peak = 0.0   # double: [math]::Max(int, double) would pick the int overload and truncate
try {
  $null = $proc.Handle   # keep a handle so ExitCode is available after exit
  while (-not $proc.HasExited) { $peak = [math]::Max($peak, (Get-TreeGB $proc.Id (Get-Procs))); Start-Sleep -Seconds 5 }
  $proc.WaitForExit(); $code = $proc.ExitCode
} finally { Remove-Item $entry -ErrorAction SilentlyContinue }
if ($peak -gt 0.2 -and $kind -ne 'emulator') {
  # read-modify-write under the gate mutex (parallel builds finish together); an unreadable file is left alone, never reset to {}
  $got = $false
  try {
    try { $got = $gate.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) {
      $txt = if (Test-Path $histFile) { Get-Content $histFile -Raw -ErrorAction Stop } else { '' }
      $h = if ("$txt".Trim()) { $txt | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { @{} }
      if ($h -is [hashtable]) {
        # at / code / cmd (first 60 chars) were added later: readers must not assume older samples carry them
        $h[$histKey] = @(@($h[$histKey] | Where-Object { $_ }) + @{ gb = [math]::Round($peak, 2); sec = [int]$sw.Elapsed.TotalSeconds; ok = ($code -eq 0); at = (Get-Date).ToString('o'); code = $code; cmd = $(if ($Cmd.Length -gt 60) { $Cmd.Substring(0, 60) } else { $Cmd }) } | Select-Object -Last 10)
        $h | ConvertTo-Json -Depth 3 | Set-Content "$histFile.tmp" -ErrorAction Stop
        Move-Item "$histFile.tmp" $histFile -Force -ErrorAction Stop
      }
    }
  } catch {} finally { if ($got) { $gate.ReleaseMutex() } }
}
exit $code
}

# ---------------------------------------------------------------- check: gated compile / typecheck / lint / test / migrations
# One command for "does my change build and pass?" in any repo. Detects the stack (dev.ps1 stack), fills in the
# command and runs it through the memory gate (dev.ps1 gate).
#
#   $D = '<workspace>/.claude/skills/dev-kit/dev.ps1'
#   & $D check -Dir <dir>                                   # quick: compile + typecheck + lint (whatever the stack has)
#   & $D check -Dir <dir> -Step test -Tests "FooTest,BarTest"
#   & $D check -Dir <dir> -Step test -Tests "src/a.spec.ts"
#   & $D check -Dir <dir> -Step lint -Files "src/a.ts src/b.ts"
# (-Tests / -Files: comma or space separated; each runner gets its own list form. Python script-style checks, .py files with no
# test cases, run one by one with the project's python instead of unittest/pytest, which would collect nothing and exit 5.)
#   & $D check -Dir <dir> -Step build                       # full build (heavy, use before shipping only)
#   & $D check -Dir <dir> -Step migrations                  # Liquibase sanity check, if the repo has master.xml
#   & $D check -Dir <dir> -Show                             # print what would run
#
# -Dir is the folder with the build file (pom.xml, package.json, *.sln, pyproject.toml, ...), or anything below it.
# Tests are targeted: -Step test needs -Tests unless you pass -AllTests (full suites are slow and eat RAM).
# A web project with no unit-test target runs its specs with spec.mjs (specs under node, DOM specs under the project's jsdom, no TestBed).
# Quick lint checks the files changed on the branch plus untracked ones. TypeScript typecheck output goes to
# <runtime>/logs/typecheck-<repo>-<time>.log; on TS5103 (an ignoreDeprecations value the installed TypeScript rejects) it retries
# once with a temp tsconfig and then prints only the errors in your changed files plus one BASELINE line, failing only on yours.
# A per-project marker (<runtime>/cache/tsbuild/ts5103.<hash>.flag, keyed on the ignoreDeprecations value and the TypeScript version)
# makes later runs skip the first tsc run that is bound to fail; a baseline-only fallback run is recorded as ok in the gate history.
# A node-spec test run uses the real @angular/core with -RealAngular (auto-on when a named spec imports @angular/forms). Container tests
# (*ContainerTest / *IT, or Testcontainers in the module) first need `docker info` to answer within 5 s, else exit 4 with a start hint.
# A fallback typecheck whose baseline exceeds 200 errors is reported UNRUN (linked node_modules do not match the branch), not ok.
# Exit code: 0 ok, non-zero = the first failing step's exit code (3 = the gate could not start it in time, 4 = Docker not running).
function Invoke-Check {
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$Since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),   # migrations: only report changelog files named with a timestamp >= this
  [switch]$Show,
  [switch]$Touched,     # -Step test: add every test of the files this branch changed (per stack; kit.local.json tests.<stack>.testFor)
  [switch]$RealAngular   # test with spec.mjs: real @angular/core instead of the stub (auto-on when a named spec imports @angular/forms)
)
$ErrorActionPreference = 'Stop'
$K = $PSScriptRoot
$st = & $KitCmd.dev stack -Dir $Dir -Json | ConvertFrom-Json
Write-Host "[check] $($st.stack) in $($st.dir)"

# Files changed on this branch (full paths, existing, under the stack dir): the diff against where the branch left its target
# plus untracked files git does not ignore. Base = the worktree's recorded target (dev.ps1 wt new), else the remote's default branch
# (origin/HEAD), else the upstream. (@{upstream} alone is the pushed branch itself, so after a push or commit quick lint used to
# see only uncommitted files.)
function Get-ChangedFiles {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $gd = (git -C $st.dir rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
  $tgt = if (Test-Path (Join-Path $gd 'claude-target')) { "origin/$((Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim())" }
  $refs = @($tgt, ((git -C $st.dir symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null) | Select-Object -First 1), '@{upstream}') | Where-Object { $_ }
  $base = $null; foreach ($r in $refs) { $base = (git -C $st.dir merge-base HEAD $r 2>$null); if ($LASTEXITCODE -eq 0 -and $base) { break }; $base = $null }
  $list = @(git -C $st.dir diff --name-only --diff-filter=ACMR $(if ($base) { $base } else { 'HEAD' }) -- . 2>$null) +
          @(git -C $st.dir ls-files --others --exclude-standard --full-name -- . 2>$null)
  @($list | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

# tsc typecheck through the gate with its output in <runtime>/logs. On TS5103 (or a cached TS5103 marker) retry once with a temp tsconfig (runtime cache, deleted
# after) that extends the project's and sets a valid ignoreDeprecations, using the repo's own node_modules/.bin/tsc; then print only
# the errors in changed files plus a BASELINE line for the rest, and fail only on changed files (and on config errors, TS5xxx/TS6xxx).
function Invoke-Typecheck([string]$TcCmd) {
  $top = git -C $st.dir rev-parse --show-toplevel 2>$null
  $top = if ($top) { [IO.Path]::GetFullPath("$top".Trim()) } else { $null }
  $repo = Split-Path $(if ($top) { $top } else { $st.dir }) -Leaf
  $log = Join-Path (Get-KitPath logs -Create) "typecheck-$repo-$(Get-Date -Format yyyyMMdd-HHmmss).log"
  $proj = if ($TcCmd -match '\s-p\s+"?([^"\s]+)"?') { $Matches[1] } else { 'tsconfig.json' }
  $base = [IO.Path]::GetFullPath((Join-Path $st.dir $proj))
  # the repo's own tsc: nearest node_modules/.bin going up to the git root (a worktree links node_modules from its main checkout)
  $bin = $null; $d = $st.dir
  while ($d) {
    $p = Join-Path $d "node_modules/.bin/$(if ($KitIsWindows) { 'tsc.cmd' } else { 'tsc' })"
    if (Test-Path -LiteralPath $p) { $bin = $p; break }
    if (-not $top -or $d -eq $top) { break }
    $parent = Split-Path $d; if (-not $parent -or $parent -eq $d) { break }; $d = $parent
  }
  $ver = '5.0'; $tsVer = ''
  if ($bin) { try { $tsVer = [string](Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $bin)) 'typescript/package.json') -Raw | ConvertFrom-Json).version; if ([int](($tsVer -split '\.')[0]) -ge 6) { $ver = '6.0' } } catch {} }
  $raw = try { Get-Content -LiteralPath $base -Raw } catch { '' }
  # TS5103 is decided by the project's ignoreDeprecations value and the installed TypeScript: once hit, a marker keyed on both skips
  # the first tsc run (bound to fail, ~10-15 s and ~1 GB each time); a changed value or TypeScript version gives a new key
  $igd = if ($raw -match '"ignoreDeprecations"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
  $md5 = { param($s) [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '').Substring(0, 12) }
  $flag = Join-Path (Get-KitPath tsbuild -Create) "ts5103.$(& $md5 "$($base.ToLower())|$igd|$tsVer").flag"
  if (Test-Path -LiteralPath $flag) {
    $out = @()
    Write-Host "[check] TS5103 known for this project (marker $(Split-Path $flag -Leaf)): skipping the first tsc run"
  } else {
    & $KitCmd.dev gate -Dir $st.dir -Cmd "$TcCmd > `"$log`" 2>&1"
    $rc = $LASTEXITCODE
    $out = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $nErr = @($out -match '^(.+?\(\d+,\d+\): )?error TS\d+').Count
    if (-not @($out -match 'error TS5103').Count) {
      # hundreds of errors on a plain run: split them like the fallback below (yours fail; a huge baseline is UNRUN)
      if ($rc -and $nErr -gt $script:TypecheckUnrunAbove) { return (Split-TypecheckErrors $out $rc $null $null) }
      $out | ForEach-Object { Write-Host $_ }
      if ($rc -and $out.Count) { Write-Host "[check] typecheck log: $log" }
      return $rc
    }
    Set-Content -LiteralPath $flag -Value "$base | ignoreDeprecations '$igd' | typescript $tsVer"
  }
  $tsCfg = [ordered]@{ extends = $base.Replace('\', '/'); compilerOptions = @{ ignoreDeprecations = $ver } }
  # without files/include in the project's config, tsc's default include is the folder of the -p config (the temp one): pin it
  if ($raw -notmatch '"(files|include)"\s*:') {
    $pd = (Split-Path $base).Replace('\', '/')
    $ex = @('node_modules', 'bower_components', 'jspm_packages')
    try { $j = $raw | ConvertFrom-Json; if ($j.exclude) { $ex = @($j.exclude) } } catch {}
    $tsCfg.include = @("$pd/**/*")
    $tsCfg.exclude = @($ex | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { "$pd/$_" } })
  }
  $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($st.dir.ToLower()))).Replace('-', '').Substring(0, 12)
  $tmp = Join-Path (Get-KitPath cache -Create) "tsconfig.ts5103.$hash.$PID.json"
  $tsb = Join-Path (Get-KitPath tsbuild -Create) "$hash.ts5103.tsbuildinfo"
  $tsc = if ($bin) { "`"$bin`"" } else { 'npx tsc' }
  Write-Host "[check] typecheck TS5103 (ignoreDeprecations) fallback: running with a temp tsconfig (ignoreDeprecations $ver) and $(if ($bin) { $bin } else { 'npx tsc' })"
  $fbCmd = "$tsc -p `"$tmp`" --noEmit --pretty false --incremental --tsBuildInfoFile `"$tsb`" >> `"$log`" 2>&1"
  $fbStart = [DateTimeOffset]::Now
  try {
    $tsCfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    & $KitCmd.dev gate -Dir $st.dir -Cmd $fbCmd
    $rc = $LASTEXITCODE
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  $out2 = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Skip $out.Count })
  if ($rc -eq 3 -and -not $out2.Count) { return 3 }   # the gate could not start it
  if (@($out2 -match 'error TS5103').Count) { Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue }   # the fallback is no cure here: next run starts over
  return (Split-TypecheckErrors $out2 $rc $fbCmd $fbStart)
}

# Errors in changed files (and config errors) fail the check; the rest is the BASELINE. A baseline above $TypecheckUnrunAbove means
# the node_modules do not match the branch: UNRUN. $GateCmd/$Since mark the gate sample ok when only baseline errors remain.
function Split-TypecheckErrors($out2, [int]$rc, [string]$GateCmd, $Since) {
  $changed = @(Get-ChangedFiles | ForEach-Object { $_.ToLower() })
  $mine = [Collections.Generic.List[string]]::new(); $mineN = 0; $baseN = 0; $baseFiles = @{}; $cur = $null; $blocks = 0
  foreach ($l in $out2) {
    if ($l -match '^(?<f>.+?)\(\d+,\d+\): error TS(?<code>\d+)' -or $l -match '^error TS(?<code>\d+)') {
      $blocks++
      $f = $Matches.f; $isCfg = (-not $f) -or $Matches.code -match '^[56]\d{3}$' -or $Matches.code -eq '18003'   # config/option errors always count
      $full = if ($f) { [IO.Path]::GetFullPath((Join-Path $st.dir $f)).ToLower() } else { $null }
      if ($isCfg -or $changed -contains $full) { $cur = 'mine'; $mineN++ } else { $cur = 'base'; $baseN++; $baseFiles[$full] = 1 }
    }
    elseif (-not ($cur -and $l -match '^\s')) { $cur = $null }
    if ($cur -eq 'mine') { $mine.Add($l) }
  }
  $mine | ForEach-Object { Write-Host $_ }
  Write-Host "BASELINE: $baseN errors outside your changes (in $($baseFiles.Count) files; not failing this check; full log: $log)"
  if ($mineN) { Write-Host "[check] typecheck: $mineN errors in your changed files (or in the config)"; return 1 }
  if ($rc -and -not $blocks) { $out2 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }; return $rc }   # tsc failed without diagnostics
  # A huge baseline means the linked node_modules do not match this branch (missing or wrong-version packages): every file errors,
  # so an error your change causes in an unchanged file hides in it. That run checked nothing: UNRUN, not a pass (no gate ok either).
  if ($baseN -gt $script:TypecheckUnrunAbove) {
    $gd = (git -C $st.dir rev-parse --git-dir 2>$null); if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
    $tgt = if ($gd -and (Test-Path (Join-Path $gd 'claude-target'))) { (Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim() } else { '<target>' }
    Write-Host "[check] typecheck UNRUN: $baseN baseline errors (> $script:TypecheckUnrunAbove) - the linked node_modules do not match this branch, so real errors hide in the baseline. Say 'typecheck unrun' in the MR; the lead can set kit.local.json linkFromByTarget.$tgt to a checkout whose node_modules match $tgt (dev-kit reference/configuration.md)."
    return 'unrun'
  }
  if ($rc -and $GateCmd) { Set-GateSampleOk $GateCmd $Since }   # baseline errors only: this check passed, so its gate sample is a pass too
  return 0
}
$script:TypecheckUnrunAbove = 200

# dev.ps1 gate records ok = (exit code 0) per run in its history.json; a fallback typecheck that failed only on baseline errors passed
# this check, so its sample (newest one of this command since the run started) is turned into ok (marked baseline), under the
# gate's own mutex. Best effort: nothing changes when the sample or the file is missing or unreadable.
function Set-GateSampleOk([string]$GateCmd, [DateTimeOffset]$Since) {
  $hf = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'history.json'
  if (-not (Test-Path -LiteralPath $hf)) { return }
  $pre = if ($GateCmd.Length -gt 60) { $GateCmd.Substring(0, 60) } else { $GateCmd }
  $fromUtc = $Since.UtcDateTime.AddSeconds(-2)
  $mx = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate'); $got = $false
  try {
    try { $got = $mx.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { return }
    $h = Get-Content -LiteralPath $hf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($h -isnot [hashtable]) { return }
    $best = $null; $bestAt = [datetime]::MinValue
    foreach ($k in @($h.Keys)) { foreach ($s in @($h[$k])) {
      if (-not $s -or $s.ok -or -not $s.at -or -not ([string]$s.cmd).StartsWith($pre)) { continue }
      $at = ([datetime]$s.at).ToUniversalTime()
      if ($at -ge $fromUtc -and $at -gt $bestAt) { $best = $s; $bestAt = $at } } }
    if (-not $best) { return }
    $best.ok = $true; $best.baseline = $true
    $h | ConvertTo-Json -Depth 3 | Set-Content "$hf.tmp" -ErrorAction Stop
    Move-Item "$hf.tmp" $hf -Force -ErrorAction Stop
  } catch {} finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
}

# Container tests (Testcontainers) need a running Docker: without it each one burns minutes in Maven/Gradle and then fails looking
# like a code bug. Judged before the gate: a test named *ContainerTest / *IT, or a named test class (or -AllTests) in a module whose
# build file references testcontainers and whose source uses it. `docker info` gets 5 s; on failure exit 4 with a start hint.
function Test-DockerForContainerTests {
  $names = @($Tests -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { (($_ -split '#')[0] -split '\.')[-1] })
  $need = @($names | Where-Object { $_ -match '(Container|IT)(Test)?$' }).Count -gt 0
  if (-not $need) {
    $bf = @('pom.xml', 'build.gradle', 'build.gradle.kts') | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bf -and (Get-Content -LiteralPath $bf -Raw) -match 'testcontainers') {
      if ($AllTests -and -not $names.Count) { $need = $true }
      else {
        $roots = @('src/test', 'src/integrationTest') | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($n in $names) {
          $src = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Include "$n.java", "$n.kt" -ErrorAction SilentlyContinue } | Select-Object -First 1)
          if ($src.Count -and (Get-Content -LiteralPath $src[0].FullName -Raw) -match '@Testcontainers|@Container\b|import\s+org\.testcontainers|extends\s+\w*Container\w*Test\b') { $need = $true; break }
        }
      }
    }
  }
  if (-not $need) { return 0 }
  $docker = Get-Command docker -ErrorAction SilentlyContinue | Select-Object -First 1
  $ok = $false; $why = 'docker is not on PATH'
  if ($docker) {
    try {
      $psi = [Diagnostics.ProcessStartInfo]::new($docker.Source, 'info --format "{{.ServerVersion}}"')
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
      $p = [Diagnostics.Process]::Start($psi)
      $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
      if (-not $p.WaitForExit(5000)) { try { $p.Kill($true) } catch {}; $why = 'docker info did not answer within 5 s' }
      elseif ($p.ExitCode -eq 0 -and "$($outTask.Result)".Trim()) { $ok = $true }
      else { $why = "docker info failed: $((("$($errTask.Result)" -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1))" }
    } catch { $why = "docker info could not run: $($_.Exception.Message)" }
  }
  if ($ok) { Write-Host '[check] container tests: Docker is running'; return 0 }
  Write-Host "[check] container tests need Docker, and it is not available ($why)."
  Write-Host "[check] Start it (Windows/macOS: Docker Desktop; Linux: the docker service), poll 'docker info' until it answers, then re-run. A container test that fails because Docker was down is not a code failure."
  return 4
}

if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  # Liquibase master changelogs: *master.xml under a liquibase/ or changelog/ folder (JHipster config/liquibase/master.xml,
  # Spring Boot db/changelog/db.changelog-master.xml). A YAML/JSON/SQL master is not checked (said so, not silently passed).
  $all = @(git -C $top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' })
  $masters = @($all | Where-Object { $_ -match '\.xml$' })
  foreach ($o in @($all | Where-Object { $_ -notmatch '\.xml$' })) { Write-Host "[check] $o is not an XML changelog - lbcheck reads XML only, not checked" }
  if (-not $masters) { Write-Host '[check] no Liquibase XML master changelog in this repo - nothing to check'; exit 0 }
  # changelog files without a yyyyMMddHHmmss name prefix are judged by git instead: the ones changed in the last 14 days (or
  # since -Since) are reported too (devtools.py lbcheck reads LBCHECK_CHANGED, basenames separated by '|')
  $sinceDate = try { [datetime]::ParseExact($Since.Substring(0, 8), 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { (Get-Date).AddDays(-14).ToString('yyyy-MM-dd') }
  $env:LBCHECK_CHANGED = (@(git -C $top log --since=$sinceDate --name-only --pretty=format: -- '*.xml') + @(git -C $top diff --name-only HEAD -- '*.xml') | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique) -join '|'
  $rc = 0
  $mine = @($masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) })
  $under = @($mine | Where-Object { $_.StartsWith($st.dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
  if ($under.Count) { $mine = $under }   # module has its own changelog: check only that one
  foreach ($full in $mine) {
    $a = @($KitCmd.devtools, 'lbcheck', $full, $Since)
    $py = Get-Python
    if ($Show) { "$py $($a -join ' ')"; continue }
    Write-Host "[check] liquibase: $full (files since $Since)"
    & $py @a; if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
  }
  exit $rc
}

$steps = if ($Step -eq 'quick') { 'compile', 'typecheck', 'lint' } else { @($Step) }
$ran = 0
foreach ($s in $steps) {
  $cmd = $st.commands.$s
  # a web project without a unit-test target (e.g. a stack override that sets none): spec.mjs runs the specs under node
  if (-not $cmd -and $s -eq 'test' -and (Test-Path -LiteralPath (Join-Path $st.dir 'package.json'))) { $cmd = "node `"$($KitCmd.spec)`" {tests}" }
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs') { Write-Host '[check] no unit-test target: running spec.mjs (specs under node; DOM specs under the project''s jsdom if it has one; TestBed/fakeAsync specs are reported NOT RUN)' }
  if ($Touched -and $s -eq 'test') {
    # every test of the touched classes / modules: CI may skip tests, the dev loop is the guard (kit.local.json tests.<stack>.testFor overrides)
    $chg = @(Get-ChangedFiles)
    $lay = Get-KitSetting "tests.$($st.stack)" $null
    $pat = if ($lay -and $lay.testFor) { @($lay.testFor) } else { switch -Regex ($st.stack) { 'maven|gradle|android|kotlin|java' { '{name}Test', '{name}Tests', '{name}IT' } 'dotnet|msbuild' { '{name}Tests', '{name}Test' } 'python' { 'test_{name}', '{name}_test' } 'go' { '{name}_test' } default { '{name}.spec', '{name}.test' } } }
    $tracked = @(git -C $st.dir ls-files 2>$null)
    $found = foreach ($cf in $chg) {
      $n = [IO.Path]::GetFileNameWithoutExtension($cf) -replace '\.(spec|test)$', ''
      if ($cf -match '\.(spec|test)\.\w+$' -or $n -match '(Test|Tests|IT|_test)$' -or $n -match '^test_') { $cf; continue }   # a changed test runs itself
      foreach ($p in $pat) { $w = $p.Replace('{name}', $n); @($tracked | Where-Object { $b = [IO.Path]::GetFileName($_); $b -like "$w.*" }) | ForEach-Object { Join-Path $st.dir $_ } }
    }
    $byName = $st.stack -match 'maven|gradle|android|kotlin|java|dotnet|msbuild'
    $sel = @($found | Where-Object { $_ } | ForEach-Object { if ($byName) { [IO.Path]::GetFileNameWithoutExtension($_) } else { [IO.Path]::GetRelativePath($st.dir, $_) -replace '\\', '/' } } | Select-Object -Unique)
    Write-Host "[check] -Touched: $($sel.Count) test(s) for $($chg.Count) changed file(s)$(if ($sel.Count) { ': ' + ($sel -join ', ') })"
    if ($sel.Count) { $Tests = (@(@($Tests -split '[,\s]+' | Where-Object { $_ }) + $sel) | Select-Object -Unique) -join ',' }
    elseif (-not $Tests) { Write-Host '[check] -Touched: no test file matches the changed files - add tests (dev-kit Rules > Tests) or pass -Tests'; exit 1 }
  }
  if ($cmd -match '\{tests\}') {
    if (-not $Tests -and -not $AllTests) { throw "-Step test needs -Tests '<names or paths>' (or -AllTests for the whole suite)" }
    # -Tests "a,b" or "a b": each runner gets its own list form (commas used to reach eslint/jest/pytest as one name, spaces broke -Dtest)
    $tl = @($Tests -split '[,\s]+' | Where-Object { $_ })
    $pyRun = if ($st.stack -eq 'python' -and $cmd -match '^(?<py>.+?)\s+-m\s+(pytest|unittest)\b') { $Matches.py } else { $null }
    # script-style checks (validation/*.py run at import, no test cases): unittest/pytest collect nothing and exit 5 - run each file instead
    $scripts = if ($pyRun -and $tl.Count) { @($tl | Where-Object { $_ -match '\.py$' -and (Test-Path -LiteralPath (Join-Path $st.dir $_) -PathType Leaf) -and -not (Select-String -LiteralPath (Join-Path $st.dir $_) -Pattern '^\s*(def test_|class \w+\(.*TestCase\)|import (unittest|pytest)|from (unittest|pytest)\b)' -Quiet) }) } else { @() }
    if ($scripts.Count -and $scripts.Count -eq $tl.Count) {
      $cmd = ($scripts | ForEach-Object { "$pyRun `"$_`"" }) -join ' && '
      Write-Host "[check] $($scripts.Count) script-style check file(s) without test cases: running each with python (exit code = the script's)"
    } else {
      $joined = if ($cmd -match '-Dtest=\{tests\}') { $tl -join ',' } elseif ($cmd -match '--tests \{tests\}') { $tl -join ' --tests ' } elseif ($cmd -match '--include \{tests\}') { $tl -join ' --include ' } elseif ($cmd -match '(-run|-R) "\{tests\}"') { $tl -join '|' } else { $tl -join ' ' }
      $cmd = $cmd.Replace('{tests}', $joined)
    }
    if ($AllTests -and -not $Tests) { $cmd = $cmd -replace ' --tests\s*(?=\s|$)', '' -replace ' -Dtest=\s', ' ' -replace ' --include\s*(?=\s|$)', '' -replace ' -run ""', '' -replace ' --filter ""', '' }
  }
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs' -and $cmd -notmatch '--real-angular') {
    # the @angular/core stub breaks @angular/forms (FormControl & co. need real core exports): such specs run on the real core
    $why = if ($RealAngular) { '-RealAngular' } else {
      $hit = @(@($Tests -split '[,\s]+' | Where-Object { $_ }) | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { $_ -match '\.(spec|test)\.\w+$' -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
               Where-Object { (Get-Content -LiteralPath $_ -Raw) -match '[''"]@angular/forms[''"]' } | Select-Object -First 1)
      if ($hit.Count) { "$(Split-Path $hit[0] -Leaf) imports @angular/forms" }
    }
    if ($why) { $cmd += ' --real-angular'; Write-Host "[check] node-spec with the real @angular/core ($why)" }
  }
  if ($s -eq 'test' -and $st.stack -match 'maven|gradle|java|kotlin') {   # -Show reports the Docker check without stopping
    $rc = Test-DockerForContainerTests
    if ($rc -and -not $Show) { exit $rc }
  }
  if ($cmd -match '\{sln\}') {
    # .NET: the solution in the stack dir, else the single project there (a test project folder has only its .csproj)
    $sln = @(Get-ChildItem -LiteralPath $st.dir -Filter *.sln -File -ErrorAction SilentlyContinue)
    if (-not $sln.Count) { $sln = @(Get-ChildItem -LiteralPath $st.dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' }) }
    if ($sln.Count -ne 1) { throw "[check] $($st.dir): expected one .sln (or one project file), found $($sln.Count) - pass -Dir to the folder that has it" }
    $cmd = $cmd.Replace('{sln}', $sln[0].FullName)
  }
  if ($cmd -match '\{files\}') {
    if (-not $Files -and $Step -eq 'quick' -and ($s -eq 'lint' -or ($s -eq 'compile' -and $st.stack -eq 'python'))) {
      # quick lint (and Python's compileall) = files changed on the branch + untracked ones, so it stays fast
      # only files the stack's linter reads (ruff/flake8 get .py, eslint gets JS/TS)
      $ext = if ($st.stack -eq 'python') { '\.(py|pyi)$' } else { '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$' }
      # paths relative to the stack dir (the gate runs there): absolute paths made a 200-file merge overflow cmd.exe's 8191 chars
      Push-Location $st.dir
      $changed = @(Get-ChangedFiles | Where-Object { $_ -match $ext } | ForEach-Object { Resolve-Path -Relative $_ })
      Pop-Location
      if (-not $changed.Count) { Write-Host "[check] ${s}: no changed files"; continue }
      $Files = ($changed | ForEach-Object { '"' + $_ + '"' }) -join ' '
    }
  }
  # still too long for one command line (cmd.exe stops at 8191 chars): run the step in batches of files
  $batches = @($cmd)
  if ($cmd -match '\{files\}') {
    $batches = @()
    $list = if ($Files) { @([regex]::Matches($Files, '"[^"]*"|[^\s,]+') | ForEach-Object Value) } else { @('.') }   # space or comma separated
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
  if ($st.solution) { $cmd = $cmd -replace '\{sln\}', $st.solution }
  # Speed-ups that don't change results:
  if ($cmd -match '^(\.[\\/]mvnw(\.cmd)?|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $cmd = $cmd -replace '^(\.[\\/]mvnw(\.cmd)?|mvn)\s', 'mvnd ' }   # warm Maven daemon
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {                                                                  # incremental type-check
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($st.dir.ToLower()))).Replace('-', '').Substring(0, 12)
    $tsb = Get-KitPath tsbuild -Create
    $cmd += " --incremental --tsBuildInfoFile `"$(Join-Path $tsb "$hash.tsbuildinfo")`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }                                                       # Gradle build cache
  if ($Show) { "$s : $cmd"; continue }
  $unrun = $false
  if ($s -eq 'typecheck' -and $cmd -match '\btsc\b') { $r = @(Invoke-Typecheck $cmd)[-1]; if ($r -eq 'unrun') { $unrun = $true; $rc = 0 } else { $rc = [int]$r } }
  else { & $KitCmd.dev gate -Dir $st.dir -Cmd $cmd; $rc = $LASTEXITCODE }
  $ran++
  if ($rc) { Write-Host "[check] $s FAILED (exit $rc)"; exit $rc }
  }
  if (-not $Show) { Write-Host "[check] $s $(if ($unrun) { 'UNRUN (not a pass: see above)' } else { 'ok' })" }
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
exit 0
}

# ---------------------------------------------------------------- pipes: wait for MR pipelines, JSON out
# Waits for merge-request pipelines and reports them as JSON (one line), so a cheap agent (or a script) can route CI failures back to
# the dev agent instead of scheduling a merge that will never happen.
#
#   & <workspace>/.claude/skills/dev-kit/dev.ps1 pipes -Mrs https://gitlab.example.com/group/api/-/merge_requests/12,https://... [-MaxMinutes 8]
#
# Output: {"done":true|false,"mrs":[{"mr":url,"status":"success|failed|running|...","job":"<failed job>","error":"<last error lines>"}]}
# done=false = some pipelines still running after -MaxMinutes (call again). Exit codes: 0 always (read the JSON; done=false = still running).
# GitLab MRs (.../-/merge_requests/<n>) through glab; GitHub pull requests (.../pull/<n>) through gh (status = the PR's checks).
function Invoke-Pipes {
param([Parameter(Mandatory)][string[]]$Mrs, [int]$MaxMinutes = 8)
$ErrorActionPreference = 'SilentlyContinue'
$list = @($Mrs -split '\s*,\s*' | Where-Object { $_ })
# GitHub: the PR's check runs / commit statuses folded into the GitLab-style statuses the callers read
function GhState($url) {
  $pr = gh pr view $url --json state,statusCheckRollup 2>$null | ConvertFrom-Json
  if (-not $pr) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($pr.state -eq 'MERGED') { return [ordered]@{ mr = $url; status = 'merged' } }
  $checks = @($pr.statusCheckRollup)
  if (-not $checks.Count) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }
  $res = @($checks | ForEach-Object { if ($_.conclusion) { $_.conclusion } elseif ($_.state) { $_.state } else { $_.status } } | ForEach-Object { "$_".ToUpper() })
  $bad = @($checks | Where-Object { "$($_.conclusion)$($_.state)".ToUpper() -match 'FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE' })
  $o = [ordered]@{ mr = $url; status = $(if ($bad.Count) { 'failed' } elseif ($res | Where-Object { $_ -match 'PENDING|QUEUED|IN_PROGRESS|EXPECTED|WAITING|REQUESTED' }) { 'running' } else { 'success' }) }
  if ($bad.Count) {
    $o.job = $(if ($bad[0].name) { $bad[0].name } else { $bad[0].context })
    $link = if ($bad[0].detailsUrl) { $bad[0].detailsUrl } else { $bad[0].targetUrl }
    if ($link -match '/runs/(\d+)') { $o.error = ((gh run view $Matches[1] --repo ($url -replace '^https?://[^/]+/([^/]+/[^/]+)/pull/.*$', '$1') --log-failed 2>$null) -split "`n" | Where-Object { $_ -match '(?i)error|fail|exception' } | Select-Object -Last 8) -join "`n" }
    if (-not $o.error) { $o.error = "see $link" }
  }
  $o
}
function State($url) {
  if ($url -match '^https?://[^/]+/[^/]+/[^/]+/pull/\d+') { return GhState $url }
  if ($url -notmatch '^https?://(?<h>[^/]+)/(?<p>.+?)/-/merge_requests/(?<i>\d+)') { return [ordered]@{ mr = $url; status = 'bad-url' } }
  $proj = $Matches.p -replace '/', '%2F'; $iid = $Matches.i
  $env:GITLAB_HOST = $Matches.h; $script:HostType = 'gitlab'   # glab would otherwise ask gitlab.com (self-hosted servers: the MR's own host)
  $m = Invoke-HostApi "projects/$proj/merge_requests/$iid"
  if (-not $m) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($m.state -eq 'merged') { return [ordered]@{ mr = $url; status = 'merged' } }
  $p = $m.head_pipeline
  if (-not $p) { return [ordered]@{ mr = $url; status = 'no-pipeline' } }
  $o = [ordered]@{ mr = $url; status = $p.status }
  if ($p.status -eq 'failed') {
    $job = @(Invoke-HostApi "projects/$proj/pipelines/$($p.id)/jobs" | Where-Object status -eq 'failed')[0]
    if ($job) {
      $o.job = $job.name
      $trace = ([string](Invoke-HostApi "projects/$proj/jobs/$($job.id)/trace")) -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' -replace '^\S+Z \d+O ', '' }
      $o.error = (@($trace | Where-Object { $_ -match '(?i)error|fail|invalid|exception|\[ERROR\]' } | Select-Object -Last 8) -join "`n")
    }
  }
  $o
}
$start = Get-Date; $end = $start.AddMinutes($MaxMinutes)
do {
  $states = @($list | ForEach-Object { State $_ })
  # right after a push the pipeline does not exist yet: 'no-pipeline' counts as busy for 3 min (after that: a repo without MR CI)
  $busy = @($states | Where-Object { $_.status -in 'created', 'pending', 'running', 'waiting_for_resource', 'preparing', 'scheduled' -or ($_.status -eq 'no-pipeline' -and ((Get-Date) - $start).TotalMinutes -lt 3) })
  if (-not $busy -or (Get-Date) -gt $end) { break }
  Start-Sleep 30
} while ($true)
[ordered]@{ done = (-not $busy); mrs = $states } | ConvertTo-Json -Depth 4 -Compress
}

# ---------------------------------------------------------------- guard: PreToolUse hook (blocks stash, --no-verify, force-push, ungated builds, ...)
# PreToolUse guard (Bash + PowerShell tools) for every session in this workspace (wired in .claude/settings.json).
# Turns the kit's hard rules into enforcement instead of advice:
#   - no `git stash` (the stash is shared across worktrees)
#   - no `--no-verify` / hook skipping
#   - no force-push to a protected branch (main, master, develop, release/*, plus kit.local.json "protectedBranches")
#   - no `adb kill-server` (it drops every agent's emulator lane)
#   - no `& <file>.md` / `Invoke-Item` on a document (it opens the owner's desktop app instead of reading the file)
#   - heavy builds/tests go through the memory gate (dev.ps1 check / dev.ps1 gate), not straight to mvn/gradle/dotnet/ng/jest/...
# Reads the hook JSON on stdin; prints a deny decision with the reason, or nothing (= allow).
#   - no deleting the runtime's work/ folder while runs are active (cache/ and logs/ may go), nor the durable *.local state
# Every block is logged to Get-KitPath guard-log (<runtime>/logs/guard.log) so /kit-retro can learn from repeated mistakes.
# Tests: pwsh -NoProfile -File dev.ps1 guard -SelfTest   (runs the cases at the end of this file through the real hook path; exit 1 on a failure)
function Invoke-Guard {
param([switch]$SelfTest)   # the hook passes no arguments
$ErrorActionPreference = 'SilentlyContinue'
if ($SelfTest) {
  # [tool, command, expect deny?] - each case is piped to this script as a hook call without session_id (nothing is logged)
  $cases = @(
    @('PowerShell', 'git stash', $true),
    @('PowerShell', 'git -C x stash pop', $true),
    @('PowerShell', '& "C:\Program Files\Git\bin\git.exe" stash list', $true),
    @('PowerShell', '$s = $(git stash list); $s', $true),
    @('PowerShell', 'pwsh -NoProfile -Command "git stash"', $true),
    @('Bash', 'git stash', $true),
    @('Bash', 'cd repo && git -C x stash pop', $true),
    @('Bash', 'FOO=1 git --no-pager stash show', $true),
    @('Bash', "bash -c 'git stash'", $true),
    @('PowerShell', 'git commit -m "fix: never git stash here"', $false),
    @('PowerShell', 'git commit -m "say `"git stash`" never"', $false),
    @('PowerShell', "`$m = @'`nnever run git stash`n'@`ngit commit -m `$m", $false),
    @('PowerShell', "Write-Output 'git stash is blocked'", $false),
    @('Bash', "git commit -m `"`$(cat <<'EOF'`nfix: never git stash in worktrees`nEOF`n)`"", $false),
    @('Bash', "cat > note.md <<EOF`ngit stash is shared`nEOF", $false),
    @('Bash', 'git checkout fix/stash-list', $false),
    @('Bash', 'echo done # not git stash', $false),
    # [tool, command, expect deny?, deny message] - opening a document with & / . / Invoke-Item instead of reading it
    @('PowerShell', '& D:\kit\skills\dev-kit\LESSONS.md', $true, 'default desktop app'),
    @('PowerShell', '& "C:\x y\notes.txt"', $true, 'default desktop app'),
    @('PowerShell', 'Invoke-Item .\report.html', $true, 'default desktop app'),
@('PowerShell', 'Start-Process .\out\kit-flow.html', $true, 'default desktop app'),
@('PowerShell', 'Start-Process https://example.com', $true, 'default desktop app'),
@('Bash', 'xdg-open out/report.html', $true, 'default desktop app'),
@('Bash', 'cmd /c start "" report.pdf', $true, 'default desktop app'),
@('PowerShell', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden', $false, ''),
    @('PowerShell', 'cd x; ii "out.pdf"', $true, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Text "resumed agent; . templates.md "Resume brief" was read (see notes.md); & LESSONS.md"', $false, 'default desktop app'),
    @('PowerShell', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, 'default desktop app'),
    @('PowerShell', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text "X2 (a b): fixed via helper buildX plus unit test; MR merged on first run, no retries" -Ref B-1 -Source workflow', $false, 'default desktop app'),
    @('PowerShell', "& D:/kit/learn.ps1 -Skill dev-kit -Kind friction -Text `"Stopped agent left a commit; merge reported via devtools.py 'merged' but not verified`" -Ref repo!1 -Source workflow`n& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"recovery worked`" -Ref repo!1", $false, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, 'default desktop app'),
    @('PowerShell', "& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/dev-kit/LESSONS.md | Out-Null", $true, 'default desktop app'),
    # [.., 'holds runs in progress'] - deleting the runtime's work/ ({RT} = the runtime folder name; judged as if runs were active)
    @('Bash', "cd /d/x/{RT}/work/qa-runs; mkdir -p 2026-01-01-run && cd 2026-01-01-run; GWS=`$(python -c `"import shutil;print(shutil.which('gws'))`"); for p in A:1 B:2; do c=`${p%%:*}; `"`$GWS`" drive files export -o `$c.txt >/dev/null 2>&1; done", $false, 'holds runs in progress'),
    @('Bash', "cd D:/x/{RT} && mkdir -p work/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/g5/body.md; cat >> work/g5/body.md <<'EOF'`n## Review follow-up`n- Plain check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/g5/body.md)`"", $false, 'holds runs in progress'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Text "never rm the {RT}/work folder" -Source workflow', $false, 'holds runs in progress'),
    @('Bash', 'rm -rf /d/x/{RT}/work', $true, 'holds runs in progress'),
    @('PowerShell', 'Remove-Item -Recurse -Force "D:\x y\{RT}\work"', $true, 'holds runs in progress'),
    @('Bash', "python -c `"import shutil; shutil.rmtree('/d/x/{RT}/work')`"", $true, 'holds runs in progress'),
    @('Bash', 'cd /d/x/{RT} && rm -rf work', $true, 'holds runs in progress'),
    @('PowerShell', 'Remove-Item D:\x\.claude\tracking.local.json', $true, 'durable local kit state'),
    # stash inside a heredoc fed to a non-shell interpreter is data; a real git stash after it is not
    @('Bash', "cd repo; python3 - <<'E'`np='a.ts'`ns=open(p).read()  # never git stash here`nE`nnode x.mjs", $false),
    @('Bash', "cd repo; python3 - <<'E'`np='a.ts'`nE`ngit stash list >/dev/null; cp a.ts /tmp/a.bak", $true),
    # [.., 'local env'] - local env branches are never pushed; dev servers start only through localenv.ps1 (when localEnv is configured)
    @('PowerShell', 'git -C x push origin localenv/shop', $true, 'local env'),
    @('Bash', 'git push -u origin HEAD:localenv/shop', $true, 'local env'),
    @('PowerShell', 'git push -u origin f/CU-1-x', $false, 'local env'),
    @('PowerShell', 'cd api; .\mvnw.cmd spring-boot:run', $true, 'local env'),
    @('Bash', 'npx ng serve --port 4200', $true, 'local env'),
    @('Bash', 'yarn start', $true, 'local env'),
    @('PowerShell', 'dotnet watch run', $true, 'local env'),
    @('PowerShell', '& D:/kit/skills/local-env/localenv.ps1 up -Env shop', $false, 'local env'),
    @('PowerShell', 'git commit -m "fix: ng serve proxy"', $false, 'local env'),
    @('Bash', 'rg "ng serve" src', $false, 'local env'),
    @('Bash', 'git log -S bootRun --oneline', $false, 'local env'),
    @('Bash', 'npm run dev:build', $false, 'local env'),
    @('PowerShell', 'dotnet run -- migrate', $false, 'local env'),
    @('Bash', 'cd web && yarn start', $true, 'local env'),
    @('Bash', 'git push origin --delete localenv/shop', $false, 'local env'),
    # [.., 'Hooks must run'] - skipping commit hooks: --no-verify, its short form -n, an emptied hooksPath
    @('Bash', 'git commit -n -m "x"', $true, 'Hooks must run'),
    @('PowerShell', 'git -C x commit -nm "x"', $true, 'Hooks must run'),
    @('Bash', 'git -c core.hooksPath=/dev/null commit -m x', $true, 'Hooks must run'),
    @('Bash', 'git commit --no-edit --amend', $false, 'Hooks must run'),
    @('PowerShell', 'git commit -m "use -n for a dry run"', $false, 'Hooks must run'),
    @('Bash', 'git log -n 3; git commit -m x', $false, 'Hooks must run')
  )
  $env:KIT_GUARD_SELFTEST_ACTIVE = '1'   # inherited by the hook runs below (also: judge as if localEnv were configured)
  $fail = 0
  foreach ($c in $cases) {
    $json = @{ tool_name = $c[0]; tool_input = @{ command = $c[1].Replace('{RT}', '.runtime') } } | ConvertTo-Json -Compress -Depth 4
    $out = ($json | pwsh -NoProfile -NonInteractive -File $PSCommandPath guard) -join ''
    $denied = $out -match '"permissionDecision":"deny"' -and $out -match $(if ($c.Count -gt 3) { [regex]::Escape($c[3]) } else { 'git stash is shared' })
    $ok = $denied -eq $c[2]
    if (-not $ok) { $fail++ }
    '{0} {1,-10} {2,-6} {3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c[0], $(if ($c[2]) { 'deny' } else { 'allow' }), ($c[1] -replace "`n", ' \n ')
  }
  "$($cases.Count - $fail)/$($cases.Count) passed"
  exit [int]($fail -gt 0)
}
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$cmd = [string]$in.tool_input.command
if (-not $cmd) { exit 0 }
$K = $PSScriptRoot   # this kit's dev-kit folder (messages point agents at the right scripts)
# extra shared branches from kit.local.json (optional); kept cheap: this runs before every shell command
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path $K 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  if ($in.session_id) {   # only real hook calls are logged: test runs (no session) must not raise supervise's guard WATCH
    $one = $raw -replace "[\r\n\t]+", " // "
    # head + tail: the line that tripped a long multi-line command is often near its end (1000-char heads hid it)
    if ($one.Length -gt 2000) { $one = $one.Substring(0, 1000) + ' /*...*/ ' + $one.Substring($one.Length - 1000) }
    "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$one" | Add-Content (Get-KitPath guard-log -Create)
  }
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  exit 0
}

# Judge the command words only: text inside quotes (grep patterns, commit messages, orch.ps1 learn -Text "...") is not a command.
$raw = $cmd
# Heredoc bodies (<<EOF ... EOF) and PowerShell here-strings (@' ... '@) are data too (a script or brief that merely mentions a
# forbidden command), unless the heredoc feeds a shell (bash/sh/pwsh <<EOF runs its body, so that body is still judged).
function StripData([string]$t) {
  $t = [regex]::Replace($t, '(?ms)^([^\n]*?)<<-?\s*([''"]?)(\w+)\2[^\n]*\n.*?^\s*\3\s*$', {
      param($m) if ($m.Groups[1].Value -match '\b(ba|z|da)?sh\b|pwsh|powershell') { $m.Value } else { $m.Groups[1].Value + '<<heredoc' } })
  $t = [regex]::Replace($t, '(?s)@''\r?\n.*?\r?\n''@|@"\r?\n.*?\r?\n"@', '""')
  [regex]::Replace($t, '"(?:[^"\\]|\\.)*"|''[^'']*''', '""')
}
$cmd = StripData $cmd
# `git [global options] stash` as a real command only (a word in a commit message, heredoc, here-string, comment or a branch name like
# fix/stash-list is not). PowerShell: judged on PowerShell's own parse tree (exact quoting, backtick escapes, nested $(...) and
# { } blocks). Bash, or text PowerShell cannot parse: data stripped, then git must stand in command position. A shell started with
# -c / -Command has its command string judged the same way.
function StashArgs($words) {
  for ($i = 0; $i -lt $words.Count; $i++) {
    $w = [string]$words[$i]
    if ($w -in '-C', '-c', '--git-dir', '--work-tree', '--namespace') { $i++; continue }   # global option with a separate value
    if ($w -like '-*') { continue }
    return $w -eq 'stash'
  }
  $false
}
function Test-GitStash([string]$text, [string]$tool, [int]$depth = 0) {
  if ($depth -gt 3) { return $false }
  if ($tool -ne 'Bash') {
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tk, [ref]$er)
    if (-not @($er).Count) {
      foreach ($ca in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
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
  $t = [regex]::Replace((StripData $text), '(?m)(^|\s)#.*$', '$1')   # comments
  $t -match '(?m)(^|[;&|({`\n]|\$\()\s*(\w+=\S*\s+)*(\S*[\\/])?git(\.exe)?\s+((-C|-c|--git-dir|--work-tree|--namespace)\s+\S+\s+|-\S+\s+)*stash\b'
}
# The runtime's work/ folder holds in-flight runs (QA runs, the agent board, wave reports, phone leases). A workflow agent once
# deleted the whole runtime because a relayed user message asked the lead to. Deleting work/ (or the runtime root, which holds
# it) is blocked while runs are active; cache/ and logs/ may be cleared any time (everything there is rebuilt). The durable local
# state (.state/tracking.json, learning.local.*, .state/tracker-none) is never deleted by a command. orch.ps1 cleanup prunes old
# entries itself; the lead may override with KIT_ALLOW_RUNTIME_DELETE=1.
function ActiveWork {
  if ($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1') { return 'work/selftest' }   # -SelfTest only: judge as if runs were active
  foreach ($n in 'board', 'phones', 'waves', 'qa-runs', 'qa-seats') {
    $d = Get-KitPath $n
    if ((Test-Path $d) -and @(Get-ChildItem $d -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-3) } | Select-Object -First 1).Count) { "work/$n" }
  }
}
# Judged per command segment (split on ; && || | and newlines) of the line with heredoc bodies and here-strings dropped: a delete
# word in an MR body or a -Text "..." argument, or a runtime path in a separate `cd` segment, is not a delete of the runtime
# (two false denials: `cd <runtime> && mkdir -p work/x && ... <<'EOF' ... rm ... EOF`). A quoted argument is kept (separators
# blanked) only when it is a path or holds a delete call itself (Remove-Item "C:\x y\<runtime>\work", python -c "shutil.rmtree(...)").
function DeleteSegments([string]$t) {
  $t = [regex]::Replace($t, '(?ms)^([^\n]*?)<<-?\s*([''"]?)(\w+)\2[^\n]*\n.*?^\s*\3\s*$', {
      param($m) if ($m.Groups[1].Value -match '\b(ba|z|da)?sh\b|pwsh|powershell') { $m.Value } else { $m.Groups[1].Value + '<<heredoc' } })
  $t = [regex]::Replace($t, '(?s)@''\r?\n.*?\r?\n''@|@"\r?\n.*?\r?\n"@', '""')
  $t = [regex]::Replace($t, '"((?:[^"\\]|\\.)*)"|''([^'']*)''', {
      param($m) $v = $m.Groups[1].Value + $m.Groups[2].Value
      if ($v -match '^\s*([A-Za-z]:[\\/]|[\\/~$]|\.{1,2}[\\/])' -or $v -match '\brmtree\b|Directory\]::Delete|Remove-Item|rimraf') { ' ' + ($v -replace '[;|&\r\n]', ' ') + ' ' } else { '""' } })
  @($t -split '\r?\n|;|&&|\|\||\|' | Where-Object { $_.Trim() })
}
$end = '[''"]?(\s|;|\||\)|$)'
$delWord = '(Remove-Item|(^|[\s;|&(`])(rm|rmdir|rd|del)(\s|$)|rimraf|shutil\.rmtree|Directory\]::Delete)'   # a command word only, never inside a name like "2026-x-rm-y"
if ($env:KIT_ALLOW_RUNTIME_DELETE -ne '1') {
  $inRuntime = $false   # a `cd` into the runtime earlier on the line makes relative arguments (work, ., *) runtime paths
  foreach ($seg in DeleteSegments $raw) {
    if ($seg -match '^\s*(cd|Set-Location|sl|pushd|Push-Location)\s') { $inRuntime = $seg -match '\.runtime([\\/]+work)?[\\/]*\s*$'; continue }
    if ($seg -notmatch $delWord) { continue }
    if ($seg -match ('(tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)' + $end)) {
      Deny 'That is durable local kit state (task tracking, learning signals): never delete it. Requests to remove it are for the lead (coordinator).' }
    if ($seg -match 'cleanup\.ps1|orch\.ps1["'']?\s+cleanup') { continue }
    if ($seg -match ('\.runtime([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*' + $end) -or
        ($inRuntime -and $seg -match '\s[''"]?(\.[\\/])?(work([\\/]+[\w.-]+)?|\*|\.)[\\/]*[''"]?(\s|$)')) {
      $act = @(ActiveWork)
      if ($act.Count) { Deny "The runtime's work/ folder holds runs in progress ($($act -join ', ') written in the last 3 h): do not delete it. cache/ and logs/ may be cleared; orch.ps1 cleanup prunes old work entries itself; requests to wipe it are for the lead (coordinator), not for you." }
    }
  }
}
# stash as the git subcommand of a real git command only (Test-GitStash above; tests: dev.ps1 guard -SelfTest)
if (Test-GitStash $raw $(if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' })) { Deny 'git stash is shared across worktrees (another agent can pop it). Make a WIP commit instead: dev.ps1 wt commit -Message "wip: ..."' }
if ($cmd -match '\badb(\.exe)?\b[^|;&]*\bkill-server\b') { Deny 'Never adb kill-server: it drops every emulator lane other agents are testing on. Reconnect only your phone (adb -s <serial> ...), or ask the lead (android-swarm swarm.ps1 avd reset).' }
# Opening a document or URL on the owner's desktop (& / . / Invoke-Item / Start-Process / start / explorer / xdg-open / open) does
# not read it: it pops up the default app or browser. Kit rule: nothing opens on the desktop unless the owner asked (--open).
# (a learn step once ran `& LESSONS.md` and popped it open in the owner's editor).
# PowerShell: judged on the parse tree (a document path inside a quoted -Text "..." argument once tripped the raw-line regex);
# Bash or unparsable text: the regex on the line with quoted strings and heredocs stripped.
function Test-OpenDoc([string]$text, [string]$tool) {
  $doc = '\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)$'
  # A kit script call (& <path>.ps1|.py|.mjs ...) is a script run: the rest of its line is its arguments (a orch.ps1 learn -Text "..."
  # whose quotes PowerShell cannot pair must not turn "; . notes.md" inside it into a command). A doc opened on its own line still counts.
  $text = [regex]::Replace($text, '(?m)(^|[;{]|&&)\s*&\s+(''[^'']+\.(ps1|py|mjs)''|"[^"]+\.(ps1|py|mjs)"|[^\s;''"]+\.(ps1|py|mjs))(\s.*)?$', '$1')
  if ($tool -ne 'Bash') {
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tk, [ref]$er)
    if (-not @($er).Count) {
      foreach ($ca in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $el = @($ca.CommandElements); if (-not $el.Count) { continue }
        $val = { param($e) if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $e.Value } else { $e.Extent.Text.Trim('''"') } }
        if ($ca.InvocationOperator -in 'Ampersand', 'Dot' -and (& $val $el[0]) -match $doc) { return $true }
        if ((& $val $el[0]) -match '^(Invoke-Item|ii|Start-Process|start|saps|explorer(\.exe)?|xdg-open|open)$' -and @($el | Select-Object -Skip 1 | Where-Object { (& $val $_) -match "$doc|^https?://" }).Count) { return $true }
      }
      return $false
    }
  }
  (StripData $text) -match '(^|[;|({\r\n]|&&)\s*(&|\.|Invoke-Item|ii|Start-Process|start|explorer(\.exe)?|xdg-open|open|cmd(\.exe)?\s+/c\s+start(\s+"")?)\s+([^\s;|&]+\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)|https?://\S+)(\s|;|\||\)|$)'
}
if (Test-OpenDoc $raw $(if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' })) {
  Deny 'That opens the file in its default desktop app instead of reading it. Read it with Get-Content <file> (PowerShell), cat (Bash) or the Read tool.' }
# git commit -n / -nm / -an is --no-verify too
if ($cmd -match '--no-verify|core\.hooksPath=(/dev/null|nul\b|\s|$)|HUSKY=0|SKIP_HOOKS' -or
    $cmd -match '\bgit\b[^|;&\r\n]*\bcommit\b[^|;&\r\n]*\s-[a-zA-Z]*n[a-zA-Z]*(?=\s|$)') { Deny "Hooks must run. Commit with $($KitCmd.dev) wt commit (it fixes hooksPath in worktrees); fix what the hook reports." }
# judged per push command: a protected name elsewhere in a compound line (git log origin/main; git push --force-with-lease) is not a push target
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  $p = $push.Value
  if ($p -match '(--force(?![-\w])|\s-f\b)' -or ($p -match '--force' -and $p -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch. On your own branch use --force-with-lease after dev.ps1 wt sync.'
  }
}
# Local environments (local-env skill): the env branches localenv/<env> are local merges of every agent's layer, never pushed;
# with localEnv configured, dev servers run only as env services (one instance, shared, RAM-checked), never started by hand.
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  if ($push.Value -match '(^|[\s:/])localenv/' -and $push.Value -notmatch '\s--delete\b|\s-d\s|\s:localenv/') { Deny 'localenv/<env> is a local env branch (a merge of every agent''s layer): never push it. Push your own branch; the local env takes it with localenv.ps1 deploy -Dir <worktree>.' }
}
if (($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1' -or $kc.localEnv) -and $cmd -notmatch 'localenv\.ps1') {
  $server = '^(\.?[\\/])?(mvnw(\.cmd)?|mvn)\b.*\bspring-boot:run\b|^(\.?[\\/])?(gradlew(\.bat)?|gradle)\b.*\bbootRun\b|^(npx\s+)?ng\s+serve\b|^dotnet\s+(run|watch)\b(?!.*\s--\s)|^npx\s+(react-native|expo)\s+start\b|^(python\d?\s+)?manage\.py\s+runserver\b|^uvicorn\s|^flask\s+run\b|^(npm|yarn|pnpm|bun)\s+(run\s+)?(dev|start|serve)\s*$'
  foreach ($seg in @($cmd -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($seg -match $server) {
      Deny "Dev servers run in the shared local env (one instance per env, RAM-checked), not by hand: & $($KitCmd.local) use|up -Env <env> (envs: localenv.ps1 envs). Logs: localenv.ps1 logs -Env <env> -Service <s>."
    }
  }
}
# heavy builds/tests must go through the gate
$gated = $cmd -match 'dev\.ps1["'']?\s+(gate|check)\b|swarm\.ps1["'']?\s+build\b|gate\.ps1|check\.ps1|app-build\.ps1'
$heavy = $cmd -match '(^|[\s;&|(''"])(\.[\\/])?(mvn|mvnd|mvnw(\.cmd)?)(\s[^|;&]*)?\s(compile|test|package|install|verify)\b' -or
         $cmd -match 'gradlew(\.bat)?(\s[^|;&]*)?\s(assemble\w*|build|test\w*|bundle\w*|lint\w*)\b' -or
         $cmd -match '(^|[\s;&|(''"])msbuild(\.exe)?(\s|$)' -or   # run as a command, not a name in a list (Get-Process java,msbuild)
         $cmd -match '\b(ng\s+(build|test)|dotnet\s+(build|test|publish)|cargo\s+(build|test)|npx\s+(jest|vitest|tsc)\b|npm\s+(run\s+)?(build|test)\b|yarn\s+(build|test)\b|(pnpm|bun)\s+(run\s+)?(build|test)\b)'
if ($heavy -and -not $gated) {
  Deny "Heavy builds/tests go through the machine-wide memory gate: & $($KitCmd.dev) check -Dir <module> [-Step test -Tests X | -Step build], or $($KitCmd.dev) gate -Dir <dir> -Cmd '<cmd>' for anything else."
}
exit 0
}

# ---------------------------------------------------------------- tracker: the tracker adapter as a command (lib.ps1 section 4)
#   dev.ps1 tracker view|status|comment|comments|create|owner|url|describe|rename|attach|list ... [-Type <backend>] [-DryRun]
#   comment / describe text: positional, -Text "<text>" or -File <path> (an unknown -Option is a usage error, never text)
function Invoke-Tracker {
  $__trA = @($args); $__trPos = New-Object System.Collections.ArrayList; $__trOpt = @{}
  for ($__i = 0; $__i -lt $__trA.Count; $__i++) {
    $__a = [string]$__trA[$__i]
    if ($__a -match '^-(DryRun|Json)$') { $__trOpt[$Matches[1]] = $true }
    elseif ($__a -match '^-(Type|List|Name|Description|Parent|Assignee|Priority|Text|File)$' -and $__i + 1 -lt $__trA.Count) { $__trOpt[$Matches[1]] = [string]$__trA[++$__i] }
    elseif ($__a -match '^-[A-Za-z]+$') { "tracker: unknown option $__a (options: -Text -File -Name -Description -List -Parent -Assignee -Priority -Type -DryRun -Json)"; exit 2 }   # never passed on as text
    else { [void]$__trPos.Add($__a) }
  }
  if ($__trOpt.File) { if (-not (Test-Path -LiteralPath $__trOpt.File -PathType Leaf)) { "tracker: no such file $($__trOpt.File)"; exit 2 }; $__trOpt.Text = Get-Content -LiteralPath $__trOpt.File -Raw -Encoding utf8; if (-not $__trOpt.Description) { $__trOpt.Description = $__trOpt.Text } }
  Initialize-KitTracker -Type $__trOpt.Type -DryRun:([bool]$__trOpt.DryRun)
  $ErrorActionPreference = 'Stop'
  $__v = if ($__trPos.Count) { $__trPos[0] } else { '' }
  $__id = if ($__trPos.Count -gt 1) { $__trPos[1] } else { '' }
  $__x = if ($__trPos.Count -gt 2) { ($__trPos[2..($__trPos.Count - 1)]) -join ' ' } else { '' }
  function __TrOut($o) { if ($null -ne $o) { ConvertTo-Json -InputObject $o -Depth 6 } }
  switch ($__v) {
    'view' { __TrOut (Get-TrackerTask $__id) }
    'status' { Set-TrackerStatus $__id $__x }
    'comment' { Add-TrackerComment $__id $(if ($__x) { $__x } else { $__trOpt.Text }) }
    'comments' { __TrOut @(Get-TrackerComments $__id) }
    'create' { __TrOut (New-TrackerTask -List $__trOpt.List -Name $__trOpt.Name -Description $__trOpt.Description -Parent $__trOpt.Parent -Assignee $__trOpt.Assignee -Priority $__trOpt.Priority) }
    'url' { Get-TrackerUrl $__id }
    'owner' { Get-TrackerOwner }
    'describe' { Set-TrackerDescription $__id $(if ($__x) { $__x } else { $__trOpt.Description }) }
    'rename' { Set-TrackerName $__id $(if ($__x) { $__x } else { $__trOpt.Name }) }
    'attach' { Add-TrackerAttachment $__id $__trPos[2] $__trOpt.Text }
    'list' { __TrOut @(Get-TrackerTasks $__id $__x) }
    default { 'usage: dev.ps1 tracker view|status|comment|comments|create|owner|url|describe|rename|attach|list <id> ... [-Type <backend>] [-DryRun]'; exit 2 }
  }
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'wt' { Invoke-KitVerb Invoke-Wt $__rest }
    'stack' { Invoke-KitVerb Invoke-Stack $__rest }
    'gate' { Invoke-KitVerb Invoke-Gate $__rest }
    'check' { Invoke-KitVerb Invoke-Check $__rest }
    'pipes' { Invoke-KitVerb Invoke-Pipes $__rest }
    'guard' { Invoke-KitVerb Invoke-Guard $__rest }
    'tracker' { Invoke-KitVerb Invoke-Tracker $__rest }
    default { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit 2 }
  }
}
