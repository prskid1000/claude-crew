#Requires -Version 7
<#
android-swarm-2.tests.ps1: phoney.ps1 lane capabilities (android-swarm.tests.ps1 is at its cap): lanes[].caps, acquire -Cap, slim and
the AVD image of a play lane; bossy: a -Cap waiter in the wait lists, decide ask's env-blame guard.
Usage: pwsh -NoProfile -File <kit>/tests/android-swarm-2.tests.ps1 (or tests/kit-tests.ps1 -Area android-swarm-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
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
$script:capPoll = { $script:capPoll = { throw 'the plain acquire waited behind the -Cap waiter' }; [Threading.Thread]::Sleep(1100)
  $capW2 = Get-Content "$script:capDir/wait/G.json" -Raw | ConvertFrom-Json; $script:capTwo = "$(@($capW2.lanes) -join ',')|$($capW2.lane)|$(Test-LaneWaiter $capW2 @('L1'))|$(Test-LaneWaiter $capW2 @('P2'))|$(@(Invoke-Phone status) -match '^waiting: G for P1 / P2 \(cap play\)')"
  $script:capTwoPlain = (Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'H') | Select-Object -Last 1 | ConvertFrom-Json).lane; Remove-Item "$script:capDir/P2.json" -Force; $script:capPoll = { } }
$capTwoGot = try { (Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'G', '-Cap', 'play') | Select-Object -Last 1 | ConvertFrom-Json).lane } catch { "$_" }
"two:$($capTwo -match '^P1,P2\|\|False\|True\|waiting: G for P1 / P2 \(cap play\)' -and $capTwoPlain -eq 'L1' -and $capTwoGot -eq 'P2')"; $script:SwarmCfg.lanes = $capLanes0
if ($args[2] -eq 'ios') { return }
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
Expect-Each $capIos 'swarm-ios lane caps: the same -Cap lane choice, queue, refusals, limits and waiter caps: #' @('acquire', 'limits', 'holder', 'running', 'two') -Show 12
# bossy wait lists: a -Cap waiter shows its capability and every lane that offers it (supervise WAIT OVER CAP, status wait rows)
$capO = Join-Path $capKit 'skills/bossy/bossy.ps1'
$capWaits = & { . $capO; $capNow = Get-Date; $capPd = Get-KitPath phones -Create; Set-JsonFile (Join-Path $capPd 'P1.json') @{ lane = 'P1'; agent = 'test:T2' }
  Set-JsonFile (Join-Path $capPd 'wait/test_T5.json') @{ agent = 'test:T5'; lane = ''; lanes = @('P1', 'P2'); cap = @('play'); since = $capNow.AddMinutes(-30).ToString('o') }
  "$(@(Get-KitWaitsOverCap $capNow 20 | ForEach-Object { "$($_.why)/$($_.holder)" }) -join ',')|$(@(Get-KitStatusWaitResources | Where-Object agent -eq 'test:T5').why)" }
Expect "bossy wait lists: a -Cap waiter shows its capability and its lanes, held by their holders ($capWaits)" ($capWaits -eq 'phone lane P1 / P2 (cap play)/test:T2 (P1)|phone lane (cap play)')
# decide ask (owner 2026-11-26): an ask that blames a lane or the env is refused until -Diagnostic says what was checked and names an existing ENV-FIX
$capFix = if ((Px $capO decide ask -Kind envfix -Run w1 -Agent X1 -Item A6 -Question 'the store is off on the lane' | Out-String) -match 'ENV-FIX (\S+) pending') { $Matches[1] }
$capAsk = @('decide', 'ask', '-Run', 'w1', '-Agent', 'X1', '-Item', 'A7', '-Context', 'today: the scan check stops at the module download', '-Options', 'A: skip — the scan stays untested', 'B: wait — the item waits', '-Recommend', 'B')
$capQ = 'The lane cannot install the scanner module: skip the scan check?'
$capB1 = Px $capO @capAsk -Question $capQ | Out-String; $capC1 = $LASTEXITCODE
$null = Px $capO @capAsk -Question $capQ -Diagnostic 'store package disabled, status says play off; envfix-none-such'; $capC2 = $LASTEXITCODE
$null = Px $capO @capAsk -Question $capQ -Diagnostic "checked $capFix"; $capC3 = $LASTEXITCODE
$null = Px $capO @capAsk -Question 'Scans are not supported on the emulator: waive them?'; $capC5 = $LASTEXITCODE
$capB4 = Px $capO @capAsk -Question $capQ -Diagnostic "store package disabled, status says play off, no play lane; $capFix" | Out-String
$capD4 = @(Px $capO decide list -Json | ConvertFrom-Json | Where-Object { $_.item -eq 'A7' })
$capB6 = Px $capO decide ask -Run w1 -Agent X1 -Item A8 -Context 'today: totals round up' -Question 'Keep the rounding?' -Options 'A: keep — no change','B: exact — totals change' -Recommend A | Out-String
Expect "decide ask: an env-blamed ask is refused (2) without -Diagnostic, with an unknown ENV-FIX id or a 2-word one; asked once it says what was checked + its ENV-FIX; a product ask passes ($capFix $capC1 $capC2 $capC3 $capC5)" ($capFix -and $capC1 -eq 2 -and $capB1 -match 'blames the env' -and $capB1 -match '-Kind envfix' -and $capC2 -eq 2 -and $capC3 -eq 2 -and $capC5 -eq 2 -and
  $capB4 -match 'DECISION \S+ pending' -and $capD4.Count -eq 1 -and $capD4[0].question -match 'checked: store package disabled' -and $capB6 -match 'DECISION \S+ pending')
Remove-Item "$capFile.ps1", $capFile, "$capFile-ios" -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $capKit
Complete-Tests
