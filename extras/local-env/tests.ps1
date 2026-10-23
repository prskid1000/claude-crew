#Requires -Version 7
<#
tests.ps1 (extra local-env): localenv.ps1 leases, usage, migration detection, the db-engine-presets line, state writes, seed.
Usage: kittool.py extra test local-env (tests/kit-tests.ps1 -Area extras runs every installed extra).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kittool.py extra test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# the extra's script is not in the core test kit: copy it in
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/local-env'); Copy-Item (Join-Path $src 'skills/local-env/localenv.ps1') $d; $kd }
# localenv usage errors exit 2; a start-lock timeout throws, never runs unlocked
$k2 = New-LocalEnvKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ snapshot = 'echo s'; restore = 'echo r' } }; mig = @{ services = @(); db = @{ engine = 'postgres' } } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
$xo = Px $L2 deploy -Env mig -Branch b 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "localenv: db.engine without its presets stops with the extra line, exit 1 ($xc)" ($xc -eq 1 -and ($xo -replace '\s*\|?\s+', ' ') -match 'db\.engine presets are an extra: run kittool\.py extra add db-engine-presets')
$null = Px $L2 bogus 2>&1; $c1 = $LASTEXITCODE
$null = Px $L2 status -Env nope 2>&1; $c2 = $LASTEXITCODE
$null = Px $L2 drop -Env shop 2>&1; $c3 = $LASTEXITCODE
$pr = & { . $L2; $ago = (Get-Date).AddMinutes(-11).ToString('o'); $u = (Get-Date).AddHours(1).ToString('o')
  $st = @{ leases = @{ dead = @{ until = $u; holderPid = 999999; seen = $ago }; grace = @{ until = $u; holderPid = 999999; seen = (Get-Date).AddMinutes(-3).ToString('o') }; live = @{ until = $u; holderPid = $PID } }
    holds = @{ own = @{ owner = $true; until = (Get-Date).AddMinutes(5).ToString('o') }; old = @{ owner = $true; until = $ago }; co = @{ agent = 'main'; seen = $ago } }; requests = @() }
  Prune $st; "$(($st.leases.Keys | Sort-Object) -join ',')|$(($st.holds.Keys | Sort-Object) -join ',')|$($st.leases.grace.graceLeft)" }
Expect "leases: no live holder -> kept for the grace, then gone; owner holds keep their minutes; a coordinator hold needs a heartbeat ($pr)" ($pr -eq 'grace,live|own|7')
$lv = & { . $L2; $b = Get-KitPath board -Create; & $J @{ agent = 'B1'; session = 'B1-s'; status = 'working'; beat = (Get-Date).ToString('o') } "$b/B1-s.json"
  & $J @{ at = (Get-Date).ToString('o'); running = @('build:R1'); labels = @('build:R1', 'local:X1') } (Get-KitPath live-steps -Create)
  "$(Test-KitLive @{ session = 'B1-s'; holderPid = 999999 })$(Test-KitLive @{ agent = 'R1' })$(Test-KitLive @{ agent = 'X1'; holderPid = $PID })" }
