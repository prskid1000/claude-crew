#Requires -Version 7
<#
localenv.tests.ps1: localenv.ps1 leases, usage, migration detection, the missing-extra line, forwarding (LIGHT/HEAVY: extra localenv-sandbox).
Usage: pwsh -NoProfile -File <kit>/tests/localenv.tests.ps1 (or tests/kit-tests.ps1 -Area localenv).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
# localenv usage errors exit 2; a start-lock timeout throws, never runs unlocked
$k2 = New-TestKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ snapshot = 'echo s'; restore = 'echo r' } }; mig = @{ services = @(); sandbox = @{ services = @('api') } } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
$xo = Px $L2 deploy -Env mig -Branch b 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "localenv: config needing an extra stops with the extra line, exit 1 ($xc)" ($xc -eq 1 -and ($xo -replace '\s*\|?\s+', ' ') -match 'migration sandboxes and exact reverts are an extra: run kittool\.py extra add localenv-sandbox')
$fx = Join-Path $k2 'skills/local-env/localenv-sandbox.ps1'; Set-Content $fx '"forwarded $args"'; $fo = Px $L2 envs 2>&1 | Out-String; Remove-Item $fx
Expect "localenv: an installed localenv-sandbox extra runs instead ($fo)" ($fo.Trim() -eq 'forwarded envs')
$null = Px $L2 bogus 2>&1; $c1 = $LASTEXITCODE
$null = Px $L2 status -Env nope 2>&1; $c2 = $LASTEXITCODE
$null = Px $L2 drop -Env shop 2>&1; $c3 = $LASTEXITCODE
$pr = & { . $L2; $o = (Get-Date).AddMinutes(-11).ToString('o'); $u = (Get-Date).AddHours(1).ToString('o')
  $st = @{ leases = @{ dead = @{ until = $u; holderPid = 999999; seen = $o }; grace = @{ until = $u; holderPid = 999999; seen = (Get-Date).AddMinutes(-3).ToString('o') }; live = @{ until = $u; holderPid = $PID } }
    holds = @{ own = @{ owner = $true; until = (Get-Date).AddMinutes(5).ToString('o') }; old = @{ owner = $true; until = $o }; co = @{ agent = 'main'; seen = $o } }; requests = @() }
  Prune $st; "$(($st.leases.Keys | Sort-Object) -join ',')|$(($st.holds.Keys | Sort-Object) -join ',')|$($st.leases.grace.graceLeft)" }
Expect "leases: no live holder -> kept for the grace, then gone; owner holds keep their minutes; a coordinator hold needs a heartbeat ($pr)" ($pr -eq 'grace,live|own|7')
$lv = & { . $L2; $b = Get-KitPath board -Create; & $J @{ agent = 'B1'; session = 'B1-s'; status = 'working'; beat = (Get-Date).ToString('o') } "$b/B1-s.json"
  & $J @{ at = (Get-Date).ToString('o'); running = @('build:R1'); labels = @('build:R1', 'local:X1') } (Get-KitPath live-steps -Create)
  "$(Test-KitLive @{ session = 'B1-s'; holderPid = 999999 })$(Test-KitLive @{ agent = 'R1' })$(Test-KitLive @{ agent = 'X1'; holderPid = $PID })" }
Expect "leases: live by a board beat or a running workflow step; a finished step is not ($lv)" ($lv -eq 'TrueTrueFalse')
$lf = & { . (Join-Path $k2 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'shop.json' }; '{"holds":{"main":{"services":["api"],"agent":"main"}}}' | Set-Content $lf
$u1 = Px $L2 up -Env shop 2>&1 | Out-String; $c4 = $LASTEXITCODE; $null = Px $L2 unhold -Env shop -Agent main 2>&1
Expect "localenv: up refuses without -Services; unhold ends a hold" ($c4 -eq 1 -and $u1 -match 'up needs -Services' -and -not @((Get-Content $lf -Raw | ConvertFrom-Json).holds.PSObject.Properties).Count)
Expect 'localenv: usage errors exit 2; a start-lock timeout throws' ($c1 -eq 2 -and $c2 -eq 2 -and $c3 -eq 2 -and (Get-Content $L2 -Raw) -match 'if \(-not \$got\) \{ \$mx\.Dispose\(\); throw')
$r3 = & { . $L2; $st = @{ leases = @{ live = @{ agent = 'A'; until = (Get-Date).AddMinutes(-5).ToString('o'); holderPid = $PID }; own = @{ owner = $true; until = (Get-Date).AddMinutes(-1).ToString('o') } }; holds = @{}; requests = @() }; Prune $st
  "$(HasMigrations $k2 'main' 'deadbeef')|$(@('CHANGELOG.md', 'db/m/README.md', 'db/changelog/1.xml', 'migrations/1.sql') -match $script:MigPattern -join ',')|$($st.leases.Keys)|$(Leased 'clients')$(Leased 'clients', 'lease:A')|$(IdleWhy 15 '')" }
Expect "localenv: an unreadable diff counts as migrations; docs are no migrations; a live holder outlives until; only a lease starts; idle why ($r3)" ($r3 -like 'True|db/changelog/1.xml,migrations/1.sql|live|FalseTrue|idle: no holder*' -and $r3 -notmatch 'restart')
# an outside reader holds the state file open: the writer's rename retries (Windows: access denied) until it closes
$sw = & { . $L2; Update-State shop { param($x) $x.n = 1 }
  $j = Start-ThreadJob { param($f) $h = [IO.File]::Open($f, 'Open', 'Read', 'Read'); Start-Sleep -Milliseconds 600; $h.Dispose() } -ArgumentList (StateFile shop)
  Start-Sleep -Milliseconds 200; Update-State shop { param($x) $x.n = 2 }; $null = Receive-Job $j -Wait; "$((Read-State shop).n)" }
Expect "localenv: a state write succeeds after an outside reader closes the file ($sw)" ($sw -eq '2')
Remove-TestKit $k2
Complete-Tests
