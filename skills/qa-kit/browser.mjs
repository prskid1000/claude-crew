// browser.mjs: headless-browser library for testing any web app (import it; usage below). Exit codes: none (a library).
// targets.local.json: web, webLogin, users, browser.engine (or KIT_BROWSER_ENGINE): chrome (default, puppeteer: one shared
// Chrome per target+tenant+user, a tab each) | chromium | firefox | webkit (Playwright, a browser per process; KIT_PLAYWRIGHT
// = module path). Logins shared via the session file (web storage + cookies), locked; never log out.
// webLogin.type: form (path, fields, submit) | sso-steps (steps: goto, fill {sel: val}, click, wait sel|ms, waitUrl) |
// script (.mjs: default async ({ page, user, pass, tenant, target, totp })) | storageState (file: cookies, origins).
// {user} {pass} {tenant} {totp} (users: [user, pass, totpSecret]); {tenant} also in web.
//   import { session, go, clickText, shot, saveNet, relogin, ... } from 'file:///<kit>/skills/qa-kit/browser.mjs'
//   const s = await session({ target, tenant, as }); await go(s.page, '/x'); await shot(s.page, '<run>/F2/shots/F2-T3_01_x.jpeg')
//   s.net.failed (4xx/5xx, JS errors) -> saveNet(s, file); 401 -> relogin(s); s.done(). Waits cap at 20 s; real clicks.
import puppeteer from 'puppeteer-core'
import { spawn } from 'node:child_process'
import { createHmac } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, delimiter, dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { homedir } from 'node:os'

const TF = new globalThis.URL('./targets.local.json', import.meta.url)
const CFG = existsSync(TF) ? JSON.parse(readFileSync(TF, 'utf8')) : { targets: {} }
const __HERE = dirname(fileURLToPath(import.meta.url))
export const KIT = resolve(__HERE, '..', '..')
const MAP = JSON.parse(readFileSync(join(__HERE, '..', 'dev-kit', 'kit.example.json'), 'utf8'))._paths
export const runtimeDir = () => process.env.CLAUDE_RUNTIME || join(KIT, MAP.runtimeDir)
export function kitPath(name, { create = false } = {}) {
  const [rel, base] = name === 'runtime' ? ['/', runtimeDir()] : name in MAP.runtime ? [MAP.runtime[name], runtimeDir()] : name in MAP.durable ? [MAP.durable[name], join(KIT, MAP.stateDir)] : []
  if (!rel) throw new Error(`kitPath: unknown name '${name}' (kit.example.json _paths)`)
  const p = rel === '/' ? base : join(base, rel.replace(/\/$/, ''))
  if (create) mkdirSync(rel.endsWith('/') ? p : dirname(p), { recursive: true })
  return p
}
const PROFILES = kitPath('chrome-profiles')
const onPath = (names) => (process.env.PATH || '').split(delimiter).filter(Boolean).flatMap((d) => names.map((n) => join(d, n)))
const PF = ['C:/Program Files', 'C:/Program Files (x86)'], MAC = (a) => `/Applications/${a}.app/Contents/MacOS/${a}`
const BROWSERS = [process.env.CHROME_PATH, ...(process.platform === 'win32' ? [...PF.map((d) => `${d}/Google/Chrome/Application/chrome.exe`), ...PF.map((d) => `${d}/Microsoft/Edge/Application/msedge.exe`)]
  : process.platform === 'darwin' ? [MAC('Google Chrome'), homedir() + MAC('Google Chrome'), MAC('Microsoft Edge'), MAC('Chromium')]
  : ['/opt/google/chrome/chrome', '/opt/microsoft/msedge/msedge', ...onPath(['google-chrome', 'google-chrome-stable', 'microsoft-edge', 'microsoft-edge-stable', 'chromium', 'chromium-browser']), '/snap/bin/chromium'])].filter(Boolean)
