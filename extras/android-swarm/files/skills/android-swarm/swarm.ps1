<#
swarm.ps1: device lanes + the app under test (android-swarm SKILL.md). devices.type: android (emulators, default) | none
(verbs refuse; app checks NOT_TESTED) | ios (extra ios-simulator: this script forwards to swarm-ios.ps1).
  pwsh 7: & <kit>/skills/android-swarm/swarm.ps1 <verb> [args]
  acquire -Agent <id> [-Lane <name>] [-Holder <board code>] [-Apk local|<path>] [-Reverse <port>,..] [-NoInstall]   lease a phone
  ensure -Agent <id> · release -Agent <id> [-Keep] · status
  build [-AppDir <checkout>] [-Local] [-Shared]   apk/app.apk; -Local: release + cleartext apk/app-local.apk
  install [-Apk <path>] [-Serials <s>,..] [-Launch] · launch -Serial <s> [-Clear] [-Stop]
  avd list|create|reset [-Lanes <names>] [-Level cold|snapshots|wipe|recreate]
  up [-Lanes ..] [-ShowAll] · down [-Lanes ..] · slim -Serial <s>
In: swarm.config.json (lanes, app, avd), kit.local.json (devices.type, gate floor).
Out: text / JSON (acquire, ensure), APKs in <runtime>/cache/android-swarm.
Exit codes: 0 ok · 1 problem (no phone, boot / install / build failed, needs an extra) · 2 usage error.
Adapters (adapters/): app_kinds.ps1 (flutter, maui, capacitor, Expo prebuild), arrange.ps1 (arrange); extra ios-simulator.
Sections: L22 config · L102 phone · L300 build · L444 install · L470 launch · L482 avd · L568 up · L655 down · L684 slim
#>
#Requires -Version 7
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
foreach ($__adapter in Get-ChildItem (Join-Path $PSScriptRoot 'adapters') -Filter '*.ps1' -ErrorAction SilentlyContinue) { . $__adapter.FullName }
# ---- config: swarm.config.json
function Get-SwarmConfig {
  if ($script:SwarmCfg) { return $script:SwarmCfg }
  $here = $PSScriptRoot
  $f = Join-Path $here 'swarm.config.json'
  if (-not (Test-Path $f)) { throw "Missing $f - orch.ps1 setup -WriteLocal writes it; then set 'app'" }
  $c = Get-Content $f -Raw | ConvertFrom-Json
  if (-not $c.avdDir) { $c | Add-Member -Force avdDir $(if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { "$HOME/.android/avd" }) }
  $c | Add-Member -Force kind ([string](Get-KitSetting 'devices.type' 'android'))
  if (-not $c.app.kind) { $c.app | Add-Member -Force kind 'react-native' }
  if (-not $c.app.buildTask) { $c.app | Add-Member -Force buildTask $(if ($c.app.kind -in 'native', 'kmp') { 'assembleDebug' } else { 'assembleRelease' }) }
  if (-not $c.app.apkGlob) { $v = if ($c.app.buildTask -match 'Release') { 'release' } else { 'debug' }; $c.app | Add-Member -Force apkGlob "$(if ($c.app.kind -eq 'kmp') { 'composeApp' } else { 'app' })/build/outputs/apk/$v/*.apk" }
  # Gradle kinds (react-native, native, kmp) or app.buildCmd + app.artifact; other presets: adapters/app_kinds.ps1 (Set-AppKindPreset)
  if ($c.app.kind -notin 'react-native', 'native', 'kmp' -and -not ($c.app.buildCmd -and $c.app.artifact)) {
    if ($ext = Get-Command Set-AppKindPreset -ErrorAction SilentlyContinue) { & $ext $c.app } else { throw "app.kind $($c.app.kind) is an extra: run kittool.py extra add android-swarm" }
  }
  foreach ($k in @{ permissions = @(); localReverse = @(); localManifests = @('src/debugOptimized/AndroidManifest.xml', 'src/debug/AndroidManifest.xml') }.GetEnumerator()) { if (-not $c.app.($k.Key)) { $c.app | Add-Member -Force $k.Key $k.Value } }
  $sdk = Get-AndroidSdk
  $c | Add-Member -Force adb (Join-Path $sdk (Join-Path 'platform-tools' (Get-ExeName 'adb')))
  $c | Add-Member -Force emulator (Join-Path $sdk (Join-Path 'emulator' (Get-ExeName 'emulator')))
  $c | Add-Member -Force dir $here
  $out = if ($c.outDir) { [string]$c.outDir } else { Get-KitPath android-swarm }
  $apkDir = Join-Path $out 'apk'
  New-Item -ItemType Directory -Force $apkDir | Out-Null
  $c | Add-Member -Force out $out
  $c | Add-Member -Force apkDir $apkDir
  $c | Add-Member -Force appFile (Join-Path $apkDir 'app.apk')
  $abi = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64-v8a' } else { 'x86_64' }   # the host's own ABI: no translation
  $av = @{ abi = $abi; api = 'android-36.1'; device = 'pixel_10_pro'; tag = 'google_apis_playstore' }
  if ($c.avd) { foreach ($p in $c.avd.PSObject.Properties) { $av[$p.Name] = $p.Value } }; $c | Add-Member -Force avd ([pscustomobject]$av)
  $c | Add-Member -Force state (Join-Path $out 'swarm.json')
  $script:SwarmCfg = $c; $c
}
function EmuProcs($port) { Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$port\b" } }
function LaneSerial($l) { "emulator-$($l.port)" }
function Test-LaneUp($l) { [bool]((& (Get-SwarmConfig).adb devices) -match "^emulator-$($l.port)\s+device") }
# lane AVD hardware; {{X}} = swarm.config.json avd (abi, api, device, tag)
$script:AvdTemplate = @"
AvdId={{NAME}}
PlayStore.enabled={{PLAY}}
abi.type={{ABI}}
avd.ini.encoding=UTF-8
disk.dataPartition.size=16G
fastboot.forceFastBoot=yes
hw.accelerometer=yes
hw.audioInput=no
hw.battery=yes
hw.camera.back=virtualscene
hw.camera.front=emulated
hw.cpu.arch={{ARCH}}
hw.cpu.ncore=4
hw.dPad=no
hw.device.name={{DEVICE}}
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gyroscope=yes
hw.keyboard=yes
hw.lcd.density=480
hw.lcd.height=2856
hw.lcd.width=1280
hw.mainKeys=no
hw.ramSize=4096
hw.sdCard=yes
hw.sensors.light=yes
hw.sensors.magnetic_field=yes
hw.sensors.orientation=yes
hw.sensors.pressure=yes
hw.sensors.proximity=yes
hw.trackBall=no
image.sysdir.1=system-images\{{API}}\{{TAG}}\{{ABI}}\
skin.name={{DEVICE}}
skin.path={{SDK}}\skins\{{DEVICE}}
tag.id={{TAG}}
tag.ids={{TAG}}
target={{API}}
vm.heapSize=2048
hw.audioOutput=no
"@

# ---- phone: acquire | ensure | release | status, phone leases (gate boots; offline lanes keep their lease)
function Invoke-Phone {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'ensure', 'release', 'status')][string]$Action,
  [string]$Agent, [string]$Lane, [int]$WaitMinutes = 90, [switch]$Keep, [switch]$NoInstall, [string]$Holder,
  [string]$Apk, # 'local' = apk/app-local.apk
  [string[]]$Reverse   # adb reverse these ports
)
$ErrorActionPreference = 'Stop'
$Reverse = @(Split-KitList $Reverse | ForEach-Object { [int]$_ })
$c = Get-SwarmConfig
$adb = $c.adb; $pkg = $c.app.package
$dir = Get-KitPath phones; $waitDir = Join-Path $dir 'wait'
New-Item -ItemType Directory -Force $dir, $waitDir | Out-Null
$mutex = New-Object System.Threading.Mutex($false, 'Global\claude-phone-leases')
function Locked([scriptblock]$b) {
  $held = $false
  try { $held = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $held = $true }   # a killed holder hands the mutex over
  try { & $b } finally { if ($held) { $mutex.ReleaseMutex() } }
}
# untouched 3 min = dead waiter
function Waiters { Get-ChildItem $waitDir -Filter '*.json' | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 } | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } }
# lease files: reads and writes under the file's lock (an open reader made the writer's rename fail)
function Lease($name) { $f = Join-Path $dir "$name.json"; Invoke-KitLocked $f { if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } } }
function Save-Json($o, [string]$f) { $t = "$f.$PID.tmp"; $o | ConvertTo-Json -Depth 5 | Set-Content $t -Encoding utf8; Invoke-KitLocked $f {
    for ($i = 0; ; $i++) { try { [IO.File]::Move($t, $f, $true); break } catch [IO.IOException], [UnauthorizedAccessException] { if ($i -ge 100) { throw }; [Threading.Thread]::Sleep(50) } }   # an open reader (Windows: access denied) blocks the rename; a real wait
  }
}
function Running($l) { Test-LaneUp $l }
function Stamp($s, $set) { if ($set) { & $adb -s $s shell "echo $set > /sdcard/.qa-apk-stamp" } else { ((& $adb -s $s shell 'cat /sdcard/.qa-apk-stamp 2>/dev/null') -join '').Trim() } }
function ApkStamp { $a = Get-Item $c.appFile -ErrorAction SilentlyContinue; if ($a) { "$($a.Length)-$($a.LastWriteTimeUtc.Ticks)" } }
# what the lanes run (local ref, no fetch)
function ApkInfo {
  $f = Join-Path $c.apkDir 'app.json'; if (-not (Test-Path $f)) { return $null }
  $i = Get-Content $f -Raw | ConvertFrom-Json
  $head = try { (git -C $i.appDir rev-parse --short "origin/$($i.branch)" 2>$null) } catch { $null }
  $warn = if ($head -and $head.Trim() -ne $i.commit) { "APK $($i.commit) is behind origin/$($i.branch) ($($head.Trim())): the lead rebuilds it (swarm.ps1 build)" }
  [ordered]@{ branch = $i.branch; commit = $i.commit; built = $i.built; warning = $warn }
}
# boot via up (gate inside); $true = no memory turn
function Boot($l, [switch]$Cold, [datetime]$Until = (Get-Date)) {
  $a = @{ Lanes = $l.name; Mode = 'None' }; if ($Cold) { $a.ColdBoot = $true }
  do {
    $boot = @(& $KitCmd.swarm up @a 3>&1)   # 3>&1: catch the gate's warning
    $boot | Select-Object -Last 2 | Out-Host
    $queued = [bool]($boot | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'no memory turn' })
    if ($queued -and (Get-Date) -lt $Until) { "$($l.name): no memory turn yet; boot queued again (until $($Until.ToString('HH:mm')))" | Out-Host }
  } while ($queued -and -not (Running $l) -and (Get-Date) -lt $Until)
  $queued
}

