// engine-playwright.mjs: a module skills/pokey/browser.mjs imports. Usage: through browser.mjs. Exit codes: none (a module).
// browser-engines: browser.engine chromium | firefox | webkit (or KIT_BROWSER_ENGINE) through Playwright, a browser server per
// login reused across calls (KIT_PLAYWRIGHT = module path; KIT_PW_IDLE_MS = server idle exit); puppeteer method names mapped. Imported by browser.mjs session() from adapters/.
// quietProfile: the Local State every kit Chrome profile starts with (browser.mjs sessions, media-grab, kitbag ui-check).
// spawnHidden: a background process with no console window (browser.mjs Chrome, the browser server).
// Sections: L13 profile · L24 engine · L46 server
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// ---- profile: the quiet Chrome Local State
const readJson = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return {} } }
// Chrome 157 fetches prediction models despite the quiet flags; the Local State pref of policy ComponentUpdatesEnabled stops it (no admin)
export function quietProfile(dir) {
  const seed = readJson(join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'crafty', 'vocab.json')).chromeLocalState || {}
  mkdirSync(dir, { recursive: true }); const f = join(dir, 'Local State'), st = readJson(f), was = JSON.stringify(st)
  for (const [k, v] of Object.entries(seed)) st[k] = { ...st[k], ...v }
  if (JSON.stringify(st) !== was) writeFileSync(f, JSON.stringify(st))
  return dir
}

