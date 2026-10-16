// browser.mjs: headless-browser library for testing any web app (import it; usage below).
// Exit codes: none (a library; a script using it exits with its own code).
// Targets (URL, login form, users): skills/qa-kit/targets.local.json; nothing app-specific here.
// SHARED SESSION: one logged-in headless Chrome per target+tenant+user (own profile + port); runs / agents attach own
// tabs: one login for all. Re-login only on expiry (login page / 401: relogin(s)), locked. Never log out.
//   import { session, go, text, clickText, clickSel, hoverSel, setInput, shot, token, killSession }
//     from 'file:///<workspace>/.claude/skills/qa-kit/browser.mjs'   // absolute file URL (Windows: file:///C:/...)
//   const s = await session({ target: 'my-staging', tenant: 'acme', as: 'admin' })   // shared browser, own tab
//   await go(s.page, '/projects')
//   console.log((await text(s.page)).slice(0, 2000))
//   await clickText(s.page, 'Filter')
//   await setInput(s.page, 'input[placeholder="Select date"]', '29/09/2026 13:45')   // type + Enter (date pickers too)
//   await mark(s.page, '.ant-table-row:first-child')   // red outline until the shot
//   await shot(s.page, '<run>/F2/shots/F2-T3_01_filter-applied.jpeg')   // names: below
//   console.log(JSON.stringify(s.net.failed))   // this script's 4xx/5xx + JS errors = failure evidence
//   if (s.net.failed.length) saveNet(s, '<run>/F2/evidence/F2-T3_02_failed-calls.json')
//   if (s.net.failed.some((f) => f.status === 401)) await relogin(s)   // expired: locked re-login, retry
//   await s.done()   // closes only your tab
//   // coordinator, no agent on that user: await killSession(sessionPort(target, tenant, as))
// Waits cap at 20 s (bad selectors fail fast). Real mouse clicks (UI kits ignore synthetic el.click()). Windows: node
// from PowerShell, not git-bash. Linux/macOS: Chrome/Edge/Chromium in usual folders / PATH; CHROME_PATH overrides.
import puppeteer from 'puppeteer-core'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, delimiter, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const TF = new globalThis.URL('./targets.local.json', import.meta.url)
const CFG = existsSync(TF) ? JSON.parse(readFileSync(TF, 'utf8')) : { targets: {} }   // none: sweeps still work
// --- kit paths (kit.example.json _paths): <runtime> = $CLAUDE_RUNTIME | <kit>/.runtime; durable: <kit>/.state
const __HERE = dirname(fileURLToPath(import.meta.url))
export const KIT = resolve(__HERE, '..', '..')
const MAP = JSON.parse(readFileSync(join(__HERE, '..', 'dev-kit', 'kit.example.json'), 'utf8'))._paths
export const runtimeDir = () => process.env.CLAUDE_RUNTIME || join(KIT, MAP.runtimeDir)
export function kitPath(name, { create = false } = {}) {
  let rel, base
  if (name === 'runtime') { rel = '/'; base = runtimeDir() }
  else if (name in MAP.runtime) { rel = MAP.runtime[name]; base = runtimeDir() }
  else if (name in MAP.durable) { rel = MAP.durable[name]; base = join(KIT, MAP.stateDir) }
  else throw new Error(`kitPath: unknown name '${name}' (see skills/dev-kit/kit.example.json _paths)`)
  const p = rel === '/' ? base : join(base, rel.replace(/\/$/, ''))
  if (create) mkdirSync(rel.endsWith('/') ? p : dirname(p), { recursive: true })
  return p
}
// kit path map: cache/chrome-profiles, cache/sessions
const PROFILES = kitPath('chrome-profiles')
// $CHROME_PATH, usual folders per OS, then PATH (Linux package names)
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
// per-target (or top-level) "browser": { lang (Accept-Language, date/number formats), timezone, width, height }; en-GB, local, 1600x1000
const browserOpts = (t) => ({ lang: 'en-GB', timezone: '', width: 1600, height: 1000, ...(CFG.browser || {}), ...((t && t.browser) || {}) })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export function targetOf(name) {
  const t = CFG.targets[name || CFG.default]
  if (!t) throw new Error(`unknown target "${name}" (known: ${Object.keys(CFG.targets).join(', ')})`)
  return t
}
let BASE = ''   // last session()'s web base, for go()'s relative paths
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
  // capped: error-looping pages grew it unbounded
  net.jsErrors = 0
  page.on('pageerror', (err) => { if (++net.jsErrors <= 50) net.failed.push({ status: 'JS', url: page.url(), body: String(err).slice(0, 400) }) })
  page.on('dialog', (d) => d.accept().catch(() => {}))
  return net
}

