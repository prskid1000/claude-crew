// web-login.mjs: a module skills/pokey/browser.mjs imports. Usage: through browser.mjs. Exit codes: none (a module).
// web-login-types: webLogin.type sso-steps (steps: goto, fill {sel: val}, click, wait sel|ms, waitUrl) | script (.mjs:
// default async ({ page, user, pass, tenant, target, totp })) | storageState (file: cookies, origins); {totp} from users[as][2].
// Imported by browser.mjs login() from adapters/; h = its helpers { nav, step, applyState, onLogin, fill, here }; session(): laneTarget.
import { spawnSync } from 'node:child_process'
import { createHmac } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

// RFC 6238 (30 s, 6 digits)
export function totp(secret, at = Date.now()) {
  const bits = String(secret).toUpperCase().replace(/[^A-Z2-7]/g, '').split('').map((c) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5, '0')).join('')
  const c = Buffer.alloc(8), h = (c.writeBigUInt64BE(BigInt(Math.floor(at / 30000))), createHmac('sha1', Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)))).update(c).digest())
  return String((h.readUInt32BE(h[19] & 15) & 0x7fffffff) % 1e6).padStart(6, '0')
}

export async function login({ page, t, tenant, user, pass, otp, type }, h) {
  const L = t.webLogin, code = otp && totp(otp)
  const f = (s) => h.fill(s, user, pass, tenant).replace(/\{totp\}/g, code || '')
  if (type === 'storageState') { await h.applyState(page, JSON.parse(readFileSync(resolve(h.here, L.file), 'utf8'))); await h.nav(page, t.web + '/', 'networkidle2') }
  else if (type === 'script') await (await import(pathToFileURL(resolve(h.here, L.script)).href)).default({ page, user, pass, tenant, target: t, totp: code })
  else if (type === 'sso-steps') {
    await h.nav(page, t.web + (L.path || '/'), 'networkidle2')
    if (!h.onLogin(page, t)) return   // logged in: never log out
    for (const s of L.steps || []) await h.step(page, s, f)
  } else if (type === 'form') {   // a form whose fields carry {totp}
    await h.nav(page, t.web + (L.path || '/'), 'networkidle2')
    if (!h.onLogin(page, t)) return
    await h.step(page, { fill: L.fields }, f)
    await h.step(page, { click: L.submit }, f)
  } else throw new Error(`webLogin.type ${type}: form | sso-steps | script | storageState`)
}
// '<target>-<bird>' / '<target><k>' = a local env lane: the base target's login, its lane-1 URL ports moved to lane k's (as pokey.ps1
// Get-LaneTarget); lanes = envy.ps1 envs -Json (omitted: run once per process; pokey.ps1's cache key is .NET file ticks)
let ENVY = null
export function laneTarget(name, targets, lanes) {
  const m = /^(.+)-([a-z]+)$/i.exec(name || '') || /^(.+?)(\d+)$/.exec(name || ''), base = m && targets[m[1]]
  if (!base) return null
  if (!Array.isArray(lanes)) { try { ENVY ??= [].concat(JSON.parse(spawnSync('pwsh', ['-NoProfile', '-File', resolve(import.meta.dirname, '../../envy/envy.ps1'), 'envs', '-Json'], { encoding: 'utf8', timeout: 60000 }).stdout || '[]')) } catch { ENVY = [] }; lanes = ENVY }
  const k = /^\d+$/.test(m[2]) ? Number(m[2]) : lanes.find((l) => String(l.env).toLowerCase().endsWith('-' + m[2].toLowerCase()))?.lane
  if (k === 1) return base
  const urls = `${base.web || ''} ${base.api || ''}`
  for (const g of lanes.filter((l) => l.lane === 1)) {
    const one = Object.entries(g.ports || {}).filter(([, p]) => new RegExp(`:${p}(?!\\d)`).test(urls)), lk = lanes.find((l) => l.group === g.group && l.lane === k)
    if (!one.length || !lk) continue
    const t = JSON.parse(JSON.stringify(base))
    for (const f of ['web', 'api']) for (const [pn, p] of one) if (t[f] && lk.ports?.[pn]) t[f] = t[f].replace(new RegExp(`:${p}(?!\\d)`), `:${lk.ports[pn]}`)
    return t
  }
  return null
}
// registry (parity.json login): the web surface (browser.mjs login()) reads users and profiles, no secret:<name> ref (a node
// process gets no value from the store; pokey.ps1 api and ui login read every store)
export const ADAPTERS = { login: {} }
ADAPTERS['login']['web'] = { users: true, profiles: true }
