#Requires -Version 7
<#
local-env-6.tests.ps1: envy.ps1 lane trains and seeds (local-env-4 is at its cap): the warm-lane target pin, the seed hint on a
service not up yet.
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
  Update-State lw { param($x) $x.leases = @{ B1 = @{ services = @('api'); agent = 'B1'; holderPid = $PID; lastUse = (Now) } }; $x.requests = @() }
  $b1 = @(Wait-Leases lw @('api') @() @()) -join ' '; $script:Preempted = @(); $script:LeaseWait0 = $null; $script:busyN = 0; $script:MaxLeaseMin = 0
  $b2 = @(Wait-Leases lw @('api') @() @()) -join ' '
  "$($b1 -match 'B1 on api \(at most \d+ min: a check runs\)')|$($b1 -match 'told B1')|$($b2 -notmatch 'a check runs' -and $b2 -match 'told B1')" }
Expect "leases: a holder whose check runs is not swapped under at leaseMinutes, waited for up to maxLeaseMinutes, then told ($lb)" ($lb -eq 'True|True|True')
# owner 2026-11-26 (baseline in place; lane DB donor = a clean baseline mark): the liquibase unmerged verb = applied changeSets the
# changelog files lack (XML, formatted SQL, YAML), per schema
Set-JsonFile (Join-Path $laneKit 'skills/crafty/kit.local.json') @{ migrations = @{ tool = 'liquibase' }; localEnv = @{ envs = @{
  don = @{ db = @{ port = 3391 }; services = @(@{ name = 'db'; port = 3391; start = 'db' }) }
  fresh = @{ db = @{ port = 3392 }; services = @(@{ name = 'db'; port = 3392; start = 'db'; init = @{ cmd = 'clone'; creates = 'zz-none'; donor = 'don' } }) } } } } 8
$um = & { . $lkL; $umRoot = New-Item -ItemType Directory -Force (Join-Path (Kd) 'um/resources/db'); function SqlId($sn) { "[$sn]" }
  Set-Content (Join-Path $umRoot 'a.xml') '<databaseChangeLog><changeSet id="1" author="dev"><sql>x</sql></changeSet><changeSet author="dev" id="2"/></databaseChangeLog>'
  Set-Content (Join-Path $umRoot 'b.sql') "--liquibase formatted sql`n--changeset ann:3`nSELECT 1;"
  Set-Content (Join-Path $umRoot 'c.yaml') "databaseChangeLog:`n  - changeSet:`n      id: 4`n      author: bob`n      changes: []"
  function Resolve-MigSets { @([pscustomobject]@{ name = 'm'; tool = 'liquibase'; searchPath = (Split-Path $umRoot); schemas = @('s1', 's2') }) }
  function Invoke-DbSql($qe, $qs) { @('dev', '1'), @('ann', '3'), @('bob', '4'), @('dev', '2'); if ($qs -match '\[s2\]') { @('eve', '77'), @('eve', '78') } }
  $umR = @(& $KitAdapters['migration']['liquibase']['unmerged'] @{ e = 'don' }); "$($umR.Count)|$($umR[0].schema)|$($umR[0].count)|$($umR[0].sample -join ',')" }
