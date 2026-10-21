// browser-engines (extra): browser.engine chromium | firefox | webkit (or KIT_BROWSER_ENGINE) through Playwright, a browser per
// process (KIT_PLAYWRIGHT = module path); puppeteer method names mapped. Imported by browser.mjs session() from adapters/.
import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

export async function pwPage(eng, bo, VIEW) {
  let pw; const hint = `npx playwright install ${eng}`
  for (const m of [process.env.KIT_PLAYWRIGHT, 'playwright-core', 'playwright'].filter(Boolean)) pw ||= await import(existsSync(m) ? pathToFileURL(statSync(m).isDirectory() ? join(m, 'index.mjs') : m).href : m).then((x) => x[eng] || x.default?.[eng], () => null)
  if (!pw) throw new Error(`browser.engine ${eng}: npm i playwright-core in skills/qa-kit (or KIT_PLAYWRIGHT=<module>), then ${hint}`)
  const browser = await pw.launch({ headless: true }).catch((e) => { throw new Error(`browser.engine ${eng}: ${String(e.message).split('\n')[0]} - ${hint}`) })
  const ctx = await browser.newContext({ viewport: VIEW, locale: bo.lang, timezoneId: bo.timezone || undefined })
  const page = await ctx.newPage(), go0 = page.goto.bind(page), wn = page.waitForNavigation.bind(page)
  const wu = (o = {}) => ({ ...o, waitUntil: o.waitUntil === 'networkidle2' ? 'networkidle' : o.waitUntil })
  Object.assign(page, { __pw: true, goto: (u, o) => go0(u, wu(o)), waitForNavigation: (o) => wn(wu(o)),
    waitForNetworkIdle: (o = {}) => page.waitForLoadState('networkidle', { timeout: o.timeout }),
    cookies: () => ctx.cookies(), setCookie: (...c) => ctx.addCookies(c) })
  return { browser, page }
}