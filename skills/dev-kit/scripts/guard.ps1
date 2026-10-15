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
    @('Bash', 'echo done # not git stash', $false),
    # [tool, command, expect deny?, deny message] - opening a document with & / . / Invoke-Item instead of reading it
    @('PowerShell', '& D:\kit\skills\dev-kit\LESSONS.md', $true, 'default desktop app'),
    @('PowerShell', '& "C:\x y\notes.txt"', $true, 'default desktop app'),
    @('PowerShell', 'Invoke-Item .\report.html', $true, 'default desktop app'),
    @('PowerShell', 'cd x; ii "out.pdf"', $true, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Text "resumed agent; . RESUME_BRIEF.md was read (see notes.md); & LESSONS.md"', $false, 'default desktop app'),
    @('PowerShell', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, 'default desktop app'),
    @('PowerShell', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text "X2 (a b): fixed via helper buildX plus unit test; MR merged on first run, no retries" -Ref B-1 -Source workflow', $false, 'default desktop app'),
    @('PowerShell', "& D:/kit/learn.ps1 -Skill dev-kit -Kind friction -Text `"Stopped agent left a commit; merge reported via devtools.py 'merged' but not verified`" -Ref repo!1 -Source workflow`n& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"recovery worked`" -Ref repo!1", $false, 'default desktop app'),
    @('PowerShell', '& D:/kit/learn.ps1 -Skill dev-kit -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, 'default desktop app'),
    @('PowerShell', "& D:/kit/learn.ps1 -Skill dev-kit -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/dev-kit/LESSONS.md | Out-Null", $true, 'default desktop app'),
    # [.., 'holds runs in progress'] - deleting the runtime's work/ ({RT} = the runtime folder name; judged as if runs were active)
    @('Bash', "cd /d/x/{RT}/work/qa-runs; mkdir -p 2026-01-01-run && cd 2026-01-01-run; GWS=`$(python -c `"import shutil;print(shutil.which('gws'))`"); for p in A:1 B:2; do c=`${p%%:*}; `"`$GWS`" drive files export -o `$c.txt >/dev/null 2>&1; done", $false, 'holds runs in progress'),
    @('Bash', "cd D:/x/{RT} && mkdir -p work/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/g5/body.md; cat >> work/g5/body.md <<'EOF'`n## Review follow-up`n- Plain RM check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/g5/body.md)`"", $false, 'holds runs in progress'),
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
    @('PowerShell', '& D:/kit/skills/local-env/scripts/localenv.ps1 up -Env shop', $false, 'local env'),
    @('PowerShell', 'git commit -m "fix: ng serve proxy"', $false, 'local env'),
    @('Bash', 'rg "ng serve" src', $false, 'local env'),
    @('Bash', 'git log -S bootRun --oneline', $false, 'local env'),
    @('Bash', 'npm run dev:build', $false, 'local env'),
    @('PowerShell', 'dotnet run -- migrate', $false, 'local env'),
    @('Bash', 'cd web && yarn start', $true, 'local env'),
    @('Bash', 'git push origin --delete localenv/shop', $false, 'local env')
  )
  $env:KIT_GUARD_SELFTEST_ACTIVE = '1'   # inherited by the hook runs below (also: judge as if localEnv were configured)
  $fail = 0
  foreach ($c in $cases) {
    $json = @{ tool_name = $c[0]; tool_input = @{ command = $c[1].Replace('{RT}', '.claude-runtime') } } | ConvertTo-Json -Compress -Depth 4
    $out = ($json | pwsh -NoProfile -NonInteractive -File $PSCommandPath) -join ''
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
$K = Split-Path $PSCommandPath   # this kit's dev-kit\scripts folder (messages point agents at the right scripts)
. (Join-Path $K 'kitpaths.ps1')   # Get-KitPath (cheap: no CLI lookups)
# extra shared branches from kit.local.json (optional); kept cheap: this runs before every shell command
$protected = @('main', 'master', 'develop', 'release/\S+')
try { $kc = Get-Content (Join-Path (Split-Path $K) 'kit.local.json') -Raw -ErrorAction Stop | ConvertFrom-Json; $protected += @($kc.protectedBranches | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }) } catch {}

function Deny($why) {
  if ($in.session_id) {   # only real hook calls are logged: test runs (no session) must not raise supervise's guard WATCH
    "$((Get-Date).ToString('s'))`t$($in.session_id)`t$why`t$(($raw -replace "[\r\n\t]+", " // ").Substring(0, [math]::Min(1000, ($raw -replace "[\r\n\t]+", " // ").Length)))" | Add-Content (Get-KitPath guard-log -Create)
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
    if ($seg -match '^\s*(cd|Set-Location|sl|pushd|Push-Location)\s') { $inRuntime = $seg -match '\.claude-runtime([\\/]+work)?[\\/]*\s*$'; continue }
    if ($seg -notmatch $delWord) { continue }
    if ($seg -match ('(tracking\.local\.json|learning\.local\.(jsonl|stamp)|tracker-none\.local)' + $end)) {
      Deny 'That is durable local kit state (task tracking, learning signals): never delete it. Requests to remove it are for the lead (coordinator).' }
    if ($seg -match 'cleanup\.ps1') { continue }
    if ($seg -match ('\.claude-runtime([\\/]+work([\\/]+[\w.-]+)?)?[\\/]*' + $end) -or
        ($inRuntime -and $seg -match '\s[''"]?(\.[\\/])?(work([\\/]+[\w.-]+)?|\*|\.)[\\/]*[''"]?(\s|$)')) {
      $act = @(ActiveWork)
      if ($act.Count) { Deny "The runtime's work/ folder holds runs in progress ($($act -join ', ') written in the last 3 h): do not delete it. cache/ and logs/ may be cleared; cleanup.ps1 prunes old work entries itself; requests to wipe it are for the lead (coordinator), not for you." }
    }
  }
}
# stash as the git subcommand of a real git command only (Test-GitStash above; tests: guard.ps1 -SelfTest)
if (Test-GitStash $raw $(if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' })) { Deny 'git stash is shared across worktrees (another agent can pop it). Make a WIP commit instead: wt.ps1 commit -Message "wip: ..."' }
if ($cmd -match '\badb(\.exe)?\b[^|;&]*\bkill-server\b') { Deny 'Never adb kill-server: it drops every emulator lane other agents are testing on. Reconnect only your phone (adb -s <serial> ...), or ask the lead (android-swarm swarm-avd.ps1 reset).' }
# PowerShell's call operator (or Invoke-Item) on a document does not read it: it opens it in the desktop's default app
# (a learn step once ran `& LESSONS.md` and popped it open in the owner's editor).
# PowerShell: judged on the parse tree (a document path inside a quoted -Text "..." argument once tripped the raw-line regex);
# Bash or unparsable text: the regex on the line with quoted strings and heredocs stripped.
function Test-OpenDoc([string]$text, [string]$tool) {
  $doc = '\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)$'
  # A kit script call (& <path>.ps1|.py|.mjs ...) is a script run: the rest of its line is its arguments (a learn.ps1 -Text "..."
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
        if ((& $val $el[0]) -match '^(Invoke-Item|ii)$' -and @($el | Select-Object -Skip 1 | Where-Object { (& $val $_) -match $doc }).Count) { return $true }
      }
      return $false
    }
  }
  (StripData $text) -match '(^|[;|({\r\n]|&&)\s*(&|\.|Invoke-Item|ii)\s+[^\s;|&]+\.(md|txt|jsonl?|html?|log|csv|xml|ya?ml|png|jpe?g|pdf)(\s|;|\||\)|$)'
}
if (Test-OpenDoc $raw $(if ($in.tool_name -eq 'Bash') { 'Bash' } else { 'PowerShell' })) {
  Deny 'That opens the file in its default desktop app instead of reading it. Read it with Get-Content <file> (PowerShell), cat (Bash) or the Read tool.' }
if ($cmd -match '--no-verify|core\.hooksPath=/dev/null|HUSKY=0|SKIP_HOOKS') { Deny "Hooks must run. Commit with $(Join-Path $K 'wt.ps1') commit (it fixes hooksPath in worktrees); fix what the hook reports." }
# judged per push command: a protected name elsewhere in a compound line (git log origin/main; git push --force-with-lease) is not a push target
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  $p = $push.Value
  if ($p -match '(--force(?![-\w])|\s-f\b)' -or ($p -match '--force' -and $p -match ('\b(origin\s+)?(' + ($protected -join '|') + ')\b(?!-)'))) {
    Deny 'Never force-push a shared branch. On your own branch use --force-with-lease after wt.ps1 sync.'
  }
}
# Local environments (local-env skill): the env branches localenv/<env> are local merges of every agent's layer, never pushed;
# with localEnv configured, dev servers run only as env services (one instance, shared, RAM-checked), never started by hand.
foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
  if ($push.Value -match '(^|[\s:/])localenv/' -and $push.Value -notmatch '\s--delete\b|\s-d\s|\s:localenv/') { Deny 'localenv/<env> is a local env branch (a merge of every agent''s layer): never push it. Push your own branch; the local env takes it with localenv.ps1 deploy -Dir <worktree>.' }
}
if (($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1' -or $kc.localEnv) -and $cmd -notmatch 'localenv\.ps1|metro-start\.ps1') {
  $server = '^(\.?[\\/])?(mvnw(\.cmd)?|mvn)\b.*\bspring-boot:run\b|^(\.?[\\/])?(gradlew(\.bat)?|gradle)\b.*\bbootRun\b|^(npx\s+)?ng\s+serve\b|^dotnet\s+(run|watch)\b(?!.*\s--\s)|^npx\s+(react-native|expo)\s+start\b|^(python\d?\s+)?manage\.py\s+runserver\b|^uvicorn\s|^flask\s+run\b|^(npm|yarn|pnpm|bun)\s+(run\s+)?(dev|start|serve)\s*$'
  foreach ($seg in @($cmd -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($seg -match $server) {
      Deny "Dev servers run in the shared local env (one instance per env, RAM-checked), not by hand: & $(Join-Path (Split-Path (Split-Path $K)) 'local-env/scripts/localenv.ps1') use|up -Env <env> (envs: localenv.ps1 envs). Logs: localenv.ps1 logs -Env <env> -Service <s>."
    }
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
