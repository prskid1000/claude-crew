#Requires -Version 7
<#
tests/pokey-visual.tests.ps1: pokey's visual helpers on one test kit: annotate draws a labelled box into a copy; ui-checks.mjs
layoutIssues / contrast in a real headless Chrome; browser.mjs logins (totp, sso-steps over Playwright, shared cookie, the firefox hint), evidence paths.
Usage: pwsh -NoProfile -File tests/pokey-visual.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/android-sdk.ps1', 'skills/phoney/SKILL.md', 'skills/phoney/adapters/app-kinds.ps1', 'skills/phoney/adapters/arrange.ps1', 'skills/phoney/phoney.ps1',
  'skills/pokey/adapters/annotate.ps1', 'skills/pokey/adapters/engine-playwright.mjs', 'skills/pokey/adapters/ui-android.ps1', 'skills/pokey/adapters/ui-checks.mjs', 'skills/pokey/adapters/web-login.mjs')   # copied into the test kit
$k = New-TestKit visual; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $qk = Join-Path $k 'skills/pokey'; $bk = Use-BrowserKit   # browser.mjs + puppeteer-core linked once
# ---- annotate
if ($IsWindows) {
  Add-Type -AssemblyName System.Drawing; $png = Join-Path (Kd) 'shot.png'; $b = [Drawing.Bitmap]::new(200, 100); $b.Save($png, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
  $out = Px $Q annotate -In $png -Rect '10,40,50,30,Save button' -Copy 2>&1 | Out-String
  $m = [Drawing.Bitmap]::new((Join-Path (Kd) 'shot-marked.png')); $px = $m.GetPixel(10, 50); $m.Dispose()
  Expect "annotate: -Copy writes <name>-marked.png with a red box ($out)" ($out -match 'annotated .*shot-marked\.png \(1 rect\)' -and $px.R -gt 150 -and $px.G -lt 100)
  $badOut = Px $Q annotate -In $png -Rect 'a,b,c,d' 2>&1 | Out-String; $unlocked = try { [IO.File]::Open($png, 'Open', 'ReadWrite', 'None').Dispose(); $true } catch { $false }
  Expect "annotate: a bad -Rect fails naming the shape and leaves the image unlocked ($(@($badOut -split "`n" -match 'want ')[0].Trim()))" ($badOut -notmatch 'annotated ' -and $badOut -match "-Rect 'a,b,c,d': want 'x,y,w,h\[,label\]'" -and $unlocked)
} else { 'SKIP annotate (Windows only)' }
# ---- ui-checks
if ($bk) {
  # 2026-11-21: a relative shots/ path from a kit folder wrote <kit>/skills/shots
  $res = NodeT evpath ("const { join } = await import('node:path'), t = (f) => { try { return m.checkName(f) } catch (e) { return /inside the kit/.test(e.message) ? 'refused' : e.message } }, rt = m.kitPath('runtime', { create: true })`n" +
    "process.chdir(join(m.KIT, 'skills')); const a = t('shots/F1-T1_01_x.jpeg'); process.chdir(rt); const b = t('qa/F1/shots/F1-T1_01_x.jpeg')`n" +
    "const c = t(rt + '-x/F1-T1_01_x.jpeg'), d = t(rt.toUpperCase() + '/F1-T1_01_x.jpeg')`n" +
    "console.log(a, b === join(rt, 'qa/F1/shots/F1-T1_01_x.jpeg'), c, process.platform === 'win32' ? d !== 'refused' : true)")
  Expect "browser.mjs evidence: a relative path inside the kit or a runtime sibling is refused; the runtime folder (any case) gets an absolute path ($res)" ("$res" -eq 'refused true refused true')
  New-Item -ItemType Directory -Force "$qk/adapters" | Out-Null; Copy-Item (Join-Path $src 'skills/pokey/adapters/ui-checks.mjs') "$qk/adapters"
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
// each key on its own free port: a hashed one may be a live agent's or another suite's Chrome (cookies, posts, kills cross)
const net = await import('node:net'), free = () => new Promise((r) => { const sv = net.createServer().listen(0, '127.0.0.1', () => { const p = sv.address().port; sv.close(() => r(p)) }) })
writeFileSync(m.kitPath('browser-ports', { create: true }), JSON.stringify({ [m.sessionKey('form', 'a', 'admin')]: await free(), [m.sessionKey('sso', 'b', 'admin')]: await free(), [m.sessionKey('ff', '', 'admin')]: await free() }))
const { b, home, out } = await login()
console.log('totp:' + ((await import(BM.replace('browser.mjs', 'adapters/web-login.mjs'))).totp(U.admin[2], 59000) === '287082'))
await out('totp-login', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
PW && (process.env.KIT_PLAYWRIGHT = PW)
const p0 = posts   // sso posts once, shared reuses its cookie: counted from here, so a totp-login miss is its own FAIL only
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === p0 + 1; await s.done(); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@) "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
  foreach ($x in 'totp', 'totp-login', 'sso', 'shared', 'hint') { if ($nopw -and $x -in 'sso', 'shared', 'hint') { "SKIP browser.mjs login: $x (no Playwright)" } else { Expect "browser.mjs login: $x$(if (@($res) -notcontains "${x}:true") { " ($(@($res) -match "^${x}:" | Select-Object -First 1))" })" (@($res) -contains "${x}:true") } }
} else { 'SKIP browser.mjs (no puppeteer-core in skills/pokey)' }
$bmSrc = Get-Content (Join-Path $src 'skills/pokey/browser.mjs') -Raw
$bmUsers = @('skills/pokey/adapters/media-grab.mjs', 'skills/bossy/kitbag.py' | Where-Object { (Get-Content (Join-Path $src $_) -Raw) -notmatch 'QUIET_ARGS \}?\s*=\s*await import\(bm\)|import \{ kitPath, QUIET_ARGS \}|args: QUIET_ARGS|args: \[\.\.\.QUIET_ARGS' })
Expect "browser.mjs: every kit Chrome (sessions, ui-check, media grab) starts with no component, model, safe-browsing or background downloads, no disk cache unless browser.diskCache (missing: $($bmUsers -join ', '))" (
  $bmSrc.Contains("'vocab.json'), 'utf8')).chromeQuietArgs || []") -and $bmSrc.Contains('.quietProfile(`${PROFILES}/') -and $bmSrc.Contains("...QUIET_ARGS,") -and $bmSrc.Contains('.pwPage(eng, bo, VIEW, QUIET_ARGS)') -and $bmSrc.Contains("...(bo.diskCache ? [] : ['--disk-cache-size=1'])") -and -not $bmUsers.Count)
