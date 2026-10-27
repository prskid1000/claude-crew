#Requires -Version 7
<#
tests.ps1 (goody media-evidence): fetcher selection, read window math, the cache + per-video lock, the local-ai lease wait,
the index format on a generated video (ffmpeg + OpenCV; skipped without them), unreadable links.
Usage: pwsh -NoProfile -File goodies/media-evidence/tests.ps1 (kitbag.py goody test media-evidence: next to the kit's
tests/harness.ps1; New-TestKit gets this goody's files). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit media; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $mpy = Join-Path $k 'skills/pokey/media_evidence.py'
$cfgF = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 }; vision = @{ enabled = $false }; image = @{ hosts = @{ 'shots.example' = '#img' } } } } $cfgF
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
& $J @{ media = @{ stt = @{ baseUrl = 'http://127.0.0.1:9'; ramGB = 0.1 }; vision = @{ enabled = $false } } } $cfgF

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
  Expect 'media index: no audio -> a note, not a failure; vision off -> degraded, still an index' ($j1.notes -match 'transcribe: no audio track' -and $j1.notes -match 'degraded vision' -and $j1.tokens -gt 50 -and $j1.tokens -lt 1000)
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
  # a fake local AI server: /v1/models 200, STT returns a sentence, vision answers 503; it logs each POST
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
        if 'audio' in self.path:
            self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({'text': 'the save failed with an error'}).encode())
        else:
            self.send_response(503); self.end_headers()
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
"@
  $fake = Start-Process $py -ArgumentList '-X', 'utf8', $srv, $port, $plog -PassThru -WindowStyle Hidden; Start-Sleep -Milliseconds 800
  & $J @{ media = @{ stt = @{ baseUrl = "http://127.0.0.1:$port"; ramGB = 0.1 }; vision = @{ baseUrl = "http://127.0.0.1:$port"; model = 'm'; ramGB = 0.1 } } } $cfgF
  $talk = Join-Path (Kd) 'talk.mp4'
  & $ff.Source -v error -y -f lavfi -i 'color=c=white:s=320x180:d=4:r=10' -f lavfi -i 'sine=frequency=440:duration=4' -vf "drawbox=x=40:y=40:w=80:h=40:color=red:t=fill:enable='gte(t,2)'" -pix_fmt yuv420p -shortest $talk 2>&1 | Out-Null
  Set-Content (Join-Path (Kd) 'other.vtt') "WEBVTT`n`n00:00.000 --> 00:02.000`nnot this video"
  $i3 = Invoke-TestScript $Q evidence index $talk -Json; $j3 = try { $i3.out.Substring($i3.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  $md3 = if ($j3) { Get-Content $j3.index -Raw } else { '' }
  $posts = @(if (Test-Path $plog) { Get-Content $plog })
  Expect "media index: speech via the STT server (not a .vtt beside the tester's file), error flag ($(@($j3.notes) -join '; '))" ($md3 -match 'say: the save failed with an error' -and $md3 -notmatch 'not this video' -and $md3 -match '\[error: ')
  Expect "media index: vision 503 -> one request, stage stopped, degraded, index kept ($(@($posts | Where-Object { $_ -notmatch 'audio' }).Count) vision posts)" (@($posts | Where-Object { $_ -notmatch 'audio' }).Count -eq 1 -and ($j3.notes -match 'degraded vision: stopped: the vision backend answered HTTP 503'))
  $gl = @(Get-ChildItem (TkPath $k audit) -Recurse -Filter 'builds.jsonl' -ErrorAction SilentlyContinue | Get-Content | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'start' })
  Expect "media index: STT + vision ran through the memory gate as kind local-ai with ramGB ($(@($gl.kind) -join ','))" (@($gl | Where-Object { $_.kind -eq 'local-ai' -and [double]$_.needGB -eq 0.1 }).Count -eq 2)
  # gpu.exclusive: an emulator lane holding the GPU blocks vision; a vision job blocks a lane; a release frees the other
  $probe = Join-Path (Kd) 'gpu-probe.json'; & $J @{ usedMB = 0; procs = @() } $probe; $env:KIT_GPU_PROBE = $probe
  & $J @{ gpu = @{ exclusive = @{ emulator = @{}; 'local-vision' = @{ idleExcept = '^llama-server' } } }; media = @{ stt = @{ baseUrl = "http://127.0.0.1:$port"; ramGB = 0.1 }; vision = @{ baseUrl = "http://127.0.0.1:$port"; model = 'm'; ramGB = 0.1 } } } $cfgF
  $emu = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
  $null = Invoke-PsTest 'gpu-emu' ". '$(Lib)'; `$null = Use-KitGpu -Kind emulator -Holder L1 -ProcessId $($emu.Id) -WaitMinutes 0"
  $n0 = @(Get-Content $plog).Count
  $g1 = Invoke-TestScript $Q evidence index $talk -Refresh -NoTranscript -WaitMinutes 0 -Json; $gj = try { $g1.out.Substring($g1.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  Expect "media gpu: a lane holding the GPU -> vision waits, sends nothing, says who holds it ($(@($gj.notes) -join '; '))" (@(Get-Content $plog).Count -eq $n0 -and ($gj.notes -match 'waiting for GPU: held by emulator L1'))
  Stop-Process -Id $emu.Id -Force; Start-Sleep -Milliseconds 300
  $g2 = Invoke-TestScript $Q evidence index $talk -Refresh -NoTranscript -WaitMinutes 0 -Json; $gk = try { $g2.out.Substring($g2.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  Expect "media gpu: the lane gone -> vision runs (one request to the server) ($(@($gk.notes) -join '; '))" (@(Get-Content $plog).Count -eq $n0 + 1 -and ($gk.notes -match 'HTTP 503'))
  # a foreign GPU process (nvidia-smi) blocks vision; the vision backend's own process does not
  & $J @{ usedMB = 900; procs = @(@{ pid = 4242; name = 'qemu-system-x86_64'; mb = $null }, @{ pid = 4343; name = 'llama-server'; mb = 8000 }) } $probe
  $g3 = Invoke-TestScript $Q evidence index $talk -Refresh -NoTranscript -WaitMinutes 0 -Json; $gm = try { $g3.out.Substring($g3.out.IndexOf('{')) | ConvertFrom-Json } catch { $null }
  Expect "media gpu: another GPU process -> vision waits, sends nothing ($(@($gm.notes) -join '; '))" (@(Get-Content $plog).Count -eq $n0 + 1 -and ($gm.notes -match 'waiting for GPU: held by gpu qemu-system-x86_64 pid 4242 using the GPU'))
  & $J @{ usedMB = 8100; procs = @(@{ pid = 4343; name = 'llama-server'; mb = 8000 }) } $probe
  $g4 = Invoke-TestScript $Q evidence index $talk -Refresh -NoTranscript -WaitMinutes 0 -Json
  Expect 'media gpu: only the vision backend on the GPU -> vision runs' (@(Get-Content $plog).Count -eq $n0 + 2)
  & $J @{ usedMB = 1300; procs = @() } $probe
  $g5 = Invoke-TestScript $Q evidence index $talk -Refresh -NoTranscript -WaitMinutes 0 -Json
  Expect 'media gpu: memory used with no backend running (> idleMaxMB) -> vision waits' (@(Get-Content $plog).Count -eq $n0 + 2 -and $g5.out -match '1300 MB used')
  & $J @{ usedMB = 0; procs = @() } $probe
  $vis = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
  $gr = Invoke-PsTest 'gpu-vis' @"
. '$(Lib)'
`$null = Use-KitGpu -Kind local-vision -Holder v1 -ProcessId $($vis.Id) -WaitMinutes 0
"blocked:`$(-not (Use-KitGpu -Kind emulator -Holder L2 -WaitMinutes 0))"; "shown:`$((Get-KitSuperviseGuardGpu) -match 'held by local-vision v1')"
Stop-Process -Id $($vis.Id) -Force; Start-Sleep -Milliseconds 300
"freed:`$(Use-KitGpu -Kind emulator -Holder L2 -WaitMinutes 0)"; Remove-KitGpu
"@
  Expect-Each $gr 'media gpu: a vision job #' @('blocked', 'shown', 'freed') -Show 6
  $env:KIT_GPU_PROBE = $null; Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
} else { 'SKIP media index: ffmpeg or OpenCV missing' }

$sv = Invoke-TestScript (Join-Path $k 'skills/bossy/bossy.ps1') supervise
Expect 'media: supervise runs with the goody loaded (no local-ai line when idle)' ($sv.out -notmatch 'local-stt:|local-vision:' -and $sv.out -notmatch 'Get-KitSuperviseGuardLocalAi')
Remove-TestKit $k
Complete-Tests