Expect "liquibase unmerged: a schema whose DATABASECHANGELOG holds changeSets the changelog files lack is named with its count; one that matches: none ($um)" ($um -eq '1|s2|2|eve:77,eve:78')
# the block reasons in order (cheapest first), said once; clean = a new baseline mark; an init with a donor that is no clean baseline is refused
$bp = & { . $lkL; function MarksOn { $true }; $global:bpPos = 1; function Get-DbPos { "binlog.000001:$((++$global:bpPos))" }; function Test-PortListening([int]$Port) { $Port -eq 3391 }
  $global:bpSeedBad = $false; function Invoke-Seed { if ($global:bpSeedBad) { $script:SeedBad = $true } }
  $global:bpRows = '0'; function Invoke-Hook($he, $hn, $hv) { $script:HookOut = @($global:bpRows); $null }
  $global:bpUm = @(); function Get-MigTool { 'liquibase' }; function Invoke-MigVerb($mt, $mv, $ma) { $global:bpUm }
  $sf = SeedFile don; $it = @(@{ name = 'i1'; check = @{ sql = 'SELECT 1' } }); Set-JsonFile $sf @{ items = $it }
  Update-State don { param($x) $x.release = @{ n = 4; repos = @{ r = @{ layers = @(@{ branch = 'f/a'; agent = 'A1' }) } } }; $x.train = @{ id = 't'; at = (Now) }; $x.leases = @{ A1 = @{ services = @('db'); agent = 'A1'; holderPid = $PID } }
    $x.marks = @(@{ name = 'baseline-0001'; kind = 'baseline'; at = (Get-Date).AddHours(-2).ToString('o'); release = 3; pos = 'binlog.000001:1' }) }
  $w = @(Get-BaselineBlock don); Update-State don { param($x) $x.train = $null }; $w += Get-BaselineBlock don
  Update-State don { param($x) $x.release.repos.r.layers = @() }; $w += Get-BaselineBlock don; Update-State don { param($x) $x.leases = @{} }; $w += Get-BaselineBlock don
  Set-JsonFile $sf @{ items = $it; clean = @(@{ name = 'qa rows'; sql = 'SELECT COUNT(*) FROM t' }) }
  $global:bpSeedBad = $true; $w += Get-BaselineBlock don; $global:bpSeedBad = $false; $global:bpRows = '7'; $w += Get-BaselineBlock don; $global:bpRows = '0'
  $global:bpUm = @([pscustomobject]@{ schema = 's1'; count = 2; sample = @('dev:9', 'dev:10') }); $w += Get-BaselineBlock don
  $h1 = @(Update-Baseline don (Read-State don)) -join ' '; $h2 = @(Update-Baseline don (Read-State don)) -join ' '
  function SvcDir { $env:TEMP }; function StartCmd { 'x' }; function Wait-Room { }; function Test-Room { $true }; function Save-LocalEnvHistory { }; function Start-AotTrain { }
  function Start-Pwsh { $PID }; function Healthy { $true }; function Stop-Svc { }; function Owned { $false }; function Get-PortPids { @() }; $global:bpInit = 0; function Invoke-Shell { $global:bpInit++; 0 }
  $fdb = @(EnvServices fresh | Where-Object name -eq 'db')[0]; $ref = try { $null = Start-SvcOnce fresh $fdb 1 ''; 'ran' } catch { "$_" }; $i0 = $global:bpInit
  $global:bpUm = @(); $ok = @(Start-SvcOnce fresh $fdb 1 '') -join ' '; $sd = Read-State don; $bs = @($sd.marks | Where-Object kind -eq 'baseline')
  $again = @(Update-Baseline don (Read-State don)).Count; Remove-Item -LiteralPath $sf -Force
  $bpCut = '[ :\x28]'; $bpWhy = @($w | ForEach-Object { ("$_" -split $bpCut)[0..1] -join ' ' }) -join ','
  $bpH1 = $h1 -match '^baseline stays baseline-0001: applied migration.s. its changelog lacks: s1 2 .dev:9, dev:10.'; $bpRef = $ref -match 'init refused: donor don is no clean baseline .applied migration'
  $bpOk = $ok -match '\[don\] mark baseline-\S+ clean on release 4'
  "$bpWhy|$bpH1|$($h2 -eq '')|$bpRef|$i0|$bpOk|$($global:bpInit)|$($bs.Count)|$($bs[-1].release)|$($null -eq $sd.baselineHold)|$again" }
Expect "baseline: blocked by a train, a layer, a lease, no clean items, a red seed, test data, an unmerged migration (said once); clean: promoted in place; a lane init refuses a dirty donor, runs on a clean one ($bp)" ($bp -eq 'a train,unmerged layer,lease s),no test-data,the seed,test data,applied migration|True|True|True|0|True|1|2|4|True|0')
Remove-TestKit $laneKit
Complete-Tests