switch ($Action) {
  'status' {
    foreach ($l in $c.lanes) {
      $ls = Lease $l.name
      $up = Running $l
      $who = if ($ls) { "leased by $($ls.agent)$(if ($ls.holder) { " (holder $($ls.holder))" }) since $($ls.since)" } else { 'free' }
      '{0,-8} {1,-14} {2}' -f $l.name, (LaneSerial $l), $(if ($up) { "up       $who" } elseif ($ls) { "down, $who (its agent runs ensure)" } else { "down     $who" })
    }
    "memory: $((Get-SysMem).AvailGB) GB available; boots queue in the memory gate (~4.5 GB a phone)"
    Get-ChildItem $waitDir -Filter '*.json' | Sort-Object LastWriteTime | ForEach-Object { $w = Get-Content $_.FullName -Raw | ConvertFrom-Json; "waiting: $($w.agent) for $(if ($w.lane) { $w.lane } else { 'any lane' }) since $($w.since)" }
  }

  'acquire' {
    if (-not $Agent) { throw 'acquire needs -Agent' }
    $lanes = @($c.lanes | Where-Object { -not $Lane -or $_.name -eq $Lane })
    if (-not $lanes) { throw "unknown lane $Lane (lanes: $($c.lanes.name -join ', '))" }
    $wf = Join-Path $waitDir "$Agent.json"
    $since = (Get-Date).ToString('s')
    Save-Json @{ agent = $Agent; lane = $Lane; since = $since } $wf
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $got = $null; $told = $false
    while (-not $got) {
      $got = Locked {
        if (Test-Path $wf) { (Get-Item $wf).LastWriteTime = Get-Date } else { Save-Json @{ agent = $Agent; lane = $Lane; since = $since } $wf }   # heartbeat
        $mine = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent } | Select-Object -First 1)
        if ($mine) {   # already ours (offline too)
          $script:had = $true
          if ($Holder) { $lf = Join-Path $dir "$($mine[0].name).json"; $o = Get-Content $lf -Raw | ConvertFrom-Json; if ($o.holder -ne $Holder) { $o | Add-Member -Force holder $Holder; Save-Json $o $lf } }
          return $mine[0]
        }
        # fair: oldest waiter a free lane satisfies first
        foreach ($ln in $lanes) { $o = Lease $ln.name; $lf = Join-Path $dir "$($ln.name).json"; if (-not $o -or $o.agent -in '__stopping__', 'manual') { continue }; $s0 = "$($o.seen)"; if (Update-KitLease $o) { if ("$($o.seen)" -ne $s0) { Save-Json $o $lf }; continue }; Remove-Item $lf -Force; "reclaimed $($ln.name) from $($o.agent): no live holder for $(Get-KitSetting 'idle.graceMinutes' 10) min" | Write-Host }
        $free = @($lanes | Where-Object { -not (Lease $_.name) })
        if (-not $free) { return $null }
        $ahead = @(Waiters | Where-Object { $_.agent -ne $Agent -and ([datetime]$_.since) -lt (Get-Date $since) -and (-not $_.lane -or $free.name -contains $_.lane) })
        if ($ahead.Count -ge $free.Count) { return $null }
        # a free running lane, else one booting for no one, else boot a new one (the gate admits it)
        $up = @($free | Where-Object { Running $_ }); $booting = @($free | Where-Object { -not (Running $_) -and ((& $adb devices) -match "^$([regex]::Escape((LaneSerial $_)))\s") })
        $pick = if ($up) { $up[0] } elseif ($booting) { $booting[0] } else { $free[0] }
        $new = @{ lane = $pick.name; serial = (LaneSerial $pick); since = (Get-Date).ToString('s'); holder = $Holder } + (New-KitLease $Agent '' $(if ($Agent -eq 'manual') { 240 }))   # no live holder for idle.graceMinutes: reclaimed
        Save-Json $new (Join-Path $dir "$($pick.name).json")
        $pick
      }
      if (-not $got) {
        if ((Get-Date) -gt $deadline) { Remove-Item $wf -Force -ErrorAction SilentlyContinue; throw "no phone free within $WaitMinutes min (swarm.ps1 status shows who holds them)" }
        if (-not $told) { "all $(if ($Lane) { "$Lane is" } else { 'lanes are' }) leased; waiting for a release or memory (fair queue) ..."; $told = $true }
        Wait-KitPoll 20
      }
    }
    $memQueued = $false
    try {
      if (-not (Running $got)) {
        # wait for RAM in 1-min gate turns, still a waiter (a release then keeps its lane up); a lane that frees up wins, this boot is dropped
        $env:KIT_SWARM_TURN_MIN = 1
        try {
          do {
            $memQueued = Boot $got   # one gate turn (KIT_SWARM_TURN_MIN = 1 min), then look for a lane freed meanwhile
            if (-not $memQueued -or (Running $got)) { break }
            if (Test-Path $wf) { (Get-Item $wf).LastWriteTime = Get-Date }
            $sw = Locked {
              $f = @($lanes | Where-Object { $_.name -ne $got.name -and -not (Lease $_.name) -and (Running $_) })[0]
              if ($f) { Remove-Item (Join-Path $dir "$($got.name).json") -Force; Save-Json (@{ lane = $f.name; serial = (LaneSerial $f); since = (Get-Date).ToString('s'); holder = $Holder } + (New-KitLease $Agent '')) (Join-Path $dir "$($f.name).json"); $f }
            }
            if ($sw) { Write-Host "$($got.name): boot dropped, $($sw.name) is free and running"; $got = $sw; $memQueued = $false; break }
          } while ((Get-Date) -lt $deadline)
        } finally { Remove-Item Env:KIT_SWARM_TURN_MIN -ErrorAction SilentlyContinue }   # also when Boot throws
      }
      Remove-Item $wf -Force -ErrorAction SilentlyContinue
      if (-not (Running $got) -and -not $script:had -and -not $memQueued) {
        "$($got.name): first boot failed, retrying once (cold boot; lease kept)" | Out-Host
        $memQueued = Boot $got -Cold -Until $deadline
      }
    } catch {   # a throwing boot must not leave a fresh lease
      if (-not $script:had) { Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force -ErrorAction SilentlyContinue } }
      throw
    }
    if (-not (Running $got)) {
      if ($script:had) {   # held lane offline: keep the lease
        throw "$($got.name) is offline and did not boot$(if ($memQueued) { " (no memory turn within -WaitMinutes)" }); lease kept: run swarm.ps1 ensure -Agent $Agent again, or release it"
      }
      Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force -ErrorAction SilentlyContinue }
      if ($memQueued) { throw "$($got.name): no memory turn within -WaitMinutes; lease released (acquire later)" }
      throw "$($got.name) did not boot (emulator problem); lease released"
    }
    $serial = LaneSerial $got; $installed = 'kept'
    if ($Apk) {   # side APK: stamp removed
      $ap = if ($Apk -eq 'local') { Join-Path $c.apkDir 'app-local.apk' } else { $Apk }
      if (-not (Test-Path $ap)) { throw "no app at $ap (local-env build: swarm.ps1 build -Local)" }
      & $KitCmd.swarm install -Apk $ap -Serials $serial | Out-Host   # throws when it fails
      & $adb -s $serial shell rm -f /sdcard/.qa-apk-stamp
      $installed = "side APK $ap (log in again; the next acquire without -Apk restores app.apk)"
    }
    $rev = @(if ($PSBoundParameters.ContainsKey('Reverse')) { $Reverse } elseif ($Apk -eq 'local') { @($c.app.localReverse) })
    foreach ($port in $rev) { & $adb -s $serial reverse "tcp:$port" "tcp:$port" | Out-Null }
    if ($rev.Count) { Locked { $lf = Join-Path $dir "$($got.name).json"; $o = Get-Content $lf -Raw | ConvertFrom-Json; $o | Add-Member -Force reverse @($rev); Save-Json $o $lf } }
    if (-not $Apk -and -not $NoInstall -and $c.app.kind -and (ApkStamp)) {
      if ((Stamp $serial) -ne (ApkStamp)) {
        try {
          & $KitCmd.swarm install -Serials $serial | Out-Host
          Stamp $serial (ApkStamp)
          $installed = 'updated (the app may need a fresh login)'
        } catch { Write-Warning "$serial : $_"; $installed = "install FAILED (the phone runs an older app): $_" }   # no stamp: next acquire retries
      }
    }
    [ordered]@{ lane = $got.name; serial = $serial; port = $got.port; user = $got.user; notes = $got.notes; installed = $installed; reverse = @($rev); apk = (ApkInfo) } | ConvertTo-Json -Compress -Depth 3
  }

  'ensure' {
    # own lease only: cold-boot when not 'device'
    if (-not $Agent) { throw 'ensure needs -Agent' }
    $got = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent } | Select-Object -First 1)
    if (-not $got) { throw "no phone leased by ${Agent}: use swarm.ps1 acquire -Agent $Agent -Lane <name>" }
    $got = $got[0]; $serial = LaneSerial $got; $state = 'up'
    if (-not (Running $got)) {
      $memQueued = Boot $got -Cold -Until (Get-Date).AddMinutes($WaitMinutes)
      if (-not (Running $got)) { throw "$($got.name) did not come back$(if ($memQueued) { " (no memory turn within -WaitMinutes)" }); lease kept: run ensure again later, or release it" }
      $state = 'cold-booted (relaunch the app; it may need a fresh login)'
      foreach ($port in @((Lease $got.name).reverse)) { & $adb -s $serial reverse "tcp:$port" "tcp:$port" | Out-Null }   # reverses are lost on reboot
    }
    [ordered]@{ lane = $got.name; serial = $serial; port = $got.port; user = $got.user; notes = $got.notes; state = $state; installed = 'kept'; apk = (ApkInfo) } | ConvertTo-Json -Compress -Depth 3
  }

  'release' {
    if (-not $Agent) { throw 'release needs -Agent' }
    Remove-Item (Join-Path $waitDir "$Agent.json") -Force -ErrorAction SilentlyContinue
    $mine = @($c.lanes | Where-Object { (Lease $_.name).agent -eq $Agent })
    if (-not $mine) { "no phone leased by $Agent"; return }
    foreach ($l in $mine) {
      $serial = LaneSerial $l
      if (Running $l) { & $adb -s $serial shell am force-stop $pkg 2>$null; & $adb -s $serial reverse --remove-all 2>$null }
      $lf = Join-Path $dir "$($l.name).json"
      $waiting = Locked {
        $n = @(Waiters | Where-Object { -not $_.lane -or $_.lane -eq $l.name }).Count
        if ($Keep -or $n -or -not (Running $l)) { Remove-Item $lf -Force -ErrorAction SilentlyContinue }
        else { Save-Json ([ordered]@{ agent = '__stopping__'; lane = $l.name; serial = $serial; since = (Get-Date).ToString('s') } + (Get-KitHolder)) $lf }
        $n
      }
      if ($Keep -or $waiting) { "$($l.name) released (kept running: $(if ($Keep) { '-Keep' } else { "$waiting agent(s) waiting" }))" }
      elseif ((Lease $l.name).agent -eq '__stopping__') {
        try { & $KitCmd.swarm down -Lanes $l.name -KeepBrowsers | Out-Null; "$($l.name) released and shut down" }
        finally { Locked { if ((Lease $l.name).agent -eq '__stopping__') { Remove-Item $lf -Force -ErrorAction SilentlyContinue } } }
      }
      else { "$($l.name) released" }
    }
  }
}
}

