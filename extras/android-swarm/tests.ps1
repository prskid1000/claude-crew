#Requires -Version 7
<#
tests.ps1 (extra android-swarm): swarm.ps1 phone lanes (acquire, reverse, release, AVD, build, lanes on demand), qa.ps1 ui on a fake
adb, the deploys[] laneApk check. iOS: extra ios-simulator.
Usage: kittool.py extra test android-swarm (tests/kit-tests.ps1 -Area extras runs every installed extra).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kittool.py extra test passes the kit; else this file sits next to <kit>/tests/harness.ps1
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
"kinds:$($ini -match 'arch=arm64\s[\s\S]*a35\\g\\arm64-v8a' -and $ini -match 'PlayStore.enabled=false') $((Get-Content "$tmp/app.apk" -Raw) -match 'fb gradlew')"
'@
$sf = "$([IO.Path]::GetTempPath())swarm-test-$PID"; Set-Content "$sf.ps1" $swt
$res = @(Px "$sf.ps1" (Join-Path $src 'skills/android-swarm/swarm.ps1') $sf 2>&1)
foreach ($x in 'reclaim:True', 'reverse:True', 'release:True', 'kinds:True True') { Expect "swarm: $x" ($res -contains $x) }
Remove-Item "$sf.ps1", $sf -Recurse -Force -ErrorAction SilentlyContinue
# lease files: reads and writes under the file lock (an open reader made the rename fail)
$ss = & { $rt = Join-Path ([IO.Path]::GetTempPath()) "swl-$PID"; Set-Item Env:CLAUDE_RUNTIME $rt; . (Join-Path $src 'skills/android-swarm/swarm.ps1')
  foreach ($fn in (Get-Command Invoke-Phone).ScriptBlock.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Save-Json', 'Lease' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
  $dir = Join-Path $rt 'ph'; New-Item -ItemType Directory -Force $dir | Out-Null; Save-Json @{ agent = 'A' } "$dir/L1.json"
  Save-Json @{ agent = 'B' } "$dir/L1.json"; "$((Lease L1).agent)$(Test-Path "$dir/L1.json.lock")" }
Expect "swarm: lease reads and writes go through the file lock, released after ($ss)" ($ss -eq 'BFalse' -and (Get-Content (Join-Path $src 'skills/android-swarm/swarm.ps1') -Raw) -match 'function Lease\(\$name\) \{[^\n]*Invoke-KitLocked')
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
$res = @(Px "$lf2.ps1" (Join-Path $src 'skills/android-swarm/swarm.ps1') $lf2 2>&1)
Expect "swarm: lanes on demand, a waiting request takes a lane freed meanwhile, no extra boot ($(@($res | Where-Object { "$_" -match '^scale:' })))" ($res -contains 'scale:True')
Remove-Item "$lf2.ps1", $lf2 -Recurse -Force -ErrorAction SilentlyContinue
# qa.ps1 ui (adapters/ui_android.ps1): a tap that finds nothing and a wait that times out exit 1 (fake adb serves one screen)
$k = New-TestKit swarm-qa; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'
foreach ($f in 'skills/qa-kit/adapters/ui_android.ps1', 'skills/dev-kit/adapters/android_sdk.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $k (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }   # Get-AndroidSdk lives in android_sdk.ps1
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
Complete-Tests
