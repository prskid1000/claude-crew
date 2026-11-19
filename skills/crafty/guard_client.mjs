// guard_client.mjs: the PreToolUse hook (settings.json): hands the hook input to the warm guard_server.ps1 over a named pipe
// (~0.1 s, no pwsh start); no server, busy, a reload or any error -> this call runs crafty.ps1 guard as before (same answer),
// and a server is started for the next call. Usage: node <kit>/skills/crafty/guard_client.mjs < hook input. Exit codes: the guard's
// (0 its answer · 2 blocked); a guard crash (any other exit, non-JSON stdout, no pwsh, node error) = 2, fail-closed (K67), logged as
// guard event crash; no answer before the hook timeout = let through, logged as event timeout. KIT_GUARD_TIMEOUT_MS: tests only.
// Not caught here: node missing or this file broken (the hook exits 1 / 127: pre-commit runs node --check on it).
// KIT_GUARD_WARM=0: always the plain pwsh path. KIT_GUARD_BYPASS=1 (owner only, while the guard is fixed): a crash lets the call through.
// Sections: L25 crash · L50 plain · L90 warm
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { appendFileSync, mkdirSync, readFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import net from 'node:net'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const t0 = Date.now(), here = dirname(fileURLToPath(import.meta.url)), kit = resolve(here, '..', '..')
const name = 'kit-guard-' + createHash('sha1').update(kit.toLowerCase()).digest('hex').slice(0, 12).toUpperCase()
const pipe = process.platform === 'win32' ? `\\\\.\\pipe\\${name}` : join(tmpdir(), `CoreFxPipe_${name}`)   // arch-ok: .NET's own pipe path on Unix (NamedPipeServerStream)
let dying = false
process.on('uncaughtException', (e) => crashed('node', (e && e.stack) || e))   // node's own exit 1 would fail open
const input = readFileSync(0, 'utf8')
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(CLAUDE|KIT)_|^(TEMP|TMP)$/i.test(k)))

// ---- crash: block (exit 2, the reason to the agent) or, under KIT_GUARD_BYPASS=1, allow; both logged for supervise
function crashed(rc, err, event = 'crash') {
  if (dying) process.exit(2); dying = true   // an error in here: still blocked, never a loop
  let inp = ''; try { inp = `${input}` } catch { }   // unset when stdin itself failed
  let key = inp; try { const j = JSON.parse(inp); key = JSON.stringify([j.tool_name, j.tool_input, j.cwd]) } catch { }   // the call, not its per-call ids
  const h = createHash('sha1').update(key).digest('hex').slice(0, 12)
  const why = `${err || ''}`.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\s+/g, ' ').trim()
    .replace(/(bearer|basic|token|passw\w*|secret|api[-_]?key|authoriz\w*|cookie)[^\s=:]*(?:\s*[=:]\s*|\s+)(?:(?:bearer|basic)\s+)?[^\s;]+(?:;\s*[^\s;]+)*;?/gi, '$1 [redacted]').slice(0, 160)   // Write-KitLog masks; this line skips it
  let tool = '', session = '', bypass = process.env.KIT_GUARD_BYPASS === '1' || event === 'timeout'
  try { const j = JSON.parse(inp); tool = `${j.tool_name || ''}`; session = `${j.session_id || ''}` } catch { }
  try {
    const map = JSON.parse(readFileSync(join(here, 'kit.example.json'), 'utf8'))._paths, d = new Date(), p = (n) => `${n}`.padStart(2, '0'), off = -d.getTimezoneOffset()
    const dir = join(kit, map.stateDir, map.durable.audit, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`)
    const at = new Date(d.getTime() + off * 60000).toISOString().slice(0, -1) + (off < 0 ? '-' : '+') + p(Math.floor(Math.abs(off) / 60)) + ':' + p(Math.abs(off) % 60)   // local, as Write-KitLog
    mkdirSync(dir, { recursive: true }); const file = join(dir, 'guard.jsonl')   // Write-KitLog's line shape: pwsh is broken or absent here
    if (event === 'timeout') { let seen = ''; try { seen = readFileSync(file, 'utf8') } catch { }; if (seen.includes(`"in":"${h}"`)) { event = 'crash'; bypass = process.env.KIT_GUARD_BYPASS === '1' } }   // the same input slow again: a hang, not load
    appendFileSync(file, JSON.stringify({ at, run: process.env.KIT_RUN || '', agent: process.env.KIT_AGENT || '', script: 'guard_client.mjs', verb: 'guard', event, session, tool, in: h, rc, letThrough: bypass, why }) + '\n')
  } catch { }
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
      if (process.platform !== 'win32') spawn('pwsh', srv, { detached: true, stdio: 'ignore' }).unref()
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
function ask(tries) {
  let buf = '', done = false
  const c = net.connect(pipe)
  const fail = (noServer) => { if (done) return; done = true; c.destroy(); if (tries > 0) setTimeout(() => ask(tries - 1), 40); else plain(noServer) }   // busy or between two calls: retry
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

if (!input.trim()) process.exit(0)
if (process.env.KIT_GUARD_WARM === '0') plain(false); else ask(2)
