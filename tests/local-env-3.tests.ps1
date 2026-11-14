#Requires -Version 7
<#
local-env-3.tests.ps1: envy.ps1 stale layers and release, supervise rows and log flags, guard rules, changeSet checksums, restore plans.
Usage: pwsh -NoProfile -File <kit>/tests/local-env-3.tests.ps1 (tests/kit-tests.ps1 -Area local-env-3 runs it with the other areas).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # a kit to test; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# envy.ps1 is not in the core test kit: copy it in
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; $kd }
# a test kit of its own: each scenario below writes the config it needs
$k3 = New-LocalEnvKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'; $cf3 = Join-Path $k3 'skills/crafty/kit.local.json'
$sq = Kd   # scratch dir next to the kit
# stale layers (supervise: drop -Stale): merged and gone-from-origin branches and a holder gone past the grace drop; a live and a paused agent's stay;
# release (drop -Agent): a finished agent's layers drop, a paused one's stay; the env is idle: each drop waits for the next lease or request
$lo = Join-Path $sq 'lo'; git init -q -b main $lo; Set-Content (Join-Path $lo 'f.txt') 'v1'; git -C $lo add .; git -C $lo -c user.name=t -c user.email=t@t commit -qm init
$lyc = { param($b) git -C $lo checkout -q -b $b main; Add-Content (Join-Path $lo "$b.txt") $b; git -C $lo add .; git -C $lo -c user.name=t -c user.email=t@t commit -qm $b; "$(git -C $lo rev-parse HEAD)".Trim() }
$ly = @{}; foreach ($b in 'mrg', 'orph', 'park', 'live', 'fin', 'pz') { $ly[$b] = & $lyc $b }
git -C $lo checkout -q main; git -C $lo merge -q --no-ff -m 'merge mrg' mrg 2>$null; $lc = Join-Path $sq 'lc'; git clone -q $lo $lc 2>$null
git -C $lc checkout -q -b gone1 origin/main; Add-Content (Join-Path $lc 'g.txt') g; git -C $lc add .; git -C $lc -c user.name=t -c user.email=t@t commit -qm gone1; $ly.gone1 = "$(git -C $lc rev-parse HEAD)".Trim(); git -C $lc checkout -q -b loc1; Add-Content (Join-Path $lc 'h.txt') h; git -C $lc add .; git -C $lc -c user.name=t -c user.email=t@t commit -qm loc1
$ly.loc1 = "$(git -C $lc rev-parse HEAD)".Trim(); git -C $lc checkout -q main; git -C $lc branch -q -D gone1   # gone1: deleted everywhere; loc1: a live agent's unpushed branch
& $J @{ repos = @(@{ name = 'r'; checkout = $lc; target = 'main' }); localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'web'; repo = 'r'; port = 41018 }) } } } } $cf3 8
$bd = TkPath $k3 board -Create; $old = (Get-Date).AddMinutes(-11).ToString('o')
& $J @{ agent = 'LV'; session = 'LV-s'; status = 'working'; beat = (Get-Date).ToString('o') } "$bd/LV-s.json"
foreach ($pa in 'P1', 'PZ') { & $J @{ agent = $pa; session = "$pa-s"; status = 'left'; paused = $old; beat = $old } "$bd/$pa-s.json" }
$lay = @(@{ branch = 'mrg'; agent = 'A1' }, @{ branch = 'orph'; agent = 'X9'; holder = @{ agent = 'X9'; seen = $old } }, @{ branch = 'park'; agent = 'P1'; holder = @{ agent = 'P1'; seen = $old } },
  @{ branch = 'live'; agent = 'LV' }, @{ branch = 'gone1'; agent = 'LV' }, @{ branch = 'loc1'; agent = 'LV' }, @{ branch = 'fin'; agent = 'RA' }, @{ branch = 'pz'; agent = 'PZ' }) | ForEach-Object { $_.sha = $ly[$_.branch]; $_.at = $old; $_ }
