// engine-playwright.mjs: a module skills/pokey/browser.mjs imports. Usage: through browser.mjs. Exit codes: none (a module).
// browser-engines: browser.engine chromium | firefox | webkit (or KIT_BROWSER_ENGINE) through Playwright, a browser per
// process (KIT_PLAYWRIGHT = module path); puppeteer method names mapped. Imported by browser.mjs session() from adapters/.
// quietProfile: the Local State every kit Chrome profile starts with (browser.mjs sessions, media_grab, kitbag ui-check).
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
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

export async function pwPage(eng, bo, VIEW, quiet = []) {
  let pw; const hint = `npx playwright install ${eng}`
  for (const m of [process.env.KIT_PLAYWRIGHT, 'playwright-core', 'playwright'].filter(Boolean)) pw ||= await import(existsSync(m) ? pathToFileURL(statSync(m).isDirectory() ? join(m, 'index.mjs') : m).href : m).then((x) => x[eng] || x.default?.[eng], () => null)
  if (!pw) throw new Error(`browser.engine ${eng}: npm i playwright-core in skills/pokey (or KIT_PLAYWRIGHT=<module>), then ${hint}`)
  const browser = await pw.launch({ headless: true, args: eng === 'chromium' ? quiet : [] }).catch((e) => { throw new Error(`browser.engine ${eng}: ${String(e.message).split('\n')[0]} - ${hint}`) })
  const ctx = await browser.newContext({ viewport: VIEW, locale: bo.lang, timezoneId: bo.timezone || undefined })
  const page = await ctx.newPage(), go0 = page.goto.bind(page), wn = page.waitForNavigation.bind(page)
  const wu = (o = {}) => ({ ...o, waitUntil: o.waitUntil === 'networkidle2' ? 'networkidle' : o.waitUntil })
  Object.assign(page, { __pw: true, goto: (u, o) => go0(u, wu(o)), waitForNavigation: (o) => wn(wu(o)),
    waitForNetworkIdle: (o = {}) => page.waitForLoadState('networkidle', { timeout: o.timeout }),
    cookies: () => ctx.cookies(), setCookie: (...c) => ctx.addCookies(c) })
  return { browser, page }
}