// ---- engine: the Playwright module and a page with puppeteer names
async function pwType(eng) {
  let pw
  for (const m of [process.env.KIT_PLAYWRIGHT, 'playwright-core', 'playwright'].filter(Boolean)) pw ||= await import(existsSync(m) ? pathToFileURL(statSync(m).isDirectory() ? join(m, 'index.mjs') : m).href : m).then((x) => x[eng] || x.default?.[eng], () => null)
  if (!pw) throw new Error(`browser.engine ${eng}: npm i playwright-core in skills/pokey (or KIT_PLAYWRIGHT=<module>), then npx playwright install ${eng}`)
  return pw
}
// ws: a browser server's endpoint to connect to (pwServed), else a browser of its own
export async function pwPage(eng, bo, VIEW, quiet = [], ws = '') {
  const pw = await pwType(eng), hint = `npx playwright install ${eng}`
  const browser = await (ws ? pw.connect(ws) : pw.launch({ headless: true, args: eng === 'chromium' ? quiet : [] })).catch((e) => { throw new Error(`browser.engine ${eng}: ${String(e.message).split('\n')[0]} - ${hint}`) })
  const ctx = await browser.newContext({ viewport: VIEW, locale: bo.lang, timezoneId: bo.timezone || undefined })
  return { browser, page: wrapPage(ctx, await ctx.newPage()) }
}
// a context's page with the puppeteer method names browser.mjs calls (the matrix: a context per variant)
export function wrapPage(ctx, page) {
  const go0 = page.goto.bind(page), wn = page.waitForNavigation.bind(page)
  const wu = (o = {}) => ({ ...o, waitUntil: o.waitUntil === 'networkidle2' ? 'networkidle' : o.waitUntil })
  return Object.assign(page, { __pw: true, goto: (u, o) => go0(u, wu(o)), waitForNavigation: (o) => wn(wu(o)),
    waitForNetworkIdle: (o = {}) => page.waitForLoadState('networkidle', { timeout: o.timeout }),
    cookies: () => ctx.cookies(), setCookie: (...c) => ctx.addCookies(c), viewport: () => page.viewportSize(), setViewport: (v) => page.setViewportSize({ width: v.width, height: v.height }) })
}
// ---- server: hidden background processes, one browser server per login
// reuse: one Playwright browser server per login key and port (a detached `node engine-playwright.mjs serve`), each call connects
// with a fresh context (the saved login restores it); the server exits after KIT_PW_IDLE_MS (30 min) without a client touching
// <used>, within 5 s once <used> is gone (browser.mjs killSession). Its ws path is a random token per server (pw-<port>.token, owner-only),
// never a fixed path another local process could guess (0600 on Unix; on Windows the user's kit runtime folder guards it).
// a background process that outlives its caller. Windows: a detached child has no console, so each console grandchild
// (chrome-headless-shell) opened a Windows Terminal window (2026-11-25); Start-Process -WindowStyle Hidden gives one to inherit.
// The launcher pwsh dies with its caller (a detached pwsh never runs): callers poll until the child answers (pwServed, browser.mjs).
const winArg = (a) => /[\s"]/.test(a) || !a ? `"${a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1')}"` : a
export function spawnHidden(exe, argv, env = process.env) {
  if (process.platform !== 'win32') return spawn(exe, argv, { detached: true, stdio: 'ignore', env }).unref()
  spawn('pwsh', ['-NoProfile', '-NonInteractive', '-Command', 'Start-Process -FilePath $env:KIT_HID_EXE -ArgumentList $env:KIT_HID_ARGS -WindowStyle Hidden'],
    { stdio: 'ignore', windowsHide: true, env: { ...env, KIT_HID_EXE: exe, KIT_HID_ARGS: argv.map(winArg).join(' ') } }).unref()
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const touch = (f) => { try { writeFileSync(f, String(Date.now())) } catch {} }
const readTok = (f) => { try { return readFileSync(f, 'utf8').trim() } catch { return '' } }
export async function pwServed(eng, bo, VIEW, quiet, port, dir) {
  const used = join(dir, `pw-${port}.used`), tokF = join(dir, `pw-${port}.token`), go = (t) => t ? pwPage(eng, bo, VIEW, quiet, `ws://127.0.0.1:${port}/${t}`).catch(() => null) : null
  let s = await go(readTok(tokF)), err = ''
  if (!s) {
    await pwType(eng); touch(used); try { unlinkSync(used + '.err') } catch {}   // no Playwright module: its hint now
    const tok = randomBytes(24).toString('hex')   // env, not argv: the process list shows argv
    spawnHidden(process.execPath, [fileURLToPath(import.meta.url), 'serve', eng, String(port), used, JSON.stringify(eng === 'chromium' ? quiet : [])], { ...process.env, KIT_PW_TOKEN: tok })
    // a racing caller's server may win the port: its token file then names the live one
    for (let i = 0; i < 60 && !s && !err; i++) { await sleep(500); const t2 = readTok(tokF); s = await go(tok) || (t2 && t2 !== tok ? await go(t2) : null); try { err = readFileSync(used + '.err', 'utf8') } catch {} }
    // an older server on a fixed path holds the port: <used> gone, it exits within a minute
    if (!s) { try { unlinkSync(used) } catch {}; throw new Error(err || `browser.engine ${eng}: no browser server came up on port ${port} (an older server there exits within a minute: retry)`) }
  }
  touch(used); setInterval(() => touch(used), 60000).unref()
  return s
}
if (process.argv[2] === 'serve' && resolve(process.argv[1] || '') === fileURLToPath(import.meta.url)) {
  const [, , , eng, port, used, args] = process.argv, tok = process.env.KIT_PW_TOKEN || randomBytes(24).toString('hex'), tokF = used.replace(/\.used$/, '.token')
  const idle = Number(process.env.KIT_PW_IDLE_MS) || 30 * 60000
  // the failure (no browser installed: the install hint) goes to <used>.err for the waiting client
  const srv = await pwType(eng).then((pw) => pw.launchServer({ headless: true, host: '127.0.0.1', port: Number(port), wsPath: `/${tok}`, args: JSON.parse(args || '[]') }))
    .catch((e) => { if (!/EADDRINUSE/.test(e.message)) writeFileSync(used + '.err', `browser.engine ${eng}: ${String(e.message).split('\n')[0]} - npx playwright install ${eng}`); process.exit(1) })   // port taken: another caller's server won
  writeFileSync(tokF, tok, { mode: 0o600 })
  const end = async () => { await srv.close().catch(() => {}); if (readTok(tokF) === tok) rmSync(tokF, { force: true }); process.exit(0) }
  setInterval(() => { let at = 0; try { at = statSync(used).mtimeMs } catch {}; if (Date.now() - at > idle) end() }, Math.min(5000, idle))
}
// registry (parity.json browser-engine; browser.mjs session() picks by browser.engine; context: the matrix): chrome = a CDP session per login, reused
// across calls (browser.mjs); the Playwright engines a browser server per login, reused across calls (pwServed)
export const ADAPTERS = { 'browser-engine': {} }
ADAPTERS['browser-engine']['chrome'] = { session: true, reuse: true, context: true }
ADAPTERS['browser-engine']['chromium'] = { session: pwPage, reuse: pwServed, context: wrapPage }
ADAPTERS['browser-engine']['firefox'] = { session: pwPage, reuse: pwServed, context: wrapPage }
ADAPTERS['browser-engine']['webkit'] = { session: pwPage, reuse: pwServed, context: wrapPage }
export const engine = (eng) => ADAPTERS['browser-engine'][eng] || (() => { throw new Error(`browser.engine ${eng}: unknown (${Object.keys(ADAPTERS['browser-engine']).join(' | ')})`) })()
