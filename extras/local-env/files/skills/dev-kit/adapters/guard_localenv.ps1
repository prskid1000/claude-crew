# local-env (extra): dev.ps1 guard rules: a localenv/<env> branch is never pushed; dev servers start in the shared local env, not by hand.
Register-KitAdapter 'guard' 'local-env' @{ check = { param($a)
    $cmd = $a.cmd
    foreach ($push in [regex]::Matches($cmd, '\bgit\b[^|;&]*\bpush\b[^|;&]*')) {
      if ($push.Value -match '(^|[\s:/])localenv/' -and $push.Value -notmatch '\s--delete\b|\s-d\s|\s:localenv/') { return 'localenv/<env> is a local env branch (all agents'' layers merged): never push it. Push your branch; localenv.ps1 deploy -Dir <worktree> takes it.' }
    }
    if (-not ($env:KIT_GUARD_SELFTEST_ACTIVE -eq '1' -or $a.config.localEnv) -or $cmd -match 'localenv\.ps1') { return }
    $server = '^(\.?[\\/])?(mvnw(\.cmd)?|mvn)\b.*\bspring-boot:run\b|^(\.?[\\/])?(gradlew(\.bat)?|gradle)\b.*\bbootRun\b|^(npx\s+)?ng\s+serve\b|^dotnet\s+(run|watch)\b(?!.*\s--\s)|^npx\s+(react-native|expo)\s+start\b|^(python\d?\s+)?manage\.py\s+runserver\b|^uvicorn\s|^flask\s+run\b|^(npm|yarn|pnpm|bun)\s+(run\s+)?(dev|start|serve)\s*$'
    foreach ($seg in @($cmd -split '\r?\n|;|&&|\|\||\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
      if ($seg -match $server) { return "Dev servers run in the shared local env, not by hand: & $($KitCmd.local) use|up -Env <env> (list: envs; logs: logs -Env <env> -Service <s>)." }
    }
  } }
