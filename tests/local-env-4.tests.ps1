#Requires -Version 7
<#
local-env-4.tests.ps1: envy.ps1 lanes: ports, per-lane overrides, lane marks, builds shared by lanes, lane seeds and pokey targets.
Usage: pwsh -NoProfile -File <kit>/tests/local-env-4.tests.ps1 (tests/kit-tests.ps1 -Area local-env-4 runs it with the other areas).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kitbag.py goody test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# the goody's script is not in the core test kit: copy it in
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; $kd }
# lanes: lane 1 = the env unchanged, lane k = <env><k>: managed ports + (k-1) x portStep, {lane} / {port:<svc>} / ":<port>" rewritten,
# envs.<env><k> overrides one lane (its db port follows); -Env <env> keeps an agent on its lane, else the least busy one; -Lane pins
$laneKit = New-LocalEnvKit lelane; $lkL = Join-Path $laneKit 'skills/envy/envy.ps1'
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ localEnv = @{ envs = @{
  shop = @{ lanes = @{ max = 3 }; env = @{ DB_PORT = '{port:db}'; SEARCH = 'http://127.0.0.1:{port:search}' }; db = @{ port = 3306 }
    services = @(@{ name = 'db'; external = $true; port = 3306 }, @{ name = 'search'; external = $true; port = 9200; start = 'search -data d{lane}' },
      @{ name = 'api'; port = 8080; debugPort = 5005; start = 'echo {port}'; health = 'http://127.0.0.1:8080/health' })
    smoke = @(@{ name = 'h'; url = 'http://127.0.0.1:8080/ok' }) }
  shop2 = @{ services = @(@{ name = 'db'; external = $false; port = 3406; start = 'db --port={port}'; init = @{ cmd = 'clone'; creates = 'x' } }) }
  solo = @{ services = @(@{ name = 'w'; port = 7000; start = 'echo' }) } } } } 8
$lr = & { . $lkL
  $c1 = Get-EnvCfg shop; $c2 = Get-EnvCfg shop2; $c3 = Get-EnvCfg shop3
  $p = { param($c, $n) @($c.services | Where-Object name -eq $n)[0] }
  $one = "$((& $p $c1 'api').port)/$((& $p $c1 'api').debugPort)/$((& $p $c1 'search').start)/$($c1.env.DB_PORT)/$($c1.db.port)/$($c1.smoke[0].url)"
  $two = "$((& $p $c2 'api').port)/$((& $p $c2 'api').debugPort)/$((& $p $c2 'search').port)/$((& $p $c2 'search').start)/$((& $p $c2 'api').health)/$($c2.env.DB_PORT)/$($c2.env.SEARCH)/$($c2.db.port)/$($c2.smoke[0].url)/$((& $p $c2 'db').init.cmd)"
  $three = "$((& $p $c3 'api').port)/$((& $p $c3 'db').port)/$($c3.db.port)"
  "$((EnvNames | Sort-Object) -join ',')|$(@(LaneNames shop2) -join ',')|$(@(LaneNames solo) -join ',')|$one|$two|$three|$(@(Test-PortClash).Count)" }
