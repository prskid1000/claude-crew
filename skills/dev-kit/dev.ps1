<#
dev.ps1: dev-kit commands (SKILL.md steps 1-8). pwsh 7: & <kit>/skills/dev-kit/dev.ps1 <verb> [args]
 wt new|sync|commit|remove|status|list ...  worktrees (deps linked, hooks run)
 stack -Dir <module> [-Json]  build/test/run commands (auto-detected; .claude-stack.json overrides)
 check -Dir <module> [-Step quick|test|build|migrations] [-Tests <names>] [-Touched]  gated checks
 gate -Dir <dir> -Cmd "<command>"  a heavy command through the machine-wide memory gate
 tracker <verb> <id> ...  tracker adapter (view, status, comment, create, list, ...)
 pipes -Mrs <url>,... [-MaxMinutes 8]  wait for MR pipelines (JSON)
 host <verb> '<args JSON>'  git-host / ci adapter verb (README "Adapters")
 guard [-SelfTest]  PreToolUse hook (tool call JSON on stdin)
 runtime use|release|status -Name <runtime> [-Agent]  leases on Docker, WSL, VMs (extra runtimes)
In: kit.local.json + verb parameters. Out: text, or JSON with -Json.
Exit codes: 0 ok · 1 problem (failed check, conflict, blocked) · 2 usage · gate/check: the command's code
Sections: L16 init · L22 wt · L224 stack · L399 gate · L643 check · L796 pipes · L832 guard · L1076 tracker · L1109 host
#>
# ---- init: verb arguments, the gate mutex, lib.ps1
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
# the gate mutex; an abandoned one is ours
function Lock-Gate($m) { try { $m.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $true } }
. (Join-Path $PSScriptRoot 'lib.ps1')
# ---- wt: a worktree per agent; deps linked, never installed
function Invoke-Wt {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('new', 'sync', 'commit', 'status', 'remove', 'list')][string]$Action,
  [string]$Repo, [string]$Branch, [string]$Target, [string]$Name, [string]$LinkFrom, [string]$Root,
  [string]$Dir, [string]$Message, [string]$MessageFile, [switch]$Force, [switch]$NoStage
)
$ErrorActionPreference = 'Stop'
function G { $o = & git @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' '): $o" }; $o }
# else git -C hits an outer repo
function Resolve-Wt($d) {
  if (-not $d) { $d = (Get-Location).Path }
  if (-not (Test-Path -LiteralPath $d -PathType Container)) { throw "no such folder: $d" }
  $d = (Resolve-Path -LiteralPath $d).Path.TrimEnd('\', '/')
  $pre = git -C $d rev-parse --show-prefix 2>$null   # '' only at a worktree top
  if ($LASTEXITCODE -or "$pre".Trim()) { throw "$d is not the top of a git worktree (top: $(git -C $d rev-parse --show-toplevel 2>$null)); pass the worktree folder as -Dir" }
  $d
}
function GitDir($d) { $g = (git -C $d rev-parse --git-dir).Trim(); if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $d $g }; $g }
function Meta($d, $k, $v) { $f = Join-Path (GitDir $d) "claude-$k"; if ($PSBoundParameters.ContainsKey('v')) { $v | Set-Content $f } elseif (Test-Path $f) { Get-Content $f } }
function DepHash($pkgJson) {
  try { $p = Get-Content $pkgJson -Raw | ConvertFrom-Json } catch { return '' }
  (@('dependencies', 'devDependencies') | ForEach-Object { if ($p.$_) { $p.$_.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)@$($_.Value)" } } }) -join ';'
}
function Add-DepLinks($path, $src, $target) {
  $made = @()
  foreach ($pj in (git -C $path ls-files -- 'package.json' '*/package.json' | Where-Object { $_ -notmatch 'node_modules/' })) {
    $rel = Split-Path $pj; if (-not $rel) { $rel = "." }; $from = Join-Path $src (Join-Path $rel 'node_modules'); $to = Join-Path $path (Join-Path $rel 'node_modules')
    if ((Test-Path $from) -and -not (Test-Path $to)) {
      $null = Set-NodeModules $to $from $src $path; $made += $to
      $a = DepHash (Join-Path $path $pj); $b = DepHash (Join-Path $src $pj)
      if ($a -ne $b) { Write-Warning "$pj deps differ from ${src}: linked node_modules may be wrong.$(if ($target) { " Use -LinkFrom <a $target checkout with matching installs>." })" }
    }
  }
  foreach ($py in (git -C $path ls-files -- 'pyproject.toml' '*/pyproject.toml' 'requirements.txt' '*/requirements.txt')) {
    $rel = Split-Path $py; if (-not $rel) { $rel = "." }; $from = Join-Path $src (Join-Path $rel '.venv'); $to = Join-Path $path (Join-Path $rel '.venv')
    if ((Test-Path $from) -and -not (Test-Path $to)) { New-DirLink $to $from; $made += $to }
  }
  $made
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

switch ($Action) {
  'new' {
    if (-not ($Repo -and $Branch -and $Target -and $Name)) { throw 'new needs -Repo -Branch -Target -Name' }
    $Repo = (Resolve-Path $Repo).Path
    if (-not $Root) { $Root = @($KitConf.WorktreeRoots)[0] }
    $path = Join-Path $Root "$Name-$(Split-Path $Repo -Leaf)"
    if (Test-Path $path) { throw "$path exists: resume there (wt status -Dir $path) or pick another -Name" }
    # a missing configured dep source is an error, no fallback
    $r = $null
    $kc = $KitConf.ConfigFile
    if ($kc -and (Test-Path $kc)) {
      $rp = (Resolve-Path $Repo).Path.TrimEnd('\', '/')
      $r = @((Get-Content $kc -Raw | ConvertFrom-Json).repos) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rp) } | Select-Object -First 1
    }
    if (-not $LinkFrom) {
      if ($r) {
        $cand = if ($r.linkFromByTarget -and $r.linkFromByTarget.$Target) { $r.linkFromByTarget.$Target } elseif ($r.linkFrom -and $Target -eq $r.target) { $r.linkFrom } else { $null }
        if ($cand -and -not (Test-Path $cand)) { throw "kit.local.json dep source $cand ($(Split-Path $Repo -Leaf), target $Target) is missing: create it (git worktree add --detach <path> origin/$Target + frozen-lockfile install) or fix kit.local.json" }
        if ($cand) { $LinkFrom = $cand; "linking dependencies from $cand (kit.local.json, target $Target)" }
      }
    }
    New-Item -ItemType Directory -Force $Root | Out-Null
    # else the root shows as untracked in an outer repo
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
    $remoteBranch = git -C $Repo ls-remote --heads origin "refs/heads/$Branch"   # bare name: suffix match
    git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"
    # reuse the local branch: -B would lose unpushed commits
    if ($LASTEXITCODE -eq 0) { G -C $Repo worktree add $path $Branch | Out-Null; "local branch $Branch exists: checked out as is$(if ($remoteBranch) { " (also on origin: compare before pushing)" })" }
    elseif ($remoteBranch) { G -C $Repo fetch -q origin $Branch | Out-Null; G -C $Repo worktree add -b $Branch $path "origin/$Branch" | Out-Null; "branch $Branch on origin: checked out" }
    else { G -C $Repo worktree add -b $Branch $path "origin/$Target" | Out-Null }
    Meta $path 'target' $Target
    $src = if ($LinkFrom) { (Resolve-Path $LinkFrom).Path } else { $Repo }
    $links = @(Add-DepLinks $path $src $Target)
    # linkPaths: git-ignored files every worktree needs
    foreach ($lp in @($r.linkPaths) | Where-Object { $_ }) {
      $from = @((Join-Path $src $lp), (Join-Path $Repo $lp)) | Where-Object { Test-Path $_ } | Select-Object -First 1
      $to = Join-Path $path $lp
      if (-not $from) { Write-Warning "linkPaths: no $lp in $src or $Repo, skipped"; continue }
      if (Test-Path $to) { continue }
      New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
      if ((Get-Item $from).PSIsContainer) { New-DirLink $to $from; $links += $to } else { Copy-Item $from $to }
    }
    # a --ignore-scripts checkout has no .husky/_
    Copy-HookDirs $path @($src, $Repo)
    Meta $path 'links' ($links -join "`n")
    Exclude-Links $path $links
    "worktree: $path"
    "branch:   $Branch (from origin/$Target)"
    if ($links) { 'linked:   ' + (($links | ForEach-Object { $_.Substring($path.Length + 1) }) -join ', ') + "  (from $src)" }
  }
  'sync' {
    $Dir = Resolve-Wt $Dir
    $t = Meta $Dir 'target'; if (-not $t) { throw "no target for ${Dir}: git -C $Dir rebase origin/<target>" }
    if (git -C $Dir status --porcelain --untracked-files=no) { throw 'uncommitted changes: commit first (WIP is fine; never git stash)' }
    G -C $Dir fetch -q origin $t | Out-Null
    git -C $Dir rebase "origin/$t"
    if ($LASTEXITCODE) { "REBASE CONFLICT. Append-only files (changelog masters, nav/i18n lists): $(Split-Path (Get-Python) -Leaf) $($KitCmd.devtools) keepboth <file>; real code: resolve by hand. Then git add + git -C $Dir rebase --continue, and re-run dev.ps1 check."; exit 1 }
    "rebased onto origin/$t"
  }
  'commit' {
    $Dir = Resolve-Wt $Dir
    if ($MessageFile) { if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { throw "no such message file: $MessageFile" }; $Message = Get-Content -LiteralPath $MessageFile -Raw -Encoding utf8 }
    if (-not $Message -or -not $Message.Trim()) { throw 'commit needs -Message or -MessageFile' }
    # a worktree not made by new lacks .husky/_ and hook deps
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
    if (-not $NoStage) { git -C $Dir add -A }
    # merge subjects name branches
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
    # never the current folder: it may be a main tree or the live kit
    if ($Name -and -not $Dir) {
      $roots = if ($Root) { @($Root) } else { $KitConf.WorktreeRoots }
      $hits = @(foreach ($rt in $roots) { Get-ChildItem -LiteralPath $rt -Directory -ErrorAction SilentlyContinue | Where-Object { $(if ($Repo) { $_.Name -eq "$Name-$(Split-Path $Repo -Leaf)" } else { $_.Name -eq $Name -or $_.Name.StartsWith("$Name-", [StringComparison]::OrdinalIgnoreCase) }) } })
      if ($hits.Count -ne 1) { throw "wt remove -Name ${Name}: $($hits.Count) worktrees match in $($roots -join ', ')$(if ($hits) { ": $($hits.FullName -join ', ')" }); pass -Repo or -Dir" }
      $Dir = $hits[0].FullName
    }
    if (-not $Dir) { throw 'remove needs -Dir <worktree> or -Name <name from wt new>' }
    $Dir = Resolve-Wt $Dir
    $gd = (git -C $Dir rev-parse --path-format=absolute --git-dir).Trim()
    if ($gd -eq (git -C $Dir rev-parse --path-format=absolute --git-common-dir).Trim() -or $Dir -eq (Resolve-Path -LiteralPath $KitConf.Kit).Path.TrimEnd('\', '/')) { throw "$Dir is a main working tree or the running kit: wt remove only removes linked worktrees" }
    $links = @(@(@(Meta $Dir 'links') | Where-Object { $_ -and (Test-Path $_) }) + @(Get-DirLinks $Dir 4 | ForEach-Object { $_.FullName }) | Sort-Object -Unique)
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
    git -C $main worktree remove $(if ($Force) { '--force' }) $Dir
    if ($LASTEXITCODE) {
      foreach ($u in $undo) { if ($u[1] -and -not (Test-Path $u[0])) { New-DirLink $u[0] $u[1] } }
      foreach ($u in $farmUndo) { $src = $u[1][0]; $wtr = $u[1][1]; $null = Set-NodeModules $u[0] $src (git -C $Dir rev-parse --path-format=absolute --git-common-dir | Split-Path) $wtr }
      throw "git worktree remove failed for $Dir (links restored): fix what git reports, or -Force"
    }
    "removed $Dir"
  }
  'list' { git -C $(if ($Repo) { $Repo } else { (Get-Location).Path }) worktree list }
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

function NodeSpecCmd { "node `"$($KitCmd.spec)`" {tests}" }

function Get-NodeTools($d) {
  $pkg = ReadJson (Join-Path $d 'package.json')
  $deps = @()
  foreach ($k in 'dependencies', 'devDependencies') { if ($pkg.$k) { $deps += $pkg.$k.PSObject.Properties.Name } }
  $scripts = if ($pkg.scripts) { $pkg.scripts.PSObject.Properties.Name } else { @() }
  $jestCfg = @('jest-unit.config.json', 'jest.config.js', 'jest.config.ts', 'jest.config.json', 'jest.config.cjs', 'jest.config.mjs') | Where-Object { Test-Path (Join-Path $d $_) } | Select-Object -First 1
  [pscustomobject]@{
    Deps = $deps; Scripts = $scripts
    Ts = Test-Path (Join-Path $d 'tsconfig.json')
    Jest = ($deps -contains 'jest') -or [bool]$jestCfg
    JestCfg = $jestCfg
    Vitest = $deps -contains 'vitest'
    Eslint = ($deps -contains 'eslint') -or (Has $d 'eslint.config.*', '.eslintrc*')
  }
}

function Get-Stack($d) {
  $c = [ordered]@{ compile = $null; typecheck = $null; lint = $null; test = $null; build = $null; format = $null; run = $null }
  $s = $null; $deps = @()

  if (Test-Path (Join-Path $d 'pom.xml')) {
    $s = 'java-maven'
    $mvn = Wrapper $d 'mvnw' 'cmd' 'mvn'
    # offline: no repo lock fights
    $off = if ((Get-KitSetting 'build.mavenOffline' $true) -ne $false -and "$(Get-KitSetting 'build.mavenOffline' $true)" -ne 'false' -and (Test-Path (Join-Path $HOME '.m2/repository'))) { '-o ' } else { '' }
    $c.compile = "$mvn $off-q compile"
    $c.test = "$mvn $off-q test -Dtest={tests} -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false"
    $c.build = "$mvn $off-q package -DskipTests"
    if ((ReadText (Join-Path $d 'pom.xml')) -match 'spring-boot') { $c.run = "$mvn $($off)spring-boot:run" }
  }
  elseif (Has $d 'build.gradle', 'build.gradle.kts', 'settings.gradle*') {
    $gw = Wrapper $d 'gradlew' 'bat' 'gradle'
    # an Android module (AndroidManifest.xml): extra stack-presets
    $android = [bool](Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $android) {
      $s = 'gradle'
      $c.compile = "$gw classes -q"
      $c.test = "$gw test --tests {tests}"
      $c.build = "$gw assemble"
      $c.run = if ((@(Get-ChildItem -LiteralPath $d -Filter 'build.gradle*' -File -ErrorAction SilentlyContinue | ForEach-Object { ReadText $_.FullName }) -join ' ') -match 'org\.springframework\.boot') { "$gw bootRun" } else { "$gw run" }
    }
  }
  elseif (Test-Path (Join-Path $d 'angular.json')) {
    $s = 'angular'; $n = Get-NodeTools $d; $deps = @('node_modules')
    $tsc = if (Test-Path (Join-Path $d 'tsconfig.app.json')) { 'tsconfig.app.json' } else { 'tsconfig.json' }
    $c.typecheck = "npx tsc -p $tsc --noEmit"
    $c.build = 'npx ng build --configuration production'
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
    else { $c.test = NodeSpecCmd }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    $c.run = 'npx ng serve --port {port}'
  }
  elseif (Test-Path (Join-Path $d 'package.json')) {
    $n = Get-NodeTools $d; $deps = @('node_modules')
    $s = if ($n.Deps -contains 'react-native') { 'react-native' } elseif ($n.Deps -contains 'next') { 'node-next' } elseif ($n.Deps -contains 'react') { 'node-react' } else { 'node' }
    $pm = Get-NodePm $d
    if ($n.Ts) { $tp = TsProject $d; $c.typecheck = if ($tp) { "npx tsc -p $tp --noEmit" } else { 'npx tsc --noEmit' } }
    if ($n.Vitest) { $c.test = 'npx vitest run {tests}' }
    elseif ($n.Jest) { $c.test = 'npx jest ' + $(if ($n.JestCfg) { "--config $($n.JestCfg) " } else { '' }) + '{tests} --no-watchman --forceExit' }
    elseif ($n.Scripts -contains 'test') { $c.test = NodeRun $pm 'test' '{tests}' }
    elseif ($n.Ts -and $s -ne 'react-native') { $c.test = NodeSpecCmd }
    if ($n.Eslint) { $c.lint = 'npx eslint {files}' }
    if ($s -ne 'react-native' -and $n.Scripts -contains 'build') { $c.build = NodeRun $pm 'build' '' }
    $agw = Wrapper (Join-Path $d 'android') 'gradlew' 'bat' $null
    if ($s -eq 'react-native' -and $agw) { $c.build = "cd android && $agw assembleRelease" }
    $c.run = if ($s -eq 'react-native') { if ($n.Deps -contains 'expo') { 'npx expo start --port {port}' } else { 'npx react-native start --port {port}' } }
            elseif ($n.Scripts -contains 'dev') { NodeRun $pm 'dev' '' } elseif ($n.Scripts -contains 'start') { NodeRun $pm 'start' '' } else { $null }
  }
  elseif (Has $d 'pyproject.toml', 'requirements*.txt', 'setup.py', 'Pipfile') {
    $s = 'python'; $deps = @('.venv')
    $py = if ($KitIsWindows -and (Test-Path (Join-Path $d '.venv\Scripts\python.exe'))) { '.venv\Scripts\python.exe' }
          elseif (-not $KitIsWindows -and (Test-Path (Join-Path $d '.venv/bin/python'))) { '.venv/bin/python' }
          elseif ($KitIsWindows -or -not (Resolve-Tool python3)) { 'python' } else { 'python3' }
    $c.compile = "$py -m compileall -q -x `"[\\/](\.venv|venv|node_modules|\.git)[\\/]`" {files}"
    $cfgText = @('pyproject.toml', 'setup.cfg', 'tox.ini') | ForEach-Object { ReadText (Join-Path $d $_) }
    $have = $null
    $pyExe = if ($py -match '^\.venv') { Join-Path $d $py } else { (Resolve-Tool $py) }
    if ($pyExe -and (Test-Path $pyExe)) {
      $have = @(& $pyExe -c "import importlib.util as u; print(' '.join(m for m in ('ruff','flake8','pytest') if u.find_spec(m)))" 2>$null) -join ' '
      if ($LASTEXITCODE) { $have = $null }
    }
    $ruffCfg = (Has $d 'ruff.toml', '.ruff.toml') -or ("$cfgText" -match '\[tool\.ruff')
    $flakeCfg = (Has $d '.flake8') -or ("$cfgText" -match '\[flake8\]')
    $pytestCfg = (Has $d 'pytest.ini', 'conftest.py') -or ("$cfgText" -match '\[tool\.pytest|\[pytest\]|\[tool:pytest\]')
    if ($null -eq $have) { $c.lint = if ($flakeCfg -and -not $ruffCfg) { "$py -m flake8 {files}" } else { "$py -m ruff check {files}" }; $c.test = "$py -m pytest {tests} -q" }
    else {
      $c.lint = if ($have -match 'ruff' -and ($ruffCfg -or -not ($flakeCfg -and $have -match 'flake8'))) { "$py -m ruff check {files}" } elseif ($have -match 'flake8') { "$py -m flake8 {files}" } else { $null }
      $c.test = if ($have -match 'pytest' -or $pytestCfg) { "$py -m pytest {tests} -q" } else { "$py -m unittest {tests}" }
    }
    if (Test-Path (Join-Path $d 'manage.py')) { $c.run = "$py manage.py runserver {port}" }
    if ((Has $d 'mypy.ini') -or (Select-String -LiteralPath (Join-Path $d 'pyproject.toml') -Pattern '\[tool\.mypy\]' -Quiet -ErrorAction SilentlyContinue)) { $c.typecheck = "$py -m mypy {files}" }
  }
  # installed extras (stack-presets): Android Gradle, .NET, Go, Rust, CMake, Make
  foreach ($plugin in @($KitAdapters.stack.Values | Where-Object { $_ })) { if (-not $s) { $s = & $plugin.detect @{ dir = $d; commands = $c } } }
  $ovr = ReadJson (Join-Path $d '.claude-stack.json')
  if (-not $s -and -not $ovr.stack -and ($android -or (Has $d '*.sln', '*.csproj', '*.fsproj', 'go.mod', 'Cargo.toml', 'CMakeLists.txt', 'Makefile'))) { throw (Get-KitExtraLine 'stack' 'presets') }
  if (-not $s -and -not $ovr.stack) { return $null }   # an override's stack alone is a stack (the "add a .claude-stack.json" advice)

  if ($ovr) {
    if ($ovr.stack) { $s = $ovr.stack }
    if ($ovr.commands) { foreach ($p in $ovr.commands.PSObject.Properties) { $c[$p.Name] = $p.Value } }
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
  $hit.commands.PSObject.Properties | Where-Object Value | ForEach-Object { '  {0,-9} {1}' -f $_.Name, $_.Value }
}
}

# ---- gate: machine-wide memory gate; exit = the command's code, 3 = not started in time
function Invoke-Gate {
param(
  [Parameter(Mandatory)][string]$Cmd,
  [string]$Dir = (Get-Location).Path,
  [int]$WaitMinutes = 90,
  [double]$KeepFreeGB = -1,   # -1 = Get-KitKeepFreeGB
  [double]$NeedGB = 0,
  [int]$MaxParallel = 0
)
$keepFromConfig = $KeepFreeGB -lt 0   # re-read every round: a config change reaches queued builds
if ($keepFromConfig) { $KeepFreeGB = Get-KitKeepFreeGB }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

$Kinds = [ordered]@{
  'emulator' = @('^exit 0 #emulator', 4.5)
  'android-build' = @('gradlew.*\b(assemble|bundle)', 7)
  'android-test' = @('gradlew.*\btest|connectedAndroidTest|lintDebug', 6)
  'gradle' = @('gradle(w|w\.bat)?\b', 3.5)
  'rn-bundle' = @('export:embed|react-native bundle|expo export', 3)
  'e2e' = @('cypress|playwright', 3.5)
  'ng-test' = @('ng test|karma', 3)
  'web-build' = @('ng build|next build|vite build|webpack|npm run build|yarn build|pnpm (run )?build|bun run build', 8)
  'maven-test' = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b.*\b(test|verify|package|install)\b', 3)
  'maven' = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b', 2.5)
  'dotnet' = @('msbuild|dotnet (build|test|publish)', 3)
  'rust' = @('cargo (build|test|clippy|check)', 4)
  'native' = @('cmake --build|\bmake\b', 3)
  'js-test' = @('jest|vitest', 2)
  'tsc-lint' = @('\btsc\b|eslint', 2)
  'python' = @('pytest|mypy|ruff|compileall', 1.5)
  'go' = @('go (build|test|vet)', 2)
}
function Get-Kind([string]$c) { foreach ($k in $Kinds.Keys) { if ($c -match $Kinds[$k][0]) { return $k } }; 'other' }

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
if ($KitIsWindows) { $semi = ConvertTo-CmdSeparators $Cmd; if ($semi -ne $Cmd) { Write-Host "[gate] cmd.exe has no ';': running $semi"; $Cmd = $semi } }

# NoDefaultCurrentDirectoryInExePath hides bare names in cwd
$Cmd = [regex]::Replace($Cmd, '(^|&&\s*|&\s*|\|\|\s*)(?<!\.[\\/])(gradlew(\.bat)?|mvnw(\.cmd)?)(?=\s|$)', $(if ($KitIsWindows) { '$1.\$2' } else { '$1./$2' }))
# runners fork a worker per core
if ($Cmd -match '\bjest\b' -and $Cmd -notmatch 'maxWorkers|runInBand|\s-i(\s|$)') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bvitest\b' -and $Cmd -notmatch 'maxWorkers|maxThreads') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bpytest\b' -and $Cmd -match '\s-n\s+auto') { $Cmd = $Cmd -replace '\s-n\s+auto', ' -n 2' }

$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
New-Item -ItemType Directory -Force $ledger | Out-Null
$histFile = Join-Path $ledger 'history.json'
function Read-History { try { Get-Content $histFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} } }

$kind = Get-Kind $Cmd
$default = if ($Kinds.Contains($kind)) { $Kinds[$kind][1] } else { 2 }
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
$need = if ($NeedGB -gt 0) { $NeedGB } else { Get-NeedEstimate $default $peaks (Get-SysMem).TotalGB }

# heap caps (extra build-heap): a JVM / Node build gets a cap from its learned peak; under memory pressure the cap shrinks to its floor
$heap = 0; $heapFloor = 0; $heapTool = $null
if (($hp = Get-Command Get-GateHeap -ErrorAction SilentlyContinue) -and ($h = & $hp $kind $peaks $NeedGB $need)) { $heap = $h.heap; $heapFloor = $h.floor; $need = $h.need; $heapTool = $h.tool }

function Get-OwnerName([string]$Leaf, [string]$Repo) {
  if ($Repo -and $Leaf.Length -gt $Repo.Length + 1 -and $Leaf.EndsWith("-$Repo", [StringComparison]::OrdinalIgnoreCase)) { return $Leaf.Substring(0, $Leaf.Length - $Repo.Length - 1) }
  ($Leaf -split '-')[0]
}
$ownerRoot = if ($top) { Split-Path $top -Leaf } else { Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf }
$owner = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { Get-OwnerName $ownerRoot $(if ($top) { $repoName } else { '' }) }
$heapBase = $heap
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

function Get-State {
  $Snap = Get-KitProcSnap

  $promised = 0; $running = 0; $backfills = 0
  foreach ($f in Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json') {
    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $Snap.procs.ContainsKey([int]$e.pid)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $running++
    if ($e.backfill) { $backfills++ }
    $promised += [math]::Max(0, [double]$e.need - (Get-KitTreeGB ([int]$e.pid) $Snap))
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
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$learned = if ($NeedGB -le 0 -and $peaks.Count -ge 2) { " (learned from $($peaks.Count) runs)" } else { '' }
$usual = if ($secs.Count -ge 2) { " usually ~$([math]::Ceiling((Get-MedianSec $secs) / 60)) min," } else { '' }
Write-Host "[gate] $kind needs ~$need GB$learned,$usual keep $KeepFreeGB GB free: $Cmd"
$proc = $null; $entry = $null; $waits = 0
Write-Ticket
try {
while ((Get-Date) -lt $deadline) {
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
      if ($waits % 3 -eq 1) { Write-Host "[gate] queued #$($pos + 1) of $($queue.Count) (owner $owner); next: $($head.owner) $($head.kind)" }
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
    if ((Test-GateStart $left $KeepFreeGB ((Get-Date) - [datetime]$since).TotalMinutes $s.Total) -and (($MaxParallel -le 0) -or ($s.Running -lt $MaxParallel))) {
      if ($heap -gt 0) { $Cmd = & (Get-Command Set-GateHeap) $heapTool $heap $Cmd }
      Write-Host "[gate] starting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> ~$([math]::Round($left,1)) GB left$(if ($heap -gt 0) { "; heap cap $heap GB" })"
      # /s + outer quotes: a leading quoted path survives
      if ($KitIsWindows) { $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/s', '/c', "`"$Cmd`"" -WorkingDirectory $Dir -NoNewWindow -PassThru }
      else {
        $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($Cmd)
        $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
      }
      Remove-Item $myTicket -ErrorAction SilentlyContinue
      @{ owner = $owner; kind = $kind; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Add-Content $startsFile
      $entry = Join-Path $ledger "$($proc.Id).json"
      @{ pid = $proc.Id; gate = $PID; owner = $owner; need = $need; kind = $kind; cmd = $Cmd; dir = $Dir; started = (Get-Date).ToString('s'); backfill = $smallFill } | ConvertTo-Json | Set-Content $entry
      break
    }
    $waits++; Add-KitMemSample $s.Avail
    $msg = "[gate] waiting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> would leave $([math]::Round($left,1)) GB (< $KeepFreeGB)"
    if ($waits % 15 -eq 1) { $msg += ". Biggest users: $(Top-Users $s.Snap)" }
    Write-Host $msg
    }
  } finally { $gate.ReleaseMutex() }
  Start-Sleep -Seconds 20
}
} finally { Remove-Item $myTicket -ErrorAction SilentlyContinue }
if (-not $proc) { Write-Host "[gate] could not start within $WaitMinutes min"; exit 3 }
$sw = [Diagnostics.Stopwatch]::StartNew(); $peak = 0.0   # double: Max(int, double) would truncate
try {
  $null = $proc.Handle   # keeps ExitCode readable
  while (-not $proc.HasExited) { $peak = [math]::Max($peak, (Get-KitTreeGB $proc.Id)); Start-Sleep -Seconds 5 }
  $proc.WaitForExit(); $code = $proc.ExitCode
} finally { Remove-Item $entry -ErrorAction SilentlyContinue }
if ($peak -gt 0.2 -and $kind -ne 'emulator') {
  # builds finish together; an unreadable file is never reset
  $got = $false
  try {
    $got = Lock-Gate $gate
    if ($got) {
      $txt = if (Test-Path $histFile) { Get-Content $histFile -Raw -ErrorAction Stop } else { '' }
      $h = if ("$txt".Trim()) { $txt | ConvertFrom-Json -AsHashtable -ErrorAction Stop } else { @{} }
      if ($h -is [hashtable]) {
        $h[$histKey] = @(@($h[$histKey] | Where-Object { $_ }) + @{ gb = [math]::Round($peak, 2); sec = [int]$sw.Elapsed.TotalSeconds; ok = ($code -eq 0); at = (Get-Date).ToString('o'); code = $code; cmd = $(if ($Cmd.Length -gt 60) { $Cmd.Substring(0, 60) } else { $Cmd }) } | Select-Object -Last 10)
        $h | ConvertTo-Json -Depth 3 | Set-Content "$histFile.tmp" -ErrorAction Stop
        Move-Item "$histFile.tmp" $histFile -Force -ErrorAction Stop
      }
    }
  } catch {} finally { if ($got) { $gate.ReleaseMutex() } }
}
exit $code
}

# ---- check: gated steps of the stack; exit = the first failing step's code (3 gate, 4 no container engine, 5 UNRUN)
function Invoke-Check {
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),
  [switch]$Show,
  [switch]$Touched,
  [switch]$RealAngular
)
$ErrorActionPreference = 'Stop'
$script:anyUnrun = $false
$k = $PSScriptRoot
$st = & $KitCmd.dev stack -Dir $Dir -Json | ConvertFrom-Json
function Hash12([string]$s) { [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '').Substring(0, 12) }
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

# the target wt new recorded
function Get-WtTarget {
  $gd = git -C $st.dir rev-parse --git-dir 2>$null; if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $st.dir $gd }
  if ($gd -and (Test-Path (Join-Path $gd 'claude-target'))) { (Get-Content (Join-Path $gd 'claude-target') -TotalCount 1).Trim() }
}
# repos[].migrations.check runs (in the worktree); else Liquibase XML -> lbcheck (extra liquibase); any other tool or changelog format = UNRUN (exit 5)
if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $main = Split-Path (git -C $top rev-parse --path-format=absolute --git-common-dir).Trim()
  $chk = (@(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and "$((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path)".TrimEnd('\', '/') -in $main, $top } | Select-Object -First 1).migrations.check
  if ($chk) { if ($Show) { "migrations : $chk"; exit 0 }; Write-Host "[check] migrations: $chk"; & $KitCmd.dev gate -Dir $top -Cmd $chk; exit $LASTEXITCODE }
  $all = @(git -C $top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' })
  $masters = @($all | Where-Object { $_ -match '\.xml$' })
  # migrations of another tool (Flyway, Alembic, Prisma, ...): no kit check
  $tool = @(git -C $top ls-files | Where-Object { $_ -match '(?i)(^|/)(migrations?|migrate|flyway|alembic|prisma)/(.+/)?[^/]+\.(sql|py|[cm]?[jt]s|rb|php|exs?|cs|go|java|kt)$' -and $_ -notmatch '(?i)liquibase|changelog|__init__\.py$|\.Designer\.cs$|ModelSnapshot\.cs$' })
  $other = @($all | Where-Object { $_ -notmatch '\.xml$' }) + @(if ($tool.Count) { "$($tool.Count) migration file(s) of another tool ($(($tool | Select-Object -First 3) -join ', ')$(if ($tool.Count -gt 3) { ', ...' }))" })
  if ($other.Count) { Write-Host "[check] migrations UNRUN: $($other -join ', ') has no kit check: set kit.local.json repos[].migrations.check (its validate / dry run); say 'migrations unrun' in the MR." }
  if (-not $masters) { if ($other.Count) { exit 5 }; Write-Host '[check] no migrations in this repo - nothing to check'; exit 0 }
  $lb = Get-Command Invoke-LiquibaseCheck -ErrorAction SilentlyContinue
  if (-not $lb) { Write-Host '[check] migrations UNRUN: the Liquibase check is an extra: run kittool.py extra add liquibase'; exit $(if ($Show) { 0 } else { 5 }) }
  if ($Show) { & $lb -Top $top -Masters $masters -Since $Since -Show; exit 0 }
  $rc = & $lb -Top $top -Masters $masters -Since $Since
  exit $(if (-not $rc -and $other.Count) { 5 } else { $rc })
}

$steps = if ($Step -eq 'quick') { 'compile', 'typecheck', 'lint' } else { @($Step) }
$ran = 0
foreach ($s in $steps) {
  $cmd = $st.commands.$s
  if (-not $cmd -and $s -eq 'test' -and (Test-Path -LiteralPath (Join-Path $st.dir 'package.json'))) { $cmd = "node `"$($KitCmd.spec)`" {tests}" }
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs' -and -not $Show) {
    # no unit-test target: the node spec runner (pure-logic specs) is the extra node-spec
    if (-not (Test-Path -LiteralPath $KitCmd.spec)) { Write-Host '[check] test UNRUN: the node spec runner is an extra: run kittool.py extra add node-spec'; exit 5 }
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
    elseif (-not $Tests) { Write-Host '[check] -Touched: no test file matches the changes: add tests (dev-kit Rules > Tests) or pass -Tests'; exit 1 }
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
  $ct = if ($s -eq 'test' -and $st.stack -match 'maven|gradle|java|kotlin') { Get-Command Test-DockerForContainerTests -ErrorAction SilentlyContinue }   # extra container-tests
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
  if ($cmd -match '^(\.[\\/]mvnw(\.cmd)?|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $cmd = $cmd -replace '^(\.[\\/]mvnw(\.cmd)?|mvn)\s', 'mvnd ' }
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {
    $hash = Hash12 $st.dir.ToLower()
    $tsb = Get-KitPath tsbuild -Create
    $cmd += " --incremental --tsBuildInfoFile `"$(Join-Path $tsb "$hash.tsbuildinfo")`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }
  if ($Show) { "$s : $cmd"; continue }
  $unrun = $false   # 'unrun' (not a pass, exit 5): extra ts-typecheck's verdict on a huge tsc baseline
  $tc = if ($s -eq 'typecheck' -and $cmd -match '\btsc\b') { Get-Command Invoke-Typecheck -ErrorAction SilentlyContinue }   # extra ts-typecheck
  if ($tc) { $r = @(& $tc $cmd)[-1]; if ($r -eq 'unrun') { $unrun = $true; $script:anyUnrun = $true; $rc = 0 } else { $rc = [int]$r } }
  else { & $KitCmd.dev gate -Dir $st.dir -Cmd $cmd; $rc = $LASTEXITCODE }
  $ran++
  if ($rc -and $s -eq 'typecheck' -and $cmd -match '\btsc\b' -and -not $tc) { Write-Host '[check] errors outside your changes fail here: the baseline split is an extra: run kittool.py extra add ts-typecheck' }
  if ($rc) { Write-Host "[check] $s FAILED (exit $rc)"; exit $rc }
  }
  if (-not $Show) { Write-Host "[check] $s $(if ($unrun) { 'UNRUN (not a pass: see above)' } else { 'ok' })" }
}
if (-not $Show -and -not $ran) { Write-Host "[check] nothing to run for $Step" }
if ($script:anyUnrun) { Write-Host '[check] exit 5: typecheck UNRUN (not a pass)'; exit 5 }
exit 0
}

# ---- pipes: wait for MR/PR pipelines (JSON); CI failures go back to the dev agent, not to a doomed merge
function Invoke-Pipes {
param([Parameter(Mandatory)][string[]]$Mrs, [int]$MaxMinutes = 8)
$ErrorActionPreference = 'SilentlyContinue'
$list = @($Mrs -split '\s*,\s*' | Where-Object { $_ })
# any host (lib.ps1 git-host): no head pipeline -> no-ci (the repo's CI adapter finds no CI config) or no-pipeline (one may start)
function State($url) {
  $u = ConvertFrom-MrUrl $url; if (-not $u) { return [ordered]@{ mr = $url; status = 'bad-url' } }
  if ($u.type -eq 'gitlab' -and $url -match '^https?://([^/]+)/') { $env:GITLAB_HOST = $Matches[1] }   # else glab asks gitlab.com
  $m = Invoke-HostVerb 'mr.get' $u -NoMemo
  if (-not $m) { return [ordered]@{ mr = $url; status = 'unknown' } }
  if ($m.state -eq 'merged') { return [ordered]@{ mr = $url; status = 'merged' } }
  $p = $m.head_pipeline
  if (-not $p) { return [ordered]@{ mr = $url; status = $(if ((Invoke-HostVerb 'ci.config' @{ repo = $u.repo; ref = $m.target_branch; type = $u.type }) -eq $false) { 'no-ci' } else { 'no-pipeline' }) } }
  $o = [ordered]@{ mr = $url; status = $p.status }
  if ($p.status -eq 'failed' -and $p.id) {
    $job = @(Invoke-HostVerb 'ci.jobs' @{ repo = $u.repo; id = $p.id; type = $u.type } | Where-Object status -eq 'failed')[0]
    if ($job) {
      $o.job = $job.name
      $trace = ([string](Invoke-HostVerb 'ci.log' @{ repo = $u.repo; id = $job.id; type = $u.type })) -split "`n" | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' -replace '^\S+Z \d+O ', '' }
      $o.error = (@($trace | Where-Object { $_ -match '(?i)error|fail|invalid|exception|\[ERROR\]' } | Select-Object -Last 8) -join "`n")
    }
  }
  $o
}
$start = Get-Date; $end = $start.AddMinutes($MaxMinutes)
do {
  $states = @($list | ForEach-Object { State $_ })
  # a pipeline may still start
  $busy = @($states | Where-Object { $_.status -in 'created', 'pending', 'running', 'waiting_for_resource', 'preparing', 'scheduled', 'no-pipeline', 'unknown' })
  if (-not $busy -or (Get-Date) -gt $end) { break }
  Start-Sleep 30
} while ($true)
[ordered]@{ done = (-not $busy); mrs = $states } | ConvertTo-Json -Depth 4 -Compress
}

# ---- guard: PreToolUse hook for the hard rules; prints a deny or nothing
function Invoke-Guard {
param([switch]$SelfTest, [string]$Json)   # -Json: the hook input without stdin (self-test runs in-process)
$ErrorActionPreference = 'SilentlyContinue'
if ($SelfTest) {
  $da = 'default desktop app'; $rp = 'holds runs in progress'; $hk = 'Hooks must run'; $pb = 'a protected kit branch'
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
  @('P', '& D:\kit\skills\dev-kit\LESSONS.md', $true, $da),
  @('P', 'Invoke-Item .\report.html', $true, $da),
  @('P', 'Start-Process https://example.com', $true, $da),
  @('B', 'xdg-open out/report.html', $true, $da),
  @('B', 'cmd /c start "" report.pdf', $true, $da),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden', $false, ''),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -PassThru -RedirectStandardOutput o.txt', $false, $da),
  @('P', 'Start-Process -FilePath .\r.html', $true, $da),
  @('P', 'Start-Process -Wait .\r.html', $true, $da),
  @('P', 'cd x; ii "out.pdf"', $true, $da),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "resumed agent; . templates.md "Resume brief" was read (see notes.md); & LESSONS.md"', $false, $da),
  @('P', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, $da),
  @('P', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, $da),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, $da),
  @('P', "& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/dev-kit/LESSONS.md | Out-Null", $true, $da),
  @('B', "cd D:/x/{RT} && mkdir -p work/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/g5/body.md; cat >> work/g5/body.md <<'EOF'`n## Review follow-up`n- Plain check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/g5/body.md)`"", $false, $rp),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "never rm the {RT}/work folder" -Source workflow', $false, $rp),
  @('B', 'rm -rf /d/x/{RT}/work', $true, $rp),
  @('P', 'Remove-Item -Recurse -Force "D:\x y\{RT}\work"', $true, $rp),
  @('B', "python -c `"import shutil; shutil.rmtree('/d/x/{RT}/work')`"", $true, $rp),
  @('B', 'cd /d/x/{RT} && rm -rf work', $true, $rp),
  @('P', 'Remove-Item D:\x\.claude\tracking.local.json', $true, 'durable local kit state'),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`ns=open(p).read()  # never git stash here`nE`nnode x.mjs", $false),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`nE`ngit stash list >/dev/null; cp a.ts /tmp/a.bak", $false),
  @('B', 'git push origin +HEAD:main', $true, 'force-push'),
  @('P', 'git -C x push origin +f/CU-1-x', $true, 'force-push'),
  @('B', 'git push origin HEAD:main', $false, 'force-push'),
  @('B', 'git push -fu origin main', $true, 'force-push'),
  @('B', 'git -C "{KIT}" push origin --force-with-lease HEAD:extras', $true, $pb),
  @('P', 'git -C "{KIT}" push origin ":extras"', $true, $pb),
  @('B', 'cd "{KIT}" && git push origin --delete "extras"', $true, $pb),
  @('P', 'Set-Location -Path "{KIT}"; git push -d origin main', $true, $pb),
  @('P', 'Push-Location "{KIT}"; git push --mirror origin', $true, $pb),
  @('B', 'git -C "{KIT}" branch -D extras', $true, $pb),
  @('B', 'git -C "{KIT}" branch -f extras HEAD~1', $true, $pb),
  @('P', 'git -C "{KIT}" branch -dr origin/extras', $true, $pb),
  @('P', 'git -C "{KIT}" update-ref -d refs/remotes/origin/extras', $true, $pb),
  @('B', 'git -C "{KIT}" push -u origin HEAD:extras; git -C "{KIT}" branch --show-current', $false, $pb),
  @('B', 'git -C "{KIT}" push origin --delete kit/build-x; git -C "{KIT}" branch -D kit/main-x', $false, $pb),
  @('B', 'git -C /nowhere/repo push origin --delete main; git -C /nowhere/repo branch -D develop', $false, $pb),
  @('B', 'git -C /nowhere/repo push origin --force-with-lease HEAD:extras', $false, $pb),
  @('P', 'git -C "{KIT}" commit -m "never git push origin --delete main"', $false, $pb),
  @('B', 'git commit -n -m "x"', $true, $hk),
  @('B', 'git -c core.hooksPath=/dev/null commit -m x', $true, $hk),
  @('B', 'git commit --no-edit --amend', $false, $hk),
  @('P', 'git commit -m "use -n for a dry run"', $false, $hk),
  @('B', 'git log -n 3; git commit -m x', $false, $hk)
  )
  $env:KIT_GUARD_SELFTEST_ACTIVE = '1'
  $fail = 0
  foreach ($c in $cases) {
    $tool = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]
    $json = @{ tool_name = $tool; tool_input = @{ command = $c[1].Replace('{RT}', '.runtime').Replace('{KIT}', (Split-Path (Split-Path $PSScriptRoot))) } } | ConvertTo-Json -Compress -Depth 4
    $out = (& $PSCommandPath guard -Json $json) -join ''
    $denied = $out -match '"permissionDecision":"deny"' -and $out -match $(if ($c.Count -gt 3) { [regex]::Escape($c[3]) } else { 'git stash is shared' })
    $ok = $denied -eq $c[2]
    if (-not $ok) { $fail++ }
    '{0} {1,-10} {2,-6} {3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $tool, $(if ($c[2]) { 'deny' } else { 'allow' }), ($c[1] -replace "`n", ' \n ')
  }
  "$($cases.Count - $fail)/$($cases.Count) passed"
  exit [int]($fail -gt 0)
}
$stdin = if ($Json) { $Json } elseif ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
if (-not "$stdin".Trim()) { exit 0 }
try { $in = $stdin | ConvertFrom-Json -ErrorAction Stop } catch {
  $one = "$stdin" -replace "[\r\n\t]+", ' '; $one = $one.Substring(0, [math]::Min(300, $one.Length))
  "$((Get-Date).ToString('s'))`t-`tmalformed hook input`t$one" | Add-Content (Get-KitPath guard-log -Create)
  if ($stdin -match '"toolCall"|"conversationId"') {
    @{ decision = 'deny'; reason = 'kit guard: hook input not JSON (logged to guard.log); retry' } | ConvertTo-Json -Compress
  } else {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = 'kit guard: hook input not JSON (logged to guard.log); retry' } } | ConvertTo-Json -Compress -Depth 4
  }
  exit 0
}
$isGravity = [bool]($in.toolCall -or $in.conversationId)
$cmd = if ($in.tool_input.command) { [string]$in.tool_input.command }
       elseif ($in.toolCall.args.CommandLine) { [string]$in.toolCall.args.CommandLine }
       elseif ($in.toolCall.args.command) { [string]$in.toolCall.args.command }
       elseif ($in.CommandLine) { [string]$in.CommandLine }
       else { '' }
if (-not $cmd) {
  if ($isGravity) { @{ decision = 'allow' } | ConvertTo-Json -Compress }
  exit 0
}
$K = $PSScriptRoot
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path $K 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($kc.protectedBranchesMode -eq 'replace') { $protected = @() }; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  if ($in.session_id) {   # test runs must not raise a guard WATCH
    $one = $raw -replace "[\r\n\t]+", " // "
    if ($one.Length -gt 2000) { $one = $one.Substring(0, 1000) + ' /*...*/ ' + $one.Substring($one.Length - 1000) }
    "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$one" | Add-Content (Get-KitPath guard-log -Create)
  }
  if ($isGravity) {
    @{ decision = 'deny'; reason = $why } | ConvertTo-Json -Compress
  } else {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  }
  exit 0
}

