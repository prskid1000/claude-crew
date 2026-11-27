#Requires -Version 7
<#
local-env-6.tests.ps1: envy.ps1 lane trains and seeds (local-env-4 is at its cap): the warm-lane target pin, the seed hint on a
service not up yet, the static server's routes, javaIncremental builds (local-env-5 is at its cap).
Usage: pwsh -NoProfile -File <kit>/tests/local-env-6.tests.ps1 (tests/kit-tests.ps1 -Area local-env-6).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/liquibase.ps1', 'skills/crafty/adapters/liquibase.py')
function New-LocalEnvKit([string]$name) { $kd = New-TestKit $name; $d = New-Item -ItemType Directory -Force (Join-Path $kd 'skills/envy'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') $d; Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) (New-Item -ItemType Directory -Force (Join-Path $d 'adapters')); $kd }
$laneKit = New-LocalEnvKit lesix; $lkL = Join-Path $laneKit 'skills/envy/envy.ps1'; $k = $laneKit
# warm lane (owner 2026-11-25): same layers, no refresh -> the repo stays on its live target commit (a target move alone: no rebuild)
$lpb = & { . $lkL; $st = @{ release = @{ n = 3; repos = @{ w = @{ targetSha = 'abc123' } } } }; $kk = @('f/x@1')
  "$(Get-TrainPinBase $st 'w' $kk $kk @('deploy'))|$(Get-TrainPinBase $st 'w' @('f/x@2') $kk @('deploy'))|$(Get-TrainPinBase $st 'w' $kk $kk @('deploy', 'refresh'))|$(Get-TrainPinBase @{ release = @{ n = 0; repos = @{} } } 'w' $kk $kk @('deploy'))|$((Get-Content $lkL -Raw).Contains('Sync-Repo $e $r @($want[$rn]) -Base $pinBase'))" }
Expect "train: unchanged layers keep the repo on its live target (pinned); a changed layer, a refresh or no release take origin/<target> ($lpb)" ($lpb -eq 'abc123||||True')
# coordinator 2026-11-25: a seed upload got HTTP 000 while a deploy restarted the api: the failed create names the service, not a port
$sdh = & { . $lkL; function Read-State { [pscustomobject]@{ services = @{ api = @{ status = 'starting' }; db = @{ status = 'up' }; mcp = @{ status = 'down' } } } }
  function EnvServices { @([pscustomobject]@{ name = 'api' }, [pscustomobject]@{ name = 'db' }, [pscustomobject]@{ name = 'mcp' }) }; function Healthy($he, $hs) { $hs.name -eq 'db' }
  $h1 = Get-SeedDownHint shop2; function Healthy($he, $hs) { $true }; "$h1|$(Get-SeedDownHint shop2)" }
Expect "seed: a failed create while a started service is not healthy names it (a deliberately stopped one never); all healthy: no hint ($sdh)" ($sdh -match '^; api not up yet \(starting\): re-run seed when envy\.ps1 status shows it up\|$')
# lane train (coordinator 2026-11-25): two layers each appending a changelog include conflict in master.xml -> both kept, the
# merge committed; a routes file under repos[].appendOnly too; a conflict in code: refused, the merge left for Sync-Repo to abort
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ migrations = @{ tool = 'liquibase' } }   # the adapter loads only when config names it
$kbr = & { . $lkL; function Get-MigTool { 'liquibase' }; function Get-RepoConf($rcN, $rcK, $rcD) { if ($rcK -eq 'appendOnly') { @('**/routes.txt') } else { $rcD } }
  $nhd = New-Item -ItemType Directory -Force (Join-Path (Kd) 'kb-nohooks'); $rkb = [pscustomobject]@{ name = 'kb' }
  $mkConflict = { param([string]$Name, [string]$Rel, [string]$Base, [string]$Ours, [string]$Theirs)
    $g = Join-Path (Kd) $Name; New-Item -ItemType Directory -Force (Split-Path (Join-Path $g $Rel)) | Out-Null; Set-Content (Join-Path $g $Rel) $Base; Save-GitRepo $g base
    git -C $g branch -q theirs; Set-Content (Join-Path $g $Rel) $Ours; git -C $g commit -q -am ours; git -C $g switch -q theirs; Set-Content (Join-Path $g $Rel) $Theirs; git -C $g commit -q -am theirs
    git -C $g switch -q -; git -C $g merge -q --no-ff --no-edit theirs 2>&1 | Out-Null; $g }
  $inc = { param($xs) $incLines = @($xs | ForEach-Object { '  <include file="{0}.xml"/>' -f $_ }); "<databaseChangeLog>`n$($incLines -join "`n")`n</databaseChangeLog>" }
  $g1 = & $mkConflict kb-master 'src/db/changelog/master.xml' (& $inc 'a') (& $inc 'a', 'b') (& $inc 'a', 'c')
  $r1 = Resolve-LaneKeepBoth shop $rkb $g1 @('src/db/changelog/master.xml') "$nhd"; $t1 = Get-Content (Join-Path $g1 'src/db/changelog/master.xml') -Raw
  $g2 = & $mkConflict kb-routes 'web/routes.txt' "r0" "r0`nr1" "r0`nr2"; $r2 = Resolve-LaneKeepBoth shop $rkb $g2 @('web/routes.txt') "$nhd"
  $g3 = & $mkConflict kb-code 'src/App.java' 'class A { int x = 0; }' 'class A { int x = 1; }' 'class A { int x = 2; }'; $r3 = Resolve-LaneKeepBoth shop $rkb $g3 @('src/App.java') "$nhd"
  $g4 = & $mkConflict kb-mixed 'src/db/changelog/master.xml' (& $inc 'a') "$(& $inc 'a', 'b')<!-- x -->" "$(& $inc 'a')<changeSet id=`"1`"/>"; $r4 = Resolve-LaneKeepBoth shop $rkb $g4 @('src/db/changelog/master.xml') "$nhd"
  $g5 = Join-Path (Kd) 'kb-del'; New-Item -ItemType Directory -Force "$g5/web" | Out-Null; Set-Content "$g5/web/routes.txt" 'r0'; Save-GitRepo $g5 base; git -C $g5 branch -q theirs
  Remove-Item "$g5/web/routes.txt"; git -C $g5 commit -q -am del; git -C $g5 switch -q theirs; Set-Content "$g5/web/routes.txt" "r0`nr2"; git -C $g5 commit -q -am edit; git -C $g5 switch -q -; git -C $g5 merge -q --no-ff --no-edit theirs 2>&1 | Out-Null
  $r5 = Resolve-LaneKeepBoth shop $rkb $g5 @('web/routes.txt') "$nhd"; $r4 = "$r4|del:$r5|$(Test-Path (Join-Path $g5 '.git/MERGE_HEAD'))"
  "$r1|$($t1 -match 'b\.xml' -and $t1 -match 'c\.xml' -and $t1 -notmatch '<<<<<<<')|$(Test-Path (Join-Path $g1 '.git/MERGE_HEAD'))|$r2|$r3|$(Test-Path (Join-Path $g3 '.git/MERGE_HEAD'))|$r4" }
Expect "train merge: an include-only changelog master conflict and a repos[].appendOnly file keep both sides and commit; code or a non-include line: refused, merge untouched ($kbr)" ($kbr -eq 'True|True|False|True|False|True|False|del:False|True')
# envfix-phone 2026-11-25: ui login / user create on a lane name: the base target on the lane's ports + the lane entry's own logins
$prt = & { . (Join-Path $laneKit 'skills/pokey/pokey.ps1'); function Get-LaneTarget($c, $n) { if ($n -eq 'local-shop-osprey') { [pscustomobject]@{ api = 'http://127.0.0.1:8280'; users = [pscustomobject]@{ base1 = @{} } } } }
  $tg = [ordered]@{ 'local-shop' = [ordered]@{ api = 'http://127.0.0.1:8080' }; 'local-shop-osprey' = [ordered]@{ users = [ordered]@{ driver1 = @{}; base1 = @{ lane = 1 } }; created = [ordered]@{ driver1 = @{ at = '2026-01-02T03:04:05Z' } } }; 'stage' = [ordered]@{ api = 'https://s'; users = [ordered]@{ a = @{} } } }
  $l1 = Resolve-PokeyTarget $tg 'local-shop-osprey'; $tp = Resolve-PokeyTarget ([pscustomobject]$tg) 'local-shop-osprey'; $tg.Remove('local-shop-osprey'); $l2 = Resolve-PokeyTarget $tg 'local-shop-osprey'; $s = Resolve-PokeyTarget $tg 'stage'
  "$($l1.api)|$(@($l1.users.Keys) -join ',')|$($l1.users.base1.lane)|$($l1.created.driver1.at)|$(@((Get-KitProps $tp.users).Name) -join ',')|$(@($l2.users.Keys) -join ',')|$($s.api)|$($null -eq (Resolve-PokeyTarget $tg 'nope'))" }
Expect "pokey targets: a lane name = the base on the lane's ports with the base's logins + the lane entry's own (own wins, dates kept; members for api); a full entry as is ($prt)" ($prt -eq 'http://127.0.0.1:8280|base1,driver1|1|2026-01-02T03:04:05Z|base1,driver1|base1|https://s|True')
# envy friction 2026-11-26 (a train swapped the api under a running cypress): a busy holder is waited for past leaseMinutes, up to maxLeaseMinutes
$tl0 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl0.Start(); $lbPort = $tl0.LocalEndpoint.Port; $tl0.Stop()
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ localEnv = @{ leaseMinutes = 0; envs = @{ lw = @{ services = @(@{ name = 'api'; start = 'echo api'; port = $lbPort }) } } } }
$lb = & { . $lkL; $script:busyN = 0; function Test-KitAgentBusy($a) { $script:busyN++; $a -eq 'B1' -and $script:busyN -le 1 }; function Send-LeaseNotice { }
  Update-State lw { param($x) $x.leases = @{ B1 = @{ services = @('api'); agent = 'B1'; holderPid = $PID; lastUse = (Get-Date).AddMinutes(-5).ToString('o') } }; $x.requests = @() }   # idle 5 min: out of the in-use window, inside the idle grace
  $b1 = @(Wait-Leases lw @('api') @() @()) -join ' '; $script:Preempted = @(); $script:LeaseWait0 = $null; $script:busyN = 0; $script:MaxLeaseMin = 0
  $b2 = @(Wait-Leases lw @('api') @() @()) -join ' '
  # coordinator 2026-11-26 (a deploy swapped a lane under a matrix UI run): no busy file, but the lease is in use (lastUse) = waited for too
  $script:Preempted = @(); $script:LeaseWait0 = $null; $script:MaxLeaseMin = 120; function Test-KitAgentBusy($a) { $false }; Update-State lw { param($x) $x.leases.B1.lastUse = (Now) }; $lu0 = Test-LeaseBusy lw B1; Update-State lw { param($x) $x.leases.B1.lastTraffic = (Now) }   # a verb's lastUse alone is no use; client traffic is
  $gkp = ${function:Get-KitParam}; $script:lbN = 0; function Get-KitParam { if ($args[0] -eq 'localEnv.leaseBusyMinutes') { if ($script:lbN++ -lt 2) { 3 } else { 0 } } else { & $gkp @args } }   # in use for the first wait round only
  $lu = "$(Test-LeaseBusy lw B1)/$(Test-LeaseBusy lw NOPE)"
  $b3 = @(Wait-Leases lw @('api') @() @()) -join ' '
  "$($b1 -match 'B1 on api \(at most \d+ min: a check runs\)')|$($b1 -match 'told B1')|$($b2 -notmatch 'a check runs' -and $b2 -match 'told B1')|$lu0|$lu|$($b3 -match 'a check runs' -and $b3 -match 'told B1')|$(Test-LeaseBusy lw B1)" }
Expect "leases: a holder whose check runs, or whose lease was used in the last leaseBusyMinutes (a matrix or phone run: no busy file), is not swapped under at leaseMinutes, waited for up to maxLeaseMinutes, then told ($lb)" ($lb -eq 'True|True|True|False|True/False|True|False')
# owner 2026-11-26 (baseline in place; lane DB donor = a clean baseline mark): the liquibase unmerged verb = applied changeSets the
# changelog files lack (XML, formatted SQL, YAML), per schema
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ migrations = @{ tool = 'liquibase' }; localEnv = @{ envs = @{
  don = @{ db = @{ port = 3391 }; services = @(@{ name = 'db'; port = 3391; start = 'db' }) }
  fresh = @{ db = @{ port = 3392 }; services = @(@{ name = 'db'; port = 3392; start = 'db'; init = @{ cmd = 'clone'; creates = 'zz-none'; donor = 'don' } }) } } } } 8