const CHROME = BROWSERS.find(existsSync)
const browserOpts = (t) => ({ engine: 'chrome', lang: Intl.DateTimeFormat().resolvedOptions().locale, width: 1600, height: 1000, ...(CFG.browser || {}), ...((t && t.browser) || {}) })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export const targetOf = (name) => CFG.targets[name || CFG.default] || (() => { throw new Error(`unknown target "${name}" (known: ${Object.keys(CFG.targets).join(', ')})`) })()
let BASE = ''   // go()'s relative paths
export const url = (p) => (/^https?:/.test(p) ? p : BASE + p)

function watch(page, apiPattern) {
  const net = { failed: [], calls: [], jsErrors: 0 }
  page.on('response', async (r) => {
    const u = r.url(), e = { status: r.status(), method: r.request().method(), url: u }
    if (apiPattern ? !u.includes(apiPattern) : !['xhr', 'fetch'].includes(r.request().resourceType())) return
    net.calls.push(e)
    if (r.status() >= 400) net.failed.push(Object.assign(e, { body: (await r.text().catch(() => '')).slice(0, 600) }))
  })
  page.on('pageerror', (err) => { if (++net.jsErrors <= 50) net.failed.push({ status: 'JS', url: page.url(), body: String(err).slice(0, 400) }) })
  page.on('dialog', (d) => d.accept().catch(() => {}))
  return net
}

// RFC 6238 (30 s, 6 digits)
export function totp(secret, at = Date.now()) {
  const bits = String(secret).toUpperCase().replace(/[^A-Z2-7]/g, '').split('').map((c) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5, '0')).join('')
  const c = Buffer.alloc(8), h = (c.writeBigUInt64BE(BigInt(Math.floor(at / 30000))), createHmac('sha1', Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)))).update(c).digest())
  return String((h.readUInt32BE(h[19] & 15) & 0x7fffffff) % 1e6).padStart(6, '0')
}
const fill = (s, user, pass, tenant, otp) => String(s).replace(/\{(user|pass|tenant|totp)\}/g, (_, k) => ({ user, pass, tenant, totp: otp && totp(otp) })[k] || '')
const nav = (page, u, waitUntil = 'domcontentloaded') => page.goto(u, { waitUntil, timeout: 90000 }).catch(() => {})
// off-host (an IdP) or the login path = a login page
const loginPath = (t) => t.webLogin.path || '/login'
const onLogin = (page, t) => !page.url().startsWith(t.web) || page.url().includes(loginPath(t))
async function applyState(page, st) {
  if ((st.cookies || []).length) await page.setCookie(...st.cookies).catch(() => {})
  for (const o of st.origins || []) {
    await nav(page, o.origin)
    await page.evaluate((o) => {
      for (const { name, value } of o.localStorage || []) localStorage.setItem(name, value)
      for (const [k, v] of Object.entries(o.session || {})) sessionStorage.setItem(k, v)
    }, o).catch(() => {})
  }
}
async function step(page, s, f) {
  if (s.goto) await nav(page, url(f(s.goto)), 'networkidle2')
  for (const [sel, v0] of Object.entries(s.fill || {})) {
    const v = f(v0); if (!v) continue
    await page.waitForSelector(sel, { timeout: 60000 }); await page.click(sel, { clickCount: 3 }).catch(() => {}); await page.type(sel, v)
  }
  if (s.click) await Promise.all([page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {}), page.click(s.click)])
  if (s.wait) await (typeof s.wait === 'number' ? sleep(s.wait) : page.waitForSelector(s.wait, { timeout: 60000 }))
  for (let i = 0; s.waitUrl && i < 120 && !new RegExp(s.waitUrl).test(page.url()); i++) await sleep(500)
}

