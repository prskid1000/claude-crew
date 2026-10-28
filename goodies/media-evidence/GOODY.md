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
    pointer), caret, ticker (a small region stepping at a steady beat, e.g. a recorder's timer: never an event) and animation
    masks; episodes against a reference frame (settle 0.3 s, transient peak, a state held >= 0.2 s inside a
    long episode, scroll by row / column profiles, fade / dim); lazy greedy coverage under the budget `frames` + `framesPerMin`
    per minute (<= `maxFrames`), then every distinct state shown whole by one frame while the budget lasts; the coverage fill
    (over the budget, events `coverage-fill`): a held screen or a still 0.5 s sample no kept frame shows to `fillCoverage`
    (0.99 of its content, the pointer and animation aside; mid-change, mid-scroll, mid-fade and blends excluded) gets a frame,
    so does a stretch of `fillSec` shown less. Events:
    `page-change`, `modal` / `modal-closed`, `scroll`, `toast` (a corner panel that goes within 10 s, also over a page change
    under it), `highlight` (a fill: a dark-theme row tint is no toast), `text`, `change`, `transient`, `animated` (loading /
    playback: ONE event per screen region with its duration, <= 3 frames), `idle`, `cursor` moves, `click?` (a guess from the pointer), each with its `before` / `after` / `peak` keyframes and
    `(same)` for a revisit. Pictures: each keyframe's cheapest one that shows all of it: a full frame (native, long edge <= 2000
    px, `keyframes/kNNN-*.jpg`), or a delta = a full keyframe (its base) + native crops of the blocks that differ from it in place
    (merged while the union costs no more, `deltaMarginPx`, on Claude's 28 px patch grid) when they cost <= `deltaShare` of a
    full frame; deltas on one base within `montageSec` share one montage (`keyframes/mNNN-*.png`, tiles labelled `kNNN m:ss @x,y`,
    <= 1568 px and 1568 patches: never shrunk); no crop = the same screen as its base, no image. Coverage and recall count a delta
    by its base + crops. Token cost (`claude_tokens`): one per 28 x 28 patch after Claude's resize to 1568 px / 1568 patches.
  - sidecar actions: `<media>.events.json` beside a local file (pokey `browser.mjs` `record()`, `phoney.ps1 events`; only these:
    other videos are pixels only) anchors keyframes: each action's settled after-frame is kept, its line says `click "Save"
    [pokey] k003->k004`; times = `at` - `start` (epoch ms; no `start`: the file time minus the duration).
  - transcribe (a sidecar transcript / VTT first, else the local OpenAI-compatible STT server on speech pieces; silent tracks
    skipped) · vision (no model call: the detector's keyframes per segment of `vidy.segmentSec`, listed per chunk as `keyframes
    (unread: run vidy)`; vidy reads ONLY these, in batches of `vidy.batch`; `write-vision` merges its screen text + one UI line
    per frame into `vision.json` (WARN for a frame that is no keyframe), logs frames read, image tokens and its spend (kitlog
    `media-vision`) and rebuilds the index; segment vidys' writes merge; a `-Refresh` keeps vidy's reading) · build (`index.md`:
    20-60 s chunks split at page changes / modals / idle, error flags; over `twoLevelOverSec` a section index + `index-sNN.md`).
- Verify loop, by script (zero tokens; seconds and tokens per stage in kitlog `media-verify` / `media-tune`): after vidy's
  answer, `verify <key> -Tune` in the background: `label` (the oracle: every frame up to 30 fps at full resolution, a state = a
  screen held >= 0.3 s, judged once per hold; changes inside the detector's ticker and pointer areas make no state; tiny or
  low-contrast changes marked ambiguous) -> the detector's keyframes -> `feedback`: `labels.json`
  beside the media, one `<state>/media/feedback.jsonl` row per miss, the clip in `<state>/media/corpus.json`. Perfect -> `passed`,
  nothing more. A miss -> `tune`: coordinate descent over the detector's thresholds, block counts, settle time and coverage
  levels against the synthetic gate + the corpus; at corpus recall 1.0 with every gate it applies (`<state>/media/params.json`
  active, a log line, a learn signal), else it names the clips and windows one kitty (kind fix) must fix in code. vidy only
  confirms the ambiguous misses (cap `vidy.labelTokens`) and never edits the detector. Media, labels, corpus, feedback and
  params stay local (`.state/`, `.runtime/`, git-ignored); the goody holds only the generator code (a test checks it).
- `bench`: 11 synthetic clips with exact ground truth + 6 crf-36 variants (generated into the cache, never committed; gate:
  recall and key recall 1.0, precision >= 0.85, the 30 s loading = one event with <= 3 frames, no dark-theme toast, a ticking
  timer no event and a toast over a page change one, no frame twice) + every
  corpus clip whose media is cached (state recall: a full keyframe in the window or one picture showing >= 98% of it; a drop
  below its recorded recall or a rise over its recorded image tokens fails; `-Record` stores both, never worse; labels' `expect` rows `{kind, t0, t1, [box], [minSec], [absent]}` and one frame
  kept twice fail too). The corpus keeps media for the newest `corpus.keep` clips (`corpus.pin`: never
  evicted); older ones keep labels and feedback rows, `media: evicted` (skipped; `index <link>` fetches again).
- Resources: one OS lock per video key (a second agent waits, then reads the same cache); STT holds the lease `local-stt` (one
  job, bound to the job's process: a killed job frees it at once) and the memory gate reserves `stt.ramGB` (kind `local-ai`); a
  server that does not answer or a wait past `-WaitMinutes` -> "waiting for local AI" and an index without speech. Download,
  detect, keyframes, reads: no lease. The server is never started or reconfigured by the kit: plain requests to its own settings.
Needed when: `media` = `*`, or listed in kit.local.json `goodies`.
- Config `media` (every key optional): `fetchers` (order), `jam.hosts`, `sharepoint.hosts` + `sharepoint.cookies` (`{host | "*":
  <cookies.txt path>}`: local only), `gdrive.hosts`, `jira.hosts`, `image.hosts` (`{host: <css selector>}`), `ytdlp.hosts`,
  `detect` (fps 10, edge 960, edgeHi 1280, idleSec 3, frames 24, framesPerMin 6, maxFrames 120, fillSec 8, fillCoverage 0.99, deltaShare 0.5: 0 =
  full frames only, deltaMarginPx 16, montageSec 30), `corpus` (keep 10,
  pin []), `chunk` (minSec 20,
  maxSec 60, sectionSec 300, twoLevelOverSec 3600), `stt` (baseUrl, model whisper-1, path /v1/audio/transcriptions, pieceSec
  30, ramGB, maxConcurrent 1), `vidy` (model sonnet: the agent's model; batch 8 frames per turn; segmentSec 300; labelTokens
  80000: the verify phase's cap per video). Env `KIT_MEDIA_CONFIG`: a JSON file with a media object on top (tests).
- Needs: yt-dlp, ffmpeg + ffprobe, Python OpenCV + numpy, node (`npm install` in skills/pokey) and Chrome / Edge for headless grabs;
  optional `gws`.
- Measured (2026-10-28, one laptop): 4-8 ms per analysed frame at 960 px, selection and coverage fill included; synthetic set
  recall 1.000 (crf 36 too); a 357 s dense recording 140 keyframes (budget 59 + 81 fills), state recall 1.0; earlier detector
  0.253 synthetic recall; STT ~5 s per request + speech length on CPU (the server's
  worker ~6.3 GB RAM while loaded); index 150-320 tokens for a 10-50 s bug video without screen text.
- Screen text (2026-10-28, the 25-frame comparison set: dark tables, filters, dates, a toast, PDF previews; score = exact ids,
  amounts, dates and messages found): vidy on Sonnet 194 / 195 (99%), ~4 k tokens a frame with its overhead; the earlier local
  35B-A3B vision model 184 / 195 (94%), ~48 s a frame.
