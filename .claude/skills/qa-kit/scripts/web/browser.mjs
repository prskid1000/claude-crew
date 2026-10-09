// Headless-browser helper for testing any web app. Targets (URL, login form, users) come from
// <workspace>/.claude/skills/qa-kit/targets.local.json — nothing app-specific lives here.
//
// FAST PATH: session() keeps ONE logged-in headless Chrome alive per port, so each script reconnects in ~1 s
// instead of relaunching and logging in again.
//
//   import { session, go, text, clickText, clickSel, hoverSel, setInput, shot, token, killSession } from 'file:///<workspace>/.claude/skills/qa-kit/scripts/web/browser.mjs'   // the absolute file URL of this file (Windows: file:///C:/...)
//   const s = await session({ port: 9401, target: 'my-staging', tenant: 'acme', as: 'admin' })  // one port per target+tenant+user
//   await go(s.page, '/projects')
//   console.log((await text(s.page)).slice(0, 2000))
//   await clickText(s.page, 'Filter')
//   await setInput(s.page, 'input[placeholder="Select date"]', '29/09/2026 13:45')   // inputs & date pickers: type + Enter
//   await mark(s.page, '.ant-table-row:first-child')                  // red outline on what matters (removed after the shot)
//   await shot(s.page, '<run>/F2/shots/F2-T3_01_filter-applied.jpeg')   // names: <CODE>-<check>_<nn>_<what> (evidence-standard.md)
//   console.log(JSON.stringify(s.net.failed))     // 4xx/5xx API calls + JS errors seen in THIS script = failure evidence
//   if (s.net.failed.length) saveNet(s, '<run>/F2/evidence/F2-T3_02_failed-calls.json')
// A login made on one port is saved (8 h) and reused by other ports/agents for the same target+tenant+user.
//   await s.done()                                // disconnect; Chrome stays alive for the next script
//   // completely finished: await killSession(9401)
//
// Every wait is capped at 20 s, so a wrong selector fails fast instead of hanging.
// Real mouse clicks are used throughout: Angular/React/ng-zorro/MUI controls often ignore synthetic el.click().
// Run scripts with: node <file>.mjs (on Windows from PowerShell: node is on its PATH, not git-bash's). Linux/macOS: Chrome, Edge or
// Chromium is found in the usual install folders or on PATH; set CHROME_PATH to pick another one.
import puppeteer from 'puppeteer-core'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, delimiter, dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'

