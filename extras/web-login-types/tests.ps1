#Requires -Version 7
# tests.ps1 (extras web-login-types + browser-engines): totp, sso-steps over Playwright chromium, shared cookie, the firefox hint.
# Next to <kit>/tests/harness.ps1 with puppeteer-core linked in skills/qa-kit (as qa.tests.ps1 does); b.totp comes from adapters/web-login.mjs.
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $qk = Join-Path $k 'skills/qa-kit'; $BM = [Uri]::new((Join-Path $qk 'browser.mjs')).AbsoluteUri
  # fixture app + IdP: form, TOTP, relogin (Chrome); sso-steps, shared cookie (Playwright)
  $pwm = $env:KIT_PLAYWRIGHT ?? "$(& $py -c 'import os, playwright; print(os.path.dirname(playwright.__file__))' 2>$null)/driver/package"; $nopw = -not (Test-Path "$pwm/index.mjs")
  $res = NodeT auth @'
import http from 'node:http'
import { writeFileSync } from 'node:fs'
const [TF, PW] = process.argv.slice(2), U = { admin: ['qa', '', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'] }, F = { '#u': '{user}', '#c': '{totp}' }
let posts = 0, gen = 1
const form = (to) => `<html><form method="post" action="${to}"><input id="u" name="u"><input id="c" name="c"><button>Go</button>`
const app = http.createServer((q, s) => {
  const go = (l, c) => { s.writeHead(302, { location: l, ...(c && { 'set-cookie': `sid=${gen}; HttpOnly` }) }); s.end() }
  if (q.method === 'POST') { posts++; let d = ''; q.on('data', (x) => (d += x)); return q.on('end', () => (/u=qa&c=\d{6}/.test(d) ? go(web + '/', 1) : go(q.url))) }
  if (/^\/(login|idp)$/.test(q.url)) return s.end(form(q.url === '/idp' ? web + '/sso' : '/login'))
  if (q.headers.cookie === `sid=${gen}`) return s.end('<html>home')
  go(q.url === '/sso-app' ? web.replace('127.0.0.1', 'localhost') + '/idp' : '/login')
})
await new Promise((r) => app.listen(0, r))
const web = `http://127.0.0.1:${app.address().port}`, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ default: 'form', targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, browser: { engine: 'chromium' }, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const b = await import(BM + '?a'), home = async (s) => (await b.text(s.page)).includes('home'), out = async (k, f) => console.log(k + ':' + await f().catch((e) => e.message))
console.log('totp:' + ((await import(BM.replace('browser.mjs', 'adapters/web-login.mjs'))).totp(U.admin[2], 59000) === '287082'))
process.env.KIT_QA_TARGETS = 'x'; await out('pin', () => b.session({ target: 'form' }).then(() => false, (e) => /QA run's target/.test(e.message))); delete process.env.KIT_QA_TARGETS
await out('chrome', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
PW && (process.env.KIT_PLAYWRIGHT = PW)
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === 3; await s.done(); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@ "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
  foreach ($x in 'totp', 'pin', 'chrome', 'sso', 'shared', 'hint') { if ($nopw -and $x -in 'sso', 'shared', 'hint') { "SKIP browser.mjs login: $x (no Playwright)" } else { Expect "browser.mjs login: $x" (@($res) -contains "${x}:true") } }
Remove-TestKit $k
Complete-Tests
