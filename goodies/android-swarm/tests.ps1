#Requires -Version 7
<#
tests.ps1 (goody android-swarm): phoney.ps1 phone lanes (acquire, reverse, release, AVD, build, lanes on demand), pokey.ps1 ui on a fake
adb, the deploys[] laneApk check. iOS: goody ios-simulator.
Usage: kitbag.py goody test android-swarm (tests/kit-tests.ps1 -Area goodies runs every installed goody).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kitbag.py goody test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# swarm: -Reverse 8080,8081 = 2 ports, whole lease; release holds '__stopping__' until down ends; avd; build command
$swt = @'
$ErrorActionPreference = 'Stop'
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$adb = "$tmp/adb.cmd"; Set-Content $adb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device)`r`nexit /b 0" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L1'; port = 5560 }); adb = $adb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
$P = Get-KitPath phones -Create; $lf = "$P/L1.json"
@{ agent = 'B'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).AddMinutes(-20).ToString('s'); seen = (Get-Date).AddMinutes(-11).ToString('o'); holderPid = 999999 } | ConvertTo-Json | Set-Content $lf
$rc = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A') *>&1 | Out-String
"reclaim:$($rc -match 'reclaimed L1 from B' -and (Get-Content $lf -Raw | ConvertFrom-Json).agent -eq 'A')"
@{ agent = 'A'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $lf
$j = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-Reverse', '8080,8081') | Select-Object -Last 1 | ConvertFrom-Json
"reverse:$((@($j.reverse) -join ',') -eq '8080,8081' -and (@((Get-Content $lf -Raw | ConvertFrom-Json).reverse) -join ',') -eq '8080,8081' -and -not @(Get-ChildItem $P -Filter '*.tmp').Count)"
Set-Content "$tmp/d.ps1" "(Get-Content '$lf' -Raw | ConvertFrom-Json).agent > '$tmp/during.txt'"; $KitCmd.swarm = "$tmp/d.ps1"
$null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'A')
"release:$((Get-Content "$tmp/during.txt" -Raw).Trim() -eq '__stopping__' -and -not (Test-Path $lf))"
$s = "$tmp/sdk"; New-Item -ItemType Directory -Force "$s/platform-tools", "$s/system-images/a35/g/arm64-v8a", "$tmp/a" | Out-Null; Copy-Item $adb "$s/platform-tools"
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'A1'; port = 5570 }); adb = "$s/platform-tools/adb.cmd"; avdDir = "$tmp/avd"; apkDir = $tmp; out = $tmp; appFile = "$tmp/app.apk"
  avd = [pscustomobject]@{ abi = 'arm64-v8a'; api = 'a35'; device = 'p8'; tag = 'g' }; app = [pscustomobject]@{ buildTask = 'b'; appDir = "$tmp/a"; buildCmd = 'fb {gw}'; artifact = 'o/*.apk' } }
