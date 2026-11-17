// guard_client.mjs: the PreToolUse hook (settings.json): hands the hook input to the warm guard_server.ps1 over a named pipe
// (~0.1 s, no pwsh start); no server, busy, a reload or any error -> this call runs crafty.ps1 guard as before (same answer),
// and a server is started for the next call. Usage: node <kit>/skills/crafty/guard_client.mjs < hook input. Exit codes: the guard's.
// KIT_GUARD_WARM=0: always the plain pwsh path.
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import net from 'node:net'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url)), kit = resolve(here, '..', '..')
const name = 'kit-guard-' + createHash('sha1').update(kit.toLowerCase()).digest('hex').slice(0, 12).toUpperCase()
const pipe = process.platform === 'win32' ? `\\\\.\\pipe\\${name}` : join(tmpdir(), `CoreFxPipe_${name}`)   // arch-ok: .NET's own pipe path on Unix (NamedPipeServerStream)
const input = readFileSync(0, 'utf8')
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(CLAUDE|KIT)_|^(TEMP|TMP)$/i.test(k)))

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
  const end = () => { process.stdout.write(r.stdout || ''); process.stderr.write(r.stderr || ''); process.exit(r.status ?? 1) }
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
    if (r.out) process.stdout.write(r.out + '\n')
    process.exit(r.code)
  })
}

if (!input.trim()) process.exit(0)
if (process.env.KIT_GUARD_WARM === '0') plain(false); else ask(2)
