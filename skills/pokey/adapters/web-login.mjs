// web-login.mjs: a module skills/pokey/browser.mjs imports. Usage: through browser.mjs. Exit codes: none (a module).
// web-login-types: webLogin.type sso-steps (steps: goto, fill {sel: val}, click, wait sel|ms, waitUrl) | script (.mjs:
// default async ({ page, user, pass, tenant, target, totp })) | storageState (file: cookies, origins); {totp} from users[as][2].
// Imported by browser.mjs login() from adapters/; h = its helpers { nav, step, applyState, onLogin, fill, here }; session(): resolveTarget.
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

// a secret:<name> value (users, profiles; any secrets.store): the kit's secret-store in a child pwsh whose stdout only this
// process reads (never logged); a plain value passes through
export function resolveSecret(v, run = spawnSync) {
  const m = /^secret:(.+)$/.exec(v || ''); if (!m) return v
  const lib = resolve(import.meta.dirname, '../../crafty/lib.ps1').replace(/'/g, "''")
  const r = run('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `. '${lib}'; [Console]::Out.Write((Get-KitSecret $env:KIT_SECRET_NAME))`], { encoding: 'utf8', timeout: 60000, env: { ...process.env, KIT_SECRET_NAME: m[1] } })
  if (r.status !== 0 || !r.stdout) throw new Error(`secret ${m[1]}: not resolved (${String(r.stderr || r.error || '').split('\n')[0].slice(0, 200)})`)
  return r.stdout
}
// the login of user `as` (users[as] = [login, password, totp seed]; a profile: its login, store secret, fields.tenant) -> the tenant
export async function login({ page, t, tenant, as }, h) {
  const L = t.webLogin, type = L.type || 'form', pf = (t.profiles || {})[as], pu = /^targets\/[^/]+\/([^/]+)\/password$/.exec(pf?.secret || '')
  const [user0, pass0, otp] = t.users?.[as] || (pu && t.users?.[pu[1]]) || [], user = pf?.login || user0
  if (!user) throw new Error(`no user "${as}" in this target`)
  const pass = resolveSecret(pf?.secret && !pu ? `secret:${pf.secret}` : pass0), code = otp && totp(resolveSecret(otp))
  if (pf?.fields?.tenant && !tenant) tenant = pf.fields.tenant
  const f = (s) => h.fill(s, user, pass, tenant).replace(/\{totp\}/g, code || '')
  if (type === 'storageState') { await h.applyState(page, JSON.parse(readFileSync(resolve(h.here, L.file), 'utf8'))); await h.nav(page, t.web + '/', 'networkidle2') }
  else if (type === 'script') await (await import(pathToFileURL(resolve(h.here, L.script)).href)).default({ page, user, pass, tenant, target: t, totp: code })
  else if (type === 'sso-steps' || type === 'form') {
    await h.nav(page, t.web + (L.path || '/'), 'networkidle2')
    if (!h.onLogin(page, t)) return tenant   // logged in: never log out
    if (type === 'sso-steps') for (const s of L.steps || []) await h.step(page, s, f)
    else {
      await h.step(page, { fill: L.fields }, f)
      if (L.rememberMeLabel) await page.evaluate((lb) => { const c = [...document.querySelectorAll('label')].find((e) => e.innerText.trim().toLowerCase() === lb.toLowerCase())?.querySelector('[type=checkbox]'); c?.checked || c?.click() }, L.rememberMeLabel)
      await h.step(page, { click: L.submit }, f)
    }
  } else throw new Error(`webLogin.type ${type}: form | sso-steps | script | storageState`)
  return tenant
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
// a target by name, as pokey.ps1 Resolve-PokeyTarget: an entry with its own URLs as is; a logins-only lane entry = the base
// target on that lane's ports, the entry's users / created / defaults over the base's (alone it opened about:blank)
export function resolveTarget(name, targets, lanes) {
  const own = targets[name]; if (own && (own.web || own.api)) return own
  const lt = laneTarget(name, targets, lanes); if (!lt) return own
  const t = { ...lt }; for (const k of ['defaultUser', 'defaultTenant']) if (own?.[k] != null) t[k] = own[k]
  for (const k of ['users', 'created']) t[k] = { ...lt[k], ...own?.[k] }
  return t
}
// userAuth.<as>.webLogin over webLogin: a login's own web login page and fields (a super admin's), as pokey.ps1 api for auth
export const webLoginOf = (t, as) => t.webLogin && { ...t.webLogin, ...t.userAuth?.[as]?.webLogin }
// registry (parity.json login): the web surface (browser.mjs login()) reads users, profiles and secret:<name> refs (resolveSecret)
export const ADAPTERS = { login: {} }
ADAPTERS['login']['web'] = { users: true, profiles: true, secretRefs: resolveSecret }
