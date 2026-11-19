#Requires -Version 7
<#
tests/deploy-restart.tests.ps1: a fake ssh on PATH answers busy / free; supervise deploy holds; offline.
Usage: pwsh -NoProfile -File tests/deploy-restart.tests.ps1 (its tests.ps1 runs this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs
$TestKitFiles = @('skills/bossy/adapters/deploy_merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed_checks.ps1')   # copied into every New-TestKit kit
$k = New-TestKit deploy-restart; $O = Join-Path $k 'skills/bossy/bossy.ps1'
foreach ($f in 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/adapters/deploy_merge.ps1', 'skills/pokey/adapters/deployed_checks.ps1') {
  $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) $f) $d
}
# fake ssh: logs each decoded host script; a script with a busy check: mode busy = always BUSY, once = BUSY on the first call, then the restarts
$bin = Join-Path (Kd) 'sshbin'; $null = New-Item -ItemType Directory -Force $bin; $sshLog = Join-Path (Kd) 'ssh.log'
Set-Content (Join-Path $bin 'fakessh.ps1') @'
$b64 = (("$($args[-1])" -split ' ')[1]); $sh = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
$n = @(Get-ChildItem (Split-Path $env:FAKE_SSH_LOG) -Filter 'ssh.log.*').Count; Set-Content "$env:FAKE_SSH_LOG.$n" $sh
if ($sh -match 'BUSY=1' -and ($env:FAKE_SSH_MODE -eq 'busy' -or ($env:FAKE_SSH_MODE -eq 'once' -and $n -eq 0))) { 'BUSY=1'; 'LIVE=4242 00:21 claude -p run' }
else { foreach ($m in [regex]::Matches($sh, "(?:systemctl|docker) restart '([^']+)'")) { $v = $m.Groups[1].Value; "DONE=$v 0"; "ACTIVE=$v active" }; 'END=1' }
'@
if ($KitIsWindows -or $IsWindows) { Set-Content (Join-Path $bin 'ssh.cmd') "@`"$pwshExe`" -NoProfile -File `"%~dp0fakessh.ps1`" %*" }
else { $sp = Join-Path $bin 'ssh'; [IO.File]::WriteAllText($sp, "#!/bin/sh`nexec `"$pwshExe`" -NoProfile -File `"`$(dirname `"`$0`")/fakessh.ps1`" `"`$@`"`n"); chmod +x $sp }
$path0 = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FAKE_SSH_LOG = $sshLog
$kl = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ repos = @(@{ name = 'svc'; deploys = @(@{ target = 'svc-stage'; ssh = @{ host = 'u@h1'; key = 'k.pem'; service = 'app,app-worker'; busy = 'pgrep -fa agent-turn' } }, @{ target = 'nobusy'; ssh = @{ host = 'u@h2'; service = 'app' } },
  @{ target = 'dock'; ssh = @{ host = 'u@h3'; service = 'web'; manager = 'docker'; sudo = $false } }, @{ target = 'bare'; ssh = @{ host = 'u@h4'; service = 'web'; manager = 'none' } },
  @{ target = 'kube'; production = $false; command = @{ restart = "`"$pwshExe`" -NoProfile -Command Write-Output rolled-{service}" } }) }); deploy = @{ ssh = @{ manager = 'systemd'; sudo = $true } } } $kl   # LEGACY deploy.ssh
$logs = { @(Get-ChildItem (Kd) -Filter 'ssh.log.*' | Sort-Object Name | ForEach-Object { Get-Content $_.FullName -Raw }) }
$clear = { Get-ChildItem (Kd) -Filter 'ssh.log.*' | Remove-Item }

$env:FAKE_SSH_MODE = 'busy'
$rb = Px $O deploy restart -Env svc-stage -WaitMinutes 0 2>&1 | Out-String; $rbc = $LASTEXITCODE; $lb = @(& $logs)
Expect "deploy restart: a live turn on the host = REFUSED exit 3, nothing restarted ($($rb.Trim()) $rbc)" ($rbc -eq 3 -and $rb -match 'REFUSED deploy restart svc-stage: live work on u@h1' -and $rb -match 'claude -p run' -and $rb -match 'not restarted: app, app-worker')
$bi = if ($lb.Count) { $lb[0].IndexOf('pgrep -fa agent-turn') } else { -1 }; $ri = if ($lb.Count) { $lb[0].IndexOf('systemctl restart') } else { -1 }
Expect "deploy restart: the busy check runs in the same host script, right before each restart ($bi $ri)" ($bi -ge 0 -and $ri -gt $bi -and ([regex]::Matches($lb[0], 'pgrep -fa agent-turn')).Count -eq 2)

& $clear; $env:FAKE_SSH_MODE = 'once'
$ro = Px $O deploy restart -Env svc-stage -WaitMinutes 1 -RecheckSeconds 1 2>&1 | Out-String; $roc = $LASTEXITCODE
Expect "deploy restart: busy then free = waits, re-checks, restarts both ($($ro.Trim()) $roc)" ($roc -eq 0 -and $ro -match 'BUSY svc-stage: live work' -and $ro -match 'RESTARTED svc-stage: app, app-worker on u@h1' -and @(& $logs).Count -eq 2)

& $clear
$rn = Px $O deploy restart -Env nobusy 2>&1 | Out-String; $rnc = $LASTEXITCODE
$ru = Px $O deploy restart -Env nobusy -Ungated 2>&1 | Out-String; $ruc = $LASTEXITCODE
Expect "deploy restart: no ssh.busy = REFUSED exit 2 without ssh; -Ungated restarts ($($rn.Trim()) $rnc | $($ru.Trim()) $ruc)" ($rnc -eq 2 -and $rn -match 'no deploys\[\]\.ssh\.busy' -and @(& $logs).Count -eq 1 -and $ruc -eq 0 -and $ru -match 'RESTARTED nobusy: app on u@h2 .*\(ungated\)')
Expect 'deploy restart: a failed restart stops the host script before the next service; the busy command reads no stdin' ($lb[0] -match '\[ \$R -eq 0 \] \|\| exit 0' -and $lb[0] -match "sh -c 'pgrep -fa agent-turn' </dev/null")
# ssh.manager docker: docker restart / inspect, no systemctl, no sudo; manager none: refused; kind command (kubectl-like): its restart line, no ssh
& $clear
$rd = Px $O deploy restart -Env dock -Ungated 2>&1 | Out-String; $rdc = $LASTEXITCODE; $ld = @(& $logs)
Expect "deploy restart: ssh.manager docker restarts with docker, no systemctl, no sudo ($($rd.Trim()) $rdc)" ($rdc -eq 0 -and $rd -match 'RESTARTED dock: web on u@h3' -and $ld.Count -eq 1 -and $ld[0] -match "docker restart 'web'" -and $ld[0] -match 'docker inspect' -and $ld[0] -notmatch 'systemctl|sudo -n')
$rbr = Px $O deploy restart -Env bare -Ungated 2>&1 | Out-String; $rbrc = $LASTEXITCODE
Expect "deploy restart: ssh.manager none = REFUSED exit 2, no ssh ($($rbr.Trim()))" ($rbrc -eq 2 -and $rbr -match 'has no manager' -and @(& $logs).Count -eq 1)
$rk = Px $O deploy restart -Env kube -Service web 2>&1 | Out-String; $rkc = $LASTEXITCODE
Expect "deploy restart: kind command runs its restart line, no ssh ($($rk.Trim()) $rkc)" ($rkc -eq 0 -and $rk -match 'RESTARTED kube \(deploy kind command\): rolled-web' -and @(& $logs).Count -eq 1)
$rx = Px $O deploy restart -Env nope 2>&1 | Out-String; $rxc = $LASTEXITCODE
Expect "deploy restart: an unknown target or one without ssh = usage, exit 2 ($($rx.Trim()))" ($rxc -eq 2 -and $rx -match 'nope has no repos\[\]\.deploys\[\]\.ssh')

$env:PATH = $path0; Remove-Item Env:FAKE_SSH_LOG, Env:FAKE_SSH_MODE
# supervise deploy holds (moved from deploys.tests.ps1: its token cap)
$ht = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Within($n) { $true }; function Invoke-Bounded { @() }
$gs = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.trigger') { 'ask' } else { & $gs @args } }.GetNewClosure())
$pc = Join-Path (Get-KitPath deploys -Create) 'plan-cache.json'; $now = Get-Date
$cacheOf = { param([string[]]$m) @{ at = $now.ToString('o'); asked = $now.ToString('o'); ready = @("stage ($($m.Count) MR(s))"); ask = @("stage: $($m.Count) MR(s) ($($m -join ', '))"); mrsOf = @{ stage = $m } } | ConvertTo-Json -Depth 4 | Set-Content $pc }
$word = { param($id, $ans, $q = 'deploy stage', $min = 1) Write-KitLog decisions-log answered ([ordered]@{ id = $id; kind = 'decision'; item = 'stage,other'; gate = 'deploy'; question = $q; answer = $ans; by = 'owner'; answeredAt = $now.AddMinutes(-$min).ToString('o'); mrs = @() }) }
$acts = { param($r) @($r | Where-Object level -eq 'ACT' | ForEach-Object what) -join ';' }
& $cacheOf @('api!1'); & $word 'd-20260101000000-coordinator-aa11' 'dont deploy stage' 'deploy stage' 3
$r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"held:$(-not (& $acts $r) -and ($r.info -join ';') -eq 'deploy stage held by owner: aa11' -and (Get-Content $pc -Raw | ConvertFrom-Json).held.stage.id -eq 'd-20260101000000-coordinator-aa11')"
& $cacheOf @('api!1', 'api!2'); $held = (Get-Content $pc -Raw | ConvertFrom-Json); $held | Add-Member -Force NoteProperty held ([pscustomobject]@{ stage = @{ id = 'd-20260101000000-coordinator-aa11'; mrs = @('api!1') } }); $held | ConvertTo-Json -Depth 5 | Set-Content $pc
$r1 = @(Get-KitSuperviseFlagsDeploys -AutoFix); $r2 = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"fresh:$((& $acts $r1) -match '^DEPLOY ASK stage: 2 MR\(s\) .*new since hold aa11: api!2' -and -not (& $acts $r2) -and ($r2.info -join ';') -match 'held by owner: aa11')"
& $word 'd-20260101000100-coordinator-bb22' 'yes, deploy stage'; $r = @(Get-KitSuperviseFlagsDeploys)
"yes:$((& $acts $r) -match '^DEPLOY GO stage: approved \(bb22, owner\)' -and (& $acts $r) -notmatch 'DEPLOY ASK' -and @($r.info -match '^deploy ready: stage').Count -eq 1)"
& $word 'd-20260101000200-opsy-stage-cc33' "wait: retry $($now.AddMinutes(30).ToString('HH:mm'))" 'host stayed busy' 0; $r = @(Get-KitSuperviseFlagsDeploys)
"wait:$(-not (& $acts $r) -and ($r.info -join ';') -eq "deploy stage waiting: host busy, retry $($now.AddMinutes(30).ToString('HH:mm')) (cc33)")"
$now = $now.AddMinutes(31); $r = @(Get-KitSuperviseFlagsDeploys)
"due:$((& $acts $r) -match '^DEPLOY RETRY stage: host busy, wait cc33 due since' -and (& $acts $r) -notmatch 'DEPLOY ASK')"
& $word 'd-20260101000300-coordinator-dd44' 'yes: standing rule' 'deploy stage' 0; $r = @(Get-KitSuperviseFlagsDeploys)   # a yes after a wait of the last 12 h: still that retry
"retry:$((& $acts $r) -match '^DEPLOY RETRY stage: host busy, wait cc33' -and (& $acts $r) -notmatch 'DEPLOY (ASK|GO)')"
& $cacheOf @('api!1', 'api!2', 'api!3'); & $word 'd-20260101000400-coordinator-ee55' 'keep stage hanges held' 'deploy stage' -1; $r = @(Get-KitSuperviseFlagsDeploys -AutoFix)
"all:$(-not (& $acts $r) -and ($r.info -join ';') -match 'deploy stage held by owner: ee55')"
$gs2 = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.hold') { @('stage') } else { & $gs2 @args } }.GetNewClosure())
& $word 'd-20260101000500-coordinator-ff66' 'yes' 'deploy stage' -2; $r = @(Get-KitSuperviseFlagsDeploys)
"cfg:$(-not (& $acts $r) -and ($r.info -join ';') -match 'deploy stage held by config: deploy.hold')"
"kinds:$((@('dont deploy hm', 'No', 'hold it', 'wait: not urgent, never cut a live turn', 'Deploy tomorrow', 'yes: standing rule', 'deploy if needed', 'Sure, no problem', 'Please deploy now, no need to hold', 'test prod pipelines also', 'keep hm hanges held', 'dnt deploy hm', 'no deploy for hm yet', 'HM: merge and promote, never deploy', 'No problem, go ahead', 'do not wait, deploy', 'No problem, but hold hm') | ForEach-Object { Get-KitDeployWordKind $_ }) -join ',')"
Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'deploy.answerWords') { [pscustomobject]@{ yes = @('ja'); no = @('nein'); noAll = @('nie'); wait = @('später') } } else { & $gs2 @args } }.GetNewClosure())
"words:$((@('Ja, bitte', 'nein', 'nie wieder', 'später', 'janky', 'yes') | ForEach-Object { Get-KitDeployWordKind $_ }) -join ',')"
'@
$hr = Invoke-PsTest 'deploy-holds' $ht @($O)
Expect-Each $hr 'supervise deploy holds: an env''s newest no = one muted "held by <by>: <id>" line, no ACT, until a later yes or an MR it did not cover (one fresh ask, then covered); a yes = DEPLOY GO; env-wide no / deploy.hold: held; a wait = "waiting: <why>, retry HH:mm", then DEPLOY RETRY (a yes after it too) (#)' @('held', 'fresh', 'yes', 'wait', 'due', 'retry', 'all', 'cfg')
Expect "deploy word kinds: no / wait / yes from the answer ($(@($hr) -match '^kinds:'))" (@($hr) -contains 'kinds:no,no,no,wait,wait,yes,yes,yes,yes,unclear,noAll,no,no,noAll,yes,yes,no')
Expect "deploy.answerWords: an org's own leading words first, whole words only, English still read ($(@($hr) -match '^words:'))" (@($hr) -contains 'words:yes,no,noAll,wait,unclear,yes')
Remove-TestKit $k
Complete-Tests