# one quiet-flag list (vocab.json chromeQuietArgs) for every kit Chromium: browser.mjs, Playwright chromium, report_pdf.py, Cypress Electron (build-heap.ps1, gate kind cypress)
$qa = @((Get-Content (Join-Path $src 'skills/crafty/vocab.json') -Raw | ConvertFrom-Json).chromeQuietArgs)
if ($bk) {
  $qpd = Join-Path (Kd) 'qp'; New-Item -ItemType Directory -Force $qpd | Out-Null; [IO.File]::WriteAllText((Join-Path $qpd 'Local State'), '{"browser":{"x":1},"component_updates":{"other":2}}')
  $qp = NodeT qp "const a = await import(new URL('adapters/engine-playwright.mjs', BM)); a.quietProfile(process.argv[2]); a.quietProfile(process.argv[2] + '/new'); console.log('ok')" $qpd
  $qs = Get-Content (Join-Path $qpd 'Local State') -Raw | ConvertFrom-Json; $qn = Get-Content (Join-Path $qpd 'new/Local State') -Raw | ConvertFrom-Json
  Expect "browser.mjs quietProfile: seeds vocab.json chromeLocalState into a profile's Local State (kept keys; a new profile gets it) ($qp)" (
    $qs.component_updates.component_updates_enabled -eq $false -and $qs.component_updates.other -eq 2 -and $qs.browser.x -eq 1 -and $qn.component_updates.component_updates_enabled -eq $false)
} else { 'SKIP browser.mjs quietProfile (no puppeteer-core in skills/pokey)' }
# a kit worktree reads the main clone's logins file; a login user create made keeps its tenant
if ($bk) {
  $res = NodeT wtlogins @'
const { mkdirSync, writeFileSync } = await import('node:fs'), { join } = await import('node:path'), r = process.argv[2], mn = join(r, 'main'), wt = join(r, 'wt'), gd = join(mn, '.git', 'worktrees', 'w')
for (const d of [gd, join(mn, 'skills', 'pokey'), wt]) mkdirSync(d, { recursive: true })
writeFileSync(join(gd, 'commondir'), '../..\n'); writeFileSync(join(wt, '.git'), `gitdir: ${gd}\n`); writeFileSync(join(mn, 'skills', 'pokey', 'targets.local.json'), '{}')
const t = { defaultTenant: 'd', created: { qa: { tenant: 'c' } } }
console.log(m.localFile('skills/pokey/targets.local.json', wt) === join(mn, 'skills', 'pokey', 'targets.local.json'), m.localFile('nope.json', wt) === join(wt, 'nope.json'), [m.tenantOf(t, 'qa'), m.tenantOf(t, 'x'), m.tenantOf(t, 'qa', 'e')].join())
'@ (Join-Path (Kd) 'wtl')
  Expect 'browser.mjs: a kit worktree finds the main clone logins file; a created login keeps its tenant' ("$res" -eq 'true true c,d,e')
} else { 'SKIP browser.mjs worktree logins (no puppeteer-core in skills/pokey)' }
$qUsers = @{ 'skills/crafty/adapters/report_pdf.py' = "dt.VOCAB.get('chromeQuietArgs'"; 'skills/pokey/adapters/media-grab.mjs' = 'quietProfile(mkdtempSync('; 'skills/bossy/kitbag.py' = 'userDataDir: ud,'; 'skills/crafty/adapters/build-heap.ps1' = "if (`$Kind -eq 'cypress' -and -not `$env:ELECTRON_EXTRA_LAUNCH_ARGS) { `$env:ELECTRON_EXTRA_LAUNCH_ARGS = `$script:KitVocab.chromeQuietArgs -join"; 'skills/pokey/adapters/engine-playwright.mjs' = "args: eng === 'chromium' ? quiet : []" }
$qMiss = @($qUsers.Keys | Where-Object { -not (Get-Content (Join-Path $src $_) -Raw).Contains($qUsers[$_]) })
$qCopies = @(git -C $src grep -l -e 'OptimizationGuideModelDownloading' -- 'skills' | Where-Object { $_ -ne 'skills/crafty/vocab.json' })
Expect "vocab.json chromeQuietArgs: one list, every kit Chromium start reads it (missing: $($qMiss -join ', '); copies: $($qCopies -join ', '))" (
  $qa -contains '--disable-component-update' -and $qa -contains '--disable-background-networking' -and @($qa -match '^--disable-features=OptimizationGuideModelDownloading,').Count -eq 1 -and -not $qMiss.Count -and -not $qCopies.Count)
