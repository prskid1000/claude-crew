<#
Self-cleaning for the kit: removes temp things the kit's own scripts, agents and workflows produce, and logs what it freed.
Runs automatically: at the end of every workflow (Learn step) and once a day from the SessionStart hook (-IfDue, in the background).

  & <workspace>\.claude\skills\orchestrate\scripts\cleanup.ps1            # clean now
  & ... cleanup.ps1 -DryRun                                              # show what would go, delete nothing
  & ... cleanup.ps1 -IfDue                                               # only if the last cleanup was > 20 h ago

What it cleans (only kit-created things; never repos, never anything in use):
  - headless test browsers (runtime\chrome-profiles) running > 3 h, or > 30 min when no QA agent is active on the board;
    then their profile folders idle > 1 day
  - idle Gradle / Kotlin compile daemons (GBs each) when no gated Gradle build is running
  - shared web logins (runtime\sessions) > 8 h, API tokens > 3 days
  - loose evidence / android shots / temp xml in runtime > 14 / 3 days
  - QA run folders > 30 days (results.json, finalize.json and report.html are kept as a record)
  - tsc incremental caches > 30 days; gate ledger entries of dead builds
  - Claude session temp dirs (%TEMP%\claude\<project>\<session>: scratchpad, task outputs) untouched > 7 days
  - kit test leftovers in %TEMP% (kit-*, claude-kit-*, wfc.js, gradletest, report-preview.html, ...) > 1 day
  - worktrees that are finished: remote branch deleted (MR merged + source branch removed), no uncommitted changes,
    no unpushed work, untouched > 2 h -> wt.ps1 remove (the local branch ref stays, nothing is lost)
  - log rotation: guard.log, cleanup.log, signals.jsonl (kept to the newest 5000 lines)
Claude Code's own transcripts are left to its `cleanupPeriodDays` setting.
#>
param([switch]$DryRun, [switch]$IfDue, [switch]$Quiet, [string[]]$WorktreeRoot = @(), [double]$WorktreeIdleHours = 2)   # WorktreeRoot default: kit.local.json "worktreeRoots" (else <reposRoot>-wt); idle 0 right after a wave finished (still-open MRs are protected by their remote branch)
$ErrorActionPreference = 'SilentlyContinue'
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$K = Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit\scripts'
. (Join-Path $K 'kitconfig.ps1')
if (-not $WorktreeRoot) { $WorktreeRoot = $KitConf.WorktreeRoots }
$keepBranches = '^(' + ((@('main', 'master', 'develop') + @($KitConf.ProtectedBranches | ForEach-Object { [regex]::Escape($_) })) -join '|') + ')$'
New-Item -ItemType Directory -Force $rt | Out-Null
$mark = Join-Path $rt 'last-cleanup.txt'; $log = Join-Path $rt 'cleanup.log'
if ($IfDue -and (Test-Path $mark) -and ((Get-Date) - [datetime](Get-Content $mark -Raw).Trim()).TotalHours -lt 20) { exit 0 }