$um = & { . $lkL; $umRoot = New-Item -ItemType Directory -Force (Join-Path (Kd) 'um/resources/db'); function SqlId($sn) { "[$sn]" }
  Set-Content (Join-Path $umRoot 'a.xml') '<databaseChangeLog><changeSet id="1" author="dev"><sql>x</sql></changeSet><changeSet author="dev" id="2"/></databaseChangeLog>'
  Set-Content (Join-Path $umRoot 'b.sql') "--liquibase formatted sql`n--changeset ann:3`nSELECT 1;"
  Set-Content (Join-Path $umRoot 'c.yaml') "databaseChangeLog:`n  - changeSet:`n      id: 4`n      author: bob`n      changes: []"
  Set-Content (Join-Path $umRoot 'd.xml') '<databaseChangeLog logicalFilePath="db/legacy name.xml"><changeSet id="9" author="dev"/></databaseChangeLog>'
  function Resolve-MigSets { @([pscustomobject]@{ name = 'm'; tool = 'liquibase'; searchPath = (Split-Path $umRoot); schemas = @('s1', 's2') }) }
  function Invoke-DbSql($qe, $qs) { @('dev', '1', 'db/a.xml'), @('ann', '3', 'classpath:db/b.sql'), @('bob', '4', 'c.yaml'), @('dev', '2', 'db\A.xml'), @('dev', '9', 'db/legacy name.xml'); if ($qs -match '\[s2\]') { @('eve', '77', 'x.xml'), @('dev', '1', 'db/other.xml') } }
  $umR = @(& $KitAdapters['migration']['liquibase']['unmerged'] @{ e = 'don' }); "$($umR.Count)|$($umR[0].schema)|$($umR[0].count)|$($umR[0].sample -join ',')" }
