#Requires -Version 7
<#
tests.ps1 (goody local-env): envy.ps1 leases, usage, migration detection, the db-engine-presets line, state writes, seed.
Usage: kitbag.py goody test local-env (tests/kit-tests.ps1 -Area goodies runs every installed goody).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kitbag.py goody test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# the goody's script is not in the core test kit: copy it in
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; $kd }
# localenv usage errors exit 2; a start-lock timeout throws, never runs unlocked
$k2 = New-LocalEnvKit le2; $L2 = Join-Path $k2 'skills/envy/envy.ps1'
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ snapshot = 'echo s'; restore = 'echo r' } }; mig = @{ services = @(); db = @{ engine = 'postgres' } } } } } (Join-Path $k2 'skills/crafty/kit.local.json') 6
$xo = Px $L2 deploy -Env mig -Branch b 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "localenv: db.engine without its presets stops with the goody line, exit 1 ($xc)" ($xc -eq 1 -and ($xo -replace '\s*\|?\s+', ' ') -match 'db\.engine presets are a goody: run kitbag\.py goody add db-engine-presets')
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
# pid reuse: a worker record names its process start, another process on that pid is not it; a train quiet past trainStallMinutes is killed + requeued
$hide = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }; $hung = Start-Process (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru @hide
$hung2 = Start-Process (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru @hide
$pu =& { . $L2; $me = Mine $PID; $old = (Get-Date).AddHours(-2).ToString('o'); $reused = @{ pid = $PID; pstart = (Get-Date).AddDays(-1).ToString('o') }
  $mk = { param($t, $n = 0, $beat = (Now)) @{ requests = @(@{ id = 'q1'; status = 'in-train'; stalls = $n }); train = $t; loop = @{ beat = $beat }; leases = @{}; holds = @{}; notices = @{} } }
  $a = & $mk (@{ id = 'tA'; at = $old; phase = 'merging and building'; requests = @('q1') } + $reused); Prune $a
  $b = & $mk (@{ id = 'tB'; at = (Get-Date).ToString('o'); phase = 'merging and building'; requests = @('q1') } + $me); Prune $b
  $c = & $mk (@{ id = 'tC'; at = $old; phaseAt = $old; phase = 'merging and building'; requests = @('q1') } + (Mine $hung.Id)); Prune $c
  $d = & $mk (@{ id = 'tD'; at = $old; phaseAt = $old; phase = 'merging and building'; requests = @('q1') } + (Mine $hung2.Id)) 1; Prune $d   # its second stall
  $s = & $mk (@{ id = 'tS'; at = $old; phaseAt = $old; phase = 'merging and building'; requests = @('q1') } + $me) 0 $old; Prune $s   # the loop slept
  "$(Owned $reused)|$(Owned $me)|$(Owned @{ pid = $PID } '-Train zz')|$($null -eq $a.train)$($a.requests[0].status)|$($b.train.id)$($b.requests[0].status)|$($null -eq $c.train)$($c.requests[0].status)$($c.trainDead.id)|$($d.requests[0].status)$($d.requests[0].result.outcome)$($d.trainDead.failed)|$($s.train.id)" }
foreach ($hp in $hung, $hung2) { $hp.WaitForExit(5000) | Out-Null }; $killed = $hung.HasExited -and $hung2.HasExited; foreach ($hp in $hung, $hung2) { if (-not $hp.HasExited) { $hp.Kill() } }
Expect "pid reuse: a reused pid (start differs) or an old record whose command line lacks its tag is not the worker; train requeued; a live train stays; a hung one is killed + requeued, failed at its second stall; no stall judged while the loop slept ($pu, killed $killed)" ($pu -eq 'False|True|False|Truequeued|tBin-train|TruequeuedtC|donefailedq1|tS' -and $killed)
$lf = & { . (Join-Path $k2 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'shop.json' }; '{"holds":{"main":{"services":["api"],"agent":"main"}}}' | Set-Content $lf
$u1 = Px $L2 up -Env shop 2>&1 | Out-String; $c4 = $LASTEXITCODE; $null = Px $L2 unhold -Env shop -Agent main 2>&1
Expect "localenv: up refuses without -Services; unhold ends a hold" ($c4 -eq 1 -and $u1 -match 'up needs -Services' -and -not @((Get-Content $lf -Raw | ConvertFrom-Json).holds.PSObject.Properties).Count)
# leases.jsonl: one line per lease or hold that comes or goes (acquire, reclaim by Prune past the grace, release); status: last used
$el = & { . $L2; $lp = Get-KitPath leases; Remove-Item $lp -ErrorAction SilentlyContinue
  Update-State shop { param($x) $x.leases.Y = @{ services = @('api') } + (New-KitLease 'Y' ''); $x.leases.Z = @{ services = @('api'); agent = 'Z'; at = (Get-Date).ToString('o'); holderPid = 999999; seen = (Get-Date).AddMinutes(-11).ToString('o') } }
  Update-State shop { param($x) Prune $x }; $null = Px $L2 release -Env shop -Agent Y
  $g = @(Get-Content $lp | ConvertFrom-Json); "$((@($g[0..1] | ForEach-Object { "$($_.event)/$($_.agent)" } | Sort-Object) + @($g[2..9] | ForEach-Object { "$($_.event)/$($_.agent)/$($_.reason)" })) -join ',')" }
$es = Px $L2 status -Env shop 2>&1 | Out-String
Expect "localenv: acquire, reclaim, release each one leases.jsonl line ($el)" ($el -eq 'acquire/Y,acquire/Z,reclaim/Z/reclaim: no live holder for 10 min,release/Y/')
Expect "localenv: status shows the env's last use ($(($es -split "`n")[0].Trim()))" ($es -match 'last used \d\d-\d\d \d\d:\d\d by Y \(release\)')
# restart: only the named service, every lease stays, no suppress (down ends leases and stops dependents)
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ snapshot = 'echo s'; restore = 'echo r' } }; rs = @{ services = @(@{ name = 'api'; start = 'echo a'; port = 1 }, @{ name = 'web'; start = 'echo w'; port = 2; dependsOn = @('api') }) } } } } (Join-Path $k2 'skills/crafty/kit.local.json') 6
$rf = & { . (Join-Path $k2 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'rs.json' }; '{"leases":{"F2":{"services":["api"],"agent":"F2","owner":true,"until":"2999-01-01T00:00:00"}}}' | Set-Content $rf
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
Expect "localenv: a waiting start is pressure, cache counts, then the claim stays while it waits for the start lock ($wr)" ($wr -eq 'start(s) waiting for RAM: shop/web|waiting')
Remove-TestKit $k2
# config: envs inherit localEnv.defaults, then extends (named lists merge by name); a loop in extends is refused
$k3 = New-LocalEnvKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'; $cf3 = Join-Path $k3 'skills/crafty/kit.local.json'
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
$lr = & { . $L3; $rows = @([pscustomobject]@{ State = 'Listen'; RemoteAddress = '0.0.0.0'; RemotePort = 0 }, [pscustomobject]@{ State = $null; RemoteAddress = '0.0.0.0'; RemotePort = 0 },
    [pscustomobject]@{ State = $null; RemoteAddress = '::'; RemotePort = 0 }, [pscustomobject]@{ State = 'Established'; RemoteAddress = '127.0.0.1'; RemotePort = 9201 }); ($rows | ForEach-Object { Test-ListenRow $_ }) -join '|' }
Expect "listen table: a listener with state 0 (no remote end) still counts; a connection does not ($lr)" ($lr -eq 'True|True|True|False')
# running services' logs: only new out-of-memory lines count; logs -Grep / -Since read from the end
$lg = Join-Path (Kd) 'svc.log'; "$((Get-Date).AddMinutes(-90).ToString('yyyy-MM-dd HH:mm:ss')) old ERROR x`n<--- JS stacktrace --->`nFATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory" | Set-Content $lg
$om = & { . $L3; $pos = @{}; $a = Find-NewLogLine $lg $script:OomPattern $pos; Add-Content $lg "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) new ERROR y"; Add-Content $lg 'FATAL ERROR: Reached heap limit again'
  $b = Find-NewLogLine $lg $script:OomPattern $pos; $c = Find-NewLogLine $lg $script:OomPattern $pos
  "$([bool]$a)|$($b -match 'again')|$([bool]$c)|$('JavaScript heap out of memory' -match $script:FailPattern)|$((Read-LogTail $lg 50 'ERROR [xy]' 30) -join ';')|$(@(Read-LogTail $lg 2 '' 0).Count)" }
Expect "logs: only new OOM lines; FailPattern has heap OOM; -Grep + -Since from the end ($om)" ($om -match '^False\|True\|False\|True\|\d{4}-\d\d-\d\d \d\d:\d\d:\d\d new ERROR y\|2$')
# _exec: the service output is copied to its log; past logMaxMB the log moves to .prev
& $J @{ localEnv = @{ logMaxMB = 0.002; envs = @{ t = @{ services = @(@{ name = 'gen'; start = 'pwsh -NoProfile -Command "1..80 | ForEach-Object { ''x'' * 60 }"' }) } } } } $cf3 8
$null = Px $L3 _exec -Env t -Service gen 2>&1; $gl = & { . (Join-Path $k3 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv-logs -Create) 't-gen.log' }
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
  function Start-Pwsh { Set-Content (LogFile t api) 'x', 'ERROR first', 'Caused by: boom'; 999999 }; function Healthy { $false }
  try { Start-Svc t (Svc t api) 9 '' | Out-Null } catch { $script:err = "$_" }
  "$($script:log -join ',')|$($script:err -match 'exited while starting\. Cause: Caused by: boom\. Log: .*t-api\.fail-9\.log' -and (Test-Path ((LogFile t api) -replace 'log$', 'fail-9.log')))" }
Expect "start: room, lock, room again when RAM fell; no stop of a stopped service; a failed start's log kept with its cause line ($ss)" ($ss -like 'room,room,stop:exited while starting|True')
# dependsOn healthy first; a start failing on a dependency connection waits for it again and retries once; another failure throws
$dr = & { . $L3; $script:h = 0; $script:n = 0; function Svc { [pscustomobject]@{ name = $args[1]; external = $args[1] -eq 'es'; dependsOn = $(if ($args[1] -eq 'api') { @('es') }) } }   # es external: waited for, never started here
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
$lq = & { . $L3; Update-State t { param($x) $x.leases = @{ Q1 = @{ services = @('api'); agent = 'Q1'; holderPid = $PID; lastUse = (Now) } }; $x.requests = @(@{ id = 'r9'; kind = 'deploy'; agent = 'Q1'; status = 'queued' }) }
  $t0 = Get-Date; $c = @(Wait-Leases t @('api') @() @()) -join ' '; "$(((Get-Date) - $t0).TotalSeconds -lt 5)|$($c -notmatch 'Q1')" }
Expect "leases: a holder whose own deploy waits in the queue behind this train is not waited for ($lq)" ($lq -eq 'True|True')
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
$null = Px $L3 _exec -Env t -Service cmp 2>&1; $cl = Get-Content (& { . (Join-Path $k3 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath localenv-logs) 't-cmp.log' }) -Raw
Expect "review: worker failure -> failed; no lease = no clock; compound stderr kept; 'not found' output != misconfigured ($rv)" ($rv -eq 'failed/True|True|1' -and $cl -match 'out1' -and $cl -match 'err1' -and $cl -match 'done1')
# a start worker that finds its service already up counts no restart; one that tries counts one (the backoff reads them)
$tl9 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 41009); $tl9.Start()
$lr = & { . $L3; @((Read-State tl).services.api.restarts | Where-Object { $_ }).Count }   # the loop above spawned api's worker: the loop counts none
& { . $L3; Update-State tl { param($x) $x.services.api = @{ status = 'down'; restarts = @((Get-Date).AddMinutes(-5).ToString('o')) } } }
$null = Px $L3 _daemon -Env tl -Start api 2>&1; $tl9.Stop()
$au = & { . $L3; $x = Read-State tl; "$lr|$($x.services.api.status)|$(@($x.services.api.restarts).Count)|$(@($x.services.gone.restarts).Count)" }
Expect "start worker: the loop counts no restart; 'already up' -> status up, none counted; a real try (gone) counts 1 ($au)" ($au -eq '0|up|1|1')
# deadlock 2026-10-29: a start waiting on CPU (or claiming a dependency) is no memory pressure; dependencies of a waiting,
# starting or train-blocked service are never idle; a down dependency is started first; a dependency failure is 'dependency down'
& $J @{ localEnv = @{ idle = @{ minMinutes = 1; maxMinutes = 1 }; envs = @{ dp = @{ services = @(@{ name = 'search'; start = 'echo s'; port = 41021 }, @{ name = 'api'; start = 'echo a'; port = 41022; dependsOn = @('search') }) } } } } $cf3 8
$cw = & { . $L3; Update-State dp { param($x) $x.services = @{ api = @{ status = 'down' } } }; $script:ph = 0
  function Get-SysMem { [pscustomobject]@{ AvailGB = 40; CacheGB = 0; TotalGB = 64 } }; function Get-SysCpu { @(95, 10)[$script:ph] }; function Need-GB { 3 }; function KeepFreeGB { 6 }
  function Start-Sleep { $script:seen = "$(Pressure)/$((Read-State dp).services.api.waitFor)"; $script:ph = 1 }
  $null = Wait-Room dp @{ name = 'api' }; $script:seen }
Expect "pressure: a start waiting only for CPU is no memory pressure (waitFor CPU) ($cw)" ($cw -eq '/CPU')
$ip = & { . $L3; $old = (Get-Date).AddMinutes(-30).ToString('o')
  $mk = { param($api) @{ services = @{ search = @{ status = 'up'; lastNeed = $old; gb = 2 }; api = $api } } }
  $r = foreach ($api in @{ status = 'waiting'; waitPid = $PID; waitStart = (Get-KitPidStart $PID) }, @{ status = 'waiting'; waitPid = 999999 }, @{ status = 'starting' }, @{ status = 'down' }) { $st = & $mk $api; (@(Get-IdleServices dp $st @{} @() 'start(s) waiting for RAM: x' | ForEach-Object name) -join ',') + '.' }
  $st = & $mk @{ status = 'down' }; $r += (@(Get-IdleServices dp $st @{} @('api') 'p' | ForEach-Object name) -join ',') + '.'; -join $r }
Expect "idle: a dependency of a live waiting / starting / train-blocked service is kept under pressure; of a stale waiting or down one it is idle ($ip)" ($ip -eq '.search..search..')
$wd = & { . $L3; Update-State dp { param($x) $x.services = @{ search = @{ status = 'down' } } }; $script:started = @()
  function Healthy { param($e, $s) $s.name -ne 'search' -or $script:started -contains 'search' }; function Wait-KitPoll { }; function Event { }
  function Start-Svc { param($e, $s) $script:started += $s.name; "claim=$((Read-State dp).services.search.status)/$((Read-State dp).services.search.waitFor)" }
  $o1 = @(Wait-Deps dp (Svc dp 'api')) -join ';'
  $script:started = @(); Update-State dp { param($x) $x.services.search = @{ status = 'waiting'; waitPid = $PID; waitStart = (Get-KitPidStart $PID) } }
  function Healthy { $false }; $script:t0 = 0; function Get-Date { if ($args.Count) { Microsoft.PowerShell.Utility\Get-Date @args } else { (Microsoft.PowerShell.Utility\Get-Date).AddMinutes(20 * $script:t0++) } }
  $o2 = try { $null = Wait-Deps dp (Svc dp 'api'); 'no throw' } catch { "$_" }
  $script:t0 = 0; Update-State dp { param($x) $x.services.search = @{ status = 'up'; pid = $PID; pstart = (Get-KitPidStart $PID) } }   # alive but slow: waited for, never restarted
  $o3 = try { $null = Wait-Deps dp (Svc dp 'api'); 'no throw' } catch { "$_" }
  "$($o1 -match 'starting it first' -and $o1 -match 'claim=waiting/dep')|$($script:started.Count)|$($o2 -match ': dependency down: search was not healthy')|$($o3 -match ': dependency down: ')" }
Expect "deps: a down dependency nobody starts is claimed and started first; one claimed by a live start or alive but unhealthy is only waited for; timeout says 'dependency down' ($wd)" ($wd -eq 'True|0|True|True')
$sr = & { . $L3; function Wait-Deps { }; function Start-SvcOnce { throw 'Connection refused: connect' }; function Healthy { $false }; function Event { }; function Wait-KitPoll { }
  try { $null = Start-Svc dp (Svc dp 'api') 1 ''; 'no throw' } catch { "$_" } }
Expect "deps: a start failing on a dependency connection while the dependency is down throws 'dependency down' (the train keeps its release) ($sr)" ($sr -match ': dependency down: search went down')
$tb = Get-Content (Join-Path $src 'skills/envy/envy.ps1') -Raw
Expect "train: a 'dependency down' switch failure keeps the release (no rollback), any other failure rolls back" ($tb -match "if \(\`$sw -notmatch ': dependency down: '\) \{ & \`$rollback" -and $tb -match 'kept release \$newN but is not up')
# envy up / use / task with -Wait <min> and a deferred request: Wait-Request reads the verb's [double]$Wait, never a [switch]
$wk = & { . $L3; [double]$Wait = 4; function Ensure-Loop { }   # the verb's Wait-Request reads $Wait by scope
  Update-State dp { param($x) $x.requests = @(@{ id = 'q1'; kind = 'drop'; branch = 'b'; status = 'deferred' }) }
  $script:wr = @(); function Wait-Request { $script:wr += "$($Wait.GetType().Name)=$Wait" }
  Wake-Deferred dp -UntilDone; "$($script:wr -join ',')|$((Read-State dp).requests[0].status)" }
Expect "up -Wait 4: Wake-Deferred -UntilDone leaves the verb's [double]`$Wait to Wait-Request (no SwitchParameter clash) ($wk)" ($wk -eq 'Double=4|queued')
# the loop reloads when a goody adapter it dot-sources changes, not only kit.local.json / envy.ps1 / lib.ps1
$ls0 = & { . $L3; Get-LoopStamp }; $adp = New-Item -ItemType Directory -Force (Join-Path $k3 'skills/envy/adapters'); Set-Content (Join-Path $adp 'zz-test.ps1') '# test'
$ls1 = & { . $L3; Get-LoopStamp }; Remove-Item (Join-Path $adp 'zz-test.ps1')
Expect "loop: an adapter added or changed changes the loop stamp ($ls1)" ($ls0 -match 'envy\.ps1=\d+' -and $ls0 -match 'lib\.ps1=\d+' -and $ls0 -match 'kit\.local\.json=\d+' -and $ls1 -match 'zz-test\.ps1=\d+' -and $ls0 -ne $ls1)
# idle stops: every idle service in one tick (a dependent first keeps its dependency); a train waiting for leases blocks none
& $J @{ localEnv = @{ idle = @{ minMinutes = 1; maxMinutes = 1 }; envs = @{ t = @{ services = @(@{ name = 'api'; start = 'echo a'; port = 41011 }, @{ name = 'web'; start = 'echo w'; port = 41012; dependsOn = @('api') }, @{ name = 'job'; start = 'echo j'; port = 41013 }) } } } } $cf3 8
$id = & { . $L3; $old = (Get-Date).AddMinutes(-30).ToString('o')
  $st = @{ services = @{ api = @{ status = 'up'; lastNeed = $old; gb = 1 }; web = @{ status = 'up'; lastNeed = $old; gb = 7 }; job = @{ status = 'up'; lastNeed = $old; gb = 2 } }; train = @{ phase = 'waiting for leases (code)'; blockServices = @('web', 'api') } }
  $a = @(Get-IdleServices t $st @{} @(Get-IdleBlock $st) '' | ForEach-Object name) -join ','
  $st.train.phase = 'switching over'; $b = @(Get-IdleServices t $st @{} @(Get-IdleBlock $st) '' | ForEach-Object name) -join ','
  $st.services.web.status = 'down'; $c = @(Get-IdleServices t $st @{ job = @('lease:x') } @() '' | ForEach-Object name) -join ','; "$a|$b|$c" }
Expect "idle: all idle services at once, biggest first, a dependency after its dependent; a train waiting for leases blocks none ($id)" ($id -eq 'web,job|job|api')
# starts: the ready line triggers health at once; a fail line half written is read again when complete; no stop event when nothing ran
$rl = Join-Path (Kd) 'ready.log'; Set-Content $rl 'boot' -NoNewline
$rd = & { . $L3; $pos = @{ $rl = 0 }; $a = Find-NewLogLine $rl 'Started \S+ in' $pos; Add-Content $rl "`nStarted App in 3.2 sec" -NoNewline; $b = Find-NewLogLine $rl 'Started \S+ in' $pos; Add-Content $rl 'onds'
  $c = Find-NewLogLine $rl 'Started \S+ in [\d.]+ seconds' $pos; [IO.File]::AppendAllBytes($rl, [byte[]](0xE9, 0xFF, 10) + [Text.Encoding]::UTF8.GetBytes("Started B in 1.0 seconds`n")); $d = Find-NewLogLine $rl 'Started B in' $pos
  "$([bool]$a)|$([bool]$b)|$($c -match 'seconds' -and [bool]$d)|$('Started MposApp in 41.2 seconds (process running for 43)' -match $script:ReadyPattern)" }
Expect "start: a line still being written is read again; the default ready line matches Spring Boot ($rd)" ($rd -eq 'False|False|True|True')
$se = & { . $L3; Update-State t { param($x) $x.services = @{ job = @{ status = 'down' } } }; $script:ev = 0; function Event { $script:ev++ }; Stop-Svc t (Svc t job) 'idle'; $script:ev }
Expect "stop: nothing ran -> no stop event ($se)" ("$se" -eq '0')
# staging: unpack keeps each library once (hard links, content hash), keepReleases + the ones in use stay, unlinked store files go;
# a static service stages its built files and runs the kit's static server; {aot} only once a training run wrote the cache
$ud = Kd; $wtd = Join-Path $ud 'wt'; New-Item -ItemType Directory -Force (Join-Path $wtd 'api/target'), (Join-Path $wtd 'web/dist/app') | Out-Null
'fat' | Set-Content (Join-Path $wtd 'api/target/app-1.jar'); '<html>i</html>' | Set-Content (Join-Path $wtd 'web/dist/app/index.html'); 'x' | Set-Content (Join-Path $wtd 'web/dist/app/main.js')
$unp = "pwsh -NoProfile -Command `"New-Item -ItemType Directory -Force '{out}/lib' | Out-Null; 'thin' | Set-Content '{out}/app.jar'; 'L1' | Set-Content '{out}/lib/a.jar'; Set-Content '{out}/lib/b.jar' `$(if (Test-Path '$ud/v2') { 'L3' } elseif (Test-Path '$ud/mid') { 'L4' } else { 'L2' })`""
& $J @{ localEnv = @{ keepReleases = 2; envs = @{ t = @{ services = @(@{ name = 'api'; dir = (Join-Path $wtd 'api'); artifact = 'target/app-*.jar'; unpack = $unp; port = 41014; start = 'java {aot} -jar "{artifact}"'; aotTrain = 'echo t' }, @{ name = 'web'; dir = (Join-Path $wtd 'web'); static = 'dist/app'; port = 41015 }) } } } } $cf3 8
$sg = & { . $L3; function RepoOf { 'r' }
  $r1 = Stage-Artifacts t r 'r1-a'; Update-State t { param($x) $x.services = @{ api = @{ status = 'up'; artifact = $r1.api } } }; Start-Sleep -Milliseconds 50
  Set-Content "$ud/mid" 1; $null = Stage-Artifacts t r 'r2-b'; Start-Sleep -Milliseconds 50; Set-Content "$ud/v2" 1; $null = Stage-Artifacts t r 'r3-c'; Start-Sleep -Milliseconds 50
  $r3 = Stage-Artifacts t r 'r4-d'; $root = Split-Path (Split-Path $r1.api)
  $dirs = @(Get-ChildItem $root -Directory | Where-Object Name -notlike '_*' | ForEach-Object Name | Sort-Object) -join ','; $store = @(Get-ChildItem (Join-Path $root '_lib') -File).Count
  $links = (Get-Item (Join-Path (Split-Path $r3.api) 'lib/a.jar')).LinkType
  $a0 = StartCmd t (Svc t api) $r3.api; Set-Content (AotFile $r3.api) 'aot'; $a1 = StartCmd t (Svc t api) $r3.api
  Update-State t { param($x) $x.services.web = @{ status = 'up'; artifact = $r3.web } }; $again = Stage-Artifacts t r 'r4-d'; $keep = Test-Path (Join-Path $r3.web 'main.js')
  Update-State t { param($x) $x.services.api = @{ status = 'up'; artifact = $again.api } }; $old = @(Remove-OldReleases t (Svc t api) $root -DryRun | ForEach-Object { Split-Path $_ -Leaf }) -join ','
  Update-State t { param($x) $x.services.web = @{ status = 'down' } }
  "$($again.web -like '*r4-d-2')/$keep/$old|$dirs|$store|$links|$(Split-Path $r3.api -Leaf)|$(Test-Path (Join-Path $r3.web 'main.js'))|$((StartCmd t (Svc t web) $r3.web) -match 'static-server\.mjs')|$($a0 -notmatch 'AOTCache')|$($a1 -match '-XX:AOTCache=')" }
Expect "stage: libraries once (hard links), 2 releases + the one in use kept, store pruned; a running copy is never replaced (-2), old ones listed by -DryRun; static files staged + served by the kit; {aot} once cached ($sg)" ($sg -eq 'True/True/r1-a|r1-a,r3-c,r4-d|3|HardLink|app.jar|True|True|True|True')
$sv = & { . $L3; $port = 41016; $srv = Start-Process node -ArgumentList "`"$(StaticServer)`" `"$(Join-Path $wtd 'web/dist/app')`" $port" -PassThru -WindowStyle Hidden
  try { for ($i = 0; $i -lt 40 -and -not (Test-PortListening $port); $i++) { Start-Sleep -Milliseconds 250 }
    $g = { param($u) try { $x = Invoke-WebRequest "http://127.0.0.1:$port$u" -SkipHttpErrorCheck -TimeoutSec 5; "$($x.StatusCode):$("$($x.Content)".Trim())" } catch { 'ERR' } }
    "$(& $g '/')|$(& $g '/orders/7')|$(& $g '/main.js')|$((& $g '/nope.js') -replace ':.*')|$((& $g '/..%2f..%2fwt') -replace ':.*')|$((& $g '/%00') -replace ':.*')|$(-not $srv.HasExited)" } finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } }
Expect "static server: index at /, unknown routes -> index.html, files as they are, a missing file 404, no way out of the root, a NUL path 400 and it keeps serving ($sv)" ($sv -match '^200:<html>i</html>\|200:<html>i</html>\|200:x\|404\|(403|404)\|400\|True$')
# builds: {reactor} = one aggregator of the module folders + the service's module, -pl it -am; prepare edits are committed locally
$rx = & { . $L3; New-Item -ItemType Directory -Force (Join-Path $wtd 'lib/m1'), (Join-Path $wtd 'lib/m2'), (Join-Path $wtd 'lib/m3') | Out-Null
  $pom = { param($g, $a) "<project><parent><groupId>$g</groupId><artifactId>$a</artifactId></parent></project>" }
  '<project><groupId>o</groupId><artifactId>root</artifactId></project>' | Set-Content (Join-Path $wtd 'pom.xml')
  & $pom 'o' 'root' | Set-Content (Join-Path $wtd 'api/pom.xml'); & $pom 'o' 'root' | Set-Content (Join-Path $wtd 'lib/m1/pom.xml'); & $pom 'o' 'lib-parent' | Set-Content (Join-Path $wtd 'lib/m3/pom.xml')
  function EnvRepos { @{ r = [pscustomobject]@{ wt = $wtd } } }; function RepoOf { 'r' }
  $a = Write-Reactor t ([pscustomobject]@{ name = 'api'; dir = (Join-Path $wtd 'api'); reactor = @('lib/*') }) 6>$null; $x = Get-Content (Join-Path $wtd '.localenv-reactor-api.xml') -Raw
  "$($a -match '-pl api -am$')|$($x -match '<module>lib/m1</module><module>api</module></modules>')|$($x -notmatch 'm2|m3')" }
Expect "build: {reactor} -> -f <aggregator> -pl <service module> -am over the module folders with a pom whose parent is the module's (m3: another parent, not built) ($rx)" ($rx -eq 'True|True|True')
# a failed unpack stages the plain artifact (event unpack-fallback); the loop restarts on an edited kit.local.json between trains
$uf = & { . $L3; function RepoOf { 'r' }; $script:evs = @(); function Event($e, $k, $d) { $script:evs += $k }
  function Svc0 { [pscustomobject]@{ name = 'api'; dir = (Join-Path $wtd 'api'); artifact = 'target/app-*.jar'; unpack = 'exit 3' } }; function EnvServices { Svc0 }
  $r = Stage-Artifacts t r 'r9-f' 6>$null; "$((Split-Path $r.api -Leaf) -eq 'app-1.jar' -and (Get-Content $r.api) -eq 'fat')|$($script:evs -contains 'unpack-fallback')" }
$ls = Get-Content (Join-Path $src 'skills/envy/envy.ps1') -Raw
Expect "stage: a failed unpack -> the plain artifact + unpack-fallback; loop: kit.local.json or envy.ps1 / lib.ps1 mtime -> a fresh loop between trains ($uf)" ($uf -eq 'True|True' -and $ls -match '\$cfgNow = Get-LoopStamp' -and $ls -match 'if \(-not \$st\.train -and \$cfgNow -ne \$cfgAt -and' -and $ls -match 'if \(\$reload\) \{ \$null = Start-Pwsh')
# cleanup: logs / run files / data folders / env worktrees no configured env uses are orphans; -DryRun deletes nothing
& $J @{ localEnv = @{ cleanup = @{ dataRoots = @(@{ dir = (Join-Path $ud 'data'); match = 'sb1|^t$' }); quick = @(@{ name = 'old q'; paths = @("$ud/q/*"); olderThanDays = 1; cmd = 'echo q' }) }; envs = @{ t = @{ db = @{ datadir = (Join-Path $ud 'data/keepsb1') }; services = @(@{ name = 'api'; start = "run -Epath.data=$(Join-Path $ud 'data/t')"; port = 41017 }) } } } } $cf3 8
$co = & { . $L3; $lgd = Get-KitPath localenv-logs -Create; foreach ($n in 't-api.log', 't-api.log.prev', 't-sb1-api.log', 't-loop.log', 'x-web.log') { Set-Content (Join-Path $lgd $n) 1; (Get-Item (Join-Path $lgd $n)).LastWriteTime = (Get-Date).AddDays(-2) }
  New-Item -ItemType Directory -Force (Join-Path $ud 'data/t'), (Join-Path $ud 'data/tsb1'), (Join-Path $ud 'data/jdk'), (Join-Path $ud 'data/keepsb1') | Out-Null; 'd' | Set-Content (Join-Path $ud 'data/tsb1/x')
  New-Item -ItemType Directory -Force "$ud/q/old", "$ud/q/new" | Out-Null; (Get-Item "$ud/q/old").LastWriteTime = (Get-Date).AddDays(-3)
  $o = @(Get-EnvOrphans | ForEach-Object { Split-Path $_.path -Leaf } | Sort-Object) -join ','; $dry = Invoke-EnvCleanup -Quick -DryRun; $dq = ($dry -join ' ') -match 'q[\\/]old \(quick: old q\)' -and ($dry -join ' ') -notmatch 'q[\\/]new' -and ($dry -join ' ') -match 'would run \(old q\): echo q'
  "$o|$((Test-Path (Join-Path $ud 'data/tsb1')) -and ($dry -join ' ') -match 'would remove' -and $dq)" }
Expect "cleanup: orphan logs (unknown env or service), run folders and data folders (dataRoots match only) found; -Quick adds cleanup.quick items past olderThanDays; -DryRun deletes nothing ($co)" ($co -match '^(.*,)?t-sb1-api\.log,(.*,)?tsb1,(.*,)?x-web\.log(,.*)?\|True$' -and $co -notmatch '(^|,)t-api\.log|t-loop|(^|,)t,|jdk|keepsb1')
# prepare: a local-only edit after each sync, committed on the env branch (never pushed); a failed prepare only warns
$gr = Kd; $go = Join-Path $gr 'o'; git init -q -b main $go; Set-Content (Join-Path $go 'f.txt') 'v1'; git -C $go add .; git -C $go -c user.name=t -c user.email=t@t commit -qm init; git clone -q $go (Join-Path $gr 'c') 2>$null
& $J @{ repos = @(@{ name = 'r'; checkout = (Join-Path $gr 'c'); target = 'main' }); localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'web'; repo = 'r'; port = 41018; prepare = "pwsh -NoProfile -Command `"Set-Content f.txt '{cache}'`"" }) } } } } $cf3 8
$pp = & { . $L3; $c = Join-Path $gr 'c'; function SvcDir { $c }; function Sync-DepLinks { }
  $res = Sync-Repo t ([pscustomobject]@{ name = 'r'; wt = $c; target = 'main'; cfg = [pscustomobject]@{ checkout = $c } }) @() -NoFetch
  "$((Get-Content (Join-Path $c 'f.txt') -Raw).Trim() -like '*localenv*t-web')|$(git -C $c log -1 --format=%s)|$(@(git -C $c status --porcelain).Count)|$($res.targetSha -eq (git -C $go rev-parse HEAD))" }
Expect "prepare: its edit (here {cache}: outside the repo) is committed on the env worktree, the target sha stays the base ($pp)" ($pp -eq 'True|localenv prepare web (local only)|0|True')
# merged layers: a squash-merged one (host: MR merged at its commit) and one merged past its commit drop; a reused branch, an MR into another target, an open one stay
$sq = Kd; $so = Join-Path $sq 'sqo'; git init -q -b main $so; Set-Content (Join-Path $so 'f.txt') 'v1'; git -C $so add .; git -C $so -c user.name=t -c user.email=t@t commit -qm init
$sqc = { param($sqb, $sqf, [switch]$New) if ($New) { git -C $so checkout -q -b $sqb main } else { git -C $so checkout -q $sqb }; Add-Content (Join-Path $so $sqf) $sqb; git -C $so add .; git -C $so -c user.name=t -c user.email=t@t commit -qm $sqb; "$(git -C $so rev-parse HEAD)".Trim() }
$sq1 = & $sqc sq1 a.txt -New; $gr1 = & $sqc grow b.txt -New; $gr2 = & $sqc grow b.txt; $ru1 = & $sqc reuse c.txt -New; $ru2 = & $sqc reuse c.txt; $ot1 = & $sqc other d.txt -New; $op1 = & $sqc open e.txt -New
git -C $so checkout -q main; git -C $so merge -q --squash sq1; git -C $so -c user.name=t -c user.email=t@t commit -qm 'sq1 squashed'
$sqd = Join-Path $sq 'sqc'; git clone -q $so $sqd 2>$null; git -C $sqd remote set-url origin 'https://git.example.com/g/r.git'
& $J @{ repos = @(@{ name = 'r'; checkout = $sqd; target = 'main' }); localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'web'; repo = 'r'; port = 41018 }) } } } } $cf3 8
$sqr = & { . $L3; function Sync-DepLinks { }; function G([string]$d) { if ($args[0] -eq 'fetch') { return }; $o = & git -C $d @args 2>&1; if ($LASTEXITCODE) { throw "git $args : $o" }; $o }
  $mrBy = @{ sq1 = @{ iid = 1; sha = $sq1; target_branch = 'main' }; grow = @{ iid = 2; sha = $gr2; target_branch = 'main' }; reuse = @{ iid = 3; sha = $ru1; target_branch = 'main' }; other = @{ iid = 4; sha = $ot1; target_branch = 'next' } }
  $global:sqAsk = @(); function Invoke-HostVerb([string]$Verb, [hashtable]$A) { $global:sqAsk += "$($A.repo):$($A.source_branch):$($A.state)"; if ($A.source_branch -eq 'open') { throw 'host offline' }; if ($mrBy[$A.source_branch]) { @([pscustomobject]$mrBy[$A.source_branch]) } else { @() } }
  $lay = @(@{ branch = 'sq1'; sha = $sq1 }, @{ branch = 'grow'; sha = $gr1 }, @{ branch = 'reuse'; sha = $ru2 }, @{ branch = 'other'; sha = $ot1 }, @{ branch = 'open'; sha = $op1 })
  $res = Sync-Repo t ([pscustomobject]@{ name = 'r'; wt = $sqd; target = 'main'; cfg = [pscustomobject]@{ checkout = $sqd } }) $lay
  $nf = Sync-Repo t ([pscustomobject]@{ name = 'r'; wt = $sqd; target = 'main'; cfg = [pscustomobject]@{ checkout = $sqd } }) @(@{ branch = 'sq1'; sha = $sq1 }) -NoFetch
  "$(@($res.kept.branch) -join ',')|$(@($res.dropped | ForEach-Object { "$($_.layer.branch)=$($_.why)" }) -join ',')|$($global:sqAsk[0])|$(@($nf.kept).Count)" }
Expect "merged layers: squash-merged (MR at the layer commit) and merged past it drop; reused branch, other target, open (host offline) stay; -NoFetch asks no host ($sqr)" ($sqr -eq 'reuse,other,open|sq1=merged into main (MR 1),grow=merged into main (MR 2)|g/r:sq1:merged|1')
# a reader holding the old service log (no delete share): the start appends to it and skips its old lines (an old fail line is no failure)
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'x' }) } } } } $cf3 8
$lk = & { . $L3; $lkLog = LogFile t api; Set-Content $lkLog 'APPLICATION FAILED TO START (old run)'; $lkHold = [IO.File]::Open($lkLog, 'Open', 'Read', 'ReadWrite')
  function SvcDir { $sq }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { Add-Content $lkLog 'Started App in 1.0 seconds'; $PID }; function Healthy { (++$script:lkH) -gt 1 }
  try { $o = @(Start-SvcOnce t (Svc t api) 1 '') -join ' '; "$($o -match 'open elsewhere, appending')|$((Read-State t).services.api.status)|$(-not (Test-Path "$lkLog.prev"))" } catch { "threw: $_" } finally { $lkHold.Dispose() } }
Expect "start: a held log is appended to, its old fail line ignored, the service comes up ($lk)" ($lk -eq 'True|up|True')
# a start worker queued with a copy that trains replaced (and pruned) while it waited for room starts the copy the state names
$lt = & { . $L3; Update-State t { param($x) $x.services = @{ api = @{ status = 'failed'; artifact = 'run/r9-b/app.jar'; release = 9 } } }
  function SvcDir { $sq }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }; $script:ltArgs = $null; function Healthy { [bool]$script:ltArgs }; function Stop-Svc { }; function Wait-Deps { }   # up only once launched
  function Start-Pwsh { $script:ltArgs = "$($args[0] -join ' ')"; $PID }
  $o = @(Start-Svc t (Svc t api) 7 'run/r7-a/app.jar' -Latest) -join ' '; $sv = (Read-State t).services.api
  $null = Start-SvcOnce t (Svc t api) 7 'run/r7-a/app.jar'; "$($script:ltArgs -match 'r7-a')|$($o -match 'starting api \(release 9\)')|$($sv.artifact)|$($sv.release)" }
$ltw = (Get-Content $L3 -Raw) -match "Start-Svc \`$e \`$s \`$Release \`$Artifact -Latest" -and ([regex]::Matches((Get-Content $L3 -Raw), 'Start-SvcOnce \$e \$s \$release \$artifact -Latest:\$Latest')).Count -eq 2
$lg = & { . $L3; function SvcDir { $sq }; function Wait-Room { }; function Test-Room { $true }; function Healthy { $true }; function Stop-Svc { }; $script:lgRun = 0; function Start-Pwsh { $script:lgRun++; $PID }
  "$(@(Start-SvcOnce t (Svc t api) 7 '' -Latest) -join ' ')|$script:lgRun" }
Expect "start: a worker (-Latest) whose service another process started while it waited for the lock launches nothing ($lg)" ($lg -match 'started by another process meanwhile\|0$')
Expect "start: -Latest (the start worker, through Start-Svc and its retry) runs the state's newer copy, not the one it was queued with; a train's own start keeps its copy ($lt|$ltw)" ($lt -eq 'True|True|run/r9-b/app.jar|9' -and $ltw)
# a switch-over that fails and a rollback restart that fails too: the state names the previous copy, never the rolled-back one
$a1 = Join-Path $sq 'r1-a.jar'; Set-Content $a1 x; $rbw = Join-Path $k3 'rb-train.ps1'
& { . $L3; Update-State t { param($x) $x.release = @{ n = 1; repos = @{ r = @{ targetSha = 't0'; layers = @() } } }; $x.services = @{ api = @{ status = 'up'; artifact = $a1; release = 1 } }
    $x.requests = @(@{ id = 'q1'; kind = 'deploy'; branch = 'b'; agent = 'A'; shas = @{ r = 's1' }; migrations = @{}; status = 'in-train' }); $x.train = @{ id = 'tr2'; requests = @('q1') } } }
Set-Content $rbw @"
. '$L3'
function EnvServices { [pscustomobject]@{ name = 'api'; repo = 'r'; artifact = 'app.jar'; start = 'x' } }; function RepoOf { 'r' }; function EnvRepos { @{ r = @{ target = 'main'; wt = '$sq'; cfg = @{ checkout = '$sq' } } } }
function Wait-Leases { }; function Sync-Repo { @{ dropped = @(); kept = @(`$args[2]); targetSha = 't1' } }; function Build-Repo { `$null }; function Stage-Artifacts { @{ api = 'run/r2-tr2/app.jar' } }
function Start-Svc { if (`$args[3] -match 'r2') { Update-State t { param(`$z) `$z.services.api.artifact = 'run/r2-tr2/app.jar'; `$z.services.api.release = 2 } }; throw 'not healthy' }
Invoke-Daemon -Env t -Train tr2
"@
$null = Px $rbw 2>&1
$rb = & { . $L3; $sv = (Read-State t).services.api; "$($sv.artifact -eq $a1)|$($sv.release)|$((Read-State t).release.n)" }
Expect "rollback: a failed switch-over and a failed restart leave the previous release's copy in the state ($rb)" ($rb -eq 'True|1|1')
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
# supervise rows from this goody (skills/bossy/adapters/localenv_supervise.ps1): idle vs leased down services, new log errors
$k = New-LocalEnvKit lsup; $ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/bossy/adapters'); Copy-Item (Join-Path $src 'skills/bossy/adapters/localenv_supervise.ps1') $ad
$O = Join-Path $k 'skills/bossy/bossy.ps1'
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
# supervise -Brief cells: short problem / next (~90 chars a cell), the whole line stays in what / action (the report file)
$sc = & { . $O; Add-Content $sl ("2026-10-23 ERROR c.d.X - " + ('boom ' * 80)); $s3 = @(Get-KitLogErrors @($sl) @{ (Resolve-Path $sl).Path = $ss.size })[0]
  $f = Get-KitSpikeFlag $s3 (& $ev @()); $d = Get-KitSpikeFlag $ss (& $ev @(@{ agent = 'q1' })); "$($f.kind)|$($f.who)|$($f.problem)|$($f.next.Length)|$($f.action -match "boom boom boom")|$($d.problem)/$($d.next)" }
Expect "ERROR SPIKE cells: kind, who '<env> <service>', problem '<n> new error lines in <env> <service> log', next = class + 60 chars; the action stays whole ($sc)" ($sc -match '^ERROR SPIKE\|shop api\|\d+ new error lines? in shop api log\|\d+\|True\|api failed to start: localhost:19 is down/bring localhost:19 up$' -and [int]($sc -split '\|')[3] -le 75)
$hk = (& { . $O; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"api","state":"down","restarts30":3},{"service":"web","state":"up (adopted)","port":4200}],"leases":[],"holds":[],"seed":{"ok":false,"missing":["roleA"],"drift":[]},"marks":{"count":1,"baseline":null,"expired":[],"binlogDays":30},"train":{"id":"t1","waitingFor":["H1"],"waitSince":"2020-01-01T00:00:00"}}]' } }
  @(Get-KitSuperviseFlagsLocalEnv) | ForEach-Object { "$($_.what)$($_.name)" } }) -join "`n"
Expect 'supervise hook (status -Json only): env row, RESTART LOOP (3 in 30 min), TRAIN WAITS, NO BASELINE MARK, SEED DRIFT, UNKNOWN port owner' ($hk -match 'TRAIN WAITS: shop train t1 waits \d+ min for the lease\(s\) of H1' -and $hk -match 'NO BASELINE MARK: shop' -and $hk -match 'SEED DRIFT: shop roleA' -and $hk -match 'shop · web' -and $hk -match 'RESTART LOOP: shop api restarted 3 times' -and $hk -match 'UNKNOWN: shop web port 4200')
$gh = & { . $O; function Left { 30 }; $now = Get-Date; $global:calls = 0; function Invoke-KitExe { if ($args[1] -contains 'status') { $global:calls++ }; [pscustomobject]@{ code = 0; out = '[{"env":"shop","services":[{"service":"web","state":"up","port":4200}],"leases":[],"holds":[],"seed":{"ok":true}}]' } }
  $g = @(Get-KitSuperviseGuardLocalEnv | ForEach-Object name) -join ','; $fl = @(Get-KitSuperviseFlagsLocalEnv | Where-Object { $_.name }).Count; "$g|$fl|$global:calls" }
Expect "supervise: env rows come from the early guard hook (one status call), the flags hook adds none ($gh)" ($gh -match '^shop · web\|0\|1$')
$ts = @(foreach ($n in 1, 2) { (& { . $O; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = $sj } }; @(Get-KitSuperviseFlagsLocalEnv) | Where-Object level -eq 'ACT' | ForEach-Object { "$($_.what) => $($_.action)" } }) -join "`n" })
Expect "supervise TRAIN STALLED (status -Json after its prune): a train on a reused pid ends, its request requeues; ACT names env, train, phase, why and the next command, once per train ($sq1 | $($ts[0]) | $($ts[1]))" ($sq1 -eq 'queued|True' -and $ts[0] -match "TRAIN STALLED: t train t9 in 'merging and building' ended \d\d:\d\d: worker gone \(or its pid reused\); 1 request\(s\) requeued" -and $ts[0] -match 'status -Env t' -and -not $ts[1])
$wq = & { . $O; $ld = Get-KitPath localenv -Create; $lp = "{`"pid`":$PID,`"pstart`":`"$(Get-KitPidStart $PID)`",`"beat`":`"$((Get-Date).ToString('o'))`"}"
  "{`"loop`":$lp,`"requests`":[{`"id`":`"r7`",`"kind`":`"deploy`",`"agent`":`"devy-x`",`"status`":`"queued`",`"at`":`"2026-01-01T00:00:00`"},{`"id`":`"r8`",`"kind`":`"deploy`",`"agent`":`"devy-x`",`"status`":`"done`"}],`"train`":{`"id`":`"t9`",`"phase`":`"merging and building`"}}" | Set-Content "$ld/wq.json"
  '{"requests":[{"id":"r9","kind":"deploy","agent":"devy-y","status":"queued"}]}' | Set-Content "$ld/wn.json"   # no controller: nothing serves it
  "{`"loop`":$lp,`"requests`":[{`"id`":`"s1`",`"agent`":`"devy-z`",`"status`":`"queued`"}]}" | Set-Content "$ld/wq.seed.json"
  $w = @(Get-KitStatusWaitLocalEnv | Where-Object agent -like 'devy-*'); Remove-Item "$ld/wq.json", "$ld/wn.json", "$ld/wq.seed.json"
  "$($w.Count)|$($w[0].agent)|$($w[0].why)|$([bool](Get-Command 'Get-KitStatusWait*' | Where-Object Name -eq 'Get-KitStatusWaitLocalEnv'))" }
