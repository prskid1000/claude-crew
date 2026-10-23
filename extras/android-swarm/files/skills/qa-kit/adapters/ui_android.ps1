#Requires -Version 7
# android-swarm (extra): qa.ps1 ui on a leased Android phone and the laneApk kind of qa.ps1 deployed (dot-sourced from adapters/).
# Test-LaneApkDeployed runs inside Invoke-Deployed and uses its $sha, $s8, $mr, $p, Row, OnRef, LocalAncestor.

# ---- deployed laneApk: is the merge in the lane APK (apk/app.json stamp written by swarm.ps1 build)?
# laneApk: true -> <outDir>/apk/app.json; a string = its path
function LaneApk($d) {
  $f = if ($d.laneApk -is [string]) { $d.laneApk } else {
    $sc = Join-Path $KitConf.Kit 'skills/android-swarm/swarm.config.json'
    $o = if (Test-Path $sc) { (Get-Content $sc -Raw | ConvertFrom-Json).outDir }
    Join-Path $(if ($o) { [string]$o } else { Get-KitPath android-swarm }) 'apk/app.json'
  }
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}
function Test-LaneApkDeployed($d) {
  $ai = LaneApk $d
  if (-not $ai -or -not $ai.commit) { return (Row $d 'UNKNOWN' 'no lane APK stamp (android-swarm apk/app.json): build the APK with swarm.ps1 build') }
  $apk = "APK $($ai.commit) ($($ai.branch), built $($ai.built))"
  $on = LocalAncestor $ai.appDir $sha $ai.commit
  if (-not $on) { $on = OnRef $p $mr $sha $ai.commit $ai.branch }   # else ask the git host
  if ($on) { Row $d 'DEPLOYED' "in the lane $apk (phones get it on their next swarm.ps1 acquire)" }
  else { Row $d 'NOT-DEPLOYED' "$s8 is not in the lane ${apk}: rebuild it (swarm.ps1 build) from a branch holding the merge" }
}