async function login(page, t, tenant, as) {
  const L = t.webLogin, type = L.type || 'form', [user, pass, otp] = t.users[as] || []
  if (!user) throw new Error(`no user "${as}" in this target`)
  const f = (s) => fill(s, user, pass, tenant, otp)
  if (type === 'storageState') { await applyState(page, JSON.parse(readFileSync(L.file, 'utf8'))); await nav(page, t.web + '/', 'networkidle2') }
  else if (type === 'script') await (await import(pathToFileURL(resolve(L.script)).href)).default({ page, user, pass, tenant, target: t, totp: otp && totp(otp) })
  else {
    await nav(page, t.web + (L.path || '/'), 'networkidle2')
    if (!onLogin(page, t)) return   // logged in: never log out
    if (type === 'sso-steps') { for (const s of L.steps || []) await step(page, s, f) }
    else {
      await step(page, { fill: L.fields }, f)
      if (L.rememberMeLabel) await page.evaluate((lb) => { const c = [...document.querySelectorAll('label')].find((e) => e.innerText.trim().toLowerCase() === lb.toLowerCase())?.querySelector('[type=checkbox]'); c?.checked || c?.click() }, L.rememberMeLabel)
      await step(page, { click: L.submit }, f)
    }
  }
  await settle(page)
  if (onLogin(page, t)) throw new Error('login failed: ' + (await text(page)).slice(0, 300))
  await page.evaluate((m) => localStorage.setItem('qa-session', m), `${tenant}/${as}`)
  try {   // share: web storage + cookies (httpOnly sessions)
    const o = await page.evaluate((origin) => ({ origin, localStorage: Object.entries(localStorage).map(([name, value]) => ({ name, value })), session: { ...sessionStorage } }), t.web + loginPath(t))   // the root may redirect to the IdP
    writeFileSync(sessionFile(t, tenant, as), JSON.stringify({ at: Date.now(), cookies: await page.cookies(), origins: [o] }))
  } catch {}
}
const sessionFile = (t, tenant, as) => `${kitPath('sessions', { create: true })}/${(t.web + '-' + tenant + '-' + as).replace(/[^\w.-]/g, '_')}.json`

// reuse a saved login: true if the app accepts it (any age)
async function restoreLogin(page, t, tenant, as) {
  const f = sessionFile(t, tenant, as)
  if (!existsSync(f)) return false
  await applyState(page, JSON.parse(readFileSync(f, 'utf8'))); await nav(page, t.web + '/')
  await sleep(1500)   // the auth guard redirects if the token is invalid
  return loggedIn(page, t)
}

const PROTO_MS = 60000