Expect "liquibase unmerged: a schema whose DATABASECHANGELOG holds changeSets the changelog files lack is named with its count (an author:id of another file counts); one that matches: none ($um)" ($um -eq '1|s2|2|eve:77@x.xml,dev:1@other.xml')
# the block reasons in order (cheapest first), said once; clean = a new baseline mark; an init with a donor that is no clean baseline is refused
$bp = & { . $lkL; function MarksOn { $true }; $global:bpPos = 1; function Get-DbPos { "binlog.000001:$((++$global:bpPos))" }; function Test-PortListening([int]$Port) { $Port -eq 3391 }
  $global:bpSeedBad = $false; function Invoke-Seed { if ($global:bpSeedBad) { $script:SeedBad = $true } }
  $global:bpRows = '0'; function Invoke-Hook($he, $hn, $hv) { $script:HookOut = @($global:bpRows); $null }
  $global:bpUm = @(); $global:bpRace = $false; function Get-MigTool { 'liquibase' }
  function Invoke-MigVerb($mt, $mv, $ma) { if ($global:bpRace) { Update-State don { param($x) $x.leases.R1 = @{ services = @('db'); agent = 'R1'; holderPid = $PID } } }; $global:bpUm }
  $sf = SeedFile don; $it = @(@{ name = 'i1'; check = @{ sql = 'SELECT 1' } }); Set-JsonFile $sf @{ items = $it }
  Update-State don { param($x) $x.release = @{ n = 4; repos = @{ r = @{ layers = @(@{ branch = 'f/a'; agent = 'A1' }) } } }; $x.train = @{ id = 't'; at = (Now) }; $x.leases = @{ A1 = @{ services = @('db'); agent = 'A1'; holderPid = $PID } }
    $x.marks = @(@{ name = 'baseline-0001'; kind = 'baseline'; at = (Get-Date).AddHours(-2).ToString('o'); release = 3; pos = 'binlog.000001:1' }) }
  $w = @(Get-BaselineBlock don); Update-State don { param($x) $x.train = $null }; $w += Get-BaselineBlock don
  Update-State don { param($x) $x.release.repos.r.layers = @() }; $w += Get-BaselineBlock don; Update-State don { param($x) $x.leases = @{}; $x.holds = @{ main = @{ services = @('db'); owner = $true; until = (Get-Date).AddHours(1).ToString('o') } } }; $w += Get-BaselineBlock don
  $dn = "$((Get-BaselineBlock don -Donor) -notmatch 'hold')"; Update-State don { param($x) $x.holds = @{} }; $w += Get-BaselineBlock don
  Set-JsonFile $sf @{ items = $it; clean = @(@{ name = 'qa rows'; sql = 'SELECT COUNT(*) FROM t' }) }
  $global:bpSeedBad = $true; $w += Get-BaselineBlock don; $global:bpSeedBad = $false; $global:bpRows = '7'; $w += Get-BaselineBlock don; $global:bpRows = '0'
  $global:bpUm = @([pscustomobject]@{ schema = 's1'; count = 2; sample = @('dev:9', 'dev:10') }); $w += Get-BaselineBlock don
  $h1 = @(Update-Baseline don (Read-State don)) -join ' '; $h2 = @(Update-Baseline don (Read-State don)) -join ' '
  $um0 = $global:bpUm; $global:bpUm = @(); $global:bpRace = $true; Update-State don { param($x) $x.Remove('baselineHold') }   # a lease lands while the checks run: no mark
  $race = "$(@(Update-Baseline don (Read-State don)).Count)/$(@((Read-State don).marks | Where-Object kind -eq 'baseline').Count)"; $global:bpRace = $false; $global:bpUm = $um0; Update-State don { param($x) $x.leases = @{} }
  function SvcDir { $env:TEMP }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { $PID }; function Healthy { $true }; function Stop-Svc { }; function Owned { $false }; function Get-PortPids { @() }; $global:bpInit = 0; function Invoke-Shell { $global:bpInit++; if ($global:bpInit -eq 2) { Update-State don { param($x) $x.leases.R2 = @{ services = @('db'); agent = 'R2'; holderPid = $PID } } }; 0 }
  $fdb = @(EnvServices fresh | Where-Object name -eq 'db')[0]; $ref = try { $null = Start-SvcOnce fresh $fdb 1 ''; 'ran' } catch { "$_" }; $i0 = $global:bpInit
  $global:bpUm = @(); $ok = @(Start-SvcOnce fresh $fdb 1 '') -join ' '; $sd = Read-State don; $bs = @($sd.marks | Where-Object kind -eq 'baseline')
  $again = @(Update-Baseline don (Read-State don)).Count; $used = try { $null = Start-SvcOnce fresh $fdb 1 ''; 'ran' } catch { "$_" }; Update-State don { param($x) $x.leases = @{} }
  function MarksOn { $false }; $nm = "$((Get-BaselineBlock don) -match 'no marks')/$($null -eq (Get-BaselineBlock don -Donor))"; Remove-Item -LiteralPath $sf -Force
  $bpCut = '[ :\x28]'; $bpWhy = @($w | ForEach-Object { ("$_" -split $bpCut)[0..1] -join ' ' }) -join ','
  $bpH1 = $h1 -match '^baseline stays baseline-0001: applied migration.s. its changelog lacks: s1 2 .dev:9, dev:10.'; $bpRef = $ref -match 'init refused: donor don is no clean baseline .applied migration'
  $bpOk = $ok -match '\[don\] mark baseline-\S+ clean on release 4'; $bpUsed = $used -match 'donor don was used during the copy .lease'
  "$bpWhy|$dn|$bpH1|$($h2 -eq '')|$race|$bpRef|$i0|$bpOk|$($bs.Count)|$($bs[-1].release)|$($null -eq $sd.baselineHold)|$again|$bpUsed|$($global:bpInit)|$nm" }
