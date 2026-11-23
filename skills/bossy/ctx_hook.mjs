// ctx_hook.mjs: the PostToolUse hook (settings.json, Claude Code): the context self-check of every agent, workflow agent and the
// coordinator (owner 2026-11-23). At budget.reviewAt x budget.window tokens, then every budget.reviewEvery, it adds one CONTEXT-CHECK
// line to the agent's context; the agent decides continue or a fresh agent and records it (bossy.ps1 board check -Decision). Same
// record and line as usage.ps1 Get-KitCtxCheckLine (board beat asks it on Codex / Antigravity). Node, not pwsh: it runs after every
// tool call (~50 ms). Usage: node <kit>/skills/bossy/ctx_hook.mjs < hook input. Exit codes: 0 always (a check never blocks a call).
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, openSync, readSync, fstatSync, closeSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url)), kit = resolve(here, '..', '..')
const json = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return null } }
const at = (o, path) => path.split('.').reduce((v, k) => (v && typeof v === 'object' ? v[k] : undefined), o)

// a subagent's own transcript (hook input names the session's): <session>/subagents[/workflows/<wf>]/agent-<id>.jsonl
function transcriptOf(j) {
  const tp = `${j.transcript_path || ''}`; if (!tp || !j.agent_id) return tp
  const sub = join(tp.replace(/\.jsonl$/i, ''), 'subagents'), name = `agent-${j.agent_id}.jsonl`
  if (existsSync(join(sub, name))) return join(sub, name)
  try { for (const w of readdirSync(join(sub, 'workflows'))) { const f = join(sub, 'workflows', w, name); if (existsSync(f)) return f } } catch { }
  return ''   // never the parent's context for a subagent
}
// the last model call's context (input + cache write + cache read + output), from the transcript's tail
function contextOf(file) {
  const fd = openSync(file, 'r'); let txt = ''
  try { const n = Math.min(fstatSync(fd).size, 512 * 1024), b = Buffer.alloc(n); readSync(fd, b, 0, n, fstatSync(fd).size - n); txt = b.toString('utf8') } finally { closeSync(fd) }
  const ls = txt.split('\n')
  for (let i = ls.length - 1; i >= 0; i--) {
    if (!ls[i].includes('"usage"')) continue
    let o; try { o = JSON.parse(ls[i]) } catch { continue }
    const u = o && o.message && o.message.usage; if (!u) continue
    return (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.output_tokens || 0)
  }
  return 0
}

try {
  const j = JSON.parse(readFileSync(0, 'utf8')), tf = transcriptOf(j); if (!tf || !existsSync(tf)) process.exit(0)
  const ctx = contextOf(tf); if (!ctx) process.exit(0)
  const ex = json(join(kit, 'skills/crafty/kit.example.json')) || {}, loc = json(join(kit, 'skills/crafty/kit.local.json')) || {}
  const reg = (json(join(here, 'params.registry.json')) || {}).params || {}
  const param = (k) => { const v = at(loc, k); if (typeof v === 'number') return v; const m = /default=([\d.]+)/.exec(reg[k] || ''); return m ? Number(m[1]) : 0 }
  const win = Number(at(loc, 'budget.window') || at(ex, 'budget.window') || 0), first = Math.round(param('budget.reviewAt') * win), every = param('budget.reviewEvery')
  if (first <= 0 || every <= 0 || ctx < first) process.exit(0)
  const th = first + every * Math.floor((ctx - first) / every), key = basename(tf).replace(/\.jsonl?$/i, '')
  const cache = join(process.env.CLAUDE_RUNTIME || join(kit, ex._paths.runtimeDir), ex._paths.runtime.cache, 'ctx-checks'), cf = join(cache, `${key.replace(/[^\w.-]/g, '_')}.json`)
  const rec = json(cf) || {}; if (Number(rec.asked || 0) >= th) process.exit(0)
  Object.assign(rec, { transcript: tf, asked: th, askedAt: new Date().toISOString() }); mkdirSync(cache, { recursive: true }); writeFileSync(cf, JSON.stringify(rec))
  const orch = join(here, 'bossy.ps1').replace(/\\/g, '/')
  const line = `CONTEXT-CHECK: context ${Math.round(ctx / 1000)}k (self-check at ${Math.round(th / 1000)}k, next at ${Math.round((th + every) / 1000)}k): decide now: continue when the rest of this phase fits (reads in ranges, no new phase), else hand off at the phase end (crafty.ps1 checkpoint -Brief, board leave -Handoff, a fresh agent); record it: & '${orch}' board check -Decision continue|handoff -Reason '<why>' -Ctx ${key}`
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: line } }))
} catch { }
process.exit(0)
