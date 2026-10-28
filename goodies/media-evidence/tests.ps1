#Requires -Version 7
<#
tests.ps1 (goody media-evidence): fetcher selection, read window math, the cache + per-video lock, the local-stt lease wait, the vidy frames path,
the index format on a generated video (ffmpeg + OpenCV; skipped without them), unreadable links.
Usage: pwsh -NoProfile -File goodies/media-evidence/tests.ps1 (kitbag.py goody test media-evidence: next to the kit's
tests/harness.ps1; New-TestKit gets this goody's files). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit media; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $mpy = Join-Path $k 'skills/pokey/video.py'
$cfgF = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 }; image = @{ hosts = @{ 'shots.example' = '#img' } } } } $cfgF
$env:KIT_MEDIA_CONFIG = $null
function Mpy { $o = & $py -X utf8 $mpy @args 2>&1; [pscustomobject]@{ out = ($o -join "`n"); code = $LASTEXITCODE } }
function Sel([string]$l) { ((Mpy select $l).out | ConvertFrom-Json).fetcher }

# fetcher selection: config order, host patterns, the manual fallback
$vid = Join-Path (Kd) 'clip.mp4'; Set-Content $vid 'x'
Expect-Cases @(
  @('media select: a jam.dev/c/<id> link -> jam-public', { Sel 'https://jam.dev/c/f5cf762b-5e0c-4975-852f-2dd9cdb4ef04' }, { param($r) $r -eq 'jam-public' }),
  @('media select: a tenant SharePoint host (*.sharepoint.com) -> sharepoint', { Sel 'https://contoso-my.sharepoint.com/:v:/g/personal/x/abc' }, { param($r) $r -eq 'sharepoint' }),
  @('media select: a configured image host -> image', { Sel 'https://shots.example/AbC' }, { param($r) $r -eq 'image' }),
  @('media select: Loom / YouTube -> ytdlp', { "$(Sel 'https://www.loom.com/share/abc')|$(Sel 'https://youtu.be/x')" }, { param($r) $r -eq 'ytdlp|ytdlp' }),
  @('media select: a Drive link -> gdrive', { Sel 'https://drive.google.com/file/d/1AbCdEfGhIjKlMn/view' }, { param($r) $r -eq 'gdrive' }),
  @('media select: a direct .mp4 URL -> http, a local file -> file', { "$(Sel 'https://cdn.example/a/b.mp4?x=1')|$(Sel $vid)" }, { param($r) $r -eq 'http|file' }),
  @('media select: an unknown page -> manual', { Sel 'https://example.org/some/page' }, { param($r) $r -eq 'manual' })
)
& $J @{ media = @{ fetchers = @('manual'); stt = @{ baseUrl = 'http://127.0.0.1:9' } } } $cfgF
Expect 'media select: media.fetchers order wins (only manual -> manual)' ((Sel 'https://jam.dev/c/f5cf762b-5e0c') -eq 'manual')
& $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 } } } $cfgF

# unreadable links: SharePoint without cookies (never a login prompt), a page with no fetcher
$sp = Invoke-TestScript $Q evidence index 'https://contoso-my.sharepoint.com/:v:/g/personal/x/abc'
Expect "media index: SharePoint without a cookies file -> unreadable: re-auth needed, exit 1 ($($sp.out.Trim()))" ($sp.code -eq 1 -and $sp.out -match '^unreadable: re-auth needed' -and $sp.out -match 'media.sharepoint.cookies')
$mn = Invoke-TestScript $Q evidence fetch 'https://example.org/some/page'
Expect "media fetch: no fetcher -> unreadable, ask the tester for the file ($($mn.out.Trim()))" ($mn.code -eq 1 -and $mn.out -match 'unreadable: no fetcher reads this link, ask the tester for the file')