# ---- build: lane APK (-Local: local-env APK) through the memory gate; stamp apk/app.json
function Invoke-Build {
param(
  [string]$AppDir,
  [string]$Task,
  [string]$BuildArgs,
  [string]$JavaHome, # default: JDK 17/21 (24+ breaks native steps)
  [switch]$NoUpdate, # default: fast-forward to upstream first
  [switch]$Local, # -> apk/app-local.apk (never app.apk)
  [switch]$Shared, # -AppDir side checkout: publish as apk/app.apk
  [switch]$AnyBranch # publish from another branch (normally refused)
)
$ErrorActionPreference = 'Stop'
$c = Get-SwarmConfig
if (-not $AppDir) { $AppDir = $c.app.appDir }
if (-not $Task) { $Task = $c.app.buildTask }
if (-not $PSBoundParameters.ContainsKey('BuildArgs')) { $BuildArgs = [string]$c.app.buildArgs }
$gate = ({ & $KitCmd.dev gate @args })
$gw = if ($KitIsWindows) { 'gradlew.bat' } else { 'gradlew' }   # the gate runs .\gradlew.bat or ./gradlew
$cmd = [string]$c.app.buildCmd   # a non-Gradle kind (Get-SwarmConfig presets) or a custom command: no Gradle / Java steps
if (-not $cmd -and ($ext = Get-Command Invoke-AppPrebuild -ErrorAction SilentlyContinue)) { & $ext $AppDir $gw }   # adapters/app_kinds.ps1: Expo apps generate android/
$android = if ($cmd) { $AppDir } elseif (Test-Path (Join-Path $AppDir "android/$gw")) { Join-Path $AppDir 'android' } elseif (Test-Path (Join-Path $AppDir $gw)) { $AppDir } else { throw "no $gw in $AppDir or $(Join-Path $AppDir 'android') (an Expo app: kittool.py extra add android-swarm)" }

$branch = (git -C $AppDir rev-parse --abbrev-ref HEAD).Trim()
$dirty = (git -C $AppDir status --porcelain -- . | Measure-Object).Count
# app.apk feeds every lane: refuse a stale or other branch
$publishes = -not $Local -and ((-not $PSBoundParameters.ContainsKey('AppDir')) -or $Shared)
if ($publishes -and -not $AnyBranch -and $branch -ne 'HEAD') {
  $track = "$(git -C $AppDir for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>$null)".Trim()
  if ($track -eq '[gone]') { throw "$AppDir is on '$branch', gone from origin (merged): the lane app would miss newer merges. Switch it, or build a worktree with -AppDir <wt> -Shared (-AnyBranch overrides)" }
}
# test the branch as merged
if (-not $NoUpdate -and $branch -ne 'HEAD') {
  $before = (git -C $AppDir rev-parse HEAD).Trim()
  git -C $AppDir fetch -q origin $branch 2>$null
  if ($dirty) { Write-Warning "checkout has uncommitted changes: not updating; building $branch as it is" }
  elseif ((git -C $AppDir rev-list --count "HEAD..origin/$branch" 2>$null) -gt 0) {
    git -C $AppDir merge -q --ff-only "origin/$branch" 2>&1 | Out-Null
    if ($LASTEXITCODE) { Write-Warning "cannot fast-forward $branch to origin/$branch (local commits?): building the local branch" }
    else {
      $b9 = if ($before.Length -ge 9) { $before.Substring(0, 9) } else { $before }
      "updated $branch $b9 -> $((git -C $AppDir rev-parse --short HEAD).Trim())"
      $lockChanged = git -C $AppDir diff --name-only $before HEAD | Where-Object { $_ -match '(^|/)(yarn\.lock|package-lock\.json|package\.json)$' }
      if ($lockChanged -and $c.app.kind -eq 'react-native') {
        $pkgDir = (Get-Item $AppDir).FullName; while ($pkgDir -and -not (Test-Path (Join-Path $pkgDir 'package.json'))) { $pkgDir = Split-Path $pkgDir }
        "dependencies changed ($($lockChanged -join ', ')): installing in $pkgDir"
        Push-Location $pkgDir; try {   # frozen install (pnpm, yarn 1 / 2+, bun, npm)
          $ic = if (Test-Path 'pnpm-lock.yaml') { 'pnpm install --frozen-lockfile' } elseif (Test-Path 'yarn.lock') { if (Test-Path '.yarnrc.yml') { 'yarn install --immutable' } else { 'yarn install --frozen-lockfile' } } elseif ((Test-Path 'bun.lockb') -or (Test-Path 'bun.lock')) { 'bun install --frozen-lockfile' } else { 'npm ci' }
          Invoke-Expression "$ic 2>&1" | Select-Object -Last 2
        } finally { Pop-Location }
      }
    }
  }
}
if ($publishes -and -not $AnyBranch) {
  if ($c.app.branch) {
    git -C $AppDir fetch -q origin $c.app.branch 2>$null
    git -C $AppDir merge-base --is-ancestor "origin/$($c.app.branch)" HEAD 2>$null
    if ($LASTEXITCODE) { throw "$AppDir ('$branch') lacks origin/$($c.app.branch) (app.branch): the lane app would miss merged fixes. Switch it, or build a worktree with -AppDir <wt> -Shared (-AnyBranch overrides)" }
  }
}
$commit = (git -C $AppDir rev-parse --short HEAD).Trim()
"Building $(if ($cmd) { $c.app.kind } else { $Task }) from $branch @ $commit$(if ($dirty) { " (+$dirty uncommitted changes)" }) ..."

$log = Join-Path $c.out 'build.log'
$t0 = Get-Date
if ($cmd) {
  & $gate -Dir $AppDir -Cmd "$($cmd.Replace('{gw}', $(if ($KitIsWindows) { $gw } else { "./$gw" }))) $BuildArgs > `"$log`" 2>&1" -WaitMinutes 120
  if ($LASTEXITCODE) { Get-Content $log -Tail 15; throw "build failed (exit $LASTEXITCODE) - see $log" }
  $apk = Get-Item (Join-Path $AppDir $c.app.artifact) -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 } | Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $apk) { throw "this build left no app.artifact $($c.app.artifact) under $AppDir" }
} else {
# JAVA_HOME 24+ ignored (breaks CMake/prefab)
$javaExe = Join-Path 'bin' (Get-ExeName 'java')
$javaOk = @(if ($c.app.javaVersions) { @($c.app.javaVersions) | ForEach-Object { [int]$_ } } else { 17, 21 })
if (-not $JavaHome -and $c.app.javaHome) { $JavaHome = [string]$c.app.javaHome }
function JavaMajor($h) { if ($h -and (Test-Path (Join-Path $h $javaExe))) { $v = (& (Join-Path $h $javaExe) -version 2>&1 | Select-Object -First 1); if ($v -match 'version "(1\.)?(\d+)') { [int]$Matches[2] } } }
if (-not $JavaHome -and (JavaMajor $env:JAVA_HOME) -in $javaOk) { $JavaHome = $env:JAVA_HOME }
if (-not $JavaHome) {
  # JDK folders: Gradle / IDE downloads, Android Studio's jbr, the OS JVM folder
  $roots = @("$HOME/.gradle/jdks", "$HOME/.jdks") + $(if ($KitIsWindows) { Join-Path $env:ProgramFiles 'Android' } elseif ($KitIsMac) { '/Library/Java/JavaVirtualMachines', '/Applications' } else { '/usr/lib/jvm', "$HOME/android-studio" })
  $JavaHome = @(Get-ChildItem $roots -Directory -ErrorAction SilentlyContinue | ForEach-Object { $d = $_.FullName; "$d/Contents/jbr/Contents/Home", "$d/jbr", "$d/Contents/Home", $d } | Where-Object { (JavaMajor $_) -in $javaOk })[0]
}
if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
"Using Java: $env:JAVA_HOME"
$env:SENTRY_DISABLE_AUTO_UPLOAD = 'true'
if ($c.app.kind -eq 'react-native') { $env:NODE_ENV = 'production' }
if ($Local) {   # JS-bundled, non-debuggable
  $init = Join-Path $c.out 'local-cleartext.init.gradle'
  @'
allprojects {
  plugins.withId('com.android.application') {
    def cands = (System.getenv('KIT_LOCAL_MANIFESTS') ?: 'src/debug/AndroidManifest.xml').split(',')
    def overlay = cands.collect { project.file(it.trim()) }.find { it.exists() }
    if (overlay) { project.android.sourceSets.release.manifest.srcFile(overlay); println "cleartext overlay: ${overlay}" }
    else { throw new GradleException("no cleartext manifest overlay (${cands.join(', ')}): set swarm.config.json app.localManifests") }
  }
}
'@ | Set-Content $init -Encoding utf8
  $env:KIT_LOCAL_MANIFESTS = (@($c.app.localManifests) -join ',')
  $BuildArgs = "$BuildArgs -I `"$init`""
}
& $gate -Dir $android -Cmd "$gw $Task $BuildArgs `"-Dorg.gradle.java.home=$env:JAVA_HOME`" --console=plain > `"$log`" 2>&1" -WaitMinutes 120
$rc = $LASTEXITCODE
Select-String -Path $log -Pattern 'BUILD|FAILURE|error:' | Select-Object -Last 15 | ForEach-Object { $_.Line }
Push-Location $android; & (Join-Path . $gw) --stop --console=plain | Out-Null; Pop-Location   # no idle multi-GB daemon
if ($rc -ne 0) { throw "Gradle build failed (exit $rc) - see $log" }
# only this run's APK (never stale)
$apkRoot = Join-Path $android ((([string]$c.app.apkGlob) -split '/build/outputs/')[0] + '/build/outputs/apk')
if (-not (([string]$c.app.apkGlob) -match '/build/outputs/')) { $apkRoot = Join-Path $android 'app/build/outputs/apk' }
$apk = Get-ChildItem $apkRoot -Recurse -Filter *.apk -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 } | Sort-Object LastWriteTime | Select-Object -Last 1
# UP-TO-DATE builds keep the old file
if (-not $apk -and $Task -eq $c.app.buildTask -and $c.app.apkGlob) { $apk = Get-ChildItem (Join-Path $android $c.app.apkGlob) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 }
if (-not $apk) { throw "no APK built under $apkRoot (app module not 'app'? set app.apkGlob)" }
}
$apkDir = $c.apkDir; $x = '.apk'; $meta = [ordered]@{ branch = $branch; commit = $commit; appDir = $AppDir; built = (Get-Date).ToString('s') }; $took = "Done in $([int]((Get-Date) - $t0).TotalMinutes) min:"
function Put($to) { Copy-Item $apk.FullName (Join-Path $apkDir $to) -Force }
if ($Local) {   # never the shared APK; app-local.apk (every lane's local app) only from the env's code: origin/<app.branch> or localenv/*
  $own = "app-local-$(($branch -replace '[^\w.-]', '_'))-$commit$x"; Put $own
  $why = if ($dirty) { "$dirty uncommitted change(s)" } elseif ($branch -notlike 'localenv/*' -and $c.app.branch) {
    git -C $AppDir fetch -q origin $c.app.branch 2>$null
    if ("$(git -C $AppDir rev-parse HEAD)".Trim() -ne "$(git -C $AppDir rev-parse "origin/$($c.app.branch)" 2>$null)".Trim()) { "$branch is not origin/$($c.app.branch) HEAD" } }
  if ($why) { "$took $(Join-Path $apkDir $own) only (side APK, app-local$x kept: $why); use it: acquire -Apk $(Join-Path $apkDir $own)"; return }
  Put "app-local$x"
  $meta + @{ local = $true } | ConvertTo-Json | Set-Content (Join-Path $apkDir 'app-local.json') -Encoding utf8
  "$took $(Join-Path $apkDir "app-local$x") ($branch @ $commit); use it: acquire -Apk local"
  return
}
$name = if ($Task -eq $c.app.buildTask) { 'app' } else { 'app-' + ($Task -replace '^assemble', '').ToLower() }
# only the configured checkout replaces app.apk
$sideBuild = (Resolve-Path $AppDir).Path.TrimEnd('\', '/') -ne (Resolve-Path $c.app.appDir).Path.TrimEnd('\', '/')
if ($sideBuild -and -not $Shared) {
  $own = "$name-$(($branch -replace '[^\w.-]', '_'))-$commit$x"; Put $own
  "$took apk\$own ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
  "Side build, NOT published: install it on YOUR phone only (swarm.ps1 install -Apk <it> -Serials <serial>; -Shared publishes)"
  return
}
Put "$name$x"; Put "$name-$commit$x"
if ($name -eq 'app') {   # stamp: what the lanes run
  $meta | ConvertTo-Json | Set-Content (Join-Path $apkDir 'app.json') -Encoding utf8
}
"$took $(Join-Path $apkDir "$name$x") ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
}

