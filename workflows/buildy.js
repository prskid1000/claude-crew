export const meta = {
 name: 'buildy',
 description: 'The dev flow for any multi-item build (any stack): devy code, goals, local loop, decisions; review, CI, merge (producers first), testing docs + tracker; deploys on a person\'s word',
 whenToUse: 'Coding (features, fixes, QA-raised bugs or failedTesting tasks) with more than 2 items, 2+ repos, or one large item (new feature, migrations, many screens)',
 phases: [
  { title: 'Spike', detail: 'one rechy answers args.openQuestions in the brief before any devy' },
  { title: 'Build', detail: 'a devy per area: worktree, code, testing goals, local loop, MRs, testing docs' },
  { title: 'Decide', detail: 'items paused for an owner decision or ENV-FIX resume after the answer' },
  { title: 'Review', detail: 'a revy per devy (+ datay on migrations) + CI pipelines' },
  { title: 'Fix', detail: 'a fix round (local tests again); a re-review holds only on blocking (one more round, then a decide ask; rest -> MR Follow-ups); merge in order, tracker task' },
  { title: 'Deploy', detail: 'merged work joins the deploy batch (bossy.ps1 deploy); a person says deploy <env>, never asked' },
  { title: 'Learn', detail: 'signals from this wave, cleanup (/tidy makes lessons)' },
 ],
}