Expect "baseline: blocked by a train, a layer, a lease, a hold (a donor's hold: allowed), no clean items, a red seed, test data, an unmerged migration (said once); a lease landing mid-check: no mark; clean: promoted in place; a lane init refuses a dirty donor, runs on a clean one, fails when the donor was used during the copy; no marks: a donor check still runs ($bp)" ($bp -eq 'a train,unmerged layer,lease s),hold s),no test-data,the seed,test data,applied migration|True|True|True|0/1|True|0|True|2|4|True|0|True|2|True/True')
# owner 2026-11-26 (lane priority: "prioritise lanes for them"): envy.ps1 priority high -Run <run> marks the run's agents (launch
# record areas + live board rows); they go first in the build gate and the start queue, their train tells holders at once (a
# running check: leaseMinutes), a cold lane opens for them without the queue wait, others keep off their lane
$tl1 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl1.Start(); $pzPort = $tl1.LocalEndpoint.Port; $tl1.Stop()
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ localEnv = @{ leaseMinutes = 5; lanes = @{ openAfterMinutes = 15 }; envs = @{ pz = @{ lanes = @{ max = 2 }; services = @(@{ name = 'api'; start = 'echo api'; port = $pzPort }) } } } } 8
$pz = & { . $lkL; $pzNow = (Get-Date).ToString('o'); $pzBd = Get-KitPath board -Create; $pzCa = $env:CLAUDE_AGENT; $env:CLAUDE_AGENT = 'devy-x'
  $vA = try { Invoke-LocalEnv priority high -Agent devy-x } catch { "$_" }; $env:CLAUDE_AGENT = ''
  Set-JsonFile (Join-Path (Get-KitPath launches -Create) 'self-buildy-run-x.json') @{ run = 'run-x'; args = @{ agents = @(@{ id = 'H1' }, @{ id = 'H2' }) } }
  Set-JsonFile (Join-Path $pzBd 'devy-7-1.json') @{ agent = 'devy-7'; run = 'run-x'; status = 'step 2'; beat = $pzNow }; Set-JsonFile (Join-Path $pzBd 'devy-6-1.json') @{ agent = 'devy-6'; run = 'run-x'; status = 'left'; beat = $pzNow }
  $v1 = @(Invoke-LocalEnv priority high -Run run-x) -join ' '; $v2 = @(Invoke-LocalEnv priority) -join ' | '; $hi = "$(Test-KitHigh H1)/$(Test-KitHigh devy-7)/$(Test-KitHigh devy-6)/$(Test-KitHigh N1)"
  Set-JsonFile (Join-Path $pzBd 'devy-8-1.json') @{ agent = 'devy-8'; run = 'run-x'; status = 'step 1'; beat = $pzNow }   # joined the high run later
  $hi += "/$(Test-KitHigh devy-8)/$([math]::Abs((([datetime](Read-KitParams).priority.H1.until) - (Get-Date).AddHours(72)).TotalMinutes) -lt 2)"; Remove-Item (Join-Path $pzBd 'devy-8-1.json')
  $go = @(Get-GateOrder @(@{ pid = 1; prio = 0; owner = 'N1'; sec = 10; since = $pzNow }, @{ pid = 2; prio = 0; owner = 'H1'; sec = 900; since = $pzNow }, @{ pid = 3; prio = 1; owner = 'H2'; sec = 5; since = $pzNow }) @{} (Get-Date) | ForEach-Object { $_.pid }) -join ','
  $env:KIT_PRIORITY = 'high'; $gt = (Get-GateTicket 'build' 'mvn' 60).prio; Remove-Item Env:KIT_PRIORITY
  function Send-LeaseNotice { }; function Test-KitAgentBusy($ba) { $false }
  Update-State pz { param($x) $x.leases = @{ N1 = @{ services = @('api'); agent = 'N1'; holderPid = $PID; lastUse = (Get-Date).AddMinutes(-5).ToString('o') } }; $x.requests = @(@{ id = 'r1'; kind = 'deploy'; status = 'in-train'; agent = 'N9'; at = (Now) }); $x.train = @{ id = 't1'; requests = @('r1'); at = (Now) } }
  $w1 = (Get-LeaseWaitMin pz) -join '/'; Update-State pz { param($x) $x.requests[0].agent = 'H1' }; $w2 = (Get-LeaseWaitMin pz) -join '/'
  $script:Preempted = @(); $script:LeaseWait0 = $null; $told = @(Wait-Leases pz @('api') @() @('H1')) -join ' '; $le = "$((LaneEnv pz (Svc pz 'api')).KIT_PRIORITY)"
  Update-State pz { param($x) $x.requests = @($x.requests) + @(@{ id = 'r2'; kind = 'deploy'; status = 'queued'; agent = 'N2'; at = (Now) }, @{ id = 'r3'; kind = 'restore'; status = 'queued'; agent = 'main'; at = (Now) }) }
  $j1 = Join-LateRequests pz 't1' 6>$null; $sj = Read-State pz; $j2 = Join-LateRequests pz 't1' 6>$null
  $jn = "$j1/$(@($sj.train.requests) -join ',')/$(@($sj.requests | Where-Object id -eq 'r2')[0].status)/$(@($sj.requests | Where-Object id -eq 'r3')[0].status)/$j2/$((Get-Content $lkL -Raw).Contains('if (Join-LateRequests $e $Train) { return Run-Train }'))"
  $qd = StartQueueDir; $ps0 = "$(Get-KitPidStart $PID)"
  Set-JsonFile (Join-Path $qd 'a.json') @{ pid = $PID; pstart = $ps0; service = 'small'; cost = 10; since = $pzNow; high = $false }; Set-JsonFile (Join-Path $qd 'b.json') @{ pid = $PID; pstart = $ps0; service = 'big'; cost = 500; since = $pzNow; high = $true }
  $qh = (Get-StartQueueHead).service; Remove-Item (Join-Path $qd '*.json')
  function Get-GateAvailGB { 50 }; function KeepFreeGB { 10 }; function Need-GB { 1 }
  Update-State pz { param($x) $x.leases = @{}; $x.train = $null; $x.requests = @() }
  Update-State pz2 { param($x) $x.services = @{ api = @{ status = 'up' } }; $x.release.repos.r = @{ layers = @(@{ branch = 'b'; agent = 'F1' }) }; $x.requests = @(@{ id = 'w1'; kind = 'deploy'; status = 'queued'; agent = 'F1'; at = (Get-Date).AddMinutes(-1).ToString('o') }) }
  $sl = "$(Select-Lane pz S1 0 'deploy' 6>$null)/$(Select-Lane pz H2 0 'deploy' 6>$null)"
  Update-State pz { param($x) $x.services = @{ api = @{ status = 'up' } }; $x.release.repos.r = @{ layers = @(@{ branch = 'g1'; agent = 'G1' }, @{ branch = 'g2'; agent = 'G2' }) } }   # both warm: 2 normal agents here, 1 there
  $sl += "/$(Select-Lane pz S9 0 'logs' 6>$null)"; $k0 = Select-Lane pz S9 0 'deploy' 6>$null; Set-LanePriority high @('F1') ''; $sl = "$sl/$k0/$(Select-Lane pz S8 0 'deploy' 6>$null)"; Set-LanePriority normal @('F1') ''
  $v3 = @(Invoke-LocalEnv priority normal -Run run-x) -join ' '; $v4 = @(Invoke-LocalEnv priority) -join ' '; $v5 = try { Invoke-LocalEnv priority high -Run nope } catch { "$_" }
  $pzV = "$($v1 -match '^priority high: H1, H2, devy-7 for 72 h')/$($v2 -match 'high H1 \(run run-x\) until \d\d-\d\d \d\d:\d\d')/$($v3 -eq 'priority normal: H1, H2, devy-7')/$($v4 -match 'no high agent')/$($v5 -match 'nope has no launch record')/$($vA -match 'never an agent .devy-x.')"; $env:CLAUDE_AGENT = $pzCa
  "$pzV|$hi|$go|$gt|$w1|$w2|$($told -match 'told N1 after 0 min')|$le|$jn|$qh|$sl" }
