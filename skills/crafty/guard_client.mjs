// guard_client.mjs: the PreToolUse hook (settings.json): hands the hook input to the warm guard_server.ps1 over a named pipe
// (~0.1 s, no pwsh start); no server, busy, a reload or any error -> this call runs crafty.ps1 guard as before (same answer),
// and a server is started for the next call. Usage: node <kit>/skills/crafty/guard_client.mjs < hook input. Exit codes: the guard's
// (0 its answer · 2 blocked); a guard crash (any other exit, no pwsh) = 2, fail-closed (K67), logged as guard event crash.
// KIT_GUARD_WARM=0: always the plain pwsh path. KIT_GUARD_BYPASS=1 (owner only, while the guard is fixed): a crash lets the call through.
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import net from 'node:net'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url)), kit = resolve(here, '..', '..')
const name = 'kit-guard-' + createHash('sha1').update(kit.toLowerCase()).digest('hex').slice(0, 12).toUpperCase()
const pipe = process.platform === 'win32' ? `\\\\.\\pipe\\${name}` : join(tmpdir(), `CoreFxPipe_${name}`)   // arch-ok: .NET's own pipe path on Unix (NamedPipeServerStream)
const input = readFileSync(0, 'utf8')
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(CLAUDE|KIT)_|^(TEMP|TMP)$/i.test(k)))

// a crash: block (exit 2, the reason to the agent) or, under KIT_GUARD_BYPASS=1, allow; both logged for supervise
function crashed(rc, err) {
  const bypass = process.env.KIT_GUARD_BYPASS === '1', why = `${err || ''}`.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/\s+/g, ' ').trim().slice(0, 300)
  let tool = '', session = ''; try { const h = JSON.parse(input); tool = `${h.tool_name || ''}`; session = `${h.session_id || ''}` } catch { }
  try {
    const map = JSON.parse(readFileSync(join(here, 'kit.example.json'), 'utf8'))._paths, d = new Date(), p = (n) => `${n}`.padStart(2, '0')
    const dir = join(kit, map.stateDir, map.durable.audit, `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`)
    const line = JSON.stringify({ at: d.toISOString(), agent: process.env.KIT_AGENT || '', script: 'guard_client.mjs', verb: 'guard', event: 'crash', session, tool, rc, letThrough: bypass, why }) + '\n'
    mkdirSync(dir, { recursive: true }); const file = join(dir, 'guard.jsonl')   // Write-KitLog's line shape: pwsh is broken or absent here
    appendFileSync(file, line)
  } catch { }
  const what = `kit guard crashed (rc ${rc}${why ? `: ${why}` : ''})`
  if (bypass) { process.stdout.write(JSON.stringify({ systemMessage: `${what}; KIT_GUARD_BYPASS=1 let this call through unguarded` }) + '\n'); process.exit(0) }
  process.stderr.write(`${what}: call blocked (fail-closed). Tell the coordinator: a kitty fixes skills/crafty in a worktree; the owner alone may set KIT_GUARD_BYPASS=1 for the session meanwhile.\n`)
  process.exit(2)
}

// the plain path: one pwsh per call (and a warm server for the next one)
function plain(start) {
  // Windows: node's children die with it (its job object): WMI starts the server outside it, while the plain call runs
  const srv = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'guard_server.ps1'), '-Pipe', name]
  let starter = null
  if (start && process.env.KIT_GUARD_WARM !== '0') {
    try {
      if (process.platform !== 'win32') spawn('pwsh', srv, { detached: true, stdio: 'ignore' }).unref()
      else {
        const cl = ['pwsh', '-WindowStyle', 'Hidden', ...srv].map((x) => (/\s/.test(x) ? `"${x}"` : x)).join(' ').replace(/'/g, "''")
        starter = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `$si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }; $null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '${cl}'; ProcessStartupInformation = $si }`], { stdio: 'ignore', windowsHide: true })
      }
    } catch { }
  }
  const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'crafty.ps1'), 'guard'], { input, encoding: 'utf8', windowsHide: true })
  const end = () => {
    if (r.error || (r.status !== 0 && r.status !== 2)) return crashed(r.error ? r.error.code || 'spawn' : r.status ?? r.signal, r.error ? r.error.message : r.stderr || r.stdout)
    process.stdout.write(r.stdout || ''); process.stderr.write(r.stderr || ''); process.exit(r.status)
  }
  if (starter && starter.exitCode === null) { starter.on('exit', end); setTimeout(end, 3000) } else end()
}

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
    if (r.code !== 0 && r.code !== 2) return plain(false)   // the plain path decides what a crash is
    if (r.out) process.stdout.write(r.out + '\n')
    process.exit(r.code)
  })
}

if (!input.trim()) process.exit(0)
if (process.env.KIT_GUARD_WARM === '0') plain(false); else ask(2)
