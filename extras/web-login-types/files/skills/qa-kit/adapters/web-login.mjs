// web-login-types (extra): webLogin.type sso-steps (steps: goto, fill {sel: val}, click, wait sel|ms, waitUrl) | script (.mjs:
// default async ({ page, user, pass, tenant, target, totp })) | storageState (file: cookies, origins); {totp} from users[as][2].
// Imported by browser.mjs login() from adapters/; h = its helpers { nav, step, applyState, onLogin, fill, here }.
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