Expect "status: an agent whose env request is queued while its controller beats is WAITING (<env> deploy <id>), not STUCK; no controller or a seed file: no wait ($wq)" ($wq -eq '1|devy-x|wq deploy r7 queued, train t9 merging and building|True')
$rf = @(foreach ($j in '[{"env":"shop","services":[]}]', '[{"env":"shop","services":[],"keepFreeGB":8}]', '[{"env":"shop","services":[],"keepFreeGB":10}]') { & { . $O; function Left { 30 }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = $j } }; @(Get-KitSuperviseFlagsLocalEnv | Where-Object { "$($_.what)" -match 'RAM FLOOR' }).Count } })
Expect "supervise RAM FLOOR: a status without keepFreeGB caches nothing (no bogus 0 -> 8); a real move flags ($($rf -join ','))" ($rf -join ',' -eq '0,0,1')
$ph = (& { . $O; $global:downs = @(); function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$T) { if ($A -contains 'down') { $global:downs += $A[-1]; return [pscustomobject]@{ code = 0 } }
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
    @('P', 'dotnet run -- migrate', $false), @('B', 'cd web && yarn start', $true), @('B', 'git push origin --delete localenv/shop', $false))) {
  $json = @{ tool_name = @{ P = 'PowerShell'; B = 'Bash' }[$c[0]]; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress
  $denied = (pwsh @np (Join-Path $gk 'skills/crafty/crafty.ps1') guard -Json $json | Out-String) -match '"permissionDecision":"deny"'
  if ($denied -ne $c[2]) { $bad += $c[1] }
}
Remove-Item Env:KIT_GUARD_SELFTEST_ACTIVE
Expect "guard: localenv/ pushes and hand-started dev servers denied, the rest allowed ($($bad -join ' | '))" (-not $bad.Count)
Remove-TestKit $k
Complete-Tests