Expect "leases: live by a board beat or a running workflow step; a finished step is not ($lv)" ($lv -eq 'TrueTrueFalse')
$lf = & { . (Join-Path $k2 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'shop.json' }; '{"holds":{"main":{"services":["api"],"agent":"main"}}}' | Set-Content $lf
$u1 = Px $L2 up -Env shop 2>&1 | Out-String; $c4 = $LASTEXITCODE; $null = Px $L2 unhold -Env shop -Agent main 2>&1
Expect "localenv: up refuses without -Services; unhold ends a hold" ($c4 -eq 1 -and $u1 -match 'up needs -Services' -and -not @((Get-Content $lf -Raw | ConvertFrom-Json).holds.PSObject.Properties).Count)
# restart: only the named service, every lease stays, no suppress (down ends leases and stops dependents)
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ snapshot = 'echo s'; restore = 'echo r' } }; rs = @{ services = @(@{ name = 'api'; start = 'echo a'; port = 1 }, @{ name = 'web'; start = 'echo w'; port = 2; dependsOn = @('api') }) } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
$rf = & { . (Join-Path $k2 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'rs.json' }; '{"leases":{"F2":{"services":["api"],"agent":"F2","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $rf
$ro = Px $L2 restart -Env rs -Services api -Agent main -Wait 0.02 2>&1 | Out-String; $rc = $LASTEXITCODE; $rs = Get-Content $rf -Raw | ConvertFrom-Json; if ($rs.loop.pid) { Stop-Process -Id $rs.loop.pid -Force -ErrorAction SilentlyContinue }
Expect "localenv: restart keeps the lease on it (the controller restarts it), no suppress; without -Services refused ($rc)" ($ro -match 'api restarting' -and $ro -notmatch 'web restarting' -and $rs.leases.F2 -and -not $rs.suppress -and ((Px $L2 restart -Env rs 2>&1 | Out-String) -match 'restart needs -Services'))
Expect 'localenv: usage errors exit 2; a start-lock timeout throws' ($c1 -eq 2 -and $c2 -eq 2 -and $c3 -eq 2 -and (Get-Content $L2 -Raw) -match 'if \(-not \$got\) \{ throw')
$r3 = & { . $L2; $st = @{ leases = @{ live = @{ agent = 'A'; until = (Get-Date).AddMinutes(-5).ToString('o'); holderPid = $PID }; own = @{ owner = $true; until = (Get-Date).AddMinutes(-1).ToString('o') } }; holds = @{}; requests = @() }; Prune $st
  "$(HasMigrations $k2 'main' 'deadbeef')|$(@('CHANGELOG.md', 'db/m/README.md', 'db/changelog/1.xml', 'migrations/1.sql') -match $script:MigPattern -join ',')|$($st.leases.Keys)|$(Leased 'clients')$(Leased 'clients', 'lease:A')|$(IdleWhy 15 '')" }
Expect "localenv: an unreadable diff counts as migrations; docs are no migrations; a live holder outlives until; only a lease starts; idle why ($r3)" ($r3 -like 'True|db/changelog/1.xml,migrations/1.sql|live|FalseTrue|idle: no holder*' -and $r3 -notmatch 'restart')
# an outside reader holds the state file open: the writer's rename retries (Windows: access denied) until it closes
$sw = & { . $L2; Update-State shop { param($x) $x.n = 1 }
  $j = Start-ThreadJob { param($f) $h = [IO.File]::Open($f, 'Open', 'Read', 'Read'); Start-Sleep -Milliseconds 600; $h.Dispose() } -ArgumentList (StateFile shop)
  Start-Sleep -Milliseconds 200; Update-State shop { param($x) $x.n = 2 }; $null = Receive-Job $j -Wait; "$((Read-State shop).n)" }
Expect "localenv: a state write succeeds after an outside reader closes the file ($sw)" ($sw -eq '2')
# a start short of RAM marks itself waiting (Pressure then names it, so other envs stop idle services); half the file cache counts
$wr = & { . $L2; Update-State shop { param($x) $x.services = @{ web = @{ status = 'down' } } }; $script:ph = 0
  function Get-SysMem { [pscustomobject]@{ AvailGB = @(1, 10, 2)[$script:ph]; CacheGB = @(0, 0, 20)[$script:ph]; TotalGB = 64 } }
  function Get-SysCpu { 10 }; function Need-GB { 3 }; function KeepFreeGB { 6 }
  function Start-Sleep { $script:ph = 1; $script:seen = Pressure; $script:ph = 2 }
  $null = Wait-Room shop @{ name = 'web' }; "$script:seen|$((Read-State shop).services.web.status)" }
Expect "localenv: a waiting start is pressure, cache counts, then the mark is cleared ($wr)" ($wr -eq 'start(s) waiting for RAM: shop/web|down')
Remove-TestKit $k2
# config: envs inherit localEnv.defaults, then extends (named lists merge by name); a loop in extends is refused
$k3 = New-LocalEnvKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/local-env/localenv.ps1'; $cf3 = Join-Path $k3 'skills/dev-kit/kit.local.json'
& $J @{ localEnv = @{ defaults = @{ db = @{ keepDays = 3 }; services = @(@{ name = 'api'; start = 'echo api'; startMinutes = 5 }) }
    envs = @{ a = @{ services = @(@{ name = 'api'; port = 41001 }) }; b = @{ extends = 'a'; services = @(@{ name = 'web'; start = 'echo web'; port = 41002 }) } } } } $cf3 8
$mg = & { . $L3; $a = Svc a api; $b = @(EnvServices b); "$($a.port)/$($a.startMinutes)/$($a.start)|$(@($b.name) -join ',')|$((Get-EnvCfg b).db.keepDays)|$((Get-EnvCfg b).extends)" }
Expect "config: defaults + extends merge (services by name), extends itself dropped ($mg)" ($mg -eq '41001/5/echo api|api,web|3|')
& $J @{ localEnv = @{ envs = @{ a = @{ extends = 'b'; services = @() }; b = @{ extends = 'a'; services = @() } } } } $cf3 8
$lp = (Px $L3 status 2>&1 | Out-String)
Expect "config: an extends loop is refused with its path" ($lp -match 'extends loops \((a -> b -> a|b -> a -> b)\)')
# shell commands: a time bound kills the tree; command-not-found = misconfigured (fail fast, also in smoke checks)
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41003 }); db = @{ snapshot = 'nope-not-a-command-x1'; timeoutSec = @{ query = 1 }; query = 'pwsh -NoProfile -Command Start-Sleep 20' }
        smoke = @(@{ name = 'bad'; cmd = 'nope-not-a-command-x2'; timeoutSec = 60 }) } } } } $cf3 8