& { . $L3; Update-State t { param($x) $x.release = @{ n = 3; repos = @{ r = @{ target = 'main'; targetSha = 't0'; layers = $lay } } }; $x.requests = @(); $x.leases = @{}; $x.holds = @{}; $x.train = $null; $x.loop = $null } }   # idle: no loop, no train starts
$dry = Px $L3 drop -Stale -Env t -DryRun 2>&1 | Out-String; $dryW = & { . $L3; @((Read-State t).release.repos.r.layers | Where-Object { $_.holder.graceMin }).Count }
$so1 = Px $L3 drop -Stale -Env t 2>&1 | Out-String
$rl1 = Px (Join-Path $k3 'skills/bossy/bossy.ps1') release -Agent 'RA,PZ' 2>&1 | Out-String
$sl = & { . $L3; $q = @((Read-State t).requests); "$(@($q | Sort-Object branch | ForEach-Object { "$($_.branch)=$($_.status)" }) -join ',')|$(@($q | Where-Object branch -eq 'fin').why)" }
Expect "stale layers: merged, gone from origin and orphan (no live holder past the grace) drop; live and paused stay; the idle env defers them ($sl)" ($sl -eq 'fin=deferred,gone1=deferred,mrg=deferred,orph=deferred|finished: fin (agent finished)' -and $so1 -match '\[t\] drop mrg due on the next lease: merged: mrg merged into main' -and $so1 -match 'orphan: orph has no live holder \(X9\) for 10 min' -and $so1 -match 'orphan: gone1 is gone from origin' -and $so1 -notmatch 'loc1')
Expect "stale layers: -DryRun lists the same drops and writes nothing (no grace clock) ($dryW)" ($dry -match '\[t\] stale merged: mrg' -and $dry -match '\[t\] stale orphan: orph' -and $dryW -eq 0 -and $dry -notmatch 'loc1')
Expect "release: a finished agent's layer drops (finished), a paused agent's is kept ($(($rl1 -split "`n" | Where-Object { $_ -match 'RA|PZ' }) -join ' / '))" ($rl1 -match 'RA env: \[t\] drop fin due on the next lease' -and $rl1 -match 'PZ env: \[t\] layers of PZ kept: it paused or handed off')
# the train logs each layer that leaves (leases.jsonl kind env-layer, the drop's reason); status lists the due drops and the recent ones; a lease or request wakes them
$wl = & { . $L3; function Ensure-Loop { }; $q = @((Read-State t).requests); Write-LayerLog t r $lay @($lay | Where-Object { $_.branch -in 'live', 'loc1', 'park', 'pz' }) $q @{ 'r|mrg' = 'merged into main' }
  $lg = @(Get-Content (Get-KitPath leases) | ConvertFrom-Json | Where-Object kind -eq 'env-layer'); $st0 = (Px $L3 status -Env t 2>&1 | Out-String); Wake-Deferred t
  $due = $st0 -match 'on the next lease: .*A1: drop mrg \(merged: mrg merged into main\)'; $rec = $st0 -match 'layer orphan: gone1 is gone from origin \(LV, \d\d:\d\d\); layer finished: fin \(agent finished\) \(RA'
  "$(@($lg | ForEach-Object { "$($_.event)/$($_.agent)" }) -join ',')|$due|$rec|$(@((Read-State t).requests | Where-Object status -eq 'queued').Count)" }
Expect "layer log: each drop one release line with its reason; status shows due and recent drops; a lease wakes the due ones ($wl)" ($wl -eq 'release/A1,release/X9,release/LV,release/RA|True|True|4')
$null = & { . $L3; Update-State t { param($x) $x.loop = @{ pid = 999999; beat = (Now) }; $x.requests = @(@{ id = 'r1'; kind = 'deploy'; agent = 'D1'; status = 'in-train'; at = (Now) })
    $x.train = @{ id = 't9'; pid = $PID; pstart = (Get-Date).AddDays(-1).ToString('o'); phase = 'merging and building'; at = (Now); requests = @('r1') } } }   # the 10-hour train: its pid now another process's
$sj = Px $L3 status -Env t -Json 2>$null | Out-String; $sq1 = & { . $L3; "$(@((Read-State t).requests)[0].status)|$($null -eq (Read-State t).train)" }
Remove-TestKit $k3
# supervise rows from skills/bossy/adapters/localenv_supervise.ps1: idle vs leased down services, new log errors
$k = New-LocalEnvKit lsup; $ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/bossy/adapters'); Copy-Item (Join-Path $src 'skills/bossy/adapters/localenv_supervise.ps1') $ad
$supBossy = Join-Path $k 'skills/bossy/bossy.ps1'
$er = & { . $supBossy; Get-KitEnvRows @([pscustomobject]@{ env = 'e'; services = @([pscustomobject]@{ service = 'api'; state = 'down'; why = 'idle for 15 min' }, [pscustomobject]@{ service = 'web'; state = 'down'; why = 'crashed' }, [pscustomobject]@{ service = 'search'; state = 'waiting (CPU)' }); leases = @([pscustomobject]@{ agent = 'a1'; services = @('web', 'search') }); holds = @() }) (Get-Date) }
Expect 'supervise: a down service with no lease is idle (no row, no flag); a leased one shows; a leased start waiting for room is no down row' (@($er.rows).Count -eq 1 -and $er.rows[0].name -match 'web' -and $er.rows[0].name -notmatch 'api' -and -not @($er.flags).Count)
$sh = & { . $supBossy; (Get-KitEnvRows @(foreach ($n in 'rm', 'hm') { [pscustomobject]@{ env = $n; services = @([pscustomobject]@{ service = 'mysql'; state = 'up (external)'; port = 3306; gb = 1.6 }); leases = @([pscustomobject]@{ agent = "a-$n"; services = @('mysql') }); holds = @() } }) (Get-Date)).rows | ForEach-Object { "$($_.name)|$($_.by)|$($_.gb)|$($_.shared)" } }
Expect "supervise rows: one service on one port shared by several envs = one row, holders merged, RAM once, shared (always on, never an orphan) ($sh)" (@($sh).Count -eq 1 -and $sh -eq 'mysql (rm, hm)|a-rm, a-hm|1.6|True')
$cg = & { . $supBossy; $sf = Join-Path (Get-KitPath localenv -Create) 'rx.json'; @{ services = @{ api = @{ status = 'up'; pid = $PID; pstart = (Get-KitPidStart $PID) }; web = @{ status = 'down'; pid = $PID }; db = @{ status = 'up'; pid = 999999 } } } | ConvertTo-Json -Depth 4 | Set-Content $sf; @(Get-KitCpuGroupsLocalEnv | ForEach-Object { "$($_.name)=$($_.pid -eq $PID)" }) -join ','; Remove-Item $sf }
Expect "supervise CPU groups: one per running service with a live pid, named '<env> · <service>' ($cg)" ($cg -eq 'rx · api=True')
$lg = Join-Path (Split-Path $k) 'an.log'; 'ok' | Set-Content $lg; $s1 = @(& { . $supBossy; Get-KitLogErrors @($lg) @{} })
Add-Content $lg "ERROR one`nTraceback (most recent call last)`nWARN cache: Error while deleting x`nTypeError: x is not a function`nGET /a status: 503`nfine"
$s2 = @(& { . $supBossy; Get-KitLogErrors @($lg) @{ (Resolve-Path $lg).Path = $s1[0].size } })
Expect 'supervise anomalies: only new log error lines count; level words case-sensitive (WARN ... Error while is none)' ($s1[0].errors -eq 0 -and $s2[0].errors -eq 4)
$sl = Join-Path (Split-Path $k) 'shop-api.log'; 'ok' | Set-Content $sl; $z = (Get-Item $sl).Length
Add-Content $sl "2026-10-23 ERROR c.d.LoggingAspect - bad.request: order not found`nWARN slow"
$sp = @(& { . $supBossy; Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $z } })[0]
Add-Content $sl "ERROR o.s.boot.SpringApplication - Application run failed`n2026-10-23 12:34:56 Caused by: java.net.ConnectException: Connection refused: localhost:19"
$ss = @(& { . $supBossy; Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $sp.size } })[0]
$ev = { param($l) @([pscustomobject]@{ env = 'shop'; release = 7; leases = $l }) }
$sf = & { . $supBossy; function Left { 30 }; @(Get-KitSpikeFlag $sp (& $ev @(@{ agent = 'q1' })) -AutoFix).Count; (Get-KitSpikeFlag $sp (& $ev @())).level; Get-KitSpikeFlag $ss (& $ev @(@{ agent = 'q1' })) -AutoFix | ForEach-Object { "$($_.level) $($_.what)" } }
Expect "ERROR SPIKE classes: an expected 4xx while a lease tests = no flag (else WATCH); a startup failure with its dependency down = ACT naming env, release, dependency ($($sf -join ' | '))" ($sp.errors -eq 0 -and $sp.expected -eq 1 -and $sf[0] -eq 0 -and $sf[1] -eq 'WATCH' -and $ss.cls -eq 'startup' -and $ss.dep -eq 'localhost:19' -and $sf[2] -match '^ACT ERROR SPIKE: shop api \(release r7\) failed to start: localhost:19 is down: ERROR o\.s\.boot\.SpringApplication - Application run failed')
# supervise -Brief cells: short problem / next (~90 chars a cell), the whole line stays in what / action (the report file)
$sc = & { . $supBossy; Add-Content $sl ("2026-10-23 ERROR c.d.X - " + ('boom ' * 80)); $s3 = @(Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $ss.size })[0]
  $f = Get-KitSpikeFlag $s3 (& $ev @()); $d = Get-KitSpikeFlag $ss (& $ev @(@{ agent = 'q1' })); "$($f.kind)|$($f.who)|$($f.problem)|$($f.next.Length)|$($f.action -match "boom boom boom")|$($d.problem)/$($d.next)" }