# ---- install: APK onto phones (one signing key keeps app data)
function Invoke-Install {
param(
  [string]$Apk, # default <out>/apk/app.apk
  [string[]]$Serials,              # default: every lane in swarm.json
  [switch]$Launch
)
$ErrorActionPreference = 'Stop'
$c = Get-SwarmConfig
$adb = $c.adb; $pkg = $c.app.package
$Serials = @(Split-KitList $Serials)
if (-not $Serials) { $Serials = (Get-Content $c.state -Raw | ConvertFrom-Json).serial }
$apk = if ($Apk) { $Apk } else { $c.appFile }
if (-not (Test-Path $apk)) { throw "$apk missing - run swarm.ps1 build" }
$failed = @()
foreach ($s in $Serials) {
  $r = & $adb -s $s install -r -g $apk 2>&1 | Select-Object -Last 1
  if ($r -notmatch 'Success') { & $adb -s $s uninstall $pkg | Out-Null; $r = & $adb -s $s install -g $apk 2>&1 | Select-Object -Last 1 }
  if ($r -notmatch 'Success') { Write-Warning "$s : install failed ($r)"; $failed += $s; continue }
  foreach ($p in @($c.app.permissions)) { & $adb -s $s shell pm grant $pkg "android.permission.$p" 2>$null }
  "$s : app installed ($r)"
  if ($Launch) { & $KitCmd.swarm launch -Serial $s }
}
if ($failed) { throw "app install failed on $($failed -join ', ')" }
}

