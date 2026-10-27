// media_grab.mjs (goody media-evidence): a public page's media in a throw-away headless browser (fresh profile, no login).
//   node media_grab.mjs <url> video [timeoutMs]              -> {"media": ["<m3u8 / mpd / mp4 url>", ...], "poster": "..."}
//   node media_grab.mjs <url> image <selector> <out file>    -> {"image": "<src>", "file": "<out file>", "bytes": n}
// Called by media_evidence.py (fetchers jam-public, image). Exit codes: 0 ok · 1 nothing found / page failed · 2 usage.
import puppeteer from 'puppeteer-core'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const [url, mode, a3, a4] = process.argv.slice(2)
if (!url || !['video', 'image'].includes(mode) || (mode === 'image' && (!a3 || !a4))) { console.error('usage: media_grab.mjs <url> video [timeoutMs] | <url> image <selector> <out file>'); process.exit(2) }
const PF = [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA].filter(Boolean)
const exe = [process.env.CHROME_PATH, ...PF.map((d) => `${d}/Google/Chrome/Application/chrome.exe`), ...PF.map((d) => `${d}/Microsoft/Edge/Application/msedge.exe`),
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find((p) => p && existsSync(p))
if (!exe) { console.log(JSON.stringify({ error: 'no Chrome/Edge found; set CHROME_PATH' })); process.exit(1) }
const MEDIA = /\.(m3u8|mpd)(\?|$)|\.(mp4|webm|mov)(\?|$)/i
const profile = mkdtempSync(join(tmpdir(), 'media-grab-'))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let browser, code = 0
try {
  browser = await puppeteer.launch({ executablePath: exe, headless: true, userDataDir: profile, args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required'] })
  const page = await browser.newPage(); await page.setViewport({ width: 1366, height: 768 })
  const seen = []
  page.on('request', (r) => { const u = r.url(); if (MEDIA.test(u) && !seen.includes(u)) seen.push(u) })
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
  if (mode === 'video') {
    const end = Date.now() + Number(a3 || 30000)
    while (Date.now() < end && !seen.some((u) => /\.(m3u8|mpd)/i.test(u))) {
      await page.evaluate(() => { for (const v of document.querySelectorAll('video')) { v.muted = true; v.play?.().catch(() => {}) } }).catch(() => {})
      await sleep(1000)
    }
    const src = await page.evaluate(() => [...document.querySelectorAll('video, video source')].map((v) => v.currentSrc || v.src).filter((s) => s && !s.startsWith('blob:'))).catch(() => [])
    const media = [...seen.filter((u) => /\.(m3u8|mpd)/i.test(u)).sort((a, b) => /m3u8/.test(b) - /m3u8/.test(a)), ...src, ...seen].filter((u, i, all) => all.indexOf(u) === i)
    console.log(JSON.stringify({ media })); if (!media.length) code = 1
  } else {
    await page.waitForSelector(a3, { timeout: 20000 })
    const src = await page.$eval(a3, (el) => el.currentSrc || el.src || '')
    const b64 = src ? await page.evaluate(async (s) => { const r = await fetch(s); const b = new Uint8Array(await r.arrayBuffer()); let x = ''; for (let i = 0; i < b.length; i += 32768) x += String.fromCharCode(...b.subarray(i, i + 32768)); return btoa(x) }, src).catch(() => '') : ''
    if (b64) { const buf = Buffer.from(b64, 'base64'); writeFileSync(a4, buf); console.log(JSON.stringify({ image: src, file: a4, bytes: buf.length })) }
    else { console.log(JSON.stringify({ image: src, error: 'image not downloadable' })); code = 1 }
  }
} catch (e) { console.log(JSON.stringify({ error: String(e.message || e).split('\n')[0] })); code = 1 }
finally { await browser?.close().catch(() => {}); try { rmSync(profile, { recursive: true, force: true }) } catch {} }
process.exit(code)
