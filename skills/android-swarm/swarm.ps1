<#
swarm.ps1: Android emulator lanes + the app under test (android-swarm SKILL.md).
  pwsh 7: & <kit>/skills/android-swarm/swarm.ps1 <verb> [args]
  acquire -Agent <id> [-Lane <name>] [-Holder <board code>] [-Apk local|<path>] [-Reverse <port>,..] [-NoInstall]   lease a phone
  ensure -Agent <id> · release -Agent <id> [-Keep] · status
  build [-AppDir <checkout>] [-Local] [-Shared] [-Clean]   apk/app.apk; -Local: release + cleartext apk/app-local.apk
  install [-Apk <path>] [-Serials <s>,..] [-Launch] · launch -Serial <s> [-Clear] [-Stop]
  avd list|create|reset [-Lanes <names>] [-Level cold|snapshots|wipe|recreate]
  up [-Lanes ..] · down [-Lanes ..] · slim -Serial <s> · arrange
In: swarm.config.json (lanes, app), kit.local.json (gate floor).
Out: text / JSON (acquire, ensure), APKs in <runtime>/cache/android-swarm.
Exit codes: 0 ok · 1 problem (no phone, boot / install / build failed) · 2 usage error.
#>
$__verb = if ($args.Count) { [string]$args[0] } else { '' }
$__rest = @($args | Select-Object -Skip 1)
. (Join-Path (Split-Path $PSScriptRoot) 'dev-kit/lib.ps1')
# ---- config: swarm.config.json (its section of dev-kit/kit.example.json)
function Get-SwarmConfig {
  if ($script:SwarmCfg) { return $script:SwarmCfg }
  $here = $PSScriptRoot
  $f = Join-Path $here 'swarm.config.json'
  if (-not (Test-Path $f)) { throw "Missing $f - run orch.ps1 setup (writes it from the swarm.config.json section of dev-kit/kit.example.json) and set 'app'" }
  $c = Get-Content $f -Raw | ConvertFrom-Json
  if (-not $c.avdDir) { $c | Add-Member -Force avdDir $(if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { (Join-Path $HOME '.android/avd') }) }
  if (-not $c.app.kind) { $c.app | Add-Member -Force kind 'react-native' }
  if (-not $c.app.buildTask) { $c.app | Add-Member -Force buildTask $(if ($c.app.kind -eq 'native') { 'assembleDebug' } else { 'assembleRelease' }) }
  if (-not $c.app.apkGlob) { $v = if ($c.app.buildTask -match 'Release') { 'release' } else { 'debug' }; $c.app | Add-Member -Force apkGlob "app/build/outputs/apk/$v/*.apk" }
  if (-not $c.app.permissions) { $c.app | Add-Member -Force permissions @() }
  if (-not $c.app.localManifests) { $c.app | Add-Member -Force localManifests @('src/debugOptimized/AndroidManifest.xml', 'src/debug/AndroidManifest.xml') }
  if ($null -eq $c.app.localReverse) { $c.app | Add-Member -Force localReverse @() }
  $sdk = Get-AndroidSdk   # env, else the OS default
  $c | Add-Member -Force adb (Join-Path $sdk (Join-Path 'platform-tools' (Get-ExeName 'adb')))
  $c | Add-Member -Force emulator (Join-Path $sdk (Join-Path 'emulator' (Get-ExeName 'emulator')))
  $c | Add-Member -Force dir $here
  $out = if ($c.outDir) { [string]$c.outDir } else { Get-KitPath android-swarm }   # APKs, build/emulator logs, swarm.json
  $apkDir = Join-Path $out 'apk'
  New-Item -ItemType Directory -Force $apkDir | Out-Null
  $c | Add-Member -Force out $out
  $c | Add-Member -Force apkDir $apkDir
  $c | Add-Member -Force state (Join-Path $out 'swarm.json')
  $script:SwarmCfg = $c; $c
}
# lane AVD hardware; x86_64: edit for Apple silicon
$script:AvdTemplate = @"
AvdId={{NAME}}
PlayStore.enabled=true
abi.type=x86_64
avd.ini.displayname={{NAME}}
avd.ini.encoding=UTF-8
disk.dataPartition.size=16G
fastboot.chosenSnapshotFile=
fastboot.forceChosenSnapshotBoot=no
fastboot.forceColdBoot=no
fastboot.forceFastBoot=yes
hw.accelerometer=yes
hw.arc=false
hw.audioInput=no
hw.battery=yes
hw.camera.back=virtualscene
hw.camera.front=emulated
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.dPad=no
hw.device.hash2=MD5:676817bd81d1edf12e463dad09a74a05
hw.device.manufacturer=Google
hw.device.name=pixel_10_pro
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gyroscope=yes
hw.initialOrientation=portrait
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
image.sysdir.1=system-images\android-36.1\google_apis_playstore\x86_64\
runtime.network.latency=none
runtime.network.speed=full
showDeviceFrame=yes
skin.dynamic=yes
skin.name=pixel_10_pro
skin.path={{SDK}}\skins\pixel_10_pro
tag.display=Google Play
tag.displaynames=Google Play
tag.id=google_apis_playstore
tag.ids=google_apis_playstore
target=android-36.1
vm.heapSize=2048
hw.audioOutput=no
"@

