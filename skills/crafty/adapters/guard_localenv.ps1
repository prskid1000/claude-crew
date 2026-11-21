#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# guard rules (crafty.ps1 guard): local-env: a localenv/<env> branch is never pushed; dev servers start in the shared local env, not by
# hand; deployed-env (K56): no hand change of a deployed env's config or runtime without an owner's decision; large-writes: no
# synthetic bulk data, scratch schema on a shared DB, big import, full dump or copied dependency / data tree; secrets: no command reads targets.local.json.
# Sections: L7 local-env · L20 deployed-env · L37 large-writes · L66 secrets
# ---- local-env: lane branch pushes, hand-started dev servers
Register-KitAdapter 'guard' 'local-env' @{ check = { param($a)
    $cmd = $a.cmd
    foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
      if ($push.Value -match '(^|[\s:/])(localenv|lane)/' -and $push.Value -notmatch '\s--delete\b|\s-d\s|\s:(localenv|lane)/') { return 'lane/<lane> (old: localenv/<env>) is a local env branch (all agents'' layers merged): never push it. Push your branch; envy.ps1 deploy -Dir <worktree> takes it.' }
    }
    if (-not ($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1' -or $a.config.localEnv) -or $cmd -match 'envy\.ps1') { return }
    $server = '^(\.?[\\/])?(mvnw(\.cmd)?|mvn)\b.*\bspring-boot:run\b|^(\.?[\\/])?(gradlew(\.bat)?|gradle)\b.*\bbootRun\b|^(npx\s+(-\S+\s+)*)?ng\s+serve\b|^dotnet\s+(run|watch)\b(?!.*\s--\s)|^npx\s+(react-native|expo)\s+start\b|^(python\d?\s+)?manage\.py\s+runserver\b|^uvicorn\s|^flask\s+run\b|^(npm|yarn|pnpm|bun)\s+((--cwd|--prefix|--dir|-C)\s+\S+\s+|workspace\s+\S+\s+)?(run\s+)?(dev|start|serve)(\s|$)|^(npm|yarn|pnpm|bun)\s+(run\s+)?ng\s+serve\b|^Start-Process\b.*\b(npm|yarn|pnpm|bun|ng)(\.cmd)?\b.*\b(start|serve|dev)\b'
    # a subshell, background or env-prefixed start counts too: (yarn start --host 0.0.0.0 > ui.log 2>&1 &)
    foreach ($seg in @($cmd -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() -replace '^[\s(&]+', '' -replace '^((\w+=\S*|nohup|setsid|exec|time|sudo|env)\s+)+', '' } | Where-Object { $_ })) {
      if ($seg -match $server) { return "Dev servers run in the shared local env as lane services (port, RAM and lease counted), not by hand: & $($KitCmd.local) restart -Env <lane> -Services web (start: up -Env <env>; list: envs; logs: logs -Env <env> -Service <s>)." }
    }
  } }
