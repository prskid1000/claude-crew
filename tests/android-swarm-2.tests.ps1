#Requires -Version 7
<#
android-swarm-2.tests.ps1: phoney.ps1 lane capabilities (android-swarm.tests.ps1 is at its cap): lanes[].caps, acquire -Cap, slim and
the AVD image of a play lane.
Usage: pwsh -NoProfile -File <kit>/tests/android-swarm-2.tests.ps1 (or tests/kit-tests.ps1 -Area android-swarm-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$capScript = @'
$ErrorActionPreference = 'Stop'
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$capAdb = "$tmp/adb.cmd"; Set-Content $capAdb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device& echo emulator-5562	device& exit /b 0)`r`necho Success" -Encoding ascii
$P = Get-KitPath phones -Create
# no -Cap takes the plain lane although the play lane is listed first, -Cap play takes the play lane, an unknown one is refused
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L2'; port = 5562; caps = @('play') }, [pscustomobject]@{ name = 'L1'; port = 5560 }); adb = $capAdb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
$capPlain = (Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'C') | Select-Object -Last 1 | ConvertFrom-Json).lane
$capPlay = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'D', '-Cap', 'play') | Select-Object -Last 1 | ConvertFrom-Json
$capNone = try { $null = Invoke-Phone acquire -Agent E -Cap nfc; 'leased' } catch { "$_" }
$capStatus = @(Invoke-Phone status | Where-Object { $_ -match 'caps play' })
"acquire:$($capPlain -eq 'L1' -and $capPlay.lane -eq 'L2' -and "$($capPlay.caps)" -eq 'play' -and $capNone -match 'no lane with capability nfc' -and $capStatus.Count -eq 1 -and $capStatus[0] -match '^L2 ')"
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
$capKit = New-TestKit swarm-caps; foreach ($f in 'skills/phoney/phoney.ps1', 'skills/phoney/adapters/app-kinds.ps1', 'skills/phoney/adapters/arrange.ps1') { $d = New-Item -ItemType Directory -Force (Join-Path $capKit (Split-Path $f)); Copy-Item (Join-Path $src $f) $d }
$capFile = "$([IO.Path]::GetTempPath())swarm-caps-$PID"; Set-Content "$capFile.ps1" $capScript
$capRes = @(Px "$capFile.ps1" (Join-Path $capKit 'skills/phoney/phoney.ps1') $capFile 2>&1)
Expect-Each $capRes 'phoney lane caps: plain lanes first and -Cap play picks the play lane (an unknown capability refused, status shows it); slim keeps its Play Store; its AVD gets a Play Store image: #' @('acquire', 'slim', 'avd') -Show 8
Remove-Item "$capFile.ps1", $capFile -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $capKit
# the iOS variant filters lanes by the same flag
$capIos = Get-Content (Join-Path $src 'skills/phoney/swarm-ios.ps1') -Raw
Expect 'swarm-ios acquire: -Cap keeps only the lanes that offer each capability' ($capIos -match '\[string\[\]\]\$Cap' -and $capIos -match 'no lane\$\(if \(\$Lane\)[^\n]*with capability')
Complete-Tests
