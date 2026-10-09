// Renders every prompt a kit workflow builds, by running the workflow with mock agents and sample args.
// Used by kit-cost.ps1 (token budget per agent type); also a cheap behaviour check: the label/model/agentType of every
// step is printed, so a prompt refactor can be diffed against the previous version.
//   node kit-cost.mjs <kitDir> [--steps]     -> JSON { calls: [{ wf, label, agentType, model, effort, bytes }] }
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const kit = (process.argv[2] || '.claude').replace(/[\\/]+$/, '')
const MR = (repo, n) => ({ url: `https://git.example.com/acme/${repo}/-/merge_requests/${n}`, repo, merged: false })
const report = (id) => ({ mrs: [MR('api', id === 'X2' ? 2 : 1)], worktrees: [`${id.toLowerCase()}-api`], done: ['A1'], deferred: [], needsLiveCheck: ['open the form and save'], seed: [], foreignHooks: [], summary: 'implemented, checks green' })

function mock(label, opts) {
  const [kind, rest = ''] = label.split(':'); const id = rest.split('@')[0]
  switch (kind) {
    case 'build': case 'fix': case 'ship': return report(id)
    case 'review': return { findings: id === 'X2' ? [{ mr: MR('api', 2).url, file: 'src/Order.java', line: 10, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] : [] }
    case 'ci': return { done: true, mrs: [{ mr: MR('api', 1).url, status: 'success' }] }
    case 'learn': return { signals: 1, lessonsChanged: [] }
    case 'test': case 'retest': return { code: id, checks: [
      { id: 'T1', subtask_id: 't1', screen: 'Orders', result: 'PASS', what_was_done: 'saved', observed: 'saved', evidence: [`${id}-T1_01_saved.jpeg`] },
      { id: 'T2', subtask_id: 't1', screen: 'Orders', result: 'PASS_WITH_NOTE', what_was_done: 'opened', observed: 'label differs', evidence: [] },
      { id: 'T3', subtask_id: 't1', screen: 'Orders', result: 'FAIL', what_was_done: 'cancelled', observed: 'PUT /api/orders -> 500', evidence: [] }],
      findings: ['seed data was old'], setup_changes: [], data_created: [] }
    case 'audit': return { reclassify: [{ id: 'T2', defect: false, reason: 'cosmetic' }], newDefects: [] }
    case 'verify': return { verdicts: [{ id: 'T3', confirmed: true, observed: '500 again', evidence: [] }] }
    case 'close': case 'hold': case 'add-followups': return { ok: true, output: 'published' }
    case 'analyse': return { proposals: [{ file: `${kit}/skills/dev-kit/LESSONS.md`, change: 'add-lesson', text: 'x', evidence: '2 signals', occurrences: 2, confidence: 'high' }] }
    case 'apply': return { applied: ['x'], proposedForApproval: [], rejected: [], report: 'r.md' }
    default: return 'ok'
  }
}

const SAMPLE = {
  'dev-wave': { brief: '/ws/.claude-runtime/briefs/wave-brief.md', kitDir: kit, mandate: ['Fix the order form bugs from the QA run and ship them.'],
    agents: [{ id: 'X1', items: 'A1, A2', area: 'order form' }, { id: 'X2', items: 'A3', area: 'order list', complex: true }] },
  'test-and-close': { runDir: '/ws/.claude-runtime/qa-runs/2026-01-01-sample', kitDir: kit, title: 'Sample epic', target: 'my-staging', tester: 'QA',
    mandate: ['Test the deployed epic tasks and close them.'], context: 'Use tenant acme.', tracker: { list: 'L1', parent: 'P1' },
    lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1' }],
    items: [{ code: 'W1', title: 'Order form', guideFile: '/ws/guides/W1.md', lane: 'web', subtasks: [{ id: 't1', name: 'Order form', mrs: 'api!1' }] },
      { code: 'P1', title: 'Order app', guideFile: '/ws/guides/P1.md', lane: 'app', subtasks: [{ id: 't2', name: 'Order app', mrs: 'app!3' }] }] },
  'kit-retro': { kitDir: kit },
}

const calls = []
for (const wf of Object.keys(SAMPLE)) {
  const src = readFileSync(join(kit, 'workflows', `${wf}.js`), 'utf8').replace(/^export const meta/m, 'const meta')
  const body = new Function('args', 'agent', 'pipeline', 'parallel', 'log', 'phase', `return (async () => {\n${src}\n})()`)
  const agent = async (prompt, opts = {}) => {
    calls.push({ wf, label: opts.label || '?', agentType: opts.agentType || '', model: opts.model || '', effort: opts.effort || '', bytes: Buffer.byteLength(prompt, 'utf8'), prompt })
    return mock(opts.label || '', opts)
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => { let r = it; for (const [i, s] of stages.entries()) r = i === 0 ? await s(it) : await s(r, it); return r }))
  const parallel = async (fns) => Promise.all(fns.map((f) => f()))
  await body(JSON.parse(JSON.stringify(SAMPLE[wf])), agent, pipeline, parallel, () => {}, () => {})
}
const keep = process.argv.includes('--prompts')
console.log(JSON.stringify({ calls: calls.map(({ prompt, ...c }) => (keep ? { ...c, prompt } : c)) }))
