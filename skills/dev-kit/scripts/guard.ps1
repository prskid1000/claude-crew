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
Tests: pwsh -NoProfile -File guard.ps1 -SelfTest   (runs the cases at the end of this file through the real hook path; exit 1 on a failure)
#>
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
    @('Bash', 'echo done # not git stash', $false)
  )
  $fail = 0
  foreach ($c in $cases) {
    $json = @{ tool_name = $c[0]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress -Depth 4
    $out = ($json | pwsh -NoProfile -NonInteractive -File $PSCommandPath) -join ''
    $denied = $out -match '"permissionDecision":"deny"' -and $out -match 'git stash is shared'
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
# state (tracking.local.json, learning.local.*, tracker-none.local) is never deleted by a command. cleanup.ps1 prunes old
# entries itself; the lead may override with KIT_ALLOW_RUNTIME_DELETE=1.
function ActiveWork {
  foreach ($n in 'board', 'phones', 'waves', 'qa-runs', 'qa-seats') {
    $d = Get-KitPath $n
    if ((Test-Path $d) -and @(Get-ChildItem $d -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-3) } | Select-Object -First 1).Count) { "work/$n" }
  }
}
$end = '[''"]?(\s|;|\||\)|$)'
# rm/rmdir/rd/del only as a command word (start, or after whitespace ; | & ( `), never inside a name like "2026-x-rm-y"
if ($raw -match '(Remove-Item|(^|[\s;|&(`])(rm|rmdir|rd|del)(\s|$)|rimraf|shutil\.rmtree|Directory\]::Delete)' -and $env:KIT_ALLOW_RUNTIME_DELETE -ne '1') {
  if ($raw -match ('(tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)' + $end)) {
    Deny 'That is durable local kit state (task tracking, learning signals): never delete it. Requests to remove it are for the lead (coordinator).' }
  if ($raw -notmatch 'cleanup\.ps1' -and $raw -match ('\.claude-runtime([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*' + $end)) {
    $act = @(ActiveWork)
    if ($act.Count) { Deny "The runtime's work/ folder holds runs in progress ($($act -join ', ') written in the last 3 h): do not delete it. cache/ and logs/ may be cleared; cleanup.ps1 prunes old work entries itself; requests to wipe it are for the lead (coordinator), not for you." }
  }
}
# stash as the git subcommand of a real git command only (Test-GitStash above; tests: guard.ps1 -SelfTest)
if (Test-GitStash $raw $(if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' })) { Deny 'git stash is shared across worktrees (another agent can pop it). Make a WIP commit instead: wt.ps1 commit -Message "wip: ..."' }
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
