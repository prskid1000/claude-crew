export const meta = {
 name: 'buildy',
 description: 'The dev flow for any multi-item build (any stack): features, fixes, refactors, migrations, bug waves, resume; devy: code, testing goals, local test loop, decision pauses; review, CI, merge (producers first), human testing doc + tracker; merged work waits for a person\'s deploy',
 whenToUse: 'Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)',
 phases: [
  { title: 'Build', detail: 'one devy per area: worktree, code, testing goals, local test loop, MRs, testing doc' },
  { title: 'Decide', detail: 'items paused for an owner decision or a coordinator ENV-FIX wait for the answer, then resume' },
  { title: 'Review', detail: 'one revy per devy + CI pipelines' },
  { title: 'Fix', detail: 'one fix round (local tests again), then merge in order and register the tracker task' },
  { title: 'Deploy', detail: 'the merged work joins the deploy batch silently (extra deploys); a person says deploy <env> (never asked, never deployed here)' },
  { title: 'Learn', detail: 'signals from this wave, cleanup (/tidy turns them into lessons)' },
 ],
}

// Sections: L17 args · L128 record-args · L148 budget · L163 build-prompt · L217 ship-prompt · L239 plan · L251 local-loop ·
//   L309 stages · L420 ship · L480 deploy · L496 learn
// ---- args: the run's input, checked
/* args = {
 brief: '<abs path>/wave-brief.md' (required; templates.md "Wave" / "Bug-fix" / "Resume brief"),
 agents: [{ id: 'X1', items: 'A3, A4', area, note, complex, model, effort, dependsOn: ['X0'] (producers merged first) }],
 mandate: ['<the owner words, verbatim>'], mode: 'feature' | 'bugfix' (repro first) | 'resume',
 complex: ['X1'] (session model instead of sonnet),
 holdMerge: ['web'] | true (reviewed + green, never merged), learn: true | false | 'auto', batch: <areas per run; the rest -> next>,
 kitDir: '<abs .claude>', runtimeDir: '<default <kitDir>/.runtime>', run: '<board run; default from the brief>',
}
Returns { agents, deferred, blocked, decisions, envFixes, needsLiveCheck, seed, openFindings, testerGuides, deployBatch, budget, next?, retroDue } or { refused, batch, next }.
*/
const A0 = args || {}   // recorded as given (resume); A = this run's batch (args.batch areas; the rest -> next)
const BATCH = A0.batch > 0 && Array.isArray(A0.agents) && A0.agents.length > A0.batch ? A0.batch : 0
const IN = BATCH ? A0.agents.slice(0, BATCH) : A0.agents || []
// producers outside a run's list ship in another run
const own = (gs) => gs.map((a) => ({ ...a, dependsOn: [].concat(a.dependsOn || []).filter((p) => gs.some((b) => b.id === p)) }))
const A = BATCH ? { ...A0, agents: own(IN) } : A0
const KIT = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const K = `${KIT}/skills/dev-kit`
const DEV = `${K}/dev.ps1`
const DT = `${K}/devtools.py`
const ORCH = `${KIT}/skills/orchestrate/orch.ps1`
const RT = (A.runtimeDir || `${KIT}/.runtime`).replace(/[\\/]+$/, '')
// kit paths by name: the same names and values as skills/dev-kit/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"cleanup-log": "logs/cleanup.log", "launches": "work/launches/"}, "durable": {}}
const rp = (n) => (n in KP.durable ? `${KIT}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
const PATHS = (/^([A-Za-z]:|[\\/])/.test(KIT) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
 '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
if (!A.brief || !Array.isArray(A.agents) || !A.agents.length) throw new Error('args.brief and args.agents[] are required')
const DEPS = Object.fromEntries(A.agents.map((a) => [a.id, [].concat(a.dependsOn || [])]))
for (const [id, ps] of Object.entries(DEPS)) for (const p of ps) if (!(p in DEPS) || p === id) throw new Error(`agents[${id}].dependsOn: unknown or self area '${p}'`)
const cyclic = (id, seen = []) => seen.includes(id) || DEPS[id].some((p) => cyclic(p, [...seen, id]))
for (const id of Object.keys(DEPS)) if (cyclic(id)) throw new Error(`agents[].dependsOn has a cycle through ${id}`)
const SETTLED = {}
for (const a of A.agents) { let res; SETTLED[a.id] = { p: new Promise((r) => { res = r }), done: (x) => res(x) } }
// blocking finding; REREVIEW: the fix for an empty review
const BLOCK = (mrs, problem, fix) => ({ mr: mrs.map((m) => m.url).join(', '), file: '-', severity: 'blocking', problem, fix }), REREVIEW = 'Re-run the review (one-off revy, kind mr), then merge.'
const consumersOf = (id) => A.agents.filter((c) => DEPS[c.id].includes(id)).map((c) => c.id)
const MODE = A.mode || 'feature'
if (!['feature', 'bugfix', 'resume'].includes(MODE)) throw new Error(`args.mode '${MODE}' is not supported${MODE === 'duel' ? ' (duel is an extra: run kittool.py extra add duel)' : ''}`)
// args removed in the 2026-10-21 trim: say so instead of silently ignoring them
for (const k of ['review', 'localRetries', 'envFixCycles', 'envFixWaitMinutes', 'decisionWaitMinutes', 'requireLocal', 'roles', 'models', 'duel']) if (k in A0) log(`WARNING: args.${k} was removed and is ignored`)
if (!A.mandate || !A.mandate.length) log('WARNING: no args.mandate (the owner words): agents may drop their items for the latest chat message. Pass mandate next time (orchestrate step 3).')
const RUN = A.run || `${(A.brief.split(/[\\/]/).pop() || 'wave').replace(/\.md$/, '')}-${fnv(String(A.brief)).slice(0, 4)}`   // hash: same name, other wave (orch.ps1 Get-LaunchRunName)
const LEARN = A.learn === undefined ? true : A.learn
const LOCAL_RETRIES = 1
// waits come in 9-minute slices (the tool timeout is 10): 34 slices = about 5 h
const WAIT_SLICES = 34
const ENV_FIX_CYCLES = 2
const HOLD = A.holdMerge === true ? ['*'] : (Array.isArray(A.holdMerge) ? A.holdMerge : [])
const HOLD_NOTE = HOLD.length
 ? `\nMERGE HOLD: never merge or schedule a merge for MRs in ${HOLD.includes('*') ? 'ANY repo' : HOLD.join(', ')}: their branch deploys and the owner approves those merges. Leave them open and green; report merged=false and say "held for approval".`
 : ''
const MERGE_WORD_NOTE = `Merge results: the LAST line of each devtools.py merge run is one word: MERGED / SCHEDULED / WAIT / CONFLICT / PIPELINE_FAILED /
NOT_MERGED. Report it as that MR's mergeState; merged=true ONLY for MERGED. WAIT: run the same merge again about 2 minutes later (at most
3 runs), then report the last word - except "waiting for producer <ref>": do not re-run, report WAIT. CONFLICT / PIPELINE_FAILED / NOT_MERGED: say why.`
const nu = (u) => String(u || '').replace(/[?#].*$/, '').replace(/\/+$/, '').toLowerCase()
const AGENT_ENV = (name) => `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${name}';  (Bash: export CLAUDE_AGENT='${name}';) - the build gate
queues your builds under this owner name (shell state does not persist between commands).`

const REPORT = {
 type: 'object',
 properties: {
  mrs: { type: 'array', items: { type: 'object', properties: { url: { type: 'string' }, repo: { type: 'string' },
   merged: { type: 'boolean', description: 'true ONLY on a confirmed merge (devtools.py merge printed MERGED, or the host says merged)' },
   mergeState: { type: 'string', enum: ['MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED', 'OPEN'] } },
   required: ['url', 'repo', 'merged'] } },
  worktrees: { type: 'array', items: { type: 'string' } },
  done: { type: 'array', items: { type: 'string' }, description: 'item ids finished (local test passed, MR open)' },
  deferred: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
  needsDecision: { type: 'array', items: { type: 'object', properties: { item: { type: 'string' }, decisionId: { type: 'string', description: 'the id orch.ps1 decide ask printed' }, question: { type: 'string' } }, required: ['item', 'decisionId', 'question'] },
   description: 'items you stopped for an owner decision (orch.ps1 decide ask); [] when none' },
  needsEnvFix: { type: 'array', items: { type: 'object', properties: { item: { type: 'string' }, envFixId: { type: 'string', description: 'the id orch.ps1 decide ask -Kind envfix printed' }, need: { type: 'string' } }, required: ['item', 'envFixId', 'need'] },
   description: 'items stopped for a local-env fix only the coordinator may do (up/down/refresh/drop, shared DB repair); [] when none' },
  localTest: { type: 'object', properties: {
   status: { type: 'string', enum: ['PASS', 'FAIL', 'BLOCKED', 'NONE'], description: 'PASS = every testing goal passed on the local env with clean logs; FAIL = goals still failing (also after the max rounds); BLOCKED = ONLY an owner decision or a remote-only dependency (blockedKind), never an env reason; NONE = no local env for these repos (automated tests only)' },
   blockedKind: { type: 'string', enum: ['decision', 'remote'], description: 'BLOCKED only: decision = waits for the owner (decide ask); remote = needs a system only reachable remotely' },
   blockedReason: { type: 'string', description: 'BLOCKED only: the decision id or the remote dependency' },
   env: { type: 'string', description: '<env> r<n>, or "none: <why>"' }, rounds: { type: 'number' },
   failing: { type: 'array', items: { type: 'string' }, description: 'goal ids still failing, with one line each' },
   goalsDoc: { type: 'string', description: 'path of the testing-goals doc' } }, required: ['status', 'env', 'rounds', 'failing', 'goalsDoc'] },
  needsLiveCheck: { type: 'array', items: { type: 'string' } },
  testerGuide: { type: 'string', description: 'link of the published human testing doc (linked on the task and in the MR); "none: <reason>" only for changes with nothing to test' },
  seed: { type: 'array', items: { type: 'string' }, description: 'settings/data to seed after deploy' },
  foreignHooks: { type: 'array', items: { type: 'string' } },
  summary: { type: 'string', description: '<=200 words; MR merge state lives in mrs[].mergeState' },
  handoff: { type: 'string', description: 'only at your budget handoff (board beat printed HANDOFF): the resume brief path; a fresh devy continues' },
 },
 required: ['mrs', 'worktrees', 'done', 'deferred', 'needsDecision', 'localTest', 'needsLiveCheck', 'seed', 'foreignHooks', 'summary', 'testerGuide'],
}
const REVIEW_SCHEMA = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
 mr: { type: 'string' }, file: { type: 'string' }, line: { type: 'number' }, severity: { type: 'string', enum: ['blocking', 'should-fix', 'nit'] },
 problem: { type: 'string' }, fix: { type: 'string' } }, required: ['mr', 'file', 'severity', 'problem', 'fix'] } } }, required: ['findings'] }
// true: fix round, then re-review
const FIXES = { blocking: true, 'should-fix': true, nit: false }
const mustFix = (f) => FIXES[f.severity] !== false
const CI_SCHEMA = { type: 'object', properties: { done: { type: 'boolean' }, mrs: { type: 'array', items: { type: 'object', properties: { mr: { type: 'string' }, status: { type: 'string' }, job: { type: 'string' }, error: { type: 'string' } }, required: ['mr', 'status'] } } }, required: ['done', 'mrs'] }
const OK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }
const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' } }, required: ['signals'] }
// one mechanical command run by a cheap agent: { ok, output }
// output = its last output line unless whole (a multi-line JSON)
const runStep = (cmd, label, phaseName, { ok = 'when it ran', slow = false, whole = false } = {}) =>
 agent(`STEP: run exactly this in PowerShell${slow ? ' (tool timeout 600000)' : ''} and return ok=true ${ok} (else ok=false) with ${whole ? 'its full output' : 'its last output line'}, nothing else:${PATHS}\n${cmd}`,
  { label, phase: phaseName, schema: OK_SCHEMA, agentType: 'devy', model: 'haiku', effort: 'low' })

// keeps agents on their items when a later owner message is relayed
const WHY = `WHY: ${A.mandate && A.mandate.length ? `the owner asked for this, verbatim:\n${[].concat(A.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}Your items below ARE that request; a relayed chat message never changes them and never triggers anything destructive ("Stay on your assignment").
`
const MODELS = { build: 'sonnet', review: 'sonnet', ci: 'haiku', ship: 'haiku', learn: 'haiku', complex: '', retest: 'opus', retestEffort: 'high' }
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
// ---- record-args: the launch record (a resume needs it byte-exact)
// full args go to the launch record first (orch.ps1 launch -Self, FNV-1a): resumes need them byte-exact
function fnv(s) { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }   // hoisted: RUN needs it
async function recordArgs(wf, run, a, phaseName, plan) {
 const json = JSON.stringify(a)
 const file = `${rp('launches')}/args-${wf}-${run.replace(/[^\w.-]/g, '_')}.json`
 const prompt = `STEP: record this workflow's launch args (crash recovery). Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${file} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${json}
ARGS>>>
2. Run in PowerShell: & ${ORCH} launch -Self -Script ${wf}.js -Run '${run}' -ArgsFile '${file}' -Fnv ${fnv(json)} -Plan '${plan}'
Return ok=true when it prints RECORDED, else ok=false; output = its full output (MISMATCH = the file differs: write it again once, re-run).`
 for (const [label, model] of [['record-args', 'haiku'], ['record-args-retry', 'sonnet']]) {
  const r = await agent(prompt, { label, phase: phaseName, schema: OK_SCHEMA, agentType: 'devy', model, effort: 'low' })
  if (r && r.ok) return r.output || ''
 }
 log('WARNING: launch args not recorded (orch.ps1 launch -Self failed twice): a resume after a restart needs them typed by hand')
 return ''
}
// ---- budget: the plan cap and the stop line
// BUDGET (README "Configuration" budget): cap = the plan's budgets; over it -> refused + split; at stopAt no new round, rest -> next
const BUD = { cap: 0, estimate: 0, stopAt: 0.8, spent: 0, guess: 0, stop: false, unit: 0 }
function takeBudget(out, units) {
 try { Object.assign(BUD, JSON.parse((/BUDGET (\{.*\})/.exec(out) || [])[1])); BUD.unit = BUD.estimate / Math.max(1, units) } catch (e) { log('WARNING: no BUDGET line from launch -Self: this run is not budget-gated') }
}
async function gate(phaseName) {   // before a new round; measures only near the stop line
 if (BUD.stop || !BUD.cap) return !BUD.stop
 BUD.guess += BUD.unit
 if (BUD.spent + BUD.guess < 0.6 * BUD.stopAt * BUD.cap) return true
 BUD.m = BUD.m || runStep(`& ${ORCH} budget -Run '${RUN}' -Json`, 'budget', phaseName).catch(() => null).then((r) => { try { BUD.spent = JSON.parse(r.output).spent; BUD.guess = 0 } catch (e) {} BUD.m = null })
 await BUD.m
 if (BUD.spent >= BUD.stopAt * BUD.cap && !BUD.stop) { BUD.stop = true; log(`BUDGET: spent ${BUD.spent} of the cap ${BUD.cap}: running rounds finish, no new one starts; the rest -> next`) }
 return !BUD.stop
}
// ---- build-prompt: devy, revy, fix and CI prompts
const isComplex = (a) => a.complex === true || [].concat(A.complex || []).includes(a.id)
const modelOf = (a) => ({ ...(a.model ? { model: a.model } : pick(isComplex(a) ? 'complex' : 'build')), ...(a.effort ? { effort: a.effort } : {}) })

function depNote(a) {
 const ps = DEPS[a.id], cs = consumersOf(a.id)
 return (ps.length ? `MERGE ORDER: you consume area(s) ${ps.join(', ')}: the workflow merges your MRs after theirs. Name the producer MRs in your MR description.\n` : '') +
  (cs.length ? `MERGE ORDER: area(s) ${cs.join(', ')} consume your work: open your MRs early and say which MR carries the contract.\n` : '')
}
const FLOW = `THE DEV FLOW = dev-kit SKILL.md steps 0-9 and your agent rules (local loop, ENV-FIX, decision pauses); this run's commands:
${MODE === 'bugfix' ? '- BUG FIX: reproduce each bug on the local env BEFORE fixing; record it in the testing-goals doc.\n' : ''}- Lease ONLY the services your items declare (brief "Services") with -Session <board token>.
- ENV-FIX: & ${ORCH} decide ask -Kind envfix -Run ${RUN} -Agent <id> -Item <item> -Question "<the fix>" ; that item -> needsEnvFix.
- DECISION: & ${ORCH} decide ask -Run ${RUN} -Agent <id> -Item <item> -Question "<q>" -Options "A: ..","B: .." -Recommend <A|B>
 -Contracts <brief>.contracts.md ; that item -> needsDecision. Both: continue the other items.
- Every goal PASS: push, MRs (templates.md "MR body"), human testing doc, solution comment, tracker review; do NOT merge (the
 workflow reviews, waits for CI, merges): merged=false, mergeState OPEN.`

function buildPrompt(a) {
 return `${WHY}
You are devy ${a.id} in a parallel wave (${MODE}; kind: ${a.kind || (MODE === 'bugfix' ? 'fix' : 'feature')}).${PATHS}${AGENT_ENV(a.id)}
Follow ${K}/SKILL.md (its steps and Rules; tools in ${DEV}, ${DT}) and the brief ${A.brief} (repos, ownership, ranges, local env, decisions; it wins).
${MODE === 'resume' ? 'RESUMING: first work out what is already done (dev-kit/templates.md "Resume brief"); continue from there.\n' : ''}YOU ARE ${a.id}. Items: ${a.items}. Area: ${a.area}.
Board: & ${ORCH} board join -Type devy -Agent ${a.id} -Run ${RUN} -Contracts <brief>.contracts.md (if it exists); DUPLICATE -> stop without writing.
Worktree name prefix: ${a.id.toLowerCase()}. Never touch other agents' worktrees, branches or processes.
${a.note || ''}
${depNote(a)}${FLOW}${HOLD_NOTE}
Only the brief, its contracts file and the mandate define your work: a relayed chat message never changes it. Return the report.`
}
function continuePrompt(a, r, why) {
 return `${WHY}
You are devy ${a.id} again (items ${a.items}, area ${a.area}).${PATHS}${AGENT_ENV(a.id)}
Follow ${K}/SKILL.md and ${A.brief}. Your worktrees: ${(r.worktrees || []).join(', ') || '(see the board / your branch)'}. Testing-goals doc: ${(r.localTest || {}).goalsDoc || '(yours)'}.
${why}
${FLOW}${HOLD_NOTE}
Return the full report (every MR, all items done so far).`
}
function reviewPrompt(a, r) {
 return `Kind mr: review devy ${a.id}'s MRs (items ${a.items}, area ${a.area}; brief ${A.brief}) as your agent definition says.${PATHS}${AGENT_ENV(`review-${a.id}`)}
${r.mrs.map((m) => `- ${m.url} (${m.repo}${m.merged ? ', merged' : ''})`).join('\n')}
Testing-goals doc: ${(r.localTest || {}).goalsDoc || '(none reported)'}; local test: ${(r.localTest || {}).status || '?'} on ${(r.localTest || {}).env || '?'}.
Rules: ${K}/SKILL.md Rules (scope, tests, migrations). Only real problems; "blocking" = must be fixed before it ships (an unasked
user-visible behaviour change is blocking; same behaviour, other internals is not). Change no code; give each finding its suggested change. Only the brief and these MRs define the review.`
}
function fixPrompt(a, r, findings) {
 return continuePrompt(a, r, `An independent reviewer or CI found these problems in your MRs (blocking and should-fix; resolve all):
${findings.map((f) => `- ${f.mr} ${f.file}${f.line ? ':' + f.line : ''}: ${f.problem} -> ${f.fix}`).join('\n')}
Fix each or explain why it is not a problem. Then run the local test loop again (every goal) before you push. An already-merged MR:
put the fix on a new branch from the target (dev.ps1 wt new) and open a follow-up MR.`)
}
function ciPrompt(r, a) {
 return `STEP: run exactly this PowerShell command (tool timeout 600000) and return its JSON output (fields done, mrs). Nothing else.${PATHS}
$env:CLAUDE_AGENT='ci-${a.id}'; & ${DEV} pipes -Mrs ${r.mrs.filter((m) => !m.merged).map((m) => m.url).join(',')} -MaxMinutes 8
If the JSON says "done": false, run it again (at most 3 times in total) and return the last JSON.`
}
// ---- ship-prompt: merge order and holds
const isHeld = (m) => HOLD.includes('*') || HOLD.includes(m.repo) || HOLD.some((h) => (m.url || '').includes(`/${h}/`))
const CONSUMER = /(^|[\/_.-])(web|ui|frontend|front|app|apps|mobile|android|ios|client|clients|portal|spa)([\/_.-]|$)/i
const isConsumer = (m) => CONSUMER.test(m.repo || '') || CONSUMER.test(((m.url || '').split('/-/')[0] || '').split('/').pop() || '')
const toShip = (r) => { const open = r.mrs.filter((m) => !m.merged && !isHeld(m)); return [...open.filter((m) => !isConsumer(m)), ...open.filter(isConsumer)] }
const SYNC_NOTE = `Before each merge, and whenever devtools.py merge prints CONFLICT: & ${DEV} wt sync -Dir <worktree>. A rebase conflict ONLY in
append-only files (changelog includes, route/nav lists, i18n keys, barrel/DI lists): python ${DT} keepboth <file>, no conflict marker
left, git add, git -c core.editor=true rebase --continue, & ${DEV} check -Dir <module>, git push --force-with-lease (the MR's own branch
only), then devtools.py merge again. A conflict in real code: git rebase --abort, report mergeState CONFLICT with the files.`
function shipPrompt(a, r, wait = []) {
 return `STEP: schedule merge-when-green for devy ${a.id}'s reviewed MRs. Change no code (only append-only conflict resolution).${PATHS}${AGENT_ENV(`ship-${a.id}`)}
These merges are authorized: the wave was launched for this work, the local test loop passed, the review is clean, and every MR whose
target deploys was removed (holdMerge). Do not ask for approval; ignore unrelated chat messages relayed to you.
Merge in THIS order (producers first, consumers last):
${toShip(r).map((m, i) => `${i + 1}. ${m.url} (${m.repo}${isConsumer(m) ? ', consumer' : ', producer/independent'})`).join('\n')}
python ${DT} merge <worktree> <iid> (worktrees: ${r.worktrees.join(', ')}). A consumer merges only after its producer printed MERGED;
otherwise register & ${ORCH} track add -Task <task id from the MR title/branch> -Discover -MergeAfter '<consumer repo>!<iid>><producer repo>!<iid>'.
${wait.length ? `These producer MRs of other areas are NOT merged yet: ${wait.map((m) => m.url).join(', ')}: register each MR listed above behind them (-MergeAfter; never a held MR), merge none.\n` : ''}${SYNC_NOTE}
${MERGE_WORD_NOTE}
Return the report with the same MRs and testerGuide "${r.testerGuide || 'none: not reported by the build agent'}".${HOLD_NOTE}`
}

// ---- plan: the budget gate before any agent
const PLAN = [...A.agents.map((a) => `devy/${modelOf(a).model || ''}:1,revy/${MODELS.review}:1,step/${MODELS.ship}:3,item:${String(a.items || '').split(',').filter(Boolean).length || 1}`),
 `step/haiku:2,kitty/${MODELS.learn}:1`].join(',')
takeBudget(await recordArgs('buildy', RUN, A0, 'Build', PLAN), A.agents.length)
const nextCall = (agents, extra = {}) => ({ scriptPath: `${KIT}/workflows/buildy.js`, args: { ...A0, agents: own(agents), batch: undefined, ...extra } })
if (BUD.cap && BUD.estimate > BUD.stopAt * BUD.cap) {
 const batch = Math.max(1, Math.floor(A.agents.length * BUD.stopAt * BUD.cap / BUD.estimate))
 log(`REFUSED: estimate ${BUD.estimate} > ${BUD.stopAt * 100}% of the cap ${BUD.cap}: run ${batch} area(s) per run (args.batch)`)
 return { refused: true, estimate: BUD.estimate, cap: BUD.cap, batch, next: { scriptPath: `${KIT}/workflows/buildy.js`, args: { ...A0, batch } } }
}
log(`wave: ${A.agents.length} agents, mode ${MODE}, local retries ${LOCAL_RETRIES}, brief ${A.brief}`)

// ---- local-loop: waits, report merges, the local test loop
// merge, don't replace: a later round reports only its own work
const uniq = (x) => [...new Set(x)]
const byId = (x) => [...new Map(x.map((d) => [d.id, d])).values()]
const byKey = (x, k) => [...new Map(x.map((d) => [d[k], d])).values()]
// slices fit the agent's tool timeout (longer waits get killed)
async function waitAnswer(id, label, tries) {
 for (let t = 0; t < tries; t++) {
  const w = await runStep(`& ${ORCH} decide wait -Id ${id} -MaxMinutes 9`, label, 'Decide', { ok: 'when it prints ANSWERED', slow: true })
  if (w && w.ok) return w.output
 }
 return null
}
function mergeReports(x, r2, note) {
 if (!r2) return x
 const mrs = [...r2.mrs, ...x.mrs.filter((m) => !r2.mrs.some((n) => nu(n.url) === nu(m.url)))]
 return { ...x, ...r2, mrs, worktrees: uniq([...(x.worktrees || []), ...(r2.worktrees || [])]), done: uniq([...(x.done || []), ...(r2.done || [])]),
  deferred: byId([...(x.deferred || []), ...(r2.deferred || [])]).filter((d) => !(r2.done || []).includes(d.id)),
  needsDecision: byKey([...(x.needsDecision || []), ...(r2.needsDecision || [])], 'decisionId'), needsEnvFix: byKey([...(x.needsEnvFix || []), ...(r2.needsEnvFix || [])], 'envFixId'), needsLiveCheck: uniq([...(x.needsLiveCheck || []), ...(r2.needsLiveCheck || [])]),
  seed: uniq([...(x.seed || []), ...(r2.seed || [])]), foreignHooks: uniq([...(x.foreignHooks || []), ...(r2.foreignHooks || [])]),
  testerGuide: r2.testerGuide && !/^none/i.test(r2.testerGuide) ? r2.testerGuide : x.testerGuide, summary: `${x.summary}\n\n${note}: ${r2.summary}` }
}
const settleOnThrow = async (a, fn) => { try { return await fn() } catch (e) { SETTLED[a.id].done(null); throw e } }
const decisions = []
const envFixes = []
// BLOCKED stands only for an owner decision or a remote-only dependency; any other BLOCKED (an env reason) is a FAIL to fix
function normLocal(r) {
 const lt = r && r.localTest
 if (lt && lt.status === 'BLOCKED' && !['decision', 'remote'].includes(lt.blockedKind)) return { ...r, localTest: { ...lt, status: 'FAIL', failing: [...(lt.failing || []), `reported BLOCKED without blockedKind (${lt.blockedReason || lt.env || 'no reason'}): the local env is ours, unblock it`] } }
 return r
}
// local test loop at workflow level: FAIL -> `retries` more rounds on the build model, then ONE stronger fix round (MODELS.retest)
async function localLoop(a, r, retries, stage) {
 for (let h = 0; r && r.handoff && h < 3; h++) {   // budget handoff -> a fresh devy
  log(`${a.id}: HANDOFF at its budget (${r.handoff}): a fresh devy continues`)
  const r2 = await agent(continuePrompt(a, r, `HANDOFF: the previous devy reached its budget; read its resume brief ${r.handoff} first and continue from there.`), { label: `handoff:${a.id}`, phase: stage, schema: REPORT, agentType: 'devy', ...modelOf(a) })
  r = mergeReports({ ...r, handoff: '' }, r2, 'Handoff')
 }
 r = normLocal(r)
 if ((r.needsEnvFix || []).length) return r   // the coordinator fixes the env first (Decide), then the loop runs again
 for (let i = 0; i < retries && r.localTest && r.localTest.status === 'FAIL'; i++) {
  if (!(await gate(stage))) return { ...r, budgetStopped: true }
  log(`${a.id}: local test FAILED (${(r.localTest.failing || []).join('; ')}) - local round ${i + 2}`)
  const r2 = await agent(continuePrompt(a, r, `Your local test loop still FAILS: ${(r.localTest.failing || []).join('; ')}. Debug locally (logs, DB state, debugger), fix, redeploy and re-run every goal.`),
   { label: `local:${a.id}`, phase: stage, schema: REPORT, agentType: 'devy', ...modelOf(a) })
  r = normLocal(mergeReports(r, r2, `Local round ${i + 2}`))
 }
 if (r.localTest && r.localTest.status === 'FAIL' && MODELS.retest) {
  if (!(await gate(stage))) return { ...r, budgetStopped: true }
  log(`${a.id}: local test still FAILS - one stronger fix round on ${MODELS.retest}`)
  const r2 = await agent(continuePrompt(a, r, `STRONGER FIX ROUND: earlier rounds could not make these goals pass: ${(r.localTest.failing || []).join('; ')}.
Start from the evidence (logs, DB state, the reproduction), find the root cause, fix, redeploy and re-run every goal. An env problem is ours to
fix (THE DEV FLOW step 3), never a reason to stop.`), { label: `local-strong:${a.id}`, phase: stage, schema: REPORT, agentType: 'devy', ...modelOf(a), model: MODELS.retest, effort: MODELS.retestEffort || 'high' })
  r = normLocal(mergeReports(r, r2, 'Stronger fix round'))
 }
 return r
}

// ---- stages: build -> review -> fix per area
const results = await pipeline(
 A.agents,
 // Build: code + testing goals + local loop; an agent that died (API timeout, usage limit) is retried once (infra flake)
 (a) => settleOnThrow(a, async () => {
  let r = await agent(buildPrompt(a), { label: `build:${a.id}`, phase: 'Build', schema: REPORT, agentType: 'devy', ...modelOf(a) })
  if (!r) { log(`${a.id}: build agent returned nothing - one retry (infra flake)`); r = await agent(continuePrompt(a, {}, 'A previous attempt stopped without a report: work out what is done (dev.ps1 wt status, the board, your branch) and continue.'), { label: `build-retry:${a.id}`, phase: 'Build', schema: REPORT, agentType: 'devy', ...modelOf(a) }) }
  if (!r) return { id: a.id, error: 'agent returned nothing (twice)' }
  return localLoop(a, r, LOCAL_RETRIES, 'Build')
 }),
 // Decide: owner-decision items wait for the answer (other areas go on), ENV-FIX items for the coordinator's fix (<= ENV_FIX_CYCLES
 // per area); then the agent continues them
 (r, a) => settleOnThrow(a, async () => {
  if (!r || r.error || r.budgetStopped || !((r.needsDecision || []).length || (r.needsEnvFix || []).length)) return r
  let cur = r, envCycles = 0
  const asked = new Set()
  // resumes may raise new decisions / env fixes and rerun the local loop
  for (let round = 0; round < 8; round++) {
   const fixes = cur.needsEnvFix || []
   const decs = (cur.needsDecision || []).filter((d) => !asked.has(d.decisionId))
   if (!fixes.length && !decs.length) break
   if (fixes.length) {
    if (envCycles++ >= ENV_FIX_CYCLES) {
     cur = { ...cur, needsEnvFix: [], deferred: byId([...(cur.deferred || []), ...fixes.map((f) => ({ id: f.item, reason: `ENV-FIX ${f.envFixId} unresolved after ${ENV_FIX_CYCLES} cycle(s): the coordinator decides` }))]) }
     log(`${a.id}: ENV-FIX unresolved after ${ENV_FIX_CYCLES} cycle(s) for ${fixes.map((f) => f.item).join(', ')} - deferred, the coordinator decides`)
     continue
    }
    const done = []
    for (const f of fixes) {
     envFixes.push({ agent: a.id, ...f })
     log(`${a.id}: item ${f.item} waits for ENV-FIX ${f.envFixId} (the coordinator fixes the local env: orch.ps1 decide answer)`)
     done.push({ ...f, ans: await waitAnswer(f.envFixId, `envfix:${a.id}`, WAIT_SLICES) })
    }
    const answered = done.filter((f) => f.ans && !/:\s*cannot\b/i.test(f.ans))
    const failed = done.filter((f) => !answered.includes(f))
    if (failed.length) cur = { ...cur, deferred: byId([...(cur.deferred || []), ...failed.map((f) => ({ id: f.item, reason: `ENV-FIX ${f.envFixId}: ${f.ans ? f.ans : 'no fix within the wait'} (the coordinator decides)` }))]) }
    cur = { ...cur, needsEnvFix: [] }
    if (!answered.length) continue
    if (!(await gate('Decide'))) { cur = { ...cur, budgetStopped: true }; break }
    const r2 = await agent(continuePrompt(a, cur, `The coordinator fixed the local env:\n${answered.map((f) => `- item ${f.item} (${f.envFixId}): ${f.ans}`).join('\n')}\nContinue those items (local test loop, MR, testing doc).`),
     { label: `envfix-resume:${a.id}`, phase: 'Decide', schema: REPORT, agentType: 'devy', ...modelOf(a) })
    cur = await localLoop(a, mergeReports(cur, r2, 'After ENV-FIX'), LOCAL_RETRIES, 'Decide')
    continue
   }
   for (const d of decs) {
    asked.add(d.decisionId)
    decisions.push({ agent: a.id, ...d })
    log(`${a.id}: item ${d.item} waits for decision ${d.decisionId} (the coordinator asks the owner: orch.ps1 decide answer)`)
    const ans = await waitAnswer(d.decisionId, `decide:${a.id}`, WAIT_SLICES)
    if (!ans) { cur = { ...cur, deferred: byId([...(cur.deferred || []), { id: d.item, reason: `needs decision ${d.decisionId} (no answer within the wait)` }]) }; continue }
    if (!(await gate('Decide'))) { cur = { ...cur, budgetStopped: true }; break }
    const r2 = await agent(continuePrompt(a, cur, `The owner answered decision ${d.decisionId} for item ${d.item}: ${ans}\nFinish item ${d.item} accordingly (testing goals, local test loop, MR, testing doc).`),
     { label: `resume:${a.id}`, phase: 'Decide', schema: REPORT, agentType: 'devy', ...modelOf(a) })
    cur = await localLoop(a, mergeReports(cur, r2, `Decision ${d.decisionId}`), LOCAL_RETRIES, 'Decide')
   }
  }
  return { ...cur, needsDecision: [], needsEnvFix: [] }
 }),
 // Review + CI (+ one fix round), ship
 (r, a) => settleOnThrow(a, async () => {
  if (!r || r.error) return r && r.error ? r : { id: a.id, error: 'agent returned nothing' }
  if (r.budgetStopped) return { id: a.id, report: r, findings: [], budgetStopped: true }
  const lt = r.localTest || { status: 'NONE' }
  if (lt.status === 'BLOCKED' || lt.status === 'FAIL') {
   // FAIL after the stronger round: held for the coordinator; BLOCKED: owner decision / remote dependency
   const why = lt.status === 'BLOCKED' ? `${lt.blockedKind}: ${lt.blockedReason || ''}` : (lt.failing || []).join('; ') || lt.env
   log(`${a.id}: local test ${lt.status} - not reviewed, not merged (${why})${lt.status === 'FAIL' ? ': the coordinator decides' : ''}`)
   return { id: a.id, report: r, findings: [], blocked: `local test ${lt.status}${lt.status === 'FAIL' ? ' after the stronger fix round' : ''}: ${why}` }
  }
  if (!r.mrs.length) return { id: a.id, report: r, findings: [] }
  const rv = await agent(reviewPrompt(a, r), { label: `review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'revy', ...pick('review') })
  if (!rv) return { id: a.id, report: r, findings: [BLOCK(r.mrs, 'The review agent returned nothing: the MRs are unreviewed and were not merged.', REREVIEW)], reviewFailed: true }
  const findings = rv.findings || []
  let x = { id: a.id, report: r, findings }
  let blocking = findings.filter(mustFix)
  if (!blocking.length) blocking = await ciGate(a, r)
  if (blocking.length) {
   if (!(await gate('Fix'))) return { ...x, budgetStopped: true }
   log(`${a.id}: ${blocking.length} blocking finding(s) / failed pipeline(s) -> fix round`)
   const r2 = await agent(fixPrompt(a, r, blocking), { label: `fix:${a.id}`, phase: 'Fix', schema: REPORT, agentType: 'devy', ...modelOf(a) })
   if (!r2) return { ...x, findings: [...findings, ...blocking], fixed: false, stopped: true }
   x = { ...x, findings: [...findings.filter((f) => !mustFix(f)), ...blocking], fixed: true, report: await localLoop(a, mergeReports(r, r2, 'Fix round'), 0, 'Fix') }
   const lt2 = x.report.localTest || {}
   if (lt2.status === 'BLOCKED' || lt2.status === 'FAIL') return { ...x, fixed: false, blocked: `local test ${lt2.status} after the fix round` }
   if (findings.some(mustFix)) {
    const rv2 = await agent(reviewPrompt(a, x.report) + `\nRE-REVIEW after the fix round: check that these findings are resolved and that the fix added no new problem:\n${findings.filter(mustFix).map((f) => `- ${f.file}${f.line ? ':' + f.line : ''}: ${f.problem}`).join('\n')}`,
     { label: `review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'revy', ...pick('review') })
    const again = rv2 ? (rv2.findings || []).filter(mustFix) : [BLOCK(x.report.mrs, 'The re-review agent returned nothing: the fix round is unreviewed and was not merged.', REREVIEW)]
    if (again.length) { log(`${a.id}: re-review after the fix round: ${again.length} finding(s) - not merged`); return { ...x, fixed: false, findings: [...x.findings, ...again] } }
   }
   const failures = await ciGate(a, x.report)
   if (failures.length) { log(`${a.id}: pipelines still failing after the fix round - left open`); return { ...x, fixed: false, findings: [...x.findings, ...failures] } }
  }
  return ship(a, x)
 }).then((y) => { SETTLED[a.id].done(y); return y }),
 // Track: register the tracker task (promoted once all MRs merge, also by hand)
 async (x, a) => {
  if (!x || x.error || !x.report || !x.report.mrs.length) return x
  const deferred = x.report.deferred || []
  const why = x.blocked || (x.budgetStopped ? 'run budget reached: continues in the next run' : '') || (deferred.length ? `deferred items: ${deferred.map((d) => d.id).join(', ')}` : x.stopped ? 'agent stopped' : '')
  if (why) log(`${a.id}: tracker task registered with its promotion HELD (${why}): release with orch.ps1 track add -Task <id> -HoldPromotion ''`)
  const tr = await agent(`STEP: register devy ${a.id}'s tracker task for its MRs. Change no code, merge nothing.${PATHS}${AGENT_ENV(`track-${a.id}`)}
MRs: ${x.report.mrs.map((m) => m.url).join(', ')}
1. The task id is in each MR's title after the tracker tag (the title wins over the branch); group the MRs by task.
2. Per task: & ${ORCH} track add -Task <task id> -Discover -Mrs '<repo>!<iid>','<repo>!<iid>'${why ? ` -HoldPromotion '${why.replace(/'/g, '').slice(0, 200)}'` : ''}
Return ok=true and the output lines.`, { label: `track:${a.id}`, phase: 'Fix', schema: OK_SCHEMA, agentType: 'devy', ...pick('ship'), effort: 'low' })
  if (!tr || !tr.ok) log(`${a.id}: WARNING tracker task not registered (${tr ? tr.output : 'agent returned nothing'})`)
  return why ? { ...x, trackHeld: why } : x
 },
)

// ---- ship: CI gate, merge, outcome
async function ciGate(a, r) {
 if (!r.mrs.some((m) => !m.merged)) return []
 const ci = await agent(ciPrompt(r, a), { label: `ci:${a.id}`, phase: 'Review', schema: CI_SCHEMA, agentType: 'devy', ...pick('ci'), effort: 'low' })
 if (!ci) { log(`${a.id}: WARNING CI gate agent returned nothing; merge-when-green still waits for the pipelines`); return [] }
 return (ci.mrs || []).filter((m) => m.status === 'failed').map((m) => ({ mr: m.mr, file: `CI job ${m.job || '?'}`, severity: 'blocking',
  problem: `The MR pipeline failed in job ${m.job || '?'}:\n${m.error || '(no error text captured)'}`,
  fix: 'Reproduce the failing job locally through the gate (dev.ps1 check), fix the cause, push, green pipeline.' }))
}
async function ship(a, x) {
 const held = x.report.mrs.filter((m) => !m.merged && isHeld(m))
 if (held.length) log(`${a.id}: ${held.length} MR(s) held for approval (holdMerge): ${held.map((m) => m.url).join(', ')}`)
 if (!toShip(x.report).length) return x
 let wait = []
 if (DEPS[a.id].length) {
  log(`${a.id}: waiting for producer area(s) ${DEPS[a.id].join(', ')} before merging`)
  const prods = await Promise.all(DEPS[a.id].map((id) => SETTLED[id].p))
  const missing = DEPS[a.id].filter((id, i) => !prods[i] || !prods[i].report || !prods[i].report.mrs.length)
  if (missing.length) return { ...x, shipFindings: [BLOCK(x.report.mrs, `Producer area(s) ${missing.join(', ')} reported no MRs: not merged (merge order).`, 'Ship the producer first, then merge these.')], mergeOrderHeld: true }
  wait = prods.flatMap((p) => p.report.mrs.filter((m) => !m.merged))
 }
 const r3 = await agent(shipPrompt(a, x.report, wait), { label: `ship:${a.id}`, phase: 'Fix', schema: REPORT, agentType: 'devy', ...pick('ship'), effort: 'low' })
 if (!r3) { log(`${a.id}: WARNING ship agent returned nothing - MRs not scheduled`); return x }
 const state = new Map(r3.mrs.map((m) => [nu(m.url), m.mergeState || (m.merged ? 'MERGED' : 'OPEN')]))
 const mrs = x.report.mrs.map((m) => { const s = m.merged ? 'MERGED' : (state.get(nu(m.url)) || m.mergeState || 'OPEN'); return { ...m, mergeState: s, merged: s === 'MERGED' } })
 const conflicts = mrs.filter((m) => m.mergeState === 'CONFLICT').map((m) => BLOCK([m], `Merge conflict outside append-only files: ${r3.summary}`.slice(0, 1500), 'wt sync, resolve by hand, re-check, push --force-with-lease, devtools.py merge again.'))
 // every merge word that is not MERGED / SCHEDULED / CONFLICT leads to its own next step for the coordinator (openFindings)
 const NEXT = { 'WAIT': 'devtools.py merge again in a few minutes (or orch.ps1 track run once the producer merged)',
  'PIPELINE_FAILED': 'reproduce the failing job locally through the gate (dev.ps1 check), fix it on the branch, push, merge again (a follow-up /buildy fix round)',
  'NOT_MERGED': 'read the MR state (approvals, draft, permissions), then devtools.py merge again or merge by hand',
  'OPEN': 'the ship step did not reach a merge: devtools.py merge again' }
 for (const m of mrs.filter((m) => !isHeld(m) && m.mergeState in NEXT)) {
  conflicts.push({ mr: m.url, file: '-', severity: 'blocking', problem: `Not merged (${m.mergeState}): ${r3.summary}`.slice(0, 1500), fix: NEXT[m.mergeState] })
 }
 return { ...x, shipFindings: conflicts, report: { ...x.report, mrs, summary: `MR state (authoritative): ${mrs.map((m) => `${m.url} ${m.mergeState}`).join(', ')}\n\n${x.report.summary}` } }
}

const out = results.filter(Boolean)
for (const x of out) {
 if (x.error) { log(`${x.id}: ERROR ${x.error}`); continue }
 const r = x.report
 log(`${x.id}: ${r.mrs.filter((m) => m.merged).length}/${r.mrs.length} MRs merged, scheduled ${r.mrs.filter((m) => m.mergeState === 'SCHEDULED').length}, local ${(r.localTest || {}).status || '?'}, done ${r.done.length}, deferred ${r.deferred.length}${x.blocked ? `, BLOCKED (${x.blocked})` : ''}`)
}
const outcome = {
 agents: out,
 deferred: out.flatMap((x) => (x.report ? x.report.deferred.map((d) => ({ agent: x.id, ...d })) : [])),
 blocked: out.filter((x) => x.blocked).map((x) => ({ agent: x.id, why: x.blocked })),
 decisions,
 envFixes,
 needsLiveCheck: out.flatMap((x) => (x.report ? x.report.needsLiveCheck : [])),
 seed: out.flatMap((x) => (x.report ? x.report.seed : [])),
 openFindings: out.flatMap((x) => [...(x.fixed ? [] : (x.findings || []).filter(mustFix)), ...(x.shipFindings || [])]),
 testerGuides: out.filter((x) => x.report).map((x) => ({ agent: x.id, guide: x.report.testerGuide || 'MISSING' })),
 budget: { cap: BUD.cap, estimate: BUD.estimate, spent: BUD.spent, stopped: BUD.stop, handoffs: out.filter((x) => /Handoff:/.test((x.report || {}).summary || '')).map((x) => x.id) },
}
// unfinished areas (budget stop) and areas beyond args.batch continue in a ready relaunch
const leftover = [...out.filter((x) => x.budgetStopped).map((x) => A0.agents.find((g) => g.id === x.id)).filter(Boolean), ...(BATCH ? A0.agents.slice(BATCH) : [])]
if (leftover.length) { outcome.next = nextCall(leftover, out.some((x) => x.budgetStopped) ? { mode: 'resume' } : {}); log(`NEXT: ${leftover.length} area(s) continue in a new run: ${leftover.map((g) => g.id).join(', ')} (outcome.next)`) }
for (const g of outcome.testerGuides) if (!g.guide || g.guide === 'MISSING' || /^none/i.test(g.guide)) log(`${g.agent}: no human testing doc (${g.guide}) - the coordinator writes or requests one before testers start`)

// ---- deploy: merged work joins the deploy batch
// Deploy (extra deploys; skipped without it): merged (or merge-scheduled) work joins the batch silently. deploy.trigger owner (default):
// nobody asks or proposes a deploy, a person says "deploy <env>" (orchestrate E5); ask: the coordinator asks once per env. Never deploys.
phase('Deploy')
const shipped = out.flatMap((x) => (x.report ? x.report.mrs.filter((m) => m.merged || m.mergeState === 'SCHEDULED').map((m) => m.url) : []))
const DEPLOYS = `${KIT}/skills/orchestrate/adapters/deploys.ps1`
const dp = shipped.length ? await runStep(`if (Test-Path '${DEPLOYS}') { & ${ORCH} deploy request -Mrs ${shipped.join(',')} -Run ${RUN} -Note "buildy ${RUN}" | Out-Null; & ${ORCH} deploy plan -Json } else { 'NO-DEPLOYS' }`,
 'deploy-batch', 'Deploy', { whole: true }) : null
if (dp && /NO-DEPLOYS/.test(dp.output || '')) log('deploy batch skipped: the deploys extra is not installed (merged work waits for a person)')
else if (shipped.length) {
 try { outcome.deployBatch = JSON.parse((dp && dp.output) || '[]') } catch (e) { outcome.deployBatch = { raw: dp ? dp.output : 'deploy-batch agent returned nothing' } }
 const ask = Array.isArray(outcome.deployBatch) && outcome.deployBatch.some((p) => p && p.trigger === 'ask')
 log(ask ? `DEPLOY ASK: ${shipped.length} MR(s) merged; the coordinator shows the batch (orch.ps1 deploy plan) and asks the owner once per env`
  : `DEPLOY BATCH: ${shipped.length} MR(s) merged; they wait for a person's "deploy <env>" (nobody asks)`)
}

