# media-evidence
- What: tester evidence links (videos, screen recordings, screenshots) -> a time-indexed text index (~100 tokens per 30 s
  chunk) plus frames on demand, so no agent watches a bug video whole: `pokey.ps1 evidence index <link>` (fetch + index, prints
  the index) -> unread keyframes: the `vidy` agent (AGENTS.md R19) reads them and writes the screen text back -> later agents
  read the index -> `pokey.ps1 evidence read-chunk <key> <start> <end> | -At <m:ss> -Window <s> | -AroundError [-Frames 3]
  [-Size 1280] [-Item <task>]` (that window's events, speech, screen text, unread keyframe paths + JPEG frames for the Read
  tool). Also `fetch <link>`, `frames <key> [-Segment <n>]`, `write-vision <key> -File <items>`, `feedback <key> -File
  <verify>`, `bench [-Key <k>] [-Record]`, `status`.
- One file per type: `skills/pokey/video.py` (the whole flow; `pokey.ps1 evidence <verb>` passes through to it),
  `skills/crafty/adapters/video.ps1` (the pass-through and the `local-stt` lease; lib.ps1 loads it so supervise sees the lease),
  `skills/pokey/adapters/media_grab.mjs` (headless stream / image grab: needs node + Chrome). Tests: `tests.ps1`.
- One pipeline for every video; per source only a thin fetcher (link -> local file + sidecars), tried in `media.fetchers` order:
  `file` · `jam-public` (`<jam>.md`, `<jam>/transcript.md`, the stream URL from a throw-away headless browser, yt-dlp) ·
  `sharepoint` (yt-dlp + a cookies file per host; none or expired -> `unreadable: re-auth needed`, never a login) · `gdrive`
  (Drive / Meet recordings via `gws`) · `jira` (attachment URL with the tracker adapter's `JIRA_*` env) · `image` (an image host's
  page: the image element, headless) · `ytdlp` (Loom, YouTube, Vimeo, ...) · `http` (a direct media URL) · `manual`
  (`unreadable: <reason>, ask the tester for the file`).