const fill = (s, user, pass, tenant) => String(s).replaceAll('{user}', user).replaceAll('{pass}', pass).replaceAll('{tenant}', tenant || '')

async function login(page, t, tenant, as) {
  const L = t.webLogin
  const [user, pass] = t.users[as] || []
  if (!user) throw new Error(`no user "${as}" in this target`)
  await page.goto(t.web + L.path, { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  if (!page.url().includes(L.path)) return   // logged in already (same user): never log out
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
  // share the login: web storage (holds the token) saved 8 h
  try {
    const st = await page.evaluate(() => ({ local: { ...localStorage }, session: { ...sessionStorage } }))
    kitPath('sessions', { create: true })
    writeFileSync(sessionFile(t, tenant, as), JSON.stringify({ at: Date.now(), ...st }))
  } catch {}
}

const sessionFile = (t, tenant, as) => `${kitPath('sessions')}/${(t.web + '-' + tenant + '-' + as).replace(/[^\w.-]/g, '_')}.json`

// Reuse another port's saved login (~1 s); true if the app accepts it.
async function restoreLogin(page, t, tenant, as) {
  const f = sessionFile(t, tenant, as)
  if (!existsSync(f)) return false
  const s = JSON.parse(readFileSync(f, 'utf8'))   // age is no reason to drop it: the auth guard decides
  await page.goto(t.web + t.webLogin.path, { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
  await page.evaluate((s) => {
    for (const [k, v] of Object.entries(s.local || {})) localStorage.setItem(k, v)
    for (const [k, v] of Object.entries(s.session || {})) sessionStorage.setItem(k, v)
  }, s)
  await page.goto(t.web + '/', { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
  await sleep(1500)   // the auth guard redirects if the token is invalid
  const tok = (t.webLogin.tokenKeys || []).length ? await token(page, t) : 'n/a'
  return !!tok && !page.url().includes(t.webLogin.path)
}

// a hung CDP call fails in 60 s, not puppeteer's 180 s
const PROTO_MS = 60000

const MAX_TABS = 8, TAB_WAIT_MS = 300000   // per shared browser; a 9th caller waits <= 5 min for a free tab, then fails
// per target+tenant+user: Chrome profile, unique registry port, login lock
export const sessionKey = (target, tenant, as) => `${target}|${tenant || ''}|${as}`.replace(/[^\w.|-]/g, '_')
const keyFile = (key) => key.replace(/\|/g, '__')
const PORT_BASE = 21000, PORT_SLOTS = 2000
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h }
// create-exclusive lock file, stale takeover; fn runs only while held
export async function withLock(name, fn, { staleMs = 180000, waitMs = 240000 } = {}) {
  const lock = `${kitPath('sessions', { create: true })}/${name}.lock`
  const end = Date.now() + waitMs
  for (;;) {
    try { writeFileSync(lock, String(process.pid), { flag: 'wx' }); break } catch {}
    try { if (Date.now() - statSync(lock).mtimeMs > staleMs) { unlinkSync(lock); continue } } catch {}
    if (Date.now() > end) throw new Error(`lock ${name} held for ${Math.round(waitMs / 1000)} s (${lock})`)
    await sleep(250)
  }
  try { return await fn() } finally { try { unlinkSync(lock) } catch {} }
}
// key's port: stable hash in the reserved range, collision-checked in the durable registry
export async function sessionPort(target, tenant, as) {
  const key = sessionKey(target, tenant, as)
  return withLock('ports', async () => {
    const f = kitPath('browser-ports', { create: true })
    const reg = existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : {}
    if (reg[key]) return reg[key]
    const used = new Set(Object.values(reg))
    let port = 0
    for (let i = 0, h = fnv(key) % PORT_SLOTS; i < PORT_SLOTS && !port; i++) { const p = PORT_BASE + ((h + i) % PORT_SLOTS); if (!used.has(p)) port = p }
    if (!port) throw new Error(`sessionPort: no free port slot left (${f})`)
    reg[key] = port
    writeFileSync(`${f}.tmp`, JSON.stringify(reg, null, 1)); renameSync(`${f}.tmp`, f)
    return port
  })
}
const loggedIn = async (page, t) => {
  if (!page.url().startsWith(t.web) || page.url().includes(t.webLogin.path)) return false
  return !(t.webLogin.tokenKeys || []).length || !!(await token(page, t).catch(() => null))
}
// log in only if needed (rechecked in the lock: another agent may have)
async function ensureLogin(page, t, tenant, as, key) {
  if (await loggedIn(page, t)) return
  await withLock(`login-${keyFile(key)}`, async () => {   // others wait (<= 2 min), then restore the fresh session file
    await page.goto(t.web + '/', { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
    await sleep(1500)   // the app's auth guard redirects when the session is gone
    if (await loggedIn(page, t)) return
    if (!(await restoreLogin(page, t, tenant, as).catch(() => false))) await login(page, t, tenant, as)
  }, { waitMs: 120000 })
}
// tab registry <sessions>/tabs-<key>.json { tabId: { agent, pid, at } }: holder dead or off the board = orphan
const tabsFile = (key) => `${kitPath('sessions', { create: true })}/tabs-${keyFile(key)}.json`
const readJson = (f, d) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return d } }
const saveJson = (f, o) => { writeFileSync(`${f}.tmp`, JSON.stringify(o)); renameSync(`${f}.tmp`, f) }
const alive = (pid) => { try { process.kill(pid, 0); return true } catch (e) { return e.code === 'EPERM' } }
function leftBoard(agent) {   // every board entry of the agent says left
  const d = kitPath('board')
  const es = existsSync(d) ? readdirSync(d).filter((f) => f.endsWith('.json')).map((f) => readJson(join(d, f), null)).filter((e) => e && e.agent === agent) : []
  return es.length > 0 && es.every((e) => e.status === 'left')
}
const tabId = async (p) => p.__tid || (p.__tid = await (async () => { const c = await p.createCDPSession(); try { return (await c.send('Target.getTargetInfo')).targetInfo.targetId } finally { await c.detach().catch(() => {}) } })())
// close orphan tabs (caller holds the tabs lock); a tab nobody registered (older client) is an orphan after 10 min
async function sweep(browser, key) {
  const f = tabsFile(key), reg = readJson(f, {}), keep = {}, now = Date.now()
  let live = 0, closed = 0
  for (const p of await browser.pages()) {
    const id = await tabId(p).catch(() => ''), h = reg[id]
    if (!h && p.url() === 'about:blank') continue
    if (h ? (h.pid && !alive(h.pid)) || (h.agent && leftBoard(h.agent)) : now - (reg[`?${id}`] || now) > 600000) { await p.close().catch(() => {}); closed++; continue }
    live++
    keep[h ? id : `?${id}`] = h || reg[`?${id}`] || now
  }
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
      reg[await tabId(p)] = { agent, pid: process.pid, at: Date.now() }
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
// every shared browser: close orphan tabs (orch.ps1 supervise -AutoFix); a registry without its Chrome is dropped
export async function sweepAll() {
  const d = kitPath('sessions', { create: true }), ports = readJson(kitPath('browser-ports'), {})
  let closed = 0
  for (const f of readdirSync(d).filter((x) => /^tabs-.*\.json$/.test(x))) {
    const key = f.slice(5, -5).replace(/__/g, '|')
    const b = ports[key] ? await puppeteer.connect({ browserURL: `http://127.0.0.1:${ports[key]}`, protocolTimeout: PROTO_MS }).catch(() => null) : null
    if (!b) { try { unlinkSync(join(d, f)) } catch {}; continue }
    try { closed += (await withLock(`tabs-${keyFile(key)}`, () => sweep(b, key))).closed } finally { b.disconnect() }
  }
  return closed
}
// expired mid-script (401 / login page): restore the fresh session or log in once (locked), retry
export async function relogin(s) { await ensureLogin(s.page, s.target, s.tenant, s.as, s.key) }
export const ensureLoggedIn = (page) => (page.__qa ? ensureLogin(page, page.__qa.t, page.__qa.tenant, page.__qa.as, page.__qa.key) : Promise.resolve())

// Attach to (or start) the user's shared Chrome + your own logged-in tab; `port` ignored (sessionPort owns it).
export async function session({ target, tenant, as = 'admin' } = {}) {
  const pin = String(process.env.KIT_QA_TARGETS || '').split(/[,\s]+/).filter(Boolean)   // as qa.ps1 api: a run tests only its own env
  if (pin.length && !pin.includes(target || CFG.default)) throw new Error(`target '${target || CFG.default}' is not this QA run's target (${pin.join(', ')}): a run tests only its own env`)
  if (!CHROME) throw new Error('no Chrome/Edge found; set CHROME_PATH')
  const t = targetOf(target)
  tenant = tenant ?? t.defaultTenant ?? ''
  const key = sessionKey(target, tenant, as)
  const port = await sessionPort(target, tenant, as)
  BASE = t.web
  const bo = browserOpts(t)
  const VIEW = { width: Number(bo.width), height: Number(bo.height) }
  let browser
  try {
    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: VIEW, protocolTimeout: PROTO_MS })
  } catch {
    const dir = `${PROFILES}/${keyFile(key)}`
    mkdirSync(dir, { recursive: true })
    const child = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, `--window-size=${VIEW.width},${VIEW.height}`, `--lang=${bo.lang}`, '--no-first-run', '--no-default-browser-check', 'about:blank'], { detached: true, stdio: 'ignore' })
    child.unref()
    for (let i = 0; i < 40 && !browser; i++) {
      await sleep(500)
      try { browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: VIEW, protocolTimeout: PROTO_MS }) } catch {}
    }
    if (!browser) throw new Error(`could not start Chrome on port ${port}`)
  }
  // undecided notification permission: its toast eats header clicks
  try { await browser.defaultBrowserContext().overridePermissions(t.web, ['notifications', 'geolocation', 'clipboard-read', 'clipboard-write']) } catch {}
  const agentId = process.env.CLAUDE_AGENT || `pid-${process.pid}`
  const page = await openTab(browser, key, { agent: agentId })   // own tab: this user's other agents keep theirs
  await page.evaluateOnNewDocument((a) => { window.__qaAgent = a }, agentId).catch(() => {})
  page.__qa = { t, tenant, as, key, agent: agentId }
  await page.setViewport(VIEW)
  if (bo.timezone) await page.emulateTimezone(bo.timezone).catch(() => {})
  page.setDefaultTimeout(20000)
  page.setDefaultNavigationTimeout(90000)
  const net = watch(page, t.apiPattern)
  if (t.webLogin) {
    await page.goto(t.web + '/', { waitUntil: 'domcontentloaded', timeout: 90000 }).catch(() => {})
    await ensureLogin(page, t, tenant, as, key)
  }
  return { browser, page, net, target: t, tenant, as, key, port,
    done: async () => { await closeTab(page, key); try { browser.disconnect() } catch {} } }
}

