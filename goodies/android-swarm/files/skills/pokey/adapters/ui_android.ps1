#Requires -Version 7
# android-swarm (goody): pokey.ps1 ui on a leased Android phone and the laneApk kind of pokey.ps1 deployed (dot-sourced from adapters/).
# Test-LaneApkDeployed runs inside Invoke-Deployed and uses its $sha, $s8, $mr, $p, Row, OnRef, LocalAncestor.
# Sections: L6 deployed laneApk · L26 ui

# ---- deployed laneApk: is the merge in the lane APK (apk/app.json stamp written by phoney.ps1 build)?
# laneApk: true -> <outDir>/apk/app.json; a string = its path
function LaneApk($d) {
  $f = if ($d.laneApk -is [string]) { $d.laneApk } else {
    $sc = Join-Path $KitConf.Kit 'skills/phoney/swarm.config.json'
    $o = if (Test-Path $sc) { (Get-Content $sc -Raw | ConvertFrom-Json).outDir }
    Join-Path $(if ($o) { [string]$o } else { Get-KitPath android-swarm }) 'apk/app.json'
  }
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}
function Test-LaneApkDeployed($d) {
  $ai = LaneApk $d
  if (-not $ai -or -not $ai.commit) { return (Row $d 'UNKNOWN' 'no lane APK stamp (android-swarm apk/app.json): build the APK with phoney.ps1 build') }
  $apk = "APK $($ai.commit) ($($ai.branch), built $($ai.built))"
  $on = LocalAncestor $ai.appDir $sha $ai.commit
  if (-not $on) { $on = OnRef $p $mr $sha $ai.commit $ai.branch }   # else ask the git host
  if ($on) { Row $d 'DEPLOYED' "in the lane $apk (phones get it on their next phoney.ps1 acquire)" }
  else { Row $d 'NOT-DEPLOYED' "$s8 is not in the lane ${apk}: rebuild it (phoney.ps1 build) from a branch holding the merge" }
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
  [Console]::Error.WriteLine('devices.type ios is a goody: run kitbag.py goody add ios-simulator'); exit 1
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
    if ($rects -and -not $KitIsWindows) { Write-Warning 'marks need pokey.ps1 annotate (Windows only): screenshot saved unmarked - name the element in the check note'; $rects = $null }
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
    if (-not $n) { "NOT FOUND: no shutter (pass its resource-id: pokey.ps1 ui photo <id>; pokey.ps1 ui dump shows ids)"; exit 1 }
    & $adb shell input tap $n.x $n.y; Start-Sleep 4
    $ok = Get-Nodes | Where-Object { $_.text -match $(if ($Arg2) { "^$([regex]::Escape($Arg2))$" } else { (Get-KitSetting 'qa.confirmText' '^(OK|Done|Use photo|Save|Confirm|✓|Use)$') }) } | Select-Object -First 1
    if ($ok) { & $adb shell input tap $ok.x $ok.y; Start-Sleep 2; "photo taken and accepted ('$($ok.text)')" } else { "photo taken (no confirm step seen)" }
  }
  'log' { & $adb logcat -d -t 300 -s $(if ($Arg) { $Arg } else { '*:E' }) }
  'mic' {
    # Arg = a 16-bit PCM WAV, or a phrase (Windows: spoken by System.Speech); start the app's listening first: audio sent
    # while nothing records is lost (gRPC injectAudio; endpoint + token from the emulator's discovery .ini)
    $port = if ($env:ANDROID_SERIAL -match '^emulator-(\d+)$') { $Matches[1] } else { 'mic: set ANDROID_SERIAL to your leased emulator'; exit 2 }
    $wav = $Arg
    if (-not $Arg -or (-not (Test-Path -LiteralPath $Arg) -and -not $KitIsWindows)) { 'usage: pokey.ps1 ui mic <16-bit PCM wav | phrase (Windows)> [timeout s]'; exit 2 }
    if (-not (Test-Path -LiteralPath $wav)) {
      Add-Type -AssemblyName System.Speech; $sp = [System.Speech.Synthesis.SpeechSynthesizer]::new(); $wav = Join-Path (Get-KitPath android-tmp -Create) "mic_$tag.wav"
      $sp.SetOutputToWaveFile($wav, [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(16000, 'Sixteen', 'Mono')); $sp.Speak($Arg); $sp.Dispose()
    }
    $ini = foreach ($d in @([IO.Path]::GetTempPath(), $env:XDG_RUNTIME_DIR, "$HOME/Library/Caches/TemporaryItems") | Where-Object { $_ }) { Get-ChildItem (Join-Path $d 'avd/running') -Filter 'pid_*.ini' -ErrorAction SilentlyContinue }
    $ini = $ini | Where-Object { Get-Process -Id ($_.BaseName -replace '^pid_') -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending   # a crashed emulator leaves its file
    $kv = $ini | ForEach-Object { $h = @{}; Get-Content $_.FullName | ForEach-Object { $k, $v = $_ -split '=', 2; $h[$k] = $v }; $h } | Where-Object { $_['port.serial'] -eq $port -and $_['grpc.port'] } | Select-Object -First 1
    if (-not $kv) { "mic: no gRPC endpoint for emulator-$port (booted by an older phoney.ps1 or with -no-audio): phoney.ps1 avd reset -Lanes <lane> -Level recreate"; exit 1 }
    # audio injected while nothing records crashes the emulator: wait up to 10 s for an active recording
    $rec = $false; for ($i = 0; $i -lt 10 -and -not $rec; $i++) { $rec = (& $adb shell dumpsys audio) -match 'active\? true'; if (-not $rec) { Start-Sleep 1 } }
    if (-not $rec) { "mic: the phone is not recording: start the app's listening first (nothing sent)"; exit 1 }
    $env:KIT_GRPC_TOKEN = $kv['grpc.token']
    $js = @'
import http2 from 'node:http2'; import fs from 'node:fs';
const [port, file, secs] = process.argv.slice(1), w = fs.readFileSync(file); let o = 12, rate = 16000, ch = 1, pcm;
while (o < w.length) { const id = w.toString('ascii', o, o + 4), n = w.readUInt32LE(o + 4);
  if (id === 'fmt ') { ch = w.readUInt16LE(o + 10); rate = w.readUInt32LE(o + 12); if (w.readUInt16LE(o + 22) !== 16) { console.log('mic: need a 16-bit PCM wav'); process.exit(2) } }
  if (id === 'data') pcm = w.subarray(o + 8, o + 8 + n); o += 8 + n + (n & 1) }
if (!pcm || !pcm.length) { console.log('mic: no audio data in the wav'); process.exit(2) }
const v = n => { const b = []; do { let x = n % 128; n = Math.floor(n / 128); b.push(n ? x | 128 : x) } while (n); return Buffer.from(b) };
const ld = (t, b) => Buffer.concat([Buffer.from([t]), v(b.length), b]);
const fmt = Buffer.concat([Buffer.from([8]), v(rate), Buffer.from([16, ch === 2 ? 1 : 0, 24, 1, 32, 1])]), step = Math.round(rate * ch / 10) * 2, pad = Buffer.alloc(step * 5);
const s = http2.connect(`http://127.0.0.1:${port}`), done = (c, m) => { console.log(m); s.destroy(); process.exit(c) };
setTimeout(() => done(1, `mic: no answer in ${secs} s after the audio`), secs * 1000 + pcm.length / rate / ch / 2 * 1000 + 1500);
s.on('error', e => done(1, `mic: ${e.message}`));
const h = { ':method': 'POST', ':path': '/android.emulation.control.EmulatorController/injectAudio', 'content-type': 'application/grpc', te: 'trailers' };
if (process.env.KIT_GRPC_TOKEN) h.authorization = `Bearer ${process.env.KIT_GRPC_TOKEN}`;
const r = s.request(h); let st = null, msg = '';
const tr = x => { if (x['grpc-status'] != null) { st = x['grpc-status']; msg = decodeURIComponent(x['grpc-message'] || '') } };
r.on('response', tr); r.on('trailers', tr); r.on('data', () => {}); r.on('error', e => done(1, `mic: ${e.message}`));
r.on('end', () => done(st === '0' ? 0 : 1, st === '0' ? `mic: ${(pcm.length / rate / ch / 2).toFixed(1)} s delivered` : `mic: grpc-status ${st} ${msg}`));
const all = Buffer.concat([pad, pcm, pad, pad]);
const t0 = Date.now();   // real-time mode, paced 100 ms packets: the blocking mode stalls the emulator while the guest is not reading
(async () => { for (let i = 0, k = 0; i < all.length; i += step, k++) {
  await new Promise(ok => setTimeout(ok, Math.max(0, t0 + (k - 2) * 100 - Date.now())));   // 200 ms ahead: the guest never reads an empty buffer
  const pk = Buffer.concat([ld(10, fmt), Buffer.from([16]), v(Date.now() * 1000), ld(26, all.subarray(i, i + step))]), f = Buffer.alloc(5); f.writeUInt32BE(pk.length, 1);
  r.write(Buffer.concat([f, pk])) } r.end() })();
'@
    try { node --input-type=module -e $js $kv['grpc.port'] $wav $(if ($Arg2) { $Arg2 } else { 60 }); if ($LASTEXITCODE) { exit $LASTEXITCODE } } finally { Remove-Item Env:KIT_GRPC_TOKEN -ErrorAction SilentlyContinue }
  }
  default { "unknown action $Action (pokey.ps1 ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log|photo|mic)"; exit 2 }
}
if ($script:uiFailed) { exit 1 }   # NOT FOUND: the caller must not read it as done
}