Expect "lane priority: priority high -Run marks the run's areas + live board agents (list, normal, an unknown run); gate: a high owner one class up; a high train: holders told at once, its builds first; late requests join a train waiting for leases (a restore never); start queue: a high lane first; a cold lane opens for a high agent at once ($pz)" ($pz -eq 'True/True/True/True/True/True|True/True/False/False/True/True|2,3,1|-1|5/120/|0/5/, high priority|True|high|True/r1,r2/in-train/queued/False/True|big|pz2/pz/pz/pz2/pz')
# agent cap (2026-11-26): localEnv.pressureStopsPerHour (4) lane stops under memory pressure in 60 min = one WATCH naming the live
# devy / checky agents and the cap; fewer, older ones or other stops: none
Copy-Item (Join-Path $src 'skills/bossy/adapters/localenv-supervise.ps1') (New-Item -ItemType Directory -Force (Join-Path $laneKit 'skills/bossy/adapters')); $supBossy = Join-Path $laneKit 'skills/bossy/bossy.ps1'
$mpW = @(foreach ($mpCount in 3, 4) {
  (& { . $supBossy; function Left { 30 }; function Within { $false }; $now = Get-Date; function Invoke-KitExe { [pscustomobject]@{ code = 0; out = '[]' } }; function Invoke-KitBackground { }
    $mpBd = Get-KitPath board -Create; Set-JsonFile (Join-Path $mpBd 'devy-1-a.json') @{ agent = 'devy-1'; type = 'devy'; status = 'step 2'; beat = $now.ToString('o') }; Set-JsonFile (Join-Path $mpBd 'checky-1-a.json') @{ agent = 'checky-1'; type = 'checky'; status = 'step 1'; beat = $now.ToString('o') }
    Set-JsonFile (Join-Path $mpBd 'devy-2-a.json') @{ agent = 'devy-2'; type = 'devy'; status = 'left'; beat = $now.ToString('o') }; Set-JsonFile (Join-Path $mpBd 'revy-1-a.json') @{ agent = 'revy-1'; type = 'revy'; status = 'working'; beat = $now.ToString('o') }
    if ($mpCount -eq 3) { Write-KitLog env stop @{ env = 'shop'; service = 'api'; why = 'idle: no holder for 15 min (starts on the next lease)' }; Write-KitLog env stop @{ at = (Get-KitStamp stored $now.AddHours(-2)); env = 'shop'; service = 'api'; why = 'idle, stopped under memory pressure (old)' }
      1..3 | ForEach-Object { Write-KitLog env stop @{ env = 'shop'; service = 'api'; why = 'idle, stopped under memory pressure (1 GB under the floor)' } } }
    else { Write-KitLog env stop @{ env = 'shop2'; service = 'db'; why = 'idle, stopped under memory pressure (RAM)' } }
    @(Get-KitSuperviseFlagsLocalEnv) | Where-Object { $_.what -match '^MEMORY PRESSURE' } | ForEach-Object { "$($_.what) -> $($_.action -replace ';.*')" } }) -join ';' })