Expect "ERROR SPIKE cells: kind, who '<env> <service>', problem '<n> new error lines in <env> <service> log', next = class + 60 chars; the action stays whole ($sc)" ($sc -match '^ERROR SPIKE\|shop api\|\d+ new error lines? in shop api log\|\d+\|True\|api failed to start: localhost:19 is down/bring localhost:19 up$' -and [int]($sc -split '\|')[3] -le 75)
# known noise: a signature (no timestamp, [thread], key=value, numbers) an -Ack stored for that env never counts again; a new one flags
$nl = @('2026-11-05 10:00:01.123 ERROR [exec-1] c.d.S3 - getLogo failed key=abc/12.png', '2026-11-05 10:00:09 ERROR [exec-2] c.d.S3 - getLogo failed key=xyz/99.png', 'ERROR c.d.Mail - send failed: no sandbox')
$kn = & { . $supBossy; $knRow = [pscustomobject](@{ path = 'C:\x\shop-api.log'; expected = 0; lines = $nl } + (Get-KitLogClass $nl)); $f1 = Get-KitSpikeFlag $knRow (& $ev @())
  $f2 = Get-KitSpikeFlag $knRow (& $ev @()) -Known @($f1.refs | Where-Object { $_ -match 'getLogo' }); $f3 = Get-KitSpikeFlag $knRow (& $ev @()) -Known @($f1.refs)
  $o = [pscustomobject](@{ path = 'C:\x\other-api.log'; expected = 0; lines = $nl } + (Get-KitLogClass $nl)); $f4 = Get-KitSpikeFlag $o @([pscustomobject]@{ env = 'other'; release = 1 }) -Known @($f1.refs)
  "$(@($f1.refs).Count)|$($f1.refs[0])|$($f2.problem)|$($f2.next)|$($null -eq $f3)|$($f4.problem)" }