# quoted text, heredocs and here-strings are data
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
  $inRuntime = $false; $rt = '(' + [regex]::Escape((Split-Path (Get-KitRuntime) -Leaf)) + ')'; $sd = [regex]::Escape($script:KitPathMap.stateDir.Trim('/\'))
  foreach ($seg in DeleteSegments $raw) {
    if ($seg -match '^\s*(cd|Set-Location|sl|pushd|Push-Location)\s') { $inRuntime = $seg -match "$rt([\\/]+work)?[\\/]*\s*`$"; continue }
    if ($seg -notmatch $delWord) { continue }
    if ($seg -match ("($sd([\\/][\w.-]+)*|tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)" + $end)) {
      Deny 'That is durable local kit state (task tracking, learning signals): never delete it. Requests to remove it are for the lead (coordinator).' }
    if ($seg -match 'cleanup\.ps1|orch\.ps1["'']?\s+cleanup') { continue }
    if ($seg -match ("$rt([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*" + $end) -or
        ($inRuntime -and $seg -match '\s[''"]?(\.[\\/])?(work([\\/]+[\w.-]+)?|\*|\.)[\\/]*[''"]?(\s|$)')) {
      $act = @(ActiveWork)
      if ($act.Count) { Deny "The runtime's work/ holds runs in progress ($($act -join ', ') written < 3 h ago): do not delete it. cache/ and logs/ may go; orch.ps1 cleanup prunes old work; a wipe is for the lead (coordinator)." }
    }
  }
}
$tn = if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' }
if (Test-GitStash $raw $tn) { Deny 'git stash is shared across worktrees (another agent can pop it): make a WIP commit (dev.ps1 wt commit -Message "wip: ...")' }
if ($cmd -match '\badb(\.exe)?\b[^|;&]*\bkill-server\b') { Deny 'Never adb kill-server: it drops every lane other agents test on. Reconnect your phone only (adb -s <serial> ...) or ask the lead (swarm.ps1 avd reset).' }
# opening a doc pops up a desktop app instead of reading it
function Test-OpenDoc([string]$text, [string]$tool) {
  $doc = '\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)$'
  # kit script call: the rest is arguments
  $text = [regex]::Replace($text, '(?m)(^|[;{]|&&)\s*&\s+(''[^'']+\.(ps1|py|mjs)''|"[^"]+\.(ps1|py|mjs)"|[^\s;''"]+\.(ps1|py|mjs))(\s.*)?$', '$1')
  if ($tool -ne 'Bash') {
    $cas = CmdAsts $text
    if ($null -ne $cas) {
      foreach ($ca in $cas) {
        $el = @($ca.CommandElements); if (-not $el.Count) { continue }
        $val = { param($e) if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $e.Value } else { $e.Extent.Text.Trim('''"') } }
        if ($ca.InvocationOperator -in 'Ampersand', 'Dot' -and (& $val $el[0]) -match $doc) { return $true }
        # only the opened target counts (first argument or -FilePath / -Path): Start-Process pwsh -RedirectStandardOutput o.txt reads nothing
        $fp = [array]::FindIndex([object[]]$el, [Predicate[object]] { param($x) $x -is [System.Management.Automation.Language.CommandParameterAst] -and $x.ParameterName -match '^(FilePath|Path|LiteralPath)$' })
        $tg = if ($fp -gt 0 -and $fp + 1 -lt $el.Count) { $el[$fp + 1] } else { $el | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | Select-Object -First 1 }
        if ((& $val $el[0]) -match '^(Invoke-Item|ii|Start-Process|start|saps|explorer(\.exe)?|xdg-open|open)$' -and $tg -and (& $val $tg) -match "$doc|^https?://") { return $true }
      }
      return $false
    }
  }
  (StripData $text) -match '(^|[;|({\r\n]|&&)\s*(&|\.|Invoke-Item|ii|Start-Process|start|explorer(\.exe)?|xdg-open|open|cmd(\.exe)?\s+/c\s+start(\s+"")?)\s+([^\s;|&]+\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)|https?://\S+)(\s|;|\||\)|$)'
}
if (Test-OpenDoc $raw $tn) {
  Deny 'That opens the file in its default desktop app instead of reading it. Read it with Get-Content <file> (PowerShell), cat (Bash) or the Read tool.' }
if ($cmd -match '--no-verify|core\.hooksPath=(/dev/null|nul\b|\s|$)|HUSKY=0|SKIP_HOOKS' -or
    $cmd -match '\bgit\b[^|;&\r\n]*\bcommit\b[^|;&\r\n]*\s-[a-zA-Z]*n[a-zA-Z]*(?=\s|$)') { Deny "Hooks must run: commit with $($KitCmd.dev) wt commit; fix what the hook reports." }
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  $p = $push.Value
  if ($p -match '(--force(?![-\w])|\s-[a-zA-Z]*f[a-zA-Z]*(?=\s|$)|\s\+[^\s+])' -or ($p -match '--force' -and $p -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch; on yours: --force-with-lease after dev.ps1 wt sync.'
  }
}
# the kit's clone and its worktrees (git -C / cd target, else the hook's cwd): main and extras never forced, deleted or moved
function GitCommon([string]$d) {
  for (; $d; $d = Split-Path $d) {
    $g = Join-Path $d '.git'
    if (Test-Path -LiteralPath $g -PathType Container) { return [IO.Path]::GetFullPath($g) }
    if ((Test-Path -LiteralPath $g -PathType Leaf) -and (Get-Content -LiteralPath $g -Raw) -match 'gitdir:\s*(.+?)\s*$') { return [IO.Path]::GetFullPath(($Matches[1] -replace '[\\/]worktrees[\\/][^\\/]+[\\/]?$', '')) }
  }
}
if ($cmd -match '\bgit\b[^|;&]*\b(push|branch|update-ref)\b' -and ($kg = GitCommon (Split-Path (Split-Path $K)))) {
  $here = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
  $dirs = @([regex]::Matches($raw, '(?:\s-C|\b(?:cd|chdir|sl|Set-Location|pushd|Push-Location))\s+(?:-(?:Literal)?Path\s+)?(?:"([^"]+)"|''([^'']+)''|([^\s;|&]+))') | ForEach-Object { $x = $_.Groups[1].Value + $_.Groups[2].Value + $_.Groups[3].Value; if ([IO.Path]::IsPathRooted($x)) { $x } else { Join-Path $here $x } })
  if (@(@($(if ($dirs) { $dirs } else { $here })) | Where-Object { (GitCommon $_) -eq $kg }).Count) {
    $u = StripData ([regex]::Replace((StripDocs $raw), '"([^"\s;|&]*)"|''([^''\s;|&]*)''', '$1$2'))   # one-word quotes are refs
    $pr = '^\+?(?:[^:\s]*:)?(?:refs/(?:heads|remotes/[^/\s]+)/|origin/)?(main|extras)$'
    foreach ($m in [regex]::Matches($u, '\bgit\b[^|;&]*\b(push\b|branch\b|update-ref\b)[^|;&]*')) {
      $p = $m.Value; $tk = -split $p; $hit = @($tk | ForEach-Object { if ($_ -match $pr) { $Matches[1] } })[0]
      $bad = switch ($m.Groups[1].Value) {
        'push' { $p -match '--mirror|--prune' -or ($hit -and ($p -match '--force|--delete|\s-[a-zA-Z]*[fd][a-zA-Z]*(?=\s|$)' -or @($tk | Where-Object { $_ -match '^[+:]' -and $_ -match $pr }).Count)) }
        'branch' { $hit -and $p -match '\s(-[a-zA-Z]*[dDfMm][a-zA-Z]*|--delete|--force|--move)(?=\s|$)' }
        default { [bool]$hit } }
      if ($bad) { Deny "$(if ($hit) { $hit } else { 'main / extras' }): a protected kit branch: fast-forward pushes only (rebase on origin first); never force-push, delete or move it (README ""Extras"")." }
    }
  }
}
$gated = $cmd -match 'dev\.ps1["'']?\s+(gate|check)\b|swarm\.ps1["'']?\s+build\b|gate\.ps1|check\.ps1|app-build\.ps1'
$heavy = $cmd -match '(^|[\s;&|(''"])(\.[\\/])?(mvn|mvnd|mvnw(\.cmd)?)(\s[^|;&]*)?\s(compile|test|package|install|verify)\b' -or
        $cmd -match 'gradlew(\.bat)?(\s[^|;&]*)?\s(assemble\w*|build|test\w*|bundle\w*|lint\w*)\b' -or
        $cmd -match '(^|[\s;&|(''"])msbuild(\.exe)?(\s|$)' -or
        $cmd -match '\b(ng\s+(build|test)|dotnet\s+(build|test|publish)|cargo\s+(build|test)|npx\s+(jest|vitest|tsc)\b|npm\s+(run\s+)?(build|test)\b|yarn\s+(build|test)\b|(pnpm|bun)\s+(run\s+)?(build|test)\b)'
if ($heavy -and -not $gated) {
  Deny "Heavy builds/tests go through the memory gate: & $($KitCmd.dev) check -Dir <module> [-Step test -Tests X | -Step build], else dev.ps1 gate -Dir <dir> -Cmd '<cmd>'."
}
# installed extras add rules: Register-KitAdapter 'guard' <name> @{ check = { param($a) <deny reason, @{ note = '<line for the agent>' } or nothing> } }
# ($a: cmd without quoted data, raw, config, hook input); last, so a note's side effect only follows a command that runs
$notes = foreach ($rule in @($KitAdapters.guard.Values | Where-Object { $_ })) { $why = & $rule.check @{ cmd = $cmd; raw = $raw; config = $kc; hook = $in }; if ($why.note) { $why.note } elseif ($why) { Deny $why } }
if ($isGravity) { @{ decision = 'allow' } | ConvertTo-Json -Compress }
elseif ($notes) { @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = (@($notes) -join "`n") } } | ConvertTo-Json -Compress -Depth 4 }
exit 0
}

