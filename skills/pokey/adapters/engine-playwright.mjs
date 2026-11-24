// engine-playwright.mjs: a module skills/pokey/browser.mjs imports. Usage: through browser.mjs. Exit codes: none (a module).
// browser-engines: browser.engine chromium | firefox | webkit (or KIT_BROWSER_ENGINE) through Playwright, a browser server per
// login reused across calls (KIT_PLAYWRIGHT = module path); puppeteer method names mapped. Imported by browser.mjs session() from adapters/.
// quietProfile: the Local State every kit Chrome profile starts with (browser.mjs sessions, media-grab, kitbag ui-check).
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const readJson = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return {} } }
// Chrome 157 fetches prediction models despite the quiet flags; the Local State pref of policy ComponentUpdatesEnabled stops it (no admin)
export function quietProfile(dir) {
  const seed = readJson(join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'crafty', 'vocab.json')).chromeLocalState || {}
  mkdirSync(dir, { recursive: true }); const f = join(dir, 'Local State'), st = readJson(f), was = JSON.stringify(st)
  for (const [k, v] of Object.entries(seed)) st[k] = { ...st[k], ...v }
  if (JSON.stringify(st) !== was) writeFileSync(f, JSON.stringify(st))
  return dir
}

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
  const page = await ctx.newPage(), go0 = page.goto.bind(page), wn = page.waitForNavigation.bind(page)
  const wu = (o = {}) => ({ ...o, waitUntil: o.waitUntil === 'networkidle2' ? 'networkidle' : o.waitUntil })
  Object.assign(page, { __pw: true, goto: (u, o) => go0(u, wu(o)), waitForNavigation: (o) => wn(wu(o)),
    waitForNetworkIdle: (o = {}) => page.waitForLoadState('networkidle', { timeout: o.timeout }),
    cookies: () => ctx.cookies(), setCookie: (...c) => ctx.addCookies(c) })
  return { browser, page }
}
// reuse: one Playwright browser server per login key and port (a detached `node engine-playwright.mjs serve`), each call connects
// with a fresh context (the saved login restores it); the server exits after SERVE_IDLE_MIN without a client touching <used>
const SERVE_IDLE_MIN = 30, sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const touch = (f) => { try { writeFileSync(f, String(Date.now())) } catch {} }
export async function pwServed(eng, bo, VIEW, quiet, port, dir) {
  const ws = `ws://127.0.0.1:${port}/kit`, used = join(dir, `pw-${port}.used`), go = () => pwPage(eng, bo, VIEW, quiet, ws)
  let s = await go().catch(() => null), err = ''
  if (!s) {
    await pwType(eng); touch(used); try { unlinkSync(used + '.err') } catch {}   // no Playwright module: its hint now
    spawn(process.execPath, [fileURLToPath(import.meta.url), 'serve', eng, String(port), used, JSON.stringify(eng === 'chromium' ? quiet : [])], { detached: true, stdio: 'ignore', windowsHide: true, env: process.env }).unref()
    for (let i = 0; i < 60 && !s && !err; i++) { await sleep(500); s = await go().catch(() => null); try { err = readFileSync(used + '.err', 'utf8') } catch {} }
    if (!s) throw new Error(err || `browser.engine ${eng}: no browser server came up on port ${port}`)
  }
  touch(used); setInterval(() => touch(used), 60000).unref()
  return s
}
if (process.argv[2] === 'serve' && resolve(process.argv[1] || '') === fileURLToPath(import.meta.url)) {
  const [, , , eng, port, used, args] = process.argv
  // the failure (no browser installed: the install hint) goes to <used>.err for the waiting client
  const srv = await pwType(eng).then((pw) => pw.launchServer({ headless: true, host: '127.0.0.1', port: Number(port), wsPath: '/kit', args: JSON.parse(args || '[]') }))
    .catch((e) => { if (!/EADDRINUSE/.test(e.message)) writeFileSync(used + '.err', `browser.engine ${eng}: ${String(e.message).split('\n')[0]} - npx playwright install ${eng}`); process.exit(1) })   // port taken: another caller's server won
  setInterval(async () => { let at = 0; try { at = statSync(used).mtimeMs } catch {}; if (Date.now() - at > SERVE_IDLE_MIN * 60000) { await srv.close().catch(() => {}); process.exit(0) } }, 60000)
}
// registry (parity.json browser-engine; browser.mjs session() picks by browser.engine): chrome = a CDP session per login, reused
// across calls (browser.mjs); the Playwright engines a browser server per login, reused across calls (pwServed)
export const ADAPTERS = { 'browser-engine': {} }
ADAPTERS['browser-engine']['chrome'] = { session: true, reuse: true }
ADAPTERS['browser-engine']['chromium'] = { session: pwPage, reuse: pwServed }
ADAPTERS['browser-engine']['firefox'] = { session: pwPage, reuse: pwServed }
ADAPTERS['browser-engine']['webkit'] = { session: pwPage, reuse: pwServed }
export const engine = (eng) => ADAPTERS['browser-engine'][eng] || (() => { throw new Error(`browser.engine ${eng}: unknown (${Object.keys(ADAPTERS['browser-engine']).join(' | ')})`) })()
