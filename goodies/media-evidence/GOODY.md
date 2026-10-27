# media-evidence
- What: tester evidence links (videos, screen recordings, screenshots) -> a time-indexed text index (~100 tokens per 30 s
  chunk) plus frames on demand, so checky / devy / watchy read a bug video without watching it whole:
  `pokey.ps1 evidence index <link>` (fetch + index, prints the index) -> read it -> `pokey.ps1 evidence read-chunk <key>
  <start> <end> | -At <m:ss> -Window <s> | -AroundError [-Frames 3] [-Size 1280] [-Item <task>]` (that window's events, speech,
  screen text + JPEG frames for the Read tool). Also `fetch <link>`, `status [<key>]`.
- One pipeline for every video; per source only a thin fetcher (link -> local file + sidecars), tried in `media.fetchers` order:
  `file` · `jam-public` (`<jam>.md`, `<jam>/transcript.md`, the stream URL from a throw-away headless browser, yt-dlp) ·
  `sharepoint` (yt-dlp + a cookies file per host; none or expired -> `unreadable: re-auth needed`, never a login) · `gdrive`
  (Drive / Meet recordings via `gws`) · `jira` (attachment URL with the tracker adapter's `JIRA_*` env) · `image` (an image host's
  page: the image element, headless) · `ytdlp` (Loom, YouTube, Vimeo, ...) · `http` (a direct media URL) · `manual`
  (`unreadable: <reason>, ask the tester for the file`).
- Index stages, cached per video (`<runtime>/cache/media/<key>/`, key = sha of the link; a new file or pipeline version
  re-indexes, so does a change of the `detect` / `chunk` / `stt` / `vision` stage settings): detect (ffmpeg grey frames at ~12 fps, 640 px; change-then-settle events with before / after crops; page
  changes; typing; pointer moves; `click?` = a guess from the pointer, real clicks only from a source's events; ticking cells
  such as a recorder clock ignored) · transcribe (a sidecar transcript / VTT first, else the local OpenAI-compatible STT server
  on speech pieces; silent tracks skipped) · vision (screen text + a UI line per keyframe / event crop from the local
  OpenAI-compatible vision LLM; long edge <= 1280, one request at a time, never retried: stops at the first backend
  error or at `gpuStopGB`, keeping what it read; `gpuStopGB` without `nvidia-smi` -> not run) · build (`index.md`: 20-60 s chunks split at page changes / idle, error flags; over
  `twoLevelOverSec` a section index + `index-sNN.md`).
- Resources: one lock per video key (a second agent waits, then reads the same cache); leases `local-stt` / `local-vision`
  (one job per server, bound to the job's process: a killed job frees it at once) and the memory gate reserves `ramGB` (kind `local-ai`); a server that does not answer or
  a wait past `-WaitMinutes` -> "waiting for local STT / vision" and an index without that stage. Download, detect, reads: no lease.
  The servers are never started or reconfigured by the kit: plain requests to their own settings.
  Vision also holds the GPU (`gpu.exclusive.local-vision`, README "Leases"): it waits while an emulator lane or, with `idleExcept`,
  any other GPU process (nvidia-smi) uses it, and no lane boots while it runs.
Needed when: `media` = `*`, or listed in kit.local.json `goodies`.
- Config `media` (every key optional): `fetchers` (order), `jam.hosts`, `sharepoint.hosts` + `sharepoint.cookies` (`{host | "*":
  <cookies.txt path>}`: local only), `gdrive.hosts`, `jira.hosts`, `image.hosts` (`{host: <css selector>}`), `ytdlp.hosts`,
  `detect` (fps 12, width 640, pixel 18, cursorPx 26, settleMs 400, pageFrac 0.25, idleSec 3, maxCrops 60), `chunk` (minSec 20,
  maxSec 60, sectionSec 300, twoLevelOverSec 3600), `stt` (baseUrl, model whisper-1, path /v1/audio/transcriptions, pieceSec
  30, ramGB, maxConcurrent 1), `vision` (baseUrl, model, enabled, path /v1/chat/completions, maxFrames 40, maxEdge 1280,
  gpuStopGB, ramGB, maxConcurrent 1, system, prompt). Env `KIT_MEDIA_CONFIG`: a JSON file with a media object on top (tests).
- Needs: yt-dlp, ffmpeg + ffprobe, Python OpenCV + numpy, node (`npm install` in skills/pokey) and Chrome / Edge for headless grabs;
  optional `gws`, `nvidia-smi`.
- Wiring: `skills/pokey/adapters/evidence.ps1` (`Invoke-Evidence`: pokey.ps1 verb `evidence`), `skills/pokey/media_evidence.py`
  (fetchers + stages, also runs alone), `skills/pokey/adapters/media_grab.mjs` (headless stream / image grab),
  `skills/crafty/adapters/local_ai.ps1` (`Use-KitLocalAi`, `Remove-KitLocalAi`, `Get-KitSuperviseGuardLocalAi`: supervise shows
  holders and "waiting for local AI"). Tests: `tests.ps1`.
- Measured (2026-10-27, one laptop): detect 1-2 s per 10-50 s of 1080p; STT ~5 s per request + speech length on CPU (the server's
  worker ~6.3 GB RAM while loaded); index 150-320 tokens for a 10-50 s bug video without screen text.
- Vision model comparison (2026-10-27, 25 real UI frames: dark tables, filter panels, date fields, a toast, PDF previews; long edge
  1280; score = exact ids, amounts, dates and messages found in the reply):

  | Model (local proxy, its own settings) | Exact text | s / frame (median, mean) | GPU peak | backend RAM | Chatter |
  |---|---|---|---|---|---|
  | 27B dense, IQ3 | 177 / 195 (91%) | 44, 57 | 11.43 GiB | 8.6 GB | 0 / 25 |
  | 35B-A3B MoE, Q4 | not scored: its backend crashed (CUDA illegal memory access) on 3 of 5 image requests, 1 with the GPU idle | - | 11.36 GiB | 22 GB | - |

  Misses: a 3-digit seal number read as letters, "Rate" read as "Cost", columns cut at the frame edge. ~45 s a frame: keep
  `vision.maxFrames` small (start, page changes, clicked crops come first).