$sh = & { . $L3; $t0 = Get-Date; $q = Invoke-Hook t query @{ sql = 'select 1' }; $sec = ((Get-Date) - $t0).TotalSeconds; $m = Invoke-Hook t snapshot @{ snapshot = 'x' }
  function Healthy { $true }; $t1 = Get-Date; $sm = Test-Smoke t; $smSec = ((Get-Date) - $t1).TotalSeconds
  "$($q -match 'timed out' -and $sec -lt 15)|$($m -match 'misconfigured')|$($sm -match 'misconfigured' -and $smSec -lt 15)|$(HookTimeout t query)/$(HookTimeout t snapshot)" }
Expect "hooks: timeoutSec bounds a hook, a missing command fails fast as misconfigured (smoke too), defaults ($sh)" ($sh -eq 'True|True|True|1/1800')
# doctor: a hook script that does not exist = FAIL (deploy stops), localhost health = WARN; health = an IPv4 127.0.0.1 connect
$miss = Join-Path (Kd) 'no-such-hook.ps1'
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41004; health = 'http://localhost:41004/h' }); db = @{ snapshot = "pwsh -NoProfile -File `"$miss`" -Name {snapshot}"; restore = 'echo r' } } } } } $cf3 8
$dr = Px $L3 doctor -Env t 2>&1 | Out-String; $dc = $LASTEXITCODE; $dp = Px $L3 deploy -Env t -Branch nope 2>&1 | Out-String; $dpc = $LASTEXITCODE
Expect "doctor: missing hook script FAIL (exit 1), localhost WARN; deploy stops on it ($dc/$dpc)" ($dc -eq 1 -and $dr -match 'FAIL t: db\.snapshot: script .*no-such-hook\.ps1 does not exist' -and $dr -match 'WARN t: api: http://localhost:41004/h uses localhost' -and $dpc -eq 1 -and $dp -match 'deploy stopped')
$v4 = & { . $L3; $l4 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l4.Start(); $p4 = $l4.LocalEndpoint.Port
  $l6 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::IPv6Loopback, 0); $l6.Start(); $p6 = $l6.LocalEndpoint.Port
  try { "$(Test-PortListening $p4)|$(Test-PortListening $p6)" } finally { $l4.Stop(); $l6.Stop() } }
Expect "health: listening means an IPv4 127.0.0.1 connect; a ::1-only server is not up ($v4)" ($v4 -eq 'True|False')
# running services' logs: only new out-of-memory lines count; logs -Grep / -Since read from the end
$lg = Join-Path (Kd) 'svc.log'; "$((Get-Date).AddMinutes(-90).ToString('yyyy-MM-dd HH:mm:ss')) old ERROR x`n<--- JS stacktrace --->`nFATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory" | Set-Content $lg
$om = & { . $L3; $pos = @{}; $a = Find-NewLogLine $lg $script:OomPattern $pos; Add-Content $lg "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) new ERROR y"; Add-Content $lg 'FATAL ERROR: Reached heap limit again'
  $b = Find-NewLogLine $lg $script:OomPattern $pos; $c = Find-NewLogLine $lg $script:OomPattern $pos
  "$([bool]$a)|$($b -match 'again')|$([bool]$c)|$('JavaScript heap out of memory' -match $script:FailPattern)|$((Read-LogTail $lg 50 'ERROR [xy]' 30) -join ';')|$(@(Read-LogTail $lg 2 '' 0).Count)" }
Expect "logs: only new OOM lines; FailPattern has heap OOM; -Grep + -Since from the end ($om)" ($om -match '^False\|True\|False\|True\|\d{4}-\d\d-\d\d \d\d:\d\d:\d\d new ERROR y\|2$')
# _exec: the service output is copied to its log; past logMaxMB the log moves to .prev
& $J @{ localEnv = @{ logMaxMB = 0.002; envs = @{ t = @{ services = @(@{ name = 'gen'; start = 'pwsh -NoProfile -Command "1..80 | ForEach-Object { ''x'' * 60 }"' }) } } } } $cf3 8
$null = Px $L3 _exec -Env t -Service gen 2>&1; $gl = & { . (Join-Path $k3 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv-logs -Create) 't-gen.log' }
Expect "_exec: output copied to the log, rotated to .prev past logMaxMB" ((Test-Path "$gl.prev") -and (Get-Item $gl).Length -lt 6KB -and (Get-Content $gl -Raw) -match 'exited 0')
# processes: tree ids from one snapshot; a state write is skipped when nothing changed
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41005 }) } } } } $cf3 8
$tr = & { . $L3; $snap = @{ procs = @{ 1 = 1GB; 2 = 1GB; 3 = 1GB; 9 = 5GB }; kids = @{ 1 = @(2); 2 = @(3) }; names = @{} }
  Update-State t { param($x) $x.n = 1 }; $w0 = (Get-Item (StateFile t)).LastWriteTimeUtc; Start-Sleep -Milliseconds 30; Update-State t { param($x) $x.n = 1 }
  "$((TreeIds 1 $snap) -join ',')|$(TreeGB @(1, 2, 3) $snap)|$((Get-Item (StateFile t)).LastWriteTimeUtc -eq $w0)" }
Expect "processes: tree from the children map, GB from the snapshot; an unchanged state is not rewritten ($tr)" ($tr -eq '1,2,3|3|True')
# starts: RAM first, the start lock, RAM again under it; no stop of a service that is not running; the learned need = its peak
$ss = & { . $L3; $script:log = @(); $script:rooms = 0
  function Wait-Room { $script:log += 'room' }; function Test-Room { $script:rooms++; $script:rooms -gt 1 }; function Stop-Svc { $script:log += "stop:$($args[2])" }
  function Start-Pwsh { 999999 }; function Healthy { $false }
  try { Start-Svc t (Svc t api) 0 '' | Out-Null } catch { $script:err = "$_" }
  "$($script:log -join ',')|$($script:err -match 'exited while starting')" }
Expect "start: room, lock, room again when RAM fell; no stop of a stopped service ($ss)" ($ss -like 'room,room,stop:exited while starting|True')
# dependsOn healthy first; a start failing on a dependency connection waits for it again and retries once; another failure throws
$dr = & { . $L3; $script:h = 0; $script:n = 0; function Svc { [pscustomobject]@{ name = $args[1]; dependsOn = $(if ($args[1] -eq 'api') { @('es') }) } }
  function Healthy { ++$script:h -gt 2 -and $script:h -ne 4 }; function Start-SvcOnce { if (++$script:n -eq 1) { throw '[t] api failed to start. Unhandled exception caught whilst connecting to ES client' }; 'up' }
  $o = @(Start-Svc t (Svc t api) 0 ''); $script:n = 1; function Start-SvcOnce { throw '[t] api failed to start: port 1 in use' }
  try { Start-Svc t (Svc t api) 0 '' | Out-Null } catch { $e2 = "$_" }; "$($o -join ' / ')|$($e2 -match 'port 1 in use')" }
Expect "start: waits for dependsOn healthy, retries once on a dependency connection failure, throws others ($dr)" ($dr -match '^\[t\] api waits for es to be healthy / \[t\] api failed on a dependency connection: waiting for es, then one retry / .*up\|True$')
$pk = & { . $L3; Update-State t { param($x) $x.services = @{ api = @{ status = 'up'; peakGB = 4 } } }; Stop-Svc t (Svc t api) 'test'; Need-GB t (Svc t api) }
Expect "need: a stop saves the service's peak RAM; the next start needs it + 15% ($pk)" ($pk -eq 4.6)
# keep-free floor: learning -> static; steady -> the minimum; falls and dips under 6 GB raise it, with the why
$kf = & { . $L3; $a = Get-KeepFreeFrom @(1..10 | ForEach-Object { 20 }) 64; $b = Get-KeepFreeFrom @(1..200 | ForEach-Object { 20 }) 64
  $c = Get-KeepFreeFrom @(1..200 | ForEach-Object { if ($_ % 40 -lt 10) { 5 } else { 12 } }) 64; "$($a.gb)|$($b.gb)|$($c.gb)|$($c.why)" }
Expect "keep-free: learning = max(6, 15%); steady = 5% floor; falls + dips raise it with the why ($kf)" ($kf -match '^9\.6\|3\.2\|(\d+(\.\d)?)\|min 3\.2 \+ 10-min fall 7 \(p90 of 24 h\) \+ \d dip\(s\) under 6 GB x 0\.5$' -and [double]($kf -split '\|')[2] -gt 10)
# seed: each check gates its create (a second seed creates nothing); -Check only reports; a needs-chain waits; green -> no mark without marks
$sdir = Kd; $sflag = Join-Path $sdir 'seed.flag'; $scnt = Join-Path $sdir 'seed.count'; $sfile = Join-Path $sdir 't.seed.json'
@{ items = @(@{ name = 'thing'; check = @{ cmd = "pwsh -NoProfile -c `"if (Test-Path '$sflag') { exit 0 } else { exit 1 }`"" }; create = @{ cmd = "pwsh -NoProfile -c `"Set-Content '$sflag' 1; Add-Content '$scnt' 1`"" } }
    @{ name = 'after'; needs = @('thing'); check = @{ cmd = 'exit 0' } }) } | ConvertTo-Json -Depth 6 | Set-Content $sfile
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41006 }); seed = $sfile } } } } $cf3 8
$sc1 = Px $L3 seed -Env t -Check 2>&1 | Out-String; $scc1 = $LASTEXITCODE
$sc2 = Px $L3 seed -Env t 2>&1 | Out-String; $scc2 = $LASTEXITCODE
$sc3 = Px $L3 seed -Env t 2>&1 | Out-String; $scc3 = $LASTEXITCODE
$sst = & { . $L3; $x = (Read-State t).seed; "$($x.ok)|$(@($x.missing) -join ',')" }
Expect "seed: -Check = missing + blocked, exit 1; seed creates once, a second seed creates nothing ($scc1 $scc2 $scc3)" ($scc1 -eq 1 -and $sc1 -match 'MISSING\s+thing' -and $sc1 -match 'BLOCKED\s+after' -and
  $scc2 -eq 0 -and $sc2 -match 'OK\s+thing \(created\)' -and $scc3 -eq 0 -and $sc3 -notmatch 'created' -and @(Get-Content $scnt).Count -eq 1 -and $sst -eq 'True|')