const CFG = JSON.parse(readFileSync(new globalThis.URL('../../targets.local.json', import.meta.url), 'utf8'))
// runtime output lives outside .claude: <parent of .claude>\.claude-runtime
const RUNTIME = process.env.CLAUDE_RUNTIME || fileURLToPath(import.meta.url).replace(/[\\/]\.claude[\\/].*$/, '') + '/.claude-runtime'
const PROFILES = `${RUNTIME}/chrome-profiles`
// Chrome/Edge/Chromium: $CHROME_PATH first, then the usual install folders per OS, then the PATH (Linux package names)
const onPath = (names) => (process.env.PATH || '').split(delimiter).filter(Boolean).flatMap((d) => names.map((n) => join(d, n)))
const BROWSERS = [
  process.env.CHROME_PATH,
  ...(process.platform === 'win32' ? [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  ] : process.platform === 'darwin' ? [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    `${homedir()}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ] : [
    '/opt/google/chrome/chrome',
    '/opt/microsoft/msedge/msedge',
    ...onPath(['google-chrome', 'google-chrome-stable', 'microsoft-edge', 'microsoft-edge-stable', 'chromium', 'chromium-browser']),
    '/snap/bin/chromium',
  ]),
].filter(Boolean)
const CHROME = BROWSERS.find((p) => existsSync(p))
const VIEW = { width: 1600, height: 1000 }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export function targetOf(name) {
  const t = CFG.targets[name || CFG.default]
  if (!t) throw new Error(`unknown target "${name}" (known: ${Object.keys(CFG.targets).join(', ')})`)
  return t
}
let BASE = ''   // web base URL of the last session(); go() paths are relative to it
export const url = (p) => (/^https?:/.test(p) ? p : BASE + p)

function watch(page, apiPattern) {
  const net = { failed: [], calls: [] }
  page.on('response', async (r) => {
    const u = r.url()
    if (apiPattern && !u.includes(apiPattern)) return
    if (!apiPattern && !['xhr', 'fetch'].includes(r.request().resourceType())) return
    const e = { status: r.status(), method: r.request().method(), url: u }
    net.calls.push(e)
    if (r.status() >= 400) {
      try { e.body = (await r.text()).slice(0, 600) } catch {}
      net.failed.push(e)
    }
  })
  page.on('pageerror', (err) => net.failed.push({ status: 'JS', url: page.url(), body: String(err).slice(0, 400) }))
  page.on('dialog', (d) => d.accept().catch(() => {}))
  return net
}

const fill = (s, user, pass, tenant) => String(s).replaceAll('{user}', user).replaceAll('{pass}', pass).replaceAll('{tenant}', tenant || '')

async function login(page, t, tenant, as) {
  const L = t.webLogin
  const [user, pass] = t.users[as] || []
  if (!user) throw new Error(`no user "${as}" in this target`)
  await page.goto(t.web + L.path, { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  if (!page.url().includes(L.path)) {   // already logged in as someone else: clear and retry
    await page.evaluate(() => { sessionStorage.clear(); localStorage.clear() })
    await page.goto(t.web + L.path, { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  }
  const sels = Object.keys(L.fields)
  await page.waitForSelector(sels[0], { timeout: 60000 })
  for (const sel of sels) {
    const v = fill(L.fields[sel], user, pass, tenant)
    if (v) { await page.click(sel, { clickCount: 3 }).catch(() => {}); await page.type(sel, v) }
  }
  if (L.rememberMeLabel) {
    await page.evaluate((lbl) => {
      const lab = [...document.querySelectorAll('label')].find((e) => (e.innerText || '').trim().toLowerCase() === lbl.toLowerCase() && e.querySelector('input[type=checkbox]'))
      const cb = lab && lab.querySelector('input[type=checkbox]')
      if (cb && !cb.checked) cb.click()
    }, L.rememberMeLabel)
  }
  await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {}), page.click(L.submit)])
  await settle(page)
  if (page.url().includes(L.path)) throw new Error('login failed: ' + (await text(page)).slice(0, 300))
  await page.evaluate((m) => localStorage.setItem('qa-session', m), `${tenant}/${as}`)
  // share this login with every other port/agent: save the web storage (token lives there) for 8 h
  try {
    const st = await page.evaluate(() => ({ local: { ...localStorage }, session: { ...sessionStorage } }))
    mkdirSync(`${RUNTIME}/sessions`, { recursive: true })
    writeFileSync(sessionFile(t, tenant, as), JSON.stringify({ at: Date.now(), ...st }))
  } catch {}
}

const sessionFile = (t, tenant, as) => `${RUNTIME}/sessions/${(t.web + '-' + tenant + '-' + as).replace(/[^\w.-]/g, '_')}.json`

// Reuse a login saved by another port (≈1 s instead of a full login). Returns true when the app accepted it.
async function restoreLogin(page, t, tenant, as) {
  const f = sessionFile(t, tenant, as)
  if (!existsSync(f)) return false
  const s = JSON.parse(readFileSync(f, 'utf8'))
  if (Date.now() - s.at > 8 * 3600 * 1000) return false
  await page.goto(t.web + t.webLogin.path, { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
  await page.evaluate((s) => {
    for (const [k, v] of Object.entries(s.local || {})) localStorage.setItem(k, v)
    for (const [k, v] of Object.entries(s.session || {})) sessionStorage.setItem(k, v)
  }, s)
  await page.goto(t.web + '/', { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
  await sleep(1500)   // let the app's auth guard redirect if the token is no longer valid
  const tok = (t.webLogin.tokenKeys || []).length ? await token(page, t) : 'n/a'
  return !!tok && !page.url().includes(t.webLogin.path)
}

// Connect to (or start) the long-lived headless Chrome on `port`, logged in as target/tenant/as.
export async function session({ port, target, tenant, as = 'admin' } = {}) {
  if (!port) throw new Error('session(): pass a port (one per target+tenant+user)')
  if (!CHROME) throw new Error('no Chrome/Edge found; set CHROME_PATH')
  const t = targetOf(target)
  tenant = tenant ?? t.defaultTenant ?? ''
  BASE = t.web
  let browser
  try {
    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: VIEW })
  } catch {
    const dir = `${PROFILES}/${port}`
    mkdirSync(dir, { recursive: true })
    const child = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, '--window-size=1600,1000', '--lang=en-GB', '--no-first-run', '--no-default-browser-check', 'about:blank'], { detached: true, stdio: 'ignore' })
    child.unref()
    for (let i = 0; i < 40 && !browser; i++) {
      await sleep(500)
      try { browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: VIEW }) } catch {}
    }
    if (!browser) throw new Error(`could not start Chrome on port ${port}`)
  }
  // Undecided notification permission makes many apps show a toast that swallows header clicks: grant it.
  try { await browser.defaultBrowserContext().overridePermissions(t.web, ['notifications', 'geolocation', 'clipboard-read', 'clipboard-write']) } catch {}
  const pages = (await browser.pages()).filter((p) => !p.url().startsWith('devtools'))
  const page = pages[0] || (await browser.newPage())
  await page.setViewport(VIEW)
  page.setDefaultTimeout(20000)
  page.setDefaultNavigationTimeout(90000)
  const net = watch(page, t.apiPattern)
  if (t.webLogin) {
    const who = await page.evaluate(() => localStorage.getItem('qa-session')).catch(() => null)
    const tok = await token(page, t).catch(() => null)
    const needTok = (t.webLogin.tokenKeys || []).length > 0
    if (!page.url().startsWith(t.web) || page.url().includes(t.webLogin.path) || (needTok && !tok) || who !== `${tenant}/${as}`) {
      const reused = who === null && (await restoreLogin(page, t, tenant, as).catch(() => false))
      if (reused) await page.evaluate((m) => localStorage.setItem('qa-session', m), `${tenant}/${as}`)
      else await login(page, t, tenant, as)
    }
  }
  return { browser, page, net, target: t, done: async () => { try { browser.disconnect() } catch {} } }
}

export async function killSession(port) {
  try { const b = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}` }); await b.close() } catch {}
}