Expect "supervise MEMORY PRESSURE: 3 pressure stops in the hour (an idle stop, a 2 h old one: not counted) none; the 4th = one WATCH with the live devy / checky count and the cap ($($mpW -join ' | '))" ($mpW[0] -eq '' -and $mpW[1] -eq 'MEMORY PRESSURE: 4 lane service stop(s) under memory pressure in 60 min (localEnv.pressureStopsPerHour 4), 2 devy / checky agent(s) live -> Start no new run, agent or lane until it clears (agent cap now: 1)')
# services[].routes: a rewrite maps a prefixed path onto the files, a cmd answers with its stdout, a capture that is no path 400, a failed cmd 404
$svr = & { . $lkL; function SvcDir { $args[1].dir }; $wtd = Join-Path $laneKit 'rt'; New-Item -ItemType Directory -Force (Join-Path $wtd 'web/dist/app') | Out-Null
  '<html>i</html>' | Set-Content (Join-Path $wtd 'web/dist/app/index.html'); 'x' | Set-Content (Join-Path $wtd 'web/dist/app/main.js'); $fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $port = $fp.LocalEndpoint.Port; $fp.Stop()
  $rs = [pscustomobject]@{ name = 'web'; dir = (Join-Path $wtd 'web'); static = 'dist/app'; port = $port; routes = @(@{ match = '^/s1/(.+\.json)$'; cmd = 'echo {"f":"$1"}' }, @{ match = '^/s1/no\.txt$'; cmd = 'exit 3' }, @{ match = '^/s1(/.*)?$'; rewrite = '$1' }) }
  $sc = StartCmd t $rs (Join-Path $wtd 'web/dist/app'); $rj = Get-Content -Raw ([regex]::Match($sc, '"([^"]+routes\.json)"').Groups[1].Value) | ConvertFrom-Json
  $srv = Start-Process node -ArgumentList ($sc -replace '^node ') -PassThru -WindowStyle Hidden
  try { for ($i = 0; $i -lt 120 -and -not (Test-PortListening $port); $i++) { Start-Sleep -Milliseconds 250 }
    $g = { param($u) try { $x = Invoke-WebRequest "http://127.0.0.1:$port$u" -SkipHttpErrorCheck -TimeoutSec 10; "$($x.StatusCode):$("$($x.Content)".Trim())" } catch { 'ERR' } }
    "$(@($rj).Count)|$(& $g '/s1/main.js')|$(& $g '/s1/about')|$(& $g '/s1/site.json')|$((& $g '/s1/a%26b.json') -replace ':.*')|$((& $g '/s1/no.txt') -replace ':.*')|$(& $g '/main.js')" } finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } }
Expect "static server routes: rewrite, cmd stdout, unsafe capture 400, failed cmd 404, plain files unchanged ($svr)" ($svr -eq '3|200:x|200:<html>i</html>|200:{"f":"site.json"}|400|404|200:x')
Copy-Item (Join-Path $src 'skills/crafty/adapters/container-tests.ps1') (New-Item -ItemType Directory -Force (Join-Path $laneKit 'skills/crafty/adapters'))   # Add-ToolFlags
# owner 2026-11-27 (javaIncremental trial): a Maven build compiles the changed sources + dependants (subclasses transitively, every
# @Mapper); full on no baseline, an entity in the set, a deleted source; every fullEvery-th also a full one, compared; failed -> full
$jit = & { . $lkL 6>$null; $jw = Join-Path $k 'ji-wt'; $jm = Join-Path $jw 'api'; $jp = Join-Path $jm 'src/main/java/p'; $jcl = Join-Path $jm 'target/classes/p'
  $null = New-Item -ItemType Directory -Force $jp, $jcl; git -C $jw init -q -b main; $jg = { git -C $jw -c user.name=t -c user.email=t@t @args 2>&1 | Out-Null }
  $jsrc = [ordered]@{ A = 'public class A { }'; B = 'public class B extends A { }'; C = 'public class C extends B { }'; F = 'class F { C c; }'; D = 'class D { }'; M = '@Mapper interface M { }'; E = '@Entity class E { F f; }' }
  'x' | Set-Content (Join-Path $jm 'pom.xml'); foreach ($jn in $jsrc.Keys) { $jsrc[$jn] | Set-Content (Join-Path $jp "$jn.java"); 'c' | Set-Content (Join-Path $jcl "$jn.class") }
  'i' | Set-Content (Join-Path $jcl 'A$In.class'); & $jg add -A; & $jg commit -q -m base; $jb = "$(git -C $jw rev-parse HEAD)".Trim()
  function EnvRepos { @{ r = [pscustomobject]@{ wt = $jw } } }; function RepoOf { 'r' }
  $jsv = [pscustomobject]@{ name = 'api'; javaIncremental = [pscustomobject]@{ fullEvery = 3; fullWhen = '@Entity' } }; $jc = 'mvn -q package'; $jlog = Join-Path $k 'ji.log'; 'x' | Set-Content $jlog
  $jold = { Get-ChildItem $jp -File | ForEach-Object { $_.LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-1) } }
  $jnew = { @(Get-ChildItem $jp -File | Where-Object { $_.LastWriteTimeUtc -gt [datetime]::UtcNow.AddMinutes(-5) } | ForEach-Object BaseName | Sort-Object) -join '' }
  $p0 = Get-JavaIncPlan t $jsv $jm $jc; Update-State t { param($x) $x.javaInc = @{ api = @{ sha = $jb; n = 0 } } }
  'public class A { int x; }' | Set-Content (Join-Path $jp 'A.java'); & $jg commit -q -am a; & $jold
  $p1 = Get-JavaIncPlan t $jsv $jm $jc; $t1 = & $jnew; $gone1 = -not (Test-Path (Join-Path $jcl 'A.class')) -and -not (Test-Path (Join-Path $jcl 'A$In.class')) -and (Test-Path (Join-Path $jcl 'D.class'))
  $s1 = Step-JavaInc t $jsv $p1 0 $jlog; $n1 = (Read-State t).javaInc.api.n
  $null = New-Item -ItemType Directory -Force (Join-Path $jm 'target/maven-status/maven-compiler-plugin/compile/x'); 'class F { C c; int q; }' | Set-Content (Join-Path $jp 'F.java'); & $jg commit -q -am f
  $p2 = Get-JavaIncPlan t $jsv $jm $jc; $rs2 = -not (Test-Path (Join-Path $jm 'target/maven-status/maven-compiler-plugin/compile')); $null = Step-JavaInc t $jsv $p2 0 $jlog
  Update-State t { param($x) $x.javaInc.api.n = 2 }; 'class D { int y; }' | Set-Content (Join-Path $jp 'D.java'); & $jg commit -q -am d
  $p3 = Get-JavaIncPlan t $jsv $jm $jc; $s3a = Step-JavaInc t $jsv $p3 0 $jlog; 'changed' | Set-Content (Join-Path $jcl 'F.class'); $s3b = Step-JavaInc t $jsv $p3 0 $jlog
  'class D { int z; }' | Set-Content (Join-Path $jp 'D.java'); & $jg commit -q -am d2; 'error: cannot find symbol' | Set-Content $jlog
  $p4 = Get-JavaIncPlan t $jsv $jm $jc; $s4 = Step-JavaInc t $jsv $p4 1 $jlog; $n4 = (Read-State t).javaInc.api.n
  'c' | Set-Content (Join-Path $jcl 'D.class'); & $jg rm -q (Join-Path $jp 'D.java'); & $jg commit -q -m rm; $p5 = Get-JavaIncPlan t $jsv $jm $jc; $gone5 = -not (Test-Path (Join-Path $jcl 'D.class'))
  $off = Get-JavaIncPlan t ([pscustomobject]@{ name = 'api' }) $jm $jc; Start-Sleep -Milliseconds 1100; $bw0 = Get-Date; 'y' | Set-Content (Join-Path $jcl 'Y.class'); $bw = Get-BuildWrites $jm $bw0
  @("$($p0.mode):$($p0.why)", "$($p1.mode):$($p1.touched):${t1}:${gone1}:$($p1.cmd)", "[$s1]$n1", "$($p2.mode):$($p2.why):$rs2", "$($p3.mode):${s3a}:[$s3b]:$($p3.diff)",
    "$($p4.mode):${s4}:${n4}:$($p4.why)", "$($p5.mode):$($p5.why):$gone5", "[$off]$($bw.files)") -join ' | ' }