# retro 2205: no upload map yet (-Check) -> plain file names, not 'Cannot index into a null array'
$qm = pwsh -NoProfile -Command ". '$Q' 6>`$null; (Build-QaReportMd -Title t -Code T2 -Item @{} -Res ([pscustomobject]@{ checks = @([pscustomobject]@{ id = 'C1'; result = 'PASS'; evidence = @('T2-C1_01_a.png') }) }) -Map `$null -Run @{} -Tester x -Date d -Cells @{}) -join ' '" 2>&1 | Out-String
Expect "report md: a null upload map renders file names ($($qm.Trim().Length) chars)" ($qm -match 'file: T2-C1_01_a\.png' -and $qm -notmatch 'null array')
# adapters/web-login.mjs laneTarget (browser.mjs session): '<target>-<bird>' / '<target><k>' = the base target's login on lane k's ports (as pokey.ps1)
$lnT = "import { laneTarget } from '$((Join-Path $src 'skills/pokey/adapters/web-login.mjs').Replace('\', '/') -replace '^', 'file:///')'`nconst tg = { loc: { web: 'http://localhost:4200', api: 'http://localhost:8443/api', users: { u: 1 } } }`nconst ln = [{ env: 'ab-falcon', group: 'ab', lane: 1, ports: { web: 4200, api: 8443 } }, { env: 'ab-kestrel', group: 'ab', lane: 2, ports: { web: 4300, api: 8543 } }]`nconst a = laneTarget('loc-kestrel', tg, ln), b = laneTarget('loc2', tg, ln)`nconsole.log([a.web, a.api, a.users.u, b.web, laneTarget('loc-falcon', tg, ln) === tg.loc, laneTarget('nope-kestrel', tg, ln), tg.loc.web].join('|'))"
Set-Content "$(Kd)/lane.mjs" $lnT; $lno = node "$(Kd)/lane.mjs" 2>&1 | Out-String
Expect "browser laneTarget: lane URLs, base login; lane 1 = base; unknown base = null; base unchanged ($lno)" ($lno.Trim() -eq 'http://localhost:4300|http://localhost:8543/api|1|http://localhost:4300|true||http://localhost:4200')
Remove-TestKit $k
Complete-Tests
