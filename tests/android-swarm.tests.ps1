#Requires -Version 7
<#
tests/android-swarm.tests.ps1: phoney.ps1 phone lanes (acquire, reverse, release, AVD, build, lanes on demand), pokey.ps1 ui on a fake
adb, the deploys[] laneApk check. iOS: swarm-ios.ps1.
Also (was android-swarm-2.tests.ps1): phoney.ps1 lane capabilities: lanes[].caps, acquire -Cap, slim and
the AVD image of a play lane; bossy: a -Cap waiter in the wait lists, decide ask's env-blame guard.
Usage: pwsh -NoProfile -File tests/android-swarm.tests.ps1 (or tests/kit-tests.ps1 -Area android-swarm).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # a kit to test; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
# swarm: -Reverse 8080,8081 = 2 ports, whole lease; release holds '__stopping__' until down ends; avd; build command
$swt = @'
$ErrorActionPreference = 'Stop'
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$adb = "$tmp/adb.cmd"; Set-Content $adb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device)`r`nexit /b 0" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L1'; port = 5560 }); adb = $adb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
$P = Get-KitPath phones -Create; $lf = "$P/L1.json"
# seen: past the grace this kit learned (a fixed 11 min waited out a learned 37: the area ran 26 min)
@{ agent = 'B'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).AddMinutes(-20).ToString('s'); seen = (Get-Date).AddMinutes(-1 - [double](Get-KitParam 'idle.graceMinutes')).ToString('o'); holderPid = 999999 } | ConvertTo-Json | Set-Content $lf
$rc = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A') *>&1 | Out-String
"reclaim:$($rc -match 'reclaimed L1 from B' -and (Get-Content $lf -Raw | ConvertFrom-Json).agent -eq 'A')"
@{ agent = 'A'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $lf
$j = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-Reverse', '8080,8081') | Select-Object -Last 1 | ConvertFrom-Json
"reverse:$((@($j.reverse) -join ',') -eq '8080,8081' -and (@((Get-Content $lf -Raw | ConvertFrom-Json).reverse) -join ',') -eq '8080,8081' -and -not @(Get-ChildItem $P -Filter '*.tmp').Count)"
Set-Content "$tmp/d.ps1" "(Get-Content '$lf' -Raw | ConvertFrom-Json).agent > '$tmp/during.txt'"; $KitCmd.swarm = "$tmp/d.ps1"
$null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'A')
"release:$((Get-Content "$tmp/during.txt" -Raw).Trim() -eq '__stopping__' -and -not (Test-Path $lf))"
$null = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'test:CL1') *>&1; $ag = (Get-Content $lf -Raw | ConvertFrom-Json).agent; $null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'test:CL1')
"colon:$($ag -eq 'test:CL1' -and -not (Test-Path $lf) -and -not @(Get-ChildItem "$tmp/rt" -Recurse -Filter '*CL1*').Count)"
$s = "$tmp/sdk"; New-Item -ItemType Directory -Force "$s/platform-tools", "$s/system-images/a35/g/arm64-v8a", "$tmp/a" | Out-Null; Copy-Item $adb "$s/platform-tools"
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'A1'; port = 5570 }); adb = "$s/platform-tools/adb.cmd"; avdDir = "$tmp/avd"; apkDir = $tmp; out = $tmp; appFile = "$tmp/app.apk"
  avd = [pscustomobject]@{ abi = 'arm64-v8a'; api = 'a35'; device = 'p8'; tag = 'g' }; app = [pscustomobject]@{ buildTask = 'b'; appDir = "$tmp/a"; buildCmd = 'fb {gw}'; artifact = 'o/*.apk' } }