Expect "javaIncremental: full without a baseline; A changed -> A, B, C (subclass of B), F (names C), M (@Mapper) touched, A classes gone, the flag; fullWhen (an entity) in the set -> full + compiler status reset; every 3rd -> a full one compared (1 class differs); failed -> full; a deleted source -> full, its class gone; off -> none; writes counted ($jit)" ($jit -eq 'full:no baseline build | incremental:5:ABCFM:True:mvn -Dmaven.compiler.useIncrementalCompilation=false -q package | []1 | full:fullWhen matches api/src/main/java/p/E.java:True | verify:mvn -q package:[]:1 | fallback:mvn -q package:0:incremental failed (exit 1): error: cannot find symbol | full:1 deleted source(s):True | []1')
# the Hibernate entity index after a compile that saw only Lamp (DIM removed) and House: other types kept, gone values and names dropped
$jix = & { . $lkL 6>$null; $ir = Join-Path $k 'ji-idx'; $null = New-Item -ItemType Directory -Force $ir
  $wr = { param($n, $t, $h) [IO.File]::WriteAllText((Join-Path $ir $n), $t); [IO.File]::SetLastWriteTimeUtc((Join-Path $ir $n), [datetime]::UtcNow.AddHours(-$h)) }
  & $wr '.ON' 'p.Lamp p.Switch ' 2; & $wr '.OFF' 'p.Lamp ' 2; & $wr '.DIM' 'p.Lamp ' 2; & $wr 'Old' 'p.Gone' 2; & $wr 'Room' 'p.Room' 2
  $jp2 = @{ idx = $ir; snap = (Get-JavaIndexSnap $ir); fqns = @('p.Gone', 'p.House') }
  & $wr '.ON' 'p.Lamp ' 0; & $wr '.OFF' 'p.Lamp ' 0; & $wr 'House' 'p.House' 0; Merge-JavaIndex $jp2
  @(Get-ChildItem $ir | Sort-Object Name | ForEach-Object { "$($_.Name)=$([IO.File]::ReadAllText($_.FullName))" }) -join ';' }
Expect "javaIncremental: entity index merged after an incremental compile ($jix)" ($jix -eq '.OFF=p.Lamp ;.ON=p.Lamp p.Switch ;House=p.House;Room=p.Room')
Remove-TestKit $laneKit
Complete-Tests
