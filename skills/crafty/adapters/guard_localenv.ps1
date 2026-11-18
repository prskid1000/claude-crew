#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# guard rules (crafty.ps1 guard): local-env: a localenv/<env> branch is never pushed; dev servers start in the shared local env, not by
# hand; deployed-env (K56): no hand change of a deployed env's config or runtime without an owner's decision; large-writes: no
# synthetic bulk data, scratch schema on a shared DB, big import, full dump or copied dependency / data tree.
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
# large writes (owner, 2026-11-18: a benchmark's 2.1M-row scratch schema on the shared DB wrote ~4 GB to C:): a row generator past
# data.maxRows, a scratch schema on a shared DB server, a load / import file past data.maxMB, a full dump, a recursive copy of a
# dependency or data tree; kit scripts (envy, tests) run their own SQL and are not agent commands
Register-KitAdapter 'guard' 'large-writes' @{ check = { param($a)
  $lw = "$($a.raw)"; if (-not $lw -or $lw -match 'envy\.ps1') { return }
  $lwRows = [long](Get-KitParam 'data.maxRows'); $lwMB = [double](Get-KitParam 'data.maxMB')
  $lwBig = { param($f) $lwF = $f.Trim('"', "'"); (Test-Path -LiteralPath $lwF -PathType Leaf) -and (Get-Item -LiteralPath $lwF).Length -gt $lwMB * 1MB }
  $lwPort = if ($lw -match '(?:\s-P\s*|--port[= ]|\bpsql\b[^|;&]*\s-p\s*)(\d+)') { [int]$Matches[1] } else { 0 }
  $lwShared = @(3306, 5432, 1433) + @(foreach ($lwE in @(Get-KitProps $a.config.localEnv.envs)) { @($lwE.Value.services | Where-Object { $_.external -and $_.port } | ForEach-Object { [int]$_.port }) })
  $lwWhy = if ($lw -match '(?i)\bWITH\s+RECURSIVE\b|\bgenerate_series\b|\bexecutemany\b|\brange\s*\(|\bseq\s+\d' -and @([regex]::Matches($lw, '(?<![\w.:-])\d[\d_]{4,}(?![\w.:-])') | Where-Object { [long]($_.Value -replace '_') -gt $lwRows }).Count) { "a row generator past data.maxRows ($lwRows)" }
    elseif ((($lw -match '(?i)\bCREATE\s+(DATABASE|SCHEMA)\b' -and $lw -match '\b(mysql|mariadb|psql|sqlcmd)(\.exe)?\s') -or $lw -match '\bmysqladmin\b[^|;&\r\n]*\bcreate\b') -and (-not $lwPort -or $lwPort -in $lwShared)) { "a scratch schema on a shared DB server (port $(if ($lwPort) { $lwPort } else { 'default' }))" }
    elseif (($lw -match '(?i)\bLOAD\s+DATA\s+(?:LOCAL\s+)?INFILE\s+(\S+)' -or $lw -match '\b(?:mysql|psql)\b[^|;&<\r\n]*<\s*(\S+)') -and (& $lwBig $Matches[1])) { "a load or import of a file past data.maxMB ($lwMB MB)" }
    elseif ($lw -match '\bmysqldump\b[^|;&\r\n]*(--all-databases|\s-A\b)|\bpg_dumpall\b') { 'a full dump' }
    elseif ($lw -match '(?i)(\bcp\s+-\w*[rR]|\bCopy-Item\b(?=[^|;&\r\n]*\s-Recurse\b)|\brobocopy\b|\bxcopy\b)[^|;&\r\n]*(node_modules|\.m2\b|\.gradle\b|\.worktrees|\.venv\b|datadir|[\\/]mysql[\w-]*([\\/"'' ]|$))') { 'a recursive copy of a dependency, worktree or data tree (link or move it)' }
  if ($lwWhy) { "kit guard: that writes large data ($lwWhy). No large writes (AGENTS.md): performance questions -> EXPLAIN / query plans, index checks, the fixtures, the read-only replica; data you add stays under data.maxRows / data.maxMB, on the kit-test or a leased lane DB, dropped at the run's end. A needed exception: bossy.ps1 decide ask (the owner runs it)." }
} }