// Sections: L18 args · L146 record-args · L165 budget · L183 build-prompt · L267 ship-prompt · L284 plan · L303 spike ·
//   L315 local-loop · L403 stages · L557 ship · L597 debate · L706 deploy · L721 learn
// ---- args: the run's input, checked
/* args = { brief: '<abs>/wave-brief.md' (required; templates.md "Wave" / "Bug-fix" / "Resume brief"), task: '<tracker id>' (2+ areas: AREA TASK subtasks),
 agents: [{ id, items, area, task, paths: [globs], note, kind, branch(es), complex, model, effort, dependsOn: [ids merged first],
  migrations (datay reviews), debate: { item, question, options: [A, B], owner } }], debateModels: [A, B], openQuestions: [q] (rechy first),
 mandate: [owner words], mode: feature | bugfix | resume, resume: { X1: { state, skip: [STEPS], mrs, doc, worktrees, uncommitted } } (bossy.ps1 recover),
 complex: [ids], phases: true (devy per phase) | false, holdMerge: [repo] | true, learn: true | false | 'auto', batch: <areas per run>,
 kitDir: '<abs .claude>', runtimeDir, run: '<board run>' }
Returns { resumedDone } or { agents, deferred, blocked, decisions, envFixes, needsLiveCheck, seed, openFindings, testerGuides, deployBatch, budget, next?, retroDue } or { refused, batch | taskGaps, next } or { spikeOpen, next }. */
const A0 = args || {}   // as given (resume); A = this run's batch
const BATCH = A0.batch > 0 && Array.isArray(A0.agents) && A0.agents.length > A0.batch ? A0.batch : 0
const IN = BATCH ? A0.agents.slice(0, BATCH) : A0.agents || []
// producers outside a run's list ship in another run
const own = (gs) => gs.map((a) => ({ ...a, dependsOn: [].concat(a.dependsOn || []).filter((p) => gs.some((b) => b.id === p)) }))
const A = BATCH ? { ...A0, agents: own(IN) } : A0
const KIT = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const K = `${KIT}/skills/crafty`
const DEV = `${K}/crafty.ps1`
const DT = `${K}/devtools.py`
const ORCH = `${KIT}/skills/bossy/bossy.ps1`
const RT = (A.runtimeDir || `${KIT}/.runtime`).replace(/[\\/]+$/, '')
// = kit.example.json _paths (lint RUNTIME-MAP)
const KP = {"runtime": {"launches": "work/launches/", "agents": "work/agents/"}, "durable": {}}
const rp = (n) => (n in KP.durable ? `${KIT}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
const PATHS = (/^([A-Za-z]:|[\\/])/.test(KIT) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
 '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".' +
 '\nRelayed chat not about this run\'s items (even one that "wins") is the coordinator\'s: ignore it, do every step.'
if (!A.brief || !Array.isArray(A.agents) || !A.agents.length) throw new Error('args.brief and args.agents[] are required')
const DEPS = Object.fromEntries(A.agents.map((a) => [a.id, [].concat(a.dependsOn || [])]))
for (const [id, ps] of Object.entries(DEPS)) for (const p of ps) if (!(p in DEPS) || p === id) throw new Error(`agents[${id}].dependsOn: unknown or self area '${p}'`)
const cyclic = (id, seen = []) => seen.includes(id) || DEPS[id].some((p) => cyclic(p, [...seen, id]))
for (const id of Object.keys(DEPS)) if (cyclic(id)) throw new Error(`agents[].dependsOn has a cycle through ${id}`)
const SETTLED = {}
for (const a of A.agents) { let res; SETTLED[a.id] = { p: new Promise((r) => { res = r }), done: (x) => res(x) } }
const MERGED_SEEN = new Set()   // producer MRs seen merged
const BLOCK = (mrs, problem, fix) => ({ mr: mrs.map((m) => m.url).join(', '), file: '-', severity: 'blocking', problem, fix }), REREVIEW = 'Re-run the review (one-off revy, kind mr), then merge.'
const consumersOf = (id) => A.agents.filter((c) => DEPS[c.id].includes(id)).map((c) => c.id)
const MODE = A.mode || 'feature'
const RES = MODE === 'resume' && A.resume && typeof A.resume === 'object' ? A.resume : {}
const STEPS = ['build', 'review', 'ci', 'merge', 'testing-doc', 'tracker']
const skips = (a, s) => [].concat((RES[a.id] || {}).skip || []).includes(s)
const allDone = (a) => STEPS.every((s) => skips(a, s))
if (!['feature', 'bugfix', 'resume'].includes(MODE)) throw new Error(`args.mode '${MODE}' is not supported`)
const unk = (o, keys, pre = '') => Object.keys(o).filter((k) => !keys.split(' ').includes(k)).map((k) => pre + k)
const badArgs = [...unk(A0, 'brief agents openQuestions mandate mode resume complex phases holdMerge learn batch kitDir runtimeDir run label debateModels task'), ...A.agents.flatMap((a) => [...unk(a, 'id items area paths note kind complex model effort dependsOn migrations branch branches debate task', `agents.${a.id}.`),
 ...(a.debate && [].concat(a.debate.options || []).length !== 2 ? [`agents.${a.id}.debate.options (2)`] : [])])]
if (badArgs.length) throw new Error(`buildy.js args refused: unknown ${badArgs.join(', ')}; free text: agents[].note or the brief`)
if (!A.mandate || !A.mandate.length) log('WARNING: no args.mandate (owner words): agents may drop items for the latest chat message (bossy step 3).')
const RUN = A.run || `${(A.brief.split(/[\\/]/).pop() || 'wave').replace(/\.md$/, '')}-${fnv(String(A.brief)).slice(0, 4)}`   // hash: same name, other wave
const LEARN = A.learn === undefined ? true : A.learn
const LOCAL_RETRIES = 1
const PHASED = A.phases !== false && MODE !== 'resume'   // a fresh devy per phase: no context carries 300+ calls
// 9-minute wait slices: 34 = ~5 h
const WAIT_SLICES = 34
const ENV_FIX_CYCLES = 2
const HOLD = A.holdMerge === true ? ['*'] : (Array.isArray(A.holdMerge) ? A.holdMerge : [])
const HOLD_NOTE = HOLD.length
 ? `\nMERGE HOLD: never merge or schedule a merge for MRs in ${HOLD.includes('*') ? 'ANY repo' : HOLD.join(', ')} (their branch deploys; the owner approves): open and green, merged=false, "held for approval".`
 : ''
const nu = (u) => String(u || '').replace(/[?#].*$/, '').replace(/\/+$/, '').toLowerCase()
const uniqMr = (l) => l.filter((m, i) => l.findIndex((n) => nu(n.url) === nu(m.url)) === i).map((m) => ({ ...m, merged: l.every((n) => nu(n.url) !== nu(m.url) || n.merged) }))   // one MR's copies: merged if all say so
const ENV = (name) => PATHS + AGENT_ENV(name), AGENT_ENV = (name) => `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${name}';  (Bash: export CLAUDE_AGENT='${name}';) - the build gate's
owner name for your builds (shell state does not persist).`

const S = { type: 'string' }, SA = { type: 'array', items: S }, B = { type: 'boolean' }, N = { type: 'number' }, obj = (p, req = Object.keys(p)) => ({ type: 'object', properties: p, required: req })
const REPORT = {
 type: 'object',
 properties: {
  mrs: { type: 'array', items: obj({ url: S, repo: S,
   merged: { ...B, description: 'only on a confirmed merge (MERGED printed, or the host)' },
   mergeState: { ...S, enum: ['MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED', 'OPEN'] } }, ['url', 'repo', 'merged']) },
  worktrees: SA,
  done: { ...SA, description: 'item ids done: local pass, MR open' },
  deferred: { type: 'array', items: obj({ id: S, reason: S, ownerDecided: B, kind: { enum: ['code', 'people'], description: 'people: no code' } }, ['id', 'reason']) },
  needsDecision: { type: 'array', items: obj({ item: S, decisionId: { ...S, description: 'decide ask id' }, question: S }), description: 'items waiting on the owner' },
  debate: { type: 'array', items: obj({ item: S, question: S, options: SA }), description: '2 paths no test settles: "A: <label> — <effect>"' },
  disputes: { type: 'array', items: obj({ finding: S, evidence: S }), description: 'contested findings; evidence: file:line, test or measurement' },
  needsEnvFix: { type: 'array', items: obj({ item: S, envFixId: { ...S, description: 'decide ask -Kind envfix id' }, need: S }), description: 'items waiting on a coordinator env fix' },
  localTest: { type: 'object', properties: {
   status: { ...S, enum: ['PASS', 'FAIL', 'BLOCKED', 'NONE'], description: 'PASS goals met, clean logs · FAIL · BLOCKED owner / remote-only · NONE no local env' },
   decisionId: { ...S, description: 'NONE: decide id allowing the merge' },
   fallback: { ...S, enum: ['ci', 'unit'], description: 'NONE: the localFallback that passed' },
   unitRun: { ...obj({ command: S, result: S }), description: 'fallback unit: check + result' },
   blockedKind: { ...S, enum: ['decision', 'remote'], description: 'BLOCKED: owner / remote-only system' },
   blockedReason: { ...S, description: 'decision id or remote dependency' },
   envGap: { ...B, description: 'FAIL: every failing goal is an env gap' },
   env: { ...S, description: '<env> r<n> | none: <why>' }, rounds: N,
   failing: { ...SA, description: 'failing goal ids, a line each' },
   goalsDoc: { ...S, description: 'cases render <task> goals path' } }, required: ['status', 'env', 'rounds', 'failing', 'goalsDoc'] },
  needsLiveCheck: SA,
  testerGuide: { ...S, description: 'human testing doc link' },
  seed: { ...SA, description: 'seed after deploy' },
  foreignHooks: SA,
  summary: { ...S, description: '<=200 words; merge state: mrs' },
  handoff: { ...S, description: 'handoff only: resume brief path' },
 },
 required: ['mrs', 'worktrees', 'done', 'deferred', 'needsDecision', 'localTest', 'needsLiveCheck', 'seed', 'foreignHooks', 'summary', 'testerGuide'],
}
const REVIEW_SCHEMA = obj({ findings: { type: 'array', items: obj({ mr: S, file: S, line: N, severity: { ...S, enum: ['blocking', 'should-fix', 'nit'] }, problem: S, fix: S }, ['mr', 'file', 'severity', 'problem', 'fix']) } })
const FIXES = { blocking: true, 'should-fix': true, nit: false }
const mustFix = (f) => FIXES[f.severity] !== false
const CI_SCHEMA = obj({ done: B, mrs: { type: 'array', items: obj({ mr: S, status: S, job: S, error: S }, ['mr', 'status']) } })
const OK_SCHEMA = obj({ ok: B, output: S }), LEARN_SCHEMA = obj({ signals: N })
// STEP agent: kit commands as kitty, product MRs as devy
const SO = (label, phase, model = MODELS.step) => ({ label, phase, schema: OK_SCHEMA, model, effort: 'low' })
const runStep = (cmd, label, phaseName, { ok = 'when it ran', slow = false, whole = false } = {}) =>
 agent(`STEP: run exactly this in PowerShell${slow ? ' (tool timeout 600000)' : ''} and return ok=true ${ok} (else ok=false) with ${whole ? 'its full output' : 'its last output line'}, nothing else:${PATHS}\n${cmd}`, { ...SO(label, phaseName), agentType: 'kitty' })

const WHY = `WHY: ${A.mandate && A.mandate.length ? `the owner asked for this, verbatim:\n${[].concat(A.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}Your items below ARE that request.
`
// tier -> model; CONFIG tiers, models win
const TIERS = { fast: 'haiku', balanced: 'sonnet', strong: 'opus', inherit: '' }, [TF, TB, TS] = ['fast', 'balanced', 'strong']
const MT = { spike: TS, debate: TB, build: TB, review: TB, ci: TF, ship: TF, docs: TB, learn: TF, complex: 'inherit', retest: TS, retestEffort: 'high', step: TF, stepRetry: TB }
const MODELS = {}, setStr = (o, src) => { for (const [k, v] of Object.entries(src || {})) if (typeof v === 'string') o[k] = v }
const tierModels = () => { for (const [k, v] of Object.entries(MT)) MODELS[k] = v in TIERS ? TIERS[v] : v }
tierModels()
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
const PM = (stage) => `@${stage}=${MODELS[stage] || ''}`   // plan token
// repos[].role (name / alias): merge order
const CFG = { roles: {}, local: {} }
function takeConfig(out) {
 let c
 try { c = JSON.parse((/^CONFIG (\{.*\})\s*$/m.exec(out || '') || [])[1]) } catch (e) { }
 if (!c) { log('WARNING: no CONFIG line: default models, no repo roles'); return }
 setStr(TIERS, c.tiers); setStr(MT, c.models); tierModels()
 CFG.roles = c.roles || {}
 CFG.local = c.local || {}; CFG.humanDoc = c.humanDoc
}
// ---- record-args: the launch record (byte-exact: a resume reads it)
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
 for (const [label, model] of [['record-args', MODELS.step], ['record-args-retry', MODELS.stepRetry]]) {
  const r = await agent(prompt, { ...SO(label, phaseName, model), agentType: 'kitty' })
  if (r && r.ok) return r.output || ''
 }
 log('WARNING: launch args not recorded (bossy.ps1 launch -Self failed twice): a resume needs them by hand')
 return ''
}
// ---- budget: over the cap -> refused + split; at stopAt the rest -> next
const BUD = { cap: 0, estimate: 0, stopAt: 0.8, spent: 0, guess: 0, stop: false, unit: 0 }
function takeBudget(out, units) {
 try { Object.assign(BUD, JSON.parse((/BUDGET (\{.*\})/.exec(out) || [])[1])); BUD.unit = BUD.estimate / Math.max(1, units) } catch (e) { log('WARNING: no BUDGET line from launch -Self: this run is not budget-gated') }
}
async function measure(phaseName) {
 const r = await runStep(`& ${ORCH} budget -Run '${RUN}' -Json`, 'budget', phaseName).catch(() => null)
 try { BUD.spent = JSON.parse(r.output).spent; BUD.guess = 0 } catch (e) {}
}
async function gate(phaseName) {   // before a new round
 if (BUD.stop || !BUD.cap) return !BUD.stop
 BUD.guess += BUD.unit
 if (BUD.spent + BUD.guess < 0.6 * BUD.stopAt * BUD.cap) return true
 BUD.m = BUD.m || measure(phaseName).then(() => { BUD.m = null })
 await BUD.m
 if (BUD.spent >= BUD.stopAt * BUD.cap && !BUD.stop) { BUD.stop = true; log(`BUDGET: spent ${BUD.spent} of the cap ${BUD.cap}: no new round; the rest -> next`) }
 return !BUD.stop
}
// ---- build-prompt: devy, revy, fix and CI prompts
const isComplex = (a) => a.complex === true || [].concat(A.complex || []).includes(a.id)
const modelOf = (a) => ({ ...(a.model ? { model: a.model } : pick(isComplex(a) ? 'complex' : 'build')), ...(a.effort ? { effort: a.effort } : {}) })
const dvo = (a, l, phase) => ({ label: `${l}:${a.id}`, phase, schema: REPORT, agentType: 'devy', ...modelOf(a) })

function depNote(a) {
 const ps = DEPS[a.id], cs = consumersOf(a.id)
 return (ps.length ? `MERGE ORDER: you consume ${ps.join(', ')} (merged first): name their MRs in your MR description.\n` : '') +
  (cs.length ? `MERGE ORDER: ${cs.join(', ')} consume your work: open your MRs early, say which MR carries the contract.\n` : '')
}
const globs = (a) => [].concat(a.paths || []).join(',')
const isFnd = (a) => (a || {}).kind === 'foundation'   // no human-facing change: no human doc, merge --no-docs (logged)
const areaNote = (a) => (globs(a) ? `AREA PATHS: wt lease -Scope '${globs(a)}'.\n` : '') + (AREA_TASK[a.id] ? `TRACKER TASK: ${AREA_TASK[a.id]} (subtask of ${a.task || A.task}) = <task> in every tracker step (status, MR title, track add); never the parent's status.\n` : '')
const IBW = 'your agent definition\'s "In a /buildy wave"', SW = `${K}/ship.md "In a /buildy wave"`
const FLOW = `THE DEV FLOW = crafty SKILL.md steps 0-9 and your agent rules with ${IBW} commands: run ${RUN}, mode ${MODE}, <O> = ${ORCH}. Do NOT merge (the workflow does): merged=false, mergeState OPEN.`
// args.phases: a fresh devy per phase; branch, checkpoints, cases spec carry state
const PH = {
 code: `\nPHASE code (1 of 3): crafty steps 0-4 only (code, cases spec, unit tests, commit, push), checkpoint -Step commit; no MR. Report localTest NONE (env "phase code") and stop: a fresh devy runs step 5.`,
 local: `PHASE local (2 of 3): crafty step 5 only on your pushed branch (a fix: steps 3-4 again), checkpoint -Step loop; no MR. Report localTest and stop: a fresh devy ships.`,
 ship: `PHASE ship (3 of 3): ${K}/ship.md steps 6-9 only (MR, docs, tracker, deploy batch); code changes only when a check fails. Report.`,
 held: ' The local loop is held (FAIL, BLOCKED or not run): Draft MRs only; no finish, tracker step or deploy request.' }

function buildPrompt(a) {
 const dn = a.debate && MODE !== 'resume' ? `ITEM ${a.debate.item} WAITS for the owner (${a.debate.question}; the workflow debates and asks): build the rest, never report it.\n` : '', rs = RES[a.id] || {}
 return `${WHY}${dn}
You are devy ${a.id} in a parallel wave (${MODE}; kind: ${a.kind || (MODE === 'bugfix' ? 'fix' : 'feature')}).${ENV(a.id)}
Follow ${K}/SKILL.md (tools ${DEV}, ${DT}) and the brief ${A.brief} (it wins): its head, Repos, your Agents row, Contracts, rule changes only.
${MODE === 'resume' ? `RESUMING: done steps at recovery: ${[].concat(rs.skip || []).join(', ') || 'none'}${(rs.mrs || []).length ? `; open MRs ${rs.mrs.map((m) => m.url).join(' ')}` : ''}${(rs.worktrees || []).length ? `; worktrees ${rs.worktrees.join(' ')} (continue there)` : ''}; the rest: templates.md "Resume brief".\n` : ''}YOU ARE ${a.id}. Items: ${a.items}. Area: ${a.area}.
Board: & ${ORCH} board join -Type devy -Run ${RUN} -Area ${a.id} -Contracts <brief>.contracts.md (if any); DUPLICATE -> stop without writing.
Worktrees: pool slots leased as ${a.id} (crafty Rules "Worktrees"). Never touch other agents' slots, branches or processes.
${a.note || ''}
${depNote(a)}${areaNote(a)}${FLOW}${HOLD_NOTE}
Return the report.`
}
function synth(a) {
 const s = RES[a.id], stage = allDone(a) ? 'done' : skips(a, 'merge') ? 'merged' : 'open'
 return { mrs: (s.mrs || []).map((m) => ({ ...m, merged: !!m.merged, mergeState: m.merged ? 'MERGED' : 'OPEN' })), worktrees: uniqPath(s.worktrees || []), done: String(a.items || '').split(',').map((x) => x.trim()).filter(Boolean),
  deferred: [], needsDecision: [], needsEnvFix: [], localTest: { status: 'PASS', env: `before the stop (resume: ${stage})`, rounds: 0, failing: [], goalsDoc: '' }, needsLiveCheck: [], seed: [], foreignHooks: [],
  summary: `resumed: skipped ${[].concat(s.skip || []).join(', ')}`, testerGuide: s.doc || '', resumed: stage }
}
function postMergePrompt(a, r) {
 return continuePrompt(a, r, `RESUME, ONLY THE HUMAN TESTING DOC: every MR below is MERGED (host-verified at recovery); build, review, CI and merge are done: never redo them, open no branch or MR.
${r.mrs.map((m) => `- ${m.url}`).join('\n')}
Complete the cases spec (devtools.py cases add / result), run devtools.py finish <task> cases solution.json review --ai cases (updates the task's docs, never new ones). Report these MRs merged=true, testerGuide = the human doc link.`)
}
function continuePrompt(a, r, why) {
 return `${WHY}
You are devy ${a.id} again (items ${a.items}, area ${a.area}).${ENV(a.id)}
Follow ${K}/SKILL.md and ${A.brief}. Your slots were released: lease your branch again (crafty.ps1 wt lease -Repo <repo> -Branch <branch> -Agent ${a.id}; last in ${(r.worktrees || []).join(', ') || 'see the board'}). Testing-goals doc: ${(r.localTest || {}).goalsDoc || '(yours)'}.
${why}
${areaNote(a)}${FLOW}${HOLD_NOTE}
Return the full report (every MR, all items done so far).`
}
function reviewPrompt(a, r) {
 return `Kind mr: review devy ${a.id}'s MRs (items ${a.items}, area ${a.area}; brief ${A.brief}; run ${RUN}) per your agent definition.${ENV(`review-${a.id}`)}
${r.mrs.map((m) => `- ${m.url} (${m.repo}${m.merged ? ', merged' : ''})`).join('\n')}
Testing-goals doc: ${(r.localTest || {}).goalsDoc || '(none reported)'}; local test: ${(r.localTest || {}).status || '?'} on ${(r.localTest || {}).env || '?'}.
Rules: ${K}/SKILL.md Rules (scope, tests, migrations). Only real problems; "blocking" = must be fixed before it ships (an unasked
user-visible behaviour change is; same behaviour, other internals is not). No code changes; a suggested change per finding; scope: the brief + these MRs.`
}
function migrationPrompt(a, r) {
 return `Kind migration: review the migrations in devy ${a.id}'s MRs (brief ${A.brief}; run ${RUN}) per your agent definition; findings only.${ENV(`migration-review-${a.id}`)}
${r.mrs.map((m) => `- ${m.url} (${m.repo})`).join('\n')}
blocking = data loss, no rollback, rows touched outside the change's filter. Return the findings (review schema).`
}
const reviews = (a, r, more = '', none = null) => Promise.all([agent(reviewPrompt(a, r) + more, { label: `review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'revy', ...pick('review') }),
 a.migrations ? agent(migrationPrompt(a, r) + more, { label: `migration-review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'datay', ...pick('review') }) : none])
const fkey = (f) => `${f.file}${f.line ? ':' + f.line : ''}`
const cl = (s, n) => String(s || '').replace(/["'`$\r\n]+/g, ' ').replace(/,/g, ';').slice(0, n)   // one quoted pwsh arg
const ANSWERS = obj({ answers: { type: 'array', items: obj({ finding: S, verdict: { enum: ['withdrawn', 'upheld'] }, evidence: S, why: S }, ['finding', 'verdict', 'evidence']) } })
const DEB = { used: 0 }, DM = [].concat(A.debateModels || [])
const debated = (o, item, id, question) => id ? { ...o, needsDecision: [...(o.needsDecision || []), { item, decisionId: id, question }] } : { ...o, deferred: [...(o.deferred || []), { id: item, reason: 'debate and ask failed: the coordinator decides' }] }
const defer = (o, l) => ({ ...o, deferred: byId([...(o.deferred || []), ...l]) })
function fixPrompt(a, r, findings) {
 return continuePrompt(a, r, `Review or CI found these problems in your MRs (blocking, should-fix): fix each, or CONTEST one you can
disprove in disputes[] (evidence: file:line, a test, a measurement; revy answers once, then the owner); never skip one silently:
${findings.map((f) => `- ${f.mr} ${fkey(f)}: ${f.problem} -> ${f.fix}`).join('\n')}
Then ${SW} FIX round.`)
}
function ciPrompt(r, a) {
 return `STEP: run exactly this PowerShell command (tool timeout 600000) and return its JSON output (fields done, mrs). Nothing else.${PATHS}
$env:CLAUDE_AGENT='ci-${a.id}'; & ${DEV} pipes -Mrs ${r.mrs.filter((m) => !m.merged).map((m) => m.url).join(',')} -MaxMinutes 8
Repeat while "done": false (3 runs at most); return the last JSON.`
}
// ---- ship-prompt: merge order and holds
const isHeld = (m) => HOLD.includes('*') || HOLD.includes(m.repo) || HOLD.some((h) => (m.url || '').includes(`/${h}/`))
const repoNames = (m) => [m.repo, String(m.url || '').replace(/[?#].*$/, '').replace(/\/(-\/)?(merge_requests|pulls?|pull-requests|pullrequest)\/.*$/i, '').split('/').pop()].map((s) => String(s || '').toLowerCase()).filter(Boolean)
const roleOf = (m) => repoNames(m).map((n) => CFG.roles[n]).find(Boolean) || ''
const isConsumer = (m) => roleOf(m) === 'consumer'
const isProducer = (m) => roleOf(m) === 'producer'
const toShip = (r) => { const open = uniqMr(r.mrs).filter((m) => !m.merged && !isHeld(m)); return [...open.filter(isProducer), ...open.filter((m) => !isProducer(m) && !isConsumer(m)), ...open.filter(isConsumer)] }
function shipPrompt(a, r) {
 return `STEP: schedule merge-when-green for devy ${a.id}'s reviewed MRs. Change no code (only append-only conflict resolution).${ENV(`ship-${a.id}`)}
These merges are authorized for this run: local loop passed, review clean, hold list applied (${SW} SHIP step). Merge in THIS order (producers first, consumers last):
${toShip(r).map((m, i) => `${i + 1}. ${m.url} (${m.repo}, ${roleOf(m) || 'independent'})`).join('\n')}
Per MR: & ${DEV} wt lease -Repo <its repo> -Branch <its source branch> -Agent ${a.id} (its "worktree:" line = <wt>; last: ${r.worktrees.join(', ')}), then python ${DT} merge <wt> <iid>${globs(a) && ` --scope '${globs(a)}'`}${isFnd(a) ? ` --no-docs 'foundation ${a.id}'` : ''}; at the end & ${DEV} wt release -Agent ${a.id}. The merge order is registered (bossy.ps1 track):
a consumer whose producer is not merged prints WAIT "waiting for producer": report WAIT, never merge it another way.
Conflicts and merge results: ${SW} SHIP step and Merge results.
Return the report with the same MRs and testerGuide "${r.testerGuide || 'none reported'}".${HOLD_NOTE}`
}

// ---- plan: the budget gate before any agent
const OQ = MODE === 'resume' ? [] : [].concat(A.openQuestions || []).map(String).filter(Boolean)
const PLAN = [...(OQ.length ? [`rechy/${PM('spike')}:1`] : []), ...A.agents.map((a) => `devy/${a.model || PM(isComplex(a) ? 'complex' : 'build')}:${PHASED ? `2,devy/${PM('docs')}:1` : 1},revy/${PM('review')}:1,${a.migrations ? `datay/${PM('review')}:1,` : ''}${a.debate ? `rechy/${PM('debate')}:5,revy/${PM('review')}:1,` : ''}step/${PM('ship')}:3,item:${String(a.items || '').split(',').filter(Boolean).length || 1}`),
 `step/${PM('step')}:2,kitty/${PM('learn')}:1`].join(',')
if (A.agents.every(allDone)) { log('RESUME: every area is done (MRs merged, tracker and testing doc set): nothing to run'); return { resumedDone: A.agents.map((a) => ({ agent: a.id, mrs: RES[a.id].mrs || [] })) } }
const REC = await recordArgs('buildy', RUN, A0, 'Build', PLAN), GAPS = REC.match(/^TASKS REFUSED .*$/gm)
takeBudget(REC, A.agents.length)
takeConfig(REC)
const AREA_TASK = Object.fromEntries([...REC.matchAll(/^AREA TASK (\S+) (?!FAILED)(\S+)/gm)].map((m) => [m[1], m[2]]))
const nextCall = (agents, extra = {}) => ({ scriptPath: `${KIT}/workflows/buildy.js`, args: { ...A0, agents: own(agents), batch: undefined, ...extra } })
if (GAPS) { log(`REFUSED:\n${GAPS.join('\n')}`); return { refused: true, taskGaps: GAPS, next: nextCall([], A0) } }
if (BUD.cap && BUD.estimate > BUD.stopAt * BUD.cap) {
 const batch = Math.max(1, Math.floor(A.agents.length * BUD.stopAt * BUD.cap / BUD.estimate))
 if (A.agents.length === 1) { log(`REFUSED: one area's estimate ${BUD.estimate} > ${BUD.stopAt * 100}% of the cap ${BUD.cap}: split the brief or raise the cap (decide ask)`); return { refused: true, estimate: BUD.estimate, cap: BUD.cap, unsplittable: true } }   // a batch of 1 changes nothing: no next
 log(`REFUSED: estimate ${BUD.estimate} > ${BUD.stopAt * 100}% of the cap ${BUD.cap}: run ${batch} area(s) per run (args.batch)`)
 return { refused: true, estimate: BUD.estimate, cap: BUD.cap, batch, next: nextCall([], { ...A0, batch }) }
}
log(`wave: ${A.agents.length} agents, mode ${MODE}, local retries ${LOCAL_RETRIES}, brief ${A.brief}`)

// ---- spike: rechy answers openQuestions before any devy
if (OQ.length) {
 phase('Spike')
 const sp = await agent(`Kind spike: answer the open questions of the brief ${A.brief} before any devy starts, as your agent definition says.${PATHS}
${OQ.map((q, i) => `${i + 1}. ${q}`).join('\n')}
Append one block per question under "## Findings (rechy)" at the bottom of the brief: answer, evidence, recommendation, confidence
(an owner choice: its decide ask id). Return ok=true when every question is answered (else ok=false: the open ones and decide ids), output = one line per question.`,
  { label: 'spike', phase: 'Spike', schema: OK_SCHEMA, agentType: 'rechy', ...pick('spike') })
 if (!(sp && sp.ok)) { const why = sp ? sp.output : 'rechy returned nothing'; log(`SPIKE OPEN: ${why} - no devy started`); return { spikeOpen: why, next: nextCall(A.agents, { openQuestions: undefined }) } }
 log(`spike: ${OQ.length} open question(s) answered in the brief`)
}

// ---- local-loop: waits, report merges, the local test loop
// merge, don't replace: a later round reports only its own work
const uniq = (x) => [...new Set(x)], fails = (lt) => (lt.failing || []).join('; ')
// C:\a\b and c:/a/b/ = one worktree (first spelling kept)
const uniqPath = (x) => { const seen = new Set(); return x.filter((p) => { const k = String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase(); return k && !seen.has(k) && seen.add(k) }) }
const byId = (x) => [...new Map(x.map((d) => [d.id, d])).values()]
const byKey = (x, k) => [...new Map(x.map((d) => [d[k], d])).values()]
// slices fit the agent's tool timeout
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
 const both = (f) => [...(x[f] || []), ...(r2[f] || [])]
 return { ...x, ...r2, mrs, worktrees: uniqPath(both('worktrees')), done: uniq(both('done')), deferred: byId(both('deferred')).filter((d) => !(r2.done || []).includes(d.id)),
  needsDecision: byKey(both('needsDecision'), 'decisionId'), debate: byKey(both('debate'), 'item'), needsEnvFix: byKey(both('needsEnvFix'), 'envFixId'), needsLiveCheck: uniq(both('needsLiveCheck')),
  seed: uniq(both('seed')), foreignHooks: uniq(both('foreignHooks')),
  testerGuide: r2.testerGuide && !/^none/i.test(r2.testerGuide) ? r2.testerGuide : x.testerGuide, summary: `${x.summary}\n\n${note}: ${r2.summary}` }
}
const settleOnThrow = async (a, fn) => { try { return await fn() } catch (e) { SETTLED[a.id].done(null); throw e } }
async function agentOrRedo(prompt, opts) {
 const r = await agent(prompt, opts)
 if (r) return r
 log(`${opts.label}: redo`)
 return agent(`No report came back: do it now (a merged / scheduled MR: report it, never merge twice).\n${prompt}`, { agentType: 'devy', ...opts, label: `${opts.label}@redo` })
}
const releaseAll = (ids, phaseName) => runStep(`& ${ORCH} release -Agent '${[].concat(ids).join(',')}' -Reason 'agent finished'`, `release-${[].concat(ids).join('-')}`, phaseName, { ok: 'when it exits 0' })
 .then((r) => { if (!r || !r.ok) log(`WARNING release of ${ids} failed (${r ? r.output : 'no answer'}): supervise -AutoFix reclaims after the grace`) }).catch(() => null)
const releasing = async (a, phaseName, fn) => { try { return await fn() } finally { await releaseAll(a.id, phaseName) } }
const decisions = []
const envFixes = []
function normLocal(r) {
 const lt = r && r.localTest
 if (lt && lt.status === 'BLOCKED' && !['decision', 'remote'].includes(lt.blockedKind)) return { ...r, localTest: { ...lt, status: 'FAIL', failing: [...(lt.failing || []), `reported BLOCKED without blockedKind (${lt.blockedReason || lt.env || 'no reason'}): the local env is ours`] } }
 return r
}
// NONE: each MR repo's CONFIG local fallback (unit: a passed unitRun); no MR: any
const unitRan = (u) => /crafty\.ps1\W+check\b/.test(String((u || {}).command)) && /\b(pass(ed)?|ok|green)\b/i.test(String((u || {}).result)) && !/\bfail/i.test(String((u || {}).result))
const fallbackOk = (lt, r) => (lt.fallback !== 'unit' || unitRan(lt.unitRun)) && (((r && r.mrs) || []).length ? r.mrs.every((m) => [lt.fallback || 'ci', 'ci'].includes(repoNames(m).map((n) => CFG.local[n]).find(Boolean))) : !!Object.keys(CFG.local)[0])
// BLOCKED, a FAIL beyond env gaps; with a: a code area's NONE, no decide id or fallback
const noneGated = (lt, a, r) => !!a && !!lt && lt.status === 'NONE' && !['doc', 'spike', 'repro'].includes(a.kind) && !fallbackOk(lt, r)
const holdsMerge = (lt, a, r) => !!lt && (lt.status === 'BLOCKED' || (lt.status === 'FAIL' && !lt.envGap) || (noneGated(lt, a, r) && !/^(?:dec-\d+|d-\d{14}-[\w-]+)$/.test(lt.decisionId)))
// NONE: a person's merge / scope / other word on this area
async function noneWordOk(a, r, id) {
 const its = [a.id, a.task, AREA_TASK[a.id], a.branch, ...[].concat(a.branches || []), ...String(a.items).split(','), ...r.mrs.flatMap((x) => repoNames(x).map((n) => `${n}!${(/(\d+)\/?$/.exec(nu(x.url)) || [])[1]}`))]
 const out = String(((await runStep(`& ${ORCH} decide check -Id ${id} -Gate 'merge,scope,other' -Item '${its.filter(Boolean).map((s) => String(s).trim()).join(',').replace(/['"`$\r\n]/g, '')}' -MaxHours 720`, `none-word:${a.id}`, 'Review', { ok: 'when it prints WORD' })) || {}).output || '').trim()
 if (!/^WORD /.test(out)) log(`${a.id}: localTest NONE, decisionId ${id} refused (${out.slice(0, 200)})`)
 return /^WORD /.test(out)
}
const mergeHeld = async (lt, a, r) => holdsMerge(lt, a, r) || (noneGated(lt, a, r) && !(await noneWordOk(a, r, lt.decisionId)))
async function localLoop(a, r, retries, stage) {
 for (let h = 0; r && r.handoff && h < 3; h++) {
  log(`${a.id}: HANDOFF at its budget (${r.handoff}): a fresh devy continues`)
  const r2 = await agent(continuePrompt(a, r, `HANDOFF: the previous devy reached its budget; read its resume brief ${r.handoff} first and continue from there.`), dvo(a, 'handoff', stage))
  r = mergeReports({ ...r, handoff: '' }, r2, 'Handoff')
 }
 r = normLocal(r)
 if ((r.needsEnvFix || []).length) return r
 // done with no local loop (19 fix rounds, retro 1124): one local round before review, never a fix round
 if (retries && (r.mrs || []).length && (r.localTest || { status: 'NONE' }).status === 'NONE' && await mergeHeld({ status: 'NONE', ...r.localTest }, a, r)) {
  if (!(await gate(stage))) return { ...r, budgetStopped: true }
  log(`${a.id}: reported done with no local loop - local round before review`)
  const r2 = await agent(continuePrompt(a, r, 'You reported done without the local test loop (localTest NONE). Run it now on the local env: every goal, then report localTest.'), dvo(a, 'local', stage))
  if (r2 && Array.isArray(r2.mrs)) r = normLocal(mergeReports(r, r2, 'Local loop round'))
 }
 for (let i = 0; i < retries && r.localTest && r.localTest.status === 'FAIL' && holdsMerge(r.localTest); i++) {
  if (!(await gate(stage))) return { ...r, budgetStopped: true }
  log(`${a.id}: local test FAILED (${fails(r.localTest)}) - local round ${i + 2}`)
  const r2 = await agent(continuePrompt(a, r, `Your local test loop still FAILS: ${fails(r.localTest)}. Debug locally (logs, DB state, debugger), fix, redeploy, re-run every goal.`),
   dvo(a, 'local', stage))
  r = normLocal(mergeReports(r, r2, `Local round ${i + 2}`))
 }
 if (r.localTest && r.localTest.status === 'FAIL' && holdsMerge(r.localTest) && MODELS.retest) {
  if (!(await gate(stage))) return { ...r, budgetStopped: true }
  log(`${a.id}: local test still FAILS - one stronger fix round on ${MODELS.retest}`)
  const r2 = await agent(continuePrompt(a, r, `STRONGER FIX ROUND: earlier rounds could not make these goals pass: ${fails(r.localTest)}.
From the evidence (logs, DB state, the reproduction): root cause, fix, redeploy, re-run every goal. An env problem is ours to fix
(THE DEV FLOW step 3), never a reason to stop.`), { ...dvo(a, 'local-strong', stage), model: MODELS.retest, effort: MODELS.retestEffort || 'high' })
  r = normLocal(mergeReports(r, r2, 'Stronger fix round'))
 }
 return r
}

// ---- stages: build -> review -> fix per area
const results = await pipeline(
 A.agents,
 // Build (a dead agent: one retry)
 (a) => settleOnThrow(a, async () => {
  if (skips(a, 'build')) {
   const r0 = synth(a)
   log(`${a.id}: resumed, skipped: ${[].concat(RES[a.id].skip).join(', ')}`)
   if (r0.resumed !== 'merged' || skips(a, 'testing-doc')) return r0
   const r2 = await agent(postMergePrompt(a, r0), dvo(a, 'postmerge', 'Build'))
   return { ...mergeReports(r0, r2, 'Post-merge'), mrs: r0.mrs, localTest: r0.localTest, resumed: 'merged' }
  }
  const open = await producersOpen(a)
  if (open.length) { const why = `producer(s) ${open.join(', ')} not MERGED: not started (outcome.afterMerge)`; log(`${a.id}: ${why}`); return { id: a.id, error: why, blocked: why, waitFor: open } }
  return releasing(a, 'Build', async () => {
  const dbt = a.debate && MODE !== 'resume' ? debateOrAsk(a, { ...a.debate, trigger: 'brief' }, 'Build') : null
  const ph = PHASED && !['spike', 'repro'].includes(a.kind)
  let r = await agent(buildPrompt(a) + (ph ? PH.code : ''), dvo(a, 'build', 'Build'))
  if (!r) { log(`${a.id}: build agent returned nothing - one retry (infra flake)`); r = await agent(continuePrompt(a, {}, 'No report came back: find what is done (wt lease + wt status, the board), continue.'), dvo(a, 'build-retry', 'Build')) }
  if (!r) return { id: a.id, error: 'agent returned nothing (twice)' }
  // a HANDOFF stays in its phase; no report after a redo: the phase before stands
  const asRep = (x) => (x && Array.isArray(x.mrs) ? x : null)
  const goOnIn = async (x, text) => { for (let h = 0; ph && x.handoff && h < 3; h++) x = mergeReports({ ...x, handoff: '' }, asRep(await agent(continuePrompt(a, x, `HANDOFF: read your resume brief ${x.handoff} first, continue. ${text}`), dvo(a, 'handoff', 'Build'))), 'Handoff'); return x }
  const phase = async (x, text, l, more) => ((await gate('Build')) ? goOnIn(mergeReports(x, asRep(await agentOrRedo(continuePrompt(a, x, text), { ...dvo(a, l, 'Build'), ...more })), `Phase ${l}`), text) : { ...x, budgetStopped: true })
  const phaseNext = (x) => ph && !x.budgetStopped && !(x.mrs || []).length && !(x.needsDecision || []).length && !(x.needsEnvFix || []).length
  r = await goOnIn(r, PH.code)
  if (phaseNext(r)) r = await phase(r, PH.local, 'loop', {})
  let o = await localLoop(a, r, LOCAL_RETRIES, 'Build')
  if (phaseNext(o)) o = { ...(await phase(o, PH.ship + (holdsMerge(o.localTest, a) ? PH.held : ''), 'docs', pick('docs'))), localTest: o.localTest }
  return dbt ? debated(o, a.debate.item, await dbt, a.debate.question) : o
  })
 }),
 // Decide: answers, ENV-FIXes, debates
 (r, a) => settleOnThrow(a, async () => {
  if (!r || r.error || r.budgetStopped || !((r.needsDecision || []).length || (r.needsEnvFix || []).length || (r.debate || []).length)) return r
  return releasing(a, 'Decide', async () => {
  let cur = r, envCycles = 0
  const goOn = async (c, why, l, note) => localLoop(a, mergeReports(c, await agent(continuePrompt(a, c, why), dvo(a, l, 'Decide')), note), LOCAL_RETRIES, 'Decide')
  const asked = new Set()
  for (let round = 0; round < 8; round++) {
   for (const q of cur.debate || []) {
    cur = debated(cur, q.item, await debateOrAsk(a, { ...q, trigger: 'low confidence' }, 'Decide'), q.question)
   }
   cur = { ...cur, debate: [] }
   const fixes = cur.needsEnvFix || []
   const decs = (cur.needsDecision || []).filter((d) => !asked.has(d.decisionId))
   if (!fixes.length && !decs.length) break
   if (fixes.length) {
    if (envCycles++ >= ENV_FIX_CYCLES) {
     cur = defer({ ...cur, needsEnvFix: [] }, fixes.map((f) => ({ id: f.item, reason: `ENV-FIX ${f.envFixId} unresolved after ${ENV_FIX_CYCLES} cycle(s): the coordinator decides` })))
     log(`${a.id}: ENV-FIX unresolved after ${ENV_FIX_CYCLES} cycle(s) for ${fixes.map((f) => f.item).join(', ')} - deferred`)
     continue
    }
    const done = []
    for (const f of fixes) {
     envFixes.push({ agent: a.id, ...f })
     log(`${a.id}: item ${f.item} waits for ENV-FIX ${f.envFixId} (coordinator: bossy.ps1 decide answer)`)
     done.push({ ...f, ans: await waitAnswer(f.envFixId, `envfix:${a.id}`, WAIT_SLICES) })
    }
    const answered = done.filter((f) => f.ans && !/:\s*cannot\b/i.test(f.ans))
    const failed = done.filter((f) => !answered.includes(f))
    if (failed.length) cur = defer(cur, failed.map((f) => ({ id: f.item, reason: `ENV-FIX ${f.envFixId}: ${f.ans || 'no fix within the wait'} (the coordinator decides)` })))
    cur = { ...cur, needsEnvFix: [] }
    if (!answered.length) continue
    if (!(await gate('Decide'))) { cur = { ...cur, budgetStopped: true }; break }
    cur = await goOn(cur, `The coordinator fixed the local env:\n${answered.map((f) => `- item ${f.item} (${f.envFixId}): ${f.ans}`).join('\n')}\nContinue those items (local test loop, MR, testing doc).`, 'envfix-resume', 'After ENV-FIX')
    continue
   }
   for (const d of decs) {
    asked.add(d.decisionId)
    decisions.push({ agent: a.id, ...d })
    log(`${a.id}: item ${d.item} waits for decision ${d.decisionId} (coordinator: bossy.ps1 decide answer)`)
    const ans = await waitAnswer(d.decisionId, `decide:${a.id}`, WAIT_SLICES)
    if (!ans) { cur = defer(cur, [{ id: d.item, reason: `needs decision ${d.decisionId} (no answer within the wait)` }]); continue }
    if (!(await gate('Decide'))) { cur = { ...cur, budgetStopped: true }; break }
    cur = await goOn(cur, `The owner answered decision ${d.decisionId} for item ${d.item}: ${ans}\nFinish item ${d.item} accordingly (testing goals, local test loop, MR, testing doc).`, 'resume', `Decision ${d.decisionId}`)
   }
   if (cur.budgetStopped) break
  }
  return { ...cur, needsDecision: [], needsEnvFix: [] }
  })
 }),
 // Review + CI (+ one fix round), ship
 (r, a) => settleOnThrow(a, async () => {
  if (!r || r.error) return r && r.error ? r : { id: a.id, error: 'agent returned nothing' }
  if (r.budgetStopped) return { id: a.id, report: r, findings: [], budgetStopped: true }
  if (['done', 'merged'].includes(r.resumed)) return { id: a.id, report: r, findings: [], resumed: r.resumed }
  const lt = r.localTest || { status: 'NONE' }
  if (!holdsMerge(lt) && lt.status === 'FAIL') log(`${a.id}: local FAIL only env gaps (${fails(lt)}): merged on a green pipeline`)
  if (await mergeHeld(lt, r.mrs.length && a, r)) {
   const why = lt.status === 'BLOCKED' ? `${lt.blockedKind}: ${lt.blockedReason || ''}` : lt.status === 'NONE' ? 'no local loop: run it, or an owner word (localTest.decisionId) or repos[].localTest' : fails(lt) || lt.env
   log(`${a.id}: local test ${lt.status} - not reviewed, not merged (${why})${['FAIL', 'NONE'].includes(lt.status) || lt.blockedKind === 'remote' ? ': the coordinator decides' : ''}`)
   return { id: a.id, report: r, findings: [], blocked: `local test ${lt.status}${lt.status === 'FAIL' ? ' after the stronger fix round' : ''}: ${why}` }
  }
  if (!r.mrs.length) return { id: a.id, report: r, findings: [] }
  const [rv, mv] = await reviews(a, r)
  if (!rv) return { id: a.id, report: r, findings: [BLOCK(r.mrs, 'The review agent returned nothing: unreviewed, not merged.', REREVIEW)], reviewFailed: true }
  if (a.migrations && !mv) return { id: a.id, report: r, findings: [BLOCK(r.mrs, 'The migration review (datay) returned nothing: unreviewed, not merged.', 'Re-run datay kind migration on these MRs, then merge.')], reviewFailed: true }
  const findings = [...(rv.findings || []), ...((mv && mv.findings) || [])]
  let x = { id: a.id, report: r, findings }
  let blocking = findings.filter(mustFix)
  if (!blocking.length) blocking = await ciGate(a, r)
  if (blocking.length) {
   if (!(await gate('Fix'))) return { ...x, budgetStopped: true }
   log(`${a.id}: ${blocking.length} blocking finding(s) / failed pipeline(s) -> fix round`)
   const r2 = await agent(fixPrompt(a, r, blocking), dvo(a, 'fix', 'Fix'))
   if (!r2) return { ...x, findings: [...findings.filter((f) => !mustFix(f)), ...blocking], fixed: false, stopped: true }
   x = { ...x, findings: [...findings.filter((f) => !mustFix(f)), ...blocking], fixed: true, report: await releasing(a, 'Fix', () => localLoop(a, mergeReports(r, r2, 'Fix round'), 0, 'Fix')) }
   const lt2 = x.report.localTest || {}
   if (await mergeHeld(lt2, a, x.report)) return { ...x, fixed: false, blocked: `local test ${lt2.status} after the fix round` }
   // re-review: blocking holds (a round, then a decision); rest -> Follow-ups
   const gone = [], decided = new Map()   // finding key -> 'A' | 'B' | a pending decision id
   const settle = async (rep, l) => { const k = await settleDisputes(a, rep, l, decided); gone.push(...l.filter((f) => !k.includes(f))); x = { ...x, findings: x.findings.filter((f) => !gone.includes(f)) }; return k }
   let open = await settle(r2, findings.filter(mustFix)), soft = []
   const held = async (y, more = []) => ({ ...x, ...y, fixed: false, findings: [...x.findings, ...open], ...((soft.length || more.length) && { followUps: await followUps(a, x.report, [...soft, ...more]) }) })
   for (let round = 1; open.length; round++) {
    const rr = `\nRE-REVIEW after fix round ${round}: check that these findings are resolved and that the fix added no new problem:\n${open.map((f) => `- ${fkey(f)}: ${f.problem}`).join('\n')}${gone.length ? `\nSettled in a dispute, never raise again: ${gone.map(fkey).join(', ')}` : ''}`
    const [rv2, mv2] = await reviews(a, x.report, rr, {})
    const again = [rv2, mv2].flatMap((v) => v ? (v.findings || []) : [BLOCK(x.report.mrs, 'The re-review agent returned nothing: the fix round is unreviewed, not merged.', REREVIEW)])
    soft.push(...again.filter((f) => f.severity !== 'blocking')); open = again.filter((f) => f.severity === 'blocking')
    if (!open.length) break
    if (round >= 2 || !rv2 || !mv2) { const d = await askBlocking(a, x.report, open, decided); return held(d ? { decisionAsked: d } : {}, d ? open : []) }   // no reviewer: nothing to fix
    if (!(await gate('Fix'))) return held({ budgetStopped: true })
    log(`${a.id}: re-review: ${open.length} blocking finding(s) -> one last fix round`)
    const ownB = [...decided].filter(([, v]) => v === 'B').map(([k]) => k)
    const r4 = await agent(fixPrompt(a, x.report, open) + (ownB.length ? `\nThe owner decided these stay: fix them, no dispute: ${ownB.join(', ')}` : ''), dvo(a, 'fix', 'Fix'))
    if (!r4) return held({ stopped: true })
    open = await settle(r4, open)
    x = { ...x, report: await releasing(a, 'Fix', () => localLoop(a, mergeReports(x.report, r4, 'Fix round 2'), 0, 'Fix')) }
    const lt3 = x.report.localTest || {}
    if (await mergeHeld(lt3, a, x.report)) return held({ blocked: `local test ${lt3.status} after fix round 2` })
   }
   if (soft.length) x = { ...x, followUps: await followUps(a, x.report, soft) }
   const failures = await ciGate(a, x.report)
   if (failures.length) { log(`${a.id}: pipelines still failing after the fix round - left open`); return { ...x, fixed: false, findings: [...x.findings, ...failures] } }
  }
  return ship(a, x)
 }).then((y) => { SETTLED[a.id].done(y); return y }),
 // Track: the tracker task
 async (x, a) => {
  if (!x || x.error || !x.report || !x.report.mrs.length || (x.resumed && skips(a, 'tracker'))) return x
  const deferred = (x.report.deferred || []).filter((d) => !d.ownerDecided && d.kind !== 'people')
  const why = x.blocked || (x.budgetStopped ? 'run budget reached: continues in the next run' : '') || (deferred.length ? `deferred items: ${deferred.map((d) => d.id).join(', ')}` : x.stopped ? 'agent stopped' : '')
  if (why) log(`${a.id}: tracker task registered with its promotion HELD (${why}): release with bossy.ps1 track add -Task <id> -HoldPromotion ''`)
  const tr = await agentOrRedo(`STEP: register devy ${a.id}'s tracker task for its MRs. Change no code, merge nothing.${ENV(`track-${a.id}`)}
MRs: ${x.report.mrs.map((m) => m.url).join(', ')}
1. The task id is in each MR's title after the tracker tag (the title wins over the branch); group the MRs by task.
2. Per task: & ${ORCH} track add -Task <task id> -Discover -Mrs '<repo>!<iid>','<repo>!<iid>'${why ? ` -HoldPromotion '${why.replace(/'/g, '').slice(0, 200)}'` : AREA_TASK[a.id] ? ` -HoldPromotion ''` : ''}
Return ok=true and the output lines.`, { label: `track:${a.id}`, phase: 'Fix', schema: OK_SCHEMA, agentType: 'kitty', model: MODELS.ship || MODELS.step, effort: 'low' })
  if (!tr || !tr.ok) log(`${a.id}: WARNING tracker task not registered (${tr ? tr.output : 'agent returned nothing'})`)
  return why ? { ...x, trackHeld: why } : x
 },
)

// ---- ship: CI gate, merge, outcome
async function ciGate(a, r) {
 if (!r.mrs.some((m) => !m.merged)) return []
 const ci = await agentOrRedo(ciPrompt(r, a), { label: `ci:${a.id}`, phase: 'Review', schema: CI_SCHEMA, agentType: 'kitty', model: MODELS.ci || MODELS.step, effort: 'low' })
 if (!ci) { log(`${a.id}: WARNING CI gate agent returned nothing; merge-when-green still waits for the pipelines`); return [] }
 return (ci.mrs || []).filter((m) => m.status === 'failed').map((m) => ({ mr: m.mr, file: `CI job ${m.job || '?'}`, severity: 'blocking',
  problem: `The MR pipeline failed in job ${m.job || '?'}:\n${m.error || '(no error text captured)'}`,
  fix: 'Reproduce the failing job locally through the gate (crafty.ps1 check), fix the cause, push, green pipeline.' }))
}
// re-review should-fix / nit findings -> MR "## Follow-ups"
async function followUps(a, r, soft) {
 const file = `${rp('agents')}/${a.id}/followups.json`, mrs = r.mrs.filter((m) => !m.merged)
 const has = (f, u) => new RegExp(u.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?!\\d)').test(String(f.mr || ''))
 if (!mrs.length) return []
 for (const m of mrs) {
  const mine = soft.filter((f) => has(f, m.url) || !mrs.some((o) => has(f, o.url)))
  log(`${a.id}: ${m.url}: ${mine.length} re-review finding(s) -> Follow-ups${mine.length ? `: ${mine.map((f) => `${f.severity} ${fkey(f)}`).join(', ')}` : ''}`)
 }
 const st = await agentOrRedo(`STEP: put review follow-ups into the MR descriptions. Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${file} with the Write tool, byte for byte (one line of JSON; no markers); read it back: it parses:
<<<JSON
${JSON.stringify(soft)}
JSON>>>
2. Run in PowerShell: python -X utf8 ${DT} followups ${file} ${mrs.map((m) => m.url).join(' ')}
Return ok=true when it exits 0, output = its full output.`, { ...SO(`followups:${a.id}`, 'Fix'), agentType: 'devy' })
 if (!st || !st.ok) { log(`${a.id}: WARNING Follow-ups not written (${st ? st.output : 'the step returned nothing'}): add them by hand`); return soft.map((f) => ({ ...f, written: false })) }
 return soft
}
// blocking after 2 fix rounds: an owner decision with both sides
async function askBlocking(a, r, open, decided) {
 const pend = open.map((f) => decided.get(fkey(f))).filter((v) => v && !['A', 'B'].includes(v))
 if (pend.length === open.length) { log(`${a.id}: still blocking; the owner's answer to ${pend[0]} is pending - not merged`); return pend[0] }
 const mrs = r.mrs.map((m) => m.url).join(' '), q = cl(open.map((f) => `${fkey(f)}: ${f.problem}`).join(' / '), 400)
 const dv = cl(open.map((f) => ((r.disputes || []).find((d) => d.finding === fkey(f)) || {}).evidence).filter(Boolean).join('; ') || (r.summary || '').split('\n').pop(), 200)
 const id = await debateOrAsk(a, { item: mrs, question: `Still blocking after 2 fix rounds: ${q}`, trigger: 'rejected twice', recommend: 'B',
  options: [`A: merge by hand, the finding goes to Follow-ups (devy: ${dv})`, `B: hold, fix it by hand (revy: ${cl(open[0].fix, 150)})`] }, 'Fix')
 log(`${a.id}: re-review still blocking after 2 fix rounds (${open.length}): ${id ? `decision ${id} asked` : 'WARNING decide ask failed'} - not merged`)
 if (id) decisions.push({ agent: a.id, item: mrs, decisionId: id, question: `still blocking: ${q}` })
 return id
}
// ---- debate: a dispute gets one revy answer; still split -> a debate or an A/B ask
async function settleDisputes(a, rep, open, decided) {
 const of = (d) => open.find((f) => fkey(f) === d.finding), ds = ((rep && rep.disputes) || []).filter((d) => d && d.evidence && of(d) && !decided.has(d.finding))
 if (!ds.length) return open
 const said = new Map()   // finding key -> the owner's free-text answer
 log(`${a.id}: devy contests ${ds.length} finding(s) -> one revy answer`)
 const v = await agent(`Kind dispute: devy ${a.id} contests your findings on ${rep.mrs.map((m) => m.url).join(', ')}; answer as your agent definition says.${PATHS}
${ds.map((d) => `- ${d.finding}: ${of(d).problem} | devy: ${d.evidence}`).join('\n')}`, { label: `dispute:${a.id}`, phase: 'Review', schema: ANSWERS, agentType: 'revy', ...pick('review') })
 for (const d of ds) {
  const ans = ((v && v.answers) || []).find((x) => x.finding === d.finding) || {}, q = `Dispute on ${d.finding}: ${cl(of(d).problem, 200)} (revy: ${cl(ans.why, 150)})`
  if (ans.verdict === 'withdrawn') { decided.set(d.finding, 'A'); continue }
  const id = await debateOrAsk(a, { item: d.finding, question: q, trigger: 'dispute', recommend: 'B', options: [`A: devy - no fix: ${d.evidence}`, `B: revy - fix it: ${ans.evidence || of(d).fix}`] }, 'Review')
  if (id) { decisions.push({ agent: a.id, item: d.finding, decisionId: id, question: q }); decided.set(d.finding, id) }
 }
 await Promise.all([...decided].filter(([k, v]) => ds.some((d) => d.finding === k) && !['A', 'B'].includes(v)).map(async ([k, id]) => {
  const w = (await waitAnswer(id, `dispute-wait:${a.id}`, WAIT_SLICES)) || '', ch = (/ANSWERED \S+:\s*(A|devy)\b/i.test(w) && 'A') || (/ANSWERED \S+:\s*(B|revy)\b/i.test(w) && 'B')
  if (ch) decided.set(k, ch)
  else if (/ANSWERED \S+:\s*\S/i.test(w)) { decided.set(k, 'B'); said.set(k, w.replace(/^[\s\S]*?ANSWERED \S+:\s*/i, '').trim()) }
 }))
 return open.filter((f) => decided.get(fkey(f)) !== 'A').map((f) => (said.has(fkey(f)) ? { ...f, fix: `${f.fix || ''} (owner: ${cl(said.get(fkey(f)), 300)})` } : f))
}
// one debate per run (owner: always), else or failed: an A/B ask
async function debateOrAsk(a, d, ph) {
 const arg = `-Item '${cl(d.item, 200)}' -Question "${cl(d.question, 400)}" -Options ${[].concat(d.options).slice(0, 2).map((o) => `"${cl(o, 300)}"`).join(',')}`
 const did = (s) => (((s && s.output) || '').match(/DECISION (\S+)/) || [])[1] || '', DOK = { ok: 'when it prints DECISION <id>' }
 if ((d.owner || !DEB.used++) && await gate(ph)) {
  const mod = await agent(`Kind debate: & ${ORCH} debate start -Run ${RUN} -Agent ${a.id} ${arg} -Why '${d.trigger}'${d.owner ? ' -Owner' : ''}, then moderate the file it prints
as your agent definition says (advocate models: ${DM.join(', ') || MODELS.debate}); output = that file.${PATHS}`, { label: `debate:${a.id}`, phase: ph, schema: OK_SCHEMA, agentType: 'rechy', ...pick('debate') })
  const id = did(mod && mod.ok && await runStep(`& ${ORCH} debate ask -File '${mod.output}'`, `debate-ask:${a.id}`, ph, DOK))
  log(`${a.id}: debate (${d.trigger}) on ${d.item}: ${id ? `decision ${id}` : 'failed, plain ask'}`)
  if (id) return id
 }
 return did(await runStep(`& ${ORCH} decide ask -Run ${RUN} -Agent ${a.id} -Context "${cl(d.why || `${d.trigger || 'a review'} left 2 valid paths`, 200)}" ${arg}${d.recommend ? ` -Recommend ${d.recommend}` : ''}`, `decide:${a.id}`, ph, DOK))
}
// open producer ids (polled): consumers wait
async function producersOpen(a) {
 if (!DEPS[a.id].length) return []
 const prods = await Promise.all(DEPS[a.id].map((id) => SETTLED[id].p))
 const unmerged = (i) => !prods[i] || !prods[i].report || !prods[i].report.mrs.length ? [{ url: '' }] : prods[i].report.mrs.filter((m) => !m.merged && !MERGED_SEEN.has(nu(m.url)))
 let wait = DEPS[a.id].flatMap((id, i) => unmerged(i))
 if (!wait.every((m) => m.url && ['SCHEDULED', 'WAIT'].includes(m.mergeState) && !isHeld(m))) wait = []
 for (let t = 0; t < WAIT_SLICES && wait.length; t++) {
  const w = await runStep(`& ${DEV} pipes -Mrs ${wait.map((m) => m.url).join(',')} -MaxMinutes 9 -UntilMerged`, `producer-wait:${a.id}`, 'Fix', { ok: 'when it prints JSON', slow: true, whole: true })
  let st
  try { st = JSON.parse((w && w.output) || '').mrs || [] } catch (e) { break }
  for (const s of st) if (s.status === 'merged') MERGED_SEEN.add(nu(s.mr))
  wait = wait.filter((m) => !MERGED_SEEN.has(nu(m.url)))
  if (st.some((s) => ['failed', 'canceled', 'closed', 'bad-url'].includes(s.status))) break
 }
 return DEPS[a.id].filter((id, i) => unmerged(i).length)
}
async function ship(a, x) {
 const held = x.report.mrs.filter((m) => !m.merged && isHeld(m))
 if (held.length) log(`${a.id}: ${held.length} MR(s) held for approval (holdMerge): ${held.map((m) => m.url).join(', ')}`)
 if (!toShip(x.report).length) return x
 const late = await producersOpen(a)   // resumed: no build gate
 if (late.length) return { ...x, shipFindings: [BLOCK(x.report.mrs, `Producer(s) ${late.join(', ')} not merged: nor these (merge order).`, 'Merge the producer, then these.')], mergeOrderHeld: true }
 const open = toShip(x.report), cons = open.filter(isConsumer)
 const pairs = cons.flatMap((c) => open.filter(isProducer).map((p) => `${c.url}>${p.url}`))
 if (pairs.length) {
  const reg = await runStep(`& ${ORCH} track add -Task <task id: the MR title after the tracker tag, else the branch> -Mrs '${(cons[0] || open[0]).url}' -MergeAfter '${pairs.join(',')}'`,
   `order:${a.id}`, 'Fix', { ok: 'when its last line lists "merge-after:"' })
  if (!reg || !reg.ok || !/merge-after:/.test(reg.output)) return { ...x, mergeOrderHeld: true, shipFindings: [BLOCK(open, `Merge order not registered (${reg ? reg.output : 'the step returned nothing'}): nothing merged.`, `bossy.ps1 track add -Task <id> -MergeAfter '${pairs.join(',')}', then devtools.py merge`)] }
 }
 const r3 = await agentOrRedo(shipPrompt(a, x.report), { label: `ship:${a.id}`, phase: 'Fix', schema: REPORT, agentType: 'devy', ...pick('ship'), effort: 'low' })
 if (!r3) { log(`${a.id}: WARNING ship agent returned nothing - MRs not scheduled`); return x }
 const state = new Map(r3.mrs.map((m) => [nu(m.url), m.mergeState || (m.merged ? 'MERGED' : 'OPEN')]))
 const mrs = uniqMr(x.report.mrs).map((m) => { const s = m.merged ? 'MERGED' : (state.get(nu(m.url)) || m.mergeState || 'OPEN'); return { ...m, mergeState: s, merged: s === 'MERGED' } })
 const conflicts = mrs.filter((m) => m.mergeState === 'CONFLICT').map((m) => BLOCK([m], `Merge conflict outside append-only files: ${r3.summary}`.slice(0, 1500), 'wt sync, resolve by hand, re-check, push --force-with-lease, devtools.py merge again.'))
 const NEXT = { 'WAIT': 'devtools.py merge again in a few minutes (or bossy.ps1 track run once the producer merged)',
  'PIPELINE_FAILED': 'reproduce the failing job locally through the gate (crafty.ps1 check), fix it on the branch, push, merge again (a follow-up /buildy fix round)',
  'NOT_MERGED': 'read the MR state (approvals, draft, permissions), then devtools.py merge again or merge by hand',
  'OPEN': 'the ship step did not reach a merge: devtools.py merge again' }
 for (const m of mrs.filter((m) => !isHeld(m) && m.mergeState in NEXT)) {
  conflicts.push({ mr: m.url, file: '-', severity: 'blocking', problem: `Not merged (${m.mergeState}): ${r3.summary}`.slice(0, 1500), fix: NEXT[m.mergeState] })
 }
 return { ...x, shipFindings: conflicts, report: { ...x.report, mrs, summary: `MR state (authoritative): ${mrs.map((m) => `${m.url} ${m.mergeState}`).join(', ')}\n\n${x.report.summary}` } }
}

const out = results.filter(Boolean), fromReports = (k) => out.flatMap((x) => (x.report ? x.report[k] : []))
for (const x of out) {
 if (x.error) { if (x.waitFor) log(`${x.id}: BLOCKED by unmerged producer(s) ${x.waitFor.join(', ')}: not started (outcome.afterMerge.next)`); else if (!x.blocked) log(`${x.id}: ERROR ${x.error}`); continue }
 const r = x.report
 log(`${x.id}: ${r.mrs.filter((m) => m.merged).length}/${r.mrs.length} MRs merged, scheduled ${r.mrs.filter((m) => m.mergeState === 'SCHEDULED').length}, local ${(r.localTest || {}).status || '?'}, done ${r.done.length}, deferred ${r.deferred.length}${x.blocked ? `, BLOCKED (${x.blocked})` : ''}`)
}
await measure('Fix')
await releaseAll(A.agents.map((a) => a.id), 'Fix')   // backstop, also an area that threw
const outcome = {
 agents: out,
 deferred: out.flatMap((x) => (x.report ? x.report.deferred.map((d) => ({ agent: x.id, ...d })) : [])),
 blocked: out.filter((x) => x.blocked).map((x) => ({ agent: x.id, why: x.blocked, ...(x.waitFor ? { blockedBy: x.waitFor } : {}) })),
 decisions,
 envFixes,
 needsLiveCheck: fromReports('needsLiveCheck'),
 seed: fromReports('seed'),
 openFindings: out.flatMap((x) => [...(x.fixed ? [] : (x.findings || []).filter(mustFix)), ...(x.shipFindings || [])]),
 followUps: out.flatMap((x) => (x.followUps || []).map((f) => ({ agent: x.id, ...f }))),
 testerGuides: out.filter((x) => x.report).map((x) => ({ agent: x.id, ...(isFnd(A.agents.find((g) => g.id === x.id)) ? { guide: 'exempt: foundation (merge --no-docs)', docsExempt: true } : { guide: x.report.testerGuide || 'MISSING' }) })),
 budget: { cap: BUD.cap, estimate: BUD.estimate, spent: BUD.spent, stopped: BUD.stop, handoffs: out.filter((x) => /Handoff:/.test((x.report || {}).summary || '')).map((x) => x.id) },
}
// budget-stopped areas + those past args.batch: a relaunch
const orig = (id) => A0.agents.find((g) => g.id === id)
const leftover = [...out.filter((x) => x.budgetStopped).map((x) => orig(x.id)).filter(Boolean), ...(BATCH ? A0.agents.slice(BATCH) : [])]
const resMap = Object.fromEntries(out.filter((x) => x.budgetStopped).map((x) => { const r = x.report || {}; return [x.id, { ...(RES[x.id] || {}), state: 'budget stop', skip: [...new Set([].concat((RES[x.id] || {}).skip || [], (r.mrs || []).length && (r.localTest || {}).status === 'PASS' ? ['build'] : []))], mrs: r.mrs || [], doc: r.testerGuide || '', worktrees: r.worktrees || [] }] }))
if (leftover.length) { outcome.next = nextCall(leftover, Object.keys(resMap).length ? { mode: 'resume', resume: resMap } : {}); log(`NEXT: ${leftover.length} area(s) continue in a new run: ${leftover.map((g) => g.id).join(', ')} (outcome.next)`) }
const held = out.filter((x) => x.waitFor)
if (held.length) outcome.afterMerge = { waitFor: uniq(held.flatMap((x) => x.waitFor)), next: nextCall(held.map((x) => orig(x.id))) }
for (const g of outcome.testerGuides) if (g.docsExempt) log(`${g.agent}: ${g.guide}`); else if (CFG.humanDoc !== false && (!g.guide || g.guide === 'MISSING' || /^none/i.test(g.guide))) log(`${g.agent}: no human testing doc (${g.guide}) - the coordinator writes or requests one before testers start`)

// ---- deploy: merged work joins the deploy batch; never deploys (bossy E5)
phase('Deploy')
const shipped = out.flatMap((x) => (x.report && x.resumed !== 'done' ? x.report.mrs.filter((m) => m.merged || m.mergeState === 'SCHEDULED').map((m) => m.url) : []))
const DEPLOYS = `${KIT}/skills/bossy/adapters/deploys.ps1`
const dp = shipped.length ? await runStep(`# record the merged MRs as pending only: this step deploys nothing and asks nobody
if (Test-Path '${DEPLOYS}') { & ${ORCH} deploy request -Mrs ${shipped.join(',')} -Run ${RUN} -Note "buildy ${RUN}" -Json } else { 'NO-DEPLOYS' }`,
 'deploy-batch', 'Deploy', { whole: true, slow: true }) : null
if (dp && /NO-DEPLOYS/.test(dp.output || '')) log('deploy batch skipped: no deploys adapter in this kit (merged work waits for a person)')
else if (shipped.length) {
 try { outcome.deployBatch = JSON.parse((dp && dp.output) || '[]') } catch (e) { outcome.deployBatch = { raw: dp ? dp.output : 'deploy-batch agent returned nothing' } }
 const ask = Array.isArray(outcome.deployBatch) && outcome.deployBatch.some((p) => p && p.trigger === 'ask')
 log(ask ? `DEPLOY ASK: ${shipped.length} MR(s) merged; the coordinator shows the batch (bossy.ps1 deploy plan) and asks the owner once per env`
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
const learned = await agent(`Kind retro (learn step): record this /buildy run's signals.${PATHS}
Outcome (JSON):
${JSON.stringify(outcome).slice(0, 60000)}

1. One signal per notable event (failures, local-test rounds, blocked items, decisions, review findings, deferrals, budget stops / handoffs, anything that cost
 time or worked unusually well): & ${ORCH} learn -Skill <crafty|envy|other skill> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. & ${ORCH} cleanup -WorktreeIdleHours 0: mention what it freed.
Return how many signals you recorded.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, agentType: 'kitty', ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s)`)
return retroDue(outcome)