# ---- ui: drive the app on your leased phone (uiautomator + adb; $env:ANDROID_SERIAL)
function Invoke-Ui {
param([Parameter(Position = 0)][string]$Action = 'dump', [Parameter(Position = 1)][string]$Arg = '', [Parameter(Position = 2)][string]$Arg2 = '',
      [Parameter(Position = 3)][string]$Arg3 = '', [Parameter(Position = 4)][string]$Arg4 = '')
$adb = Join-Path (Get-AndroidSdk) (Join-Path 'platform-tools' (Get-ExeName 'adb'))   # ANDROID_HOME / ANDROID_SDK_ROOT / OS default
$dt = Get-KitSetting 'devices.type' 'android'
if ($dt -eq 'none') { 'no devices (devices.type none): app checks are NOT_TESTED'; exit 1 }
if ($dt -eq 'ios') {
  if ($ext = Get-Command Invoke-UiIos -ErrorAction SilentlyContinue) { return & $ext @PSBoundParameters }
  [Console]::Error.WriteLine('devices.type ios is an extra: run kittool.py extra add ios-simulator'); exit 1
}
$tag = if ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { 'default' }
$xmlLocal = Join-Path (Get-KitPath android-tmp -Create) "ui_$tag.xml"
function Get-Nodes {
  # a failed dump must not return the old screen
  & $adb shell rm -f /sdcard/ui.xml | Out-Null; Remove-Item $xmlLocal -Force -ErrorAction SilentlyContinue
  & $adb shell uiautomator dump /sdcard/ui.xml | Out-Null
  & $adb pull /sdcard/ui.xml $xmlLocal 2>$null | Out-Null
  if (-not (Test-Path $xmlLocal)) { throw 'uiautomator dump failed (no fresh ui.xml): screen busy or device offline - retry' }
  [xml]$x = Get-Content $xmlLocal -Raw
  $x.SelectNodes('//node') | ForEach-Object {
    $t = if ($_.text) { $_.text } elseif ($_.'content-desc') { $_.'content-desc' } else { '' }
    if ($_.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $l, $u, $r, $b = 1..4 | ForEach-Object { [int]$Matches[$_] }
      [pscustomobject]@{ text = $t; rid = $_.'resource-id'; cls = $_.class; x = [int](($l + $r) / 2); y = [int](($u + $b) / 2); l = $l; t = $u; w = $r - $l; h = $b - $u }
    }
  }
}
# text (exact, then contains) or #<resource-id suffix>
function Find($all, $w) { if ($w -like '#*') { $all | Where-Object { $_.rid -like "*$($w.TrimStart('#'))" } | Select-Object -First 1 } else { ($all | Where-Object { $_.text -eq $w } | Select-Object -First 1) ?? ($all | Where-Object { $_.text -like "*$w*" } | Select-Object -First 1) } }
function Tap($n, $w) { if ($n) { & $adb shell input tap $n.x $n.y; "tapped $(if ($w -like '#*') { "#$($n.rid)" } else { "'$($n.text)'" }) at $($n.x),$($n.y)" } else { "NOT FOUND: $w"; $script:uiFailed = $true } }
function Shot($name, $dir) {
  if (-not $dir) { $dir = Join-Path (Get-KitPath shots) $tag }; New-Item -ItemType Directory -Force $dir | Out-Null; $f = Join-Path $dir "$name.png"; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  & $adb shell screencap -p /sdcard/qa_shot.png | Out-Null; & $adb pull /sdcard/qa_shot.png $f 2>&1 | Out-Null
  if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) { throw "screenshot failed (device $tag offline?): nothing saved to $f" }; $f
}
switch ($Action) {
  'dump' { Get-Nodes | Where-Object { $_.text -or $_.rid -or $_.cls -match 'EditText' } | ForEach-Object { '{0} @({1},{2}){3}{4}' -f $_.text, $_.x, $_.y, $(if ($_.cls -match 'EditText') { ' [edit]' }), $(if ($_.rid) { " #$($_.rid)" }) } }
  'tap' { Tap (Find (Get-Nodes) $Arg) $Arg }
  'tapid' { Tap (Find (Get-Nodes) "#$Arg") "#$Arg" }
  'tapxy' { & $adb shell input tap $Arg $Arg2; "tapped $Arg,$Arg2" }
  'type' { & $adb shell input text ($Arg -replace ' ', '%s' -replace '([#&;()<>|$''"])', '\$1'); 'typed' }
  'key' { & $adb shell input keyevent $Arg; "key $Arg" }
  'swipe' { & $adb shell input swipe $Arg $Arg2 $Arg3 $Arg4 400; 'swiped' }
  'openurl' { & $adb shell am start -a android.intent.action.VIEW -d $Arg | Out-Null; "opened $Arg" }
  'shot' { "saved $(Shot $Arg $Arg2)" }
  'shotmark' {
    # Arg name, Arg2 text or #id ('|' between), Arg3 label, Arg4 dir
    $all = Get-Nodes
    $rects = foreach ($want in ($Arg2 -split '\s*\|\s*')) {
      $n = Find $all $want
      if ($n) { "$($n.l - 6),$($n.t - 6),$($n.w + 12),$($n.h + 12),$(if ($Arg3) { $Arg3 } else { $n.text })" } else { Write-Warning "NOT FOUND: $want (screenshot taken without a mark for it)" }
    }
    $f = Shot $Arg $Arg4
    if ($rects -and -not $KitIsWindows) { Write-Warning 'marks need qa.ps1 annotate (Windows only): screenshot saved unmarked - name the element in the check note'; $rects = $null }
    if ($rects) { & $KitCmd.qa annotate -In $f -Rect @($rects) | Out-Null }
    "saved $f$(if ($rects) { " with $(@($rects).Count) mark(s)" })"
  }
  'wait' {
    $end = (Get-Date).AddSeconds($(if ($Arg2) { [int]$Arg2 } else { 30 }))
    # not `if (try ...)`: in ( ) `try` is a command
    while ((Get-Date) -lt $end) { $hit = try { Get-Nodes | Where-Object { $_.text -like "*$Arg*" } } catch { $null }; if ($hit) { "found '$Arg'"; return }; Wait-KitPoll 2 }
    "TIMEOUT waiting for '$Arg'"; exit 1
  }
  'photo' {
    # shutter: -Arg id suffix, else common ids; Arg2 = confirm text
    Start-Sleep 3
    $all = Get-Nodes
    $n = @(@($(if ($Arg) { $Arg } else { 'take-image-button', 'shutter', 'capture', 'take_photo', 'camera_button', 'btnCapture' }) | ForEach-Object { Find $all "#$_" }) + @($all | Where-Object { $_.text -match (Get-KitSetting 'qa.shutterText' '^(Take photo|Capture|Shutter|Take picture)$') }))[0]
    if (-not $n) { "NOT FOUND: no shutter (pass its resource-id: qa.ps1 ui photo <id>; qa.ps1 ui dump shows ids)"; exit 1 }
    & $adb shell input tap $n.x $n.y; Start-Sleep 4
    $ok = Get-Nodes | Where-Object { $_.text -match $(if ($Arg2) { "^$([regex]::Escape($Arg2))$" } else { (Get-KitSetting 'qa.confirmText' '^(OK|Done|Use photo|Save|Confirm|✓|Use)$') }) } | Select-Object -First 1
    if ($ok) { & $adb shell input tap $ok.x $ok.y; Start-Sleep 2; "photo taken and accepted ('$($ok.text)')" } else { "photo taken (no confirm step seen)" }
  }
  'log' { & $adb logcat -d -t 300 -s $(if ($Arg) { $Arg } else { '*:E' }) }
  default { "unknown action $Action (qa.ps1 ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo)"; exit 2 }
}
if ($script:uiFailed) { exit 1 }   # NOT FOUND: the caller must not read it as done
}
