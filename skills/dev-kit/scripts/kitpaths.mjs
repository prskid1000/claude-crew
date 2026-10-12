// Kit paths for Node: the only place a .mjs learns where runtime or durable local state lives (map: kitpaths.json).
//   import { kitPath } from '<kit>/skills/dev-kit/scripts/kitpaths.mjs'
//   kitPath('chrome-profiles')            // <runtime>/cache/chrome-profiles   ('runtime' = the runtime root)
//   kitPath('sessions', { create: true }) // creates the folder (or a file's parent folder) first
// <runtime> = $CLAUDE_RUNTIME, else <kit>/.claude-runtime.
import { readFileSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
export const KIT = resolve(HERE, '..', '..', '..')
const MAP = JSON.parse(readFileSync(join(HERE, 'kitpaths.json'), 'utf8'))
export const runtimeDir = () => process.env.CLAUDE_RUNTIME || join(KIT, MAP.runtimeDir)

export function kitPath(name, { create = false } = {}) {
  let rel, base
  if (name === 'runtime') { rel = '/'; base = runtimeDir() }
  else if (name in MAP.runtime) { rel = MAP.runtime[name]; base = runtimeDir() }
  else if (name in MAP.durable) { rel = MAP.durable[name]; base = KIT }
  else throw new Error(`kitPath: unknown name '${name}' (see skills/dev-kit/scripts/kitpaths.json)`)
  const p = rel === '/' ? base : join(base, rel.replace(/\/$/, ''))
  if (create) mkdirSync(rel.endsWith('/') ? p : dirname(p), { recursive: true })
  return p
}
