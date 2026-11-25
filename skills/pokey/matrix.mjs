// matrix.mjs: one UI case at every variant it needs, concurrently in one browser (adapters/ui-checks.mjs matrix: a context each).
// Usage: node <kit>/skills/pokey/matrix.mjs --case A3 --script case.mjs --out <dir> [--task <id>] [--agent <id>] [--target <t>]
//   [--tenant <x>] [--as <user>] [--path </screen>] [--parallel <n>]
//   case.mjs: export default async ({ page, tag, viewport, locale, b, ui, out }) => ({ result: 'PASS' })   b = browser.mjs, ui = ui-checks.mjs
//   (hitTest, layoutIssues, contrast, openNav: a narrow screen's collapsed nav opened first)
// Its own entry file: run as ui-checks.mjs, browser.mjs re-imported that module mid top-level await and hung (hitTest in a case).
// Exit codes: 0 all variants PASS · 1 a FAIL · 2 usage.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url)), arg = (k) => { const i = process.argv.indexOf('--' + k); return i > 1 ? process.argv[i + 1] : '' }
if (!arg('case') || !arg('script') || !arg('out')) { console.error(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(0, 7).join('\n')); process.exit(2) }
if (arg('agent')) process.env.CLAUDE_AGENT = arg('agent')
const b = await import(pathToFileURL(join(here, 'browser.mjs')).href), ui = await import(pathToFileURL(join(here, 'adapters', 'ui-checks.mjs')).href), cfg = await ui.qaCfg()
// the variants: the task's recorded scope (devtools.py matrix-scope <task> --dir <wt>), else the full qa.matrix
const sc = arg('task') ? (() => { try { return JSON.parse(readFileSync(join(b.kitPath('tasks'), arg('task').replace(/[^\w.-]/g, '_') + '.json'), 'utf8')).cases?.matrixScope } catch { return null } })() : { scope: 'full', matrix: cfg.matrix || {} }
if (!sc?.matrix) { console.error(`matrix: task ${arg('task')} has no recorded scope: python -X utf8 <kit>/skills/crafty/devtools.py matrix-scope ${arg('task')} --dir <worktree>, then again`); process.exit(2) }
const out = resolve(arg('out')), fn = (await import(pathToFileURL(resolve(arg('script'))).href)).default, t0 = Date.now()
mkdirSync(out, { recursive: true })
const s = await b.session({ target: arg('target') || undefined, tenant: arg('tenant') || undefined, as: arg('as') || undefined })
let rows
try { if (arg('path')) await b.go(s.page, arg('path')); rows = await ui.matrix(s, (v) => fn({ ...v, b, ui, out, case: arg('case') }), sc.matrix, { parallel: Number(arg('parallel')) || cfg.matrixRun?.parallel || 4 }) } finally { await s.done() }
const line = ui.matrixLine(rows, sc), fails = rows.filter((x) => !ui.passed(x.result))
writeFileSync(join(out, `${arg('case')}-matrix.json`), JSON.stringify({ case: arg('case'), scope: sc.scope, reason: sc.reason || '', ms: Date.now() - t0, rows, line }, null, 1))
for (const x of rows) console.log(`${ui.passed(x.result) ? 'PASS' : 'FAIL'} ${arg('case')} ${x.variant} ${x.ms ?? ''} ms ${JSON.stringify(x.result).slice(0, 160)}`)
console.log(line); process.exit(fails.length ? 1 : 0)