# read window math: --at centres, clamps at both ends, an empty window is refused
$w = { param($a) ((Mpy window @a).out | ConvertFrom-Json) -join ',' }
Expect-Cases @(
  @('media window: start/end in m:ss', { & $w @('0:10', '1:05', '--duration', '300') }, { param($r) $r -eq '10,65' }),
  @('media window: --at 1:00 --window 20 -> 50-70', { & $w @('0', '0', '--at', '1:00', '--window', '20', '--duration', '300') }, { param($r) $r -eq '50,70' }),
  @('media window: clamped to 0 and to the duration', { "$(& $w @('0', '0', '--at', '0:03', '--window', '20', '--duration', '300'))|$(& $w @('0', '0', '--at', '4:58', '--window', '20', '--duration', '300'))" }, { param($r) $r -eq '0,13|288,300' }),
  @('media window: an empty or reversed window exits 1', { (Mpy window '1:00' '0:30' --duration 300).code }, { param($r) $r -eq 1 })
)

# local-ai lease: one job per server; a second waits, gives up at its limit, gets it once the holder dies
$hold = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
$lt = @"
. '$(Lib)'
`$f = Get-KitLocalAiFile 'local-stt'
Write-KitAtomic `$f (@{ leases = @(@{ agent = 'other'; pid = $($hold.Id); pidStart = (Get-KitPidStart $($hold.Id)); at = (Get-Date).ToString('o') }); waiting = @() } | ConvertTo-Json -Depth 4)
`$a = Use-KitLocalAi 'local-stt' -Agent t1 -WaitMinutes 0.02
Stop-Process -Id $($hold.Id) -Force; Start-Sleep -Milliseconds 300
`$b = Use-KitLocalAi 'local-stt' -Agent t1 -WaitMinutes 0.02
`$s = Get-KitLocalAiState 'local-stt'; Remove-KitLocalAi 'local-stt'; `$e = Get-KitLocalAiState 'local-stt'
"held:`$(-not `$a)"; "dead:`$(`$b -and `$s.leases.Count -eq 1 -and `$s.leases[0].agent -eq 't1')"; "released:`$(`$e.leases.Count -eq 0)"
`$sv = @(Get-KitSuperviseGuardLocalAi) -join '|'; "quiet:`$(-not `$sv)"
"@
$lr = Invoke-PsTest 'lease' $lt
Expect-Each $lr 'media lease local-stt: #' @('held', 'dead', 'released', 'quiet') -Show 6
Expect 'media lease: the waiter says "waiting for local AI"' (($lr -join "`n") -match 'waiting for local AI: local-stt busy \(other')

# index on a generated video: a box appears at 2 s, a full-screen change at 5 s; cache reuse; the per-video lock
$ff = Get-Command ffmpeg -ErrorAction SilentlyContinue; $null = & $py -c 'import cv2' 2>&1; $cv = $LASTEXITCODE -eq 0
if ($ff -and $cv) {
  $mp4 = Join-Path (Kd) 'synthetic.mp4'
  & $ff.Source -v error -y -f lavfi -i 'color=c=white:s=640x360:d=8:r=15' -vf "drawbox=x=100:y=100:w=120:h=60:color=red:t=fill:enable='gte(t,2)',drawbox=x=0:y=0:w=640:h=360:color=navy:t=fill:enable='gte(t,5)'" -pix_fmt yuv420p $mp4 2>&1 | Out-Null
  $i1 = Invoke-TestScript $Q evidence index $mp4 -Json
  $j1 = try { $i1.out.Substring($i1.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  $md = if ($j1) { Get-Content $j1.index -Raw } else { '' }
  Expect "media index: header, a change at 0:02, a page-change at 0:05, one chunk row (~$($j1.tokens) tokens)" ($md -match '(?m)^# media [0-9a-f]{16} · file · video · 0:08' -and $md -match '(?m)^- 0:02 change at \(0\.1\d,0\.2\d\)' -and $md -match '(?m)^- 0:05 page-change' -and $md -match '(?m)^## c01 0:00-0:08')
  Expect 'media index: no audio -> a note, not a failure; an index' ($j1.notes -match 'transcribe: no audio track' -and $j1.tokens -gt 50 -and $j1.tokens -lt 1000)
  $i2 = Invoke-TestScript $Q evidence index $mp4 -Json; $j2 = try { $i2.out.Substring($i2.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  Expect 'media index: a second run reuses the cache (fetch cached, same index)' ($j2.times.fetch -eq 'cached' -and $j2.index -eq $j1.index)
  $rc = Invoke-TestScript $Q evidence read-chunk $j1.key -At 0:05 -Window 4 -Frames 2 -Size 320
  $jpgs = @([regex]::Matches($rc.out, 'frame \d+:\d+: (\S+\.jpg)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { Test-Path $_ })
  Expect "media read-chunk: the window's events + 2 JPEG frames ($($jpgs.Count))" ($rc.code -eq 0 -and $rc.out -match '# [0-9a-f]{16} 0:03-0:07' -and $rc.out -match 'page-change' -and $jpgs.Count -eq 2)
  $kd = ((Mpy paths $j1.key).out | ConvertFrom-Json).keyDir
  $fs = [IO.File]::Open("$kd.lock", 'OpenOrCreate', 'ReadWrite', 'None')
  try { $lk = Invoke-TestScript $Q evidence index $mp4 -LockMinutes 0 } finally { $fs.Dispose() }
  Expect "media index: a video another agent holds -> waits, then says so, exit 1 ($($lk.out.Trim() -split "`n" | Select-Object -Last 1))" ($lk.code -eq 1 -and $lk.out -match 'another agent is processing this video' -and $lk.out -match 'still being processed')
  $ne = Invoke-TestScript $Q evidence read-chunk 0123456789abcdef 0 5
  Expect 'media read-chunk: an unknown key exits 1 with the index hint' ($ne.code -eq 1 -and $ne.out -match 'run pokey.ps1 evidence index')
  # vidy path: vision lists the keyframes (no model call), index.md marks them unread with paths; write-vision -> index + read-chunk
  Expect "media vision: no model call, unread keyframes with paths in index.md ($(@($j1.notes) -join '; '))" ($j1.notes -match 'vision: \d+ keyframes unread: run vidy' -and $md -match 'keyframes unread: run vidy \(pokey.ps1 evidence frames' -and $md -match '(?m)^keyframes \(unread: run vidy\): .*keyframes[\\/][\w-]+\.jpg')
  $fr = Invoke-TestScript $Q evidence frames $j1.key
  $fpaths = @([regex]::Matches($fr.out, '(?m)^\S+ \d+:\d+(?: crops on k\d+)?: (\S+?\.(?:jpg|png))') | ForEach-Object { $_.Groups[1].Value })
  $px = if ($fpaths) { & $py -c "import cv2,sys; print(cv2.imread(sys.argv[1]).shape[1])" $fpaths[0] } else { 0 }
  Expect "media frames: the detector's keyframes as existing full frames (640 px wide), one batch ($($fpaths.Count), $px px)" ($fr.code -eq 0 -and $fpaths.Count -ge 2 -and -not @($fpaths | Where-Object { -not (Test-Path $_) }).Count -and $fr.out -match "the detector's $($fpaths.Count) keyframes \(read only these\)" -and $fr.out -match '(?m)^batch 1:' -and "$px" -eq '640')
  $rcU = Invoke-TestScript $Q evidence read-chunk $j1.key -At 0:05 -Window 4 -Frames 1 -Size 320
  Expect 'media read-chunk: unread keyframe paths in the window' ($rcU.out -match 'unread \w+ 0:0\d: \S+\.jpg \(run vidy\)')
  $items = Join-Path (Kd) 'vidy-items.json'
  ConvertTo-Json -Depth 5 -InputObject @(@{ ref = 'start'; t = 0.5; text = "Order 4711`nTotal 12.50"; ui = 'a white page'; frames = @($fpaths[0]) },
    @{ ref = 'e002'; t = '0:05'; text = 'Error: save failed (HTTP 500)'; ui = 'a navy page'; frames = @($fpaths[-1]) }) | Set-Content $items
  $wv = Invoke-TestScript $Q evidence write-vision $j1.key -File $items -Model sonnet -Tokens 4200
  $md2 = Get-Content $j1.index -Raw
  Expect "media write-vision: vision.json -> index.md screen text, vidy marked, error flag ($($wv.out.Trim()))" ($wv.code -eq 0 -and $wv.out -match '2 items from 2 frames \(of \d+ keyframes\), ~\d+ image tokens, 4200 agent tokens' -and $md2 -match 'screen text: 2 frames \(vidy sonnet\)' -and $md2 -match 'screen: Order 4711' -and $md2 -match '\[error: ')
  $rcV = Invoke-TestScript $Q evidence read-chunk $j1.key -At 0:05 -Window 4 -Frames 1 -Size 320
  Expect 'media read-chunk: picks up the vidy-written screen text' ($rcV.out -match 'screen 0:05: Error: save failed \(HTTP 500\)')
  $vlog = @(Get-ChildItem (TkPath $k audit) -Recurse -Filter 'calls.jsonl' -ErrorAction SilentlyContinue | Get-Content | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'media-vision' })
  Expect "media write-vision: logs frames read and tokens ($(@($vlog).Count) lines)" (@($vlog | Where-Object { $_.framesRead -eq 2 -and $_.agentSpend -eq 4200 -and $_.imageSpend -gt 0 }).Count -eq 1)
  $null = Invoke-TestScript $Q evidence index $mp4 -Refresh -Json
  Expect 'media index -Refresh: keeps the vidy reading' ((Get-Content $j1.index -Raw) -match 'screen: Order 4711')
  $bad = Join-Path (Kd) 'bad-items.json'; ConvertTo-Json -Depth 5 -InputObject @(@{ ref = 'x'; t = 1; text = 'y'; frames = @((Join-Path (Kd) 'missing.jpg')) }) | Set-Content $bad
  $wb = Invoke-TestScript $Q evidence write-vision $j1.key -File $bad
  Expect 'media write-vision: a frame that does not exist -> exit 1' ($wb.code -eq 1 -and $wb.out -match 'frame not found')
  # segments: segmentSec 4 -> 2 segments; -Segment 2 lists only its own keyframes; segment vidys write in parallel and merge
  & $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 }; vidy = @{ segmentSec = 4 } } } $cfgF
  $i5 = Invoke-TestScript $Q evidence index $mp4 -Json; $j5 = try { $i5.out.Substring($i5.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  $f5 = Invoke-TestScript $Q evidence frames $j5.key
  $seg = foreach ($n in 1, 2) { , @([regex]::Matches((Invoke-TestScript $Q evidence frames $j5.key -Segment $n).out, '(?m)^\S+ \d+:\d+(?: crops on k\d+)?: (\S+\.(?:jpg|png))') | ForEach-Object { $_.Groups[1].Value }) }
  Expect "media segments: 8 s at segmentSec 4 -> 2 segments, -Segment n lists only its own ($($seg[0].Count) + $($seg[1].Count))" ($f5.out -match '2 segment\(s\)' -and $f5.out -match 'one vidy per segment' -and $f5.out -match '## segment 2/2' -and $seg[0].Count -ge 1 -and $seg[1].Count -ge 1 -and -not @($seg[0] | Where-Object { $seg[1] -contains $_ }).Count)
  $sA = Join-Path (Kd) 'seg1.json'; $sB = Join-Path (Kd) 'seg2.json'
  ConvertTo-Json -Depth 5 -InputObject @(@{ ref = 's1'; t = 1; text = 'segment one text'; frames = @($seg[0]) }) | Set-Content $sA
  ConvertTo-Json -Depth 5 -InputObject @(@{ ref = 's2'; t = 6; text = 'segment two text'; frames = @($seg[1]) }) | Set-Content $sB
  $wA = Start-Job { param($q, $kk, $f) pwsh -NoProfile -File $q evidence write-vision $kk -File $f } -ArgumentList $Q, $j5.key, $sA
  $wB = Invoke-TestScript $Q evidence write-vision $j5.key -File $sB; $null = $wA | Wait-Job -Timeout 120 | Receive-Job
  $md5 = Get-Content $j5.index -Raw
  Expect "media segments: two segment vidys write -> both readings merged, none unread ($($wB.out.Trim()))" ($md5 -match 'segment one text' -and $md5 -match 'segment two text' -and $md5 -notmatch 'keyframes unread')
  $nk = Join-Path (Kd) 'not-key.json'; ConvertTo-Json -Depth 5 -InputObject @(@{ ref = 'x'; t = 5; text = 'from a read-chunk frame'; frames = @($jpgs[0]) }) | Set-Content $nk
  $w5 = Invoke-TestScript $Q evidence write-vision $j5.key -File $nk
  Expect "media vidy: a frame that is not a detector keyframe -> WARN ($($w5.out.Trim()))" ($w5.out -match "WARN: 1 frame\(s\) read are not the detector's keyframes")
  # STT through a fake local server; vision sends nothing to it and takes no GPU lease (an emulator GPU kind is set)
  $port = Get-Random -Minimum 20000 -Maximum 29000; $plog = Join-Path (Kd) 'fake-ai.log'
  $srv = Join-Path (Kd) 'fake_ai.py'
  Set-Content $srv @"
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data": []}')
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        open(sys.argv[2], 'a').write(self.path + '\n')
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({'text': 'the save failed with an error'}).encode())
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
"@
  $fake = Start-Process $py -ArgumentList '-X', 'utf8', $srv, $port, $plog -PassThru -WindowStyle Hidden; Start-Sleep -Milliseconds 800
  & $J @{ gpu = @{ exclusive = @{ emulator = @{} } }; media = @{ stt = @{ baseUrl = "http://127.0.0.1:$port"; ramGB = 0.1 } } } $cfgF
  $talk = Join-Path (Kd) 'talk.mp4'
  & $ff.Source -v error -y -f lavfi -i 'color=c=white:s=320x180:d=4:r=10' -f lavfi -i 'sine=frequency=440:duration=4' -vf "drawbox=x=40:y=40:w=80:h=40:color=red:t=fill:enable='gte(t,2)'" -pix_fmt yuv420p -shortest $talk 2>&1 | Out-Null
  Set-Content (Join-Path (Kd) 'other.vtt') "WEBVTT`n`n00:00.000 --> 00:02.000`nnot this video"
  $emu = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
  $null = Invoke-PsTest 'gpu-emu' ". '$(Lib)'; `$null = Use-KitGpu -Kind emulator -Holder L1 -ProcessId $($emu.Id) -WaitMinutes 0"
  $i3 = Invoke-TestScript $Q evidence index $talk -WaitMinutes 0 -Json; $j3 = try { $i3.out.Substring($i3.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  $md3 = if ($j3) { Get-Content $j3.index -Raw } else { '' }
  $posts = @(if (Test-Path $plog) { Get-Content $plog })
  Expect "media index: speech via the STT server (not a .vtt beside the tester's file), error flag ($(@($j3.notes) -join '; '))" ($md3 -match 'say: the save failed with an error' -and $md3 -notmatch 'not this video' -and $md3 -match '\[error: ')
  $gpuF = TkPath $k runtimes; $gpuF = Join-Path $gpuF 'gpu.json'
  $gpuLeases = if (Test-Path $gpuF) { @((Get-Content $gpuF -Raw | ConvertFrom-Json).leases) + @((Get-Content $gpuF -Raw | ConvertFrom-Json).waiting) | Where-Object { $_ -and $_.kind -ne 'emulator' } } else { @() }
  Expect "media index: vision makes no server call and takes no GPU lease ($(@($posts).Count) posts: $($posts -join ','))" (@($posts | Where-Object { $_ -notmatch 'audio' }).Count -eq 0 -and @($posts).Count -ge 1 -and -not @($gpuLeases).Count -and -not ($j3.notes -match 'GPU'))
  $gl = @(Get-ChildItem (TkPath $k audit) -Recurse -Filter 'builds.jsonl' -ErrorAction SilentlyContinue | Get-Content | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'start' })
  Expect "media index: STT ran through the memory gate as kind local-ai with ramGB ($(@($gl.kind) -join ','))" (@($gl | Where-Object { $_.kind -eq 'local-ai' -and [double]$_.needGB -eq 0.1 }).Count -eq 1)
  Stop-Process -Id $fake.Id, $emu.Id -Force -ErrorAction SilentlyContinue
  # sidecar actions anchor keyframes: a pokey record() log next to the media -> a real click line with its before -> after frames
  & $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 }; corpus = @{ keep = 1 } } } $cfgF
  $sc = Join-Path (Kd) 'flow.mp4'
  & $ff.Source -v error -y -f lavfi -i 'color=c=white:s=640x360:d=8:r=15' -vf "drawbox=x=0:y=60:w=640:h=300:color=navy:t=fill:enable='gte(t,3.2)'" -pix_fmt yuv420p $sc 2>&1 | Out-Null
  & $J @{ source = 'pokey'; start = 1000; size = @(640, 360); events = @(@{ at = 4000; action = 'click'; target = 'Save'; box = @(300, 30, 40, 20) }) } "$sc.events.json"
  $is = Invoke-TestScript $Q evidence index $sc -Json; $js = try { $is.out.Substring($is.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  $mds = if ($js) { Get-Content $js.index -Raw } else { '' }
  Expect "media sidecar: a pokey action log anchors a click line with before -> after keyframes ($(([regex]::Match($mds, '(?m)^- 0:03 click.*$')).Value))" ($mds -match '(?m)^- 0:03 click "Save" at \(0\.47,0\.08\).*\[pokey\] k\d{3}->k\d{3}')
  # vidy's verify phase: perfect -> passed, nothing more; a miss -> feedback row, labels, corpus open, the TUNE line; keep 1 evicts the older media
  $ok = Join-Path (Kd) 'verify-ok.json'; & $J @{ name = 'synthetic box'; states = @(@(0, 1.9, 'white'), @(2, 4.9, 'red box'), @(5, 8, 'navy')); findings = @(); tokens = 1200 } $ok
  $fb1 = Invoke-TestScript $Q evidence feedback $j1.key -File $ok
  $cf = Join-Path (Join-Path (Split-Path (TkPath $k signals)) 'media') 'corpus.json'; $fbl = Join-Path (Join-Path (Split-Path (TkPath $k signals)) 'media') 'feedback.jsonl'
  $c1 = Get-Content $cf -Raw | ConvertFrom-Json
  Expect "media feedback: perfect -> corpus passed, recall 1, no feedback rows, no tune ($(($fb1.out -split "`n" | Where-Object { $_.Trim() })[-1]))" ($fb1.code -eq 0 -and $fb1.out -match 'perfect: nothing more for this video' -and $fb1.out -notmatch 'TUNE' -and $c1.($j1.key).status -eq 'passed' -and $c1.($j1.key).recall -eq 1 -and -not (Test-Path $fbl))
  $bad = Join-Path (Kd) 'verify-miss.json'
  & $J @{ name = 'flow'; states = @(@(0, 3.1, 'white'), @(3.3, 8, 'navy')); animations = @(); findings = @(@{ kind = 'missed'; t0 = '0:03'; t1 = 3.5; frames = @($sc); note = 'navy page has no keyframe' }); tokens = 90000 } $bad
  $fb2 = Invoke-TestScript $Q evidence feedback $js.key -File $bad
  $row = Get-Content $fbl | ConvertFrom-Json; $c2 = Get-Content $cf -Raw | ConvertFrom-Json
  Expect "media feedback: a miss -> feedback.jsonl (kind, window, frames, pipe), labels next to the media, corpus open, TUNE line, over the token cap" ($fb2.out -match "TUNE $($js.key): spawn kitty" -and $row.kind -eq 'missed' -and $row.t0 -eq 3 -and $row.pipe -ge 3 -and $row.frames -contains $sc -and (Test-Path $c2.($js.key).labels) -and $c2.($js.key).status -eq 'open' -and $fb2.out -match '90000 tokens > media.vidy.labelTokens')
  $kd1 = ((Mpy paths $j1.key).out | ConvertFrom-Json).keyDir
  Expect "media corpus: keep 1 -> the older clip's media evicted, its labels kept ($($fb2.out -split "`n" | Select-String 'evicted'))" ($c2.($j1.key).media -eq 'evicted' -and $c2.($js.key).media -ne 'evicted' -and (Test-Path (Join-Path $kd1 'labels.json')) -and -not @(Get-ChildItem $kd1 -Directory).Count)
  # the regression gate: a corpus clip whose recall would drop below its recorded value fails; evicted clips are skipped
  $c2.($js.key) | Add-Member -Force recall 1.0; $c2 | ConvertTo-Json -Depth 6 | Set-Content $cf
  & $J @{ key = $js.key; states = @(@(0, 1, 'white'), @(20, 21, 'a state the detector never shows (past the end)')) } $c2.($js.key).labels
  $g1 = Invoke-TestScript $Q evidence bench -Key $js.key
  & $J @{ key = $js.key; states = @(, @(0, 0.2, 'white')) } $c2.($js.key).labels
  $g2 = Invoke-TestScript $Q evidence bench -Key $js.key -Record
  $ge = Invoke-TestScript $Q evidence bench -Key $j1.key
  Expect "media bench: a corpus recall drop fails, a covered clip passes and records, an evicted clip is skipped ($(($g1.out -split "`n" | Select-String 'FAIL') -join ' '))" ($g1.code -eq 1 -and $g1.out -match 'FAIL corpus .*recall .* < 1.0 recorded' -and $g2.code -eq 0 -and $g2.out -match 'bench: pass' -and $ge.out -match 'media evicted' -and $ge.code -eq 0)
  & $J @{ key = $js.key; states = @(, @(0, 0.2, 'white')); expect = @(@{ kind = 'start'; t0 = 0; t1 = 1; absent = $true }, @{ kind = 'toast'; t0 = 0; t1 = 8 }) } $c2.($js.key).labels
  $g3 = Invoke-TestScript $Q evidence bench -Key $js.key
  Expect "media bench: labels' expect rows gate too: an event that must be absent shows, one that must show does not ($(($g3.out -split "`n" | Select-String 'FAIL') -join ' '))" ($g3.code -eq 1 -and $g3.out -match 'event present: .*start' -and $g3.out -match 'event missing: .*toast')
} else { 'SKIP media index: ffmpeg or OpenCV missing' }

# the loop by script (zero tokens): label = the oracle's held states, verify = oracle vs keyframes -> feedback (perfect: passed,
# nothing more), tune = a parameter search that applies only at corpus recall 1.0; no media or label file is ever in the goody
if ($ff -and $cv) {
  $null = Invoke-TestScript $Q evidence index $mp4 -Json   # its media came back (evicted above)
  $lb = Invoke-TestScript $Q evidence label $j1.key; $st = try { $lb.out | ConvertFrom-Json } catch { @() }
  Expect "media label: the oracle finds the white, red-box and navy screens ($(@($st).Count) states)" (@($st).Count -eq 3 -and $st[1][0] -ge 1.9 -and $st[1][0] -le 2.2 -and $st[2][0] -ge 4.9 -and $st[2][0] -le 5.2)
  $vr = Invoke-TestScript $Q evidence verify $j1.key
  Expect "media verify: oracle vs keyframes by script -> perfect, passed, no tune ($(($vr.out -split "`n")[0]))" ($vr.code -eq 0 -and $vr.out -match 'state recall 1\.0' -and $vr.out -match 'perfect: nothing more' -and $vr.out -notmatch 'TUNE|ambiguous misses')
  $mdir = Join-Path (Split-Path (TkPath $k signals)) 'media'
  $cj = Get-Content (Join-Path $mdir 'corpus.json') -Raw | ConvertFrom-Json
  foreach ($p in $cj.PSObject.Properties) { if ($p.Name -ne $j1.key) { $cj.PSObject.Properties.Remove($p.Name) } }; $cj | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $mdir 'corpus.json')
  $sp = Join-Path (Kd) 'space.json'; & $J @{ gain_min = @(3.0) } $sp
  $tn = Invoke-TestScript $Q evidence tune -MaxEvals 2 -Names cursor -Space $sp
  $pj = Get-Content (Join-Path $mdir 'params.json') -Raw | ConvertFrom-Json
  Expect "media tune: 2 trials, every corpus clip at 1.0 -> params applied (active), learn signal ($(($tn.out -split "`n" | Select-String 'APPLIED') -join ' '))" ($tn.code -eq 0 -and $tn.out -match '(?m)^APPLIED ' -and $pj.active -and $pj.evals -eq 2)
}
$gl = @(git -C (Split-Path (Split-Path $PSScriptRoot)) ls-files 2>$null | Where-Object { $_ -match '^goodies/media-evidence/' }) + @(Get-ChildItem $PSScriptRoot -Recurse -File | ForEach-Object { $_.Name })
Expect "media goody: no video, image or label JSON among its files ($(@($gl).Count) files)" (-not @($gl | Where-Object { $_ -match '\.(mp4|webm|mkv|mov|avi|jpe?g|png|gif)$|labels?\.json$|corpus\.json$|feedback\.jsonl$|\.gt\.json$' }).Count)
# the detector gate: 11 synthetic clips + 6 crf-36 variants, generated here (never committed): recall and key recall 1.000,
# precision >= 0.85, the 30 s loading = one event with <= 3 frames, a dark highlight is no toast, a ticking timer is no event and
# a toast over a page change is one, no frame kept twice; KIT_MEDIA_CORPUS (a corpus.json) adds a local corpus
if ($ff -and $cv) {
  if ($env:KIT_MEDIA_CORPUS -and (Test-Path $env:KIT_MEDIA_CORPUS)) { Copy-Item $env:KIT_MEDIA_CORPUS (Join-Path (New-Item -ItemType Directory -Force (Join-Path (Split-Path (TkPath $k signals)) 'media')).FullName 'corpus.json') -Force }
  $bn = Invoke-TestScript $Q evidence bench $(if (-not $env:KIT_MEDIA_CORPUS) { '-NoCorpus' })
  $bn.out -split "`n" | Where-Object { $_ -match '^(q-)?\w+: recall|^corpus ' } | ForEach-Object { "  $_" }
  Expect "media bench: the synthetic gate holds ($(($bn.out -split "`n" | Select-String 'FAIL|bench: pass') -join ' '))" ($bn.code -eq 0 -and $bn.out -match 'bench: pass' -and @([regex]::Matches($bn.out, '(?m)^(q-)?\w+: recall 1\.0 key 1\.0')).Count -eq 17)
  # media.detect.fillCoverage: a budget of 1 frame; the fill (default 0.99) still gives every screen a frame, at 0 none does
  $nf = { param($o) [regex]::Match($o, '(?m)^page: .* frames (\d+)').Groups[1].Value }
  $fb = foreach ($fcv in @($null, 0)) {
    $fc = Join-Path (Kd) "fill$fcv.json"; & $J @{ detect = (@{ frames = 1; framesPerMin = 0 } + $(if ($null -ne $fcv) { @{ fillCoverage = $fcv } } else { @{} })) } $fc
    $env:KIT_MEDIA_CONFIG = $fc; & $nf (Invoke-TestScript $Q evidence bench -Names page --no-crf36 -NoCorpus).out; $env:KIT_MEDIA_CONFIG = $null
  }
  Expect "media detect.fillCoverage: over a 1-frame budget the default 0.99 adds fills, 0 adds none (frames $($fb -join ' vs '))" ([int]$fb[0] -ge 3 -and [int]$fb[1] -eq 1)
  # media.detect.deltaShare: typing changes one line; the default sends crops on a base frame (fewer images and tokens, recall
  # held), 0 sends every keyframe whole
  $dl = foreach ($dsv in @($null, 0)) {
    $dc = Join-Path (Kd) "delta$dsv.json"; & $J @{ detect = $(if ($null -ne $dsv) { @{ deltaShare = $dsv } } else { @{} }) } $dc
    $env:KIT_MEDIA_CONFIG = $dc; $o = (Invoke-TestScript $Q evidence bench -Names typing --no-crf36 -NoCorpus).out; $env:KIT_MEDIA_CONFIG = $null
    $mt = [regex]::Match($o, '(?m)^typing: recall (\S+) .* frames (\d+) images (\d+) tokens (\d+)'); , @($mt.Groups[1].Value, [int]$mt.Groups[2].Value, [int]$mt.Groups[3].Value, [int]$mt.Groups[4].Value)
  }
  Expect "media detect.deltaShare: crops cut images and tokens at recall 1.0 ($(($dl | ForEach-Object { $_ -join '/' }) -join ' vs '))" ($dl[0][0] -eq '1.0' -and $dl[0][2] -lt $dl[1][2] -and $dl[0][3] -lt $dl[1][3] -and $dl[1][2] -eq $dl[1][1])
}
$sv = Invoke-TestScript (Join-Path $k 'skills/bossy/bossy.ps1') supervise
Expect 'media: supervise runs with the goody loaded (no local-ai line when idle)' ($sv.out -notmatch 'local-stt:' -and $sv.out -notmatch 'Get-KitSuperviseGuardLocalAi')
Remove-TestKit $k
Complete-Tests
