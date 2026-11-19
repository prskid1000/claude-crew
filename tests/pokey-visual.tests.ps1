#Requires -Version 7
<#
tests/pokey-visual.tests.ps1: pokey's visual helpers on one test kit: annotate draws a labelled box into a copy; ui_checks.mjs
layoutIssues / contrast in a real headless Chrome; browser.mjs logins (totp, sso-steps over Playwright, shared cookie, the firefox hint).
Usage: pwsh -NoProfile -File tests/pokey-visual.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/android_sdk.ps1', 'skills/phoney/SKILL.md', 'skills/phoney/adapters/app_kinds.ps1', 'skills/phoney/adapters/arrange.ps1', 'skills/phoney/phoney.ps1',
  'skills/pokey/adapters/annotate.ps1', 'skills/pokey/adapters/ui_android.ps1', 'skills/pokey/adapters/ui_checks.mjs', 'skills/pokey/adapters/web-login.mjs')   # copied into the test kit
$k = New-TestKit visual; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $qk = Join-Path $k 'skills/pokey'; $bk = Use-BrowserKit   # browser.mjs + puppeteer-core linked once
# ---- annotate
if ($IsWindows) {
  Add-Type -AssemblyName System.Drawing; $png = Join-Path (Kd) 'shot.png'; $b = [Drawing.Bitmap]::new(200, 100); $b.Save($png, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
  $out = Px $Q annotate -In $png -Rect '10,40,50,30,Save button' -Copy 2>&1 | Out-String
  $m = [Drawing.Bitmap]::new((Join-Path (Kd) 'shot-marked.png')); $px = $m.GetPixel(10, 50); $m.Dispose()
  Expect "annotate: -Copy writes <name>-marked.png with a red box ($out)" ($out -match 'annotated .*shot-marked\.png \(1 rect\)' -and $px.R -gt 150 -and $px.G -lt 100)
  $badOut = Px $Q annotate -In $png -Rect 'a,b,c,d' 2>&1 | Out-String; $unlocked = try { [IO.File]::Open($png, 'Open', 'ReadWrite', 'None').Dispose(); $true } catch { $false }
  Expect "annotate: a bad -Rect fails and leaves the image unlocked ($($badOut.Trim()))" ($badOut -notmatch 'annotated ' -and $unlocked)
} else { 'SKIP annotate (Windows only)' }
# ---- ui-checks
if ($bk) {
  New-Item -ItemType Directory -Force "$qk/adapters" | Out-Null; Copy-Item (Join-Path $src 'skills/pokey/adapters/ui_checks.mjs') "$qk/adapters"
  $res = NodeT ui @'
import { createRequire } from 'node:module'
const exe = m.CHROME   // browser.mjs: the kit's one lookup and quiet flags
if (!exe) { console.log('nochrome'); process.exit(0) }
const br = await createRequire(BM)('puppeteer-core').launch({ executablePath: exe, headless: true, args: [...m.QUIET_ARGS, '--disk-cache-size=1'] }), page = await br.newPage()
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
# ---- web-login-types
if ($bk) {
  # TOTP form login, relogin (Chrome); sso-steps, shared cookie (Playwright)
  $pwm = $env:KIT_PLAYWRIGHT ?? "$(& $py -c 'import os, playwright; print(os.path.dirname(playwright.__file__))' 2>$null)/driver/package"; $eng = Join-Path $src 'skills/pokey/adapters/engine-playwright.mjs'   # sso / shared / hint need browser-engines too
  $nopw = -not (Test-Path "$pwm/index.mjs") -or -not (Test-Path $eng); if (-not $nopw) { Copy-Item $eng "$qk/adapters" }
  $res = NodeT auth ($LoginApp + @'
const [TF, PW] = process.argv.slice(2), F = { '#u': '{user}', '#c': '{totp}' }, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ default: 'form', targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, browser: { engine: 'chromium' }, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const { b, home, out } = await login()
console.log('totp:' + ((await import(BM.replace('browser.mjs', 'adapters/web-login.mjs'))).totp(U.admin[2], 59000) === '287082'))
await out('totp-login', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
PW && (process.env.KIT_PLAYWRIGHT = PW)
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === 3; await s.done(); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@) "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
  foreach ($x in 'totp', 'totp-login', 'sso', 'shared', 'hint') { if ($nopw -and $x -in 'sso', 'shared', 'hint') { "SKIP browser.mjs login: $x (no Playwright)" } else { Expect "browser.mjs login: $x" (@($res) -contains "${x}:true") } }
} else { 'SKIP browser.mjs (no puppeteer-core in skills/pokey)' }
$bmSrc = Get-Content (Join-Path $src 'skills/pokey/browser.mjs') -Raw
$bmUsers = @('skills/pokey/adapters/media_grab.mjs', 'skills/bossy/kitbag.py' | Where-Object { (Get-Content (Join-Path $src $_) -Raw) -notmatch 'QUIET_ARGS \}?\s*=\s*await import\(bm\)|import \{ kitPath, QUIET_ARGS \}|args: QUIET_ARGS|args: \[\.\.\.QUIET_ARGS' })
Expect "browser.mjs: every kit Chrome (sessions, ui-check, media grab) starts with no component, model, safe-browsing or background downloads, no disk cache unless browser.diskCache (missing: $($bmUsers -join ', '))" (
  $bmSrc -match "'--disable-component-update', '--disable-background-networking', '--safebrowsing-disable-auto-update',\s+'--disable-features=OptimizationGuideModelDownloading," -and $bmSrc.Contains("...QUIET_ARGS,") -and $bmSrc.Contains("...(bo.diskCache ? [] : ['--disk-cache-size=1'])") -and -not $bmUsers.Count)
# retro 2205: no upload map yet (-Check) -> plain file names, not 'Cannot index into a null array'
$qm = pwsh -NoProfile -Command ". '$Q' 6>`$null; (Build-QaReportMd -Title t -Code T2 -Item @{} -Res ([pscustomobject]@{ checks = @([pscustomobject]@{ id = 'C1'; result = 'PASS'; evidence = @('T2-C1_01_a.png') }) }) -Map `$null -Run @{} -Tester x -Date d -Cells @{}) -join ' '" 2>&1 | Out-String
Expect "report md: a null upload map renders file names ($($qm.Trim().Length) chars)" ($qm -match 'file: T2-C1_01_a\.png' -and $qm -notmatch 'null array')
Remove-TestKit $k
Complete-Tests
