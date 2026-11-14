#Requires -Version 7
<#
tests/deploy-restart.tests.ps1: a fake ssh on PATH answers busy / free; offline.
Usage: pwsh -NoProfile -File tests/deploy-restart.tests.ps1 (its tests.ps1 runs this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
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
else { foreach ($m in [regex]::Matches($sh, "systemctl restart '([^']+)'")) { $v = $m.Groups[1].Value; "DONE=$v 0"; "ACTIVE=$v active" }; 'END=1' }
'@
if ($KitIsWindows -or $IsWindows) { Set-Content (Join-Path $bin 'ssh.cmd') "@`"$pwshExe`" -NoProfile -File `"%~dp0fakessh.ps1`" %*" }
else { $sp = Join-Path $bin 'ssh'; [IO.File]::WriteAllText($sp, "#!/bin/sh`nexec `"$pwshExe`" -NoProfile -File `"`$(dirname `"`$0`")/fakessh.ps1`" `"`$@`"`n"); chmod +x $sp }
$path0 = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FAKE_SSH_LOG = $sshLog
$kl = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ repos = @(@{ name = 'svc'; deploys = @(@{ target = 'svc-stage'; ssh = @{ host = 'u@h1'; key = 'k.pem'; service = 'app,app-worker'; busy = 'pgrep -fa agent-turn' } }, @{ target = 'nobusy'; ssh = @{ host = 'u@h2'; service = 'app' } }) }) } $kl
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
$rx = Px $O deploy restart -Env nope 2>&1 | Out-String; $rxc = $LASTEXITCODE
Expect "deploy restart: an unknown target or one without ssh = usage, exit 2 ($($rx.Trim()))" ($rxc -eq 2 -and $rx -match 'nope has no repos\[\]\.deploys\[\]\.ssh')

$env:PATH = $path0; Remove-Item Env:FAKE_SSH_LOG, Env:FAKE_SSH_MODE
Remove-TestKit $k
Complete-Tests