// wait for XHR to go quiet
export async function settle(page, ms = 1200) {
  try { await page.waitForNetworkIdle({ idleTime: 700, timeout: 20000 }) } catch {}
  await sleep(ms)
}

export async function go(page, path) {
  await page.goto(url(path), { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  await settle(page)
}

// visible text of the page (or of a selector)
export async function text(page, selector = 'body') {
  return page.$eval(selector, (el) => el.innerText).catch(() => '')
}

// Real mouse click on the innermost visible element whose text / title / aria-label matches (exact first, then contains).
export async function clickText(page, label, { nth = 0, within = 'body', exact = false, right = false } = {}) {
  const box = await page.evaluate(({ label, nth, within, exact }) => {
    const root = document.querySelector(within) || document.body
    const vis = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' }
    const all = [...root.querySelectorAll('*')].filter(vis)
    const norm = (s) => (s || '').replace(/\s+/g, ' ').trim()
    const own = (el) => norm(el.innerText || el.getAttribute('title') || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '')
    let hits = all.filter((el) => own(el) === label)
    if (!hits.length && !exact) hits = all.filter((el) => own(el).includes(label))
    hits = hits.filter((el) => !hits.some((o) => o !== el && el.contains(o)))
    const el = hits[nth]
    if (!el) return null
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, n: hits.length }
  }, { label, nth, within, exact })
  if (!box) throw new Error(`clickText: "${label}" not found`)
  await page.mouse.click(box.x, box.y, { button: right ? 'right' : 'left' })
  await settle(page, 700)
  return box
}

export async function clickSel(page, selector, { right = false, nth = 0 } = {}) {
  await page.waitForSelector(selector, { visible: true, timeout: 20000 })
  const el = (await page.$$(selector))[nth]
  await el.scrollIntoView()
  const b = await el.boundingBox()
  await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2, { button: right ? 'right' : 'left' })
  await settle(page, 700)
}