Expect "ERROR SPIKE known noise: per env and signature; the rest still flags ($kn)" ($kn -eq '2|noise:shop:ERROR c.d.S# - getLogo failed key=<v>|1 new error line in shop api log|error: ERROR c.d.Mail - send failed: no sandbox|True|3 new error lines in other api log')
$hk = (& { . $supBossy; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"api","state":"down","restarts30":3},{"service":"web","state":"up (adopted)","port":4200}],"leases":[],"holds":[],"seed":{"ok":false,"missing":["roleA"],"drift":[]},"marks":{"count":1,"baseline":null,"expired":[],"binlogDays":30},"train":{"id":"t1","waitingFor":["H1"],"waitSince":"2020-01-01T00:00:00"},"halfRestored":{"mark":"bm1","at":"2026-11-14T10:00:00","why":"mysql 3730"}}]' } }
  @(Get-KitSuperviseFlagsLocalEnv) | ForEach-Object { "$($_.what)$($_.name)" } }) -join "`n"
Expect 'supervise hook (status -Json only): env row, RESTART LOOP (3 in 30 min), TRAIN WAITS, NO BASELINE MARK, SEED DRIFT, UNKNOWN port owner, HALF-RESTORED' ($hk -match 'TRAIN WAITS: shop train t1 waits \d+ min for the lease\(s\) of H1' -and $hk -match 'NO BASELINE MARK: shop' -and $hk -match 'SEED DRIFT: shop roleA' -and $hk -match 'shop · web' -and $hk -match 'RESTART LOOP: shop api restarted 3 times' -and $hk -match 'UNKNOWN: shop web port 4200' -and $hk -match 'HALF-RESTORED: shop restore to bm1 failed part way 10:00: mysql 3730')
$gh = & { . $supBossy; function Left { 30 }; $now = Get-Date; $global:calls = 0; function Invoke-KitExe { if ($args[1] -contains 'status') { $global:calls++ }; [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"web","state":"up","port":4200}],"leases":[],"holds":[],"seed":{"ok":true}}]' } }
  $g = @(Get-KitSuperviseGuardLocalEnv | ForEach-Object name) -join ','; $fl = @(Get-KitSuperviseFlagsLocalEnv | Where-Object { $_.name }).Count; "$g|$fl|$global:calls" }