Expect "lanes: lane 1 unchanged, lanes 2..max derived (ports + portStep, {lane}, {port:<svc>}, URL ports), envs.<env><k> overrides its lane, no clash ($lr)" ($lr -eq 'shop,shop2,shop3,solo|shop,shop2,shop3|solo|8080/5005/search -data d/3306/3306/http://127.0.0.1:8080/ok|8180/5105/9300/search -data d2/http://127.0.0.1:8180/health/3406/http://127.0.0.1:9300/3406/http://127.0.0.1:8180/ok/clone|8280/3306/3306|0')
$ls = & { . $lkL
  Update-State shop { param($x) $x.leases.A1 = @{ services = @('api'); agent = 'A1' }; $x.leases.A2 = @{ services = @('api'); agent = 'A2' } }
  Update-State shop2 { param($x) $x.release.repos.r = @{ layers = @(@{ branch = 'b'; agent = 'B1' }) } }
  function Get-GateAvailGB { 50 }; function KeepFreeGB { 10 }; function Need-GB { 1 }
  $sticky = Select-Lane shop B1 0 'use'; $pick = Select-Lane shop N1 0 'deploy'; $read = Select-Lane shop N2 0 'logs'; $pin = Select-Lane shop N3 2 'logs'
  function Get-GateAvailGB { 5 }; $cold = Select-Lane shop N4 0 'deploy'
  $bad = try { Select-Lane shop N5 4 'use' } catch { 'refused' }
  Update-State shop3 { param($x) $x.requests = @(@{ id = 'q9'; kind = 'deploy'; status = 'queued'; agent = 'Q1' }, @{ id = 'q8'; kind = 'deploy'; status = 'done'; agent = 'Q2' }) }
  $queued = Select-Lane shop Q1 0 'deploy'; $waitId = Select-Lane shop Q2 0 'wait' 'q8'
  "$sticky|$pick|$read|$pin|$cold|$bad|$queued|$waitId" } 6>$null
Expect "lanes: the agent's lane (layer, lease, open deploy) sticks; wait -Id finds its request's lane; deploy / use go to the least busy lane (a cold one only with room); other verbs stay; -Lane pins; a lane past max refused ($ls)" ($ls -eq 'shop2|shop3|shop|shop2|shop|refused|shop3|shop3')
$lm = & { . $lkL; function MarksOn { $true }; function Get-DbPos { 'pos1' }; $global:lmUp = $false; function Test-PortListening { $global:lmUp }
  $q = New-Mark shop2 'release-3' 'release'; $pend = "$(@((Read-State shop2).pendingMarks).name)|$(@((Read-State shop2).marks | Where-Object { $_ }).Count)"
  function SvcDir { $env:TEMP }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { $PID }; function Healthy { $global:lmUp = $true; $true }; function Stop-Svc { }; function Owned { $false }; function Get-PortPids { @() }
  $db = @(EnvServices shop2 | Where-Object name -eq 'db')[0] | Select-Object * -ExcludeProperty init
  $out = @(Start-SvcOnce shop2 $db 1 '') -join ' '; $st = Read-State shop2
  "$q|$pend|$(@($st.marks).name)|$(@($st.pendingMarks).Count)|$($out -match 'waited for db')|$(DbSvcDown shop)" }
Expect "lanes: a mark while the lane's own DB service is down waits and is taken when it starts; an external DB is never 'down' ($lm)" ($lm -eq 'release-3|release-3|0|release-3|0|True|False')
$lb = & { . $lkL; function MarksOn { $true }; function Get-DbPos { 'pos2' }; $global:lbUp = $false; function Test-PortListening { $global:lbUp }
  function SvcDir { $env:TEMP }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { $PID }; function Healthy { $global:lbUp = $true; $true }; function Stop-Svc { }; function Owned { $false }; function Get-PortPids { @() }
  $global:lbGreen = $false; $global:lbRuns = 0; function Invoke-Seed { $global:lbRuns++; if (-not $global:lbGreen) { $script:SeedBad = $true }; 'seed lines' }
  $sf = SeedFile shop2; Set-JsonFile $sf @{ items = @(@{ name = 'i1'; check = @{ sql = 'SELECT 1' } }, @{ name = 'i2'; check = @{ cmd = 'pokey' } }) }
  Update-State shop2 { param($x) $x.marks = @(); $x.pendingMarks = @() }
  $db = @(EnvServices shop2 | Where-Object name -eq 'db')[0] | Select-Object * -ExcludeProperty init
  $cmdSeed = @(Start-SvcOnce shop2 $db 1 '') -join ' '; $runs = $global:lbRuns
  Set-JsonFile $sf @{ items = @(@{ name = 'i1'; check = @{ sql = 'SELECT 1' } }) }
  $global:lbUp = $false; $red = @(Start-SvcOnce shop2 $db 1 '') -join ' '; $n1 = @((Read-State shop2).marks | Where-Object { $_ }).Count
  $global:lbUp = $false; $global:lbGreen = $true; $green = @(Start-SvcOnce shop2 $db 1 '') -join ' '; $b = @((Read-State shop2).marks | Where-Object { $_ -and $_.kind -eq 'baseline' })
  $global:lbUp = $false; $third = @(Start-SvcOnce shop2 $db 1 '') -join ' '; Remove-Item -LiteralPath $sf -Force
  "$($cmdSeed -match 'non-SQL checks')|$runs|$($red -match 'seed check is not green')|$n1|$($green -match 'seed check green')|$(@($b).Count)|$($b[0].pos)|$($third -match 'baseline')" }