# leases: no holder -> a train goes at once; held -> it waits leaseMinutes, tells the holder, goes on, the lease stays; unused -> released
& $J @{ localEnv = @{ leaseMinutes = 0; leaseIdleMinutes = 5; envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41007 }) } } } } $cf3 8
$lw = & { . $L3; $t0 = Get-Date; $a = @(Wait-Leases t @('api') @() @()); $fast = ((Get-Date) - $t0).TotalSeconds -lt 5
  Update-State t { param($x) $x.leases = @{ H1 = @{ services = @('api'); agent = 'H1'; holderPid = $PID; lastUse = (Now) } } }
  $b = @(Wait-Leases t @('api') @() @()) -join ' '; $st = Read-State t
  $inbox = Join-Path (Get-KitPath board) 'inbox/h1.jsonl'
  "$fast|$($b -match 'told H1')|$([bool]$st.leases.H1)|$($st.notices.H1.text -match 'deploy of api starting')|$((Test-Path $inbox) -and (Get-Content $inbox -Raw) -match 'pause')|$($script:Preempted -join ',')" }
Expect "leases: no holder -> no wait; held -> wait bound, holder told (inbox + notice), lease kept ($lw)" ($lw -eq 'True|True|True|True|True|H1')
$ir = & { . $L3; $st = @{ leases = @{ old = @{ services = @('api'); agent = 'old'; holderPid = $PID; lastUse = (Get-Date).AddMinutes(-6).ToString('o') }; new = @{ services = @('api'); agent = 'new'; holderPid = $PID; lastUse = (Now) }
      own = @{ services = @('api'); owner = $true; until = (Get-Date).AddMinutes(30).ToString('o'); lastUse = (Get-Date).AddMinutes(-60).ToString('o') } }; holds = @{}; notices = @{}; requests = @() }
  Prune $st; "$(($st.leases.Keys | Sort-Object) -join ',')|$($st.notices.old.text -match 'unused for 5 min')" }