$now = Get-Date; $freed = 0L; $actions = New-Object System.Collections.ArrayList
function Size($p) { if (Test-Path $p -PathType Leaf) { (Get-Item $p).Length } else { (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
function Gone($path, $why) {
  if (-not (Test-Path $path)) { return }
  $sz = [long](Size $path)
  # Remove-Item -Force also clears read-only files ([IO.Directory]::Delete threw on them and the same dirs were "freed" every run)
  if (-not $DryRun) { try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { [void]$actions.Add(('  FAILED    {0}  ({1}): {2}' -f $path, $why, $_.Exception.Message)); return } }
  $script:freed += $sz
  [void]$actions.Add(('{0,8:N1} MB  {1}  ({2})' -f ($sz / 1MB), $path, $why))
}
function Old($item, $hours) { ($now - $item.LastWriteTime).TotalHours -gt $hours }

# 1. headless test browsers left running, then idle profiles
$profiles = Join-Path $rt 'chrome-profiles'
$chromes = Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match [regex]::Escape($profiles) }
$qaRuns = @(Get-ChildItem (Join-Path $rt 'qa-runs') -Directory | ForEach-Object Name)
$qaActive = @(Get-ChildItem (Join-Path $rt 'board') -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
  Where-Object { $_.status -ne 'left' -and ($now - [datetime]$_.beat).TotalMinutes -lt 20 -and ($_.run -in $qaRuns -or "$($_.worktrees)" -match 'chrome:') }).Count
$browserLimitH = if ($qaActive) { 3 } else { 0.5 }
foreach ($c in $chromes | Where-Object { $_.ParentProcessId -notin $chromes.ProcessId }) {   # browser roots only
  if (($now - $c.CreationDate).TotalHours -gt $browserLimitH) { [void]$actions.Add("killed headless browser pid $($c.ProcessId) (running $([int]($now - $c.CreationDate).TotalHours) h)"); if (-not $DryRun) { Stop-Process -Id $c.ProcessId -Force } }
}
$inUse = @($chromes | ForEach-Object { if ($_.CommandLine -match 'chrome-profiles[\\/](\d+)') { $Matches[1] } } | Sort-Object -Unique)
foreach ($p in Get-ChildItem $profiles -Directory) { if ($p.Name -notin $inUse -and (Old $p 24)) { Gone $p.FullName 'idle browser profile' } }

# 1b. idle Gradle / Kotlin daemons (they keep GBs after a build) - only when no gated Gradle build is running
$gradleBusy = @(Get-ChildItem (Join-Path $env:TEMP 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json' |
  ForEach-Object { try { $e = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($e.kind -match 'android|gradle' -and (Get-Process -Id $e.pid)) { $e } } catch {} }).Count
if (-not $gradleBusy) {
  foreach ($d in Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' }) {
    if (($now - $d.CreationDate).TotalMinutes -gt 10) { [void]$actions.Add(("stopped idle {0} pid {1} ({2:N1} GB)" -f $(if ($d.CommandLine -match 'Kotlin') { 'Kotlin daemon' } else { 'Gradle daemon' }), $d.ProcessId, ($d.WorkingSetSize / 1GB))); $script:freed += [long]$d.WorkingSetSize; if (-not $DryRun) { Stop-Process -Id $d.ProcessId -Force } }
  }
}

# 2. logins, tokens, loose evidence, android temp
foreach ($f in Get-ChildItem (Join-Path $rt 'sessions') -File) { if (Old $f 8) { Gone $f.FullName 'expired shared web login' } }
foreach ($f in Get-ChildItem (Join-Path $rt 'tokens') -File) { if (Old $f 72) { Gone $f.FullName 'old API token' } }
foreach ($f in Get-ChildItem (Join-Path $rt 'evidence') -File) { if (Old $f (14 * 24)) { Gone $f.FullName 'loose evidence > 14 d' } }
foreach ($d in 'android', 'shots') { foreach ($f in Get-ChildItem (Join-Path $rt $d) -Recurse -File) { if (Old $f 72) { Gone $f.FullName "$d temp > 3 d" } } }

# 3. old QA runs: keep the record, drop the bulk
foreach ($r in Get-ChildItem (Join-Path $rt 'qa-runs') -Directory) {
  if (Old $r (30 * 24)) { foreach ($sub in Get-ChildItem $r.FullName -Recurse -Directory | Where-Object Name -in 'shots', 'evidence', 'scripts') { Gone $sub.FullName 'QA run > 30 d (results/report kept)' } }
}
foreach ($f in Get-ChildItem (Join-Path $rt 'tsbuild') -File) { if (Old $f (30 * 24)) { Gone $f.FullName 'tsc cache > 30 d' } }

# 4. gate ledger: entries of builds that are no longer running
foreach ($f in Get-ChildItem (Join-Path $env:TEMP 'claude-build-gate') -Filter '*.json' | Where-Object Name -ne 'history.json') {
  try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (-not (Get-Process -Id $e.pid -ErrorAction SilentlyContinue)) { Gone $f.FullName 'dead gate entry' } } catch {}
}

# 5. Claude session temp dirs (scratchpad, task outputs) untouched for a week
foreach ($proj in Get-ChildItem (Join-Path $env:TEMP 'claude') -Directory) {
  foreach ($sess in Get-ChildItem $proj.FullName -Directory | Where-Object Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {   # session ids only
    $newest = Get-ChildItem $sess.FullName -Recurse -File -Force | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $last = if ($newest) { $newest.LastWriteTime } else { $sess.LastWriteTime }
    if (($now - $last).TotalDays -gt 7) { Gone $sess.FullName 'Claude session temp untouched > 7 d' }
  }
}

# 6. kit test leftovers in %TEMP%
foreach ($f in Get-ChildItem $env:TEMP -Force | Where-Object { $_.Name -match '^(kit-|claude-kit-|wfc\.js$|gradletest$|report-preview\.html$|gate-debug\.ps1$|bad-findings\.json$|audit-test$|kitshots$|tsc\d\.log$|claude-wt-selftest$)' }) {
  if (Old $f 24) { Gone $f.FullName 'kit test leftover' }
}

# 7. finished worktrees
foreach ($root in $WorktreeRoot) {
  foreach ($w in Get-ChildItem $root -Directory) {
    $d = $w.FullName
    if (-not (git -C $d rev-parse --is-inside-work-tree 2>$null)) { continue }
    $br = git -C $d rev-parse --abbrev-ref HEAD 2>$null
    if (-not $br -or $br -eq 'HEAD' -or $br -match $keepBranches) { continue }
    if (git -C $d status --porcelain 2>$null) { continue }                                   # uncommitted work
    $newest = (Get-ChildItem $d -File -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue | Where-Object FullName -notmatch '\\(node_modules|\.git|target|build)\\' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($newest -and ($now - $newest).TotalHours -lt $WorktreeIdleHours) { continue }
    git -C $d fetch -q --prune origin 2>$null
    if (git -C $d ls-remote --heads origin $br 2>$null) { continue }                          # branch still open on the remote
    $unpushed = git -C $d log --oneline "@{upstream}..HEAD" 2>$null
    if ($LASTEXITCODE -eq 0 -and $unpushed) { continue }
    [void]$actions.Add("worktree $d (branch $br merged + deleted on remote, clean, idle > $WorktreeIdleHours h) -> wt.ps1 remove; local branch ref kept")
    if (-not $DryRun) { & "$K\wt.ps1" remove -Dir $d | Out-Null }
  }
}

# 8. rotate logs
foreach ($f in @((Join-Path $rt 'guard.log'), $log, (Join-Path $rt 'learning\signals.jsonl'))) {
  if ((Test-Path $f) -and @(Get-Content $f).Count -gt 5000) { if (-not $DryRun) { $keep = Get-Content $f -Tail 5000; Set-Content $f $keep }; [void]$actions.Add("rotated $f to 5000 lines") }
}

$summary = "$(if ($DryRun) { '[dry run] would free' } else { 'freed' }) $([math]::Round($freed / 1MB, 1)) MB in $($actions.Count) action(s)"
if (-not $DryRun) {
  $now.ToString('s') | Set-Content $mark
  "$($now.ToString('s')) $summary" | Add-Content $log; $actions | ForEach-Object { "  $_" } | Add-Content $log
}
if (-not $Quiet) { $summary; $actions }
$global:LASTEXITCODE = 0
