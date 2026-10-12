<#
PreToolUse guard (Bash + PowerShell tools) for every session in this workspace (wired in .claude/settings.json).
Turns the kit's hard rules into enforcement instead of advice:
  - no `git stash` (the stash is shared across worktrees)
  - no `--no-verify` / hook skipping
  - no force-push to a protected branch (main, master, develop, release/*, plus kit.local.json "protectedBranches")
  - no `adb kill-server` (it drops every agent's emulator lane)
  - no `& <file>.md` / `Invoke-Item` on a document (it opens the owner's desktop app instead of reading the file)
  - heavy builds/tests go through the memory gate (check.ps1 / gate.ps1), not straight to mvn/gradle/dotnet/ng/jest/...
Reads the hook JSON on stdin; prints a deny decision with the reason, or nothing (= allow).
  - no deleting the runtime's work/ folder while runs are active (cache/ and logs/ may go), nor the durable *.local state
Every block is logged to Get-KitPath guard-log (<runtime>/logs/guard.log) so /kit-retro can learn from repeated mistakes.
#>
$ErrorActionPreference = 'SilentlyContinue'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$cmd = [string]$in.tool_input.command
if (-not $cmd) { exit 0 }
$K = Split-Path $PSCommandPath   # this kit's dev-kit\scripts folder (messages point agents at the right scripts)
. (Join-Path $K 'kitpaths.ps1')   # Get-KitPath (cheap: no CLI lookups)
# extra shared branches from kit.local.json (optional); kept cheap: this runs before every shell command
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path (Split-Path $K) 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  if ($in.session_id) {   # only real hook calls are logged: test runs (no session) must not raise supervise's guard WATCH
    "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$(($raw -replace "[\r\n\t]+", " // ").Substring(0, [math]::Min(200, ($raw -replace "[\r\n\t]+", " // ").Length)))" | Add-Content (Get-KitPath guard-log -Create)
  }
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  exit 0
}

# Judge the command words only: text inside quotes (grep patterns, commit messages, learn.ps1 -Text "...") is not a command.
$raw = $cmd
# Heredoc bodies (<<EOF ... EOF) and PowerShell here-strings (@' ... '@) are data too (a script or brief that merely mentions a
# forbidden command), unless the heredoc feeds a shell (bash/sh/pwsh <<EOF runs its body, so that body is still judged).
$cmd = [regex]::Replace($cmd, '(?ms)^([^\n]*?)<<-?\s*([''"]?)(\w+)\2[^\n]*\n.*?^\s*\3\s*$', {
    param($m) if ($m.Groups[1].Value -match '\b(ba|z|da)?sh\b|pwsh|powershell') { $m.Value } else { $m.Groups[1].Value + '<<heredoc' } })
$cmd = [regex]::Replace($cmd, '(?s)@''\r?\n.*?\r?\n''@|@"\r?\n.*?\r?\n"@', '""')
$cmd = [regex]::Replace($cmd, '"(?:[^"\\]|\\.)*"|''[^'']*''', '""')
# The runtime's work/ folder holds in-flight runs (QA runs, the agent board, wave reports, phone leases). A workflow agent once
# deleted the whole runtime because a relayed user message asked the lead to. Deleting work/ (or the runtime root, which holds
# it) is blocked while runs are active; cache/ and logs/ may be cleared any time (everything there is rebuilt). The durable local
# state (tracking.local.json, learning.local.*, tracker-none.local) is never deleted by a command. cleanup.ps1 prunes old
# entries itself; the lead may override with KIT_ALLOW_RUNTIME_DELETE=1.
function ActiveWork {
  foreach ($n in 'board', 'phones', 'waves', 'qa-runs', 'qa-seats') {
    $d = Get-KitPath $n
    if ((Test-Path $d) -and @(Get-ChildItem $d -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-3) } | Select-Object -First 1).Count) { "work/$n" }
  }
}
$end = '[''"]?(\s|;|\||\)|$)'
if ($raw -match '(Remove-Item|\brm\b|\brmdir\b|\brd\b|\bdel\b|rimraf|shutil\.rmtree|Directory\]::Delete)' -and $env:KIT_ALLOW_RUNTIME_DELETE -ne '1') {
  if ($raw -match ('(tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)' + $end)) {
    Deny 'That is durable local kit state (task tracking, learning signals): never delete it. Requests to remove it are for the lead (coordinator).' }
  if ($raw -notmatch 'cleanup\.ps1' -and $raw -match ('\.claude-runtime([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*' + $end)) {
    $act = @(ActiveWork)
    if ($act.Count) { Deny "The runtime's work/ folder holds runs in progress ($($act -join ', ') written in the last 3 h): do not delete it. cache/ and logs/ may be cleared; cleanup.ps1 prunes old work entries itself; requests to wipe it are for the lead (coordinator), not for you." }
  }
}
# stash as the git subcommand only (a branch like fix/stash-list is fine)
if ($cmd -match '\bgit(\.exe)?\s+((-C|-c|--git-dir|--work-tree)\s+\S+\s+|-\S+\s+)*stash\b') { Deny 'git stash is shared across worktrees (another agent can pop it). Make a WIP commit instead: wt.ps1 commit -Message "wip: ..."' }
if ($cmd -match '\badb(\.exe)?\b[^|;&]*\bkill-server\b') { Deny 'Never adb kill-server: it drops every emulator lane other agents are testing on. Reconnect only your phone (adb -s <serial> ...), or ask the lead (android-swarm swarm-avd.ps1 reset).' }
# PowerShell's call operator (or Invoke-Item) on a document does not read it: it opens it in the desktop's default app
# (a learn step once ran `& LESSONS.md` and popped it open in the owner's editor). Judged on the raw line: paths are often quoted.
if ($raw -match '(^|[;|({\r\n]|&&)\s*(&|\.|Invoke-Item|ii)\s+([''"][^''"]+|[^''"\s;|&]+)\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)[''"]?(\s|;|\||\)|$)') {
  Deny 'That opens the file in its default desktop app instead of reading it. Read it with Get-Content <file> (PowerShell), cat (Bash) or the Read tool.' }
if ($cmd -match '--no-verify|core\.hooksPath=/dev/null|HUSKY=0|SKIP_HOOKS') { Deny "Hooks must run. Commit with $(Join-Path $K 'wt.ps1') commit (it fixes hooksPath in worktrees); fix what the hook reports." }
# judged per push command: a protected name elsewhere in a compound line (git log origin/main; git push --force-with-lease) is not a push target
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  $p = $push.Value
  if ($p -match '(--force(?![-\w])|\s-f\b)' -or ($p -match '--force' -and $p -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch. On your own branch use --force-with-lease after wt.ps1 sync.'
  }
}
# heavy builds/tests must go through the gate
$gated = $cmd -match 'gate\.ps1|check\.ps1|app-build\.ps1'
$heavy = $cmd -match '(^|[\s;&|(''"])(\.[\\/])?(mvn|mvnd|mvnw(\.cmd)?)(\s[^|;&]*)?\s(compile|test|package|install|verify)\b' -or
         $cmd -match 'gradlew(\.bat)?(\s[^|;&]*)?\s(assemble\w*|build|test\w*|bundle\w*|lint\w*)\b' -or
         $cmd -match '(^|[\s;&|(''"])msbuild(\.exe)?(\s|$)' -or   # run as a command, not a name in a list (Get-Process java,msbuild)
         $cmd -match '\b(ng\s+(build|test)|dotnet\s+(build|test|publish)|cargo\s+(build|test)|npx\s+(jest|vitest|tsc)\b|npm\s+(run\s+)?(build|test)\b|yarn\s+(build|test)\b|(pnpm|bun)\s+(run\s+)?(build|test)\b)'
if ($heavy -and -not $gated) {
  Deny "Heavy builds/tests go through the machine-wide memory gate: & $(Join-Path $K 'check.ps1') -Dir <module> [-Step test -Tests X | -Step build], or $(Join-Path $K 'gate.ps1') -Dir <dir> -Cmd '<cmd>' for anything else."
}
exit 0