const MAX_TABS = 8, TAB_WAIT_MS = 300000   // per shared browser; a 9th caller waits <= 5 min
export const sessionKey = (target, tenant, as) => `${target}|${tenant || ''}|${as}`.replace(/[^\w.|-]/g, '_')
const keyFile = (key) => key.replace(/\|/g, '__')
const PORT_BASE = 21000, PORT_SLOTS = 2000
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h }
// create-exclusive lock file, stale takeover
export async function withLock(name, fn, { staleMs = 180000, waitMs = 240000 } = {}) {
  const lock = `${kitPath('sessions', { create: true })}/${name}.lock`, end = Date.now() + waitMs
  for (;;) {
    try { writeFileSync(lock, String(process.pid), { flag: 'wx' }); break } catch {}
    try { if (Date.now() - statSync(lock).mtimeMs > staleMs) { unlinkSync(lock); continue } } catch {}
    if (Date.now() > end) throw new Error(`lock ${name} held for ${Math.round(waitMs / 1000)} s (${lock})`)
    await sleep(250)
  }
  try { return await fn() } finally { try { unlinkSync(lock) } catch {} }
}
// key's port: stable hash, collision-checked in the durable registry
export async function sessionPort(target, tenant, as) {
  const key = sessionKey(target, tenant, as)
  return withLock('ports', async () => {
    const f = kitPath('browser-ports', { create: true }), reg = readJson(f, {}), used = new Set(Object.values(reg))
    if (reg[key]) return reg[key]
    let port = 0
    for (let i = 0, h = fnv(key) % PORT_SLOTS; i < PORT_SLOTS && !port; i++) { const p = PORT_BASE + ((h + i) % PORT_SLOTS); if (!used.has(p)) port = p }
    if (!port) throw new Error(`sessionPort: no free port slot left (${f})`)
    reg[key] = port; saveJson(f, reg)
    return port
  })
}
const loggedIn = async (page, t) => !onLogin(page, t) && (!(t.webLogin.tokenKeys || []).length || !!(await token(page, t).catch(() => null)))
// log in only if needed (rechecked under the lock)
async function ensureLogin(page, t, tenant, as, key) {
  if (await loggedIn(page, t)) return
  await withLock(`login-${keyFile(key)}`, async () => {
    await nav(page, t.web + '/')
    await sleep(1500)   // the app's auth guard redirects when the session is gone
    if (await loggedIn(page, t)) return
    if (!(await restoreLogin(page, t, tenant, as).catch(() => false))) await login(page, t, tenant, as)
  }, { waitMs: 120000 })
}
// tab registry <sessions>/tabs-<key>.json { tabId: { agent, pid, at } }
const tabsFile = (key) => `${kitPath('sessions', { create: true })}/tabs-${keyFile(key)}.json`
const readJson = (f, d) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return d } }
const saveJson = (f, o) => { writeFileSync(`${f}.tmp`, JSON.stringify(o)); renameSync(`${f}.tmp`, f) }
const alive = (pid) => { try { process.kill(pid, 0); return true } catch (e) { return e.code === 'EPERM' } }
function leftBoard(agent) {   // all its board entries say left
  const d = kitPath('board')
  const es = existsSync(d) ? readdirSync(d).filter((f) => f.endsWith('.json')).map((f) => readJson(join(d, f), null)).filter((e) => e && e.agent === agent) : []
  return es.length > 0 && es.every((e) => e.status === 'left')
}
const tabId = async (p) => p.__tid || (p.__tid = await (async () => { const c = await p.createCDPSession(); try { return (await c.send('Target.getTargetInfo')).targetInfo.targetId } finally { await c.detach().catch(() => {}) } })())
const GRACE_MS = 60000 * ((() => { try { return JSON.parse(readFileSync(new globalThis.URL('../dev-kit/kit.local.json', import.meta.url), 'utf8')).idle?.graceMinutes } catch {} })() ?? 10)
// close tabs with no live holder for idle.graceMinutes (caller holds the tabs lock); an unregistered tab counts from first sight
async function sweep(browser, key) {
  const f = tabsFile(key), reg = readJson(f, {}), keep = { _key: key }, now = Date.now()   // _key: file names lose '__' vs '|'
  let live = 0, closed = 0
  for (const p of await browser.pages()) {
    const id = await tabId(p).catch(() => ''), h = reg[id]
    if (!h && p.url() === 'about:blank') continue
    if (h && !((h.pid && !alive(h.pid)) || (h.agent && leftBoard(h.agent)))) h.seen = now   // live holder (README "Leases")
    if (now - (h ? h.seen || h.at : reg[`?${id}`] || now) > GRACE_MS) { await p.close().catch(() => {}); closed++; continue }
    live++
    keep[h ? id : `?${id}`] = h || reg[`?${id}`] || now
  }
  if (!live) keep._idle = reg._idle || now   // supervise closes a browser idle for idle.graceMinutes
  saveJson(f, keep)
  return { live, closed }
}
// a free tab slot, atomic: count + open + register under one lock; waits <= waitMs, then fails clearly
export async function openTab(browser, key, { agent = process.env.CLAUDE_AGENT || `pid-${process.pid}`, waitMs = TAB_WAIT_MS } = {}) {
  const end = Date.now() + waitMs
  for (;;) {
    const page = await withLock(`tabs-${keyFile(key)}`, async () => {
      if ((await sweep(browser, key)).live >= MAX_TABS) return null
      const p = await browser.newPage(), f = tabsFile(key), reg = readJson(f, {})
      reg[await tabId(p)] = { agent, pid: process.pid, at: Date.now() }; reg._key = key; delete reg._idle
      saveJson(f, reg)
      return p
    })
    if (page) return page
    if (Date.now() > end) throw new Error(`session: all ${MAX_TABS} tabs of ${key} stayed busy for ${Math.round(waitMs / 1000)} s (holders: ${tabsFile(key)}); free one with s.done() or retry later`)
    await sleep(1000)
  }
}
export async function closeTab(page, key) {
  const id = await tabId(page).catch(() => '')
  await page.close().catch(() => {})
  await withLock(`tabs-${keyFile(key)}`, async () => { const f = tabsFile(key), reg = readJson(f, {}); delete reg[id]; saveJson(f, reg) }).catch(() => {})
}
// orphan tabs of every shared browser (supervise -AutoFix); a failed connect keeps the registry
export async function sweepAll() {
  const d = kitPath('sessions', { create: true }), ports = readJson(kitPath('browser-ports'), {})
  let closed = 0
  for (const f of readdirSync(d).filter((x) => /^tabs-.*\.json$/.test(x))) {
    const key = readJson(join(d, f), {})._key || f.slice(5, -5).replace(/__/g, '|')
    if (!ports[key]) { try { unlinkSync(join(d, f)) } catch {}; continue }
    const b = await puppeteer.connect({ browserURL: `http://127.0.0.1:${ports[key]}`, protocolTimeout: PROTO_MS }).catch(() => null)
    if (!b) continue
    try { closed += (await withLock(`tabs-${keyFile(key)}`, () => sweep(b, key))).closed } finally { b.disconnect() }
  }
  return closed
}
export const relogin = (s) => ensureLogin(s.page, s.target, s.tenant, s.as, s.key)
export const ensureLoggedIn = async (page, q = page.__qa) => q && ensureLogin(page, q.t, q.tenant, q.as, q.key)

