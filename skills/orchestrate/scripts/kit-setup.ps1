#Requires -Version 7
<#
Install step for a workspace kit (the workspace's .claude folder is a git clone of the kit repo), local-only excludes, and the
one-time migration from the old layout (a synced copy with its runtime next to .claude).

  git clone https://github.com/prskid1000/claude-crew <workspace>/.claude
  pwsh -File <workspace>/.claude/skills/orchestrate/scripts/kit-setup.ps1              # install / repair (idempotent)
  pwsh -File ... kit-setup.ps1 -Exclude [-Quiet]                                     # only refresh .git/info/exclude
  pwsh -File ... kit-setup.ps1 -Migrate <old runtime> [-Work] [-Apk]                 # carry durable state over (never deletes)

Install / repair:
  - git config core.hooksPath .githooks   (the versioned pre-push gate: org terms, ignored/local files; kit-health checks it)
  - points Claude Code auto memory at <kit>/memory (autoMemoryDirectory in settings.local.json; created if missing)
- writes the kit.local.json "localOnly" paths into the clone's .git/info/exclude (a managed block), so org-only skills and
    files stay untracked and never show in git status (kit-health runs -Exclude at every SessionStart)
  - creates <runtime>/work, cache, logs and lists the local config files still to copy from their *.example.json
-Migrate <dir>: an old runtime folder (e.g. <workspace>/.claude-runtime from the synced-copy layout). Copies what is durable:
  learning/signals.jsonl -> learning.local.jsonl (lines merged, no duplicates), learning/last-retro.txt -> learning.local.stamp,
  learning/retro-*.md -> logs/retros, tracking/<task>.json + automerge.json -> tracking.local.json (existing tasks win),
  tracker-none/ -> tracker-none.local/ (+ tracker.log -> logs/tracker-none.log).
  -Work also copies in-flight work (qa-runs, waves, board, briefs, phones, qa-seats, audits, docs, evidence, shots) into work/;
  -Apk copies the android-swarm build output (APKs are slow to rebuild) into cache/. Everything else there is regenerable.
  The old folder is never deleted: check the result, then remove it yourself once no agents run.
#>
param([switch]$Exclude, [switch]$Quiet, [string]$Migrate, [switch]$Work, [switch]$Apk)
$ErrorActionPreference = 'Stop'
$kit = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/orchestrate/scripts -> <kit>
. (Join-Path $kit 'skills/dev-kit/scripts/kitpaths.ps1')
function Say($s) { if (-not $Quiet) { $s } }

# Claude Code auto memory goes into this kit: <kit>/memory (git-ignored). The setting must be an absolute path, so it is
# written per clone into the git-ignored settings.local.json (merged, other keys kept); the folder is created if missing.
# Takes effect from the next session. Opt out with  "memory": { "keepDefault": true }  in kit.local.json (then a user-level
# autoMemoryDirectory, e.g. one structured folder for all projects, or the harness default applies).
function Set-Memory {
  try { $cfg = Get-Content (Join-Path $kit 'skills/dev-kit/kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cfg = $null }
  if ($cfg -and $cfg.memory -and $cfg.memory.keepDefault) { return $null }
  $dir = Join-Path $kit 'memory'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $want = ($dir -replace '\\', '/')
  $sl = Join-Path $kit 'settings.local.json'
  $s = if (Test-Path $sl) { try { Get-Content $sl -Raw | ConvertFrom-Json -AsHashtable } catch { $null } } else { @{} }
  if ($null -eq $s) { return "settings.local.json is not valid JSON: autoMemoryDirectory not set (fix the file, then re-run)" }
  if ($s['autoMemoryDirectory'] -eq $want) { return $null }
  $s['autoMemoryDirectory'] = $want
  [IO.File]::WriteAllText($sl, ($s | ConvertTo-Json -Depth 20))
  "memory: autoMemoryDirectory = $want (settings.local.json; from the next session)"
}

function Update-Exclude {
  if (-not (Test-Path (Join-Path $kit '.git'))) { return 'not a git clone: no .git/info/exclude' }
  $gd = Join-Path $kit '.git'
  if (Test-Path $gd -PathType Leaf) { $gd = ((Get-Content $gd -Raw) -replace '^gitdir:\s*', '').Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $kit $gd } }
  $ex = Join-Path $gd 'info/exclude'
  $paths = @()
  $kl = Join-Path $kit 'skills/dev-kit/kit.local.json'
  if (Test-Path $kl) { try { $paths = @((Get-Content $kl -Raw | ConvertFrom-Json).localOnly | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').Trim('/') }) } catch { return "kit.local.json is not valid JSON: $_" } }
  $begin = '# >>> kit localOnly (managed by skills/orchestrate/scripts/kit-setup.ps1; edit kit.local.json "localOnly" instead)'
  $end = '# <<< kit localOnly'
  $old = if (Test-Path $ex) { Get-Content $ex -Raw } else { '' }
  $rest = [regex]::Replace($old, '(?s)\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?', "`n").TrimEnd()
  $block = if ($paths.Count) { "$begin`n" + (($paths | ForEach-Object { "/$_" }) -join "`n") + "`n$end" } else { '' }
  $new = (@($rest, $block) | Where-Object { $_ }) -join "`n`n"
  $new = if ($new) { $new + "`n" } else { '' }
  if ($new -ne $old) { New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null; [IO.File]::WriteAllText($ex, $new); "excluded $($paths.Count) localOnly path(s) in $ex" }
}

if ($Exclude) { $r = Update-Exclude; if ($r) { Say $r }; $m = Set-Memory; if ($m) { Say $m }; exit 0 }

if ($Migrate) {
  if (-not (Test-Path $Migrate -PathType Container)) { throw "no such folder: $Migrate" }
  $old = (Resolve-Path $Migrate).Path
  # signals: merge lines, keep order, no duplicates
  $sig = Join-Path $old 'learning/signals.jsonl'
  if (Test-Path $sig) {
    $dst = Get-KitPath signals -Create
    $have = @{}; if (Test-Path $dst) { Get-Content $dst | ForEach-Object { $have[$_] = $true } }
    $add = @(Get-Content $sig | Where-Object { $_.Trim() -and -not $have[$_] })
    if ($add.Count) { $add | Add-Content $dst -Encoding utf8 }
    "signals: $($add.Count) new line(s) -> $dst"
  }
  $mark = Join-Path $old 'learning/last-retro.txt'
  if (Test-Path $mark) {
    $dst = Get-KitPath last-retro -Create; $t = (Get-Content $mark -Raw).Trim()
    $cur = if (Test-Path $dst) { (Get-Content $dst -Raw).Trim() } else { '' }
    if (-not $cur -or [datetime]$t -gt [datetime]$cur) { Set-Content $dst $t -Encoding utf8; "last retro: $t -> $dst" }
  }
  foreach ($r in Get-ChildItem (Join-Path $old 'learning') -Filter 'retro-*.md' -File -ErrorAction SilentlyContinue) {
    $d = Get-KitPath retros -Create; if (-not (Test-Path (Join-Path $d $r.Name))) { Copy-Item $r.FullName $d; "retro report: $($r.Name) -> $d" }
  }
  # tracking: one file per task + automerge.json -> tracking.local.json
  $tasks = @(Get-ChildItem (Join-Path $old 'tracking') -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $amf = Join-Path $old 'automerge.json'
  if ($tasks.Count -or (Test-Path $amf)) {
    $n = 0; $m = 0
    Update-KitTracking {
      param($t)
      foreach ($f in $tasks) {
        try { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "skipped $($f.Name): $_"; continue }
        $id = if ($o.task) { [string]$o.task } else { $f.BaseName }
        if (-not $t.tasks.ContainsKey($id)) { $o.task = $id; $t.tasks[$id] = $o; $script:n++ }
      }
      if (Test-Path $amf) {
        $am = try { Get-Content $amf -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
        foreach ($k in @($am.Keys)) { if (-not $t.automerge.ContainsKey($k)) { $t.automerge[$k] = $am[$k]; $script:m++ } }
      }
    }
    "tracking: $n task(s), $m merge intent(s) -> $(Get-KitPath tracking)"
  }
  # the 'none' tracker's store
  $tn = Join-Path $old 'tracker-none'
  if (Test-Path $tn) {
    $d = Get-KitPath tracker-none -Create; $c = 0
    foreach ($f in Get-ChildItem $tn -Filter '*.json' -File) { if (-not (Test-Path (Join-Path $d $f.Name))) { Copy-Item $f.FullName $d; $c++ } }
    $lg = Join-Path $tn 'tracker.log'; if (Test-Path $lg) { Get-Content $lg | Add-Content (Get-KitPath tracker-log -Create) -Encoding utf8 }
    "tracker-none: $c task file(s) -> $d"
  }
  if ($Work) {
    foreach ($n in 'qa-runs', 'waves', 'board', 'briefs', 'phones', 'qa-seats', 'audits', 'docs', 'evidence', 'shots') {
      $src = Join-Path $old $n; if (-not (Test-Path $src)) { continue }
      $dst = Get-KitPath $n -Create
      Get-ChildItem $src -Force | ForEach-Object { if (-not (Test-Path (Join-Path $dst $_.Name))) { Copy-Item $_.FullName $dst -Recurse -Force } }
      "work: $n -> $dst"
    }
  }
  if ($Apk -and (Test-Path (Join-Path $old 'android-swarm'))) {
    $dst = Get-KitPath android-swarm -Create
    Get-ChildItem (Join-Path $old 'android-swarm') -Force | ForEach-Object { if (-not (Test-Path (Join-Path $dst $_.Name))) { Copy-Item $_.FullName $dst -Recurse -Force } }
    "cache: android-swarm -> $dst"
  }
  if ($old -eq (Get-KitPath runtime)) {
    # migrating in place (the old layout's entries sit at the root of the current runtime): park them under cache/, where
    # everything is disposable, so the runtime holds only work/ cache/ logs/ and kit-lint RUNTIME-DURABLE is quiet
    $park = Join-Path (Get-KitPath cache -Create) 'old-layout'
    New-Item -ItemType Directory -Force $park | Out-Null
    foreach ($e in Get-ChildItem $old -Force | Where-Object { $_.Name -notin 'work', 'cache', 'logs' }) { Move-Item $e.FullName (Join-Path $park $e.Name) -Force }
    "parked the old layout's leftovers in $park (disposable: delete it whenever you like)"
  } else {
    "migrated from $old (nothing deleted). Check the files above, then delete the old folder yourself once no agents run."
  }
  exit 0
}

# ---- install / repair
if (-not (Test-Path (Join-Path $kit '.git'))) { Write-Warning "$kit is not a git clone: install with  git clone https://github.com/prskid1000/claude-crew <workspace>/.claude" }
else {
  if ((git -C $kit config core.hooksPath) -ne '.githooks') { git -C $kit config core.hooksPath .githooks; Say 'git: core.hooksPath = .githooks (pre-push gate on)' }
  $r = Update-Exclude; if ($r) { Say $r }
}
$m = Set-Memory; if ($m) { Say $m }
foreach ($n in 'work', 'cache', 'logs') { $null = Get-KitPath $n -Create }
Say "runtime: $(Get-KitPath runtime) (work/ cache/ logs/; disposable)"
foreach ($pair in @(@('skills/dev-kit/kit.example.json', 'skills/dev-kit/kit.local.json'), @('skills/qa-kit/targets.example.json', 'skills/qa-kit/targets.local.json'),
    @('skills/android-swarm/swarm.example.json', 'skills/android-swarm/swarm.config.json'))) {
  if (-not (Test-Path (Join-Path $kit $pair[1]))) { Say "to do: copy $($pair[0]) to $($pair[1]) and fill it in (git-ignored)" }
}
$legacy = Join-Path (Split-Path $kit) '.claude-runtime'
if ((Test-Path $legacy) -and $legacy -ne (Get-KitPath runtime)) { Say "old runtime found at $($legacy): pwsh -File $PSCommandPath -Migrate $legacy [-Work] [-Apk]" }
Say 'kit ready.'