// ---- learn: signals for /tidy
phase('Learn')
const retroDue = (o) => { log('RETRO DUE: run /tidy once no other workflow of this session runs'); return { ...o, retroDue: true } }
const eventful = out.some((x) => x.error || x.blocked || x.fixed !== undefined || (x.findings || []).length || (x.report && x.report.deferred.length)) || outcome.openFindings.length > 0 || decisions.length > 0 || envFixes.length > 0
if (LEARN === false || (LEARN === 'auto' && !eventful)) {
 await runStep(`& ${ORCH} cleanup -Quiet -WorktreeIdleHours 0`, 'cleanup', 'Learn')
 return retroDue(outcome)
}
// signals only: /tidy (run after every finished run) turns them into lessons
const learned = await agent(`Kind retro (learn step): record this /buildy run's signals.${PATHS}
Outcome (JSON):
${JSON.stringify(outcome).slice(0, 60000)}

1. One signal per notable event (failures, local-test rounds, blocked items, decisions, review findings, deferrals, budget stops / handoffs, anything that cost
 time or worked unusually well): & ${ORCH} learn -Skill <dev-kit|local-env|other skill> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. & ${ORCH} cleanup -Quiet -WorktreeIdleHours 0, then Get-Content ${rp('cleanup-log')} -Tail 15: mention what was freed.
Return how many signals you recorded.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, agentType: 'kitty', ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s)`)
return retroDue(outcome)