// Playwright: a browser per process, puppeteer names mapped
async function pwPage(eng, bo, VIEW) {
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
// your own logged-in tab
export async function session({ target, tenant, as = 'admin' } = {}) {
  const pin = String(process.env.KIT_QA_TARGETS || '').split(/[,\s]+/).filter(Boolean), tn = target || CFG.default
  if (pin.length && !pin.includes(tn)) throw new Error(`target '${tn}' is not this QA run's target (${pin.join(', ')})`)
  const t0 = targetOf(target)
  tenant = tenant ?? t0.defaultTenant ?? ''
  const t = { ...t0, web: fill(t0.web || '', '', '', tenant) }, bo = browserOpts(t0), eng = process.env.KIT_BROWSER_ENGINE || bo.engine
  const key = sessionKey(target, tenant, as), VIEW = { width: Number(bo.width), height: Number(bo.height) }
  BASE = t.web
  let browser, page, port = null
  const agentId = process.env.CLAUDE_AGENT || `pid-${process.pid}`
  if (eng !== 'chrome') ({ browser, page } = await pwPage(eng, bo, VIEW))
  else {
    if (!CHROME) throw new Error('no Chrome/Edge found; set CHROME_PATH')
    port = await sessionPort(target, tenant, as)
    const conn = () => puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: VIEW, protocolTimeout: PROTO_MS })
    try { browser = await conn() } catch {
      const dir = `${PROFILES}/${keyFile(key)}`; mkdirSync(dir, { recursive: true })
      spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, `--window-size=${VIEW.width},${VIEW.height}`, `--lang=${bo.lang}`, '--no-first-run', '--no-default-browser-check', 'about:blank'], { detached: true, stdio: 'ignore' }).unref()
      for (let i = 0; i < 40 && !browser; i++) { await sleep(500); try { browser = await conn() } catch {} }
      if (!browser) throw new Error(`could not start Chrome on port ${port}`)
    }
    // a notification prompt eats header clicks
    await browser.defaultBrowserContext().overridePermissions(t.web, ['notifications', 'geolocation', 'clipboard-read', 'clipboard-write']).catch(() => {})
    page = await openTab(browser, key, { agent: agentId })
    if (bo.timezone) await page.emulateTimezone(bo.timezone).catch(() => {})
  }
  page.__qa = { t, tenant, as, key, agent: agentId }
  page.setDefaultTimeout(20000); page.setDefaultNavigationTimeout(90000)
  const net = watch(page, t.apiPattern)
  if (t.webLogin) { await nav(page, t.web + '/'); await ensureLogin(page, t, tenant, as, key) }
  return { browser, page, net, target: t, tenant, as, key, port, engine: eng,
    done: async () => { if (port === null) return browser.close().catch(() => {}); await closeTab(page, key); try { browser.disconnect() } catch {} } }
}
export const killSession = (port) => puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, protocolTimeout: PROTO_MS }).then((b) => b.close()).catch(() => {})

