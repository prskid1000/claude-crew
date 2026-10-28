# media-evidence
- What: tester evidence links (videos, screen recordings, screenshots) -> a time-indexed text index (~100 tokens per 30 s
  chunk) plus frames on demand, so no agent watches a bug video whole: `pokey.ps1 evidence index <link>` (fetch + index, prints
  the index) -> unread keyframes: the `vidy` agent (AGENTS.md R19) reads them and writes the screen text back -> later agents
  read the index -> `pokey.ps1 evidence read-chunk <key> <start> <end> | -At <m:ss> -Window <s> | -AroundError [-Frames 3]
  [-Size 1280] [-Item <task>]` (that window's events, speech, screen text, unread keyframe paths + JPEG frames for the Read
  tool). Also `fetch <link>`, `frames <key> [-Segment <n>]`, `write-vision <key> -File <items>`, `status`.
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
  re-indexes, so does a change of the `detect` / `chunk` / `stt` settings or `vidy.maxFrames` / `segmentSec`): detect (ffmpeg grey
  frames at ~12 fps, 640 px; change-then-settle events; page changes; typing; pointer moves; `click?` = a guess from the pointer,
  real clicks only from a source's events; ticking cells such as a recorder clock ignored) · transcribe (a sidecar transcript /
  VTT first, else the local OpenAI-compatible STT server on speech pieces; silent tracks skipped) · vision (no model call: the
  detector's keyframes - start, page changes, then changes by click and size - as full frames, native size up to 2000 px,
  at most `vidy.maxFrames` per segment of `vidy.segmentSec`, listed per chunk as `keyframes (unread: run vidy)`; vidy reads them
  in batches of `vidy.batch` and `write-vision` merges its screen text + one UI line per frame into `vision.json`, logs frames
  read, estimated image tokens and its own spend (kitlog `media-vision`) and rebuilds the index; one vidy per segment of a
  long video, their writes merge; a `-Refresh` keeps vidy's reading) · build (`index.md`: 20-60 s chunks split at page changes /
  idle, error flags; over `twoLevelOverSec` a section index + `index-sNN.md`).
- Resources: one OS lock per video key (a second agent waits, then reads the same cache); STT holds the lease `local-stt` (one
  job, bound to the job's process: a killed job frees it at once) and the memory gate reserves `stt.ramGB` (kind `local-ai`); a
  server that does not answer or a wait past `-WaitMinutes` -> "waiting for local AI" and an index without speech. Download,
  detect, keyframes, reads: no lease. The server is never started or reconfigured by the kit: plain requests to its own settings.
Needed when: `media` = `*`, or listed in kit.local.json `goodies`.
- Config `media` (every key optional): `fetchers` (order), `jam.hosts`, `sharepoint.hosts` + `sharepoint.cookies` (`{host | "*":
  <cookies.txt path>}`: local only), `gdrive.hosts`, `jira.hosts`, `image.hosts` (`{host: <css selector>}`), `ytdlp.hosts`,
  `detect` (fps 12, width 640, pixel 18, cursorPx 26, settleMs 400, pageFrac 0.25, idleSec 3, maxCrops 60), `chunk` (minSec 20,
  maxSec 60, sectionSec 300, twoLevelOverSec 3600), `stt` (baseUrl, model whisper-1, path /v1/audio/transcriptions, pieceSec
  30, ramGB, maxConcurrent 1), `vidy` (model sonnet: the agent's model; maxFrames 12 keyframes per segment; batch 8 frames per
  turn; segmentSec 300). Env `KIT_MEDIA_CONFIG`: a JSON file with a media object on top (tests).
- Needs: yt-dlp, ffmpeg + ffprobe, Python OpenCV + numpy, node (`npm install` in skills/pokey) and Chrome / Edge for headless grabs;
  optional `gws`.
- Measured (2026-10-27, one laptop): detect 1-2 s per 10-50 s of 1080p; STT ~5 s per request + speech length on CPU (the server's
  worker ~6.3 GB RAM while loaded); index 150-320 tokens for a 10-50 s bug video without screen text.
- Screen text (2026-10-28, the 25-frame comparison set: dark tables, filters, dates, a toast, PDF previews; score = exact ids,
  amounts, dates and messages found): vidy on Sonnet 194 / 195 (99%), ~4 k tokens a frame with its overhead; the earlier local
  35B-A3B vision model 184 / 195 (94%), ~48 s a frame.