- Index stages, cached per video (`<runtime>/cache/media/<key>/`, key = sha of the link; a new file or pipeline version
  re-indexes, so does a change of the `detect` / `chunk` / `stt` settings or `vidy.segmentSec`):
  - detect (pixels only, cv2 + numpy + ffmpeg): BGR frames at 10 fps, long edge 960 (1280 from 1440p up); a per-video noise
    model (16 px block counts of the max-channel difference, block means, codec pulses); pointer (a learned template, one
    pointer), caret and animation masks; episodes against a reference frame (settle 0.3 s, transient peak, a state held inside a
    long episode, scroll by row / column profiles, fade / dim); lazy greedy coverage under the budget `frames` + `framesPerMin`
    per minute (<= `maxFrames`), then every distinct state shown whole by one frame while the budget lasts; the coverage fill
    (over the budget, events `coverage-fill`): a 0.5 s sample no kept frame shows (>= 95% of its content, the pointer and
    animation aside; mid-scroll, mid-fade and blends excluded) gets a frame, so does a stretch of `fillSec` shown < 98%. Events:
    `page-change`, `modal` / `modal-closed`, `scroll`, `toast` (only once its region reverts), `highlight` (a fill: a dark-theme
    row tint is no toast), `text`, `change`, `transient`, `animated` (loading / playback: ONE event with its duration, <= 3
    frames), `idle`, `cursor` moves, `click?` (a guess from the pointer), each with its `before` / `after` / `peak` keyframes and
    `(same)` for a revisit. Keyframes: full frames, native size up to 2000 px (`keyframes/kNNN.jpg`).
  - sidecar actions: `<media>.events.json` beside a local file (pokey `browser.mjs` `record()`, `phoney.ps1 events`; only these:
    other videos are pixels only) anchors keyframes: each action's settled after-frame is kept, its line says `click "Save"
    [pokey] k003->k004`; times = `at` - `start` (epoch ms; no `start`: the file time minus the duration).
  - transcribe (a sidecar transcript / VTT first, else the local OpenAI-compatible STT server on speech pieces; silent tracks
    skipped) · vision (no model call: the detector's keyframes per segment of `vidy.segmentSec`, listed per chunk as `keyframes
    (unread: run vidy)`; vidy reads ONLY these, in batches of `vidy.batch`; `write-vision` merges its screen text + one UI line
    per frame into `vision.json` (WARN for a frame that is no keyframe), logs frames read, image tokens and its spend (kitlog
    `media-vision`) and rebuilds the index; segment vidys' writes merge; a `-Refresh` keeps vidy's reading) · build (`index.md`:
    20-60 s chunks split at page changes / modals / idle, error flags; over `twoLevelOverSec` a section index + `index-sNN.md`).
- Verify loop (vidy, after its answer): dense labels of the clip (every distinct screen state with its window; animation
  windows with a frame cap; up to `vidy.labelTokens` tokens) -> `feedback <key> -File <verify.json>`: `labels.json` beside the
  media, one `<state>/media/feedback.jsonl` row per finding (missed / wasted / wrong-label, window, frames, pipeline), the clip in
  `<state>/media/corpus.json`. Perfect -> `passed`, nothing more. Any finding -> `open` + the `TUNE` line: a kitty (kind fix)
  runs `bench -Key <key>` until that clip reaches recall 1.0, then a full `bench` (no clip drops), pushes, re-indexes
  (`index <link> -Refresh`) and a vidy re-checks the missed windows; out of budget -> it logs why and the clip stays `open`.
  vidy never edits the detector.
- `bench`: 10 synthetic clips with exact ground truth + 6 crf-36 variants (generated into the cache, never committed; gate:
  recall and key recall 1.0, precision >= 0.9, the 30 s loading = one event with <= 3 frames, no dark-theme toast) + every
  corpus clip whose media is cached (state recall: a kept frame in the window or one showing >= 98% of it; a drop below its
  recorded recall fails; `-Record` stores it). The corpus keeps media for the newest `corpus.keep` clips (`corpus.pin`: never
  evicted); older ones keep labels and feedback rows, `media: evicted` (skipped; `index <link>` fetches again).
- Resources: one OS lock per video key (a second agent waits, then reads the same cache); STT holds the lease `local-stt` (one
  job, bound to the job's process: a killed job frees it at once) and the memory gate reserves `stt.ramGB` (kind `local-ai`); a
  server that does not answer or a wait past `-WaitMinutes` -> "waiting for local AI" and an index without speech. Download,
  detect, keyframes, reads: no lease. The server is never started or reconfigured by the kit: plain requests to its own settings.
Needed when: `media` = `*`, or listed in kit.local.json `goodies`.
- Config `media` (every key optional): `fetchers` (order), `jam.hosts`, `sharepoint.hosts` + `sharepoint.cookies` (`{host | "*":
  <cookies.txt path>}`: local only), `gdrive.hosts`, `jira.hosts`, `image.hosts` (`{host: <css selector>}`), `ytdlp.hosts`,
  `detect` (fps 10, edge 960, edgeHi 1280, idleSec 3, frames 24, framesPerMin 6, maxFrames 120, fillSec 8), `corpus` (keep 10,
  pin []), `chunk` (minSec 20,
  maxSec 60, sectionSec 300, twoLevelOverSec 3600), `stt` (baseUrl, model whisper-1, path /v1/audio/transcriptions, pieceSec
  30, ramGB, maxConcurrent 1), `vidy` (model sonnet: the agent's model; batch 8 frames per turn; segmentSec 300; labelTokens
  80000: the verify phase's cap per video). Env `KIT_MEDIA_CONFIG`: a JSON file with a media object on top (tests).
- Needs: yt-dlp, ffmpeg + ffprobe, Python OpenCV + numpy, node (`npm install` in skills/pokey) and Chrome / Edge for headless grabs;
  optional `gws`.
- Measured (2026-10-28, one laptop): detect 4-5 ms per analysed frame at 960 px (8-11 ms with the coverage fill); synthetic set
  recall 1.000 (crf 36 too); a 357 s dense recording 99 keyframes (budget 59 + 40 fills), state recall 0.91; earlier detector
  0.253 synthetic recall; STT ~5 s per request + speech length on CPU (the server's
  worker ~6.3 GB RAM while loaded); index 150-320 tokens for a 10-50 s bug video without screen text.
- Screen text (2026-10-28, the 25-frame comparison set: dark tables, filters, dates, a toast, PDF previews; score = exact ids,
  amounts, dates and messages found): vidy on Sonnet 194 / 195 (99%), ~4 k tokens a frame with its overhead; the earlier local
  35B-A3B vision model 184 / 195 (94%), ~48 s a frame.