// quiet XHR <= 8 s (polling pages never idle), not past 100 JS errors
export async function settle(page, ms = 1200) {
  let errs = 0, tick
  const onErr = () => { errs++ }
  page.on('pageerror', onErr)
  await Promise.race([page.waitForNetworkIdle({ idleTime: 700, timeout: 8000 }).catch(() => {}), new Promise((r) => { tick = setInterval(() => errs > 100 && r(), 200) })])
  clearInterval(tick); page.off('pageerror', onErr)
  if (errs > 100) return console.error(`[browser] settle: ${errs} page errors, stopped waiting`)
  await sleep(ms)
}

const TIMED_OUT = Symbol('timed out')
const scrollTo = (el) => (el.scrollIntoView ? el.scrollIntoView() : el.scrollIntoViewIfNeeded())
const capped = (p, ms) => { let t; return Promise.race([p, new Promise((r) => { t = setTimeout(() => r(TIMED_OUT), ms) })]).finally(() => clearTimeout(t)) }

export async function go(page, path) {
  await nav(page, url(path), 'networkidle2')
  const q = page.__qa
  if (q && q.t.webLogin && url(path).startsWith(q.t.web) && onLogin(page, q.t) && !String(path).includes(loginPath(q.t))) {
    await ensureLogin(page, q.t, q.tenant, q.as, q.key)   // expired: once, then retry
    await nav(page, url(path), 'networkidle2')
  }
  await settle(page)
}

export const text = (page, selector = 'body') => page.$eval(selector, (el) => el.innerText).catch(() => '')

// real click on the innermost visible text / title / aria-label match (exact, then contains)
export async function clickText(page, label, { nth = 0, within = 'body', exact = false, right = false } = {}) {
  let box = await capped(page.evaluate(({ label, nth, within, exact }) => {
    const root = document.querySelector(within) || document.body
    const vis = (el) => { const r = el.getBoundingClientRect(), s = getComputedStyle(el); return r.width && r.height && s.visibility !== 'hidden' && s.display !== 'none' }
    const all = [...root.querySelectorAll('*')].filter(vis), at = (el, a) => el.getAttribute(a)
    const own = (el) => (el.innerText || at(el, 'title') || at(el, 'aria-label') || at(el, 'placeholder') || '').replace(/\s+/g, ' ').trim()
    let hits = all.filter((el) => own(el) === label)
    if (!hits.length && !exact) hits = all.filter((el) => own(el).includes(label))
    hits = hits.filter((el) => !hits.some((o) => o !== el && el.contains(o)))
    const el = hits[nth]
    if (!el) return null
    el.scrollIntoView({ block: 'center' }); const r = el.getBoundingClientRect()
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, n: hits.length }
  }, { label, nth, within, exact }), 15000)
  if (box === TIMED_OUT) {   // DOM walk > 15 s: a text query + boundingBox
    box = null
    const hs = await capped(page.$$(page.__pw ? `${within} >> text=${label}` : `${within === 'body' ? '' : within + ' '}::-p-text(${JSON.stringify(label)})`), 15000).catch(() => [])
    const el = Array.isArray(hs) ? hs[nth] : null
    await (el && capped(scrollTo(el), 5000).catch(() => {}))
    const b = el && await capped(el.boundingBox(), 5000).catch(() => null)
    if (b && b !== TIMED_OUT) box = { ...mid(b), n: hs.length, fallback: true }
  }
  if (!box) throw new Error(`clickText: "${label}" not found`)
  await page.mouse.click(box.x, box.y, { button: right ? 'right' : 'left' })
  await settle(page, 700)
  return box
}

const mid = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 })
// nth match, scrolled in, with its box
export async function pick(page, selector, nth = 0, what = 'element') {
  await page.waitForSelector(selector, { visible: true, timeout: 20000 })
  const all = await page.$$(selector), el = all[nth]
  if (!el) throw new Error(`${what}: "${selector}" has ${all.length} match(es), no index ${nth}`)
  await scrollTo(el); const b = await el.boundingBox()
  if (!b) throw new Error(`${what}: "${selector}" [${nth}] has no box (hidden or detached)`)
  return { el, b }
}