# ---- launch: (re)start or clear the app on one phone
function Invoke-Launch {
param([Parameter(Mandatory)][string]$Serial, [switch]$NoForceStop, [switch]$Clear, [switch]$Stop)   # -Stop: close the app
$c = Get-SwarmConfig
$adb = $c.adb; $pkg = $c.app.package
if ($Stop) { & $adb -s $Serial shell am force-stop $pkg; "$Serial : app closed"; return }
if ($Clear) { & $adb -s $Serial shell pm clear $pkg | Out-Null; foreach ($p in $c.app.permissions) { & $adb -s $Serial shell pm grant $pkg "android.permission.$p" 2>$null } }
if (-not $NoForceStop) { & $adb -s $Serial shell am force-stop $pkg }
& $adb -s $Serial shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
"$Serial : app launched"
}

# ---- avd: list | create | reset, lane emulators from the template (qa.ps1 ui assumes its resolution)
function Invoke-Avd {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'create', 'reset')][string]$Action,
  [string[]]$Lanes,
  [ValidateSet('cold', 'snapshots', 'wipe', 'recreate')][string]$Level = 'cold',
  [switch]$NoBoot, # create/reset: don't boot afterwards
  [switch]$Force # even if leased
)
$ErrorActionPreference = 'Stop'
$Lanes = @(Split-KitList $Lanes)
$c = Get-SwarmConfig
$sdk = Split-Path (Split-Path $c.adb); $avdHome = $c.avdDir   # Get-SwarmConfig defaults it
$leases = Get-KitPath phones
$all = @($c.lanes | Where-Object { -not $Lanes -or $Lanes -contains $_.name })
if ($Lanes) { $bad = @($Lanes | Where-Object { $c.lanes.name -notcontains $_ }); if ($bad) { throw "unknown lane(s) $($bad -join ', ') (lanes: $($c.lanes.name -join ', '))" } }
function Running($l) { Test-LaneUp $l }
function Holder($l) { $f = Join-Path $leases "$($l.name).json"; if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).agent } }