Expect "leases: unused past leaseIdleMinutes -> released with a notice; owner leases keep their minutes ($ir)" ($ir -eq 'new,own|True')
# the controller: a failing tick is logged and retried, never the end of the loop; starts go to a start worker
& $J @{ localEnv = @{ loopExitMinutes = 0.02; envs = @{ tl = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41008 }) } } } } $cf3 8
$lo = & { . $L3; $script:boom = 0; $script:spawned = @()
  function Add-RamSample { $script:boom++; if ($script:boom -eq 1) { throw 'boom once' } }
  function Start-Sleep { }; function Start-Svc { throw 'inline start' }
  function Start-Pwsh { $script:spawned += ($args[0] -join ' '); Update-State tl { param($x) $x.leases = @{} }; 999999 }
  Update-State tl { param($x) $x.leases = @{ L1 = @{ services = @('api'); agent = 'L1'; holderPid = $PID } } }
  Invoke-Daemon -Env tl; $ll = Get-Content (LogFile tl 'loop') -Raw
  "$($ll -match 'tick 1 failed \(1 in a row, retrying\): boom once')|$($ll -match 'idle: loop exits')|$($script:spawned -join ';')" }
Expect "loop: a tick error is retried with backoff; a needed start runs in a worker ($lo)" ($lo -eq 'True|True|_daemon -Env tl -Start api -Release 0 -Artifact ')
# review: a start worker that throws marks the service failed (backoff); the lease clock starts at the first blocking lease;
# _exec keeps stderr of every part of a compound command; a program's own "not found" is no misconfiguration
& $J @{ localEnv = @{ leaseMinutes = 30; envs = @{ tl = @{ services = @(@{ name = 'api'; start = 'echo api'; port = 41009 }, @{ name = 'gone'; dir = (Join-Path (Kd) 'no-such-dir'); start = 'echo x' }) }
    t = @{ services = @(@{ name = 'cmp'; start = 'echo out1&& pwsh -NoProfile -Command "[Console]::Error.WriteLine(''err1'')"&& echo done1' }) } } } } $cf3 8
