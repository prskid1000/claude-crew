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
  # retro 2026-11-25: a script ending without s.done() leaked its tab (moved here for the params.tests.ps1 cap)
  $relf = Join-Path (Kd) 'released-end.txt'; $null = NodeT exitend "const fs = await import('node:fs'), f = process.argv[2]; m.releaseOnExit(async () => fs.appendFileSync(f, 'c')); process.exitCode = 3" $relf; $relc = $LASTEXITCODE
  Expect "browser.mjs: a script ending without s.done() still runs it (tabs closed), its exit code kept ($relc)" ($relc -eq 3 -and (Get-Content $relf -Raw) -eq 'c')
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
const h = await m.hitTest(page, ['#next', '#ok', { text: 'fine' }, '#none']), vw = await m.testerScreen({ page }, async () => page.viewport().width)
console.log(`hit:${!h.pass && h.rows.map((r) => r.ok).join() === 'false,true,true,false' && h.rows[0].by === 'div#fab' && h.rows[3].by === 'not found' && vw[0].result === 1366 && page.viewport().width === 800}`)
// waits: waitFor returns once the text shows (a miss throws naming it); quiet = a still DOM, not the full max; sheet = one image of n shots
const fs = await import('node:fs'), { fileURLToPath } = await import('node:url'), dir = new URL('./sheet-t/', BM); fs.mkdirSync(dir, { recursive: true }); const f = (n) => fileURLToPath(new URL(n, dir))
await page.screenshot({ path: f('a.jpeg') }); await page.setContent(`<body><p id="s">wait</p><script>setTimeout(() => { s.textContent = 'Saved' }, 300)</script></body>`)
const wf = await m.waitFor(page, 'Saved', { timeout: 3000 }); let miss = ''; try { await m.waitFor(page, { gone: 'Saved' }, { timeout: 300 }) } catch (e) { miss = e.message }
const q0 = Date.now(); await m.quiet(page, 1500); const qd = Date.now() - q0; await page.screenshot({ path: f('b.jpeg') }); const sh = await m.sheet({ browser: br }, [f('a.jpeg'), f('b.jpeg')], f('ab-sheet.jpeg'), { width: 800 })
console.log(`waits:${wf >= 200 && wf < 2500 && /gone.*not within 300 ms/.test(miss) && qd < 1000 && fs.statSync(sh).size > fs.statSync(f('b.jpeg')).size}`)
await br.close()
'@
  if ("$res" -match 'nochrome') { 'SKIP ui-checks (no Chrome or Edge)' } else { Expect-Each $res 'ui-checks (hit: hitTest covered / found / missing, testerScreen 1366 then restored; waits: waitFor, quiet, sheet) #' 'layout', 'contrast', 'hit', 'waits' }
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
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === p0 + 1; await s.done(); if (k === 'shared') await b.killSession(s.port); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@) "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
  foreach ($x in 'totp', 'totp-login', 'sso', 'shared', 'hint') { if ($nopw -and $x -in 'sso', 'shared', 'hint') { "SKIP browser.mjs login: $x (no Playwright)" } else { Expect "browser.mjs login: $x$(if (@($res) -notcontains "${x}:true") { " ($(@($res) -match "^${x}:" | Select-Object -First 1))" })" (@($res) -contains "${x}:true") } }
} else { 'SKIP browser.mjs (no puppeteer-core in skills/pokey)' }
$bmSrc = Get-Content (Join-Path $src 'skills/pokey/browser.mjs') -Raw
$bmUsers = @('skills/pokey/adapters/media-grab.mjs', 'skills/bossy/kitbag.py' | Where-Object { (Get-Content (Join-Path $src $_) -Raw) -notmatch 'QUIET_ARGS \}?\s*=\s*await import\(bm\)|import \{ kitPath, QUIET_ARGS \}|args: QUIET_ARGS|args: \[\.\.\.QUIET_ARGS' })
Expect "browser.mjs: every kit Chrome (sessions, ui-check, media grab) starts with no component, model, safe-browsing or background downloads, no disk cache unless browser.diskCache (missing: $($bmUsers -join ', '))" (
  $bmSrc.Contains("'vocab.json'), 'utf8')).chromeQuietArgs || []") -and $bmSrc.Contains('.quietProfile(`${PROFILES}/') -and $bmSrc.Contains("...QUIET_ARGS,") -and $bmSrc.Contains('eg.session(eng, bo, VIEW, QUIET_ARGS)') -and (Get-Content (Join-Path $src 'skills/pokey/adapters/engine-playwright.mjs') -Raw).Contains("['chromium'] = { session: pwPage, reuse: pwServed, context: wrapPage }") -and $bmSrc.Contains("...(bo.diskCache ? [] : ['--disk-cache-size=1'])") -and -not $bmUsers.Count)
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
# browser.mjs pick / matrix (moved from pokey.tests.ps1: its token cap)
if ($bk) {
  # datay-15: a logins-only lane entry in the targets file hid the base target's web / webLogin (session on about:blank)
  $rtF = Join-Path (Kd) 'rt-targets.json'; Set-Content $rtF '{"targets":{"loc":{"web":"http://localhost:4200","api":"http://localhost:8443/api","webLogin":{"type":"form"},"defaultUser":"admin","users":{"admin":["a","x"],"qa":["base","x"]}},"loc-kestrel":{"defaultUser":"qa","users":{"qa":["lane","y"]},"created":{"qa":{"tenant":"c"}}},"loc-falcon":{"users":{"qa":["l1","z"]}},"own-kestrel":{"web":"http://own:1"},"solo":{"users":{}}}}'
  $res = NodeT rt @'
const tg = JSON.parse((await import('node:fs')).readFileSync(process.argv[2], 'utf8')).targets, wl = await import(BM.replace('browser.mjs', 'adapters/web-login.mjs'))
const ln = [{ env: 'ab-falcon', group: 'ab', lane: 1, ports: { web: 4200, api: 8443 } }, { env: 'ab-kestrel', group: 'ab', lane: 2, ports: { web: 4300, api: 8543 } }]
const r = wl.resolveTarget('loc-kestrel', tg, ln), f = wl.resolveTarget('loc-falcon', tg, ln)
console.log([r.web, r.api, Object.keys(r.users).join(), r.users.qa[0], r.created.qa.tenant, r.defaultUser, r.webLogin.type, wl.resolveTarget('own-kestrel', tg, ln) === tg['own-kestrel'], wl.resolveTarget('solo', tg, ln) === tg.solo, f !== tg.loc && f.users.qa[0] + f.web, tg.loc.users.qa[0] + tg.loc.defaultUser, wl.resolveTarget('nope', tg, ln)].join('|'))
'@ $rtF
  Expect "browser.mjs session resolveTarget (web-login.mjs): a logins-only lane entry = the base on the lane's ports, its logins and defaults over the base's; own URLs as is; base unchanged, lane 1 too; session() calls it ($res)" ($bmSrc.Contains(".resolveTarget(tn, CFG.targets) || targetOf(tn)") -and "$res" -eq 'http://localhost:4300|http://localhost:8543/api|admin,qa|lane|c|qa|form|true|true|l1http://localhost:4200|baseadmin|')
  $res = NodeT pick ("const pg = (els) => ({ waitForSelector: async () => {}, `$`$: async () => els }), e = (p) => m.pick(p, '.x', 0, 'x').catch((x) => x.message)`n" +
    "console.log(/has 0 match\(es\), no index 0/.test(await e(pg([]))), /has no box/.test(await e(pg([{ scrollIntoView: async () => {}, boundingBox: async () => null }]))))")
  Expect 'browser.mjs pick: bad nth / hidden element errors' ("$res" -eq 'true true')
  $res = NodeT matrix ("const vs = [], s = { page: { viewport: () => ({ width: 9, height: 9 }), setViewport: async (v) => vs.push(v.width) } }, o = (v, f) => ({ matrix: { viewports: v, fontScales: f } })`n" +
    "const r = await m.matrix(s, async (v) => v.tag, o(['1280x720', '1920x1080'], [2])); console.log(r.map((x) => x.result).join(), vs.join(), await m.matrix(s, 0, o(['1280'])).catch((e) => /<width>x<height>/.test(e.message)), await m.matrix(s, 0, { matrix: { locales: ['de'] } }).catch((e) => /context of its own/.test(e.message)))")
  Expect 'browser.mjs matrix: each qa.matrix variant, viewport restored; a bad viewport names its fix; a locale with no browser is refused, never tagged unapplied' ("$res" -eq '1280x720_f2,1920x1080_f2 1280,1920,9 true true')
  # owner 2026-11-25: 5 UI cases x 9 variants ran one after another (~2 h); variants now run at once, a context each, in one Chrome
  $wl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $wl.Start(); $wp = $wl.LocalEndpoint.Port; $wl.Stop()
  [IO.File]::WriteAllText("$qk/targets.local.json", "{`"default`": `"loc`", `"targets`": {`"loc`": {`"web`": `"http://127.0.0.1:$wp`"}}}")
  $kf = Join-Path $k 'skills/crafty/kit.local.json'; $kj = if (Test-Path $kf) { Get-Content $kf -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
  $kj.qa = @{ matrix = @{ viewports = @('800x600', '1024x700', '390x844'); fontScales = @(1, 2, 3) } }; $kj | ConvertTo-Json -Depth 9 | Set-Content $kf
  # coordinator 2026-11-25: a case calling browser.mjs hitTest hung the CLI (it re-imported itself); the menu sits behind a hamburger
[IO.File]::WriteAllText("$(Kd)/case.mjs", "export default async ({ page, tag, b, ui }) => { const nav = await ui.openNav(page), h = await b.hitTest(page, [{ text: 'Groups' }])`n  return { result: process.env.FAILX && tag.startsWith('390') ? 'FAIL' : nav && h.pass ? 'PASS' : 'FAIL', w: await page.evaluate(() => innerWidth) } }")
  $res = NodeT pmatrix @'
const { existsSync, readFileSync, writeFileSync, mkdirSync } = await import('node:fs'), { join } = await import('node:path'), { execFile } = await import('node:child_process')
if (!m.CHROME) { console.log('nochrome'); process.exit(0) }
const [wp, dir] = process.argv.slice(2), http = await import('node:http'), net = await import('node:net')
const srv = http.createServer((q, r) => { r.setHeader('content-type', 'text/html'); r.end('<button class="navbar-toggler" aria-expanded="false" onclick="document.getElementById(\'m\').hidden=false">=</button><nav id="m" hidden><a href="#">Groups</a></nav><p>x</p>') }).listen(+wp, '127.0.0.1'); await new Promise((r) => srv.on('listening', r))
const cp = await new Promise((r) => { const sv = net.createServer().listen(0, '127.0.0.1', () => { const p = sv.address().port; sv.close(() => r(p)) }) })
writeFileSync(m.kitPath('browser-ports', { create: true }), JSON.stringify({ [m.sessionKey('loc', '', '')]: cp }))
process.env.CLAUDE_AGENT = 'kt-a'; const bf = join(m.kitPath('agents'), 'kt-a', `busy-${process.pid}.json`)
const s = await m.session(); await m.go(s.page, '/'); await s.page.evaluate(() => localStorage.setItem('tok', 'T')); const busy = existsSync(bf)
const work = async (v) => { await new Promise((r) => setTimeout(r, 1500)); return v.page.evaluate((t) => { const seen = localStorage.getItem('tok') + (localStorage.getItem('mine') || ''); localStorage.setItem('mine', t); return { result: 'PASS', w: innerWidth, l: navigator.language, seen } }, v.tag) }
const mx = { viewports: ['800x600', '1024x700', '390x844'], fontScales: [1, 2, 3] }
let t = Date.now(); const par = await m.matrix(s, work, { matrix: { ...mx, locales: ['de-DE'] }, parallel: 4 }), parMs = Date.now() - t
t = Date.now(); const ser = await m.matrix(s, work, { matrix: mx }), serMs = Date.now() - t
console.log(`par:${par.length === 9 && par.every((x) => x.result.seen === 'T' && x.result.l === 'de-DE' && x.variant.endsWith('_de-de')) && par.map((x) => x.result.w).join() === ser.map((x) => x.result.w).join() && ser[1].result.seen !== 'T'}`)
// coordinator 2026-11-25: a context stayed open under load; a hung variant times out, FAILs, and its context still closes
const to = await m.matrix(s, async (v) => { if (v.tag.startsWith('390')) await new Promise(() => {}); return { result: 'PASS' } }, { matrix: { viewports: ['800x600', '390x844'] }, parallel: 2, variantSec: 2 })
console.log(`timeout:${to[0].result.result === 'PASS' && /timed out after 2 s/.test(to[1].result.error)}`)
console.log(`clean:${s.browser.browserContexts().length === 1}`); console.log(`busy:${busy}`); await s.done(); console.log(`unbusy:${!existsSync(bf)}`)
// async: a sync spawn blocks this process's web server (a 60 s stall per CDP call)
const cli = (env, ...a) => new Promise((r) => execFile(process.execPath, [m.KIT + '/skills/pokey/matrix.mjs', '--case', 'A1', '--script', dir + '/case.mjs', '--out', dir + '/mx', '--path', '/', ...a], { encoding: 'utf8', env: { ...process.env, ...env } }, (e, stdout, stderr) => r({ status: e ? e.code : 0, stdout, stderr })))
const full = await cli({}), j = JSON.parse(readFileSync(dir + '/mx/A1-matrix.json', 'utf8'))
console.log(`cli:${full.status === 0 && j.rows.length === 9 && j.rows.every((x) => x.result.result === 'PASS') && /^Matrix: 800x600_f1, 800x600_f2, .*390x844_f3$/m.test(full.stdout)}`)
mkdirSync(m.kitPath('tasks'), { recursive: true }); writeFileSync(join(m.kitPath('tasks'), 'T9.json'), JSON.stringify({ cases: { matrixScope: { scope: 'reduced', reason: '1 file(s)', matrix: { viewports: ['1366x768', '390x844'] } } } }))
const red = await cli({ FAILX: '1' }, '--task', 'T9'), none = await cli({}, '--task', 'T8')
console.log(`reduced:${red.status === 1 && /^FAIL A1 390x844 /m.test(red.stdout) && /^Matrix: 1366x768, 390x844 \(reduced: 1 file\(s\)\)$/m.test(red.stdout) && none.status === 2 && /matrix-scope T8/.test(none.stderr)}`)
console.log(`speed:${parMs < serMs * 0.75} ${serMs} ${parMs}`); await m.killSession(cp); srv.close(); process.exit(0)
'@ $wp (Kd)
  if ("$res" -match 'nochrome') { 'SKIP matrix parallel (no Chrome or Edge)' } else {
    Expect-Each $res 'browser.mjs matrix: parallel = a context per variant (own viewport, locale, storage; the login copied), closed after (a hung variant: timed out, FAIL, closed too); matrix.mjs CLI (a case calling hitTest, openNav): per-variant results + the Matrix line, a recorded reduced set, exit 1 on a FAIL; a session marks its agent busy #' 'par', 'timeout', 'clean', 'busy', 'unbusy', 'cli', 'reduced'
    $sp = "$(@($res) -match '^speed:')"; Expect "matrix: 9 variants of 1.5 s, 4 at once (3 waves + ~1 s context and load each) vs one after another ($sp ms)" ($sp -match '^speed:True ') }
}
# prepare (moved from qa-config: its cap): the run title is cut to 25 words
$ttl = pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; (Limit-KitWords ((1..30 | ForEach-Object { ""w`$_"" }) -join ' ') 25 '+3-items'), (Limit-KitWords 'a b' 25 x)"
Expect "prepare: the run title is cut to 25 words at creation (finalize -Check limit), the last word says how many items ($($ttl[0]))" (@($ttl[0] -split ' ').Count -eq 25 -and $ttl[0] -match 'w24 \+3-items$' -and $ttl[1] -eq 'a b' -and (Get-Content $Q -Raw) -match 'title = \(Limit-KitWords ')
# guide copy (owner 2026-11-22: a 1494-line guide of earlier runs): the head + the newest env run, older runs only counted; one run: whole
# 2026-11-25 (supervise ACT, 8k-token guide reads): the newest run's "### Evidence index" and a "## Round <n> — <date>" section are not copied either
$gkept = Join-Path (Kd) 'kept.md'; Set-Content $gkept "# Testing: X`n## Checks`n| C1 | a |`n## shop-staging run 2026-11-05 16:54`nold-a`n## shop-staging run 2026-11-07 09:18`nnew-b`n### Results`nnew-c`n### Evidence index`n| [e1.png](u1) | C1 | x |`n| [e2.png](u2) | C1 | y |`n### Notes`nnew-n`n## docs-staging run 2026-11-06 10:20`nold-d`n## Round 1 — 2026-11-04 19:59`nold-r"
$gcp = pwsh -NoProfile -Command "`$a = [Management.Automation.Language.Parser]::ParseFile('$Q', [ref]`$null, [ref]`$null); iex `$a.Find({ param(`$n) `$n.Name -eq 'Copy-QaGuide' }, `$true).Extent.Text; Copy-QaGuide '$gkept' '$gkept.out'; Copy-QaGuide '$gkept.out' '$gkept.one'; Set-Content '$gkept.none' 'no runs'; Copy-QaGuide '$gkept.none' '$gkept.n2'; (Get-Content '$gkept.out') -join '|'; (Get-Content '$gkept.one') -join '|'; (Get-Content '$gkept.n2') -join '|'"
Expect "guide copy: head + newest run (its ### parts minus the evidence index), older runs and Round sections named; a copy again: the same; no run: whole ($($gcp -join ' // '))" ($gcp[0] -match '^# Testing: X\|## Checks\|\| C1 \| a \|\|## shop-staging run 2026-11-07 09:18\|new-b\|### Results\|new-c\|### Notes\|new-n\|\|> Not copied: older runs \(3\) and the newest run''s evidence index \(2 files\)\. In ' -and $gcp[0] -notmatch 'old-|e1\.png' -and $gcp[1] -eq $gcp[0] -and $gcp[2] -eq 'no runs')
# spawnHidden (2026-11-25: a detached browser server's chrome-headless-shell opened a Windows Terminal window): resolves once
# started, args whole, no console window (no new OpenConsole -Embedding); no PowerShell on PATH -> detached start; a bad exe -> false
$shOut = Join-Path (Kd) 'sh-args.json'; $shKid = Join-Path (Kd) 'sh-kid.mjs'; $shRun = Join-Path (Kd) 'sh-run.mjs'
[IO.File]::WriteAllText($shKid, "import { writeFileSync } from 'node:fs'; import { execFileSync } from 'node:child_process'; try { execFileSync('cmd.exe', ['/c', 'ver']) } catch {}; writeFileSync(process.argv[2], JSON.stringify(process.argv.slice(3))); writeFileSync(process.argv[2] + '.env', JSON.stringify(Object.keys(process.env).filter((k) => k.startsWith('KIT_HID_'))))")
[IO.File]::WriteAllText($shRun, @'
const m = await import(process.argv[2]), [, , , kid, out] = process.argv, { dirname } = await import('node:path')
const bare = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^path$/i.test(k))); bare.PATH = dirname(process.execPath)
const a = await m.spawnHidden(process.execPath, [kid, out, 'a b', 'q"x', '["--x","y z"]', 'end\\', ''])
const b = await m.spawnHidden(process.execPath, [kid, out + '.nops', 'x'], bare)
const c = await m.spawnHidden(process.platform === 'win32' ? 'C:/no/such/tool.exe' : '/no/such/tool', [])
const d = await m.spawnHidden(process.platform === 'win32' ? `${process.env.SystemRoot}/System32/hostname.exe` : '/bin/true', [])
const e = await m.spawnHidden('', [])
console.log(`${a}|${b}|${c}|${d}|${e}`)
'@)
$shEmb = { @(if ($IsWindows) { Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" | Where-Object CommandLine -match 'Embedding' | ForEach-Object ProcessId }) }
$shB = & $shEmb; $shRes = node $shRun ([Uri](Join-Path $src 'skills/pokey/adapters/engine-playwright.mjs')).AbsoluteUri $shKid $shOut 2>&1 | Out-String
for ($shI = 0; $shI -lt 40 -and -not ((Test-Path $shOut) -and (Test-Path "$shOut.nops")); $shI++) { Start-Sleep -Milliseconds 250 }
$shGot = Get-Content $shOut -Raw -ErrorAction SilentlyContinue; $shNew = @(& $shEmb | Where-Object { $_ -notin $shB })
Expect "engine-playwright spawnHidden: resolves true, args whole, no console window; no PowerShell: detached; bad / empty exe: false, no throw; no args ok; KIT_HID_* gone ($($shRes.Trim()); $shGot; handoffs $($shNew.Count))" (
  $shRes.Trim() -eq 'true|true|false|true|false' -and (Get-Content "$shOut.env" -Raw -ErrorAction SilentlyContinue) -eq '[]' -and $shGot -eq '["a b","q\"x","[\"--x\",\"y z\"]","end\\",""]' -and (Get-Content "$shOut.nops" -Raw -ErrorAction SilentlyContinue) -eq '["x"]' -and $shNew.Count -eq 0)
$kbP = Join-Path $src 'skills/bossy/kitbag.py'; $pop = & $py -X utf8 $kbP popups --minutes 0 2>&1 | Out-String; $popBad = & $py -X utf8 $kbP popups --minutes x 2>&1 | Out-String; $popBadC = $LASTEXITCODE
$popK = if ($IsWindows) { "$(& $py -X utf8 $kbP popups --exe (Join-Path $env:SystemRoot 'System32/cmd.exe'))|$(& $py -X utf8 $kbP popups --exe (Join-Path $env:SystemRoot 'System32/notepad.exe'))" } else { 'console|gui' }
Expect "kitbag popups: --minutes 0 a bounded watch; bad --minutes = usage, exit 2; --exe: cmd.exe console, notepad.exe gui ($($pop.Trim()) / $popBadC / $popK)" (
  $pop -match 'popups: (0 window\(s\) in 0 min|Windows only)' -and $popBadC -eq 2 -and $popBad -match 'usage' -and $popK -eq 'console|gui')
Remove-TestKit $k
Complete-Tests