# ---- deployed-env: hand changes of a deployed env (K56)
Register-KitAdapter 'guard' 'deployed-env' @{ check = { param($a)
  # a deployed env's config or runtime changed by hand restarts it under everyone (K56, 2026-11-17: a tester's env-option toggle restarted a
  # test env twice, 502s for other runs): only with an owner's deploy decision on the line (KIT_DECISION=<id>); kit deploy verbs run inside scripts
  # quoted text is data (a commit message), a quoted exe path counts as its name, a shell's -c / -Command payload is a command too
  $envChg = Get-KitEnvChangeRx
  if ($envChg) {
    $envDoc = [regex]::Replace((StripDocs $a.raw), '["''][^"''\r\n]*[\\/]([\w.-]+)["'']', ' $1')
    $envTxt = @(StripData $envDoc) + @([regex]::Matches($envDoc, '(?:^|\s)(?:-c|-Command|/c)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')') | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value })
    $envHit = @(foreach ($et in $envTxt) { $em = [regex]::Match($et, $envChg); if ($em.Success) { $em.Groups['verb'].Value; break } })
    if ($envHit.Count) {
      # the owner's word for this target (the env / cluster / function / namespace on the line), used once
      $tgt = if ($a.raw -match '--(?:environment-name|cluster|function-name|service|name|namespace|app)[ =](?<t>[^\s;&|"'']+)|\s-n\s+(?<t>[^\s;&|"'']+)') { $Matches.t } else { '' }
      $dId = if ($a.raw -match '\bKIT_DECISION\s*=\s*[''"]?(?<d>d-[\w-]+)') { $Matches.d }
      if (-not ($dId -and $tgt -and "$(pwsh -NoProfile -File $KitCmd.orch decide check -Id $dId -Gate deploy -Item $tgt -MaxHours 12 -Use -Agent guard)" -match '^WORD ')) {
        return "kit guard: that changes a deployed env's config or restarts it ($("$($envHit[0])" -replace '\s+', ' ')), which restarts it for every run and tester on it. A feature behind an env switch that is off there is NOT_TESTED (tool-down) plus bossy.ps1 decide ask; never toggle it. With the owner's yes for this one change: bossy.ps1 decide record -Gate deploy -Item <the env / cluster / function name on the line> ..., then KIT_DECISION=<decision id> <command> (one use)" } } }
  } }
# ---- large-writes: bulk data, scratch schemas, big imports, dumps, copied trees
# large writes (owner, 2026-11-18: a benchmark's 2.1M-row scratch schema on the shared DB wrote ~4 GB to C:): a row generator past
# data.maxRows, a scratch schema on a shared DB server, a load / import file past data.maxMB, a full dump, a recursive copy of a
# dependency or data tree; kit scripts (envy, tests) run their own SQL and are not agent commands
Register-KitAdapter 'guard' 'large-writes' @{ check = { param($a)
  $lw = "$($a.raw)"
  # cheap first: no trigger word, no rule; a lone envy.ps1 call (its own SQL) passes, an envy call chained with more does not
  if (-not $lw -or $lw -notmatch '(?i)create|generate_series|range|\bseq\b|executemany|recursive|infile|dump|\bcp\b|copy|robocopy|xcopy|archive|<|\.\.\d' -or
    ($lw -match '^\s*(&\s*)?(pwsh\s+(-\S+\s+)*)?["'']?[^\s"'']*envy\.ps1' -and $lw -notmatch '[;&|]')) { return }
  $lwRows = [long](Get-KitParam 'data.maxRows'); $lwMB = [double](Get-KitParam 'data.maxMB')
  $lwBig = { param($f) $lwF = $f.Trim('"', "'"); (Test-Path -LiteralPath $lwF -PathType Leaf) -and (Get-Item -LiteralPath $lwF).Length -gt $lwMB * 1MB }
  # a client at a command position (not a word in rg / git / gh text): a quoted Windows path, an env prefix, after ; & | or a new line
  $lwBare = [regex]::Replace($lw, '"[^"]*"|''[^'']*''', { param($q) if ($q.Value -match '[\\/](mysql|mariadb|psql|sqlcmd|mysqladmin)(\.exe)?["'']$') { $Matches[1] } else { '""' } })   # quoted text is data, a quoted exe path its name
  $lwClient = '(?im)(?:^|[;&|(]\s*|\n\s*)(?:&\s*)?(?:\w+=\S*\s+)*(mysql|mariadb|psql|sqlcmd|mysqladmin)(\.exe)?(\s|$)'
  $lwPort = if ($lw -match '(?:\s-P\s*|--port[= ]|\bpsql\b[^|;&]*\s-p\s*|\bMYSQL_TCP_PORT=)(\d+)') { [int]$Matches[1] } else { 0 }
  $lwShared = @(3306, 5432, 1433) + @(foreach ($lwE in @(Get-KitProps $a.config.localEnv.envs)) { @($lwE.Value.services | Where-Object { $_.external -and $_.port } | ForEach-Object { [int]$_.port }) })
  # the count bound to its generator: range(N) / range(a, N), generate_series(a, N), seq [a] N, n < N in a recursive CTE, a..N, 10**k,
  # 1ek (alone: a uuid / hex group such as 4eeb-93e6-cf44 is an id, not a count)
  $lwGen = '(?i)\brange\s*\(\s*(?:\d[\d_]*\s*,\s*)?(\d[\d_]*)\s*[,)]|\bgenerate_series\s*\(\s*\d+\s*,\s*(\d+)|\bseq\s+(?:\d+\s+)*(\d+)\b|\bRECURSIVE\b[\s\S]*?\b\w+\s*<=?\s*(\d+)\b|\b\d+\.\.(\d[\d_]*)\b|\b10\s*\*\*\s*(\d)\b|(?<![\w.:/-])\d+e(\d)(?![\w.:/-])'
  $lwGenHit = @([regex]::Matches($lw, $lwGen) | Where-Object { $m = $_; @(1..7 | Where-Object { $m.Groups[$_].Success } | ForEach-Object {
      $v = [long]($m.Groups[$_].Value -replace '_'); if ($_ -ge 6) { [Math]::Pow(10, $v) } else { $v } } | Where-Object { $_ -gt $lwRows }).Count }).Count
  $lwWhy = if ($lwGenHit) { "a row generator past data.maxRows ($lwRows)" }
    elseif ((($lw -match '(?i)\bCREATE\s+(DATABASE|SCHEMA)\b' -and $lwBare -match $lwClient) -or $lw -match '\bmysqladmin\b[^|;&\r\n]*\bcreate\b') -and (-not $lwPort -or $lwPort -in $lwShared)) { "a scratch schema on a shared DB server (port $(if ($lwPort) { $lwPort } else { 'default' }))" }
    elseif (($lw -match '(?i)\bLOAD\s+DATA\s+(?:LOCAL\s+)?INFILE\s+(\S+)' -or $lw -match '\b(?:mysql|psql)\b[^|;&<\r\n]*<\s*(\S+)') -and (& $lwBig $Matches[1])) { "a load or import of a file past data.maxMB ($lwMB MB)" }
    elseif ($lw -match '\bmysqldump\b[^|;&\r\n]*(--all-databases|\s-A\b)|\bpg_dumpall\b') { 'a full dump' }
    elseif ($lw -match '(?i)(\bcp\s+-\w*[rR]|\bCopy-Item\b(?=[^|;&\r\n]*\s-Recurse\b)|\brobocopy\b|\bxcopy\b)[^|;&\r\n]*(node_modules|(?<![\w-])\.m2\b|(?<![\w-])\.gradle\b|\.worktrees|(?<![\w-])\.venv\b|datadir|[\\/]mysql[\\/]data\b|[\\/]mysql-\d[\w.-]*[\\/](data|var)\b)') { 'a recursive copy of a dependency, worktree or data tree (link or move it)' }
    elseif ($lw -match '(?i)\bgit\b(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+archive\b([^|;&<>\r\n]*)' -and @(($Matches[1] -replace '(?i)\s(-o|--output|--prefix|--remote|--format)(\s+|=)\S+', ' ' -split '\s+') | Where-Object { $_ -and $_ -notlike '-*' }).Count -eq 1) { 'a whole-repo export (git archive without a path: a review export wrote 323 MB; read the ref with git show <ref>:<path> / git diff, or a crafty.ps1 wt worktree)' }
  if ($lwWhy) { "kit guard: that writes large data ($lwWhy). No large writes (AGENTS.md): performance questions -> EXPLAIN / query plans, index checks, the fixtures, the read-only replica; data you add stays under data.maxRows / data.maxMB, on the kit-test or a leased lane DB, dropped at the run's end. A needed exception: bossy.ps1 decide ask (the owner runs it)." }
} }
# ---- secrets: test logins (owner 2026-11-19: QA agents printed passwords): no command reads targets.local.json; a grep of the bare name is a pattern
Register-KitAdapter 'guard' 'secrets' @{ check = { param($a)
  $secRead = '(?i)(^|[\s;|&(`])(cat|type|more|less|head|tail|sed|awk|jq|bat|strings|xxd|od|base64|cp|copy|Copy-Item|cpi|Get-Content|gc|Import-Csv|scp|curl)(\.exe)?\s|open\(|readFile|ReadAll(Text|Lines|Bytes)|json\.load'
  # a commit message is text, not a read (2026-11-21: a message quoting the file name was denied); $( ) or ` in it still runs
  $secCmd = "$($a.raw)"
  if ($secCmd -match '(?i)\bcommit\b') {
    $secCmd = $secCmd -replace '(?i)(-m|--message|-Message)(=|\s*)"\$\(cat\s+<<-?\s*''(\w+)''\r?\n[\s\S]*?\r?\n\s*\3\s*\r?\n?\s*\)"', '$1 MSG' `
      -replace '(?i)(-F|--file)(=|\s+)-\s+<<-?\s*''(\w+)''\r?\n[\s\S]*?\r?\n\s*\3(?=\s*(\r?\n|$))', '$1 - MSG' `
      -replace '(?i)(-m|--message|-Message)\s+@''\r?\n[\s\S]*?\r?\n''@', '$1 MSG' `
      -replace '(?i)(-m|--message|-Message)(=|\s+)''[^'']*''', '$1 MSG' `
      -replace '(?i)(-m|--message|-Message)(=|\s+)"[^"$`\\]*"', '$1 MSG'
    # no escapes inside: '' (pwsh) or \" (bash) means another quote in the other shell; unstripped text is checked (a safe deny)
  }
  if (@($secCmd -split '[;&|\r\n]+' | Where-Object { $_ -match '(?i)targets\.local\.json' -and ($_ -match $secRead -or ($_ -match '(?i)\b(grep|egrep|rg|findstr|Select-String|sls)\b' -and $_ -match '(?i)[\/]targets\.local\.json')) }).Count) {
    'kit guard: skills/pokey/targets.local.json holds test logins: never read or print it. Instead: names + tenants: pokey.ps1 user list -Target <t> · a call: pokey.ps1 api -Target <t> -As <login> -Method GET -Path ''/...'' · a browser: session({ target, as }) · an app: pokey.ps1 ui login -Target <t> -As <login> · none fits: pokey.ps1 user create -Target <t> -Name <login> -Role <role> · keys: kitbag.py audit config' } } }
