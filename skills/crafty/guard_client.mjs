// guard_client.mjs: the PreToolUse hook (settings.json): hands the hook input to the warm guard_server.ps1 over a named pipe
// (~0.1 s, no pwsh start); no server, busy, a reload or any error -> this call runs crafty.ps1 guard as before (same answer),
// and a server is started for the next call. Usage: node <kit>/skills/crafty/guard_client.mjs < hook input. Exit codes: the guard's
// (0 its answer · 2 blocked); a guard crash (any other exit, non-JSON stdout, no pwsh, node error) = 2, fail-closed (K67), logged as
// guard event crash; no answer before the hook timeout = let through, logged as event timeout. KIT_GUARD_TIMEOUT_MS: tests only.
// Not caught here: node missing or this file broken (the hook exits 1 / 127: pre-commit runs node --check on it).
// KIT_GUARD_WARM=0: always the plain pwsh path. KIT_GUARD_BYPASS=1 (owner only, while the guard is fixed): a crash lets the call through.
// Sections: L25 crash · L56 plain · L96 warm · L121 context · L190 idle
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { appendFileSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import net from 'node:net'
import { dirname, join, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const t0 = Date.now(), here = dirname(fileURLToPath(import.meta.url)), kit = resolve(here, '..', '..')
const name = 'kit-guard-' + createHash('sha1').update(kit.toLowerCase()).digest('hex').slice(0, 12).toUpperCase()
const pipe = process.platform === 'win32' ? `\\\\.\\pipe\\${name}` : join(tmpdir(), `CoreFxPipe_${name}`)   // arch-ok: .NET's own pipe path on Unix (NamedPipeServerStream)
let dying = false
process.on('uncaughtException', (e) => crashed('node', (e && e.stack) || e))   // node's own exit 1 would fail open
const input = readFileSync(0, 'utf8')
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(CLAUDE|KIT)_|^(TEMP|TMP)$/i.test(k)))

