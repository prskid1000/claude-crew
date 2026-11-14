#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/ui-checks.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests.ps1 (goody ui-checks): layoutIssues finds a covered control, overlapping text and clipped text (not scrolled-away rows);
# contrast gives the WCAG ratio for text and an SVG icon. A real headless Chrome; next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/ui_checks.mjs')   # copied into every New-TestKit kit
$k = New-TestKit ui; $qk = Join-Path $k 'skills/pokey'
if (Use-BrowserKit) {
  New-Item -ItemType Directory -Force "$qk/adapters" | Out-Null; Copy-Item (Join-Path $src 'skills/pokey/adapters/ui_checks.mjs') "$qk/adapters"
  $res = NodeT ui @'
import { createRequire } from 'node:module'
import { existsSync } from 'node:fs'
const exe = [process.env.CHROME_PATH, 'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find((x) => x && existsSync(x))
if (!exe) { console.log('nochrome'); process.exit(0) }
const br = await createRequire(BM)('puppeteer-core').launch({ executablePath: exe, headless: true }), page = await br.newPage()
await page.setViewport({ width: 800, height: 600 })
const at = (l, t) => `position:absolute;left:${l}px;top:${t}px`
await page.setContent(`<body style="margin:0;font:14px sans-serif"><div style="position:absolute;right:10px;bottom:10px"><button id="next">Next</button></div>
<div id="fab" style="position:fixed;right:0;bottom:0;width:80px;height:60px;background:#06c"></div><span id="h1" style="${at(100, 100)}">08:00</span>
<span id="h2" style="${at(110, 102)}">09:00</span><div id="chip" style="${at(300, 100)};width:60px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis">a long chip label</div>
<div style="${at(300, 200)};width:120px;height:40px;overflow:auto"><p>row 1</p><p>row 2</p><p>row 3</p><button>deep</button></div>
<p id="ok" style="${at(500, 300)};color:#000">fine</p><span id="icon" style="${at(500, 400)}"><svg width="20" height="20"><path d="M0 0h20v20H0z" fill="#ddd"/></svg></span></body>`)
const li = await m.layoutIssues(page), t = await m.contrast(page, '#ok'), i = await m.contrast(page, '#icon')
console.log(`layout:${li.count === 3 && li.covered[0]?.el.includes('#next') && li.covered[0].by.includes('#fab') && li.overlaps[0]?.a.includes('#h1') && li.clipped[0]?.includes('#chip')}`)
console.log(`contrast:${t.ratio === 21 && t.pass && i.ratio === 1.36 && i.min === 3 && !i.pass}`)
await br.close()
'@
  if ("$res" -match 'nochrome') { 'SKIP ui-checks (no Chrome or Edge)' } else { Expect-Each $res 'ui-checks #' 'layout', 'contrast' }
} else { 'SKIP ui-checks (no puppeteer-core in skills/pokey)' }
Remove-TestKit $k
Complete-Tests
