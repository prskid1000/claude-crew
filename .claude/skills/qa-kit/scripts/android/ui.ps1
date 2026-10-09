<#
Android UI helper for any app on an emulator or device (via uiautomator + adb input).

  $env:ANDROID_SERIAL = 'emulator-5556'      # ALWAYS set your own phone first when several devices are attached
  & <workspace>\.claude\skills\qa-kit\scripts\android\ui.ps1 dump                 # visible texts with @(x,y) centre, [edit], #resource-id
  & ... ui.ps1 tap "Start shift"           # tap by text (exact, then contains)
  & ... ui.ps1 tapid "login_button"        # tap by resource-id (suffix match)
  & ... ui.ps1 tapxy 640 1400
  & ... ui.ps1 type "hello world"          # into the focused field
  & ... ui.ps1 key 4                       # keyevent (4 = BACK, 66 = ENTER)
  & ... ui.ps1 swipe 640 2000 640 800      # scroll
  & ... ui.ps1 shot T3_after_save [<dir>]  # PNG screenshot (default dir: <.claude-runtime>\shots\<serial>)
  & ... ui.ps1 shotmark T3_total "Total|#save_btn" ["wrong total"] [<dir>]   # screenshot + red box/label on those elements, one go
  & ... ui.ps1 wait "Welcome" 30           # wait up to N s for a text
  & ... ui.ps1 log ReactNativeJS           # recent logcat lines for a tag (clear with: adb logcat -c)
  & ... ui.ps1 photo [shutterId] [okText]  # after tapping the app's camera icon: press the shutter, accept the photo
#>
param([Parameter(Position = 0)][string]$Action = 'dump', [Parameter(Position = 1)][string]$Arg = '', [Parameter(Position = 2)][string]$Arg2 = '',
      [Parameter(Position = 3)][string]$Arg3 = '', [Parameter(Position = 4)][string]$Arg4 = '')