// ---- crash: block (exit 2, the reason to the agent) or, under KIT_GUARD_BYPASS=1, allow; both logged for supervise
// guard.jsonl in Write-KitLog's line shape (pwsh is broken, absent or not asked here); a write error never blocks
function guardLog() {
  const map = JSON.parse(readFileSync(join(here, 'kit.example.json'), 'utf8'))._paths, d = new Date(), p = (n) => `${n}`.padStart(2, '0')
  return join(kit, map.stateDir, map.durable.audit, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`, 'guard.jsonl')
}
function logLine(fields) {
  try {
    const d = new Date(), p = (n) => `${n}`.padStart(2, '0'), off = -d.getTimezoneOffset(), file = guardLog()
    const at = new Date(d.getTime() + off * 60000).toISOString().slice(0, -1) + (off < 0 ? '-' : '+') + p(Math.floor(Math.abs(off) / 60)) + ':' + p(Math.abs(off) % 60)   // local, as Write-KitLog
    mkdirSync(dirname(file), { recursive: true }); appendFileSync(file, JSON.stringify({ at, run: process.env.KIT_RUN || '', agent: process.env.KIT_AGENT || '', script: 'guard_client.mjs', verb: 'guard', ...fields }) + '\n')
  } catch { }
}
function crashed(rc, err, event = 'crash') {
  if (dying) process.exit(2); dying = true   // an error in here: still blocked, never a loop
  let inp = ''; try { inp = `${input}` } catch { }   // unset when stdin itself failed
  let key = inp; try { const j = JSON.parse(inp); key = JSON.stringify([j.tool_name, j.tool_input, j.cwd]) } catch { }   // the call, not its per-call ids
  const h = createHash('sha1').update(key).digest('hex').slice(0, 12)
  const why = `${err || ''}`.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\s+/g, ' ').trim()
    .replace(/(bearer|basic|token|passw\w*|secret|api[-_]?key|authoriz\w*|cookie)[^\s=:]*(?:\s*[=:]\s*|\s+)(?:(?:bearer|basic)\s+)?[^\s;]+(?:;\s*[^\s;]+)*;?/gi, '$1 [redacted]').slice(0, 160)   // Write-KitLog masks; this line skips it
  let tool = '', session = '', bypass = process.env.KIT_GUARD_BYPASS === '1' || event === 'timeout'
  try { const j = JSON.parse(inp); tool = `${j.tool_name || ''}`; session = `${j.session_id || ''}` } catch { }
  if (event === 'timeout') { let seen = ''; try { seen = readFileSync(guardLog(), 'utf8') } catch { }; if (seen.includes(`"in":"${h}"`)) { event = 'crash'; bypass = process.env.KIT_GUARD_BYPASS === '1' } }   // the same input slow again: a hang, not load
  logLine({ event, session, tool, in: h, rc, letThrough: bypass, why })
  const what = `kit guard crashed (rc ${rc}${why ? `: ${why}` : ''})`
  if (event === 'timeout') process.exit(0)
  if (bypass) { process.stdout.write(JSON.stringify({ systemMessage: `${what}; KIT_GUARD_BYPASS=1 let this call through unguarded` }) + '\n'); process.exit(0) }
  process.stderr.write(`${what}: call blocked (fail-closed). Tell the coordinator: a kitty fixes skills/crafty in a worktree; the owner alone may set KIT_GUARD_BYPASS=1 for the session meanwhile.\n`)
  process.exit(2)
}

// ---- plain: a deny is exit 0 + JSON (other stdout would read as plain text and allow the call); one pwsh per call
// guard_server.ps1 marks a failed load with the crafty.ps1 + lib.ps1 mtimes; true while both are unchanged (±1 ms) and the mark
// is under 5 min old (a cause elsewhere, e.g. an adapter, gets a retry)
function noload() {
  try {
    const map = JSON.parse(readFileSync(join(here, 'kit.example.json'), 'utf8'))._paths, mk = join(kit, map.runtimeDir, map.runtime.cache, `${name}.noload`)
    if (statSync(mk).mtimeMs < Date.now() - 300000) return false
    const mark = readFileSync(mk, 'utf8').trim().split(',').map(Number)
    return ['crafty.ps1', 'lib.ps1'].every((f, i) => Math.abs(statSync(join(here, f)).mtimeMs - mark[i]) <= 1)
  } catch { return false }
}
function answer(s) { s = `${s || ''}`.trim(); if (!s) return true; try { const o = JSON.parse(s); return !!o && typeof o === 'object' } catch { return false } }

function plain(start) {
  // Windows: node's children die with it (its job object): WMI starts the server outside it, while the plain call runs
  const srv = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'guard_server.ps1'), '-Pipe', name]
  let starter = null
  if (start && noload()) start = false   // a crafty.ps1 that did not load: no server per call until it changes (K67r)
  if (start && process.env.KIT_GUARD_WARM !== '0') {
    try {
      if (process.platform !== 'win32') spawn('pwsh', srv, { detached: true, stdio: 'ignore', windowsHide: true }).unref()
      else {
        const cl = ['pwsh', '-WindowStyle', 'Hidden', ...srv].map((x) => (/\s/.test(x) ? `"${x}"` : x)).join(' ').replace(/'/g, "''")
        starter = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `$si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }; $null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '${cl}'; ProcessStartupInformation = $si }`], { stdio: 'ignore', windowsHide: true })
      }
    } catch { }
  }
  // ends before the hook's 10 s (Claude Code would let the call through unlogged); slow is not a crash: a loaded machine passes, logged
  const ms = Number(process.env.KIT_GUARD_TIMEOUT_MS) || Math.max(1500, 9300 - (Date.now() - t0))
  const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'crafty.ps1'), 'guard'], { input, encoding: 'utf8', windowsHide: true, timeout: ms, killSignal: 'SIGKILL' })
  const end = () => {
    if (r.error && r.error.code === 'ETIMEDOUT') return crashed('timeout', `no answer in ${ms} ms`, 'timeout')
    if (r.error || (r.status !== 0 && r.status !== 2) || (r.status === 0 && !answer(r.stdout))) return crashed(r.error ? r.error.code || 'spawn' : r.status ?? r.signal, r.error ? r.error.message : r.stderr || r.stdout)
    process.stdout.write(r.stdout || ''); process.stderr.write(r.stderr || ''); process.exit(r.status)
  }
  // the starter dies with this process: it gets what is left of the hook's 10 s since node started (a fixed 3 s killed it under
  // load: no server ever, K96)
  if (starter && starter.exitCode === null) { starter.on('exit', end); setTimeout(end, Math.max(0, (Number(process.env.KIT_GUARD_TIMEOUT_MS) || 8500) - process.uptime() * 1000)) } else end()
}

// ---- warm: ask the guard_server.ps1 pipe; busy, absent or odd -> the plain path
// a config key as lib.ps1 Get-KitParam: KIT_PARAM_<KEY>, a kit.local.json pin, else the registry default (no browser.mjs import: hot path)
function kitParam(key) {
  const env = +process.env['KIT_PARAM_' + key.replace(/\W/g, '_').toUpperCase()], json = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return {} } }
  const pin = key.split('.').reduce((o, k) => o?.[k], json(join(here, 'kit.local.json')))
  return env || (typeof pin === 'number' ? pin : +(/default=([\d.]+)/.exec(json(join(kit, 'skills', 'bossy', 'params.registry.json')).params?.[key] || '') || [])[1] || 0)
}
function ask(tries) {
  let buf = '', done = false
  const c = net.connect(pipe)
  const fail = (noServer) => { if (done) return; done = true; c.destroy(); if (tries > 0) setTimeout(() => ask(tries - 1), kitParam('guard.clientRetryMs')); else plain(noServer) }   // busy or between two calls: retry
  c.setTimeout(3000, () => { if (!done) { done = true; c.destroy(); plain(false) } })   // a slow server: this call the plain way (hook timeout 10 s)
  c.on('error', (e) => fail(e.code === 'ENOENT'))   // still no server after the retries: start one
  c.on('connect', () => c.write(JSON.stringify({ env, input }) + '\n'))
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return
    done = true; c.end()
    let r; try { r = JSON.parse(buf.slice(0, nl)) } catch { return plain(false) }
    if (r.reload || typeof r.code !== 'number') return plain(true)
    if ((r.code !== 0 && r.code !== 2) || (r.code === 0 && !answer(r.out))) return plain(false)   // the plain path decides what a crash is
    if (r.out) process.stdout.write(r.out + '\n')
    process.exit(r.code)
  })
}

// ---- context: Read and SQL calls answered here, never by pwsh (owner 2026-11-22: big whole-file Reads and wide SQL results filled
// agents' context): a Read (whole file or one offset / limit range) of a text file over guard.readMaxLines lines or guard.readMaxKB; a SELECT * over 10 rows or a row
// SELECT without LIMIT <= guard.sqlMaxRows (aggregates, SHOW, DESCRIBE, EXPLAIN pass). Pins: kit.local.json guard.<key>. Denies go to guard.jsonl.
function param(key) {
  let v; try { v = key.split('.').reduce((o, k) => o?.[k], JSON.parse(readFileSync(join(here, 'kit.local.json'), 'utf8'))) } catch { }
  if (typeof v === 'number') return v
  try { return Number(/default=([\d.]+)/.exec(JSON.parse(readFileSync(join(kit, 'skills', 'bossy', 'params.registry.json'), 'utf8')).params[key])[1]) } catch { return 0 }
}
// a deny here is logged like crafty.ps1 guard's (bossy.ps1 audit, supervise WATCH); test runs (no session_id) are not
let hookIn = null
function deny(why) {
  const ti = hookIn?.tool_input || {}, cmd = `${ti.file_path ?? ti.query ?? ti.sql ?? ti.statement ?? ti.command ?? (ti.timeout_ms != null ? `timeout_ms ${ti.timeout_ms}` : '')}`.replace(/[\r\n\t]+/g, ' // ').slice(0, 2000)
  if (hookIn?.session_id) logLine({ event: 'deny', session: `${hookIn.session_id}`, agentId: `${hookIn.agent_id || ''}`, tool: `${hookIn.tool_name || ''}`, why, cmd })
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } }) + '\n'); process.exit(0) }
// a screenshot costs ~2k tokens per read (owner 2026-11-27: 14 per test session, 1.3 of them re-reads): its browser.viewScale copy
// first, never the same unchanged image twice in one agent's session; Read limit: 1 = the full image on purpose (small text, after a compaction)
function imageRule(f, who) {
  let cache; try { const map = JSON.parse(readFileSync(join(here, 'kit.example.json'), 'utf8'))._paths; cache = join(kit, map.runtimeDir, map.runtime.cache) } catch { return }
  let mt; try { mt = statSync(f).mtimeMs } catch { return }
  const view = join(cache, 'shot-view', `${createHash('sha1').update(resolve(f).toLowerCase()).digest('hex').slice(0, 10)}-${f.replace(/^.*[\\/]/, '').replace(/\.\w+$/, '')}.jpg`)   // ui-checks.mjs viewCopy: same key
  if (resolve(f).toLowerCase() !== view.toLowerCase()) { try { if (statSync(view).mtimeMs >= mt - 5000) deny(`kit guard: read the smaller copy ${view} (same screen at browser.viewScale, ~40% fewer image tokens); the full image (small text): Read ${f} with limit: 1`) } catch { } }
  if (!who) return
  const log = join(cache, 'guard-reads', `${who.replace(/[^\w.-]/g, '_')}.txt`), key = `${resolve(f).toLowerCase()}|${Math.round(mt)}`
  let seen = ''; try { seen = readFileSync(log, 'utf8') } catch { }
  if (!seen) for (const d of ['guard-reads', 'shot-view']) try { for (const x of readdirSync(join(cache, d))) { const fx = join(cache, d, x); if (statSync(fx).mtimeMs < Date.now() - 172800000) unlinkSync(fx) } } catch { }   // a new session prunes both: 48 h
  if (seen.split('\n').includes(key)) deny(`kit guard: you already read ${f} in this session (unchanged; its image is in your context): use what you saw or noted; to look again (after a compaction, a detail): Read it with limit: 1`)
  try { mkdirSync(dirname(log), { recursive: true }); appendFileSync(log, key + '\n') } catch { }
}
// rule secrets: the same text as adapters/guard-localenv.ps1 (a command that reads the store)
const SECRET_WAYS = "Instead: names + tenants: pokey.ps1 user list -Target <t> · a call: pokey.ps1 api -Target <t> -As <login> -Method GET -Path '/...' · a browser: session({ target, as }) · an app: pokey.ps1 ui login -Target <t> -As <login> · none fits: pokey.ps1 user create -Target <t> -Name <login> -Role <role> · keys: kitbag.py audit config"
function readRule(ti, who = '') {
  const f = `${ti.file_path || ''}`
  // the test logins: Claude Code's settings.json deny covers its Read; this one covers every CLI's own file view (README "Install")
  if (/(^|[\\/])skills[\\/]pokey[\\/]targets\.local\.json$/i.test(f)) deny(`kit guard: ${f} holds test logins and secrets (secrets.store): never read or print it. ${SECRET_WAYS}`)
  if (f && /\.(png|jpe?g|webp)$/i.test(f) && ti.limit == null) imageRule(f, who)
  if (!f || ti.pages || /\.(png|jpe?g|gif|webp|bmp|ico|svg|pdf|ipynb)$/i.test(f)) return
  const maxL = param('guard.readMaxLines'), maxKB = param('guard.readMaxKB'); let kb = 0, lines = 0
  const ranged = ti.offset != null || ti.limit != null, from = Math.max(1, Number(ti.offset) || 1), upto = from + (ti.limit != null ? Number(ti.limit) || 0 : 2000)   // no limit: the Read tool's 2000 lines
  // a kit script is run, not read (owner 2026-11-26): its head says how; the live kit's only (a kit worktree's copy is kitty's and revy's work)
  if (!ranged && resolve(f).toLowerCase().startsWith(kit.toLowerCase() + sep) && /^(skills|workflows|scripts)[\\/](?!.*node_modules[\\/]).*\.(ps1|py|m?js)$/i.test(resolve(f).slice(kit.length + 1))) {
    const cap = param('guard.kitScriptLines'); let n = 0; try { for (const b of readFileSync(f)) if (b === 10) n++ } catch { return }
    if (cap && n > cap) deny(`kit guard: ${f} is a kit script (${n} lines): run it, never read it whole: its top 40 lines (Read limit 40) hold the usage, the verbs and the Sections: map; then only the section you need (offset / limit)`) }
  try { const st = statSync(f); if (!st.isFile()) return
    if (!ranged) { kb = Math.round(st.size / 1024); if (!(maxKB && kb > maxKB)) for (const b of readFileSync(f)) if (b === 10) lines++ }   // size first: a huge log is never read here
    else if (st.size <= 16 * 1024 * 1024) { let n = 1, by = 0, lb = 0; for (const b of readFileSync(f)) { if (n >= from) { lb++; if (b === 10) { lines++; by += Math.min(lb, 2000); lb = 0 } } if (b === 10 && ++n >= upto) break }
      kb = Math.round((by + Math.min(lb, 2000)) / 1024) }   // a range (offset 1, limit 700 passed the cap): its own lines and bytes (the tool cuts a line at 2000)
    else lines = upto - from } catch { return }
  if ((maxL && lines > maxL) || (maxKB && kb > maxKB)) deny(`kit guard: ${f}${ranged ? ` lines ${from}-${from + lines - 1}` : ''} is ${lines} lines / ${kb} KB (cap ${maxL} lines / ${maxKB} KB, AGENTS.md "File inspection"): read its section map (top 40 lines; a .md: Grep '^#' for its headings) then the range you need (offset / limit); note what you need from it once (your crafty.ps1 dir notes)`)
}
function sqlRule(ti) {
  const q0 = `${ti.query || ti.sql || ti.statement || ''}`; if (!q0.trim()) return
  const q1 = q0.replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`[^`]*`/g, 'x').replace(/--[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\//g, ' ').trim()
  if (!/^\(?\s*(select|with)\b/i.test(q1)) return
  // the top level only (subqueries, CTE bodies and EXISTS (SELECT * ...) return no rows to the agent): m = the query, paren bodies blanked (same length)
  const blank = (t) => { let d = 0, o = ''; for (const ch of t) { if (ch === ')') d--; o += d > 0 ? ' ' : ch; if (ch === '(') d++ } return o }
  let base = q1, m = blank(base); if (!m.replace(/[()\s;]/g, '')) { base = q1.replace(/^\(\s*|\s*\)\s*;?\s*$/g, ''); m = blank(base) }   // the whole query in parens
  const q = m.replace(/\(\s*\)/g, '()'), max = param('guard.sqlMaxRows')
  const lim = /\blimit\s+(?:\d+\s*,\s*)?(\d+)\s*(?:offset\s+\d+\s*)?(?:for\s+update\s*|lock\s+in\s+share\s+mode\s*)?;?\s*$/i.exec(q)
  // a look at a few whole rows is fine (audit 2026-11-27: SELECT * ... LIMIT 5 was denied)
  if (/\bselect\s+(?:distinct\s+)?(?:[\w]+\.)?\*/i.test(q) && !(lim && Number(lim[1]) <= SQL_STAR_ROWS)) deny(`kit guard: SELECT * pulls every column into your context: name the columns you need (DESCRIBE <table> first), or look at a few rows with LIMIT <= ${SQL_STAR_ROWS}`)
  if (lim) { if (max && Number(lim[1]) > max) deny(`kit guard: LIMIT ${lim[1]} is over ${max} rows (guard.sqlMaxRows): aggregate (COUNT, GROUP BY) or page with a smaller LIMIT`); return }
  const sel = [...m.matchAll(/\bselect\s+(?:distinct\s+)?([\s\S]*?)\bfrom\b/dgi)].pop(); if (!sel) return   // no FROM: one row
  // every item an aggregate, wrapped or aliased (COUNT(*) c, DATE(MIN(x)) d1), and no GROUP BY: one row
  const [s0, s1] = sel.indices[1], items = []; let at = s0
  for (let i = s0; i <= s1; i++) if (i === s1 || m[i] === ',') { items.push(base.slice(at, i)); at = i + 1 }
  if (items.every((x) => !/\bselect\b/i.test(x) && /\b(count|sum|min|max|avg|group_concat|bit_and|bit_or|std|stddev\w*|variance|var_(pop|samp))\s*\(/i.test(x)) && !/\bgroup\s+by\b/i.test(q)) return
  deny(`kit guard: a row query without LIMIT can fill your context: add LIMIT <= ${max} (guard.sqlMaxRows), or aggregate (COUNT, GROUP BY ... LIMIT)`)
}
const SQL_STAR_ROWS = 10
// ---- idle: an idle wait over the 5 min prompt-cache life re-writes the whole context on the next call (owner 2026-11-27: 1,049
// misses, 224M tokens in 4 days); a Monitor expiry or a short sleep wakes the agent inside it
function warmRule(tn, ti, sub) {   // subagents only: the main session writes its cache with a 1 h life
  const w = param('guard.warmSeconds'); if (!w || !sub) return
  const how = `wait in slices of <= ${w} s (guard.warmSeconds): a Monitor with timeout_ms <= ${w * 1000}, re-armed on expiry; a long command: run_in_background, then that Monitor; kit waits (decide wait, envy wait) return within it, rerun them`
  if (tn === 'Monitor' && Number(ti.timeout_ms ?? 300000) > w * 1000) deny(`kit guard: a Monitor over ${w} s lets your prompt cache expire (5 min) while you idle: the next call re-writes your whole context. ${how}`)
  if ((tn === 'Bash' || tn === 'PowerShell') && ti.run_in_background !== true) {
    const code = `${ti.command || ''}`.replace(/<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?^\s*\2\s*$/gm, '').replace(/"(?:\\.|[^"\\])*"|'[^']*'/g, '""')   // heredocs and quoted text are data
    const s = Math.max(0, ...[...code.matchAll(/(?:^|[\s;&|(])(?:sleep\s+(\d+(?:\.\d+)?)([smh]?)(?![\w.])|Start-Sleep\s+(?:-s\w*\s+)?(\d+)\b|Start-Sleep\s+-m\w*\s+(\d+))/gi)]
      .map((m) => m[4] ? Number(m[4]) / 1000 : m[3] ? Number(m[3]) : Number(m[1]) * ({ m: 60, h: 3600 }[m[2].toLowerCase()] || 1)))
    if (s > w) deny(`kit guard: sleep ${s} in the foreground lets your prompt cache expire (5 min): the next call re-writes your whole context. ${how}`) }
}

if (!input.trim()) process.exit(0)
{ let j = null; try { j = JSON.parse(input) } catch { }
  hookIn = j; const tn = `${j?.tool_name || ''}`
  if (tn === 'Read') { readRule(j.tool_input || {}, j.session_id ? `${j.session_id}-${j.agent_id || 'main'}` : ''); process.exit(0) }
  warmRule(tn, j?.tool_input || {}, j?.agent_id); if (tn === 'Monitor') process.exit(0)
  if (/^mcp__/.test(tn)) { sqlRule(j.tool_input || {}); process.exit(0) } }
if (process.env.KIT_GUARD_WARM === '0') plain(false); else ask(2)
