#Requires -Version 7
# tests.ps1 (goodies web-login-types + browser-engines): totp, sso-steps over Playwright chromium, shared cookie, the firefox hint.
# Next to <kit>/tests/harness.ps1 (browser.mjs, its login fixture app; pin and plain form login: core tests); b.totp comes from adapters/web-login.mjs.
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $qk = Join-Path $k 'skills/pokey'
if (Use-BrowserKit) {
  # TOTP form login, relogin (Chrome); sso-steps, shared cookie (Playwright)
  $pwm = $env:KIT_PLAYWRIGHT ?? "$(& $py -c 'import os, playwright; print(os.path.dirname(playwright.__file__))' 2>$null)/driver/package"; $eng = Join-Path $src 'skills/pokey/adapters/engine-playwright.mjs'   # sso / shared / hint need browser-engines too
  $nopw = -not (Test-Path "$pwm/index.mjs") -or -not (Test-Path $eng); if (-not $nopw) { Copy-Item $eng "$qk/adapters" }
  $res = NodeT auth ($LoginApp + @'
const [TF, PW] = process.argv.slice(2), F = { '#u': '{user}', '#c': '{totp}' }, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ default: 'form', targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, browser: { engine: 'chromium' }, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const { b, home, out } = await login()
console.log('totp:' + ((await import(BM.replace('browser.mjs', 'adapters/web-login.mjs'))).totp(U.admin[2], 59000) === '287082'))
await out('totp-login', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
PW && (process.env.KIT_PLAYWRIGHT = PW)
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === 3; await s.done(); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@) "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
  foreach ($x in 'totp', 'totp-login', 'sso', 'shared', 'hint') { if ($nopw -and $x -in 'sso', 'shared', 'hint') { "SKIP browser.mjs login: $x (no Playwright or no goody browser-engines)" } else { Expect "browser.mjs login: $x" (@($res) -contains "${x}:true") } }
} else { 'SKIP browser.mjs (no puppeteer-core in skills/pokey)' }
Remove-TestKit $k
Complete-Tests
