// ui-checks.mjs: a module skills/pokey/browser.mjs imports, and a CLI. Usage: below. Exit codes: (CLI) 0 all variants PASS · 1 a FAIL · 2 usage.
// ui-checks.mjs: layout faults, contrast, hit tests for any web UI, selector-free, and the qa.matrix loop; browser.mjs re-exports them.
//   const b = await import('file:///<kit>/skills/pokey/browser.mjs'); await b.layoutIssues(s.page); await b.contrast(s.page, '.icon')
//   node <kit>/skills/pokey/adapters/ui-checks.mjs matrix --case A3 --script case.mjs --out <dir> [--task <id>] [--agent <id>]: the case at
//   every variant, n contexts at once; case.mjs: export default async ({ page, tag, viewport, locale, b, out }) => ({ result: 'PASS' })
// Sections: L8 checks · L82 matrix

// ---- checks: layout, contrast, hit test
// controls another element covers (hit test at the centre of the first line box), text boxes overlapping, text cut by an overflow
// hidden / clip box (its own, e.g. an ellipsis, or an ancestor's; scroll boxes only crop); ignore: selectors skipped (a carousel).
// -> { count, covered, overlaps, clipped } (each <= 30)
export async function layoutIssues(page, { scope = 'body', ignore = [] } = {}) {
  return page.evaluate((scope, ignore) => {
    const W = innerWidth, H = innerHeight, skip = (e) => ignore.some((x) => e.closest(x)), R = document.createRange()
    const lab = (e) => `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}${typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.') : ''} "${(e.innerText || e.getAttribute('aria-label') || '').trim().slice(0, 30)}"`
    const shown = (e) => { const c = getComputedStyle(e), r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && c.visibility !== 'hidden' && +c.opacity > 0 && !skip(e) }
    const view = (e, b) => {   // the visible part of box b of e, and whether a hidden / clip box cuts it
      let [l, t, r, d] = [Math.max(b.left, 0), Math.max(b.top, 0), Math.min(b.right, W), Math.min(b.bottom, H)], cut = false
      for (let p = e; p && p !== document.documentElement; p = p.parentElement) {
        const c = getComputedStyle(p); if (c.overflowX === 'visible' && c.overflowY === 'visible') continue
        const q = p.getBoundingClientRect()
        if (/hidden|clip/.test(c.overflowX + c.overflowY) && (b.right > q.right + 1 || b.bottom > q.bottom + 1 || b.left < q.left - 1 || b.top < q.top - 1)) cut = true
        l = Math.max(l, q.left); t = Math.max(t, q.top); r = Math.min(r, q.right); d = Math.min(d, q.bottom)
      }
      return r - l > 1 && d - t > 1 ? { box: { left: l, top: t, right: r, bottom: d }, cut } : null
    }
    const textBox = (e) => { const ns = [...e.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim()); if (!ns.length) return null
      const bs = ns.map((n) => { R.selectNodeContents(n); return R.getBoundingClientRect() })
      return { left: Math.min(...bs.map((b) => b.left)), top: Math.min(...bs.map((b) => b.top)), right: Math.max(...bs.map((b) => b.right)), bottom: Math.max(...bs.map((b) => b.bottom)) } }
    const els = [...(document.querySelector(scope) || document.body).querySelectorAll('*')].filter(shown), covered = [], overlaps = [], clipped = []
    for (const e of els.filter((x) => x.matches('a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=tab]'))) {
      const v = view(e, e.getClientRects()[0] || e.getBoundingClientRect()); if (!v) continue   // a wrapped link: its first line
      const hit = document.elementFromPoint((v.box.left + v.box.right) / 2, (v.box.top + v.box.bottom) / 2)
      if (hit && !e.contains(hit) && !hit.contains(e) && !skip(hit)) covered.push({ el: lab(e), by: lab(hit) })
    }
    const texts = els.map((e) => { const b = textBox(e), v = b && view(e, b); return v && [e, v.box, v.cut] }).filter(Boolean).slice(0, 1500)
    texts.forEach(([e, , cut]) => cut && clipped.push(lab(e)))
    for (let i = 0; i < texts.length; i++) for (let j = i + 1; j < texts.length; j++) {
      const [a, p] = texts[i], [b, q] = texts[j]
      if (Math.min(p.right, q.right) - Math.max(p.left, q.left) > 2 && Math.min(p.bottom, q.bottom) - Math.max(p.top, q.top) > 2 && !a.contains(b) && !b.contains(a)) overlaps.push({ a: lab(a), b: lab(b) })
    }
    return { count: covered.length + overlaps.length + clipped.length, covered: covered.slice(0, 30), overlaps: overlaps.slice(0, 30), clipped: clipped.slice(0, 30) }
  }, scope, ignore)
}
// WCAG contrast of the element's text (no text: its SVG fill / stroke, else colour) on the backgrounds behind it; min 4.5 text, 3
// non-text (WCAG 1.4.3 / 1.4.11); approx: an image, gradient or opacity behind it (check the shot); a colour other than rgb() /
// rgba(): ratio null, pass false. -> { ratio, min, pass, fg, bg, approx, note? }
export async function contrast(page, selector, { min = null } = {}) {
  const r = await page.$eval(selector, (e) => {
    const rgba = (s) => { const n = (String(s).match(/[\d.]+/g) || []).map(Number); return /^rgba?\(/.test(s) && n.length >= 3 ? [n[0], n[1], n[2], n[3] ?? 1] : null }
    const over = (f, b) => f.slice(0, 3).map((x, i) => x * f[3] + b[i] * (1 - f[3]))
    const text = [...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())
    const g = text ? e : [e, ...e.querySelectorAll('path,circle,rect,polygon,ellipse,line,use')].find((x) => x instanceof SVGElement) || e, gc = getComputedStyle(g)
    const fg = (!text && g instanceof SVGElement && [gc.fill, gc.stroke].map(rgba).find((x) => x && x[3] > 0)) || rgba(getComputedStyle(e).color)
    const layers = []; let approx = false
    if (!fg) return { ratio: null, text, approx: true, note: 'unsupported colour: ' + getComputedStyle(e).color }
    for (let p = e; p; p = p.parentElement) { const c = getComputedStyle(p), b = rgba(c.backgroundColor); if (c.backgroundImage !== 'none' || +c.opacity < 1) approx = true
      if (b && b[3] > 0) { layers.push(b); if (b[3] >= 1) break } }
    const bg = layers.reverse().reduce((acc, l) => over(l, acc), [255, 255, 255]), f = over(fg, bg)
    const lum = (c) => c.map((v) => (v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4).reduce((s, v, i) => s + v * [0.2126, 0.7152, 0.0722][i], 0)
    const [hi, lo] = [lum(f), lum(bg)].sort((x, y) => y - x)
    return { ratio: Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100, text, fg: f.map(Math.round), bg: bg.map(Math.round), approx }
  })
  const m = min ?? (r.text ? 4.5 : 3)
  return { ...r, min: m, pass: r.ratio != null && r.ratio >= m }
}

// hitTest(page, [selector | { text }]): each control a change touches is shown and on top at its centre (elementFromPoint), as a
// tester clicks it (crafty testing.md "Proof"). -> { pass, rows: [{ target, ok, by }] } (by: what covers it, 'not found', 'off screen')
export async function hitTest(page, targets) {
  const rows = await page.evaluate((ts) => ts.map((t) => {
    const own = (x) => [...x.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim() === t.text)
    const e = typeof t === 'string' ? document.querySelector(t) : [...document.querySelectorAll('body *')].find(own)
    if (!e) return { target: t, ok: false, by: 'not found' }
    e.scrollIntoView({ block: 'center', inline: 'center' }); const r = e.getBoundingClientRect(), h = r.width > 0 && r.height > 0 ? document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) : null
    const ok = !!h && (h === e || e.contains(h) || h.contains(e))
    return { target: t, ok, by: ok ? '' : h ? `${h.tagName.toLowerCase()}${h.id ? '#' + h.id : ''}` : 'off screen' }
  }), [].concat(targets))
  return { pass: rows.length > 0 && rows.every((x) => x.ok), rows }
}

// ---- matrix: qa.matrix variants, serial on s.page or a browser context each (parallel), the case CLI
const dims = (v) => { const [width, height] = String(v).split('x').map(Number); if (!(width > 0 && height > 0)) throw new Error(`qa.matrix.viewports "${v}" is not <width>x<height>, e.g. 1280x720: fix kit.local.json`); return { width, height } }
export function variants(m) {   // the axes' product; an empty axis = off
  const ax = (k) => (m[k]?.length ? m[k] : [null]), out = []
  for (const viewport of ax('viewports')) for (const fontScale of ax('fontScales')) for (const theme of ax('themes')) for (const locale of ax('locales')) {
    if (viewport) dims(viewport)
    out.push({ viewport, fontScale, theme, locale, tag: [viewport, fontScale != null && 'f' + fontScale, theme, locale].filter(Boolean).map((x) => String(x).toLowerCase().replace(/[^a-z0-9.]+/g, '-')).join('_') })
  }
  return out
}
// a context of s's browser: own viewport, locale, colour scheme, storage (s.page's login copied), its tab registered (browser.mjs openTab)
// s.page's login once per run, over CDP (no page script): cookies, web storage
async function seedOf(s) {
  if (s.page.__pw) return null
  const cdp = await s.page.createCDPSession(), o = /^https?:/.test(s.page.url()) ? new URL(s.page.url()).origin : ''
  const items = async (isLocalStorage) => (o ? (await cdp.send('DOMStorage.getDOMStorageItems', { storageId: { securityOrigin: o, isLocalStorage } }).catch(() => ({ entries: [] }))).entries : [])
  try { await cdp.send('DOMStorage.enable').catch(() => {}); return { cookies: (await cdp.send('Network.getAllCookies')).cookies, st: { o, l: await items(true), ss: await items(false) } } } finally { await cdp.detach().catch(() => {}) }
}
async function variantPage(s, v, seed) {
  const vp = v.viewport && dims(v.viewport), scheme = /^(light|dark)$/i.test(v.theme || '') ? v.theme.toLowerCase() : null, url = s.page.url()
  let page, close
  if (s.page.__pw) {
    const ctx = await s.browser.newContext({ ...(vp && { viewport: vp }), ...(v.locale && { locale: v.locale }), ...(scheme && { colorScheme: scheme }), storageState: await s.page.context().storageState() })
    page = (await import('./engine-playwright.mjs')).wrapPage(ctx, await ctx.newPage()); close = () => ctx.close()
  } else {
    const b = await import('../browser.mjs'), ctx = await s.browser.createBrowserContext(), { cookies, st } = seed
    page = await b.openTab(s.browser, s.key, { agent: s.page.__qa?.agent, ctx }); close = async () => { await b.closeTab(page, s.key); await ctx.close().catch(() => {}) }
    if (vp) await page.setViewport({ ...(s.page.viewport() || {}), ...vp })
    if (cookies.length) await page.setCookie(...cookies.map(({ name, value, domain, path, expires, httpOnly, secure, sameSite }) => ({ name, value, domain, path, expires, httpOnly, secure, sameSite })))
    if (st) await page.evaluateOnNewDocument((st) => { if (location.origin === st.o && !sessionStorage.getItem('qa-seeded')) { for (const [k, x] of st.l) localStorage.setItem(k, x); for (const [k, x] of st.ss) sessionStorage.setItem(k, x); sessionStorage.setItem('qa-seeded', '1') } }, st)
    if (v.locale) { await page.setExtraHTTPHeaders({ 'Accept-Language': v.locale }); await page.evaluateOnNewDocument((l) => { Object.defineProperty(navigator, 'language', { get: () => l }); Object.defineProperty(navigator, 'languages', { get: () => [l] }) }, v.locale) }
    if (scheme) await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
  }
  page.__qa = s.page.__qa
  if (/^https?:/.test(url)) await page.goto(url, { waitUntil: 'networkidle2', timeout: 90000 }).catch(() => {})
  return { page, close }
}
// browser.mjs matrix(): fn per variant (m = qa.matrix); parallel <= 1: on s.page in turn, its viewport restored after; parallel n:
// n variants at once, each in its own context (fn gets its page: use v.page, never s.page); a throw is that variant's FAIL
export async function matrix(s, fn, m, { parallel = 1 } = {}) {
  const vs = variants(m), out = new Array(vs.length), v0 = s.page.viewport?.(), own = vs.some((v) => v.locale || /^(light|dark)$/i.test(v.theme || ''))
  if (own && !s.browser) throw new Error('matrix: a locale or light / dark theme variant needs a context of its own: pass a browser.mjs session')
  if (parallel <= 1 && !own || !s.browser) {   // s.page in turn; a locale / scheme: contexts, one at a time at least
    try { for (const [i, v] of vs.entries()) { if (v.viewport) await s.page.setViewport({ ...(v0 || {}), ...dims(v.viewport) }); out[i] = { variant: v.tag, result: await fn({ ...v, page: s.page }) } } } finally { if (v0) await s.page.setViewport(v0) }
    return out
  }
  let next = 0; const seed = await seedOf(s)
  const work = async () => { for (let i; (i = next++) < vs.length;) {
    const v = vs[i], t0 = Date.now(); let ctx = null
    try { ctx = await variantPage(s, v, seed); out[i] = { variant: v.tag, result: await fn({ ...v, page: ctx.page }) } } catch (e) { out[i] = { variant: v.tag, result: { result: 'FAIL', error: String(e.message || e).slice(0, 300) } } } finally { await ctx?.close().catch(() => {}) }
    out[i].ms = Date.now() - t0 } }
  await Promise.all(Array.from({ length: Math.min(parallel, vs.length) }, work))
  return out
}
const qaCfg = async () => { const b = await import('../browser.mjs'), { readFileSync } = await import('node:fs'); try { return JSON.parse(readFileSync(b.localFile('skills/crafty/kit.local.json'), 'utf8')).qa || {} } catch { return {} } }
// browser.mjs testerScreen(s, fn, { mobile }): fn at qa.testerViewport (web 1366x768, mobile 390x844)
export async function testerScreen(s, fn, { mobile = false } = {}) { const v = { web: '1366x768', mobile: '390x844', ...(await qaCfg()).testerViewport }; return matrix(s, fn, { viewports: [v[mobile ? 'mobile' : 'web']] }) }
export const passed = (r) => r === true || /^pass/i.test(String(r?.result ?? r))
// the AI doc's "Matrix:" line (devtools.py case_gaps reads it); a reduced set names its reason (proof.py matrix-scope)
export const matrixLine = (rows, sc) => `Matrix: ${rows.map((x) => x.variant || 'default').join(', ')}${sc?.scope === 'reduced' ? ` (reduced: ${sc.reason})` : ''}`

// CLI: one case x every variant it needs, concurrently in one browser; exit 0 all PASS · 1 a FAIL · 2 usage
if (process.argv[2] === 'matrix' && (await import('node:path')).resolve(process.argv[1] || '') === (await import('node:url')).fileURLToPath(import.meta.url)) {
  const { mkdirSync, readFileSync, writeFileSync } = await import('node:fs'), { join, resolve } = await import('node:path'), { pathToFileURL } = await import('node:url')
  const arg = (k) => { const i = process.argv.indexOf('--' + k); return i > 2 ? process.argv[i + 1] : '' }
  if (!arg('case') || !arg('script') || !arg('out')) { console.error('usage: node ui-checks.mjs matrix --case <id> --script <case.mjs> --out <dir> [--task <id>] [--agent <id>] [--target <t>] [--tenant <x>] [--as <user>] [--path </screen>] [--parallel <n>]'); process.exit(2) }
  if (arg('agent')) process.env.CLAUDE_AGENT = arg('agent')
  const b = await import('../browser.mjs'), cfg = await qaCfg()
  // the variants: the task's recorded scope (devtools.py matrix-scope <task> --dir <wt>), else the full qa.matrix
  const sc = arg('task') ? (() => { try { return JSON.parse(readFileSync(join(b.kitPath('tasks'), arg('task').replace(/[^\w.-]/g, '_') + '.json'), 'utf8')).cases?.matrixScope } catch { return null } })() : { scope: 'full', matrix: cfg.matrix || {} }
  if (!sc?.matrix) { console.error(`matrix: task ${arg('task')} has no recorded scope: python -X utf8 <kit>/skills/crafty/devtools.py matrix-scope ${arg('task')} --dir <worktree>, then again`); process.exit(2) }
  const out = resolve(arg('out')), fn = (await import(pathToFileURL(resolve(arg('script'))).href)).default, t0 = Date.now()
  mkdirSync(out, { recursive: true })
  const s = await b.session({ target: arg('target') || undefined, tenant: arg('tenant') || undefined, as: arg('as') || undefined })
  let rows
  try { if (arg('path')) await b.go(s.page, arg('path')); rows = await matrix(s, (v) => fn({ ...v, b, out, case: arg('case') }), sc.matrix, { parallel: Number(arg('parallel')) || cfg.matrixRun?.parallel || 4 }) } finally { await s.done() }
  const line = matrixLine(rows, sc), fails = rows.filter((x) => !passed(x.result))
  writeFileSync(join(out, `${arg('case')}-matrix.json`), JSON.stringify({ case: arg('case'), scope: sc.scope, reason: sc.reason || '', ms: Date.now() - t0, rows, line }, null, 1))
  for (const x of rows) console.log(`${passed(x.result) ? 'PASS' : 'FAIL'} ${arg('case')} ${x.variant} ${x.ms ?? ''} ms ${JSON.stringify(x.result).slice(0, 160)}`)
  console.log(line); process.exit(fails.length ? 1 : 0)
}