$null = Px $L3 _daemon -Env tl -Start gone 2>&1
$rv = & { . $L3; $f1 = (Read-State tl).services.gone; $null = @(Wait-Leases tl @('api') @() @()); $c0 = $null -eq $script:LeaseWait0
  $code = Invoke-Shell 'echo Status: not found&& exit 1' (Join-Path (Kd) 'nf.log') @{}; "$($f1.status)/$($f1.why -match 'does not exist')|$c0|$code" }
$null = Px $L3 _exec -Env t -Service cmp 2>&1; $cl = Get-Content (& { . (Join-Path $k3 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv-logs) 't-cmp.log' }) -Raw
Expect "review: worker failure -> failed; no lease = no clock; compound stderr kept; 'not found' output != misconfigured ($rv)" ($rv -eq 'failed/True|True|1' -and $cl -match 'out1' -and $cl -match 'err1' -and $cl -match 'done1')
Remove-TestKit $k3
# supervise rows from this extra (skills/orchestrate/adapters/localenv_supervise.ps1): idle vs leased down services, new log errors
$k = New-LocalEnvKit lsup; $ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/orchestrate/adapters'); Copy-Item (Join-Path $src 'skills/orchestrate/adapters/localenv_supervise.ps1') $ad
$O = Join-Path $k 'skills/orchestrate/orch.ps1'
$er = & { . $O; Get-KitEnvRows @([pscustomobject]@{ env = 'e'; services = @([pscustomobject]@{ service = 'api'; state = 'down'; why = 'idle for 15 min' }, [pscustomobject]@{ service = 'web'; state = 'down'; why = 'crashed' }); leases = @([pscustomobject]@{ agent = 'a1'; services = @('web') }); holds = @() }) (Get-Date) }
Expect 'supervise: a down service with no lease is idle (no row, no flag); a leased one shows' (@($er.rows).Count -eq 1 -and $er.rows[0].name -match 'web' -and $er.rows[0].name -notmatch 'api' -and -not @($er.flags).Count)
$sh = & { . $O; (Get-KitEnvRows @(foreach ($n in 'rm', 'hm') { [pscustomobject]@{ env = $n; services = @([pscustomobject]@{ service = 'mysql'; state = 'up (external)'; port = 3306; gb = 1.6 }); leases = @([pscustomobject]@{ agent = "a-$n"; services = @('mysql') }); holds = @() } }) (Get-Date)).rows | ForEach-Object { "$($_.name)|$($_.by)|$($_.gb)" } }
Expect "supervise rows: one service on one port shared by several envs = one row, holders merged, RAM once ($sh)" (@($sh).Count -eq 1 -and $sh -eq 'mysql (rm, hm)|a-rm, a-hm|1.6')
$lg = Join-Path (Split-Path $k) 'an.log'; 'ok' | Set-Content $lg; $s1 = @(& { . $O; Get-KitLogErrors @($lg) @{} })
Add-Content $lg "ERROR one`nTraceback (most recent call last)`nWARN cache: Error while deleting x`nTypeError: x is not a function`nGET /a status: 503`nfine"
$s2 = @(& { . $O; Get-KitLogErrors @($lg) @{ (Resolve-Path $lg).Path = $s1[0].size } })
Expect 'supervise anomalies: only new log error lines count; level words case-sensitive (WARN ... Error while is none)' ($s1[0].errors -eq 0 -and $s2[0].errors -eq 4)
$sl = Join-Path (Split-Path $k) 'shop-api.log'; 'ok' | Set-Content $sl; $z = (Get-Item $sl).Length
Add-Content $sl "2026-10-23 ERROR c.d.LoggingAspect - bad.request: order not found`nWARN slow"
$sp = @(& { . $O; Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $z } })[0]
Add-Content $sl "ERROR o.s.boot.SpringApplication - Application run failed`n2026-10-23 12:34:56 Caused by: java.net.ConnectException: Connection refused: localhost:19"
$ss = @(& { . $O; Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $sp.size } })[0]
$ev = { param($l) @([pscustomobject]@{ env = 'shop'; release = 7; leases = $l }) }
$sf = & { . $O; function Left { 30 }; @(Get-KitSpikeFlag $sp (& $ev @(@{ agent = 'q1' })) -AutoFix).Count; (Get-KitSpikeFlag $sp (& $ev @())).level; Get-KitSpikeFlag $ss (& $ev @(@{ agent = 'q1' })) -AutoFix | ForEach-Object { "$($_.level) $($_.what)" } }
Expect "ERROR SPIKE classes: an expected 4xx while a lease tests = no flag (else WATCH); a startup failure with its dependency down = ACT naming env, release, dependency ($($sf -join ' | '))" ($sp.errors -eq 0 -and $sp.expected -eq 1 -and $sf[0] -eq 0 -and $sf[1] -eq 'WATCH' -and $ss.cls -eq 'startup' -and $ss.dep -eq 'localhost:19' -and $sf[2] -match '^ACT ERROR SPIKE: shop api \(release r7\) failed to start: localhost:19 is down: ERROR o\.s\.boot\.SpringApplication - Application run failed')
$hk = (& { . $O; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"api","state":"down","restarts30":3},{"service":"web","state":"up (adopted)","port":4200}],"leases":[],"holds":[],"seed":{"ok":false,"missing":["roleA"],"drift":[]},"marks":{"count":1,"baseline":null,"expired":[],"binlogDays":30},"train":{"id":"t1","waitingFor":["H1"],"waitSince":"2020-01-01T00:00:00"}}]' } }
  @(Get-KitSuperviseFlagsLocalEnv) | ForEach-Object { "$($_.what)$($_.name)" } }) -join "`n"