$null = Invoke-KitVerb Invoke-Avd @('create', '-Lanes', 'A1', '-NoBoot'); $ini = Get-Content "$tmp/avd/A1.avd/config.ini" -Raw
Set-Content "$tmp/gate.ps1" 'param($v, $Dir, $Cmd, $WaitMinutes) New-Item -ItemType Directory -Force "$Dir/o" | Out-Null; Set-Content "$Dir/o/x.apk" $Cmd'; $KitCmd.dev = "$tmp/gate.ps1"
git -C "$tmp/a" init -q; git -C "$tmp/a" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i; $null = Invoke-KitVerb Invoke-Build @('-NoUpdate')
# build -Local: app-local.apk only from origin/<app.branch> HEAD or a localenv/* branch, else a side APK
$script:SwarmCfg.app | Add-Member branch 'main'; Set-Content "$tmp/a/.gitignore" 'o/'; git -C "$tmp/a" add .gitignore; git -C "$tmp/a" -c user.name=t -c user.email=t@t commit -q -m ig
$null = Invoke-KitVerb Invoke-Build @('-NoUpdate', '-Local'); $side = -not (Test-Path "$tmp/app-local.apk") -and @(Get-ChildItem $tmp -Filter 'app-local-*.apk').Count
git -C "$tmp/a" checkout -q -b localenv/r1; $null = Invoke-KitVerb Invoke-Build @('-NoUpdate', '-Local')
"local:$($side -and (Test-Path "$tmp/app-local.apk"))"
"kinds:$($ini -match 'arch=arm64\s[\s\S]*a35\\g\\arm64-v8a' -and $ini -match 'PlayStore.enabled=false' -and $ini -match 'hw.audioInput=yes') $((Get-Content "$tmp/app.apk" -Raw) -match 'fb gradlew')"
'@
$sf = "$([IO.Path]::GetTempPath())swarm-test-$PID"; Set-Content "$sf.ps1" $swt
$res = @(Px "$sf.ps1" (Join-Path $src 'skills/phoney/phoney.ps1') $sf 2>&1)
foreach ($x in 'reclaim:True', 'reverse:True', 'release:True', 'kinds:True True', 'local:True') { Expect "swarm: $x" ($res -contains $x) }
Remove-Item "$sf.ps1", $sf -Recurse -Force -ErrorAction SilentlyContinue
# lease files: reads and writes under the file lock (an open reader made the rename fail)
$ss = & { $rt = Join-Path ([IO.Path]::GetTempPath()) "swl-$PID"; Set-Item Env:CLAUDE_RUNTIME $rt; . (Join-Path $src 'skills/phoney/phoney.ps1')
  foreach ($fn in (Get-Command Invoke-Phone).ScriptBlock.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Save-Json', 'Lease' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
  $dir = Join-Path $rt 'ph'; New-Item -ItemType Directory -Force $dir | Out-Null; Save-Json @{ agent = 'A' } "$dir/L1.json"
  Save-Json @{ agent = 'B' } "$dir/L1.json"; "$((Lease L1).agent)$(Test-Path "$dir/L1.json.lock")" }
Expect "swarm: lease reads and writes go through the file lock, released after ($ss)" ($ss -eq 'BFalse' -and (Get-Content (Join-Path $src 'skills/phoney/phoney.ps1') -Raw) -match 'function Lease\(\$name\) \{[^\n]*Invoke-KitLocked')
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) "swl-$PID") -Recurse -Force -ErrorAction SilentlyContinue
# lanes 0..N on demand: 3 requests, RAM for 2 boots: 2 boot, the 3rd waits, takes lane 1 when A releases it; no 3rd emulator ever starts
$lsc = @'
$tmp = $args[1]; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$dev = Join-Path $tmp 'devices.txt'; $adb = Join-Path $tmp 'adb.cmd'
Set-Content $adb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& type `"$dev`" 2>nul)`r`nexit /b 0" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @(1..3 | ForEach-Object { [pscustomobject]@{ name = "L$_"; port = 5560 + 2 * $_ } }); adb = $adb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
Set-Content "$tmp/mock.ps1" @"
param([Parameter(Position = 0)]`$Verb, `$Lanes, `$Mode, [switch]`$ColdBoot, [switch]`$KeepBrowsers)
`$port = 5560 + 2 * [int]("`$Lanes" -replace '\D')
if (`$Verb -eq 'up') { if (Test-Path '$tmp/full') { Start-Sleep 2; Write-Warning "`$Lanes not started: no memory turn"; return }; Add-Content '$dev' "emulator-`$port``tdevice"; Add-Content '$tmp/boots.txt' `$Lanes }
if (`$Verb -eq 'down') { Set-Content '$dev' @(Get-Content '$dev' | Where-Object { `$_ -notmatch "-`$port\s" }) }
"@
$KitCmd.swarm = "$tmp/mock.ps1"
if ($args[2] -eq 'C') { Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'C', '-NoInstall', '-WaitMinutes', '2') | Select-Object -Last 1; return }
New-Item -ItemType File -Force $dev | Out-Null
$a = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-NoInstall') | Select-Object -Last 1 | ConvertFrom-Json
$b = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'B', '-NoInstall') | Select-Object -Last 1 | ConvertFrom-Json
New-Item -ItemType File "$tmp/full" | Out-Null
$cp = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $PSCommandPath, $args[0], $tmp, 'C' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$tmp/c.out"
for ($i = 0; $i -lt 60 -and -not (Test-Path (Join-Path (Get-KitPath phones) 'L3.json')); $i++) { Start-Sleep -Milliseconds 500 }
$null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'A'); $null = $cp.WaitForExit(120000)
$cj = @(Get-Content "$tmp/c.out" | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json
"scale:$($a.lane -eq 'L1' -and $b.lane -eq 'L2' -and $cj.lane -eq 'L1' -and (@(Get-Content "$tmp/boots.txt") -join ',') -eq 'L1,L2')"
'@
$lf2 = "$([IO.Path]::GetTempPath())lanes-test-$PID"; New-Item -ItemType Directory -Force $lf2 | Out-Null; Set-Content "$lf2.ps1" $lsc
$res = @(Px "$lf2.ps1" (Join-Path $src 'skills/phoney/phoney.ps1') $lf2 2>&1)
Expect "swarm: lanes on demand, a waiting request takes a lane freed meanwhile, no extra boot ($(@($res | Where-Object { "$_" -match '^scale:' })))" ($res -contains 'scale:True')
Remove-Item "$lf2.ps1", $lf2 -Recurse -Force -ErrorAction SilentlyContinue
# pokey.ps1 ui (adapters/ui_android.ps1): a tap that finds nothing and a wait that times out exit 1 (fake adb serves one screen)
$k = New-TestKit swarm-qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
foreach ($f in 'skills/pokey/adapters/ui_android.ps1', 'skills/crafty/adapters/android_sdk.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $k (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }   # Get-AndroidSdk lives in android_sdk.ps1
$null = Px $Q ui bogus 2>&1; $uc = $LASTEXITCODE
$ud = Join-Path (Kd) 'ui'; New-Item -ItemType Directory -Force "$ud/platform-tools" | Out-Null
Set-Content "$ud/s.xml" '<hierarchy><node text="Hello" resource-id="a:id/h" class="x" bounds="[0,0][10,10]"/></hierarchy>'
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`nif `"%1`"==`"pull`" copy /y `"$ud\s.xml`" `"%3`" >nul`r`nexit /b 0" -Encoding ascii
Set-Content "$ud/u.ps1" '$a = @($args); Set-Item Env:CLAUDE_RUNTIME "$($a[1])/rt"; $env:ANDROID_HOME = $a[1]; . $a[0]; function Get-ExeName($n) { "$n.cmd" }; Invoke-Ui "$($a[2])" "$($a[3])" "$($a[4])"'
$ut = @(foreach ($a in @(@('tap', 'Hello'), @('tap', 'Nope'), @('wait', 'Nope', '1'))) { $null = Px "$ud/u.ps1" $Q $ud @a 2>&1; $LASTEXITCODE })
Expect "ui: found 0, NOT FOUND 1, wait TIMEOUT 1; unknown action 2 ($($ut -join ','),$uc)" (($ut -join ',') -eq '0,1,1' -and $uc -eq 2)
# ui mic: no emulator serial = usage 2; an emulator with no gRPC discovery file = 1, nothing sent
Set-Content "$ud/s.wav" 'x'; $env:ANDROID_SERIAL = $null; $null = Px "$ud/u.ps1" $Q $ud mic "$ud/s.wav" 2>&1; $m1 = $LASTEXITCODE
$env:ANDROID_SERIAL = 'emulator-5999'; $mo = Px "$ud/u.ps1" $Q $ud mic "$ud/s.wav" 2>&1 | Out-String; $m2 = $LASTEXITCODE; $env:ANDROID_SERIAL = $null
Expect "ui mic: no serial 2, no gRPC endpoint 1 ($m1,$m2)" ($m1 -eq 2 -and $m2 -eq 1 -and $mo -match 'no gRPC endpoint for emulator-5999')
# deploys[] laneApk: no stamp = UNKNOWN with the build hint; a stamp holding the merge = DEPLOYED (local checkout answers)
# Row, LocalAncestor, OnRef: the Invoke-Deployed helpers the adapter calls (a local checkout answers; no git host)
$la = & { . $Q; function Row($d, $s, $x) { "$s|$x" }; function OnRef { $false }
  function LocalAncestor($dir, $sha, $commit) { git -C $dir merge-base --is-ancestor $sha $commit 2>$null; $LASTEXITCODE -eq 0 }
  $gr = Join-Path (Kd) 'app'; git init -q $gr; git -C $gr -c user.name=t -c user.email=t@t commit -qm a --allow-empty
  $sha = "$(git -C $gr rev-parse HEAD)".Trim(); $s8 = $sha.Substring(0, 8); $stamp = Join-Path (Kd) 'app.json'
  $a = Test-LaneApkDeployed ([pscustomobject]@{ laneApk = $stamp })
  & $J @{ commit = $sha; branch = 'main'; built = 'now'; appDir = $gr } $stamp; $b = Test-LaneApkDeployed ([pscustomobject]@{ laneApk = $stamp }); "$a#$b" }
Expect "deployed laneApk: no stamp UNKNOWN, merged commit in the APK DEPLOYED ($la)" ($la -match '^UNKNOWN\|no lane APK stamp.*#DEPLOYED\|in the lane APK')
Remove-TestKit $k

# gpu.exclusive: another kind holding the GPU -> up boots no emulator ("waiting for GPU", the acquire queue retries)
$k = New-TestKit swarm-gpu; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force   # the installed goody: -Kit runs give a core-only test kit
& $J @{ gpu = @{ exclusive = @{ emulator = @{}; 'gpu-job' = @{} } } } (Join-Path $k 'skills/crafty/kit.local.json')
$vis = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
$gt = Join-Path (Kd) 'gpu-up'; New-Item -ItemType Directory -Force $gt | Out-Null
$gu = Invoke-PsTest 'swarm-gpu' @"
. '$(Join-Path $k 'skills/phoney/phoney.ps1')'
`$null = Use-KitGpu -Kind gpu-job -Holder v1 -ProcessId $($vis.Id) -WaitMinutes 0
Set-Content '$gt/adb.cmd' "@echo off``r``nexit /b 0" -Encoding ascii; Set-Content '$gt/emu.cmd' "@echo off``r``necho started> '$gt/started.txt'" -Encoding ascii
`$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'G1'; port = 5590 }); adb = '$gt/adb.cmd'; emulator = '$gt/emu.cmd'; avdDir = '$gt'; dir = '$gt'; out = '$gt'; state = '$gt/swarm.json'; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() } }
`$env:KIT_SWARM_TURN_MIN = '0'
`$w = @(Invoke-Up -Lanes G1 -Mode None -Headless 3>&1 | Where-Object { `$_ -is [Management.Automation.WarningRecord] })
"blocked:`$((`$w.Message -match 'G1 not started: no memory turn \(waiting for GPU\)').Count -eq 1 -and -not (Test-Path '$gt/started.txt'))"
# avd.gpu swiftshader (software rendering, no GPU memory): boots although another kind holds the GPU
Set-Content '$gt/adb.cmd' "@echo off``r``necho 1``r``nexit /b 0" -Encoding ascii; Set-Content '$gt/emu.cmd' "@echo off``r``necho started> $gt\started.txt" -Encoding ascii; Set-Content '$gt/noop.ps1' 'exit 0'; `$KitCmd.swarm = '$gt/noop.ps1'; `$KitCmd.dev = '$gt/noop.ps1'
`$script:SwarmCfg | Add-Member -Force avd ([pscustomobject]@{ gpu = 'swiftshader' })
`$null = Invoke-Up -Lanes G1 -Mode None -Headless 3>&1; for (`$i = 0; `$i -lt 20 -and -not (Test-Path '$gt/started.txt'); `$i++) { Start-Sleep -Milliseconds 250 }
"software:`$(Test-Path '$gt/started.txt')"
"@
Stop-Process -Id $vis.Id -Force -ErrorAction SilentlyContinue
Expect-Each $gu 'swarm gpu: another kind holding the GPU -> no lane boot, a software-rendered lane boots: #' @('blocked', 'software') -Show 8
Remove-Item $gt -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k

# gpu.exclusive.emulator.minFreeMB (2048): 1500 MB free -> waits (supervise shows it), then refuses naming the GPU users; 3000 boots; no nvidia-smi skips
$k = New-TestKit swarm-vram; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force
& $J @{ gpu = @{ exclusive = @{ emulator = @{} } } } (Join-Path $k 'skills/crafty/kit.local.json')
$vt = Join-Path (Kd) 'vram'; New-Item -ItemType Directory -Force $vt | Out-Null
$vSetup = @'
. '__K__/skills/phoney/phoney.ps1'
Set-Content '__VT__/adb.cmd' "@echo off`r`necho 1`r`nexit /b 0" -Encoding ascii; Set-Content '__VT__/emu.cmd' "@echo off`r`necho started> __VT__\started.txt" -Encoding ascii
Set-Content '__VT__/noop.ps1' 'exit 0'; $KitCmd.swarm = '__VT__/noop.ps1'; $KitCmd.dev = '__VT__/noop.ps1'
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'V1'; port = 5592 }); adb = '__VT__/adb.cmd'; emulator = '__VT__/emu.cmd'; avdDir = '__VT__'; dir = '__VT__'; out = '__VT__'; state = '__VT__/swarm.json'; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() } }
$env:KIT_GPU_PROBE = '__VT__/probe.json'; $env:KIT_POLL_MS = '200'
'@
$vSetup = $vSetup.Replace('__K__', $k).Replace('__VT__', $vt)
Set-Content "$vt/wait.ps1" ($vSetup + "`n`$env:KIT_SWARM_TURN_MIN = '0.1'; Invoke-Up -Lanes V1 -Mode None -Headless *>&1 | Out-String | Set-Content '$vt/wait.txt'")
$vr = Invoke-PsTest 'swarm-vram' ($vSetup + @'

$pr = { param($free) (@{ usedMB = 10000; freeMB = $free; procs = @(@{ pid = 4242; name = 'gpu-app'; mb = 9000 }) } | ConvertTo-Json -Depth 4) | Set-Content $env:KIT_GPU_PROBE }
& $pr 1500
$child = Start-Process pwsh -ArgumentList '-NoProfile', '-File', '__VT__/wait.ps1' -PassThru -WindowStyle Hidden
$sup = ''; for ($i = 0; $i -lt 60 -and $sup -notmatch 'waiting for GPU: emulator V1'; $i++) { Start-Sleep -Milliseconds 200; $sup = "$(Get-KitSuperviseGuardGpu)" }
$supOk = $sup -match 'waiting for GPU: emulator V1 \(held by gpu needs 2048 MB free GPU memory, 1500 MB free'; "supervise:$supOk"
$child.WaitForExit(30000) | Out-Null; $wt = Get-Content '__VT__/wait.txt' -Raw
"refused:$($wt -match 'lane V1: needs 2048 MB free GPU memory, 1500 MB free \(held by gpu-app pid 4242 9000 MB\); not started: no memory turn' -and -not (Test-Path '__VT__/started.txt') -and -not @((Get-KitGpuState).waiting).Count)"
& $pr 3000
$null = Invoke-Up -Lanes V1 -Mode None -Headless 3>&1; for ($i = 0; $i -lt 20 -and -not (Test-Path '__VT__/started.txt'); $i++) { Start-Sleep -Milliseconds 250 }
"boots:$(Test-Path '__VT__/started.txt')"
Remove-Item '__VT__/started.txt'; Set-Content $env:KIT_GPU_PROBE 'null'
$w = @(Invoke-Up -Lanes V1 -Mode None -Headless 3>&1 | Where-Object { $_ -is [Management.Automation.WarningRecord] })
for ($i = 0; $i -lt 20 -and -not (Test-Path '__VT__/started.txt'); $i++) { Start-Sleep -Milliseconds 250 }
"skips:$(@($w.Message -match 'GPU free-memory check skipped: nvidia-smi does not answer').Count -eq 1 -and (Test-Path '__VT__/started.txt'))"
'@.Replace('__VT__', $vt))
Expect-Each $vr 'swarm vram: under minFreeMB a lane waits (supervise shows it) then refuses, 3000 MB free boots, no nvidia-smi skips: #' @('supervise', 'refused', 'boots', 'skips') -Show 12
Remove-Item $vt -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k
# lane events (fixture logs, no emulator): off by default; getevent taps + uiautomator clicks / typing -> one sidecar, epoch times, screen px
$k = New-TestKit swarm-events
$ev = Invoke-PsTest 'swarm-events' @"
. '$(Join-Path $src 'skills/phoney/phoney.ps1')'
`$script:SwarmCfg = [pscustomobject]@{ adb = 'adb-never-called'; out = '$((Kd) -replace "'", "''")'; events = `$false }
"off:`$((Invoke-Events start -Serial emulator-5554) -match 'capture is off')"
`$ge = @('[  100.000000] /dev/input/event1: EV_ABS       ABS_MT_TRACKING_ID   00000001', '[  100.000000] /dev/input/event1: EV_ABS       ABS_MT_POSITION_X    00002000',
  '[  100.000000] /dev/input/event1: EV_ABS       ABS_MT_POSITION_Y    00004000', '[  100.000000] /dev/input/event1: EV_KEY       BTN_TOUCH            DOWN',
  '[  100.000000] /dev/input/event1: EV_SYN       SYN_REPORT           00000000', '[  100.080000] /dev/input/event1: EV_KEY       BTN_TOUCH            UP',
  '[  102.000000] /dev/input/event1: EV_ABS       ABS_MT_POSITION_X    00002000', '[  102.000000] /dev/input/event1: EV_ABS       ABS_MT_POSITION_Y    00006000',
  '[  102.000000] /dev/input/event1: EV_KEY       BTN_TOUCH            DOWN', '[  102.000000] /dev/input/event1: EV_SYN       SYN_REPORT           00000000',
  '[  102.300000] /dev/input/event1: EV_ABS       ABS_MT_POSITION_Y    00002000', '[  102.300000] /dev/input/event1: EV_KEY       BTN_TOUCH            UP')
`$ui = @('EventType: TYPE_VIEW_CLICKED; EventTime: 100150; PackageName: com.example; ClassName: android.widget.Button; Text: [Save]; ContentDescription: null',
  'EventType: TYPE_VIEW_TEXT_CHANGED; EventTime: 104000; PackageName: com.example; ClassName: android.widget.EditText; Text: [QA-123]',
  'EventType: TYPE_VIEW_SCROLLED; EventTime: 104500; PackageName: com.example')
