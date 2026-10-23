#Requires -Version 7
# ios-simulator (goody): pokey.ps1 ui on iOS Simulators (devices.type ios; $env:KIT_DEVICE = udid): shot, openurl, log. pokey.ps1 ui hands
# every call to Invoke-UiIos when this file is present (dot-sourced from adapters/).
function Invoke-UiIos {
param([Parameter(Position = 0)][string]$Action = 'dump', [Parameter(Position = 1)][string]$Arg = '', [Parameter(Position = 2)][string]$Arg2 = '',
      [Parameter(Position = 3)][string]$Arg3 = '', [Parameter(Position = 4)][string]$Arg4 = '')
$adb = Join-Path (Get-AndroidSdk) (Join-Path 'platform-tools' (Get-ExeName 'adb'))   # ANDROID_HOME / ANDROID_SDK_ROOT / OS default
$dt = Get-KitSetting 'devices.type' 'android'
if ($dt -eq 'none') { 'no devices (devices.type none): app checks are NOT_TESTED'; exit 1 }
$ios = $dt -eq 'ios'   # Simulator: $env:KIT_DEVICE = udid
$tag = if ($ios) { if ($env:KIT_DEVICE) { $env:KIT_DEVICE } else { 'booted' } } elseif ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { 'default' }
if ($ios -and $Action -notin 'shot', 'openurl', 'log') { "ios: no ui $Action (simctl has no UI driver): use shot | openurl | log, prove the rest via the API"; exit 2 }
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
function Tap($n, $w) { if ($n) { & $adb shell input tap $n.x $n.y; "tapped $(if ($w -like '#*') { "#$($n.rid)" } else { "'$($n.text)'" }) at $($n.x),$($n.y)" } else { "NOT FOUND: $w" } }
function Shot($name, $dir) {
  if (-not $dir) { $dir = Join-Path (Get-KitPath shots) $tag }; New-Item -ItemType Directory -Force $dir | Out-Null; $f = Join-Path $dir "$name.png"; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  if ($ios) { xcrun simctl io $tag screenshot $f | Out-Null } else { & $adb shell screencap -p /sdcard/qa_shot.png | Out-Null; & $adb pull /sdcard/qa_shot.png $f 2>&1 | Out-Null }
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
  'openurl' { if ($ios) { xcrun simctl openurl $tag $Arg } else { & $adb shell am start -a android.intent.action.VIEW -d $Arg | Out-Null }; "opened $Arg" }
  'shot' { "saved $(Shot $Arg $Arg2)" }
  'shotmark' {
    # Arg name, Arg2 text or #id ('|' between), Arg3 label, Arg4 dir
    $all = Get-Nodes
    $rects = foreach ($want in ($Arg2 -split '\s*\|\s*')) {
      $n = Find $all $want
      if ($n) { "$($n.l - 6),$($n.t - 6),$($n.w + 12),$($n.h + 12),$(if ($Arg3) { $Arg3 } else { $n.text })" } else { Write-Warning "NOT FOUND: $want (screenshot taken without a mark for it)" }
    }
    $f = Shot $Arg $Arg4
    if ($rects -and -not $KitIsWindows) { Write-Warning 'marks need pokey.ps1 annotate (Windows only): screenshot saved unmarked - name the element in the check note'; $rects = $null }
    if ($rects) { & $KitCmd.qa annotate -In $f -Rect @($rects) | Out-Null }
    "saved $f$(if ($rects) { " with $(@($rects).Count) mark(s)" })"
  }
  'wait' {
    $end = (Get-Date).AddSeconds($(if ($Arg2) { [int]$Arg2 } else { 30 }))
    # not `if (try ...)`: in ( ) `try` is a command
    while ((Get-Date) -lt $end) { $hit = try { Get-Nodes | Where-Object { $_.text -like "*$Arg*" } } catch { $null }; if ($hit) { "found '$Arg'"; return }; Start-Sleep 2 }
    "TIMEOUT waiting for '$Arg'"
  }
  'photo' {
    # shutter: -Arg id suffix, else common ids; Arg2 = confirm text
    Start-Sleep 3
    $all = Get-Nodes
    $n = @(@($(if ($Arg) { $Arg } else { 'take-image-button', 'shutter', 'capture', 'take_photo', 'camera_button', 'btnCapture' }) | ForEach-Object { Find $all "#$_" }) + @($all | Where-Object { $_.text -match (Get-KitSetting 'qa.shutterText' '^(Take photo|Capture|Shutter|Take picture)$') }))[0]
    if (-not $n) { "NOT FOUND: no shutter (pass its resource-id: pokey.ps1 ui photo <id>; pokey.ps1 ui dump shows ids)"; return }
    & $adb shell input tap $n.x $n.y; Start-Sleep 4
    $ok = Get-Nodes | Where-Object { $_.text -match $(if ($Arg2) { "^$([regex]::Escape($Arg2))$" } else { (Get-KitSetting 'qa.confirmText' '^(OK|Done|Use photo|Save|Confirm|✓|Use)$') }) } | Select-Object -First 1
    if ($ok) { & $adb shell input tap $ok.x $ok.y; Start-Sleep 2; "photo taken and accepted ('$($ok.text)')" } else { "photo taken (no confirm step seen)" }
  }
  'log' { if ($ios) { xcrun simctl spawn $tag log show --last 5m --style compact --predicate $(if ($Arg) { "process == '$Arg'" } else { 'messageType == error' }) } else { & $adb logcat -d -t 300 -s $(if ($Arg) { $Arg } else { '*:E' }) } }
  default { "unknown action $Action (pokey.ps1 ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo)"; exit 2 }
}
}