$gksAvd = ${function:Get-KitSetting}; Set-Item function:Get-KitSetting ({ if ($args[0] -eq 'devices.avd.extra') { [pscustomobject]@{ 'hw.ramSize' = 2048; 'hw.custom' = 'x' } } else { & $gksAvd @args } }.GetNewClosure())   # devices.avd.extra sets and adds lines
$null = Invoke-KitVerb Invoke-Avd @('create', '-Lanes', 'A1', '-NoBoot'); $ini = Get-Content "$tmp/avd/A1.avd/config.ini" -Raw; Set-Item function:Get-KitSetting $gksAvd
Set-Content "$tmp/gate.ps1" 'param($v, $Dir, $Cmd, $WaitMinutes) New-Item -ItemType Directory -Force "$Dir/o" | Out-Null; Set-Content "$Dir/o/x.apk" $Cmd'; $KitCmd.dev = "$tmp/gate.ps1"
git -C "$tmp/a" init -q; git -C "$tmp/a" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i; $null = Invoke-KitVerb Invoke-Build @('-NoUpdate')
# build -Local: app-local.apk only from origin/<app.branch> HEAD or a localenv/* branch, else a side APK
$script:SwarmCfg.app | Add-Member branch 'main'; Set-Content "$tmp/a/.gitignore" 'o/'; git -C "$tmp/a" add .gitignore; git -C "$tmp/a" -c user.name=t -c user.email=t@t commit -q -m ig
# K64: a buildCmd kind has no cleartext overlay: -Local refused without app.localBuildCmd, else built with it
$noLb = try { $null = Invoke-Build -NoUpdate -Local; 'built' } catch { "$_" }; $script:SwarmCfg.app | Add-Member localBuildCmd 'fbl {gw}'
$null = Invoke-KitVerb Invoke-Build @('-NoUpdate', '-Local'); $side = -not (Test-Path "$tmp/app-local.apk") -and @(Get-ChildItem $tmp -Filter 'app-local-*.apk').Count
git -C "$tmp/a" checkout -q -b localenv/r1; $null = Invoke-KitVerb Invoke-Build @('-NoUpdate', '-Local')
"local:$($side -and (Test-Path "$tmp/app-local.apk") -and (Get-Content "$tmp/app-local.apk" -Raw) -match 'fbl' -and $noLb -match 'localBuildCmd')"
"kinds:$($ini -match 'arch=arm64\s[\s\S]*a35\\g\\arm64-v8a' -and $ini -match 'PlayStore.enabled=false' -and $ini -match 'hw.audioInput=yes' -and $ini -match 'hw\.ramSize=2048\r?\n' -and $ini -notmatch 'ramSize=4096' -and $ini -match 'hw\.custom=x') $((Get-Content "$tmp/app.apk" -Raw) -match 'fb gradlew')"
# K70 (K7 fixes): install uninstalls (wipes app data) only on a signature / version clash; acquire -Lane stays on that lane
$a2 = "$tmp/adb2.cmd"; Set-Content $a2 "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device& echo emulator-5562	device& exit /b 0)`r`nif `"%3`"==`"uninstall`" (echo %2>> `"$tmp\un.txt`"& exit /b 0)`r`nif `"%4`"==`"-r`" (type `"$tmp\mode.txt`"& exit /b 0)`r`necho Success" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L1'; port = 5560 }, [pscustomobject]@{ name = 'L2'; port = 5562 }); adb = $a2; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
Set-Content "$tmp/i.apk" 'x'; $ins = foreach ($m in 'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]', 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: x]', 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]', 'Failure [INSTALL_FAILED_INCONSISTENT_CERTIFICATES]') { Set-Content "$tmp/mode.txt" $m; $ok = try { $null = Invoke-Install -Apk "$tmp/i.apk" -Serials 'e1' 3>$null; 1 } catch { 0 }; "$ok$(@(Get-Content "$tmp/un.txt" -ErrorAction SilentlyContinue).Count)" }
foreach ($n in 'L1', 'L2') { @{ agent = 'A'; lane = $n; serial = "emulator-556$(if ($n -eq 'L2') { 2 } else { 0 })"; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content "$P/$n.json" }
$jl = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-Lane', 'L2') | Select-Object -Last 1 | ConvertFrom-Json
"clash:$($ins -join ',') $($jl.lane)"
'@
# phoney from a test kit: its own .state (from the source kit, the lease log of a live kit got lanes L1 / L2 held by A, B, C)
$swk = New-TestKit swarm-state; foreach ($f in 'skills/phoney/phoney.ps1', 'skills/phoney/adapters/app-kinds.ps1', 'skills/phoney/adapters/arrange.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $swk (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }
$swp = Join-Path $swk 'skills/phoney/phoney.ps1'; $srcLeases = Join-Path $src '.state/leases.jsonl'
$sf = "$([IO.Path]::GetTempPath())swarm-test-$PID"; Set-Content "$sf.ps1" $swt
$res = @(Px "$sf.ps1" $swp $sf 2>&1)
foreach ($x in 'reclaim:True', 'reverse:True', 'release:True', 'colon:True', 'kinds:True True', 'local:True', 'clash:00,11,12,13 L2') { Expect "swarm: $x" ($res -contains $x) }
Remove-Item "$sf.ps1", $sf -Recurse -Force -ErrorAction SilentlyContinue
# lease files: reads and writes under the file lock (an open reader made the rename fail)
$ss = & { $rt = Join-Path ([IO.Path]::GetTempPath()) "swl-$PID"; Set-Item Env:CLAUDE_RUNTIME $rt; . (Join-Path $src 'skills/phoney/phoney.ps1')
  foreach ($fn in (Get-Command Invoke-Phone).ScriptBlock.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Save-Json', 'Lease' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
  $dir = Join-Path $rt 'ph'; New-Item -ItemType Directory -Force $dir | Out-Null; Save-Json @{ agent = 'A' } "$dir/L1.json"
  Save-Json @{ agent = 'B' } "$dir/L1.json"; "$((Lease L1).agent)$(Test-FileLockHeld "$dir/L1.json")" }
Expect "swarm: lease reads and writes go through the file lock, released after ($ss)" ($ss -eq 'BFalse' -and (Get-Content (Join-Path $src 'skills/phoney/phoney.ps1') -Raw) -match 'function Lease\(\$name\) \{[^\n]*Invoke-KitLocked')
Remove-Item (Join-Path ([IO.Path]::GetTempPath()) "swl-$PID") -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # later tests: their own kit's runtime, not the deleted swl-<pid>
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
$lc = @(Get-Content (Get-KitLogFile leases) | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.agent -eq 'C' -and $_.event -eq 'acquire' })[-1]   # its log line: since = when it began to wait; the kit's log may hold a torn line
"scale:$($a.lane -eq 'L1' -and $b.lane -eq 'L2' -and $cj.lane -eq 'L1' -and (@(Get-Content "$tmp/boots.txt") -join ',') -eq 'L1,L2' -and [datetime]$lc.since -lt [datetime]$lc.at)"
'@
$lf2 = "$([IO.Path]::GetTempPath())lanes-test-$PID"; New-Item -ItemType Directory -Force $lf2 | Out-Null; Set-Content "$lf2.ps1" $lsc
$res = @(Px "$lf2.ps1" $swp $lf2 2>&1)
Expect "swarm: lanes on demand, a waiting request takes a lane freed meanwhile (logged since = its wait start), no extra boot ($(@($res | Where-Object { "$_" -match '^scale:' })))" ($res -contains 'scale:True')
Remove-Item "$lf2.ps1", $lf2 -Recurse -Force -ErrorAction SilentlyContinue
$leak = @(Select-String -LiteralPath $srcLeases -Pattern "(swarm|lanes)-test-$PID\.ps1" -ErrorAction SilentlyContinue).Count
Expect "swarm: the lane tests log their leases in the test kit, none in the source kit's leases log ($leak)" ($leak -eq 0 -and @(Select-String -LiteralPath (Join-Path $swk '.state/leases.jsonl') -Pattern "lanes-test-$PID" -ErrorAction SilentlyContinue).Count)
# K92: each emulator's RAM row is named by its own -port's lane (the filter's $Matches named all three "phone Falcon")
$k = New-TestKit swarm-ram; Set-JsonFile (Join-Path $k 'skills/phoney/swarm.config.json') @{ lanes = @(@{ name = 'Falcon'; port = 5556 }, @{ name = 'Kestrel'; port = 5558 }, @{ name = 'Osprey'; port = 5560 }) }
$ram = Invoke-PsTest swarm-ram @'
. $args[0]; foreach ($a in @(Get-ChildItem $args[1] -Filter '*.ps1')) { . $a.FullName }
function Get-KitSweepProcs { foreach ($pt in 5560, 5558, 5556, 5562) { [pscustomobject]@{ Id = $pt; ParentId = 1; Name = 'emulator.exe'; CommandLine = "emulator.exe -avd Heron -port $pt"; WorkingSet = 1GB; Created = Get-Date } } }
$now = Get-Date; (@(Get-KitSuperviseGuardResources) | Where-Object { "$($_.name)" -like 'phone *' } | ForEach-Object { "$($_.name)=$($_.pid)" }) -join ','
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Join-Path $k 'skills/bossy/adapters'))
Expect "K92: RAM rows name each emulator by its own port's lane, else its AVD, never the serial ($(@($ram) -join ' '))" ((@($ram) -join ' ') -match 'phone Osprey=5560,phone Kestrel=5558,phone Falcon=5556,phone Heron=5562')
# N3 phone lane alias map: lane-<nn> and an old bird name = the nn-th lane; a lane's own name as is; unknown as given
$pla = Invoke-PsTest swarm-alias @'
. $args[0]; $fa = [System.Management.Automation.Language.Parser]::ParseFile($args[1], [ref]$null, [ref]$null).Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Resolve-PhoneLane' }, $true)
. ([scriptblock]::Create($fa.Extent.Text)); function Get-SwarmConfig { [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'lane-01' }, [pscustomobject]@{ name = 'Pixel B' }) } }
(@('lane-02', 'Kestrel', 'lane-01', 'Falcon', 'lane-07', 'x') | ForEach-Object { Resolve-PhoneLane $_ }) -join ','
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Join-Path $src 'skills/phoney/phoney.ps1'))
Expect "phoney -Lane alias: lane-02 / Kestrel -> the 2nd lane, Falcon -> lane-01, unknown kept ($pla)" ("$pla".Trim() -eq 'Pixel B,Pixel B,lane-01,lane-01,lane-07,x')
# pokey.ps1 ui (adapters/ui-android.ps1): a tap that finds nothing and a wait that times out exit 1 (fake adb serves one screen)
$k = New-TestKit swarm-qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; & $J @{ devices = @{ type = 'android' } } (Join-Path $k 'skills/crafty/kit.local.json')   # devices.type default: none
foreach ($f in 'skills/pokey/adapters/ui-android.ps1', 'skills/crafty/adapters/android-sdk.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $k (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }   # Get-AndroidSdk lives in android-sdk.ps1
$null = Px $Q ui bogus 2>&1; $uc = $LASTEXITCODE
$ud = Join-Path (Kd) 'ui'; New-Item -ItemType Directory -Force "$ud/platform-tools" | Out-Null
Set-Content "$ud/s.xml" '<hierarchy><node text="Hello" resource-id="a:id/h" class="x" bounds="[0,0][10,10]"/></hierarchy>'
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`nif `"%1`"==`"pull`" copy /y `"$ud\s.xml`" `"%3`" >nul`r`nexit /b 0" -Encoding ascii
Set-Content "$ud/u.ps1" '$a = @($args); Set-Item Env:CLAUDE_RUNTIME "$($a[1])/rt"; $env:ANDROID_HOME = $a[1]; . $a[0]; function Get-ExeName($n) { "$n.cmd" }; Invoke-Ui "$($a[2])" "$($a[3])" "$($a[4])"'
$ut = @(foreach ($a in @(@('tap', 'Hello'), @('tap', 'Nope'), @('wait', 'Nope', '1'))) { $null = Px "$ud/u.ps1" $Q $ud @a 2>&1; $LASTEXITCODE })
Expect "ui: found 0, NOT FOUND 1, wait TIMEOUT 1; unknown action 2 ($($ut -join ','),$uc)" (($ut -join ',') -eq '0,1,1' -and $uc -eq 2)
# retro 2026-11-19 (92 failed dumps): a pull that fails once is retried; no ui.xml after 3 tries exits 1
$env:KIT_PARAM_PHONE_UIDUMPRETRYMS = '10'; $adbOk = Get-Content "$ud/platform-tools/adb.cmd" -Raw
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`nif not `"%1`"==`"pull`" exit /b 0`r`nif not exist `"$ud\once`" ( echo.>`"$ud\once`" & exit /b 1 )`r`ncopy /y `"$ud\s.xml`" `"%3`" >nul`r`nexit /b 0" -Encoding ascii
$d1 = Px "$ud/u.ps1" $Q $ud dump 2>&1 | Out-String; $dc1 = $LASTEXITCODE
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`nexit /b 0" -Encoding ascii
$d2 = Px "$ud/u.ps1" $Q $ud dump 2>&1 | Out-String; $dc2 = $LASTEXITCODE
Set-Content "$ud/platform-tools/adb.cmd" $adbOk -NoNewline -Encoding ascii; $env:KIT_PARAM_PHONE_UIDUMPRETRYMS = $null
Expect "ui dump: one failed pull retried (exit $dc1), 3 failed tries exit 1 ($dc2)" ($dc1 -eq 0 -and $d1 -match 'Hello @\(5,5\)' -and $dc2 -eq 1 -and $d2 -match 'failed 3 times')
# ui login (owner 2026-11-21): app.steps type the stored login (user, password, tenant) via adb; the password reaches adb only, never stdout; an optional field not on screen is skipped
Set-Content "$ud/s.xml" '<hierarchy><node text="" resource-id="username" class="android.widget.EditText" bounds="[0,0][10,10]"/><node text="" resource-id="password" class="android.widget.EditText" bounds="[0,20][10,30]"/><node text="Log in" resource-id="login-button" class="x" bounds="[0,40][10,50]"/></hierarchy>'
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`necho %*>>`"$ud\adb.log`"`r`nif `"%1`"==`"pull`" copy /y `"$ud\s.xml`" `"%3`" >nul`r`nexit /b 0" -Encoding ascii
& $J @{ targets = @{ tu = @{ api = 'http://127.0.0.1:9'; defaultTenant = 'acme'; users = @{ 'qa-drv' = 'qa-drv', 'Pw-x7Kq2_LongEnough9' }; created = @{ 'qa-drv' = @{ tenant = 't2' } } } } } (Join-Path $k 'skills/pokey/targets.local.json') 6
& $J @{ devices = @{ type = 'android' }; qa = @{ userRecipes = @{ r1 = @{ targets = '^tu$'; app = @{ steps = @(@{ into = 'username'; text = '{user}' }, @{ into = 'password'; text = '{pass}' }, @{ into = 'client-id'; text = '{tenant}'; optional = $true }, @{ tap = 'login-button' }) } } } } } (Join-Path $k 'skills/crafty/kit.local.json') 8
Set-Content "$ud/l.ps1" '$a = @($args); Set-Item Env:CLAUDE_RUNTIME "$($a[1])/rt"; $env:ANDROID_HOME = $a[1]; . $a[0]; function Get-ExeName($n) { "$n.cmd" }; Invoke-UiLogin -Target tu -As qa-drv -Serial emulator-5554'
$ul = Px "$ud/l.ps1" $Q $ud 2>&1 | Out-String; $ulc = $LASTEXITCODE; $ulog = Get-Content "$ud/adb.log" -Raw
Expect "ui login: user + password typed via adb, client-id skipped (optional, not on screen), button tapped; stdout has no password ($ulc)" ($ulc -eq 0 -and $ulog -match 'input text qa-drv' -and $ulog -match 'input text Pw-x7Kq2_LongEnough9' -and $ulog -match 'KEYCODE_DEL' -and $ul -match 'typed #password \(hidden\)' -and $ul -match 'skipped #client-id' -and $ul -match "tapped #login-button" -and $ul -match "tenant 't2'" -and $ul -notmatch 'Pw-x7Kq2')
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
$k = New-TestKit swarm-gpu; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force   # New-TestKit copies no phoney files
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
Set-Content '$gt/adb.cmd' "@echo off``r``necho %*>> $gt\adb.txt``r``necho 1``r``nexit /b 0" -Encoding ascii; Set-Content '$gt/emu.cmd' "@echo off``r``necho started> $gt\started.txt" -Encoding ascii; Set-Content '$gt/noop.ps1' 'exit 0'; `$KitCmd.swarm = '$gt/noop.ps1'; `$KitCmd.dev = '$gt/noop.ps1'
`$script:SwarmCfg | Add-Member -Force avd ([pscustomobject]@{ gpu = 'swiftshader' })
`$null = Invoke-Up -Lanes G1 -Mode None -Headless 3>&1; for (`$i = 0; `$i -lt 20 -and -not (Test-Path '$gt/started.txt'); `$i++) { Start-Sleep -Milliseconds 250 }
"software:`$(Test-Path '$gt/started.txt')"
# a play lane (lanes[].caps): up turns its Play Store back on; a plain lane's boot never touches it
`$plainBoot = @(Get-Content '$gt/adb.txt' | Where-Object { `$_ -match 'pm enable com.android.vending' }).Count; `$script:SwarmCfg.lanes[0] | Add-Member caps @('play')
`$null = Invoke-Up -Lanes G1 -Mode None -Headless 3>&1
"store:`$(`$plainBoot -eq 0 -and @(Get-Content '$gt/adb.txt' | Where-Object { `$_ -match '-s emulator-5590 shell pm enable com.android.vending' }).Count -eq 1)"
"@
Stop-Process -Id $vis.Id -Force -ErrorAction SilentlyContinue
Expect-Each $gu 'swarm gpu: another kind holding the GPU -> no lane boot, a software-rendered lane boots, a play lane gets its store on: #' @('blocked', 'software', 'store') -Show 8
Remove-Item $gt -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k
# defaults: app.kind native; AVD neutral < kit.local.json devices.avd < swarm.config.json avd; installs by argv, no Invoke-Expression
$k = New-TestKit swarm-defaults; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force; Copy-Item (Join-Path $src 'skills/crafty/adapters/android-sdk.ps1') (New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters'))
& $J @{ devices = @{ avd = @{ device = 'd9' } } } (Join-Path $k 'skills/crafty/kit.local.json')
& $J @{ lanes = @(); app = @{ package = 'x' }; avd = @{ api = 'a99' } } (Join-Path $k 'skills/phoney/swarm.config.json')
$sd = Invoke-PsTest 'swarm-defaults' @"
Set-Item Env:CLAUDE_RUNTIME '$(Join-Path (Kd) 'sd-rt')'; . '$(Join-Path $k 'skills/phoney/phoney.ps1')'
`$c = Get-SwarmConfig
"defaults:`$(`$c.app.kind) `$(`$c.app.buildTask) `$(`$c.avd.device) `$(`$c.avd.api) `$(`$c.avd.tag)"
"argv:`$((Split-KitCommand 'yarn install --frozen-lockfile' @{}) -join '|')"
"@
$noIex = @('phoney.ps1', 'swarm-ios.ps1' | Where-Object { (Get-Content (Join-Path $src "skills/phoney/$_") -Raw) -match 'Invoke-Expression' })
Expect "phoney defaults: kind native (assembleDebug), devices.avd under swarm avd, neutral tag; argv installs, no Invoke-Expression ($sd $noIex)" ("$sd" -match 'defaults:native assembleDebug d9 a99 google_apis' -and "$sd" -match 'argv:yarn\|install\|--frozen-lockfile' -and -not $noIex.Count)
Remove-TestKit $k

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
`$e = @(ConvertTo-LaneEvents -InputLines `$ge -UiEvents `$ui -Uptime 99 -At 1700000000000 -Size 1080, 2400 -Max 32767, 32767)
"parsed:`$((`$e.action -join ',') -eq 'click,swipe,type' -and `$e[0].text -eq 'Save' -and `$e[0].at -eq 1700000001000 -and `$e[0].target -eq '270,1200' -and `$e[2].text -eq 'QA-123' -and `$e[2].at -eq 1700000005000 -and `$e[1].target -match '-> 270,600')"
"@
Expect-Each $ev 'swarm events: #' @('off', 'parsed') -Show 6
Remove-TestKit $k
# reaper: supervise -AutoFix, no phoney call, reclaims the lane of a holder that left the board (its holder pid = the live session
# process) and stops it (emu kill); leases.jsonl gets one reclaim and one down line; phoney.ps1 status shows last used
$k = New-TestKit swarm-reap; Copy-Item (Join-Path $src 'skills/phoney') (Join-Path $k 'skills') -Recurse -Force; & $J @{ devices = @{ type = 'android' } } (Join-Path $k 'skills/crafty/kit.local.json')
$rp = Join-Path (Kd) 'reap'; New-Item -ItemType Directory -Force "$rp/platform-tools", "$k/skills/crafty/adapters" | Out-Null; $ab = "$rp/platform-tools/adb.cmd"
Set-Content "$k/skills/crafty/adapters/android-sdk.ps1" "function Get-AndroidSdk { '$rp' }; function Get-ExeName([string]`$Name) { `"`$Name.cmd`" }"   # the fake adb, never the machine's
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
# Quick Boot: the first close saves the golden snapshot, later ones never; a cold boot or a newer emulator / AVD config saves again
foreach ($snapScript in 'phoney.ps1', 'swarm-ios.ps1') {
  $snapRes = & { $rt = Join-Path ([IO.Path]::GetTempPath()) "snp-$PID"; Set-Item Env:CLAUDE_RUNTIME $rt; . (Join-Path $src "skills/phoney/$snapScript")
    $av = Join-Path $rt 'avd'; $sd = New-Item -ItemType Directory -Force (Join-Path $av 'L1.avd/snapshots/default_boot'); $emu = Join-Path $rt 'emulator.exe'; $ini = Join-Path $av 'L1.avd/config.ini'
    foreach ($f in $emu, $ini) { Set-Content $f 'x'; (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-2) }
    $c = [pscustomobject]@{ avdDir = $av; emulator = $emu }; $none = "$(SnapshotFlag $c L1 $false)"
    Set-Content (Join-Path $sd 'snapshot.pb') 'g'; $golden = "$(SnapshotFlag $c L1 $false)"; $cold = "$(SnapshotFlag $c L1 $true)"
    (Get-Item $emu).LastWriteTime = Get-Date; $upgraded = "$(SnapshotFlag $c L1 $false)"
    Remove-Item $rt -Recurse -Force -ErrorAction SilentlyContinue; "$none|$golden|$cold|$upgraded" }
  Expect "swarm up ($snapScript): -no-snapshot-save only with a golden snapshot newer than the emulator and the AVD config, never on a cold boot ($snapRes)" ($snapRes -eq '|-no-snapshot-save||')
}
# ---- was android-swarm-2.tests.ps1 (its own test kit)
$capScript = @'
$ErrorActionPreference = 'Stop'
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$capAdb = "$tmp/adb.cmd"; Set-Content $capAdb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device& echo emulator-5562	device& exit /b 0)`r`necho Success" -Encoding ascii
$capDir = Get-KitPath phones -Create
# no -Cap takes the plain lane although the play lane is listed first, -Cap play takes the play lane, an unknown one is refused
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L2'; port = 5562; caps = @('play') }, [pscustomobject]@{ name = 'L1'; port = 5560 }); adb = $capAdb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
# the queue: D waits for the leased play lane as a waiter for that lane, so a later plain agent still gets the free plain lane
@{ agent = 'manual'; lane = 'L2'; serial = 'emulator-5562'; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content "$capDir/L2.json"
function Wait-KitPoll { if ($script:capPoll) { return (& $script:capPoll) }; $script:capWaitCap = "$((Get-Content "$script:capDir/wait/D.json" -Raw | ConvertFrom-Json).cap)|$(@(Invoke-Phone status) -match '^waiting: D for L2 \(cap play\)')"; $script:capWait = (Get-Content "$script:capDir/wait/D.json" -Raw | ConvertFrom-Json).lane; $script:capPlain =(Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'C') | Select-Object -Last 1 | ConvertFrom-Json).lane; Remove-Item "$script:capDir/L2.json" -Force -ErrorAction SilentlyContinue }
if ($args[2] -eq 'ios') { function Start-Sleep { Wait-KitPoll 0 } }   # its wait loop sleeps by the cmdlet
$capPlay = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'D', '-Cap', 'play') | Select-Object -Last 1 | ConvertFrom-Json
$capNone = try { $null = Invoke-Phone acquire -Agent E -Cap nfc; 'leased' } catch { "$_" }
$capMiss = try { $null = Invoke-Phone acquire -Agent E -Lane L1 -Cap play; 'leased' } catch { "$_" }
$capStatus = @(Invoke-Phone status | Where-Object { $_ -match 'caps play' })
"acquire:$($capWait -eq 'L2' -and $capPlain -eq 'L1' -and $capPlay.lane -eq 'L2' -and "$($capPlay.caps)" -eq 'play' -and $capNone -match 'no lane with capability nfc' -and $capMiss -match 'no lane L1 with capability play' -and $capStatus.Count -eq 1 -and $capStatus[0] -match '^L2 ')"
# status and the acquire JSON say what each lane offers and what slim turned off; a waiter shows its capability
$capAll = @(Invoke-Phone status)
"limits:$(@($capAll -match '^L2 .* play: on$').Count -eq 1 -and @($capAll -match '^L1 .* play: off \(slim\)$').Count -eq 1 -and @($capAll -match '^every lane: camera .*not supported: .*NFC').Count -eq 1 -and $capPlay.limits.play -eq 'on' -and $capPlay.limits.unsupported -match 'Bluetooth printer' -and $capWaitCap -match '^play\|waiting: D for L2 \(cap play\)')"
# C holds the plain lane and asks -Cap play: it gets the play lane, never its plain one back
Remove-Item "$capDir/L2.json" -Force; $capHold = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'C', '-Cap', 'play') | Select-Object -Last 1 | ConvertFrom-Json
"holder:$($capHold.lane -eq 'L2' -and (Get-Content "$capDir/L1.json" -Raw | ConvertFrom-Json).agent -eq 'C')"
# the play lane runs, the plain lane is down: a plain acquire takes the running one (no second boot)
Remove-Item "$capDir/L1.json", "$capDir/L2.json" -Force
$capAdb2 = "$tmp/adb2.cmd"; Set-Content $capAdb2 "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5562	device& exit /b 0)`r`necho Success" -Encoding ascii; $script:SwarmCfg.adb = $capAdb2
$capUp = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'F') | Select-Object -Last 1 | ConvertFrom-Json
"running:$($capUp.lane -eq 'L2' -and $capUp.limits.play -eq 'on' -and -not (Test-Path "$capDir/L1.json"))"
# two play lanes, both leased: the -Cap waiter names both (no any-lane waiter), so a later plain acquire still gets the free plain lane
Remove-Item "$capDir/L2.json" -Force
$capAdb4 = "$tmp/adb4.cmd"; Set-Content $capAdb4 "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device& echo emulator-5564	device& echo emulator-5566	device& exit /b 0)`r`necho Success" -Encoding ascii
$capLanes0 = $script:SwarmCfg.lanes; $script:SwarmCfg.lanes = @([pscustomobject]@{ name = 'P1'; port = 5564; caps = @('play') }, [pscustomobject]@{ name = 'P2'; port = 5566; caps = @('play') }, [pscustomobject]@{ name = 'L1'; port = 5560 }); $script:SwarmCfg.adb = $capAdb4
foreach ($capBusy in 'P1', 'P2') { @{ agent = 'manual'; lane = $capBusy; serial = 'x'; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content "$capDir/$capBusy.json" }
$script:capPoll = { $script:capPoll = { throw 'the plain acquire waited behind the -Cap waiter' }
  $capW2 = Get-Content "$script:capDir/wait/G.json" -Raw | ConvertFrom-Json; $capW2.since = (Get-Date).AddSeconds(-5).ToString('s'); $capW2 | ConvertTo-Json | Set-Content "$script:capDir/wait/G.json"; $script:capTwo = "$(@($capW2.lanes) -join ',')|$($capW2.lane)|$(Test-LaneWaiter $capW2 @('L1'))|$(Test-LaneWaiter $capW2 @('P2'))|$(@(Invoke-Phone status) -match '^waiting: G for P1 / P2 \(cap play\)')"
  $script:capTwoPlain = (Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'H') | Select-Object -Last 1 | ConvertFrom-Json).lane; Remove-Item "$script:capDir/P2.json" -Force; $script:capPoll = { throw 'G not served after P2 freed' } }
$capTwoGot = try { (Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'G', '-Cap', 'play') | Select-Object -Last 1 | ConvertFrom-Json).lane } catch { "$_" }
"two:$($capTwo -match '^P1,P2\|\|False\|True\|waiting: G for P1 / P2 \(cap play\)' -and $capTwoPlain -eq 'L1' -and $capTwoGot -eq 'P2')"; $script:SwarmCfg.lanes = $capLanes0
if ($args[2] -eq 'ios') { $script:SwarmCfg | Add-Member -Force kind 'ios'; "sim:$((Get-LaneLimits $null).play -match 'Simulator has no Play Store')"; return }
# slim keeps the Play Store on the play lane only
$capAdb3 = "$tmp/adb3.cmd"; Set-Content $capAdb3 "@echo off`r`necho %*>> `"$tmp\sh.txt`"`r`necho package:com.android.vending`r`necho package:com.google.android.youtube`r`necho disabled" -Encoding ascii; $script:SwarmCfg.adb = $capAdb3
$null = Invoke-Slim -Serial emulator-5560; $null = Invoke-Slim -Serial emulator-5562; $slimLog = @(Get-Content "$tmp/sh.txt" | Where-Object { $_ -match 'disable-user' })
"slim:$(@($slimLog | Where-Object { $_ -match 'com\.android\.vending' }).Count -eq 1 -and "$($slimLog -match 'com\.android\.vending')" -match 'emulator-5560' -and @($slimLog | Where-Object { $_ -match 'youtube' }).Count -eq 2)"
# a play lane's AVD gets a Play Store image whatever avd.tag says; a plain lane keeps avd.tag
$capSdk = "$tmp/sdk"; New-Item -ItemType Directory -Force "$capSdk/platform-tools", "$capSdk/system-images/a35/g/arm64-v8a", "$capSdk/system-images/a35/google_apis_playstore/arm64-v8a" | Out-Null; Copy-Item $capAdb "$capSdk/platform-tools"
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'A1'; port = 5570 }, [pscustomobject]@{ name = 'A2'; port = 5572; caps = @('play') }); adb = "$capSdk/platform-tools/adb.cmd"; avdDir = "$tmp/avd"; apkDir = $tmp; out = $tmp; avd = [pscustomobject]@{ abi = 'arm64-v8a'; api = 'a35'; device = 'p8'; tag = 'g' } }
$null = Invoke-KitVerb Invoke-Avd @('create', '-NoBoot'); $iniPlain = Get-Content "$tmp/avd/A1.avd/config.ini" -Raw; $iniPlay = Get-Content "$tmp/avd/A2.avd/config.ini" -Raw
"avd:$($iniPlay -match 'PlayStore.enabled=true' -and $iniPlay -match 'tag\.id=google_apis_playstore' -and $iniPlay -match 'a35\\google_apis_playstore\\arm64-v8a' -and $iniPlain -match 'PlayStore.enabled=false' -and $iniPlain -match 'tag\.id=g\r?\n')"
'@
$TestKitFiles = @('skills/bossy/adapters/waits.ps1'); $capKit = New-TestKit swarm-caps; foreach ($f in 'skills/phoney/phoney.ps1', 'skills/phoney/adapters/app-kinds.ps1', 'skills/phoney/adapters/arrange.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $capKit (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }
$capFile = "$([IO.Path]::GetTempPath())swarm-caps-$PID"; Set-Content "$capFile.ps1" $capScript
$capRes = @(Px "$capFile.ps1" (Join-Path $capKit 'skills/phoney/phoney.ps1') $capFile 2>&1)
Expect-Each $capRes 'phoney lane caps: plain lanes first and -Cap play picks the play lane (an unknown capability refused, status shows it); slim keeps its Play Store; its AVD gets a Play Store image; status / acquire print each lane''s limits (play: off (slim)) and a waiter''s cap; a plain-lane holder asking -Cap play gets the play lane; a running play lane beats a down plain one; 2 play lanes: the -Cap waiter names both: #' @('acquire', 'limits', 'holder', 'running', 'two', 'slim', 'avd') -Show 12
# the iOS variant: the same lane choice and queue
Copy-Item (Join-Path $src 'skills/phoney/swarm-ios.ps1') (Join-Path $capKit 'skills/phoney')
$capIos = @(Px "$capFile.ps1" (Join-Path $capKit 'skills/phoney/swarm-ios.ps1') "$capFile-ios" 'ios' 2>&1)
Expect-Each $capIos 'swarm-ios lane caps: the same -Cap lane choice, queue, refusals, limits (a Simulator: no Play Store) and waiter caps: #' @('acquire', 'limits', 'holder', 'running', 'two', 'sim') -Show 12
# bossy wait lists: a -Cap waiter shows its capability and every lane that offers it (supervise WAIT OVER CAP, status wait rows)
$capO = Join-Path $capKit 'skills/bossy/bossy.ps1'
$capWaits = & { . $capO; $capNow = Get-Date; $capPd = Get-KitPath phones -Create; Set-JsonFile (Join-Path $capPd 'P1.json') @{ lane = 'P1'; agent = 'test:T2' }
  Set-JsonFile (Join-Path $capPd 'wait/test_T5.json') @{ agent = 'test:T5'; lane = ''; lanes = @('P1', 'P2'); cap = @('play'); since = $capNow.AddMinutes(-30).ToString('o') }
  "$(@(Get-KitWaitsOverCap $capNow 20 | ForEach-Object { "$($_.why)/$($_.holder)" }) -join ',')|$(@(Get-KitStatusWaitResources | Where-Object agent -eq 'test:T5').why)" }
Expect "bossy wait lists: a -Cap waiter shows its capability and its lanes, held by their holders ($capWaits)" ($capWaits -eq 'phone lane P1 / P2 (cap play)/test:T2 (P1)|phone lane (cap play)')
# decide ask (owner 2026-11-26): an ask that blames a lane or the env is refused until -Diagnostic says what was checked and names an existing ENV-FIX
$capFix = if ((Px $capO decide ask -Kind envfix -Run w1 -Agent X1 -Item A6 -Question 'the lane cannot install the module' | Out-String) -match 'ENV-FIX (\S+) pending') { $Matches[1] }
$capAsk = @('decide', 'ask', '-Run', 'w1', '-Agent', 'X1', '-Item', 'A7', '-Context', 'today: the scan check stops at the module download', '-Options', 'A: skip — the scan stays untested', 'B: wait — the item waits', '-Recommend', 'B')
$capQ = 'The lane cannot install the scanner module: skip the scan check?'
$capB1 = Px $capO @capAsk -Question $capQ | Out-String; $capC1 = $LASTEXITCODE
$null = Px $capO @capAsk -Question $capQ -Diagnostic 'store package disabled, status says play off; envfix-none-such'; $capC2 = $LASTEXITCODE
$null = Px $capO @capAsk -Question $capQ -Diagnostic "checked $capFix"; $capC3 = $LASTEXITCODE
$null = Px $capO @capAsk -Question 'Scans are not supported on the emulator: waive them?'; $capC5 = $LASTEXITCODE
$capB4 = Px $capO @capAsk -Question $capQ -Diagnostic "store package disabled, status says play off, no play lane; $capFix" | Out-String
$capD4 = @(Px $capO decide list -Json | ConvertFrom-Json | Where-Object { $_.item -eq 'A7' })
$capWords = @('could not install', 'couldn''t install', 'won''t boot with', 'fails to install', 'is not able to install', 'does not work with') | ForEach-Object { $null = Px $capO @capAsk -Question "The lane $_ the scanner module: skip it?"; $LASTEXITCODE }
$capB6 = Px $capO decide ask -Run w1 -Agent X1 -Item A8 -Context 'today: closed lanes are hidden, drivers cannot see a note in the lane list' -Question 'The lane list hides closed lanes: show them?' -Options 'A: show — more rows','B: hide — as today' -Recommend B | Out-String
Expect "decide ask: an env-blamed ask is refused (2) without -Diagnostic, with an unknown ENV-FIX id or a 2-word one (could not, won't, fails to ... too: $capWords); asked once it says what was checked + its ENV-FIX; an ENV-FIX and a product ask about lanes pass ($capFix $capC1 $capC2 $capC3 $capC5)" ($capFix -and "$capWords" -eq '2 2 2 2 2 2' -and $capC1 -eq 2 -and $capB1 -match 'blames the env' -and $capB1 -match '-Kind envfix' -and $capC2 -eq 2 -and $capC3 -eq 2 -and $capC5 -eq 2 -and
  $capB4 -match 'DECISION \S+ pending' -and $capD4.Count -eq 1 -and $capD4[0].question -match 'checked: store package disabled' -and $capB6 -match 'DECISION \S+ pending')
Remove-Item "$capFile.ps1", $capFile, "$capFile-ios" -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $capKit
Complete-Tests
