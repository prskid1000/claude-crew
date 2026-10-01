<#
PreToolUse guard (Bash + PowerShell tools) for every session in this workspace (wired in .claude\settings.json).
Turns the kit's hard rules into enforcement instead of advice:
  - no `git stash` (the stash is shared across worktrees)
  - no `--no-verify` / hook skipping
  - no force-push to a protected branch (main, master, develop, release/*, plus kit.local.json "protectedBranches")
  - heavy builds/tests go through the memory gate (check.ps1 / gate.ps1), not straight to mvn/gradle/dotnet/ng/jest/...
Reads the hook JSON on stdin; prints a deny decision with the reason, or nothing (= allow).
Every block is logged to <.claude-runtime>\guard.log so /kit-retro can learn from repeated mistakes.
#>
$ErrorActionPreference = 'SilentlyContinue'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$cmd = [string]$in.tool_input.command
if (-not $cmd) { exit 0 }
$K = Split-Path $PSCommandPath   # this kit's dev-kit\scripts folder (messages point agents at the right scripts)
# extra shared branches from kit.local.json (optional); kept cheap: this runs before every shell command
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path (Split-Path $K) 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  $rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
  New-Item -ItemType Directory -Force $rt | Out-Null
  "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$(($raw -replace "[\r\n\t]+", " // ").Substring(0, [math]::Min(200, ($raw -replace "[\r\n\t]+", " // ").Length)))" | Add-Content (Join-Path $rt 'guard.log')
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  exit 0
}

# Judge the command words only: text inside quotes (grep patterns, commit messages, learn.ps1 -Text "...") is not a command.
$raw = $cmd
$cmd = [regex]::Replace($cmd, '"(?:[^"\\]|\\.)*"|''[^'']*''', '""')
if ($cmd -match '\bgit\b[^|;&]*\bstash\b') { Deny 'git stash is shared across worktrees (another agent can pop it). Make a WIP commit instead: wt.ps1 commit -Message "wip: ..."' }
if ($cmd -match '--no-verify|core\.hooksPath=/dev/null|HUSKY=0|SKIP_HOOKS') { Deny "Hooks must run. Commit with $K\wt.ps1 commit (it fixes hooksPath in worktrees); fix what the hook reports." }
if ($cmd -match '\bgit\b[^|;&]*\bpush\b[^|;&]*(--force(?!-with-lease)|\s-f\b)' -or ($cmd -match '\bgit\b[^|;&]*\bpush\b[^|;&]*--force' -and $cmd -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
  Deny 'Never force-push a shared branch. On your own branch use --force-with-lease after wt.ps1 sync.'
}
# heavy builds/tests must go through the gate
$gated = $cmd -match 'gate\.ps1|check\.ps1|app-build\.ps1'
$heavy = $cmd -match '(^|[\s;&|(''"])(\.\\)?(mvn|mvnd|mvnw(\.cmd)?)(\s[^|;&]*)?\s(compile|test|package|install|verify)\b' -or
         $cmd -match 'gradlew(\.bat)?(\s[^|;&]*)?\s(assemble\w*|build|test\w*|bundle\w*|lint\w*)\b' -or
         $cmd -match '\b(ng\s+(build|test)|dotnet\s+(build|test|publish)|msbuild\b|cargo\s+(build|test)|npx\s+(jest|vitest|tsc)\b|npm\s+(run\s+)?(build|test)\b|yarn\s+(build|test)\b)'
if ($heavy -and -not $gated) {
  Deny "Heavy builds/tests go through the machine-wide memory gate: & $K\check.ps1 -Dir <module> [-Step test -Tests X | -Step build], or $K\gate.ps1 -Dir <dir> -Cmd '<cmd>' for anything else."
}
exit 0