Expect "supervise: env rows come from the early guard hook (one status call), the flags hook adds none ($gh)" ($gh -match '^shop · web\|0\|1$')
$ts = @(foreach ($n in 1, 2) { (& { . $supBossy; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = $sj } }; @(Get-KitSuperviseFlagsLocalEnv) | Where-Object level -eq 'ACT' | ForEach-Object { "$($_.what) => $($_.action)" } }) -join "`n" })
Expect "supervise TRAIN STALLED (status -Json after its prune): a train on a reused pid ends, its request requeues; ACT names env, train, phase, why and the next command, once per train ($sq1 | $($ts[0]) | $($ts[1]))" ($sq1 -eq 'queued|True' -and $ts[0] -match "TRAIN STALLED: t train t9 in 'merging and building' ended \d\d:\d\d: worker gone \(or its pid reused\); 1 request\(s\) requeued" -and $ts[0] -match 'status -Env t' -and -not $ts[1])
$wq = & { . $supBossy; $ld = Get-KitPath localenv -Create; $lp = "{`"pid`":$PID,`"pstart`":`"$(Get-KitPidStart $PID)`",`"beat`":`"$((Get-Date).ToString('o'))`"}"
  "{`"loop`":$lp,`"requests`":[{`"id`":`"r7`",`"kind`":`"deploy`",`"agent`":`"devy-x`",`"status`":`"queued`",`"at`":`"2026-01-01T00:00:00`"},{`"id`":`"r8`",`"kind`":`"deploy`",`"agent`":`"devy-x`",`"status`":`"done`"}],`"train`":{`"id`":`"t9`",`"phase`":`"merging and building`"}}" | Set-Content "$ld/wq.json"
  '{"requests":[{"id":"r9","kind":"deploy","agent":"devy-y","status":"queued"}]}' | Set-Content "$ld/wn.json"   # no controller: nothing serves it
  "{`"loop`":$lp,`"requests`":[{`"id`":`"s1`",`"agent`":`"devy-z`",`"status`":`"queued`"}]}" | Set-Content "$ld/wq.seed.json"
  $w = @(Get-KitStatusWaitLocalEnv | Where-Object agent -like 'devy-*'); Remove-Item "$ld/wq.json", "$ld/wn.json", "$ld/wq.seed.json"
  "$($w.Count)|$($w[0].agent)|$($w[0].why)|$([bool](Get-Command 'Get-KitStatusWait*' | Where-Object Name -eq 'Get-KitStatusWaitLocalEnv'))" }
Expect "status: an agent whose env request is queued while its controller beats is WAITING (<env> deploy <id>), not STUCK; no controller or a seed file: no wait ($wq)" ($wq -eq '1|devy-x|wq deploy r7 queued, train t9 merging and building|True')
$rf = @(foreach ($j in '[{"env":"shop","services":[]}]', '[{"env":"shop","services":[],"keepFreeGB":8}]', '[{"env":"shop","services":[],"keepFreeGB":10}]') { & { . $supBossy; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = $j } }; @(Get-KitSuperviseFlagsLocalEnv | Where-Object { "$($_.what)" -match 'RAM FLOOR' }).Count } })
Expect "supervise RAM FLOOR: a status without keepFreeGB caches nothing (no bogus 0 -> 8); a real move flags ($($rf -join ','))" ($rf -join ',' -eq '0,0,1')
$ph = (& { . $supBossy; $global:downs = @(); function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$T) { if ($A -contains 'down') { $global:downs += $A[-1]; return [pscustomobject]@{ code = 0 } }
  [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"api","state":"up"},{"service":"web","state":"up"},{"service":"db","state":"up"},{"service":"x","state":"up (external)"}],"leases":[{"agent":"P1","services":["api"],"graceLeft":8}],"holds":[{"who":"me","services":["db"],"graceLeft":null}]}]' } }
  Invoke-KitPauseLocalEnv; "downs=$($global:downs -join '|')" }) -join "`n"
