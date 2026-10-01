# Evidence standard

Every tested check leaves evidence that a reviewer, developer or customer can understand **without asking the tester**.
`finalize.ps1` checks names and publishes everything listed here.

## 1. Where
```
<run dir>\<CODE>\
├── shots\       screenshots (.jpeg web, .png app), short screen recordings (.mp4)
├── evidence\    API / network / DB / log evidence (.json, .log)
└── scripts\     the scripts you ran (kept, never published)
```

## 2. File names
`<CODE>-<checkId>[_verify]_<nn>_<what>.<ext>`  (ext: jpeg/png, json, log, pdf, csv, txt, html, xls/xlsx, mp4). Evidence saved elsewhere (absolute paths, verify folders) is collected by finalize.ps1; helper scripts are not evidence.

| Part | Rule | Example |
|---|---|---|
| `CODE` | package code from run.json | `F2` |
| `checkId` | exactly as in the guide; `X1`… for off-script defects | `T4`, `L2`, `X1` |
| `_verify` | only for the independent verifier's evidence | |
| `nn` | 2-digit step order inside the check (optional after `_verify`) | `01`, `02` |
| `what` | lowercase-kebab, ≤ 40 chars, says what is shown | `order-saved-toast`, `before-edit`, `after-edit`, `500-on-save` |

Good: `F2-T4_01_before-edit.jpeg`, `F2-T4_02_after-edit.jpeg`, `F2-T4_03_put-order.json`, `F2-X1_01_500-on-cancel.json`.
Bad: `screenshot1.png`, `F2 T4.jpeg`, `test.json`, `F2-T4_final_FINAL.jpeg`.

## 3. What each verdict needs
| Verdict | Minimum evidence |
|---|---|
| PASS (UI) | 1 screenshot of the **result** (the expected state visible, not a loading page). State changes: a `before` + `after` pair |
| PASS (API / backend) | 1 request/response JSON of the call that proves it |
| FAIL | screenshot of the failure state **and** the failing call JSON (`s.net.failed` → `saveNet`) or the error/log excerpt, plus exact steps in `what_was_done` |
| PASS_WITH_NOTE | the evidence a PASS needs, and the note says what differs from the guide |
| NOT_TESTED | no file needed; `observed` says why and what was tried |
| Verify (re-test) | the verifier's own files, with `_verify` in the name |

## 4. Formats
**Screenshots**
- Web: JPEG quality 80, 1600×1000 viewport. Prefer an element or region (`shot(page, f, {selector})`); full page only for layout checks.
- Before shooting, highlight the element that matters: `await mark(page, selector)` (red outline, removed after the shot).
- App: PNG from `ui.ps1 shot`, unscaled.
- Never a blank, loading, or login page. Open the image with Read before listing it.

**API / network JSON** (written by `api.ps1 -Save` and `browser.mjs saveNet`):
```json
{
  "meta":     { "code": "F2", "check": "T4", "target": "my-staging", "tenant": "acme", "user": "admin",
                "at": "2026-10-01T09:14:03Z", "durationMs": 412, "tool": "api.ps1" },
  "request":  { "method": "PUT", "url": "https://.../api/sale-orders", "headers": { "Authorization": "[redacted]" }, "body": { } },
  "response": { "status": 200, "headers": { "content-type": "application/json" }, "body": { } }
}
```
- Bodies over 200 KB are trimmed with a `"_truncated": true` marker; keep what proves the point.

**Logs**: `.log` text, only the relevant lines (± 20 lines around the error), with timestamps. App: `ui.ps1 log <tag>`.

**DB evidence** (read-only queries): `.json` with `{ meta, query, rows }`, at most 50 rows.

**Screen recordings** (only when a static shot can't show it, e.g. a flicker or a sequence): `.mp4` ≤ 30 s.

## 5. Redaction (always)
- Never store passwords, tokens, cookies, API keys: the helpers write `[redacted]` for `Authorization`, `Cookie`, `Set-Cookie`, `*token*`, `*password*`, `*secret*`, `*apiKey*` keys.
- Real customer data: prefer QA-created records (`QA-<CODE>` prefix). If a real customer's data must appear, crop it out
  of screenshots or mask it.

## 6. In results.json
- `evidence`: file names only (no paths), in step order, only files that exist.
- `observed` for a FAIL: what you saw + the failing call in one line: `PUT /api/sale-orders → 500 "NullPointerException at ..."`.
