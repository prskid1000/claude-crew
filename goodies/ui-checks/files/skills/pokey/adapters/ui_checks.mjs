// ui_checks.mjs (goody ui-checks): layout faults and contrast for any web UI, selector-free; browser.mjs re-exports both.
//   const b = await import('file:///<kit>/skills/pokey/browser.mjs'); await b.layoutIssues(s.page); await b.contrast(s.page, '.icon')

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