# ---- acquire | ensure | release | status: phone leases (gate boots; offline lanes keep their lease)
function Invoke-Phone {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('acquire', 'ensure', 'release', 'status')][string]$Action,
  [string]$Agent, [string]$Lane, [int]$WaitMinutes = 90, [switch]$Keep, [switch]$NoInstall, [string]$Holder,
  [string]$Apk,        # 'local' = apk/app-local.apk
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
  # $held, not $got: a local $got would shadow the lease
  $held = $false
  try { $held = $mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $held = $true }   # a killed holder hands the mutex over
  try { & $b } finally { if ($held) { $mutex.ReleaseMutex() } }
}
# untouched 3 min = dead waiter
function Waiters { Get-ChildItem $waitDir -Filter '*.json' | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 } | Sort-Object LastWriteTime | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } }
function Lease($name) { $f = Join-Path $dir "$name.json"; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } }
function Save-Json($o, [string]$f) { $t = "$f.$PID.tmp"; $o | ConvertTo-Json -Depth 5 | Set-Content $t -Encoding utf8; Move-Item $t $f -Force }
function Running($l) { [bool]((& $adb devices) -match "^emulator-$($l.port)\s+device") }
function ApkStamp { $a = Get-Item (Join-Path $c.apkDir 'app.apk') -ErrorAction SilentlyContinue; if ($a) { "$($a.Length)-$($a.LastWriteTimeUtc.Ticks)" } }
# what the lanes run (local ref, no fetch)
function ApkInfo {
  $f = Join-Path $c.apkDir 'app.json'; if (-not (Test-Path $f)) { return $null }
  $i = Get-Content $f -Raw | ConvertFrom-Json
  $head = try { (git -C $i.appDir rev-parse --short "origin/$($i.branch)" 2>$null) } catch { $null }
  $warn = if ($head -and $head.Trim() -ne $i.commit) { "the APK is $($i.commit) but origin/$($i.branch) is at $($head.Trim()): ask the lead to rebuild (swarm.ps1 build)" }
  [ordered]@{ branch = $i.branch; commit = $i.commit; built = $i.built; warning = $warn }
}
# memory: only the gate admits (keepFreeGB)
function GateKeepFreeGB { if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { [double](Get-KitSetting 'gate.keepFreeGB' ([math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)))) } }
# boot via swarm-up (gate inside); $true = no memory turn
function Boot($l, [switch]$Cold, [datetime]$Until = (Get-Date)) {
  $a = @{ Lanes = $l.name; Mode = 'None' }; if ($Cold) { $a.ColdBoot = $true }
  do {
    $boot = @(& $KitCmd.swarm up @a 3>&1)   # 3>&1: catch the gate's warning
    $boot | Select-Object -Last 2 | Out-Host
    $queued = [bool]($boot | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'no memory turn' })
    if ($queued -and (Get-Date) -lt $Until) { "$($l.name): still no memory turn in the gate; queuing the boot again (until $($Until.ToString('HH:mm')))" | Out-Host }
  } while ($queued -and -not (Running $l) -and (Get-Date) -lt $Until)
  $queued
}