# ---- tracker: lib.ps1 tracker adapters
function Invoke-Tracker {
  $__trA = @($args); $__trPos = New-Object System.Collections.ArrayList; $__trOpt = @{}
  for ($__i = 0; $__i -lt $__trA.Count; $__i++) {
    $__a = [string]$__trA[$__i]
    if ($__a -match '^-(DryRun|Json)$') { $__trOpt[$Matches[1]] = $true }
    elseif ($__a -match '^-(Type|List|Name|Description|Parent|Assignee|Priority|Text|File)$' -and $__i + 1 -lt $__trA.Count) { $__trOpt[$Matches[1]] = [string]$__trA[++$__i] }
    elseif ($__a -match '^-[A-Za-z]+$') { "tracker: unknown option $__a (options: -Text -File -Name -Description -List -Parent -Assignee -Priority -Type -DryRun -Json)"; exit 2 }
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

# ---- host: the git-host / ci adapters (lib.ps1 git-host) for devtools.py: host <verb> '<args JSON>' | @<json file> -> JSON
function Invoke-Host([Parameter(Mandatory)][string]$Verb, [string]$ArgJson = '{}') {
  $a = $(if ($ArgJson -like '@*') { Get-Content -LiteralPath $ArgJson.Substring(1) -Raw -Encoding utf8 } else { $ArgJson }) | ConvertFrom-Json -AsHashtable
  $global:KitHostFailed = $false; $r = @(Invoke-HostVerb $Verb $a -NoMemo | Where-Object { $null -ne $_ })   # one JSON line; a failed call = null (unknown)
  if (-not $r.Count -and $global:KitHostFailed) { 'null' } elseif ($Verb -in 'mr.list', 'ci.runs', 'ci.jobs') { ConvertTo-Json -InputObject $r -Depth 8 -Compress }
  elseif ($r.Count -eq 1 -and $r[0] -is [string]) { $r[0] } else { ConvertTo-Json -InputObject $(if ($r.Count) { $r[0] } else { $null }) -Depth 8 -Compress }
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced: functions only
  switch ($__verb) {
    'wt' { Invoke-KitVerb Invoke-Wt $__rest }
    'stack' { Invoke-KitVerb Invoke-Stack $__rest }
    'gate' { Invoke-KitVerb Invoke-Gate $__rest }
    'check' { Invoke-KitVerb Invoke-Check $__rest }
    'pipes' { Invoke-KitVerb Invoke-Pipes $__rest }
    'guard' { Invoke-KitVerb Invoke-Guard $__rest }
    'tracker' { Invoke-KitVerb Invoke-Tracker $__rest }
    'host' { Invoke-KitVerb Invoke-Host $__rest }
    'runtime' { if (Get-Command Invoke-Runtime -ErrorAction SilentlyContinue) { Invoke-KitVerb Invoke-Runtime $__rest } else { [Console]::Error.WriteLine('dev.ps1 runtime is an extra: run kittool.py extra add runtimes'); exit 1 } }
    default { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit $(if ($__verb -in '-h', '--help', 'help', '-?') { 0 } else { 2 }) }
  }
}