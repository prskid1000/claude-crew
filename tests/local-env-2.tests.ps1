#Requires -Version 7
<#
local-env-2.tests.ps1: envy.ps1 dependency waits, trains, deferred requests, idle stops, staging, builds, cleanup, prepare, merged layers, init, switch-over.
Usage: pwsh -NoProfile -File <kit>/tests/local-env-2.tests.ps1 (tests/kit-tests.ps1 -Area local-env-2 runs it with the other areas).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kitbag.py goody test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# the goody's script is not in the core test kit: copy it in
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; $kd }
# a test kit of its own: each scenario below writes the config it needs
$k3 = New-LocalEnvKit le3; $k = $k3; $L3 = Join-Path $k3 'skills/envy/envy.ps1'; $cf3 = Join-Path $k3 'skills/crafty/kit.local.json'
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
# 2026-11-13: search's start waited 30 min for CPU; api gave up after startMinutes. A live dependency start is waited for past it
$wl = & { . $L3; Update-State dp { param($x) $x.services = @{ search = @{ status = 'waiting'; why = 'no room to start'; waitFor = 'CPU'; waitPid = $PID; waitStart = (Get-KitPidStart $PID) } } }
  $script:hc = 0; function Healthy { param($e, $s) $s.name -ne 'search' -or ++$script:hc -gt 4 }; function Wait-KitPoll { }; function Event { }
  $script:t0 = 0; function Get-Date { if ($args.Count) { Microsoft.PowerShell.Utility\Get-Date @args } else { (Microsoft.PowerShell.Utility\Get-Date).AddMinutes(4 * $script:t0++) } }
  $o = try { @(Wait-Deps dp (Svc dp 'api')) -join ';' } catch { "THROW $_" }
  "$($o -match 'still waits for search: its start is in progress')|$($o -notmatch 'THROW')" }
$wl += '|' + ((Px $L3 status -Env dp 2>&1 | Out-String) -match '(?m)^\s+search\s+waiting \(CPU\)[^\r\n]*' -and $Matches[0] -notmatch 'no room')
Expect "deps: a dependency whose own start waits for room is waited for past startMinutes; status shows 'waiting (CPU)' without the stale why ($wl)" ($wl -eq 'True|True|True')
# 2026-11-13: a worker started r356 while the train's r357 start waited for room; r357 then saw r356 healthy on its port
$sm = & { . $L3; Update-State dp { param($x) $x.services = @{ api = @{ status = 'down' } } }; $script:ran = $false; $script:stops = @()
  function SvcDir { $k3 }; function StartCmd { 'echo a' }; function Test-Room { $true }; function Test-PortListening { $false }
  function Wait-Room { $script:ran = $true }; function Get-PortPids { if ($script:ran) { @(4242) } else { @() } }
  function Stop-Svc { param($e, $s, $why) $script:stops += $why; $script:ran = $false; Update-State dp { param($x) $x.services.api = @{ status = 'down' } } }
  function Start-Pwsh { $v = (Read-State dp).services.api; throw "launched $($v.status)/$($v.waitFor)" }
  $l = try { $null = Start-SvcOnce dp (Svc dp 'api') 357 ''; 'no launch' } catch { "$_" }; "$($script:stops -join ';')|$l" }
Expect "start: a service another start ran while this one waited for room is stopped under the lock before this launch, its claim kept ($sm)" ($sm -eq 'stopped before a new start (another start ran it while this one waited for room)|launched waiting/lock')
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
$sv = & { . $L3; $fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $port = $fp.LocalEndpoint.Port; $fp.Stop()   # a free port: a fixed one collides with parallel runs
  $srv = Start-Process node -ArgumentList "`"$(StaticServer)`" `"$(Join-Path $wtd 'web/dist/app')`" $port" -PassThru -WindowStyle Hidden
  try { for ($i = 0; $i -lt 120 -and -not (Test-PortListening $port); $i++) { Start-Sleep -Milliseconds 250 }
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
# init (a lane's own data): runs before a start while init.creates is missing, then not again; a failed init stops the start
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'db'; start = 'x'; init = @{ cmd = 'echo made> "{dir}/made.txt"'; creates = '{dir}/made.txt' } }, @{ name = 'bad'; start = 'x'; init = @{ cmd = 'exit 3'; creates = '{dir}/never.txt' } }) } } } } $cf3 8
$initRes = & { . $L3; Remove-Item (Join-Path $sq 'made.txt') -ErrorAction SilentlyContinue
  function SvcDir { $sq }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { $PID }; function Healthy { $true }; function Stop-Svc { }; function Owned { $false }
  $first = @(Start-SvcOnce t (Svc t db) 1 '') -join ' '; $made = Test-Path (Join-Path $sq 'made.txt'); $again = @(Start-SvcOnce t (Svc t db) 1 '') -join ' '
  $bad = try { Start-SvcOnce t (Svc t bad) 1 '' | Out-Null; 'started' } catch { "$_" }
  Remove-Item (Join-Path $sq 'made.txt') -ErrorAction SilentlyContinue
  "$($first -match 'db: init')|$made|$($again -match 'init')|$($bad -match 'init failed \(exit 3\)')" }
Expect "start: init runs once while init.creates is missing; a failed init stops the start ($initRes)" ($initRes -eq 'True|True|False|True')
& $J @{ localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'api'; start = 'x' }) } } } } $cf3 8   # the config the next checks share
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
Remove-TestKit $k3
Complete-Tests