// Hover-triggered menus: move the pointer in from outside, in steps, so mouseenter fires.
export async function hoverSel(page, selector, { nth = 0 } = {}) {
  await page.waitForSelector(selector, { visible: true, timeout: 20000 })
  const el = (await page.$$(selector))[nth]
  await el.scrollIntoView()
  const b = await el.boundingBox()
  await page.mouse.move(b.x - 40, b.y - 40)
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 12 })
  await sleep(900)
}

// Replace an input's value (text, number, date/time pickers): click, select all, type, Enter.
export async function setInput(page, selector, value, { nth = 0, enter = true } = {}) {
  await page.waitForSelector(selector, { visible: true, timeout: 20000 })
  const el = (await page.$$(selector))[nth]
  await el.scrollIntoView()
  await el.click({ clickCount: 3 })
  await page.keyboard.down('Control'); await page.keyboard.press('KeyA'); await page.keyboard.up('Control')
  await page.keyboard.press('Backspace')
  await el.type(String(value), { delay: 20 })
  if (enter) await page.keyboard.press('Enter')
  await settle(page, 500)
  return page.evaluate((e) => e.value, el)
}

// Evidence names: <CODE>-<checkId>[_verify]_<nn>_<what>.<ext>  (see qa-kit\reference\evidence-standard.md)
const EVIDENCE_NAME = /^[A-Za-z0-9]+-[A-Za-z]*\d+(_verify)?_\d{2}_[a-z0-9]+(-[a-z0-9]+)*\.(jpe?g|png|json|log|mp4)$/
function checkName(file) {
  if (!EVIDENCE_NAME.test(basename(file))) console.warn(`[evidence] "${basename(file)}" does not follow <CODE>-<check>_<nn>_<what>.<ext> (e.g. F2-T4_01_order-saved.jpeg)`)
}

// Red outline around the element(s) that matter, for the next screenshot. Removed by unmark() or shot().
export async function mark(page, selector, { nth = null } = {}) {
  await page.evaluate(({ selector, nth }) => {
    const els = [...document.querySelectorAll(selector)]
    for (const [i, el] of els.entries()) {
      if (nth !== null && i !== nth) continue
      el.dataset.qaMark = el.style.outline || ' '
      el.style.outline = '3px solid #e11d48'; el.style.outlineOffset = '2px'
    }
  }, { selector, nth })
}
export async function unmark(page) {
  await page.evaluate(() => document.querySelectorAll('[data-qa-mark]').forEach((el) => { el.style.outline = el.dataset.qaMark.trim(); el.style.outlineOffset = ''; delete el.dataset.qaMark })).catch(() => {})
}

// Save network evidence (default: the failed calls seen in this script) in the standard envelope.
export function saveNet(s, file, { calls = null, meta = {} } = {}) {
  checkName(file)
  const m = basename(file).match(/^([A-Za-z0-9]+)-([A-Za-z]*\d+)/) || []
  const out = {
    meta: { code: m[1] || '', check: m[2] || '', target: s.target.web, at: new Date().toISOString(), tool: 'browser.mjs', ...meta },
    calls: (calls || s.net.failed).map((c) => ({ request: { method: c.method || '', url: c.url }, response: { status: c.status, body: c.body || '' } })),
  }
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, JSON.stringify(out, null, 2))
  return file
}

export async function shot(page, file, { full = false, selector = null } = {}) {
  checkName(file)
  mkdirSync(dirname(file), { recursive: true })
  const png = file.endsWith('.png')
  const opts = { path: file, type: png ? 'png' : 'jpeg', ...(png ? {} : { quality: 80 }) }
  try {
    if (selector) { const el = await page.$(selector); if (el) { await el.screenshot(opts); return file } }
    await page.screenshot({ ...opts, fullPage: full })
  } finally { await unmark(page) }
  return file
}

// Bearer token of the logged-in UI session (to call the API as the same user). Looks in the target's tokenKeys.
export async function token(page, t = null) {
  const keys = ((t || {}).webLogin || {}).tokenKeys || Object.values(CFG.targets).flatMap((x) => (x.webLogin || {}).tokenKeys || [])
  return page.evaluate((keys) => { for (const k of keys) { const v = sessionStorage.getItem(k) || localStorage.getItem(k); if (v) return v } return null }, keys)
}