Expect 'supervise hook (status -Json only): env row, RESTART LOOP (3 in 30 min), TRAIN WAITS, NO BASELINE MARK, SEED DRIFT, UNKNOWN port owner' ($hk -match 'TRAIN WAITS: shop train t1 waits \d+ min for the lease\(s\) of H1' -and $hk -match 'NO BASELINE MARK: shop' -and $hk -match 'SEED DRIFT: shop roleA' -and $hk -match 'shop · web' -and $hk -match 'RESTART LOOP: shop api restarted 3 times' -and $hk -match 'UNKNOWN: shop web port 4200')
$rf = @(foreach ($j in '[{"env":"shop","services":[]}]', '[{"env":"shop","services":[],"keepFreeGB":8}]', '[{"env":"shop","services":[],"keepFreeGB":10}]') { & { . $O; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = $j } }; @(Get-KitSuperviseFlagsLocalEnv | Where-Object { "$($_.what)" -match 'RAM FLOOR' }).Count } })
Expect "supervise RAM FLOOR: a status without keepFreeGB caches nothing (no bogus 0 -> 8); a real move flags ($($rf -join ','))" ($rf -join ',' -eq '0,0,1')
$ph = (& { . $O; $global:downs = @(); function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$T) { if ($A -contains 'down') { $global:downs += $A[-1]; return [pscustomobject]@{ code = 0 } }
  [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"api","state":"up"},{"service":"web","state":"up"},{"service":"db","state":"up"},{"service":"x","state":"up (external)"}],"leases":[{"agent":"P1","services":["api"],"graceLeft":8}],"holds":[{"who":"me","services":["db"],"graceLeft":null}]}]' } }
  Invoke-KitPauseLocalEnv; "downs=$($global:downs -join '|')" }) -join "`n"