$adb = if ($env:ANDROID_HOME) { "$env:ANDROID_HOME\platform-tools\adb.exe" } else { "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($MyInvocation.MyCommand.Path -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }   # runtime output lives outside .claude
$tag = if ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { 'default' }
$tmp = Join-Path $rt "android"; New-Item -ItemType Directory -Force $tmp | Out-Null
$xmlLocal = Join-Path $tmp "ui_$tag.xml"
function Get-Nodes {
  & $adb shell uiautomator dump /sdcard/ui.xml | Out-Null
  & $adb pull /sdcard/ui.xml $xmlLocal | Out-Null
  [xml]$x = Get-Content $xmlLocal -Raw
  $x.SelectNodes('//node') | ForEach-Object {
    $t = if ($_.text) { $_.text } elseif ($_.'content-desc') { $_.'content-desc' } else { '' }
    if ($_.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      [pscustomobject]@{ text = $t; rid = $_.'resource-id'; cls = $_.class; x = [int](([int]$Matches[1] + [int]$Matches[3]) / 2); y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
        l = [int]$Matches[1]; t = [int]$Matches[2]; w = [int]$Matches[3] - [int]$Matches[1]; h = [int]$Matches[4] - [int]$Matches[2] }
    }
  }
}
switch ($Action) {
  'dump' { Get-Nodes | Where-Object { $_.text -or $_.rid -or $_.cls -match 'EditText' } | ForEach-Object { '{0} @({1},{2}){3}{4}' -f $_.text, $_.x, $_.y, $(if ($_.cls -match 'EditText') { ' [edit]' }), $(if ($_.rid) { " #$($_.rid)" }) } }
  'tap' {
    $all = Get-Nodes
    $n = $all | Where-Object { $_.text -eq $Arg } | Select-Object -First 1
    if (-not $n) { $n = $all | Where-Object { $_.text -like "*$Arg*" } | Select-Object -First 1 }
    if ($n) { & $adb shell input tap $n.x $n.y; "tapped '$($n.text)' at $($n.x),$($n.y)" } else { "NOT FOUND: $Arg" }
  }
  'tapid' {
    $n = Get-Nodes | Where-Object { $_.rid -like "*$Arg" } | Select-Object -First 1
    if ($n) { & $adb shell input tap $n.x $n.y; "tapped #$($n.rid) at $($n.x),$($n.y)" } else { "NOT FOUND: #$Arg" }
  }
  'tapxy' { & $adb shell input tap $Arg $Arg2; "tapped $Arg,$Arg2" }
  'type' { & $adb shell input text ($Arg -replace ' ', '%s' -replace '([#&;()<>|$''"])', '\$1'); 'typed' }
  'key' { & $adb shell input keyevent $Arg; "key $Arg" }
  'swipe' { & $adb shell input swipe $Arg $Arg2 $Arg3 $Arg4 400; 'swiped' }
  'shot' {
    $dir = if ($Arg2) { $Arg2 } else { Join-Path $rt "shots\$tag" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $f = Join-Path $dir "$Arg.png"
    & $adb shell screencap -p /sdcard/qa_shot.png | Out-Null; & $adb pull /sdcard/qa_shot.png $f | Out-Null
    "saved $f"
  }
  'shotmark' {
    # one go: screenshot + red box (and label) around the element found by text or #resource-id. Arg = name, Arg2 = text or #id,
    # Arg3 = label (default: the element text), Arg4 = dir. Several elements: separate with ' | ' in Arg2.
    $dir = if ($Arg4) { $Arg4 } else { Join-Path $rt "shots\$tag" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $f = Join-Path $dir "$Arg.png"
    $all = Get-Nodes
    $rects = foreach ($want in ($Arg2 -split '\s*\|\s*')) {
      $n = if ($want -like '#*') { $all | Where-Object { $_.rid -like "*$($want.TrimStart('#'))" } | Select-Object -First 1 }
           else { ($all | Where-Object { $_.text -eq $want } | Select-Object -First 1) ?? ($all | Where-Object { $_.text -like "*$want*" } | Select-Object -First 1) }
      if ($n) { "$($n.l - 6),$($n.t - 6),$($n.w + 12),$($n.h + 12),$(if ($Arg3) { $Arg3 } else { $n.text })" } else { Write-Warning "NOT FOUND: $want (screenshot taken without a mark for it)" }
    }
    & $adb shell screencap -p /sdcard/qa_shot.png | Out-Null; & $adb pull /sdcard/qa_shot.png $f | Out-Null
    if ($rects) { & (Join-Path (Split-Path $PSScriptRoot) 'annotate.ps1') -In $f -Rect @($rects) | Out-Null }
    "saved $f$(if ($rects) { " with $(@($rects).Count) mark(s)" })"
  }
  'wait' {
    $end = (Get-Date).AddSeconds($(if ($Arg2) { [int]$Arg2 } else { 30 }))
    while ((Get-Date) -lt $end) { if (Get-Nodes | Where-Object { $_.text -like "*$Arg*" }) { "found '$Arg'"; return }; Start-Sleep 2 }
    "TIMEOUT waiting for '$Arg'"
  }
  'photo' {
    # In-app camera: call after tapping the app's camera icon. Finds the shutter (resource-id suffix -Arg, else common ids/labels),
    # takes the picture, then accepts it if the app shows a confirm step. The emulator's back camera is a virtual scene, so any
    # photo works for upload/POD/inspection checks. Optional Arg2 = text of the confirm button (default: OK/Done/Use photo/Save/✓).
    Start-Sleep 3
    $all = Get-Nodes
    $ids = if ($Arg) { @($Arg) } else { @('take-image-button', 'shutter', 'capture', 'take_photo', 'camera_button', 'btnCapture') }
    $n = $null; foreach ($i in $ids) { $n = $all | Where-Object { $_.rid -like "*$i" } | Select-Object -First 1; if ($n) { break } }
    if (-not $n) { $n = $all | Where-Object { $_.text -match '^(Take photo|Capture|Shutter|Take picture)$' } | Select-Object -First 1 }
    if (-not $n) { "NOT FOUND: no shutter (pass its resource-id: ui.ps1 photo <id>; ui.ps1 dump shows ids)"; return }
    & $adb shell input tap $n.x $n.y; Start-Sleep 4
    $ok = Get-Nodes | Where-Object { $_.text -match $(if ($Arg2) { "^$([regex]::Escape($Arg2))$" } else { '^(OK|Done|Use photo|Save|Confirm|✓|Use)$' }) } | Select-Object -First 1
    if ($ok) { & $adb shell input tap $ok.x $ok.y; Start-Sleep 2; "photo taken and accepted ('$($ok.text)')" } else { "photo taken (no confirm step seen)" }
  }
  'log' { & $adb logcat -d -t 300 -s $(if ($Arg) { $Arg } else { '*:E' }) }
  default { "unknown action $Action" }
}