function New-Avd($name) {
  $v = $c.avd
  $tpl = $script:AvdTemplate.Replace('{{ABI}}', $v.abi).Replace('{{ARCH}}', ($v.abi -replace '-v8a$')).Replace('{{API}}', $v.api).Replace('{{TAG}}', $v.tag).Replace('{{DEVICE}}', $v.device).Replace('{{PLAY}}', "$($v.tag -match 'playstore')".ToLower())
  $sys = Join-Path $sdk "system-images/$($v.api)/$($v.tag)/$($v.abi)"
  if (-not (Test-Path $sys)) { throw "system image missing: $sys - install it: sdkmanager `"system-images;$($v.api);$($v.tag);$($v.abi)`" (or set swarm.config.json avd)" }
  $d = Join-Path $avdHome "$name.avd"
  New-Item -ItemType Directory -Force $d | Out-Null
  $cfg = $tpl.Replace('{{NAME}}', $name).Replace('{{SDK}}', $sdk)
  if (-not $KitIsWindows) { $cfg = $cfg.Replace('\', '/') }   # template uses Windows separators
  $cfg | Set-Content (Join-Path $d 'config.ini') -Encoding ascii -NoNewline
  @('avd.ini.encoding=UTF-8', "path=$d", "path.rel=avd$([IO.Path]::DirectorySeparatorChar)$name.avd", "target=$($v.api)") | Set-Content (Join-Path $avdHome "$name.ini") -Encoding ascii
  "$name created in $avdHome (first boot takes minutes)"
}
function Stop-Lane($l) {
  if (Running $l) { & $KitCmd.swarm down -Lanes $l.name -KeepBrowsers | Select-Object -First 1 }
  # a hung emulator holds the AVD files: kill by port
  $left = @(EmuProcs $l.port)
  if ($left.Count) { $left | ForEach-Object { Stop-SysProcess $_.Id }; Wait-KitPoll 2 }
}

switch ($Action) {
  'list' {
    foreach ($l in $all) {
      '{0,-8} {1,-14} avd={2,-8} {3,-5} {4}' -f $l.name, "emulator-$($l.port)", $(if (Test-Path (Join-Path $avdHome "$($l.name).avd/config.ini")) { 'present' } else { 'MISSING' }),
        $(if (Running $l) { 'up' } else { 'down' }), $(if ($h = Holder $l) { "leased by $h" } else { '' })
    }
  }
  'create' {
    $made = @()
    foreach ($l in $all) {
      if (Test-Path (Join-Path $avdHome "$($l.name).avd/config.ini")) { "$($l.name) exists - kept (reset -Level recreate rebuilds it)"; continue }
      New-Avd $l.name; $made += $l.name
    }
    if ($made -and -not $NoBoot) { & $KitCmd.swarm up -Lanes $made -Mode None -ColdBoot | Select-Object -Last 3 }
  }
  'reset' {
    if (-not $Lanes) { throw 'reset needs -Lanes (never every phone)' }
    foreach ($l in $all) {
      $h = Holder $l
      if ($h -and $h -ne 'manual' -and -not $Force) { Write-Warning "$($l.name) is leased by agent $h - skipped (wait for it, or -Force)"; continue }
      Stop-Lane $l
      $d = Join-Path $avdHome "$($l.name).avd"
      switch ($Level) {
        'snapshots' {
          Remove-Item (Join-Path $d 'snapshots') -Recurse -Force -ErrorAction SilentlyContinue
          if (Test-Path (Join-Path $d 'snapshots')) { Write-Warning "$($l.name): snapshots could not be deleted (file in use?)" } else { "$($l.name): snapshots deleted" }
        }
        'wipe' {
          # factory reset: rebuilt from the system image
          $left = @(foreach ($f in @('userdata-qemu', 'cache', 'encryptionkey' | ForEach-Object { "$_.img"; "$_.img.qcow2" }) + 'snapshots', 'multiinstance.lock', 'hardware-qemu.ini.lock') {
            Remove-Item (Join-Path $d $f) -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path (Join-Path $d $f)) { $f }
          })
          if ($left.Count) { Write-Warning "$($l.name): NOT wiped, could not delete $($left -join ', ') (emulator still running?)" } else { "$($l.name): wiped (factory reset)" }
        }
        'recreate' {
          Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $avdHome "$($l.name).ini") -Force -ErrorAction SilentlyContinue
          New-Avd $l.name
        }
      }
      Remove-Item (Join-Path $leases "$($l.name).json") -Force -ErrorAction SilentlyContinue   # any lease on a reset phone is void
      if (-not $NoBoot) { & $KitCmd.swarm up -Lanes $l.name -Mode None -ColdBoot | Select-Object -Last 2 }
    }
  }
}
}

# ---- up: boot lanes (run by acquire): boot, slim once, permissions, install, swarm.json
function Invoke-Up {
param(
  [int]$Count = 0, # 0 = all lanes
  [string[]]$Lanes, # or name them
  [switch]$ColdBoot, # ignore the snapshot
  [ValidateSet('Release', 'None')][string]$Mode = 'Release',
  [switch]$Headless, # no windows
  [switch]$ShowAll # show windows (owner asked)
)
$ErrorActionPreference = 'Stop'
$c = Get-SwarmConfig
$adb = $c.adb
$all = @($c.lanes)
$Lanes = @(Split-KitList $Lanes)
if (-not $Lanes) { $Lanes = @($all | Select-Object -First $(if ($Count -gt 0) { $Count } else { $all.Count }) | ForEach-Object name) }
$gate = ({ & $KitCmd.dev gate @args })
$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'; New-Item -ItemType Directory -Force $ledger | Out-Null
function FreeGB { Get-FreeGB }
function Turn($what, $gb) { & $gate -Dir $c.dir -Cmd "exit 0 #$what $name" -NeedGB $gb -WaitMinutes $(if ($env:KIT_SWARM_TURN_MIN) { [int]$env:KIT_SWARM_TURN_MIN } else { 30 }) | Select-Object -Last 1 | Out-Host; if ($LASTEXITCODE) { Write-Warning "$name not started: no memory turn within 30 min" }; -not $LASTEXITCODE }   # fair turn + memory

$out = @()
foreach ($name in $Lanes) {
  $l = $all | Where-Object name -eq $name | Select-Object -First 1
  if (-not $l) { throw "unknown lane $name (swarm.config.json lanes: $($all.name -join ', '))" }
  $serial = "emulator-$($l.port)"
  # leftover not 'device': < 8 min booting, older hung
  $left = @(EmuProcs $l.port)
  if ($left.Count -and -not (Test-LaneUp $l)) {
    $age = [int](($left | ForEach-Object { ((Get-Date) - $_.Created).TotalMinutes } | Measure-Object -Minimum).Minimum)
    if ($age -lt 8 -and @($left | Where-Object Name -like 'qemu-system*').Count) { "$name is already booting ($age min) ..."; $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }; continue }
    Write-Warning "$name`: killing a dead/hung emulator on port $($l.port) (adb not 'device' after $age min)"
    $left | ForEach-Object { Stop-SysProcess $_.Id }; Wait-KitPoll 2
  }
  if (-not (Test-LaneUp $l)) {
    if (-not (Turn 'emulator' 4.5)) { continue }
    $ini = Join-Path $c.avdDir "$name.avd/emulator-user.ini"
    if (Test-Path (Split-Path $ini)) { @('window.scale = 0.220000', 'resizable.config.id = -1', 'posture = 0') | Set-Content $ini -Encoding ascii }   # same window on every boot
    $a = @('-avd', $name, '-port', $l.port, '-no-audio', '-no-boot-anim'); if ($ColdBoot) { $a += '-no-snapshot-load' }
    $noWin = $Headless -or -not ($ShowAll -or $l.headless -eq $false -or ($null -eq $l.headless -and $c.headless -eq $false))   # window only with -ShowAll or headless: false
    if ($noWin) { $a += '-no-window' }
    # WMI: not our child (survives tool timeouts); SW_HIDE, CREATE_NO_WINDOW
    if ($KitIsWindows) {
      $si = New-CimInstance -CimClass (Get-CimClass -ClassName Win32_ProcessStartup) -ClientOnly -Property @{ ShowWindow = [uint16]0 }
      $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('"' + $c.emulator + '" ' + ($a -join ' ')); CurrentDirectory = (Split-Path $c.emulator); ProcessStartupInformation = $si }
      if ($r.ReturnValue -ne 0) { throw "could not start $name ($($r.ReturnValue))" }
    } else {
      if (-not (Test-Path $c.emulator)) { throw "no emulator at $($c.emulator) - set ANDROID_HOME (or ANDROID_SDK_ROOT)" }
      Start-Detached -FilePath $c.emulator -ArgumentList ($a | ForEach-Object { [string]$_ }) -WorkingDirectory (Split-Path $c.emulator) -Log (Join-Path $c.out "emulator-$name.log")
    }
    "$name booting on $serial ..."
    # gate ledger entry: the booting emulator's memory
    Wait-KitPoll 3
    $qemu = EmuProcs $l.port | Sort-Object Created -Descending | Select-Object -First 1
    if ($qemu) { @{ pid = $qemu.Id; need = 4.5; kind = 'emulator'; cmd = "emulator $name"; dir = $c.dir; started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $ledger "$($qemu.Id).json") }
  }
  $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }
}
$ready = @()
foreach ($o in $out) {
  # bounded wait: wait-for-device hangs if it dies
  $booted = $false
  for ($i = 0; $i -lt 120; $i++) { if ((& $adb -s $o.serial shell getprop sys.boot_completed 2>$null) -match '1') { $booted = $true; break }; Wait-KitPoll 3 }
  if (-not $booted) {
    Write-Warning "$($o.lane) did not finish booting in 6 min: killed (a hidden emulator keeps its RAM)"
    EmuProcs $o.port | ForEach-Object { Stop-SysProcess $_.Id }
    continue
  }
  $ready += $o
  if (-not ((& $adb -s $o.serial shell 'cat /sdcard/.qa-slimmed 2>/dev/null') -match 'slimmed')) { & $KitCmd.swarm slim -Serial $o.serial }
  foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') { & $adb -s $o.serial shell settings put global $k 0 }
  "$($o.lane) ready: $($o.serial)"
}
$out = $ready
# merge by lane (empty/corrupt file = none)
Invoke-KitLocked $c.state {
  $prev = try { @(Get-Content $c.state -Raw -ErrorAction Stop | ConvertFrom-Json) | Where-Object { $_.lane -and $_.lane -notin $Lanes } } catch { @() }
  ConvertTo-Json @(@($prev) + @($out)) | Set-Content $c.state -Encoding utf8
}
if (-not $Headless -and ($arrange = Get-Command Invoke-Arrange -ErrorAction SilentlyContinue) -and @($all | Where-Object { $_.name -in $Lanes -and ($ShowAll -or $_.headless -eq $false -or ($null -eq $_.headless -and $c.headless -eq $false)) }).Count) {   # extra emulator-windows; windows appear late
  foreach ($i in 1..3) { Wait-KitPoll 4; & $arrange | Out-Null }
  & $arrange | Out-Host
}
if ($Mode -ne 'None' -and $out) { & $KitCmd.swarm install -Serials $out.serial }
"swarm.json written; free RAM now $(FreeGB) GB"
}