Expect 'pause hook: services only a paused agent''s lease (in grace) or nobody needs stop; a live hold and external ones stay' ($ph -match 'stopped api, web \(no live holder\)' -and $ph -match 'downs=api,web$')
# guard rules (adapters/guard_localenv.ps1): localenv/ pushes and hand-started dev servers are denied; rows: tool, command, deny
$gk = New-TestKit leguard; New-Item -ItemType Directory -Force (Join-Path $gk 'skills/crafty/adapters') | Out-Null
Copy-Item (Join-Path $(if ($Kit) { $Kit } else { $src }) 'skills/crafty/adapters/guard_localenv.ps1') (Join-Path $gk 'skills/crafty/adapters')
$env:KIT_GUARD_SELFTEST_ACTIVE = '1'; $bad = @()
foreach ($c in @(@('P', 'git -C x push origin localenv/shop', $true), @('P', 'git push -u origin f/CU-1-x', $false), @('P', 'cd api; .\mvnw.cmd spring-boot:run', $true),
    @('B', 'npx ng serve --port 4200', $true), @('P', '& D:/kit/skills/envy/envy.ps1 up -Env shop', $false), @('B', 'yarn start', $true), @('P', 'dotnet watch run', $true),
    @('B', 'rg "ng serve" src', $false), @('B', 'git log -S bootRun --oneline', $false), @('P', 'git commit -m "fix: ng serve proxy"', $false), @('B', 'npm run dev:build', $false),
    @('P', 'dotnet run -- migrate', $false), @('B', 'cd web && yarn start', $true), @('B', 'git push origin --delete localenv/shop', $false),
    @('B', 'cd D:/w/web-ui && (yarn start --host 0.0.0.0 > D:/k/ui.log 2>&1 &) ; sleep 5', $true), @('B', 'PORT=4201 npm start', $true), @('P', 'Start-Process yarn -ArgumentList start', $true),
    @('B', 'nohup yarn start &', $true), @('B', 'npx --yes ng serve', $true), @('B', 'yarn --cwd web start', $true), @('B', 'yarn workspace web start', $true),
    @('B', 'yarn lint --fix', $false), @('B', 'npm run dev:build -- --watch=false', $false))) {
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress
  $denied = (pwsh @np (Join-Path $gk 'skills/crafty/crafty.ps1') guard -Json $json | Out-String) -match '"permissionDecision":"deny"'
  if ($denied -ne $c[2]) { $bad += $c[1] }
}
Remove-Item Env:KIT_GUARD_SELFTEST_ACTIVE
Expect "guard: localenv/ pushes and hand-started dev servers denied, the rest allowed ($($bad -join ' | '))" (-not $bad.Count)
# a rebuilt layer edited an applied, unmerged changeSet: its MD5SUM is nulled (merged and unchanged ones untouched); restore.after runs with the release mark
$ck = New-LocalEnvKit lecs; $ckL = Join-Path $ck 'skills/envy/envy.ps1'; $ckr = Join-Path $ck 'repo'; git init -q -b main $ckr
$ckx = { param($body) Set-Content (Join-Path $ckr 'changelog/c1.xml') "<databaseChangeLog>$body</databaseChangeLog>"; git -C $ckr add .; git -C $ckr -c user.name=t -c user.email=t@t commit -qm x; "$(git -C $ckr rev-parse HEAD)".Trim() }
New-Item -ItemType Directory -Force (Join-Path $ckr 'changelog') | Out-Null
$null = & $ckx '<changeSet id="m1" author="a"><sql>select 1</sql></changeSet>'; git -C $ckr update-ref refs/remotes/origin/main HEAD
$ckp = & $ckx '<changeSet id="m1" author="a"><sql>select 1</sql></changeSet><changeSet author="a" id="l1"><sql>select 2</sql></changeSet><changeSet id="l2" author="a"><sql>x</sql></changeSet>'
$ckn = & $ckx '<changeSet id="m1" author="a"><sql>select 1</sql></changeSet><changeSet author="a" id="l1"><sql>select 3</sql></changeSet><changeSet id="l2" author="a">  <sql>x</sql></changeSet>'
Set-JsonFile (Join-Path $ck 'skills/crafty/kit.local.json') @{ localEnv = @{ envs = @{ t = @{ services = @(); restore = @{ after = @(@{ name = 'marker'; cmd = 'echo reset {mark}' }, @{ name = 'slow'; cmd = 'echo reindex'; onMigrations = $false }) } } } } } 8
$cks = & { . $ckL; $global:ckSql = @(); function Invoke-DbSql { $global:ckSql += $args[1] }; function LiquibaseSchemas { 's1' }; function SqlId($n) { "``$n``" }; function SqlQ($v) { "'$v'" }
  $pure = @(Get-EditedChangeSets '<changeSet id="x" author="b">1</changeSet>' '<changeSet id="x" author="b">2</changeSet>' '<changeSet id="x" author="b">1</changeSet>').Count
  $sqlNotes = @(Reset-EditedChecksums t @{ r = @{ wt = $ckr; target = 'main' } } @{ r = @(@{ branch = 'b'; sha = $ckp; migrations = $true }) } @{ r = @(@{ branch = 'b'; sha = $ckn; migrations = $true }) })
  $after = @(Invoke-RestoreAfter t 'release-7' -Migrations); $all = @(Invoke-RestoreAfter t 'm1').Count
  "$pure|$($global:ckSql -join ';')|$($sqlNotes -join ';')|$($after -join ';')|$all" }