Expect "lanes: a lane DB start with no baseline mark takes one on a green SQL-only seed check (a cmd check may need the app: none), once ($lb)" ($lb -eq 'True|0|True|0|True|1|pos2|False')
$le = & { . $lkL; $global:leUp = $false; function Test-PortListening { $global:leUp }; $global:leStarts = @()
  function Start-Svc([string]$e, $s, [int]$release, [string]$artifact, [switch]$Latest) { $global:leStarts += "$e/$($s.name)/$release/$Latest"; $global:leUp = $true }
  Update-State shop2 { param($x) $x.services.db = @{ status = 'down' } }
  $o1 = @(Ensure-DbUp shop2 4) -join ' '; $s1 = $global:leStarts -join ','; $o2 = @(Ensure-DbUp shop2 4).Count
  $global:leUp = $false; Update-State shop2 { param($x) $x.services.db = @{ status = 'starting'; pid = $PID } }; function Owned { $true }; function Start-Sleep { $global:leUp = $true }
  $o3 = @(Ensure-DbUp shop2 4).Count; $s3 = $global:leStarts.Count; $global:leUp = $false; $o4 = @(Ensure-DbUp shop 4).Count
  Update-State shop2 { param($x) $x.services.db = @{ status = 'down' } }; function Owned { $false }
  $global:lePolls = 0; function Get-SysProcs { if (++$global:lePolls -eq 1) { [pscustomobject]@{ CommandLine = 'pwsh -File envy.ps1 _daemon -Env shop2 -Start db -Release 4' } } }; function Start-Sleep { }
  $o5 = @(Ensure-DbUp shop2 4) -join ' '; $s5 = $global:leStarts.Count
  $li = @{ train = @{ phase = 'merging and building'; blockServices = @('api') } }
  $order = (Get-Content -LiteralPath $lkL -Raw) -match "Phase 'db up for the release marks and checks' \`$block @\(\`$affected\); try \{ Ensure-DbUp"
  "$($o1 -match 'rests: started')|$s1|$o2|$o3|$s3|$o4|$global:lePolls|$s5|$((Get-IdleBlock $li shop2) -join ',')|$((Get-IdleBlock $li shop) -join ',')|$(@(Get-IdleBlock @{ train = @{ phase = 'waiting for leases (code)' } } shop2).Count)|$order" }
