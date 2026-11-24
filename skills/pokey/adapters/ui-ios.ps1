#Requires -Version 7
# Usage: dot-sourced by pokey.ps1 from adapters/. Exit codes: none here (its verbs exit through pokey.ps1).
# ios-simulator: pokey.ps1 ui on iOS Simulators (devices.type ios; $env:KIT_DEVICE = udid, else the booted one): shot, openurl,
# log through xcrun simctl; dump, tap, tapid, tapxy, type, clear, key, swipe, shotmark, wait through idb (fb-idb + idb_companion:
# the accessibility tree and HID input simctl lacks). photo / mic refuse (parity.json device). pokey.ps1 ui hands every call here
# when devices.type is ios.
function Invoke-UiIos {
param([Parameter(Position = 0)][string]$Action = 'dump', [Parameter(Position = 1)][string]$Arg = '', [Parameter(Position = 2)][string]$Arg2 = '',
      [Parameter(Position = 3)][string]$Arg3 = '', [Parameter(Position = 4)][string]$Arg4 = '')
$tag = if ($env:KIT_DEVICE) { $env:KIT_DEVICE } else { 'booted' }
if (-not $KitAdapters.device.ios.ContainsKey($Action)) { "ios: no ui $Action (a Simulator has no camera and no audio injection): use $(@($KitAdapters.device.ios.Keys | Sort-Object) -join ' | '), prove the rest on an android lane or by hand"; exit 2 }
$idbUdid = if ($env:KIT_DEVICE) { @('--udid', $env:KIT_DEVICE) } else { @() }
function Invoke-Idb([string[]]$IdbArgs) {
  if (-not (Get-Command idb -ErrorAction SilentlyContinue)) { throw 'ios ui: idb not found (pip install fb-idb; brew install facebook/fb/idb-companion)' }
  $out = & idb @IdbArgs 2>&1; if ($LASTEXITCODE) { throw "idb $($IdbArgs[0..1] -join ' ') failed (exit $LASTEXITCODE): $(@($out)[0])" }; $out
}
function Get-Nodes {
  # the accessibility tree in points: a JSON array (older idb: one element per line)
  $raw = @(Invoke-Idb (@('ui', 'describe-all') + $idbUdid + @('--json'))) -join "`n"
  $els = try { @($raw | ConvertFrom-Json) } catch { @($raw -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
  foreach ($el in @($els | ForEach-Object { $_ })) {
    $fr = $el.frame; if (-not $fr) { continue }
    $t = if ($el.AXLabel) { "$($el.AXLabel)" } elseif ($el.AXValue) { "$($el.AXValue)" } else { '' }
    $l, $u, $w, $h = [int]$fr.x, [int]$fr.y, [int]$fr.width, [int]$fr.height
    [pscustomobject]@{ text = $t; rid = "$($el.AXUniqueId)"; cls = "$($el.type)"; x = [int]($l + $w / 2); y = [int]($u + $h / 2); l = $l; t = $u; w = $w; h = $h }
  }
}
# text (exact, then contains) or #<accessibility id suffix>
function Find($all, $w) { if ($w -like '#*') { $all | Where-Object { $_.rid -and $_.rid -like "*$($w.TrimStart('#'))" } | Select-Object -First 1 } else { ($all | Where-Object { $_.text -eq $w } | Select-Object -First 1) ?? ($all | Where-Object { $_.text -like "*$w*" } | Select-Object -First 1) } }
function Tap($n, $w) { if ($n) { $null = Invoke-Idb (@('ui', 'tap') + $idbUdid + @("$($n.x)", "$($n.y)")); "tapped $(if ($w -like '#*') { "#$($n.rid)" } else { "'$($n.text)'" }) at $($n.x),$($n.y)" } else { "NOT FOUND: $w" } }
function Shot($name, $dir) {
  if (-not $dir) { $dir = Join-Path (Get-KitPath shots) $tag }; New-Item -ItemType Directory -Force $dir | Out-Null; $f = Join-Path $dir "$name.png"; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  xcrun simctl io $tag screenshot $f | Out-Null
  if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) { throw "screenshot failed (simulator $tag not booted?): nothing saved to $f" }; $f
}
# screenshot pixels per point: the PNG width (IHDR, bytes 16-19) / the widest element's right edge
function Get-ShotScale($f, $all) {
  $b = [IO.File]::ReadAllBytes($f); $px = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
  $pt = ($all | ForEach-Object { $_.l + $_.w } | Measure-Object -Maximum).Maximum; if ($pt -gt 0) { $px / $pt } else { 1 }
}
# HID usage ids (idb ui key): Android-style names map to them; a number passes through
$keys = @{ ENTER = 40; RETURN = 40; BACK = 41; ESCAPE = 41; DEL = 42; BACKSPACE = 42; TAB = 43; SPACE = 44 }
switch ($Action) {
  'dump' { Get-Nodes | Where-Object { $_.text -or $_.rid -or $_.cls -match 'TextField|TextView|SearchField' } | ForEach-Object { '{0} @({1},{2}){3}{4}' -f $_.text, $_.x, $_.y, $(if ($_.cls -match 'TextField|TextView|SearchField') { ' [edit]' }), $(if ($_.rid) { " #$($_.rid)" }) } }
  'tap' { Tap (Find (Get-Nodes) $Arg) $Arg }
  'tapid' { Tap (Find (Get-Nodes) "#$Arg") "#$Arg" }
  'tapxy' { $null = Invoke-Idb (@('ui', 'tap') + $idbUdid + @($Arg, $Arg2)); "tapped $Arg,$Arg2" }
  'type' { $null = Invoke-Idb (@('ui', 'text') + $idbUdid + @($Arg)); 'typed' }
  # the focused field; Arg = deletes
  'clear' { $null = Invoke-Idb (@('ui', 'key-sequence') + $idbUdid + @(1..$(if ($Arg) { [int]$Arg } else { 50 }) | ForEach-Object { '42' })); 'cleared' }
  'key' {
    $kn = ($Arg -replace '^KEYCODE_', '').ToUpper()
    if ($kn -eq 'HOME') { $null = Invoke-Idb (@('ui', 'button') + $idbUdid + @('HOME')) }
    elseif ($kn -match '^\d+$' -or $keys.ContainsKey($kn)) { $null = Invoke-Idb (@('ui', 'key') + $idbUdid + @("$(if ($keys.ContainsKey($kn)) { $keys[$kn] } else { $kn })")) }
    else { "ios: key $Arg unknown (a HID usage number, HOME or $(@($keys.Keys | Sort-Object) -join ' | '))"; exit 2 }
    "key $Arg"
  }
  'swipe' { $null = Invoke-Idb (@('ui', 'swipe') + $idbUdid + @($Arg, $Arg2, $Arg3, $Arg4, '--duration', '0.4')); 'swiped' }
  'openurl' { xcrun simctl openurl $tag $Arg; "opened $Arg" }
  'shot' { "saved $(Shot $Arg $Arg2)" }
  'shotmark' {
    # Arg name, Arg2 text or #id ('|' between), Arg3 label, Arg4 dir; marks in screenshot pixels (points x scale)
    $all = @(Get-Nodes); $f = Shot $Arg $Arg4; $sc = Get-ShotScale $f $all
    $rects = foreach ($want in ($Arg2 -split '\s*\|\s*')) {
      $n = Find $all $want
      if ($n) { "$([int](($n.l - 3) * $sc)),$([int](($n.t - 3) * $sc)),$([int](($n.w + 6) * $sc)),$([int](($n.h + 6) * $sc)),$(if ($Arg3) { $Arg3 } else { $n.text })" } else { Write-Warning "NOT FOUND: $want (screenshot taken without a mark for it)" }
    }
    if ($rects -and -not $KitIsWindows) { Write-Warning 'marks need pokey.ps1 annotate (Windows only): screenshot saved unmarked - name the element in the check note'; $rects = $null }
    if ($rects) { & $KitCmd.qa annotate -In $f -Rect @($rects) | Out-Null }
    "saved $f$(if ($rects) { " with $(@($rects).Count) mark(s)" })"
  }
  'wait' {
    $end = (Get-Date).AddSeconds($(if ($Arg2) { [int]$Arg2 } else { 30 }))
    # poll-ok: bounded by the timeout; not `if (try ...)`: in ( ) `try` is a command
    while ((Get-Date) -lt $end) { $hit = try { Get-Nodes | Where-Object { $_.text -like "*$Arg*" } } catch { $null }; if ($hit) { "found '$Arg'"; return }; Start-Sleep 2 }
    "TIMEOUT waiting for '$Arg'"
  }
  'log' { xcrun simctl spawn $tag log show --last 5m --style compact --predicate $(if ($Arg) { "process == '$Arg'" } else { 'messageType == error' }) }
}
}