Expect "localenv: an edited unmerged changeSet gets MD5SUM NULL (merged / whitespace-only untouched); restore.after gets {mark}, onMigrations false skips releases ($cks)" ($cks -match '^0\|UPDATE `s1`\.DATABASECHANGELOG SET MD5SUM = NULL WHERE ID = ''l1'' AND AUTHOR = ''a'' AND \(FILENAME = ''c1\.xml'' OR FILENAME LIKE ''%/c1\.xml''\)\|r b: changeSet\(s\) a:l1 of c1\.xml .*NOT re-applied' -and $cks -match '\|restore\.after marker: ok: reset release-7\|2$')
# restore plan: a schema dropped after the mark (tenant reset) keeps its re-created objects and seeds its tables (never dropped as
# "created after the mark"; ALTER DATABASE changes nothing); seed -Check: a routine an executed changeSet file made, now gone = DRIFT
Set-Content (Join-Path $ckr 'changelog/c2.xml') '<changeSet id="p" author="a"><sql>DROP PROCEDURE IF EXISTS `p1`;</sql><sql>CREATE DEFINER=`root`@`localhost` PROCEDURE `p1`(in a int) BEGIN END</sql><sql>CREATE FUNCTION p2(a int) RETURNS int RETURN 1</sql><rollback>DROP PROCEDURE p1</rollback></changeSet>'
Set-Content (Join-Path $ckr 'changelog/c3.xml') '<changeSet id="q" author="a"><sql>DROP FUNCTION IF EXISTS p2</sql><rollback>CREATE FUNCTION p2(a int) RETURNS int RETURN 1</rollback></changeSet>'
Set-Content (Join-Path $ckr 'changelog/c4.xml') '<changeSet id="b" author="a"><sql>CREATE PROCEDURE `p3`() BEGIN END</sql><sql>CALL `p3`()</sql><sql>DROP PROCEDURE IF EXISTS `p3`</sql></changeSet>'   # a backfill: made, run, dropped
$rpOut = & { . $ckL
  function DbPosKey([string]$fp) { $f, $p = $fp -split ':(?=\d+$)'; @([long]([regex]::Match($f, '\d+$').Value), [long]$p) }
  function Test-DbPosBefore([string]$a, [string]$b) { $x = DbPosKey $a; $y = DbPosKey $b; $x[0] -lt $y[0] -or ($x[0] -eq $y[0] -and $x[1] -lt $y[1]) }
  function Read-State { @{ marks = @(); undone = @() } }; function Get-DbPos { 'b.000009:1' }
  function Invoke-DbFlashback { @{ fallback = @(); warnings = @(); ddl = @(
        @{ schema = 's1'; table = ''; kind = 'database'; at = 'b.000008:100'; sql = 'drop database s1' }, @{ schema = 's1'; table = 't1'; kind = 'create'; at = 'b.000008:150' },
        @{ schema = 's2'; table = ''; kind = 'database'; at = 'b.000008:250'; sql = 'ALTER DATABASE s2 CHARACTER SET utf8mb4' },
        @{ schema = 's1'; table = 'p1'; kind = 'object'; object = 'PROCEDURE'; op = 'CREATE'; at = 'b.000008:200'; sql = 'CREATE PROCEDURE p1' },
        @{ schema = 's2'; table = 't2'; kind = 'create'; at = 'b.000008:300' },
        @{ schema = 's2'; table = 'p9'; kind = 'object'; object = 'PROCEDURE'; op = 'CREATE'; at = 'b.000008:400'; sql = 'CREATE PROCEDURE p9' }) } }
  $rp = Get-RestorePlan t @{ pos = 'b.000008:50' } @('s1', 's2') ''
  function Get-LiquibaseMaster { Join-Path $ckr 'changelog/c1.xml' }; function LiquibaseDir { $ckr }; function LiquibaseSchemas { 's1', 's2' }
  function Invoke-DbSql([string]$e, [string]$sql) {
    if ($sql -match 'DATABASECHANGELOG') { , @('config/changelog/c2.xml', '5'); , @('config/changelog/c3.xml', '9'); , @('config/changelog/c4.xml', '11') }
    elseif ($sql -match "'s2'") { , @('p1') } }
  $mr = @(Get-MissingRoutines t)
  "drops=$($rp.objectDrops -join ',')|tdrops=$($rp.drops -join ',')|fb=$(@($rp.fallback.table) -join ',')|warn=$(@($rp.warnings).Count)|missing=$(@($mr | ForEach-Object { "$($_.schema):$($_.names -join '+')" }) -join ',')" }