Expect 'pause hook: services only a paused agent''s lease (in grace) or nobody needs stop; a live hold and external ones stay' ($ph -match 'stopped api, web \(no live holder\)' -and $ph -match 'downs=api,web$')
# guard rules (adapters/guard_localenv.ps1): localenv/ pushes and hand-started dev servers are denied; rows: tool, command, deny
$gk = New-TestKit leguard; New-Item -ItemType Directory -Force (Join-Path $gk 'skills/dev-kit/adapters') | Out-Null
Copy-Item (Join-Path $(if ($Kit) { $Kit } else { $src }) 'skills/dev-kit/adapters/guard_localenv.ps1') (Join-Path $gk 'skills/dev-kit/adapters')
$env:KIT_GUARD_SELFTEST_ACTIVE = '1'; $bad = @()
foreach ($c in @(@('P', 'git -C x push origin localenv/shop', $true), @('P', 'git push -u origin f/CU-1-x', $false), @('P', 'cd api; .\mvnw.cmd spring-boot:run', $true),
    @('B', 'npx ng serve --port 4200', $true), @('P', '& D:/kit/skills/local-env/localenv.ps1 up -Env shop', $false), @('B', 'yarn start', $true), @('P', 'dotnet watch run', $true),
    @('B', 'rg "ng serve" src', $false), @('B', 'git log -S bootRun --oneline', $false), @('P', 'git commit -m "fix: ng serve proxy"', $false), @('B', 'npm run dev:build', $false),
    @('P', 'dotnet run -- migrate', $false), @('B', 'cd web && yarn start', $true), @('B', 'git push origin --delete localenv/shop', $false))) {
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress
  $denied = (pwsh @np (Join-Path $gk 'skills/dev-kit/dev.ps1') guard -Json $json | Out-String) -match '"permissionDecision":"deny"'
  if ($denied -ne $c[2]) { $bad += $c[1] }
}
Remove-Item Env:KIT_GUARD_SELFTEST_ACTIVE
Expect "guard: localenv/ pushes and hand-started dev servers denied, the rest allowed ($($bad -join ' | '))" (-not $bad.Count)
Remove-TestKit $k
Complete-Tests