Expect "lanes: a train's DB steps start a resting lane DB (-Latest) or wait for a start (claimed or a worker before its claim); lane 1's external DB untouched; idle never stops the lane DB once the train leaves its lease wait ($le)" ($le -eq 'True|shop2/db/4/True|0|0|1|0|2|2|api,db|api|0|True')
$lrt = & { . $lkL; $now = (Get-Date).ToString('o')
  $f = @{ status = 'failed'; why = 'boom'; artifact = 'old.jar'; restarts = @($now, $now, $now) }; $u = @{ status = 'up'; restarts = @($now) }
  Clear-StartBackoff $f 'release 6 staged'; Clear-StartBackoff $u 'x'; Clear-StartBackoff $null 'x'
  $src = Get-Content -LiteralPath $lkL -Raw
  "$($f.status)|$(@($f.restarts).Count)|$($f.why)|$($u.status)|$(@($u.restarts).Count)|$($src -match 'Clear-StartBackoff \$x\.services\[\$sn\] "release \$newN staged"')|$($src -match "Clear-StartBackoff \`$x\.services\[\`$s\.name\] 'restart asked'")" }
Expect "lanes: a new release staged for a service in start backoff (Record-Train) and an asked restart clear the backoff; a running one is untouched ($lrt)" ($lrt -eq 'down|0|release 6 staged: backoff cleared (was: boom)|up|1|True|True')
$lc = & { . $lkL; $global:lcCalls = @(); function Test-DbTemp { $true }; function MarksOn { $true }
  function Invoke-DbTempWatch { $global:lcCalls += 'temp' }; function Invoke-DbPool { $global:lcCalls += 'pool'; 'db pool: resized' }; function Update-Marks { $global:lcCalls += 'marks'; throw 'mysql: ERROR 2003' }
  $global:lcUp = $false; function Test-PortListening { $global:lcUp }
  $at = @{ temp = [datetime]::MinValue; pool = [datetime]::MinValue; marks = [datetime]::MinValue }
  $down = @(Invoke-DbChores shop2 @{} $at).Count; $downCalls = $global:lcCalls.Count
  $global:lcUp = $true; $up = @(Invoke-DbChores shop2 @{} $at) -join ';'; $again = @(Invoke-DbChores shop2 @{} $at).Count
  "$down|$downCalls|$($global:lcCalls -join ',')|$up|$again" }
Expect "lanes: the loop's db chores (watchdog, pool, mark expiry) rest while the lane's DB is down; a failed one is said once a minute, the tick goes on ($lc)" ($lc -eq '0|0|temp,pool,marks|db pool: resized;marks: mysql: ERROR 2003|0')
$lvd = & { $src = Get-Content -LiteralPath $lkL -Raw
  $vd1 = @'
($st2.services[$_.name].status -eq 'up' -or ($_.artifact -and $_.name -in $wanted))
'@
  $vd2 = @'
$switchNames = @($switch | Where-Object { $_.name -notin $verifyDown }
'@
  $vd3 = @'
if ($s.name -notin $verifyDown -and (Read-State $e)
'@
  "$($src.Contains($vd1.Trim()))|$($src.Contains($vd2.Trim()))|$($src.Contains($vd3.Trim()))" }
Expect "train: a changed service that is down but leased starts on the new release in the switch-over (verified, rolled back on failure), its leases not waited for ($lvd)" ($lvd -eq 'True|True|True')
$lsb = & { . $lkL; $web = [pscustomobject]@{ name = 'web'; repo = 'w'; build = 'b'; static = 'dist'; artifact = 'dist'; shareBuild = $true }
  function EnvServices { @($web) }; function RepoOf { 'w' }; function SvcDir { $env:TEMP }; function BuildKey { 'k1' }; $global:lsbBuilt = 0; function Expand-Placeholders { $global:lsbBuilt++; 'b' }
  $run = Get-KitPath localenv -Create; $src = Join-Path $run 'run/shop/web/r7'; New-Item -ItemType Directory -Force $src | Out-Null; Set-Content (Join-Path $src 'index.html') 'one'; Set-Content (Join-Path $src 'app.aot') 'x'
  Update-State shop { param($x) $x.builds = @{ web = @(@{ key = 'k1'; dir = $src; path = $src }) } }
  $err = Build-Repo shop2 'w' 6>$null; $to = (Stage-Artifacts shop2 'w' 'r1').web; $rec = @((Read-State shop2).builds.web)[-1]
  $null = Build-Repo shop2 'w' 6>$null; Remove-Item -LiteralPath $src -Recurse -Force   # pruned between build and stage
  $src3 = Join-Path $run 'run/shop3/web/r2'; New-Item -ItemType Directory -Force $src3 | Out-Null; Set-Content (Join-Path $src3 'index.html') 'three'
  Update-State shop3 { param($x) $x.builds = @{ web = @(@{ key = 'k1'; dir = $src3; path = $src3 }) } }
  $to2 = (Stage-Artifacts shop2 'w' 'r2').web
  $null = Build-Repo shop2 'w' 6>$null; Remove-Item -LiteralPath $src3 -Recurse -Force
  $gone = try { $null = Stage-Artifacts shop2 'w' 'r3'; 'staged' } catch { "$_" -match 'gone since the build step' }
  foreach ($l in 'shop', 'shop2', 'shop3') { Update-State $l { param($x) $x.Remove('builds') } }
  "$($null -eq $err)|$global:lsbBuilt|$(Test-Path (Join-Path $to 'index.html'))|$(Test-Path (Join-Path $to 'app.aot'))|$($rec.key)|$($rec.path -eq $to)|$(Get-Content (Join-Path $to2 'index.html'))|$gone|$($null -eq (Find-SharedBuild shop2 $web 'k2'))" }
Expect "lanes: a lane stages another lane's recorded copy of the same build, no build, no AOT cache, records its own; pruned meanwhile: the next lane's copy, none left: refused ($lsb)" ($lsb -eq 'True|0|True|False|k1|True|three|True|True')
$lk2 = & { . $lkL; $g = Join-Path $env:TEMP "lebk-$PID"; Remove-Item $g -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($n in 'a', 'b', 'c') { $d = Join-Path $g $n; New-Item -ItemType Directory -Force $d | Out-Null; git -C $d init -q; Set-Content (Join-Path $d 'f.txt') $(if ($n -eq 'c') { 'other' } else { 'same' }); git -C $d add -A; git -C $d -c user.name=t -c user.email=t@t commit -q -m 'code' }
  foreach ($p in 'web', 'docs') { Set-Content (Join-Path $g "b/$p.json") "cache b $p"; git -C (Join-Path $g 'b') add -A; git -C (Join-Path $g 'b') -c user.name=t -c user.email=t@t commit -q -m "localenv prepare $p (local only)" }
  function RepoOf { 'w' }; function EnvRepos([string]$e) { @{ w = [pscustomobject]@{ wt = (Join-Path $g $e) } } }
  $s = [pscustomobject]@{ name = 'web'; repo = 'w'; build = 'b'; static = 'dist'; shareBuild = $true }; $off = [pscustomobject]@{ name = 'web'; repo = 'w'; build = 'b'; static = 'dist' }
  $other = [pscustomobject]@{ name = 'web'; repo = 'w'; build = 'b --prod'; static = 'dist'; shareBuild = $true }
  $ka = BuildKey a $s; $kb = BuildKey b $s; $kc = BuildKey c $s; $kd = BuildKey a $other
  Remove-Item $g -Recurse -Force -ErrorAction SilentlyContinue
  "$($ka.Length)|$($ka -eq $kb)|$($ka -eq $kc)|$($ka -eq $kd)|$($null -eq (BuildKey a $off))" }
Expect "lanes: the build key = the code without its prepare commits + the build config; only shareBuild true has one ($lk2)" ($lk2 -eq '40|True|False|False|True')
$lsd = & { . $lkL; $none = [pscustomobject]@{ port = '' }; "$(Split-Path (SeedFile shop2) -Leaf)|$(Expand-Placeholders 'pokey -Target local-shop{lane}' shop2 $none '' '')|$(Expand-Placeholders 'local-shop{lane}' shop $none '' '')" }
Expect "lanes: a lane seeds from its env's seed file; {lane} expands at run time too (seed commands) ($lsd)" ($lsd -eq 'shop.seed.json|pokey -Target local-shop2|local-shop')
$lt = & { . (Join-Path $laneKit 'skills/pokey/pokey.ps1'); $tc = [pscustomobject]@{ targets = [pscustomobject]@{ 'local-shop' = [pscustomobject]@{ api = 'http://127.0.0.1:8080/x'; web = 'http://127.0.0.1:4200' } } }
  $t2 = Get-LaneTarget $tc 'local-shop2'; "$($t2.api)|$($t2.web)|$($null -eq (Get-LaneTarget $tc 'other2'))|$((Get-LaneTarget $tc 'local-shop3').api)" }
Expect "lanes: pokey target <target><k> = the base target with lane k's ports ($lt)" ($lt -eq 'http://127.0.0.1:8180/x|http://127.0.0.1:4200|True|http://127.0.0.1:8280/x')
Remove-TestKit $laneKit
Complete-Tests