Expect "localenv: restore keeps objects / seeds tables of a schema re-created after the mark; seed finds routines an executed changeSet made that are gone ($rpOut)" ($rpOut -eq 'drops=PROCEDURE:s2.p9|tdrops=s2.t2|fb=s1.t1|warn=1|missing=s1:p1')
# restore: mark~end is recorded undone only after the row flashback applied (a failed one left it recorded: the next restore skipped it)
$fbOut = foreach ($ok in $false, $true) { & { . $ckL; $script:rec = 0
    function Read-State { @{ marks = @(); undone = @() } }; function Get-EnvCfg { @{ db = @{} } }; function Invoke-DbSql { }; function Get-DbPos { 'b.000009:1' }
    function Invoke-DbFlashback { @{ applied = $ok; error = 'disk full'; fallback = @(); refused = @() } }; function Update-State { $script:rec++ }; function Remove-MarkSlices { }; function Event { }
    "$(Invoke-RestoreDb t @{ pos = 'b.000008:50'; name = 'm1' } @('s1') @{ to = 'b.000009:1'; steps = @(); objects = @(); renames = @(); drops = @(); objectDrops = @() })|$script:rec" } }
Expect "localenv: restore records mark~end undone only after the row flashback applied ($($fbOut -join ' / '))" ($fbOut[0] -eq 'row flashback failed: disk full|0' -and $fbOut[1] -eq '|1')
# restore: tables made after the mark go in one FK-checks-off statement (parent before child: mysql 3730)
$dq = & { . $ckL; $global:dSql = @(); function Read-State { @{ marks = @(); undone = @() } }; function Get-EnvCfg { @{ db = @{} } }; function Invoke-DbSql { $global:dSql += $args[1] }; function Get-DbPos { 'b.000009:1' }
  function Invoke-DbFlashback { @{ applied = $true; fallback = @(); refused = @() } }; function Update-State { }; function Remove-MarkSlices { }; function Event { }
  $null = Invoke-RestoreDb t @{ pos = 'b.000008:50'; name = 'm1' } @('s1') @{ to = 'b.000009:1'; steps = @(); objects = @(); renames = @(); drops = @('s1.agent', 's1.agent_eval_case'); objectDrops = @() }; @($global:dSql -match 'DROP TABLE') }
Expect "localenv: restore drops post-mark tables in one statement with FOREIGN_KEY_CHECKS = 0 ($dq)" (@($dq).Count -eq 1 -and $dq -match '^SET FOREIGN_KEY_CHECKS = 0; DROP TABLE IF EXISTS `s1`.`agent`, `s1`.`agent_eval_case`; SET FOREIGN_KEY_CHECKS = 1$')
Remove-TestKit $ck
Remove-TestKit $k
Complete-Tests