export async function killSession(port) {
  try { const b = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, protocolTimeout: PROTO_MS }); await b.close() } catch {}
}

// wait for quiet XHR: <= 8 s (polling pages never idle); stop early on > 100 JS errors
export async function settle(page, ms = 1200) {
  let errs = 0
  const onErr = () => { errs++ }
  page.on('pageerror', onErr)
  let tick
  const flood = new Promise((r) => { tick = setInterval(() => { if (errs > 100) r() }, 200) })
  try { await Promise.race([page.waitForNetworkIdle({ idleTime: 700, timeout: 8000 }).catch(() => {}), flood]) } catch {}
  clearInterval(tick)
  page.off('pageerror', onErr)
  if (errs > 100) { console.error(`[browser] settle: ${errs} page errors while waiting - stopped waiting (error flood on ${page.url().slice(0, 120)})`); return }
  await sleep(ms)
}

const TIMED_OUT = Symbol('timed out')
const capped = (p, ms) => { let t; return Promise.race([p, new Promise((r) => { t = setTimeout(() => r(TIMED_OUT), ms) })]).finally(() => clearTimeout(t)) }

export async function go(page, path) {
  await page.goto(url(path), { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  const q = page.__qa
  if (q && q.t.webLogin && page.url().includes(q.t.webLogin.path) && !String(path).includes(q.t.webLogin.path)) {
    await ensureLogin(page, q.t, q.tenant, q.as, q.key)   // expired (another login may rotate it): once, then retry
    await page.goto(url(path), { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  }
  await settle(page)
}

// visible text of the page or a selector
export async function text(page, selector = 'body') {
  return page.$eval(selector, (el) => el.innerText).catch(() => '')
}

// real click on the innermost visible text / title / aria-label match (exact, then contains); DOM walk <= 15 s, then ::-p-text
export async function clickText(page, label, { nth = 0, within = 'body', exact = false, right = false } = {}) {
  let box = await capped(page.evaluate(({ label, nth, within, exact }) => {
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
  }, { label, nth, within, exact }), 15000)
  if (box === TIMED_OUT) {
    console.error(`[browser] clickText "${label}": the DOM walk took > 15 s - falling back to a text query + boundingBox`)
    box = null
    const hs = await capped(page.$$(`${within === 'body' ? '' : within + ' '}::-p-text(${JSON.stringify(label)})`), 15000).catch(() => [])
    const el = Array.isArray(hs) ? hs[nth] : null
    if (el) {
      await capped(el.scrollIntoView(), 5000).catch(() => {})
      const b = await capped(el.boundingBox(), 5000).catch(() => null)
      if (b && b !== TIMED_OUT) box = { x: b.x + b.width / 2, y: b.y + b.height / 2, n: hs.length, fallback: true }
    }
  }
  if (!box) throw new Error(`clickText: "${label}" not found`)
  await page.mouse.click(box.x, box.y, { button: right ? 'right' : 'left' })
  await settle(page, 700)
  return box
}

// nth match, scrolled in, with its box: clear error on bad nth / hidden element
export async function pick(page, selector, nth = 0, what = 'element') {
  await page.waitForSelector(selector, { visible: true, timeout: 20000 })
  const all = await page.$$(selector)
  const el = all[nth]
  if (!el) throw new Error(`${what}: "${selector}" has ${all.length} match(es), no index ${nth}`)
  await el.scrollIntoView()
  const b = await el.boundingBox()
  if (!b) throw new Error(`${what}: "${selector}" [${nth}] has no box (hidden or detached)`)
  return { el, b }
}

export async function clickSel(page, selector, { right = false, nth = 0 } = {}) {
  const { b } = await pick(page, selector, nth, 'clickSel')
  await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2, { button: right ? 'right' : 'left' })
  await settle(page, 700)
}

// Hover menus: pointer in from outside, in steps, so mouseenter fires.
export async function hoverSel(page, selector, { nth = 0 } = {}) {
  const { b } = await pick(page, selector, nth, 'hoverSel')
  await page.mouse.move(b.x - 40, b.y - 40)
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 12 })
  await sleep(900)
}

// Replace an input's value (text, number, date/time pickers): click, select all, type, Enter.
export async function setInput(page, selector, value, { nth = 0, enter = true } = {}) {
  const { el } = await pick(page, selector, nth, 'setInput')
  await el.click({ clickCount: 3 })
  const mod = process.platform === 'darwin' ? 'Meta' : 'Control'   // Cmd+A on macOS
  await page.keyboard.down(mod); await page.keyboard.press('KeyA'); await page.keyboard.up(mod)
  await page.keyboard.press('Backspace')
  await el.type(String(value), { delay: 20 })
  if (enter) await page.keyboard.press('Enter')
  await settle(page, 500)
  return page.evaluate((e) => e.value, el)
}

// Evidence names: <CODE>-<checkId>[_verify]_<nn>[m]_<what>.<ext>, setup <code>-<nn>-<what>.<ext> (evidence-standard.md);
// same literal as lib/report.ps1 $script:EvidenceName (/i: PowerShell -match ignores case)
const EVIDENCE_NAME = /^(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-[A-Za-z]*\d+[a-z]?(_verify(_\d{2}m?)?|_\d{2}m?)_[a-z0-9]+([-._][a-z0-9]+)*|[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(jpe?g|png|json|log|mp4|pdf|csv|txt|html|xlsx?|jsonl|ndjson)$/i
function checkName(file) {
  if (!EVIDENCE_NAME.test(basename(file))) console.warn(`[evidence] "${basename(file)}" does not follow <CODE>-<check>_<nn>_<what>.<ext> (e.g. F2-T4_01_order-saved.jpeg)`)
}

// Red outline for the next shot; unmark() or shot() removes it.
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

// Save network evidence (default: this script's failed calls), standard envelope.
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

// UI session Bearer token (call the API as that user), via the target's tokenKeys
export async function token(page, t = null) {
  const keys = ((t || {}).webLogin || {}).tokenKeys || Object.values(CFG.targets).flatMap((x) => (x.webLogin || {}).tokenKeys || [])
  return page.evaluate((keys) => { for (const k of keys) { const v = sessionStorage.getItem(k) || localStorage.getItem(k); if (v) return v } return null }, keys)
}
