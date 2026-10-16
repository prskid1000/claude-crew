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
In: kit.local.json + verb parameters. Out: text, or JSON with -Json.
Exit codes: 0 ok · 1 problem (failed check, conflict, blocked) · 2 usage · gate/check: the command's code ·

#>
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
    if (-not $Root) {
      $kcRoot = $null
      try { if ($env:CLAUDE_WT_ROOT -or (Get-KitValue 'worktreeRoots' $null)) { $kcRoot = @($KitConf.WorktreeRoots)[0] } } catch { }
      $Root = if ($kcRoot) { $kcRoot } else { (Split-Path $Repo) + '-wt' }
    }
    $path = Join-Path $Root "$Name-$(Split-Path $Repo -Leaf)"
    if (Test-Path $path) { throw "$path exists: resume there (wt status -Dir $path) or pick another -Name" }
    # a missing configured dep source is an error, no fallback
    $r = $null
    $kc = Join-Path $PSScriptRoot 'kit.local.json'
    if (Test-Path $kc) {
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
    $Dir = Resolve-Wt $Dir
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
  'list' { git -C $Repo worktree list }
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
function First($d, $pattern) { Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
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
    $android = (Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Filter AndroidManifest.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($android) {
      $s = 'android-gradle'
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
  elseif (Has $d '*.sln', '*.csproj', '*.fsproj', '*.vbproj') {
    $projs = Get-ChildItem -LiteralPath $d -Recurse -Depth 3 -Include *.csproj, *.fsproj, *.vbproj -File -ErrorAction SilentlyContinue | Select-Object -First 50
    $legacy = [bool]($projs | Where-Object { -not (Select-String -LiteralPath $_.FullName -Pattern '<Project\s+Sdk=' -Quiet) } | Select-Object -First 1)
    if ($legacy) {
      $s = 'dotnet-msbuild'
      # msbuild: on PATH only in a Developer prompt
      $msb = 'msbuild'; $vst = 'vstest.console.exe'
      $vswhere = if ($KitIsWindows -and ${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
      if ($vswhere -and (Test-Path $vswhere)) {
        if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null)[0]; if ($f) { $msb = "`"$f`"" } }
        if (-not (Get-Command vstest.console.exe -ErrorAction SilentlyContinue)) { $f = @(& $vswhere -latest -products * -find '**\TestPlatform\vstest.console.exe' 2>$null)[0]; if ($f) { $vst = "`"$f`"" } }
      }
      $c.compile = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Debug"
      $c.build = "$msb `"{sln}`" /m:2 /v:q /nologo /p:Configuration=Release"
      $c.test = "$vst {tests}"
    } else {
      $s = 'dotnet'
      $c.compile = 'dotnet build "{sln}" -nologo -v q -m:2'
      $c.test = 'dotnet test "{sln}" -nologo --filter "{tests}"'
      $c.format = 'dotnet format "{sln}" --verify-no-changes'
      $c.build = 'dotnet build "{sln}" -nologo -v q -c Release'
      if (Has $d '*.csproj', '*.fsproj') { $c.run = 'dotnet run --urls http://localhost:{port}' }
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
    if ((ReadText (Join-Path $d 'Makefile')) -match '(?m)^test\s*:') { $c.test = 'make test' }
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
if (-not $hit) { throw "No known stack under $Dir (up to the git root): add a .claude-stack.json" }
if ($Json) { $hit | ConvertTo-Json -Depth 4 }
else {
  "stack: $($hit.stack)   dir: $($hit.dir)$(if ($hit.solution) { "   solution: $($hit.solution)" })"
  $hit.commands.PSObject.Properties | Where-Object Value | ForEach-Object { '  {0,-9} {1}' -f $_.Name, $_.Value }
}
}

# ---- gate: machine-wide memory gate; exit = the command's code, 3 = not started in time
function Invoke-Gate {
param(
  [Parameter(Mandatory)][string]$Cmd,
  [string]$Dir = (Get-Location).Path,
  [int]$WaitMinutes = 90,
  [double]$KeepFreeGB = $(if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { -1 }),   # -1 = 15% of RAM, min 6 GB
  [double]$NeedGB = 0,
  [int]$MaxParallel = 0
)
# heap caps replace inherited -Xmx
$HeapMinGB = [double](Get-KitSetting 'gate.heapMinGB' 4)
if ($KeepFreeGB -lt 0) { $KeepFreeGB = [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) }
$StartGB = @{ gradle = [double](Get-KitSetting 'gate.startHeapGB.gradle' 12); maven = [double](Get-KitSetting 'gate.startHeapGB.maven' 8); node = [double](Get-KitSetting 'gate.startHeapGB.node' 4) }
$mavenKeep = ([string]$env:MAVEN_OPTS -replace '-Xm[xs]\S+|-XX:\+Use\w+GC|-XX:MaxMetaspaceSize=\S+', '' -replace '\s+', ' ').Trim()
$nodeKeep = ([string]$env:NODE_OPTIONS -replace '--max-old-space-size=\d+', '' -replace '\s+', ' ').Trim()
if (-not $env:GRADLE_OPTS) { $env:GRADLE_OPTS = '-Dorg.gradle.workers.max=4' }
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
$peaks = @($samples | ForEach-Object { [double]$_.gb }); $peakMax = ($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum
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

$jvmKind = $kind -like 'maven*'
$nodeKind = $kind -in @('ng-test', 'web-build', 'js-test', 'tsc-lint', 'rn-bundle', 'e2e')
$gradleKind = $kind -in @('android-build', 'android-test', 'gradle')
$heap = 0
if ($jvmKind -or $nodeKind -or $gradleKind) {
  # G1 free-ratios let the learned peak fall
  $startHeap = if ($gradleKind) { $StartGB.gradle } elseif ($jvmKind) { $StartGB.maven } else { $StartGB.node }   # not $startGB: same variable
  $maxGB = [math]::Max($startHeap, 8)
  $heap = if ($peaks.Count -ge 2) { [int][math]::Ceiling($peakMax * 1.25) } else { $startHeap }
  $heap = [math]::Min($maxGB, [math]::Max($HeapMinGB, $heap))
  if ($NeedGB -le 0 -and $peaks.Count -lt 2) { $need = [math]::Max($need, $heap + 0.5) }   # no history: the heap can fill up
}
function Set-HeapEnv([int]$gb) {
  if ($jvmKind) { $env:MAVEN_OPTS = "$mavenKeep -Xmx${gb}g -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000".Trim() }
  if ($nodeKind) { $env:NODE_OPTIONS = "$nodeKeep --max-old-space-size=$($gb * 1024)".Trim() }
  if ($gradleKind -and $script:Cmd -notmatch 'org\.gradle\.jvmargs') {
    # a -D overrides org.gradle.jvmargs
    $script:Cmd = ([regex]'(gradlew(\.bat)?|\bgradle)(?=\s|$)').Replace($script:Cmd, "`$1 `"-Dorg.gradle.jvmargs=-Xmx${gb}g -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000 -Dfile.encoding=UTF-8`"", 1)
  }
}

function Get-OwnerName([string]$Leaf, [string]$Repo) {
  if ($Repo -and $Leaf.Length -gt $Repo.Length + 1 -and $Leaf.EndsWith("-$Repo", [StringComparison]::OrdinalIgnoreCase)) { return $Leaf.Substring(0, $Leaf.Length - $Repo.Length - 1) }
  ($Leaf -split '-')[0]
}
$ownerRoot = if ($top) { Split-Path $top -Leaf } else { Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf }
$owner = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { Get-OwnerName $ownerRoot $(if ($top) { $repoName } else { '' }) }
$heapBase = $heap
# a smaller heap thrashes in GC
$heapFloor = if ($heap -gt 0 -and $peaks.Count -ge 2) { [math]::Min($heapBase, [math]::Max($HeapMinGB, [int][math]::Ceiling($peakMax * 1.1))) } else { $HeapMinGB }
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
    if ($left -ge $KeepFreeGB -and (($MaxParallel -le 0) -or ($s.Running -lt $MaxParallel))) {
      if ($heap -gt 0) { Set-HeapEnv $heap }
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
  while (-not $proc.HasExited) { $peak = [math]::Max($peak, (Get-TreeGB $proc.Id (Get-Procs))); Start-Sleep -Seconds 5 }
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

# ---- check: gated steps of the stack; exit = the first failing step's code (3 gate, 4 no Docker, 5 UNRUN)
function Invoke-Check {
param(
  [string]$Dir = (Get-Location).Path,
  [ValidateSet('quick', 'compile', 'typecheck', 'lint', 'test', 'build', 'format', 'migrations')][string]$Step = 'quick',
  [string]$Tests = '',
  [string]$Files = '',
  [switch]$AllTests,
  [string]$Since = (Get-Date).AddDays(-14).ToString('yyyyMMdd000000'),
  [switch]$Show,
  [switch]$Touched,
  [switch]$RealAngular
)
$ErrorActionPreference = 'Stop'
$script:anyUnrun = $false
$K = $PSScriptRoot
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
# TS5103: one retry with a temp tsconfig; fail only on changed files + config errors
function Invoke-Typecheck([string]$TcCmd) {
  $top = git -C $st.dir rev-parse --show-toplevel 2>$null
  $top = if ($top) { [IO.Path]::GetFullPath("$top".Trim()) } else { $null }
  $repo = Split-Path $(if ($top) { $top } else { $st.dir }) -Leaf
  $log = Join-Path (Get-KitPath logs -Create) "typecheck-$repo-$(Get-Date -Format yyyyMMdd-HHmmss).log"
  $proj = if ($TcCmd -match '\s-p\s+"?([^"\s]+)"?') { $Matches[1] } else { 'tsconfig.json' }
  $base = [IO.Path]::GetFullPath((Join-Path $st.dir $proj))
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
  # the marker skips a doomed first run (~1 GB)
  $igd = if ($raw -match '"ignoreDeprecations"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
  $flag = Join-Path (Get-KitPath tsbuild -Create) "ts5103.$(Hash12 "$($base.ToLower())|$igd|$tsVer").flag"
  if (Test-Path -LiteralPath $flag) {
    $out = @()
    Write-Host "[check] TS5103 known (marker $(Split-Path $flag -Leaf)): skipping the first tsc run"
  } else {
    & $KitCmd.dev gate -Dir $st.dir -Cmd "$TcCmd > `"$log`" 2>&1"
    $rc = $LASTEXITCODE
    $out = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $nErr = @($out -match '^(.+?\(\d+,\d+\): )?error TS\d+').Count
    if (-not @($out -match 'error TS5103').Count) {
      if ($rc -and $nErr -gt $script:TypecheckUnrunAbove) { return (Split-TypecheckErrors $out $rc $null $null) }
      $out | ForEach-Object { Write-Host $_ }
      if ($rc -and $out.Count) { Write-Host "[check] typecheck log: $log" }
      return $rc
    }
    Set-Content -LiteralPath $flag -Value "$base | ignoreDeprecations '$igd' | typescript $tsVer"
  }
  $tsCfg = [ordered]@{ extends = $base.Replace('\', '/'); compilerOptions = @{ ignoreDeprecations = $ver } }
  # else tsc includes the temp config's folder
  if ($raw -notmatch '"(files|include)"\s*:') {
    $pd = (Split-Path $base).Replace('\', '/')
    $ex = @('node_modules', 'bower_components', 'jspm_packages')
    try { $j = $raw | ConvertFrom-Json; if ($j.exclude) { $ex = @($j.exclude) } } catch {}
    $tsCfg.include = @("$pd/**/*")
    $tsCfg.exclude = @($ex | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { "$pd/$_" } })
  }
  $hash = Hash12 $st.dir.ToLower()
  $tmp = Join-Path (Get-KitPath cache -Create) "tsconfig.ts5103.$hash.$PID.json"
  $tsb = Join-Path (Get-KitPath tsbuild -Create) "$hash.ts5103.tsbuildinfo"
  $tsc = if ($bin) { "`"$bin`"" } else { 'npx tsc' }
  Write-Host "[check] typecheck TS5103 fallback: temp tsconfig (ignoreDeprecations $ver), $(if ($bin) { $bin } else { 'npx tsc' })"
  $fbCmd = "$tsc -p `"$tmp`" --noEmit --pretty false --incremental --tsBuildInfoFile `"$tsb`" >> `"$log`" 2>&1"
  $fbStart = [DateTimeOffset]::Now
  try {
    $tsCfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    & $KitCmd.dev gate -Dir $st.dir -Cmd $fbCmd
    $rc = $LASTEXITCODE
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  $out2 = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Skip $out.Count })
  if ($rc -eq 3 -and -not $out2.Count) { return 3 }
  if (@($out2 -match 'error TS5103').Count) { Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue }   # no cure: next run starts over
  return (Split-TypecheckErrors $out2 $rc $fbCmd $fbStart)
}

# a huge baseline (node_modules mismatch) is UNRUN, not a pass
function Split-TypecheckErrors($out2, [int]$rc, [string]$GateCmd, $Since) {
  $changed = @(Get-ChangedFiles | ForEach-Object { $_.ToLower() })
  $mine = [Collections.Generic.List[string]]::new(); $mineN = 0; $baseN = 0; $baseFiles = @{}; $cur = $null; $blocks = 0
  foreach ($l in $out2) {
    if ($l -match '^(?<f>.+?)\(\d+,\d+\): error TS(?<code>\d+)' -or $l -match '^error TS(?<code>\d+)') {
      $blocks++
      $f = $Matches.f; $isCfg = (-not $f) -or $Matches.code -match '^[56]\d{3}$' -or $Matches.code -eq '18003'
      $full = if ($f) { [IO.Path]::GetFullPath((Join-Path $st.dir $f)).ToLower() } else { $null }
      if ($isCfg -or $changed -contains $full) { $cur = 'mine'; $mineN++ } else { $cur = 'base'; $baseN++; $baseFiles[$full] = 1 }
    }
    elseif (-not ($cur -and $l -match '^\s')) { $cur = $null }
    if ($cur -eq 'mine') { $mine.Add($l) }
  }
  $mine | ForEach-Object { Write-Host $_ }
  Write-Host "BASELINE: $baseN errors outside your changes ($($baseFiles.Count) files; not failing; log: $log)"
  if ($mineN) { Write-Host "[check] typecheck: $mineN errors in your changed files (or config)"; return 1 }
  if ($rc -and -not $blocks) { $out2 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }; return $rc }
  if ($baseN -gt $script:TypecheckUnrunAbove) {
    $tgt = Get-WtTarget; if (-not $tgt) { $tgt = '<target>' }
    Write-Host "[check] typecheck UNRUN: $baseN baseline errors (> $script:TypecheckUnrunAbove): the linked node_modules do not match this branch, real errors hide there. Say 'typecheck unrun' in the MR; the lead sets kit.local.json linkFromByTarget.$tgt to a checkout with matching node_modules."
    return 'unrun'
  }
  if ($rc -and $GateCmd) { Set-GateSampleOk $GateCmd $Since }
  return 0
}
$script:TypecheckUnrunAbove = 200

function Set-GateSampleOk([string]$GateCmd, [DateTimeOffset]$Since) {
  $hf = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'history.json'
  if (-not (Test-Path -LiteralPath $hf)) { return }
  $pre = if ($GateCmd.Length -gt 60) { $GateCmd.Substring(0, 60) } else { $GateCmd }
  $fromUtc = $Since.UtcDateTime.AddSeconds(-2)
  $mx = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate'); $got = $false
  try {
    $got = Lock-Gate $mx
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

# without Docker, container tests burn minutes, then fail like a code bug
function Test-DockerForContainerTests {
  $names = @($Tests -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { (($_ -split '#')[0] -split '\.')[-1] })
  $need = @($names | Where-Object { $_ -match '(Container|IT)(Test)?$' }).Count -gt 0
  if (-not $need) {
    $bf = @(@('pom.xml', 'build.gradle', 'build.gradle.kts', 'package.json', 'pyproject.toml', 'requirements.txt', 'go.mod') | ForEach-Object { Join-Path $st.dir $_ }) + @(Get-ChildItem -LiteralPath $st.dir -Filter *.csproj -File -ErrorAction SilentlyContinue | ForEach-Object FullName) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
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
  $why = 'neither docker nor podman is on PATH'   # Colima: the docker CLI; Podman for Testcontainers: DOCKER_HOST = its socket
  foreach ($x in 'docker', 'podman') {
    if (-not (Get-Command $x -ErrorAction SilentlyContinue)) { continue }
    $r = Invoke-KitExe $x @('info') 5; if (-not $r.code) { Write-Host "[check] container tests: $x is running"; return 0 }
    $why = "$x info failed: $(@("$($r.err)" -split "`n" | Where-Object { $_.Trim() })[0])"
  }
  Write-Host "[check] container tests need a container engine, and none answers ($why)."
  Write-Host "[check] Start it (Docker Desktop / docker service / podman machine start / colima start), wait until '<engine> info' answers, re-run; a test failing on a down engine is no code failure."
  return 4
}

# repos[].migrations.check runs (in the worktree); else Liquibase XML -> lbcheck; any other tool or changelog format = UNRUN (exit 5)
if ($Step -eq 'migrations') {
  $top = (git -C $st.dir rev-parse --show-toplevel).Trim()
  $main = Split-Path (git -C $top rev-parse --path-format=absolute --git-common-dir).Trim()
  $chk = (@(Get-KitValue 'repos' @()) | Where-Object { $_.checkout -and "$((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path)".TrimEnd('\', '/') -in $main, $top } | Select-Object -First 1).migrations.check
  if ($chk) { if ($Show) { "migrations : $chk"; exit 0 }; Write-Host "[check] migrations: $chk"; & $KitCmd.dev gate -Dir $top -Cmd $chk; exit $LASTEXITCODE }
  $all = @(git -C $top ls-files '*master.xml' '*master.yaml' '*master.yml' '*master.json' '*master.sql' | Where-Object { $_ -match '(?i)liquibase|changelog' })
  $masters = @($all | Where-Object { $_ -match '\.xml$' })
  $det = & (Get-Python) -X utf8 $KitCmd.devtools migrations detect --repo $top 2>$null | ConvertFrom-Json -AsHashtable
  $other = @($all | Where-Object { $_ -notmatch '\.xml$' }) + @(if ($det) { $det.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value) files)" } })
  if ($other.Count) { Write-Host "[check] migrations UNRUN: $($other -join ', ') has no kit check: set kit.local.json repos[].migrations.check (its validate / dry run); say 'migrations unrun' in the MR." }
  if (-not $masters) { if ($other.Count) { exit 5 }; Write-Host '[check] no migrations in this repo - nothing to check'; exit 0 }
  $sinceDate = try { [datetime]::ParseExact($Since.Substring(0, 8), 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { (Get-Date).AddDays(-14).ToString('yyyy-MM-dd') }
  $env:LBCHECK_CHANGED = (@(git -C $top log --since=$sinceDate --name-only --pretty=format: -- '*.xml') + @(git -C $top diff --name-only HEAD -- '*.xml') | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique) -join '|'
  $rc = 0
  $mine = @($masters | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $top $_)) })
  $under = @($mine | Where-Object { $_.StartsWith($st.dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
  if ($under.Count) { $mine = $under }
  foreach ($full in $mine) {
    $a = @($KitCmd.devtools, 'lbcheck', $full, $Since)
    $py = Get-Python
    if ($Show) { "$py $($a -join ' ')"; continue }
    Write-Host "[check] liquibase: $full (files since $Since)"
    & $py @a; if ($LASTEXITCODE) { $rc = $LASTEXITCODE }
  }
  exit $(if (-not $rc -and $other.Count) { 5 } else { $rc })
}

$steps = if ($Step -eq 'quick') { 'compile', 'typecheck', 'lint' } else { @($Step) }
$ran = 0
foreach ($s in $steps) {
  $cmd = $st.commands.$s
  if (-not $cmd -and $s -eq 'test' -and (Test-Path -LiteralPath (Join-Path $st.dir 'package.json'))) { $cmd = "node `"$($KitCmd.spec)`" {tests}" }
  if (-not $cmd) { if ($Step -ne 'quick') { Write-Host "[check] $($st.stack) has no '$s' step"; exit 2 }; continue }
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs') { Write-Host '[check] no unit-test target: spec.mjs runs specs under node (DOM: the project''s jsdom if any; TestBed/fakeAsync: NOT RUN)' }
  if ($Touched -and $s -eq 'test') {
    # CI may skip tests
    $chg = @(Get-ChangedFiles)
    $lay = Get-KitSetting "tests.$($st.stack)" $null
    $pat = if ($lay -and $lay.testFor) { @($lay.testFor) } else { switch -Regex ($st.stack) { 'maven|gradle|android|kotlin|java' { '{name}Test', '{name}Tests', '{name}IT' } 'dotnet|msbuild' { '{name}Tests', '{name}Test' } 'python' { 'test_{name}', '{name}_test' } 'go' { '{name}_test' } default { '{name}.spec', '{name}.test' } } }
    $tracked = @(git -C $st.dir ls-files 2>$null)
    $found = foreach ($cf in $chg) {
      $n = [IO.Path]::GetFileNameWithoutExtension($cf) -replace '\.(spec|test)$', ''
      if ($cf -match '\.(spec|test)\.\w+$' -or $n -match '(Test|Tests|IT|_test)$' -or $n -match '^test_') { $cf; continue }
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
  if ($s -eq 'test' -and $cmd -match 'spec\.mjs' -and $cmd -notmatch '--real-angular') {
    # the @angular/core stub breaks @angular/forms
    $why = if ($RealAngular) { '-RealAngular' } else {
      $hit = @(@($Tests -split '[,\s]+' | Where-Object { $_ }) | ForEach-Object { Join-Path $st.dir $_ } | Where-Object { $_ -match '\.(spec|test)\.\w+$' -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
              Where-Object { (Get-Content -LiteralPath $_ -Raw) -match '[''"]@angular/forms[''"]' } | Select-Object -First 1)
      if ($hit.Count) { "$(Split-Path $hit[0] -Leaf) imports @angular/forms" }
    }
    if ($why) { $cmd += ' --real-angular'; Write-Host "[check] node-spec with the real @angular/core ($why)" }
  }
  if ($s -eq 'test' -and $st.stack -match 'maven|gradle|java|kotlin') {
    $rc = Test-DockerForContainerTests
    if ($rc -and -not $Show) { exit $rc }
  }
  if ($cmd -match '\{sln\}') {
    $sln = @(Get-ChildItem -LiteralPath $st.dir -Filter *.sln -File -ErrorAction SilentlyContinue)
    if (-not $sln.Count) { $sln = @(Get-ChildItem -LiteralPath $st.dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' }) }
    if ($sln.Count -ne 1) { throw "[check] $($st.dir): expected one .sln (or project file), found $($sln.Count): -Dir to its folder" }
    $cmd = $cmd.Replace('{sln}', $sln[0].FullName)
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
  if ($st.solution) { $cmd = $cmd -replace '\{sln\}', $st.solution }
  if ($cmd -match '^(\.[\\/]mvnw(\.cmd)?|mvn)\s' -and (Get-Command mvnd -ErrorAction SilentlyContinue)) { $cmd = $cmd -replace '^(\.[\\/]mvnw(\.cmd)?|mvn)\s', 'mvnd ' }
  if ($cmd -match '\btsc\b' -and $cmd -notmatch 'incremental|tsBuildInfoFile') {
    $hash = Hash12 $st.dir.ToLower()
    $tsb = Get-KitPath tsbuild -Create
    $cmd += " --incremental --tsBuildInfoFile `"$(Join-Path $tsb "$hash.tsbuildinfo")`""
  }
  if ($cmd -match 'gradlew' -and $cmd -notmatch 'build-cache') { $cmd += ' --build-cache' }
  if ($Show) { "$s : $cmd"; continue }
  $unrun = $false
  if ($s -eq 'typecheck' -and $cmd -match '\btsc\b') { $r = @(Invoke-Typecheck $cmd)[-1]; if ($r -eq 'unrun') { $unrun = $true; $script:anyUnrun = $true; $rc = 0 } else { $rc = [int]$r } }
  else { & $KitCmd.dev gate -Dir $st.dir -Cmd $cmd; $rc = $LASTEXITCODE }
  $ran++
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
# any host (lib.ps1 section 5): no head pipeline -> no-ci (the repo's CI adapter finds no CI config) or no-pipeline (one may start)
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
param([switch]$SelfTest)
$ErrorActionPreference = 'SilentlyContinue'
if ($SelfTest) {
  $da = 'default desktop app'; $rp = 'holds runs in progress'; $le = 'local env'; $hk = 'Hooks must run'
  $cases = @(
  @('P', 'git stash', $true),
  @('P', 'git -C x stash pop', $true),
  @('P', '& "C:\Program Files\Git\bin\git.exe" stash list', $true),
  @('P', '$s = $(git stash list); $s', $true),
  @('P', 'pwsh -NoProfile -Command "git stash"', $true),
  @('B', 'git stash', $true),
  @('B', 'cd repo && git -C x stash pop', $true),
  @('B', 'FOO=1 git --no-pager stash show', $true),
  @('B', "bash -c 'git stash'", $true),
  @('P', 'git commit -m "fix: never git stash here"', $false),
  @('P', 'git commit -m "say `"git stash`" never"', $false),
  @('P', "`$m = @'`nnever run git stash`n'@`ngit commit -m `$m", $false),
  @('P', "Write-Output 'git stash is blocked'", $false),
  @('B', "git commit -m `"`$(cat <<'EOF'`nfix: never git stash in worktrees`nEOF`n)`"", $false),
  @('B', "cat > note.md <<EOF`ngit stash is shared`nEOF", $false),
  @('B', 'git checkout fix/stash-list', $false),
  @('B', 'echo done # not git stash', $false),
  @('P', '& D:\kit\skills\dev-kit\LESSONS.md', $true, $da),
  @('P', '& "C:\x y\notes.txt"', $true, $da),
  @('P', 'Invoke-Item .\report.html', $true, $da),
  @('P', 'Start-Process .\out\kit-flow.html', $true, $da),
  @('P', 'Start-Process https://example.com', $true, $da),
  @('B', 'xdg-open out/report.html', $true, $da),
  @('B', 'cmd /c start "" report.pdf', $true, $da),
  @('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden', $false, ''),
  @('P', 'cd x; ii "out.pdf"', $true, $da),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "resumed agent; . templates.md "Resume brief" was read (see notes.md); & LESSONS.md"', $false, $da),
  @('P', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, $da),
  @('P', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, $da),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text "X2 (a b): fixed via helper buildX plus unit test; MR merged on first run, no retries" -Ref B-1 -Source workflow', $false, $da),
  @('P', "& D:/kit/learn.ps1 -Skill dev-kit -Kind friction -Text `"Stopped agent left a commit; merge reported via devtools.py 'merged' but not verified`" -Ref repo!1 -Source workflow`n& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"recovery worked`" -Ref repo!1", $false, $da),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, $da),
  @('P', "& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/dev-kit/LESSONS.md | Out-Null", $true, $da),
  @('B', "cd /d/x/{RT}/work/qa-runs; mkdir -p 2026-01-01-run && cd 2026-01-01-run; GWS=`$(python -c `"import shutil;print(shutil.which('gws'))`"); for p in A:1 B:2; do c=`${p%%:*}; `"`$GWS`" drive files export -o `$c.txt >/dev/null 2>&1; done", $false, $rp),
  @('B', "cd D:/x/{RT} && mkdir -p work/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/g5/body.md; cat >> work/g5/body.md <<'EOF'`n## Review follow-up`n- Plain check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/g5/body.md)`"", $false, $rp),
  @('P', '& D:/kit/learn.ps1 -Skill dev-kit -Text "never rm the {RT}/work folder" -Source workflow', $false, $rp),
  @('B', 'rm -rf /d/x/{RT}/work', $true, $rp),
  @('P', 'Remove-Item -Recurse -Force "D:\x y\{RT}\work"', $true, $rp),
  @('B', "python -c `"import shutil; shutil.rmtree('/d/x/{RT}/work')`"", $true, $rp),
  @('B', 'cd /d/x/{RT} && rm -rf work', $true, $rp),
  @('P', 'Remove-Item D:\x\.claude\tracking.local.json', $true, 'durable local kit state'),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`ns=open(p).read()  # never git stash here`nE`nnode x.mjs", $false),
  @('B', "cd repo; python3 - <<'E'`np='a.ts'`nE`ngit stash list >/dev/null; cp a.ts /tmp/a.bak", $true),
  @('P', 'git -C x push origin localenv/shop', $true, $le),
  @('B', 'git push -u origin HEAD:localenv/shop', $true, $le),
  @('P', 'git push -u origin f/CU-1-x', $false, $le),
  @('P', 'cd api; .\mvnw.cmd spring-boot:run', $true, $le),
  @('B', 'npx ng serve --port 4200', $true, $le),
  @('B', 'yarn start', $true, $le),
  @('P', 'dotnet watch run', $true, $le),
  @('P', '& D:/kit/skills/local-env/localenv.ps1 up -Env shop', $false, $le),
  @('P', 'git commit -m "fix: ng serve proxy"', $false, $le),
  @('B', 'rg "ng serve" src', $false, $le),
  @('B', 'git log -S bootRun --oneline', $false, $le),
  @('B', 'npm run dev:build', $false, $le),
  @('P', 'dotnet run -- migrate', $false, $le),
  @('B', 'cd web && yarn start', $true, $le),
  @('B', 'git push origin --delete localenv/shop', $false, $le),
  @('B', 'git push origin +HEAD:main', $true, 'force-push'),
  @('P', 'git -C x push origin +f/CU-1-x', $true, 'force-push'),
  @('B', 'git push origin HEAD:main', $false, 'force-push'),
  @('B', 'git commit -n -m "x"', $true, $hk),
  @('P', 'git -C x commit -nm "x"', $true, $hk),
  @('B', 'git -c core.hooksPath=/dev/null commit -m x', $true, $hk),
  @('B', 'git commit --no-edit --amend', $false, $hk),
  @('P', 'git commit -m "use -n for a dry run"', $false, $hk),
  @('B', 'git log -n 3; git commit -m x', $false, $hk)
  )
  $env:KIT_GUARD_SELFTEST_ACTIVE = '1'
  $fail = 0
  foreach ($c in $cases) {
    $tool = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]
    $json = @{ tool_name = $tool; tool_input = @{ command = $c[1].Replace('{RT}', '.runtime') } } | ConvertTo-Json -Compress -Depth 4
    $out = ($json | pwsh -NoProfile -NonInteractive -File $PSCommandPath guard) -join ''
    $denied = $out -match '"permissionDecision":"deny"' -and $out -match $(if ($c.Count -gt 3) { [regex]::Escape($c[3]) } else { 'git stash is shared' })
    $ok = $denied -eq $c[2]
    if (-not $ok) { $fail++ }
    '{0} {1,-10} {2,-6} {3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $tool, $(if ($c[2]) { 'deny' } else { 'allow' }), ($c[1] -replace "`n", ' \n ')
  }
  "$($cases.Count - $fail)/$($cases.Count) passed"
  exit [int]($fail -gt 0)
}
$stdin = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
if (-not "$stdin".Trim()) { exit 0 }
try { $in = $stdin | ConvertFrom-Json -ErrorAction Stop } catch {
  $one = "$stdin" -replace "[\r\n\t]+", ' '; $one = $one.Substring(0, [math]::Min(300, $one.Length))
  "$((Get-Date).ToString('s'))`t-`tmalformed hook input`t$one" | Add-Content (Get-KitPath guard-log -Create)
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = 'kit guard: hook input not JSON (logged to guard.log); retry' } } | ConvertTo-Json -Compress -Depth 4
  exit 0
}
$cmd = [string]$in.tool_input.command
if (-not $cmd) { exit 0 }
$K = $PSScriptRoot
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path $K 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($kc.protectedBranchesMode -eq 'replace') { $protected = @() }; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  if ($in.session_id) {   # test runs must not raise a guard WATCH
    $one = $raw -replace "[\r\n\t]+", " // "
    if ($one.Length -gt 2000) { $one = $one.Substring(0, 1000) + ' /*...*/ ' + $one.Substring($one.Length - 1000) }
    "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$one" | Add-Content (Get-KitPath guard-log -Create)
  }
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
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
    return $w -eq 'stash'
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
  $t -match '(?m)(^|[;&|({`\n]|\$\()\s*(\w+=\S*\s+)*(\S*[\\/])?git(\.exe)?\s+((-C|-c|--git-dir|--work-tree|--namespace)\s+\S+\s+|-\S+\s+)*stash\b'
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
        if ((& $val $el[0]) -match '^(Invoke-Item|ii|Start-Process|start|saps|explorer(\.exe)?|xdg-open|open)$' -and @($el | Select-Object -Skip 1 | Where-Object { (& $val $_) -match "$doc|^https?://" }).Count) { return $true }
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
  if ($p -match '(--force(?![-\w])|\s-f\b|\s\+[^\s+])' -or ($p -match '--force' -and $p -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch; on yours: --force-with-lease after dev.ps1 wt sync.'
  }
}
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  if ($push.Value -match '(^|[\s:/])localenv/' -and $push.Value -notmatch '\s--delete\b|\s-d\s|\s:localenv/') { Deny 'localenv/<env> is a local env branch (all agents'' layers merged): never push it. Push your branch; localenv.ps1 deploy -Dir <worktree> takes it.' }
}
if (($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1' -or $kc.localEnv) -and $cmd -notmatch 'localenv\.ps1') {
  $server = '^(\.?[\\/])?(mvnw(\.cmd)?|mvn)\b.*\bspring-boot:run\b|^(\.?[\\/])?(gradlew(\.bat)?|gradle)\b.*\bbootRun\b|^(npx\s+)?ng\s+serve\b|^dotnet\s+(run|watch)\b(?!.*\s--\s)|^npx\s+(react-native|expo)\s+start\b|^(python\d?\s+)?manage\.py\s+runserver\b|^uvicorn\s|^flask\s+run\b|^(npm|yarn|pnpm|bun)\s+(run\s+)?(dev|start|serve)\s*$'
  foreach ($seg in @($cmd -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($seg -match $server) {
      Deny "Dev servers run in the shared local env, not by hand: & $($KitCmd.local) use|up -Env <env> (list: envs; logs: logs -Env <env> -Service <s>)."
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
exit 0
}

# ---- tracker: lib.ps1 section 4
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

# ---- host: the git-host / ci adapters (lib.ps1 section 5) for devtools.py: host <verb> '<args JSON>' | @<json file> -> JSON
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
    default { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit $(if ($__verb -in '-h', '--help', 'help', '-?') { 0 } else { 2 }) }
  }
}
