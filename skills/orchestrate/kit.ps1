<#
kit.ps1: kit maintenance in one file (orchestrate SKILL.md "Change the kit", kit-audit SKILL.md). Run from pwsh 7:
  & <kit>/skills/orchestrate/kit.ps1 <verb> [args]
Verbs:
  health [-Flow] [-Fetch]                  SessionStart hook: git state, gates, stopped runs, lint, ports, retro / audit nudges (JSON for the hook)
  setup [-Exclude] [-Quiet] [-Migrate]     install / repair (idempotent); -Migrate moves the old layout (.claude-runtime, root *.local.* state)
  guard-sendmessage                        PreToolUse hook for SendMessage
  prepush · precommit                      the git hooks' logic (.githooks/pre-push, .githooks/pre-commit)
Inputs: the kit clone, kit.local.json. Outputs: text (hooks: one JSON line). Exit codes: 0 ok · 1 blocked / problem · 2 usage error (hooks: 2 = block).
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---------------------------------------------------------------- health: SessionStart hook - kit git state, gates, stopped runs, lint, ports, retro + audit nudges
# SessionStart hook: one line when the workspace kit needs attention (orchestrate event E17), nothing otherwise. No network.
# The kit (the workspace's .claude folder) is a git clone of the kit repo, edited in place:
#   - git: uncommitted kit changes, and commits behind/ahead of the LAST FETCHED upstream (git status --branch; the async
#     -Fetch hook refreshes it for the next start); core.hooksPath must be .githooks (the pre-push gate)
#   - kit.local.json "localOnly" paths are kept in .git/info/exclude (kit.ps1 setup -Exclude; rewrites only on change)
#   - an old runtime next to .claude (pre-clone layout) -> migrate it (kit.ps1 setup -Migrate)
#   - workflow launches with no completion (orch.ps1 launch -List -Brief: resumeFromRunId + args file) and QA runs whose
#     autoclose watcher stopped, plus a note that no heartbeat is armed yet (skipped after a compaction: same session)
#   - kit-lint summary (warn only): unrouted parts, unlisted files, fuzzy triggers, dangling paths, raw runtime paths,
#     durable state inside the runtime (RUNTIME-DURABLE), overlay problems
#   pwsh -File kit.ps1 health                # the checks above (synchronous hook, well under 2 s)
#   pwsh -File kit.ps1 health -Flow -Fetch   # async hook: regenerate <runtime>/cache/kit-flow.html, git fetch the kit's upstream
function Invoke-Health {
param([switch]$Flow, [switch]$Fetch)
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
if ($Flow -or $Fetch) {
  if ($Fetch -and (Test-Path (Join-Path $kit '.git'))) { git -C $kit fetch --quiet 2>$null }
  if ($Flow -and $py) { & $py -X utf8 $KitCmd.kittool flow $kit | Out-Null }
  exit 0
}

$msgs = @()
if (Test-Path (Join-Path $kit '.git')) {
  try { & $KitCmd.kit setup -Exclude -Quiet | Out-Null } catch {}
  $st = @(git -C $kit status --porcelain=v1 --branch 2>$null)
  $head = [string]($st | Select-Object -First 1)
  $changes = @($st | Select-Object -Skip 1).Count
  $parts = @()
  if ($changes) { $parts += "$changes uncommitted change(s) (commit + push them, or list org-only paths in kit.local.json localOnly)" }
  if ($head -match '\.\.\.(?<up>\S+)') {
    $up = $Matches.up
    if ($head -match 'behind (?<b>\d+)') { $parts += "$($Matches.b) commit(s) behind $up (git -C $kit pull --rebase once no agents run)" }
    if ($head -match 'ahead (?<a>\d+)') { $parts += "$($Matches.a) commit(s) ahead of $up (push them)" }
  }
  if ((git -C $kit config core.hooksPath 2>$null) -ne '.githooks') { $parts += "pre-push gate off (run: pwsh -File $($KitCmd.kit) setup)" }
  if ($parts) { $msgs += "kit: " + ($parts -join '; ') }
} else {
  $msgs += "kit: $kit is not a git clone of the kit repo (install: git clone https://github.com/prskid1000/claude-crew <workspace>/.claude; docs/install.md)"
}
$legacy = Join-Path $kit '.claude-runtime'
if ((Test-Path $legacy) -and -not (Get-Item $legacy).LinkType) { $msgs += "old runtime at $($legacy): move it once no agents run: pwsh -File $($KitCmd.kit) setup -Migrate" }
# Workflows die with the session that ran them: list launches with no completion (orch.ps1 launch) and QA runs whose autoclose
# watcher went quiet, so the coordinator resumes them instead of rebuilding them by hand. Not after a compaction (same session:
# its workflows still run). A fresh session has no heartbeat armed yet: say so when there is something to supervise.
$hook = $null
if ([Console]::IsInputRedirected) { try { $hook = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch {} }
if (-not $hook -or $hook.source -ne 'compact') {
  $stopped = @(& $KitCmd.orch launch -List -Brief 2>$null)
  if ($stopped.Count) { $msgs += "workflow runs with no completion (stopped with the last session? resume them, orchestrate E6; finished: orch.ps1 launch -Done): $($stopped -join '; '); no heartbeat is armed in this session (E1)" }
}
if ($py) {
  $lint =& $py -X utf8 $KitCmd.kittool lint $kit --summary --warn --no-flow 2>$null
  if ($lint) { $msgs += ($lint -join ' ') }
  & $py -X utf8 $KitCmd.kittool port --check 2>$null | ForEach-Object { $msgs += $_ }
}
foreach ($n in @(& $KitCmd.kit nudge | ForEach-Object { try { ($_ | ConvertFrom-Json).systemMessage } catch { } } | Where-Object { $_ })) { $msgs += $n }
if ($msgs) {
  $text = ($msgs -join ' | ') + ' (orchestrate Events)'
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
}

# ---------------------------------------------------------------- nudge: retro due / kit audit due (part of health)
#
function Invoke-Nudge {
# SessionStart hook: one line, nothing otherwise (no network, well under 1 s):
#  - E14: many learning signals piled up since the last /kit-retro -> run /kit-retro
#  - E21: the last kit audit (kittool.py audit stamp) is older than kit.local.json kitAudit.everyDays (default 7; 0 = off) and no
#    kit-auditor is on the board -> spawn kit-auditor
$ErrorActionPreference = 'SilentlyContinue'
$kit = $KitConf.Kit
$msgs = @()

$file = Get-KitPath signals; $mark = Get-KitPath last-retro; $guard = Get-KitPath guard-log
if ((Test-Path $file) -or (Test-Path $guard)) {
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  $n = @(Get-Content $file | Where-Object { $_ -match '"at":"([^"]+)"' -and [datetime]$Matches[1] -gt $since }).Count
  $g = @(Get-Content $guard | Where-Object { $_ -match '^(\S+)\t' -and [datetime]$Matches[1] -gt $since }).Count
  if (($n + $g) -ge 15) { $msgs += "Kit learning: $n signals + $g guard blocks since the last retro. Run /kit-retro to turn them into lessons and rule updates." }
}

# weekly kit audit (the stamp is durable: <kit>/kit-audit.local.stamp); kit.local.json read directly to keep the hook cheap
$every = 7
try { $c = Get-Content (Join-Path $kit 'skills/dev-kit/kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if ($null -ne $c.kitAudit.everyDays) { $every = [double]$c.kitAudit.everyDays } } catch {}
if ($every -gt 0) {
  $am = Get-KitPath last-kit-audit
  $last = $null; if (Test-Path $am) { try { $last = [datetime]((Get-Content $am -Raw).Trim()) } catch {} }
  if (-not $last -or ((Get-Date) - $last).TotalDays -ge $every) {
    $busy = @(Get-ChildItem (Get-KitPath board) -Filter '*.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
        Where-Object { $_.agent -eq 'kit-auditor' -and $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 }).Count
    if (-not $busy) { $msgs += "Kit audit due (last $(if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }), every $every days): spawn one kit-auditor agent (orchestrate E21)." }
  }
}

if ($msgs) {
  $text = $msgs -join ' | '
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
}

# ---------------------------------------------------------------- setup: install / repair, localOnly excludes, local config files, -Migrate the old layout
# Install step for a workspace kit (the workspace's .claude folder is a git clone of the kit repo), local-only excludes, and the
# one-time migration from the old layout (a synced copy with its runtime next to .claude).
#
#   git clone https://github.com/prskid1000/claude-crew <workspace>/.claude
#   pwsh -File <workspace>/.claude/skills/orchestrate/kit.ps1 setup              # install / repair (idempotent)
#   pwsh -File ... kit.ps1 setup -Exclude [-Quiet]                                     # only refresh .git/info/exclude
#   pwsh -File ... kit.ps1 setup -Migrate <old runtime> [-Work] [-Apk]                 # carry durable state over (never deletes)
#
# Install / repair:
#   - git config core.hooksPath .githooks   (the versioned pre-push gate: org terms, ignored/local files; kit-health checks it)
#   - points Claude Code auto memory at <kit>/memory (autoMemoryDirectory in settings.local.json; created if missing)
# - writes the kit.local.json "localOnly" paths into the clone's .git/info/exclude (a managed block), so org-only skills and
#     files stay untracked and never show in git status (kit-health runs -Exclude at every SessionStart)
#   - creates <runtime>/work, cache, logs and lists the local config files still to copy from their *.example.json
# -Migrate <dir>: an old runtime folder (e.g. <workspace>/.claude-runtime from the synced-copy layout). Copies what is durable:
#   learning/signals.jsonl -> .state/learning.jsonl (lines merged, no duplicates), learning/last-retro.txt -> .state/learning.stamp,
#   learning/retro-*.md -> logs/retros, tracking/<task>.json + automerge.json -> .state/tracking.json (existing tasks win),
#   tracker-none/ -> .state/tracker-none/ (+ tracker.log -> logs/tracker-none.log).
#   -Work also copies in-flight work (qa-runs, waves, board, briefs, phones, qa-seats, audits, docs, evidence, shots) into work/;
#   -Apk copies the android-swarm build output (APKs are slow to rebuild) into cache/. Everything else there is regenerable.
#   The old folder is never deleted: check the result, then remove it yourself once no agents run.
function Invoke-Setup {
param([switch]$Exclude, [switch]$Quiet, [switch]$Migrate, [switch]$WriteLocal)
$ErrorActionPreference = 'Stop'
$kit = $KitConf.Kit
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
  $begin = '# >>> kit localOnly (managed by skills/orchestrate/kit.ps1 setup; edit kit.local.json "localOnly" instead)'
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
  # the old layout: <kit>/.claude-runtime and durable *.local.* state at the kit root (paths.json "legacy") -> .runtime + .state/
  $map = Get-Content (Join-Path $kit 'skills/dev-kit/paths.json') -Raw | ConvertFrom-Json
  $oldRt = Join-Path $kit $map.legacy.runtimeDir; $newRt = Get-KitPath runtime
  # never while something runs: launch records without completion, live board entries, phone leases, QA seats
  $live = @()
  $live += @(& $KitCmd.orch launch -List -Brief 2>$null | Where-Object { $_ })
  foreach ($rt in @($oldRt, $newRt) | Where-Object { Test-Path $_ }) {
    $live += @(Get-ChildItem (Join-Path $rt 'work/board') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 } | ForEach-Object { "board: $($_.agent) ($($_.run))" })
    $live += @(Get-ChildItem (Join-Path $rt 'work/phones') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { "phone lease: $($_.BaseName)" })
    $live += @(Get-ChildItem (Join-Path $rt 'work/qa-seats/seats') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { "QA seat: $($_.BaseName)" })
  }
  if ($live.Count) { "migrate refused: something still runs - $(($live | Select-Object -First 6) -join '; '). Run it again once nothing runs."; exit 1 }
  if ((Test-Path $oldRt) -and -not ((Get-Item $oldRt).LinkType)) {
    if (Test-Path $newRt) { foreach ($e in Get-ChildItem $oldRt -Force) { $dst = Join-Path $newRt $e.Name; if (-not (Test-Path $dst)) { Move-Item $e.FullName $dst } else { "kept $($e.FullName) (already in $newRt)" } } ; if (-not @(Get-ChildItem $oldRt -Force).Count) { Remove-Item $oldRt -Force } }
    else { Move-Item $oldRt $newRt }
    if (-not (Test-Path $oldRt)) { New-DirLink -Path $oldRt -Target $newRt; "runtime: $oldRt -> $newRt (a link stays at the old path for one release)" }
  }
  foreach ($p in $map.legacy.durable.PSObject.Properties) {
    $src = Join-Path $kit ([string]$p.Value).TrimEnd('/'); if (-not (Test-Path $src)) { continue }
    $dst = Get-KitPath $p.Name -Create
    if ((Test-Path $dst) -and (Get-Item $src).PSIsContainer) { foreach ($e in Get-ChildItem $src -Force) { if (-not (Test-Path (Join-Path $dst $e.Name))) { Move-Item $e.FullName $dst } }; if (-not @(Get-ChildItem $src -Force).Count) { Remove-Item $src -Force } }
    elseif (Test-Path $dst) { "kept $src ($dst exists: merge by hand)" }
    else { Move-Item $src $dst }
    if (-not (Test-Path $src)) { "state: $($p.Value) -> $dst" }
  }
  # per-skill LESSONS.local.md / HISTORY.local.md -> one LESSONS.local.md at the kit root (## <skill> sections)
  $ll = Join-Path $kit 'LESSONS.local.md'
  foreach ($sk in Get-ChildItem (Join-Path $kit 'skills') -Directory) {
    foreach ($n in 'LESSONS.local.md', 'HISTORY.local.md') {
      $src = Join-Path $sk.FullName $n; if (-not (Test-Path $src)) { continue }
      $body = @((Get-Content $src) | Where-Object { $_ -match '^(- |### )' -or $_ -match '^## Project' } | ForEach-Object { $_ -replace '^## Project', '### Project' })
      if ($body.Count) { Add-Content $ll ("`n## $($sk.Name)$(if ($n -like 'HISTORY*') { ' (history)' })`n" + ($body -join "`n")) -Encoding utf8 }
      Move-Item $src (Join-Path (Get-KitPath cache -Create) "migrated-$($sk.Name)-$n") -Force; "lessons: skills/$($sk.Name)/$n -> LESSONS.local.md"
    }
  }
  'migrated. The old paths are gone (runtime: a link for one release). Nothing else changed.'
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
# local config files (git-ignored): kit.local.json = kit.example.json minus "localFiles"; the others from its "localFiles" section
$ex = Get-Content (Join-Path $kit 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json
$want = [ordered]@{ 'skills/dev-kit/kit.local.json' = ($ex | Select-Object -Property * -ExcludeProperty localFiles) }
foreach ($p in $ex.localFiles.PSObject.Properties) { $want[$p.Name] = $p.Value }
foreach ($k in $want.Keys) {
  $f = Join-Path $kit $k; if (Test-Path $f) { continue }
  if ($WriteLocal) { $want[$k] | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding utf8; Say "wrote $k from kit.example.json: fill in the <...> values (git-ignored)" }
  else { Say "to do: $k is missing (kit.ps1 setup -WriteLocal writes it from kit.example.json; then fill it in)" }
}
if ((Test-Path (Join-Path $kit '.claude-runtime')) -and -not (Get-Item (Join-Path $kit '.claude-runtime')).LinkType) { Say "old layout found: kit.ps1 setup -Migrate (once nothing runs)" }
Say 'kit ready.'
}

# ---------------------------------------------------------------- guard-sendmessage: PreToolUse hook for SendMessage (blocks messages to workflow agents)
# PreToolUse hook for SendMessage: blocks a message to an agent that belongs to a workflow run (dev-wave, test-and-close ...).
# Such a send does not reach the running agent: it RESUMES a second copy from its transcript, and both copies then write the same
# worktree (duplicate edits, broken tests). Relay to workflow agents through <brief>.contracts.md instead (they read it before pushing).
# Exit 2 = block (stderr goes back to the model); exit 0 = allow.
function Invoke-GuardSendMessage {
$ErrorActionPreference = 'SilentlyContinue'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$to = "$($in.tool_input.to)".Trim()
if ($to -notmatch '^(?<id>a[0-9a-f]{12,})$') { exit 0 }
$id = $Matches.id
$meta = Get-ChildItem (Join-Path $HOME ".claude/projects/*/*/subagents/workflows/*/agent-$id.meta.json") | Select-Object -First 1
if (-not $meta) { exit 0 }
$label = (Get-Content $meta.FullName -Raw | ConvertFrom-Json).description
[Console]::Error.WriteLine("Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you.")
exit 2
}

# ---------------------------------------------------------------- prepush: the pre-push gate (org terms, ignored / local files)
# Kit pre-push gate, run by .githooks/pre-push (git passes: <remote name> <url>; stdin: <local ref> <local sha> <remote ref> <remote sha>).
# Blocks the push (exit 1) on any hit:
#   1. LOCAL FILE  a pushed commit adds or changes a file that matches .gitignore or .git/info/exclude (force-added *.local.*,
#                  settings.local.json, targets/swarm configs, kit.local.json "localOnly" paths, runtime output, ...)
#   2. ORG TERM    kittool.py lint --org-terms finds an org term in a published file of the working tree, or a pushed commit adds a
#                  line with one. Terms: "orgTerms" in skills/dev-kit/kit.local.json (or $env:KIT_ORG_TERMS, comma list).
#   3. PORTS       kittool.py port --check differs (generated .codex/ .agents/ GEMINI.md or the workspace copies are stale)
# The kit's other lint problems are printed as a warning only.
function Invoke-PrePush {
$ErrorActionPreference = 'Stop'
$root = $KitConf.Kit
$zero = '0' * 40
$updates = @([Console]::In.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_ -split '\s+'; [pscustomobject]@{ lsha = $p[1]; rsha = $p[3] } } | Where-Object { $_.lsha -ne $zero })
$hits = @()

# commits being pushed: new ones only (for a new branch: those on no remote yet)
$revs = foreach ($u in $updates) { if ($u.rsha -eq $zero) { git -C $root rev-list $u.lsha --not --remotes } else { git -C $root rev-list "$($u.rsha)..$($u.lsha)" } }
$revs = @($revs | Where-Object { $_ } | Select-Object -Unique)

# 1. ignored / local-only files in the pushed commits
if ($revs.Count) {
  $files = @($revs | ForEach-Object { git -C $root diff-tree --no-commit-id --name-only --diff-filter=ACMR -r $_ } | Where-Object { $_ } | Select-Object -Unique)
  if ($files.Count) {
    # paths as arguments, in batches (piping from pwsh on Windows would append CR to every path)
    $ign = @(for ($i = 0; $i -lt $files.Count; $i += 100) { git -C $root check-ignore --no-index -- @($files[$i..([math]::Min($i + 99, $files.Count - 1))]) 2>$null })
    foreach ($f in $ign) { $hits += "LOCAL FILE  $f is git-ignored or local-only (.gitignore / .git/info/exclude) but a pushed commit carries it: git rm --cached it and amend" }
  }
}

# 2. org terms
$terms = @()
$cfg = Join-Path $root 'skills/dev-kit/kit.local.json'
if ($env:KIT_ORG_TERMS) { $terms = @($env:KIT_ORG_TERMS -split ',' | Where-Object { $_.Trim() }) }
elseif (Test-Path $cfg) { try { $terms = @((Get-Content $cfg -Raw | ConvertFrom-Json).orgTerms | Where-Object { $_ }) } catch { $hits += "CONFIG      $cfg is not valid JSON: $_" } }
if (-not $terms.Count) { Write-Host 'pre-push: no orgTerms in skills/dev-kit/kit.local.json - org-term scan skipped' }
else {
  $py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
  if (-not $py) { $hits += 'PYTHON      python is not installed: the org-term scan (kittool.py lint) cannot run' }
  else {
    $out = Join-Path ([IO.Path]::GetTempPath()) "kit-prepush-$PID.json"
    & $py -X utf8 $KitCmd.kittool lint $root --warn --no-flow --org-terms ($terms -join ',') --json $out | Out-Null
    if (-not (Test-Path $out)) { $hits += "LINT        kittool.py lint failed (exit $LASTEXITCODE, no JSON): the org-term scan of the working tree did not run" }
    $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
    foreach ($p in $probs | Where-Object code -eq 'ORG-TERM') { $hits += "ORG TERM    $($p.where): $($p.problem)" }
    $other = @($probs | Where-Object code -ne 'ORG-TERM')
    if ($other.Count) { Write-Host "pre-push: warning: kit-lint reports $($other.Count) other problem(s) (python skills/orchestrate/kittool.py lint)" }
  }
  # lines added by the pushed commits (catches a term that was committed and later removed from the working tree)
  # whole words; a term with a capital letter matches case-sensitively (the same rule as kit-lint ORG-TERM)
  # a term ending in * is a prefix (same rule as kit-lint)
  $rx = @($terms | ForEach-Object { $t = $_.Trim(); $stem = $t.TrimEnd('*'); [pscustomobject]@{ term = $t; rx = [regex]::new('(?<![\w-])' + [regex]::Escape($stem) + $(if ($t.EndsWith('*')) { '' } else { '(?![\w-])' }), $(if ($stem -cne $stem.ToLower()) { 'None' } else { 'IgnoreCase' })) } })
  foreach ($r in $revs) {
    foreach ($line in @(git -C $root show --format= --unified=0 --no-color $r)) {
      if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
      foreach ($x in $rx) { if ($x.rx.IsMatch($line)) { $hits += "ORG TERM    commit $($r.Substring(0, 8)) adds ""$($x.term)"": $($line.Substring(0, [math]::Min(120, $line.Length)))"; break } }
    }
  }
}

# 3. stale ports (the pre-commit hook regenerates them; a commit made without the hook leaves them stale)
$py3 = Get-Python
if ($py3) { $pc = & $py3 -X utf8 $KitCmd.kittool port --check 2>&1; if ($LASTEXITCODE) { $hits += "PORTS       stale generated ports: $("$pc".Trim()) - run kittool.py port and commit" } }

if ($hits.Count) {
  Write-Host "pre-push: BLOCKED - $($hits.Count) problem(s):" -ForegroundColor Red
  $hits | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
  Write-Host 'Fix them (the kit is public and generic: org values belong in *.local.* files or localOnly paths), then push again.'
  exit 1
}
exit 0
}

# ---------------------------------------------------------------- precommit: the pre-commit gate (graph sections in README, lint)
# Regenerates the README graph sections (kittool flow --readme) and the ports (kittool port: .codex/, .agents/, GEMINI.md, plus the
# workspace copies when the kit is an installed <workspace>/.claude), stages them, fails when port --check still differs or while
# kit-lint finds blocking problems (unreached files, budgets, file cap, conventions). Run by .githooks/pre-commit.
function Invoke-PreCommit {
  $root = $KitConf.Kit
  $py = Get-Python
  & $py -X utf8 $KitCmd.kittool flow --readme $root | Out-Null
  if ($LASTEXITCODE) { Write-Host "pre-commit: kittool flow failed (exit $LASTEXITCODE)"; exit 1 }
  if (@(git -C $root status --porcelain -- README.md).Count) { git -C $root add -- README.md; Write-Host 'pre-commit: README graph sections regenerated and staged' }
  # ports: regenerate (and deploy to the workspace when this is an installed <workspace>/.claude), stage the kit-side files
  & $py -X utf8 $KitCmd.kittool port | Out-Null
  if ($LASTEXITCODE) { Write-Host "pre-commit: BLOCKED - kittool port failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }
  $gen = @('.codex', '.agents', 'GEMINI.md') | Where-Object { Test-Path (Join-Path $root $_) }
  if (@(git -C $root status --porcelain -- @gen).Count) { git -C $root add -A -- @gen; Write-Host 'pre-commit: ports regenerated and staged' }
  $chk = & $py -X utf8 $KitCmd.kittool port --check 2>&1
  if ($LASTEXITCODE) { Write-Host "pre-commit: BLOCKED - ports still differ after regeneration: $chk" -ForegroundColor Red; exit 1 }
  $out = Join-Path ([IO.Path]::GetTempPath()) "kit-precommit-$PID.json"
  & $py -X utf8 $KitCmd.kittool lint $root --no-flow --json $out | Out-Null
  $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
  if ($probs.Count) { Write-Host "pre-commit: BLOCKED - kit-lint: $($probs.Count) problem(s):" -ForegroundColor Red; $probs | Select-Object -First 25 | ForEach-Object { Write-Host "  $($_.code) $($_.where): $($_.problem)" }; exit 1 }
  exit 0
}
if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    'health' { Invoke-KitVerb Invoke-Health $__rest }
    'nudge' { Invoke-KitVerb Invoke-Nudge $__rest }
    'setup' { Invoke-KitVerb Invoke-Setup $__rest }
    'guard-sendmessage' { Invoke-KitVerb Invoke-GuardSendMessage $__rest }
    'prepush' { Invoke-KitVerb Invoke-PrePush $__rest }
    'precommit' { Invoke-KitVerb Invoke-PreCommit $__rest }
    default { Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1; exit 2 }
  }
}