export async function clickSel(page, selector, { right = false, nth = 0 } = {}) {
  const { b } = await pick(page, selector, nth, 'clickSel')
  const { x, y } = mid(b); await page.mouse.click(x, y, { button: right ? 'right' : 'left' })
  await settle(page, 700)
}

// pointer in from outside, in steps: mouseenter fires
export async function hoverSel(page, selector, { nth = 0 } = {}) {
  const { b } = await pick(page, selector, nth, 'hoverSel')
  await page.mouse.move(b.x - 40, b.y - 40)
  const { x, y } = mid(b); await page.mouse.move(x, y, { steps: 12 })
  await sleep(900)
}

// replace an input's value (date pickers too): select all, type, Enter
export async function setInput(page, selector, value, { nth = 0, enter = true } = {}) {
  const { el } = await pick(page, selector, nth, 'setInput')
  await el.click({ clickCount: 3 })
  const k = page.keyboard, mod = process.platform === 'darwin' ? 'Meta' : 'Control'   // Cmd+A on macOS
  await k.down(mod); await k.press('KeyA'); await k.up(mod); await k.press('Backspace')
  await el.type(String(value), { delay: 20 })
  if (enter) await k.press('Enter')
  await settle(page, 500)
  return page.evaluate((e) => e.value, el)
}

// evidence names (evidence-standard.md); same literal as qa.ps1 $script:EvidenceName
const EVIDENCE_NAME = /^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2}m?)?|_\d{2}m?)_[a-z0-9]+([-._][a-z0-9]+)*|[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?|jsonl|ndjson)$/i
function checkName(file) {
  if (!EVIDENCE_NAME.test(basename(file))) console.warn(`[evidence] "${basename(file)}" is not <CODE>-<check>_<nn>_<what>.<ext> (F2-T4_01_order-saved.jpeg)`)
  mkdirSync(dirname(file), { recursive: true })
}

// red outline until the next shot / unmark()
export async function mark(page, selector, { nth = null } = {}) {
  await page.evaluate(({ selector, nth }) => [...document.querySelectorAll(selector)].forEach((el, i) => {
    if (nth === null || i === nth) { el.dataset.qaMark = el.style.outline || ' '; el.style.outline = '3px solid #e11d48'; el.style.outlineOffset = '2px' }
  }), { selector, nth })
}
export async function unmark(page) {
  await page.evaluate(() => document.querySelectorAll('[data-qa-mark]').forEach((el) => { el.style.outline = el.dataset.qaMark.trim(); el.style.outlineOffset = ''; delete el.dataset.qaMark })).catch(() => {})
}

export function saveNet(s, file, { calls = null, meta = {} } = {}) {
  checkName(file)
  const m = basename(file).match(/^([A-Za-z0-9]+)-([A-Za-z]*\d+)/) || []
  writeFileSync(file, JSON.stringify({ meta: { code: m[1] || '', check: m[2] || '', target: s.target.web, at: new Date().toISOString(), tool: 'browser.mjs', ...meta },
    calls: (calls || s.net.failed).map((c) => ({ request: { method: c.method || '', url: c.url }, response: { status: c.status, body: c.body || '' } })) }, null, 2))
  return file
}

export async function shot(page, file, { full = false, selector = null } = {}) {
  checkName(file)
  const png = file.endsWith('.png'), opts = { path: file, type: png ? 'png' : 'jpeg', ...(!png && { quality: 80 }) }
  try {
    if (selector) { const el = await page.$(selector); if (el) { await el.screenshot(opts); return file } }
    await page.screenshot({ ...opts, fullPage: full })
  } finally { await unmark(page) }
  return file
}

// the UI session's token (target tokenKeys)
export async function token(page, t = null) {
  const keys = t?.webLogin?.tokenKeys || Object.values(CFG.targets).flatMap((x) => x.webLogin?.tokenKeys || [])
  return page.evaluate((keys) => { for (const k of keys) { const v = sessionStorage.getItem(k) || localStorage.getItem(k); if (v) return v } return null }, keys)
}