# ---- down: stop lanes (snapshot saved, reverses removed, browser.mjs browsers killed)
function Invoke-Down {
param([string[]]$Lanes, [switch]$KeepBrowsers)
$Lanes = @(Split-KitList $Lanes)
$c = Get-SwarmConfig
$adb = $c.adb
foreach ($l in @($c.lanes) | Where-Object { -not $Lanes -or $Lanes -contains $_.name }) {
  $serial = LaneSerial $l
  if ((& $adb devices) -match "^$serial\s+device") {
    & $adb -s $serial reverse --remove-all 2>$null
    & $adb -s $serial emu kill | Out-Null
    # `emu kill` may be ignored: verify, then force-stop
    $listed = { (& $adb devices) -match "^$serial\s" }
    for ($i = 0; $i -lt 45 -and (& $listed); $i++) { Wait-KitPoll 2 }
    if (& $listed) {
      EmuProcs $l.port | ForEach-Object { Stop-SysProcess $_.Id }
      Wait-KitPoll 3
      "$($l.name) ($serial) did not stop on request: process killed$(if (& $listed) { ' - STILL LISTED, check by hand' })"
    } else { "$($l.name) ($serial) stopped" }
  } else { "$($l.name) not running" }
}
if (-not $KeepBrowsers) {
  $hc = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|headless_shell|google chrome|microsoft edge|firefox|MiniBrowser|WebKitWebProcess)(\.exe)?$' | Where-Object { $_.CommandLine -match '--?headless|-juggler' -and $_.CommandLine -match 'chrome-profiles' }
  $hc | ForEach-Object { Stop-SysProcess $_.Id }
  "killed $(@($hc).Count) headless test browser processes"
}
"free RAM now $(Get-FreeGB) GB"
}