`$e = @(ConvertTo-LaneEvents -GetEvent `$ge -UiEvents `$ui -Uptime 99 -At 1700000000000 -Size 1080, 2400 -Max 32767, 32767)
"parsed:`$((`$e.action -join ',') -eq 'click,swipe,type' -and `$e[0].text -eq 'Save' -and `$e[0].at -eq 1700000001000 -and `$e[0].target -eq '270,1200' -and `$e[2].text -eq 'QA-123' -and `$e[2].at -eq 1700000005000 -and `$e[1].target -match '-> 270,600')"
"@
Expect-Each $ev 'swarm events: #' @('off', 'parsed') -Show 6
Remove-TestKit $k
# reaper: supervise -AutoFix, no phoney call, reclaims the lane of a holder that left the board (its holder pid = the live session
# process) and stops it (emu kill); leases.jsonl gets one reclaim and one down line; phoney.ps1 status shows last used
$k = New-TestKit swarm-reap; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force
$rp = Join-Path (Kd) 'reap'; New-Item -ItemType Directory -Force "$rp/platform-tools", "$k/skills/crafty/adapters" | Out-Null; $ab = "$rp/platform-tools/adb.cmd"
Set-Content "$k/skills/crafty/adapters/android_sdk.ps1" "function Get-AndroidSdk { '$rp' }; function Get-ExeName([string]`$Name) { `"`$Name.cmd`" }"   # the fake adb, never the machine's
Set-Content $ab "@echo off`r`necho %* >> `"$rp/adb.log`"`r`nif `"%3`"==`"emu`" (type nul > `"$rp/killed`")`r`nif `"%1`"==`"devices`" (echo List of devices attached& if not exist `"$rp/killed`" echo emulator-5556`tdevice)`r`nexit /b 0" -Encoding ascii
& $J @{ lanes = @(@{ name = 'Falcon'; port = 5556 }); adb = $ab; app = @{ package = 'x' } } (Join-Path $k 'skills/phoney/swarm.config.json')
$ho = @{ holderPid = $PID; holderStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
& $J (@{ session = 'AP-e3'; agent = 'AP'; run = 'r1'; type = 'devy'; status = 'left'; beat = (Get-Date).AddMinutes(-30).ToString('o'); joined = (Get-Date).AddHours(-1).ToString('o') } + $ho) (Join-Path (TkPath $k board -Create) 'AP-e3.json')
& $J (@{ agent = 'AP'; lane = 'Falcon'; serial = 'emulator-5556'; holder = 'AP-e3'; since = (Get-Date).AddHours(-1).ToString('s'); seen = (Get-Date).AddMinutes(-11).ToString('o') } + $ho) (Join-Path (TkPath $k phones -Create) 'Falcon.json')
$sv = (pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') supervise -AutoFix -Json | Out-String | ConvertFrom-Json).flags.what -join "`n"
$lg = @(Get-Content (TkPath $k leases) | ConvertFrom-Json | ForEach-Object { "$($_.event)/$($_.name)/$($_.agent)/$($_.reason)" }) -join ','
Expect "swarm reaper: lane of a left holder reclaimed and stopped by supervise ($lg)" (-not (Test-Path (Join-Path (TkPath $k phones) 'Falcon.json')) -and (Get-Content "$rp/adb.log" -Raw) -match 'emu kill' -and
  $lg -eq 'reclaim/Falcon/AP/reclaim: no live holder for 10 min,down/Falcon//reclaim: no live holder for 10 min' -and $sv -match 'auto-fixed: reclaimed phone Falcon of AP')
$ps = pwsh @np (Join-Path $k 'skills/phoney/phoney.ps1') status | Out-String
Expect "swarm status: last used per lane ($(($ps -split "`n")[0].Trim()))" ($ps -match 'Falcon\s+emulator-5556\s+down\s+free \S+ last used \d\d-\d\d \d\d:\d\d by AP \(reclaim: no live holder for 10 min\)')
# an agent stage that ends holding a lane: the workflow's bossy.ps1 release leaves no lease and no running lane
Remove-Item "$rp/killed", "$rp/adb.log"; & $J (@{ agent = 'X1'; lane = 'Falcon'; serial = 'emulator-5556'; since = (Get-Date).ToString('s') } + $ho) (Join-Path (TkPath $k phones) 'Falcon.json')
$ro = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') release -Agent X1 | Out-String; $last = Get-Content (TkPath $k leases) | Select-Object -Last 2 | ConvertFrom-Json
Expect "swarm release: an ended agent's lane freed and stopped ($($ro.Trim()))" (-not (Test-Path (Join-Path (TkPath $k phones) 'Falcon.json')) -and (Get-Content "$rp/adb.log" -Raw) -match 'emu kill' -and
  "$($last[0].event)/$($last[0].agent)/$($last[0].reason) $($last[1].event)" -eq 'release/X1/agent finished down')
Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the goodies merged into this one
Complete-Tests
