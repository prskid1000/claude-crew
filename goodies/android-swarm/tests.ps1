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
"kinds:$($ini -match 'arch=arm64\s[\s\S]*a35\\g\\arm64-v8a' -and $ini -match 'PlayStore.enabled=false') $((Get-Content "$tmp/app.apk" -Raw) -match 'fb gradlew')"
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

# gpu.exclusive: a vision job holding the GPU -> up boots no emulator ("waiting for GPU", the acquire queue retries)
$k = New-TestKit swarm-gpu; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force   # the installed goody: -Kit runs give a core-only test kit
& $J @{ gpu = @{ exclusive = @{ emulator = @{}; 'local-vision' = @{} } } } (Join-Path $k 'skills/crafty/kit.local.json')
$vis = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
$gt = Join-Path (Kd) 'gpu-up'; New-Item -ItemType Directory -Force $gt | Out-Null
$gu = Invoke-PsTest 'swarm-gpu' @"
. '$(Join-Path $k 'skills/phoney/phoney.ps1')'
`$null = Use-KitGpu -Kind local-vision -Holder v1 -ProcessId $($vis.Id) -WaitMinutes 0
Set-Content '$gt/adb.cmd' "@echo off``r``nexit /b 0" -Encoding ascii; Set-Content '$gt/emu.cmd' "@echo off``r``necho started> '$gt/started.txt'" -Encoding ascii
`$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'G1'; port = 5590 }); adb = '$gt/adb.cmd'; emulator = '$gt/emu.cmd'; avdDir = '$gt'; dir = '$gt'; out = '$gt'; state = '$gt/swarm.json'; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() } }
`$env:KIT_SWARM_TURN_MIN = '0'
`$w = @(Invoke-Up -Lanes G1 -Mode None -Headless 3>&1 | Where-Object { `$_ -is [Management.Automation.WarningRecord] })
"blocked:`$((`$w.Message -match 'G1 not started: no memory turn \(waiting for GPU\)').Count -eq 1 -and -not (Test-Path '$gt/started.txt'))"
"@
Stop-Process -Id $vis.Id -Force -ErrorAction SilentlyContinue
Expect-Each $gu 'swarm gpu: a vision job holding the GPU -> no lane boot: #' @('blocked') -Show 8
Remove-Item $gt -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the goodies merged into this one
Complete-Tests