# ---- slim: one-time (run by up)
function Invoke-Slim {
param([Parameter(Mandatory)][string]$Serial)
# disable heavy Google extras once (undo: adb shell pm enable <package>)
$adb = (Get-SwarmConfig).adb
function A { & $adb -s $Serial shell @args 2>&1 }

# KEEP: gms, gsf, maps, phone, messaging, documentsui, Gboard, camera, chrome, the app, SystemUI, Settings
$disable = @('com.android.vending') + @('googlequicksearchbox', 'as', 'as.oss', 'youtube', 'apps.youtube.music', 'apps.youtube.kids', 'gm', 'apps.photos', 'apps.docs', 'apps.tachyon', 'calendar',
  'apps.subscriptions.red', 'apps.wellbeing', 'apps.turbo', 'projection.gearhead', 'apps.safetyhub', 'feedback', 'printservice.recommendation', 'apps.wallpaper',
  'apps.nbu.files', 'videos', 'apps.restore', 'apps.pixelmigrate' | ForEach-Object { "com.google.android.$_" })
$installed = (A pm list packages) -replace '^package:', ''
$done = @()
foreach ($p in $disable) {
  if ($installed -contains $p) { $r = A pm disable-user --user 0 $p; if ($r -match 'disabled') { $done += $p } }
}

# automation: no animations, screen on, no lock
foreach ($k in 'window_animation_scale 0', 'transition_animation_scale 0', 'animator_duration_scale 0', 'stay_on_while_plugged_in 7', 'bluetooth_on 0', 'wifi_scan_always_enabled 0',
  'ble_scan_always_enabled 0', 'package_verifier_enable 0') { A settings put global $k | Out-Null }
A settings put system screen_off_timeout 1800000 | Out-Null; A locksettings set-disabled true | Out-Null; A svc bluetooth disable | Out-Null
A settings put secure location_mode 3 | Out-Null          # high accuracy (GPS + network)
A 'echo slimmed > /sdcard/.qa-slimmed' | Out-Null

"$Serial slimmed: disabled $($done.Count) packages ($($done -join ', '))"
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  $dt = Get-KitSetting 'devices.type' 'android'
  if ($dt -eq 'ios') {   # extra ios-simulator: its full variant runs
    $ios = Join-Path $PSScriptRoot 'swarm-ios.ps1'
    if (Test-Path $ios) { & $ios @args; exit $LASTEXITCODE }
    [Console]::Error.WriteLine('devices.type ios is an extra: run kittool.py extra add ios-simulator'); exit 1
  }
  if ($__verb -notmatch '^(-|help$)' -and $dt -eq 'none') { 'no device lanes: devices.type none; app checks are NOT_TESTED'; exit 1 }
  switch ($__verb) {
    { $_ -in 'acquire', 'ensure', 'release', 'status' } { Invoke-KitVerb Invoke-Phone (@($__verb) + $__rest) }
    'build' { Invoke-KitVerb Invoke-Build $__rest }
    'install' { Invoke-KitVerb Invoke-Install $__rest }
    'launch' { Invoke-KitVerb Invoke-Launch $__rest }
    'avd' { Invoke-KitVerb Invoke-Avd $__rest }
    'up' { Invoke-KitVerb Invoke-Up $__rest }
    'down' { Invoke-KitVerb Invoke-Down $__rest }
    'slim' { Invoke-KitVerb Invoke-Slim $__rest }
    'arrange' { if (Get-Command Invoke-Arrange -ErrorAction SilentlyContinue) { Invoke-KitVerb 'Invoke-Arrange' $__rest } else { [Console]::Error.WriteLine('arrange is an extra: run kittool.py extra add android-swarm'); exit 1 } }
    { $_ -in '-h', '--help', 'help', '-?' } { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit 0 }
    default { Get-Content $PSCommandPath -TotalCount 15 | Select-Object -Skip 1; exit 2 }
  }
}