switch ($Action) {
  'status' {
    foreach ($l in $c.lanes) {
      $ls = Lease $l.name
      $up = Running $l
      $who = if ($ls) { "leased by $($ls.agent)$(if ($ls.holder) { " (holder $($ls.holder))" }) since $($ls.since)" } else { 'free' }
      '{0,-8} {1,-14} {2}' -f $l.name, "emulator-$($l.port)", $(if ($up) { "up       $who" } elseif ($ls) { "down, $who (offline: its agent runs swarm.ps1 ensure)" } else { "down     $who" })
    }
    "memory: $((Get-SysMem).AvailGB) GB available; boots queue in the memory gate (keeps $(GateKeepFreeGB) GB free, a phone needs ~4.5 GB)"
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
        $free = @($lanes | Where-Object { -not (Lease $_.name) })
        if (-not $free) { return $null }
        $ahead = @(Waiters | Where-Object { $_.agent -ne $Agent -and ([datetime]$_.since) -lt (Get-Date $since) -and (-not $_.lane -or $free.name -contains $_.lane) })
        if ($ahead.Count -ge $free.Count) { return $null }
        # a free running phone first, else a free lane
        $up = @($free | Where-Object { Running $_ })
        $pick = if ($up) { $up[0] } else { $free[0] }
        $new = [ordered]@{ agent = $Agent; lane = $pick.name; serial = "emulator-$($pick.port)"; since = (Get-Date).ToString('s') } + (Get-KitHolder); if ($Holder) { $new.holder = $Holder }   # holderPid: supervise frees a crashed session's lease
        Save-Json $new (Join-Path $dir "$($pick.name).json")
        $pick
      }
      if (-not $got) {
        if ((Get-Date) -gt $deadline) { Remove-Item $wf -Force -ErrorAction SilentlyContinue; throw "no phone free within $WaitMinutes min (swarm.ps1 status shows who holds them)" }
        if (-not $told) { "all $(if ($Lane) { "$Lane is" } else { 'lanes are' }) leased; waiting for a release or memory (fair queue) ..."; $told = $true }
        Start-Sleep 20
      }
    }
    Remove-Item $wf -Force -ErrorAction SilentlyContinue
    $serial = "emulator-$($got.port)"
    $memQueued = $false
    try {
      if (-not (Running $got)) { $memQueued = Boot $got -Until $deadline }
      if (-not (Running $got) -and -not $script:had -and -not $memQueued) {
        # first boot failed: one cold retry
        "$($got.name): first boot failed, retrying once (cold boot; lease kept)" | Out-Host
        $memQueued = Boot $got -Cold -Until $deadline
      }
    } catch {   # a throwing boot must not leave a fresh lease
      if (-not $script:had) { Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force -ErrorAction SilentlyContinue } }
      throw
    }
    if (-not (Running $got)) {
      if ($script:had) {   # held lane offline: keep the lease
        throw "$($got.name) is offline and did not boot$(if ($memQueued) { " (no memory turn in the gate within -WaitMinutes $WaitMinutes)" }); lease kept: run swarm.ps1 ensure -Agent $Agent again, or release it"
      }
      Locked { Remove-Item (Join-Path $dir "$($got.name).json") -Force -ErrorAction SilentlyContinue }
      if ($memQueued) { throw "$($got.name) queued behind memory: the gate gave no memory turn within -WaitMinutes $WaitMinutes; lease released (acquire again later)" }
      throw "$($got.name) did not boot (emulator problem); lease released"
    }
    $installed = 'kept'
    if ($Apk) {   # side APK: stamp removed
      $ap = if ($Apk -eq 'local') { Join-Path $c.apkDir 'app-local.apk' } else { $Apk }
      if (-not (Test-Path $ap)) { throw "no APK at $ap (local-env APK: swarm.ps1 build -Local)" }
      $r = & $adb -s $serial install -r -g $ap 2>&1 | Select-Object -Last 1
      if ($r -notmatch 'Success') { throw "$serial : install of $ap failed ($r)" }
      & $adb -s $serial shell rm -f /sdcard/.qa-apk-stamp
      foreach ($p in $c.app.permissions) { & $adb -s $serial shell pm grant $c.app.package "android.permission.$p" 2>$null }
      $installed = "side APK $ap (log in again; the next acquire without -Apk restores app.apk)"
    }
    $rev = @(if ($PSBoundParameters.ContainsKey('Reverse')) { $Reverse } elseif ($Apk -eq 'local') { @($c.app.localReverse) })
    foreach ($port in $rev) { & $adb -s $serial reverse "tcp:$port" "tcp:$port" | Out-Null }
    if ($rev.Count) { Locked { $lf = Join-Path $dir "$($got.name).json"; $o = Get-Content $lf -Raw | ConvertFrom-Json; $o | Add-Member -Force reverse @($rev); Save-Json $o $lf } }
    if (-not $Apk -and -not $NoInstall -and $c.app.kind -and (ApkStamp)) {
      $onPhone = ((& $adb -s $serial shell 'cat /sdcard/.qa-apk-stamp 2>/dev/null') -join '').Trim()
      if ($onPhone -ne (ApkStamp)) {
        try {
          & $KitCmd.swarm install -Mode Release -Serials $serial | Out-Host
          & $adb -s $serial shell "echo $(ApkStamp) > /sdcard/.qa-apk-stamp"
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
    $got = $got[0]; $serial = "emulator-$($got.port)"; $state = 'up'
    if (-not (Running $got)) {
      $memQueued = Boot $got -Cold -Until (Get-Date).AddMinutes($WaitMinutes)
      if (-not (Running $got)) { throw "$($got.name) did not come back$(if ($memQueued) { " (no memory turn in the gate within -WaitMinutes $WaitMinutes)" }); lease kept: run ensure again later, or release it" }
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
      $serial = "emulator-$($l.port)"
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
  [string]$Task,                   # default app.buildTask
  [string]$BuildArgs,              # default app.buildArgs
  [switch]$Clean,
  [string]$JavaHome,               # default: JDK 17/21 (24+ breaks native steps)
  [switch]$NoUpdate,               # default: fast-forward to upstream first
  [switch]$Local,                  # -> apk/app-local.apk (never app.apk)
  [switch]$Shared,                 # -AppDir side checkout: publish as apk/app.apk
  [switch]$AnyBranch               # publish from another branch (normally refused)
)
$ErrorActionPreference = 'Stop'
$c = Get-SwarmConfig
if (-not $AppDir) { $AppDir = $c.app.appDir }
if (-not $Task) { $Task = $c.app.buildTask }
if (-not $PSBoundParameters.ContainsKey('BuildArgs')) { $BuildArgs = [string]$c.app.buildArgs }
$gate = ({ & $KitCmd.dev gate @args })
$gw = if ($KitIsWindows) { 'gradlew.bat' } else { 'gradlew' }   # the gate runs .\gradlew.bat or ./gradlew
# Expo CNG: prebuild when android/ is missing
if (-not (Test-Path (Join-Path $AppDir "android/$gw")) -and -not (Test-Path (Join-Path $AppDir $gw)) -and (Test-Path (Join-Path $AppDir 'package.json')) -and
    ((Get-Content (Join-Path $AppDir 'package.json') -Raw) -match '"expo"\s*:')) {
  "no android/ in $AppDir (Expo app): npx expo prebuild --platform android --no-install"
  Push-Location $AppDir
  $ci = $env:CI
  try { $env:CI = '1'; & npx expo prebuild --platform android --no-install 2>&1 | Select-Object -Last 5; if ($LASTEXITCODE) { throw "expo prebuild failed (exit $LASTEXITCODE)" } } finally { $env:CI = $ci; Pop-Location }
}
$android = if (Test-Path (Join-Path $AppDir "android/$gw")) { Join-Path $AppDir 'android' } elseif (Test-Path (Join-Path $AppDir $gw)) { $AppDir } else { throw "no $gw in $AppDir or $(Join-Path $AppDir 'android')" }

$branch = (git -C $AppDir rev-parse --abbrev-ref HEAD).Trim()
$dirty = (git -C $AppDir status --porcelain -- . | Measure-Object).Count
# app.apk feeds every lane: refuse a stale or other branch
$publishes = -not $Local -and ((-not $PSBoundParameters.ContainsKey('AppDir')) -or $Shared)
if ($publishes -and -not $AnyBranch -and $branch -ne 'HEAD') {
  $track = "$(git -C $AppDir for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>$null)".Trim()
  if ($track -eq '[gone]') { throw "the checkout $AppDir is on '$branch', whose remote branch is gone (merged and deleted): the lane APK would miss newer merges. Switch it to the branch under test, or build a worktree of it with -AppDir <worktree> -Shared (-AnyBranch to override)." }
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
      "updated $branch $($before.Substring(0, 9)) -> $((git -C $AppDir rev-parse --short HEAD).Trim())"
      $lockChanged = git -C $AppDir diff --name-only $before HEAD | Where-Object { $_ -match '(^|/)(yarn\.lock|package-lock\.json|package\.json)$' }
      if ($lockChanged -and $c.app.kind -eq 'react-native') {
        $pkgDir = (Get-Item $AppDir).FullName; while ($pkgDir -and -not (Test-Path (Join-Path $pkgDir 'package.json'))) { $pkgDir = Split-Path $pkgDir }
        "dependencies changed ($($lockChanged -join ', ')): installing in $pkgDir"
        # frozen install (yarn 1 / yarn 2+)
        Push-Location $pkgDir; try {
          if (Test-Path 'pnpm-lock.yaml') { pnpm install --frozen-lockfile 2>&1 | Select-Object -Last 2 }
          elseif (Test-Path 'yarn.lock') { if (Test-Path '.yarnrc.yml') { yarn install --immutable 2>&1 | Select-Object -Last 2 } else { yarn install --frozen-lockfile 2>&1 | Select-Object -Last 2 } }
          elseif ((Test-Path 'bun.lockb') -or (Test-Path 'bun.lock')) { bun install --frozen-lockfile 2>&1 | Select-Object -Last 2 }
          else { npm ci 2>&1 | Select-Object -Last 2 }
        } finally { Pop-Location }
      }
    }
  }
}
# must contain every commit of origin/<app.branch>
if ($publishes -and -not $AnyBranch) {
  if ($c.app.branch) {
    git -C $AppDir fetch -q origin $c.app.branch 2>$null
    git -C $AppDir merge-base --is-ancestor "origin/$($c.app.branch)" HEAD 2>$null
    if ($LASTEXITCODE) { throw "the checkout $AppDir ('$branch') does not contain origin/$($c.app.branch) (app.branch): the lane APK would miss merged fixes. Switch it, or build a worktree of $($c.app.branch) with -AppDir <worktree> -Shared (-AnyBranch to override)." }
  }
}
$commit = (git -C $AppDir rev-parse --short HEAD).Trim()
"Building $Task from $branch @ $commit$(if ($dirty) { " (+$dirty uncommitted changes)" }) ..."

# JAVA_HOME 24+ ignored (breaks CMake/prefab)
$javaExe = Join-Path 'bin' (Get-ExeName 'java')
$javaOk = @(if ($c.app.javaVersions) { @($c.app.javaVersions) | ForEach-Object { [int]$_ } } else { 17, 21 })
if (-not $JavaHome -and $c.app.javaHome) { $JavaHome = [string]$c.app.javaHome }
function JavaMajor($h) { if ($h -and (Test-Path (Join-Path $h $javaExe))) { $v = (& (Join-Path $h $javaExe) -version 2>&1 | Select-Object -First 1); if ($v -match 'version "(1\.)?(\d+)') { [int]$Matches[2] } } }
if (-not $JavaHome -and (JavaMajor $env:JAVA_HOME) -in $javaOk) { $JavaHome = $env:JAVA_HOME }
if (-not $JavaHome) {
  # JDK folders per OS
  $roots = @((Join-Path $HOME '.gradle/jdks'), (Join-Path $HOME '.jdks'))
  $roots += if ($KitIsWindows) { @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Android'; Join-Path $_ 'Java'; Join-Path $_ 'Eclipse Adoptium'; Join-Path $_ 'Microsoft'; Join-Path $_ 'Amazon Corretto'; Join-Path $_ 'Zulu' } }
            elseif ($KitIsMac) { '/Library/Java/JavaVirtualMachines', '/Applications' }
            else { '/usr/lib/jvm', '/opt', (Join-Path $HOME 'android-studio') }
  $JavaHome = @(Get-ChildItem $roots -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { if ($_.Name -match '^Android Studio') { if ($KitIsMac) { Join-Path $_.FullName 'Contents/jbr/Contents/Home' } else { Join-Path $_.FullName 'jbr' } } elseif ($_.Name -eq 'android-studio') { Join-Path $_.FullName 'jbr' } elseif (Test-Path (Join-Path $_.FullName 'Contents/Home')) { Join-Path $_.FullName 'Contents/Home' } else { $_.FullName } } |
    Where-Object { Test-Path (Join-Path $_ $javaExe) } | Where-Object { (JavaMajor $_) -in $javaOk })[0]
}
if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
"Using Java: $env:JAVA_HOME"
$env:SENTRY_DISABLE_AUTO_UPLOAD = 'true'
if ($c.app.kind -eq 'react-native') { $env:NODE_ENV = 'production' }
$log = Join-Path $c.out 'build.log'
$t0 = Get-Date
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
if ($Clean) { Push-Location $android; & (Join-Path . $gw) clean --console=plain | Select-Object -Last 3; Pop-Location }
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
if (-not $apk) { throw "no APK built by this run under $apkRoot (set swarm.config.json app.apkGlob to <module>/build/outputs/apk/... if the app module is not 'app')" }
$apkDir = $c.apkDir
if ($Local) {   # never the shared APK
  Copy-Item $apk.FullName (Join-Path $apkDir 'app-local.apk') -Force
  Copy-Item $apk.FullName (Join-Path $apkDir "app-local-$(($branch -replace '[^\w.-]', '_'))-$commit.apk") -Force
  [ordered]@{ branch = $branch; commit = $commit; appDir = $AppDir; built = (Get-Date).ToString('s'); local = $true } | ConvertTo-Json | Set-Content (Join-Path $apkDir 'app-local.json') -Encoding utf8
  "Done in $([int]((Get-Date) - $t0).TotalMinutes) min: $(Join-Path $apkDir 'app-local.apk') ($branch @ $commit). Use it: swarm.ps1 acquire -Agent <id> -Apk local (reverses app.localReverse)"
  return
}
$name = if ($Task -eq $c.app.buildTask) { 'app' } else { 'app-' + ($Task -replace '^assemble', '').ToLower() }
# only the configured checkout replaces app.apk
$sideBuild = (Resolve-Path $AppDir).Path.TrimEnd('\', '/') -ne (Resolve-Path $c.app.appDir).Path.TrimEnd('\', '/')
if ($sideBuild -and -not $Shared) {
  $own = "$name-$(($branch -replace '[^\w.-]', '_'))-$commit.apk"
  Copy-Item $apk.FullName (Join-Path $apkDir $own) -Force
  "Done in $([int]((Get-Date) - $t0).TotalMinutes) min: apk\$own ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
  "Side-checkout build: NOT published as apk\$name.apk (the lanes keep their build). Install it on YOUR leased phone only: adb -s <serial> install -r `"$(Join-Path $apkDir $own)`"  (-Shared to publish it to every lane)"
  return
}
Copy-Item $apk.FullName (Join-Path $apkDir "$name.apk") -Force
Copy-Item $apk.FullName (Join-Path $apkDir "$name-$commit.apk") -Force
if ($name -eq 'app') {   # stamp: what the lanes run
  [ordered]@{ branch = $branch; commit = $commit; appDir = $AppDir; built = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $apkDir 'app.json') -Encoding utf8
}
"Done in $([int]((Get-Date) - $t0).TotalMinutes) min: $(Join-Path $apkDir "$name.apk") ($([math]::Round($apk.Length / 1MB)) MB, $branch @ $commit)"
}

# ---- install: APK onto phones (one signing key keeps app data)
function Invoke-Install {
param(
  [string]$Apk,                    # default <out>/apk/app.apk
  [string[]]$Serials,              # default: every lane in swarm.json
  [switch]$Launch
)
$ErrorActionPreference = 'Stop'
$c = Get-SwarmConfig
$adb = $c.adb; $pkg = $c.app.package; $Mode = 'Release'
$Serials = @(Split-KitList $Serials)
if (-not $Serials) { $Serials = (Get-Content $c.state -Raw | ConvertFrom-Json).serial }
$apk = if ($Apk) { $Apk } else { Join-Path $c.apkDir 'app.apk' }
if (-not (Test-Path $apk)) { throw "$apk missing - run swarm.ps1 build" }
$failed = @()
foreach ($s in $Serials) {
  $r = & $adb -s $s install -r -g $apk 2>&1 | Select-Object -Last 1
  if ($r -notmatch 'Success') { & $adb -s $s uninstall $pkg | Out-Null; $r = & $adb -s $s install -g $apk 2>&1 | Select-Object -Last 1 }
  if ($r -notmatch 'Success') { Write-Warning "$s : $Mode install failed ($r)"; $failed += $s; continue }
  foreach ($p in $c.app.permissions) { & $adb -s $s shell pm grant $pkg "android.permission.$p" 2>$null }
  & $adb -s $s shell "echo $Mode > /sdcard/.qa-app-mode"
  "$s : $Mode app installed ($r)"
  if ($Launch) { & $KitCmd.swarm launch -Serial $s }
}
if ($failed) { throw "app install failed on $($failed -join ', ')" }
}

# ---- launch: (re)start or clear the app on one phone (mode from /sdcard/.qa-app-mode)
function Invoke-Launch {
param([Parameter(Mandatory)][string]$Serial, [switch]$NoForceStop, [switch]$Clear, [switch]$Stop)   # -Stop: close the app
$c = Get-SwarmConfig
$adb = $c.adb; $pkg = $c.app.package
if ($Stop) { & $adb -s $Serial shell am force-stop $pkg; "$Serial : app closed"; return }
$mode = ((& $adb -s $Serial shell 'cat /sdcard/.qa-app-mode 2>/dev/null') -join '').Trim()
if (-not $mode) { $mode = 'Release' }
if ($Clear) { & $adb -s $Serial shell pm clear $pkg | Out-Null; foreach ($p in $c.app.permissions) { & $adb -s $Serial shell pm grant $pkg "android.permission.$p" 2>$null } }
if (-not $NoForceStop) { & $adb -s $Serial shell am force-stop $pkg }
& $adb -s $Serial shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
"$Serial : app launched ($mode mode)"
}

# ---- avd list | create | reset: lane emulators from the template (keep the resolution: qa.ps1 ui assumes it)
function Invoke-Avd {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'create', 'reset')][string]$Action,
  [string[]]$Lanes,
  [ValidateSet('cold', 'snapshots', 'wipe', 'recreate')][string]$Level = 'cold',
  [switch]$NoBoot,                  # create/reset: don't boot afterwards
  [switch]$Force                    # even if leased
)
$ErrorActionPreference = 'Stop'
$Lanes = @(Split-KitList $Lanes)
$c = Get-SwarmConfig
$adb = $c.adb
$sdk = Split-Path (Split-Path $c.adb)
$avdHome = if ($c.avdDir) { $c.avdDir } elseif ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { (Join-Path $HOME '.android/avd') }
$leases = Get-KitPath phones
$all = @($c.lanes | Where-Object { -not $Lanes -or $Lanes -contains $_.name })
if ($Lanes) { $bad = @($Lanes | Where-Object { $c.lanes.name -notcontains $_ }); if ($bad) { throw "unknown lane(s) $($bad -join ', ') (lanes: $($c.lanes.name -join ', '))" } }
function Running($l) { [bool]((& $adb devices) -match "^emulator-$($l.port)\s+device") }
function Holder($l) { $f = Join-Path $leases "$($l.name).json"; if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).agent } }

function New-Avd($name) {
  $tpl = $script:AvdTemplate
  $sys = if ($tpl -match 'image\.sysdir\.1=(.+)') { Join-Path $sdk $Matches[1].Trim() } else { throw 'template has no image.sysdir.1' }
  if (-not (Test-Path $sys)) { throw "system image missing: $sys - install it in Android Studio (SDK Manager > SDK Platforms > Android 36.1 > Google Play x86_64)" }
  $d = Join-Path $avdHome "$name.avd"
  New-Item -ItemType Directory -Force $d | Out-Null
  $cfg = $tpl.Replace('{{NAME}}', $name).Replace('{{SDK}}', $sdk)
  if (-not $KitIsWindows) { $cfg = $cfg.Replace('\', '/') }   # template uses Windows separators
  $cfg | Set-Content (Join-Path $d 'config.ini') -Encoding ascii -NoNewline
  $target = if ($tpl -match '(?m)^target=(.+)$') { $Matches[1].Trim() } else { 'android-36.1' }
  @('avd.ini.encoding=UTF-8', "path=$d", "path.rel=avd$([IO.Path]::DirectorySeparatorChar)$name.avd", "target=$target") | Set-Content (Join-Path $avdHome "$name.ini") -Encoding ascii
  "$name created in $avdHome (first boot builds its disks: a few minutes)"
}
function Stop-Lane($l) {
  if (Running $l) { & $KitCmd.swarm down -Lanes $l.name -KeepBrowsers | Select-Object -First 1 }
  # a hung emulator holds the AVD files: kill by port
  $left = @(Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" })
  if ($left.Count) { $left | ForEach-Object { Stop-SysProcess $_.Id }; Start-Sleep 2 }
}

switch ($Action) {
  'list' {
    foreach ($l in $all) {
      '{0,-8} {1,-14} avd={2,-8} {3,-5} {4}' -f $l.name, "emulator-$($l.port)", $(if (Test-Path (Join-Path $avdHome "$($l.name).avd\config.ini")) { 'present' } else { 'MISSING' }),
        $(if (Running $l) { 'up' } else { 'down' }), $(if ($h = Holder $l) { "leased by $h" } else { '' })
    }
  }
  'create' {
    $made = @()
    foreach ($l in $all) {
      if (Test-Path (Join-Path $avdHome "$($l.name).avd\config.ini")) { "$($l.name) exists - kept (use reset -Level recreate to rebuild it)"; continue }
      New-Avd $l.name; $made += $l.name
    }
    if ($made -and -not $NoBoot) { & $KitCmd.swarm up -Lanes $made -Mode None -ColdBoot | Select-Object -Last 3 }
  }
  'reset' {
    if (-not $Lanes) { throw 'reset needs -Lanes (it never resets every phone by accident)' }
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
          $left = @(foreach ($f in 'userdata-qemu.img', 'userdata-qemu.img.qcow2', 'cache.img', 'cache.img.qcow2', 'encryptionkey.img', 'encryptionkey.img.qcow2', 'snapshots', 'multiinstance.lock', 'hardware-qemu.ini.lock') {
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
  [int]$Count = 0,                 # 0 = all lanes
  [string[]]$Lanes,                # or name them
  [switch]$ColdBoot,               # ignore the snapshot
  [ValidateSet('Release', 'None')][string]$Mode = 'Release',
  [switch]$Headless,               # no windows (see above)
  [switch]$ShowAll                 # show windows (owner asked)
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

$out = @()
foreach ($name in $Lanes) {
  $l = $all | Where-Object name -eq $name | Select-Object -First 1
  if (-not $l) { throw "unknown lane $name (swarm.config.json lanes: $($all.name -join ', '))" }
  $serial = "emulator-$($l.port)"
  # leftover not 'device': < 8 min booting, older hung
  $left = @(Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" })
  if ($left.Count -and -not ((& $adb devices) -match "^$serial\s+device")) {
    $age = [int](($left | ForEach-Object { ((Get-Date) - $_.Created).TotalMinutes } | Measure-Object -Minimum).Minimum)
    if ($age -lt 8 -and @($left | Where-Object Name -like 'qemu-system*').Count) { "$name is already booting ($age min) ..."; $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }; continue }
    Write-Warning "$name`: killing a dead/hung emulator on port $($l.port) (adb not 'device' after $age min)"
    $left | ForEach-Object { Stop-SysProcess $_.Id }; Start-Sleep 2
  }
  if (-not ((& $adb devices) -match "^$serial\s+device")) {
    # fair turn + memory via the gate
    & $gate -Dir $c.dir -Cmd "exit 0 #emulator $name" -NeedGB 4.5 -WaitMinutes 30 | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { Write-Warning "$name not started: no memory turn within 30 min"; continue }
    $ini = Join-Path $c.avdDir "$name.avd\emulator-user.ini"
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
      # Linux/macOS: setsid/nohup to outlive this shell
      if (-not (Test-Path $c.emulator)) { throw "no emulator at $($c.emulator) - set ANDROID_HOME (or ANDROID_SDK_ROOT)" }
      Start-Detached -FilePath $c.emulator -ArgumentList ($a | ForEach-Object { [string]$_ }) -WorkingDirectory (Split-Path $c.emulator) -Log (Join-Path $c.out "emulator-$name.log")
    }
    "$name booting on $serial ..."
    # gate ledger entry: the booting emulator's memory
    Start-Sleep 3
    $qemu = Get-SysProcs -Name '^(qemu-system|emulator)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" } | Sort-Object Created -Descending | Select-Object -First 1
    if ($qemu) { @{ pid = $qemu.Id; need = 4.5; kind = 'emulator'; cmd = "emulator $name"; dir = $c.dir; started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content (Join-Path $ledger "$($qemu.Id).json") }
  }
  $out += [pscustomobject]@{ lane = $name; serial = $serial; port = $l.port }
}
$ready = @()
foreach ($o in $out) {
  # bounded wait: wait-for-device hangs if it dies
  $booted = $false
  for ($i = 0; $i -lt 120; $i++) { if ((& $adb -s $o.serial shell getprop sys.boot_completed 2>$null) -match '1') { $booted = $true; break }; Start-Sleep 3 }
  if (-not $booted) {
    Write-Warning "$($o.lane) did not finish booting in 6 min: killing it (a hidden emulator would otherwise keep its RAM)"
    Get-SysProcs -Name '^(emulator|qemu-system)' | Where-Object { $_.CommandLine -match "-port\s+$($o.port)\b" } | ForEach-Object { Stop-SysProcess $_.Id }
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
foreach ($i in 1..3) { Start-Sleep 4; & $KitCmd.swarm arrange | Out-Null }
& $KitCmd.swarm arrange
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
  $serial = "emulator-$($l.port)"
  if ((& $adb devices) -match "^$serial\s+device") {
    & $adb -s $serial reverse --remove-all 2>$null
    & $adb -s $serial emu kill | Out-Null
    # `emu kill` may be ignored: verify, then force-stop
    for ($i = 0; $i -lt 45 -and ((& $adb devices) -match "^$serial\s"); $i++) { Start-Sleep 2 }
    if ((& $adb devices) -match "^$serial\s") {
      Get-SysProcs -Name '^(qemu-system|emulator)' | Where-Object { $_.CommandLine -match "-port\s+$($l.port)\b" } | ForEach-Object { Stop-SysProcess $_.Id }
      Start-Sleep 3
      "$($l.name) ($serial) did not stop on request: process killed$(if ((& $adb devices) -match "^$serial\s") { ' - STILL LISTED, check by hand' })"
    } else { "$($l.name) ($serial) stopped" }
  } else { "$($l.name) not running" }
}
if (-not $KeepBrowsers) {
  $hc = Get-SysProcs -Name '(?i)^(chrome|msedge|chromium(-browser)?|chrome-headless-shell|google chrome|microsoft edge)(\.exe)?$' | Where-Object { $_.CommandLine -match '--headless' -and $_.CommandLine -match 'chrome-profiles' }
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
$disable = @(
  'com.google.android.googlequicksearchbox',   # Google app / Assistant
  'com.google.android.as',                     # Android System Intelligence
  'com.google.android.as.oss',                 # Private Compute Services
  'com.android.vending',                       # Play Store
  'com.google.android.youtube',
  'com.google.android.apps.youtube.music',
  'com.google.android.apps.youtube.kids',
  'com.google.android.gm',                     # Gmail
  'com.google.android.apps.photos',
  'com.google.android.apps.docs',              # Drive
  'com.google.android.apps.tachyon',           # Meet
  'com.google.android.calendar',
  'com.google.android.apps.subscriptions.red', # Google One
  'com.google.android.apps.wellbeing',
  'com.google.android.apps.turbo',             # Device Health Services
  'com.google.android.projection.gearhead',    # Android Auto
  'com.google.android.apps.safetyhub',         # Personal Safety
  'com.google.android.feedback',
  'com.google.android.printservice.recommendation',
  'com.google.android.apps.wallpaper',
  'com.google.android.apps.nbu.files',         # Files by Google
  'com.google.android.videos',
  'com.google.android.apps.restore',
  'com.google.android.apps.pixelmigrate'
)
$installed = (A pm list packages) -replace '^package:', ''
$done = @()
foreach ($p in $disable) {
  if ($installed -contains $p) { $r = A pm disable-user --user 0 $p; if ($r -match 'disabled') { $done += $p } }
}

# automation: no animations, screen on, no lock
A settings put global window_animation_scale 0 | Out-Null
A settings put global transition_animation_scale 0 | Out-Null
A settings put global animator_duration_scale 0 | Out-Null
A settings put global stay_on_while_plugged_in 7 | Out-Null
A settings put system screen_off_timeout 1800000 | Out-Null
A locksettings set-disabled true | Out-Null
A settings put global bluetooth_on 0 | Out-Null
A svc bluetooth disable | Out-Null
A settings put global wifi_scan_always_enabled 0 | Out-Null
A settings put global ble_scan_always_enabled 0 | Out-Null
A settings put secure location_mode 3 | Out-Null          # high accuracy (GPS + network)
A settings put global package_verifier_enable 0 | Out-Null
A 'echo slimmed > /sdcard/.qa-slimmed' | Out-Null

"$Serial slimmed: disabled $($done.Count) packages ($($done -join ', '))"
}

# ---- arrange: place emulator windows (Windows; run by up)
function Invoke-Arrange {
param([int]$Gap = 16, [double]$HeightShare = 0.78)   # share of the monitor's height
# lane-order row centred on the main monitor (physical px); Windows only
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { 'window arranging is Windows-only (Win32 APIs): skipped - place emulator windows by hand or use swarm.ps1 up -Headless'; return }
Add-Type @'
using System; using System.Runtime.InteropServices;
public class SwarmWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT rc; public RECT work; public uint flags; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@ -ErrorAction SilentlyContinue
[SwarmWin]::SetProcessDPIAware() | Out-Null
$mi = New-Object SwarmWin+MONITORINFO; $mi.cb = [Runtime.InteropServices.Marshal]::SizeOf($mi)
[SwarmWin]::GetMonitorInfo([SwarmWin]::MonitorFromPoint((New-Object SwarmWin+POINT), 1), [ref]$mi) | Out-Null   # 1 = primary
$work = $mi.work

$order = @((Get-SwarmConfig).lanes.name)
$wins = Get-Process | Where-Object { $_.MainWindowTitle -match 'Android Emulator - (\w+):' -and $_.MainWindowHandle -ne 0 } |
  ForEach-Object { $null = $_.MainWindowTitle -match 'Android Emulator - (\w+):'; [pscustomobject]@{ Lane = $Matches[1]; H = $_.MainWindowHandle } } |
  Sort-Object { [array]::IndexOf($order, $_.Lane) }
if (-not $wins) { 'no emulator windows found'; return }

# centre the row on the main monitor
$sizes = foreach ($w in $wins) { [SwarmWin]::ShowWindow($w.H, 9) | Out-Null; $r = New-Object SwarmWin+RECT; [SwarmWin]::GetWindowRect($w.H, [ref]$r) | Out-Null; [pscustomobject]@{ W = $w; Width = $r.R - $r.L; Height = $r.B - $r.T } }
# width from the first phone's aspect
$ref = $sizes[0]; $h = [int]((($work.B - $work.T) * $HeightShare)); $w = [int]($ref.Width * $h / $ref.Height)
foreach ($s in $sizes) { $s.Width = $w; $s.Height = $h }
$total = ($sizes | Measure-Object Width -Sum).Sum + $Gap * ($sizes.Count - 1)
$tallest = ($sizes | Measure-Object Height -Maximum).Maximum
$x = $work.L + [math]::Max(0, [int](($work.R - $work.L - $total) / 2))
$y = $work.T + [math]::Max(0, [int](($work.B - $work.T - $tallest) / 2))
$placed = @()
foreach ($s in $sizes) {
  [SwarmWin]::SetWindowPos($s.W.H, [IntPtr]::Zero, $x, $y, $s.Width, $s.Height, 0x0004) | Out-Null   # NOZORDER, explicit equal size
  $placed += "$($s.W.Lane) at x=$x"
  $x += $s.Width + $Gap
}
if ($total -gt ($work.R - $work.L)) { Write-Warning 'windows are wider than the main monitor - they overlap' }
"main monitor $($work.R - $work.L)x$($work.B - $work.T): " + ($placed -join ', ') + " (y=$y)"
}

if ($MyInvocation.InvocationName -ne '.') {   # dot-sourced (tests): functions only
  switch ($__verb) {
    { $_ -in 'acquire', 'ensure', 'release', 'status' } { Invoke-KitVerb Invoke-Phone (@($__verb) + $__rest) }
    'build' { Invoke-KitVerb Invoke-Build $__rest }
    'install' { Invoke-KitVerb Invoke-Install $__rest }
    'launch' { Invoke-KitVerb Invoke-Launch $__rest }
    'avd' { Invoke-KitVerb Invoke-Avd $__rest }
    'up' { Invoke-KitVerb Invoke-Up $__rest }
    'down' { Invoke-KitVerb Invoke-Down $__rest }
    'slim' { Invoke-KitVerb Invoke-Slim $__rest }
    'arrange' { Invoke-KitVerb Invoke-Arrange $__rest }
    { $_ -in '-h', '--help', 'help', '-?' } { Get-Content $PSCommandPath -TotalCount 14 | Select-Object -Skip 1; exit 0 }
    default { Get-Content $PSCommandPath -TotalCount 14 | Select-Object -Skip 1; exit 2 }
  }
}
